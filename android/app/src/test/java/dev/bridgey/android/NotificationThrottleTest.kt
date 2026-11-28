package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * The notification throttle against a model of Android's own check (NotificationManagerService with RateEstimator,
 * copied here on its own so the throttle's estimate is not checked against itself). Plain JVM: a fake clock, and the
 * wake-up the throttle asks for runs when the test's time passes it.
 */
class NotificationThrottleTest {
    /**
     * Android's side: which notifications are up, its rate estimate, the rate each enqueue met and every update it shed.
     * It starts where the throttle assumes an earlier process left it: a post just now, at 4 a second (a fresh
     * RateEstimator would be far more lenient).
     */
    private class AndroidModel(start: Long) {
        private var last: Long? = start
        private var interarrival = 0.25 // seconds
        val up = mutableMapOf<NotificationKey, String>()
        val seen = mutableListOf<Pair<NotificationKey, Double>>()
        var shed = 0
        var accepted = 0

        private fun estimate(now: Long, last: Long) = 0.7 * interarrival + 0.3 * maxOf((now - last) / 1000.0, 0.0005)
        fun rate(now: Long) = last?.let { 1.0 / estimate(now, it) } ?: 0.0

        fun enqueue(now: Long, key: NotificationKey, payload: String) {
            seen += key to rate(now)
            if (key in up && !payload.endsWith(COMPLETE) && rate(now) > 5.0) {
                shed++
                return
            }
            last?.let { interarrival = estimate(now, it) }
            last = now
            accepted++
            up[key] = payload
        }

        fun cancel(key: NotificationKey) {
            up.remove(key)
        }
    }

    private var now = 10_000L
    private var wake: Long? = null
    private val android = AndroidModel(now)
    private val log = mutableListOf<Triple<Long, NotificationKey, String?>>()
    private val throttle = NotificationThrottle<String, String>(
        clock = { now },
        wakeAt = { wake = it },
        prepare = { building(it) },
        post = { key, payload -> log += Triple(now, key, payload); android.enqueue(now, key, payload); true },
        remove = { key -> log += Triple(now, key, null); android.cancel(key) },
    )

    /** Runs while a notification is built, outside the throttle's lock: what another thread does meanwhile. */
    private var building: (String) -> String = { it }

    /** Moves the clock to [until], running each wake-up the throttle asked for on the way. */
    private fun advance(until: Long) {
        while (true) {
            val at = wake ?: break
            if (at > until) break
            now = maxOf(now, at)
            wake = null
            throttle.flush()
        }
        now = until
    }

    private fun key(id: Int, tag: String? = null) = NotificationKey(tag, id)
    private fun posts(key: NotificationKey) = log.filter { it.second == key && it.third != null }

    @Test fun aBurstOfUpdatesBecomesOnePostOfTheLatest() {
        val status = key(42_458)
        throttle.notify(status, "waiting")
        // Five collectors and a status change, each re-posting within the same moment, then 50 progress ticks.
        repeat(55) { i -> now += 2; throttle.notify(status, "state $i") }
        assertEquals("the first post goes out at once", listOf("waiting"), posts(status).map { it.third })
        advance(now + 5_000)
        assertEquals(listOf("waiting", "state 54"), posts(status).map { it.third })
        assertTrue("the update waited its interval", posts(status)[1].first - posts(status)[0].first >= 500)
        assertEquals(0, android.shed)
    }

    @Test fun newNotificationsAndPromptsDoNotWait() {
        val status = key(1)
        throttle.notify(status, "a")
        now += 10
        throttle.notify(status, "b") // waits for its interval
        // A received file and a phone control prompt: new notifications go out on the spot.
        throttle.notify(key(2), "received photo.jpg")
        throttle.notify(key(3), "control prompt", NotificationUrgency.IMMEDIATE)
        assertEquals(listOf(key(1), key(2), key(3)), log.map { it.second })
        // An update to a prompt skips the interval and the queue of status updates: "b" still waits for the app's
        // ceiling, the prompt goes as soon as Android would take it.
        advance(now + 600)
        throttle.notify(key(3), "control prompt again", NotificationUrgency.IMMEDIATE)
        assertEquals("control prompt again", log.last().third)
        assertEquals("a", android.up[status])
        advance(now + 2_000)
        assertEquals("b", android.up[status])
        assertEquals(0, android.shed)
    }

