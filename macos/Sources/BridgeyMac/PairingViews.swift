import SwiftUI

/*
 * The pairing flow as the menu bar panel and setup's pair step draw it: one content view per state
 * (connecting, waiting for Allow pairing on the other device, the code check in its four states, paired,
 * failed), so both places say and do the same. The hosts wrap it in their own card. Android draws the same
 * states with the same words (PairingCoordinator.kt, strings_pairing.xml).
 */

struct PairingFlowActions {
    var confirm: (String) -> Void = { _ in }
    var reject: (String) -> Void = { _ in }
    var cancel: () -> Void = {}
    var retry: () -> Void = {}
    var openLocalNetworkSettings: () -> Void = {}
}

/// The words of the pairing flow, shared by the panel and setup.
enum PairingCopy {
    static func connecting(_ name: String) -> String { String(format: L10n.text("panel.connecting", fallback: "Connecting to %@"), name) }
    static var connectingDetail: String { L10n.text("panel.connecting.detail", fallback: "Setting up a secure session") }
    static func waitingForAllow(_ name: String) -> String {
        String(format: L10n.text("pairing.allowWait.title", fallback: "Open Bridgey on %@ and tap Allow pairing"), name)
    }
    static var checkTitle: String { L10n.text("pairing.check.title", fallback: "Check the code") }
    static func alsoOn(_ name: String) -> String { String(format: L10n.text("pairing.check.alsoOn", fallback: "This code is also on %@."), name) }
    static func waitingTitle(_ name: String) -> String { String(format: L10n.text("pairing.waiting.title", fallback: "Waiting for %@\u{2026}"), name) }
    static var waitingDetail: String { L10n.text("pairing.waiting.detail", fallback: "Tap Codes match there too.") }
    static func remoteConfirmedTitle(_ name: String) -> String { String(format: L10n.text("pairing.remoteConfirmed.title", fallback: "%@ confirmed"), name) }
    static var remoteConfirmedDetail: String {
        L10n.text("pairing.remoteConfirmed.detail", fallback: "Check the code, then tap Codes match here to finish.")
    }
    static var finishingTitle: String { L10n.text("pairing.finishing.title", fallback: "Both confirmed") }
    static func finishingDetail(_ name: String) -> String { String(format: L10n.text("pairing.finishing.detail", fallback: "Finishing pairing with %@."), name) }
    static var match: String { L10n.text("panel.verify.match", fallback: "Codes match") }
    static var mismatch: String { L10n.text("pairing.mismatch", fallback: "Don\u{2019}t match") }
    static func paired(_ name: String) -> String { String(format: L10n.text("pairing.paired.title", fallback: "Paired with %@"), name) }
    static var pairedNext: String { L10n.text("pairing.paired.next", fallback: "Drop a file on the bar below, or send your clipboard.") }
    static var failedTitle: String { L10n.text("panel.pairingFailed", fallback: "Pairing failed") }
    static var tryAgain: String { L10n.text("pairing.tryAgain", fallback: "Try again") }
    static var close: String { L10n.text("action.close", fallback: "Close") }
    static var cancel: String { L10n.text("action.cancel", fallback: "Cancel") }
    static var done: String { L10n.text("action.done", fallback: "Done") }
    static func request(_ name: String) -> String { String(format: L10n.text("pairing.request.title", fallback: "%@ wants to pair."), name) }
    static var requestDetail: String { L10n.text("pairing.request.detail", fallback: "Allow it only if you are pairing it now.") }
    static var allow: String { L10n.text("pairing.allow", fallback: "Allow pairing") }
    static var allowPrompt: String { L10n.text("pairing.allow.prompt", fallback: "Pairing from a phone?") }
    static func allowed(_ seconds: Int) -> String {
        String(format: L10n.text("pairing.allowed", fallback: "Pairing allowed for %@"), pairingCountdownText(seconds))
    }
    static var stop: String { L10n.text("action.stop", fallback: "Stop") }
    static var dismiss: String { L10n.text("action.dismiss", fallback: "Dismiss") }
    static var openSettings: String { L10n.text("panel.localNetwork", fallback: "Open Settings") }

    static func failure(_ reason: PairingFailure, peerName: String, detail: String?) -> String {
        let message = reason.message(peerName: peerName)
        return detail.map { "\($0). \(message)" } ?? message
    }
}

/// The six digits, grouped 3 + 3, monospaced and large; VoiceOver reads them digit by digit.
struct PairingCodeText: View {
    let code: String
    var size: CGFloat = 34
    var muted = false
    @Environment(\.brand) private var c

    var body: some View {
        Text(formattedPairingCode(code))
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .kerning(size * 0.06)
            .foregroundStyle(muted ? c.on2 : c.on)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: size * 1.9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s3.opacity(c.isDark ? 0.7 : 1)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pairingCodeSpokenLabel(code))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Three dots that breathe while the other device is working (opacity only; still with reduced motion and in screenshots).
struct PairingLiveDots: View {
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot
    @State private var lit = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(c.pri)
                    .frame(width: 5, height: 5)
                    .opacity(reduce || snapshot ? 0.4 + 0.25 * Double(index) : (lit ? 1 : 0.25))
                    .animation(reduce || snapshot ? nil : .easeInOut(duration: 0.7).repeatForever().delay(0.2 * Double(index)), value: lit)
            }
        }
        .onAppear { if !reduce && !snapshot { lit = true } }
        .accessibilityHidden(true)
    }
}

