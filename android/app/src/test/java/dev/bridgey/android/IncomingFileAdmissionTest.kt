package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Test

class IncomingFileAdmissionTest {
    private val margin = 64L * 1024 * 1024

    @Test fun acceptsWhileUnderBothCapsAndTheFileFits() {
        assertEquals(
            IncomingFileAdmission.Accept,
            incomingFileAdmission(size = 1_000, deviceInFlight = 3, totalInFlight = 7, reservedBytes = 0, freeBytes = margin + 1_000, margin = margin),
        )
    }

    @Test fun refusesAFifthFileFromOneMacAndANinthInAll() {
        assertEquals(
            IncomingFileAdmission.Busy,
            incomingFileAdmission(size = 1, deviceInFlight = MAX_INCOMING_FILES_PER_DEVICE, totalInFlight = 4, reservedBytes = 0, freeBytes = null),
        )
        assertEquals(
            IncomingFileAdmission.Busy,
            incomingFileAdmission(size = 1, deviceInFlight = 0, totalInFlight = MAX_INCOMING_FILES_TOTAL, reservedBytes = 0, freeBytes = null),
        )
    }

    @Test fun freeSpaceCountsWhatTheFilesAlreadyArrivingStillNeed() {
        val free = margin + 1_000
        assertEquals(
            IncomingFileAdmission.Accept,
            incomingFileAdmission(size = 600, deviceInFlight = 1, totalInFlight = 1, reservedBytes = 400, freeBytes = free, margin = margin),
        )
        assertEquals(
            IncomingFileAdmission.NoSpace(neededBytes = margin + 1_001, freeBytes = free),
            incomingFileAdmission(size = 600, deviceInFlight = 1, totalInFlight = 1, reservedBytes = 401, freeBytes = free, margin = margin),
        )
    }

    @Test fun unknownFreeSpaceDoesNotRefuse() {
        assertEquals(
            IncomingFileAdmission.Accept,
            incomingFileAdmission(size = Long.MAX_VALUE / 4, deviceInFlight = 0, totalInFlight = 0, reservedBytes = 0, freeBytes = null),
        )
    }
}
