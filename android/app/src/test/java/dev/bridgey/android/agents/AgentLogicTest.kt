package dev.bridgey.android.agents

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

/** Grants and their windows, the rate limits, the codes broker, the activity list and questions. */
class AgentLogicTest {
    private val zone = ZoneId.of("Asia/Kolkata")
    private var now = ZonedDateTime.of(2026, 11, 3, 15, 40, 0, 0, zone).toInstant().toEpochMilli()
    private val hour = 3_600_000L

    // MARK: windows and grants

    @Test fun windowsEnd() {
        assertEquals(now + hour, GrantWindow.HOUR.expiresAt(now, zone))
        assertEquals(now + 7 * 24 * hour, GrantWindow.WEEK.expiresAt(now, zone))
        assertNull(GrantWindow.FOREVER.expiresAt(now, zone))
        // Today ends at the next midnight on the phone.
        assertEquals(ZonedDateTime.of(2026, 11, 4, 0, 0, 0, 0, zone).toInstant().toEpochMilli(), GrantWindow.TODAY.expiresAt(now, zone))
        assertEquals(listOf("1h", "today", "7d", "forever"), GrantWindow.entries.map { it.wire })
    }

    private fun book(store: GrantStore = MemoryGrantStore()) = AgentGrantBook(store, { now }, { zone })

    @Test fun everyGrantStartsOff() {
        val grants = book()
        AgentGrant.entries.forEach { assertFalse(grants.isOn("agent", it)) }
        assertTrue(grants.views("agent", "Download/Bridgey/A").all { it.state == GrantShown.OFF })
        assertEquals(AgentGrant.entries, grants.views("agent", "").map { it.grant })
    }

    @Test fun aWindowEndsOnUseAndOnExpiry() {
        val grants = book()
        assertTrue(grants.set("agent", AgentGrant.NOTIFY, on = true, window = GrantWindow.HOUR))
        assertTrue(grants.isOn("agent", AgentGrant.NOTIFY))
        assertEquals(now + hour, grants.nextChangeAt())
        val view = grants.views("agent", "").first { it.grant == AgentGrant.NOTIFY }
        assertEquals(GrantShown.ON, view.state)
        assertEquals(GrantWindow.HOUR, view.window)
        assertEquals(now, view.grantedAt)
        assertEquals(now + hour, view.expiresAt)
        now += hour
        // Checked on use: off the moment the window ends, before the timer runs.
        assertFalse(grants.isOn("agent", AgentGrant.NOTIFY))
        val ended = grants.expireDue()
        assertEquals(listOf(ExpiredGrant("agent", AgentGrant.NOTIFY, GrantWindow.HOUR)), ended)
        assertTrue(grants.expireDue().isEmpty())
        assertNull(grants.nextChangeAt())
    }

    @Test fun foreverAndOff() {
        val grants = book()
        grants.set("agent", AgentGrant.FILES, on = true, window = GrantWindow.FOREVER)
        now += 400 * 24 * hour
        assertTrue(grants.isOn("agent", AgentGrant.FILES))
        assertEquals("Download/Bridgey/A", grants.views("agent", "Download/Bridgey/A").first { it.grant == AgentGrant.FILES }.scope)
        assertTrue(grants.set("agent", AgentGrant.FILES, on = false, window = null))
        assertFalse(grants.isOn("agent", AgentGrant.FILES))
        assertFalse("nothing changed", grants.set("agent", AgentGrant.FILES, on = false, window = null))
    }

    @Test fun notificationsCannotBeGranted() {
        val grants = book()
        assertFalse(grants.set("agent", AgentGrant.NOTIFICATIONS, on = true, window = GrantWindow.FOREVER))
        assertFalse(grants.isOn("agent", AgentGrant.NOTIFICATIONS))
        assertFalse("on needs a window", grants.set("agent", AgentGrant.ASK, on = true, window = null))
    }

    @Test fun waitingForTwentyFourHours() {
        val grants = book()
        grants.set("agent", AgentGrant.NOTIFY, on = true, window = GrantWindow.FOREVER)
        val marked = grants.markWaiting("agent", listOf(AgentGrant.NOTIFY, AgentGrant.CODES, AgentGrant.NOTIFICATIONS))
        assertEquals(listOf(AgentGrant.CODES), marked)
        assertEquals(GrantShown.WAITING, grants.views("agent", "").first { it.grant == AgentGrant.CODES }.state)
        assertFalse(grants.isOn("agent", AgentGrant.CODES))
        now += GRANT_WAITING_MILLIS
        assertTrue(grants.expireDue().isEmpty())
        assertEquals(GrantShown.OFF, grants.views("agent", "").first { it.grant == AgentGrant.CODES }.state)
    }

