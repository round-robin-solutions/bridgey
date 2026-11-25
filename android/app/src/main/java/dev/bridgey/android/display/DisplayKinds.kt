package dev.bridgey.android.display

/** The message kinds of Mac screen to phone (draft screen_control_draft1, docs/protocol.md). */
object DisplayKinds {
    const val REQUEST = "display.request"
    const val STATUS = "display.status"
    const val START = "display.start"
    const val STARTED = "display.started"
    const val FRAME = "display.frame"
    const val ACK = "display.ack"
    const val STATS = "display.stats"
    const val GEOMETRY = "display.geometry"
    const val CONTROL = "display.control"
    const val INPUT = "display.input"
    const val STOP = "display.stop"
}

/** One open request per Mac, at most one every 3 seconds; it expires after 2 minutes without a final answer. */
class DisplayRequests(private val clock: () -> Long) {
    data class Open(val deviceId: String, val requestId: String, val sentAtMillis: Long)

    private val open = mutableMapOf<String, Open>()
    private val lastAt = mutableMapOf<String, Long>()

    /** Whether a new request to [deviceId] may go now; records it when it may. */
    @Synchronized fun begin(deviceId: String, requestId: String): Boolean {
        val now = clock()
        open[deviceId]?.takeIf { now - it.sentAtMillis >= DisplayLimits.REQUEST_LIFETIME_MILLIS }?.let { open.remove(deviceId) }
        if (open.containsKey(deviceId)) return false
        val last = lastAt[deviceId]
        if (last != null && now - last < DisplayLimits.REQUEST_SPACING_MILLIS) return false
        lastAt[deviceId] = now
        open[deviceId] = Open(deviceId, requestId, now)
        return true
    }

    /** Milliseconds until a request to [deviceId] may go, 0 when it may go now (ignoring an open one). */
    @Synchronized fun waitMillis(deviceId: String): Long {
        val last = lastAt[deviceId] ?: return 0
        return (DisplayLimits.REQUEST_SPACING_MILLIS - (clock() - last)).coerceAtLeast(0)
    }

    /** The open request with this ID, if it has not expired. */
    @Synchronized fun current(deviceId: String, requestId: String): Open? {
        val request = open[deviceId]?.takeIf { it.requestId == requestId } ?: return null
        if (clock() - request.sentAtMillis >= DisplayLimits.REQUEST_LIFETIME_MILLIS) {
            open.remove(deviceId)
            return null
        }
        return request
    }

    /** The request got its final answer (a start, or a status other than waiting). True if it was open. */
    @Synchronized fun finish(deviceId: String, requestId: String): Boolean {
        if (open[deviceId]?.requestId != requestId) return false
        open.remove(deviceId)
        return true
    }

    /** The request expired: returns it once. */
    @Synchronized fun expired(deviceId: String): Open? {
        val request = open[deviceId] ?: return null
        if (clock() - request.sentAtMillis < DisplayLimits.REQUEST_LIFETIME_MILLIS) return null
        open.remove(deviceId)
        return request
    }

    /** The Mac disconnected or the person left: its request is forgotten. */
    @Synchronized fun ended(deviceId: String): Open? = open.remove(deviceId)
}

/** The last 16 ended stream IDs: a start that reuses one is ignored. */
class EndedStreams(private val capacity: Int = DisplayLimits.REMEMBERED_STREAMS) {
    private val ids = ArrayDeque<String>()

    @Synchronized fun remember(streamId: String) {
        ids.remove(streamId)
        ids.addLast(streamId)
        while (ids.size > capacity) ids.removeFirst()
    }

    @Synchronized operator fun contains(streamId: String): Boolean = streamId in ids
}
