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
 */
class ScreenShareHub(
    private val context: Context,
    private val pairing: PairingCoordinator,
    private val appInForeground: () -> Boolean,
) : PairingCoordinator.ScreenListener {
    private val mutableState = MutableStateFlow(ScreenShareState())
    val state: StateFlow<ScreenShareState> = mutableState.asStateFlow()

    @Volatile private var stream: ScreenStream? = null

    /** Writes screen.stop off the main thread. */
    private val stopWriter = java.util.concurrent.Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "bridgey-screen-stop") }

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
    fun consentGranted(from: Context, deviceId: String, macName: String, requestId: String?, resultCode: Int, data: Intent) {
        requestId?.let { pairing.finishScreenRequest(deviceId, it) }
        ScreenNotifier.dismissAsk(context, deviceId)
        mutableState.value = ScreenShareState(ScreenShareState.Phase.STARTING, deviceId, macName)
        val started = runCatching {
            ContextCompat.startForegroundService(from, ScreenShareService.startIntent(from, deviceId, macName, requestId, resultCode, data))
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

    /** The service holds a projection: a new stream to [deviceId], or null when it is no longer reachable. */
    fun begin(deviceId: String, macName: String, requestId: String?): ScreenStream? {
        val link = pairing.screenLink(deviceId) ?: run {
            requestId?.let { pairing.sendScreenStatus(deviceId, it, ScreenStatus.FAILED) }
            mutableState.value = ScreenShareState()
            return null
        }
        stream?.stop(ScreenStopReason.FAILED, tell = false)
        val created = ScreenStream(
            deviceId, macName, requestId, link, clock = { System.nanoTime() / 1_000_000 }, log = ::log,
            stopWriter = { runCatching { stopWriter.execute(it) } },
        )
        created.onStarted = { if (stream === created) mutableState.value = ScreenShareState(ScreenShareState.Phase.SHARING, deviceId, macName) }
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
        mutableState.value = ScreenShareState(ScreenShareState.Phase.STARTING, deviceId, macName)
        pairing.recordRemoteControlEvent("screen_started", deviceId, requestId?.let { "requested" } ?: "phone")
        return created
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

    override fun requested(request: ScreenRequest) {
        val locked = context.getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true
        // With Bridgey in front and the phone unlocked, Android's dialog opens at once; otherwise a notification waits.
        if (!locked && appInForeground() && ask(context, request.deviceId, request.macName, request.requestId)) return
        ScreenNotifier.showAsk(context, request)
    }

    override fun requestEnded(request: ScreenRequest) = ScreenNotifier.dismissAsk(context, request.deviceId)

    override fun message(deviceId: String, message: ScreenMacMessage) {
        stream?.takeIf { it.deviceId == deviceId }?.receive(message)
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
