import AppKit
import SwiftUI

/// What the call card asks of the system. Tests replace each part to stall or finish animations,
/// lock the screen or keep a window on screen behind AppKit's back.
@MainActor
struct CallOverlayEnvironment {
    /// Fades `window` to `alpha`; `completion` runs when the fade ends, late, or never.
    var fade: @MainActor (_ window: NSWindow, _ alpha: CGFloat, _ duration: TimeInterval, _ completion: @escaping @Sendable () -> Void) -> Void
    /// The screen is locked or asleep: the card appears and goes without a fade.
    var screenUnavailable: @MainActor () -> Bool
    /// The window server still draws the window with this number, whatever AppKit believes.
    var windowServerShows: @MainActor (_ windowNumber: Int) -> Bool
    var fadeDuration: TimeInterval = 0.18
    /// When a fade has not finished by then, the card is ordered out (or shown) anyway.
    var transitionDeadline: TimeInterval = 0.6
    /// How often the card is checked while it is on screen or not yet confirmed gone.
    var watchdogInterval: TimeInterval = 2

    static var live: CallOverlayEnvironment {
        CallOverlayEnvironment(
            fade: { window, alpha, duration, completion in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = duration
                    window.animator().alphaValue = alpha
                }, completionHandler: completion)
            },
            screenUnavailable: {
                if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
                let session = CGSessionCopyCurrentDictionary() as? [String: Any]
                return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
            },
            windowServerShows: { number in
                guard number > 0,
                      let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
                      let window = info.first else { return false }
                return (window[kCGWindowIsOnscreen as String] as? Bool) == true
            }
        )
    }
}

/// The call on the card. It stays set while the card fades out, so the card never shows empty.
@MainActor
final class CallCardContent: ObservableObject {
    @Published var call: RemoteCallStatus?
}

let callOverlayWindowIdentifier = NSUserInterfaceItemIdentifier("in.roundrobin.bridgey.call-card")

/// The floating call card. Hiding always ends with the window ordered out: a fade that is
/// interrupted, finishes late or never finishes (a locked or sleeping screen) is cut short by a
/// deadline, and a watchdog orders out a card that is on screen without a call. A card the window
/// server keeps drawing after it was ordered out is closed and replaced by a new window.
@MainActor
final class CallOverlayWindowController {
    var onHide: () -> Void = {}
    var onAction: (RemoteCallAction) -> Void = { _ in }
    /// The card repaired itself (reason, the call it last showed): for the calls log.
    var onRepair: (String, RemoteCallStatus?) -> Void = { _, _ in }

    let content = CallCardContent()
    private let environment: CallOverlayEnvironment
    private(set) var panel: NSPanel?
    /// A call should be on screen.
    private(set) var isShowing = false
    /// Bumped by every show and hide: a fade that finishes after the next one started does nothing.
    private var transition = 0
    private var transitionInFlight = false
    private var deadline: DispatchWorkItem?
    private var watchdog: Timer?
    private var lastCall: RemoteCallStatus?
    /// Checks in a row that found the hidden card gone; the watchdog stops after a few.
    private var cleanChecks = 0
    /// The window server still drew the hidden card at the last check.
    private var ghostSeen = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(environment: CallOverlayEnvironment? = nil) {
        self.environment = environment ?? .live
        observeSystemChanges()
    }

    /// Shows `call`, or updates the card already on screen. Placed once when it appears; updates
    /// while it is on screen never move it. A show during a fade-out cancels the fade.
    func show(_ call: RemoteCallStatus) {
        content.call = call
        lastCall = call
        let panel = self.panel ?? makePanel()
        let wasOnScreen = panel.isVisible && isShowing
        isShowing = true
        ghostSeen = false
        cleanChecks = 0
        if wasOnScreen && !transitionInFlight {
            panel.alphaValue = 1
            return
        }
        transition += 1
        let current = transition
        if !panel.isVisible { position(panel) }
        if environment.screenUnavailable() {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            finishTransition(current)
        } else {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            beginTransition(current, panel: panel, alpha: 1)
        }
        startWatchdog()
    }

    /// Hides the card. It always ends ordered out, emptied and transparent.
    func hide() {
        isShowing = false
        cleanChecks = 0
        transition += 1
        let current = transition
        guard let panel, panel.isVisible, !environment.screenUnavailable() else {
            finishTransition(current)
            startWatchdog()
            return
        }
        beginTransition(current, panel: panel, alpha: 0)
        startWatchdog()
    }

