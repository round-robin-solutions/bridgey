import AppKit

/*
 * How Bridgey takes its windows, panels and popovers off the screen.
 *
 * Bridgey is a menu-bar app that is almost never the active app, and most of its windows are
 * non-activating panels. Two things AppKit does for an ordinary app do not happen then:
 * - A transient popover (SwiftUI's .popover) closes when the user clicks outside it only if the
 *   app sees that click. Clicks in other apps go to those apps, so the Tray's send-options popover
 *   stayed open over the Tray and covered its close button.
 * - A window ordered out with an animation leaves the screen only when the animation finishes.
 *   A call card hidden while the Mac was locked with its display off stayed on screen.
 * So every hide goes through `BridgeyWindows` (popovers and sheets first, no ordering animation,
 * fades with a deadline), and `WindowWatchdog` closes popovers on outside clicks and orders out
 * windows that stayed on screen after they were closed.
 */

@MainActor
enum BridgeyWindows {
    /// This app's windows the window server draws now, whatever AppKit believes. One query per call.
    static var onScreenWindowNumbers: () -> Set<Int> = {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(info.compactMap { entry in
            (entry[kCGWindowOwnerPID as String] as? Int) == pid ? entry[kCGWindowNumber as String] as? Int : nil
        })
    }

    static func windowServerShows(_ windowNumber: Int) -> Bool {
        windowNumber > 0 && onScreenWindowNumbers().contains(windowNumber)
    }

    /// The screen is locked or asleep: fades would never be seen and may never finish.
    static var screenUnavailable: () -> Bool = {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Runs one fade; `completion` may run late or never (tests replace it).
    static var animateAlpha: (_ window: NSWindow, _ alpha: CGFloat, _ duration: TimeInterval, _ completion: @escaping @Sendable () -> Void) -> Void = {
        window, alpha, duration, completion in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    /// A fade that has not finished by then is finished by hand.
    static var fadeDeadline: TimeInterval = 0.6

    private static var fadeGenerations: [ObjectIdentifier: Int] = [:]
    /// The step that ends each running fade, run once by the fade's end or its deadline.
    private static var pendingFades: [ObjectIdentifier: (generation: Int, finish: () -> Void)] = [:]

    /// Closes `window`: its popovers, sheets and child windows go first, then the window, without
    /// an ordering animation. The watchdog checks that it really left the screen.
    static func close(_ window: NSWindow?) {
        guard let window else { return }
        cancelFade(window)
        detachTransients(of: window)
        withoutOrderingAnimation(window) { $0.close() }
        WindowWatchdog.shared.windowHidden(window)
    }

    /// As `close`, for windows that are kept and shown again.
    static func orderOut(_ window: NSWindow?) {
        guard let window else { return }
        cancelFade(window)
        detachTransients(of: window)
        withoutOrderingAnimation(window) { $0.orderOut(nil) }
        WindowWatchdog.shared.windowHidden(window)
    }

    /// Fades `window` out, then orders it out. The window always ends ordered out: on a locked or
    /// sleeping screen at once, otherwise when the fade ends or at the deadline, whichever is first.
    /// A show (`cancelFade`) or another fade in between wins.
    static func fadeOut(_ window: NSWindow?, duration: TimeInterval = 0.15) {
        guard let window else { return }
        guard window.isVisible, duration > 0, !screenUnavailable() else {
            orderOut(window)
            return
        }
        detachTransients(of: window)
        fade(window, to: 0, duration: duration) { [weak window] in orderOut(window) }
    }

    /// Fades `window` in from where it is; it is fully shown at the deadline even if the fade stalls.
    static func fadeIn(_ window: NSWindow, duration: TimeInterval = 0.15) {
        guard duration > 0, !screenUnavailable() else {
            cancelFade(window)
            window.alphaValue = 1
            return
        }
        fade(window, to: 1, duration: duration) { [weak window] in window?.alphaValue = 1 }
    }

    /// A newer show or hide: an older fade's end does nothing.
    static func cancelFade(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        fadeGenerations[key, default: 0] += 1
        pendingFades.removeValue(forKey: key)
    }

    private static func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval, then finish: @escaping () -> Void) {
        let key = ObjectIdentifier(window)
        let generation = fadeGenerations[key, default: 0] + 1
        fadeGenerations[key] = generation
        pendingFades[key] = (generation, finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDeadline) {
            MainActor.assumeIsolated { finishFade(key, generation) }
        }
        animateAlpha(window, alpha, duration) {
            DispatchQueue.main.async { MainActor.assumeIsolated { finishFade(key, generation) } }
        }
    }

    private static func finishFade(_ key: ObjectIdentifier, _ generation: Int) {
        guard let pending = pendingFades[key], pending.generation == generation else { return }
        pendingFades.removeValue(forKey: key)
        pending.finish()
    }

    /// Popovers and sheets go before their window: a popover left on screen covers the window's
    /// controls, and a sheet left attached keeps the window from closing.
    static func detachTransients(of window: NSWindow) {
        WindowWatchdog.shared.closePopovers(in: window)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
            withoutOrderingAnimation(child) { $0.orderOut(nil) }
        }
    }

