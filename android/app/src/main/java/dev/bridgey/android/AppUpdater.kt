package dev.bridgey.android

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import dev.bridgey.android.updates.UpdateReason
import dev.bridgey.android.updates.UpdateState
import dev.bridgey.android.updates.UpdateStatus
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class UpdateUiState(
    val channel: UpdateChannel,
    val lastCheckedAt: Long,
    val checking: Boolean = false,
    val available: AndroidUpdate? = null,
    val downloadProgress: Float? = null,
    val needsInstallPermission: Boolean = false,
    val promptVisible: Boolean = false,
    /** Later was tapped: Settings says the update is waiting instead of showing it in full. */
    val deferred: Boolean = false,
    /** The version the user skipped, hidden until they check by hand. */
    val skippedVersion: String? = null,
    /** The APK is with the Android installer, waiting for the user to confirm. */
    val awaitingConfirmation: Boolean = false,
    val error: UpdateError? = null,
    /** The update is downloaded and verified, waiting to install (Update all's countdown, or Later). */
    val readyToInstall: Boolean = false,
    /** Handed to the Android installer; Bridgey restarts next. */
    val installing: Boolean = false,
    /** The version this phone installed and then started again without. Never tried again on its own. */
    val notApplied: dev.bridgey.android.updates.NotApplied? = null,
    /** Started by a paired device or by Update all: no Bridgey dialogs, high-priority notifications instead. */
    val remoteRun: Boolean = false,
)

/**
 * Round Robin edition self-updater. Reads the channel feeds published on the
 * fork's GitHub release tag `channels`, downloads the APK only after the user
 * taps Install (or Update all, here or on a paired device), verifies its SHA-256,
 * package, version code and signing certificate, and hands it to PackageInstaller.
 * On Android 12 and later it asks Android not to require a tap (see
 * [commitInstallSession]); Android still shows its confirmation when it must.
 */
