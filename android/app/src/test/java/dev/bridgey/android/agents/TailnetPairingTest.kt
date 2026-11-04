package dev.bridgey.android.agents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pairing over the tailnet (docs/mesh-and-codes.md, phase 2): the typed target, and a server paired that way. */
class TailnetPairingTest {
    @Test fun typedTargets() {
        assertEquals("work" to 42_458, tailnetTarget(" work "))
        assertEquals("100.90.0.3" to 42_458, tailnetTarget("100.90.0.3"))
        assertEquals("100.90.0.3" to 42_481, tailnetTarget("100.90.0.3:42481"))
        assertEquals("work.tail1234.ts.net" to 42_458, tailnetTarget("work.tail1234.ts.net"))
        assertEquals("fd7a:115c:a1e0::a033:5522" to 42_458, tailnetTarget("fd7a:115c:a1e0::a033:5522"))
        assertEquals("fd7a:115c:a1e0::a033:5522" to 42_481, tailnetTarget("[fd7a:115c:a1e0::a033:5522]:42481"))
        assertEquals("work" to 42_458, tailnetTarget("work:99999"))
    }

    /** A server says what it is in its own map; a Mac's map (the mirror, codes) never makes it an agent. */
    @Test fun aServerIsAnAgentByItsOwnMap() {
        assertTrue(advertisesAgent(mapOf(AGENT_FEATURE_KEY to true, NOTIFY_FEATURE_KEY to true, ASK_FEATURE_KEY to true)))
        assertFalse(advertisesAgent(mapOf(AGENT_FEATURE_KEY to true)))
        assertFalse(advertisesAgent(mapOf(AGENTS_MIRROR_FEATURE_KEY to true, "sms_codes_draft1" to true)))
    }

    /** A pairing from a tailnet address starts restricted; an IP typed by hand outside the tailnet is not dialled. */
    @Test fun tailnetAddresses() {
        assertTrue(isTailnetAddress("100.77.183.42"))
        assertTrue(isTailnetAddress("100.64.0.1"))
        assertFalse(isTailnetAddress("100.128.0.1"))
        assertFalse(isTailnetAddress("192.168.1.10"))
        assertTrue(isTailnetAddress("fd7a:115c:a1e0::9833:b72b"))
        assertTrue(isTailnetAddress("::ffff:100.90.0.3"))
        assertFalse(isTailnetAddress("work"))
        assertTrue(refusedTailnetLiteral("192.168.1.10"))
        assertTrue(refusedTailnetLiteral("2001:db8::1"))
        assertFalse(refusedTailnetLiteral("100.90.0.3"))
        assertFalse(refusedTailnetLiteral("work.tail1234.ts.net"))
    }

    /** The saving rule in PairingCoordinator: tailnet first pairings are stored as agents and marked for promotion. */
    @Test fun aTailnetPairingIsSavedRestricted() {
        val source = java.io.File(java.io.File(System.getProperty("bridgey.repoRoot") ?: "../.."),
            "android/app/src/main/java/dev/bridgey/android/PairingCoordinator.kt").readText()
        assertTrue(source.contains("current.remoteHost?.let { dev.bridgey.android.agents.isTailnetAddress(it) } == true"))
        assertTrue(source.contains("platform = if (current.invite != null || viaTailnet) dev.bridgey.android.agents.AGENT_PLATFORM else null"))
        assertTrue(source.contains("trust.markTailnet(current.remoteDeviceId)"))
    }
}
