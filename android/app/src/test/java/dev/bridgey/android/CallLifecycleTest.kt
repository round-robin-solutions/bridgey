package dev.bridgey.android

import android.app.Notification
import android.app.NotificationManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CallLifecycleTest {
    private class FakeScheduler : CallScheduler {
        private data class Task(val at: Long, val run: () -> Unit, var cancelled: Boolean = false)
        private val tasks = mutableListOf<Task>()
        var now = 0L

        override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
            val entry = Task(now + delayMs, task)
            tasks += entry
            return { entry.cancelled = true }
        }

        fun advance(ms: Long) {
            val until = now + ms
            while (true) {
                val next = tasks.filter { !it.cancelled && it.at <= until }.minByOrNull { it.at } ?: break
                tasks.remove(next)
                now = next.at
                next.run()
            }
            now = until
        }
    }

    private val scheduler = FakeScheduler()
    private var phone: String? = "incoming"
    private val ended = mutableListOf<Pair<String, String>>()
    private val lifecycle = CallLifecycle(
        scheduler = scheduler,
        telephonyState = { phone },
        endCall = { id, reason -> ended += id to reason },
    )

    private fun update(
        key: String,
        flags: Int = 0,
        category: String? = null,
        visibility: Int = Notification.VISIBILITY_PRIVATE,
        importance: Int? = NotificationManager.IMPORTANCE_HIGH,
        hasContent: Boolean = true,
    ) = NotificationUpdate(key, flags, category, visibility, importance, hasContent)

    private fun ringingDialerCall(): String {
        lifecycle.forwarded("call-id", "dialer-key", "dialer.app", telephony = true)
        return "call-id"
    }

    @Test fun unrelatedNotificationDuringCallLeavesTheCallAlone() {
        ringingDialerCall()

        val outcome = classifyNotificationUpdate(update("chat-key", category = Notification.CATEGORY_MESSAGE), lifecycle)

        assertEquals(UpdateOutcome.Forward(isCall = false), outcome)
        scheduler.advance(10_000)
        assertTrue(ended.isEmpty())
        assertTrue(lifecycle.isTracked("dialer-key"))
    }

    @Test fun callUpdateHittingEveryFilterKeepsTheCard() {
        ringingDialerCall()
        val filtered = mapOf(
            "group_summary" to update("dialer-key", flags = Notification.FLAG_GROUP_SUMMARY, category = Notification.CATEGORY_CALL),
            "secret" to update("dialer-key", category = Notification.CATEGORY_CALL, visibility = Notification.VISIBILITY_SECRET),
            "min_importance" to update("dialer-key", category = Notification.CATEGORY_CALL, importance = NotificationManager.IMPORTANCE_MIN),
            "empty" to update("dialer-key", category = Notification.CATEGORY_CALL, hasContent = false),
        )

        filtered.forEach { (reason, shape) ->
            assertEquals(reason, UpdateOutcome.KeepCall(reason), classifyNotificationUpdate(shape, lifecycle))
        }
        scheduler.advance(10_000)
        assertTrue(ended.isEmpty())
    }

    @Test fun sameFiltersStillRetractOrdinaryNotifications() {
        assertEquals(
            UpdateOutcome.Retract("ongoing"),
            classifyNotificationUpdate(update("music-key", flags = Notification.FLAG_ONGOING_EVENT), lifecycle),
        )
        assertEquals(UpdateOutcome.Retract("empty"), classifyNotificationUpdate(update("chat-key", hasContent = false), lifecycle))
        assertEquals(
            UpdateOutcome.Retract("group_summary"),
            classifyNotificationUpdate(update("chat-summary", flags = Notification.FLAG_GROUP_SUMMARY), lifecycle),
        )
    }

    // The reported bug: an AOSP-style dialer re-posts the ringing call under the same key as an
    // ongoing notification without CATEGORY_CALL (quiet incoming once its call screen shows).
    // Before, that update was retracted and the Mac lost the call card.
    @Test fun dialerQuietRepostWithoutCallCategoryStaysACall() {
        ringingDialerCall()

        val outcome = classifyNotificationUpdate(update("dialer-key", flags = Notification.FLAG_ONGOING_EVENT), lifecycle)

        assertEquals(UpdateOutcome.Forward(isCall = true), outcome)
        assertTrue(ended.isEmpty())
    }

    @Test fun untrackedOngoingNotificationWithoutCallCategoryIsNotACall() {
        assertEquals(
            UpdateOutcome.Retract("ongoing"),
            classifyNotificationUpdate(update("dialer-key", flags = Notification.FLAG_ONGOING_EVENT), lifecycle),
        )
    }

    @Test fun dialerKeyChangeContinuesTheSameCard() {
        val id = ringingDialerCall()

        assertEquals(id, lifecycle.notificationRemoved("dialer-key"))
        scheduler.advance(400)
        assertEquals(id, lifecycle.callIdFor("dialer-key-2", "dialer.app", freshId = "fresh"))
        lifecycle.forwarded(id, "dialer-key-2", "dialer.app", telephony = true)
        scheduler.advance(10_000)

        assertTrue(ended.isEmpty())
        assertTrue(lifecycle.isTracked("dialer-key-2"))
        assertFalse(lifecycle.isTracked("dialer-key"))
    }

    @Test fun repostUnderTheSameKeyAfterRemovalKeepsTheCard() {
        val id = ringingDialerCall()
        phone = null

        lifecycle.notificationRemoved("dialer-key")
        assertEquals(id, lifecycle.callIdFor("dialer-key", "dialer.app", freshId = "fresh"))
        scheduler.advance(10_000)

        assertTrue(ended.isEmpty())
    }

    @Test fun anotherAppsCallIsNotMergedIntoTheCard() {
        ringingDialerCall()
        lifecycle.notificationRemoved("dialer-key")

        assertEquals("fresh", lifecycle.callIdFor("voip-key", "voip.app", freshId = "fresh"))
    }

    @Test fun removedNotificationWithoutRepostEndsAfterGraceWhenPhoneIsIdle() {
        lifecycle.forwarded("voip-id", "voip-key", "voip.app", telephony = false)

        lifecycle.notificationRemoved("voip-key")
        scheduler.advance(CallLifecycle.REKEY_GRACE_MS - 1)
        assertTrue(ended.isEmpty())
        scheduler.advance(1)

        assertEquals(listOf("voip-id" to "notification_removed"), ended)
    }

    @Test fun dialerNotificationGoneWhilePhoneStillInCallKeepsTheCardUntilIdle() {
        val id = ringingDialerCall()
        phone = "ongoing"

        lifecycle.notificationRemoved("dialer-key")
        scheduler.advance(10_000)
        assertTrue(ended.isEmpty())

        phone = "idle"
        lifecycle.telephonyChanged("idle")
        scheduler.advance(CallLifecycle.IDLE_DEBOUNCE_MS)
        assertEquals(listOf(id to "phone_idle"), ended)
    }

    @Test fun removalWhilePhoneIsIdleEndsAtOnce() {
        val id = ringingDialerCall()
        phone = "idle"

        lifecycle.notificationRemoved("dialer-key")

        assertEquals(listOf(id to "removed_phone_idle"), ended)
    }

    @Test fun idleGlitchShorterThanDebounceKeepsTheCard() {
        ringingDialerCall()

        phone = "idle"
        lifecycle.telephonyChanged("idle")
        scheduler.advance(CallLifecycle.IDLE_DEBOUNCE_MS / 2)
        phone = "incoming"
        lifecycle.telephonyChanged("incoming")
        scheduler.advance(10_000)

        assertTrue(ended.isEmpty())
    }

    @Test fun idleCallbackWhilePhoneAlreadyRingsAgainKeepsTheCard() {
        ringingDialerCall()

        lifecycle.telephonyChanged("idle")
        phone = "incoming"
        scheduler.advance(CallLifecycle.IDLE_DEBOUNCE_MS)

        assertTrue(ended.isEmpty())
    }

    @Test fun sustainedIdleEndsOnlyTelephonyCalls() {
        val id = ringingDialerCall()
        lifecycle.forwarded("voip-id", "voip-key", "voip.app", telephony = false)

        phone = "idle"
        lifecycle.telephonyChanged("idle")
        scheduler.advance(CallLifecycle.IDLE_DEBOUNCE_MS)

        assertEquals(listOf(id to "phone_idle"), ended)
        assertTrue(lifecycle.isTracked("voip-key"))
    }

    @Test fun dialerUpdateThatIsNoLongerACallStaysWhileThePhoneRings() {
        ringingDialerCall()

        assertEquals(UpdateOutcome.KeepCall("not_call"), classifyNotificationUpdate(update("dialer-key"), lifecycle))
        assertTrue(ended.isEmpty())
    }

    @Test fun appCallThatTurnsIntoAMissedCallNotificationEnds() {
        lifecycle.forwarded("voip-id", "voip-key", "voip.app", telephony = false)

        val outcome = classifyNotificationUpdate(update("voip-key", category = Notification.CATEGORY_MISSED_CALL), lifecycle)

        assertEquals(UpdateOutcome.Forward(isCall = false), outcome)
        assertEquals(listOf("voip-id" to "not_call"), ended)
    }

    @Test fun forgottenCallIsNoLongerTracked() {
        val id = ringingDialerCall()
        lifecycle.notificationRemoved("dialer-key")

        lifecycle.forget(id)
        scheduler.advance(10_000)

        assertTrue(ended.isEmpty())
        assertNull(lifecycle.notificationRemoved("dialer-key"))
    }

    @Test fun registryNeverEvictsACallInProgress() {
        val registry = ForwardedNotificationRegistry(limit = 2, isPinned = { it == "call" })
        registry.record("call", "call-key", "dialer.app")
        registry.record("one", "one-key", "chat.app")
        registry.record("two", "two-key", "chat.app")
        registry.record("three", "three-key", "chat.app")

        assertEquals("call-key", registry.systemKey("call"))
        assertNull(registry.systemKey("one"))
        assertEquals("call-key", registry.removeNotificationId("call"))
    }
}
