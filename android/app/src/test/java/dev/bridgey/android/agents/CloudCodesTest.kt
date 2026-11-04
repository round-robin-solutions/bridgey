package dev.bridgey.android.agents

import dev.bridgey.android.codes.CodeRelay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Codes over cloud (docs/mesh-and-codes.md, phase 2): opt-in, strict guard, no fallback, a rate limit, the order. */
class CloudCodesTest {
    private var now = 1_798_000_000_000L
    private var on = true
    private val calls = mutableListOf<String>()

    private fun cloud(answer: (String) -> CodeRelay.Answer) = CloudCodes({ on }, { text, _ -> calls += text; answer(text) }, { now })

    @Test fun offUntilChosenAndNothingIsSent() {
        on = false
        assertEquals(CloudRead.OFF to null, cloud { CodeRelay.Answer.Candidate("482913") }.read("OTP is 482913", "57575"))
        assertTrue(calls.isEmpty())
    }

    @Test fun aCodeCountsOnlyIfItIsVerbatimInTheText() {
        assertEquals(CloudRead.FOUND to "482913", cloud { CodeRelay.Answer.Candidate("482913") }.read("OTP is 482913", "57575"))
        assertEquals(CloudRead.REFUSED to null, cloud { CodeRelay.Answer.Candidate("999999") }.read("OTP is 482913", "57575"))
        assertEquals(CloudRead.REFUSED to null, cloud { CodeRelay.Answer.Candidate("482913") }.read("Open https://x.io/v/482913 now", "57575"), )
    }

    @Test fun aFailureIsNothing() {
        assertEquals(CloudRead.FAILED to null, cloud { CodeRelay.Answer.Failed("timeout") }.read("OTP is 482913", null))
        assertEquals(CloudRead.FAILED to null, cloud { error("network") }.read("OTP is 482913", null))
        assertEquals(CloudRead.NONE to null, cloud { CodeRelay.Answer.NoCode }.read("OTP is 482913", null))
    }

    /** The hourly limit is kept where it survives a restart: a new CloudCodes over the same history is still limited. */
    @Test fun theLimitSurvivesARestart() {
        val history = MemoryCloudHistory()
        val first = CloudCodes({ on }, { _, _ -> CodeRelay.Answer.NoCode }, { now }, history)
        repeat(CLOUD_READS_PER_HOUR) { first.read("OTP 482913", null) }
        val restarted = CloudCodes({ on }, { _, _ -> CodeRelay.Answer.NoCode }, { now }, history)
        assertEquals(CloudRead.LIMITED, restarted.read("OTP 482913", null).first)
    }

    /** Setting the clock back does not free the hour's reads. */
    @Test fun turningTheClockBackKeepsTheLimit() {
        val history = MemoryCloudHistory()
        val c = CloudCodes({ on }, { _, _ -> CodeRelay.Answer.NoCode }, { now }, history)
        repeat(CLOUD_READS_PER_HOUR) { c.read("OTP 482913", null) }
        now -= 6 * 3_600_000L
        assertEquals(CloudRead.LIMITED, c.read("OTP 482913", null).first)
    }

    /** A relay that hangs is a failure after the time limit, never a wait without end. */
    @Test fun aHangingRelayTimesOut() {
        val started = System.nanoTime()
        val read = cloud { Thread.sleep(10_000); CodeRelay.Answer.Candidate("482913") }.read("OTP is 482913", null)
        assertEquals(CloudRead.FAILED to null, read)
        assertTrue((System.nanoTime() - started) / 1_000_000 < CLOUD_TIMEOUT_MS + 1_500)
    }

    @Test fun atMostTwentyAnHour() {
        val c = cloud { CodeRelay.Answer.NoCode }
        repeat(CLOUD_READS_PER_HOUR) { assertEquals(CloudRead.NONE, c.read("OTP 482913", null).first) }
        assertEquals(CloudRead.LIMITED, c.read("OTP 482913", null).first)
        assertEquals(CLOUD_READS_PER_HOUR, calls.size)
        now += 3_600_000
        assertEquals(CloudRead.NONE, c.read("OTP 482913", null).first)
    }

    /** A Mac first, then a server with Detect codes, then this phone over cloud; and only for an agent that reads codes. */
    @Test fun theCloudComesLast() {
        assertTrue(cloudReads(macReaders = 0, anyReader = true, detectors = 0, cloudOn = true))
        assertFalse(cloudReads(macReaders = 1, anyReader = true, detectors = 0, cloudOn = true))
        assertFalse(cloudReads(macReaders = 0, anyReader = true, detectors = 1, cloudOn = true))
        assertFalse(cloudReads(macReaders = 0, anyReader = false, detectors = 0, cloudOn = true))
        assertFalse(cloudReads(macReaders = 0, anyReader = true, detectors = 0, cloudOn = false))
    }

    @Test fun detectCodesDefaultsToUntilTurnedOff() {
        assertEquals(GrantWindow.FOREVER, windowsFor(AgentGrant.CODES_DETECT).first())
        assertEquals(GrantWindow.entries.toSet(), windowsFor(AgentGrant.CODES_DETECT).toSet())
        assertEquals(GrantWindow.entries, windowsFor(AgentGrant.CODES))
    }

    /** Email previews never go to the cloud: the only caller of the cloud read is the text-message path. */
    @Test fun onlyTextMessagesReachTheCloud() {
        val hub = java.io.File(java.io.File(System.getProperty("bridgey.repoRoot") ?: "../.."),
            "android/app/src/main/java/dev/bridgey/android/agents/AgentHub.kt").readText()
        assertEquals(2, Regex("readOverCloud\\(").findAll(hub).count())
        val caller = hub.substringBefore("private fun readOverCloud").substringAfterLast("fun ")
        assertTrue(caller, caller.startsWith("smsCandidate("))
    }
}
