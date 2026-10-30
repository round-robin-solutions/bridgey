package dev.bridgey.android

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The Android side's transfer ceiling without the emulator: the same frame code the app uses (FastTransfer.kt, the
 * JSON envelope with its protocol 2 tag) over TCP loopback on the JVM, printed as "CEILING ..." lines. Runs only with
 * -Pbench=1 (timings depend on the machine; docs/transfer-speed.md has the numbers):
 *   ./gradlew :app:testDebugUnitTest -Pbench=1 --tests '*FastTransferCeilingBench'
 * -Pbench.mb=<size> changes the file size (default 1000 MB).
 *
 * Each run mirrors the app's threads: the sender reads the file, waits for room in its TransferPacer, seals and writes
 * under the session's write lock; the receiver's read loop splits frames, decrypts, checks replay, writes the file and
 * its SHA-256 (as IncomingFileTransfer does) and answers each chunk with a tagged files.chunk.ack; the sender's read
 * loop feeds the acks to the pacer.
 */
class FastTransferCeilingBench {
    companion object {
        /**
         * The same runs on Android's runtime (ART, Conscrypt), outside the app, with this class dexed next to the debug APK:
         *   CLASSPATH=app-debug.apk:bench.dex app_process -Djava.io.tmpdir=/data/local/tmp -Dbridgey.bench=1 / \
         *     dev.bridgey.android.FastTransferCeilingBench
         */
        @JvmStatic fun main(args: Array<String>) {
            val bench = FastTransferCeilingBench()
            if (!args.contains("--disk-only")) {
                bench.codecAlone()
                bench.rawTcp()
                bench.fastFramesWithAcksNoDisk()
            }
            if (args.contains("--no-disk")) return
            bench.fastFramesWithAcksAndDisk()
            bench.legacyJsonWithAcksAndDisk()
        }
    }

    private val enabled = System.getProperty("bridgey.bench") != null
    private val megabytes = System.getProperty("bridgey.benchMb")?.toLongOrNull() ?: 1000L
    private val key = ByteArray(32) { it.toByte() }
    private val envelopeKey = ByteArray(32) { (it + 7).toByte() }
    private val phone = "7e57d00d-0000-4000-8000-0000000000aa"
    private val mac = "7e57d00d-0000-4000-8000-0000000000bb"
    private val loopback = InetAddress.getLoopbackAddress()

    private fun report(name: String, bytes: Long, nanos: Long, extra: String = "") {
        val seconds = nanos / 1e9
        println("CEILING android-${System.getProperty("java.vm.name")?.takeIf { it.contains("Dalvik") }?.let { "art" } ?: "jvm"} $name: ${"%.0f".format(bytes / 1e6 / seconds)} MB/s (${bytes / 1_000_000} MB in ${"%.2f".format(seconds)} s)$extra")
    }

    private fun sourceFile(): File {
        val file = File(System.getProperty("java.io.tmpdir"), "bridgey-ceiling-$megabytes.bin")
        if (file.length() != megabytes * 1_000_000) {
            val block = ByteArray(1_000_000).also(java.util.Random(1)::nextBytes)
            FileOutputStream(file).use { out -> repeat(megabytes.toInt()) { out.write(block) } }
        }
        return file
    }

    @Test
    fun codecAlone() {
        assumeTrue(enabled)
        val chunk = ByteArray(FastFrame.CHUNK_SIZE) { it.toByte() }
        val count = 400
        repeat(200) { val frame = sealFastFrame(1, "t", it.toLong(), chunk, key, mac); openFastFrameBody(1, frame.copyOfRange(6, frame.size), key, mac) }
        var started = System.nanoTime()
        val frames = (0 until count).map { sealFastFrame(1, "t", it.toLong(), chunk, key, mac) }
        report("seal 256 KiB binary frames", count.toLong() * chunk.size, System.nanoTime() - started)
        started = System.nanoTime()
        for (frame in frames) openFastFrameBody(1, frame.copyOfRange(6, frame.size), key, mac)
        report("open 256 KiB binary frames", count.toLong() * chunk.size, System.nanoTime() - started)
        val small = ByteArray(24 * 1024) { it.toByte() }
        val jsonCount = 4_000
        started = System.nanoTime()
        val lines = (0 until jsonCount).map {
            val sealed = Crypto.encrypt(key, small)
            Message(kind = "files.chunk", sessionId = "s", messageId = UUID.randomUUID().toString(), transferId = "t",
                sequence = it.toLong(), nonce = sealed.nonce, ciphertext = sealed.ciphertext).encode()
        }
        report("seal 24 KiB JSON chunks", jsonCount.toLong() * small.size, System.nanoTime() - started)
        started = System.nanoTime()
        for (line in lines) {
            val message = Message.decode(line)
            checkNotNull(Crypto.decrypt(key, message.nonce!!, message.ciphertext!!))
        }
        report("open 24 KiB JSON chunks", jsonCount.toLong() * small.size, System.nanoTime() - started)
        val digest = MessageDigest.getInstance("SHA-256")
        started = System.nanoTime()
        repeat(count) { digest.update(chunk) }
        report("SHA-256", count.toLong() * chunk.size, System.nanoTime() - started)
    }

