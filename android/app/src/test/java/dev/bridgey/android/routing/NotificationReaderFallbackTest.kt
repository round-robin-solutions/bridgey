package dev.bridgey.android.routing

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.agents.*
import dev.bridgey.android.codes.CodeRelay
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
class NotificationReaderFallbackTest {
    private val mac = ReaderLink(agent = false, smsCodes = true, notifiedHere = true, mirror = true)

    private class Transport(private val detector: Boolean) : AgentTransport {
        val sent = mutableListOf<String>()
        override fun send(deviceId: String, kind: String, payload: ByteArray): Boolean { sent += kind; return true }
        override fun currentSessionToken(deviceId: String): String? = "routing-test-session".takeIf { deviceId == "agent" }
        override fun sendIfCurrent(deviceId: String, sessionToken: String, kind: String, payload: ByteArray): Boolean =
            currentSessionToken(deviceId) == sessionToken && send(deviceId, kind, payload)
        override fun connectedAgents() = listOf("agent")
        override fun mirrorMacs() = emptyList<String>()
        // This generic status is deliberately stale: candidate processing must use its actual recipients.
        override fun readerLinks() = listOf(ReaderLink(false, true, true, true))
        override fun canDetect(deviceId: String) = detector
        override fun deviceName(deviceId: String) = "Test agent"
        override fun agentIds() = listOf("agent")
        override fun route(deviceId: String): String? = "lan"
        override fun refreshFeatures(deviceId: String) = Unit
        override fun stopRing(deviceId: String) = Unit
    }

    @Test fun disconnectOrNotificationRevocationBeforeProcessingAllowsTheDetector() = runTest {
        for (revoked in listOf(false, true)) {
            val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
            try {
                val transport = Transport(detector = true)
                val hub = AgentHub(ApplicationProvider.getApplicationContext<Application>(), scope, transport, clock = { 1_000_000 }, freshnessClock = { 1_000_000 })
                hub.grants.set("agent", AgentGrant.CODES, true, GrantWindow.FOREVER)
                hub.grants.set("agent", AgentGrant.CODES_DETECT, true, GrantWindow.FOREVER)
                var live = listOf(mac)
                scope.launch { hub.smsCandidate("candidate-$revoked", "Service", "Messages", "Your OTP is 482913", 1_000_000) { live } }
                live = if (revoked) listOf(mac.copy(notifiedHere = false)) else emptyList()
                runCurrent()
                assertEquals(1, transport.sent.count { it == AgentKinds.CODES_CANDIDATE })
            } finally { scope.cancel() }
        }
    }

    @Test fun disconnectedReaderBeforeProcessingAllowsTheExplicitlyEnabledCloudFallback() = runTest {
        val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
        try {
            val transport = Transport(detector = false)
            val hub = AgentHub(ApplicationProvider.getApplicationContext<Application>(), scope, transport, clock = { 1_000_000 }, freshnessClock = { 1_000_000 })
            hub.grants.set("agent", AgentGrant.CODES, true, GrantWindow.FOREVER)
            val called = CompletableDeferred<Unit>()
            hub.cloud = CloudCodes({ true }, { _, _ -> called.complete(Unit); CodeRelay.Answer.NoCode }, { 1_000_000 })
            var live = listOf(mac)
            scope.launch { hub.smsCandidate("cloud", "Service", "Messages", "Your OTP is 482913", 1_000_000) { live } }
            live = emptyList()
            runCurrent()
            // The fake extractor runs on real IO; use a real bounded dispatcher timeout, not virtual time.
            withContext(Dispatchers.Default) { withTimeout(5_000) { called.await() } }
            assertTrue(called.isCompleted)
            assertEquals(0, transport.sent.count { it == AgentKinds.CODES_CANDIDATE })
        } finally { scope.cancel() }
    }

    @Test fun onlySuccessfulActualRecipientsCountAndQuietReadersStillCount() = runTest {
        for (sent in listOf(false, true)) {
            val scope = CoroutineScope(SupervisorJob() + StandardTestDispatcher(testScheduler))
            try {
                val transport = Transport(detector = true)
                val hub = AgentHub(ApplicationProvider.getApplicationContext<Application>(), scope, transport, clock = { 1_000_000 }, freshnessClock = { 1_000_000 })
                hub.grants.set("agent", AgentGrant.CODES, true, GrantWindow.FOREVER)
                hub.grants.set("agent", AgentGrant.CODES_DETECT, true, GrantWindow.FOREVER)
                val routes = NotificationAlertRoutes()
                val ticket = routes.plan("quiet-$sent") { "another-mac" }!!
                val delivered = dispatchNotification(ticket, listOf("quiet-mac"), false, { routes.current(ticket) }, { it },
                    { _, alert -> assertFalse(alert); sent })
                hub.smsCandidate("quiet-$sent", "Service", "Messages", "Your OTP is 482913", 1_000_000) {
                    delivered.map { mac }
                }
                assertEquals(if (sent) 0 else 1, transport.sent.count { it == AgentKinds.CODES_CANDIDATE })
            } finally { scope.cancel() }
        }
    }
}
