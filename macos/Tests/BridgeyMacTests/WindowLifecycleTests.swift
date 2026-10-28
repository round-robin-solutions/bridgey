import AppKit
import XCTest
@testable import BridgeyMac

/// "Windows get stuck while trying to close" (beta 8, 2026-10-28): the Tray's send-options popover
/// stayed open over the Tray, covering its close button, because Bridgey is not the active app and
/// never saw the clicks outside it; and a call card stayed on screen after its hide. These drive the
/// shared close path and the watchdog with real windows and popovers.
@MainActor
final class WindowLifecycleTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var repairs: [String] = []
    private var pendingFades: [() -> Void] = []
    private var savedAnimate = BridgeyWindows.animateAlpha
    private var savedServer = BridgeyWindows.windowServerShows
    private var savedUnavailable = BridgeyWindows.screenUnavailable
    private var savedDeadline = BridgeyWindows.fadeDeadline
    private var clock = Date()

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        let watchdog = WindowWatchdog.shared
        watchdog.sweepInterval = 1_000
        watchdog.start()
        repairs = []
        pendingFades = []
        clock = Date()
        watchdog.now = { [unowned self] in clock }
        watchdog.onRepair = { [unowned self] _, reason in repairs.append(reason) }
        savedAnimate = BridgeyWindows.animateAlpha
        savedServer = BridgeyWindows.windowServerShows
        savedUnavailable = BridgeyWindows.screenUnavailable
        savedDeadline = BridgeyWindows.fadeDeadline
        BridgeyWindows.screenUnavailable = { false }
        BridgeyWindows.windowServerShows = { _ in false }
    }

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows = []
        BridgeyWindows.animateAlpha = savedAnimate
        BridgeyWindows.windowServerShows = savedServer
        BridgeyWindows.screenUnavailable = savedUnavailable
        BridgeyWindows.fadeDeadline = savedDeadline
        WindowWatchdog.shared.now = Date.init
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A Tray-like panel: titled, closable, non-activating, with a button to anchor a popover.
    private func makePanel() -> (StatusPanel, NSButton) {
        let panel = StatusPanel(contentRect: NSRect(x: 200, y: 200, width: 340, height: 320),
                                styleMask: [.titled, .closable, .fullSizeContentView, .resizable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        let button = NSButton(title: "Original, no location", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 200, height: 28)
        panel.contentView?.addSubview(button)
        panel.orderFrontRegardless()
        windows.append(panel)
        return (panel, button)
    }

    private func showPopover(from button: NSButton) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 326, height: 300))
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        spin(0.3)
        XCTAssertTrue(popover.isShown, "the popover did not open")
        return popover
    }

    private func visiblePopoverWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.className.contains("Popover") }
    }

    private func assertNothingLeft(_ popover: NSPopover, _ panel: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(popover.isShown, "the popover is still shown", file: file, line: line)
        XCTAssertEqual(visiblePopoverWindows().count, 0, "a popover window is still visible", file: file, line: line)
        XCTAssertFalse(panel.isVisible, "the panel is still visible", file: file, line: line)
    }

    func testClosingAPanelClosesItsPopoverFirst() {
        let (panel, button) = makePanel()
        let popover = showPopover(from: button)
        BridgeyWindows.close(panel)
        spin(0.3)
        assertNothingLeft(popover, panel)
    }

    /// The close button and Command-W go through AppKit, not BridgeyWindows.
    func testCloseButtonAlsoTakesThePopover() {
        let (panel, button) = makePanel()
        let popover = showPopover(from: button)
        panel.performClose(nil)
        spin(0.3)
        assertNothingLeft(popover, panel)
    }

    func testEscapeOnTheTrayPanelTakesThePopover() {
        let (panel, button) = makePanel()
        let popover = showPopover(from: button)
        panel.cancelOperation(nil)
        spin(0.3)
        assertNothingLeft(popover, panel)
    }

    /// Bridgey is not the active app: AppKit never sees a click in another app, the watchdog does.
    func testClickInAnotherAppClosesThePopover() {
        let (panel, button) = makePanel()
        let popover = showPopover(from: button)
        WindowWatchdog.shared.outsideClick()
        spin(0.5)
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(visiblePopoverWindows().count, 0)
        XCTAssertTrue(panel.isVisible, "an outside click closes the popover, not the panel")
    }

    func testSwitchingToAnotherAppClosesThePopover() throws {
        let (panel, button) = makePanel()
        let popover = showPopover(from: button)
        // Bridgey itself becoming active keeps it.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                                   userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        spin(0.2)
        XCTAssertTrue(popover.isShown)
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                                   userInfo: [NSWorkspace.applicationUserInfoKey: other])
        spin(0.3)
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(visiblePopoverWindows().count, 0)
        XCTAssertTrue(panel.isVisible)
    }

    func testPopoverWhoseWindowWentAwayIsClosed() {
        let (panel, button) = makePanel()
        let popover = showPopover(from: button)
        // The window went without telling anyone (as AppKit does when an app hides).
        if let popoverWindow = popover.contentViewController?.view.window { panel.removeChildWindow(popoverWindow) }
        panel.orderOut(nil)
        WindowWatchdog.shared.sweep()
        spin(0.3)
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(visiblePopoverWindows().count, 0)
    }

    func testSheetEndsBeforeItsWindowCloses() {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        windows += [parent, sheet]
        parent.beginSheet(sheet)
        spin(0.4)
        BridgeyWindows.close(parent)
        spin(0.4)
        XCTAssertNil(parent.attachedSheet)
        XCTAssertFalse(sheet.isVisible)
        XCTAssertFalse(parent.isVisible)
    }

    func testFadeOutThatNeverFinishesStillOrdersOut() {
        BridgeyWindows.animateAlpha = { _, _, _, _ in }
        BridgeyWindows.fadeDeadline = 0.05
        let (panel, _) = makePanel()
        BridgeyWindows.fadeOut(panel)
        XCTAssertTrue(panel.isVisible, "fading")
        spin(0.2)
        XCTAssertFalse(panel.isVisible, "the deadline ordered it out")
    }

    func testLockedScreenHidesAtOnce() {
        BridgeyWindows.animateAlpha = { _, _, _, _ in XCTFail("no fade on a locked screen") }
        BridgeyWindows.screenUnavailable = { true }
        let (panel, _) = makePanel()
        BridgeyWindows.fadeOut(panel)
        XCTAssertFalse(panel.isVisible)
    }

    /// The toast race: a toast fading out when the next toast arrives.
    func testShowDuringFadeOutWins() {
        BridgeyWindows.animateAlpha = { [unowned self] window, alpha, _, completion in
            pendingFades.append {
                window.alphaValue = alpha
                completion()
            }
        }
        BridgeyWindows.fadeDeadline = 0.1
        let (panel, _) = makePanel()
        BridgeyWindows.fadeOut(panel)
        let staleFadeOut = pendingFades.removeFirst()
        // The next show.
        BridgeyWindows.cancelFade(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        staleFadeOut()
        spin(0.3)
        XCTAssertTrue(panel.isVisible, "an old fade-out hid the new window")
    }

    func testDropToastRapidShowAndHide() {
        BridgeyWindows.animateAlpha = { [unowned self] window, alpha, _, completion in
            pendingFades.append {
                window.alphaValue = alpha
                completion()
            }
        }
        BridgeyWindows.fadeDeadline = 0.05
        let toast = DropToastController()
        for round in 0..<20 {
            toast.show(DropToastModel(text: "Sent \(round)", actions: []), near: nil, seconds: 60)
            if round.isMultiple(of: 3) { pendingFades.forEach { $0() }; pendingFades = [] }
            toast.hide()
            if round.isMultiple(of: 2) { pendingFades.reversed().forEach { $0() }; pendingFades = [] }
        }
        toast.show(DropToastModel(text: "Last", actions: []), near: nil, seconds: 60)
        let pending = pendingFades
        pendingFades = []
        pending.forEach { $0() }
        spin(0.2)
        XCTAssertTrue(toast.panel?.isVisible ?? false, "the last toast was hidden by an older fade")
        XCTAssertEqual(toast.panel?.alphaValue, 1)
        toast.hide()
        spin(0.2)
        XCTAssertFalse(toast.panel?.isVisible ?? true, "the toast stayed after its hide")
        if let panel = toast.panel { windows.append(panel) }
    }

    func testWatchdogOrdersOutAWindowLeftOnScreen() {
        let (panel, _) = makePanel()
        let number = panel.windowNumber
        panel.orderOut(nil)
        // The window server keeps drawing it.
        BridgeyWindows.windowServerShows = { $0 == number }
        let watchdog = WindowWatchdog.shared
        watchdog.sweep()
        XCTAssertEqual(repairs, [], "a window just ordered out may still be animating")
        clock = clock.addingTimeInterval(2)
        watchdog.sweep()
        XCTAssertEqual(repairs, ["still_on_screen"])
        XCTAssertEqual(panel.alphaValue, 0, "a stuck window is made transparent")
        clock = clock.addingTimeInterval(2)
        watchdog.sweep()
        XCTAssertEqual(repairs, ["still_on_screen", "resynced"])
        XCTAssertFalse(panel.isVisible)
        BridgeyWindows.windowServerShows = { _ in false }
        clock = clock.addingTimeInterval(2)
        watchdog.sweep()
        XCTAssertEqual(repairs.count, 2, "a window that left the screen is not touched again")
    }

    func testWatchdogLeavesWindowsMidAnimationAlone() {
        let (panel, _) = makePanel()
        let number = panel.windowNumber
        panel.orderOut(nil)
        BridgeyWindows.windowServerShows = { $0 == number }
        WindowWatchdog.shared.sweep()
        clock = clock.addingTimeInterval(1)
        BridgeyWindows.windowServerShows = { _ in false }
        WindowWatchdog.shared.sweep()
        clock = clock.addingTimeInterval(2)
        WindowWatchdog.shared.sweep()
        XCTAssertEqual(repairs, [])
        XCTAssertEqual(panel.alphaValue, 1)
    }

    func testRapidCloseAndReopenEndsWhereTheLastCallSaid() {
        BridgeyWindows.animateAlpha = { [unowned self] window, alpha, _, completion in
            pendingFades.append {
                window.alphaValue = alpha
                completion()
            }
        }
        BridgeyWindows.fadeDeadline = 0.05
        let (panel, button) = makePanel()
        for round in 0..<30 {
            BridgeyWindows.fadeOut(panel)
            if round.isMultiple(of: 4) { pendingFades.forEach { $0() }; pendingFades = [] }
            BridgeyWindows.cancelFade(panel)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        let popover = showPopover(from: button)
        BridgeyWindows.fadeOut(panel)
        XCTAssertFalse(popover.isShown, "the popover goes before the fade")
        spin(0.2)
        pendingFades.forEach { $0() }
        assertNothingLeft(popover, panel)
    }
}
