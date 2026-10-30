package dev.bridgey.android.updates

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.telephony.TelephonyManager
import androidx.annotation.RequiresApi
import dev.bridgey.android.FileTransferState
import dev.bridgey.android.PairingState
import dev.bridgey.android.TransferKind
import dev.bridgey.android.remote.RemoteSessionState
import dev.bridgey.android.screen.ScreenShareState
import java.util.concurrent.Executor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/*
 * What the person is doing on this phone, so Update all devices automatically waits instead of
 * restarting Bridgey under them (updates.status `busy`). The rules are pure and unit tested; the
 * monitor reads Android (the audio mode, the phone state, the call cards) and Bridgey's own flows.
 */

/** Everything the busy rules read, at one moment. */
data class BusySignals(
    /** AudioManager's mode (ringing, in a call, or in a VoIP call). */
    val audioMode: Int = AudioManager.MODE_NORMAL,
    /** TelephonyManager's call state, when Bridgey may read it. */
    val telephonyCallState: Int = TelephonyManager.CALL_STATE_IDLE,
    /** A call card Bridgey forwards is showing (a call notification it tracks). */
    val callCards: Boolean = false,
    val screen: ScreenShareState.Phase = ScreenShareState.Phase.IDLE,
    val remote: RemoteSessionState = RemoteSessionState.Idle,
    val transfers: Collection<FileTransferState> = emptyList(),
    /** Clipboard items being fetched from a Mac right now. */
    val clipFetches: Int = 0,
    val pairing: PairingState = PairingState.Idle,
    /** Allow pairing is on (the button's two minutes, or a pairing screen holding it open). */
    val pairingArmed: Boolean = false,
    /** The setup screens are open. */
    val setupShowing: Boolean = false,
)

object BusyRules {
    /** Ringing, in a call, or in a VoIP or video call: every mode but normal (and unknown ones) means a call. */
    fun callFromAudioMode(mode: Int): Boolean = mode == AudioManager.MODE_RINGTONE || mode == AudioManager.MODE_IN_CALL ||
        mode == AudioManager.MODE_IN_COMMUNICATION || mode == MODE_CALL_SCREENING || mode == MODE_CALL_REDIRECT || mode == MODE_COMMUNICATION_REDIRECT

    fun callFromTelephony(state: Int): Boolean = state == TelephonyManager.CALL_STATE_RINGING || state == TelephonyManager.CALL_STATE_OFFHOOK

    /** A Mac downloads a folder from its Phone files window. */
    fun phoneFilesDownload(transfer: FileTransferState): Boolean =
        transfer.active && transfer.kind == TransferKind.FOLDER && transfer.folder?.download == true

    fun busy(signals: BusySignals): Set<UpdateBusy> = buildSet {
        if (callFromAudioMode(signals.audioMode) || callFromTelephony(signals.telephonyCallState) || signals.callCards) add(UpdateBusy.CALL)
        if (signals.screen == ScreenShareState.Phase.STARTING || signals.screen == ScreenShareState.Phase.SHARING) add(UpdateBusy.SCREEN_SHARE)
        if (signals.remote is RemoteSessionState.Starting || signals.remote is RemoteSessionState.Active) add(UpdateBusy.REMOTE_CONTROL)
        val active = signals.transfers.filter { it.active }
        if (active.any(::phoneFilesDownload)) add(UpdateBusy.PHONE_FILES)
        if (active.any { !phoneFilesDownload(it) } || signals.clipFetches > 0) add(UpdateBusy.TRANSFER)
        val pairingGoesOn = signals.pairing is PairingState.Connecting || signals.pairing is PairingState.WaitingForAllow ||
            signals.pairing is PairingState.Verification
        if (pairingGoesOn || signals.pairingArmed || signals.setupShowing) add(UpdateBusy.SETUP)
    }

    // Android 11 and 13 modes, by value so the rule reads the same on every SDK.
    private const val MODE_CALL_SCREENING = 4
    private const val MODE_CALL_REDIRECT = 5
    private const val MODE_COMMUNICATION_REDIRECT = 6
}

