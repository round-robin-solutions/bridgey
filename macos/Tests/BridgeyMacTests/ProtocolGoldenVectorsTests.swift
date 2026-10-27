import Foundation
import XCTest
@testable import BridgeyMac

/// protocol/test-vectors/protocol-v1.json: Android (ProtocolGoldenVectorsTest.kt) decodes the same vectors
/// and must reach the same results. Regenerate with protocol/tools/golden_vectors.py.
final class ProtocolGoldenVectorsTests: XCTestCase {
    private var vectors: [String: Any] = [:]
    private var sessionID = ""

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/protocol-v1.json")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        sessionID = try XCTUnwrap(vectors["sessionId"] as? String)
    }

    func testFrames() throws {
        try each("frames") { vector in
            let prefix = #"{"kind":"pairing.offer","sessionId":"\#(sessionID)","deviceName":""#
            let padding = (vector["padTo"] as? Int).map { String(repeating: "a", count: $0 - prefix.utf8.count - 2) } ?? ""
            var bytes: Data
            if let base64 = vector["lineBase64"] as? String {
                bytes = try XCTUnwrap(Data(base64Encoded: base64))
            } else if let depth = vector["nest"] as? Int {
                let inner = String(repeating: "[", count: depth - 1) + String(repeating: "]", count: depth - 1)
                bytes = Data(#"{"kind":"x.y","sessionId":"\#(sessionID)","x":\#(inner)}"#.utf8)
            } else if vector["padTo"] != nil {
                bytes = Data((prefix + padding + "\"}").utf8)
            } else {
                bytes = Data((vector["line"] as! String).utf8)
            }
            bytes.append(Data(((vector["lineEnding"] as? String) ?? "\n").utf8))
            var reader = ProtocolFrameReader()
            reader.append(bytes)
            let decoded = (try? reader.next()).map(Self.fields)
            if (vector["expect"] as? String) == "reject" { return decoded == nil }
            guard let decoded, var expected = vector["expect"] as? [String: Any] else { return false }
            for (key, value) in expected where value as? String == "@PAD@" { expected[key] = padding }
            return NSDictionary(dictionary: decoded).isEqual(to: expected)
        }
    }

    func testFeaturesUpdate() throws {
        try each("featuresUpdate") { vector in
            let result: Any
            switch decodeFeatureState(plaintext(vector)) {
            case .invalid: result = "invalid"
            case .ignored: result = "ignored"
            case let .state(features, drafts):
                result = ["features": Dictionary(uniqueKeysWithValues: features.map { ($0.key.rawValue, $0.value) }), "drafts": drafts]
            }
            return Self.same(result, vector["expect"])
        }
    }

    func testBatteryUpdate() throws {
        try each("batteryUpdate") { vector in
            let result: Any = decodeBatteryStatus(plaintext(vector)).map { ["level": $0.level, "isCharging": $0.isCharging] as [String: Any] } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    func testClipboardRich() throws {
        try each("clipboardRich") { vector in
            let result: Any = decodeRichClipboard(plaintext(vector)).map { ["text": $0.text, "html": $0.html] } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    func testClipboardOffer() throws {
        try each("clipboardOffer") { vector in
            let result: Any = ClipboardOffer.decode(plaintext(vector)).map { offer in
                [
                    "offerId": offer.offerId.lowercased(), "createdAt": offer.createdAt, "sensitive": offer.sensitive ?? false,
                    "items": offer.items.map { item in
                        [
                            "index": item.index, "kind": item.kind.rawValue, "mime": item.mime, "name": item.name ?? NSNull(),
                            "size": item.size, "sha256": item.sha256 ?? NSNull(),
                            "inlineBytes": item.inline.flatMap { Data(base64Encoded: $0)?.count } ?? NSNull(),
                        ] as [String: Any]
                    },
                ] as [String: Any]
            } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// Files 2.0 refs: the Mac reads them from media.page; the phone reads the same ones from every browse request.
    func testBrowseRef() throws {
        try each("browseRef") { vector in
            let result: Any = (try? JSONDecoder().decode(WireRef.self, from: plaintext(vector)))?.ref.map { ref -> [String: Any] in
                switch ref {
                case let .media(id): return ["mediaId": id]
                case let .place(placeId, path, name): return ["placeId": placeId, "path": path, "name": name]
                }
            } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// The Mac is the remote control host: it accepts exactly what the phone may send.
    func testRemoteInputAsTheHostReadsIt() throws {
        try each("remoteInput") { vector in
            let data = try JSONSerialization.data(withJSONObject: vector["plaintext"] as Any)
            let result: Any = RemoteInputMessage.parse(kind: vector["kind"] as! String, data: data).map { Self.describe($0.command) } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    // MARK: helpers

    private func each(_ group: String, file: StaticString = #filePath, line: UInt = #line, _ check: ([String: Any]) throws -> Bool) throws {
        let list = try XCTUnwrap(vectors[group] as? [[String: Any]])
        XCTAssertGreaterThan(list.count, 5)
        let failed = list.filter { ((try? check($0)) ?? false) == false }.map { $0["name"] as! String }
        XCTAssertEqual(failed, [], "\(group) vectors that decode differently from the contract", file: file, line: line)
    }

    private func plaintext(_ vector: [String: Any]) -> Data {
        if let raw = vector["plaintextString"] as? String { return Data(raw.utf8) }
        return (try? JSONSerialization.data(withJSONObject: vector["plaintext"] as Any, options: [.fragmentsAllowed])) ?? Data()
    }

    private static func same(_ result: Any, _ expected: Any?) -> Bool {
        guard let expected else { return false }
        return NSArray(object: result).isEqual(to: [expected])
    }

    private static func fields(_ message: PairingMessage) -> [String: Any] {
        var fields: [String: Any] = ["kind": message.kind, "sessionId": message.sessionId]
        let optional: [(String, String?)] = [
            ("deviceId", message.deviceId), ("deviceName", message.deviceName), ("publicKey", message.publicKey),
            ("identityKey", message.identityKey), ("proof", message.proof), ("signature", message.signature),
            ("messageId", message.messageId), ("nonce", message.nonce), ("ciphertext", message.ciphertext),
            ("transferId", message.transferId), ("targetDeviceId", message.targetDeviceId),
        ]
        for (key, value) in optional { if let value { fields[key] = value } }
        if let sequence = message.sequence { fields["sequence"] = sequence }
        return fields
    }

    private static func describe(_ command: RemoteInputCommand) -> [String: Any] {
        switch command {
        case let .start(mode): return ["command": "start", "mode": mode?.rawValue ?? NSNull()]
        case .heartbeat: return ["command": "heartbeat"]
        case let .stop(reason): return ["command": "stop", "reason": reason.rawValue]
        case let .pointer(dx, dy): return ["command": "pointer", "dx": dx, "dy": dy]
        case let .button(button, down): return ["command": "button", "button": button.rawValue, "down": down]
        case let .scroll(dx, dy, unit): return ["command": "scroll", "dx": dx, "dy": dy, "unit": unit.rawValue]
        case .dragStart: return ["command": "dragStart"]
        case let .dragMove(dx, dy): return ["command": "dragMove", "dx": dx, "dy": dy]
        case .dragEnd: return ["command": "dragEnd"]
        case let .text(text): return ["command": "text", "text": text]
        case let .key(key, shift): return ["command": "key", "key": key.rawValue, "shift": shift]
        case let .present(action, x, y):
            var value: [String: Any] = ["command": "present", "action": action.rawValue]
            if let x { value["x"] = x }
            if let y { value["y"] = y }
            return value
        }
    }
}
