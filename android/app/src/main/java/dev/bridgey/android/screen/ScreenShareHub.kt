package dev.bridgey.android.screen

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import dev.bridgey.android.PairingCoordinator
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Where screen sharing is, for the device screen, the tile and the notification. */
data class ScreenShareState(
    val phase: Phase = Phase.IDLE,
    val deviceId: String? = null,
    val macName: String? = null,
    val stats: ScreenStats? = null,
    /** Screenshots: an unattended share nobody approved video for. */
    val mode: ScreenMode = ScreenMode.VIDEO,
) {
    enum class Phase { IDLE, ASKING, STARTING, SHARING }

    val active: Boolean get() = phase != Phase.IDLE

    fun sharingWith(deviceId: String): Boolean = active && this.deviceId == deviceId
}

/**
 * Screen sharing on this phone (draft screen_draft1): one stream at a time. A share starts with Android's
 * consent dialog (ScreenConsentActivity), every time; the consent result starts ScreenShareService, which
 * takes the MediaProjection and runs the encoder and the stream made here. Requests from Macs arrive from
 * the coordinator; Stop comes from the notification, the tile, the app, the Mac, a locked screen or the
 * session ending.
 *
 * Unattended access: a request from a Mac allowed without asking skips Bridgey's question. With nobody here to approve
 * Android's video prompt, the share sends Bridgey control's screenshots instead, about 3 a second ([ScreenshotShare]);
 * its notification offers Use video, which asks Android for consent and replaces it with video. Without Android 11, Bridgey
 * control or an unlocked screen, the request waits for someone here as before, and the Mac hears why (`needs`).
 */
