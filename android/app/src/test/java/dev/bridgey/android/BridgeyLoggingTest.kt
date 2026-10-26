package dev.bridgey.android

import dev.bridgey.core.discovery.DiscoveryLog
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeyLoggingTest {
    private val off = LoggingPolicy(
        connection = false, calls = false, notifications = false, clipboard = false, remoteControl = false,
    )

    @After fun restoreDefaults() {
        BridgeyLogging.policy = LoggingPolicy()
    }

    @Test fun defaultsArePrivacyLeaningExceptCalls() {
        val policy = LoggingPolicy()
        assertTrue(policy.connection && policy.calls && policy.notifications && policy.clipboard && policy.remoteControl)
        assertFalse(policy.callNumbers || policy.notificationContent || policy.clipboardPreviews || policy.fileNames)
    }

    // In JVM unit tests android.util.Log is not mocked and throws when called, so these calls
    // passing proves a disabled category never reaches Logcat.
    @Test fun disabledCategoriesNeverReachLogcat() {
        BridgeyLogging.policy = off
        BridgeyLogging.i(LogCategory.CONNECTION, "RECONNECT dial")
        BridgeyLogging.w(LogCategory.CALLS, "CALL failed", IllegalStateException())
        BridgeyLogging.d(LogCategory.NOTIFICATIONS, "PLUGIN notification observed")
        BridgeyLogging.i(LogCategory.CLIPBOARD, "CLIPBOARD sent")
        BridgeyLogging.i(LogCategory.REMOTE_CONTROL, "REMOTE session_active")
        BridgeyLogging.line(LogLines.call(off, "started", "abcdef0123", "telephony", caller = "Asha"))
        BridgeyLogging.line(LogLines.notification(off, "sent", "Chat", "Asha", "Hello"))
        BridgeyLogging.line(LogLines.clipboard(off, "sent", "secret"))
        assertFalse(DiscoveryLog.enabled)
    }

    @Test fun connectionSwitchControlsDiscoveryLogging() {
        BridgeyLogging.policy = LoggingPolicy(connection = false)
        assertFalse(DiscoveryLog.enabled)
        BridgeyLogging.policy = LoggingPolicy(connection = true)
        assertTrue(DiscoveryLog.enabled)
    }

    @Test fun callLinesCarryStateAndCallerButMaskNumbersByDefault() {
        val line = LogLines.call(LoggingPolicy(), "forwarded", "0123456789abcdef", "incoming", caller = "Asha Rao")
        assertEquals("CALL forwarded id=01234567 reason=incoming caller=\"Asha Rao\"", line)

        val unknown = LogLines.call(LoggingPolicy(), "forwarded", "0123456789abcdef", "incoming", caller = "+91 98765 43210")
        assertEquals("CALL forwarded id=01234567 reason=incoming caller=\"[number]\"", unknown)
        assertFalse(unknown!!.contains("98765"))

        val withNumbers = LogLines.call(LoggingPolicy(callNumbers = true), "forwarded", "0123456789abcdef", "incoming", caller = "+91 98765 43210")
        assertTrue(withNumbers!!.contains("+91 98765 43210"))

        assertNull(LogLines.call(LoggingPolicy(calls = false), "forwarded", "0123", "incoming", caller = "Asha"))
    }

    @Test fun maskingKeepsShortNumbersInNames() {
        assertEquals("Flat 12 office", maskPhoneNumbers("Flat 12 office"))
        assertEquals("Mum [number]", maskPhoneNumbers("Mum 9876543210"))
        assertEquals("[number]", maskPhoneNumbers("(011) 2345-6789"))
    }

    @Test fun notificationLinesAddContentOnlyWhenAllowed() {
        val plain = LogLines.notification(LoggingPolicy(), "sent", "Chat", "Asha", "See you at 6")
        assertEquals("NOTIFICATION sent app=\"Chat\"", plain)
        val full = LogLines.notification(LoggingPolicy(notificationContent = true), "sent", "Chat", "Asha", "See you at 6")
        assertEquals("NOTIFICATION sent app=\"Chat\" title=\"Asha\" text=\"See you at 6\"", full)
        assertNull(LogLines.notification(LoggingPolicy(notifications = false, notificationContent = true), "sent", "Chat", "Asha", "x"))
    }

    @Test fun clipboardPreviewsOnlyWhenAllowed() {
        assertEquals("CLIPBOARD sent", LogLines.clipboard(LoggingPolicy(), "sent", "password123"))
        assertEquals(
            "CLIPBOARD sent preview=\"line one line two\"",
            LogLines.clipboard(LoggingPolicy(clipboardPreviews = true), "sent", "line one\nline two"),
        )
        assertNull(LogLines.clipboard(LoggingPolicy(clipboard = false, clipboardPreviews = true), "sent", "x"))
    }

    @Test fun fileNamesOnlyWhenAllowed() {
        assertEquals("FILE received transfer=abcdef01", LogLines.file(LoggingPolicy(), "received", "abcdef0123", "Payslip.pdf"))
        assertEquals(
            "FILE received transfer=abcdef01 name=\"Payslip.pdf\"",
            LogLines.file(LoggingPolicy(fileNames = true), "received", "abcdef0123", "Payslip.pdf"),
        )
    }

    @Test fun disabledCategoriesNeverReachDiagnostics() {
        var policy = off
        val diagnostics = BridgeyDiagnostics(allows = { policy.allows(diagnosticLogCategory(it)) })
        diagnostics.record("transport", "connected")
        diagnostics.record("reconnect", "dial_failed")
        diagnostics.record("call", "started")
        diagnostics.record("calls", "request")
        diagnostics.record("notification", "removed_remotely")
        diagnostics.record("clipboard", "text_sent")
        diagnostics.record("remote", "session_active")
        diagnostics.record("transfer", "received")
        assertEquals(listOf("transfer"), diagnostics.snapshot().map(DiagnosticEvent::category))

        policy = LoggingPolicy()
        diagnostics.record("call", "started")
        assertEquals(listOf("transfer", "call"), diagnostics.snapshot().map(DiagnosticEvent::category))
    }

    @Test fun clearLogsEmptiesDiagnostics() {
        val diagnostics = BridgeyDiagnostics(allows = { true })
        diagnostics.record("call", "started")
        diagnostics.clear()
        assertTrue(diagnostics.snapshot().isEmpty())
    }

    @Test fun policyRoundTripsThroughPreferences() {
        val stored = mutableMapOf<String, Boolean>()
        val custom = LoggingPolicy(connection = false, callNumbers = true, fileNames = true)
        stored += loggingPreferenceValues(custom)
        assertEquals(custom, loggingPolicyFrom { key, default -> stored[key] ?: default })
        assertEquals(LoggingPolicy(), loggingPolicyFrom { _, default -> default })
    }
}
