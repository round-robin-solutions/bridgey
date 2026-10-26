package dev.bridgey.android.bench

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

const val BLOCK_BYTES = 1 shl 20
const val QUICK_BYTES = 256L * 1024 * 1024
const val FULL_BYTES = 1024L * 1024 * 1024
const val TARGET_BYTES = 10_000_000_000L
const val OPLUS_11_BATTERY_MAH = 5000.0

/** The integrity modes, in run order. [id] is the stable key used in JSON. */
enum class BenchMode(val id: String, val english: String) {
    WRITE_ONLY("write_only", "1. Write only"),
    BLAKE3_BLOCK("blake3_block", "2. Write + BLAKE3 per 1 MiB block"),
    BLAKE3_BLOCK_READBACK("blake3_block_readback", "3. Mode 2 + read back and hash again"),
    BLAKE3_WHOLE_END("blake3_whole_end", "4. Write, then one BLAKE3 of the whole file"),
    SHA256_BLOCK("sha256_block", "5. Write + SHA-256 per 1 MiB block (comparison)"),
}

/** Free space the test needs: two copies of the file plus 1 GiB of headroom. */
fun requiredFreeBytes(fileBytes: Long): Long = 2 * fileBytes + 1024L * 1024 * 1024

fun hasEnoughSpace(freeBytes: Long, fileBytes: Long): Boolean = freeBytes >= requiredFreeBytes(fileBytes)

/** What the energy sampler saw during one mode. Null fields mean the device did not report them. */
data class EnergyReading(
    val chargeUsedUah: Long?,
    val avgCurrentUa: Long?,
    val currentMah: Double?,
    val samples: Int,
)

data class ModeResult(
    val mode: BenchMode,
    val bytes: Long,
    val wallNanos: Long,
    val cpuMillis: Long,
    val energy: EnergyReading?,
    val verifyMismatches: Int = 0,
) {
    val wallSeconds: Double get() = wallNanos / 1e9
    val cpuSeconds: Double get() = cpuMillis / 1e3
    val mbPerSecond: Double get() = if (wallNanos <= 0) 0.0 else bytes / 1e6 / wallSeconds

    /** Battery use in mAh: the charge counter when it moved, otherwise the integrated current. */
    val energyMah: Double?
        get() {
            val e = energy ?: return null
            val counter = e.chargeUsedUah
            if (counter != null && counter > 0) return counter / 1000.0
            return e.currentMah
        }

    val energySource: String
        get() {
            val e = energy ?: return "none"
            val counter = e.chargeUsedUah
            return when {
                counter != null && counter > 0 -> "charge_counter"
                e.currentMah != null -> "current_now"
                else -> "none"
            }
        }
}

/** A mode scaled to [TARGET_BYTES], and what it costs on top of the write-only baseline. */
data class Extrapolation(
    val mode: BenchMode,
    val wallSeconds: Double,
    val cpuSeconds: Double,
    val mah: Double?,
    val extraWallSeconds: Double,
    val extraCpuSeconds: Double,
    val extraMah: Double?,
    val extraPercentOfBattery: Double?,
)

fun extrapolate(
    baseline: ModeResult,
    result: ModeResult,
    targetBytes: Long = TARGET_BYTES,
    batteryMah: Double = OPLUS_11_BATTERY_MAH,
): Extrapolation {
    fun scale(value: Double, bytes: Long) = value * targetBytes / bytes
    val wall = scale(result.wallSeconds, result.bytes)
    val cpu = scale(result.cpuSeconds, result.bytes)
    val mah = result.energyMah?.let { scale(it, result.bytes) }
    val baseWall = scale(baseline.wallSeconds, baseline.bytes)
    val baseCpu = scale(baseline.cpuSeconds, baseline.bytes)
    val baseMah = baseline.energyMah?.let { scale(it, baseline.bytes) }
    val extraMah = if (mah != null && baseMah != null) mah - baseMah else null
    return Extrapolation(
        mode = result.mode,
        wallSeconds = wall,
        cpuSeconds = cpu,
        mah = mah,
        extraWallSeconds = wall - baseWall,
        extraCpuSeconds = cpu - baseCpu,
        extraMah = extraMah,
        extraPercentOfBattery = extraMah?.let { it / batteryMah * 100.0 },
    )
}