class ScreenShareHub(
    private val context: Context,
    private val pairing: PairingCoordinator,
    private val appInForeground: () -> Boolean,
    /** The Mac controls the phone (phone_control_draft1): null in builds without it. */
    private val phoneControl: () -> dev.bridgey.android.control.PhoneControlHub? = { null },
    /** Bridgey control's screenshots while it is connected (unattended access). */
    private val screenshots: () -> ScreenshotTaker? = { dev.bridgey.android.control.BridgeyControlService.current },
) : PairingCoordinator.ScreenListener {
    private val mutableState = MutableStateFlow(ScreenShareState())
    val state: StateFlow<ScreenShareState> = mutableState.asStateFlow()

    @Volatile private var stream: ScreenStream? = null

    /** Writes screen.stop off the main thread. */
    private val stopWriter = java.util.concurrent.Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "bridgey-screen-stop") }

    /** Writes screen.geometry and screen.control in order, so phone control never waits behind a frame being written. */
    private val controlWriter = java.util.concurrent.Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "bridgey-screen-control-out") }

    /** The service's way to tear down when the stream ends. */
    @Volatile var streamEnded: () -> Unit = {}

    private fun log(message: String) = BridgeyLogging.i(LogCategory.REMOTE_CONTROL, message)

    // MARK: Asking

    /**
     * Opens Android's consent dialog for sharing with [deviceId]; [requestId] when it answers the Mac's request.
     * From an activity, or with a new task from a notification, the tile or the application.
     */
    fun ask(launcher: Context, deviceId: String, macName: String, requestId: String?): Boolean {
        if (state.value.active && state.value.deviceId != deviceId) return false
        if (state.value.phase == ScreenShareState.Phase.SHARING || state.value.phase == ScreenShareState.Phase.STARTING) return false
        mutableState.value = ScreenShareState(ScreenShareState.Phase.ASKING, deviceId, macName)
        return runCatching { launcher.startActivity(ScreenConsentActivity.intent(launcher, deviceId, macName, requestId)) }
            .onFailure { mutableState.value = ScreenShareState() }
            .isSuccess
    }

    /** The consent dialog opened from a notification or the tile. */
    fun markAsking(deviceId: String, macName: String) {
        if (!state.value.active) mutableState.value = ScreenShareState(ScreenShareState.Phase.ASKING, deviceId, macName)
    }

    /** The person allowed capture: the service starts in the foreground and takes the projection. */
    fun consentGranted(from: Context, deviceId: String, macName: String, requestId: String?, resultCode: Int, data: Intent, control: Boolean = false) {
        requestId?.let { pairing.finishScreenRequest(deviceId, it) }
        ScreenNotifier.dismissAsk(context, deviceId)
        mutableState.value = ScreenShareState(ScreenShareState.Phase.STARTING, deviceId, macName)
        val started = runCatching {
            ContextCompat.startForegroundService(from, ScreenShareService.startIntent(from, deviceId, macName, requestId, resultCode, data, control))
        }.onFailure { BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "SCREEN service did not start", it) }.isSuccess
        if (!started) {
            requestId?.let { pairing.sendScreenStatus(deviceId, it, ScreenStatus.FAILED) }
            mutableState.value = ScreenShareState()
        }
    }

    /** The person said no in Android's dialog (or it could not open): the Mac that asked hears `declined`. */
    fun consentDeclined(deviceId: String, requestId: String?) {
        requestId?.let { if (pairing.finishScreenRequest(deviceId, it)) pairing.sendScreenStatus(deviceId, it, ScreenStatus.DECLINED) }
        ScreenNotifier.dismissAsk(context, deviceId)
        if (state.value.phase == ScreenShareState.Phase.ASKING) mutableState.value = ScreenShareState()
    }

    /** Not now on the request notification. */
    fun declineRequest(deviceId: String, requestId: String) = consentDeclined(deviceId, requestId)

    // MARK: The stream

    /**
     * The service holds a projection (or Bridgey control takes screenshots, [mode]): a new stream to [deviceId], or null
     * when it is no longer reachable. [control]: the capture is the whole display and the Mac may control this phone, so
     * the stream is control-capable.
     */
    fun begin(deviceId: String, macName: String, requestId: String?, control: Boolean = false, mode: ScreenMode = ScreenMode.VIDEO): ScreenStream? {
        val link = pairing.screenLink(deviceId) ?: run {
            requestId?.let { pairing.sendScreenStatus(deviceId, it, ScreenStatus.FAILED) }
            mutableState.value = ScreenShareState()
            return null
        }
        stream?.stop(ScreenStopReason.FAILED, tell = false)
        val created = ScreenStream(
            deviceId, macName, requestId, link, clock = { System.nanoTime() / 1_000_000 }, log = ::log,
            stopWriter = { runCatching { stopWriter.execute(it) } },
            controlWriter = { runCatching { controlWriter.execute(it) } },
            mode = mode,
        )
        val hub = phoneControl()
        if (control && hub != null && hub.controlCapable(deviceId)) created.control = hub.attach(created, deviceId, macName)
        created.onStarted = { if (stream === created) mutableState.value = ScreenShareState(ScreenShareState.Phase.SHARING, deviceId, macName, mode = mode) }
        created.onStats = { stats -> if (stream === created) mutableState.value = mutableState.value.copy(stats = stats) }
        created.onEnded = { reason, _ ->
            if (stream === created) {
                stream = null
                mutableState.value = ScreenShareState()
                pairing.recordRemoteControlEvent("screen_ended", deviceId, reason.wire)
                streamEnded()
            }
        }
        stream = created
        mutableState.value = ScreenShareState(ScreenShareState.Phase.STARTING, deviceId, macName, mode = mode)
        pairing.recordRemoteControlEvent(
            "screen_started", deviceId,
            (requestId?.let { "requested" } ?: "phone") + (if (created.control != null) ",control" else "") + (if (mode == ScreenMode.SCREENSHOTS) ",screenshots" else ""),
        )
        return created
    }

    // MARK: Unattended access

    /** What a request from [deviceId] does now: ask the person, or share screenshots without asking. */
    fun route(deviceId: String): ScreenRoute {
        val hub = phoneControl() ?: return ScreenRoute.Ask(null)
        if (!hub.unattendedView(deviceId)) return ScreenRoute.Ask(null)
        val keyguard = context.getSystemService(android.app.KeyguardManager::class.java)
        val power = context.getSystemService(android.os.PowerManager::class.java)
        return screenRoute(
            dev.bridgey.android.control.PhoneControlGrantMode.ALWAYS,
            unlocked = keyguard?.isKeyguardLocked != true,
            screenOn = power?.isInteractive != false,
            sdkInt = android.os.Build.VERSION.SDK_INT,
            serviceConnected = screenshots() != null,
        )
    }

    /**
     * Shares Bridgey control's screenshots with [deviceId] without asking (a Mac allowed without asking, nobody to approve
     * video). False when it cannot start now.
     */
    fun shareScreenshots(deviceId: String, macName: String, requestId: String?): Boolean {
        val taker = screenshots() ?: return false
        if (state.value.active) return false
        requestId?.let { pairing.finishScreenRequest(deviceId, it) }
        ScreenNotifier.dismissAsk(context, deviceId)
        mutableState.value = ScreenShareState(ScreenShareState.Phase.STARTING, deviceId, macName, mode = ScreenMode.SCREENSHOTS)
        log("SCREEN unattended share with screenshots peer=${deviceId.take(8)}")
        ScreenshotShare(taker, deviceId, macName, requestId).start()
        return true
    }

    /**
     * One screenshot share: its own capture thread, the encoder, the once-a-second tick, the screen-off rule, the sharing
     * notification (with Use video) and Bridgey control's bar naming the Mac, with Stop, for as long as it runs. No
     * foreground service of its own: Bridgey's connection service and the bound accessibility service keep the app running.
     */
    private inner class ScreenshotShare(
        private val taker: ScreenshotTaker,
        private val deviceId: String,
        private val macName: String,
        private val requestId: String?,
    ) {
        private val thread = android.os.HandlerThread("bridgey-screen-shots").also { it.start() }
        private val handler = android.os.Handler(thread.looper)
        private val ended = java.util.concurrent.atomic.AtomicBoolean(false)
        private var capture: ScreenCapture? = null
        private var ticker: java.util.concurrent.ScheduledExecutorService? = null
        private var receiverRegistered = false
        private var created: ScreenStream? = null
        private val finisher: () -> Unit = { finish() }

        private val screenOff = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == Intent.ACTION_SCREEN_OFF) created?.stop(ScreenStopReason.SCREEN_OFF)
            }
        }

        fun start() {
            handler.post {
                // Stop may have come before this ran: then nothing starts.
                val now = state.value
                if (now.phase != ScreenShareState.Phase.STARTING || now.mode != ScreenMode.SCREENSHOTS || now.deviceId != deviceId) {
                    finish()
                    return@post
                }
                val stream = begin(deviceId, macName, requestId, control = true, mode = ScreenMode.SCREENSHOTS) ?: run {
                    finish()
                    return@post
                }
                created = stream
                streamEnded = finisher
                val hubStarted = stream.onStarted
                stream.onStarted = {
                    hubStarted()
                    ScreenNotifier.updateSharing(context, macName, sharing = true, screenshotsFor = deviceId)
                }
                ScreenNotifier.updateSharing(context, macName, sharing = false, screenshotsFor = deviceId)
                (taker as? dev.bridgey.android.control.ControlService)?.showViewing(macName) { stop(ScreenStopReason.USER) }
                ContextCompat.registerReceiver(context, screenOff, android.content.IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED)
                receiverRegistered = true
                val source = ScreenshotFrameSource(taker, onFailure = { reason -> stream.stop(reason) })
                val newCapture = ScreenCapture(context, source, stream, handler) { reason -> stream.stop(reason) }
                capture = newCapture
                newCapture.start()
                ticker = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "bridgey-screen-shots-ticker") }.also {
                    it.scheduleWithFixedDelay({ runCatching { stream.tick() } }, 1, 1, java.util.concurrent.TimeUnit.SECONDS)
                }
            }
        }

        /** Tears everything down once; the stream has already ended (or never started). */
        fun finish() {
            if (!ended.compareAndSet(false, true)) return
            if (streamEnded === finisher) streamEnded = {}
            handler.post {
                ticker?.shutdownNow()
                ticker = null
                capture?.release()
                capture = null
                if (receiverRegistered) {
                    runCatching { context.unregisterReceiver(screenOff) }
                    receiverRegistered = false
                }
                (taker as? dev.bridgey.android.control.ControlService)?.hideViewing()
                // A video share that replaced this one has its own notification under the same ID.
                if (state.value.phase == ScreenShareState.Phase.IDLE) {
                    context.getSystemService(android.app.NotificationManager::class.java)?.cancel(ScreenNotifier.SHARING_NOTIFICATION_ID)
                }
                thread.quitSafely()
            }
        }
    }

    /** Stop from this phone: the notification, the tile, the app, a locked screen, the capture ending. */
    fun stop(reason: ScreenStopReason) {
        val current = stream
        if (current != null) {
            current.stop(reason, tell = true)
        } else if (state.value.phase == ScreenShareState.Phase.STARTING) {
            mutableState.value = ScreenShareState()
            streamEnded()
        }
    }

    // MARK: PairingCoordinator.ScreenListener

    override fun requested(request: ScreenRequest): ScreenAnswer {
        val route = route(request.deviceId)
        if (route == ScreenRoute.Screenshots && shareScreenshots(request.deviceId, request.macName, request.requestId)) return ScreenAnswer.Sharing
        val needs = (route as? ScreenRoute.Ask)?.needs ?: if (route == ScreenRoute.Screenshots) ScreenNeeds.ACCESSIBILITY else null
        val locked = context.getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true
        // With Bridgey in front and the phone unlocked, Android's dialog opens at once; otherwise a notification waits.
        if (!locked && appInForeground() && ask(context, request.deviceId, request.macName, request.requestId)) return ScreenAnswer.Waiting(needs)
        ScreenNotifier.showAsk(context, request)
        return ScreenAnswer.Waiting(needs)
    }

    override fun requestEnded(request: ScreenRequest) = ScreenNotifier.dismissAsk(context, request.deviceId)

    override fun message(deviceId: String, message: ScreenMacMessage) {
        stream?.takeIf { it.deviceId == deviceId }?.receive(message)
    }

    override fun input(deviceId: String, plaintext: ByteArray, connection: ByteArray) {
        if (stream?.takeIf { it.deviceId == deviceId }?.control == null) return
        phoneControl()?.input(deviceId, plaintext, connection)
    }

    override fun disconnected(deviceId: String) {
        stream?.takeIf { it.deviceId == deviceId }?.let {
            log("SCREEN session ended stream=${it.streamId.take(8)}")
            it.stop(ScreenStopReason.FAILED, tell = false)
        }
    }

    override fun policy(deviceId: String, localOn: Boolean, remoteOn: Boolean) {
        val current = stream?.takeIf { it.deviceId == deviceId } ?: return
        // Off here: the Mac hears why. Off on the Mac: nothing more may be sent to it.
        if (!localOn) current.stop(ScreenStopReason.DISABLED, tell = true)
        else if (!remoteOn) current.stop(ScreenStopReason.DISABLED, tell = false)
    }

    override fun sharing(): Boolean = state.value.active
}
