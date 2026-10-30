package dev.bridgey.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceRateLimitTest {
    private var now = 1_000_000L
    private val limit = DeviceRateLimit(ALERT_INTERVAL_MILLIS) { now }

    @Test fun dropsExtrasFromOneDeviceWithinTheInterval() {
        assertTrue(limit.allow("mac-a"))
        now += ALERT_INTERVAL_MILLIS - 1
        assertFalse(limit.allow("mac-a"))
        now += 1
        assertTrue(limit.allow("mac-a"))
    }

    @Test fun eachDeviceHasItsOwnInterval() {
        assertTrue(limit.allow("mac-a"))
        assertTrue(limit.allow("mac-b"))
        assertFalse(limit.allow("mac-a"))
    }

    @Test fun aClockThatWentBackDoesNotBlockForever() {
        assertTrue(limit.allow("mac-a"))
        now -= 60_000
        assertTrue(limit.allow("mac-a"))
    }
}