    static func withoutOrderingAnimation(_ window: NSWindow, _ body: (NSWindow) -> Void) {
        let behavior = window.animationBehavior
        window.animationBehavior = .none
        body(window)
        window.animationBehavior = behavior
    }
}

/// Watches Bridgey's windows and popovers: closes popovers on clicks in other apps, takes a
/// window's popovers with it when it closes, and orders out windows that stayed on screen after
/// they were closed or ordered out.
@MainActor
final class WindowWatchdog: NSObject {
    static let shared = WindowWatchdog()

    /// Logged for each repair: what kind of window and why.
    var onRepair: (_ window: String, _ reason: String) -> Void = { window, reason in
        BridgeyLog.line(BridgeyLog.windows, "window repaired kind=\(window) reason=\(reason)")
    }
    /// How long a closed window may stay drawn (an ordering animation) before it counts as stuck.
    var ghostGrace: TimeInterval = 1.5
    var sweepInterval: TimeInterval = 2
    var now: () -> Date = Date.init

    private var started = false
    /// Windows the watchdog made transparent; they are made opaque again when shown.
    private var madeTransparent: [ObjectIdentifier: NSWindow] = [:]
    private var popovers: [ObjectIdentifier: NSPopover] = [:]
    private var outsideClickMonitor: Any?
    private var timer: Timer?
    /// Hidden windows the window server still drew at the last sweep, with when that was first seen.
    private var ghosts: [ObjectIdentifier: (window: NSWindow, since: Date, orderedOut: Bool)] = [:]
    private var quietSweeps = 0

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(popoverWillShow(_:)), name: NSPopover.willShowNotification, object: nil)
        center.addObserver(self, selector: #selector(popoverDidClose(_:)), name: NSPopover.didCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(occlusionChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(systemChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(systemChanged), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(self, selector: #selector(closeAllPopovers), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(applicationActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemChanged), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil
        )
        startSweeping()
    }

    @objc private func popoverWillShow(_ note: Notification) {
        guard let popover = note.object as? NSPopover else { return }
        popovers[ObjectIdentifier(popover)] = popover
        updateOutsideClickMonitor()
        startSweeping()
    }

    @objc private func popoverDidClose(_ note: Notification) {
        guard let popover = note.object as? NSPopover else { return }
        popovers.removeValue(forKey: ObjectIdentifier(popover))
        updateOutsideClickMonitor()
    }

    /// A window closed by its close button or Command-W takes its popovers and sheets with it.
    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow, !window.className.contains("Popover") else { return }
        closePopovers(in: window)
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
            BridgeyWindows.withoutOrderingAnimation(child) { $0.orderOut(nil) }
        }
        windowHidden(window)
    }

    @objc private func occlusionChanged(_ note: Notification) {
        if let window = note.object as? NSWindow, window.isVisible,
           madeTransparent.removeValue(forKey: ObjectIdentifier(window)) != nil {
            window.alphaValue = 1
        }
        startSweeping()
    }

    @objc private func systemChanged() {
        quietSweeps = 0
        sweep()
        startSweeping()
    }

    /// The user switched to another app (Command-Tab, the Dock): as an outside click.
    @objc private func applicationActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        outsideClick()
    }

    /// The user clicked in another app. Bridgey is not active, so AppKit never sees that click.
    func outsideClick() {
        guard !popovers.isEmpty else { return }
        closeAllPopovers()
    }

    /// Without the closing animation: a fade that never finishes is how windows got stuck.
    @objc func closeAllPopovers() {
        for popover in popovers.values {
            popover.animates = false
            popover.close()
        }
        popovers.removeAll()
        updateOutsideClickMonitor()
    }

    /// Closes the popovers shown from `window` at once (the window is going).
    func closePopovers(in window: NSWindow) {
        for (key, popover) in popovers {
            let popoverWindow = Self.window(of: popover)
            guard popoverWindow?.parent === window || popoverWindow === window else { continue }
            popover.animates = false
            popover.close()
            popovers.removeValue(forKey: key)
        }
        updateOutsideClickMonitor()
    }

    /// `window` was just closed or ordered out: make sure it left the screen.
    func windowHidden(_ window: NSWindow) {
        guard started else { return }
        startSweeping()
    }

    /// One pass over Bridgey's windows. Runs on a timer while anything is on screen, and after
    /// screen wake, unlock, display and Space changes.
    func sweep() {
        let time = now()
        var seen = Set<ObjectIdentifier>()
        for (key, popover) in popovers where popover.isShown {
            // A popover whose window went away (closed behind AppKit's back) is an orphan.
            let parent = Self.window(of: popover)?.parent
            if parent == nil || parent?.isVisible == false {
                onRepair("popover", "orphan")
                popover.animates = false
                popover.close()
                popovers.removeValue(forKey: key)
            }
        }
        updateOutsideClickMonitor()
        let onScreen = BridgeyWindows.onScreenWindowNumbers()
        for window in NSApp.windows where !Self.isStatusItemWindow(window) && window.windowNumber > 0 {
            if window.isVisible {
                if window.contentView == nil {
                    onRepair(Self.kind(window), "no_content")
                    BridgeyWindows.withoutOrderingAnimation(window) { $0.orderOut(nil) }
                }
                continue
            }
            // A minimised window lives in the Dock; ordering it out would lose it.
            guard !window.isMiniaturized, onScreen.contains(window.windowNumber) else { continue }
            let key = ObjectIdentifier(window)
            seen.insert(key)
            guard let ghost = ghosts[key] else {
                ghosts[key] = (window, time, false)
                continue
            }
            guard time.timeIntervalSince(ghost.since) >= ghostGrace else { continue }
            if !ghost.orderedOut {
                onRepair(Self.kind(window), "still_on_screen")
                window.alphaValue = 0
                madeTransparent[key] = window
                BridgeyWindows.withoutOrderingAnimation(window) { $0.orderOut(nil) }
                ghosts[key] = (window, time, true)
            } else {
                // Ordered out twice and still drawn: show it to the window server once more without
                // a frame on screen, then order it out, which resyncs AppKit and the server.
                onRepair(Self.kind(window), "resynced")
                BridgeyWindows.withoutOrderingAnimation(window) {
                    $0.alphaValue = 0
                    $0.orderBack(nil)
                    $0.orderOut(nil)
                }
                madeTransparent[key] = window
                ghosts.removeValue(forKey: key)
            }
        }
        ghosts = ghosts.filter { seen.contains($0.key) }
        let anyVisible = NSApp.windows.contains { $0.isVisible && !Self.isStatusItemWindow($0) }
        if anyVisible || !ghosts.isEmpty || !popovers.isEmpty {
            quietSweeps = 0
        } else {
            quietSweeps += 1
            if quietSweeps >= 3 { stopSweeping() }
        }
    }

    private func startSweeping() {
        guard started else { return }
        quietSweeps = 0
        guard timer == nil else { return }
        let timer = Timer(timeInterval: sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        timer.tolerance = sweepInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopSweeping() {
        timer?.invalidate()
        timer = nil
    }

    /// Mouse events need no permission to watch; the monitor runs only while a popover is open.
    private func updateOutsideClickMonitor() {
        let needed = !popovers.isEmpty
        if needed, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                Task { @MainActor [weak self] in self?.outsideClick() }
            }
        } else if !needed, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private static func window(of popover: NSPopover) -> NSWindow? {
        guard let controller = popover.contentViewController, controller.isViewLoaded else { return nil }
        return controller.view.window
    }

    private static func isStatusItemWindow(_ window: NSWindow) -> Bool {
        window.className.contains("StatusBarWindow")
    }

    private static func kind(_ window: NSWindow) -> String {
        if window.identifier == callOverlayWindowIdentifier { return "call_card" }
        if window.className.contains("Popover") { return "popover" }
        return window is NSPanel ? "panel" : "window"
    }
}
