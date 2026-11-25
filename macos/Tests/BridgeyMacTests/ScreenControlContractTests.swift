import Foundation
import XCTest
@testable import BridgeyMac

/// The shared screen/control contract (ScreenControlContract.swift), checked like rust/proto/src/screen_control/tests.rs
/// against rust/proto/test-vectors/screen-control-v1.json. Pure synthetic tests: no capture, no injection.
final class ScreenControlContractTests: XCTestCase {
    typealias SC = ScreenControl

    private static let fixture: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../rust/proto/test-vectors/screen-control-v1.json").standardizedFileURL
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }()

    private func inputs() -> SC.InputCapabilities { SC.InputCapabilities(pointer: true, touch: true, keys: true, text: true, navigation: true) }

    private func authority() -> SC.Authority {
        SC.Authority(
            generation: 1,
            binding: SC.Binding(peer: SC.PeerIdentity(device: Array(repeating: 1, count: 16), keySHA256: Array(repeating: 2, count: 32)),
                                transport: 1, connection: Array(repeating: 7, count: 16)),
            stream: 4, trustedDevice: true, viewGrant: true, controlGrant: true, captureReady: true, inputReady: true, unlocked: true,
            streamActive: true,
            host: SC.Capabilities(v: 1, screenSource: true, fullDisplaySource: true, h264Encode: true, inputHost: inputs(),
                                  captureRequiresPrompt: true),
            controller: SC.Capabilities(v: 1, screenViewer: true, h264Decode: true, inputController: inputs()))
    }

    private func geometry() -> SC.Geometry { SC.Geometry(generation: 1, source: 9, kind: .display, width: 1920, height: 1080) }

    private func packet(_ info: SC.SessionInfo, _ seq: UInt64, _ input: SC.Input) -> SC.Packet {
        SC.Packet(v: 1, session: info.session, transport: info.transport, connection: info.connection, stream: info.stream,
                  geometry: info.geometry.generation, seq: seq, input: input)
    }

    private func ready() throws -> (SC.HostSession, SC.Authority, SC.SessionInfo) {
        var host = SC.HostSession()
        let local = authority()
        let info = try host.begin(local, geometry: geometry(), nowMs: 0).get()
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 1, .geometryAck), nowMs: 0).status, .accepted)
        return (host, local, info)
    }

    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func isStopped(_ status: SC.Status) -> Bool { if case .stopped = status { return true } else { return false } }
    private func isRejected(_ status: SC.Status) -> Bool { if case .rejected = status { return true } else { return false } }

    // MARK: Golden wire

    func testGoldenWireCapabilitiesGeometryAndPackets() throws {
        let fixture = Self.fixture
        XCTAssertEqual(fixture["protocol"] as? String, SC.protocolName)
        let local = authority()
        for (name, expected) in [("host", local.host), ("controller", local.controller)] {
            let object = try XCTUnwrap(fixture[name])
            XCTAssertEqual(SC.Capabilities.decode(try data(object)), .success(expected), name)
            XCTAssertEqual(expected.json as NSDictionary, object as? NSDictionary, name)
        }
        XCTAssertEqual(SC.Geometry.decode(fixture["geometry"]), geometry())
        XCTAssertEqual(geometry().json as NSDictionary, fixture["geometry"] as? NSDictionary)
        var host = SC.HostSession()
        let info = try host.begin(local, geometry: geometry(), nowMs: 0).get()
        let packets = try XCTUnwrap(fixture["packets"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(packets.count, 4)
        for (index, value) in packets.enumerated() {
            let decoded = try SC.Packet.decode(try data(value)).get()
            XCTAssertEqual(decoded.json as NSDictionary, value as NSDictionary, "packet \(index + 1)")
            XCTAssertEqual(try SC.Packet.decode(decoded.encoded()).get(), decoded)
            XCTAssertEqual(decoded.seq, UInt64(index + 1))
            XCTAssertEqual(host.receive(local, sender: local.binding, packet: decoded, nowMs: UInt64(index)).status, .accepted,
                           "packet \(index + 1)")
        }
        XCTAssertEqual(info.session, 1)
        XCTAssertEqual(geometry().pixel(0.25, 0.75), SC.PixelPoint(x: 480, y: 809))
        let invalid = try XCTUnwrap(fixture["invalidPackets"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(invalid.count, 3)
        for value in invalid {
            if case .success = SC.Packet.decode(try data(value)) { XCTFail("accepted \(value)") }
        }
    }

    func testUnknownCapabilitiesNeverCreatePermissionOrAssumePlatformRoles() throws {
        let missing = try SC.Capabilities.decode(Data(#"{"v":1,"futureCapability":true}"#.utf8)).get()
        XCTAssertEqual(missing.inputHost, SC.InputCapabilities())
        XCTAssertFalse(missing.screenSource)
        XCTAssertEqual(SC.Capabilities.negotiatedInput(host: missing, controller: authority().controller), .failure(.unsupported))
        XCTAssertEqual(SC.Capabilities.decode(Data(#"{"v":2,"screenSource":true}"#.utf8)), .failure(.version))
        XCTAssertEqual(SC.Capabilities.decode(Data(#"{"screenSource":true}"#.utf8)), .failure(.version))
        XCTAssertEqual(SC.Capabilities.decode(Data(#"{"v":1,"screenSource":"yes"}"#.utf8)), .failure(.malformed))
        XCTAssertEqual(SC.Capabilities.decode(Data(repeating: 0x20, count: SC.maxPacketBytes + 1)), .failure(.packetSize))
    }

    func testNegotiatedRolesIntersectWithoutInventingTextSupport() throws {
        var local = authority()
        local.host.inputHost.text = false
        let input = try SC.Capabilities.negotiatedInput(host: local.host, controller: local.controller).get()
        XCTAssertFalse(input.text)
        XCTAssertTrue(input.pointer && input.navigation)
        local.host.inputHost = SC.InputCapabilities()
        XCTAssertEqual(SC.Capabilities.negotiatedInput(host: local.host, controller: local.controller), .failure(.unsupported))
    }

    // MARK: Grants and authority

    func testPairingOrAnOSPermissionAloneDoesNotGrantControl() {
        for change in 0..<8 {
            var local = authority()
            switch change {
            case 0: local.trustedDevice = false
            case 1: local.viewGrant = false
            case 2: local.controlGrant = false
            case 3: local.captureReady = false
            case 4: local.inputReady = false
            case 5: local.unlocked = false
            case 6: local.streamActive = false
            default: local.binding.peer.keySHA256 = Array(repeating: 0, count: 32)
            }
            var host = SC.HostSession()
            if case .success = host.begin(local, geometry: geometry(), nowMs: 0) { XCTFail("case \(change)") }
        }
    }

    func testAuthorityCountersAndTransportNonceAreRequired() {
        for invalid in [0, SC.maxSequence + 1, UInt64.max] {
            for field in 0..<3 {
                var local = authority()
                switch field {
                case 0: local.generation = invalid
                case 1: local.binding.transport = invalid
                default: local.stream = invalid
                }
                var host = SC.HostSession()
                XCTAssertEqual(host.begin(local, geometry: geometry(), nowMs: 0), .failure(.counter))
            }
        }
        var local = authority()
        local.binding.connection = Array(repeating: 0, count: 16)
        var host = SC.HostSession()
        XCTAssertEqual(host.begin(local, geometry: geometry(), nowMs: 0), .failure(.binding))
    }

    func testExactPinnedSenderAndCurrentTransportAreRequiredWithoutStoppingAnotherPeer() throws {
        var (host, local, info) = try ready()
        let input = packet(info, 2, .pointer(x: 0.2, y: 0.8))
        for field in 0..<4 {
            var sender = local.binding
            switch field {
            case 0: sender.peer.device[0] ^= 1
            case 1: sender.peer.keySHA256[0] ^= 1
            case 2: sender.transport += 1
            default: sender.connection[0] ^= 1
            }
            XCTAssertEqual(host.receive(local, sender: sender, packet: input, nowMs: 0).status, .rejected(.binding))
            XCTAssertEqual(host.info, info)
        }
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: input, nowMs: 0).status, .accepted)
    }

    func testAProcessRestartCannotReuseAnOldPacketOnANewTransport() throws {
        let (_, local, oldInfo) = try ready()
        let old = packet(oldInfo, 1, .geometryAck)
        var restarted = SC.HostSession()
        var newLocal = local
        newLocal.binding.connection = Array(repeating: 8, count: 16)
        let newInfo = try restarted.begin(newLocal, geometry: geometry(), nowMs: 0).get()
        XCTAssertEqual(newInfo.session, oldInfo.session, "counter reuse alone must not authorise old packets")
        XCTAssertEqual(restarted.receive(newLocal, sender: newLocal.binding, packet: old, nowMs: 0).status, .rejected(.binding))
        var fresh = old
        fresh.connection = newLocal.binding.connection
        XCTAssertEqual(restarted.receive(newLocal, sender: newLocal.binding, packet: fresh, nowMs: 0).status, .accepted)
    }

    func testRevocationEndsHoldsAndOldAuthorityCannotReenableIt() throws {
        var (host, local, info) = try ready()
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 2, .key(.shift, down: true)), nowMs: 0).status, .accepted)
        var revoked = local
        revoked.generation = 2
        revoked.controlGrant = false
        let stopped = host.synchronize(revoked)
        XCTAssertEqual(stopped.status, .stopped(.revoked))
        XCTAssertNotEqual(stopped.release.keys, 0)
        XCTAssertEqual(host.begin(local, geometry: geometry(), nowMs: 0), .failure(.authorityReplay))
        XCTAssertEqual(host.stop(.user).release, SC.HeldInput())
        var regranted = local
        regranted.generation = 3
        XCTAssertNoThrow(try host.begin(regranted, geometry: geometry(), nowMs: 0).get())
        let current = host.info
        XCTAssertEqual(host.synchronize(local).status, .rejected(.authorityReplay))
        XCTAssertEqual(host.info, current, "an obsolete callback cannot stop the newer authorised session")
    }

    func testReusingAnAuthorityGenerationBurnsItInsteadOfRestoringAStaleGrant() throws {
        var (host, local, _) = try ready()
        var changed = local
        changed.controlGrant = false
        XCTAssertEqual(host.synchronize(changed).status, .stopped(.authorityChanged))
        XCTAssertEqual(host.begin(local, geometry: geometry(), nowMs: 0), .failure(.authorityReplay))
        var fresh = local
        fresh.generation += 1
        XCTAssertNoThrow(try host.begin(fresh, geometry: geometry(), nowMs: 0).get())
    }

    func testStopFencesAPendingNativeBeginBeforeAnyActiveSessionExists() {
        var host = SC.HostSession()
        let local = authority()
        XCTAssertEqual(host.synchronize(local).status, .accepted)
        XCTAssertEqual(host.stop(.user).release, SC.HeldInput())
        XCTAssertEqual(host.begin(local, geometry: geometry(), nowMs: 0), .failure(.authorityReplay))
        var fresh = local
        fresh.generation += 1
        XCTAssertNoThrow(try host.begin(fresh, geometry: geometry(), nowMs: 0).get())
    }

    // MARK: Geometry

    func testAWrongGeometryReleaseCannotLeaveNativeInputHeldByHeartbeats() throws {
        let transitions: [(SC.Input, SC.Input)] = [
            (.button(.primary, down: true, x: 0.5, y: 0.5), .button(.primary, down: false, x: 0.5, y: 0.5)),
            (.key(.shift, down: true), .key(.shift, down: false)),
            (.touch(contact: 0, phase: .down, x: 0.5, y: 0.5), .touch(contact: 0, phase: .up, x: 0.5, y: 0.5)),
        ]
        for (down, up) in transitions {
            var (host, local, info) = try ready()
            XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 2, down), nowMs: 0).status, .accepted)
            let held = host.held
            XCTAssertFalse(held.isEmpty)
            var stale = packet(info, 3, up)
            stale.geometry += 1
            let stopped = host.receive(local, sender: local.binding, packet: stale, nowMs: 0)
            XCTAssertEqual(stopped.status, .stopped(.geometryInvalid))
            XCTAssertEqual(stopped.release, held)
            XCTAssertTrue(host.held.isEmpty)
            XCTAssertNotEqual(host.receive(local, sender: local.binding, packet: packet(info, 4, .heartbeat), nowMs: 1).status, .accepted)
            XCTAssertNil(host.info)
        }
    }

    func testAnOldCaptureCallbackCannotResizeOrStopANewControlSession() throws {
        var (host, local, old) = try ready()
        _ = host.stop(.user)
        var fresh = local
        fresh.generation += 1
        fresh.stream += 1
        let current = try host.begin(fresh, geometry: geometry(), nowMs: 0).get()
        var resized = geometry()
        resized.generation = 2
        resized.width = 1080
        resized.height = 1920
        XCTAssertEqual(host.geometryChanged(expected: old, geometry: resized).status, .rejected(.session))
        XCTAssertEqual(host.info, current)
        var wrongChannel = current
        wrongChannel.connection[0] ^= 1
        XCTAssertEqual(host.geometryChanged(expected: wrongChannel, geometry: resized).status, .rejected(.session))
        XCTAssertEqual(host.info, current)
        XCTAssertEqual(host.geometryChanged(expected: current, geometry: resized).status, .accepted)
    }

    func testChangedPermissionLockStreamOrBindingStopsBeforeNextInput() throws {
        for field in 0..<5 {
            var (host, local, info) = try ready()
            var changed = local
            changed.generation += 1
            switch field {
            case 0: changed.captureReady = false
            case 1: changed.inputReady = false
            case 2: changed.unlocked = false
            case 3: changed.streamActive = false
            default: changed.binding.transport += 1
            }
            XCTAssertTrue(isStopped(host.receive(changed, sender: local.binding, packet: packet(info, 2, .pointer(x: 0.5, y: 0.5)), nowMs: 0).status))
            XCTAssertNil(host.info)
        }
    }

    func testResizeReleasesHoldsAndRequiresNewGeometryAck() throws {
        var (host, local, info) = try ready()
        _ = host.receive(local, sender: local.binding, packet: packet(info, 2, .button(.primary, down: true, x: 0.25, y: 0.75)), nowMs: 0)
        var changed = geometry()
        changed.generation = 2
        changed.width = 1080
        changed.height = 1920
        let resized = host.geometryChanged(expected: info, geometry: changed)
        XCTAssertEqual(resized.status, .accepted)
        XCTAssertEqual(resized.release.buttons, 1)
        XCTAssertTrue(host.held.isEmpty)
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 3, .pointer(x: 0.5, y: 0.5)), nowMs: 0).status,
                       .rejected(.geometry))
        let current = try XCTUnwrap(host.info)
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(current, 4, .pointer(x: 0.5, y: 0.5)), nowMs: 0).status,
                       .rejected(.geometryNotAcknowledged))
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(current, 5, .geometryAck), nowMs: 0).status, .accepted)
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(current, 6, .pointer(x: 0.5, y: 0.5)), nowMs: 0).status, .accepted)
    }

    func testReplacingTheSourceOrReusingGeometryGenerationStopsInsteadOfRetargeting() throws {
        var g1 = geometry(); g1.generation = 2; g1.source = 10
        var g2 = geometry(); g2.generation = 2; g2.kind = .window
        var g3 = geometry(); g3.width = 1080; g3.height = 1920
        var g4 = geometry(); g4.generation = 2; g4.width = 0
        for changed in [g1, g2, g3, g4] {
            var (host, _, info) = try ready()
            XCTAssertTrue(isStopped(host.geometryChanged(expected: info, geometry: changed).status))
            XCTAssertNil(host.info)
        }
        var (host, _, info) = try ready()
        var next = geometry()
        next.generation = 2
        _ = host.geometryChanged(expected: info, geometry: next)
        XCTAssertEqual(host.geometryChanged(expected: info, geometry: geometry()).status, .rejected(.geometry))
        XCTAssertEqual(host.info?.geometry.generation, 2)
    }

    func testFullDisplayGeometryIsRequired() {
        var bad: [SC.Geometry] = []
        var g = geometry(); g.kind = .window; bad.append(g)
        g = geometry(); g.width = 0; bad.append(g)
        g = geometry(); g.height = 0; bad.append(g)
        g = geometry(); g.width = SC.maxDimension + 1; bad.append(g)
        g = geometry(); g.width = SC.maxDimension; g.height = SC.maxDimension; bad.append(g)
        g = geometry(); g.generation = 0; bad.append(g)
        for geometry in bad {
            var host = SC.HostSession()
            XCTAssertEqual(host.begin(authority(), geometry: geometry, nowMs: 0), .failure(.geometry))
        }
    }

    func testNonfiniteOrOutsidePointsNeverMapToAnotherDisplay() throws {
        var (host, local, info) = try ready()
        for (index, value) in [Double.nan, .infinity, -.infinity, -0.001, 1.001].enumerated() {
            XCTAssertNil(geometry().pixel(value, 0.5))
            XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, UInt64(index) + 2, .pointer(x: value, y: 0.5)), nowMs: 0).status,
                           .rejected(.coordinates))
        }
        XCTAssertEqual(geometry().pixel(0, 0), SC.PixelPoint(x: 0, y: 0))
        XCTAssertEqual(geometry().pixel(1, 1), SC.PixelPoint(x: 1919, y: 1079))
    }

    func testDeterministicCoordinateBoundaryCorpusStaysInsideSelectedPixels() throws {
        var seed: UInt64 = 0x94d0_49bb_1331_11eb
        for _ in 0..<2_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let x = Double(UInt32(truncatingIfNeeded: seed >> 32)) / Double(UInt32.max)
            let y = Double(UInt32(truncatingIfNeeded: seed)) / Double(UInt32.max)
            let point = try XCTUnwrap(geometry().pixel(x, y))
            XCTAssertTrue(point.x < geometry().width && point.y < geometry().height)
            XCTAssertNil(geometry().pixel(x + 1.000_001, y))
        }
    }

    // MARK: Input

    func testButtonsAndScrollHaveTheirOwnPositionNotAStalePointerCache() throws {
        var (host, local, info) = try ready()
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 2, .button(.primary, down: true, x: 0.8, y: 0.2)), nowMs: 0).status,
                       .accepted)
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 3, .button(.primary, down: false, x: .nan, y: 0.2)), nowMs: 0).status,
                       .stopped(.invalidInput))
        XCTAssertTrue(host.held.isEmpty)
        (host, _, _) = try ready()
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 2, .scroll(dx: 0, dy: 10, x: -0.1, y: 0.5)), nowMs: 0).status,
                       .rejected(.coordinates))
        var wire = packet(info, 5, .button(.primary, down: false, x: 0.8, y: 0.2)).json
        var input = try XCTUnwrap(wire["input"] as? [String: Any])
        input.removeValue(forKey: "x")
        wire["input"] = input
        XCTAssertEqual(SC.Packet.decode(try data(wire)), .failure(.malformed))
    }

    func testTextIsStoppedIfNativeFocusIsOutsideTheSelectedSource() throws {
        var (host, local, info) = try ready()
        var ineligible = local
        ineligible.generation += 1
        ineligible.inputReady = false
        XCTAssertEqual(host.receive(ineligible, sender: local.binding, packet: packet(info, 2, .text("synthetic text")), nowMs: 0).status,
                       .stopped(.permissionLost))
        XCTAssertNil(host.info)
    }

    func testStopReturnsAllHeldNativeInputsOnce() throws {
        var (host, local, info) = try ready()
        let inputs: [SC.Input] = [.button(.primary, down: true, x: 0.25, y: 0.75), .key(.control, down: true),
                                  .touch(contact: 3, phase: .down, x: 0.2, y: 0.3)]
        for (index, input) in inputs.enumerated() {
            XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, UInt64(index) + 2, input), nowMs: 0).status, .accepted)
        }
        let held = host.held
        XCTAssertNotEqual(held.buttons, 0)
        XCTAssertNotEqual(held.keys, 0)
        XCTAssertEqual(held.contacts, 1 << 3)
        XCTAssertEqual(host.stop(.disconnected).release, held)
        XCTAssertTrue(host.stop(.user).release.isEmpty)
        XCTAssertNil(host.info)
    }

    func testInvalidHoldTransitionsDoNotInjectDuplicateOrUnmatchedEvents() throws {
        var (host, local, info) = try ready()
        let commands: [SC.Input] = [.button(.primary, down: false, x: 0.25, y: 0.75), .key(.alt, down: false),
                                    .touch(contact: 0, phase: .move, x: 0.2, y: 0.3), .touch(contact: 10, phase: .down, x: 0.2, y: 0.3)]
        for (index, command) in commands.enumerated() {
            XCTAssertTrue(isRejected(host.receive(local, sender: local.binding, packet: packet(info, UInt64(index) + 2, command), nowMs: 0).status))
            XCTAssertTrue(host.held.isEmpty)
        }
    }

    func testDuplicatePacketsAndOldSessionIDsCannotInjectAgain() throws {
        var (host, local, info) = try ready()
        let input = packet(info, 2, .pointer(x: 0.3, y: 0.4))
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: input, nowMs: 0).status, .accepted)
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: input, nowMs: 0).status, .rejected(.replay))
        _ = host.stop(.user)
        XCTAssertEqual(host.begin(local, geometry: geometry(), nowMs: 0), .failure(.authorityReplay))
        var fresh = local
        fresh.generation += 1
        let newInfo = try host.begin(fresh, geometry: geometry(), nowMs: 0).get()
        XCTAssertGreaterThan(newInfo.session, info.session)
        XCTAssertEqual(host.receive(fresh, sender: fresh.binding, packet: input, nowMs: 0).status, .rejected(.session))
    }

    func testAGapOnTheOrderedControlLaneReleasesHolds() throws {
        var (host, local, info) = try ready()
        _ = host.receive(local, sender: local.binding, packet: packet(info, 2, .key(.shift, down: true)), nowMs: 0)
        let result = host.receive(local, sender: local.binding, packet: packet(info, 4, .heartbeat), nowMs: 0)
        XCTAssertEqual(result.status, .stopped(.sequenceGap))
        XCTAssertNotEqual(result.release.keys, 0)
    }

    func testPointerRateLimitDoesNotBlockStop() throws {
        var (host, local, info) = try ready()
        for seq in UInt64(2)..<122 {
            XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, seq, .pointer(x: 0.5, y: 0.5)), nowMs: 0).status, .accepted)
        }
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 122, .pointer(x: 0.5, y: 0.5)), nowMs: 0).status,
                       .rejected(.rate))
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 123, .stop), nowMs: 0).status, .stopped(.user))
    }

    func testARateLimitedDiscreteTransitionReleasesInsteadOfStickingAButton() throws {
        var (host, local, info) = try ready()
        _ = host.receive(local, sender: local.binding, packet: packet(info, 2, .button(.primary, down: true, x: 0.25, y: 0.75)), nowMs: 0)
        for seq in UInt64(3)..<22 {
            XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, seq, .text("a")), nowMs: 0).status, .accepted)
        }
        let result = host.receive(local, sender: local.binding, packet: packet(info, 22, .button(.primary, down: false, x: 0.25, y: 0.75)), nowMs: 0)
        XCTAssertEqual(result.status, .stopped(.rateLimited))
        XCTAssertEqual(result.release.buttons, 1)
    }

    func testInvalidInputsDoNotExtendTheSixSecondLivenessDeadline() throws {
        var (host, local, info) = try ready()
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 2, .pointer(x: .nan, y: 0.5)), nowMs: 5_900).status,
                       .rejected(.coordinates))
        XCTAssertEqual(host.tick(6_000).status, .stopped(.timeout))
        (host, _, _) = try ready()
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 2, .heartbeat), nowMs: 5_000).status, .accepted)
        XCTAssertEqual(host.tick(10_999).status, .accepted)
        XCTAssertEqual(host.tick(11_000).status, .stopped(.timeout))
    }

    func testMonotonicClockReversalStops() throws {
        var (host, local, info) = try ready()
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, 2, .heartbeat), nowMs: 100).status, .accepted)
        XCTAssertEqual(host.tick(99).status, .stopped(.clock))
    }

    func testCountersFailClosedAtJSONSafeLimitsWithoutWrapping() throws {
        var exhausted = SC.HostSession()
        exhausted.testingSetLastSession(SC.maxSequence)
        XCTAssertEqual(exhausted.begin(authority(), geometry: geometry(), nowMs: 0), .failure(.exhausted))
        var (host, local, info) = try ready()
        host.testingSetSequence(SC.maxSequence - 1)
        XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, SC.maxSequence, .key(.shift, down: true)), nowMs: 0).status,
                       .stopped(.exhausted))
        XCTAssertTrue(host.held.isEmpty)
        for invalid in ["0", String(SC.maxSequence + 1), String(UInt64.max)] {
            let text = String(decoding: packet(info, 2, .heartbeat).encoded(), as: UTF8.self)
                .replacingOccurrences(of: "\"seq\":2", with: "\"seq\":\(invalid)")
            let result = SC.Packet.decode(Data(text.utf8))
            if invalid == String(UInt64.max) {
                if case .success = result { XCTFail("accepted seq \(invalid)") }
            } else {
                XCTAssertEqual(result, .failure(.counter), invalid)
            }
        }
    }

    func testTextScrollAndOperationDecodingHaveExplicitBounds() throws {
        var (host, local, info) = try ready()
        let inputs: [SC.Input] = [.text(String(repeating: "a", count: SC.maxTextScalars + 1)), .text("\n"), .text(""),
                                  .scroll(dx: Int32.min, dy: 1, x: 0.25, y: 0.75), .scroll(dx: 0, dy: 0, x: 0.25, y: 0.75)]
        for (index, input) in inputs.enumerated() {
            XCTAssertEqual(host.receive(local, sender: local.binding, packet: packet(info, UInt64(index) + 2, input), nowMs: 0).status,
                           .rejected(.invalidInput))
        }
        XCTAssertEqual(SC.Packet.decode(Data(repeating: 0x20, count: SC.maxPacketBytes + 1)), .failure(.packetSize))
        var value = packet(info, 1, .heartbeat).json
        value["input"] = ["op": "shell", "command": "forbidden"]
        XCTAssertEqual(SC.Packet.decode(try data(value)), .failure(.malformed))
        for operation in ["geometry_ack", "heartbeat", "stop"] {
            value["input"] = ["op": operation, "unexpected": true]
            XCTAssertEqual(SC.Packet.decode(try data(value)), .failure(.malformed))
        }
        // Fractions are not integers, as in serde.
        let fraction = String(decoding: packet(info, 2, .heartbeat).encoded(), as: UTF8.self).replacingOccurrences(of: "\"seq\":2", with: "\"seq\":2.0")
        XCTAssertEqual(SC.Packet.decode(Data(fraction.utf8)), .failure(.malformed))
        XCTAssertEqual(SC.Packet.decode(Data("{v:1}".utf8)), .failure(.malformed))
    }

    func testDebuggingAPacketDoesNotExposeTypedContent() throws {
        let (_, _, info) = try ready()
        let typed = packet(info, 2, .text("private typed fixture"))
        XCTAssertFalse(String(describing: typed).contains("private typed fixture"))
        XCTAssertFalse(String(reflecting: typed).contains("private typed fixture"))
    }

    func testConnectionNonceIsSixteenBytesAndDependsOnKeyAndSession() {
        let key = Data((0..<32).map { UInt8($0) })
        let a = SC.connectionNonce(sessionKey: key, sessionID: "one")
        XCTAssertEqual(a.count, 16)
        XCTAssertNotEqual(a, SC.connectionNonce(sessionKey: key, sessionID: "two"))
        XCTAssertNotEqual(a, SC.connectionNonce(sessionKey: Data(repeating: 0xA5, count: 32), sessionID: "one"))
    }
}
