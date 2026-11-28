package dev.bridgey.android

import kotlin.math.ceil
import kotlin.math.max

/** A notification as NotificationManager knows it: its tag and ID. */
internal data class NotificationKey(val tag: String?, val id: Int)

/** How soon a notification has to reach the shade. */
enum class NotificationUrgency {
    /** Status and progress: at most one update per notification per interval, within the app's ceiling. */
    NORMAL,

    /**
     * Prompts, calls, codes, pairing and final states: posted at once, unless Android would drop it as an update over
     * its rate, and then as soon as it would not.
     */
    IMMEDIATE,
}

/**
 * The throttle's limits, in Android's own measure (see [EnqueueRate]). Android drops updates once a package is over
 * 5 a second; the ceilings leave room below that.
 */
internal data class NotificationLimits(
    val ceilingPerSecond: Double = 4.0,
    val immediateCeilingPerSecond: Double = 4.5,
    val minIntervalMs: Long = 500,
)

/**
 * Android's estimate of a package's notification enqueue rate (RateEstimator in AOSP): an exponentially weighted mean
 * of the time between accepted enqueues, in seconds. NotificationManagerService checks it before each update and
 * drops the update when the rate an enqueue now would give is over 5 a second; every accepted enqueue, new
 * notification or update, moves it.
 */
internal class EnqueueRate(private var lastAt: Long?, private var interarrivalSeconds: Double) {
    /** The rate Android would see for an enqueue at [now] (milliseconds). */
    fun rateAt(now: Long): Double = lastAt?.let { 1.0 / estimate(now, it) } ?: 0.0

    fun record(now: Long) {
        lastAt?.let { interarrivalSeconds = estimate(now, it) }
        lastAt = now
    }

    /** The first moment at or after [now] when an enqueue would be seen at no more than [ceiling] a second. */
    fun allowedAt(now: Long, ceiling: Double): Long {
        val last = lastAt ?: return now
        val gapSeconds = (1.0 / ceiling - ALPHA * interarrivalSeconds) / (1.0 - ALPHA)
        if (gapSeconds <= MIN_GAP_SECONDS) return now
        return max(now, last + ceil(gapSeconds * 1000.0).toLong())
    }

    private fun estimate(now: Long, last: Long): Double =
        ALPHA * interarrivalSeconds + (1.0 - ALPHA) * max((now - last) / 1000.0, MIN_GAP_SECONDS)

    private companion object {
        const val ALPHA = 0.7
        const val MIN_GAP_SECONDS = 0.0005
    }
}

/**
 * Every notification post and removal of the app goes through one of these (AppNotifications), so the app stays under
 * the rate at which Android sheds notification updates ("Package enqueue rate is 5.2. Shedding ..." in the system
 * log, and the update is lost).
 *
 * - A new notification goes out at once: Android never sheds those.
 * - An update waits until its notification's last post is [NotificationLimits.minIntervalMs] old (or the interval
 *   given) and until the app's rate, measured as Android measures it, would stay at or under the ceiling. While it
 *   waits a newer update replaces it in its place in the queue: the latest state wins.
 * - An [NotificationUrgency.IMMEDIATE] update skips the interval and the queue of normal updates, and waits only while
 *   Android would shed it.
 * - A removal goes out at once and takes any waiting update for that notification with it, so a late update can never
 *   bring back a notification the app removed, and a transfer's final state stays final.
 *
 * Waiting updates go out in the order they first waited, immediate ones first, from [flush], which [wakeAt] asks to be
 * called at a clock time. [prepare] (building the notification) runs outside the throttle's lock, on the caller's
 * thread for a post made at once and in [flush] for a waiting one; [post] and [remove] (the calls to Android) run
 * under it. Each post takes a ticket when it is let go, and a post whose ticket is older than the last post or removal
 * Android has seen for that notification is dropped, so Android sees each notification's states in the order the app
 * made them.
 */