    @Test
    fun rawTcp() {
        assumeTrue(enabled)
        val total = megabytes * 1_000_000
        ServerSocket(0, 1, loopback).use { server ->
            val received = AtomicLong()
            val reader = thread {
                server.accept().use { socket ->
                    val buffer = ByteArray(256 * 1024)
                    val input = socket.getInputStream()
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        received.addAndGet(count.toLong())
                    }
                }
            }
            val started = System.nanoTime()
            Socket(loopback, server.localPort).use { socket ->
                val output = socket.getOutputStream()
                val block = ByteArray(256 * 1024)
                var sent = 0L
                while (sent < total) {
                    output.write(block)
                    sent += block.size
                }
            }
            reader.join()
            report("raw TCP loopback", received.get(), System.nanoTime() - started)
        }
    }

    @Test
    fun fastFramesWithAcksAndDisk() {
        assumeTrue(enabled)
        transfer("fast 256 KiB binary frames, acks, disk", fast = true, disk = true)
    }

    @Test
    fun fastFramesWithAcksNoDisk() {
        assumeTrue(enabled)
        transfer("fast 256 KiB binary frames, acks, no disk", fast = true, disk = false)
    }

    @Test
    fun legacyJsonWithAcksAndDisk() {
        assumeTrue(enabled)
        transfer("legacy 24 KiB JSON chunks, acks, 64-chunk window, disk", fast = false, disk = true)
    }

    /** One transfer of the source file from a sender socket to a receiver socket over loopback. */
    private fun transfer(name: String, fast: Boolean, disk: Boolean) {
        val source = sourceFile()
        val total = source.length()
        val transferId = UUID.randomUUID().toString()
        // -Dbridgey.benchDir puts the received file elsewhere (on a phone: /sdcard/Download, through Android's storage layer).
        val target = File(System.getProperty("bridgey.benchDir") ?: System.getProperty("java.io.tmpdir"), "bridgey-ceiling-received-${UUID.randomUUID()}.bin")
        ServerSocket(0, 1, loopback).use { server ->
            var receiverError: Throwable? = null
            val receiver = thread(name = "receiver-read-loop") {
                runCatching {
                    server.accept().use { socket ->
                        socket.tcpNoDelay = true
                        val frames = ProtocolStreamReader(socket.getInputStream()).apply { binaryAllowed = fast }
                        val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
                        val file: OutputStream = if (disk) FileOutputStream(target) else OutputStream.nullOutputStream()
                        val digest = MessageDigest.getInstance("SHA-256")
                        val replay = FastReplayGuard()
                        var received = 0L
                        var next = 0L
                        file.use {
                            while (received < total) {
                                val (sequence, plaintext) = when (val frame = frames.next() ?: break) {
                                    is ProtocolFrame.Binary -> {
                                        val payload = openFastFrameBody(frame.kind, frame.body, key, phone)
                                        check(replay.accept(payload))
                                        payload.sequence to payload.plaintext
                                    }
                                    is ProtocolFrame.Json -> {
                                        val message = Message.decode(frame.text)
                                        check(SessionSecurity.tagMatches(envelopeKey, phone, message))
                                        message.sequence!! to Crypto.decrypt(key, message.nonce!!, message.ciphertext!!)!!
                                    }
                                }
                                check(sequence == next++)
                                file.write(plaintext)
                                digest.update(plaintext)
                                received += plaintext.size
                                val ack = Message(kind = "files.chunk.ack", sessionId = "s", transferId = transferId, sequence = sequence)
                                output.write(ack.copy(tag = SessionSecurity.tag(envelopeKey, mac, ack)).encode().toByteArray())
                                output.write('\n'.code)
                                output.flush()
                            }
                        }
                        check(received == total)
                    }
                }.onFailure { receiverError = it }
            }
            val socket = Socket(loopback, server.localPort).apply { tcpNoDelay = true }
            val pacer = TransferPacer(fast)
            val ackReader = thread(name = "sender-read-loop") {
                runCatching {
                    val frames = ProtocolStreamReader(socket.getInputStream())
                    while (true) {
                        val frame = frames.next() as? ProtocolFrame.Json ?: break
                        val message = Message.decode(frame.text)
                        check(SessionSecurity.tagMatches(envelopeKey, mac, message))
                        pacer.acknowledged(message.transferId!!, message.sequence!!)
                    }
                }
            }
            val writeLock = Any()
            val output = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
            val started = System.nanoTime()
            FileInputStream(source).use { input ->
                val buffer = ByteArray(pacer.chunkSize)
                var sequence = 0L
                while (true) {
                    val count = input.readFully(buffer)
                    if (count <= 0) break
                    check(pacer.waitForRoom(count, timeoutMillis = 30_000))
                    pacer.didSend(transferId, sequence, count)
                    val bytes = if (fast) {
                        sealFastFrame(FastFrame.CHUNK_KIND, transferId, sequence, buffer, key, phone, 0, count)
                    } else {
                        val sealed = Crypto.encrypt(key, buffer.copyOf(count))
                        val message = Message(kind = "files.chunk", sessionId = "s", messageId = UUID.randomUUID().toString(),
                            transferId = transferId, sequence = sequence, nonce = sealed.nonce, ciphertext = sealed.ciphertext)
                        (message.copy(tag = SessionSecurity.tag(envelopeKey, phone, message)).encode() + "\n").toByteArray()
                    }
                    synchronized(writeLock) {
                        output.write(bytes)
                        output.flush()
                    }
                    sequence++
                }
            }
            check(pacer.waitForAll(timeoutMillis = 60_000))
            val elapsed = System.nanoTime() - started
            receiver.join()
            socket.close()
            ackReader.join()
            target.delete()
            receiverError?.let { throw it }
            val window = if (fast) ", window ${pacer.window / 1024} KiB, base round trip ${"%.2f".format((pacer.baseRoundTripNanos ?: 0) / 1e6)} ms" else ""
            report(name, total, elapsed, window)
        }
    }
}
