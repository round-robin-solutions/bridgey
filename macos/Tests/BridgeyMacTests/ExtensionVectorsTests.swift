import Foundation
import XCTest
@testable import BridgeyMac

/// Edition extension kinds in protocol/test-vectors/protocol-v1.json that had no vector (docs/protocol-v1.md, Gaps). This Mac
/// reads "clipboardFetch", "clipboardError", "codesAdvertiseStop", "smsChanged", "smsThreadsPage", "smsAttachmentData",
/// "smsContactsResult", "settingsAck" and "settingsError", and writes the vectors marked write of "clipboardFetch",
/// "clipboardError", "inputSessionStarted", "connectSetupAck", "settingsAck" and "settingsError". Android
/// (ExtensionVectorsTest.kt) and rust/client (src/vectors.rs) check the same groups from their side.
final class ExtensionVectorsTests: XCTestCase {
    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/protocol-v1.json")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: clipboard.fetch and clipboard.error (clipboard_files_draft1)

    func testClipboardFetchReads() throws {
        try reads("clipboardFetch") { data -> Any? in
            guard let fetch = ClipboardFetchPayload.received(data) else { return nil }
            return ["offerId": fetch.offerId, "index": fetch.index, "transferId": fetch.transferId] as [String: Any]
        }
    }

    func testClipboardFetchWrites() throws {
        try writes("clipboardFetch") { p -> Any? in
            guard let offerId = p["offerId"] as? String, let index = p["index"] as? Int, let transferId = p["transferId"] as? String else { return nil }
            return try JSONEncoder().encode(ClipboardFetchPayload(offerId: offerId, index: index, transferId: transferId))
        }
    }

    func testClipboardErrorReads() throws {
        try reads("clipboardError") { data -> Any? in
            guard let payload = ClipboardErrorPayload.received(data) else { return nil }
            return ["offerId": payload.offerId, "index": payload.index, "transferId": payload.transferId, "code": payload.code.rawValue] as [String: Any]
        }
    }

    func testClipboardErrorWrites() throws {
        try writes("clipboardError") { p -> Any? in
            guard let offerId = p["offerId"] as? String, let index = p["index"] as? Int, let transferId = p["transferId"] as? String,
                  let code = (p["code"] as? String).flatMap(ClipboardErrorCode.init(rawValue:)) else { return nil }
            return try JSONEncoder().encode(ClipboardErrorPayload(offerId: offerId, index: index, transferId: transferId, code: code))
        }
    }

