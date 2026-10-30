package dev.bridgey.android

import java.io.EOFException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.withLock

/*
 * Fast transfers (draft files_fast_draft1; docs/transfer-speed.md, docs/protocol.md "Fast transfers"). Between two
 * peers that both advertise the key, file chunks travel as binary frames instead of base64 inside JSON, chunks are
 * 256 KiB instead of 24 KiB, receivers acknowledge every chunk, and senders keep a window of unacknowledged bytes
 * that follows the queueing delay of the link. Peers without the key keep the 24 KiB JSON chunks. The Mac has the
 * same code in FastTransfer.swift.
 */

/** The feature key. A capability, so the app advertises it whenever it supports it. */
internal const val FILES_FAST_FEATURE_KEY = "files_fast_draft1"

internal object FastFrame {
    /** The first byte of a binary frame: never the start of a JSON frame, never the first byte of UTF-8 text. */
    const val MARKER: Byte = 0xB1.toByte()
    /** Marker, kind, and the body length as a 32-bit big-endian integer. */
    const val HEADER_BYTES = 6
    /** files.chunk: one chunk of a file (single files, folders, downloads, clipboard files). */
    const val CHUNK_KIND = 1
    /** speed.data: test bytes for the speed test, acknowledged and thrown away. */
    const val SPEED_KIND = 2
    const val MAXIMUM_PLAINTEXT = 1_048_576
    const val MAXIMUM_ID_BYTES = 64
    /** The largest body: ID length, ID, sequence, nonce, the largest ciphertext and its tag. */
    const val MAXIMUM_BODY = 1 + MAXIMUM_ID_BYTES + 8 + 12 + MAXIMUM_PLAINTEXT + 16
    /** What senders use. Receivers take up to [MAXIMUM_PLAINTEXT]. */
    const val CHUNK_SIZE = 256 * 1024
    const val MAXIMUM_SEQUENCE = 9_007_199_254_740_991L
    /** The first field of the associated data. Fast frames exist only on protocol 2 sessions. */
    const val ASSOCIATED_DATA_LABEL = "bridgey-fast-frame-v2"
}

/** A decoded binary frame: what a files.chunk JSON message carried, without the envelope. */
internal class FastFramePayload(val kind: Int, val id: String, val sequence: Long, val plaintext: ByteArray)

internal class FastFrameException(message: String) : IllegalArgumentException(message)

private val fastRandom = SecureRandom()

private fun validFastId(id: ByteArray): Boolean = id.size in 1..FastFrame.MAXIMUM_ID_BYTES && id.all { it in 0x21..0x7E }

/**
 * What the AES-GCM tag covers besides the ciphertext, length-prefixed like protocol 2 envelope tags
 * ([SessionSecurity.lengthPrefixed]): the label, the sending device's ID, the kind, the transfer (or test) ID and the
 * sequence. So a frame cannot be moved to another transfer, position or kind, nor reflected back to its sender.
 */
internal fun fastFrameAssociatedData(sender: String, kind: Int, id: String, sequence: Long): ByteArray =
    SessionSecurity.lengthPrefixed(listOf(FastFrame.ASSOCIATED_DATA_LABEL, sender, kind.toString(), id, sequence.toString()))

/**
 * One whole frame, header included, from [sender] (this device's ID), with [length] bytes of [plaintext] at [offset].
 * [nonce] is random unless a vector fixes it.
 */
internal fun sealFastFrame(
    kind: Int,
    id: String,
    sequence: Long,
    plaintext: ByteArray,
    key: ByteArray,
    sender: String,
    offset: Int = 0,
    length: Int = plaintext.size,
    nonce: ByteArray? = null,
): ByteArray {
    val idBytes = id.toByteArray(Charsets.US_ASCII)
    if (!validFastId(idBytes) || sequence !in 0..FastFrame.MAXIMUM_SEQUENCE || length !in 1..FastFrame.MAXIMUM_PLAINTEXT) {
        throw FastFrameException("invalid frame")
    }
    val iv = nonce ?: ByteArray(12).also(fastRandom::nextBytes)
    val bodyLength = 1 + idBytes.size + 8 + 12 + length + 16
    val frame = ByteArray(FastFrame.HEADER_BYTES + bodyLength)
    val head = ByteBuffer.wrap(frame)
    head.put(FastFrame.MARKER).put(kind.toByte()).putInt(bodyLength).put(idBytes.size.toByte()).put(idBytes).putLong(sequence).put(iv)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
    cipher.updateAAD(fastFrameAssociatedData(sender, kind, id, sequence))
    val written = cipher.doFinal(plaintext, offset, length, frame, head.position())
    check(written == length + 16)
    return frame
}

