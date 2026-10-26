package dev.bridgey.android.folders

import dev.bridgey.android.folders.FolderPolicy.AskReason
import dev.bridgey.android.folders.FolderPolicy.Asker
import dev.bridgey.android.folders.FolderPolicy.Conflict
import dev.bridgey.android.folders.FolderPolicy.Destination
import dev.bridgey.android.folders.FolderPolicy.Existing
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FolderPolicyTest {
    private val picked = FolderDestination("q3Jx0bVv1eG7tq8Wm2l5wA", "Trip")

    @Test fun senderPicksUsesTheOfferedDestination() {
        assertEquals(Destination.Offered(picked), FolderPolicy.destination(DestinationMode.SENDER_PICKS, picked, defaultAvailable = true))
    }

    @Test fun senderPicksWithoutADestinationAsksOnThisDevice() {
        assertEquals(Destination.AskHere(AskReason.NO_DESTINATION), FolderPolicy.destination(DestinationMode.SENDER_PICKS, null, true))
    }

    @Test fun receiverAsksIgnoresAnyOfferedDestination() {
        assertEquals(Destination.AskHere(AskReason.MODE), FolderPolicy.destination(DestinationMode.RECEIVER_ASKS, picked, true))
        assertEquals(Destination.AskHere(AskReason.MODE), FolderPolicy.destination(DestinationMode.RECEIVER_ASKS, null, true))
    }

    @Test fun fixedUsesTheDefaultFolderAndAsksWhenItLostAccess() {
        assertEquals(Destination.Fixed, FolderPolicy.destination(DestinationMode.FIXED, picked, defaultAvailable = true))
        assertEquals(Destination.AskHere(AskReason.DEFAULT_UNAVAILABLE), FolderPolicy.destination(DestinationMode.FIXED, null, defaultAvailable = false))
    }

    @Test fun theQuestionShowsWhereTheDestinationWasChosen() {
        assertEquals(Asker.SENDER, FolderPolicy.askerFor(Destination.Offered(picked)))
        assertEquals(Asker.RECEIVER, FolderPolicy.askerFor(Destination.Fixed))
        assertEquals(Asker.RECEIVER, FolderPolicy.askerFor(Destination.AskHere(AskReason.MODE)))
    }

    @Test fun noClashNeedsNoQuestion() {
        ConflictPolicy.entries.forEach { policy ->
            assertEquals(Conflict.Proceed(ConflictChoice.NONE), FolderPolicy.conflict(Existing.NONE, policy, Asker.SENDER))
        }
    }

    @Test fun askEachTimeOffersAllThreeChoicesWhereTheDestinationWasChosen() {
        val all = listOf(ConflictChoice.MERGE, ConflictChoice.REPLACE, ConflictChoice.NEW_FOLDER)
        assertEquals(Conflict.Ask(Asker.SENDER, all), FolderPolicy.conflict(Existing.FOLDER, ConflictPolicy.ASK, Asker.SENDER))
        assertEquals(Conflict.Ask(Asker.RECEIVER, all), FolderPolicy.conflict(Existing.FOLDER, ConflictPolicy.ASK, Asker.RECEIVER))
    }

    @Test fun aPresetIsAppliedWithoutAsking() {
        assertEquals(Conflict.Proceed(ConflictChoice.MERGE), FolderPolicy.conflict(Existing.FOLDER, ConflictPolicy.MERGE, Asker.SENDER))
        assertEquals(Conflict.Proceed(ConflictChoice.REPLACE), FolderPolicy.conflict(Existing.FOLDER, ConflictPolicy.REPLACE, Asker.RECEIVER))
        assertEquals(Conflict.Proceed(ConflictChoice.NEW_FOLDER), FolderPolicy.conflict(Existing.FOLDER, ConflictPolicy.NEW_FOLDER, Asker.SENDER))
    }

    @Test fun anExistingFileOnlyAllowsSaveAsNewFolder() {
        assertEquals(Conflict.Ask(Asker.SENDER, listOf(ConflictChoice.NEW_FOLDER)), FolderPolicy.conflict(Existing.FILE, ConflictPolicy.ASK, Asker.SENDER))
        assertEquals(Conflict.Proceed(ConflictChoice.NEW_FOLDER), FolderPolicy.conflict(Existing.FILE, ConflictPolicy.MERGE, Asker.RECEIVER))
        assertEquals(Conflict.Proceed(ConflictChoice.NEW_FOLDER), FolderPolicy.conflict(Existing.FILE, ConflictPolicy.REPLACE, Asker.RECEIVER))
    }

    @Test fun onlyOfferedChoicesOrCancelAreAccepted() {
        val offered = listOf(ConflictChoice.NEW_FOLDER)
        assertTrue(FolderPolicy.isOffered(ConflictChoice.NEW_FOLDER, offered))
        assertTrue(FolderPolicy.isOffered(ConflictChoice.CANCEL, offered))
        assertFalse(FolderPolicy.isOffered(ConflictChoice.REPLACE, offered))
        assertFalse(FolderPolicy.isOffered(ConflictChoice.MERGE, offered))
    }

    @Test fun aReplaceFromTheOtherDeviceAsksOnThePhoneUntilAllowed() {
        assertTrue(FolderPolicy.replaceNeedsLocalConfirmation(ConflictChoice.REPLACE, Asker.SENDER, allowOtherDevicesToReplace = false))
        assertFalse(FolderPolicy.replaceNeedsLocalConfirmation(ConflictChoice.REPLACE, Asker.SENDER, allowOtherDevicesToReplace = true))
        assertFalse(FolderPolicy.replaceNeedsLocalConfirmation(ConflictChoice.REPLACE, Asker.RECEIVER, allowOtherDevicesToReplace = false))
        assertFalse(FolderPolicy.replaceNeedsLocalConfirmation(ConflictChoice.MERGE, Asker.SENDER, allowOtherDevicesToReplace = false))
    }

    @Test fun theQuestionCountsDownThreeMinutesThenTimesOut() {
        assertEquals(180, FolderPolicy.secondsLeft(0, 0))
        assertEquals(161, FolderPolicy.secondsLeft(0, 19_100))
        assertEquals(1, FolderPolicy.secondsLeft(0, 179_999))
        assertEquals(0, FolderPolicy.secondsLeft(0, 180_000))
        assertEquals("2:41", FolderPolicy.countdown(161))
        assertEquals("0:05", FolderPolicy.countdown(5))
    }

    @Test fun resumeIsAutomaticForTwentyFourHoursAfterTheLastProgress() {
        val hour = 60 * 60 * 1000L
        assertTrue(FolderTimeouts.canResume(lastProgressAtMillis = 0, nowMillis = 23 * hour))
        assertFalse(FolderTimeouts.canResume(lastProgressAtMillis = 0, nowMillis = 24 * hour))
        assertFalse(FolderTimeouts.canResume(lastProgressAtMillis = 10 * hour, nowMillis = 9 * hour))
    }

    @Test fun recentDestinationsKeepTheNewestFirstWithoutRepeats() {
        val a = FolderDestination(DEFAULT_PLACE_ID, "")
        val b = FolderDestination(DEFAULT_PLACE_ID, "Trip")
        assertEquals(listOf(b, a), recentDestinations(listOf(a, b), b))
        assertEquals(5, recentDestinations((1..9).map { FolderDestination(DEFAULT_PLACE_ID, "p$it") }, a).size)
    }
}
