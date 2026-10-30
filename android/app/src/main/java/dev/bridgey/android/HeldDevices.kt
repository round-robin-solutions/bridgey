package dev.bridgey.android

/**
 * Devices the user disconnected on this phone. They are not redialled, and a session they
 * open themselves is closed after authentication, until the user connects again from the
 * device page. Kept in memory only: restarting Bridgey forgets it.
 */
class HeldDevices {
    private val held = HashSet<String>()

    @Synchronized fun hold(deviceId: String) { held += deviceId }

    @Synchronized fun release(deviceId: String) { held -= deviceId }

    @Synchronized fun isHeld(deviceId: String): Boolean = deviceId in held

    @Synchronized fun all(): Set<String> = held.toSet()
}
