package dev.bridgey.android.agents

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Detect codes: who reads a code text message, and what the phone takes back (docs/mesh-and-codes.md). */
class CodeDetectionsTest {
    private var now = 1_798_000_000_000L
    private val detections = CodeDetections { now }
    private val id = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d21"

    private fun candidate(deviceId: String = "agent-a", text: String = "OTP is 482913 for your login.") =
        PendingCandidate(id, deviceId, text, "AX-HDFCBK-S", CodeSource.SMS, "messages", "n1", now - 1_000, now)

    @Test fun noCandidateWhileAMacReadsOrNoAgentReadsCodes() {
        assertNull(detections.pick(macReaders = 1, anyReader = true, detectors = listOf("agent-a")))
        assertNull(detections.pick(macReaders = 0, anyReader = false, detectors = listOf("agent-a")))
        assertNull(detections.pick(macReaders = 0, anyReader = true, detectors = emptyList()))
    }

    /** The order is the one the phone gives (when Rahul allowed each), never the device IDs the devices chose. */
    @Test fun exactlyOneDetectorInTheGivenOrder() {
        assertEquals("agent-b", detections.pick(0, true, listOf("agent-b", "agent-a")))
        assertEquals("00000000-0000-0000-0000-000000000000", detections.pick(0, true, listOf("00000000-0000-0000-0000-000000000000", "agent-a")))
    }

    /** Picking reserves the rate slot and a pending slot at once, so two messages at the same moment cannot both pass. */
    @Test fun pickingReservesAtOnce() {
        repeat(DETECT_PER_HOUR) { assertEquals("agent-a", detections.pick(0, true, listOf("agent-a", "agent-b"))); detections.release() }
        assertEquals("agent-b", detections.pick(0, true, listOf("agent-a", "agent-b")))
        val fresh = CodeDetections { now }
        repeat(DETECT_PENDING_MAX) { index -> assertEquals("a$index", fresh.pick(0, true, listOf("a$index"))) }
        assertNull("reserved candidates count towards the pending cap", fresh.pick(0, true, listOf("z")))
        fresh.release()
        assertEquals("z", fresh.pick(0, true, listOf("z")))
    }

    /** M1: any Mac this phone sends notifications to that reads codes counts, mirror or not; one with Notifications off does not. */
    @Test fun macsThatReadCodes() {
        val mirrorless = ReaderLink(agent = false, smsCodes = true, notifiedHere = true, mirror = false)
        val off = ReaderLink(agent = false, smsCodes = true, notifiedHere = false, mirror = true)
        val reporting = ReaderLink(agent = false, smsCodes = true, notifiedHere = true, mirror = true)
        val agent = ReaderLink(agent = true, smsCodes = true, notifiedHere = true, mirror = true)
        assertEquals(1, macsReadingCodes(listOf(mirrorless, off, agent)))
        assertEquals(0, macsReportingCodes(listOf(mirrorless, off, agent)))
        assertEquals(1, macsReportingCodes(listOf(reporting, off)))
        assertEquals(0, macsReadingCodes(listOf(off)))
    }

    @Test fun detectCodesIsSetOnlyOnThePhone() {
        assertFalse(grantSettableFromMac(AgentGrant.CODES_DETECT))
        assertFalse(grantSettableFromMac(AgentGrant.NOTIFICATIONS))
        assertTrue(grantSettableFromMac(AgentGrant.CODES))
    }

    @Test fun aFoundCodeIsGuardedAndTheServiceIsThePhones() {
        detections.sent(candidate())
        val answer = detections.answer("agent-a", CodesDetected(id, CodesDetectedOutcome.FOUND, "482913", null))
        val found = (answer as DetectAnswer.Found).found
        assertEquals("482913", found.code)
        assertEquals("AX-HDFCBK-S", found.service)
        assertEquals("hdfcbk", found.serviceKey)
        assertEquals("n1", found.notificationId)
        // Taken once.
        assertEquals(DetectAnswer.Unknown, detections.answer("agent-a", CodesDetected(id, CodesDetectedOutcome.FOUND, "482913", null)))
    }

    @Test fun aCodeNotInTheMessageIsRefused() {
        detections.sent(candidate())
        assertEquals(DetectAnswer.Refused, detections.answer("agent-a", CodesDetected(id, CodesDetectedOutcome.FOUND, "999999", null)))
    }

    @Test fun anotherAgentsOrALateAnswerIsUnknown() {
        detections.sent(candidate())
        assertEquals(DetectAnswer.Unknown, detections.answer("agent-b", CodesDetected(id, CodesDetectedOutcome.FOUND, "482913", null)))
        now += DETECT_WAIT_MILLIS
        assertEquals(DetectAnswer.Unknown, detections.answer("agent-a", CodesDetected(id, CodesDetectedOutcome.FOUND, "482913", null)))
    }

    @Test fun anUpdatedNotificationWithTheSameTextIsSentOnce() {
        assertTrue(detections.firstSight("n1", "OTP 482913"))
        assertFalse(detections.firstSight("n1", "OTP 482913"))
        assertTrue(detections.firstSight("n1", "OTP 482913 and 551204"))
        now += 120_000
        assertTrue(detections.firstSight("n1", "OTP 482913"))
    }

    @Test fun oneAgentGetsAtMostSixtyAnHour() {
        repeat(DETECT_PER_HOUR) { index ->
            assertEquals("agent-a", detections.pick(0, true, listOf("agent-a", "agent-b")))
            detections.sent(candidate().copy(candidateId = "01934f3e-8a7c-7b1e-9d1a-2f6c0b8e%04d".format(index)))
            now += DETECT_WAIT_MILLIS
        }
        assertEquals("agent-b", detections.pick(0, true, listOf("agent-a", "agent-b")))
        now += 3_600_000
        assertEquals("agent-a", detections.pick(0, true, listOf("agent-a", "agent-b")))
    }
}
