import CoreGraphics
import Foundation
import XCTest
@testable import BridgeyMac

/// protocol/test-vectors/display-v1.json (Mac screen to phone, screen_control_draft1): what the Mac as the source
/// reads (request, sourceStream), writes (status, start, viewerStream, checked as exact plaintexts) and computes
/// (connection nonce, capture size, Mac points, keyboard eligibility). Android checks the viewer's half of the same file.
final class DisplayVectorsTests: XCTestCase {
    private static let vector: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/display-v1.json").standardizedFileURL
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }()

    private func cases(_ key: String) throws -> [[String: Any]] {
        let list = try XCTUnwrap(Self.vector[key] as? [[String: Any]], key)
        XCTAssertFalse(list.isEmpty, key)
        return list
    }

    private func plaintext(_ c: [String: Any]) throws -> Data {
        if let string = c["plaintextString"] as? String { return Data(string.utf8) }
        return try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["plaintext"]))
    }

    private func name(_ c: [String: Any]) -> String { c["name"] as? String ?? "?" }

    private func isReject(_ c: [String: Any]) -> Bool { c["expect"] as? String == "reject" }

    private func capabilities(_ value: Any?) throws -> ScreenControl.Capabilities {
        try ScreenControl.Capabilities.decode(object: value).get()
    }

    private func normalised(_ caps: ScreenControl.Capabilities) -> NSDictionary { caps.json as NSDictionary }

    func testFormat() {
        XCTAssertEqual(Self.vector["format"] as? String, "bridgey.display.v1")
    }

    func testConnectionNonce() throws {
        for c in try cases("connection") {
            let key = try XCTUnwrap(Data(hexString: try XCTUnwrap(c["keyHex"] as? String)))
            let expect = try XCTUnwrap(c["expect"] as? [Int]).map { UInt8($0) }
            XCTAssertEqual(ScreenControl.connectionNonce(sessionKey: key, sessionID: try XCTUnwrap(c["sessionId"] as? String)), expect, name(c))
        }
    }

    func testRequest() throws {
        for c in try cases("request") {
            let decoded = DisplayRequest.decode(try plaintext(c))
            if isReject(c) {
                XCTAssertNil(decoded, name(c))
                continue
            }
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let request = try XCTUnwrap(decoded, name(c))
            XCTAssertEqual(request.requestID, expect["requestId"] as? String, name(c))
            XCTAssertEqual(normalised(request.capabilities), expect["capabilities"] as? NSDictionary, name(c))
        }
    }

    func testSourceStream() throws {
        for c in try cases("sourceStream") {
            let data = try plaintext(c)
            let kind = try XCTUnwrap(c["kind"] as? String)
            let decoded: [String: Any]?
            switch kind {
            case "display.started":
                decoded = DisplayStarted.decode(data).map { ["streamId": $0.streamID, "sequence": $0.sequence] }
            case "display.ack":
                decoded = DisplayAck.decode(data).map {
                    ["streamId": $0.streamID, "sequence": $0.sequence, "frame": Int($0.frame), "decodeMs": $0.decodeMs, "keyframe": $0.keyframe]
                }
            case "display.control":
                decoded = DisplayViewerControl.decode(data).map { ["streamId": $0.streamID, "sequence": $0.sequence, "action": $0.action.rawValue] }
            case "display.stop":
                decoded = DisplayStop.decode(data).map { ["streamId": $0.streamID, "sequence": $0.sequence, "reason": $0.reason.rawValue] }
            default:
                XCTFail("unknown kind \(kind)")
                continue
            }
            if isReject(c) {
                XCTAssertNil(decoded, name(c))
            } else {
                XCTAssertEqual(try XCTUnwrap(decoded, name(c)) as NSDictionary, c["expect"] as? NSDictionary, name(c))
            }
        }
    }

    /// The Mac writes exactly the vector's plaintext for every status.
    func testStatusPayloads() throws {
        for c in try cases("status") where !isReject(c) {
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let status = try XCTUnwrap(DisplayStatus(rawValue: try XCTUnwrap(expect["status"] as? String)), name(c))
            let built = DisplayPayloads.status(requestID: try XCTUnwrap(expect["requestId"] as? String), status: status)
            XCTAssertEqual(built as NSDictionary, c["plaintext"] as? NSDictionary, name(c))
        }
    }

    /// The Mac's display.start is exactly the vector plaintext for each valid start written with lower-case IDs.
    func testStartPayloads() throws {
        var checked = 0
        for c in try cases("start") where !isReject(c) {
            guard let plain = c["plaintext"] as? [String: Any], (plain["streamId"] as? String) == (plain["streamId"] as? String)?.lowercased() else { continue }
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let geometry = try XCTUnwrap(ScreenControl.Geometry.decode(expect["geometry"]))
            let info = DisplayStartInfo(
                streamID: try XCTUnwrap(expect["streamId"] as? String), sequence: try XCTUnwrap(expect["sequence"] as? Int),
                requestID: try XCTUnwrap(expect["requestId"] as? String), fps: try XCTUnwrap(expect["fps"] as? Int),
                bitrate: try XCTUnwrap(expect["bitrate"] as? Int),
                stream: UInt64(try XCTUnwrap(expect["stream"] as? Int)), transport: UInt64(try XCTUnwrap(expect["transport"] as? Int)),
                geometry: geometry, capabilities: try capabilities(expect["capabilities"]),
                control: try XCTUnwrap(expect["control"] as? Bool), displayName: expect["displayName"] as? String)
            var built = DisplayPayloads.start(info)
            var wanted = plain
            // Capabilities go out with every flag; the vector lists only the true ones. Compare them normalised.
            XCTAssertEqual(normalised(try capabilities(built["capabilities"])), normalised(try capabilities(wanted["capabilities"])), name(c))
            built.removeValue(forKey: "capabilities")
            wanted.removeValue(forKey: "capabilities")
            XCTAssertEqual(built as NSDictionary, wanted as NSDictionary, name(c))
            let encoded = try JSONSerialization.data(withJSONObject: DisplayPayloads.start(info))
            XCTAssertLessThanOrEqual(encoded.count, DisplayLimits.startBytes, name(c))
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 3)
        let long = DisplayPayloads.boundedDisplayName(String(repeating: "é", count: 40))
        XCTAssertLessThanOrEqual(long.utf8.count, DisplayLimits.displayNameBytes)
        XCTAssertEqual(long, String(repeating: "é", count: 32))
    }

    /// stats, geometry, control and stop as the Mac writes them, compared with every vector the viewer accepts and
    /// whose plaintext the Mac would write (known reasons only).
    func testViewerStreamPayloads() throws {
        var checked = 0
        for c in try cases("viewerStream") where !isReject(c) {
            guard let plain = c["plaintext"] as? [String: Any], let kind = c["kind"] as? String,
                  let streamID = plain["streamId"] as? String, let sequence = plain["sequence"] as? Int else { continue }
            let built: [String: Any]?
            switch kind {
            case "display.stats":
                built = DisplayPayloads.stats(streamID: streamID, sequence: sequence, latencyMs: plain["latencyMs"] as? Int ?? -1,
                                              rttMs: plain["rttMs"] as? Int ?? -1, bitrate: plain["bitrate"] as? Int ?? -1,
                                              sentBitrate: plain["sentBitrate"] as? Int ?? -1, fps: plain["fps"] as? Int ?? -1,
                                              dropped: plain["dropped"] as? Int ?? -1)
            case "display.geometry":
                built = DisplayPayloads.geometry(streamID: streamID, sequence: sequence,
                                                 geometry: try XCTUnwrap(ScreenControl.Geometry.decode(plain["geometry"])))
            case "display.control":
                let state: DisplayControlState?
                switch plain["state"] as? String {
                case "active":
                    let input = try XCTUnwrap(ScreenControl.InputCapabilities.decode(plain["input"]))
                    state = .active(session: UInt64(try XCTUnwrap(plain["session"] as? Int)), input: input)
                case "ended": state = (plain["reason"] as? String).flatMap(DisplayControlReason.init(rawValue:)).map { .ended($0) }
                case "refused": state = (plain["reason"] as? String).flatMap(DisplayControlReason.init(rawValue:)).map { .refused($0) }
                default: state = nil
                }
                built = state.map { DisplayPayloads.control(streamID: streamID, sequence: sequence, state: $0) }
                if case .active = state, var b = built {
                    // Input goes out with every flag.
                    XCTAssertEqual(ScreenControl.InputCapabilities.decode(b["input"]), ScreenControl.InputCapabilities.decode(plain["input"]))
                    var p = plain
                    b.removeValue(forKey: "input")
                    p.removeValue(forKey: "input")
                    XCTAssertEqual(b as NSDictionary, p as NSDictionary, name(c))
                    checked += 1
                    continue
                }
            case "display.stop":
                built = (plain["reason"] as? String).flatMap(DisplayStopReason.init(rawValue:)).map {
                    DisplayPayloads.stop(streamID: streamID, sequence: sequence, reason: $0)
                }
            default:
                built = nil
            }
            guard let built else { continue }
            XCTAssertEqual(built as NSDictionary, plain as NSDictionary, name(c))
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 6)
    }

    func testCaptureSize() throws {
        for c in try cases("captureSize") {
            let native = try XCTUnwrap(c["native"] as? [Int])
            let expect = try XCTUnwrap(c["expect"] as? [Int])
            let size = DisplayGeometryRules.captureSize(nativeWidth: native[0], nativeHeight: native[1])
            XCTAssertEqual([size.width, size.height], expect, name(c))
        }
    }

    func testMacPoint() throws {
        for c in try cases("macPoint") {
            let g = try XCTUnwrap(c["geometry"] as? [String: Int])
            let geometry = ScreenControl.Geometry(generation: 1, source: 1, kind: .display, width: UInt32(try XCTUnwrap(g["width"])),
                                                  height: UInt32(try XCTUnwrap(g["height"])))
            let b = try XCTUnwrap(c["bounds"] as? [Double])
            let bounds = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
            let result = DisplayGeometryRules.macPoint(geometry: geometry, bounds: bounds, x: try XCTUnwrap(c["x"] as? Double),
                                                       y: try XCTUnwrap(c["y"] as? Double))
            if isReject(c) {
                XCTAssertNil(result, name(c))
                continue
            }
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let mapped = try XCTUnwrap(result, name(c))
            XCTAssertEqual([Int(mapped.pixel.x), Int(mapped.pixel.y)], expect["pixel"] as? [Int], name(c))
            let point = try XCTUnwrap(expect["point"] as? [Double])
            XCTAssertEqual(Double(mapped.point.x), point[0], accuracy: 1e-9, name(c))
            XCTAssertEqual(Double(mapped.point.y), point[1], accuracy: 1e-9, name(c))
            XCTAssertTrue(bounds.contains(mapped.point), "\(name(c)): stays on the selected display")
        }
    }

    func testKeyboardEligible() throws {
        for c in try cases("keyboardEligible") {
            let d = try XCTUnwrap(c["display"] as? [Double])
            let window = (c["window"] as? [Double]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            XCTAssertEqual(DisplayGeometryRules.keyboardEligible(display: CGRect(x: d[0], y: d[1], width: d[2], height: d[3]),
                                                                 focusedWindow: window, displayCount: try XCTUnwrap(c["displays"] as? Int)),
                           c["expect"] as? Bool, name(c))
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
