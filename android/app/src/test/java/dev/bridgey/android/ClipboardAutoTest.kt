package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardAutoTest {
    private val now = 1_800_000_000_000L

    @Test
    fun skipRulesCoverUnavailableEmptySensitiveAndOversize() {
        assertEquals(ClipboardAutoDecision.SKIP_UNAVAILABLE, autoClipboardDecision("hi", false, available = false, lastHash = null))
        assertEquals(ClipboardAutoDecision.SKIP_EMPTY, autoClipboardDecision(null, false, available = true, lastHash = null))
        assertEquals(ClipboardAutoDecision.SKIP_EMPTY, autoClipboardDecision("", false, available = true, lastHash = null))
        assertEquals(ClipboardAutoDecision.SKIP_SENSITIVE, autoClipboardDecision("secret", sensitive = true, available = true, lastHash = null))
        val oversize = "a".repeat(MAX_CLIPBOARD_CONTENT_BYTES + 1)
        assertEquals(ClipboardAutoDecision.SKIP_TOO_LARGE, autoClipboardDecision(oversize, false, available = true, lastHash = null))
    }

    @Test
    fun sendsFreshUniqueContent() {
        assertEquals(ClipboardAutoDecision.SEND, autoClipboardDecision("room 2 at 4", false, available = true, lastHash = null))
    }

    @Test
    fun duplicateContentIsSkipped() {
        val hash = clipboardHash("room 2 at 4")
        assertEquals(ClipboardAutoDecision.SKIP_DUPLICATE, autoClipboardDecision("room 2 at 4", false, available = true, lastHash = hash))
        // Different content with the same stale hash still sends.
        assertEquals(ClipboardAutoDecision.SEND, autoClipboardDecision("something else", false, available = true, lastHash = hash))
    }

    @Test
    fun hashIsStableAndContentDependent() {
        assertEquals(clipboardHash("abc"), clipboardHash("abc"))
        assertNotEquals(clipboardHash("abc"), clipboardHash("abd"))
    }

    @Test
    fun loopPreventionBlocksOurOwnWrite() {
        val tracker = AutoClipboardTracker()
        val received = "pasted from the Mac"
        // Writing a received clip records its hash; the clip-change listener then reads the same
        // content and must treat it as a duplicate, so it is never bounced back.
        tracker.record("mac", clipboardHash(received))
        assertTrue(tracker.isDuplicate("mac", clipboardHash(received)))
        assertEquals(
            ClipboardAutoDecision.SKIP_DUPLICATE,
            autoClipboardDecision(received, false, available = true, lastHash = tracker.lastHash("mac")),
        )
    }

    @Test
    fun trackerIsPerDeviceAndClears() {
        val tracker = AutoClipboardTracker()
        tracker.record("mac", clipboardHash("x"))
        assertFalse(tracker.isDuplicate("mini", clipboardHash("x")))
        tracker.clear("mac")
        assertNull(tracker.lastHash("mac"))
    }

    @Test
    fun freshnessWindowIsTenMinutes() {
        assertTrue(clipIsFresh(now, now))
        assertTrue(clipIsFresh(now - AUTO_CLIPBOARD_MAX_AGE_MILLIS, now))
        assertFalse(clipIsFresh(now - AUTO_CLIPBOARD_MAX_AGE_MILLIS - 1, now))
        assertFalse(clipIsFresh(0L, now)) // unknown timestamp is not fresh
        assertFalse(clipIsFresh(now + 60_000, now)) // a future timestamp is not fresh
    }

    @Test
    fun perDeviceEnablementFollowsGlobalByDefault() {
        assertFalse(effectiveAutoClipboardEnabled(globalEnabled = false, deviceEnabled = true))
        assertTrue(effectiveAutoClipboardEnabled(globalEnabled = true, deviceEnabled = null))
        assertTrue(effectiveAutoClipboardEnabled(globalEnabled = true, deviceEnabled = true))
        assertFalse(effectiveAutoClipboardEnabled(globalEnabled = true, deviceEnabled = false))
    }
}