class AppUpdater(
    private val context: Context,
    private val scope: CoroutineScope,
) {
    private val preferences = context.getSharedPreferences("bridgey.updates", Context.MODE_PRIVATE)
    private val checkMutex = Mutex()
    private var installJob: Job? = null

    /** The downloaded and verified APK waiting for [commitPrepared], with the update it is. */
    @Volatile private var prepared: Pair<java.io.File, AndroidUpdate>? = null

    /** Set by the application: a Bridgey screen is in front (then Android's own screens can open at once). */
    @Volatile var isForeground: () -> Boolean = { false }

    /**
     * Set by Update all: "Update all devices automatically" is on. Then the scheduled check runs every 30
     * minutes (6 hours on Stable), waking up and network changes check too, and a new version starts the
     * automatic run instead of the "Update available" prompt and notification.
     */
    @Volatile var automatic: () -> Boolean = { false }

    /** The last check started by waking up or a network change (not saved: a fresh process may check once). */
    @Volatile private var lastEventCheckAt = 0L

    /** The updater can run: this build has an HTTPS channel feed. */
    val canUpdate: Boolean = BuildConfig.UPDATE_FEED_BASE_URL.startsWith("https://")
    private val mutableState = MutableStateFlow(
        UpdateUiState(
            channel = UpdateChannel.fromKey(preferences.getString(KEY_CHANNEL, null)),
            lastCheckedAt = preferences.getLong(KEY_LAST_CHECKED, 0L),
        ),
    )
    val state: StateFlow<UpdateUiState> = mutableState.asStateFlow()
    private val mutableConfirmation = MutableStateFlow<Intent?>(null)
    val pendingConfirmation: StateFlow<Intent?> = mutableConfirmation.asStateFlow()

    private val mutableInstalledNotes = MutableStateFlow<String?>(null)

    /** What's new: the feed's notes for the installed build, once a check has seen them. */
    val installedNotes: StateFlow<String?> = mutableInstalledNotes.asStateFlow()

    val installedVersionName: String = BuildConfig.VERSION_NAME
    val installedVersionCode: Long = BuildConfig.VERSION_CODE.toLong()

    init {
        // A version handed to the installer last time that is not what runs now did not apply.
        val pending = preferences.getLong(KEY_PENDING_BUILD, 0L).takeIf { it > 0 }?.let {
            dev.bridgey.android.updates.PendingInstall(it, preferences.getString(KEY_PENDING_VERSION, null).orEmpty(), preferences.getLong(KEY_PENDING_AT, 0L))
        }
        if (pending != null) {
            dev.bridgey.android.updates.settlePendingInstall(pending, installedVersionCode, System.currentTimeMillis())?.let(::storeNotApplied)
            preferences.edit().remove(KEY_PENDING_BUILD).remove(KEY_PENDING_VERSION).remove(KEY_PENDING_AT).apply()
        }
        val marker = preferences.getLong(KEY_NOT_APPLIED_BUILD, 0L).takeIf { it > installedVersionCode }?.let {
            dev.bridgey.android.updates.NotApplied(it, preferences.getString(KEY_NOT_APPLIED_VERSION, null).orEmpty())
        }
        if (marker == null) clearNotAppliedPreference()
        mutableState.update { it.copy(notApplied = marker) }
    }

    fun setChannel(channel: UpdateChannel) {
        if (channel == mutableState.value.channel) return
        preferences.edit().putString(KEY_CHANNEL, channel.key).apply()
        mutableState.update { it.copy(channel = channel, available = null, promptVisible = false, deferred = false, skippedVersion = null, error = null) }
        checkNow()
    }

    /** A check the user started: it also shows a version they skipped. */
    fun checkNow() {
        scope.launch { check(notify = false, userInitiated = true) }
    }

    fun checkOnAppOpen() {
        if (UpdateFeeds.isCheckDue(lastCheckedAt(), System.currentTimeMillis(), UpdateFeeds.APP_OPEN_MIN_INTERVAL_MILLIS)) {
            scope.launch { check(notify = false, userInitiated = false) }
        }
    }

    /**
     * Runs while the connection service runs: one check a day, or every 30 minutes on Beta and Nightly
     * and every 6 hours on Stable with Update all devices automatically on. Wakes every few minutes to
     * see whether one is due (a delay does not run during deep sleep, so a due check runs on waking).
     */
    suspend fun runPeriodicChecks() {
        while (true) {
            if (UpdateFeeds.isCheckDue(lastCheckedAt(), System.currentTimeMillis(), checkInterval())) {
                check(notify = true, userInitiated = false)
            }
            delay(PERIODIC_WAKE_MILLIS)
        }
    }

    private fun checkInterval(): Long {
        val channel = dev.bridgey.android.updates.WireChannel.fromWire(mutableState.value.channel.key) ?: dev.bridgey.android.updates.WireChannel.STABLE
        return dev.bridgey.android.updates.AutoUpdateRules.checkInterval(automatic(), channel)
    }

    /**
     * The screen came on or the network changed: with Update all devices automatically on, check now,
     * unless any check ran in the last 10 minutes.
     */
    fun checkOnEvent() {
        if (!canUpdate || !automatic()) return
        val now = System.currentTimeMillis()
        if (!dev.bridgey.android.updates.AutoUpdateRules.eventCheckAllowed(lastCheckedAt(), lastEventCheckAt, now)) return
        lastEventCheckAt = now
        scope.launch { check(notify = true, userInitiated = false) }
    }

    fun later() {
        val update = mutableState.value.available ?: return
        preferences.edit()
            .putLong(KEY_SNOOZED_CODE, update.versionCode)
            .putLong(KEY_SNOOZED_UNTIL, System.currentTimeMillis() + UpdateFeeds.CHECK_INTERVAL_MILLIS)
            .apply()
        mutableState.update { it.copy(promptVisible = false, deferred = true) }
    }

    /** Shows a deferred update in full again. */
    fun showUpdate() {
        mutableState.update { it.copy(deferred = false) }
    }

    /** Hides this version from automatic checks; Check now still finds it. */
    fun skip() {
        val update = mutableState.value.available ?: return
        preferences.edit().putLong(KEY_SKIPPED_CODE, update.versionCode).apply()
        mutableState.update { it.copy(available = null, promptVisible = false, deferred = false, skippedVersion = update.versionName) }
    }

    fun dismissError() {
        mutableState.update { it.copy(error = null) }
    }

    fun dismissInstallPermission() {
        mutableState.update { it.copy(needsInstallPermission = false) }
    }

    /** Install, tapped here: a version that did not apply may be tried again, by the person. */
    fun install() {
        clearNotApplied()
        mutableState.update { it.copy(remoteRun = false) }
        val ready = prepared
        if (ready != null && ready.second == mutableState.value.available) commitPrepared() else runInstall(commit = true)
    }

    /** Update all on this phone: download and verify now; [commitPrepared] installs after the countdown. */
    fun prepareForRun() {
        // The person chose Update all here: a version that did not apply may go again.
        clearNotApplied()
        mutableState.update { it.copy(remoteRun = true) }
        if (prepared?.second == mutableState.value.available && mutableState.value.readyToInstall) return
        runInstall(commit = false)
    }

    /**
     * A paired device asked this phone to update itself (updates.start, already accepted). Checks this
     * phone's own channel feed, then downloads, verifies and installs a newer build without Bridgey's
     * dialogs. [retry] is the person's Retry on that device: a version that did not apply may go again.
     */
    fun startFromPeer(retry: Boolean) {
        if (retry) clearNotApplied()
        mutableState.update { it.copy(remoteRun = true) }
        if (installJob?.isActive == true || mutableState.value.installing || mutableState.value.awaitingConfirmation) return
        if (mutableState.value.readyToInstall && prepared != null) {
            commitPrepared()
            return
        }
        scope.launch {
            check(notify = false, userInitiated = true)
            val state = mutableState.value
            if (state.available != null && state.error == null && state.notApplied == null) runInstall(commit = true)
        }
    }

    /** Installs the update [prepareForRun] verified. */
    fun commitPrepared() {
        val (apk, update) = prepared ?: return runInstall(commit = true)
        if (installJob?.isActive == true) return
        if (!context.packageManager.canRequestPackageInstalls()) {
            needInstallPermission()
            return
        }
        installJob = scope.launch {
            mutableState.update { it.copy(readyToInstall = false, error = null) }
            val result = withContext(Dispatchers.IO) { runCatching { commit(apk, update) } }
            finishInstallStep(result, committed = true)
        }
    }

    private fun runInstall(commit: Boolean) {
        val update = mutableState.value.available ?: return
        if (installJob?.isActive == true) return
        if (!context.packageManager.canRequestPackageInstalls()) {
            needInstallPermission()
            return
        }
        cancelAttention()
        installJob = scope.launch {
            mutableState.update {
                it.copy(promptVisible = false, needsInstallPermission = false, deferred = false, downloadProgress = 0f, error = null, readyToInstall = false)
            }
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val apk = download(update)
                    verifyApk(apk, update)
                    prepared = apk to update
                    if (commit) commit(apk, update)
                }
            }
            if (!commit && result.isSuccess) {
                mutableState.update { it.copy(downloadProgress = null, readyToInstall = true) }
            } else {
                finishInstallStep(result, committed = commit)
            }
        }
    }

    private fun commit(apk: java.io.File, update: AndroidUpdate) {
        try {
            // Written before the session commits: if Bridgey starts again on its old build, it did not apply.
            preferences.edit()
                .putLong(KEY_PENDING_BUILD, update.versionCode)
                .putString(KEY_PENDING_VERSION, update.versionName)
                .putLong(KEY_PENDING_AT, System.currentTimeMillis())
                .commit()
            commitInstallSession(apk)
        } catch (error: Exception) {
            clearPending()
            throw UpdateFeedException(error.message ?: "Installer failed", UpdateError.INSTALLER)
        }
    }

    private fun finishInstallStep(result: Result<Unit>, committed: Boolean) {
        mutableState.update {
            it.copy(
                downloadProgress = null,
                installing = committed && result.isSuccess && !it.awaitingConfirmation,
                readyToInstall = false,
                error = result.exceptionOrNull()?.let { error -> (error as? UpdateFeedException)?.error ?: UpdateError.DOWNLOAD },
            )
        }
        if (result.isFailure) prepared = null
    }

    private fun needInstallPermission() {
        mutableState.update { it.copy(needsInstallPermission = true, promptVisible = false) }
        // In front, the dialog asks; otherwise a notification does (Update all or a paired device started this).
        if (mutableState.value.remoteRun && !isForeground()) notifyAttention(Attention.PERMISSION)
    }

    /** Later after Update all's countdown: the verified update waits for Install in Settings > Updates. */
    fun laterAfterRun() {
        mutableState.update { it.copy(remoteRun = false) }
    }

    fun onInstallNeedsConfirmation(intent: Intent?) {
        if (intent == null) {
            onInstallFinished(UpdateError.INSTALLER)
        } else {
            mutableConfirmation.value = intent
            mutableState.update { it.copy(installing = false, awaitingConfirmation = true) }
            // Android needs a tap (first update from another installer, an update owner, or its 30-second limit).
            // In front, the confirmation opens at once; otherwise a high-priority notification leads to it.
            if (!isForeground()) notifyAttention(Attention.CONFIRM)
        }
    }

    fun confirmationLaunched() {
        mutableConfirmation.value = null
        cancelAttention()
    }

    /** The installer's answer. Success replaces this process, so only failures stay on screen. */
    fun onInstallFinished(error: UpdateError?) {
        if (error != null) {
            clearPending()
            prepared = null
        }
        cancelAttention()
        mutableState.update { it.copy(awaitingConfirmation = false, installing = false, error = error) }
    }

    /**
     * What this phone tells its paired devices (updates.status). [automatic]: Update all devices
     * automatically is on; [busy]: what the person is doing here, so an automatic run waits.
     */
    fun wireStatus(remoteStart: Boolean, automatic: Boolean = false, busy: dev.bridgey.android.updates.UpdateBusy? = null): UpdateStatus =
        localUpdateStatus(mutableState.value, installedVersionName, installedVersionCode, remoteStart, canUpdate, automatic, busy)

    private fun storeNotApplied(marker: dev.bridgey.android.updates.NotApplied) {
        preferences.edit().putLong(KEY_NOT_APPLIED_BUILD, marker.build).putString(KEY_NOT_APPLIED_VERSION, marker.version).apply()
    }

    private fun clearNotAppliedPreference() {
        preferences.edit().remove(KEY_NOT_APPLIED_BUILD).remove(KEY_NOT_APPLIED_VERSION).apply()
    }

    private fun clearNotApplied() {
        if (mutableState.value.notApplied == null) return
        clearNotAppliedPreference()
        mutableState.update { it.copy(notApplied = null) }
    }

    private fun clearPending() {
        preferences.edit().remove(KEY_PENDING_BUILD).remove(KEY_PENDING_VERSION).remove(KEY_PENDING_AT).apply()
    }

    private enum class Attention { CONFIRM, PERMISSION }

    /** "Tap to finish updating Bridgey" or "Allow Bridgey to install updates", on a high-priority channel. */
    private fun notifyAttention(kind: Attention) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(ATTENTION_CHANNEL_ID, context.getString(R.string.update_attention_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.update_attention_channel_detail)
            },
        )
        val version = mutableState.value.available?.versionName ?: prepared?.second?.versionName.orEmpty()
        val (title, text, intent) = when (kind) {
            Attention.CONFIRM -> Triple(
                context.getString(R.string.update_attention_confirm_title),
                context.getString(R.string.update_attention_confirm_text, version),
                // Opens Bridgey, where the waiting confirmation launches Android's installer screen.
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(dev.bridgey.android.ui.SettingsDeepLink.EXTRA_SECTION, dev.bridgey.android.ui.SettingsSection.UPDATES.name),
            )
            Attention.PERMISSION -> Triple(
                context.getString(R.string.update_attention_permission_title),
                context.getString(R.string.update_attention_permission_text),
                Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, android.net.Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
        val open = PendingIntent.getActivity(context, ATTENTION_NOTIFICATION_ID, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify(
            ATTENTION_NOTIFICATION_ID,
            android.app.Notification.Builder(context, ATTENTION_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_bridgey_notification)
                .setContentTitle(title)
                .setContentText(text)
                .setCategory(android.app.Notification.CATEGORY_STATUS)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun cancelAttention() {
        context.getSystemService(NotificationManager::class.java).cancel(ATTENTION_NOTIFICATION_ID)
    }

    private fun lastCheckedAt(): Long = preferences.getLong(KEY_LAST_CHECKED, 0L)

    private suspend fun check(notify: Boolean, userInitiated: Boolean) = checkMutex.withLock {
        mutableState.update { it.copy(checking = true, error = if (userInitiated) null else it.error) }
        val channel = mutableState.value.channel
        val result = withContext(Dispatchers.IO) { runCatching { fetchCandidates(channel) } }
        val now = System.currentTimeMillis()
        result.fold(
            onSuccess = { candidates ->
                preferences.edit().putLong(KEY_LAST_CHECKED, now).apply()
                candidates.firstOrNull { it.versionCode == installedVersionCode && it.notes.isNotBlank() }?.let { mutableInstalledNotes.value = it.notes }
                val newest = UpdateFeeds.selectUpdate(installedVersionCode, candidates, Build.VERSION.SDK_INT)
                val update = UpdateFeeds.offer(newest, preferences.getLong(KEY_SKIPPED_CODE, 0L), userInitiated)
                // A check from Settings shows the update in the Settings card, not in a dialog on top of it.
                // A marker stays only while the feed offers that same build: a newer release clears it.
                val stillNotApplied = dev.bridgey.android.updates.notAppliedStillMatches(mutableState.value.notApplied, update?.versionCode)
                if (stillNotApplied == null && mutableState.value.notApplied != null) clearNotApplied()
                val snoozed = update != null && !userInitiated &&
                    preferences.getLong(KEY_SNOOZED_CODE, 0L) == update.versionCode &&
                    now < preferences.getLong(KEY_SNOOZED_UNTIL, 0L)
                // Update all devices automatically starts its own run (with its own notice) for a new version.
                val automatic = automatic()
                mutableState.update {
                    it.copy(
                        checking = false,
                        lastCheckedAt = now,
                        available = update,
                        promptVisible = update != null && !userInitiated && !snoozed && !automatic && it.downloadProgress == null,
                        deferred = update != null && snoozed,
                        skippedVersion = if (update == null) newest?.versionName else null,
                        // The feed answered: "couldn't reach the update server" is no longer true. With automatic
                        // updates on, a newer build than the one that failed is a new attempt (the same build waits for the person).
                        error = when {
                            it.error == UpdateError.CHECK -> null
                            automatic && update != null && it.available != null && update.versionCode != it.available.versionCode -> null
                            else -> it.error
                        },
                    )
                }
                if (notify && update != null && !snoozed && !automatic) notifyUpdate(update)
            },
            onFailure = {
                mutableState.update { it.copy(checking = false, error = if (userInitiated) UpdateError.CHECK else it.error) }
            },
        )
    }

    /** Fetches the feed of [channel] and of every more stable channel. Missing feeds (404) are skipped. */
    private fun fetchCandidates(channel: UpdateChannel): List<AndroidUpdate> {
        var reachedAny = false
        val candidates = mutableListOf<AndroidUpdate>()
        channel.feedChannels.forEach { feedChannel ->
            val text = runCatching { fetchFeed(UpdateFeeds.feedUrl(BuildConfig.UPDATE_FEED_BASE_URL, feedChannel)) }
                .getOrElse { return@forEach }
            reachedAny = true
            text ?: return@forEach
            runCatching {
                UpdateFeeds.parseAndroid(text, feedChannel, context.packageName, BuildConfig.UPDATE_ASSET_URL_PREFIX)
            }.getOrNull()?.let(candidates::add)
        }
        if (!reachedAny) throw IOException("No update feed was reachable")
        return candidates
    }

    private fun openConnection(url: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = NETWORK_TIMEOUT_MILLIS
            readTimeout = NETWORK_TIMEOUT_MILLIS
            instanceFollowRedirects = true
            useCaches = false
            setRequestProperty("User-Agent", "BridgeyRR-Android/${BuildConfig.VERSION_NAME}")
        }

    private fun fetchFeed(url: String): String? {
        val connection = openConnection(url)
        try {
            val code = connection.responseCode
            if (code == HttpURLConnection.HTTP_NOT_FOUND) return null
            if (code != HttpURLConnection.HTTP_OK) throw IOException("HTTP $code")
            if (connection.url.protocol != "https") throw IOException("Redirected away from HTTPS")
            return connection.inputStream.use { readBounded(it, UpdateFeeds.MAX_FEED_BYTES.toLong()) }.toString(Charsets.UTF_8)
        } finally {
            connection.disconnect()
        }
    }

    private fun readBounded(input: InputStream, limit: Long): ByteArray {
        val bytes = input.readNBytesCompat(limit + 1)
        if (bytes.size > limit) throw UpdateFeedException("Update feed is too large")
        return bytes
    }

    private fun InputStream.readNBytesCompat(limit: Long): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (out.size() < limit) {
            val read = read(buffer, 0, minOf(buffer.size.toLong(), limit - out.size()).toInt())
            if (read < 0) break
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private fun download(update: AndroidUpdate): File {
        val directory = File(context.cacheDir, "updates").apply { mkdirs() }
        directory.listFiles()?.forEach { it.delete() }
        val partial = File(directory, "bridgey-${update.versionCode}.apk.part")
        val connection = openConnection(update.apkUrl)
        try {
            if (connection.responseCode != HttpURLConnection.HTTP_OK) {
                throw UpdateFeedException("The update download failed (HTTP ${connection.responseCode}).", UpdateError.DOWNLOAD)
            }
            if (connection.url.protocol != "https") throw UpdateFeedException("The update download left HTTPS.")
            var written = 0L
            connection.inputStream.use { input ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        written += read
                        if (written > update.size) throw UpdateFeedException("The download is larger than announced.")
                        output.write(buffer, 0, read)
                        val progress = written.toFloat() / update.size
                        mutableState.update { it.copy(downloadProgress = progress) }
                    }
                }
            }
            if (written != update.size) throw UpdateFeedException("The download was incomplete.", UpdateError.DOWNLOAD)
        } catch (error: Exception) {
            partial.delete()
            throw error
        } finally {
            connection.disconnect()
        }
        if (!UpdateFeeds.sha256Matches(partial, update.sha256)) {
            partial.delete()
            throw UpdateFeedException("The download failed its SHA-256 check and was deleted.")
        }
        val apk = File(directory, "bridgey-${update.versionCode}.apk")
        if (!partial.renameTo(apk)) throw IOException("Could not store the update")
        return apk
    }

    private fun verifyApk(apk: File, update: AndroidUpdate) {
        val packageManager = context.packageManager
        val archive = archiveInfo(packageManager, apk.path)
            ?: throw UpdateFeedException("The download is not a valid Android app.")
        if (archive.packageName != context.packageName) throw UpdateFeedException("The download is for another app.")
        if (archive.versionCodeCompat() != update.versionCode) throw UpdateFeedException("The download does not match the announced version.")
        val installed = signerDigests(installedInfo(packageManager))
        if (!UpdateFeeds.signersMatch(installed, signerDigests(archive))) {
            apk.delete()
            throw UpdateFeedException("The update is not signed with this app's certificate and was deleted.")
        }
    }

    private fun commitInstallSession(apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            setInstallReason(PackageManager.INSTALL_REASON_USER)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Install without a tap where Android allows it: the person already chose Install or Update all
                // (here or on a paired device with its switch on), and the APK passed the SHA-256, package,
                // version code and signer checks above. Android (12 and later) honours it when Bridgey declares
                // UPDATE_PACKAGES_WITHOUT_USER_ACTION and is updating itself or is the installer of record,
                // and this app's target SDK is recent enough; otherwise it answers STATUS_PENDING_USER_ACTION
                // and the person confirms (for example when another app owns updates on Android 14, or a
                // silent update ran in the last 30 seconds).
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, apk.length()).use { output ->
                    apk.inputStream().use { it.copyTo(output) }
                    session.fsync(output)
                }
                val intent = Intent(context, UpdateInstallReceiver::class.java)
                    .setAction(UpdateInstallReceiver.ACTION_INSTALL_STATUS)
                    .setPackage(context.packageName)
                val mutability = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
                val statusReceiver = PendingIntent.getBroadcast(
                    context,
                    sessionId,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or mutability,
                )
                session.commit(statusReceiver.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(sessionId)
            throw error
        }
    }

    private fun notifyUpdate(update: AndroidUpdate) {
        if (preferences.getLong(KEY_NOTIFIED_CODE, 0L) == update.versionCode) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL_ID, "App updates", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Tells you when a new Bridgey by Round Robin version is ready"
            },
        )
        val open = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            // Opens Settings > Updates, where the update waits with its notes and Install.
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(dev.bridgey.android.ui.SettingsDeepLink.EXTRA_SECTION, dev.bridgey.android.ui.SettingsSection.UPDATES.name),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            NOTIFICATION_ID,
            android.app.Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_bridgey_notification)
                .setContentTitle("Update available")
                .setContentText("Bridgey by Round Robin ${update.versionName} is ready to install.")
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
        preferences.edit().putLong(KEY_NOTIFIED_CODE, update.versionCode).apply()
    }

    private fun installedInfo(packageManager: PackageManager): PackageInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(signingFlags().toLong()))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(context.packageName, signingFlags())
        }

    private fun archiveInfo(packageManager: PackageManager, path: String): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(signingFlags().toLong()))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageArchiveInfo(path, signingFlags())
        }

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        return signatures.orEmpty().map { UpdateFeeds.certificateSha256(it.toByteArray()) }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun PackageInfo.versionCodeCompat(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode else versionCode.toLong()

    companion object {
        private const val KEY_CHANNEL = "channel"
        private const val KEY_LAST_CHECKED = "last_checked_at"
        private const val KEY_SNOOZED_CODE = "snoozed_version_code"
        private const val KEY_SNOOZED_UNTIL = "snoozed_until"
        private const val KEY_NOTIFIED_CODE = "notified_version_code"
        private const val KEY_SKIPPED_CODE = "skipped_version_code"
        private const val NETWORK_TIMEOUT_MILLIS = 15_000
        private const val PERIODIC_WAKE_MILLIS = 5L * 60 * 1000
        private const val NOTIFICATION_CHANNEL_ID = "bridgey.updates"
        private const val NOTIFICATION_ID = 42_470
        private const val ATTENTION_CHANNEL_ID = "bridgey.updates.attention"
        private const val ATTENTION_NOTIFICATION_ID = 42_471
        private const val KEY_PENDING_BUILD = "pending_install_build"
        private const val KEY_PENDING_VERSION = "pending_install_version"
        private const val KEY_PENDING_AT = "pending_install_at"
        private const val KEY_NOT_APPLIED_BUILD = "not_applied_build"
        private const val KEY_NOT_APPLIED_VERSION = "not_applied_version"
    }
}

