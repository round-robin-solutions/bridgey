package dev.bridgey.android.agents

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.AgentSessionOutbox
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Synthetic phone data only. No Bridgey application, paired device, account or live clipboard access. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class AgentHubAuthorizationTest {
    private data class Delivery(val device: String, val session: String?, val kind: String, val body: JSONObject)
    private class Link : AgentTransport {
        val sessions = linkedMapOf("a" to "a-original", "b" to "b-original")
        val delivered = CopyOnWriteArrayList<Delivery>()
        var beforeEnqueue: (() -> Unit)? = null
        var outbox: AgentSessionOutbox? = null
        var snapshot = AgentNotificationsSnapshot(available = false)
        var snapshotReads = 0
        var duringSnapshot: (() -> Unit)? = null
        override fun notificationSnapshot(limit: Int): AgentNotificationsSnapshot {
            snapshotReads++
            duringSnapshot?.invoke()
            return snapshot
        }
        override fun send(deviceId: String, kind: String, payload: ByteArray) = true
        override fun currentSessionToken(deviceId: String) = sessions[deviceId]
        override fun sendIfCurrent(deviceId: String, sessionToken: String, kind: String, payload: ByteArray): Boolean {
            beforeEnqueue?.invoke()
            if (sessions[deviceId] != sessionToken) return false
            outbox?.let { return it.enqueue(kind, payload) }
            delivered += Delivery(deviceId, sessionToken, kind, JSONObject(String(payload, Charsets.UTF_8)))
            return true
        }
        override fun connectedAgents() = sessions.keys.toList()
        override fun mirrorMacs() = emptyList<String>()
        override fun readerLinks() = emptyList<ReaderLink>()
        override fun deviceName(deviceId: String) = "Synthetic $deviceId"
        override fun agentIds() = listOf("a", "b")
        override fun route(deviceId: String) = "test"
        override fun refreshFeatures(deviceId: String) = Unit
        override fun stopRing(deviceId: String) = Unit
    }
    private lateinit var context: Context
    private lateinit var scope: CoroutineScope
    private lateinit var hub: AgentHub
    private lateinit var link: Link
    private var now = 1_800_000_000_000L

    @Before fun prepare() {
        context = ApplicationProvider.getApplicationContext<Application>()
        context.getSharedPreferences("bridgey.agents", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("bridgey.agents.grants", Context.MODE_PRIVATE).edit().clear().commit()
        context.noBackupFilesDir.resolve("agents").deleteRecursively()
        context.getSystemService(NotificationManager::class.java).cancelAll()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        link = Link()
        hub = AgentHub(context, scope, link, { now }, { now })
    }
    @After fun close() { scope.cancel() }
    private fun id() = UUID.randomUUID().toString()
    private fun grant(device: String, grant: AgentGrant, window: GrantWindow = GrantWindow.FOREVER) = hub.setGrant(device, grant, true, window)
    private fun receive(device: String, kind: String, payload: JSONObject, session: String = link.sessions.getValue(device), messageId: String = id()) =
        hub.receive(device, session, kind, messageId, payload.put("version", 1).toString().toByteArray())
    private fun query(device: String, queryId: String = id(), waitMs: Long = 600_000) {
        receive(device, AgentKinds.CODES_QUERY, JSONObject().put("queryId", queryId).put("sinceMs", 600_000)
            .put("waitMs", waitMs).put("latestOnly", false))
    }
    private fun found() {
        hub.receiveFromMac("synthetic-mac", "Synthetic Mac", AgentKinds.CODES_FOUND, JSONObject()
            .put("version", 1).put("foundId", id()).put("code", "654321").put("service", "Example")
            .put("serviceKey", "example").put("source", "sms").put("app", "messages")
            .put("notificationId", "synthetic-notification").put("postedAt", now).toString().toByteArray())
    }
    private fun codeDeliveries() = link.delivered.filter { it.kind == AgentKinds.CODES_RESULT }
    private fun clipRequest(device: String, requestId: String = id()): String {
        receive(device, AgentKinds.CLIPBOARD_REQUEST, JSONObject().put("requestId", requestId).put("expiresAt", now + 60_000))
        val prefix = "agent-clip:$device:"
        return context.getSystemService(NotificationManager::class.java).activeNotifications
            .single { it.tag.startsWith(prefix) }.tag.removePrefix(prefix)
    }

    @Test fun revokingOneReaderCancelsItsWaitWhileAnotherReaderReceives() {
        grant("a", AgentGrant.CODES); grant("b", AgentGrant.CODES)
        query("a"); query("b")
        hub.setGrant("a", AgentGrant.CODES, false, null)
        found()
        assertEquals(listOf("b"), codeDeliveries().map { it.device })
        assertEquals(0, hub.codes.heldCount("a"))
    }

    @Test fun revocationSettlesOriginalWaitWithPayloadFreeBoundDenial() {
        grant("a", AgentGrant.CODES); grant("b", AgentGrant.CODES)
        val originalRef = id()
        receive("a", AgentKinds.CODES_QUERY, JSONObject().put("queryId", id()).put("sinceMs", 600_000)
            .put("waitMs", 600_000).put("latestOnly", false), messageId = originalRef)
        query("b")
        hub.setGrant("a", AgentGrant.CODES, false, null)
        val denial = link.delivered.single { it.device == "a" }
        assertEquals("a-original", denial.session)
        assertEquals(AgentKinds.REQUEST_RESULT, denial.kind)
        assertEquals(originalRef, denial.body.getString("ref"))
        assertEquals(AgentStatus.NOT_GRANTED, denial.body.getString("status"))
        assertFalse(denial.body.has("codes")); assertFalse(denial.body.has("text"))
        found()
        assertEquals(listOf("b"), codeDeliveries().map { it.device })
    }

    @Test fun revokingOldWaitCannotSendDenialToReplacementSession() {
        grant("a", AgentGrant.CODES); query("a")
        link.sessions["a"] = "a-replacement"
        hub.setGrant("a", AgentGrant.CODES, false, null)
        assertTrue(link.delivered.isEmpty())
    }

    @Test fun expiryIsEnforcedAtUseEvenBeforeExpiryAlarm() {
        grant("a", AgentGrant.CODES, GrantWindow.HOUR); grant("b", AgentGrant.CODES)
        query("a"); query("b")
        now += 3_600_000
        found()
        assertEquals(listOf("b"), codeDeliveries().map { it.device })
        hub.checkExpiry()
        assertEquals(0, hub.codes.heldCount("a"))
    }

    @Test fun identicalQueryIdsOnDifferentServersCancelIndependently() {
        grant("a", AgentGrant.CODES); grant("b", AgentGrant.CODES)
        val same = id(); query("a", same); query("b", same)
        receive("a", AgentKinds.CODES_CANCEL, JSONObject().put("queryId", same))
        assertEquals(0, hub.codes.heldCount("a")); assertEquals(1, hub.codes.heldCount("b"))
        found()
        assertEquals(listOf("b"), codeDeliveries().map { it.device })
    }

    @Test fun identicalQueryIdsKeepIndependentTimeoutJobs() {
        scope.cancel()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        hub = AgentHub(context, scope, link, { now }, { now })
        val main = shadowOf(Looper.getMainLooper())
        main.idle()
        grant("a", AgentGrant.CODES); grant("b", AgentGrant.CODES)
        val same = id(); query("a", same, 100); query("b", same, 200)
        main.idle()
        main.idleFor(101, TimeUnit.MILLISECONDS)
        assertEquals(listOf("a"), codeDeliveries().map { it.device })
        main.idleFor(100, TimeUnit.MILLISECONDS)
        assertEquals(listOf("a", "b"), codeDeliveries().map { it.device })
        assertTrue(codeDeliveries().all { it.body.getBoolean("timedOut") })
    }

    @Test fun oldSessionDisconnectDoesNotCancelReplacementQuery() {
        grant("a", AgentGrant.CODES); query("a")
        link.sessions["a"] = "a-replacement"
        hub.sessionStarted("a", "a-replacement")
        query("a")
        hub.sessionEnded("a", "a-original")
        found()
        assertEquals(listOf("a-replacement"), codeDeliveries().map { it.session })
    }

    @Test fun replacementWithoutStartCallbackCannotReceiveOldWait() {
        grant("a", AgentGrant.CODES); query("a")
        link.sessions["a"] = "a-replacement"
        found()
        assertTrue(codeDeliveries().isEmpty())
    }

    @Test fun disconnectCancelsOnlyThatSessionsQueriesAndClipboardApprovals() {
        grant("a", AgentGrant.CODES); grant("b", AgentGrant.CODES)
        grant("a", AgentGrant.CLIPBOARD_REQUEST); grant("b", AgentGrant.CLIPBOARD_REQUEST)
        query("a"); query("b")
        val aAction = clipRequest("a"); val bAction = clipRequest("b")
        link.sessions.remove("a")
        hub.sessionEnded("a", "a-original")
        assertEquals(0, hub.codes.heldCount("a")); assertEquals(1, hub.codes.heldCount("b"))
        assertFalse(hub.clipboardPending("a", aAction)); assertTrue(hub.clipboardPending("b", bAction))
        var reads = 0
        hub.clipboardReadAndSend("a", aAction) { reads++; "synthetic" to null }
        assertEquals(0, reads)
        found()
        assertEquals(listOf("b"), codeDeliveries().map { it.device })
    }

    @Test fun delayedMessageFromOldSessionIsIgnored() {
        grant("a", AgentGrant.CODES)
        link.sessions["a"] = "a-replacement"
        receive("a", AgentKinds.CODES_QUERY, JSONObject().put("queryId", id()).put("sinceMs", 600_000)
            .put("waitMs", 600_000).put("latestOnly", false), session = "a-original")
        assertEquals(0, hub.codes.heldCount("a"))
    }

    @Test fun clipboardRevocationPreventsEvenForegroundRead() {
        grant("a", AgentGrant.CLIPBOARD_REQUEST)
        val action = clipRequest("a")
        hub.setGrant("a", AgentGrant.CLIPBOARD_REQUEST, false, null)
        var reads = 0
        hub.clipboardReadAndSend("a", action) { reads++; "synthetic private clipboard" to null }
        assertEquals(0, reads)
        assertFalse(hub.clipboardPending("a", action))
        assertTrue(link.delivered.none { it.kind == AgentKinds.CLIPBOARD_RESPONSE })
    }

    @Test fun clipboardExpiryPreventsForegroundReadWithoutAlarm() {
        grant("a", AgentGrant.CLIPBOARD_REQUEST)
        val action = clipRequest("a")
        now += 60_000
        var reads = 0
        hub.clipboardReadAndSend("a", action) { reads++; "synthetic" to null }
        assertEquals(0, reads)
        assertTrue(link.delivered.isEmpty())
    }

    @Test fun oldApprovalCannotAuthorizeReusedWireIdOnNewSession() {
        grant("a", AgentGrant.CLIPBOARD_REQUEST)
        val wireId = id(); val oldAction = clipRequest("a", wireId)
        link.sessions["a"] = "a-replacement"; hub.sessionStarted("a", "a-replacement")
        // Give the abandoned action an expired deadline too; the replacement has a fresh deadline.
        now += 61_000
        val newAction = clipRequest("a", wireId)
        assertNotEquals(oldAction, newAction)
        hub.sessionEnded("a", "a-original")
        var reads = 0
        hub.clipboardReadAndSend("a", oldAction) { reads++; "stale" to null }
        assertEquals(0, reads); assertTrue(hub.clipboardPending("a", newAction))
        hub.clipboardReadAndSend("a", newAction) { "fresh synthetic clipboard" to null }
        val sent = link.delivered.single { it.kind == AgentKinds.CLIPBOARD_RESPONSE }
        assertEquals("a-replacement", sent.session)
        assertEquals(wireId, sent.body.getString("requestId"))
        assertEquals("fresh synthetic clipboard", sent.body.getString("text"))
    }

    @Test fun clipboardAuthorityIsRecheckedAfterReadBeforeSend() {
        grant("a", AgentGrant.CLIPBOARD_REQUEST)
        val action = clipRequest("a")
        hub.clipboardReadAndSend("a", action) {
            hub.setGrant("a", AgentGrant.CLIPBOARD_REQUEST, false, null)
            "synthetic private clipboard" to null
        }
        assertTrue(link.delivered.none { it.kind == AgentKinds.CLIPBOARD_RESPONSE })
    }

    @Test fun clipboardReplacementDuringReadNeverSendsToNewConnection() {
        grant("a", AgentGrant.CLIPBOARD_REQUEST)
        val action = clipRequest("a")
        hub.clipboardReadAndSend("a", action) {
            link.sessions["a"] = "a-replacement"
            "synthetic private clipboard" to null
        }
        assertTrue(link.delivered.isEmpty())
    }

    @Test fun revokeAndCodeEnqueueShareOneAuthorityBoundary() {
        grant("a", AgentGrant.CODES); query("a")
        val entered = CountDownLatch(1); val allowSend = CountDownLatch(1); val revokeStarted = CountDownLatch(1)
        val order = CopyOnWriteArrayList<String>()
        link.beforeEnqueue = {
            entered.countDown()
            check(allowSend.await(5, TimeUnit.SECONDS))
            order += "send"
        }
        val sender = thread { found() }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val revoker = thread {
            revokeStarted.countDown()
            hub.setGrant("a", AgentGrant.CODES, false, null)
            order += "revoke"
        }
        assertTrue(revokeStarted.await(5, TimeUnit.SECONDS))
        allowSend.countDown(); sender.join(5_000); revoker.join(5_000)
        assertFalse(sender.isAlive); assertFalse(revoker.isAlive)
        assertEquals(listOf("send", "revoke"), order.toList())
        link.beforeEnqueue = null
        query("a")
        assertEquals(1, codeDeliveries().size)
    }

    @Test fun stalledSessionWriterCannotBlockGrantRevocation() {
        val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val revoked = CountDownLatch(1)
        val outbox = AgentSessionOutbox(ioScope, write = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); true
        })
        link.outbox = outbox
        try {
            grant("a", AgentGrant.CODES); query("a"); found()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val revoker = thread {
                hub.setGrant("a", AgentGrant.CODES, false, null)
                revoked.countDown()
            }
            assertTrue("grant revocation finishes while writer remains stalled", revoked.await(5, TimeUnit.SECONDS))
            assertFalse(hub.isOn("a", AgentGrant.CODES))
            release.countDown(); revoker.join(5_000)
        } finally {
            outbox.close(); release.countDown(); ioScope.cancel()
        }
    }

    @Test fun successfulClipboardAndCodeAuditsContainNoPrivatePayload() {
        grant("a", AgentGrant.CODES); query("a"); found()
        grant("a", AgentGrant.CLIPBOARD_REQUEST)
        val action = clipRequest("a")
        hub.clipboardReadAndSend("a", action) { "synthetic private clipboard" to null }
        val audit = hub.audit.exportJson("a", "Synthetic A")
        assertFalse(audit.contains("654321")); assertFalse(audit.contains("synthetic private clipboard"))
        assertEquals(2, link.delivered.size)
    }

    @Test fun productionBrokerExpiresCodesAcrossAndroidDeepSleep() {
        val broker = CodesBroker()
        val nowMillis = System.currentTimeMillis()
        broker.add(CodeFound(id(), "654321", "Synthetic", "synthetic", CodeSource.SMS, "messages", "fixture", nowMillis))
        val query = CodesQuery(id(), null, 3_600_000, null, 0, false)
        assertEquals(1, broker.answer(query).codes.size)
        val uptime = android.os.SystemClock.uptimeMillis()
        org.robolectric.shadows.ShadowSystemClock.simulateDeepSleep(java.time.Duration.ofMinutes(20))
        assertEquals("sleep does not advance the awake clock", uptime, android.os.SystemClock.uptimeMillis())
        assertTrue("retention counts time spent asleep", broker.answer(query).codes.isEmpty())
    }

    private fun notifications(device: String = "a") = receive(device, AgentKinds.NOTIFICATIONS_QUERY, JSONObject().put("queryId", id()).put("limit", 5))
    private fun notificationSnapshot() = AgentNotificationsSnapshot(true, listOf(
        AgentNotification("synthetic-id", "example.package", "Synthetic app", "Private synthetic title", "Private synthetic body", now),
    ))

    @Test fun notifyGrantDoesNotGrantReadingAndMissingReadGrantNeverTouchesSource() {
        grant("a", AgentGrant.NOTIFY)
        link.snapshot = notificationSnapshot()
        notifications()
        assertEquals(0, link.snapshotReads)
        assertTrue(link.delivered.isEmpty())
        assertFalse(hub.featureValues("a").getValue("notifications"))
        assertFalse(hub.featureValues("a").getValue(AGENT_NOTIFICATIONS_FEATURE_KEY))
    }

    @Test fun readGrantReturnsOneBoundSnapshotWithoutPrivateAuditContent() {
        grant("a", AgentGrant.NOTIFICATIONS)
        link.snapshot = notificationSnapshot()
        notifications()
        val result = link.delivered.single()
        assertEquals(AgentKinds.NOTIFICATIONS_RESULT, result.kind)
        assertEquals("ok", result.body.getString("status"))
        assertEquals("Private synthetic body", result.body.getJSONArray("notifications").getJSONObject(0).getString("text"))
        assertTrue(hub.featureValues("a").getValue(AGENT_NOTIFICATIONS_FEATURE_KEY))
        assertFalse(hub.featureValues("a").getValue("notifications"))
        val audit = hub.audit.exportJson("a", "Synthetic A")
        assertFalse(audit.contains("Private synthetic")); assertFalse(audit.contains("example.package"))
    }

    @Test fun grantedReadWithoutListenerReturnsUnavailable() {
        grant("a", AgentGrant.NOTIFICATIONS)
        notifications()
        val result = link.delivered.single().body
        assertEquals("unavailable", result.getString("status"))
        assertEquals(0, result.getJSONArray("notifications").length())
    }

    @Test fun expiryOrReplacementDuringSnapshotDropsResult() {
        grant("a", AgentGrant.NOTIFICATIONS, GrantWindow.HOUR)
        link.snapshot = notificationSnapshot()
        link.duringSnapshot = { now += 3_600_000 }
        notifications()
        assertTrue(link.delivered.isEmpty())
        grant("a", AgentGrant.NOTIFICATIONS)
        link.duringSnapshot = { link.sessions["a"] = "replacement" }
        notifications()
        assertTrue(link.delivered.isEmpty())
    }

    @Test fun grantRevokedDuringSnapshotDropsResult() {
        grant("a", AgentGrant.NOTIFICATIONS)
        link.snapshot = notificationSnapshot()
        link.duringSnapshot = { hub.setGrant("a", AgentGrant.NOTIFICATIONS, false, null) }
        notifications()
        assertTrue(link.delivered.isEmpty())
    }

}
