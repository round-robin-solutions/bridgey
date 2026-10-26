import CoreBluetooth
import Foundation
import XCTest
@testable import BridgeyMac

/// Codes from messages. Messages come only from protocol/test-vectors/otp-samples.json (synthetic).
final class CodeReaderTests: XCTestCase {
    private struct Sample {
        let id: String
        let body: String
        let sender: String
        let codes: [String]
    }

    private var samples: [Sample] = []

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/otp-samples.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let list = try XCTUnwrap(root["samples"] as? [[String: Any]])
        samples = list.map {
            Sample(id: $0["id"] as! String, body: $0["body"] as! String, sender: $0["sender"] as! String, codes: $0["code"] as! [String])
        }
        XCTAssertEqual(samples.count, 42)
    }

    private func sample(_ id: String) -> Sample { samples.first { $0.id == id }! }

    // MARK: Guard

    func testGuardAcceptsEveryExpectedCodeAsWritten() {
        for item in samples where !item.codes.isEmpty {
            for code in item.codes {
                let accepted = CodeGuard.accept(code, in: item.body)
                let expected = code.replacingOccurrences(of: "G-", with: "").filter { $0 != "-" && $0 != " " }
                XCTAssertEqual(accepted, expected, item.id)
            }
        }
    }

    func testGuardRefusesWhatIsNotLiterallyInTheMessage() {
        let otp = sample("otp01").body
        XCTAssertNil(CodeGuard.accept("482914", in: otp), "not in the text")
        XCTAssertNil(CodeGuard.accept("4829", in: otp), "part of a longer token")
        XCTAssertNil(CodeGuard.accept("4417", in: "card ending 44175"), "part of a longer token")
        // The invented code a model gave for the "authentication successful using OTP" notice.
        XCTAssertNil(CodeGuard.accept("123456", in: sample("neg12").body))
        // A live answer with junk after the code (otp26): 17 characters, so it falls back.
        XCTAssertNil(CodeGuard.accept("381-406 4sgLq1p5sV6", in: sample("otp26").body))
    }

    func testGuardRefusesShapesThatAreNotCodes() {
        let text = "Pay 2,499.00 now. Ref ABCDEF and 123 and 12345678901 and token AB12CD34EF56 and SAVE50"
        XCTAssertNil(CodeGuard.accept("2,499.00", in: text))
        XCTAssertNil(CodeGuard.accept("ABCDEF", in: text), "no digit")
        XCTAssertNil(CodeGuard.accept("123", in: text), "too short")
        XCTAssertNil(CodeGuard.accept("12345678901", in: text), "too long")
        XCTAssertNil(CodeGuard.accept("AB12CD34EF56", in: text), "too long")
        XCTAssertNil(CodeGuard.accept(nil, in: text))
        XCTAssertNil(CodeGuard.accept("", in: text))
        XCTAssertNil(CodeGuard.accept("  ", in: text))
        // Shape alone never decides: a promo code that is literally there passes; the model decides it is not a code.
        XCTAssertEqual(CodeGuard.accept("SAVE50", in: text), "SAVE50")
    }

    func testGuardKeepsTheMessagesLetterCaseAndJoinsSeparators() {
        XCTAssertEqual(CodeGuard.accept("ab3de9", in: "Your code is aB3dE9."), "aB3dE9")
        XCTAssertEqual(CodeGuard.accept("441902", in: "Use 441 902 to sign in"), "441902")
        XCTAssertEqual(CodeGuard.accept("441 902", in: "Use 441-902 to sign in"), "441902")
        XCTAssertEqual(CodeGuard.accept("G-739108", in: "G-739108 is your Google verification code."), "739108")
        XCTAssertNil(CodeGuard.accept("ABC-DEF1", in: "Use ABC-DEF1"), "every part needs a digit after the prefix")
    }

    // MARK: Pre-check

    func testPreCheckMatchesTheRelayGate() {
        for item in samples where !item.codes.isEmpty {
            XCTAssertTrue(looksLikeOtpTraffic(item.body), item.id)
        }
        // Same list the relay's tests record (services/otp-proxy/test).
        let rejected = samples.filter { $0.codes.isEmpty && !looksLikeOtpTraffic($0.body) }.map(\.id)
        XCTAssertEqual(rejected, ["neg03", "neg05", "neg07", "neg10"])
        XCTAssertFalse(looksLikeOtpTraffic("See you at the station"))
        XCTAssertTrue(looksLikeOtpTraffic("code 59-04"))
    }

    func testCandidatesAreUnhiddenSmsWithSomethingCodeLike() {
        let body = sample("otp01").body
        XCTAssertTrue(isCodeCandidate(packageName: "x.sms", smsDefaultApp: true, redacted: false, text: body))
        XCTAssertFalse(isCodeCandidate(packageName: "x.sms", smsDefaultApp: true, redacted: true, text: body))
        XCTAssertFalse(isCodeCandidate(packageName: "com.whatsapp", smsDefaultApp: false, redacted: nil, text: body))
        // An older phone does not say which app is the SMS app: the known list decides.
        XCTAssertTrue(isCodeCandidate(packageName: "com.google.android.apps.messaging", smsDefaultApp: nil, redacted: nil, text: body))
        XCTAssertFalse(isCodeCandidate(packageName: "com.whatsapp", smsDefaultApp: nil, redacted: nil, text: body))
        XCTAssertFalse(isCodeCandidate(packageName: "x.sms", smsDefaultApp: true, redacted: nil, text: "See you at 5"))
        XCTAssertFalse(isCodeCandidate(packageName: "x.sms", smsDefaultApp: true, redacted: nil, text: String(repeating: "a", count: 600) + " 482913 x"))
        XCTAssertFalse(isCodeCandidate(packageName: "x.sms", smsDefaultApp: true, redacted: nil, text: "   "))
    }

    // MARK: Relay request and answer

    private let installID = String(repeating: "ab", count: 32)

    func testRequestCarriesTextSenderAndInstallIDOnly() throws {
        let base = URL(string: "https://relay.example")!
        let request = try XCTUnwrap(CodeRelay.request(baseURL: base, installID: installID, text: "  OTP 482913 \n", sender: " HDFC Bank "))
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/extract")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bridgey-Install"), installID)
        XCTAssertEqual(request.timeoutInterval, CodeRelay.budget)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["v"] as? Int, 1)
        XCTAssertEqual(body["text"] as? String, "OTP 482913")
        XCTAssertEqual(body["sender"] as? String, "HDFC Bank")
        XCTAssertEqual(body.count, 3)
    }

    func testRequestLimits() throws {
        let base = URL(string: "https://relay.example")!
        XCTAssertNil(CodeRelay.request(baseURL: base, installID: "short", text: "OTP 482913", sender: nil))
        XCTAssertNil(CodeRelay.request(baseURL: base, installID: installID.uppercased(), text: "OTP 482913", sender: nil))
        XCTAssertNil(CodeRelay.request(baseURL: base, installID: installID, text: String(repeating: "1", count: 601), sender: nil))
        let noSender = try XCTUnwrap(CodeRelay.request(baseURL: base, installID: installID, text: "OTP 482913", sender: "  "))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(noSender.httpBody)) as? [String: Any])
        XCTAssertNil(body["sender"])
        // Sender capped at 64 UTF-16 units without splitting a character.
        let long = String(repeating: "\u{0939}\u{093F}", count: 40)
        XCTAssertEqual(CodeRelay.prefix(long, utf16Limit: 64).utf16.count, 64)
        XCTAssertEqual(CodeRelay.prefix("ab\u{1F600}", utf16Limit: 3), "ab")
        XCTAssertTrue(CodeRelay.isInstallID(CodeRelay.newInstallID()))
        XCTAssertNotEqual(CodeRelay.newInstallID(), CodeRelay.newInstallID())
    }

    func testParsesRelayAnswers() {
        func parse(_ status: Int, _ json: String) -> CodeRelayAnswer { CodeRelay.parse(status: status, data: Data(json.utf8)) }
        XCTAssertEqual(parse(200, #"{"is_otp":true,"code":"482913"}"#), .candidate("482913"))
        XCTAssertEqual(parse(200, #"{"is_otp":false,"code":null}"#), .noCode)
        XCTAssertEqual(parse(200, #"{"is_otp":true,"code":null}"#), .noCode)
        XCTAssertEqual(parse(200, #"{"is_otp":true,"code":""}"#), .noCode)
        XCTAssertEqual(parse(200, #"{"code":"482913"}"#), .failed(.invalidResponse))
        XCTAssertEqual(parse(200, "not json"), .failed(.invalidResponse))
        XCTAssertEqual(parse(422, #"{"error":"not_otp_like"}"#), .noCode)
        XCTAssertEqual(parse(429, #"{"error":"rate_limited"}"#), .failed(.rateLimited))
        XCTAssertEqual(parse(504, #"{"error":"timeout"}"#), .failed(.timeout))
        XCTAssertEqual(parse(502, #"{"error":"upstream"}"#), .failed(.unavailable))
        XCTAssertEqual(parse(0, ""), .failed(.unavailable))
    }

    // MARK: Reader

    private struct FakeTransport: CodeRelayTransport {
        var status = 200
        var body = #"{"is_otp":true,"code":"482913"}"#
        var delay: TimeInterval = 0
        var error: Error?

        func send(_ request: URLRequest) async throws -> (Int, Data) {
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if let error { throw error }
            return (status, Data(body.utf8))
        }
    }

    private func reader(_ transport: FakeTransport, budget: TimeInterval = 2, base: URL? = URL(string: "https://relay.example")) -> CodeReader {
        CodeReader(baseURL: base, installID: installID, transport: transport, budget: budget)
    }

    func testReaderShowsAGuardedCode() async {
        let text = sample("otp01").body
        let outcome = await reader(FakeTransport()).read(text: text, sender: "VM-HDFCBK")
        XCTAssertEqual(outcome, .code("482913"))
        XCTAssertEqual(outcome.diagnosticName, "found")
    }

    func testReaderFallsBackWhenTheGuardRefuses() async {
        let text = sample("otp01").body
        let outcome = await reader(FakeTransport(body: #"{"is_otp":true,"code":"999999"}"#)).read(text: text, sender: nil)
        XCTAssertEqual(outcome, .noCode)
    }

    func testReaderGivesUpAtTheBudget() async {
        let started = Date()
        let outcome = await reader(FakeTransport(delay: 5), budget: 0.2).read(text: sample("otp01").body, sender: nil)
        XCTAssertEqual(outcome, .fallback(.timeout))
        XCTAssertEqual(outcome.diagnosticName, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testReaderFallsBackOnErrorsAndMissingRelay() async {
        let text = sample("otp01").body
        let failed = await reader(FakeTransport(error: URLError(.notConnectedToInternet))).read(text: text, sender: nil)
        XCTAssertEqual(failed, .fallback(.unavailable))
        let timedOut = await reader(FakeTransport(error: URLError(.timedOut))).read(text: text, sender: nil)
        XCTAssertEqual(timedOut, .fallback(.timeout))
        let limited = await reader(FakeTransport(status: 429, body: "{}")).read(text: text, sender: nil)
        XCTAssertEqual(limited, .fallback(.rateLimited))
        let missing = await reader(FakeTransport(), base: nil).read(text: text, sender: nil)
        XCTAssertEqual(missing, .fallback(.notConfigured))
    }

    // MARK: Presentation

    func testNotificationTitleUsesTheSenderElseTheApp() {
        XCTAssertEqual(codeNotificationTitle(code: "482913", sender: "HDFC Bank", applicationName: "Messages"), "Code 482913 from HDFC Bank")
        XCTAssertEqual(codeNotificationTitle(code: "482913", sender: "  ", applicationName: "Messages"), "Code 482913 from Messages")
    }

    func testAutoCopyNeedsTheSettingAnUnlockedMacAndRecentInput() {
        XCTAssertTrue(shouldAutoCopyCode(enabled: true, screenLocked: false, idleSeconds: 5))
        XCTAssertFalse(shouldAutoCopyCode(enabled: false, screenLocked: false, idleSeconds: 5))
        XCTAssertFalse(shouldAutoCopyCode(enabled: true, screenLocked: true, idleSeconds: 5))
        XCTAssertFalse(shouldAutoCopyCode(enabled: true, screenLocked: false, idleSeconds: 120))
    }

    func testCopiedLineCountsDown() {
        let start = Date(timeIntervalSince1970: 1_000)
        var card = LiveCodeCard(id: "r", code: "482913", sender: "HDFC Bank", deviceName: "OnePlus 11", receivedAt: start)
        XCTAssertNil(card.copiedLine(now: start))
        card.copiedAt = start
        XCTAssertEqual(card.copiedLine(now: start.addingTimeInterval(18.2)), "Copied. Clears in 42 s.")
        XCTAssertNil(card.copiedLine(now: start.addingTimeInterval(60)))
        card.copiedAutomatically = true
        XCTAssertEqual(card.copiedLine(now: start), "Copied automatically. Clears in 60 s.")
    }

    // MARK: Companion link status

    func testCodeAccessStatusMapping() {
        XCTAssertEqual(CodeAccessStatus(wire: "allowed"), .allowed)
        XCTAssertEqual(CodeAccessStatus(wire: "hidden"), .hidden)
        XCTAssertEqual(CodeAccessStatus(wire: "not_linked"), .notLinked)
        XCTAssertNil(CodeAccessStatus(wire: "linked"))
        XCTAssertEqual(CodeAccessDisplay.status(.allowed).text, "Allowed: Android shows Bridgey the full message")
        XCTAssertEqual(CodeAccessDisplay.status(.hidden).text, "Hidden by Android: link this phone to the Mac")
        XCTAssertEqual(CodeAccessDisplay.status(.notLinked).text, "Not linked: Android may hide codes from Bridgey")
        XCTAssertFalse(CodeAccessDisplay.status(.allowed).offersLink)
        XCTAssertTrue(CodeAccessDisplay.status(.hidden).offersLink)
        XCTAssertTrue(CodeAccessDisplay.status(.hidden).isWarning)
        XCTAssertFalse(CodeAccessDisplay.noPhone.offersLink)
        XCTAssertFalse(CodeAccessDisplay.phoneTooOld.offersLink)
    }

    func testAdvertiseReadiness() {
        XCTAssertEqual(try? companionAdvertiseReadiness(.poweredOn).get(), true)
        XCTAssertEqual(try? companionAdvertiseReadiness(.unknown).get(), false)
        XCTAssertEqual(try? companionAdvertiseReadiness(.resetting).get(), false)
        XCTAssertEqual(companionAdvertiseReadiness(.poweredOff), .failure(.bluetoothOff))
        XCTAssertEqual(companionAdvertiseReadiness(.unauthorized), .failure(.unauthorized))
        XCTAssertEqual(companionAdvertiseReadiness(.unsupported), .failure(.unsupported))
    }
}

/// Copy code: concealed, kept on this Mac, cleared after 60 s only if nothing else was copied.
@MainActor
final class CodeClipboardTests: XCTestCase {
    private final class FakePasteboard: CodePasteboard {
        var changeCount = 10
        var written: [String] = []
        var cleared = 0

        func writeCode(_ code: String) -> Int {
            changeCount += 1
            written.append(code)
            return changeCount
        }

        func clearCode() {
            changeCount += 1
            cleared += 1
        }
    }

    private var scheduled: [(TimeInterval, @MainActor () -> Void)] = []

    private func clipboard(_ pasteboard: FakePasteboard) -> CodeClipboard {
        CodeClipboard(pasteboard: pasteboard) { [weak self] delay, work in self?.scheduled.append((delay, work)) }
    }

    func testClearsAfterSixtySecondsWhenUnchanged() {
        let board = FakePasteboard()
        let clip = clipboard(board)
        clip.copy("482913")
        XCTAssertEqual(board.written, ["482913"])
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].0, 60)
        scheduled[0].1()
        XCTAssertEqual(board.cleared, 1)
        XCTAssertNil(clip.pendingChangeCount)
    }

    func testLeavesALaterCopyAlone() {
        let board = FakePasteboard()
        let clip = clipboard(board)
        clip.copy("482913")
        board.changeCount += 1 // the user copied something else
        scheduled[0].1()
        XCTAssertEqual(board.cleared, 0)
    }

    func testANewCodeReplacesTheOldTimer() {
        let board = FakePasteboard()
        let clip = clipboard(board)
        clip.copy("482913")
        clip.copy("730164")
        scheduled[0].1() // the first timer no longer owns the clipboard
        XCTAssertEqual(board.cleared, 0)
        scheduled[1].1()
        XCTAssertEqual(board.cleared, 1)
    }

    func testRealPasteboardWriteIsConcealedTransientAndLocal() {
        let board = NSPasteboard(name: NSPasteboard.Name("bridgey.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let count = board.writeCode("482913")
        XCTAssertEqual(count, board.changeCount)
        let types = Set((board.types ?? []).map(\.rawValue))
        XCTAssertTrue(types.contains("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(types.contains("org.nspasteboard.TransientType"))
        XCTAssertTrue(clipboardTypesAreSecret(Array(types)), "Automatic clipboard must skip it")
        XCTAssertEqual(board.string(forType: .string), "482913")
        board.clearCode()
        XCTAssertNil(board.string(forType: .string))
    }
}