    @Test fun anImmediateUpdateWaitsOnlyWhileAndroidWouldShedIt() {
        // Twelve new notifications in one moment push Android's estimate far over 5 a second.
        repeat(12) { throttle.notify(key(100 + it), "file $it") }
        val prompt = key(7)
        throttle.notify(prompt, "ask", NotificationUrgency.IMMEDIATE)
        now += 5
        throttle.notify(prompt, "ask, updated", NotificationUrgency.IMMEDIATE)
        assertEquals("over the limit it waits", "ask", android.up[prompt])
        advance(now + 3_000)
        assertEquals("ask, updated", posts(prompt).last().third)
        // It went out as soon as the rate allowed, just under 4.5 a second, not at the 4 that status updates wait for.
        val met = android.seen.last { it.first == prompt }.second
        assertTrue("rate met $met", met > 4.0 && met <= 4.5)
        assertEquals(0, android.shed)
    }

    @Test fun removalIsImmediateAndNoWaitingUpdateBringsTheNotificationBack() {
        val transfer = key(50_123)
        throttle.notify(transfer, "photo.jpg 10%")
        now += 100
        throttle.notify(transfer, "photo.jpg 60%")
        now += 100
        throttle.notify(transfer, "photo.jpg 99%")
        // Done: the progress notification goes, at once.
        throttle.cancel(transfer)
        assertEquals(null, log.last().third)
        val removedAt = log.size
        advance(now + 10_000)
        assertEquals("nothing after the removal", removedAt, log.size)
        assertTrue(transfer !in android.up)
        // The same ID later is a new notification again, posted at once.
        throttle.notify(transfer, "next file 0%")
        assertEquals("next file 0%", android.up[transfer])
    }

    @Test fun aFinalStateReplacesWaitingProgressAndGoesFirst() {
        val paste = key(50_124)
        val status = key(1)
        throttle.notify(status, "connected")
        throttle.notify(paste, "paste 5%")
        now += 20
        throttle.notify(status, "connected, sending")
        throttle.notify(paste, "paste 40%")
        throttle.notify(paste, "paste 100% $COMPLETE", NotificationUrgency.IMMEDIATE)
        advance(now + 3_000)
        assertEquals(listOf("paste 5%", "paste 100% $COMPLETE"), posts(paste).map { it.third })
        assertEquals("connected, sending", android.up[status])
        val final = posts(paste).last().first
        assertTrue("the final state is not held behind the status update", posts(status).last().first >= final)
    }

    @Test fun waitingUpdatesGoOutInTheOrderTheyFirstWaited() {
        val keys = (1..4).map { key(it) }
        keys.forEach { throttle.notify(it, "first") }
        now += 10
        keys.reversed().forEach { throttle.notify(it, "second") } // 4, 3, 2, 1 wait in that order
        throttle.notify(key(3), "third") // replaces 3's update in its place
        now += 10
        throttle.notify(key(9), "new") // not waiting: new
        throttle.notify(key(9), "prompt update", NotificationUrgency.IMMEDIATE)
        advance(now + 10_000)
        val updates = log.filter { it.third in setOf("second", "third", "prompt update") }
        assertEquals(listOf(key(9), key(4), key(3), key(2), key(1)), updates.map { it.second })
        assertEquals("third", android.up[key(3)])
        assertEquals(0, android.shed)
    }

    @Test fun aPostOvertakenWhileItIsBuiltIsDropped() {
        val transfer = key(50_200)
        val status = key(1)
        throttle.notify(status, "connected")
        // While the progress notification is being built, the transfer ends on another thread.
        building = { payload -> if (payload == "photo.jpg 40%") throttle.cancel(transfer); payload }
        throttle.notify(transfer, "photo.jpg 40%")
        assertTrue("the removal won", transfer !in android.up)
        assertEquals(listOf<String?>(null), log.filter { it.second == transfer }.map { it.third })
        // An older post finishing after a newer one does not overwrite it either.
        var nested = false
        building = { payload ->
            if (payload == "connected, old" && !nested) {
                nested = true
                now += 2_000
                throttle.notify(status, "connected, new", NotificationUrgency.IMMEDIATE)
            }
            payload
        }
        now += 2_000
        throttle.notify(status, "connected, old")
        assertEquals("connected, new", android.up[status])
        assertEquals(listOf("connected", "connected, new"), posts(status).map { it.third })
        assertEquals(0, android.shed)
    }