/**
 * Reads and decrypts a frame body (what follows the 6-byte header) from [sender] (the other device's ID). A malformed
 * field or a failed tag is dropped and counted like a frame with a bad envelope tag (16 close the session).
 */
internal fun openFastFrameBody(kind: Int, body: ByteArray, key: ByteArray, sender: String): FastFramePayload {
    if (body.size > FastFrame.MAXIMUM_BODY || body.isEmpty()) throw FastFrameException("malformed")
    val idLength = body[0].toInt() and 0xFF
    if (idLength !in 1..FastFrame.MAXIMUM_ID_BYTES || body.size < 1 + idLength + 8 + 12 + 16 + 1) throw FastFrameException("malformed")
    val idBytes = body.copyOfRange(1, 1 + idLength)
    if (!validFastId(idBytes)) throw FastFrameException("malformed")
    val sequence = ByteBuffer.wrap(body, 1 + idLength, 8).long
    if (sequence !in 0..FastFrame.MAXIMUM_SEQUENCE) throw FastFrameException("malformed")
    val nonceStart = 1 + idLength + 8
    val cipherStart = nonceStart + 12
    if (body.size - cipherStart - 16 > FastFrame.MAXIMUM_PLAINTEXT) throw FastFrameException("malformed")
    val id = String(idBytes, Charsets.US_ASCII)
    val plaintext = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, body, nonceStart, 12))
        cipher.updateAAD(fastFrameAssociatedData(sender, kind, id, sequence))
        cipher.doFinal(body, cipherStart, body.size - cipherStart)
    } catch (_: java.security.GeneralSecurityException) {
        throw FastFrameException("undecryptable")
    }
    return FastFramePayload(kind, id, sequence, plaintext)
}

/**
 * Binary frames do not enter the messageId window. Instead each kind and ID must carry a higher sequence than the last
 * frame taken with them (file chunks follow on 0, 1, 2, ...; speed test bytes too), so a frame recorded and sent again is
 * dropped before it reaches a transfer. Remembers the 256 most recently used IDs, so a long transfer that keeps sending is
 * never forgotten while short ones come and go. A forgotten ID's replayed frame still reaches no data: every receiver
 * takes only the exact next sequence of a transfer it owns. Used by one read loop.
 */
internal class FastReplayGuard(private val capacity: Int = 256) {
    /** In access order: least recently used first. */
    private val highest = LinkedHashMap<String, Long>(16, 0.75f, true)

    fun accept(payload: FastFramePayload): Boolean {
        val key = "${payload.kind}:${payload.id}"
        val last = highest[key]
        if (last != null && payload.sequence <= last) return false
        if (last == null && highest.size >= capacity) highest.remove(highest.keys.first())
        highest[key] = payload.sequence
        return true
    }
}

/** One frame read from the connection. */
internal sealed interface ProtocolFrame {
    class Json(val text: String) : ProtocolFrame

    /** A binary frame, still encrypted. */
    class Binary(val kind: Int, val body: ByteArray) : ProtocolFrame
}

/**
 * Splits one connection's bytes into frames with its own buffer (no per-byte reads): JSON frames end at LF, with the
 * same rules as [readProtocolLine] (one CR before the LF dropped, at most [maxJsonBytes], strict UTF-8, a partial frame
 * at the end of the stream returned as a frame). Once [binaryAllowed] (the session is authenticated), a frame that
 * starts with [FastFrame.MARKER] is binary. A socket timeout keeps everything read so far, so the heartbeat loop can
 * call [next] again.
 */
internal class ProtocolStreamReader(private val input: InputStream, private val maxJsonBytes: Int = MAX_PROTOCOL_FRAME_BYTES) {
    @Volatile var binaryAllowed = false
    private var buffer = ByteArray(256 * 1024)
    private var start = 0
    private var end = 0
    private var searched = 0
    private var ended = false

    /** A binary body that is larger than what is buffered, filled across reads. */
    private var pendingKind = 0
    private var pendingBody: ByteArray? = null
    private var pendingFilled = 0