    @Test fun grantsSurviveARestart() {
        val store = MemoryGrantStore()
        val first = book(store)
        first.set("agent", AgentGrant.RING, on = true, window = GrantWindow.TODAY)
        first.markWaiting("agent", listOf(AgentGrant.CODES))
        val second = book(MemoryGrantStore(store.saved))
        assertTrue(second.isOn("agent", AgentGrant.RING))
        assertEquals(GrantShown.WAITING, second.views("agent", "").first { it.grant == AgentGrant.CODES }.state)
        second.forget("agent")
        assertFalse(second.isOn("agent", AgentGrant.RING))
    }

    @Test fun presetsNeverIncludeCodes() {
        assertEquals(listOf(AgentGrant.NOTIFY, AgentGrant.ASK), GrantPreset.MESSAGES.grants)
        assertEquals(listOf(AgentGrant.FILES), GrantPreset.FILES.grants)
        assertEquals(listOf(AgentGrant.RING, AgentGrant.BATTERY), GrantPreset.FIND.grants)
        assertTrue(GrantPreset.entries.none { AgentGrant.CODES in it.grants })
    }

    // MARK: rate limits

    @Test fun notifyBurstThenHourly() {
        val limits = AgentRateLimits { now }
        repeat(5) { assertNull(limits.acquire("agent", AgentAction.NOTIFY)) }
        val wait = limits.acquire("agent", AgentAction.NOTIFY)
        assertNotNull(wait)
        assertTrue(wait!! in 1..(hour / 30))
        // Another agent has its own limits.
        assertNull(limits.acquire("other", AgentAction.NOTIFY))
        now += hour / 30
        assertNull(limits.acquire("agent", AgentAction.NOTIFY))
        // 30 an hour in all: one every two minutes keeps under the burst, and the 31st within the hour is refused.
        repeat(24) {
            now += hour / 30
            assertNull(limits.acquire("agent", AgentAction.NOTIFY))
        }
        now += hour / 30
        assertNotNull(limits.acquire("agent", AgentAction.NOTIFY))
    }

    @Test fun highPriorityTenAnHour() {
        val limits = AgentRateLimits { now }
        repeat(10) {
            assertNull(limits.acquire("agent", AgentAction.NOTIFY_HIGH))
            now += 6 * 60_000
        }
        now -= 6 * 60_000
        assertNotNull(limits.acquire("agent", AgentAction.NOTIFY_HIGH))
    }

    @Test fun ringThreePerTenMinutes() {
        val limits = AgentRateLimits { now }
        val start = now
        repeat(3) {
            assertNull(limits.acquire("agent", AgentAction.RING))
            now += 60_000
        }
        assertEquals(start + 10 * 60_000 - now, limits.acquire("agent", AgentAction.RING))
        now = start + 10 * 60_000
        assertNull(limits.acquire("agent", AgentAction.RING))
    }

    @Test fun otherLimits() {
        val limits = AgentRateLimits { now }
        mapOf(AgentAction.ASK to 20, AgentAction.CLIP_SET to 60, AgentAction.CLIP_GET to 10, AgentAction.SEND to 20, AgentAction.GRANT_REQUEST to 3)
            .forEach { (action, limit) ->
                repeat(limit) { assertNull("$action $it", limits.acquire("agent", action)) }
                assertNotNull("$action over $limit", limits.acquire("agent", action))
            }
        now += hour
        assertNull(limits.acquire("agent", AgentAction.GRANT_REQUEST))
    }

    // MARK: codes broker

    private fun found(code: String, service: String, posted: Long, source: CodeSource = CodeSource.SMS, app: String = "messages") =
        CodeFound("01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d22", code, service, service.lowercase(), source, app, "n", posted)

    private fun query(service: String? = null, since: Long = CODES_SINCE_MAX_MILLIS, newerThan: Long? = null, latestOnly: Boolean = false, wait: Long = 0) =
        CodesQuery("01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d21", service, since, newerThan, wait, latestOnly)

