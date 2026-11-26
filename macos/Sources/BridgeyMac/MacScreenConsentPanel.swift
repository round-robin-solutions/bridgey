import AppKit
import SwiftUI

/*
 * Ask each time: a small floating prompt at the top of the main screen, "Pixel 9 wants to see this screen", with
 * Don't allow and Allow. It never takes focus from the app in front. Allow does nothing while a phone controls this
 * Mac (it could otherwise press Allow itself); the prompt then says to stop remote control first.
 */
@MainActor
final class DisplayConsentPanel: DisplayConsentPresenting {
    private var panel: NSPanel?
    private let model = DisplayConsentModel()

    func ask(deviceName: String, canAllow: @escaping () -> Bool, answer: @escaping (Bool) -> Void) {
        dismiss()
        model.deviceName = deviceName
        model.blocked = false
        model.allow = { [weak self] in
            guard let self else { return }
            guard DisplayConsentRules.allowTakes(canAllow: canAllow(), event: NSApp.currentEvent) else {
                self.model.blocked = true
                return
            }
            answer(true)
        }
        model.deny = { answer(false) }
        let host = ConsentHostingView(rootView: DisplayConsentWindowContent(model: model))
        let size = CGSize(width: 380, height: host.fittingSize.height)
        let created = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.contentView = host
        if let visible = NSScreen.main?.visibleFrame {
            created.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
        }
        created.orderFrontRegardless()
        panel = created
    }

    func dismiss() {
        BridgeyWindows.orderOut(panel)
        panel = nil
    }
}

/// When Allow on the prompt counts (security review 1.0).
enum DisplayConsentRules {
    /// Nothing controls this Mac now, and the click is a person's: a click Bridgey injected for a phone (the touchpad
    /// or screen control, marked by [InjectedEvents]) never presses Allow, even one that arrives after its session ended,
    /// such as the release of a held button.
    static func allowTakes(canAllow: Bool, event: NSEvent?) -> Bool {
        canAllow && !InjectedEvents.isInjected(event)
    }
}

/// Every mouse and key event Bridgey posts for another device carries this mark, so Bridgey's own prompts can tell
/// them from a person's.
enum InjectedEvents {
    /// "BRDGYIN1".
    static let marker: Int64 = 0x4252_4447_5949_4E31

    /// An event source whose events carry the mark (`eventSourceUserData`).
    static func source() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = marker
        return source
    }

    static func isInjected(_ event: NSEvent?) -> Bool {
        event?.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }
}

@MainActor
final class DisplayConsentModel: ObservableObject {
    @Published var deviceName = ""
    @Published var blocked = false
    var allow: () -> Void = {}
    var deny: () -> Void = {}
}

private final class ConsentHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct DisplayConsentWindowContent: View {
    @ObservedObject var model: DisplayConsentModel

    var body: some View {
        BrandRoot(reduceMotion: UserDefaults.standard.bool(forKey: "settings.reduceMotion")) {
            DisplayConsentPrompt(deviceName: model.deviceName, blocked: model.blocked, allow: model.allow, deny: model.deny)
                .padding(12)
        }
    }
}

/// The prompt itself, also drawn by the screenshot tests.
struct DisplayConsentPrompt: View {
    let deviceName: String
    let blocked: Bool
    let allow: () -> Void
    let deny: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(c.on2)
                    .accessibilityHidden(true)
                Text(String(format: L10n.text("display.consent.title", fallback: "%@ wants to see this screen"), deviceName))
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(c.on)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if blocked {
                Text(L10n.text("display.consent.blocked", fallback: "Stop remote control first."))
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.tpi)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.text("display.consent.deny", fallback: "Don\u{2019}t allow"), action: deny)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                Button(L10n.text("display.consent.allow", fallback: "Allow"), action: allow)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 30))
            }
        }
        .padding(14)
        .frame(width: 356, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.panel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BrandPalette.aurora, lineWidth: 1.5))
        .compositingGroup()
        .shadow(color: .black.opacity(c.isDark ? 0.45 : 0.18), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}
