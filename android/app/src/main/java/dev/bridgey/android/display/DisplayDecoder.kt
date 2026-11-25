package dev.bridgey.android.display

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue

/** One H.264 decoder drawing onto a surface. The app uses MediaCodec; tests use a fake. */
interface VideoCodec {
    val name: String

    /** Configures for these parameter sets onto [surface] and starts; false when the codec refused. */
    fun configure(width: Int, height: Int, sets: H264ParameterSets.Sets, surface: Any): Boolean

    /** Queues one access unit and renders whatever is ready, waiting at most [timeoutMs] for this frame. */
    fun decode(accessUnit: ByteArray, presentationUs: Long, timeoutMs: Long): Decoded

    fun release()

    enum class Decoded {
        /** This frame came out and was drawn. */
        RENDERED,

        /** Accepted; its picture comes out with a later call. */
        QUEUED,

        /** The codec failed: it needs to be made again from a key frame. */
        FAILED,
    }
}

/**
 * The decoding rules, apart from threads and MediaCodec: nothing decodes without a surface; a key frame's SPS and PPS
 * (re)configure the codec when they change (a rotation or resize on the Mac); after a failure, a lost frame or a new
 * surface, frames wait for the next key frame. Not thread safe: [DisplayDecoder] calls it under one lock.
 */
class DisplayDecodeLogic(private val makeCodec: () -> VideoCodec, private val clock: () -> Long) {
    sealed interface Outcome {
        data class Decoded(val millis: Long) : Outcome

        /** The frame could not be decoded until a key frame arrives (asked for in the ack). */
        data object NeedsKeyFrame : Outcome

        /** No surface to draw on: acknowledged, not decoded. */
        data object NoSurface : Outcome
    }

    private var codec: VideoCodec? = null
    private var sets: H264ParameterSets.Sets? = null
    private var surface: Any? = null
    private var needsKey = true

    /** The codec's name once one runs, for the log. */
    var codecName: String? = null
        private set

    val waitingForKey: Boolean get() = needsKey

    /** A new surface (or none): the codec belonged to the old one, so it goes and the next key frame starts again. */
    fun attach(newSurface: Any?) {
        releaseCodec()
        surface = newSurface
        needsKey = true
    }

    /** A frame was lost before it reached the decoder: wait for a key frame. */
    fun lost() {
        needsKey = true
    }

    fun decode(frame: AssembledFrame, width: Int, height: Int): Outcome {
        val target = surface ?: return Outcome.NoSurface.also { needsKey = true }
        if (frame.key) {
            val found = H264ParameterSets.find(frame.data)
            if (found != null && (codec == null || found != sets)) {
                releaseCodec()
                val made = runCatching(makeCodec).getOrNull()
                if (made == null || !runCatching { made.configure(width, height, found, target) }.getOrDefault(false)) {
                    runCatching { made?.release() }
                    needsKey = true
                    return Outcome.NeedsKeyFrame
                }
                codec = made
                codecName = made.name
                sets = found
            }
        }
        val current = codec ?: return Outcome.NeedsKeyFrame.also { needsKey = true }
        if (needsKey && !frame.key) return Outcome.NeedsKeyFrame
        val started = clock()
        return when (runCatching { current.decode(frame.data, frame.frame * 1_000, DECODE_WAIT_MILLIS) }.getOrDefault(VideoCodec.Decoded.FAILED)) {
            VideoCodec.Decoded.RENDERED, VideoCodec.Decoded.QUEUED -> {
                needsKey = false
                Outcome.Decoded(clock() - started)
            }
            VideoCodec.Decoded.FAILED -> {
                releaseCodec()
                needsKey = true
                Outcome.NeedsKeyFrame
            }
        }
    }

    fun release() {
        releaseCodec()
        surface = null
        needsKey = true
    }

    private fun releaseCodec() {
        runCatching { codec?.release() }
        codec = null
        sets = null
    }

    companion object {
        /** How long one frame may take to come out before the ack goes anyway. */
        const val DECODE_WAIT_MILLIS = 50L
    }
}

/** Where the hub hands complete frames for decoding. */
interface FrameDecoder {
    val codecName: String?

    /** False when the frame cannot be taken now (the hub then drops until a key frame). */
    fun offer(frame: AssembledFrame, width: Int, height: Int): Boolean

    fun attach(surface: Any?)

    fun clear()

    fun release()
}

/**
 * Decodes on its own thread, fed through a bounded queue so the session's reader never waits: a full queue refuses
 * the frame (the hub then drops until a key frame). [onResult] runs on the decoder thread.
 */
