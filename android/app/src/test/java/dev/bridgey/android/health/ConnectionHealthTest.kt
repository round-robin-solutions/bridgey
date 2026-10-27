package dev.bridgey.android.health

import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionHealthTest {
    private val zone = ZoneId.of("Asia/Kolkata")
    private fun at(day: Int, hour: Int, minute: Int = 0) = ZonedDateTime.of(2026, 10, day, hour, minute, 0, 0, zone).toInstant().toEpochMilli()
    private val device = "a1b2c3d4-0000-4000-8000-000000000001"

    @Test fun routesAreClassesNeverAddresses() {
        mapOf(
            "192.168.1.20" to RouteClass.SAME_NETWORK,
            "10.0.0.3" to RouteClass.SAME_NETWORK,
            "172.20.1.1" to RouteClass.SAME_NETWORK,
            "172.32.1.1" to RouteClass.OTHER,
            "169.254.3.3" to RouteClass.SAME_NETWORK,
            "100.71.43.72" to RouteClass.PRIVATE_NETWORK,
            "100.128.0.1" to RouteClass.OTHER,
            "100.63.255.255" to RouteClass.OTHER,
            "8.8.8.8" to RouteClass.OTHER,
            "fe80::1%wlan0" to RouteClass.SAME_NETWORK,
            "[fd12:3456::1]" to RouteClass.SAME_NETWORK,
            "fd7a:115c:a1e0::1" to RouteClass.PRIVATE_NETWORK,
            "2001:db8::1" to RouteClass.OTHER,
            "::ffff:192.168.0.9" to RouteClass.SAME_NETWORK,
            "mac.local" to RouteClass.UNKNOWN,
            "999.1.1.1" to RouteClass.UNKNOWN,
            "" to RouteClass.UNKNOWN,
            null to RouteClass.UNKNOWN,
        ).forEach { (host, expected) -> assertEquals("$host", expected, classifyRoute(host)) }
    }

    @Test fun roundTripUsesOnlyOurPingsAndKeepsTheLastTen() {
        val book = ConnectionHealthBook { zone }
        book.connected(device, "192.168.1.20", dialledHere = true, wallMillis = at(27, 9))
        book.heartbeatAnswered(device, "unknown", 50)
        (1..12).forEach { n ->
            book.heartbeatSent(device, "p$n", n * 10_000L)
            book.heartbeatAnswered(device, "p$n", n * 10_000L + n * 5)
        }
        book.heartbeatAnswered(device, "p12", 999_999)
        val health = book.snapshot(device, discoverySeesNow = true, batteryOptimisationExempt = true, nowMillis = at(27, 10))
        assertEquals(60L, health.lastRttMillis)
        assertEquals(10, health.rttSamples)
        assertEquals("Median of 15..60", 35L, health.medianRttMillis)
        assertEquals(RouteClass.SAME_NETWORK, health.route)
        assertEquals(true, health.dialledHere)
    }

    @Test fun reconnectAttemptsCountSinceLocalMidnight() {
        val book = ConnectionHealthBook { zone }
        book.dialAttempt(device, at(26, 23, 50))
        book.dialAttempt(device, at(26, 23, 55))
        assertEquals(2, book.snapshot(device, false, null, at(26, 23, 59)).reconnectAttemptsToday)
        assertEquals("A new day starts at zero", 0, book.snapshot(device, false, null, at(27, 0, 5)).reconnectAttemptsToday)
        book.dialAttempt(device, at(27, 0, 10))
        assertEquals(1, book.snapshot(device, false, null, at(27, 1)).reconnectAttemptsToday)
    }

    @Test fun disconnectKeepsAReasonTokenAndClearsTheRoute() {
        val book = ConnectionHealthBook { zone }
        book.connected(device, "100.71.43.72", dialledHere = false, wallMillis = at(27, 9))
        book.disconnected(device, "Connect to 192.168.1.20:42458 failed: ECONNRESET", at(27, 9, 30))
        val health = book.snapshot(device, false, false, at(27, 10))
        assertFalse(health.connected)
        assertEquals(RouteClass.UNKNOWN, health.route)
        assertNull(health.dialledHere)
        assertEquals("connect_to_addr_42458_failed__econnreset", health.lastDisconnectReason)
    }

    @Test fun exportedHealthHasNoAddressNameOrFullId() {
        val book = ConnectionHealthBook { zone }
        book.connected(device, "192.168.1.20", dialledHere = true, wallMillis = at(27, 9))
        book.heartbeatSent(device, "p1", 0)
        book.heartbeatAnswered(device, "p1", 12)
        book.disconnected(device, "reset by 10.0.0.3", at(27, 9, 1))
        book.connected(device, "fd7a:115c:a1e0::5", dialledHere = false, wallMillis = at(27, 9, 2))
        val json = book.snapshot(device, discoverySeesNow = true, batteryOptimisationExempt = false, nowMillis = at(27, 10)).toJson().toString()
        listOf("192.168", "10.0.0.3", "fd7a", "a1e0", "Work MacBook", device).forEach {
            assertFalse("Health export must not contain $it: $json", json.contains(it))
        }
        assertFalse("No IPv4-looking text", Regex("\\d{1,3}(\\.\\d{1,3}){3}").containsMatchIn(json.replace(Regex("\"[0-9T:.Z-]+Z\""), "")))
        assertTrue(json.contains("\"device\":\"a1b2c3d4\""))
        assertTrue(json.contains("\"route\":\"private_network\""))
        assertTrue(json.contains("\"dialledBy\":\"other_device\""))
    }

    @Test fun medianIsTheLowerMiddle() {
        assertNull(medianOf(emptyList()))
        assertEquals(5L, medianOf(listOf(5)))
        assertEquals(5L, medianOf(listOf(9, 5)))
        assertEquals(7L, medianOf(listOf(9, 5, 7)))
    }
}
