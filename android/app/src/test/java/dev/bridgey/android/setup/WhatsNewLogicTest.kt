package dev.bridgey.android.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WhatsNewLogicTest {
    private val v9 = AppVersion("0.6.0-rr.1-beta.9", 609)
    private val v10 = AppVersion("0.6.0-rr.1-beta.10", 610)
    private val bundled = BundledNotes("0.6.0-rr.1", "- A new setup.")

    private fun decide(installed: AppVersion, last: AppVersion?, fresh: Boolean = false, legacy: Boolean = false, feed: String? = null, notes: BundledNotes? = bundled) =
        WhatsNewLogic.decide(installed, last, fresh, legacy, feed, notes)

    @Test
    fun freshInstallShowsNothingAndRecordsTheVersion() {
        assertEquals(WhatsNewDecision.None(record = v10), decide(v10, null, fresh = true))
    }

    @Test
    fun sameVersionShowsNothing() {
        assertEquals(WhatsNewDecision.None(record = null), decide(v10, v10))
        // A local build keeps its build number: the same build, a new name is only recorded.
        val dev = AppVersion("0.6.0-rr.1-dev", 1)
        assertEquals(WhatsNewDecision.None(record = dev), decide(dev, AppVersion("0.6.0-rr.1-dev2", 1)))
    }

    @Test
    fun newerVersionShowsOnceWithItsNotes() {
        assertEquals(WhatsNewDecision.Show(v10, "- A new setup.", reviewSetup = false), decide(v10, v9))
        assertEquals(WhatsNewDecision.Show(v10, "- From the feed.", reviewSetup = false), decide(v10, v9, feed = "- From the feed."))
        // Once recorded as seen, it is the same version.
        assertEquals(WhatsNewDecision.None(record = null), decide(v10, v10))
    }

    @Test
    fun downgradeShowsNothingAndRecordsTheOlderVersion() {
        assertEquals(WhatsNewDecision.None(record = v9), decide(v9, v10))
    }

    @Test
    fun notesMissingStillShowsWithoutNotes() {
        assertEquals(WhatsNewDecision.Show(v10, null, reviewSetup = false), decide(v10, v9, notes = null))
        // Bundled notes for another version do not apply.
        assertEquals(WhatsNewDecision.Show(v10, null, reviewSetup = false), decide(v10, v9, notes = BundledNotes("0.7.0-rr.1", "- Later.")))
        assertNull(WhatsNewLogic.notesFor(v10, "  ", BundledNotes("0.6.0-rr.1", "")))
    }

    @Test
    fun updateFromBeforeSetupOffersReviewSetup() {
        assertEquals(WhatsNewDecision.Show(v10, "- A new setup.", reviewSetup = true), decide(v10, null, legacy = true))
        // A setup-era install that never recorded a version (cleared) shows nothing.
        assertEquals(WhatsNewDecision.None(record = v10), decide(v10, null, fresh = false, legacy = false))
    }

    @Test
    fun launchDecision() {
        val fresh = SetupLaunchLogic.decide(null, oldOnboardingCompleted = false, settingsStored = false)
        assertEquals(SetupLaunch(SetupStatus.NEEDED, showSetup = true, freshInstall = true, legacyUser = false), fresh)
        // Existing users who update are not forced through setup.
        assertEquals(SetupStatus.LEGACY, SetupLaunchLogic.decide(null, oldOnboardingCompleted = true, settingsStored = false).status)
        val legacy = SetupLaunchLogic.decide(null, oldOnboardingCompleted = false, settingsStored = true)
        assertEquals(false, legacy.showSetup)
        assertEquals(true, legacy.legacyUser)
        // Setup not finished yet: shown again, but no longer a fresh install.
        assertEquals(SetupLaunch(SetupStatus.NEEDED, showSetup = true, freshInstall = false, legacyUser = false), SetupLaunchLogic.decide(SetupStatus.NEEDED, false, true))
        assertEquals(false, SetupLaunchLogic.decide(SetupStatus.DONE, false, false).showSetup)
        assertEquals(true, SetupLaunchLogic.decide(SetupStatus.LEGACY, false, false).legacyUser)
    }
}
