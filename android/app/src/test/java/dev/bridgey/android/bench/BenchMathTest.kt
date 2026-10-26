package dev.bridgey.android.bench

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BenchMathTest {
    private fun result(mode: BenchMode, bytes: Long, wallSec: Double, cpuMs: Long, uah: Long? = null, currentMah: Double? = null) =
        ModeResult(mode, bytes, (wallSec * 1e9).toLong(), cpuMs, if (uah == null && currentMah == null) null else EnergyReading(uah, null, currentMah, 4))

    @Test
    fun throughputIsDecimalMegabytesPerSecond() {
        val r = result(BenchMode.WRITE_ONLY, 1_000_000_000, 4.0, 1000)
        assertEquals(250.0, r.mbPerSecond, 1e-9)
        assertEquals(1.0, r.cpuSeconds, 1e-9)
    }

    @Test
    fun extrapolationScalesToTenGigabytesAndSubtractsTheBaseline() {
        val base = result(BenchMode.WRITE_ONLY, 1_000_000_000, 4.0, 1000, uah = 10_000)
        val b3 = result(BenchMode.BLAKE3_BLOCK, 1_000_000_000, 5.0, 3000, uah = 15_000)
        val e = extrapolate(base, b3)
        assertEquals(50.0, e.wallSeconds, 1e-9)
        assertEquals(10.0, e.extraWallSeconds, 1e-9)
        assertEquals(20.0, e.extraCpuSeconds, 1e-9)
        assertEquals(50.0, e.extraMah!!, 1e-9)
        assertEquals(1.0, e.extraPercentOfBattery!!, 1e-9)
    }

    @Test
    fun differentSizesScaleSeparately() {
        val base = result(BenchMode.WRITE_ONLY, 500_000_000, 2.0, 500)
        val r = result(BenchMode.BLAKE3_BLOCK, 1_000_000_000, 3.0, 1500)
        val e = extrapolate(base, r)
        assertEquals(30.0 - 40.0, e.extraWallSeconds, 1e-9)
        assertNull(e.extraMah)
    }

    @Test
    fun energyPrefersTheChargeCounterThenCurrent() {
        assertEquals(2.5, result(BenchMode.WRITE_ONLY, 1, 1.0, 1, uah = 2500, currentMah = 9.0).energyMah!!, 1e-9)
        val fallback = result(BenchMode.WRITE_ONLY, 1, 1.0, 1, uah = 0, currentMah = 9.0)
        assertEquals(9.0, fallback.energyMah!!, 1e-9)
        assertEquals("current_now", fallback.energySource)
        assertNull(result(BenchMode.WRITE_ONLY, 1, 1.0, 1).energyMah)
    }

    @Test
    fun spaceNeedsTwiceTheFileAndOneGigabyteExtra() {
        val gib = 1024L * 1024 * 1024
        assertEquals(3 * gib, requiredFreeBytes(gib))
        assertTrue(hasEnoughSpace(3 * gib, gib))
        assertFalse(hasEnoughSpace(3 * gib - 1, gib))
        assertEquals(1536L * 1024 * 1024, requiredFreeBytes(QUICK_BYTES))
    }

    @Test
    fun jsonCarriesEveryModeAndTheExtrapolation() {
        val base = result(BenchMode.WRITE_ONLY, 1_000_000_000, 4.0, 1000, uah = 10_000)
        val b3 = result(BenchMode.BLAKE3_BLOCK, 1_000_000_000, 5.0, 3000, uah = 15_000)
        val report = BenchReport("test", true, true, 1_000_000_000, 0L, "dev", "1.0", false, "note", listOf(base, b3))
        val json = JSONObject(report.toJson())
        assertEquals(2, json.getJSONArray("modes").length())
        assertEquals("blake3_block", json.getJSONArray("per10GbExtraOverWriteOnly").getJSONObject(0).getString("mode"))
        assertEquals(10.0, json.getJSONArray("per10GbExtraOverWriteOnly").getJSONObject(0).getDouble("extraWallSeconds"), 1e-9)
        assertTrue(report.toText { it.english }.contains("Extra per 10 GB"))
        assertFalse(report.toJson().contains("—"))
    }

    /** Runs the engine on a 4 MiB file with SHA-256 standing in for BLAKE3, and checks the clean-up. */
    @Test
    fun engineRunsEveryModeVerifiesReadBackAndDeletesItsFiles() {
        val dir = Files.createTempDirectory("bench").toFile()
        var cpu = 0L
        val probe = object : BenchProbe {
            override fun cpuMillis() = cpu++
            override fun startEnergy() {}
            override fun stopEnergy(): EnergyReading? = null
        }
        val bench = HashBenchmark(dir, probe, Sha256Hasher::newHasher)
        val results = bench.runAll(4L * BLOCK_BYTES)
        assertEquals(BenchMode.entries, results.map { it.mode })
        assertTrue(results.all { it.verifyMismatches == 0 && it.bytes == 4L * BLOCK_BYTES })
        assertEquals(0, dir.listFiles()!!.size)
        dir.deleteRecursively()
    }

    @Test
    fun cancellingStopsAndLeavesNoFile() {
        val dir = Files.createTempDirectory("bench").toFile()
        val probe = object : BenchProbe {
            override fun cpuMillis() = 0L
            override fun startEnergy() {}
            override fun stopEnergy(): EnergyReading? = null
        }
        var n = 0
        val bench = HashBenchmark(dir, probe, Sha256Hasher::newHasher, isCancelled = { ++n > 2 })
        try {
            bench.runAll(4L * BLOCK_BYTES)
            throw AssertionError("should have been cancelled")
        } catch (_: BenchCancelled) {
        }
        assertEquals(0, dir.listFiles()!!.size)
        dir.deleteRecursively()
        assertNotNull(Blake3Vectors.input(3))
    }
}
