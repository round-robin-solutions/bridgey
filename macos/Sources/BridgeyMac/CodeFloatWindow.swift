import AppKit
import SwiftUI

/*
 * The floating Copy code card (Rahul, 2026-10-31: "The Copy OTP notification and button should
 * float for 60 seconds. This will make it quickest to do.").
 *
 * A code from a message gets a notification banner with Copy code, and the macOS banner is gone
 * after a few seconds. This small card stays at the top right for 60 seconds (or until the code is
 * copied or the card is closed), so Copy is one click away while the code is still fresh.
 *
 * - It never takes focus: a non-activating panel that does not become key when clicked, so Copy
 *   followed at once by Command-V pastes into the app the person was in.
 * - It leaves the screen through BridgeyWindows (WindowLifecycle.swift), whose watchdog repairs a
 *   window that stays drawn. A locked screen, a sleeping display and a switched-out session close it
 *   on the spot, and it is not shown at all while the screen is locked.
 * - It is excluded from screenshots and screen sharing (`sharingType = .none`).
 * - The code is held by the card in memory only. It is never logged.
 *
 * A Time Sensitive notification (to keep the banner itself up longer) needs the restricted
 * `com.apple.developer.usernotifications.time-sensitive` entitlement, which must come from a
 * provisioning profile; none of this app's builds (Developer ID, Round Robin or ad hoc signing) carries
 * one, and a restricted entitlement without its profile stops the app from launching. So the
 * notification keeps its normal level and this card is how the button stays on screen.
 */

// MARK: - Setting

/// Settings > Notifications > Codes from messages > Keep the copy button on screen for. Stored as
/// `settings.codes.float` on this Mac only (it is not one of the synced settings). A value this build
/// does not know reads as the default.
enum CodeFloatSetting: String, CaseIterable, Equatable {
    case sixty = "60"
    case thirty = "30"
    /// No floating card: the notification is all there is.
    case off

    static let defaultsKey = "settings.codes.float"
    static let `default`: CodeFloatSetting = .sixty

    static func stored(_ value: String?) -> CodeFloatSetting {
        value.flatMap(CodeFloatSetting.init(rawValue:)) ?? .default
    }

    /// How long the card stays; nil when there is no card.
    var seconds: TimeInterval? {
        switch self {
        case .sixty: 60
        case .thirty: 30
        case .off: nil
        }
    }

    var title: String {
        switch self {
        case .sixty: L10n.text("codes.float.60", fallback: "60 seconds")
        case .thirty: L10n.text("codes.float.30", fallback: "30 seconds")
        case .off: L10n.text("codes.float.off", fallback: "Only the notification")
        }
    }
}

// MARK: - Controller

/// What the card asks of the system. Tests replace each part to run time by hand or lock the screen.
@MainActor
struct CodeFloatEnvironment {
    /// Runs `work` after `delay` seconds on the main queue; the result cancels it.
    var schedule: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
    /// The screen is locked or asleep: the card is not shown.
    var screenUnavailable: @MainActor () -> Bool
    var reduceMotion: @MainActor () -> Bool
    /// How long "Copied" shows before the card goes.
    var copiedLinger: TimeInterval = 1.2
    /// A fade that has not ended by then is cut short and the card emptied.
    var cleanupDelay: TimeInterval = BridgeyWindows.fadeDeadline + 0.2

