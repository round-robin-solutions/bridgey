import AppKit
import XCTest
@testable import BridgeyMac

/// AppPasteboard (Edition.swift): the app's clipboard features use the system clipboard; only a debug test instance
/// gets a private pasteboard, so live tests never touch the person's clipboard or feed the real app's automatic clipboard.
final class AppPasteboardTests: XCTestCase {
    func testTheAppUsesTheSystemClipboard() {
        XCTAssertFalse(TestInstance.enabled)
        XCTAssertEqual(AppPasteboard.current.name, NSPasteboard.general.name)
    }
}
