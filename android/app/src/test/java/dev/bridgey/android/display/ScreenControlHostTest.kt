package dev.bridgey.android.display

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The host reducer ported from rust/proto/src/screen_control.rs (its tests are mirrored here by name): the phone is the
 * host when a Mac controls it. Pure synthetic tests: no gesture is dispatched.
 */
class ScreenControlHostTest {
    private val all = InputCapabilities(pointer = true, touch = true, keys = true, text = true, navigation = true)
    private val peer = PeerIdentity(ByteArray(16) { 1 }, ByteArray(32) { 2 })
    private val binding = ControlBinding(peer, 1, ByteArray(16) { 7 })
    private val geometry = Geometry(1, 9, SourceKind.DISPLAY, 1920, 1080)

    private fun authority(generation: Long = 1, edit: ControlAuthority.() -> ControlAuthority = { this }): ControlAuthority = ControlAuthority(
        generation = generation, binding = binding, stream = 4, trustedDevice = true, viewGrant = true, controlGrant = true,
        captureReady = true, inputReady = true, unlocked = true, streamActive = true,
        host = Capabilities(screenSource = true, fullDisplaySource = true, h264Encode = true, inputHost = all, captureRequiresPrompt = true),
        controller = Capabilities(screenViewer = true, h264Decode = true, inputController = all),
    ).edit()

    private fun packet(info: ControlSessionInfo, seq: Long, input: ControlInput, geometry: Long = info.geometry.generation) =
        ControlPacket(info.session, info.transport, info.connection, info.stream, geometry, seq, input)

    private fun ready(): Triple<ScreenControlHost, ControlAuthority, ControlSessionInfo> {
        val host = ScreenControlHost()
        val authority = authority()
        val info = host.begin(authority, geometry, 0).getOrThrow()
        assertEquals(ControlStatus.Accepted, host.receive(authority, authority.binding, packet(info, 1, ControlInput.GeometryAck), 0).status)
        return Triple(host, authority, info)
    }

    @Test fun goldenPacketsAreAcceptedInOrder() {
        val root = File(System.getProperty("bridgey.repoRoot") ?: "../..")
        val fixture = JSONObject(File(root, "rust/proto/test-vectors/screen-control-v1.json").readText(Charsets.UTF_8))
        val host = ScreenControlHost()
        val local = authority()
        val info = host.begin(local, geometry, 0).getOrThrow()
        assertEquals(1L, info.session)
        val packets = fixture.getJSONArray("packets")
        assertTrue("touch and navigate packets are in the vectors", packets.length() >= 18)
        for (index in 0 until packets.length()) {
            val decoded = ControlPacket.decode(packets.getJSONObject(index).toString().toByteArray())!!
            assertEquals("packet ${index + 1}", ControlStatus.Accepted, host.receive(local, local.binding, decoded, index.toLong()).status)
        }
        assertTrue("every contact went up again", host.held.isEmpty)
    }

    @Test fun pairingOrAnOsPermissionAloneDoesNotGrantControl() {
        assertEquals(ControlRejection.GRANT, ScreenControlHost.reasonOf(ScreenControlHost().begin(authority { copy(controlGrant = false) }, geometry, 0).exceptionOrNull()!!))
        assertEquals(ControlRejection.GRANT, ScreenControlHost.reasonOf(ScreenControlHost().begin(authority { copy(viewGrant = false) }, geometry, 0).exceptionOrNull()!!))
        assertEquals(ControlRejection.IDENTITY, ScreenControlHost.reasonOf(ScreenControlHost().begin(authority { copy(trustedDevice = false) }, geometry, 0).exceptionOrNull()!!))
        assertEquals(ControlRejection.PERMISSION, ScreenControlHost.reasonOf(ScreenControlHost().begin(authority { copy(inputReady = false) }, geometry, 0).exceptionOrNull()!!))
        assertEquals(ControlRejection.LOCKED, ScreenControlHost.reasonOf(ScreenControlHost().begin(authority { copy(unlocked = false) }, geometry, 0).exceptionOrNull()!!))
        assertEquals(ControlRejection.NO_STREAM, ScreenControlHost.reasonOf(ScreenControlHost().begin(authority { copy(streamActive = false) }, geometry, 0).exceptionOrNull()!!))
    }

