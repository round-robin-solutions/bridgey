package dev.bridgey.android.screen

import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/** How a stream reaches its Mac: JSON stream messages and frame plaintexts, encrypted on the session. */
interface ScreenLink {
    fun sendJson(kind: String, payload: JSONObject): Boolean
    fun sendFrame(plaintext: ByteArray): Boolean

    /** The session's 16-byte contract nonce (phone_control_draft1); all zero, which binds nothing, when unknown. */
    val connection: ByteArray get() = ByteArray(16)
}

/** A control-capable stream's phone control (phone_control_draft1, PhoneControlHub). Every call is quick. */
interface StreamControl {
    /** The control object for screen.start: the stream is [width] by [height], the display [displayWidth] by [displayHeight]. */
    fun offer(width: Int, height: Int, displayWidth: Int, displayHeight: Int): JSONObject
    fun started()
    fun resized(width: Int, height: Int, displayWidth: Int, displayHeight: Int)
    fun mac(message: dev.bridgey.android.control.MacControlMessage)
    fun ended()
}

/** What the stream asks of the encoder. */
interface ScreenEncoderControl {
    fun requestKeyFrame()
    fun setBitrate(bitsPerSecond: Long)
}

enum class ScreenStreamPhase { STARTING, STREAMING, ENDED }

/**
 * One stream from this phone to one Mac: screen.start, waiting for screen.started, frames paced on the
 * Mac's acks, screen.stats once a second, and screen.stop. Thread safe: frames come from the encoder
 * thread, acks from the session reader, ticks from a timer. Every phone message of the stream takes its
 * sequence and is written under one lock, so the Mac sees them in sequence order.
 */
