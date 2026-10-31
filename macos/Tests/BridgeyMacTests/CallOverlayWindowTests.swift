import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The call card stuck on screen as an empty glass panel after a call ended (beta 8, 2026-10-28):
/// two calls reused one id, and the second ended while the Mac was locked with its display off.
/// These drive the real card controller and its real window through that and the nearby cases.
@MainActor
final class CallOverlayWindowTests: XCTestCase {
    /// The system as the card sees it: fades finish only when a test says so, or never.
    @MainActor
    private final class FakeSystem {
        enum FadeMode { case immediate, manual, never }
        var fadeMode = FadeMode.manual
        var locked = false
        var windowServerShows = false
        private(set) var fadeCount = 0
        private var pending: [() -> Void] = []

        func environment(deadline: TimeInterval = 5, watchdog: TimeInterval = 60) -> CallOverlayEnvironment {
            CallOverlayEnvironment(
                fade: { [unowned self] window, alpha, _, completion in
                    fadeCount += 1
                    switch fadeMode {
                    case .immediate:
                        window.alphaValue = alpha
                        completion()
                    case .manual:
                        pending.append {
                            window.alphaValue = alpha
                            completion()
                        }
                    case .never:
                        break
                    }
                },
                screenUnavailable: { [unowned self] in locked },
                windowServerShows: { [unowned self] _ in windowServerShows },
                fadeDuration: 0.01,
                transitionDeadline: deadline,
                watchdogInterval: watchdog
            )
        }

        /// Finishes the fades still running, oldest first unless `newestFirst`.
        func finishFades(newestFirst: Bool = false) {
            let fades = newestFirst ? pending.reversed() : pending
            pending.removeAll()
            fades.forEach { $0() }
        }

        /// The oldest fade still running, kept to finish late.
        func takeOldestFade() -> () -> Void {
            pending.removeFirst()
        }
    }