    @Test fun foldedByServiceAndCode() {
        val broker = CodesBroker { now }
        broker.add(found("482913", "HDFC Bank", now))
        broker.add(found("482913", "HDFC Bank", now, CodeSource.EMAIL, "gmail"))
        broker.add(found("482913", "HDFC Bank", now))
        val answer = broker.answer(query())
        assertEquals(1, answer.codes.size)
        assertEquals(listOf("sms", "email:gmail"), answer.codes.single().via)
    }

    @Test fun latestAndReplacedNewestFirst() {
        val broker = CodesBroker { now }
        broker.add(found("119204", "HDFC Bank", now - 60_000))
        broker.add(found("482913", "HDFC Bank", now))
        broker.add(found("G-555123", "Google", now - 30_000, CodeSource.EMAIL, "gmail"))
        val all = broker.answer(query()).codes
        assertEquals(listOf("482913", "G-555123", "119204"), all.map { it.code })
        assertEquals(listOf(true, true, false), all.map { it.latest })
        assertEquals(listOf(false, false, true), all.map { it.replaced })
        assertEquals(listOf("482913", "G-555123"), broker.answer(query(latestOnly = true)).codes.map { it.code })
        // The service matches case-insensitively, by name or key.
        assertEquals(listOf("482913", "119204"), broker.answer(query(service = "hdfc BANK")).codes.map { it.code })
        assertEquals(listOf("482913"), broker.answer(query(newerThan = now - 30_000)).codes.map { it.code })
        assertEquals(listOf("482913", "G-555123"), broker.answer(query(since = 45_000)).codes.map { it.code })
        assertEquals("HDFC Bank", broker.answer(query(service = "HDFC Bank")).service("HDFC Bank"))
    }

    @Test fun keptFifteenMinutesAndAtMostFifty() {
        val broker = CodesBroker { now }
        broker.add(found("482913", "HDFC Bank", now))
        now += CODE_KEEP_MILLIS
        assertEquals(0, broker.size())
        repeat(60) { broker.add(found("1000${it + 10}", "S$it", now + it)) }
        assertEquals(CODE_KEEP_MAX, broker.size())
        // The oldest ones went.
        assertTrue(broker.answer(query(service = "S0")).codes.isEmpty())
        assertEquals(CODES_RESULT_MAX, broker.answer(query()).codes.size)
    }

