import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Fixture-owned windows and synthetic lifecycle notifications. This does not drive a real
/// Control Center menu or inspect any running user's Settings, preferences or screen contents.
@MainActor
final class SettingsWindowLifecycleTests: XCTestCase {
    private var window: SettingsWindow!
    private var events: [SettingsWindow.Lifecycle] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        events = []
        let content = NSHostingController(rootView: Text("Synthetic fixture"))
        window = SettingsWindow.make(content: content, title: "Private fixture title", frameAutosaveName: nil)
        window.onLifecycle = { [unowned self] in events.append($0) }
    }

    override func tearDown() {
        window.close()
        window = nil
        events = []
        super.tearDown()
    }

    func testProductionFactoryCreatesAnIndependentPersistentWindow() {
        let native: NSWindow = window
        XCTAssertFalse(native is NSPanel)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.transient))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertEqual(window.identifier, SettingsSearchKeys.windowID)
        XCTAssertNil(window.parent)
    }

    func testSyntheticDeactivationAndOcclusionDoNotHideSettings() {
        window.orderFrontRegardless()
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            NotificationCenter.default.post(name: name, object: NSApp)
        }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(events.contains { $0.event == "close" || $0.event == "order_out" })
        XCTAssertTrue(events.contains { $0.event == "app_inactive" })
        XCTAssertTrue(events.contains { $0.event == "occlusion" })
        XCTAssertTrue(events.allSatisfy { !$0.line.contains("Private fixture title") })
    }

    func testMenuPanelDismissalCannotCloseTheIndependentSettingsWindow() {
        let panel = MenuBarStatusController(content: NSHostingController(rootView: AnyView(Text("Panel fixture"))))
        panel.reduceMotion = { true }
        panel.currentEvent = { nil }
        defer {
            panel.close(animated: false)
            NSStatusBar.system.removeStatusItem(panel.statusItem)
        }
        window.orderFrontRegardless()
        panel.open(byDrag: false)
        panel.dismissFromOutside()
        XCTAssertFalse(panel.isOpen)
        XCTAssertTrue(window.isVisible)
        panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertTrue(window.isVisible)
    }

    func testExplicitCloseStaysClosedAndReopeningKeepsTheContent() {
        let content = window.contentViewController
        window.orderFrontRegardless()
        window.close()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(events.contains { $0.event == "close" })
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.contentViewController === content)
    }
}
