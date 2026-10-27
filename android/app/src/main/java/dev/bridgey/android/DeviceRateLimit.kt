package dev.bridgey.android

/** Pings and code link requests: one per device in this window. */
internal const val ALERT_INTERVAL_MILLIS = 2_000L

/** At most one event per device every [intervalMillis]; the extras are dropped, not queued. */
internal class DeviceRateLimit(
    private val intervalMillis: Long,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val last = HashMap<String, Long>()

    @Synchronized fun allow(deviceId: String): Boolean {
        val now = clock()
        val previous = last[deviceId]
        if (previous != null && now - previous in 0 until intervalMillis) return false
        last[deviceId] = now
        if (last.size > MAX_DEVICES) last.keys.firstOrNull { it != deviceId }?.let(last::remove)
        return true
    }

    private companion object {
        const val MAX_DEVICES = 64
    }
}
