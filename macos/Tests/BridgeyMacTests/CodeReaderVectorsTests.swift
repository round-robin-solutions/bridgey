import XCTest
@testable import BridgeyMac

/// protocol/test-vectors/codes-reader-v1.json, written by the shared Rust reader (rust/codes/examples/vectors.rs), the
/// single source of truth for the code rules (docs/mesh-and-codes.md). This Mac's Swift copy gives the same answers
/// until it calls the Rust reader itself.
final class CodeReaderVectorsTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func cases(_ name: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: repo.appendingPathComponent("protocol/test-vectors/codes-reader-v1.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object[name] as? [[String: Any]], name)
    }

    func testGuard() throws {
        for v in try cases("guard") {
            let text = try XCTUnwrap(v["text"] as? String)
            XCTAssertEqual(CodeGuard.accept(v["answer"] as? String, in: codeGuardText(codeReadText(text))), v["expect"] as? String, "\(v)")
        }
    }

    func testJoinGuardTextAndGate() throws {
        for v in try cases("readText") {
            XCTAssertEqual(codeReadText(try XCTUnwrap(v["text"] as? String)), v["expect"] as? String, "\(v)")
        }
        for v in try cases("guardText") {
            XCTAssertEqual(codeGuardText(try XCTUnwrap(v["text"] as? String)), v["expect"] as? String, "\(v)")
        }
        for v in try cases("gate") {
            XCTAssertEqual(looksLikeCodeText(codeReadText(try XCTUnwrap(v["text"] as? String))), v["expect"] as? Bool, "\(v)")
        }
    }

    func testServiceAndSender() throws {
        for v in try cases("serviceKey") {
            XCTAssertEqual(codeServiceKey(try XCTUnwrap(v["sender"] as? String)), v["expect"] as? String, "\(v)")
        }
        for v in try cases("sender") {
            XCTAssertEqual(codeSender(title: try XCTUnwrap(v["title"] as? String), applicationName: try XCTUnwrap(v["applicationName"] as? String)),
                           v["expect"] as? String, "\(v)")
        }
    }

    func testPromptAndAnswer() throws {
        for v in try cases("prompt") {
            XCTAssertEqual(CodeModelPrompt.user(sender: v["sender"] as? String, text: try XCTUnwrap(v["text"] as? String)), v["expect"] as? String, "\(v)")
        }
        for v in try cases("parse") {
            let expect = try XCTUnwrap(v["expect"] as? [String: Any])
            let want: CodeRelayAnswer
            switch expect["kind"] as? String {
            case "candidate": want = .candidate(try XCTUnwrap(expect["code"] as? String))
            case "none": want = .noCode
            default: want = .failed(.invalidResponse)
            }
            XCTAssertEqual(CodeModelPrompt.parse(try XCTUnwrap(v["output"] as? String)), want, "\(v)")
        }
    }

    func testCandidatesAndSnippets() throws {
        for v in try cases("candidate") {
            let f = try XCTUnwrap(v["fields"] as? [String: Any])
            let got = codeCandidate(packageName: try XCTUnwrap(f["packageName"] as? String), smsDefaultApp: f["smsDefaultApp"] as? Bool,
                                    redacted: f["redacted"] as? Bool, text: try XCTUnwrap(f["text"] as? String), emailApp: f["emailApp"] as? Bool,
                                    preview: f["preview"] as? String, emailCodes: f["emailCodes"] as? Bool ?? false)
            let expect = v["expect"] as? [String: Any]
            switch got {
            case let .sms(text):
                XCTAssertEqual(expect?["channel"] as? String, "sms", "\(v)")
                XCTAssertEqual(expect?["text"] as? String, text, "\(v)")
            case let .email(text):
                XCTAssertEqual(expect?["channel"] as? String, "email", "\(v)")
                XCTAssertEqual(expect?["text"] as? String, text, "\(v)")
            case nil:
                XCTAssertNil(expect, "\(v)")
            }
        }
        for v in try cases("emailSnippets") {
            XCTAssertEqual(emailModelSnippets(try XCTUnwrap(v["text"] as? String)), v["expect"] as? [String], "\(v)")
        }
    }
}
