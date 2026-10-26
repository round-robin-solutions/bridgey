package dev.bridgey.android

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.folders.ConflictPolicy
import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.DestinationMode
import dev.bridgey.android.folders.FolderDestination
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class FolderSettingsTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun defaultsAreSenderPicksAskAndNoReplaceFromOtherDevices() {
        val state = BridgeySettings(context, "Phone").state.value
        assertEquals(DestinationMode.SENDER_PICKS, state.folderMode)
        assertEquals(ConflictPolicy.ASK, state.folderConflict)
        assertEquals(DEFAULT_PLACE_ID, state.folderDefaultPlace)
        assertFalse("Allow other devices to replace files here is off by default", state.allowReplaceFromOtherDevices)
        assertTrue(state.recentFolderDestinations.isEmpty())
        val receive = state.folderReceiveSettings
        assertEquals(DestinationMode.SENDER_PICKS, receive.mode)
        assertEquals(ConflictPolicy.ASK, receive.policy)
        assertFalse(receive.allowReplaceFromOtherDevices)
    }

    @Test
    fun choicesPersistAndRecentDestinationsStayShortAndUnique() {
        val settings = BridgeySettings(context, "Phone")
        settings.setFolderMode(DestinationMode.FIXED)
        settings.setFolderConflict(ConflictPolicy.REPLACE)
        settings.setFolderDefaultPlace("q3Jx0bVv1eG7tq8Wm2l5wA")
        settings.setAllowReplaceFromOtherDevices(true)
        val trip = FolderDestination("q3Jx0bVv1eG7tq8Wm2l5wA", "Trip")
        repeat(7) { settings.addRecentFolderDestination(FolderDestination(DEFAULT_PLACE_ID, "Folder $it")) }
        settings.addRecentFolderDestination(trip)
        settings.addRecentFolderDestination(trip)
        val reloaded = BridgeySettings(context, "Phone").state.value
        assertEquals(DestinationMode.FIXED, reloaded.folderMode)
        assertEquals(ConflictPolicy.REPLACE, reloaded.folderConflict)
        assertEquals("q3Jx0bVv1eG7tq8Wm2l5wA", reloaded.folderDefaultPlace)
        assertTrue(reloaded.allowReplaceFromOtherDevices)
        assertEquals(5, reloaded.recentFolderDestinations.size)
        assertEquals(trip, reloaded.recentFolderDestinations.first())
        settings.forgetPlace("q3Jx0bVv1eG7tq8Wm2l5wA")
        assertTrue(settings.state.value.recentFolderDestinations.none { it.placeId == "q3Jx0bVv1eG7tq8Wm2l5wA" })
        settings.setFolderDefaultPlace("not a place id")
        assertEquals(DEFAULT_PLACE_ID, settings.state.value.folderDefaultPlace)
    }
}