/**
 * This phone's updates.status from the updater's state (docs/protocol.md "Update all"). One state
 * at a time, the step furthest along first. A version that did not apply stays reported until the
 * person installs by hand, retries, or a newer build is offered. `auto` only when the updater can
 * run; `busy` is what the person is doing here.
 */
fun localUpdateStatus(
    state: UpdateUiState,
    installedVersionName: String,
    installedVersionCode: Long,
    remoteStart: Boolean,
    canUpdate: Boolean,
    automatic: Boolean = false,
    busy: dev.bridgey.android.updates.UpdateBusy? = null,
): UpdateStatus {
    val update = state.available
    val notApplied = state.notApplied
    fun status(
        value: UpdateState,
        target: String? = update?.versionName,
        targetBuild: Long? = update?.versionCode,
        progress: Int? = null,
        reason: UpdateReason? = null,
    ) = UpdateStatus(
        platform = dev.bridgey.android.updates.UpdatePlatform.ANDROID,
        edition = dev.bridgey.android.updates.UPDATES_EDITION,
        app = installedVersionName,
        build = installedVersionCode,
        channel = dev.bridgey.android.updates.WireChannel.fromWire(state.channel.key) ?: dev.bridgey.android.updates.WireChannel.STABLE,
        state = value,
        target = target,
        targetBuild = target?.let { targetBuild },
        progress = progress,
        reason = reason,
        remoteStart = remoteStart && canUpdate,
        checkedAt = state.lastCheckedAt.coerceAtLeast(0),
        auto = automatic && canUpdate,
        busy = busy,
    )
    return when {
        !canUpdate -> status(UpdateState.MANUAL, target = null)
        state.installing && update != null -> status(UpdateState.INSTALLING)
        state.awaitingConfirmation && update != null -> status(UpdateState.NEEDS_USER, reason = UpdateReason.CONFIRM)
        state.needsInstallPermission && update != null -> status(UpdateState.NEEDS_USER, reason = UpdateReason.PERMISSION)
        state.downloadProgress != null && update != null ->
            status(UpdateState.DOWNLOADING, progress = (state.downloadProgress.coerceIn(0f, 1f) * 100).toInt())
        state.readyToInstall && update != null -> status(UpdateState.READY)
        notApplied != null -> status(UpdateState.FAILED, notApplied.version.ifEmpty { null }, notApplied.build, reason = UpdateReason.NOT_APPLIED)
        state.error != null -> status(
            UpdateState.FAILED,
            reason = when (state.error) {
                UpdateError.CHECK -> UpdateReason.CHECK
                UpdateError.DOWNLOAD -> UpdateReason.DOWNLOAD
                UpdateError.SAFETY -> UpdateReason.SAFETY
                UpdateError.INSTALLER -> UpdateReason.INSTALLER
                UpdateError.CANCELLED -> UpdateReason.CANCELLED
            },
        )
        state.checking -> status(UpdateState.CHECKING, target = null)
        update != null -> status(UpdateState.AVAILABLE)
        else -> status(UpdateState.CURRENT, target = null)
    }
}