class DisplayDecoder(
    private val logic: DisplayDecodeLogic,
    private val onResult: (frame: AssembledFrame, outcome: DisplayDecodeLogic.Outcome) -> Unit,
    capacity: Int = QUEUE_FRAMES,
) : FrameDecoder {
    private class Item(val frame: AssembledFrame, val width: Int, val height: Int)

    private val queue = ArrayBlockingQueue<Item>(capacity)
    private val lock = Any()
    @Volatile private var running = true
    @Volatile private var lostPending = false
    private val thread = Thread({ loop() }, "bridgey-display-decoder").apply {
        isDaemon = true
        priority = Thread.MAX_PRIORITY
        start()
    }

    override val codecName: String? get() = synchronized(lock) { logic.codecName }

    /** False when the queue is full: the frame is not decoded. */
    override fun offer(frame: AssembledFrame, width: Int, height: Int): Boolean = running && queue.offer(Item(frame, width, height))

    /** The surface appeared, changed or went (null). Waits for a decode in progress, so the old surface is free after. */
    override fun attach(surface: Any?) {
        synchronized(lock) { logic.attach(surface) }
    }

    /** A stream ended or a frame was lost: queued frames go and the next one must be a key frame. */
    override fun clear() {
        queue.clear()
        // Read by the decoder thread before its next frame, so the session's reader never waits for a decode.
        lostPending = true
    }

    override fun release() {
        running = false
        queue.clear()
        thread.interrupt()
        synchronized(lock) { logic.release() }
    }

    private fun loop() {
        while (running) {
            // Blocks without waking while nothing is shown; release() interrupts it.
            val item = try {
                queue.take()
            } catch (_: InterruptedException) {
                break
            }
            val outcome = synchronized(lock) {
                if (lostPending) {
                    lostPending = false
                    logic.lost()
                }
                logic.decode(item.frame, item.width, item.height)
            }
            runCatching { onResult(item.frame, outcome) }
        }
    }

    companion object {
        const val QUEUE_FRAMES = 8
    }
}

/** MediaCodec H.264 onto a Surface: a hardware decoder when there is one, low latency where the codec offers it. */
class MediaCodecVideo : VideoCodec {
    private var codec: MediaCodec? = null
    private val info = MediaCodec.BufferInfo()
    override var name: String = ""
        private set

    override fun configure(width: Int, height: Int, sets: H264ParameterSets.Sets, surface: Any): Boolean {
        val target = surface as? Surface ?: return false
        if (!target.isValid) return false
        val chosen = decoderInfo()
        for (lowLatency in listOf(true, false)) {
            val created = try {
                chosen?.let { MediaCodec.createByCodecName(it.name) } ?: MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            } catch (error: Exception) {
                BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "DISPLAY decoder not created", error)
                return false
            }
            try {
                val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                    setByteBuffer("csd-0", ByteBuffer.wrap(sets.sps))
                    setByteBuffer("csd-1", ByteBuffer.wrap(sets.pps))
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, MAX_INPUT_BYTES)
                    setInteger(MediaFormat.KEY_PRIORITY, 0)
                    if (lowLatency && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                created.configure(format, target, null, 0)
                created.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
                created.start()
                codec = created
                name = created.name
                BridgeyLogging.i(LogCategory.REMOTE_CONTROL, "DISPLAY decoder ${created.name} ${width}x$height lowLatency=$lowLatency")
                return true
            } catch (error: Exception) {
                runCatching { created.release() }
                if (!lowLatency) BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "DISPLAY decoder configure failed", error)
            }
        }
        return false
    }

    override fun decode(accessUnit: ByteArray, presentationUs: Long, timeoutMs: Long): VideoCodec.Decoded {
        val current = codec ?: return VideoCodec.Decoded.FAILED
        return try {
            var index = current.dequeueInputBuffer(INPUT_WAIT_US)
            if (index < 0) {
                // The decoder holds every input: draw what is ready and try once more.
                drain(current, presentationUs, 0)
                index = current.dequeueInputBuffer(INPUT_WAIT_US)
                if (index < 0) return VideoCodec.Decoded.FAILED
            }
            val buffer = current.getInputBuffer(index) ?: return VideoCodec.Decoded.FAILED
            if (accessUnit.size > buffer.capacity()) return VideoCodec.Decoded.FAILED
            buffer.clear()
            buffer.put(accessUnit)
            current.queueInputBuffer(index, 0, accessUnit.size, presentationUs, 0)
            if (drain(current, presentationUs, timeoutMs)) VideoCodec.Decoded.RENDERED else VideoCodec.Decoded.QUEUED
        } catch (error: Exception) {
            BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "DISPLAY decode failed", error)
            VideoCodec.Decoded.FAILED
        }
    }

    /** Draws every output that is ready; true once the frame at [presentationUs] came out. */
    private fun drain(current: MediaCodec, presentationUs: Long, timeoutMs: Long): Boolean {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (true) {
            val wait = if (timeoutMs == 0L) 0L else OUTPUT_WAIT_US
            val index = current.dequeueOutputBuffer(info, wait)
            when {
                index >= 0 -> {
                    val ours = info.presentationTimeUs == presentationUs
                    current.releaseOutputBuffer(index, true)
                    if (ours) return true
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (System.nanoTime() >= deadline) return false
                // Format and buffer changes: keep reading.
                else -> Unit
            }
            if (System.nanoTime() >= deadline && index < 0) return false
        }
    }

    override fun release() {
        val current = codec ?: return
        codec = null
        runCatching { current.stop() }
        runCatching { current.release() }
    }

    private fun decoderInfo(): MediaCodecInfo? {
        val decoders = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, ignoreCase = true) }
            }
        }.getOrDefault(emptyList())
        val hardware = decoders.firstOrNull { info ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isHardwareAccelerated
            else !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")
        }
        return hardware ?: decoders.firstOrNull()
    }

    private companion object {
        const val INPUT_WAIT_US = 10_000L
        const val OUTPUT_WAIT_US = 5_000L
        const val MAX_INPUT_BYTES = 2 * 1024 * 1024 + 4096
    }
}