    @Test fun windowGeometryIsNeverControlCapable() {
        val window = geometry.copy(kind = SourceKind.WINDOW)
        assertEquals(ControlRejection.GEOMETRY, ScreenControlHost.reasonOf(ScreenControlHost().begin(authority(), window, 0).exceptionOrNull()!!))
    }

    @Test fun inputWaitsForTheGeometryAcknowledgement() {
        val host = ScreenControlHost()
        val authority = authority()
        val info = host.begin(authority, geometry, 0).getOrThrow()
        val tap = ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5)
        assertEquals(ControlStatus.Rejected(ControlRejection.GEOMETRY_NOT_ACKNOWLEDGED), host.receive(authority, binding, packet(info, 1, tap), 0).status)
        assertEquals(ControlStatus.Accepted, host.receive(authority, binding, packet(info, 2, ControlInput.GeometryAck), 0).status)
        assertEquals(ControlStatus.Accepted, host.receive(authority, binding, packet(info, 3, tap), 0).status)
    }

    @Test fun revocationEndsHoldsAndOldAuthorityCannotReenableIt() {
        val (host, authority, info) = ready()
        assertEquals(ControlStatus.Accepted, host.receive(authority, binding, packet(info, 2, ControlInput.Touch(3, TouchPhase.DOWN, 0.2, 0.2)), 1).status)
        val revoked = host.synchronize(authority(generation = 2) { copy(controlGrant = false) })
        assertEquals(ControlStatus.Stopped(ControlStopReason.REVOKED), revoked.status)
        assertEquals(listOf(3), revoked.release.heldContacts)
        // The old enabled snapshot is older than what the host has seen.
        assertTrue(host.begin(authority, geometry, 2).isFailure)
        assertEquals(ControlRejection.AUTHORITY_REPLAY, ScreenControlHost.reasonOf(host.begin(authority, geometry, 2).exceptionOrNull()!!))
    }

    @Test fun reusingAnAuthorityGenerationBurnsIt() {
        val host = ScreenControlHost()
        assertTrue(host.begin(authority(), geometry, 0).isSuccess)
        // The same generation with different state stops, and the generation stays burnt.
        assertEquals(ControlStatus.Stopped(ControlStopReason.AUTHORITY_CHANGED), host.synchronize(authority { copy(unlocked = true, inputReady = true, captureReady = true, stream = 5) }).status)
        assertTrue(host.begin(authority(), geometry, 0).isFailure)
        assertTrue(host.begin(authority(generation = 2), geometry, 0).isSuccess)
    }

    @Test fun stopFencesAPendingBegin() {
        val host = ScreenControlHost()
        assertEquals(ControlStatus.Accepted, host.synchronize(authority(generation = 3)).status)
        host.stop(ControlStopReason.USER)
        assertTrue(host.begin(authority(generation = 3), geometry, 0).isFailure)
        assertTrue(host.begin(authority(generation = 4), geometry, 0).isSuccess)
    }

    @Test fun aWrongGeometryReleaseCannotLeaveAFingerHeldByHeartbeats() {
        val (host, authority, info) = ready()
        host.receive(authority, binding, packet(info, 2, ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5)), 1)
        val stale = host.receive(authority, binding, packet(info, 3, ControlInput.Touch(0, TouchPhase.UP, 0.5, 0.5), geometry = 7), 2)
        assertEquals(ControlStatus.Stopped(ControlStopReason.GEOMETRY_INVALID), stale.status)
        assertEquals(listOf(0), stale.release.heldContacts)
    }

    @Test fun rotationReleasesHoldsAndNeedsANewAcknowledgement() {
        val (host, authority, info) = ready()
        host.receive(authority, binding, packet(info, 2, ControlInput.Touch(1, TouchPhase.DOWN, 0.5, 0.5)), 1)
        val rotated = geometry.copy(generation = 2, width = 1080, height = 1920)
        val changed = host.geometryChanged(info, rotated)
        assertEquals(ControlStatus.Accepted, changed.status)
        assertEquals(listOf(1), changed.release.heldContacts)
        assertFalse(host.acknowledged)
        val next = host.info!!
        // Old-geometry input is refused (nothing is held any more), and so is new input before the acknowledgement.
        assertEquals(ControlStatus.Rejected(ControlRejection.GEOMETRY), host.receive(authority, binding, packet(info, 3, ControlInput.Touch(1, TouchPhase.DOWN, 0.1, 0.1)), 2).status)
        assertEquals(ControlStatus.Rejected(ControlRejection.GEOMETRY_NOT_ACKNOWLEDGED), host.receive(authority, binding, packet(next, 4, ControlInput.Touch(1, TouchPhase.DOWN, 0.1, 0.1)), 2).status)
        assertEquals(ControlStatus.Accepted, host.receive(authority, binding, packet(next, 5, ControlInput.GeometryAck), 3).status)
        assertEquals(ControlStatus.Accepted, host.receive(authority, binding, packet(next, 6, ControlInput.Touch(1, TouchPhase.DOWN, 0.1, 0.1)), 3).status)
    }

    @Test fun anOldCaptureCallbackCannotResizeANewSession() {
        val (host, _, info) = ready()
        val other = ControlSessionInfo(info.session + 1, info.transport, info.connection, info.stream, info.geometry)
        assertEquals(ControlStatus.Rejected(ControlRejection.SESSION), host.geometryChanged(other, geometry.copy(generation = 2)).status)
        assertEquals(ControlStatus.Rejected(ControlRejection.GEOMETRY), host.geometryChanged(info, geometry).status)
        assertEquals(ControlStatus.Stopped(ControlStopReason.GEOMETRY_INVALID), host.geometryChanged(info, geometry.copy(width = 1000)).status)
    }

    @Test fun anotherSourceStopsInsteadOfRetargeting() {
        val (host, _, info) = ready()
        assertEquals(ControlStatus.Stopped(ControlStopReason.SOURCE_CHANGED), host.geometryChanged(info, geometry.copy(generation = 2, source = 10)).status)
        assertFalse(host.isActive)
    }

    @Test fun aSequenceGapReleasesHolds() {
        val (host, authority, info) = ready()
        host.receive(authority, binding, packet(info, 2, ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5)), 1)
        val gap = host.receive(authority, binding, packet(info, 4, ControlInput.Heartbeat), 2)
        assertEquals(ControlStatus.Stopped(ControlStopReason.SEQUENCE_GAP), gap.status)
        assertEquals(listOf(0), gap.release.heldContacts)
    }

    @Test fun duplicatesAndOtherBindingsNeverInjectAgain() {
        val (host, authority, info) = ready()
        val tap = packet(info, 2, ControlInput.Navigate(ControlNavigation.BACK))
        assertEquals(ControlStatus.Accepted, host.receive(authority, binding, tap, 1).status)
        assertEquals(ControlStatus.Rejected(ControlRejection.REPLAY), host.receive(authority, binding, tap, 1).status)
        val elsewhere = ControlBinding(peer, 1, ByteArray(16) { 8 })
        assertEquals(ControlStatus.Rejected(ControlRejection.BINDING), host.receive(authority, elsewhere, packet(info, 3, ControlInput.Heartbeat), 1).status)
    }

    @Test fun stopReturnsEveryHeldInputOnceAndIsNeverRateLimited() {
        val (host, authority, info) = ready()
        host.receive(authority, binding, packet(info, 2, ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5)), 1)
        host.receive(authority, binding, packet(info, 3, ControlInput.Key(ControlKey.SHIFT, true)), 1)
        host.receive(authority, binding, packet(info, 4, ControlInput.Button(ControlButton.PRIMARY, true, 0.5, 0.5)), 1)
        // Use up the control budget; Stop still goes through.
        var seq = 5L
        repeat(12) { host.receive(authority, binding, packet(info, seq++, ControlInput.Heartbeat), 1) }
        val stopped = host.receive(authority, binding, packet(info, seq, ControlInput.Stop), 1)
        assertEquals(ControlStatus.Stopped(ControlStopReason.USER), stopped.status)
        assertEquals(listOf(0), stopped.release.heldContacts)
        assertEquals(listOf(ControlKey.SHIFT), stopped.release.heldKeys)
        assertEquals(listOf(ControlButton.PRIMARY), stopped.release.heldButtons)
        assertTrue(host.stop(ControlStopReason.USER).release.isEmpty)
    }

    @Test fun aRateLimitedTransitionStopsRatherThanStick() {
        val (host, authority, info) = ready()
        var seq = 2L
        var last: ControlTransition? = null
        // 20 discrete a second: the 21st down/up in the same millisecond stops control.
        repeat(11) {
            last = host.receive(authority, binding, packet(info, seq++, ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5)), 5)
            if (last!!.status == ControlStatus.Accepted) last = host.receive(authority, binding, packet(info, seq++, ControlInput.Touch(0, TouchPhase.UP, 0.5, 0.5)), 5)
        }
        assertEquals(ControlStatus.Stopped(ControlStopReason.RATE_LIMITED), last!!.status)
    }

    @Test fun invalidInputDoesNotExtendLiveness() {
        val (host, authority, info) = ready()
        assertEquals(ControlStatus.Rejected(ControlRejection.COORDINATES), host.receive(authority, binding, packet(info, 2, ControlInput.Touch(0, TouchPhase.DOWN, 1.5, 0.5)), 5_000).status)
        assertEquals(ControlStatus.Stopped(ControlStopReason.TIMEOUT), host.tick(6_000).status)
    }

    @Test fun clockReversalStops() {
        val (host, _, _) = ready()
        assertEquals(ControlStatus.Accepted, host.tick(100).status)
        assertEquals(ControlStatus.Stopped(ControlStopReason.CLOCK), host.tick(50).status)
    }

    @Test fun countersFailClosedWithoutWrapping() {
        val host = ScreenControlHost()
        host.testingSetLastSession(ScreenControl.MAX_SEQUENCE)
        assertEquals(ControlRejection.EXHAUSTED, ScreenControlHost.reasonOf(host.begin(authority(), geometry, 0).exceptionOrNull()!!))
        val (ready, authority, info) = ready()
        ready.testingSetSequence(ScreenControl.MAX_SEQUENCE - 1)
        assertEquals(ControlStatus.Stopped(ControlStopReason.EXHAUSTED), ready.receive(authority, binding, packet(info, ScreenControl.MAX_SEQUENCE, ControlInput.Heartbeat), 1).status)
    }

    @Test fun touchTransitionsMustMatchWhatIsHeld() {
        val (host, authority, info) = ready()
        assertEquals(ControlStatus.Rejected(ControlRejection.INVALID_INPUT), host.receive(authority, binding, packet(info, 2, ControlInput.Touch(0, TouchPhase.MOVE, 0.5, 0.5)), 1).status)
        assertEquals(ControlStatus.Rejected(ControlRejection.INVALID_INPUT), host.receive(authority, binding, packet(info, 3, ControlInput.Touch(0, TouchPhase.UP, 0.5, 0.5)), 1).status)
        assertEquals(ControlStatus.Rejected(ControlRejection.COORDINATES), host.receive(authority, binding, packet(info, 4, ControlInput.Touch(10, TouchPhase.DOWN, 0.5, 0.5)), 1).status)
        assertEquals(ControlStatus.Accepted, host.receive(authority, binding, packet(info, 5, ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5)), 1).status)
        // A second down for a held contact is an invalid transition while something is held: control ends.
        assertEquals(ControlStatus.Stopped(ControlStopReason.INVALID_INPUT), host.receive(authority, binding, packet(info, 6, ControlInput.Touch(0, TouchPhase.DOWN, 0.5, 0.5)), 1).status)
    }

    @Test fun capabilitiesTheControllerLacksAreUnsupported() {
        val reducer = ScreenControlHost()
        val noTyping = authority { copy(host = host.copy(inputHost = all.copy(keys = false, text = false))) }
        val info = reducer.begin(noTyping, geometry, 0).getOrThrow()
        reducer.receive(noTyping, binding, packet(info, 1, ControlInput.GeometryAck), 0)
        assertEquals(ControlStatus.Rejected(ControlRejection.UNSUPPORTED), reducer.receive(noTyping, binding, packet(info, 2, ControlInput.Text("hi")), 1).status)
        assertEquals(ControlStatus.Accepted, reducer.receive(noTyping, binding, packet(info, 3, ControlInput.Navigate(ControlNavigation.HOME)), 1).status)
    }

    @Test fun aBusyHostRefusesASecondController() {
        val (host, _, _) = ready()
        assertEquals(ControlRejection.BUSY, ScreenControlHost.reasonOf(host.begin(authority(generation = 2), geometry, 0).exceptionOrNull()!!))
        assertNotNull(host.info)
        assertNull(ScreenControlHost().info)
    }
}