internal class NotificationThrottle<P, R : Any>(
    private val clock: () -> Long,
    private val wakeAt: (Long) -> Unit,
    private val prepare: (P) -> R?,
    private val post: (NotificationKey, R) -> Boolean,
    private val remove: (NotificationKey) -> Unit,
    private val limits: NotificationLimits = NotificationLimits(),
    shown: Collection<NotificationKey> = emptyList(),
) {
    private class Waiting<P>(var payload: P, var urgency: NotificationUrgency, var minIntervalMs: Long)

    private val lock = Any()
    private val shown = HashSet(shown)
    private val postedAt = HashMap<NotificationKey, Long>()
    private val waiting = LinkedHashMap<NotificationKey, Waiting<P>>()

    // Posts let go and not yet made, per notification, and the newest ticket Android has seen for each of those.
    private val inFlight = HashMap<NotificationKey, Int>()
    private val applied = HashMap<NotificationKey, Long>()
    private var tickets = 0L

    // Android's estimate from an earlier process of the app is not known here: start as if the app had just posted at
    // the ceiling, which costs at most a quarter of a second before the first update.
    private val rate = EnqueueRate(clock(), 1.0 / limits.ceilingPerSecond)
    private var wakeTime: Long? = null

    /**
     * Posts [payload] as [key] now, or keeps it until it may go. False only when a post made now failed (a waiting
     * update reports nothing).
     */
    fun notify(key: NotificationKey, payload: P, urgency: NotificationUrgency = NotificationUrgency.NORMAL, minIntervalMs: Long = limits.minIntervalMs): Boolean {
        val ticket = synchronized(lock) {
            val now = clock()
            val already = waiting[key]
            if (already != null) {
                already.payload = payload
                already.urgency = maxOf(already.urgency, urgency)
                already.minIntervalMs = minIntervalMs
            } else if (key in shown && (readyAt(key, urgency, minIntervalMs, now) > now || nextReady(now, urgency) != null)) {
                waiting[key] = Waiting(payload, urgency, minIntervalMs)
            } else {
                return@synchronized letGo(key, now)
            }
            scheduleLocked(now)
            return true
        }
        return send(key, ticket, payload)
    }

    /** Removes [key] now, with any update still waiting for it. */
    fun cancel(key: NotificationKey) = synchronized(lock) {
        waiting.remove(key)
        shown.remove(key)
        postedAt.remove(key)
        supersede(key)
        remove(key)
    }

    /** [key] was posted outside [notify] (Service.startForeground, which cannot wait): counted, and any waiting update dropped. */
    fun posted(key: NotificationKey) = synchronized(lock) {
        val now = clock()
        waiting.remove(key)
        supersede(key)
        rate.record(now)
        shown.add(key)
        postedAt[key] = now
    }

    /** The notifications the throttle has posted or is holding an update for. */
    fun known(): Set<NotificationKey> = synchronized(lock) { shown + waiting.keys }

    /** Posts every waiting update that may go now; called back through [wakeAt]. */
    fun flush() {
        synchronized(lock) { wakeTime = null }
        while (true) {
            val (key, ticket, payload) = synchronized(lock) {
                val now = clock()
                val key = nextReady(now, NotificationUrgency.NORMAL)
                val next = key?.let(waiting::remove)
                if (key == null || next == null) {
                    scheduleLocked(now)
                    return
                }
                Triple(key, letGo(key, now), next.payload)
            }
            send(key, ticket, payload)
        }
    }

    /** Counts a post Android is about to see and gives it its ticket. */
    private fun letGo(key: NotificationKey, now: Long): Long {
        rate.record(now)
        shown.add(key)
        postedAt[key] = now
        inFlight[key] = (inFlight[key] ?: 0) + 1
        return ++tickets
    }

    /** A removal or a foreground post reached Android: posts let go before it are now stale. */
    private fun supersede(key: NotificationKey) {
        if (key in inFlight) applied[key] = ++tickets
    }

    private fun send(key: NotificationKey, ticket: Long, payload: P): Boolean {
        val ready = prepare(payload)
        synchronized(lock) {
            val current = ticket > (applied[key] ?: 0L)
            val ok = when {
                !current -> true
                ready == null -> false
                else -> post(key, ready)
            }
            if (current) applied[key] = ticket
            val left = (inFlight[key] ?: 1) - 1
            if (left > 0) {
                inFlight[key] = left
            } else {
                inFlight.remove(key)
                applied.remove(key)
            }
            return ok
        }
    }

    private fun ceiling(urgency: NotificationUrgency) =
        if (urgency == NotificationUrgency.IMMEDIATE) limits.immediateCeilingPerSecond else limits.ceilingPerSecond

    private fun readyAt(key: NotificationKey, urgency: NotificationUrgency, minIntervalMs: Long, now: Long): Long {
        val own = if (urgency == NotificationUrgency.IMMEDIATE) now else (postedAt[key]?.plus(minIntervalMs) ?: now)
        return max(own, rate.allowedAt(now, ceiling(urgency)))
    }

    /** The first waiting update of at least [atLeast] urgency that may go at [now]: immediate ones first, then in order. */
    private fun nextReady(now: Long, atLeast: NotificationUrgency): NotificationKey? {
        for (urgency in listOf(NotificationUrgency.IMMEDIATE, NotificationUrgency.NORMAL)) {
            if (urgency < atLeast) break
            for ((key, entry) in waiting) {
                if (entry.urgency == urgency && readyAt(key, urgency, entry.minIntervalMs, now) <= now) return key
            }
        }
        return null
    }

    private fun scheduleLocked(now: Long) {
        if (waiting.isEmpty()) return
        val next = waiting.entries.minOf { (key, entry) -> readyAt(key, entry.urgency, entry.minIntervalMs, now) }
        val current = wakeTime
        if (current != null && current <= next) return
        wakeTime = next
        wakeAt(next)
    }
}
