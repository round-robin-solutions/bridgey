import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Owned windows and injected providers only: no general clipboard, live player or application state.
@MainActor
final class MenuBarPresentationTests: XCTestCase {
    private var controller: MenuBarStatusController!
    private var refreshes: [@MainActor @Sendable () -> Void] = []
    private var fades: [(alpha: CGFloat, duration: TimeInterval)] = []
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
        BridgeyWindows.animateAlpha = { [unowned self] window, alpha, duration, completion in
            fades.append((alpha, duration))
            // Match the animator's model value without running a real timed animation.
            window.alphaValue = alpha
            fadeCompletions.append(completion)
        }
        controller = MenuBarStatusController(content: NSHostingController(rootView: AnyView(Text("Fixture").frame(width: 240, height: 120))))
        controller.currentEvent = { nil }
        controller.reduceMotion = { true }
        // Never the test runner's defaults: a leaked value there would change every run.
        controller.panelMotion = { .spring }
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

    func testThePanelSpringsOpenByDefault() {
        controller.reduceMotion = { false }
        controller.open(byDrag: false)
        XCTAssertEqual(controller.presentation.motion, .spring)
        XCTAssertEqual(fades.map(\.alpha), [1])
        controller.close()
        XCTAssertEqual(controller.presentation.motion, .spring, "the content shrinks back while the window fades")
    }

    func testFadeOnlyKeepsTheFadeWithoutMovement() {
        controller.reduceMotion = { false }
        controller.panelMotion = { .fade }
        controller.open(byDrag: false)
        controller.close()
        XCTAssertEqual(controller.presentation.motion, .fade)
        XCTAssertEqual(fades.map(\.alpha), [1, 0])
    }

    func testReduceMotionAndOffShowThePanelAtOnce() {
        for (reduce, motion) in [(true, MenuBarPanelMotion.spring), (false, .off)] {
            fades = []
            controller.reduceMotion = { reduce }
            controller.panelMotion = { motion }
            controller.open(byDrag: false)
            XCTAssertEqual(controller.presentation.motion, .off)
            XCTAssertEqual(controller.panel.alphaValue, 1)
            controller.close()
            XCTAssertFalse(controller.panel.isVisible)
            XCTAssertTrue(fades.isEmpty)
        }
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
