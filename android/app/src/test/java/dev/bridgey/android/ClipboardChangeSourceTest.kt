package dev.bridgey.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ClipboardChangeSourceTest {
    private val pkg = "in.roundrobin.bridgey"

    @Test
    fun matchesTheDenialLineForOurPackage() {
        assertTrue(isClipboardDenialLine("W ClipboardService: Denying clipboard access to $pkg, application is not in focus", pkg))
        assertTrue(isClipboardDenialLine("Denying clipboard access to $pkg nor focused", pkg))
    }

    @Test
    fun ignoresOtherPackagesTagsAndMalformedLines() {
        assertFalse(isClipboardDenialLine("W ClipboardService: Denying clipboard access to com.other.app", pkg))
        assertFalse(isClipboardDenialLine("I ActivityManager: Start proc $pkg for activity", pkg))
        assertFalse(isClipboardDenialLine("", pkg))
        assertFalse(isClipboardDenialLine("random log line about $pkg", pkg))
    }

    @Test
    fun debouncerFoldsABurstThenFiresAgainAfterTheWindow() {
        val debouncer = Debouncer(500L)
        assertTrue(debouncer.shouldFire(1_000L))
        assertFalse(debouncer.shouldFire(1_200L))
        assertFalse(debouncer.shouldFire(1_499L))
        assertTrue(debouncer.shouldFire(1_500L))
        assertFalse(debouncer.shouldFire(1_600L))
    }
}