    @Test fun heldQueries() {
        val broker = CodesBroker { now }
        val waiting = query(service = "HDFC Bank", wait = 120_000).copy(queryId = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d31")
        assertTrue(broker.hold("agent", waiting))
        assertTrue(broker.hold("agent", waiting.copy(queryId = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d32")))
        assertFalse("two held per agent", broker.hold("agent", waiting.copy(queryId = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d33")))
        assertTrue(broker.hold("other", waiting))
        assertTrue("another service answers nothing", broker.add(found("555123", "Google", now)).isEmpty())
        val answered = broker.add(found("482913", "HDFC Bank", now))
        assertEquals(3, answered.size)
        assertEquals(0, broker.heldCount("agent"))
        assertTrue(broker.hold("agent", waiting))
        assertNotNull(broker.release("agent", waiting.queryId))
        assertNull(broker.release("agent", waiting.queryId))
    }

    // MARK: activity

    @Test fun activityLimitsAndExport() {
        val directory = kotlin.io.path.createTempDirectory("audit").toFile()
        try {
            val log = AgentAuditLog(directory) { now }
            log.record("agent", AuditAction.PAIR, AuditOutcome.OK)
            log.record("agent", AuditAction.NOTIFY, AuditOutcome.DELIVERED, "t".repeat(200))
            assertEquals(AUDIT_DETAIL_MAX_CHARS, log.entries("agent").first().detail!!.length)
            assertEquals(AuditAction.NOTIFY, log.entries("agent").first().action)
            // Read back from the file by a new log.
            assertEquals(2, AgentAuditLog(directory) { now }.entries("agent").size)
            val export = JSONObject(log.exportJson("agent", "Contabo Europe"))
            assertEquals("Contabo Europe", export.getJSONObject("device").getString("name"))
            assertEquals(2, export.getJSONArray("entries").length())
            now += AUDIT_MAX_AGE_MILLIS + 1
            log.record("agent", AuditAction.RING, AuditOutcome.DELIVERED)
            assertEquals(listOf(AuditAction.RING), log.entries("agent").map { it.action })
            repeat(AUDIT_MAX_ENTRIES + 5) { log.record("agent", AuditAction.PING, AuditOutcome.DELIVERED) }
            assertEquals(AUDIT_MAX_ENTRIES, log.entries("agent").size)
            log.clear("agent")
            assertTrue(log.entries("agent").isEmpty())
            assertTrue(AgentAuditLog(directory) { now }.entries("agent").isEmpty())
        } finally {
            directory.deleteRecursively()
        }
    }

    // MARK: questions

    private fun ask(askId: String, deviceId: String = "agent") = AskRecord(
        deviceId, askId, "Deploy?", null, listOf(AskOption("approve", "Approve")), false, null, true,
        expiresAt = now + hour, from = null, postedAt = now, notificationId = askId.hashCode(),
    )

    @Test fun questionsEndAndAreKeptADay() {
        val file = kotlin.io.path.createTempFile("asks", ".json").toFile()
        try {
            val asks = AgentAskBook(file) { now }
            asks.add(ask("a1"))
            asks.add(ask("a2"))
            asks.add(ask("b1", "other"))
            assertEquals(2, asks.openCount("agent"))
            assertEquals(3, asks.openCount())
            assertNotNull(asks.end("agent", "a1", AskState.ANSWERED, option = "approve"))
            assertNull("ends once", asks.end("agent", "a1", AskState.DISMISSED))
            assertEquals(listOf("a1"), asks.endedFor("agent").map { it.askId })
            // A restart keeps the answer for the next session.
            val again = AgentAskBook(file) { now }
            assertEquals("approve", again.get("agent", "a1")?.option)
            now += hour
            assertEquals(listOf("a2"), again.expiredOpen().filter { it.deviceId == "agent" }.map { it.askId })
            again.end("agent", "a2", AskState.EXPIRED)
            now += ASK_KEEP_MILLIS + 1
            assertTrue(again.endedFor("agent").isEmpty())
            assertEquals(1, again.forget("other").size)
        } finally {
            file.delete()
        }
    }

    // MARK: what goes to an agent

    @Test fun thePhonePushesNothingOfItsOwnToAnAgent() {
        listOf("clipboard.update", "clipboard.rich", "clipboard.offer", "notifications.post", "files.offer", "settings.update", "sms.threads",
            "focus.state", "updates.status", "codes.status", "find.start", "ping.request", "media.state", "quick.request")
            .forEach { assertFalse(it, phoneMaySendToAgent(it)) }
        listOf("features.update", "agent.grants", "agent.request_result", "ask.answer", "codes.result", "clipboard.response", "battery.update",
            "find.started", "ping.ack", "clipboard.ack", "files.accept", "connect.setup")
            .forEach { assertTrue(it, phoneMaySendToAgent(it)) }
    }

    @Test fun anAgentReachesOnlyItsKinds() {
        listOf("sms.send", "settings.update", "input.key", "screen.request", "camera.request", "actions.result", "notifications.action",
            "calls.request", "files.list", "places.list", "codes.found", "agents.grant_set")
            .forEach { assertFalse(it, agentMaySend(it)) }
        listOf("agent.hello", "notify.post", "ask.request", "codes.query", "clipboard.update", "find.start", "ping.request", "files.offer")
            .forEach { assertTrue(it, agentMaySend(it)) }
    }

    @Test fun folderNames() {
        assertEquals("rr-dev-1 agent", agentFolderName("rr-dev-1 agent"))
        assertEquals("a_b_c", agentFolderName("a/b\\c"))
        assertEquals("Agent", agentFolderName(".."))
    }

    @Test fun boundedClipboard() {
        assertEquals("hi" to "<b>hi</b>", boundedClip("hi", "<b>hi</b>"))
        val long = "x".repeat(CLIPBOARD_RESPONSE_MAX_BYTES - 2)
        assertEquals(long to null, boundedClip(long, "<b>more</b>"))
        val tooLong = "é".repeat(CLIPBOARD_RESPONSE_MAX_BYTES)
        val (text, html) = boundedClip(tooLong, null)
        assertNull(html)
        assertTrue(text.toByteArray().size <= CLIPBOARD_RESPONSE_MAX_BYTES)
        assertNotNull(clipboardResponsePayload("01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d21", ClipResponseStatus.SENT, text))
    }
}