/// One pairing state's content. `codeSize`: larger in setup's wider column.
struct PairingFlowContent: View {
    let state: PairingState
    let actions: PairingFlowActions
    var codeSize: CGFloat = 34
    @Environment(\.brand) private var c

    var body: some View {
        switch state {
        case let .connecting(name):
            header(symbol: "lock.shield", tint: .blue, title: PairingCopy.connecting(name), detail: PairingCopy.connectingDetail)
        case let .waitingForAllow(name):
            header(symbol: "hand.tap", tint: .blue, title: PairingCopy.waitingForAllow(name), detail: nil, live: true)
            buttons { secondary(PairingCopy.cancel, actions.cancel) }
        case let .verification(prompt):
            verification(prompt)
        case let .paired(_, name):
            header(symbol: "checkmark", tint: .green, title: PairingCopy.paired(name), detail: PairingCopy.pairedNext)
            buttons { secondary(PairingCopy.done, actions.cancel) }
        case let .failed(reason, name, detail):
            header(symbol: "exclamationmark.triangle.fill", tint: .purple, title: PairingCopy.failedTitle,
                   detail: PairingCopy.failure(reason, peerName: name, detail: detail))
            buttons {
                secondary(PairingCopy.close, actions.cancel)
                if reason == .localNetworkDenied {
                    Button(PairingCopy.openSettings, action: actions.openLocalNetworkSettings)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                }
                Button(PairingCopy.tryAgain, action: actions.retry)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
            }
        case .idle, .connected:
            EmptyView()
        }
    }

    @ViewBuilder private func verification(_ prompt: PairingPrompt) -> some View {
        let name = prompt.peerName
        switch (prompt.localConfirmed, prompt.remoteConfirmed) {
        case (false, false):
            title(PairingCopy.checkTitle)
            PairingCodeText(code: prompt.code, size: codeSize)
            detail(PairingCopy.alsoOn(name))
            decision(prompt)
        case (true, false):
            title(PairingCopy.waitingTitle(name), live: true)
            PairingCodeText(code: prompt.code, size: codeSize, muted: true)
            detail(PairingCopy.waitingDetail)
            buttons { secondary(PairingCopy.cancel, actions.cancel) }
        case (false, true):
            title(PairingCopy.remoteConfirmedTitle(name), check: true)
            PairingCodeText(code: prompt.code, size: codeSize)
            detail(PairingCopy.remoteConfirmedDetail)
            decision(prompt)
        case (true, true):
            title(PairingCopy.finishingTitle, live: true)
            PairingCodeText(code: prompt.code, size: codeSize, muted: true)
            detail(PairingCopy.finishingDetail(name))
        }
    }

    private func title(_ text: String, live: Bool = false, check: Bool = false) -> some View {
        HStack(spacing: 6) {
            if check {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.tgi)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if live { PairingLiveDots() }
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(12))
            .foregroundStyle(c.on2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Don't match and Codes match, side by side; Codes match is the main action. No Return shortcut: confirming has to
    /// be a deliberate click after reading both screens.
    private func decision(_ prompt: PairingPrompt) -> some View {
        HStack(spacing: 8) {
            Button { actions.reject(prompt.token) } label: { Text(PairingCopy.mismatch).frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
            Button { actions.confirm(prompt.token) } label: { Text(PairingCopy.match).frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle(kind: .gradient, height: 32))
        }
        .padding(.top, 2)
    }

    private func header(symbol: String, tint: TileTint, title: String, detail: String?, live: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 32, corner: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if live { PairingLiveDots().padding(.top, 2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The card's buttons on the right; when they do not fit on one line (longer languages) they stack, still right-aligned.
    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let items = content()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                items
            }
            VStack(alignment: .trailing, spacing: 8) { items }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(PillButtonStyle(kind: .outline, height: 30))
    }
}

/// The panel's Allow pairing row: a quiet offer while nothing is armed, the countdown and Stop while it is.
struct AllowPairingRow: View {
    let armedSeconds: Int
    let onAllow: () -> Void
    let onStop: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        let armed = armedSeconds > 0
        HStack(spacing: 10) {
            Image(systemName: armed ? "lock.open" : "iphone.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(armed ? c.tgi : c.on2)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(armed ? PairingCopy.allowed(armedSeconds) : PairingCopy.allowPrompt)
                .font(BrandFont.body(12, armed ? .medium : .regular))
                .monospacedDigit()
                .foregroundStyle(armed ? c.on : c.on2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if armed {
                Button(PairingCopy.stop, action: onStop)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 26))
            } else {
                Button(PairingCopy.allow, action: onAllow)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 26))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(armed ? c.tg : c.s2))
        .accessibilityElement(children: .contain)
    }
}

/// "<name> wants to pair.": a device tried while this Mac was not accepting pairings. An older Bridgey cannot pair at
/// all, so its card says to update it instead of offering Allow pairing.
struct PairingRequestContent: View {
    let request: PairingRequest
    let onAllow: () -> Void
    let onDismiss: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: request.oldVersion ? "arrow.down.circle" : "iphone.radiowaves.left.and.right",
                     tint: request.oldVersion ? .purple : .blue, size: 32, corner: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(PairingCopy.request(request.peerName))
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on)
                    .fixedSize(horizontal: false, vertical: true)
                Text(request.oldVersion ? pairingOldVersionText(request.peerName) : PairingCopy.requestDetail)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(PairingCopy.dismiss, action: onDismiss)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 30))
            if !request.oldVersion {
                Button(PairingCopy.allow, action: onAllow)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
            }
        }
    }
}
