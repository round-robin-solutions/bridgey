import XCTest
@testable import BridgeyMacStore

final class StoreBoundaryTests: XCTestCase {
    func testStoreCannotDispatchExcludedFeatures() {
        for kind in ["remote_input.event", "media.command", "handoff.takeover", "updates.start", "sms.send", "actions.run", "screen.start", "settings.update", "camera.request", "agent.ask"] {
            XCTAssertFalse(StorePolicy.permits(kind), kind)
        }
        XCTAssertEqual(Set(StorePolicy.features.filter(\.value).keys), ["files", "clipboard", "notifications"])
    }
    func testUntrustedFilenamesCannotEscapeDestination() {
        for name in ["../escape", "/etc/passwd", "..", "folder/file", "a\\b", "a:b", "bad\0name"] { XCTAssertNil(StorePolicy.fileName(name)) }
        XCTAssertEqual(StorePolicy.fileName("Report.pdf"), "Report.pdf")
    }
    func testSharedEnvelopeTagBindsSenderAndKind() throws {
        let key = Data(repeating: 7, count: 32)
        var message = PairingMessage(kind: "clipboard.update", sessionId: "session", messageId: "message")
        message.tag = SessionSecurity.tag(envelopeKey: key, senderDeviceID: "phone", message: message)
        XCTAssertTrue(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: "phone", message: message))
        XCTAssertFalse(SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: "other", message: message))
    }
}
