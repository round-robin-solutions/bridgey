import XCTest
@testable import BridgeyMac

final class CallMediaProtocolTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    func testBothCodecsMatchTheSharedGoldenVectors() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("protocol/test-vectors/call-media-v1.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "bridgey.call-media.v1")
        for kind in ["state", "result"] {
            for record in try XCTUnwrap(root[kind] as? [[String: Any]]) {
                let name = try XCTUnwrap(record["name"] as? String)
                let valid = try XCTUnwrap(record["valid"] as? Bool)
                let plaintext: Data
                if let raw = record["plaintextString"] as? String { plaintext = Data(raw.utf8) }
                else { plaintext = try JSONSerialization.data(withJSONObject: try XCTUnwrap(record["plaintext"])) }
                let payload: [String: Any]?
                if kind == "state" { payload = CallMediaStatePacket.decode(plaintext)?.payload }
                else { payload = CallMediaResultPacket.decode(plaintext)?.payload }
                XCTAssertEqual(payload != nil, valid, "\(kind): \(name)")
                if valid {
                    let expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: plaintext) as? NSDictionary)
                    XCTAssertEqual(payload.map { $0 as NSDictionary }, expected, "\(kind): \(name)")
                }
            }
        }
    }

    func testEqualRevisionRenewsOnlyAnIdenticalStateIncludingUncertainty() {
        var sources = CallMediaSources()
        let state = CallMediaStatePacket(revision: 5, calls: ["call"])
        XCTAssertTrue(sources.receive(state, peerID: "phone", sessionID: "session", now: 0))
        XCTAssertFalse(sources.receive(CallMediaStatePacket(revision: 4, calls: []), peerID: "phone", sessionID: "session", now: 50))
        XCTAssertFalse(sources.receive(CallMediaStatePacket(revision: 5, calls: ["call"], uncertain: true), peerID: "phone", sessionID: "session", now: 50))
        XCTAssertFalse(sources.receive(CallMediaStatePacket(revision: 5, calls: []), peerID: "phone", sessionID: "session", now: 50))
        XCTAssertTrue(sources.receive(state, peerID: "phone", sessionID: "session", now: 50))
        XCTAssertTrue(sources.expire(now: 124).isEmpty)
        XCTAssertEqual(sources.expire(now: 125), ["phone"])
    }

    func testOneSourceCannotClearAnotherAndNewSessionResetsOnlyItsRevision() {
        var sources = CallMediaSources()
        XCTAssertTrue(sources.receive(CallMediaStatePacket(revision: 9, calls: ["same-id"]), peerID: "A", sessionID: "one", now: 0))
        XCTAssertTrue(sources.receive(CallMediaStatePacket(revision: 1, calls: ["same-id"]), peerID: "B", sessionID: "two", now: 0))
        XCTAssertEqual(sources.activeCalls.count, 2)
        XCTAssertTrue(sources.receive(CallMediaStatePacket(revision: 1, calls: []), peerID: "A", sessionID: "new", now: 1))
        XCTAssertEqual(sources.activeCalls, ["B:same-id"])
    }

    func testExpiryRetainsTheCurrentSessionsRevisionFence() {
        var sources = CallMediaSources()
        let latest = CallMediaStatePacket(revision: 8, calls: ["call"])
        XCTAssertTrue(sources.receive(latest, peerID: "A", sessionID: "S", now: 0))
        XCTAssertEqual(sources.expire(now: 75), ["A"])
        XCTAssertFalse(sources.receive(CallMediaStatePacket(revision: 7, calls: []), peerID: "A", sessionID: "S", now: 76))
        XCTAssertFalse(sources.receive(CallMediaStatePacket(revision: 8, calls: [], uncertain: true), peerID: "A", sessionID: "S", now: 76))
        XCTAssertTrue(sources.activeCalls.isEmpty)
        XCTAssertTrue(sources.receive(latest, peerID: "A", sessionID: "S", now: 76))
        XCTAssertEqual(sources.activeCalls, ["A:call"])
    }

    func testUncertainLostSourceSurvivesAnUnrelatedConfirmedEnd() {
        var sources = CallMediaSources()
        sources.receive(CallMediaStatePacket(revision: 2, calls: [], uncertain: true), peerID: "lost", sessionID: "S", now: 0)
        sources.receive(CallMediaStatePacket(revision: 1, calls: ["other"]), peerID: "other", sessionID: "T", now: 0)
        sources.receive(CallMediaStatePacket(revision: 2, calls: []), peerID: "other", sessionID: "T", now: 10)
        XCTAssertTrue(sources.activeCalls.isEmpty)
        XCTAssertTrue(sources.hasUncertainty)
        sources.receive(CallMediaStatePacket(revision: 3, calls: [], uncertain: false), peerID: "lost", sessionID: "S", now: 11)
        XCTAssertFalse(sources.hasUncertainty)
    }
}
