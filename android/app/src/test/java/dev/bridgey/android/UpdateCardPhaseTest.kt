package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Settings > Updates shows one state at a time; these pin which one wins. */
class UpdateCardPhaseTest {
    private val update = AndroidUpdate(
        UpdateChannel.BETA, "0.6.0-rr.1-beta.10", 10, "", "- a", "https://example.com/a.apk", "a".repeat(64), 15_200_000, 26,
    )
    private val base = UpdateUiState(channel = UpdateChannel.BETA, lastCheckedAt = 1_000)

    @Test fun eachStateShowsOnce() {
        assertEquals(UpdateCardPhase.Current(1_000), updateCardPhase(base))
        assertEquals(UpdateCardPhase.Current(0), updateCardPhase(base.copy(lastCheckedAt = 0)))
        assertEquals(UpdateCardPhase.Checking, updateCardPhase(base.copy(checking = true)))
        assertEquals(UpdateCardPhase.Available(update), updateCardPhase(base.copy(available = update)))
        assertEquals(UpdateCardPhase.Waiting(update), updateCardPhase(base.copy(available = update, deferred = true)))
        assertEquals(UpdateCardPhase.Downloading(update, 0.4f), updateCardPhase(base.copy(available = update, downloadProgress = 0.4f)))
        assertEquals(UpdateCardPhase.Confirming(update), updateCardPhase(base.copy(available = update, awaitingConfirmation = true)))
        assertEquals(UpdateCardPhase.Skipped("0.6.0-rr.1-beta.10"), updateCardPhase(base.copy(skippedVersion = "0.6.0-rr.1-beta.10")))
    }

    @Test fun errorsRetryTheStepThatFailed() {
        assertEquals(UpdateCardPhase.Failed(UpdateError.CHECK, retryInstalls = false), updateCardPhase(base.copy(error = UpdateError.CHECK, checking = true)))
        assertEquals(UpdateCardPhase.Failed(UpdateError.DOWNLOAD, retryInstalls = true), updateCardPhase(base.copy(available = update, error = UpdateError.DOWNLOAD)))
    }

    @Test fun skippedVersionsWaitForAManualCheck() {
        assertNull(UpdateFeeds.offer(update, skippedVersionCode = 10, userInitiated = false))
        assertEquals(update, UpdateFeeds.offer(update, skippedVersionCode = 10, userInitiated = true))
        assertEquals(update, UpdateFeeds.offer(update, skippedVersionCode = 9, userInitiated = false))
    }

    @Test fun shortVersionKeepsOnlyWhatDiffers() {
        assertEquals("beta.10", UpdateFeeds.shortVersion("0.6.0-rr.1-beta.10", "0.6.0-rr.1-beta.9"))
        assertEquals("nightly.20261026", UpdateFeeds.shortVersion("0.6.0-rr.1-nightly.20261026", "0.6.0-rr.1-beta.9"))
        assertEquals("0.7.0-rr.1-beta.1", UpdateFeeds.shortVersion("0.7.0-rr.1-beta.1", "0.6.0-rr.1-beta.9"))
        assertEquals("0.6.0-rr.1", UpdateFeeds.shortVersion("0.6.0-rr.1", "0.6.0-rr.1-beta.9"))
    }
}
