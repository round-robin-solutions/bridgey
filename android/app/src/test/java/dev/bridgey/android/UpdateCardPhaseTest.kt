package dev.bridgey.android

import dev.bridgey.android.updates.UpdateReason
import dev.bridgey.android.updates.UpdateState
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

    @Test fun updateAllPhases() {
        assertEquals(UpdateCardPhase.Ready(update), updateCardPhase(base.copy(available = update, readyToInstall = true)))
        assertEquals(UpdateCardPhase.Installing(update), updateCardPhase(base.copy(available = update, installing = true)))
        val marker = dev.bridgey.android.updates.NotApplied(10, "0.6.0-rr.1-beta.10")
        assertEquals(UpdateCardPhase.NotApplied("0.6.0-rr.1-beta.10", canRetry = true), updateCardPhase(base.copy(available = update, notApplied = marker)))
        assertEquals(UpdateCardPhase.NotApplied("0.6.0-rr.1-beta.10", canRetry = false), updateCardPhase(base.copy(notApplied = marker)))
        // A retry that is downloading again shows the download, not the old failure.
        assertEquals(UpdateCardPhase.Downloading(update, 0.2f), updateCardPhase(base.copy(available = update, notApplied = marker, downloadProgress = 0.2f)))
    }

    @Test fun wireStatusFollowsTheCard() {
        fun status(state: UpdateUiState, remoteStart: Boolean = true, canUpdate: Boolean = true) =
            localUpdateStatus(state, "0.6.0-rr.1-beta.9", 9, remoteStart, canUpdate)
        assertEquals(UpdateState.CURRENT, status(base).state)
        assertEquals(null, status(base).target)
        assertEquals(1_000L, status(base).checkedAt)
        assertEquals(UpdateState.CHECKING, status(base.copy(checking = true)).state)
        status(base.copy(available = update)).let {
            assertEquals(UpdateState.AVAILABLE, it.state)
            assertEquals("0.6.0-rr.1-beta.10", it.target)
            assertEquals(10L, it.targetBuild)
            assertEquals(dev.bridgey.android.updates.WireChannel.BETA, it.channel)
            assertEquals(dev.bridgey.android.updates.UpdatePlatform.ANDROID, it.platform)
            assertEquals("rr", it.edition)
        }
        assertEquals(42, status(base.copy(available = update, downloadProgress = 0.42f)).progress)
        assertEquals(UpdateState.READY, status(base.copy(available = update, readyToInstall = true)).state)
        assertEquals(UpdateState.INSTALLING, status(base.copy(available = update, installing = true)).state)
        status(base.copy(available = update, awaitingConfirmation = true)).let { assertEquals(UpdateState.NEEDS_USER to UpdateReason.CONFIRM, it.state to it.reason) }
        status(base.copy(available = update, needsInstallPermission = true)).let { assertEquals(UpdateState.NEEDS_USER to UpdateReason.PERMISSION, it.state to it.reason) }
        status(base.copy(available = update, error = UpdateError.SAFETY)).let { assertEquals(UpdateState.FAILED to UpdateReason.SAFETY, it.state to it.reason) }
        status(base.copy(available = update, notApplied = dev.bridgey.android.updates.NotApplied(10, "0.6.0-rr.1-beta.10"))).let {
            assertEquals(UpdateState.FAILED to UpdateReason.NOT_APPLIED, it.state to it.reason)
            assertEquals("0.6.0-rr.1-beta.10", it.target)
        }
        assertEquals(UpdateState.MANUAL, status(base.copy(available = update), canUpdate = false).state)
        assertEquals(false, status(base, canUpdate = false).remoteStart)
        assertEquals(false, status(base, remoteStart = false).remoteStart)
        assertEquals(true, status(base).remoteStart)
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
