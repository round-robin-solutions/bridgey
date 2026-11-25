package dev.bridgey.android.display

import dev.bridgey.android.screen.ScreenSequenceGuard
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/** How the viewer reaches one Mac's current session. Bound to that session: after a reconnect its sends fail. */
interface DisplayLink {
    /** Encrypts and writes one message; false when the session is gone. Blocking: called on the hub's sender thread. */
    fun send(kind: String, payload: ByteArray): Boolean

    /** The session's 16-byte connection nonce (ScreenControl.connectionNonce). */
    val connection: ByteArray
}

/** What the hub needs from the sessions (the pairing coordinator in the app, a fake in tests). */
interface DisplayHost {
    fun link(deviceId: String): DisplayLink?

    /** See Mac screens is on here for this Mac, and the Mac advertises the key for this phone. */
    fun available(deviceId: String): Boolean

    /** See Mac screens is on here for this Mac (false: this phone turned it off). */
    fun enabledHere(deviceId: String): Boolean

    fun record(event: String, deviceId: String, detail: String) {}

    fun log(message: String) {}
}

/** Why there is no picture: shown in the viewer with Start again. */
sealed interface DisplayOutcome {
    data class Refused(val status: DisplayStatus) : DisplayOutcome
    data class Stopped(val reason: DisplayStopReason, val byMac: Boolean) : DisplayOutcome
    data object Disconnected : DisplayOutcome
    data object NoAnswer : DisplayOutcome

    /** The feature is not available with this Mac now (off here, not allowed on the Mac, not connected). */
    data object Unavailable : DisplayOutcome
}

data class DisplayViewState(
    val phase: Phase = Phase.IDLE,
    val deviceId: String? = null,
    val macName: String = "",
    val displayName: String? = null,
    val geometry: Geometry? = null,
    /** The Mac said control may be asked for during this stream. */
    val controlAllowed: Boolean = false,
    val control: ControlPhase = ControlPhase.OFF,
    val input: InputCapabilities = InputCapabilities(),
    val stats: DisplaySourceMessage.Stats? = null,
    val outcome: DisplayOutcome? = null,
    /** Why control ended or was refused, until control starts again. */
    val controlNote: DisplayControlReason? = null,
    /** Changes whenever gestures in progress must be forgotten (geometry change, control ended, stream ended). */
    val gestureEpoch: Int = 0,
    /** The last second on this phone: decoded frames, decode time and frames lost. */
    val decodedFps: Int = 0,
    val decodeMsAverage: Double = 0.0,
    val decodeMsMax: Long = 0,
    val lostFrames: Int = 0,
) {
    enum class Phase { IDLE, ASKING, WAITING, STREAMING, ENDED }
    enum class ControlPhase { OFF, STARTING, ACTIVE }

    val streaming: Boolean get() = phase == Phase.STREAMING
    val controlling: Boolean get() = control == ControlPhase.ACTIVE
}

/**
 * Mac screen to phone on this phone (draft screen_control_draft1, docs/protocol.md "Mac screen to phone"): one viewer,
 * one stream at a time. The viewer screen asks ([open]); the Mac answers with display.status and display.start, then
 * frames. Frames are reassembled on the session's reader thread and decoded on their own thread; acknowledgements,
 * control and input go out in order on one sender thread. Leaving the viewer, Stop on either side, a disconnect or the
 * feature going off ends the stream, and nothing starts again until the person asks. Thread safe.
 */
