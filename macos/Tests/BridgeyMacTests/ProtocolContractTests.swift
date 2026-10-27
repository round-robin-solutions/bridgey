import Foundation
import XCTest
@testable import BridgeyMac

/// protocol/messages.json lists every message kind this app sends or handles (docs/protocol-contract.md).
/// Adding a message without documenting it fails here; so does documenting one the code never uses.
/// Android runs the same scan (ProtocolContractTest.kt), and so does scripts/rr/tests/test_protocol_contract.py.
final class ProtocolContractTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private var contract: [String: Any] = [:]
    private var listed: [String: [String: Any]] = [:]

    override func setUpWithError() throws {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("protocol/messages.json"))
        contract = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(contract["messages"] as? [[String: Any]])
        listed = Dictionary(uniqueKeysWithValues: messages.map { ($0["kind"] as! String, $0) })
    }

    func testEveryKindTheCodeUsesIsListed() throws {
        let found = try Self.scanKinds(in: Self.repoRoot.appendingPathComponent("macos/Sources"))
        XCTAssertGreaterThan(found.count, 50, "the scan found nothing; did the sources move?")
        var problems: [String] = []
        for (kind, file) in found.sorted(by: { $0.key < $1.key }) {
            guard let entry = listed[kind] else {
                problems.append("\(kind) (in \(file)) is not in protocol/messages.json")
                continue
            }
            if !implemented(entry) { problems.append("\(kind) (in \(file)) is used but messages.json does not list macos") }
        }
        for (kind, entry) in listed.sorted(by: { $0.key < $1.key }) where implemented(entry) && found[kind] == nil {
            problems.append("messages.json lists \(kind) for macos, but the sources never use it")
        }
        XCTAssertEqual(problems, [], "Document new messages in docs/protocol.md and protocol/messages.json")
    }

    func testEveryFeatureKeyThisAppAdvertisesIsListed() throws {
        let features = try XCTUnwrap(contract["features"] as? [[String: Any]])
        let keys = Set(features.map { $0["key"] as! String })
        let advertised = BridgeyFeature.allCases.map(\.rawValue) + knownDraftFeatureKeys
        XCTAssertEqual(advertised.filter { !keys.contains($0) }, [])
        let required = Set(features.filter { $0["requiredInMap"] as? Bool == true }.map { $0["key"] as! String })
        XCTAssertEqual(required, Set(BridgeyFeature.allCases.filter(featureEnabledByLegacyPeer).map(\.rawValue)))
    }

    func testTransportLimitsMatchTheContract() throws {
        let transport = try XCTUnwrap(contract["transport"] as? [String: Any])
        XCTAssertEqual(transport["maxFrameBytes"] as? Int, maximumProtocolFrameBytes)
        XCTAssertEqual(transport["maxJsonDepth"] as? Int, maximumProtocolJSONDepth)
        XCTAssertEqual(transport["port"] as? Int, ReconnectPolicy.listeningPort)
    }

    func testScanFindsEveryStyleTheCodeUses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        current.send(PairingMessage(kind: "b.one", sessionId: id))
                    case "b.two", "b.three":
        enum FolderKind {
            static let x = "b.four"
        }
        _ = send(deviceID, "b.five", reply)
        if message.kind == "b.six" { }
        L10n.text("b.seven", fallback: "x")
        case "com.apple.iWork.Keynote": self = .keynote
        """.write(to: directory.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(try Self.scanKinds(in: directory).keys), ["b.one", "b.two", "b.three", "b.four", "b.five", "b.six"])
    }

    private func implemented(_ entry: [String: Any]) -> Bool { (entry["implemented"] as? [String] ?? []).contains("macos") }

    private static let kindPattern = #"[a-z][a-z0-9]*(?:\.[a-z0-9_]+)+"#

    /// Kinds used as a message kind in Swift sources, with the first file that uses each.
    static func scanKinds(in root: URL) throws -> [String: String] {
        let k = kindPattern
        let patterns = try [#"kind:\s*"(\#(k))""#, #"kind\s*==\s*"(\#(k))""#, #"\bsend\w*\((?:[^()"]*,\s*)?"(\#(k))""#]
            .map { try NSRegularExpression(pattern: $0) }
        let caseLine = try NSRegularExpression(pattern: #"^\s*case\s+((?:"\#(k)"\s*,\s*)*"\#(k)")\s*:"#)
        let literal = try NSRegularExpression(pattern: #""(\#(k))""#)
        let block = try NSRegularExpression(pattern: #"enum \w*Kinds?\s*\{(.*?)\n\}"#, options: .dotMatchesLineSeparators)
        let constant = try NSRegularExpression(pattern: #"static let \w+ = "(\#(k))""#)
        var found: [String: String] = [:]
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        func groups(_ regex: NSRegularExpression, _ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                for pattern in patterns {
                    for kind in groups(pattern, line) where found[kind] == nil { found[kind] = file.lastPathComponent }
                }
                for list in groups(caseLine, line) {
                    for kind in groups(literal, list) where found[kind] == nil { found[kind] = file.lastPathComponent }
                }
            }
            for body in groups(block, text) {
                for kind in groups(constant, body) where found[kind] == nil { found[kind] = file.lastPathComponent }
            }
        }
        return found
    }
}
