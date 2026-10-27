import Foundation
import XCTest
@testable import BridgeyMac

/// Protocol 2 helpers from the v0.10 security review (docs/security-review-0.10.md).
final class SessionSecurityTests: XCTestCase {
    func testOnlyPairingKindsAreAllowedBeforeAuthentication() {
        for kind in ["pairing.offer", "pairing.answer", "pairing.reveal", "pairing.confirm", "pairing.cancel"] {
            XCTAssertTrue(SessionSecurity.allowedBeforeAuthentication(kind), kind)
        }
        for kind in [
            "files.cancel", "files.accept", "files.complete.ack", "files.rejected", "files.cancel.ack", "files.chunk.ack",
            "clipboard.ack", "clipboard.rejected", "calls.status", "ping.ack", "heartbeat.ping", "pairing", "",
        ] {
            XCTAssertFalse(SessionSecurity.allowedBeforeAuthentication(kind), kind)
        }
    }

    func testPendingConnectionsAreCappedInAllAndPerAddress() {
        XCTAssertTrue(admitsPendingConnection(pendingHosts: [], host: "10.0.0.2"))
        XCTAssertTrue(admitsPendingConnection(pendingHosts: ["10.0.0.2", "10.0.0.2"], host: "10.0.0.2"))
        XCTAssertFalse(admitsPendingConnection(pendingHosts: ["10.0.0.2", "10.0.0.2", "10.0.0.2"], host: "10.0.0.2"))
        XCTAssertTrue(admitsPendingConnection(pendingHosts: ["10.0.0.2", "10.0.0.2", "10.0.0.2"], host: "10.0.0.3"))
        XCTAssertFalse(admitsPendingConnection(pendingHosts: (0..<8).map { "10.0.0.\($0 + 10)" }, host: "10.0.0.3"))
        XCTAssertTrue(admitsPendingConnection(pendingHosts: (0..<7).map { "10.0.0.\($0 + 10)" }, host: nil))
    }

    func testInboundPairingPromptsAreLimitedPerMinute() {
        var limiter = InboundPairingLimiter(limit: 3, window: 60)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(limiter.tryAcquire(now: start))
        XCTAssertTrue(limiter.tryAcquire(now: start + 1))
        XCTAssertTrue(limiter.tryAcquire(now: start + 2))
        XCTAssertFalse(limiter.tryAcquire(now: start + 3))
        XCTAssertFalse(limiter.tryAcquire(now: start + 59.9))
        XCTAssertTrue(limiter.tryAcquire(now: start + 60))
        XCTAssertFalse(limiter.tryAcquire(now: start + 60.1))
    }

    func testPeerNamesLoseControlAndBidiCharactersAndAreBounded() {
        XCTAssertEqual(sanitizedPeerName("Rahul's Pixel", fallback: "Phone"), "Rahul's Pixel")
        XCTAssertEqual(sanitizedPeerName("Phone\u{202E}gpj.exe", fallback: "Phone"), "Phonegpj.exe")
        XCTAssertEqual(sanitizedPeerName("a\u{0}\nb\u{2066}", fallback: "Phone"), "ab")
        XCTAssertEqual(sanitizedPeerName("  \u{200F} ", fallback: "Phone"), "Phone")
        XCTAssertEqual(sanitizedPeerName(nil, fallback: "Phone"), "Phone")
        XCTAssertEqual(sanitizedPeerName(String(repeating: "x", count: 10_000), fallback: "Phone").count, maximumPeerNameCharacters)
    }

    func testCommitmentBindsSessionAndKey() {
        let commitment = SessionSecurity.commitment(sessionID: "s1", publicKey: "BAAA")
        XCTAssertTrue(SessionSecurity.commitmentMatches(commitment, sessionID: "s1", publicKey: "BAAA"))
        XCTAssertFalse(SessionSecurity.commitmentMatches(commitment, sessionID: "s2", publicKey: "BAAA"))
        XCTAssertFalse(SessionSecurity.commitmentMatches(commitment, sessionID: "s1", publicKey: "BAAB"))
        XCTAssertFalse(SessionSecurity.commitmentMatches("not base64 !", sessionID: "s1", publicKey: "BAAA"))
        XCTAssertFalse(SessionSecurity.commitmentMatches("", sessionID: "s1", publicKey: "BAAA"))
    }

    func testLengthPrefixingKeepsFieldBoundaries() {
        XCTAssertNotEqual(SessionSecurity.lengthPrefixed(["ab", "c"]), SessionSecurity.lengthPrefixed(["a", "bc"]))
        XCTAssertNotEqual(SessionSecurity.lengthPrefixed([nil]), SessionSecurity.lengthPrefixed([""]))
        XCTAssertNotEqual(SessionSecurity.lengthPrefixed(["a\u{0}", "b"]), SessionSecurity.lengthPrefixed(["a", "\u{0}b"]))
    }

    func testProtocolPinsOnlyRiseAndForgetClearsThem() throws {
        let suite = "bridgey.tests.protocolPins.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = ProtocolPins(defaults: defaults)
        XCTAssertEqual(pins.pinned("Phone-A"), 1)
        pins.pin("Phone-A", version: 2)
        XCTAssertEqual(pins.pinned("phone-a"), 2)
        pins.pin("Phone-A", version: 1)
        XCTAssertEqual(pins.pinned("Phone-A"), 2)
        pins.remove("PHONE-A")
        XCTAssertEqual(pins.pinned("Phone-A"), 1)
    }

    /// Fuzz: random envelopes, keys and tags never verify unless the tag was made for exactly that frame.
    func testRandomTagsAndMutatedFramesNeverVerify() {
        var generator = SystemRandomNumberGenerator()
        func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        let key = bytes(32)
        for _ in 0..<500 {
            var message = PairingMessage(
                kind: ["clipboard.update", "calls.request", "find.start", "files.cancel", "x"].randomElement()!,
                sessionId: "s\(Int.random(in: 0..<1000))",
                messageId: Bool.random() ? "m\(Int64.random(in: 0...Int64.max))" : nil,
                nonce: Bool.random() ? bytes(12).base64EncodedString() : nil,
                ciphertext: Bool.random() ? bytes(Int.random(in: 0..<64)).base64EncodedString() : nil,
                transferId: Bool.random() ? "t\(Int.random(in: 0...Int.max))" : nil,
                sequence: Bool.random() ? Int64.random(in: 0..<(1 << 53)) : nil
            )
            let sender = "device-\(Int.random(in: 0..<4))"
            message.tag = SessionSecurity.tag(envelopeKey: key, senderDeviceID: sender, message: message)
            XCTAssertTrue(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: sender, message: message))
            XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: bytes(32), senderDeviceID: sender, message: message))
            var forged = message
            forged.tag = bytes(32).base64EncodedString()
            XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: sender, message: forged))
            forged.tag = "%%%"
            XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: sender, message: forged))
            var mutated = message
            switch Int.random(in: 0..<4) {
            case 0: mutated.messageId = (message.messageId ?? "") + "x"
            case 1: mutated.transferId = (message.transferId ?? "") + "x"
            case 2: mutated.sequence = (message.sequence ?? 0) + 1
            default: mutated.nonce = (message.nonce ?? "") + "AA=="
            }
            XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: sender, message: mutated))
        }
    }
}
