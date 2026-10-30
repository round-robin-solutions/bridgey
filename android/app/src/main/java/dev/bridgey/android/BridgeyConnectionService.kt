package dev.bridgey.android

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

class BridgeyConnectionService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var notificationManager: NotificationManager
    private var supportedProfile = true
    private var lastStatus = "Not connected · waiting for paired device"
    private var wifiKeeper: WifiKeeper? = null

    override fun onCreate() {
        super.onCreate()
        val bridgey = application as BridgeyApplication
        if (!bridgey.isPrimaryUser || !bridgey.isBridgeyEnabled) {
            supportedProfile = false
            stopSelf()
            return
        }
        notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Bridgey clipboard", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Keeps paired Bridgey devices connected"
                setSound(null, null)
                enableVibration(false)
            },
        )
        notificationManager.createNotificationChannel(
            NotificationChannel(TRANSFER_CHANNEL_ID, "File transfers", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows active Bridgey file transfers and cancellation"
                setSound(null, null)
                enableVibration(false)
            },
        )
        notificationManager.createNotificationChannel(
            NotificationChannel(FIND_CHANNEL_ID, "Find device", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Shows when another Bridgey device is finding this phone"
                setSound(null, null)
                enableVibration(false)
            },
        )
        startForeground(NOTIFICATION_ID, buildNotification(lastStatus))
        serviceScope.launch {
            val pairing = (application as BridgeyApplication).pairing
            combine(pairing.connections, pairing.pairingFlow) { connections, flow -> connectionStatus(connections, flow) }
                .distinctUntilChanged()
                .collect { status ->
                    lastStatus = status
                    notificationManager.notify(NOTIFICATION_ID, buildNotification(lastStatus))
                }
        }
        serviceScope.launch {
            bridgey.pairing.fileTransferActive.collect {
                notificationManager.notify(NOTIFICATION_ID, buildNotification(lastStatus))
            }
        }
        serviceScope.launch {
            bridgey.settings.state.collect {
                notificationManager.notify(NOTIFICATION_ID, buildNotification(lastStatus))
            }
        }
        serviceScope.launch {
            bridgey.pairing.connections.collect {
                notificationManager.notify(NOTIFICATION_ID, buildNotification(lastStatus))
            }
        }
        serviceScope.launch { bridgey.pairing.fileTransfers.collect(::updateTransferNotifications) }
        FolderNotifier.ensureChannels(this)
        serviceScope.launch { bridgey.pairing.folderQuestions.collect(::updateFolderQuestionNotifications) }
        serviceScope.launch { bridgey.pairing.clipboardInbox.progress.collect(::updatePasteNotifications) }
        serviceScope.launch { bridgey.updater.runPeriodicChecks() }
        // Calls hold Update all devices automatically: looked at every few seconds while connected.
        serviceScope.launch { bridgey.busyMonitor.watchCalls() }
        // Optional background clipboard: run the READ_LOGS source only while it is enabled, automatic
        // clipboard is on, and a device is connected. Stops on disconnect, when off, or when the
        // service stops.
        serviceScope.launch {
            combine(bridgey.settings.state, bridgey.pairing.state) { settings, pairingState ->
                settings.backgroundClipboardEnabled && settings.autoClipboardGlobal && pairingState is PairingState.Connected
            }.distinctUntilChanged().collect { active ->
                if (active) bridgey.backgroundClipboardSource.start() else bridgey.backgroundClipboardSource.stop()
            }
        }
        // Optional Wi-Fi lock (Android 13 and older): held while the service runs and the setting is on.
        val keeper = WifiKeeper(this).also { wifiKeeper = it }
        serviceScope.launch {
            bridgey.settings.state.map { it.keepWifiAwake }.distinctUntilChanged().collect(keeper::set)
        }
        serviceScope.launch {
            bridgey.pairing.phoneRinging.collect { ringing ->
                if (ringing) notificationManager.notify(FIND_NOTIFICATION_ID, buildFindNotification())
                else notificationManager.cancel(FIND_NOTIFICATION_ID)
            }
        }
    }

    private val shownTransferNotifications = mutableSetOf<Int>()
    private val transferNotificationUpdatedAt = mutableMapOf<String, Long>()

    private fun updateTransferNotifications(transfers: Map<String, FileTransferState>) {
        // Queued files get no notification until they start: 50 queued files must not post 50 "Cancel" notifications.
        val active = notifiableTransfers(transfers)
        val activeIds = active.map { transferNotificationId(it.id) }.toSet()
        (shownTransferNotifications - activeIds).forEach(notificationManager::cancel)
        transferNotificationUpdatedAt.keys.retainAll(active.map { it.id }.toSet())
        shownTransferNotifications.clear()
        shownTransferNotifications.addAll(activeIds)
        active.forEach { transfer ->
            val now = SystemClock.elapsedRealtime()
            val previous = transferNotificationUpdatedAt[transfer.id] ?: 0L
            if (now - previous < 1_000) return@forEach
            transferNotificationUpdatedAt[transfer.id] = now
            val notificationId = transferNotificationId(transfer.id)
            val cancelTransfer = PendingIntent.getService(
                this,
                notificationId,
                Intent()
                    .setComponent(ComponentName(this, BridgeyConnectionService::class.java))
                    .setAction(ACTION_CANCEL_TRANSFER)
                    .putExtra(EXTRA_TRANSFER_ID, transfer.id),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val folder = transfer.folder
            // One notification per folder: "Photos · 37 of 124 files", Cancel cancels the whole folder.
            val builder = android.app.Notification.Builder(this, TRANSFER_CHANNEL_ID)
                .setSmallIcon(dev.bridgey.android.R.drawable.ic_bridgey_notification)
                .setContentTitle(if (folder != null) FolderNotifier.progressTitle(this, folder) else transfer.name)
                .setContentText(if (folder != null) FolderNotifier.progressText(this, folder) else compactTransferStatus(transfer))
                .setSubText(transfer.progressPercent?.let { "$it%" })
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setCategory(android.app.Notification.CATEGORY_PROGRESS)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    if (folder != null) getString(R.string.action_cancel) else "Cancel this file",
                    cancelTransfer,
                )
            transfer.progressPercent?.let { builder.setProgress(100, it, false) }
                ?: builder.setProgress(0, 0, true)
            notificationManager.notify(
                notificationId,
                builder.build(),
            )
        }
    }

    private val shownFolderQuestions = mutableMapOf<String, dev.bridgey.android.folders.FolderQuestion>()

    /** The phone's folder questions (6.4); a question that is answered, cancelled or timed out loses its notification. */
    private fun updateFolderQuestionNotifications(questions: List<dev.bridgey.android.folders.FolderQuestion>) {
        val current = questions.associateBy { it.folderTransferId }
        (shownFolderQuestions.keys - current.keys).forEach { notificationManager.cancel(FolderNotifier.questionNotificationId(it)) }
        shownFolderQuestions.keys.retainAll(current.keys)
        current.values.forEach { question ->
            if (shownFolderQuestions[question.folderTransferId] == question) return@forEach
            shownFolderQuestions[question.folderTransferId] = question
            val notification = FolderNotifier.question(this, question) { choice ->
                PendingIntent.getService(
                    this,
                    FolderNotifier.questionNotificationId(question.folderTransferId) * 8 + choice.ordinal,
                    Intent()
                        .setComponent(ComponentName(this, BridgeyConnectionService::class.java))
                        .setAction(ACTION_FOLDER_ANSWER)
                        .putExtra(EXTRA_TRANSFER_ID, question.folderTransferId)
                        .putExtra(EXTRA_FOLDER_CHOICE, choice.wire),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            notificationManager.notify(FolderNotifier.questionNotificationId(question.folderTransferId), notification)
        }
    }

    private val shownPasteNotifications = mutableSetOf<Int>()
    private val pasteNotificationUpdatedAt = mutableMapOf<String, Long>()

    /** A paste waiting on a big item from the Mac shows its progress, with Cancel. */
    private fun updatePasteNotifications(fetches: List<ClipFetchProgress>) {
        val big = fetches.filter { it.size >= PASTE_NOTIFICATION_MIN_BYTES }
        val ids = big.map { transferNotificationId(it.transferId) + 1 }.toSet()
        (shownPasteNotifications - ids).forEach(notificationManager::cancel)
        pasteNotificationUpdatedAt.keys.retainAll(big.map { it.transferId }.toSet())
        shownPasteNotifications.clear()
        shownPasteNotifications.addAll(ids)
        big.forEach { fetch ->
            val now = SystemClock.elapsedRealtime()
            if (now - (pasteNotificationUpdatedAt[fetch.transferId] ?: 0L) < 1_000 && fetch.received < fetch.size) return@forEach
            pasteNotificationUpdatedAt[fetch.transferId] = now
            val notificationId = transferNotificationId(fetch.transferId) + 1
            val cancel = PendingIntent.getService(
                this,
                notificationId,
                Intent()
                    .setComponent(ComponentName(this, BridgeyConnectionService::class.java))
                    .setAction(ACTION_CANCEL_PASTE)
                    .putExtra(EXTRA_TRANSFER_ID, fetch.transferId),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val percent = if (fetch.size <= 0) 100 else ((fetch.received * 100) / fetch.size).toInt().coerceIn(0, 100)
            val showName = (application as BridgeyApplication).uiPreferences.showPreviews.value
            notificationManager.notify(
                notificationId,
                android.app.Notification.Builder(this, TRANSFER_CHANNEL_ID)
                    .setSmallIcon(dev.bridgey.android.R.drawable.ic_bridgey_notification)
                    .setContentTitle(getString(R.string.paste_progress_title, fetch.peerName))
                    .setContentText(
                        if (showName) getString(R.string.paste_progress_detail, fetch.name, percent)
                        else getString(R.string.paste_progress_detail_unnamed, percent),
                    )
                    .setOnlyAlertOnce(true)
                    .setOngoing(true)
                    .setCategory(android.app.Notification.CATEGORY_PROGRESS)
                    .setProgress(100, percent, false)
                    .addAction(android.R.drawable.ic_menu_close_clear_cancel, getString(R.string.action_cancel), cancel)
                    .build(),
            )
        }
    }

    private fun compactTransferStatus(transfer: FileTransferState): String {
        val detail = transfer.status.substringAfter(": ", transfer.status)
        return detail
            .replace(Regex("^(Sending|Receiving)\\s+${Regex.escape(transfer.name)}:?\\s*"), "")
            .ifBlank { if (transfer.progressPercent == null) "Preparing…" else "Transferring…" }
    }

    private fun transferNotificationId(transferId: String) = 50_000 + (transferId.hashCode() and 0x0fff)

    private fun buildNotification(status: String): android.app.Notification {
        val openAppIntent = Intent()
            .setComponent(ComponentName(this, MainActivity::class.java)).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingOpenApp = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val captureIntent = Intent()
            .setComponent(ComponentName(this, ClipboardCaptureActivity::class.java)).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
                Intent.FLAG_ACTIVITY_MULTIPLE_TASK or
                Intent.FLAG_ACTIVITY_NO_ANIMATION
        }
        val pendingCapture = PendingIntent.getActivity(
            this,
            1,
            captureIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val restoreNotification = PendingIntent.getService(
            this,
            3,
            Intent()
                .setComponent(ComponentName(this, BridgeyConnectionService::class.java))
                .setAction(ACTION_RESTORE_NOTIFICATION),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val turnOff = PendingIntent.getService(
            this,
            4,
            Intent()
                .setComponent(ComponentName(this, BridgeyConnectionService::class.java))
                .setAction(ACTION_TURN_OFF),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = android.app.Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(dev.bridgey.android.R.drawable.ic_bridgey_notification)
            .setContentTitle("Bridgey")
            .setContentText(status)
            .setCategory(android.app.Notification.CATEGORY_SERVICE)
            .setVisibility(android.app.Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingOpenApp)
            .setDeleteIntent(restoreNotification)
            .setAutoCancel(false)
            .setOngoing(true)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            notification.setForegroundServiceBehavior(android.app.Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        val pairing = (application as BridgeyApplication).pairing
        val connectedDeviceId = (pairing.state.value as? PairingState.Connected)?.deviceId
        if (connectedDeviceId != null && pairing.isFeatureAvailable(BridgeyFeature.CLIPBOARD)) {
            // One full-width, easy-to-hit "Send copied item" button in a decorated custom view,
            // rather than the small action chip. The status stays above it; Turn off stays an action.
            val content = android.widget.RemoteViews(packageName, R.layout.notification_clipboard).apply {
                setTextViewText(R.id.notification_status, status)
                setTextViewText(R.id.notification_send, getString(R.string.notification_send_copied_text))
                setOnClickPendingIntent(R.id.notification_send, pendingCapture)
            }
            notification
                .setStyle(android.app.Notification.DecoratedCustomViewStyle())
                .setCustomContentView(content)
                .setCustomBigContentView(content)
        }
        return notification
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, getString(R.string.notification_turn_off), turnOff)
            .build()
    }

    private fun buildFindNotification(): android.app.Notification {
        val stop = PendingIntent.getService(
            this,
            5,
            Intent()
                .setComponent(ComponentName(this, BridgeyConnectionService::class.java))
                .setAction(ACTION_STOP_FINDING),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return android.app.Notification.Builder(this, FIND_CHANNEL_ID)
            .setSmallIcon(dev.bridgey.android.R.drawable.ic_bridgey_notification)
            .setContentTitle("Bridgey is finding this phone")
            .setContentText("Your Mac requested a sound")
            .setCategory(android.app.Notification.CATEGORY_ALARM)
            .setVisibility(android.app.Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stop)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!supportedProfile) return START_NOT_STICKY
        if (intent?.action == ACTION_TURN_OFF) {
            (application as BridgeyApplication).disableBridgey()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            Handler(Looper.getMainLooper()).postDelayed({
                android.os.Process.killProcess(android.os.Process.myPid())
            }, 250)
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_CANCEL_TRANSFER) {
            val transferId = intent.getStringExtra(EXTRA_TRANSFER_ID)
            if (transferId != null) (application as BridgeyApplication).pairing.cancelFileTransfer(transferId)
            else (application as BridgeyApplication).pairing.cancelFileTransfer()
            updateTransferNotifications((application as BridgeyApplication).pairing.fileTransfers.value)
            startForeground(NOTIFICATION_ID, buildNotification(lastStatus))
            return START_STICKY
        }
        if (intent?.action == ACTION_FOLDER_ANSWER) {
            val id = intent.getStringExtra(EXTRA_TRANSFER_ID)
            val choice = dev.bridgey.android.folders.ConflictChoice.fromWire(intent.getStringExtra(EXTRA_FOLDER_CHOICE))
            if (id != null && choice != null) (application as BridgeyApplication).pairing.answerFolderConflict(id, choice)
            return START_STICKY
        }
        if (intent?.action == ACTION_CANCEL_PASTE) {
            intent.getStringExtra(EXTRA_TRANSFER_ID)?.let((application as BridgeyApplication).pairing.clipboardInbox::cancel)
            return START_STICKY
        }
        if (intent?.action == ACTION_STOP_FINDING) {
            (application as BridgeyApplication).pairing.stopFinding()
            notificationManager.cancel(FIND_NOTIFICATION_ID)
            return START_STICKY
        }
        // Re-post even when the service is already alive: Android 13+ and some
        // Samsung builds allow users to dismiss foreground-service cards.
        startForeground(NOTIFICATION_ID, buildNotification(lastStatus))
        return START_STICKY
    }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        wifiKeeper?.set(false)
        if (supportedProfile) runCatching { (application as BridgeyApplication).backgroundClipboardSource.stop() }
        serviceScope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "bridgey_clipboard_v2"
        private const val NOTIFICATION_ID = 42_458
        private const val TRANSFER_CHANNEL_ID = "bridgey_file_transfers_v1"
        private const val FIND_CHANNEL_ID = "bridgey_find_device_v1"
        private const val FIND_NOTIFICATION_ID = 42_459
        private const val ACTION_RESTORE_NOTIFICATION = "dev.bridgey.android.RESTORE_NOTIFICATION"
        const val ACTION_TURN_OFF = "dev.bridgey.android.TURN_OFF"
        private const val ACTION_CANCEL_TRANSFER = "dev.bridgey.android.CANCEL_TRANSFER"
        private const val ACTION_STOP_FINDING = "dev.bridgey.android.STOP_FINDING"
        private const val ACTION_CANCEL_PASTE = "dev.bridgey.android.CANCEL_PASTE"
        private const val PASTE_NOTIFICATION_MIN_BYTES = 1_000_000L
        private const val EXTRA_TRANSFER_ID = "dev.bridgey.android.extra.TRANSFER_ID"
        private const val ACTION_FOLDER_ANSWER = "dev.bridgey.android.FOLDER_ANSWER"
        private const val EXTRA_FOLDER_CHOICE = "dev.bridgey.android.extra.FOLDER_CHOICE"
    }
}

class ClipboardCaptureActivity : Activity() {
    /** onResume runs again when the photo access dialog closes: send once. */
    private var started = false

    /** The clip read before asking for photo access, sent once the answer is in. */
    private var waitingForPhotos: Pair<LocalClip?, Long>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setDimAmount(0f)
    }

    companion object {
        /** Set by the optional background clipboard source to auto-send silently (no toasts). */
        const val EXTRA_AUTOMATIC = "dev.bridgey.android.extra.AUTOMATIC"

        /** Device Controls and widgets: send to this Mac instead of the selected one. */
        const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.DEVICE_ID"
        private const val REQUEST_PHOTOS = 7_301
    }

    override fun onResume() {
        super.onResume()
        if (started) return
        started = true
        Handler(Looper.getMainLooper()).postDelayed({
            // Clipboard access is allowed only once this user-initiated activity is foreground.
            val pairing = (application as BridgeyApplication).pairing
            // Background trigger (optional READ_LOGS source): auto-send silently through the same
            // path as a copy made while Bridgey is open, with the same skip rules.
            if (intent?.getBooleanExtra(EXTRA_AUTOMATIC, false) == true) {
                pairing.autoSendClip(pairing.readClipForAutomaticSend())
                close()
                return@postDelayed
            }
            val clip = pairing.readClipForManualSend()
            val timestamp = readClipTimestamp(this)
            if (photoAccessNeeded()) {
                // Send a fresh screenshot is on (the default) and has never had photo access: ask once,
                // on this tap, then send.
                waitingForPhotos = clip to timestamp
                requestPermissions(PhotoPermissions.request, REQUEST_PHOTOS)
                return@postDelayed
            }
            send(clip, timestamp)
        }, 150)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_PHOTOS) return
        val (clip, timestamp) = waitingForPhotos ?: return close()
        waitingForPhotos = null
        when (PhotoPermissions.access(this)) {
            PhotoAccess.FULL -> Unit
            PhotoAccess.PARTIAL -> turnScreenshotsOff(R.string.screenshot_off_partial)
            PhotoAccess.NONE -> turnScreenshotsOff(R.string.screenshot_off_denied)
        }
        send(clip, timestamp)
    }

    /** True when photo access should be asked for now. Selected photos only cannot see new screenshots: the setting goes off. */
    private fun photoAccessNeeded(): Boolean {
        val app = application as BridgeyApplication
        if (!app.settings.state.value.screenshotSendEnabled || !app.pairing.clipboardOffersAvailable()) return false
        return when (PhotoPermissions.access(this)) {
            PhotoAccess.FULL -> false
            PhotoAccess.PARTIAL -> {
                turnScreenshotsOff(R.string.screenshot_off_partial)
                false
            }
            PhotoAccess.NONE -> true
        }
    }

    private fun turnScreenshotsOff(reason: Int) {
        (application as BridgeyApplication).settings.setScreenshotSendEnabled(false)
        Toast.makeText(applicationContext, reason, Toast.LENGTH_LONG).show()
    }

    private fun send(clip: LocalClip?, timestamp: Long) {
        val pairing = (application as BridgeyApplication).pairing
        val appContext = applicationContext
        val main = Handler(Looper.getMainLooper())
        val deviceId = intent?.getStringExtra(EXTRA_DEVICE_ID)?.takeIf { it.isNotBlank() }
        pairing.sendCopiedItem(timestamp, deviceId = deviceId, sendClipboard = { sendClipboard(appContext, pairing, clip, deviceId) }) { result, peerName ->
            main.post {
                val message = if (result == ClipboardSendResult.DELIVERED) {
                    appContext.getString(R.string.screenshot_sent, peerName)
                } else {
                    sendResultMessage(result)
                }
                Toast.makeText(appContext, message, Toast.LENGTH_SHORT).show()
            }
        }
        close()
    }

    private fun sendClipboard(appContext: android.content.Context, pairing: PairingCoordinator, clip: LocalClip?, deviceId: String?) {
        if (clip == null || clip == LocalClip.Own) {
            Toast.makeText(
                appContext,
                if (clip == null) "Clipboard is empty" else "This clip came from your Mac",
                Toast.LENGTH_SHORT,
            ).show()
            return
        }
        pairing.sendClip(clip, deviceId) { result ->
            Handler(Looper.getMainLooper()).post {
                Toast.makeText(appContext, sendResultMessage(result), Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun sendResultMessage(result: ClipboardSendResult): String = when (result) {
        ClipboardSendResult.DELIVERED -> "Clipboard sent to Mac"
        ClipboardSendResult.EMPTY -> "Clipboard is empty"
        ClipboardSendResult.DISABLED -> "Clipboard is turned off on one of your devices"
        ClipboardSendResult.NOT_CONNECTED -> "Not connected — clipboard not sent"
        ClipboardSendResult.CONNECTION_LOST -> "Send failed — connection lost"
        ClipboardSendResult.NO_ACKNOWLEDGEMENT -> "Mac did not confirm delivery"
        ClipboardSendResult.TOO_LARGE -> "Clipboard exceeds 32 KiB. Send it as a file."
    }

    private fun close() {
        if (isFinishing) return
        finishAndRemoveTask()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
