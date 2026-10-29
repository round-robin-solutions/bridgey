package dev.bridgey.android

import dev.bridgey.android.ui.RingState
import dev.bridgey.android.ui.deviceRings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HeldDevicesTest {
    @Test fun aDeviceDisconnectedByTheUserStaysHeldUntilReleased() {
        val held = HeldDevices()
        held.hold("mac-a")
        assertTrue(held.isHeld("mac-a"))
        assertFalse(held.isHeld("mac-b"))
        assertEquals(setOf("mac-a"), held.all())
        held.release("mac-a")
        assertFalse(held.isHeld("mac-a"))
    }

    @Test fun aHeldMacShowsDisconnectedNotReconnecting() {
        val trusted = listOf(TrustedDevice("mac-a", "Studio"))
        val held = mapOf("mac-a" to ReconnectDisplay(lastSeenMillis = 1L, struggling = false, disconnectedByUser = true))
        val ring = deviceRings(trusted, emptyList(), emptyList(), PairingState.Idle, held).single()
        assertEquals(RingState.OFFLINE, ring.state)
        val retrying = mapOf("mac-a" to ReconnectDisplay(lastSeenMillis = 1L, struggling = false))
        assertEquals(RingState.CONNECTING, deviceRings(trusted, emptyList(), emptyList(), PairingState.Idle, retrying).single().state)
    }
}