data class BenchReport(
    val hashImplementation: String,
    val nativeBlake3: Boolean,
    val vectorsPassed: Boolean,
    val sizeBytes: Long,
    val startedAtMillis: Long,
    val device: String,
    val appVersion: String,
    val pluggedIn: Boolean?,
    val readBackNote: String,
    val results: List<ModeResult>,
    val batteryMah: Double = OPLUS_11_BATTERY_MAH,
) {
    val baseline: ModeResult? get() = results.firstOrNull { it.mode == BenchMode.WRITE_ONLY }

    val extrapolations: List<Extrapolation>
        get() {
            val base = baseline ?: return emptyList()
            return results.filter { it.mode != BenchMode.WRITE_ONLY }.map { extrapolate(base, it, TARGET_BYTES, batteryMah) }
        }

    fun toJson(): String {
        val root = JSONObject()
        root.put("schema", 1)
        root.put("app", "Bridgey by Round Robin")
        root.put("appVersion", appVersion)
        root.put("device", device)
        root.put("startedAtEpochMillis", startedAtMillis)
        root.put("fileBytes", sizeBytes)
        root.put("blockBytes", BLOCK_BYTES)
        root.put("hashImplementation", hashImplementation)
        root.put("nativeBlake3", nativeBlake3)
        root.put("blake3VectorsPassed", vectorsPassed)
        root.put("pluggedIn", pluggedIn ?: JSONObject.NULL)
        root.put("batteryCapacityMah", batteryMah)
        root.put("readBackNote", readBackNote)
        val modes = JSONArray()
        for (r in results) {
            val o = JSONObject()
            o.put("mode", r.mode.id)
            o.put("bytes", r.bytes)
            o.put("wallSeconds", r.wallSeconds)
            o.put("mbPerSecond", r.mbPerSecond)
            o.put("cpuSeconds", r.cpuSeconds)
            o.put("verifyMismatches", r.verifyMismatches)
            o.put("energySource", r.energySource)
            o.put("energyMah", r.energyMah ?: JSONObject.NULL)
            o.put("chargeCounterUsedUah", r.energy?.chargeUsedUah ?: JSONObject.NULL)
            o.put("avgCurrentUa", r.energy?.avgCurrentUa ?: JSONObject.NULL)
            o.put("energySamples", r.energy?.samples ?: 0)
            modes.put(o)
        }
        root.put("modes", modes)
        val ex = JSONArray()
        for (e in extrapolations) {
            val o = JSONObject()
            o.put("mode", e.mode.id)
            o.put("per10GbWallSeconds", e.wallSeconds)
            o.put("per10GbCpuSeconds", e.cpuSeconds)
            o.put("per10GbMah", e.mah ?: JSONObject.NULL)
            o.put("extraWallSeconds", e.extraWallSeconds)
            o.put("extraCpuSeconds", e.extraCpuSeconds)
            o.put("extraMah", e.extraMah ?: JSONObject.NULL)
            o.put("extraPercentOfBattery", e.extraPercentOfBattery ?: JSONObject.NULL)
            ex.put(o)
        }
        root.put("per10GbExtraOverWriteOnly", ex)
        return root.toString(2)
    }

    /** Plain text for Copy results. [name] gives the display name of a mode. */
    fun toText(name: (BenchMode) -> String): String {
        val sb = StringBuilder()
        val l = Locale.US
        sb.append("Bridgey performance test, $device, $appVersion\n")
        sb.append("$hashImplementation; test vectors ${if (vectorsPassed) "pass" else "FAIL"}; file ${sizeBytes / (1024 * 1024)} MiB, block 1 MiB\n")
        if (pluggedIn == true) sb.append("WARNING: the phone was plugged in, so battery numbers mean nothing.\n")
        sb.append("\n")
        for (r in results) {
            sb.append(String.format(l, "%s: %.2f s, %.0f MB/s, CPU %.2f s", name(r.mode), r.wallSeconds, r.mbPerSecond, r.cpuSeconds))
            r.energyMah?.let { sb.append(String.format(l, ", %.2f mAh (%s)", it, r.energySource)) }
            if (r.verifyMismatches > 0) sb.append(", MISMATCHES ${r.verifyMismatches}")
            sb.append("\n")
        }
        sb.append("\nExtra per 10 GB over write only\n")
        for (e in extrapolations) {
            sb.append(String.format(l, "%s: %+.1f s, %+.1f CPU s", name(e.mode), e.extraWallSeconds, e.extraCpuSeconds))
            if (e.extraMah != null && e.extraPercentOfBattery != null) {
                sb.append(String.format(l, ", %+.1f mAh (%.2f%% of %.0f mAh)", e.extraMah, e.extraPercentOfBattery, batteryMah))
            }
            sb.append("\n")
        }
        sb.append("\n").append(readBackNote).append("\n")
        return sb.toString()
    }
}