    static var live: CodeFloatEnvironment {
        CodeFloatEnvironment(
            schedule: { delay, work in
                let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                return { item.cancel() }
            },
            screenUnavailable: { BridgeyWindows.screenUnavailable() },
            reduceMotion: {
                UserDefaults.standard.bool(forKey: "settings.reduceMotion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        )
    }
}

/// The code on the card. It stays set while the card fades out, so the card never shows empty.
@MainActor
final class CodeFloatContent: ObservableObject {
    @Published var card: LiveCodeCard?
    @Published var copied = false
}

let codeFloatWindowIdentifier = NSUserInterfaceItemIdentifier("in.roundrobin.bridgey.code-float")
/// Below the call card (`.statusBar`) and above notification banners (measured at 21 on macOS 26).
let codeFloatWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
let codeFloatSize = NSSize(width: 348, height: 172)

/// A panel that never activates the app. Esc closes it while it has keyboard focus.
final class CodeFloatPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

@MainActor
final class CodeFloatWindowController {
    /// Copy was pressed on the card: the reference of the code to copy.
    var onCopy: (String) -> Void = { _ in }
    /// The frame of a window the card must not cover (the call card), if one is on screen.
    var avoid: () -> NSRect? = { nil }

    let content = CodeFloatContent()
    private let environment: CodeFloatEnvironment
    private(set) var panel: CodeFloatPanel?
    /// A code should be on screen.
    private(set) var isShowing = false
    private var cancelClose: (() -> Void)?
    private var cancelCleanup: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(environment: CodeFloatEnvironment? = nil) {
        self.environment = environment ?? .live
        observeSystemChanges()
    }

    /// Shows `card` for `seconds`. A card already on screen takes the new code and starts the time
    /// again, without moving. Nothing shows while the screen is locked or asleep.
    func show(_ card: LiveCodeCard, seconds: TimeInterval) {
        guard seconds > 0, !environment.screenUnavailable() else { return }
        cancelCleanup?()
        cancelCleanup = nil
        content.card = card
        content.copied = false
        let panel = self.panel ?? makePanel()
        let wasOnScreen = panel.isVisible && isShowing
        isShowing = true
        BridgeyWindows.cancelFade(panel)
        if wasOnScreen {
            panel.alphaValue = 1
        } else {
            if !panel.isVisible { position(panel) }
            let reduce = environment.reduceMotion()
            panel.alphaValue = reduce ? 1 : 0
            panel.orderFrontRegardless()
            if !reduce { BridgeyWindows.fadeIn(panel) }
        }
        scheduleClose(after: seconds)
    }

    /// The code was copied (from the card, the banner, the panel or automatically): the card says so
    /// and goes. Another code's copy leaves it alone.
    func markCopied(_ reference: String) {
        guard isShowing, content.card?.id == reference else { return }
        content.copied = true
        scheduleClose(after: environment.copiedLinger)
    }

    /// Close button, Esc, or the end of the time.
    func dismiss() {
        hide(animated: true)
    }

    /// The locked, sleeping or switched-out screen: gone at once, no fade.
    func screenWentAway() {
        hide(animated: false)
    }

    private func scheduleClose(after seconds: TimeInterval) {
        cancelClose?()
        cancelClose = environment.schedule(seconds) { [weak self] in self?.dismiss() }
    }

    /// Always ends with the window ordered out and the code gone from the card.
    private func hide(animated: Bool) {
        cancelClose?()
        cancelClose = nil
        isShowing = false
        guard let panel else {
            empty()
            return
        }
        if animated, panel.isVisible, !environment.reduceMotion() {
            BridgeyWindows.fadeOut(panel)
        } else {
            BridgeyWindows.orderOut(panel)
            empty()
        }
        // A fade that never ended: ordered out and emptied by hand.
        cancelCleanup?()
        cancelCleanup = environment.schedule(environment.cleanupDelay) { [weak self] in
            guard let self, !self.isShowing else { return }
            if let panel = self.panel, panel.isVisible { BridgeyWindows.orderOut(panel) }
            self.empty()
        }
    }

    private func empty() {
        content.card = nil
        content.copied = false
    }

    private func makePanel() -> CodeFloatPanel {
        let root = BrandRoot(reduceMotion: environment.reduceMotion()) {
            CodeFloatView(
                content: content,
                copy: { [weak self] in
                    guard let self, let id = self.content.card?.id else { return }
                    self.onCopy(id)
                },
                close: { [weak self] in self?.dismiss() }
            )
        }
        let host = NSHostingView(rootView: root)
        let panel = CodeFloatPanel(contentRect: NSRect(origin: .zero, size: codeFloatSize),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.identifier = codeFloatWindowIdentifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // A click on Copy must not make the card the key window: the person pastes into the app they
        // were in, and that app keeps the keyboard.
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = codeFloatWindowLevel
        panel.collectionBehavior = callOverlayCollectionBehavior
        // The card fades itself (BridgeyWindows); AppKit's own ordering animation could leave it drawn.
        panel.animationBehavior = .none
        // Out of screenshots, recordings and screen sharing: the card shows a one-time code.
        panel.sharingType = .none
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.setContentSize(codeFloatSize)
        self.panel = panel
        return panel
    }

    private func position(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        var top = visible.maxY - 18
        if let other = avoid(), other.maxX > visible.maxX - frame.width - 18 { top = min(top, other.minY - 10) }
        window.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 18, y: max(visible.minY, top - frame.height)))
    }

    /// Lock, display sleep, system sleep and a switched-out user session: the card goes with them.
    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenWentAway() }
        }
        observers.append((center, observer))
    }
}

// MARK: - View

/// The card: where the code came from, the code, and one large Copy button.
struct CodeFloatView: View {
    @ObservedObject var content: CodeFloatContent
    let copy: () -> Void
    let close: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Group {
            if let card = content.card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        IconTile(symbol: "key.fill", tint: .blue, size: 30, corner: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: L10n.text("codes.float.from", fallback: "Code from %@"), card.sender))
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(c.on)
                                .lineLimit(1)
                            Text(card.deviceName)
                                .font(BrandFont.body(12))
                                .foregroundStyle(c.on2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(c.on2)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(c.s3))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("codes.float.close", fallback: "Close"))
                    }
                    Text(card.code)
                        .font(BrandFont.heading(34))
                        .tracking(3)
                        .foregroundStyle(c.on)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: copy) {
                        HStack(spacing: 7) {
                            if content.copied { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
                            Text(content.copied ? L10n.text("codes.float.copied", fallback: "Copied") : L10n.text("codes.copy", fallback: "Copy code"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: content.copied ? .good : .gradient, height: 40))
                }
                .padding(16)
                .frame(width: codeFloatSize.width, height: codeFloatSize.height)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(c.s1))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(c.panelBorder, lineWidth: 1))
            } else {
                Color.clear.frame(width: codeFloatSize.width, height: codeFloatSize.height)
            }
        }
    }
}
