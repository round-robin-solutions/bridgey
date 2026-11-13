import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Owned windows and injected providers only: no general clipboard, live player or application state.
@MainActor
final class MenuBarPresentationTests: XCTestCase {
    private var controller: MenuBarStatusController!
    private var refreshes: [@MainActor @Sendable () -> Void] = []
    private var fades: [(alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction?)] = []
    private var fadeCompletions: [@Sendable () -> Void] = []
    private var savedAnimate = BridgeyWindows.animateAlpha
    private var savedUnavailable = BridgeyWindows.screenUnavailable

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedAnimate = BridgeyWindows.animateAlpha
        savedUnavailable = BridgeyWindows.screenUnavailable
        refreshes = []
        fades = []
        fadeCompletions = []
        BridgeyWindows.screenUnavailable = { false }
        BridgeyWindows.animateAlpha = { [unowned self] window, alpha, duration, timing, completion in
            fades.append((alpha, duration, timing))
            // Match the animator's model value without running a real timed animation.
            window.alphaValue = alpha
            fadeCompletions.append(completion)
        }
        controller = MenuBarStatusController(content: NSHostingController(rootView: AnyView(Text("Fixture").frame(width: 240, height: 120))))
        controller.currentEvent = { nil }
        controller.reduceMotion = { true }
        // Never the test runner's defaults: a leaked value there would change every run.
        controller.panelMotion = { .move }
        controller.scheduleOpenRefresh = { [unowned self] refresh in refreshes.append(refresh) }
    }

    override func tearDown() {
        controller.close(animated: false)
        NSStatusBar.system.removeStatusItem(controller.statusItem)
        controller = nil
        refreshes = []
        fadeCompletions = []
        BridgeyWindows.animateAlpha = savedAnimate
        BridgeyWindows.screenUnavailable = savedUnavailable
        super.tearDown()
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testPreparingContentDoesNotShowOrRefreshThePanel() {
        var reads = 0
        controller.presentation.readClipboard = { _ in
            reads += 1
            return PasteboardPreview(changeCount: 1, line: "fixture", hidden: false)
        }
        controller.onDidOpen = { [unowned self] in controller.presentation.refreshClipboard() }
        controller.prepareContent()
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertFalse(controller.presentation.isPresented)
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertTrue(fades.isEmpty)
        XCTAssertEqual(reads, 0)
        XCTAssertGreaterThan(controller.panel.windowNumber, 0, "the window is created before the first open")
        XCTAssertEqual(controller.panel.alphaValue, 0)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
    }

    func testTheFirstOpenAfterPreparingStillFadesAndMovesIn() {
        controller.reduceMotion = { false }
        controller.prepareContent()
        controller.open(byDrag: false)
        XCTAssertTrue(controller.isOpen)
        XCTAssertFalse(controller.panel.ignoresMouseEvents)
        XCTAssertEqual(fades.map(\.alpha), [1])
        XCTAssertNotNil(controller.contentLayer?.animation(forKey: MenuBarPanelMover.key))
    }

    func testProviderRefreshWaitsForTheEntranceToComplete() async {
        controller.reduceMotion = { false }
        var calls = 0
        controller.onDidOpen = { calls += 1 }
        controller.open(byDrag: false)
        XCTAssertTrue(refreshes.isEmpty, "provider work must not compete with the entrance")
        fadeCompletions[0]()
        await drainMainQueue()
        XCTAssertEqual(refreshes.count, 1)
        refreshes.removeFirst()()
        XCTAssertEqual(calls, 1)
    }

    func testClosingDuringEntranceCancelsTheRefreshCompletion() async {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        let entrance = fadeCompletions[0]
        controller.close(animated: false)
        entrance()
        await drainMainQueue()
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertFalse(controller.isOpen)
    }

    func testEntranceCompletionQueuesOnlyOneRefresh() async {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        let entrance = fadeCompletions[0]
        entrance()
        entrance()
        await drainMainQueue()
        XCTAssertEqual(refreshes.count, 1)
    }

    func testEntranceDeadlineStillRefreshesWhenAnimatorNeverCompletes() {
        let deadline = BridgeyWindows.fadeDeadline
        BridgeyWindows.fadeDeadline = 0.01
        defer { BridgeyWindows.fadeDeadline = deadline }
        let refreshed = expectation(description: "the entrance fallback schedules a refresh")
        controller.scheduleOpenRefresh = { [unowned self] work in
            refreshes.append(work)
            refreshed.fulfill()
        }
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        wait(for: [refreshed], timeout: 2)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        XCTAssertEqual(refreshes.count, 1)
    }

    func testRefreshIsDeferredUntilAfterTheExistingPanelIsOrderedIn() {
        var calls = 0
        controller.onDidOpen = { [unowned self] in
            calls += 1
            XCTAssertTrue(controller.isOpen)
            XCTAssertTrue(controller.panel.isVisible)
            XCTAssertTrue(controller.presentation.isPresented)
        }
        controller.open(byDrag: false)
        XCTAssertTrue(controller.isOpen)
        XCTAssertEqual(calls, 0, "provider refresh must not be part of the synchronous opening path")
        XCTAssertEqual(refreshes.count, 1)
        controller.open(byDrag: false)
        XCTAssertEqual(refreshes.count, 1, "an already-open panel must not enqueue another refresh")
        refreshes.removeFirst()()
        XCTAssertEqual(calls, 1)
    }

    func testClosingBeforeTheQueuedRefreshRunsCancelsItsProviderReads() {
        var reads = 0
        controller.presentation.readClipboard = { _ in
            reads += 1
            return PasteboardPreview(changeCount: 1, line: "fixture", hidden: false)
        }
        controller.onDidOpen = { [unowned self] in controller.presentation.refreshClipboard() }
        controller.open(byDrag: false)
        controller.close(animated: false)
        refreshes.removeFirst()()
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(controller.presentation.isPresented)
    }

    func testOnlyTheNewestOpeningCanRunItsQueuedRefresh() {
        var calls = 0
        controller.onDidOpen = { calls += 1 }
        controller.open(byDrag: false)
        controller.close(animated: false)
        controller.open(byDrag: false)
        XCTAssertEqual(refreshes.count, 2)
        refreshes.removeFirst()()
        XCTAssertEqual(calls, 0)
        refreshes.removeFirst()()
        XCTAssertEqual(calls, 1)
    }

    func testClosingBecomesLogicallyClosedAndInertBeforeItsFadeFinishes() {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        let frame = controller.panel.frame
        controller.close()
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.presentation.isPresented)
        XCTAssertTrue(controller.panel.isVisible, "the outgoing window is retained only for its fade")
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
        XCTAssertTrue(controller.panel.isAccessibilityHidden())
        XCTAssertEqual(controller.panel.frame, frame, "opacity must not animate the panel's geometry")
        XCTAssertEqual(fades.map(\.alpha), [1, 0])
        XCTAssertEqual(fades[0].duration, MenuBarStatusController.openingDuration)
        XCTAssertEqual(fades[1].duration, MenuBarStatusController.closingDuration)
    }

    private var motion: CABasicAnimation? {
        controller.contentLayer?.animation(forKey: MenuBarPanelMover.key) as? CABasicAnimation
    }

    private func transform(_ value: Any?) -> CATransform3D? { (value as? NSValue)?.caTransform3DValue }

    func testThePanelMovesOpenByDefault() throws {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        let entrance = try XCTUnwrap(motion)
        let hidden = try XCTUnwrap(transform(entrance.fromValue))
        XCTAssertFalse(CATransform3DIsIdentity(hidden), "the entrance starts small and raised")
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(transform(entrance.toValue))))
        XCTAssertEqual(entrance.duration, MenuBarStatusController.openingDuration)
        XCTAssertEqual(entrance.timingFunction, MenuBarPanelMover.entrance)
        XCTAssertEqual(fades.map(\.alpha), [1])
        XCTAssertEqual(fades[0].timing, MenuBarPanelMover.entrance, "fade and movement share one curve")
        controller.close()
        let exit = try XCTUnwrap(motion)
        XCTAssertTrue(CATransform3DEqualToTransform(try XCTUnwrap(transform(exit.toValue)), hidden), "it shrinks back the way it came")
        XCTAssertEqual(exit.duration, MenuBarStatusController.closingDuration)
        XCTAssertEqual(exit.timingFunction, MenuBarPanelMover.exit)
        XCTAssertEqual(fades.map(\.timing), [MenuBarPanelMover.entrance, MenuBarPanelMover.exit])
    }

    func testMovementIsVisualOnly() throws {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        let frame = controller.panel.frame
        let layer = try XCTUnwrap(controller.contentLayer)
        XCTAssertTrue(CATransform3DIsIdentity(layer.transform), "only the presentation moves; layout and hit testing do not")
        controller.close()
        XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
        XCTAssertEqual(controller.panel.frame, frame)
    }

    func testTheHiddenStateGrowsFromTheTopEdgeUnderTheIcon() {
        for (flipped, anchor) in [(false, CGPoint.zero), (true, CGPoint(x: 0.5, y: 0.5))] {
            let parent = CALayer()
            parent.isGeometryFlipped = flipped
            let layer = CALayer()
            layer.anchorPoint = anchor
            layer.bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
            parent.addSublayer(layer)
            let t = MenuBarPanelMover.hiddenTransform(for: layer, pivotX: 210)
            func apply(_ p: CGPoint) -> CGPoint {
                let a = CGPoint(x: anchor.x * 300, y: anchor.y * 200)
                let q = CGPoint(x: p.x - a.x, y: p.y - a.y)
                return CGPoint(x: a.x + q.x * t.m11 + q.y * t.m21 + t.m41, y: a.y + q.x * t.m12 + q.y * t.m22 + t.m42)
            }
            let top: CGFloat = flipped ? 0 : 200, bottom: CGFloat = flipped ? 200 : 0
            let up: CGFloat = flipped ? -1 : 1
            let pivot = apply(CGPoint(x: 210, y: top))
            XCTAssertEqual(pivot.x, 210, accuracy: 0.001, "the point under the icon does not slide sideways")
            XCTAssertEqual(pivot.y, top + up * MenuBarPanelMover.hiddenRise, accuracy: 0.001, "it starts a few points toward the menu bar")
            let corner = apply(CGPoint(x: 0, y: bottom))
            XCTAssertEqual(corner.x, 210 * (1 - MenuBarPanelMover.hiddenScale), accuracy: 0.001)
            XCTAssertEqual((corner.y - pivot.y) * up, -200 * MenuBarPanelMover.hiddenScale, accuracy: 0.001)
        }
    }

    func testFadeOnlyKeepsTheFadeWithoutMovement() {
        controller.reduceMotion = { false }
        controller.panelMotion = { .fade }
        controller.open(byDrag: false)
        XCTAssertNil(motion)
        controller.close()
        XCTAssertNil(motion)
        XCTAssertEqual(fades.map(\.alpha), [1, 0])
    }

    func testReduceMotionAndOffShowThePanelAtOnce() {
        for (reduce, mode) in [(true, MenuBarPanelMotion.move), (false, .off)] {
            fades = []
            controller.reduceMotion = { reduce }
            controller.panelMotion = { mode }
            controller.open(byDrag: false)
            XCTAssertNil(motion)
            XCTAssertEqual(controller.panel.alphaValue, 1)
            controller.close()
            XCTAssertNil(motion)
            XCTAssertFalse(controller.panel.isVisible)
            XCTAssertTrue(fades.isEmpty)
        }
    }

    func testAReopenDuringTheExitMovesBackFromWhereItIs() throws {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        let hidden = try XCTUnwrap(transform(motion?.fromValue))
        controller.close()
        controller.open(byDrag: false)
        let reopen = try XCTUnwrap(motion)
        XCTAssertFalse(CATransform3DEqualToTransform(try XCTUnwrap(transform(reopen.fromValue)), hidden),
                       "a panel still on screen continues from its drawn state, not from fully hidden")
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(transform(reopen.toValue))))
    }

    func testAClosedPanelReopensFromHiddenAndADragDismissalLeavesNoMotion() throws {
        controller.reduceMotion = { false }
        controller.open(byDrag: true)
        XCTAssertNotNil(motion)
        controller.close()
        XCTAssertNil(motion, "a drag dismissal orders out at once and leaves the content at rest")
        controller.open(byDrag: false)
        XCTAssertFalse(CATransform3DIsIdentity(try XCTUnwrap(transform(motion?.fromValue))))
    }

    func testAStaleFadeCompletionCannotHideARapidReopen() async {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        controller.close()
        let staleEntrance = fadeCompletions[0]
        let staleExit = fadeCompletions[1]
        controller.open(byDrag: false)
        staleExit()
        staleEntrance()
        await drainMainQueue()
        XCTAssertTrue(controller.isOpen)
        XCTAssertTrue(controller.presentation.isPresented)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        XCTAssertFalse(controller.panel.ignoresMouseEvents)
        XCTAssertFalse(controller.panel.isAccessibilityHidden())
        XCTAssertEqual(fades.map(\.alpha), [1, 0, 1])
    }

    func testTheCurrentExitCompletionOrdersTheWindowOut() async {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        controller.close()
        fadeCompletions.last?()
        await drainMainQueue()
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.panel.isVisible)
    }

    func testReducedMotionShowsAndClosesImmediatelyWithoutCallingTheAnimator() {
        controller.open(byDrag: false)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        controller.close()
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertTrue(fades.isEmpty)
    }

    func testAnUnavailableScreenSkipsTheEntranceAndExitAnimations() {
        BridgeyWindows.screenUnavailable = { true }
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        controller.close()
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertTrue(fades.isEmpty)
    }

    func testDragDismissalDoesNotWaitForAnExitFade() {
        controller.reduceMotion = { false }
        controller.open(byDrag: true)
        let entranceCount = fades.count
        controller.close()
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(fades.count, entranceCount)
    }

    func testEscapeUsesTheControllerCloseLifecycle() {
        controller.open(byDrag: false)
        controller.panel.cancelOperation(nil)
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.presentation.isPresented)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
        XCTAssertTrue(controller.panel.isAccessibilityHidden())
        XCTAssertEqual(refreshes.count, 1)
        refreshes.removeFirst()()
        XCTAssertFalse(controller.isOpen)
    }

    func testHiddenClipboardRefreshDoesNotReadAndPreparingAnOpeningClearsOldPreview() {
        let presentation = MenuBarPanelPresentation()
        var reads = 0
        presentation.readClipboard = { _ in
            reads += 1
            return PasteboardPreview(changeCount: 7, line: "fixture preview", hidden: true)
        }
        presentation.refreshClipboard()
        XCTAssertEqual(reads, 0)
        presentation.setPresented(true)
        presentation.refreshClipboard()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(presentation.clipboard.line, "fixture preview")
        presentation.setPresented(false)
        presentation.refreshClipboard()
        XCTAssertEqual(reads, 1)
        presentation.prepareToOpen()
        XCTAssertNil(presentation.clipboard.line)
        XCTAssertFalse(presentation.clipboard.hidden)
        XCTAssertEqual(presentation.clipboard.changeCount, -1)
        XCTAssertEqual(reads, 1, "preparing the panel must clear cached data without contacting its provider")
    }

    func testOldClipboardPreviewIsClearedBeforeTheNextPreShowLayout() {
        controller.presentation.readClipboard = { _ in PasteboardPreview(changeCount: 9, line: "fixture preview", hidden: false) }
        controller.onDidOpen = { [unowned self] in controller.presentation.refreshClipboard() }
        controller.open(byDrag: false)
        refreshes.removeFirst()()
        XCTAssertNotNil(controller.presentation.clipboard.line)
        controller.close(animated: false)
        var prepared = false
        controller.onWillOpen = { [unowned self] in
            prepared = true
            XCTAssertNil(controller.presentation.clipboard.line)
            XCTAssertFalse(controller.presentation.isPresented)
        }
        controller.open(byDrag: false)
        XCTAssertTrue(prepared)
        XCTAssertNil(controller.presentation.clipboard.line)
        refreshes.removeFirst()()
        XCTAssertEqual(controller.presentation.clipboard.line, "fixture preview")
    }
}