class DisplayViewerHub(
    private val host: DisplayHost,
    private val clock: () -> Long,
    private val decoderFactory: () -> VideoCodec = { MediaCodecVideo() },
    /** Where messages are written, in order. Tests run them in place. */
    private val sender: Executor = Executors.newSingleThreadExecutor { Thread(it, "bridgey-display-out").apply { isDaemon = true } },
    /** Ticks (timeouts, the log) and control flushes; null in tests, which call [tick] and [flushControl] themselves. */
    private val timer: ScheduledExecutorService? = Executors.newSingleThreadScheduledExecutor { Thread(it, "bridgey-display-timer").apply { isDaemon = true } },
    /** Decoding; tests replace it with a synchronous fake by passing their own logic through [decoderFactory]. */
    makeDecoder: ((DisplayDecodeLogic, (AssembledFrame, DisplayDecodeLogic.Outcome) -> Unit) -> FrameDecoder)? = null,
) {
    private val mutableState = MutableStateFlow(DisplayViewState())
    val state: StateFlow<DisplayViewState> = mutableState.asStateFlow()

    private class Stream(
        val deviceId: String,
        val start: DisplayStart,
        val link: DisplayLink,
        now: Long,
    ) {
        val guard = ScreenSequenceGuard().also { it.accept(start.sequence) }
        var viewerSequence = 0L
        val assembler = DisplayFrameAssembler()
        var geometry = start.geometry
        var waitingForKey = true
        var lastKeyRequestAt = Long.MIN_VALUE / 2
        var lastFrame = 0L
        var lastActivityAt = now
        fun nextSequence(): Long = ++viewerSequence
    }

    private val lock = Any()
    private val requests = DisplayRequests(clock)
    private val ended = EndedStreams()
    private val controller = DisplayController(clock)
    private var stream: Stream? = null
    private var requestId: String? = null
    private var requestLink: DisplayLink? = null
    private var ticker: ScheduledFuture<*>? = null
    private var flusher: ScheduledFuture<*>? = null
    private var retry: ScheduledFuture<*>? = null

    // One second of numbers for the log and the viewer.
    private var windowStart = clock()
    private var decoded = 0
    private var decodeTotal = 0L
    private var decodeMax = 0L
    private var lost = 0
    private var queueDrops = 0
    private var bytes = 0L

    private val decoder: FrameDecoder = run {
        val logic = DisplayDecodeLogic(decoderFactory, clock)
        val onResult: (AssembledFrame, DisplayDecodeLogic.Outcome) -> Unit = ::decoded
        makeDecoder?.invoke(logic, onResult) ?: DisplayDecoder(logic, onResult)
    }

    // MARK: The viewer screen

    /** The viewer opened for [deviceId]: asks the Mac, unless a stream or a request with it is already running. */
    fun open(deviceId: String, macName: String) {
        synchronized(lock) {
            val current = mutableState.value
            if (current.deviceId == deviceId && current.phase in setOf(DisplayViewState.Phase.ASKING, DisplayViewState.Phase.WAITING, DisplayViewState.Phase.STREAMING)) return
            stream?.let { endLocked(it, DisplayStopReason.USER, tell = true, outcome = null) }
            requestId?.let { requests.ended(current.deviceId ?: deviceId) }
            requestId = null
            retry?.cancel(false)
            if (!host.available(deviceId)) {
                mutableState.value = DisplayViewState(DisplayViewState.Phase.ENDED, deviceId, macName, outcome = DisplayOutcome.Unavailable)
                return
            }
            val wait = requests.waitMillis(deviceId)
            if (wait > 0 && timer != null) {
                // Asked again within 3 seconds: the request goes as soon as it may.
                mutableState.value = DisplayViewState(DisplayViewState.Phase.ASKING, deviceId, macName)
                retry = timer.schedule({ synchronized(lock) { if (mutableState.value.phase == DisplayViewState.Phase.ASKING && requestId == null) requestLocked(deviceId, macName) } }, wait, TimeUnit.MILLISECONDS)
                return
            }
            requestLocked(deviceId, macName)
        }
    }

    /** Start again after an ending: a new request, asked on the Mac again unless it allows this phone without asking. */
    fun startAgain() {
        val current = mutableState.value
        val deviceId = current.deviceId ?: return
        if (current.phase == DisplayViewState.Phase.ENDED || current.phase == DisplayViewState.Phase.IDLE) open(deviceId, current.macName)
    }

    /**
     * The person stopped or left the viewer: the Mac hears why. The viewer then says it stopped, with Start again; an
     * earlier ending (a refusal, a disconnect) keeps its own words.
     */
    fun close(reason: DisplayStopReason) {
        synchronized(lock) {
            retry?.cancel(false)
            val current = mutableState.value
            val running = stream != null || requestId != null || current.phase == DisplayViewState.Phase.ASKING
            stream?.let { endLocked(it, reason, tell = true, outcome = DisplayOutcome.Stopped(reason, byMac = false)) }
            if (requestId != null) current.deviceId?.let { requests.ended(it) }
            requestId = null
            requestLink = null
            if (running && mutableState.value.phase != DisplayViewState.Phase.ENDED) {
                mutableState.value = mutableState.value.copy(
                    phase = DisplayViewState.Phase.ENDED,
                    outcome = DisplayOutcome.Stopped(reason, byMac = false),
                    control = DisplayViewState.ControlPhase.OFF,
                )
            }
            stopTickerIfIdleLocked()
        }
    }

    /** The surface the picture is drawn on appeared, changed or went (null). */
    fun surface(surface: Any?) {
        decoder.attach(surface)
        if (surface == null) return
        synchronized(lock) {
            val current = stream ?: return
            // A new surface needs a key frame; the last frame is acknowledged again to ask for one.
            current.waitingForKey = true
            if (current.lastFrame > 0) ackLocked(current, current.lastFrame, 0, wantKey = true, force = true)
        }
    }

    // MARK: Control

    /** Control on: asks the Mac (it checks its own permission for this phone). */
    fun beginControl() {
        synchronized(lock) {
            val current = stream ?: return
            val view = mutableState.value
            if (!view.controlAllowed || view.control != DisplayViewState.ControlPhase.OFF) return
            mutableState.value = view.copy(control = DisplayViewState.ControlPhase.STARTING, controlNote = null)
            sendLocked(current, DisplayKinds.CONTROL, displayControlPayload(current.start.streamId, current.nextSequence(), DisplayControlAction.BEGIN))
        }
    }

    /** Control off; the picture stays. */
    fun endControl() {
        synchronized(lock) {
            val current = stream ?: return
            when (mutableState.value.control) {
                DisplayViewState.ControlPhase.OFF -> return
                DisplayViewState.ControlPhase.STARTING ->
                    sendLocked(current, DisplayKinds.CONTROL, displayControlPayload(current.start.streamId, current.nextSequence(), DisplayControlAction.END))
                DisplayViewState.ControlPhase.ACTIVE -> controller.stop()?.let { sendPacketLocked(current, it) }
            }
            controller.end()
            stopFlusherLocked()
            mutableState.value = mutableState.value.copy(control = DisplayViewState.ControlPhase.OFF, gestureEpoch = mutableState.value.gestureEpoch + 1)
        }
    }

    /** One action from the picture or the keyboard; false when it was not taken (no control, refused, budget queue full). */
    fun input(action: DisplayAction): Boolean {
        synchronized(lock) {
            if (stream == null || mutableState.value.control != DisplayViewState.ControlPhase.ACTIVE) return false
            val taken = controller.submit(action)
            // Key and button transitions go at once when the budget allows; motion waits for the next flush.
            if (taken && action !is DisplayAction.Pointer && action !is DisplayAction.Scroll) flushControlLocked()
            return taken
        }
    }

    /** One press and release of a named key, with Shift held around it when asked. */
    fun press(key: ControlKey, shift: Boolean = false): Boolean {
        synchronized(lock) {
            if (stream == null || mutableState.value.control != DisplayViewState.ControlPhase.ACTIVE) return false
            return controller.press(key, shift).also { if (it) flushControlLocked() }
        }
    }

    /** The controller's numbered packets that may go now (the timer calls it about 60 times a second). */
    fun flushControl() {
        synchronized(lock) { flushControlLocked() }
    }

    // MARK: From the session

    /** display.status for this phone's open request. */
    fun onStatus(deviceId: String, plaintext: ByteArray) {
        synchronized(lock) {
            val status = decodeDisplayStatus(plaintext) ?: return
            if (status.requestId != requestId || requests.current(deviceId, status.requestId) == null) return
            val view = mutableState.value
            if (view.deviceId != deviceId) return
            if (status.status == DisplayStatus.WAITING) {
                if (view.phase == DisplayViewState.Phase.ASKING) mutableState.value = view.copy(phase = DisplayViewState.Phase.WAITING)
                return
            }
            requests.finish(deviceId, status.requestId)
            requestId = null
            requestLink = null
            host.log("DISPLAY status ${status.status.wire}")
            mutableState.value = view.copy(phase = DisplayViewState.Phase.ENDED, outcome = DisplayOutcome.Refused(status.status))
            stopTickerIfIdleLocked()
        }
    }

    /** display.start from [deviceId], whose current session is [link]. */
    fun onStart(deviceId: String, plaintext: ByteArray, link: DisplayLink) {
        synchronized(lock) {
            val start = decodeDisplayStart(plaintext)
            if (start == null) {
                displayStartStreamId(plaintext)?.takeIf { it !in ended && it != stream?.start?.streamId }?.let { id ->
                    refuseLocked(link, id, DisplayStopReason.INVALID)
                }
                host.log("DISPLAY start refused reason=invalid")
                return
            }
            if (start.streamId in ended || start.streamId == stream?.start?.streamId) return
            val view = mutableState.value
            val asked = view.deviceId == deviceId && requestId == start.requestId &&
                view.phase in setOf(DisplayViewState.Phase.ASKING, DisplayViewState.Phase.WAITING) &&
                requests.current(deviceId, start.requestId) != null
            if (!asked) {
                // Nobody is looking (the viewer left, or this is not the request it made): the Mac must not stream.
                refuseLocked(link, start.streamId, DisplayStopReason.LEFT_SCREEN)
                return
            }
            requests.finish(deviceId, start.requestId)
            requestId = null
            requestLink = null
            val created = Stream(deviceId, start, link, clock())
            stream = created
            decoder.clear()
            resetWindowLocked()
            mutableState.value = view.copy(
                phase = DisplayViewState.Phase.STREAMING,
                displayName = start.displayName,
                geometry = start.geometry,
                controlAllowed = start.control,
                control = DisplayViewState.ControlPhase.OFF,
                outcome = null,
                controlNote = null,
                stats = null,
                gestureEpoch = view.gestureEpoch + 1,
            )
            sendLocked(created, DisplayKinds.STARTED, displayStartedPayload(start.streamId, created.nextSequence()))
            host.record("display_started", deviceId, if (start.control) "control" else "view")
            host.log("DISPLAY started stream=${start.streamId.take(8)} size=${start.geometry.width}x${start.geometry.height} fps=${start.fps} control=${start.control}")
            ensureTickerLocked()
        }
    }

    /** display.stats, display.geometry, display.control or display.stop from [deviceId]. */
    fun onStreamMessage(deviceId: String, kind: String, plaintext: ByteArray) {
        synchronized(lock) {
            val current = stream?.takeIf { it.deviceId == deviceId } ?: return
            val message: DisplaySourceMessage = when (kind) {
                DisplayKinds.STATS -> decodeDisplayStats(plaintext)
                DisplayKinds.GEOMETRY -> decodeDisplayGeometry(plaintext)
                DisplayKinds.CONTROL -> decodeDisplayControlFromSource(plaintext)
                DisplayKinds.STOP -> decodeDisplayStop(plaintext)
                else -> null
            } ?: return
            if (message.streamId != current.start.streamId || !current.guard.accept(message.sequence)) return
            when (message) {
                is DisplaySourceMessage.Stats -> {
                    current.lastActivityAt = clock()
                    mutableState.value = mutableState.value.copy(stats = message)
                    host.log("DISPLAY stats latency=${message.latencyMs}ms rtt=${message.rttMs}ms bitrate=${message.bitrate} sent=${message.sentBitrate} fps=${message.fps} dropped=${message.dropped}")
                }
                is DisplaySourceMessage.GeometryChanged -> {
                    if (message.geometry.generation <= current.geometry.generation) return
                    current.geometry = message.geometry
                    // Input not sent yet is dropped and the new generation acknowledged before anything else.
                    controller.geometryChanged(message.geometry.generation).forEach { sendPacketLocked(current, it) }
                    mutableState.value = mutableState.value.copy(geometry = message.geometry, gestureEpoch = mutableState.value.gestureEpoch + 1)
                    host.log("DISPLAY geometry generation=${message.geometry.generation} size=${message.geometry.width}x${message.geometry.height}")
                }
                is DisplaySourceMessage.Control -> controlLocked(current, message)
                is DisplaySourceMessage.Stop -> {
                    host.log("DISPLAY stopped by the Mac reason=${message.reason.wire}")
                    endLocked(current, message.reason, tell = false, outcome = DisplayOutcome.Stopped(message.reason, byMac = true))
                }
            }
        }
    }

    /** One display.frame plaintext from [deviceId], on the session's reader thread. Never blocks on decoding. */
    fun onFrame(deviceId: String, plaintext: ByteArray) {
        synchronized(lock) {
            val current = stream?.takeIf { it.deviceId == deviceId } ?: return
            val (header, payload) = decodeDisplayFrame(plaintext) ?: return
            if (header.streamId != current.start.streamId || !current.guard.accept(header.sequence)) return
            current.lastActivityAt = clock()
            bytes += payload.size
            when (val event = current.assembler.add(header, payload)) {
                DisplayFrameAssembler.Event.Pending, DisplayFrameAssembler.Event.Ignored -> Unit
                is DisplayFrameAssembler.Event.Lost -> {
                    lost++
                    current.waitingForKey = true
                    decoder.clear()
                    ackLocked(current, event.frame, 0, wantKey = true)
                }
                is DisplayFrameAssembler.Event.Complete -> {
                    val frame = event.frame
                    current.lastFrame = frame.frame
                    if (current.waitingForKey && !frame.key) {
                        ackLocked(current, frame.frame, 0, wantKey = true)
                        return
                    }
                    if (!decoder.offer(frame, current.geometry.width, current.geometry.height)) {
                        // The decoder is behind: this frame goes, and so does everything up to the next key frame.
                        queueDrops++
                        current.waitingForKey = true
                        decoder.clear()
                        ackLocked(current, frame.frame, 0, wantKey = true)
                        return
                    }
                    current.waitingForKey = false
                }
            }
        }
    }

    /** The Mac's session ended. */
    fun disconnected(deviceId: String) {
        synchronized(lock) {
            stream?.takeIf { it.deviceId == deviceId }?.let {
                host.log("DISPLAY session ended stream=${it.start.streamId.take(8)}")
                endLocked(it, DisplayStopReason.FAILED, tell = false, outcome = DisplayOutcome.Disconnected)
            }
            val view = mutableState.value
            if (view.deviceId == deviceId && view.phase in setOf(DisplayViewState.Phase.ASKING, DisplayViewState.Phase.WAITING)) {
                requests.ended(deviceId)
                requestId = null
                requestLink = null
                retry?.cancel(false)
                mutableState.value = view.copy(phase = DisplayViewState.Phase.ENDED, outcome = DisplayOutcome.Disconnected)
            }
            stopTickerIfIdleLocked()
        }
    }

    /** The feature changed here or on the Mac for a connected Mac. */
    fun policy(deviceId: String) {
        synchronized(lock) {
            if (host.available(deviceId)) return
            val enabledHere = host.enabledHere(deviceId)
            stream?.takeIf { it.deviceId == deviceId }?.let {
                // Off here: the Mac hears why. Off on the Mac: nothing more may be sent to it.
                endLocked(it, DisplayStopReason.DISABLED, tell = !enabledHere, outcome = DisplayOutcome.Stopped(DisplayStopReason.DISABLED, byMac = enabledHere))
            }
            val view = mutableState.value
            if (view.deviceId == deviceId && view.phase in setOf(DisplayViewState.Phase.ASKING, DisplayViewState.Phase.WAITING)) {
                requests.ended(deviceId)
                requestId = null
                mutableState.value = view.copy(phase = DisplayViewState.Phase.ENDED, outcome = DisplayOutcome.Unavailable)
            }
        }
    }

    /** Request expiry, the stream timeout and the once-a-second numbers (every quarter second while something runs). */
    fun tick() {
        synchronized(lock) {
            val now = clock()
            val view = mutableState.value
            val deviceId = view.deviceId
            if (deviceId != null && requestId != null && requests.expired(deviceId) != null) {
                requestId = null
                requestLink = null
                mutableState.value = view.copy(phase = DisplayViewState.Phase.ENDED, outcome = DisplayOutcome.NoAnswer)
            }
            stream?.let { current ->
                if (now - current.lastActivityAt >= DisplayLimits.STREAM_TIMEOUT_MILLIS) {
                    host.log("DISPLAY no frame or stats for 6 s stream=${current.start.streamId.take(8)}")
                    endLocked(current, DisplayStopReason.TIMEOUT, tell = true, outcome = DisplayOutcome.Stopped(DisplayStopReason.TIMEOUT, byMac = false))
                }
            }
            if (now - windowStart >= 1_000) publishWindowLocked(now)
            stopTickerIfIdleLocked()
        }
    }

    fun release() {
        close(DisplayStopReason.LEFT_SCREEN)
        decoder.release()
        timer?.shutdownNow()
    }

    // MARK: Private

    private fun requestLocked(deviceId: String, macName: String) {
        val link = host.link(deviceId)
        val id = UUID.randomUUID().toString()
        if (link == null || !requests.begin(deviceId, id)) {
            mutableState.value = DisplayViewState(DisplayViewState.Phase.ENDED, deviceId, macName, outcome = DisplayOutcome.Unavailable)
            return
        }
        requestId = id
        requestLink = link
        mutableState.value = DisplayViewState(DisplayViewState.Phase.ASKING, deviceId, macName, gestureEpoch = mutableState.value.gestureEpoch + 1)
        val payload = displayRequestPayload(id).toString().toByteArray(Charsets.UTF_8)
        sender.execute {
            if (!link.send(DisplayKinds.REQUEST, payload)) disconnectedRequest(deviceId, id)
        }
        host.log("DISPLAY request sent")
        ensureTickerLocked()
    }

    private fun disconnectedRequest(deviceId: String, id: String) {
        synchronized(lock) {
            if (requestId != id) return
            requests.ended(deviceId)
            requestId = null
            requestLink = null
            mutableState.value = mutableState.value.copy(phase = DisplayViewState.Phase.ENDED, outcome = DisplayOutcome.Disconnected)
        }
    }

    private fun controlLocked(current: Stream, message: DisplaySourceMessage.Control) {
        val view = mutableState.value
        when (message.state) {
            DisplayControlState.ACTIVE -> {
                val session = message.session ?: return
                val input = message.input ?: return
                if (view.control != DisplayViewState.ControlPhase.STARTING) {
                    // Not asked for (any more): end it on the Mac at once.
                    sendLocked(current, DisplayKinds.CONTROL, displayControlPayload(current.start.streamId, current.nextSequence(), DisplayControlAction.END))
                    return
                }
                val packets = controller.begin(session, input, DisplayController.Binding(current.start.transport, current.link.connection, current.start.stream), current.geometry.generation)
                if (packets.isEmpty()) return
                packets.forEach { sendPacketLocked(current, it) }
                mutableState.value = view.copy(control = DisplayViewState.ControlPhase.ACTIVE, input = input, controlNote = null, gestureEpoch = view.gestureEpoch + 1)
                ensureFlusherLocked()
                host.log("DISPLAY control active session=$session pointer=${input.pointer} keys=${input.keys} text=${input.text}")
            }
            DisplayControlState.ENDED, DisplayControlState.REFUSED -> {
                controller.end()
                stopFlusherLocked()
                if (view.control == DisplayViewState.ControlPhase.OFF && message.state == DisplayControlState.ENDED && message.reason == DisplayControlReason.USER) return
                mutableState.value = view.copy(control = DisplayViewState.ControlPhase.OFF, input = InputCapabilities(), controlNote = message.reason, gestureEpoch = view.gestureEpoch + 1)
                host.log("DISPLAY control ${message.state.wire} reason=${message.reason?.wire}")
            }
        }
    }

    private fun flushControlLocked() {
        val current = stream ?: return
        if (!controller.active) return
        controller.flush().forEach { sendPacketLocked(current, it) }
    }

    private fun sendPacketLocked(current: Stream, packet: ControlPacket) {
        val bytes = packet.encode()
        val link = current.link
        sender.execute { if (!link.send(DisplayKinds.INPUT, bytes)) linkFailed(current) }
    }

    private fun sendLocked(current: Stream, kind: String, payload: JSONObject) {
        val bytes = payload.toString().toByteArray(Charsets.UTF_8)
        val link = current.link
        sender.execute { if (!link.send(kind, bytes)) linkFailed(current) }
    }

    private fun refuseLocked(link: DisplayLink, streamId: String, reason: DisplayStopReason) {
        ended.remember(streamId)
        val bytes = displayStopPayload(streamId, 1, reason).toString().toByteArray(Charsets.UTF_8)
        sender.execute { link.send(DisplayKinds.STOP, bytes) }
    }

    /** A write failed: the session went away (a reconnect never resumes a stream). */
    private fun linkFailed(failed: Stream) {
        synchronized(lock) {
            if (stream !== failed) return
            endLocked(failed, DisplayStopReason.FAILED, tell = false, outcome = DisplayOutcome.Disconnected)
        }
    }

    /** Acknowledges a frame; asks for a key frame at most once a second ([force]: a new surface asks at once). */
    private fun ackLocked(current: Stream, frame: Long, decodeMs: Long, wantKey: Boolean, force: Boolean = false) {
        var keyframe = false
        if (wantKey) {
            val now = clock()
            if (force || now - current.lastKeyRequestAt >= 1_000) {
                current.lastKeyRequestAt = now
                keyframe = true
            }
        }
        sendLocked(current, DisplayKinds.ACK, displayAckPayload(current.start.streamId, current.nextSequence(), frame, decodeMs, keyframe))
    }

    /** The decoder thread's result for one frame. */
    private fun decoded(frame: AssembledFrame, outcome: DisplayDecodeLogic.Outcome) {
        synchronized(lock) {
            val current = stream ?: return
            when (outcome) {
                is DisplayDecodeLogic.Outcome.Decoded -> {
                    decoded++
                    decodeTotal += outcome.millis
                    decodeMax = maxOf(decodeMax, outcome.millis)
                    ackLocked(current, frame.frame, outcome.millis, wantKey = false)
                }
                DisplayDecodeLogic.Outcome.NeedsKeyFrame -> {
                    lost++
                    current.waitingForKey = true
                    ackLocked(current, frame.frame, 0, wantKey = true)
                }
                DisplayDecodeLogic.Outcome.NoSurface -> ackLocked(current, frame.frame, 0, wantKey = false)
            }
        }
    }

    private fun endLocked(current: Stream, reason: DisplayStopReason, tell: Boolean, outcome: DisplayOutcome?) {
        if (stream !== current) return
        stream = null
        if (controller.active && tell) controller.stop()?.let { sendPacketLocked(current, it) }
        controller.end()
        stopFlusherLocked()
        if (tell) sendLocked(current, DisplayKinds.STOP, displayStopPayload(current.start.streamId, current.nextSequence(), reason))
        ended.remember(current.start.streamId)
        decoder.clear()
        host.record("display_ended", current.deviceId, reason.wire)
        host.log("DISPLAY end stream=${current.start.streamId.take(8)} reason=${reason.wire} told=$tell")
        val view = mutableState.value
        mutableState.value = view.copy(
            phase = if (outcome == null) DisplayViewState.Phase.IDLE else DisplayViewState.Phase.ENDED,
            control = DisplayViewState.ControlPhase.OFF,
            input = InputCapabilities(),
            outcome = outcome,
            stats = null,
            gestureEpoch = view.gestureEpoch + 1,
        )
    }

    private fun ensureTickerLocked() {
        val scheduler = timer ?: return
        if (ticker == null) ticker = scheduler.scheduleWithFixedDelay({ runCatching { tick() } }, 250, 250, TimeUnit.MILLISECONDS)
    }

    private fun stopTickerIfIdleLocked() {
        if (stream == null && requestId == null) {
            ticker?.cancel(false)
            ticker = null
        }
    }

    private fun ensureFlusherLocked() {
        val scheduler = timer ?: return
        if (flusher == null) flusher = scheduler.scheduleWithFixedDelay({ runCatching { flushControl() } }, 16, 16, TimeUnit.MILLISECONDS)
    }

    private fun stopFlusherLocked() {
        flusher?.cancel(false)
        flusher = null
    }

    private fun resetWindowLocked() {
        windowStart = clock()
        decoded = 0
        decodeTotal = 0
        decodeMax = 0
        lost = 0
        queueDrops = 0
        bytes = 0
    }

    private fun publishWindowLocked(now: Long) {
        val elapsed = (now - windowStart).coerceAtLeast(1)
        val fps = ((decoded * 1000L + elapsed / 2) / elapsed).toInt()
        val average = if (decoded > 0) decodeTotal.toDouble() / decoded else 0.0
        if (stream != null) {
            host.log(
                "DISPLAY receive fps=$fps decodeMsAvg=${"%.2f".format(java.util.Locale.US, average)} decodeMsMax=$decodeMax lost=$lost " +
                    "queueDrops=$queueDrops kbps=${bytes * 8 / elapsed} codec=${decoder.codecName} control=${mutableState.value.control.name.lowercase()} pending=${controller.pending}",
            )
            mutableState.value = mutableState.value.copy(decodedFps = fps, decodeMsAverage = average, decodeMsMax = decodeMax, lostFrames = lost)
        }
        resetWindowLocked()
        windowStart = now
    }
}
