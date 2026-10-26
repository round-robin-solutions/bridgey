package dev.bridgey.android.bench

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/** Reads CPU time and battery energy around one mode. Faked in unit tests. */
interface BenchProbe {
    fun cpuMillis(): Long
    fun startEnergy()
    fun stopEnergy(): EnergyReading?
}

class BenchCancelled : RuntimeException()

/**
 * Writes a test file in 1 MiB blocks under each integrity mode and measures it. The data is
 * incompressible pseudo-random bytes, built once, so generating it costs nothing per mode.
 * Hash work happens before the write of each block, as it would when a block arrives.
 */
class HashBenchmark(
    private val dir: File,
    private val probe: BenchProbe,
    private val newBlake3: () -> BlockHasher,
    private val newSha256: () -> BlockHasher = Sha256Hasher::newHasher,
    private val isCancelled: () -> Boolean = { false },
    private val clock: () -> Long = System::nanoTime,
) {
    private val block = ByteArray(BLOCK_BYTES).also { fillPseudoRandom(it) }

    /** Progress is (finished work in 0..1 across all modes, mode being run). */
    fun runAll(fileBytes: Long, modes: List<BenchMode> = BenchMode.entries, progress: (Float, BenchMode) -> Unit = { _, _ -> }): List<ModeResult> {
        require(fileBytes > 0 && fileBytes % BLOCK_BYTES == 0L) { "size must be a whole number of blocks" }
        val out = mutableListOf<ModeResult>()
        modes.forEachIndexed { index, mode ->
            val file = File(dir, "bench-${mode.id}.bin")
            try {
                out += runMode(mode, file, fileBytes) { fraction ->
                    progress((index + fraction) / modes.size, mode)
                }
            } finally {
                file.delete()
            }
        }
        return out
    }

    fun runMode(mode: BenchMode, file: File, fileBytes: Long, progress: (Float) -> Unit = {}): ModeResult {
        val blocks = (fileBytes / BLOCK_BYTES).toInt()
        val perBlock: BlockHasher? = when (mode) {
            BenchMode.BLAKE3_BLOCK, BenchMode.BLAKE3_BLOCK_READBACK -> newBlake3()
            BenchMode.SHA256_BLOCK -> newSha256()
            else -> null
        }
        val whole: BlockHasher? = if (mode == BenchMode.BLAKE3_WHOLE_END) newBlake3() else null
        val cvs = if (perBlock != null) ByteArray(blocks * 32) else null
        var mismatches = 0
        val buf = ByteArray(BLOCK_BYTES)
        try {
            file.delete()
            probe.startEnergy()
            val cpu0 = probe.cpuMillis()
            val t0 = clock()
            FileOutputStream(file).use { out ->
                for (i in 0 until blocks) {
                    if (isCancelled()) throw BenchCancelled()
                    stamp(i)
                    if (perBlock != null && cvs != null) {
                        perBlock.reset()
                        perBlock.update(block, 0, BLOCK_BYTES)
                        perBlock.digest().copyInto(cvs, i * 32)
                    }
                    out.write(block, 0, BLOCK_BYTES)
                    progress(writeShare(mode) * (i + 1) / blocks)
                }
                out.fd.sync()
            }
            if (mode == BenchMode.BLAKE3_BLOCK_READBACK && perBlock != null && cvs != null) {
                FileInputStream(file).use { input ->
                    for (i in 0 until blocks) {
                        if (isCancelled()) throw BenchCancelled()
                        readFully(input, buf)
                        perBlock.reset()
                        perBlock.update(buf, 0, BLOCK_BYTES)
                        val cv = perBlock.digest()
                        if (!cv.contentEquals(cvs.copyOfRange(i * 32, i * 32 + 32))) mismatches++
                        progress(0.5f + 0.5f * (i + 1) / blocks)
                    }
                }
            }
            if (whole != null) {
                FileInputStream(file).use { input ->
                    for (i in 0 until blocks) {
                        if (isCancelled()) throw BenchCancelled()
                        readFully(input, buf)
                        whole.update(buf, 0, BLOCK_BYTES)
                        progress(0.5f + 0.5f * (i + 1) / blocks)
                    }
                }
                whole.digest()
            }
            val wall = clock() - t0
            val cpu = probe.cpuMillis() - cpu0
            val energy = probe.stopEnergy()
            progress(1f)
            return ModeResult(mode, fileBytes, wall, cpu, energy, mismatches)
        } finally {
            perBlock?.close()
            whole?.close()
        }
    }

    private fun writeShare(mode: BenchMode): Float =
        if (mode == BenchMode.BLAKE3_BLOCK_READBACK || mode == BenchMode.BLAKE3_WHOLE_END) 0.5f else 1f

    private fun stamp(index: Int) {
        var v = index.toLong()
        for (k in 0 until 8) {
            block[k] = v.toByte()
            v = v ushr 8
        }
    }

    private fun readFully(input: FileInputStream, into: ByteArray) {
        var at = 0
        while (at < into.size) {
            val n = input.read(into, at, into.size - at)
            if (n < 0) throw java.io.EOFException("test file shorter than written")
            at += n
        }
    }

    companion object {
        fun fillPseudoRandom(target: ByteArray) {
            var x = 0x9E3779B97F4A7C15uL.toLong()
            var i = 0
            while (i < target.size) {
                x = x xor (x shl 13); x = x xor (x ushr 7); x = x xor (x shl 17)
                var v = x
                var k = 0
                while (k < 8 && i < target.size) {
                    target[i++] = v.toByte(); v = v ushr 8; k++
                }
            }
        }
    }
}