    fun next(): ProtocolFrame? {
        while (true) {
            pendingBody?.let { body ->
                val take = minOf(end - start, body.size - pendingFilled)
                System.arraycopy(buffer, start, body, pendingFilled, take)
                start += take
                pendingFilled += take
                if (pendingFilled == body.size) {
                    pendingBody = null
                    return ProtocolFrame.Binary(pendingKind, body)
                }
                if (ended) throw EOFException("stream ended inside a frame")
                if (start == end) {
                    start = 0
                    end = 0
                }
                // Large bodies read straight into the body array.
                val count = input.read(body, pendingFilled, body.size - pendingFilled)
                if (count < 0) throw EOFException("stream ended inside a frame")
                pendingFilled += count
                if (pendingFilled == body.size) {
                    pendingBody = null
                    return ProtocolFrame.Binary(pendingKind, body)
                }
                continue
            }
            if (end > start) {
                if (binaryAllowed && buffer[start] == FastFrame.MARKER) {
                    if (end - start >= FastFrame.HEADER_BYTES) {
                        val kind = buffer[start + 1].toInt() and 0xFF
                        val length = ByteBuffer.wrap(buffer, start + 2, 4).int
                        if (length < 1 || length > FastFrame.MAXIMUM_BODY) throw ProtocolFrameTooLargeException()
                        start += FastFrame.HEADER_BYTES
                        searched = 0
                        pendingKind = kind
                        pendingBody = ByteArray(length)
                        pendingFilled = 0
                        continue
                    }
                } else {
                    var index = start + searched
                    while (index < end && buffer[index] != '\n'.code.toByte()) index++
                    if (index < end) {
                        val frame = decode(start, index)
                        start = index + 1
                        searched = 0
                        return ProtocolFrame.Json(frame)
                    }
                    searched = end - start
                    // One byte over the limit is allowed only for the CR that may end the frame.
                    if (searched > maxJsonBytes + 1 || (searched == maxJsonBytes + 1 && buffer[end - 1] != '\r'.code.toByte())) {
                        throw ProtocolFrameTooLargeException()
                    }
                }
            }
            if (ended) {
                if (end > start && !(binaryAllowed && buffer[start] == FastFrame.MARKER)) {
                    val frame = decode(start, end)
                    start = end
                    return ProtocolFrame.Json(frame)
                }
                return null
            }
            if (start > 0) {
                System.arraycopy(buffer, start, buffer, 0, end - start)
                end -= start
                start = 0
            }
            if (end == buffer.size) buffer = buffer.copyOf(buffer.size * 2)
            val count = input.read(buffer, end, buffer.size - end)
            if (count < 0) ended = true else end += count
        }
    }

    private fun decode(from: Int, lineEnd: Int): String {
        val length = if (lineEnd > from && buffer[lineEnd - 1] == '\r'.code.toByte()) lineEnd - from - 1 else lineEnd - from
        if (length > maxJsonBytes) throw ProtocolFrameTooLargeException()
        return Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(buffer, from, length))
            .toString()
    }
}

/**
 * Sender-side flow control for one transfer (or one folder, or one speed test).
 *
 * Legacy peers: at most 64 chunks unacknowledged, as before. Fast peers: a window of unacknowledged bytes that grows
 * while acknowledgements come back quickly and shrinks when their round trip climbs more than [TARGET_QUEUE_DELAY_MILLIS]
 * above the lowest one seen, so a transfer fills the link without parking seconds of data in front of clipboard,
 * notifications and calls (a delay-based controller in the spirit of LEDBAT, RFC 6817). Thread-safe.
 */
internal class TransferPacer(val fast: Boolean, private val now: () -> Long = System::nanoTime) {
    val chunkSize: Int = if (fast) FastFrame.CHUNK_SIZE else 24 * 1024
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()
    private class Sent(val sequence: Long, val bytes: Int, val sentAt: Long)
    private val inFlight = HashMap<String, ArrayDeque<Sent>>()
    private var inFlightBytes = 0L
    private var inFlightChunks = 0
    var window: Long = if (fast) INITIAL_WINDOW else LEGACY_WINDOW_CHUNKS.toLong()
        private set
    private val minimumWindow = 2L * FastFrame.CHUNK_SIZE
    private val baseRoundTrips = ArrayDeque<LongArray>()
    private var lastDecrease = 0L
    private var windowLimited = false
    @Volatile var smoothedRoundTripNanos: Long? = null
        private set
    private var cancelled = false

    val unacknowledgedBytes: Long get() = lock.withLock { inFlightBytes }
    val baseRoundTripNanos: Long? get() = lock.withLock { baseRoundTrips.minOfOrNull { it[1] } }

    fun canSend(bytes: Int): Boolean = lock.withLock { roomLocked(bytes) }

    private fun roomLocked(bytes: Int): Boolean {
        if (!fast) return inFlightChunks < LEGACY_WINDOW_CHUNKS
        if (inFlightBytes == 0L) return true
        val fits = inFlightBytes + bytes <= window
        if (!fits) windowLimited = true
        return fits
    }

    /**
     * Blocks until a chunk of [bytes] fits. False when cancelled, or after [timeoutMillis] without an acknowledgement
     * making progress.
     */
    fun waitForRoom(bytes: Int, timeoutMillis: Long = 10_000, isCancelled: () -> Boolean = { false }): Boolean = lock.withLock {
        var deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        var lastBytes = inFlightBytes
        while (!roomLocked(bytes)) {
            if (cancelled || isCancelled()) return false
            changed.await(250, TimeUnit.MILLISECONDS)
            if (inFlightBytes != lastBytes) {
                lastBytes = inFlightBytes
                deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
            } else if (System.nanoTime() >= deadline) {
                return false
            }
        }
        !(cancelled || isCancelled())
    }