class ScreenStream(
    val deviceId: String,
    val macName: String,
    val requestId: String?,
    private val link: ScreenLink,
    private val clock: () -> Long,
    private val log: (String) -> Unit = {},
    override val streamId: String = UUID.randomUUID().toString(),
    /** Where screen.stop is written: stops come from the main thread too, and sockets may not be written there. */
    private val stopWriter: (Runnable) -> Unit = { it.run() },
    /** Where screen.geometry and screen.control are written, in order, so input handling never waits for a frame. */
    private val controlWriter: (Runnable) -> Unit = { it.run() },
) : dev.bridgey.android.control.ControlStreamLink {
    @Volatile var encoder: ScreenEncoderControl? = null

    /** Set before [start] for a control-capable stream (the Mac shows phone_control_draft1 and has a grant here). */
    @Volatile var control: StreamControl? = null

    override val connection: ByteArray get() = link.connection

    /** Called once when the stream ends, with the reason and whether this phone said so. */
    @Volatile var onEnded: (ScreenStopReason, Boolean) -> Unit = { _, _ -> }

    /** Called once the Mac answered screen.started. */
    @Volatile var onStarted: () -> Unit = {}

    /** Called with each second's stats. */
    @Volatile var onStats: (ScreenStats) -> Unit = {}

    @Volatile var phase = ScreenStreamPhase.STARTING
        private set

    private val sendLock = Any()
    private val sequence = AtomicLong(0)
    private val guard = ScreenSequenceGuard()
    private val pacer = ScreenPacer()
    private val startedAt = clock()
    private val bitrate = ScreenBitrate(startedAt)
    private val window = ScreenStatsWindow(startedAt)
    private var frameNumber = 0L
    private var lastKeyRequestAt = Long.MIN_VALUE / 2
    @Volatile private var lastAckAt = startedAt

    val currentBitrate: Long get() = bitrate.bitrate

    /** Sends screen.start, with the control object when the stream is control-capable. False when the session is gone. */
    fun start(width: Int, height: Int, displayWidth: Int = width, displayHeight: Int = height): Boolean {
        val info = ScreenStartInfo(width, height, ScreenRates.FPS, bitrate.bitrate, requestId)
        val offer = control?.offer(width, height, displayWidth, displayHeight)
        val sent = synchronized(sendLock) { link.sendJson(ScreenKinds.START, screenStartPayload(streamId, sequence.incrementAndGet(), info, offer)) }
        log("SCREEN start stream=${streamId.take(8)} size=${width}x$height bitrate=${bitrate.bitrate} control=${offer != null} sent=$sent")
        if (!sent) end(ScreenStopReason.FAILED, tell = false)
        return sent
    }

    /** A message from the Mac on some stream; ignored unless it is this stream's and in sequence. */
    fun receive(message: ScreenMacMessage) {
        if (message.streamId != streamId || phase == ScreenStreamPhase.ENDED || !guard.accept(message.sequence)) return
        val now = clock()
        when (message) {
            is ScreenMacMessage.Started -> synchronized(this) {
                if (phase != ScreenStreamPhase.STARTING) return
                phase = ScreenStreamPhase.STREAMING
                lastAckAt = now
                pacer.requireKey()
                requestKey(now, force = true)
                log("SCREEN started stream=${streamId.take(8)}")
            }.also {
                onStarted()
                control?.started()
            }
            is ScreenMacMessage.Ack -> {
                lastAckAt = now
                pacer.acknowledge(message.frame, message.decodeMs, now)?.let { sample ->
                    window.sample(sample)
                    bitrate.onRtt(sample.rttMillis, now)?.let { encoder?.setBitrate(it) }
                }
                if (message.keyframe) {
                    pacer.requireKey()
                    requestKey(now, force = false)
                }
            }
            is ScreenMacMessage.Stop -> {
                log("SCREEN stopped by the Mac stream=${streamId.take(8)} reason=${message.reason.wire}")
                end(message.reason, tell = false)
            }
            is ScreenMacMessage.Control -> if (phase == ScreenStreamPhase.STREAMING) control?.mac(message.message)
        }
    }

    /** screen.geometry or screen.control, numbered and written in order on the control writer. */
    override fun send(kind: String, payload: (sequence: Long) -> JSONObject): Boolean {
        if (phase == ScreenStreamPhase.ENDED) return false
        controlWriter(Runnable {
            synchronized(sendLock) {
                if (phase != ScreenStreamPhase.ENDED) link.sendJson(kind, payload(sequence.incrementAndGet()))
            }
        })
        return true
    }

    /** The capture has a new size or the display rotated: control moves to a new geometry generation. */
    fun resized(width: Int, height: Int, displayWidth: Int, displayHeight: Int) {
        if (phase != ScreenStreamPhase.ENDED) control?.resized(width, height, displayWidth, displayHeight)
    }

    /**
     * One encoded access unit from the encoder thread. Sent in parts when the pacer admits it; otherwise
     * dropped, with a key frame asked for and the bit rate lowered. Blocks while the parts are written.
     */
    fun onEncodedFrame(accessUnit: ByteArray, key: Boolean, parameterSets: Boolean, captureMillis: Long, captureMicros: Long) {
        if (phase != ScreenStreamPhase.STREAMING || accessUnit.isEmpty()) return
        val now = clock()
        if (accessUnit.size > ScreenLimits.PART_MAX_BYTES * ScreenLimits.MAX_PARTS) {
            window.dropped()
            pacer.requireKey()
            bitrate.onDrop(now)?.let { encoder?.setBitrate(it) }
            requestKey(now, force = false)
            return
        }
        when (pacer.admit(accessUnit.size, key, bitrate.bitrate)) {
            FrameVerdict.SEND -> Unit
            FrameVerdict.SKIP -> {
                window.dropped()
                requestKey(now, force = false)
                return
            }
            FrameVerdict.DROP -> {
                window.dropped()
                bitrate.onDrop(now)?.let { encoder?.setBitrate(it) }
                requestKey(now, force = false)
                return
            }
        }
        val ok = synchronized(sendLock) {
            if (phase != ScreenStreamPhase.STREAMING) return
            val frame = ++frameNumber
            val count = (accessUnit.size + ScreenLimits.PART_MAX_BYTES - 1) / ScreenLimits.PART_MAX_BYTES
            val first = sequence.get() + 1
            val parts = ScreenFrameCodec.parts(streamId, first, frame, key, parameterSets, captureMicros, accessUnit)
            sequence.addAndGet(count.toLong())
            pacer.sending(frame, accessUnit.size, captureMillis, now)
            val written = parts.all(link::sendFrame)
            if (written) pacer.written(frame, clock()) else pacer.unsent(frame)
            written
        }
        if (ok) window.sent(accessUnit.size) else end(ScreenStopReason.FAILED, tell = false)
    }

    /** Once a second: timeouts, the bit rate's growth, and screen.stats. */
    fun tick() {
        val now = clock()
        when (phase) {
            ScreenStreamPhase.ENDED -> return
            ScreenStreamPhase.STARTING -> if (now - startedAt >= ScreenLimits.STARTED_TIMEOUT_MILLIS) {
                log("SCREEN no screen.started stream=${streamId.take(8)}")
                end(ScreenStopReason.TIMEOUT, tell = true)
                return
            }
            ScreenStreamPhase.STREAMING -> {
                val oldest = pacer.oldestWrittenAtMillis()
                if (oldest != null && now - lastAckAt >= ScreenLimits.ACK_TIMEOUT_MILLIS && now - oldest >= ScreenLimits.ACK_TIMEOUT_MILLIS) {
                    log("SCREEN no ack for 6 s stream=${streamId.take(8)}")
                    end(ScreenStopReason.TIMEOUT, tell = true)
                    return
                }
                bitrate.tick(now)?.let { encoder?.setBitrate(it) }
                val stats = window.take(now, bitrate.bitrate)
                synchronized(sendLock) {
                    if (phase == ScreenStreamPhase.STREAMING) link.sendJson(ScreenKinds.STATS, screenStatsPayload(streamId, sequence.incrementAndGet(), stats))
                }
                log(
                    "SCREEN stats latency=${stats.latencyMs}ms rtt=${stats.rttMs}ms bitrate=${stats.bitrate} sent=${stats.sentBitrate} " +
                        "fps=${stats.fps} dropped=${stats.dropped} inflight=${pacer.framesInFlight}/${pacer.bytesInFlight}B",
                )
                onStats(stats)
            }
        }
    }

    /** The encoder restarted (a new size): the next frame must be a key frame with its SPS and PPS. */
    fun encoderRestarted() {
        pacer.requireKey()
    }

    /** This phone ends the stream: screen.stop to the Mac (unless [tell] is false), then onEnded. */
    fun stop(reason: ScreenStopReason, tell: Boolean = true) = end(reason, tell)

    private fun end(reason: ScreenStopReason, tell: Boolean) {
        synchronized(this) {
            if (phase == ScreenStreamPhase.ENDED) return
            phase = ScreenStreamPhase.ENDED
        }
        if (tell) {
            stopWriter(Runnable { synchronized(sendLock) { link.sendJson(ScreenKinds.STOP, screenStopPayload(streamId, sequence.incrementAndGet(), reason)) } })
        }
        pacer.clear()
        log("SCREEN end stream=${streamId.take(8)} reason=${reason.wire} told=$tell")
        control?.ended()
        onEnded(reason, tell)
    }

    private fun requestKey(now: Long, force: Boolean) {
        synchronized(this) {
            if (!force && now - lastKeyRequestAt < ScreenRates.KEYFRAME_SPACING_MILLIS) return
            lastKeyRequestAt = now
        }
        encoder?.requestKeyFrame()
    }
}
