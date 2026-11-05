import AppKit
import XCTest
@testable import BridgeyMac

final class DevicePresenceTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func testCodecMatchesSharedGoldenVectors() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("protocol/test-vectors/device-presence-v1.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "bridgey.device-presence.v1")
        for vector in try XCTUnwrap(root["state"] as? [[String: Any]]) {
            let name = try XCTUnwrap(vector["name"] as? String)
            let valid = try XCTUnwrap(vector["valid"] as? Bool)
            let plaintext: Data
            if let raw = vector["raw"] as? String { plaintext = Data(raw.utf8) }
            else { plaintext = try JSONSerialization.data(withJSONObject: try XCTUnwrap(vector["plaintext"]), options: [.fragmentsAllowed]) }
            let packet = DevicePresencePacket.decode(plaintext)
            XCTAssertEqual(packet != nil, valid, name)
            if let packet {
                let expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: plaintext) as? NSDictionary)
                XCTAssertEqual(packet.payload as NSDictionary, expected, name)
            }
        }
    }

    func testSampleFailsClosedAndBoundsIdleAge() {
        XCTAssertEqual(DevicePresenceSample.available(idleSeconds: .infinity), .unknown)
        XCTAssertEqual(DevicePresenceSample.available(idleSeconds: .nan), .unknown)
        XCTAssertEqual(DevicePresenceSample.available(idleSeconds: -1), .unknown)
        XCTAssertEqual(DevicePresenceSample.available(idleSeconds: 119.9).state, .active)
        XCTAssertEqual(DevicePresenceSample.available(idleSeconds: 120).state, .idle)
        XCTAssertEqual(DevicePresenceSample.available(idleSeconds: 200_000).idleSeconds, 86_400)
        XCTAssertNil(DevicePresenceSample.locked.idleSeconds)
    }

    func testPollingDoesNotSendEveryIdleAgeChangeAndKeepAliveRenewsAtTenSeconds() {
        var publisher = DevicePresencePublisher()
        let peers: Set<DevicePresencePeer> = [peer()]
        XCTAssertEqual(publisher.emissions(to: peers, sample: .available(idleSeconds: 5), now: 0).first?.packet.sequence, 1)
        XCTAssertTrue(publisher.emissions(to: peers, sample: .available(idleSeconds: 7), now: 2).isEmpty)
        XCTAssertTrue(publisher.emissions(to: peers, sample: .available(idleSeconds: 14), now: 9).isEmpty)
        let renewal = publisher.emissions(to: peers, sample: .available(idleSeconds: 15), now: 10)
        XCTAssertEqual(renewal.count, 1)
        XCTAssertEqual(renewal.first?.packet.sequence, 2)
        XCTAssertEqual(renewal.first?.packet.sample.idleSeconds, 15)
    }

    func testContinuousTypingRenewsEvenWhenEveryPollReportsZeroIdle() {
        var publisher = DevicePresencePublisher()
        let peers: Set<DevicePresencePeer> = [peer()]
        _ = publisher.emissions(to: peers, sample: .available(idleSeconds: 0), now: 0)
        XCTAssertEqual(publisher.emissions(to: peers, sample: .available(idleSeconds: 0), now: 2).first?.packet.sequence, 2)
        XCTAssertEqual(publisher.emissions(to: peers, sample: .available(idleSeconds: 0), now: 4).first?.packet.sequence, 3)
        XCTAssertTrue(publisher.emissions(to: peers, sample: .available(idleSeconds: 2), now: 6).isEmpty)
    }

    func testNewInputAndAvailabilityChangesPublishBeforeKeepAlive() {
        var publisher = DevicePresencePublisher()
        let peers: Set<DevicePresencePeer> = [peer()]
        _ = publisher.emissions(to: peers, sample: .available(idleSeconds: 90), now: 0)
        let input = publisher.emissions(to: peers, sample: .available(idleSeconds: 0), now: 2)
        XCTAssertEqual(input.first?.packet.sample.state, .active)
        let locked = publisher.emissions(to: peers, sample: .locked, now: 3)
        XCTAssertEqual(locked.first?.packet.sample.state, .locked)
        XCTAssertNil(locked.first?.packet.payload["idleSeconds"])
        XCTAssertEqual(publisher.emissions(to: peers, sample: .unknown, now: 4).first?.packet.sample.state, .unknown)
    }

    func testSessionReplacementResetsAndUnsubscribingPreservesTheSessionsSequence() {
        var publisher = DevicePresencePublisher()
        let a = peer(), b = DevicePresencePeer(deviceID: "B", sessionID: "B1")
        _ = publisher.emissions(to: [a, b], sample: .locked, now: 0)
        let newA = peer(session: "new")
        let replacement = publisher.emissions(to: [newA, b], sample: .locked, now: 2)
        XCTAssertEqual(replacement.count, 1)
        XCTAssertEqual(replacement.first?.peer, newA)
        XCTAssertEqual(replacement.first?.packet.sequence, 1)
        XCTAssertTrue(publisher.emissions(to: [], sample: .unknown, now: 3).isEmpty)
        XCTAssertEqual(publisher.emissions(to: [b], sample: .locked, now: 4).first?.packet.sequence, 2)
        let newB = DevicePresencePeer(deviceID: "B", sessionID: "B2")
        XCTAssertEqual(publisher.emissions(to: [newB], sample: .locked, now: 5).first?.packet.sequence, 1)
    }

    @MainActor
    func testSessionFixturesAllowOmittedUnlockedKeyButNeverUnknownOrUnavailableSession() {
        let console = kCGSessionOnConsoleKey as String
        let login = kCGSessionLoginDoneKey as String
        let unlocked: [String: Any] = [console: true, login: true]
        func sample(_ session: [String: Any]?, asleep: Bool = false) -> DevicePresenceSample {
            DevicePresenceMonitor.sessionSample(session, displayAsleep: asleep, idleSeconds: 0)
        }
        XCTAssertEqual(sample(unlocked).state, .active, "the optional locked-state key may be absent while unlocked")
        XCTAssertEqual(sample(nil), .unknown)
        XCTAssertEqual(sample([:]), .unknown)
        XCTAssertEqual(sample([console: true]), .unknown)
        XCTAssertEqual(sample([console: false, login: true]), .locked)
        XCTAssertEqual(sample([console: true, login: false]), .locked)
        XCTAssertEqual(sample(unlocked, asleep: true), .locked)
        XCTAssertEqual(sample(unlocked.merging(["CGSSessionScreenIsLocked": true]) { $1 }), .locked)
        XCTAssertEqual(sample(unlocked.merging(["CGSSessionScreenIsLocked": false]) { $1 }).state, .active)
        XCTAssertEqual(sample(unlocked.merging(["CGSSessionScreenIsLocked": "false"]) { $1 }), .unknown)
    }

    @MainActor
    func testWakingDoesNotClearAnObservedScreenLock() {
        let monitor = DevicePresenceMonitor()
        var packets: [DevicePresencePacket] = []
        monitor.sample = { .available(idleSeconds: 0) }
        monitor.clock = { 0 }
        monitor.send = { _, packet in packets.append(packet) }
        monitor.update(subscribers: [peer()])
        defer { monitor.update(subscribers: []) }
        monitor.availabilityChanged(.screenLocked, unavailable: true)
        monitor.availabilityChanged(.systemAsleep, unavailable: true)
        monitor.availabilityChanged(.systemAsleep, unavailable: false)
        XCTAssertEqual(packets.last?.sample, .locked, "wake is not an unlock")
        monitor.availabilityChanged(.screenLocked, unavailable: false)
        XCTAssertEqual(packets.last?.sample.state, .active)
    }

    @MainActor
    func testNoSubscriberMeansNoSamplingOrTimerAndRevocationStopsIt() {
        let monitor = DevicePresenceMonitor()
        var samples = 0
        var packets: [DevicePresencePacket] = []
        monitor.sample = { samples += 1; return .locked }
        monitor.clock = { 0 }
        monitor.send = { _, packet in packets.append(packet) }
        monitor.tick()
        XCTAssertEqual(samples, 0)
        XCTAssertFalse(monitor.isRunning)
        monitor.update(subscribers: [peer()])
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(packets.count, 1)
        monitor.update(subscribers: [])
        XCTAssertFalse(monitor.isRunning)
        monitor.tick(force: true)
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(packets.count, 1)
    }

    private func peer(session: String = "session") -> DevicePresencePeer {
        DevicePresencePeer(deviceID: "A", sessionID: session)
    }
}
