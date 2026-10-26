package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class BridgeyDiagnosticsTest {
    @Test fun diagnosticsAreBoundedAndStoreOnlyNormalizedEventMetadata() {
        val diagnostics = BridgeyDiagnostics(limit = 2)
        diagnostics.record("Transport", "Connected to Semyon's Mac", "OK")
        diagnostics.record("Plugin", "Clipboard Content", "Rejected")
        diagnostics.record("Transfer", "Interrupted", "Needs Retry")

        val events = diagnostics.snapshot()

        assertEquals(2, events.size)
        assertEquals("transfer", events.last().category)
        assertEquals("needs_retry", events.last().outcome)
        assertFalse(events.any { it.event.contains("Semyon", ignoreCase = true) })
    }

    @Test fun connectionEventsSurviveARestartWithTokensOnly() {
        val file = java.io.File.createTempFile("bridgey-diagnostics", ".json").apply { delete() }
        try {
            val diagnostics = BridgeyDiagnostics(limit = 10, file = file)
            diagnostics.record("transport", "disconnected", "reset_by_peer", device = "f00dfeed-0000-4000", detail = "idle_screen_off_bucket_10_optimised")
            diagnostics.record("reconnect", "dial", "backoff", device = "f00dfeed", detail = "n3_inbound_v4.148")
            val deadline = System.currentTimeMillis() + 5_000
            while (!file.exists() && System.currentTimeMillis() < deadline) Thread.sleep(50)
            val reloaded = BridgeyDiagnostics(limit = 10, file = file).snapshot()
            assertEquals(listOf("disconnected", "dial"), reloaded.map { it.event })
            assertEquals("f00dfeed", reloaded.first().device)
            assertEquals("reset_by_peer", reloaded.first().outcome)
            assertEquals("n3_inbound_v4.148", reloaded.last().detail)
        } finally {
            file.delete()
        }
    }
}