    /// A code of another type reads as unavailable too, as on the phone.
    func testClipboardErrorCodeOfAnotherTypeReadsAsUnavailable() {
        let reference = #"{"version":1,"offerId":"6f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f","index":0,"transferId":"7a8b9c0d-1e2f-4a3b-8c4d-5e6f7a8b9c0d""#
        XCTAssertEqual(ClipboardErrorPayload.received(Data((reference + #","code":7}"#).utf8))?.code, .unavailable)
        XCTAssertEqual(ClipboardErrorPayload.received(Data((reference + #","code":"busy"}"#).utf8))?.code, .busy)
    }

    // MARK: codes.advertise_stop (sms_codes_draft1)

    /// The Mac keeps only the service UUID; linked is for the phone's own screen.
    func testCodesAdvertiseStopReads() throws {
        try reads("codesAdvertiseStop", keep: { expect in (expect as? [String: Any])?["serviceUuid"] ?? expect }) { data -> Any? in
            guard let payload = CodesWire.payload(data), let uuid = CodesWire.advertiseStop(payload) else { return nil }
            return uuid.uuidString.lowercased()
        }
    }

    // MARK: input.session.started (remote_input_draft1)

    func testInputSessionStartedWrites() throws {
        try writes("inputSessionStarted") { p -> Any? in
            guard let id = p["inputSessionId"] as? String, let sequence = p["sequence"] as? Int else { return nil }
            return RemoteInputReply.started(inputSessionID: id, sequence: sequence)
        }
    }

    // MARK: Text messages (sms_draft1), read from the phone

    func testSmsChangedReads() throws {
        try reads("smsChanged") { data -> Any? in
            guard let cursor = decodeSmsChanged(data) else { return nil }
            return ["cursor": ["sms": cursor.sms, "mms": cursor.mms]] as [String: Any]
        }
    }

    func testSmsThreadsPageReads() throws {
        try reads("smsThreadsPage") { data -> Any? in
            guard let page = decodeSmsThreadsPage(data) else { return nil }
            let threads = page.threads.map { thread -> [String: Any] in
                ["threadId": thread.threadId, "snippet": thread.snippet, "date": thread.date, "unread": thread.unread,
                 "subId": thread.subId ?? NSNull(),
                 "participants": thread.participants.map { ["address": $0.address, "name": $0.name ?? NSNull()] as [String: Any] }]
            }
            return ["requestId": page.requestID, "threads": threads, "more": page.more, "error": page.error ?? NSNull()] as [String: Any]
        }
    }

    func testSmsAttachmentDataReads() throws {
        try reads("smsAttachmentData") { data -> Any? in
            guard let attachment = decodeSmsAttachment(data) else { return nil }
            return ["requestId": attachment.requestID, "partId": attachment.partID, "data": attachment.data?.base64EncodedString() ?? NSNull(),
                    "width": attachment.width, "height": attachment.height, "error": attachment.error ?? NSNull()] as [String: Any]
        }
    }

    func testSmsContactsResultReads() throws {
        try reads("smsContactsResult") { data -> Any? in
            guard let result = decodeSmsContactsResult(data) else { return nil }
            let contacts = result.contacts.map { ["name": $0.name, "address": $0.address, "label": $0.label ?? NSNull()] as [String: Any] }
            return ["requestId": result.requestID, "contacts": contacts, "error": result.error ?? NSNull()] as [String: Any]
        }
    }

    // MARK: connect.setup.ack (connect_draft1): informational, nothing is read from it

    func testConnectSetupAckWrites() throws {
        try writes("connectSetupAck") { _ -> Any? in ConnectSetup.ackPayload }
    }

    // MARK: settings.ack and settings.error (settings_sync_draft1)

    /// The Mac reads the acknowledged message and the keys applied; it does not read kept.
    func testSettingsAckReads() throws {
        let keep: (Any?) -> Any? = { expect in
            guard let object = expect as? [String: Any] else { return expect }
            return ["ackOf": object["ackOf"] ?? NSNull(), "applied": object["applied"] ?? NSNull()] as [String: Any]
        }
        try reads("settingsAck", keep: keep) { data -> Any? in
            guard let ack = decodeSettingsAck(data) else { return nil }
            return ["ackOf": ack.ackOf, "applied": ack.applied.map(\.rawValue)] as [String: Any]
        }
    }

    func testSettingsAckWrites() throws {
        try writes("settingsAck") { p -> Any? in
            guard let ackOf = p["ackOf"] as? String, let applied = p["applied"] as? [String], let kept = p["kept"] as? [String] else { return nil }
            return settingsAckPayload(ackOf: ackOf, applied: applied.compactMap(SyncKey.init(rawValue:)), kept: kept.compactMap(SyncKey.init(rawValue:)))
        }
    }

    func testSettingsErrorReads() throws {
        try reads("settingsError") { data -> Any? in
            guard let code = decodeSettingsError(data) else { return nil }
            return ["code": code] as [String: Any]
        }
    }

    func testSettingsErrorWrites() throws {
        try writes("settingsError") { p -> Any? in
            guard let code = p["code"] as? String else { return nil }
            return settingsErrorPayload(code)
        }
    }

    // MARK: helpers

    private func cases(_ group: String) throws -> [[String: Any]] {
        let list = try XCTUnwrap(vectors[group] as? [[String: Any]], group)
        XCTAssertFalse(list.isEmpty, group)
        return list
    }

    /// Every vector of `group`: what this Mac keeps (nil for reject) equals expect, as `keep` narrows it to what this Mac reads.
    private func reads(_ group: String, keep: (Any?) -> Any? = { $0 }, file: StaticString = #filePath, line: UInt = #line,
                       _ decode: (Data) throws -> Any?) throws {
        let failed = try cases(group).filter { vector in
            let result = try? decode(plaintext(vector))
            return !Self.same(result ?? "reject", keep(vector["expect"]))
        }.map { $0["name"] as? String ?? "?" }
        XCTAssertEqual(failed, [], "\(group) vectors this Mac reads differently", file: file, line: line)
    }

    /// The vectors of `group` marked write: from the plaintext's values, this Mac's encoder writes exactly that plaintext.
    private func writes(_ group: String, file: StaticString = #filePath, line: UInt = #line, _ encode: ([String: Any]) throws -> Any?) throws {
        let list = try cases(group).filter { $0["write"] as? Bool == true }
        XCTAssertFalse(list.isEmpty, group)
        let failed = list.filter { vector in
            guard let expected = vector["plaintext"] as? [String: Any], let written = try? encode(expected) else { return true }
            let object: Any = (written as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? written
            return !Self.same(object, expected)
        }.map { $0["name"] as? String ?? "?" }
        XCTAssertEqual(failed, [], "\(group) vectors this Mac writes differently", file: file, line: line)
    }

    private func plaintext(_ vector: [String: Any]) -> Data {
        if let raw = vector["plaintextString"] as? String { return Data(raw.utf8) }
        return (try? JSONSerialization.data(withJSONObject: vector["plaintext"] as Any, options: [.fragmentsAllowed])) ?? Data()
    }

    private static func same(_ result: Any, _ expected: Any?) -> Bool {
        guard let expected else { return false }
        return NSArray(object: result).isEqual(to: [expected])
    }
}
