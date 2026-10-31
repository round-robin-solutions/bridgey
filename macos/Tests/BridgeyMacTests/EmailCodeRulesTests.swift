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
            let normalised = codeReadText(vector.text)
            if normalised != vector.normalised { failures.append("\(index) normalised") }
            if emailCodePrecheck(normalised) != vector.precheck { failures.append("\(index) precheck want \(vector.precheck)") }
            if codeGuardText(normalised) != vector.guardText { failures.append("\(index) guardText") }
            let snippets = vector.precheck ? emailModelSnippets(normalised) : []
            if snippets != vector.snippets { failures.append("\(index) snippets") }
        }
        XCTAssertEqual(failures, [], "vectors that differ from email_guard.py (index and part; texts are not printed)")
    }

    func testTheGuardIgnoresCodesThatOnlyAppearInLinks() {
        let text = "Your verification code is below. https://example.com/verify/482913"
        XCTAssertNil(CodeGuard.accept("482913", in: codeGuardText(text)))
        XCTAssertEqual(CodeGuard.accept("482913", in: codeGuardText("Your code is 482913. https://example.com/x")), "482913")
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

        private func record(_ text: String) {
            lock.lock()
            seen.append(text)
            lock.unlock()
        }

        func answer(text: String, sender: String?) async -> CodeRelayAnswer {
            record(text)
            return answer(text)
        }
    }

    private let preview = "Welcome back to Acme, we are glad you are here and we hope you enjoy every part of it today. "
        + "To finish signing in, enter your one-time code 730164 on the page you came from. "
        + "If this was not you, reset your password at https://acme.example/reset/91827364."

    func testASnippetIsReadWhenTheWholePreviewGivesNothing() async {
        let source = ScriptedSource { $0.count < 200 ? .candidate("730164") : .noCode }
        let outcome = await CodeReader(source: source).read(text: preview, sender: "Acme", channel: .email)
        XCTAssertEqual(outcome, .code("730164"))
        XCTAssertEqual(source.texts.count, 2, "the whole preview, then one snippet")
        XCTAssertEqual(source.texts.first, preview)
    }

    func testAModelMissingAnswerStopsAtOnce() async {
        let source = ScriptedSource { _ in .failed(.modelMissing) }
        let outcome = await CodeReader(source: source).read(text: preview, sender: "Acme", channel: .email)
        XCTAssertEqual(outcome, .fallback(.modelMissing))
        XCTAssertEqual(source.texts.count, 1)
    }

    func testACodeOnlyInALinkIsRefused() async {
        let source = ScriptedSource { _ in .candidate("91827364") }
        let outcome = await CodeReader(source: source).read(text: preview, sender: "Acme", channel: .email)
        XCTAssertEqual(outcome, .noCode)
    }
}

/// Text messages take the same path: the digit-box join, the shared gate and the guard with links blanked.
final class SharedCodePathTests: XCTestCase {
    private final class Counting: CodeAnswerSource, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let reply: CodeRelayAnswer
        init(_ reply: CodeRelayAnswer) { self.reply = reply }
        var reads: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        private func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        func answer(text: String, sender: String?) async -> CodeRelayAnswer {
            bump()
            return reply
        }
    }

    func testATextMessageJoinsDigitBoxesAndPassesTheSharedGate() {
        XCTAssertEqual(codeCandidate(packageName: "com.google.android.apps.messaging", smsDefaultApp: true, redacted: nil,
                                     text: "Your Spotify code: 4 8 2 9 1 3"),
                       .sms("Your Spotify code: 482913"))
        XCTAssertEqual(codeCandidate(packageName: "com.google.android.apps.messaging", smsDefaultApp: true, redacted: nil,
                                     text: "Steam Guard code 7Q3-9XT"),
                       .sms("Steam Guard code 7Q3-9XT"), "a split letters-and-digits code passes the gate")
        XCTAssertTrue(looksLikeCodeText("Steam Guard code 7Q3-9XT"))
        XCTAssertFalse(looksLikeOtpTraffic("Steam Guard code 7Q3-9XT"), "the relay's own pre-check alone missed it")
    }

    func testATextMessageIsReadOnceAndItsGuardIgnoresLinks() async {
        let none = Counting(.noCode)
        let long = "Your order is on its way. " + String(repeating: "Track it in the app any time you like. ", count: 6)
            + "Your delivery code is 482913, share it with the rider."
        let outcome = await CodeReader(source: none).read(text: long, sender: "AMAZON")
        XCTAssertEqual(outcome, .noCode)
        XCTAssertEqual(none.reads, 1, "no second read on snippets for a text message")
        let linkOnly = Counting(.candidate("482913"))
        let refused = await CodeReader(source: linkOnly).read(text: "Track your parcel: https://track.example/p/482913", sender: "AMAZON")
        XCTAssertEqual(refused, .noCode, "a code only inside a link is refused for SMS too")
        let accepted = await CodeReader(source: Counting(.candidate("482913"))).read(text: "OTP 482913 for your order", sender: "AMAZON")
        XCTAssertEqual(accepted, .code("482913"))
    }
}
