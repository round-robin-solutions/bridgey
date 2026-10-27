package dev.bridgey.android.screen

/** One open "Phone screen" request: which Mac asked, and when. */
data class ScreenRequest(val deviceId: String, val macName: String, val requestId: String, val receivedAtMillis: Long) {
    fun expired(now: Long): Boolean = now - receivedAtMillis >= ScreenLimits.REQUEST_LIFETIME_MILLIS
}

/** What to do with a screen.request. */
sealed interface ScreenRequestDecision {
    /** Malformed: no answer. */
    data object Drop : ScreenRequestDecision

    /** Answer with this status and do nothing else. */
    data class Refuse(val requestId: String, val status: ScreenStatus) : ScreenRequestDecision

    /** Answer `waiting` and ask the person (the consent dialog, or a notification that leads to it). */
    data class Accept(val request: ScreenRequest) : ScreenRequestDecision
}

/**
 * Open screen requests, one per Mac. With the switch off: `disabled`. While this phone shares with any Mac:
 * `busy`. A Mac asking again within 3 seconds, or while its request is open: `busy`.
 */
class ScreenRequests(private val clock: () -> Long) {
    private val open = mutableMapOf<String, ScreenRequest>()
    private val lastRequestAt = mutableMapOf<String, Long>()

    @Synchronized fun receive(deviceId: String, macName: String, plaintext: ByteArray, enabled: Boolean, sharing: Boolean): ScreenRequestDecision {
        val requestId = decodeScreenRequest(plaintext) ?: return ScreenRequestDecision.Drop
        if (!enabled) return ScreenRequestDecision.Refuse(requestId, ScreenStatus.DISABLED)
        val now = clock()
        open[deviceId]?.takeIf { it.expired(now) }?.let { open.remove(deviceId) }
        val last = lastRequestAt[deviceId]
        lastRequestAt[deviceId] = now
        if (sharing) return ScreenRequestDecision.Refuse(requestId, ScreenStatus.BUSY)
        if (last != null && now - last < ScreenLimits.REQUEST_SPACING_MILLIS) return ScreenRequestDecision.Refuse(requestId, ScreenStatus.BUSY)
        if (open.containsKey(deviceId)) return ScreenRequestDecision.Refuse(requestId, ScreenStatus.BUSY)
        val request = ScreenRequest(deviceId, macName.take(64), requestId, now)
        open[deviceId] = request
        return ScreenRequestDecision.Accept(request)
    }

    /** The request, if it is still open and not expired. */
    @Synchronized fun current(deviceId: String, requestId: String): ScreenRequest? {
        val request = open[deviceId]?.takeIf { it.requestId == requestId } ?: return null
        if (request.expired(clock())) {
            open.remove(deviceId)
            return null
        }
        return request
    }

    /** The request is answered (shared, declined, failed or expired). True if it was open. */
    @Synchronized fun finish(deviceId: String, requestId: String): Boolean {
        if (open[deviceId]?.requestId != requestId) return false
        open.remove(deviceId)
        return true
    }

    /** The Mac disconnected or the feature went off: its request ends. */
    @Synchronized fun ended(deviceId: String): ScreenRequest? = open.remove(deviceId)
}