    @Test fun startForegroundCountsAndReplacesAWaitingUpdate() {
        val service = key(42_458)
        throttle.notify(service, "a")
        now += 10
        throttle.notify(service, "b")
        throttle.posted(service) // startForeground with the latest state
        advance(now + 5_000)
        assertEquals("the waiting update was dropped", listOf("a"), posts(service).map { it.third })
        assertTrue(service in throttle.known())
    }

    @Test fun theAppStaysUnderAndroidsRateWithSoakTraffic() {
        // The soak's mix for ten minutes, as the app's code paths make it. Without the throttle Android sheds updates;
        // through it, none, and every notification ends in the last state the app gave it.
        fun run(throttled: Boolean): Pair<AndroidModel, Map<NotificationKey, String?>> {
            val model = AndroidModel(0)
            val wanted = mutableMapOf<NotificationKey, String?>()
            var t = 0L
            var pendingWake: Long? = null
            val subject = NotificationThrottle<String, String>(
                clock = { t },
                wakeAt = { pendingWake = it },
                prepare = { it },
                post = { key, payload -> model.enqueue(t, key, payload); true },
                remove = model::cancel,
            )
            fun notify(key: NotificationKey, payload: String, urgency: NotificationUrgency = NotificationUrgency.NORMAL, interval: Long = 500) {
                wanted[key] = payload
                if (throttled) subject.notify(key, payload, urgency, interval) else model.enqueue(t, key, payload)
            }
            fun cancel(key: NotificationKey) {
                wanted[key] = null
                if (throttled) subject.cancel(key) else model.cancel(key)
            }
            val random = Random(7)
            val status = key(42_458)
            val transfers = mutableMapOf<NotificationKey, Int>()
            var nextFile = 0
            var tick = 0
            notify(status, "waiting")
            while (t < 10 * 60_000) {
                t += 20
                tick++
                while (true) {
                    val at = pendingWake ?: break
                    if (at > t) break
                    pendingWake = null
                    subject.flush()
                }
                // A connection event: five collectors re-post the connection notification.
                if (random.nextInt(100) < 4) repeat(5) { notify(status, "status $tick.$it") }
                // Clipboard every few seconds: a status refresh.
                if (tick % 200 == 0) notify(status, "clip $tick")
                // Batches of 8 to 32 small files: progress, done, a received-file notification each.
                if (random.nextInt(1_000) < 3) repeat(8 + random.nextInt(25)) {
                    val k = key(50_000 + (nextFile++ % 4_000))
                    notify(k, "file $nextFile 0%")
                    transfers[k] = 0
                }
                if (random.nextInt(1_000) < 5) {
                    val k = key(50_000 + (nextFile++ % 4_000))
                    notify(k, "big $nextFile 0%")
                    transfers[k] = 0
                }
                for ((k, done) in transfers.toMap()) {
                    val next = done + 1 + random.nextInt(6)
                    if (next >= 100 || random.nextInt(2_000) == 0) {
                        transfers.remove(k)
                        cancel(k)
                        notify(key(90_000 + nextFile++), "received")
                    } else {
                        transfers[k] = next
                        notify(k, "progress $next%", interval = 1_000)
                    }
                }
                // Now and then a prompt, and its update.
                if (random.nextInt(5_000) == 0) {
                    notify(key(69_600), "control prompt $tick", NotificationUrgency.IMMEDIATE)
                    notify(key(69_600), "control prompt $tick, again", NotificationUrgency.IMMEDIATE)
                }
            }
            // Traffic stops; whatever waits goes out.
            repeat(500) {
                t += 20
                val at = pendingWake
                if (at != null && at <= t) { pendingWake = null; subject.flush() }
            }
            return model to wanted
        }
        val (before, _) = run(throttled = false)
        assertTrue("the traffic is enough for Android to shed (${before.shed} shed of ${before.accepted + before.shed})", before.shed > 0)
        val (after, wanted) = run(throttled = true)
        assertEquals("updates shed with the throttle", 0, after.shed)
        for ((k, payload) in wanted) assertEquals("final state of $k", payload, after.up[k])
    }

    private companion object {
        /** A payload standing for a notification whose progress bar is complete (Android never sheds those). */
        const val COMPLETE = "[complete]"
    }
}
