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
                // Mac actions is a switch here but a draft key on the wire: it is pinned once, under drafts,
                // and the switch must read exactly what the draft key says.
                let drafted = features.filter { knownDraftFeatureKeys.contains($0.key.rawValue) }
                if drafted.contains(where: { drafts[$0.key.rawValue] != $0.value }) { return false }
                let plain = features.filter { !knownDraftFeatureKeys.contains($0.key.rawValue) }
                result = ["features": Dictionary(uniqueKeysWithValues: plain.map { ($0.key.rawValue, $0.value) }), "drafts": drafts]
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

    /// Focus sync: both platforms read focus.state alike.
    func testFocusState() throws {
        try each("focusState") { vector in
            let result: Any = decodeFocusState(plaintext(vector)).map { ["active": $0] } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// Mac actions: the Mac reads the phone's run. A bad action or value still decodes; the host answers it.
    func testActionsRun() throws {
        try each("actionsRun") { vector in
            let result: Any = MacActionRun.decode(plaintext(vector)).map { run -> [String: Any] in
                let value: Any
                switch run.value {
                case .absent: value = NSNull()
                case let .integer(number): value = number
                case .other: value = "other"
                }
                return ["requestId": run.requestID, "action": run.action ?? NSNull(), "sequence": run.sequence, "value": value]
            } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// Mac actions: the catalog this Mac writes for a configuration is the plaintext the phone reads.
    func testActionsCatalogAsTheMacWritesIt() throws {
        var checked = 0
        try each("actionsCatalog") { vector in
            guard let spec = vector["mac"] as? [String: Any] else { return true }
            checked += 1
            var config = MacActionsConfig()
            for name in spec["switches"] as? [String] ?? [] { config.switches[MacActionSwitch(rawValue: name)!] = true }
            for app in spec["apps"] as? [[String: String]] ?? [] { _ = config.addApp(AllowedApp(bundleID: app["bundleID"]!, name: app["name"]!)) }
            for shortcut in spec["shortcuts"] as? [[String: String]] ?? [] { _ = config.addShortcut(named: shortcut["name"]!, handle: shortcut["id"]!) }
            let written = macActionsCatalogEntries(config, accessibilityTrusted: spec["accessibilityTrusted"] as? Bool ?? false)
            let expected = (vector["plaintext"] as? [String: Any])?["actions"] as? [[String: Any]] ?? []
            guard written.count == expected.count else { return false }
            // System titles are this Mac's own (localised) words; phones show theirs. Apps and Shortcuts carry the name.
            return zip(written, expected).allSatisfy { mine, theirs in
                let id = mine["id"] as? String ?? ""
                let named = id.hasPrefix("app:") || id.hasPrefix("shortcut:")
                return id == theirs["id"] as? String && mine["blocked"] as? String == theirs["blocked"] as? String
                    && (!named || mine["title"] as? String == theirs["title"] as? String)
                    && (named || !(mine["title"] as? String ?? "").isEmpty)
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
    }

    /// Mac actions: the result this Mac writes is the plaintext the phone reads.
    func testActionsResultAsTheMacWritesIt() throws {
        var checked = 0
        try each("actionsResult") { vector in
            guard let spec = vector["mac"] as? [String: Any] else { return true }
            checked += 1
            let plaintext = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let outcome: MacActionOutcome
            if spec["outcome"] as? String == "done" {
                let volume = (spec["volume"] as? [String: Any]).map { MacVolumeState(level: $0["level"] as! Int, muted: $0["muted"] as! Bool) }
                outcome = .done(volume: volume)
            } else {
                outcome = .refused(try XCTUnwrap(MacActionRefusal(rawValue: spec["reason"] as? String ?? "")))
            }
            let written = macActionResultPayload(outcome, requestID: plaintext["requestId"] as! String, wire: plaintext["action"] as! String)
            return NSDictionary(dictionary: written).isEqual(to: plaintext)
        }
        XCTAssertGreaterThanOrEqual(checked, 9)
    }

    /// Phone camera: the request this Mac writes is the plaintext the phone reads.
    func testCameraRequestAsTheMacWritesIt() throws {
        var checked = 0
        try each("cameraRequest") { vector in
            guard vector["mac"] as? Bool == true else { return true }
            checked += 1
            let plaintext = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            return NSDictionary(dictionary: cameraRequestPayload(plaintext["requestId"] as! String)).isEqual(to: plaintext)
        }
        XCTAssertGreaterThanOrEqual(checked, 1)
    }

    /// Phone camera: the Mac reads the phone's status.
    func testCameraStatus() throws {
        try each("cameraStatus") { vector in
            let result: Any = decodeCameraStatus(plaintext(vector)).map { ["requestId": $0.requestID, "status": $0.status.rawValue] } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// Text messages: the Mac reads the phone's sms.status.
    func testSmsStatus() throws {
        try each("smsStatus") { vector in
            let result: Any = decodeSmsStatus(plaintext(vector)).map { status -> [String: Any] in
                ["read": status.read, "send": status.send, "contacts": status.contacts,
                 "sims": status.sims.map { ["subId": $0.subId, "slot": $0.slot, "label": $0.label] },
                 "cursor": ["sms": status.cursor.sms, "mms": status.cursor.mms]]
            } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// Text messages: one message object of a page, as the Mac reads it (an invalid one is dropped).
    func testSmsMessage() throws {
        try each("smsMessage") { vector in
            let value = try? JSONSerialization.jsonObject(with: plaintext(vector), options: [.fragmentsAllowed])
            let result: Any = decodeSmsMessage(value).map { message -> [String: Any] in
                ["id": message.id, "threadId": message.threadId, "direction": message.direction.rawValue, "status": message.status.rawValue,
                 "date": message.date, "address": message.address, "body": message.body, "truncated": message.truncated,
                 "subId": message.subId ?? NSNull(), "read": message.read,
                 "parts": message.parts.map { ["partId": $0.partId, "mimeType": $0.mimeType, "size": $0.size ?? NSNull()] as [String: Any] }]
            } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// Text messages: the Mac reads the phone's sms.send_status.
    func testSmsSendStatus() throws {
        try each("smsSendStatus") { vector in
            let result: Any = decodeSmsSendStatus(plaintext(vector)).map { status -> [String: Any] in
                ["requestId": status.requestID, "status": status.status.rawValue,
                 "reason": status.reason?.rawValue ?? NSNull(), "via": status.via ?? NSNull()]
            } ?? "reject"
            return Self.same(result, vector["expect"])
        }
    }

    /// Text messages: every request the phone accepts, the Mac writes the same way from the decoded values.
    func testSmsRequestsAsTheMacWritesThem() throws {
        var checked = 0
        try each("smsRequest") { vector in
            guard let expect = vector["expect"] as? [String: Any] else { return true }
            checked += 1
            let id = expect["requestId"] as! String
            let written: [String: Any]?
            switch vector["kind"] as! String {
            case SmsKinds.threads: written = SmsRequests.threads(id, before: expect["before"] as? Int, limit: expect["limit"] as! Int)
            case SmsKinds.messages:
                let before = (expect["before"] as? [String: Any]).map {
                    SmsMessage(id: $0["id"] as! String, threadId: expect["threadId"] as! Int, direction: .incoming, status: .received,
                               date: $0["date"] as! Int, address: "", body: "")
                }
                written = SmsRequests.messages(id, threadId: expect["threadId"] as! Int, before: before, limit: expect["limit"] as! Int)
            case SmsKinds.sync:
                let since = expect["since"] as! [String: Int]
                written = SmsRequests.sync(id, since: SmsCursor(sms: since["sms"]!, mms: since["mms"]!), limit: expect["limit"] as! Int)
            case SmsKinds.attachment: written = SmsRequests.attachment(id, partID: expect["partId"] as! String)
            case SmsKinds.contacts: written = SmsRequests.contacts(id, query: expect["query"] as! String)
            default: return false
            }
            guard var written else { return false }
            if written["before"] == nil, expect.keys.contains("before") { written["before"] = NSNull() }
            written.removeValue(forKey: "version")
            return NSDictionary(dictionary: written).isEqual(to: expect)
        }
        XCTAssertGreaterThanOrEqual(checked, 12)
    }

    /// Text messages: sends the phone accepts are what the Mac writes; malformed bodies and numbers never leave the Mac.
    func testSmsSendAsTheMacWritesIt() throws {
        try each("smsSend") { vector in
            guard let expect = vector["expect"] as? [String: Any] else {
                // A rejected send: the Mac's own encoder refuses the same body or number when it can tell.
                guard let plaintext = vector["plaintext"] as? [String: Any], let body = plaintext["body"] as? String else { return true }
                if !SmsRequests.isSendableBody(body) { return SmsRequests.send(Self.requestID, body: body, to: .thread(1)) == nil }
                if let address = plaintext["address"] as? String, plaintext["threadId"] == nil, plaintext["notificationId"] == nil {
                    return SmsRequests.send(Self.requestID, body: body, to: .address(address)) == nil
                }
                return true
            }
            let target: SmsRequests.Target
            if let thread = expect["threadId"] as? Int { target = .thread(thread) }
            else if let address = expect["address"] as? String { target = .address(address) }
            else { target = .notification(expect["notificationId"] as! String) }
            guard var written = SmsRequests.send(expect["requestId"] as! String, body: expect["body"] as! String, to: target,
                                                 subId: expect["subId"] as? Int) else { return false }
            written.removeValue(forKey: "version")
            for key in ["threadId", "address", "notificationId", "subId"] where written[key] == nil { written[key] = NSNull() }
            return NSDictionary(dictionary: written).isEqual(to: expect)
        }
    }

    private static let requestID = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"

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
