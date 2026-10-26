package dev.bridgey.android.bench

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Process
import android.os.SystemClock

/** CPU time from the process clock; battery charge counter and current sampled every 250 ms. */
class AndroidBenchProbe(context: Context) : BenchProbe {
    private val battery = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
    @Volatile private var running = false
    private var thread: Thread? = null
    private var chargeStart: Long? = null
    private var startedAt = 0L
    private var currentSumUa = 0.0
    private var currentSamples = 0
    private var lastSampleAt = 0L
    private var currentMicroAmpSeconds = 0.0

    override fun cpuMillis(): Long = Process.getElapsedCpuTime()

    override fun startEnergy() {
        chargeStart = readCharge()
        currentSumUa = 0.0
        currentSamples = 0
        currentMicroAmpSeconds = 0.0
        startedAt = SystemClock.elapsedRealtime()
        lastSampleAt = startedAt
        running = true
        thread = Thread({
            while (running) {
                sampleCurrent()
                try { Thread.sleep(SAMPLE_MS) } catch (_: InterruptedException) { break }
            }
        }, "bench-energy").also { it.isDaemon = true; it.start() }
    }

    override fun stopEnergy(): EnergyReading? {
        running = false
        thread?.interrupt()
        thread?.join(1000)
        sampleCurrent()
        val end = readCharge()
        val start = chargeStart
        val used = if (start != null && end != null) start - end else null
        val avg = if (currentSamples > 0) (currentSumUa / currentSamples).toLong() else null
        // Integrated |current| over the run: microamp-seconds to mAh.
        val mah = if (currentSamples > 0) currentMicroAmpSeconds / 3600.0 / 1000.0 else null
        return EnergyReading(used, avg, mah, currentSamples)
    }

    @Synchronized
    private fun sampleCurrent() {
        val now = SystemClock.elapsedRealtime()
        val raw = battery.getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        if (raw == Long.MIN_VALUE || raw == 0L) { lastSampleAt = now; return }
        val ua = Math.abs(raw).toDouble()
        currentSumUa += ua
        currentSamples++
        currentMicroAmpSeconds += ua * (now - lastSampleAt) / 1000.0
        lastSampleAt = now
    }

    private fun readCharge(): Long? =
        battery.getLongProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER).takeIf { it != Long.MIN_VALUE && it > 0 }

    companion object {
        const val SAMPLE_MS = 250L

        fun isPluggedIn(context: Context): Boolean? {
            val i = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
            return i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
        }
    }
}
