import XCTest
@testable import BridgeyMac

final class LoggingPolicyTests: XCTestCase {
    private let off = LoggingPolicy(connection: false, calls: false, notifications: false, clipboard: false, remoteControl: false)

    override func tearDown() {
        BridgeyLog.policy = LoggingPolicy()
        super.tearDown()
    }

    func testDefaultsArePrivacyLeaningExceptCalls() {
        let policy = LoggingPolicy()
        XCTAssertTrue(policy.connection && policy.calls && policy.notifications && policy.clipboard && policy.remoteControl)
        XCTAssertFalse(policy.callNumbers || policy.notificationContent || policy.clipboardPreviews || policy.fileNames)
    }

    func testDisabledCategoriesProduceNoLogLines() {
        XCTAssertNil(LogLines.call(off, event: "shown", id: "0123456789", peer: "phone-1234", reason: "incoming", caller: "Asha"))
        XCTAssertNil(LogLines.notification(off, event: "shown", appName: "Chat", title: "Asha", text: "Hi"))
        XCTAssertNil(LogLines.clipboard(off, event: "received", preview: "secret"))
        for category in [LogCategory.connection, .calls, .notifications, .clipboard, .remoteControl] {
            XCTAssertFalse(off.allows(category))
        }
        XCTAssertTrue(off.allows(.files))
    }

    func testCallLinesCarryStateAndCallerButMaskNumbersByDefault() {
        XCTAssertEqual(
            LogLines.call(LoggingPolicy(), event: "shown", id: "0123456789abcdef", peer: "phone-123456", reason: "incoming", caller: "Asha Rao"),
            "call shown id=01234567 peer=phone-12 reason=incoming caller=\"Asha Rao\""
        )
        let masked = LogLines.call(LoggingPolicy(), event: "shown", id: "0123456789", peer: "phone", reason: "incoming", caller: "+91 98765 43210")
        XCTAssertEqual(masked, "call shown id=01234567 peer=phone reason=incoming caller=\"[number]\"")
        var numbers = LoggingPolicy()
        numbers.callNumbers = true
        XCTAssertTrue(LogLines.call(numbers, event: "shown", id: "0123456789", peer: "phone", reason: "incoming", caller: "+91 98765 43210")!.contains("98765"))
    }

    func testMaskingKeepsShortNumbers() {
        XCTAssertEqual(maskPhoneNumbers("Flat 12 office"), "Flat 12 office")
        XCTAssertEqual(maskPhoneNumbers("Mum 9876543210"), "Mum [number]")
        XCTAssertEqual(maskPhoneNumbers("(011) 2345-6789"), "[number]")
    }

    func testContentFieldsOnlyWhenAllowed() {
        XCTAssertEqual(LogLines.notification(LoggingPolicy(), event: "shown", appName: "Chat", title: "Asha", text: "Hi"), "notification shown app=\"Chat\"")
        var content = LoggingPolicy()
        content.notificationContent = true
        content.clipboardPreviews = true
        content.fileNames = true
        XCTAssertEqual(LogLines.notification(content, event: "shown", appName: "Chat", title: "Asha", text: "Hi"),
                       "notification shown app=\"Chat\" title=\"Asha\" text=\"Hi\"")
        XCTAssertEqual(LogLines.clipboard(LoggingPolicy(), event: "received", preview: "password"), "clipboard received")
        XCTAssertEqual(LogLines.clipboard(content, event: "received", preview: "one\ntwo"), "clipboard received preview=\"one two\"")
        XCTAssertEqual(LogLines.file(LoggingPolicy(), event: "received", transfer: "abcdef0123", name: "Payslip.pdf"), "file received transfer=abcdef01")
        XCTAssertEqual(LogLines.file(content, event: "received", transfer: "abcdef0123", name: "Payslip.pdf"),
                       "file received transfer=abcdef01 name=\"Payslip.pdf\"")
    }

    func testDisabledCategoriesNeverReachDiagnostics() {
        var policy = off
        let diagnostics = BridgeyDiagnostics(allows: { policy.allows(diagnosticLogCategory($0)) })
        for category in ["transport", "reconnect", "pairing", "discovery", "call", "notification", "clipboard", "remote", "transfer"] {
            diagnostics.record(category: category, event: "event")
        }
        XCTAssertEqual(diagnostics.snapshot().map(\.category), ["transfer"])

        policy = LoggingPolicy()
        diagnostics.record(category: "call", event: "shown")
        XCTAssertEqual(diagnostics.snapshot().map(\.category), ["transfer", "call"])
    }

    func testDefaultDiagnosticsFollowTheCurrentPolicy() {
        BridgeyLog.policy = off
        let diagnostics = BridgeyDiagnostics()
        diagnostics.record(category: "call", event: "shown")
        XCTAssertTrue(diagnostics.snapshot().isEmpty)
        BridgeyLog.policy = LoggingPolicy()
        diagnostics.record(category: "call", event: "shown")
        XCTAssertEqual(diagnostics.snapshot().count, 1)
    }

    func testClearLogsEmptiesDiagnostics() {
        let diagnostics = BridgeyDiagnostics(allows: { _ in true })
        diagnostics.record(category: "call", event: "shown")
        diagnostics.clear()
        XCTAssertTrue(diagnostics.snapshot().isEmpty)
    }

    func testPolicyRoundTripsThroughDefaults() {
        var custom = LoggingPolicy()
        custom.connection = false
        custom.callNumbers = true
        custom.fileNames = true
        let stored = loggingPreferenceValues(custom)
        XCTAssertEqual(loggingPolicy { key, fallback in stored[key] ?? fallback }, custom)
        XCTAssertEqual(loggingPolicy { _, fallback in fallback }, LoggingPolicy())
    }
}
