import AppKit
import XCTest
@testable import BridgeyMac

/// The floating Copy code card: it shows for the chosen time, a newer code replaces it, Copy closes
/// it, the three settings do what they say, and it always leaves the screen (a stalled fade, a locked
/// or sleeping screen, a window the window server keeps drawing). These drive the real controller and
/// its real window, with time run by hand.
@MainActor
final class CodeFloatWindowTests: XCTestCase {
    /// Time and the system as the card sees them.
    @MainActor
    private final class FakeSystem {
        struct Job {
            let id: Int
            let delay: TimeInterval
            let work: @MainActor () -> Void
        }
        var locked = false
        var reduceMotion = false
        private(set) var jobs: [Job] = []
        private var nextID = 0
        private(set) var cancelled: Set<Int> = []

        var environment: CodeFloatEnvironment {
            CodeFloatEnvironment(
                schedule: { [unowned self] delay, work in
                    nextID += 1
                    let id = nextID
                    jobs.append(Job(id: id, delay: delay, work: work))
                    return { [unowned self] in cancelled.insert(id) }
                },
                screenUnavailable: { [unowned self] in locked },
                reduceMotion: { [unowned self] in reduceMotion },
                copiedLinger: 1.2,
                cleanupDelay: 0.8
            )
        }

        /// Jobs that were not cancelled, oldest first.
        var live: [Job] { jobs.filter { !cancelled.contains($0.id) } }

        /// Runs the live job with this delay.
        func fire(delay: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
            guard let job = live.last(where: { $0.delay == delay }) else {
                XCTFail("nothing scheduled after \(delay) s; live: \(live.map(\.delay))", file: file, line: line)
                return
            }
            cancelled.insert(job.id)
            job.work()
        }
    }