/** Where the monitor reads Bridgey's own state. The screen share and remote control hubs are built later, so they come lazily. */
class BusySources(
    val transfers: StateFlow<Map<String, FileTransferState>>,
    val clipFetches: StateFlow<List<*>>,
    val pairing: StateFlow<PairingState>,
    /** Allow pairing is on. */
    val pairingArmed: StateFlow<Boolean> = MutableStateFlow(false),
    val setupShowing: StateFlow<Boolean>,
    val screen: () -> StateFlow<ScreenShareState>?,
    val remote: () -> StateFlow<RemoteSessionState>?,
    /** A call card Bridgey forwards is showing (read on the main thread). */
    val callCards: () -> Boolean,
)

/**
 * This phone's busy set for Update all. Bridgey's own activities arrive as flows; calls are read from
 * Android: every few seconds while the connection service runs ([watchCalls]), at once when the
 * audio mode changes (Android 12 and later), and every second during a run ([refreshCalls]).
 */
class BusyMonitor(context: Context, private val scope: CoroutineScope, private val sources: BusySources) {
    private val appContext = context.applicationContext
    private val audio = appContext.getSystemService(AudioManager::class.java)
    private val telephony = appContext.getSystemService(TelephonyManager::class.java)
    private val call = MutableStateFlow(CallSignals())
    private val mutableBusy = MutableStateFlow<Set<UpdateBusy>>(emptySet())

    /** What is going on here now; empty when nothing is. */
    val busy: StateFlow<Set<UpdateBusy>> = mutableBusy.asStateFlow()
    private var job: Job? = null

    private data class CallSignals(val audioMode: Int = AudioManager.MODE_NORMAL, val telephony: Int = TelephonyManager.CALL_STATE_IDLE, val cards: Boolean = false)

    /** Starts following Bridgey's flows; call once the screen share and remote control hubs exist. */
    fun start() {
        if (job != null) return
        refreshCalls()
        val screen: Flow<ScreenShareState.Phase> = sources.screen()?.let { flow -> flow.mapPhase() } ?: flowOf(ScreenShareState.Phase.IDLE)
        val remote: Flow<RemoteSessionState> = sources.remote() ?: flowOf(RemoteSessionState.Idle)
        val pairing = combine(sources.pairing, sources.pairingArmed) { flow, armed -> flow to armed }
        val own = combine(sources.transfers, sources.clipFetches, pairing, sources.setupShowing) { transfers, fetches, (flow, armed), setup ->
            BusySignals(transfers = transfers.values, clipFetches = fetches.size, pairing = flow, pairingArmed = armed, setupShowing = setup)
        }
        job = scope.launch {
            combine(own, screen, remote, call) { signals, phase, session, calls ->
                BusyRules.busy(signals.copy(audioMode = calls.audioMode, telephonyCallState = calls.telephony, callCards = calls.cards, screen = phase, remote = session))
            }.distinctUntilChanged().collect { mutableBusy.value = it }
        }
    }

    /** Reads the call signals now (cheap). */
    fun refreshCalls() {
        call.value = CallSignals(
            audioMode = runCatching { audio.mode }.getOrDefault(AudioManager.MODE_NORMAL),
            telephony = telephonyState(),
            cards = runCatching { sources.callCards() }.getOrDefault(false),
        )
    }

    /** Runs while the connection service runs: looks at calls every few seconds, and at once on an audio mode change. */
    suspend fun watchCalls() {
        val listener: Any? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) addModeListener() else null
        try {
            while (true) {
                refreshCalls()
                delay(CALL_POLL_MILLIS)
            }
        } finally {
            if (listener != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) removeModeListener(listener)
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun addModeListener(): Any? {
        val listener = AudioManager.OnModeChangedListener { scope.launch { refreshCalls() } }
        return runCatching { audio.addOnModeChangedListener(Executor { it.run() }, listener) }.map { listener }.getOrNull()
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun removeModeListener(listener: Any) {
        runCatching { audio.removeOnModeChangedListener(listener as AudioManager.OnModeChangedListener) }
    }

    /** The phone's call state, only with READ_PHONE_STATE (Android asks for it with Calls from Mac); otherwise idle. */
    private fun telephonyState(): Int {
        if (appContext.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return TelephonyManager.CALL_STATE_IDLE
        return runCatching {
            @Suppress("DEPRECATION")
            telephony.callState
        }.getOrDefault(TelephonyManager.CALL_STATE_IDLE)
    }

    private fun StateFlow<ScreenShareState>.mapPhase(): Flow<ScreenShareState.Phase> = map { it.phase }.distinctUntilChanged()

    companion object {
        private const val CALL_POLL_MILLIS = 4_000L
    }
}
