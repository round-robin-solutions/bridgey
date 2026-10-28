package dev.bridgey.android.sms

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SmsProtocolTest {
    private fun sms(id: Long, date: Long, body: String = "hi", thread: Long = 1) =
        SmsMessage("s$id", thread, SmsDirection.IN, SmsStatus.RECEIVED, date, "+15550100", body)

    private fun mms(id: Long, date: Long, thread: Long = 1) =
        SmsMessage("m$id", thread, SmsDirection.IN, SmsStatus.RECEIVED, date, "+15550100", "", parts = listOf(SmsPart("p$id", "image/jpeg")))

    @Test fun providerColumnsMapToDirectionAndStatus() {
        assertEquals(SmsDirection.IN to SmsStatus.RECEIVED, smsDirectionStatus(1, -1))
        assertEquals(SmsDirection.OUT to SmsStatus.DELIVERED, smsDirectionStatus(2, 0))
        assertEquals(SmsDirection.OUT to SmsStatus.SENT, smsDirectionStatus(2, 32))
        assertEquals(SmsDirection.OUT to SmsStatus.SENT, smsDirectionStatus(2, -1))
        assertEquals(SmsDirection.OUT to SmsStatus.FAILED, smsDirectionStatus(2, 64))
        assertEquals(SmsDirection.OUT to SmsStatus.PENDING, smsDirectionStatus(4, -1))
        assertEquals(SmsDirection.OUT to SmsStatus.PENDING, smsDirectionStatus(6, -1))
        assertEquals(SmsDirection.OUT to SmsStatus.FAILED, smsDirectionStatus(5, -1))
        assertNull("drafts are never shown", smsDirectionStatus(3, -1))
        assertEquals(SmsDirection.IN to SmsStatus.RECEIVED, mmsDirectionStatus(1))
        assertEquals(SmsDirection.OUT to SmsStatus.SENT, mmsDirectionStatus(2))
        assertNull(mmsDirectionStatus(3))
    }

    @Test fun longBodiesAreCutWithoutSplittingAnEmoji() {
        val body = "a".repeat(3_999) + "😀" + "b"
        val json = sms(1, 1, body).toJson()
        assertEquals(3_999, json.getString("body").length)
        assertTrue(json.getBoolean("truncated"))
        assertFalse(sms(1, 1, "short").toJson().has("truncated"))
    }

    @Test fun conversationPagesAreNewestFirstAndExclusive() {
        val all = listOf(sms(1, 100), sms(2, 200), mms(3, 200), sms(4, 300))
        val (first, moreFirst) = conversationPage(all, null, 2, tablesFull = false)
        assertEquals(listOf("s4", "s2"), first.map { it.id })
        assertTrue(moreFirst)
        val (second, moreSecond) = conversationPage(all, first.last().key, 2, tablesFull = false)
        assertEquals("same date: ordered by id, nothing skipped or repeated", listOf("m3", "s1"), second.map { it.id })
        assertFalse(moreSecond)
    }

    @Test fun syncCursorNeverSkipsARow() {
        val since = SmsCursor(10, 5)
        val smsRows = (11L..20L).map { sms(it, it * 10) }
        val mmsRows = (6L..8L).map { mms(it, it * 25) }
        val page = syncPage(since, smsRows, mmsRows, limit = 6, budget = 40_000, tablesFull = false)
        assertEquals(6, page.messages.size)
        assertTrue(page.more)
        val included = page.messages.map { it.getString("id") }
        // Each table contributes a prefix of its own rows.
        val smsIds = included.filter { it.startsWith("s") }.map { it.drop(1).toLong() }
        val mmsIds = included.filter { it.startsWith("m") }.map { it.drop(1).toLong() }
        assertEquals((11L until 11L + smsIds.size).toList(), smsIds.sorted())
        assertEquals((6L until 6L + mmsIds.size).toList(), mmsIds.sorted())
        assertEquals(SmsCursor(smsIds.maxOrNull() ?: 10, mmsIds.maxOrNull() ?: 5), page.cursor)
    }

    @Test fun syncPagesStayUnderTheBudget() {
        val rows = (1L..50L).map { sms(it, it, "x".repeat(2_000)) }
        val page = syncPage(SmsCursor(0, 0), rows, emptyList(), limit = 200, budget = 10_000, tablesFull = false)
        assertTrue(page.messages.isNotEmpty())
        assertTrue(page.more)
        assertTrue(page.messages.sumOf { it.toString().length + 1 } <= 10_000)
        assertEquals(page.messages.size.toLong(), page.cursor.sms)
    }

    @Test fun syncResetsWhenAheadOrTooFarBehind() {
        assertEquals(SyncPlan.Read, planSync(SmsCursor(5, 5), SmsCursor(10, 5), 5))
        assertEquals(SyncPlan.Reset, planSync(SmsCursor(11, 5), SmsCursor(10, 5), 0))
        assertEquals(SyncPlan.Reset, planSync(SmsCursor(5, 6), SmsCursor(10, 5), 0))
        assertEquals(SyncPlan.Reset, planSync(SmsCursor(0, 0), SmsCursor(5_000, 0), 5_000))
        assertEquals(SyncPlan.Read, planSync(SmsCursor(0, 0), SmsCursor(1_000, 0), 1_000))
    }

    @Test fun fitEntriesKeepsAtLeastOne() {
        val big = JSONObject().put("x", "y".repeat(500))
        val (kept, cut) = fitEntries(listOf(big, big), 100)
        assertEquals(1, kept.size)
        assertTrue(cut)
        val (all, more) = fitEntries(listOf(big), 10_000)
        assertEquals(1, all.size)
        assertFalse(more)
    }

    @Test fun pagesFitTheFrame() {
        val base = pageBase("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293").put("messages", org.json.JSONArray()).put("more", true)
        val room = pageRoom(base)
        val entries = (1L..200L).map { sms(it, it, "Привет 😀 ".repeat(300)).toJson() }
        val (kept, cut) = fitEntries(entries, room)
        assertTrue(cut)
        val page = pageBase("5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293").put("messages", org.json.JSONArray(kept)).put("more", true)
        assertTrue(page.toString().toByteArray().size <= SmsLimits.PAGE_MAX_BYTES)
    }

    @Test fun sendLimiterAllowsOnePerSecondAndThirtyInTenMinutes() {
        var now = 0L
        val limiter = SmsSendLimiter { now }
        assertTrue(limiter.allow("mac"))
        assertFalse("within a second", limiter.allow("mac"))
        assertTrue("another Mac has its own budget", limiter.allow("other"))
        repeat(29) {
            now += 1_000
            assertTrue(limiter.allow("mac"))
        }
        now += 1_000
        assertFalse("31st within ten minutes", limiter.allow("mac"))
        now = 600_000
        assertTrue(limiter.allow("mac"))
    }

    @Test fun changesAreDebouncedAndSpaced() {
        val throttle = ChangeThrottle(debounce = 1_000, spacing = 2_000)
        assertEquals(1_000, throttle.delayFor(0))
        throttle.sent(1_000)
        assertEquals(1_500, throttle.delayFor(1_500))
        assertEquals(1_000, throttle.delayFor(10_000))
    }

    @Test fun addressesAreNormalised() {
        assertEquals("+919876543210", normalizeSmsAddress("+91 98765-43210"))
        assertEquals("0225550101", normalizeSmsAddress("(022) 555.0101"))
        assertNull(normalizeSmsAddress("HDFCBK"))
        assertNull(normalizeSmsAddress("55+50100"))
        assertTrue(sameNumber("+919876543210", "9876543210"))
        assertFalse(sameNumber("+919876543210", "543210"))
    }

    @Test fun notificationsMatchTheirConversation() {
        val t = 1_000_000_000L
        val candidates = listOf(
            InboxCandidate(7, "+919876543210", "See you at 6", t - 2_000, "Anna"),
            InboxCandidate(9, "+15550100", "Your code is 482913", t - 1_000),
            InboxCandidate(11, "+15550199", "Old message", t - 3_600_000, "Bob"),
        )
        assertEquals(7L, matchNotificationThread("Anna", "See you at 6", t, candidates))
        assertEquals("by the body even when the title is a name the phone does not know", 9L, matchNotificationThread("HDFC", "Your code is 482913", t, candidates))
        assertEquals("by the name", 7L, matchNotificationThread("Anna", "2 new messages", t, candidates))
        assertEquals("by the number", 9L, matchNotificationThread("+1 555 0100", "hidden", t, candidates))
        assertEquals("an ellipsis cut", 9L, matchNotificationThread("x", "Your code is…", t, candidates))
        assertNull("too old", matchNotificationThread("Bob", "Old message", t, candidates))
    }

    /**
     * Android 15 hides the sender and text from a listener that is not linked (seen on the API 35
     * emulator with Google Messages, whose Notification.when is the provider's date even on re-posts).
     */
    @Test fun hiddenNotificationsMatchByTheirOwnTimestamp() {
        val t = 1_000_000_000L
        val hidden = "Sensitive notification content hidden"
        val inbox = listOf(
            InboxCandidate(1, "+15551234", "Can you bring the tickets?", t + 960_000),
            InboxCandidate(2, "+15559876", "Your OTP is 482913", t + 3_000),
            InboxCandidate(1, "+15551234", "Lunch at 1?", t),
        )
        // The older conversation's notification is re-posted when the newer message arrives: it keeps its own time.
        assertEquals(2L, matchNotificationThread("", hidden, t + 960_200, inbox, messageTime = t + 3_000))
        assertEquals(1L, matchNotificationThread("", hidden, t + 960_200, inbox, messageTime = t + 960_000))
        assertEquals("an app that stamps the post time", 1L, matchNotificationThread("", hidden, t + 960_200, inbox, messageTime = t + 960_200))
        assertNull("no timestamp", matchNotificationThread("", hidden, t + 960_200, inbox))
        assertNull("nothing that close", matchNotificationThread("", hidden, t + 960_200, inbox, messageTime = t + 500_000))
        val close = listOf(InboxCandidate(1, "+15551234", "A", t), InboxCandidate(2, "+15559876", "B", t + 1_000))
        assertNull("two conversations within 1.5 seconds", matchNotificationThread("", hidden, t, close, messageTime = t))
    }

    @Test fun aRepostKeepsTheConversationFoundBefore() {
        SmsNotificationTargets.clear()
        SmsNotificationTargets.record(SmsNotificationTarget("n1", "", "hidden", 1, 7, null))
        SmsNotificationTargets.record(SmsNotificationTarget("n1", "", "hidden", 2, null, null))
        assertEquals(7L, SmsNotificationTargets.get("n1")?.threadId)
        assertEquals(2L, SmsNotificationTargets.get("n1")?.postTime)
        SmsNotificationTargets.clear()
    }

    @Test fun sendStatusCarriesAReasonOnlyWhenItFailed() {
        val id = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"
        assertFalse(smsSendStatusPayload(id, SendState.SENT, SendReason.GROUP).has("reason"))
        assertEquals("group", smsSendStatusPayload(id, SendState.REFUSED, SendReason.GROUP).getString("reason"))
        assertEquals("app", smsSendStatusPayload(id, SendState.SENT, via = SendVia.APP).getString("via"))
    }

    @Test fun threadsAreBounded() {
        val thread = SmsThread(3, (1..12).map { SmsParticipant("+1555010$it", if (it == 1) "Anna" else null) }, "s".repeat(300), 5, 2, subId = -1)
        val json = thread.toJson()
        assertEquals(10, json.getJSONArray("participants").length())
        assertEquals("Anna", json.getJSONArray("participants").getJSONObject(0).getString("name"))
        assertFalse(json.getJSONArray("participants").getJSONObject(1).has("name"))
        assertEquals(160, json.getString("snippet").length)
        assertFalse(json.has("subId"))
    }

    private fun target(id: String, thread: Long?, markRead: String?) =
        SmsNotificationTarget(id, "Anna", "See you", 1_000, thread, replyToken = null, markReadToken = markRead)

    @Test fun markReadRunsTheAppsOwnActionOnEveryNotificationOfTheConversation() {
        val ran = mutableListOf<String>()
        val targets = listOf(target("n1", 12, "t1"), target("n2", 12, "t2"), target("n3", 7, null), target("n4", null, "t4"))
        val results = markReadResults(listOf(12L, 7L, 3L, 12L), targets) { id, token -> ran += "$id:$token"; true }
        assertEquals(listOf(12L to MarkReadResult.MARKED, 7L to MarkReadResult.NO_ACTION, 3L to MarkReadResult.NOT_SHOWN), results)
        assertEquals("an unmatched notification is never marked", listOf("n1:t1", "n2:t2"), ran)
    }

    @Test fun markReadSaysFailedOnlyWhenAndroidRefusedEveryAction() {
        val targets = listOf(target("n1", 12, "t1"), target("n2", 12, "t2"))
        assertEquals(listOf(12L to MarkReadResult.MARKED), markReadResults(listOf(12L), targets) { id, _ -> id == "n2" })
        assertEquals(listOf(12L to MarkReadResult.FAILED), markReadResults(listOf(12L), targets) { _, _ -> false })
    }

    @Test fun markReadAndBlockedNumbersPayloads() {
        val id = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"
        val payload = smsMarkReadResultPayload(id, listOf(12L to MarkReadResult.MARKED, 7L to MarkReadResult.NOT_SHOWN))
        assertEquals(1, payload.getInt("version"))
        assertFalse(payload.has("error"))
        assertEquals("not_shown", payload.getJSONArray("results").getJSONObject(1).getString("result"))
        assertEquals("disabled", smsMarkReadResultPayload(id, emptyList(), "disabled").getString("error"))
        assertTrue(smsMarkReadResultPayload(id, (1L..60L).map { it to MarkReadResult.MARKED }).toString().toByteArray().size <= SmsLimits.MARK_READ_RESULT_MAX_BYTES)
        assertEquals("notified", smsBlockedNumbersResultPayload(id, BlockedNumbersResult.NOTIFIED).getString("result"))
    }

    @Test fun markReadAndBlockedNumbersAreRequestsFromTheMac() {
        assertTrue(SmsKinds.MARK_READ in SmsKinds.fromMac)
        assertTrue(SmsKinds.BLOCKED_NUMBERS in SmsKinds.fromMac)
        val request = decodeSmsRequest(SmsKinds.MARK_READ, JSONObject().put("version", 1).put("requestId", "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293")
            .put("threadIds", org.json.JSONArray(listOf(3, 3, 4))).toString().toByteArray())
        assertEquals(listOf(3L, 4L), (request as SmsRequest.MarkRead).threadIds)
    }
}