    /// The watchdog's check, also run when the screen wakes, unlocks or changes.
    func verify() {
        guard !transitionInFlight else { return }
        guard let panel else {
            stopWatchdog()
            return
        }
        if isShowing {
            guard content.call != nil else {
                // Never a card without a call on it.
                repair("empty_card")
                isShowing = false
                orderOut(panel)
                return
            }
            if panel.alphaValue < 1 { panel.alphaValue = 1 }
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        if panel.isVisible {
            repair("visible_without_call")
            orderOut(panel)
            return
        }
        if environment.windowServerShows(panel.windowNumber) {
            if ghostSeen {
                // Ordered out twice and still drawn: this window goes for good.
                repair("window_replaced")
                retire(panel)
            } else {
                repair("window_server_ghost")
                ghostSeen = true
                orderOut(panel)
            }
            return
        }
        ghostSeen = false
        cleanChecks += 1
        if cleanChecks >= 3 { stopWatchdog() }
    }

    private func beginTransition(_ current: Int, panel: NSPanel, alpha: CGFloat) {
        transitionInFlight = true
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishTransition(current) }
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + environment.transitionDeadline, execute: work)
        environment.fade(panel, alpha, environment.fadeDuration) { [weak self] in
            MainActor.assumeIsolated { self?.finishTransition(current) }
        }
    }

    /// Where every show and hide lands, from the fade, the deadline, or at once.
    private func finishTransition(_ current: Int) {
        guard current == transition else { return }
        deadline?.cancel()
        deadline = nil
        transitionInFlight = false
        guard let panel else { return }
        if isShowing {
            panel.alphaValue = 1
        } else {
            orderOut(panel)
        }
    }

    private func orderOut(_ panel: NSPanel) {
        // Transparent first: a window the window server keeps after this shows nothing.
        panel.alphaValue = 0
        panel.orderOut(nil)
        content.call = nil
    }

    /// Closes a window that would not leave the screen; the next call gets a new one.
    private func retire(_ panel: NSPanel) {
        orderOut(panel)
        panel.close()
        self.panel = nil
        ghostSeen = false
        stopWatchdog()
    }

    private func repair(_ reason: String) {
        onRepair(reason, lastCall)
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: environment.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verify() }
        }
        timer.tolerance = environment.watchdogInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// A woken, unlocked or rearranged screen is where a card can be left behind: check at once.
    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            observe(workspace, name)
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"))
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil else { return }
                self.cleanChecks = 0
                self.verify()
                self.startWatchdog()
            }
        }
        observers.append((center, observer))
    }

    private func makePanel() -> NSPanel {
        let root = CallOverlayView(
            content: content,
            hide: { [weak self] in self?.onHide() },
            perform: { [weak self] in self?.onAction($0) }
        )
        let panel = NSPanel(contentViewController: NSHostingController(rootView: root))
        panel.identifier = callOverlayWindowIdentifier
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // macOS draws notification banners in a full-screen window at level 21 (measured on macOS
        // 26), above `.floating` (3): a banner arriving during a call used to cover the card in the
        // same top-right corner. `.statusBar` (25) keeps the card above banners and other windows.
        panel.level = callOverlayWindowLevel
        // On every Space and over full-screen apps; stationary so Mission Control does not hide it.
        panel.collectionBehavior = callOverlayCollectionBehavior
        // The card fades itself (see show and hide); AppKit's own ordering animation could leave
        // the window on screen when it never finished (a call ending on a locked Mac).
        panel.animationBehavior = .none
        panel.setContentSize(NSSize(width: 390, height: 154))
        self.panel = panel
        return panel
    }

    private func position(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - 18,
            y: visible.maxY - frame.height - 18
        ))
    }
}

let callOverlayWindowLevel = NSWindow.Level.statusBar
let callOverlayCollectionBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
]

/// A soft ring repeated while a call rings on the phone, until it is answered, declined, hidden or
/// ends. Stops by itself after `maximumDuration`, as a phone stops ringing.
@MainActor
final class CallRinger {
    static let interval: TimeInterval = 3
    static let maximumDuration: TimeInterval = 120
    private let sound: NSSound?
    private var startedAt: Date?
    private var next: DispatchWorkItem?

    init(sound: NSSound? = NSSound(named: NSSound.Name("Glass"))) {
        self.sound = sound
        sound?.volume = 0.6
    }

    var isRinging: Bool { next != nil }

    func update(ringing: Bool) {
        if ringing {
            guard startedAt == nil else { return }
            startedAt = Date()
            ring()
        } else {
            next?.cancel()
            next = nil
            startedAt = nil
            sound?.stop()
        }
    }

    private func ring() {
        guard let startedAt, Date().timeIntervalSince(startedAt) < Self.maximumDuration else {
            next = nil
            return
        }
        sound?.stop()
        sound?.play()
        let work = DispatchWorkItem { [weak self] in self?.ring() }
        next = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval, execute: work)
    }
}

struct CallOverlayView: View {
    @ObservedObject var content: CallCardContent
    let hide: () -> Void
    let perform: (RemoteCallAction) -> Void

    var body: some View {
        // The glass is part of the card: with no call there is nothing to draw, not an empty panel.
        if let call = content.call {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remoteCallStatusTitle(call.type))
                            .font(.headline)
                        Text(call.caller.isEmpty ? call.applicationName : call.caller)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        hide()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Hide call controls; they remain available in Bridgey")
                }

                if call.actions.isEmpty {
                    Text("Use the phone to control this call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(visibleCallActions(call.actions, limit: 2)) { action in
                            Button(action.title) {
                                perform(action)
                            }
                            .buttonStyle(CallActionButtonStyle(color: callActionColor(action.title)))
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 390, height: 154)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.18))
            }
        } else {
            Color.clear.frame(width: 390, height: 154)
        }
    }

    private func callActionColor(_ title: String) -> Color {
        switch callActionRole(title) {
        case .answer: return .green
        case .end: return .red
        case .other: return .gray
        }
    }
}

private struct CallActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                color.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum CallActionRole {
    case answer
    case end
    case other
}

private let answerCallActionTitles = ["answer", "accept", "ответить", "принять"]
private let endCallActionTitles = [
    "decline", "reject", "hang up", "hangup", "end call",
    "отклонить", "сбросить", "завершить",
]

// Titles are only a hint: Android sends the semantic call actions first, in its own order.
func callActionRole(_ title: String) -> CallActionRole {
    let normalized = title.lowercased()
    if endCallActionTitles.contains(where: normalized.contains) { return .end }
    if answerCallActionTitles.contains(where: normalized.contains) { return .answer }
    return .other
}

func visibleCallActions(_ actions: [RemoteCallAction], limit: Int) -> [RemoteCallAction] {
    var visible = Array(actions.prefix(limit))
    guard !visible.isEmpty,
          !visible.contains(where: { callActionRole($0.title) == .end }),
          let end = actions.dropFirst(limit).first(where: { callActionRole($0.title) == .end }) else {
        return visible
    }
    visible[visible.count - 1] = end
    return visible
}