    /** Blocks until everything sent is acknowledged; false on cancel or timeout. */
    fun waitForAll(timeoutMillis: Long = 10_000, isCancelled: () -> Boolean = { false }): Boolean = lock.withLock {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        while (inFlightChunks > 0) {
            if (cancelled || isCancelled() || System.nanoTime() >= deadline) return false
            changed.await(250, TimeUnit.MILLISECONDS)
        }
        !(cancelled || isCancelled())
    }

    fun didSend(id: String, sequence: Long, bytes: Int) = lock.withLock {
        inFlight.getOrPut(id) { ArrayDeque() }.addLast(Sent(sequence, bytes, now()))
        inFlightBytes += bytes
        inFlightChunks++
    }

    /** A cumulative acknowledgement: every chunk of [id] up to [sequence] arrived. */
    fun acknowledged(id: String, sequence: Long) = lock.withLock {
        val queue = inFlight[id] ?: return@withLock
        var ackedBytes = 0
        var newest: Sent? = null
        while (queue.isNotEmpty() && queue.first().sequence <= sequence) {
            val head = queue.removeFirst()
            ackedBytes += head.bytes
            inFlightChunks--
            newest = head
        }
        if (queue.isEmpty()) inFlight.remove(id)
        val acked = newest ?: return@withLock
        inFlightBytes -= ackedBytes
        val at = now()
        sample(maxOf(0L, at - acked.sentAt), ackedBytes, at)
        changed.signalAll()
    }

    /** Drops what is left of a transfer (completed, cancelled or failed) so it no longer counts. */
    fun forget(id: String) = lock.withLock {
        val queue = inFlight.remove(id) ?: return@withLock
        queue.forEach {
            inFlightBytes -= it.bytes
            inFlightChunks--
        }
        changed.signalAll()
    }

    fun cancel() = lock.withLock {
        cancelled = true
        changed.signalAll()
    }

    private fun sample(roundTrip: Long, ackedBytes: Int, at: Long) {
        smoothedRoundTripNanos = smoothedRoundTripNanos?.let { (it * 7 + roundTrip) / 8 } ?: roundTrip
        while (baseRoundTrips.isNotEmpty() && at - baseRoundTrips.first()[0] > BASE_MEMORY_NANOS) baseRoundTrips.removeFirst()
        baseRoundTrips.addLast(longArrayOf(at, roundTrip))
        while (baseRoundTrips.size > 64) baseRoundTrips.removeFirst()
        if (!fast) return
        val base = baseRoundTrips.minOf { it[1] }
        val queueing = roundTrip - base
        if (queueing > TARGET_QUEUE_DELAY_NANOS) {
            // At most one decrease per round trip, so one burst of late acknowledgements counts once.
            if (at - lastDecrease >= maxOf(roundTrip, 20_000_000L)) {
                window = maxOf(minimumWindow, (window * 7) / 10)
                lastDecrease = at
            }
        } else if (windowLimited) {
            val growth = if (queueing < TARGET_QUEUE_DELAY_NANOS / 2) ackedBytes.toLong() else ackedBytes.toLong() * chunkSize / maxOf(window, 1L)
            window = minOf(MAXIMUM_WINDOW, window + maxOf(growth, 1L))
            windowLimited = false
        }
    }

    companion object {
        const val LEGACY_WINDOW_CHUNKS = 64
        const val INITIAL_WINDOW = 2L * 1024 * 1024
        const val MAXIMUM_WINDOW = 32L * 1024 * 1024
        const val TARGET_QUEUE_DELAY_MILLIS = 40L
        private const val TARGET_QUEUE_DELAY_NANOS = TARGET_QUEUE_DELAY_MILLIS * 1_000_000
        private const val BASE_MEMORY_NANOS = 10_000_000_000L
    }
}

/**
 * The speed shown in transfer rows: an average with a two-second time constant, so the number is steady enough to read
 * and the time left does not jump, yet follows a real change within a few seconds. The first sample stands alone.
 */
internal fun smoothedRate(previous: Double, sample: Double, elapsedSeconds: Double): Double {
    if (previous <= 0 || elapsedSeconds >= 2) return sample
    return previous + (sample - previous) * (1 - kotlin.math.exp(-elapsedSeconds.coerceAtLeast(0.0) / 2))
}

/** Reads until [buffer] is full or the stream ends; the count read. */
internal fun InputStream.readFully(buffer: ByteArray, length: Int = buffer.size): Int {
    var filled = 0
    while (filled < length) {
        val count = read(buffer, filled, length - filled)
        if (count < 0) break
        filled += count
    }
    return filled
}
