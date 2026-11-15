package dev.bridgey.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceDestinationSelectionTest {
    private val work = DeviceDestination("work", "Work Mac", true, "Connected")
    private val personal = DeviceDestination("personal", "Personal Mac", true, "Active", suggested = true)
    private val offline = DeviceDestination("offline", "Offline Mac", false, "Offline")

    @Test fun suggestionOrdersRowsButDoesNotChooseADestinationOrAuthorizeSend() {
        val rows = DeviceDestinationSelection.ordered(listOf(work, personal, offline))
        assertEquals(listOf("personal", "work", "offline"), rows.map { it.deviceId })
        assertNull(DeviceDestinationSelection.selected(rows, null))
        assertFalse(DeviceDestinationSelection.canSend(rows, null))
        assertTrue(DeviceDestinationSelection.canSend(rows, "work"))
    }

    @Test fun activityChangesCannotReplaceAnExplicitChoice() {
        val rows = DeviceDestinationSelection.ordered(listOf(work, personal))
        val changed = DeviceDestinationSelection.ordered(listOf(work.copy(suggested = true), personal.copy(suggested = false)))
        assertEquals("personal", DeviceDestinationSelection.selected(rows, "personal")?.deviceId)
        assertEquals("personal", DeviceDestinationSelection.selected(changed, "personal")?.deviceId)
        assertEquals("work", DeviceDestinationSelection.selected(rows, "work")?.deviceId)
    }

    @Test fun disconnectedAndForgottenChoicesNeverFallBackToAnotherMac() {
        val rows = listOf(work, personal.copy(available = false, detail = "Offline"))
        assertEquals("personal", DeviceDestinationSelection.selected(rows, "personal")?.deviceId)
        assertFalse(DeviceDestinationSelection.canSend(rows, "personal"))
        assertNull(DeviceDestinationSelection.selected(listOf(work), "personal"))
        assertFalse(DeviceDestinationSelection.canSend(listOf(work), "personal"))
    }

    @Test fun singleDeviceStillNeedsAChoiceAndEmptyListsCannotSend() {
        assertFalse(DeviceDestinationSelection.canSend(listOf(work), null))
        assertTrue(DeviceDestinationSelection.canSend(listOf(work), "work"))
        assertFalse(DeviceDestinationSelection.canSend(emptyList(), "work"))
    }

    @Test fun noRecommendationPreservesPairedOrderAndOfflineRows() {
        val rows = listOf(work, offline, personal.copy(suggested = false))
        assertEquals(rows, DeviceDestinationSelection.ordered(rows))
        assertEquals(3, DeviceDestinationSelection.ordered(rows).size)
    }
}
