package dev.bridgey.android.screen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenRequestsTest {
    private var now = 0L
    private val requests = ScreenRequests { now }
    private fun request(id: String) = """{"version":1,"requestId":"$id"}""".toByteArray()

    @Test fun oneOpenRequestPerMacAndSpacing() {
        val first = requests.receive("a", "MacBook", request(R1), enabled = true, sharing = false)
        assertTrue(first is ScreenRequestDecision.Accept)
        now += 5_000
        assertEquals(ScreenRequestDecision.Refuse(R2, ScreenStatus.BUSY), requests.receive("a", "MacBook", request(R2), enabled = true, sharing = false))
        assertTrue(requests.receive("b", "Mini", request(R2), enabled = true, sharing = false) is ScreenRequestDecision.Accept)
        now += 1_000
        assertEquals(ScreenRequestDecision.Refuse(R1, ScreenStatus.BUSY), requests.receive("b", "Mini", request(R1), enabled = true, sharing = false))
    }

    @Test fun switchOffAndSharingRefuse() {
        assertEquals(ScreenRequestDecision.Refuse(R1, ScreenStatus.DISABLED), requests.receive("a", "M", request(R1), enabled = false, sharing = false))
        assertEquals(ScreenRequestDecision.Refuse(R1, ScreenStatus.BUSY), requests.receive("b", "M", request(R1), enabled = true, sharing = true))
        assertEquals(ScreenRequestDecision.Drop, requests.receive("c", "M", "{}".toByteArray(), enabled = true, sharing = false))
    }

    @Test fun requestsExpireAfterTwoMinutes() {
        val accepted = requests.receive("a", "M", request(R1), enabled = true, sharing = false) as ScreenRequestDecision.Accept
        assertEquals(accepted.request, requests.current("a", R1))
        now += ScreenLimits.REQUEST_LIFETIME_MILLIS
        assertNull(requests.current("a", R1))
        assertTrue(requests.receive("a", "M", request(R2), enabled = true, sharing = false) is ScreenRequestDecision.Accept)
        assertTrue(requests.finish("a", R2))
        assertNull(requests.ended("a"))
    }

    private companion object {
        const val R1 = "8a5d9c3e-2b47-4f1a-9e60-7c1d2b3a4f5e"
        const val R2 = "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b"
    }
}