    private var system = FakeSystem()
    private var controller: CodeFloatWindowController!
    private var copied: [String] = []
    private var savedAnimate = BridgeyWindows.animateAlpha
    private var savedServer = BridgeyWindows.onScreenWindowNumbers
    private var savedUnavailable = BridgeyWindows.screenUnavailable
    private var savedDeadline = BridgeyWindows.fadeDeadline
    private var repairs: [(window: String, reason: String)] = []
    private var clock = Date()
    private var pendingFades: [() -> Void] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        system = FakeSystem()
        copied = []
        repairs = []
        pendingFades = []
        clock = Date()
        savedAnimate = BridgeyWindows.animateAlpha
        savedServer = BridgeyWindows.onScreenWindowNumbers
        savedUnavailable = BridgeyWindows.screenUnavailable
        savedDeadline = BridgeyWindows.fadeDeadline
        // Fades finish at once unless a test says otherwise.
        BridgeyWindows.animateAlpha = { window, alpha, _, completion in
            window.alphaValue = alpha
            completion()
        }
        BridgeyWindows.screenUnavailable = { false }
        BridgeyWindows.onScreenWindowNumbers = { [] }
        let watchdog = WindowWatchdog.shared
        watchdog.sweepInterval = 1_000
        watchdog.start()
        watchdog.now = { [unowned self] in clock }
        watchdog.onRepair = { [unowned self] window, reason in repairs.append((window, reason)) }
        controller = CodeFloatWindowController(environment: system.environment)
        controller.onCopy = { [unowned self] reference in
            copied.append(reference)
            controller.markCopied(reference)
        }
    }

    override func tearDown() {
        for window in NSApp.windows where window.identifier == codeFloatWindowIdentifier {
            window.orderOut(nil)
            window.close()
        }
        BridgeyWindows.animateAlpha = savedAnimate
        BridgeyWindows.onScreenWindowNumbers = savedServer
        BridgeyWindows.screenUnavailable = savedUnavailable
        BridgeyWindows.fadeDeadline = savedDeadline
        WindowWatchdog.shared.now = Date.init
        WindowWatchdog.shared.onRepair = { window, reason in
            BridgeyLog.line(BridgeyLog.windows, "window repaired kind=\(window) reason=\(reason)")
        }
        controller = nil
        super.tearDown()
    }

    private func card(_ code: String, id: String = UUID().uuidString) -> LiveCodeCard {
        LiveCodeCard(id: id, code: code, sender: "HDFCBK", deviceName: "OnePlus 11", receivedAt: Date())
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var visibleCodeWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier == codeFloatWindowIdentifier && $0.isVisible }
    }

    /// The card is off the screen and holds no code. A fade out leaves the code on the card until the
    /// cleanup step (after the fade's deadline), so that step runs first.
    private func assertGone(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if system.live.contains(where: { $0.delay == 0.8 }) { system.fire(delay: 0.8) }
        XCTAssertFalse(controller.isShowing, message, file: file, line: line)
        XCTAssertEqual(visibleCodeWindows.count, 0, "the card is still on screen: \(message)", file: file, line: line)
        XCTAssertNil(controller.content.card, "the code is still held: \(message)", file: file, line: line)
    }

    // MARK: - The card

    func testShowsForSixtySecondsThenCloses() throws {
        controller.show(card("482913"), seconds: 60)
        XCTAssertTrue(controller.isShowing)
        XCTAssertEqual(visibleCodeWindows.count, 1)
        XCTAssertEqual(controller.content.card?.code, "482913")
        XCTAssertEqual(system.live.map(\.delay), [60], "one timer, 60 s")
        system.fire(delay: 60)
        spin(0.05)
        assertGone("after the 60 s")
    }

    func testPanelIsNonActivatingPrivateAndSafe() throws {
        controller.show(card("482913"), seconds: 60)
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "it must not steal focus")
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded, "clicking Copy must not make it the key window")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(panel.sharingType, .none, "out of screenshots and screen sharing")
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertGreaterThan(panel.level.rawValue, 21, "above notification banners")
        XCTAssertLessThan(panel.level, callOverlayWindowLevel, "below the call card")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        let visible = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first).visibleFrame
        XCTAssertGreaterThan(panel.frame.midX, visible.midX, "right half")
        XCTAssertGreaterThan(panel.frame.midY, visible.midY, "top half")
    }

    func testNewerCodeReplacesTheCardAndRestartsTheTime() {
        controller.show(card("111111", id: "a"), seconds: 60)
        let firstPanel = controller.panel
        let firstOrigin = firstPanel?.frame.origin
        controller.show(card("222222", id: "b"), seconds: 60)
        XCTAssertEqual(controller.content.card?.code, "222222")
        XCTAssertTrue(controller.panel === firstPanel, "one window")
        XCTAssertEqual(controller.panel?.frame.origin, firstOrigin, "it does not move")
        XCTAssertEqual(visibleCodeWindows.count, 1)
        XCTAssertEqual(system.live.map(\.delay), [60], "the first 60 s was cancelled and a new one started")
        XCTAssertEqual(system.jobs.count, 2)
        system.fire(delay: 60)
        spin(0.05)
        assertGone("the second code's time")
    }

    func testNewerCodeAfterCopiedStartsAFreshCard() {
        controller.show(card("111111", id: "a"), seconds: 60)
        controller.markCopied("a")
        XCTAssertTrue(controller.content.copied)
        controller.show(card("222222", id: "b"), seconds: 60)
        XCTAssertFalse(controller.content.copied, "the new code is not copied yet")
        XCTAssertEqual(system.live.map(\.delay), [60], "the closing after Copied was cancelled")
    }

    func testCopyShowsCopiedThenCloses() {
        controller.show(card("482913", id: "a"), seconds: 60)
        controller.onCopy("a")
        XCTAssertEqual(copied, ["a"])
        XCTAssertTrue(controller.content.copied, "Copied shows")
        XCTAssertTrue(controller.isShowing, "for a moment")
        XCTAssertEqual(system.live.map(\.delay), [1.2], "the 60 s is replaced by the short wait")
        system.fire(delay: 1.2)
        spin(0.05)
        assertGone("after Copied")
    }

    func testAnotherCodesCopyLeavesTheCardAlone() {
        controller.show(card("482913", id: "a"), seconds: 60)
        controller.markCopied("some-older-code")
        XCTAssertFalse(controller.content.copied)
        XCTAssertEqual(system.live.map(\.delay), [60])
    }

    func testCopyFromTheBannerAlsoClosesTheCard() {
        controller.show(card("482913", id: "a"), seconds: 60)
        // Pairing.copyCode (banner action, panel card or automatic) reports every copy.
        controller.markCopied("a")
        system.fire(delay: 1.2)
        spin(0.05)
        assertGone("copied elsewhere")
    }

    func testEscapeAndTheCloseButtonClose() throws {
        controller.show(card("482913"), seconds: 60)
        let panel = try XCTUnwrap(controller.panel)
        panel.cancelOperation(nil)
        spin(0.05)
        assertGone("Esc")
        controller.show(card("111111"), seconds: 60)
        XCTAssertEqual(visibleCodeWindows.count, 1, "it shows again after a close")
        controller.dismiss()
        spin(0.05)
        assertGone("the close button")
    }

    func testReduceMotionClosesWithoutAFade() {
        system.reduceMotion = true
        BridgeyWindows.animateAlpha = { _, _, _, _ in XCTFail("no fade with Reduce motion") }
        controller.show(card("482913"), seconds: 60)
        XCTAssertEqual(controller.panel?.alphaValue, 1)
        controller.dismiss()
        assertGone("Reduce motion")
    }

    // MARK: - The setting

    func testSettingOptions() {
        XCTAssertEqual(CodeFloatSetting.allCases.map(\.rawValue), ["60", "30", "off"])
        XCTAssertEqual(CodeFloatSetting.sixty.seconds, 60)
        XCTAssertEqual(CodeFloatSetting.thirty.seconds, 30)
        XCTAssertNil(CodeFloatSetting.off.seconds, "Only the notification: no card")
        XCTAssertEqual(CodeFloatSetting.default, .sixty)
        XCTAssertEqual(CodeFloatSetting.sixty.title, "60 seconds")
        XCTAssertEqual(CodeFloatSetting.thirty.title, "30 seconds")
        XCTAssertEqual(CodeFloatSetting.off.title, "Only the notification")
    }

    func testStoredValueFallsBackToSixty() {
        XCTAssertEqual(CodeFloatSetting.stored(nil), .sixty)
        XCTAssertEqual(CodeFloatSetting.stored("30"), .thirty)
        XCTAssertEqual(CodeFloatSetting.stored("off"), .off)
        XCTAssertEqual(CodeFloatSetting.stored("90"), .sixty, "a value this build does not know")
        XCTAssertEqual(CodeFloatSetting.stored(""), .sixty)
    }

    func testSettingIsKeptOnThisMacAndNotSynced() {
        let key = CodeFloatSetting.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let settings = BridgeySettings()
        XCTAssertEqual(settings.codesFloat, .sixty, "60 seconds is the default")
        settings.setCodesFloat(.thirty)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "30")
        XCTAssertEqual(BridgeySettings().codesFloat, .thirty, "kept")
        settings.setCodesFloat(.off)
        XCTAssertEqual(BridgeySettings().codesFloat, .off)
        let values = settingsSyncStoredValues([key: "off"])
        XCTAssertTrue(values.isEmpty, "settings sync does not carry it")
    }

    func testEachChoiceSetsTheTimeTheCardStays() {
        for setting in CodeFloatSetting.allCases {
            let system = FakeSystem()
            let controller = CodeFloatWindowController(environment: system.environment)
            // What Pairing does with the setting.
            if let seconds = setting.seconds { controller.show(card("482913"), seconds: seconds) }
            switch setting {
            case .sixty: XCTAssertEqual(system.live.map(\.delay), [60])
            case .thirty: XCTAssertEqual(system.live.map(\.delay), [30])
            case .off:
                XCTAssertTrue(system.jobs.isEmpty)
                XCTAssertFalse(controller.isShowing)
                XCTAssertNil(controller.panel, "no window is even made")
            }
            controller.dismiss()
            spin(0.05)
            for window in NSApp.windows where window.identifier == codeFloatWindowIdentifier { BridgeyWindows.orderOut(window) }
        }
    }

    // MARK: - It always closes

    func testNotShownOnALockedScreen() {
        system.locked = true
        controller.show(card("482913"), seconds: 60)
        XCTAssertFalse(controller.isShowing)
        XCTAssertNil(controller.panel)
        XCTAssertTrue(system.jobs.isEmpty)
    }

    func testClosesAtOnceWhenTheDisplaySleeps() {
        controller.show(card("482913"), seconds: 60)
        BridgeyWindows.animateAlpha = { _, _, _, _ in XCTFail("no fade when the screen goes") }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
        spin(0.05)
        assertGone("display sleep")
        XCTAssertTrue(system.live.allSatisfy { $0.delay != 60 }, "the 60 s timer is cancelled")
    }

    func testClosesAtOnceOnSystemSleepAndSessionSwitch() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            controller.show(card("482913"), seconds: 60)
            XCTAssertEqual(visibleCodeWindows.count, 1)
            NSWorkspace.shared.notificationCenter.post(name: name, object: NSWorkspace.shared)
            spin(0.05)
            assertGone(name.rawValue)
        }
    }

    func testClosesAtOnceWhenTheScreenLocks() {
        controller.show(card("482913"), seconds: 60)
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        spin(0.3)
        assertGone("screen lock")
    }

    func testLockWhileFadingStillEnds() {
        // A fade that never finishes (a screen that went dark under it).
        BridgeyWindows.animateAlpha = { _, _, _, _ in }
        BridgeyWindows.fadeDeadline = 0.05
        controller.show(card("482913"), seconds: 60)
        controller.dismiss()
        system.locked = true
        BridgeyWindows.screenUnavailable = { true }
        spin(0.2)
        XCTAssertEqual(visibleCodeWindows.count, 0, "the deadline ordered it out")
        system.fire(delay: 0.8)
        assertGone("cleanup after a fade that never ended")
    }

    func testFadeThatNeverEndsIsCutShort() {
        BridgeyWindows.animateAlpha = { _, _, _, _ in }
        BridgeyWindows.fadeDeadline = 0.05
        controller.show(card("482913"), seconds: 60)
        controller.dismiss()
        XCTAssertNotNil(controller.content.card, "the card stays filled while it fades")
        spin(0.2)
        XCTAssertEqual(visibleCodeWindows.count, 0)
        system.fire(delay: 0.8)
        assertGone("stalled fade")
    }

    func testShowDuringFadeOutWins() {
        BridgeyWindows.animateAlpha = { [unowned self] window, alpha, _, completion in
            pendingFades.append {
                window.alphaValue = alpha
                completion()
            }
        }
        BridgeyWindows.fadeDeadline = 0.1
        controller.show(card("111111", id: "a"), seconds: 60)
        controller.dismiss()
        let staleFadeOut = pendingFades.removeLast()
        controller.show(card("222222", id: "b"), seconds: 60)
        staleFadeOut()
        // The cleanup of the first close is cancelled by the new show.
        XCTAssertFalse(system.live.contains { $0.delay == 0.8 })
        spin(0.3)
        XCTAssertEqual(visibleCodeWindows.count, 1, "an old fade-out hid the new card")
        XCTAssertEqual(controller.content.card?.code, "222222")
        XCTAssertEqual(controller.panel?.alphaValue, 1)
    }

    func testRapidCodesAlwaysEndGone() {
        BridgeyWindows.animateAlpha = { [unowned self] window, alpha, _, completion in
            pendingFades.append {
                window.alphaValue = alpha
                completion()
            }
        }
        BridgeyWindows.fadeDeadline = 0.05
        for round in 0..<30 {
            controller.show(card(String(format: "%06d", round), id: "c\(round)"), seconds: 60)
            if round.isMultiple(of: 3) { controller.markCopied("c\(round)") }
            if round.isMultiple(of: 4) { controller.dismiss() }
            if round.isMultiple(of: 5) { pendingFades.forEach { $0() }; pendingFades = [] }
        }
        XCTAssertLessThanOrEqual(visibleCodeWindows.count, 1, "never two cards")
        controller.dismiss()
        pendingFades.reversed().forEach { $0() }
        pendingFades = []
        spin(0.2)
        system.fire(delay: 0.8)
        assertGone("after rapid codes")
    }

    func testWatchdogRepairsACardTheWindowServerKeepsDrawing() throws {
        controller.show(card("482913"), seconds: 60)
        let panel = try XCTUnwrap(controller.panel)
        let number = panel.windowNumber
        controller.dismiss()
        spin(0.05)
        XCTAssertFalse(panel.isVisible)
        // The window server keeps drawing it after AppKit ordered it out.
        BridgeyWindows.onScreenWindowNumbers = { [number] }
        let watchdog = WindowWatchdog.shared
        watchdog.sweep()
        clock = clock.addingTimeInterval(2)
        watchdog.sweep()
        XCTAssertEqual(repairs.map(\.reason), ["still_on_screen"])
        XCTAssertEqual(repairs.first?.window, "code_card")
        XCTAssertEqual(panel.alphaValue, 0, "a stuck card is made transparent")
    }

    func testClosedCardKeepsNoCode() {
        controller.show(card("482913"), seconds: 60)
        controller.dismiss()
        spin(0.05)
        system.fire(delay: 0.8)
        XCTAssertNil(controller.content.card)
        XCTAssertFalse(controller.content.copied)
    }
}
