import Foundation
import XCTest
@testable import BridgeyMac

/// The Swift port of the email rules gives exactly the answers of the reference in
/// outputs/bridgey/research/otp-tiny-model/email/email_guard.py (the final rule measured in the
/// Phase 0 eval), stored in protocol/test-vectors/email-codes-v1.json. Android checks its preview
/// gate against the same file.
final class EmailCodeRulesTests: XCTestCase {
    private struct Vector: Decodable {
        let text: String
        let phoneGate: Bool
        let normalised: String
        let precheck: Bool
        let guardText: String
        let snippets: [String]
    }

    private struct File: Decodable { let vectors: [Vector] }

    private func vectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/email-codes-v1.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).vectors
    }

    func testThePortMatchesTheEvalReference() throws {
        let all = try vectors()
        XCTAssertGreaterThan(all.count, 400)
        var failures: [String] = []
        for (index, vector) in all.enumerated() {
            let normalised = normaliseEmailText(vector.text)
            if normalised != vector.normalised { failures.append("\(index) normalised") }
            if emailCodePrecheck(normalised) != vector.precheck { failures.append("\(index) precheck want \(vector.precheck)") }
            if emailGuardText(normalised) != vector.guardText { failures.append("\(index) guardText") }
            let snippets = vector.precheck ? emailModelSnippets(normalised) : []
            if snippets != vector.snippets { failures.append("\(index) snippets") }
        }
        XCTAssertEqual(failures, [], "vectors that differ from email_guard.py (index and part; texts are not printed)")
    }

    func testTheGuardIgnoresCodesThatOnlyAppearInLinks() {
        let text = "Your verification code is below. https://example.com/verify/482913"
        XCTAssertNil(CodeGuard.accept("482913", in: emailGuardText(text)))
        XCTAssertEqual(CodeGuard.accept("482913", in: emailGuardText("Your code is 482913. https://example.com/x")), "482913")
    }
}

/// Mail previews: a second read on snippets when the whole preview gives no code, inside one budget.
final class EmailCodeReadTests: XCTestCase {
    /// Answers by the text it is given; records every text it saw.
    private final class ScriptedSource: CodeAnswerSource, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        let answer: @Sendable (String) -> CodeRelayAnswer

        init(_ answer: @escaping @Sendable (String) -> CodeRelayAnswer) { self.answer = answer }

        var texts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func answer(text: String, sender: String?) async -> CodeRelayAnswer {
            lock.lock()
            seen.append(text)
            lock.unlock()
            return answer(text)
        }
    }

    private let preview = "Welcome back to Acme, we are glad you are here and we hope you enjoy every part of it today. "
        + "To finish signing in, enter your one-time code 730164 on the page you came from. "
        + "If this was not you, reset your password at https://acme.example/reset/91827364."

    func testASnippetIsReadWhenTheWholePreviewGivesNothing() async {
        let source = ScriptedSource { $0.count < 200 ? .candidate("730164") : .noCode }
        let outcome = await CodeReader(source: source).readEmail(text: preview, sender: "Acme")
        XCTAssertEqual(outcome, .code("730164"))
        XCTAssertEqual(source.texts.count, 2, "the whole preview, then one snippet")
        XCTAssertEqual(source.texts.first, preview)
    }

    func testAModelMissingAnswerStopsAtOnce() async {
        let source = ScriptedSource { _ in .failed(.modelMissing) }
        let outcome = await CodeReader(source: source).readEmail(text: preview, sender: "Acme")
        XCTAssertEqual(outcome, .fallback(.modelMissing))
        XCTAssertEqual(source.texts.count, 1)
    }

    func testACodeOnlyInALinkIsRefused() async {
        let source = ScriptedSource { _ in .candidate("91827364") }
        let outcome = await CodeReader(source: source).readEmail(text: preview, sender: "Acme")
        XCTAssertEqual(outcome, .noCode)
    }
}
