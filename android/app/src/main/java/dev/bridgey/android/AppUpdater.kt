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
    val status: String? = null,
    val downloadProgress: Float? = null,
    val needsInstallPermission: Boolean = false,
    val promptVisible: Boolean = false,
)

/**
 * Round Robin edition self-updater. Reads the channel feeds published on the
 * fork's GitHub release tag `channels`, downloads the APK only after the user
 * taps Install, verifies its SHA-256 and signing certificate, and hands it to
 * PackageInstaller, which always asks the user to confirm.
 */
class AppUpdater(
    private val context: Context,
    private val scope: CoroutineScope,
) {
    private val preferences = context.getSharedPreferences("bridgey.updates", Context.MODE_PRIVATE)
    private val checkMutex = Mutex()
    private var installJob: Job? = null
    private val mutableState = MutableStateFlow(
        UpdateUiState(
            channel = UpdateChannel.fromKey(preferences.getString(KEY_CHANNEL, null)),
            lastCheckedAt = preferences.getLong(KEY_LAST_CHECKED, 0L),
        ),
    )
    val state: StateFlow<UpdateUiState> = mutableState.asStateFlow()
    private val mutableConfirmation = MutableStateFlow<Intent?>(null)
    val pendingConfirmation: StateFlow<Intent?> = mutableConfirmation.asStateFlow()

    val installedVersionName: String = BuildConfig.VERSION_NAME
    val installedVersionCode: Long = BuildConfig.VERSION_CODE.toLong()

    fun setChannel(channel: UpdateChannel) {
        if (channel == mutableState.value.channel) return
        preferences.edit().putString(KEY_CHANNEL, channel.key).apply()
        mutableState.update { it.copy(channel = channel, available = null, promptVisible = false, status = null) }
        checkNow()
    }

    fun checkNow() {
        scope.launch { check(notify = false) }
    }

    fun checkOnAppOpen() {
        if (UpdateFeeds.isCheckDue(lastCheckedAt(), System.currentTimeMillis(), UpdateFeeds.APP_OPEN_MIN_INTERVAL_MILLIS)) {
            scope.launch { check(notify = false) }
        }
    }

    /** Runs while the connection service runs: at most one check per 24 hours. */
    suspend fun runPeriodicChecks() {
        while (true) {
            if (UpdateFeeds.isCheckDue(lastCheckedAt(), System.currentTimeMillis(), UpdateFeeds.CHECK_INTERVAL_MILLIS)) {
                check(notify = true)
            }
            delay(PERIODIC_WAKE_MILLIS)
        }
    }

    fun later() {
        val update = mutableState.value.available ?: return
        preferences.edit()
            .putLong(KEY_SNOOZED_CODE, update.versionCode)
            .putLong(KEY_SNOOZED_UNTIL, System.currentTimeMillis() + UpdateFeeds.CHECK_INTERVAL_MILLIS)
            .apply()
        mutableState.update { it.copy(promptVisible = false) }
    }

    fun dismissInstallPermission() {
        mutableState.update { it.copy(needsInstallPermission = false) }
    }

    fun install() {
        val update = mutableState.value.available ?: return
        if (installJob?.isActive == true) return
        if (!context.packageManager.canRequestPackageInstalls()) {
            mutableState.update { it.copy(needsInstallPermission = true, promptVisible = false) }
            return
        }
        installJob = scope.launch {
            mutableState.update {
                it.copy(promptVisible = false, needsInstallPermission = false, downloadProgress = 0f, status = "Downloading ${update.versionName}…")
            }
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val apk = download(update)
                    verifyApk(apk, update)
                    commitInstallSession(apk)
                }
            }
            mutableState.update {
                it.copy(
                    downloadProgress = null,
                    status = result.fold(
                        onSuccess = { "Confirm the update in the Android installer." },
                        onFailure = { error -> (error as? UpdateFeedException)?.message ?: "The update could not be downloaded. Try again later." },
                    ),
                )
            }
        }
    }

    fun onInstallNeedsConfirmation(intent: Intent?) {
        if (intent == null) {
            onInstallFinished("Android did not open the installer.")
        } else {
            mutableConfirmation.value = intent
        }
    }

    fun confirmationLaunched() {
        mutableConfirmation.value = null
    }

    fun onInstallFinished(errorMessage: String?) {
        mutableState.update { it.copy(status = errorMessage ?: "Update installed.") }
    }

    private fun lastCheckedAt(): Long = preferences.getLong(KEY_LAST_CHECKED, 0L)

    private suspend fun check(notify: Boolean) = checkMutex.withLock {
        mutableState.update { it.copy(checking = true) }
        val channel = mutableState.value.channel
        val result = withContext(Dispatchers.IO) { runCatching { fetchCandidates(channel) } }
        val now = System.currentTimeMillis()
        result.fold(
            onSuccess = { candidates ->
                preferences.edit().putLong(KEY_LAST_CHECKED, now).apply()
                val update = UpdateFeeds.selectUpdate(installedVersionCode, candidates, Build.VERSION.SDK_INT)
                val snoozed = update != null &&
                    preferences.getLong(KEY_SNOOZED_CODE, 0L) == update.versionCode &&
                    now < preferences.getLong(KEY_SNOOZED_UNTIL, 0L)
                mutableState.update {
                    it.copy(
                        checking = false,
                        lastCheckedAt = now,
                        available = update,
                        promptVisible = update != null && !snoozed && it.downloadProgress == null,
                        status = if (update != null) "Version ${update.versionName} is available." else "Bridgey is up to date.",
                    )
                }
                if (notify && update != null && !snoozed) notifyUpdate(update)
            },
            onFailure = {
                mutableState.update { it.copy(checking = false, status = "Could not check for updates. Try again later.") }
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
            if (connection.responseCode != HttpURLConnection.HTTP_OK) throw UpdateFeedException("The update download failed (HTTP ${connection.responseCode}).")
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
            if (written != update.size) throw UpdateFeedException("The download was incomplete.")
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
                // Never install silently, even where Android would allow it for the installer of record.
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
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
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
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
        private const val NETWORK_TIMEOUT_MILLIS = 15_000
        private const val PERIODIC_WAKE_MILLIS = 60L * 60 * 1000
        private const val NOTIFICATION_CHANNEL_ID = "bridgey.updates"
        private const val NOTIFICATION_ID = 42_470
    }
}
