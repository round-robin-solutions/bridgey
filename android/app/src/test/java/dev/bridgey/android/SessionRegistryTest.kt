package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionRegistryTest {
    /** Stands in for a socket session; identity is what matters. */
    private class FakeSession(val name: String) {
        var closed = false
        override fun toString() = name
    }

    // The phone's id sorts between the two Macs: it dials "m-zz" and is dialled by "a-mac".
    private val phoneId = "m-phone"
    private val personalMac = "a-mac"
    private val workMac = "z-mac"

    private fun registry() = SessionRegistry<FakeSession>(phoneId)

    private fun SessionRegistry<FakeSession>.connect(session: FakeSession, deviceId: String, initiatedLocally: Boolean): SessionRegistry.Admission<FakeSession> {
        addPending(session, initiatedLocally)
        return authenticate(session, deviceId, session.name)
    }

    @Test
    fun addsSeveralDevicesSideBySide() {
        val registry = registry()
        val personal = FakeSession("Personal Mac")
        val work = FakeSession("Work Mac")
        val third = FakeSession("Studio Mac")
        val fourth = FakeSession("Office Mac")
        assertEquals(SessionRegistry.Admission.Accepted(null), registry.connect(personal, personalMac, initiatedLocally = false))
        assertEquals(SessionRegistry.Admission.Accepted(null), registry.connect(work, workMac, initiatedLocally = true))
        registry.connect(third, "b-mac", initiatedLocally = false)
        registry.connect(fourth, "c-mac", initiatedLocally = false)

        assertEquals(listOf(personalMac, workMac, "b-mac", "c-mac"), registry.connectedIds())
        assertSame(personal, registry.session(personalMac))
        assertSame(work, registry.session(workMac))
        assertEquals(listOf("Personal Mac", "Work Mac", "Studio Mac", "Office Mac"), registry.connections().map { it.peerName })
    }

    /**
     * The reported bug: the phone is connected to the personal Mac, the work Mac is in its
     * verification step, and the personal Mac reconnects (its reconnect timer fired). Before,
     * handle() closed the only session, killing the pairing. Now the reconnect is its own session.
     */
    @Test
    fun pairingSurvivesTrustedDeviceReconnectingMeanwhile() {
        val registry = registry()
        val stale = FakeSession("Personal Mac (old)")
        registry.connect(stale, personalMac, initiatedLocally = false)

        // The work Mac dials in to pair: pending, waiting for the code to be confirmed.
        val pairing = FakeSession("Work Mac pairing")
        registry.addPending(pairing, initiatedLocally = false)

        // The personal Mac reconnects while the code is on screen.
        val reconnect = FakeSession("Personal Mac (reconnect)")
        registry.addPending(reconnect, initiatedLocally = false)
        assertTrue(registry.isPending(pairing))
        val admission = registry.connect(reconnect, personalMac, initiatedLocally = false)

        // Same dialler (the Mac), so the newer socket replaces the stale one; the pairing is untouched.
        assertEquals(SessionRegistry.Admission.Accepted(stale), admission)
        assertTrue(registry.isPending(pairing))
        assertEquals(listOf(pairing), registry.pendingSessions())
        assertSame(reconnect, registry.session(personalMac))

        // The stale socket's reader ends later: it no longer owns the device, so nothing disconnects.
        assertNull(registry.remove(stale))
        assertSame(reconnect, registry.session(personalMac))

        // The user confirms the code: the work Mac joins without disturbing the personal Mac.
        assertEquals(SessionRegistry.Admission.Accepted(null), registry.authenticate(pairing, workMac, "Work Mac"))
        assertEquals(listOf(personalMac, workMac), registry.connectedIds())
        assertTrue(registry.pendingSessions().isEmpty())
    }

    @Test
    fun duplicateKeepsSocketDialledByLowerId() {
        // a-mac < m-phone: the Mac dials, so its socket (not initiated here) wins either way round.
        val registry = registry()
        val macDialled = FakeSession("mac dialled")
        val phoneDialled = FakeSession("phone dialled")
        registry.connect(macDialled, personalMac, initiatedLocally = false)
        assertEquals(SessionRegistry.Admission.Rejected, registry.connect(phoneDialled, personalMac, initiatedLocally = true))
        assertSame(macDialled, registry.session(personalMac))

        val other = registry()
        other.connect(phoneDialled, personalMac, initiatedLocally = true)
        assertEquals(SessionRegistry.Admission.Accepted(phoneDialled), other.connect(macDialled, personalMac, initiatedLocally = false))
        assertSame(macDialled, other.session(personalMac))
    }

    @Test
    fun duplicateRuleAgreesOnBothEnds() {
        // The phone and the Mac each hold two sockets for the same pair; both must keep the same one.
        val phone = SessionRegistry<String>("m-phone")
        val mac = SessionRegistry<String>("z-mac")
        // Socket A was dialled by the phone (lower id), socket B by the Mac.
        phone.addPending("B", initiatedLocally = false); phone.authenticate("B", "z-mac", "Mac")
        phone.addPending("A", initiatedLocally = true); phone.authenticate("A", "z-mac", "Mac")
        mac.addPending("A", initiatedLocally = false); mac.authenticate("A", "m-phone", "Phone")
        mac.addPending("B", initiatedLocally = true); mac.authenticate("B", "m-phone", "Phone")
        assertEquals("A", phone.session("z-mac"))
        assertEquals("A", mac.session("m-phone"))
    }

    @Test
    fun removeOnlyDisconnectsTheLiveSession() {
        val registry = registry()
        val personal = FakeSession("personal")
        val work = FakeSession("work")
        registry.connect(personal, personalMac, initiatedLocally = false)
        registry.connect(work, workMac, initiatedLocally = true)
        assertEquals(personalMac, registry.remove(personal))
        assertEquals(listOf(workMac), registry.connectedIds())
        assertNull(registry.remove(personal))
        val pending = FakeSession("pending")
        registry.addPending(pending, initiatedLocally = false)
        assertNull(registry.remove(pending))
        assertFalse(registry.isPending(pending))
    }

    @Test
    fun perDeviceStateIsIsolated() {
        val registry = registry()
        registry.connect(FakeSession("personal"), personalMac, initiatedLocally = false)
        registry.connect(FakeSession("work"), workMac, initiatedLocally = true)
        registry.update(personalMac) {
            it.copy(
                battery = RemoteBatteryStatus(80, true),
                ringing = true,
                remoteFeatures = it.remoteFeatures + (BridgeyFeature.CLIPBOARD to false),
                remoteClipboardFiles = true,
            )
        }
        val personal = registry.state(personalMac)!!
        val work = registry.state(workMac)!!
        assertEquals(RemoteBatteryStatus(80, true), personal.battery)
        assertTrue(personal.ringing)
        assertNull(work.battery)
        assertFalse(work.ringing)
        assertFalse(work.remoteClipboardFiles)
        assertEquals(false, personal.remoteFeatures[BridgeyFeature.CLIPBOARD])
        assertEquals(DeviceLinkState().remoteFeatures, work.remoteFeatures)
        assertFalse(registry.update("unknown") { it })
    }

    @Test
    fun replacedDuplicateKeepsDeviceState() {
        val registry = registry()
        val old = FakeSession("old")
        registry.connect(old, personalMac, initiatedLocally = false)
        registry.update(personalMac) { it.copy(battery = RemoteBatteryStatus(42, false)) }
        registry.connect(FakeSession("new"), personalMac, initiatedLocally = false)
        assertEquals(RemoteBatteryStatus(42, false), registry.state(personalMac)!!.battery)
    }

    @Test
    fun broadcastTargetsOnlyDevicesWithTheFeature() {
        val registry = registry()
        val personal = FakeSession("personal")
        val work = FakeSession("work")
        val third = FakeSession("third")
        registry.connect(personal, personalMac, initiatedLocally = false)
        registry.connect(work, workMac, initiatedLocally = true)
        registry.connect(third, "b-mac", initiatedLocally = false)
        registry.update(workMac) { it.copy(remoteFeatures = it.remoteFeatures + (BridgeyFeature.NOTIFICATIONS to false)) }
        val localOff = setOf("b-mac")
        val targets = registry.broadcastTargets { id, state ->
            id !in localOff && state.remoteFeatures[BridgeyFeature.NOTIFICATIONS] != false
        }
        assertEquals(listOf(personalMac to personal), targets)
        // Pending (pairing) sessions never receive broadcasts.
        registry.addPending(FakeSession("pairing"), initiatedLocally = false)
        assertEquals(3, registry.broadcastTargets { _, _ -> true }.size)
    }

    @Test
    fun targetIsSelectionWhileConnectedElseLatest() {
        val registry = registry()
        assertNull(registry.target(null))
        registry.connect(FakeSession("personal"), personalMac, initiatedLocally = false)
        registry.connect(FakeSession("work"), workMac, initiatedLocally = true)
        assertEquals(workMac, registry.target(null))
        assertEquals(personalMac, registry.target(personalMac))
        assertEquals(workMac, registry.target("offline-mac"))
    }

    @Test
    fun backoffIsPerDevice() {
        val backoff = ReconnectBackoff()
        assertTrue(backoff.mayDial(workMac, 0))
        backoff.dialed(workMac, 0)
        assertFalse(backoff.mayDial(workMac, 500))
        assertTrue(backoff.mayDial("other-mac", 500))
        assertTrue(backoff.mayDial(workMac, 1_000))
        backoff.dialed(workMac, 1_000)
        assertEquals(2_000, backoff.waitMillis(workMac, 1_000))
        backoff.connected(workMac)
        assertTrue(backoff.mayDial(workMac, 1_000))
    }

    @Test
    fun notificationStatusCountsDevices() {
        val one = listOf(DeviceConnection(personalMac, "Personal Mac", DeviceLinkState()))
        val two = one + DeviceConnection(workMac, "Work Mac", DeviceLinkState())
        assertEquals("Connected to Personal Mac", connectionStatus(one, PairingState.Idle))
        assertEquals("Connected to 2 devices", connectionStatus(two, PairingState.Idle))
        assertEquals("Connected to Personal Mac · pairing confirmation required", connectionStatus(one, PairingState.Verification("Work Mac", "123456")))
        assertEquals("Pairing confirmation required", connectionStatus(emptyList(), PairingState.Verification("Work Mac", "123456")))
        assertEquals("Connecting to Work Mac…", connectionStatus(emptyList(), PairingState.Connecting("Work Mac")))
        assertEquals("Not connected · waiting for paired device", connectionStatus(emptyList(), PairingState.Idle))
    }
}
