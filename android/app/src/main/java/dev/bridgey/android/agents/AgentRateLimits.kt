package dev.bridgey.android.agents

/**
 * At most [limit] events per [windowMillis] per key (sliding window). [tryAcquire] counts the event and returns
 * null, or returns how long until one more would be allowed and counts nothing.
 */
class SlidingWindowLimiter(private val limit: Int, private val windowMillis: Long) {
    private val events = HashMap<String, ArrayDeque<Long>>()

    @Synchronized fun retryAfter(key: String, now: Long): Long? {
        val list = events.getOrPut(key, ::ArrayDeque)
        while (list.isNotEmpty() && now - list.first() >= windowMillis) list.removeFirst()
        if (list.size < limit) return null
        return (list.first() + windowMillis - now).coerceAtLeast(1)
    }

    @Synchronized fun record(key: String, now: Long) {
        events.getOrPut(key, ::ArrayDeque).addLast(now)
    }

    @Synchronized fun tryAcquire(key: String, now: Long): Long? = retryAfter(key, now) ?: run {
        record(key, now)
        null
    }

    @Synchronized fun forget(key: String) {
        events.remove(key)
    }
}

/** A burst of [capacity], refilled at one token every [refillMillis]. */
class TokenBucket(private val capacity: Int, private val refillMillis: Long) {
    private class State(var tokens: Double, var at: Long)
    private val states = HashMap<String, State>()

    private fun state(key: String, now: Long): State {
        val state = states.getOrPut(key) { State(capacity.toDouble(), now) }
        val elapsed = (now - state.at).coerceAtLeast(0)
        state.tokens = (state.tokens + elapsed.toDouble() / refillMillis).coerceAtMost(capacity.toDouble())
        state.at = now
        return state
    }

    @Synchronized fun retryAfter(key: String, now: Long): Long? {
        val state = state(key, now)
        if (state.tokens >= 1.0) return null
        return ((1.0 - state.tokens) * refillMillis).toLong().coerceAtLeast(1)
    }

    @Synchronized fun record(key: String, now: Long) {
        state(key, now).tokens -= 1.0
    }

    @Synchronized fun forget(key: String) {
        states.remove(key)
    }
}

/** What a limited action is, per docs/agent-cli.md section 8. */
enum class AgentAction { NOTIFY, NOTIFY_HIGH, ASK, RING, CLIP_SET, CLIP_GET, SEND, GRANT_REQUEST }

/**
 * The phone's limits per agent device (docs/agent-cli.md section 8): notify 30 an hour with a burst of 5 (high
 * priority also 10 an hour), ask 20 an hour, ring 3 per 10 minutes, clip set 60 an hour, clip get 10 an hour,
 * send 20 transfers an hour, grant requests 3 an hour. Pending limits (asks, clipboard requests, held code
 * queries) are counted where those live.
 */
class AgentRateLimits(private val clock: () -> Long = System::currentTimeMillis) {
    private val notifyHour = SlidingWindowLimiter(30, HOUR)
    private val notifyBurst = TokenBucket(5, HOUR / 30)
    private val notifyHigh = SlidingWindowLimiter(10, HOUR)
    private val ask = SlidingWindowLimiter(20, HOUR)
    private val ring = SlidingWindowLimiter(3, 10 * 60_000L)
    private val clipSet = SlidingWindowLimiter(60, HOUR)
    private val clipGet = SlidingWindowLimiter(10, HOUR)
    private val send = SlidingWindowLimiter(20, HOUR)
    private val grantRequests = SlidingWindowLimiter(3, HOUR)

    /** Counts one [action] by [deviceId] and returns null, or returns retryAfterMs and counts nothing. */
    @Synchronized fun acquire(deviceId: String, action: AgentAction): Long? {
        val now = clock()
        return when (action) {
            AgentAction.NOTIFY, AgentAction.NOTIFY_HIGH -> {
                val waits = listOfNotNull(
                    notifyHour.retryAfter(deviceId, now),
                    notifyBurst.retryAfter(deviceId, now),
                    if (action == AgentAction.NOTIFY_HIGH) notifyHigh.retryAfter(deviceId, now) else null,
                )
                if (waits.isNotEmpty()) return waits.max()
                notifyHour.record(deviceId, now)
                notifyBurst.record(deviceId, now)
                if (action == AgentAction.NOTIFY_HIGH) notifyHigh.record(deviceId, now)
                null
            }
            AgentAction.ASK -> ask.tryAcquire(deviceId, now)
            AgentAction.RING -> ring.tryAcquire(deviceId, now)
            AgentAction.CLIP_SET -> clipSet.tryAcquire(deviceId, now)
            AgentAction.CLIP_GET -> clipGet.tryAcquire(deviceId, now)
            AgentAction.SEND -> send.tryAcquire(deviceId, now)
            AgentAction.GRANT_REQUEST -> grantRequests.tryAcquire(deviceId, now)
        }
    }

    @Synchronized fun forget(deviceId: String) {
        listOf(notifyHour, notifyHigh, ask, ring, clipSet, clipGet, send, grantRequests).forEach { it.forget(deviceId) }
        notifyBurst.forget(deviceId)
    }

    private companion object {
        const val HOUR = 3_600_000L
    }
}