    private var repairs: [String] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        repairs = []
    }

    override func tearDown() {
        for window in NSApp.windows where window.identifier == callOverlayWindowIdentifier {
            window.orderOut(nil)
            window.close()
        }
        super.tearDown()
    }

    private func makeController(_ system: FakeSystem, deadline: TimeInterval = 5, watchdog: TimeInterval = 60) -> CallOverlayWindowController {
        let controller = CallOverlayWindowController(environment: system.environment(deadline: deadline, watchdog: watchdog))
        controller.onRepair = { [unowned self] reason, _ in repairs.append(reason) }
        return controller
    }

    private func call(_ caller: String, id: String = "f50c2274aa", type: String = "ongoing") -> RemoteCallStatus {
        RemoteCallStatus(
            notificationID: id, deviceID: "5dfae7ce00", applicationName: "Phone",
            caller: caller, detail: "", type: type,
            actions: [RemoteCallAction(id: "hang", title: "Hang up")]
        )
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Every call card window in the app that is on screen with no call on it.
    private func visibleEmptyCallWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard window.identifier == callOverlayWindowIdentifier, window.isVisible else { return false }
            let root = (window.contentViewController as? NSHostingController<CallOverlayView>)?.rootView
            return root?.content.call == nil
        }
    }

    private func assertNoEmptyCard(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(visibleEmptyCallWindows().count, 0, "an empty call card is on screen: \(message)", file: file, line: line)
    }

    private func assertHidden(_ controller: CallOverlayWindowController, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(controller.isShowing, message, file: file, line: line)
        XCTAssertFalse(controller.panel?.isVisible ?? false, "the card is still ordered in: \(message)", file: file, line: line)
        XCTAssertEqual(controller.panel?.alphaValue ?? 0, 0, "a hidden card stays transparent: \(message)", file: file, line: line)
        XCTAssertNil(controller.content.call, message, file: file, line: line)
        XCTAssertTrue(
            NSApp.windows.filter { $0.identifier == callOverlayWindowIdentifier && $0.isVisible }.isEmpty,
            "a call window is still visible: \(message)", file: file, line: line
        )
    }

    private func assertShowing(_ controller: CallOverlayWindowController, _ caller: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(controller.isShowing, file: file, line: line)
        XCTAssertTrue(controller.panel?.isVisible ?? false, file: file, line: line)
        XCTAssertEqual(controller.content.call?.caller, caller, file: file, line: line)
    }

    /// Rahul's log: call shown, ended, the same id shown for another caller, ended.
    func testSameIDCallDuringFadeOutThenEndLeavesNoWindow() {
        let system = FakeSystem()
        let controller = makeController(system)
        controller.show(call("Rtr. Kamakshi Aggarwal"))
        system.finishFades()
        assertShowing(controller, "Rtr. Kamakshi Aggarwal")
        XCTAssertEqual(controller.panel?.alphaValue, 1)

        controller.hide()
        let staleFadeOut = system.takeOldestFade()
        assertNoEmptyCard("first call fading out")
        controller.show(call("Ghazal"))
        assertShowing(controller, "Ghazal")
        // The first call's fade-out finishes after the second call appeared: it must not hide it.
        staleFadeOut()
        assertShowing(controller, "Ghazal")
        system.finishFades()
        assertShowing(controller, "Ghazal")
        XCTAssertEqual(controller.panel?.alphaValue, 1)
        assertNoEmptyCard("second call on screen")

        controller.hide()
        assertNoEmptyCard("second call fading out")
        system.finishFades()
        assertHidden(controller, "after the second call ended")
        XCTAssertEqual(repairs, [])
    }

    /// The exact sequence, with the second end arriving while the screen is locked and asleep.
    func testRahulsSequenceWithTheEndOnALockedScreen() {
        let system = FakeSystem()
        system.fadeMode = .immediate
        let controller = makeController(system)
        controller.show(call("Rtr. Kamakshi Aggarwal"))
        controller.hide()
        assertHidden(controller, "first call ended")
        controller.show(call("Ghazal"))
        assertShowing(controller, "Ghazal")
        system.locked = true
        let fades = system.fadeCount
        controller.hide()
        XCTAssertEqual(system.fadeCount, fades, "no fade on a locked or sleeping screen")
        assertHidden(controller, "second call ended while locked")
        system.locked = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        spin(0.05)
        assertHidden(controller, "after the screen woke and unlocked")
    }

    func testEndDuringAHideOrdersOutOnce() {
        let system = FakeSystem()
        let controller = makeController(system)
        controller.show(call("A"))
        system.finishFades()
        controller.hide()
        controller.hide()
        assertNoEmptyCard("two ends in a row")
        system.finishFades(newestFirst: true)
        assertHidden(controller, "two ends, fades finishing out of order")
    }

    func testFadeThatNeverFinishesStillOrdersOut() {
        let system = FakeSystem()
        system.fadeMode = .never
        let controller = makeController(system, deadline: 0.05)
        controller.show(call("A"))
        spin(0.15)
        assertShowing(controller, "A")
        XCTAssertEqual(controller.panel?.alphaValue, 1, "a card whose fade-in never finished is still fully shown")
        controller.hide()
        assertNoEmptyCard("hide in progress")
        spin(0.15)
        assertHidden(controller, "the fade-out never finished")
    }

    func testFadeThatFinishesLateDoesNotHideTheNextCall() {
        let system = FakeSystem()
        let controller = makeController(system, deadline: 0.05)
        controller.show(call("A"))
        system.finishFades()
        controller.hide()
        let late = system.takeOldestFade()
        spin(0.15)
        assertHidden(controller, "the deadline ordered the card out")
        controller.show(call("B"))
        late()
        assertShowing(controller, "B")
        spin(0.15)
        assertShowing(controller, "B")
        XCTAssertEqual(controller.panel?.alphaValue, 1)
    }

    func testRapidShowEndShow() {
        let system = FakeSystem()
        let controller = makeController(system, deadline: 0.05)
        for round in 0..<40 {
            controller.show(call("Caller \(round)", id: round.isMultiple(of: 3) ? "same" : "id\(round)"))
            if round.isMultiple(of: 2) { system.finishFades(newestFirst: round.isMultiple(of: 4)) }
            assertNoEmptyCard("round \(round) shown")
            controller.hide()
            if round.isMultiple(of: 5) { system.finishFades() }
            assertNoEmptyCard("round \(round) ended")
        }
        controller.show(call("Last"))
        system.finishFades()
        spin(0.15)
        assertShowing(controller, "Last")
        controller.hide()
        spin(0.15)
        system.finishFades()
        assertHidden(controller, "after rapid show and end")
    }

    func testDisplayChangeMidHide() {
        let system = FakeSystem()
        let controller = makeController(system, deadline: 0.05)
        controller.show(call("A"))
        system.finishFades()
        controller.hide()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        assertNoEmptyCard("display changed mid-hide")
        spin(0.15)
        assertHidden(controller, "display changed mid-hide")
        system.finishFades()
        assertHidden(controller, "the interrupted fade finished afterwards")
    }

    func testWatchdogOrdersOutACardLeftOnScreenWithoutACall() {
        let system = FakeSystem()
        system.fadeMode = .immediate
        let controller = makeController(system, deadline: 0.05, watchdog: 0.05)
        controller.show(call("A"))
        controller.hide()
        assertHidden(controller, "ended")
        // Something put the window back (AppKit after a wake, a Space change).
        controller.panel?.alphaValue = 1
        controller.panel?.orderFrontRegardless()
        spin(0.3)
        assertHidden(controller, "the watchdog ordered it out")
        XCTAssertEqual(repairs, ["visible_without_call"])
    }

    func testWindowTheWindowServerKeepsIsReplaced() {
        let system = FakeSystem()
        system.fadeMode = .immediate
        let controller = makeController(system)
        controller.show(call("A"))
        controller.hide()
        weak var ghost = controller.panel
        system.windowServerShows = true
        controller.verify()
        XCTAssertEqual(repairs, ["window_server_ghost"])
        XCTAssertNotNil(controller.panel)
        controller.verify()
        XCTAssertEqual(repairs, ["window_server_ghost", "window_replaced"])
        XCTAssertNil(controller.panel, "the stuck window is closed and dropped")
        XCTAssertFalse(ghost?.isVisible ?? false)
        system.windowServerShows = false

        controller.show(call("B"))
        XCTAssertNotNil(controller.panel)
        XCTAssertFalse(controller.panel === ghost, "the next call gets a new window")
        assertShowing(controller, "B")
        controller.hide()
        assertHidden(controller, "the new window hides normally")
    }

    func testHiddenCardStopsBeingChecked() {
        let system = FakeSystem()
        system.fadeMode = .immediate
        let controller = makeController(system)
        controller.show(call("A"))
        controller.hide()
        for _ in 0..<3 { controller.verify() }
        XCTAssertEqual(repairs, [])
        assertHidden(controller, "clean checks")
    }

    func testHideBeforeAnyCallIsHarmless() {
        let system = FakeSystem()
        let controller = makeController(system)
        controller.hide()
        controller.verify()
        XCTAssertNil(controller.panel)
        assertNoEmptyCard("hide with no card")
    }

    /// With no call there is nothing to draw: not even the glass and its border.
    func testCardWithoutACallDrawsNothing() throws {
        let content = CallCardContent()
        let empty = try alphaRange(CallOverlayView(content: content, hide: {}, perform: { _ in }))
        XCTAssertEqual(empty.max, 0, "an empty card draws pixels")
        content.call = call("Ghazal")
        let full = try alphaRange(CallOverlayView(content: content, hide: {}, perform: { _ in }))
        XCTAssertGreaterThan(full.max, 0, "a card with a call draws nothing")
    }

    private func alphaRange(_ view: CallOverlayView) throws -> (min: UInt8, max: UInt8) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 154)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var lowest: UInt8 = 255
        var highest: UInt8 = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                let alpha = UInt8(((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded())
                lowest = min(lowest, alpha)
                highest = max(highest, alpha)
            }
        }
        return (lowest, highest)
    }
}
