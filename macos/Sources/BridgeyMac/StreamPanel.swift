import AppKit
import Combine
import SwiftUI

/*
 * Direction B "Stream" menu-bar panel, 360 pt wide. Reading order: device chips (ring style
 * shows the route), then live cards that need an action now, then what moved, newest first,
 * then quick actions and the send bar (the one main action: send the clipboard, or drop a file).
 *
 * The view draws from a plain `PanelModel`, so screenshots render it from sample state.
 */

enum RingingState: Equatable {
    /// The phone is ringing this Mac.
    case mac(String)
    /// This Mac is ringing the phone.
    case phone(String)
}

enum NotificationPrompt: Equatable { case request, openSettings }

struct PanelModel {
    var onboardingDone = true
    /// Once after an update from before v0.10 setup: "See what's new and review your setup".
    var showsSetupReview = false
    var state: PairingState = .idle
    /// The pairing in progress only; drives the verification and failure cards.
    var pairingFlow: PairingState = .idle
    var rings: [DeviceRing] = []
    var battery: RemoteBatteryStatus?
    /// Each connected phone's own battery, by device id.
    var batteries: [String: RemoteBatteryStatus] = [:]
    /// The phone single-target actions go to.
    var targetDeviceID: String?
    var transfers: [FileTransferRow] = []
    /// Folder cards drawn expanded (screenshots; in the app the card's disclosure decides).
    var expandedTransfers: Set<String> = []
    var hasTransferHistory = false
    var receivedLink: String?
    var ringing: RingingState?
    var call: RemoteCallStatus?
    /// Codes from messages: the newest code, for ten minutes.
    var code: LiveCodeCard?
    /// Codes from messages > On this Mac: the model download, then "ready" until dismissed.
    var codeModel: CodeModelPanelState?
    var rows: [StreamRow] = []
    var showPreviews = true
    var now = Date()
    var available: Set<BridgeyFeature> = []
    var clipboardLine: String?
    var clipboardHidden = false
    var status: String?
    var notificationPrompt: NotificationPrompt?
    var mediaPlayer: MediaPlayer = .off
    var mediaDetail = ""
    var fileTransferActive = false
    /// Automatic clipboard is running for the connected device.
    var autoClipboard = false
    /// "Look for devices again" is running.
    var rediscovering = false
    /// In-app update progress (Sparkle drives it; no system windows).
    var update: UpdateFlow = .idle
    var appVersion = ""
    /// The pairing file could not be loaded; phones wait until Try again succeeds.
    var pairingStoreIssue: PairingStoreIssue?

    var connectedName: String? {
        if case let .connected(_, name) = state { return name }
        return nil
    }

    var isConnected: Bool { connectedName != nil }
}

struct PanelActions {
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    var completeOnboarding: () -> Void = {}
    var openSetupReview: () -> Void = {}
    var dismissSetupReview: () -> Void = {}
    var connect: (DeviceRing) -> Void = { _ in }
    var disconnect: () -> Void = {}
    var disconnectDevice: (String) -> Void = { _ in }
    var selectDevice: (String) -> Void = { _ in }
    var confirm: () -> Void = {}
    var cancel: () -> Void = {}
    var openLocalNetworkSettings: () -> Void = {}
    var sendClipboard: () -> Void = {}
    var dropFiles: ([URL]) -> Bool = { _ in false }
    var chooseFile: () -> Void = {}
    var openDropWindow: () -> Void = {}
    var showTransfers: () -> Void = {}
    var sendLink: () -> Void = {}
    var call: () -> Void = {}
    var ping: () -> Void = {}
    var find: () -> Void = {}
    var stopFinding: () -> Void = {}
    var setPlayer: (MediaPlayer) -> Void = { _ in }
    var refreshMedia: () -> Void = {}
    var openLink: () -> Void = {}
    var dismissLink: () -> Void = {}
    var cancelTransfer: (String) -> Void = { _ in }
    var cancelAllTransfers: () -> Void = {}
    var retryTransfer: (String) -> Void = { _ in }
    var resumeTransfer: (String) -> Void = { _ in }
    var callAction: (RemoteCallAction) -> Void = { _ in }
    var copyCode: (String) -> Void = { _ in }
    var dismissCode: () -> Void = {}
    var codeModel = CodeModelPanelActions()
    var enableNotifications: () -> Void = {}
    var retryDevice: (String) -> Void = { _ in }
    var lookForDevices: () -> Void = {}
    var update = UpdateFlowActions()
    var retryPairingStore: () -> Void = {}
}

struct StreamPanelView: View {
    let model: PanelModel
    let actions: PanelActions
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    static let width: CGFloat = 360
    /// The stream scrolls inside this height so the panel never grows past the screen.
    static let maximumStreamHeight: CGFloat = 36 + 44 * 5 + 8

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(onOpenSettings: actions.openSettings)
            if !model.onboardingDone {
                WelcomeCard(onContinue: actions.completeOnboarding)
                    .padding(12)
            } else {
                main
            }
            footer
        }
        .frame(width: Self.width)
        .background(c.panel)
    }

    @ViewBuilder private var main: some View {
        if model.rings.isEmpty {
            SearchingCard(rediscovering: model.rediscovering, onLookAgain: actions.lookForDevices)
                .padding(.horizontal, 12)
                .padding(.top, 12)
        } else {
            DeviceChips(rings: model.rings, batteries: model.batteries, targetDeviceID: model.targetDeviceID,
                        fileTransferActive: model.fileTransferActive, rediscovering: model.rediscovering,
                        now: model.now, actions: actions)
                .padding(.top, 12)
        }
        stateCard
        if let issue = model.pairingStoreIssue {
            NoticeBanner(
                symbol: "key",
                text: pairingStoreIssueText(issue),
                button: L10n.text("action.retry", fallback: "Retry"),
                action: actions.retryPairingStore
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        if model.showsSetupReview {
            SetupReviewBanner(onOpen: actions.openSetupReview, onDismiss: actions.dismissSetupReview)
                .padding(.horizontal, 12)
                .padding(.top, 12)
        }
        if let prompt = model.notificationPrompt {
            NoticeBanner(
                symbol: "bell.badge",
                text: L10n.text("panel.notifications.prompt", fallback: "Allow notifications on this Mac to see Android alerts."),
                button: prompt == .request
                    ? L10n.text("panel.notifications.enable", fallback: "Allow")
                    : L10n.text("panel.notifications.settings", fallback: "Open Settings"),
                action: actions.enableNotifications
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        LiveCards(model: model, actions: actions)
        StreamList(rows: model.rows, showPreviews: model.showPreviews, now: model.now, hasLiveCards: hasLiveCards)
        if model.isConnected {
            QuickActionBar(model: model, actions: actions)
                .padding(.horizontal, 12)
                .padding(.top, 10)
        }
        SendBar(model: model, actions: actions)
            .padding(12)
    }

    private var hasLiveCards: Bool {
        !model.transfers.isEmpty || model.receivedLink != nil || model.ringing != nil || model.call != nil || model.code != nil || model.codeModel != nil || model.update.showsInPanel
    }

    @ViewBuilder private var stateCard: some View {
        switch model.pairingFlow {
        case let .connecting(name):
            StatusCard(
                symbol: "lock.shield",
                title: String(format: L10n.text("panel.connecting", fallback: "Connecting to %@"), name),
                detail: L10n.text("panel.connecting.detail", fallback: "Setting up a secure session")
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
        case let .verification(name, code):
            VerificationCard(name: name, code: code, actions: actions)
                .padding(.horizontal, 12)
                .padding(.top, 12)
        case let .failed(message):
            FailureCard(message: message, actions: actions)
                .padding(.horizontal, 12)
                .padding(.top, 12)
        case .idle, .connected:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.text("panel.settings", fallback: "Settings\u{2026}"), action: actions.openSettings)
            Spacer()
            Button(L10n.text("panel.quit", fallback: "Quit Bridgey"), action: actions.quit)
        }
        .buttonStyle(.plain)
        .font(BrandFont.body(13))
        .foregroundStyle(c.on2)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }
}

// MARK: - Header

/// The brand row. In light mode it sits on the midnight band, painted once.
private struct PanelHeader: View {
    let onOpenSettings: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        let header = c.isDark ? c : BrandPalette.band
        HStack(spacing: 8) {
            AuroraMark(size: 22)
            Text("Bridgey")
                .font(BrandFont.heading(17))
                .foregroundStyle(header.on)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(header.on2)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .help(L10n.text("panel.settings.help", fallback: "Settings"))
            .accessibilityLabel(L10n.text("panel.settings.help", fallback: "Settings"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
        .background { if !c.isDark { AuroraBand() } }
        .environment(\.brand, header)
    }
}

/// Midnight with two soft aurora glows. Static: no blur, nothing animates.
struct AuroraBand: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                BrandPalette.midnight
                RadialGradient(
                    colors: [BrandPalette.auroraPurple.opacity(0.30), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, 1) * 0.8
                )
                RadialGradient(
                    colors: [BrandPalette.auroraBlue.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, 1) * 0.8
                )
            }
        }
    }
}

// MARK: - Device chips

private struct DeviceChips: View {
    let rings: [DeviceRing]
    /// Each connected phone's own battery.
    let batteries: [String: RemoteBatteryStatus]
    let targetDeviceID: String?
    let fileTransferActive: Bool
    let rediscovering: Bool
    let now: Date
    let actions: PanelActions
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        if rings.count <= 2 {
            HStack(spacing: 8) {
                ForEach(rings) { ring in chip(ring).frame(maxWidth: .infinity) }
                LookAgainButton(rediscovering: rediscovering, action: actions.lookForDevices)
            }
            .padding(.horizontal, 12)
        } else if snapshot {
            HStack(spacing: 8) {
                ForEach(rings) { chip($0).frame(width: 164) }
                LookAgainButton(rediscovering: rediscovering, action: actions.lookForDevices)
            }
                .padding(.horizontal, 12)
                .frame(width: StreamPanelView.width, alignment: .leading)
                .clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(rings) { chip($0).frame(width: 164) }
                    LookAgainButton(rediscovering: rediscovering, action: actions.lookForDevices)
                }
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder private func chip(_ ring: DeviceRing) -> some View {
        let content = DeviceChip(ring: ring, battery: ring.state == .connected ? ring.deviceID.flatMap { batteries[$0] } : nil, now: now)
        switch ring.state {
        case _ where ring.canRetry:
            // A trusted device Bridgey is still trying to reach: say so, and offer to try now.
            PopUpMenuButton(items: {
                [
                    PopUpMenuItem(
                        title: L10n.text("panel.retryNow", fallback: "Retry now"),
                        enabled: true,
                        action: { if let id = ring.deviceID { actions.retryDevice(id) } }
                    ),
                    PopUpMenuItem(
                        title: L10n.text("panel.lookAgain", fallback: "Look for devices again"),
                        enabled: !rediscovering,
                        action: actions.lookForDevices
                    ),
                ]
            }) { content }
            .help(ringRetryHelp(ring))
        case .connected:
            PopUpMenuButton(items: {
                var items: [PopUpMenuItem] = []
                // Several phones: pick which one sends, pings and finds go to.
                if let id = ring.deviceID, id != targetDeviceID {
                    items.append(PopUpMenuItem(
                        title: String(format: L10n.text("panel.sendTo", fallback: "Send to %@"), ring.name),
                        enabled: true,
                        action: { actions.selectDevice(id) }
                    ))
                }
                items.append(PopUpMenuItem(
                    title: String(format: L10n.text("panel.disconnect", fallback: "Disconnect %@"), ring.name),
                    enabled: !fileTransferActive,
                    action: { if let id = ring.deviceID { actions.disconnectDevice(id) } else { actions.disconnect() } }
                ))
                return items
            }) { content }
            .help(L10n.text("panel.chip.connected.help", fallback: "Connected. Click for options."))
        case .nearby where ring.canConnect:
            Button { actions.connect(ring) } label: { content }
                .buttonStyle(PressScaleStyle())
                .help(ring.trusted
                      ? L10n.text("panel.chip.reconnect.help", fallback: "Connect to this device")
                      : L10n.text("panel.chip.pair.help", fallback: "Pair with this device"))
        default:
            content
        }
    }
}

/// "Look for devices again": restarts discovery and tries every dropped device now.
private struct LookAgainButton: View {
    let rediscovering: Bool
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        let label = L10n.text("panel.lookAgain", fallback: "Look for devices again")
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.on2)
                .frame(width: 32, height: 48)
                .background(Capsule().fill(c.s2))
                .contentShape(Capsule())
                .opacity(rediscovering ? 0.4 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(rediscovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct DeviceChip: View {
    let ring: DeviceRing
    let battery: RemoteBatteryStatus?
    let now: Date
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 0) {
            DeviceRingView(state: ring.state, platform: ring.platform, size: 36)
                .padding(.trailing, 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(ring.name)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                // The long form ("Reconnecting… (last seen 02:56)") when the chip is wide enough.
                ViewThatFits(in: .horizontal) {
                    Text(ringStatusDetail(ring, now: now))
                    Text(status)
                }
                    .font(BrandFont.body(11, .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let battery {
                // The ring and "Same Wi-Fi" already show the route, so the trailing mark shows the battery.
                Image(systemName: batterySymbol(battery))
                    .font(.system(size: 11, weight: .medium))
                    .padding(.leading, 4)
                    .foregroundStyle(battery.level <= 20 && !battery.isCharging ? c.warn : c.on2)
                    .help(batteryText(battery))
                    .accessibilityLabel(batteryText(battery))
            } else if let symbol = routeSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.leading, 4)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(Capsule().fill(ring.state == .connected ? c.tb : c.s2))
        .contentShape(Capsule())
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: ring.state)
        .accessibilityElement(children: .combine)
    }

    private var status: String { ringStatusText(ring) }

    private func batteryText(_ battery: RemoteBatteryStatus) -> String {
        String(format: battery.isCharging
            ? L10n.text("panel.battery.charging", fallback: "Battery %d%%, charging")
            : L10n.text("panel.battery", fallback: "Battery %d%%"), battery.level)
    }

    private func batterySymbol(_ battery: RemoteBatteryStatus) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var statusColor: Color {
        switch ring.state {
        case .connected, .nearby: c.tgi
        case .connecting, .privateNetwork: c.tbi
        case .relay: c.tpi
        case .offline: c.on2
        }
    }

    private var routeSymbol: String? {
        switch ring.state {
        case .connected: "wifi"
        case .relay: "cloud"
        case .privateNetwork: "network"
        default: nil
        }
    }
}

// MARK: - Cards

private struct CardShell<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
    }
}

private struct CardText: View {
    let title: String
    let detail: String?
    var detailLines = 2
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on)
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .lineLimit(detailLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WelcomeCard: View {
    let onContinue: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            AuroraMark(size: 36)
            Text(L10n.text("welcome.title", fallback: "Welcome to Bridgey"))
                .font(BrandFont.heading(17))
                .foregroundStyle(c.on)
            Text(L10n.text(
                "welcome.body",
                fallback: "Keep your Mac and phone on the same local network. Choose a device, compare the pairing code, and confirm it on both devices. Optional permissions are requested only when you use the related feature."
            ))
            .font(BrandFont.body(12))
            .foregroundStyle(c.on2)
            .fixedSize(horizontal: false, vertical: true)
            Button(action: onContinue) {
                Text(L10n.text("welcome.continue", fallback: "Get started")).frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .gradient, height: 36))
            .accessibilityHint(L10n.text("welcome.continue.hint", fallback: "Closes the welcome guide and starts device discovery"))
        }
    }
}

private struct SearchingCard: View {
    var rediscovering = false
    var onLookAgain: () -> Void = {}

    var body: some View {
        CardShell {
            HStack(spacing: 10) {
                IconTile(symbol: "dot.radiowaves.left.and.right", tint: .blue, size: 32, corner: 10)
                CardText(
                    title: L10n.text("panel.searching", fallback: "Looking for Android devices"),
                    detail: L10n.text("panel.searching.detail", fallback: "Keep both devices on the same Wi-Fi network.")
                )
            }
            Button(L10n.text("panel.lookAgain", fallback: "Look for devices again"), action: onLookAgain)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                .disabled(rediscovering)
        }
    }
}

private struct StatusCard: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        CardShell {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: .blue, size: 32, corner: 10)
                CardText(title: title, detail: detail)
            }
        }
    }
}

private struct VerificationCard: View {
    let name: String
    let code: String
    let actions: PanelActions
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            Text(String(format: L10n.text("panel.verify", fallback: "Verify %@"), name))
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on)
            Text(code)
                .font(BrandFont.heading(32))
                .monospacedDigit()
                .kerning(2)
                .foregroundStyle(c.on)
                .textSelection(.enabled)
            Text(L10n.text("panel.verify.detail", fallback: "Confirm only if the same code appears on both devices."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                    .buttonStyle(PillButtonStyle(kind: .outline))
                Button(L10n.text("panel.verify.match", fallback: "Codes Match"), action: actions.confirm)
                    .buttonStyle(PillButtonStyle(kind: .gradient))
            }
        }
    }
}

private struct FailureCard: View {
    let message: String
    let actions: PanelActions

    var body: some View {
        CardShell {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: "exclamationmark.triangle.fill", tint: .purple, size: 32, corner: 10)
                CardText(title: L10n.text("panel.pairingFailed", fallback: "Pairing failed"), detail: message, detailLines: 4)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.text("action.dismiss", fallback: "Dismiss"), action: actions.cancel)
                    .buttonStyle(PillButtonStyle(kind: .outline))
                if message.contains("Local Network") {
                    Button(L10n.text("panel.localNetwork", fallback: "Open Settings"), action: actions.openLocalNetworkSettings)
                        .buttonStyle(PillButtonStyle(kind: .tonal))
                }
            }
        }
    }
}

/// One quiet line with an action, on a purple tint (the design's "away" banner style).
private struct NoticeBanner: View {
    let symbol: String
    let text: String
    let button: String
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(c.tpi)
            Text(text)
                .font(BrandFont.body(12))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(button, action: action)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 26))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.tp))
    }
}

func pairingStoreIssueText(_ issue: PairingStoreIssue) -> String {
    switch issue {
    case .keychainAccessDenied:
        L10n.text("pairingStore.keychain", fallback: "Bridgey needs Keychain access one last time to move your pairing keys into a private file. After that, updates never ask. Phones stay disconnected until then.")
    case .fileUnreadable:
        L10n.text("pairingStore.file", fallback: "Bridgey can't open its pairing file, so phones stay disconnected.")
    }
}

// MARK: - Live cards

private struct LiveCards: View {
    let model: PanelModel
    let actions: PanelActions
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: 8) {
            if let call = model.call {
                LiveCard(symbol: "phone.fill", tint: .green, title: remoteCallStatusTitle(call.type),
                         detail: call.caller.isEmpty ? call.applicationName : call.caller) {
                    if call.actions.isEmpty {
                        Text(L10n.text("panel.call.usePhone", fallback: "Use the phone to control this call."))
                            .font(BrandFont.body(12))
                    } else {
                        ForEach(visibleCallActions(call.actions, limit: 3)) { action in
                            Button(action.title) { actions.callAction(action) }
                                .buttonStyle(PillButtonStyle(kind: callKind(action.title), height: 28))
                        }
                    }
                }
                .id("call")
                .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
            }
            if let code = model.code {
                LiveCard(symbol: "key.fill", tint: .blue,
                         title: String(format: L10n.text("codes.card.title", fallback: "Code %@"), code.code),
                         detail: code.copiedLine(now: model.now)
                             ?? String(format: L10n.text("codes.card.detail", fallback: "From %1$@ on %2$@"), code.sender, code.deviceName)) {
                    Button(L10n.text("action.dismiss", fallback: "Dismiss"), action: actions.dismissCode)
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                    Button(L10n.text("codes.copy", fallback: "Copy code")) { actions.copyCode(code.id) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
                .id("code")
                .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
            }
            if let state = model.codeModel {
                LiveCard(symbol: CodeModelPanelText.symbol(state).name, tint: CodeModelPanelText.symbol(state).tint,
                         title: CodeModelPanelText.title(state), detail: CodeModelPanelText.detail(state),
                         modelProgress: state.download.flatMap { $0.showsBar ? .some($0.state == .verifying ? nil : $0.fraction) : nil }) {
                    CodeModelPanelButtons(state: state, actions: actions.codeModel)
                }
                .accessibilityElement(children: .contain)
                .id("codeModel")
                .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
            }
            if let ringing = model.ringing {
                LiveCard(symbol: "location.fill", tint: .purple, title: ringingTitle(ringing),
                         detail: L10n.text("panel.find.detail", fallback: "Find device")) {
                    Button(L10n.text("action.stop", fallback: "Stop"), action: actions.stopFinding)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
                .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
            }
            if let link = model.receivedLink {
                LiveCard(symbol: "link", tint: .blue,
                         title: String(format: L10n.text("panel.link.title", fallback: "Link from %@"), model.connectedName ?? ""),
                         detail: link) {
                    Button(L10n.text("action.dismiss", fallback: "Dismiss"), action: actions.dismissLink)
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                    Button(L10n.text("action.open", fallback: "Open"), action: actions.openLink)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
                .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
            }
            if model.update.showsInPanel {
                let visual = updateFlowSymbol(model.update)
                LiveCard(symbol: visual.symbol, tint: visual.tint,
                         title: UpdateFlowText.title(model.update, currentVersion: model.appVersion),
                         detail: UpdateFlowText.detail(model.update),
                         progress: model.update.isBusy ? .some(model.update.progress) : nil) {
                    UpdateFlowButtons(flow: model.update, actions: actions.update)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(UpdateFlowText.line(model.update, currentVersion: model.appVersion))
                .id("update")
                .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
            }
            ForEach(model.transfers) { transfer in
                if let folder = transfer.folder {
                    FolderLiveCard(transfer: transfer, folder: folder, now: model.now, expandedAtFirst: model.expandedTransfers.contains(transfer.id),
                                   showsCancelAll: transfer.id == model.transfers.first?.id && showsCancelAll(model.transfers), actions: actions)
                        .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
                } else {
                LiveCard(symbol: transfer.queued ? "clock" : transfer.active ? "arrow.up.arrow.down" : "exclamationmark.arrow.triangle.2.circlepath",
                         tint: transfer.active ? .green : .neutral,
                         title: transfer.name, detail: transferDetail(transfer)) {
                    if transfer.id == model.transfers.first?.id, showsCancelAll(model.transfers) {
                        Button(L10n.text("transfers.cancelAll", fallback: "Cancel All"), action: actions.cancelAllTransfers)
                            .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                    } else {
                        Button(L10n.text("panel.transfer.details", fallback: "Details"), action: actions.showTransfers)
                            .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                    }
                    if transfer.active {
                        Button(L10n.text("action.cancel", fallback: "Cancel")) { actions.cancelTransfer(transfer.id) }
                            .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                    } else if transfer.retryable {
                        Button(L10n.text("action.retry", fallback: "Retry")) { actions.retryTransfer(transfer.id) }
                            .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                    }
                }
                .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, hasCards ? 12 : 0)
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: cardKeys)
    }

    private var hasCards: Bool { !cardKeys.isEmpty }

    private var cardKeys: [String] {
        var keys: [String] = []
        if model.call != nil { keys.append("call") }
        if model.code != nil { keys.append("code") }
        if model.codeModel != nil { keys.append("codeModel") }
        if model.ringing != nil { keys.append("ringing") }
        if model.receivedLink != nil { keys.append("link") }
        if model.update.showsInPanel { keys.append("update") }
        keys += model.transfers.map { "transfer:\($0.id)" }
        return keys
    }

    private func ringingTitle(_ ringing: RingingState) -> String {
        switch ringing {
        case let .mac(name): String(format: L10n.text("panel.find.mac", fallback: "%@ is ringing this Mac"), name)
        case let .phone(name): String(format: L10n.text("panel.find.phone", fallback: "Ringing %@"), name)
        }
    }

    private func callKind(_ title: String) -> PillKind {
        switch callActionRole(title) {
        case .answer: .good
        case .end: .danger
        case .other: .neutral
        }
    }
}

/// A folder's live card: "Photos → OnePlus 11 › Pictures/Trip", a bar by bytes, "37 of 124 files · 812 MB of
/// 2.3 GB · 12 MB/s · 2 min left", and a disclosure for the current file, failures and the last names.
private struct FolderLiveCard: View {
    let transfer: FileTransferRow
    let folder: FolderRowSummary
    let now: Date
    let expandedAtFirst: Bool
    let showsCancelAll: Bool
    let actions: PanelActions
    @State private var expanded: Bool?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    private var isExpanded: Bool { expanded ?? expandedAtFirst }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: symbol, tint: tint, size: 28, corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FolderText.title(folder))
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(c.on)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    status
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { expanded = !isExpanded } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(c.on2)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("folders.details.toggle", fallback: "Show files"))
            }
            if showsBar {
                UpdateProgressBar(progress: folder.progress.bytesTotal > 0 ? Double(folder.progress.bytesDone) / Double(folder.progress.bytesTotal) : (folder.hashing ?? 0))
                    .padding(.leading, 38)
            }
            if isExpanded {
                FolderExpandedDetails(progress: folder.progress, maxHeight: 110)
                    .padding(.leading, 38)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if showsCancelAll {
                    Button(L10n.text("transfers.cancelAll", fallback: "Cancel All"), action: actions.cancelAllTransfers)
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                } else {
                    Button(L10n.text("panel.transfer.details", fallback: "Details"), action: actions.showTransfers)
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                }
                if transfer.active {
                    Button(L10n.text("action.cancel", fallback: "Cancel")) { actions.cancelTransfer(transfer.id) }
                        .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                } else {
                    if folder.canSendAgain {
                        Button(L10n.text("folders.action.sendAgain", fallback: "Send Again")) { actions.retryTransfer(transfer.id) }
                            .buttonStyle(PillButtonStyle(kind: folder.canResume ? .neutral : .tonal, height: 28))
                    }
                    if folder.canResume {
                        Button(L10n.text("folders.action.resume", fallback: "Resume")) { actions.resumeTransfer(transfer.id) }
                            .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                    }
                }
            }
            .foregroundStyle(c.on2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.tb, lineWidth: 1))
    }

    @ViewBuilder private var status: some View {
        if snapshot || !folder.progress.phase.hasCountdown {
            statusText(now: snapshot ? now : Date())
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in statusText(now: context.date) }
        }
    }

    private func statusText(now: Date) -> some View {
        Text(FolderText.status(folder, now: now))
            .font(BrandFont.body(12).monospacedDigit())
            .foregroundStyle(c.on2)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var showsBar: Bool {
        switch folder.state {
        case .preparing: folder.hashing != nil
        case .running: folder.progress.phase == .sending || folder.progress.phase == .completing
        default: false
        }
    }

    private var symbol: String {
        switch folder.state {
        case .queued: "clock"
        case .done: "checkmark.circle"
        case .interrupted, .incomplete: "exclamationmark.arrow.triangle.2.circlepath"
        default: "folder"
        }
    }

    private var tint: TileTint {
        switch folder.state {
        case .interrupted, .incomplete: .neutral
        case .queued: .blue
        default: .green
        }
    }
}

extension FolderPhase {
    var hasCountdown: Bool {
        switch self {
        case .waiting, .asking: true
        default: false
        }
    }
}

private struct LiveCard<Buttons: View>: View {
    let symbol: String
    let tint: TileTint
    let title: String
    let detail: String?
    /// Outer nil: no bar. Inner nil: a step of unknown length.
    var progress: Double?? = nil
    /// The code model's bar (transform-only fill); same meaning as `progress`.
    var modelProgress: Double?? = nil
    @ViewBuilder let buttons: Buttons
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: symbol, tint: tint, size: 28, corner: 8)
                CardText(title: title, detail: detail)
            }
            if let progress {
                UpdateProgressBar(progress: progress)
                    .padding(.leading, 38)
            }
            if let modelProgress {
                CodeModelProgressBar(fraction: modelProgress)
                    .padding(.leading, 38)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                buttons
            }
            .foregroundStyle(c.on2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.tb, lineWidth: 1))
    }
}

// MARK: - Stream

private struct StreamList: View {
    let rows: [StreamRow]
    let showPreviews: Bool
    let now: Date
    let hasLiveCards: Bool
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    static let headerHeight: CGFloat = 36
    static let rowHeight: CGFloat = 44

    var body: some View {
        if rows.isEmpty {
            if !hasLiveCards { empty }
        } else {
            BoundedScroll {
                ForEach(rows) { row in
                    switch row {
                    case let .header(section):
                        Text(ActivityText.section(section).uppercased())
                            .font(BrandFont.body(11, .semibold))
                            .kerning(0.55)
                            .foregroundStyle(c.on2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .frame(height: Self.headerHeight)
                            .accessibilityAddTraits(.isHeader)
                    case let .item(item, section):
                        StreamRowView(item: item, section: section, highlighted: item.id == newestID, showPreviews: showPreviews, now: now)
                            .padding(.horizontal, 8)
                            .transition(BrandMotion.arrival(reduce: reduce).animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce)))
                    }
                }
            }
            .frame(height: height, alignment: .top)
            .clipped()
            .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: rows.map(\.id))
        }
    }

    private var newestID: Int64? {
        for row in rows { if case let .item(item, _) = row { return item.id } }
        return nil
    }

    /// Fixed row heights make the height exact, so the panel never jumps while it lays out.
    private var height: CGFloat {
        let content = rows.reduce(CGFloat(0)) { total, row in
            if case .header = row { return total + Self.headerHeight }
            return total + Self.rowHeight
        }
        return min(content, StreamPanelView.maximumStreamHeight)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("stream.empty.title", fallback: "Nothing has moved yet"))
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on)
            Text(L10n.text("stream.empty.body", fallback: "Send your clipboard below, or drop a file on it. What moves between your devices shows here for 7 days."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
}

/// Icon and tint for a stream item.
func activityVisual(_ kind: ActivityKind) -> (symbol: String, tint: TileTint) {
    switch kind {
    case .clipboardSent, .clipboardReceived: ("doc.on.clipboard", .blue)
    case .fileSent, .fileReceived: ("doc.text", .green)
    case .fileFailed: ("exclamationmark.circle", .neutral)
    case .linkSent, .linkReceived: ("link", .blue)
    case .notificationsShown: ("bell", .purple)
    case .callShown, .callStarted: ("phone", .green)
    case .pingSent, .pingReceived: ("wave.3.right", .blue)
    case .findMac, .findPhone: ("location", .blue)
    case .paired: ("laptopcomputer.and.iphone", .purple)
    case .clipOfferSent, .clipOfferReceived, .clipPasted: ("doc.on.clipboard", .blue)
    case .clipPasteFailed: ("exclamationmark.circle", .neutral)
    case .folderSent, .folderReceived: ("folder", .green)
    case .folderIncomplete: ("folder.badge.questionmark", .neutral)
    }
}

/// Clipboard offers take their icon from what was copied.
func activityVisual(_ item: ActivityItem) -> (symbol: String, tint: TileTint) {
    guard item.kind.isClipOffer, item.kind != .clipPasteFailed else { return activityVisual(item.kind) }
    switch item.content {
    case "image": return ("photo", .blue)
    case "file": return ("doc", .green)
    default: return ("doc.on.clipboard", .blue)
    }
}

private struct StreamRowView: View {
    let item: ActivityItem
    let section: DaySection
    let highlighted: Bool
    let showPreviews: Bool
    let now: Date
    @Environment(\.brand) private var c

    var body: some View {
        let visual = activityVisual(item)
        let detail = ActivityText.detail(item, showPreviews: showPreviews)
        HStack(spacing: 10) {
            IconTile(symbol: visual.symbol, tint: visual.tint, size: 28, corner: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(ActivityText.title(item, showPreviews: showPreviews))
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(BrandFont.body(11.5))
                        .foregroundStyle(item.sensitive || item.preview == nil || !showPreviews ? c.on2 : c.on.opacity(0.82))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(ActivityText.time(item.at, now: now, section: section))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: StreamList.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(highlighted ? c.s2 : Color.clear))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Quick actions

/// File, Link, Call, Ping, Find, Media as one connected button group.
private struct QuickActionBar: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View {
        let ringing = model.ringing != nil
        HStack(spacing: 2) {
            PopUpMenuButton(items: {
                [
                    PopUpMenuItem(title: L10n.text("quick.file.choose", fallback: "Send Files or Folders\u{2026}"), action: actions.chooseFile),
                    PopUpMenuItem(title: L10n.text("drop.open", fallback: "Open file drop window"), action: actions.openDropWindow),
                    .separator,
                    PopUpMenuItem(title: L10n.text("quick.file.transfers", fallback: "Show File Transfers"), enabled: model.hasTransferHistory || !model.transfers.isEmpty, action: actions.showTransfers),
                ]
            }) {
                QuickActionLabel(symbol: "paperclip", title: L10n.text("quick.file", fallback: "File"), position: .first)
            }
            .disabled(!model.available.contains(.files))
            .help(L10n.text("quick.file.help", fallback: "Send a file"))

            quick("link", L10n.text("quick.link", fallback: "Link"), .links, help: L10n.text("quick.link.help", fallback: "Open the copied link on the phone"), action: actions.sendLink)
            quick("phone.arrow.up.right", L10n.text("quick.call", fallback: "Call"), .calls, help: L10n.text("quick.call.help", fallback: "Call the phone number currently in the clipboard"), action: actions.call)
            quick("wave.3.right", L10n.text("quick.ping", fallback: "Ping"), .ping, help: L10n.text("quick.ping.help", fallback: "Play a short alert on the phone"), action: actions.ping)
            quick(ringing ? "stop.circle" : "location", ringing ? L10n.text("action.stop", fallback: "Stop") : L10n.text("quick.find", fallback: "Find"),
                  .findDevice, help: L10n.text("quick.find.help", fallback: "Ring the phone until you stop it"), enabled: ringing || model.available.contains(.findDevice),
                  action: ringing ? actions.stopFinding : actions.find)

            PopUpMenuButton(items: {
                var items = MediaPlayer.allCases.map { player in
                    PopUpMenuItem(title: player.title, checked: player == model.mediaPlayer) { actions.setPlayer(player) }
                }
                items.append(.separator)
                items.append(PopUpMenuItem(title: L10n.text("quick.media.refresh", fallback: "Refresh Player"), enabled: model.mediaPlayer != .off, action: actions.refreshMedia))
                return items
            }) {
                QuickActionLabel(symbol: "music.note", title: L10n.text("quick.media", fallback: "Media"), position: .last)
            }
            .disabled(!model.available.contains(.media))
            .help(model.mediaDetail.isEmpty ? L10n.text("quick.media.help", fallback: "Choose the Mac player the phone controls") : model.mediaDetail)
        }
    }

    private func quick(
        _ symbol: String,
        _ title: String,
        _ feature: BridgeyFeature,
        help: String,
        enabled: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            QuickActionLabel(symbol: symbol, title: title, position: .middle)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!(enabled ?? model.available.contains(feature)))
        .help(help)
    }
}

private enum GroupPosition { case first, middle, last }

private struct QuickActionLabel: View {
    let symbol: String
    let title: String
    let position: GroupPosition
    @Environment(\.brand) private var c
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(c.tbi)
            Text(title)
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(c.on)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(CornerShape(radii: radii).fill(c.s2))
        .contentShape(CornerShape(radii: radii))
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .combine)
    }

    private var radii: CornerShape.Radii {
        switch position {
        case .first: .init(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 6)
        case .middle: .init(topLeading: 6, bottomLeading: 6, bottomTrailing: 6, topTrailing: 6)
        case .last: .init(topLeading: 6, bottomLeading: 6, bottomTrailing: 20, topTrailing: 20)
        }
    }
}

/// A rectangle with its own radius per corner (UnevenRoundedRectangle needs macOS 14).
struct CornerShape: Shape {
    struct Radii {
        var topLeading: CGFloat
        var bottomLeading: CGFloat
        var bottomTrailing: CGFloat
        var topTrailing: CGFloat
    }

    let radii: Radii

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let tl = min(radii.topLeading, limit), tr = min(radii.topTrailing, limit)
        let bl = min(radii.bottomLeading, limit), br = min(radii.bottomTrailing, limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }
}

// MARK: - Send bar

/// The main action: send what is on the clipboard, or drop a file on the bar.
private struct SendBar: View {
    let model: PanelModel
    let actions: PanelActions
    @State private var targeted = false
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(BrandFont.body(11))
                    .foregroundStyle(c.on2)
                    .lineLimit(1)
                Text(line)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(model.clipboardLine == nil || model.clipboardHidden ? c.on2 : c.on)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: actions.sendClipboard) {
                Circle()
                    .fill(BrandPalette.aurora)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(BrandPalette.midnight)
                    )
                    .opacity(canSendClipboard ? 1 : 0.4)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canSendClipboard)
            .help(L10n.text("send.help", fallback: "Send the clipboard"))
            .accessibilityLabel(L10n.text("send.label", fallback: "Send clipboard"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(Capsule().fill(c.s2))
        .overlay(Capsule().strokeBorder(targeted ? c.pri : Color.clear, lineWidth: 2))
        .modifier(FileDrop(enabled: !snapshot) { urls in
            guard canDrop, !urls.isEmpty else { return false }
            return actions.dropFiles(urls)
        } targeted: { targeted = $0 && canDrop })
    }

    private var canSendClipboard: Bool { model.isConnected && model.available.contains(.clipboard) && model.clipboardLine != nil }
    private var canDrop: Bool { model.isConnected && model.available.contains(.files) }

    private var label: String {
        if let status = model.status { return status }
        guard let name = model.connectedName else {
            return model.rings.contains(where: \.trusted)
                ? L10n.text("send.connect", fallback: "Connect a device to send")
                : L10n.text("send.pair", fallback: "Pair a device to send")
        }
        if !model.available.contains(.clipboard) && !model.available.contains(.files) {
            return String(format: L10n.text("send.off", fallback: "Sending is off for %@"), name)
        }
        if model.autoClipboard {
            return model.available.contains(.files)
                ? L10n.text("send.hint.auto", fallback: "Copies send automatically, or drop a file")
                : L10n.text("send.hint.autoOnly", fallback: "Copies send automatically")
        }
        return model.available.contains(.files)
            ? L10n.text("send.hint", fallback: "Clipboard, or drop a file")
            : L10n.text("send.hint.clipboard", fallback: "Clipboard")
    }

    private var line: String {
        if model.clipboardHidden { return L10n.text("send.hidden", fallback: "Hidden (password)") }
        return model.clipboardLine ?? L10n.text("send.empty", fallback: "Nothing copied yet")
    }
}

/// Accepts dropped files; left out while ImageRenderer draws (it cannot draw drop targets).
private struct FileDrop: ViewModifier {
    let enabled: Bool
    let perform: ([URL]) -> Bool
    let targeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in perform(urls) } isTargeted: { targeted($0) }
        } else {
            content
        }
    }
}

// MARK: - Live panel

/// Builds the panel from the running app's objects.
struct BridgeyPanel: View {
    @ObservedObject var discovery: BonjourDiscovery
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var settings: BridgeySettings
    @ObservedObject var activity: ActivityLog
    @ObservedObject var quickActions: QuickActions
    @ObservedObject var media: MediaController
    @ObservedObject var updater: AppUpdater
    @ObservedObject var codeModel: CodeModelStore
    @ObservedObject var setupCenter = SetupCenter.shared
    let onOpenSettings: () -> Void
    @State private var clipboard = PasteboardPreview()
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(discovery: BonjourDiscovery, pairing: PairingCoordinator, settings: BridgeySettings, updater: AppUpdater, onOpenSettings: @escaping () -> Void) {
        self.updater = updater
        self.discovery = discovery
        self.pairing = pairing
        self.settings = settings
        activity = pairing.activity
        quickActions = pairing.quickActions
        media = pairing.mediaController
        codeModel = pairing.codeModel
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        MenuBarPanelSurface {
            BrandRoot(reduceMotion: settings.reduceMotion) {
                StreamPanelView(model: model, actions: actions)
            }
        }
        .onAppear {
            pairing.refreshNotificationAuthorization()
            activity.prune()
            clipboard = PasteboardPreview.current()
            now = Date()
        }
        .onReceive(ticker) { date in
            let latest = PasteboardPreview.current(previous: clipboard)
            if latest != clipboard { clipboard = latest }
            // A copied code counts down "Clears in 42 s" every second; otherwise once a minute is enough.
            let countingDown = pairing.liveCode?.copiedLine(now: date) != nil || pairing.liveCode?.copiedLine(now: now) != nil
            if countingDown || Calendar.current.component(.minute, from: date) != Calendar.current.component(.minute, from: now) { now = date }
        }
    }

    private var model: PanelModel {
        var model = PanelModel()
        model.onboardingDone = settings.hasCompletedOnboarding
        model.showsSetupReview = setupCenter.showsReviewBanner
        model.state = pairing.state
        model.pairingFlow = pairing.pairingFlow
        model.rings = deviceRings(trusted: pairing.trustedDevices, peers: discovery.peers, connected: pairing.connectedPhones,
                                  pairing: pairing.pairingFlow, reconnecting: pairing.reconnectStates)
        model.rediscovering = pairing.isRediscovering
        model.battery = pairing.isFeatureAvailable(.battery) ? pairing.remoteBattery : nil
        model.batteries = Dictionary(pairing.connectedPhones.compactMap { phone in
            pairing.isFeatureAvailable(.battery, for: phone.id) ? phone.state.battery.map { (phone.id, $0) } : nil
        }, uniquingKeysWith: { $1 })
        if case let .connected(deviceID, _) = pairing.state { model.targetDeviceID = deviceID }
        model.transfers = liveTransfers(pairing.fileTransfers)
        model.hasTransferHistory = !pairing.fileTransfers.isEmpty
        model.fileTransferActive = pairing.fileTransferActive
        if case let .connected(deviceID, _) = pairing.state {
            model.autoClipboard = pairing.isFeatureAvailable(.clipboard) && settings.isAutoClipboardEnabled(for: deviceID)
        }
        model.receivedLink = quickActions.receivedLink
        if case let .connected(_, name) = pairing.state {
            if pairing.macRinging { model.ringing = .mac(name) } else if pairing.androidRinging { model.ringing = .phone(name) }
        }
        model.call = pairing.remoteCall
        model.code = pairing.liveCode
        model.codeModel = CodeModelPanelState.shown(download: codeModel.download, finished: codeModel.justFinished)
        model.rows = streamRows(activity.items, now: now)
        model.showPreviews = settings.showActivityPreviews
        model.now = now
        model.available = Set(BridgeyFeature.allCases.filter { pairing.isFeatureAvailable($0) })
        model.clipboardLine = clipboard.line
        model.clipboardHidden = clipboard.hidden
        model.status = pairing.rediscoverStatus ?? pairing.clipboardStatus ?? pairing.callStatus ?? pairing.pingStatus ?? quickActions.status ?? pairing.fileTransferStatus.flatMap { pairing.fileTransferActive ? nil : $0 }
        if pairing.isFeatureAvailable(.notifications) && !pairing.notificationsAuthorized {
            model.notificationPrompt = pairing.notificationPermissionDetermined ? .openSettings : .request
        }
        model.mediaPlayer = media.player
        model.mediaDetail = media.snapshot.detail
        model.update = updater.flow
        model.appVersion = updater.shortVersion
        model.pairingStoreIssue = pairing.pairingStoreIssue
        return model
    }

    private var actions: PanelActions {
        var actions = PanelActions()
        actions.openSettings = onOpenSettings
        actions.quit = { NSApplication.shared.terminate(nil) }
        // Get started on the first-run card opens setup (SetupWindow.swift), which completes it.
        actions.completeOnboarding = { setupCenter.startSetup() }
        actions.openSetupReview = { setupCenter.openReviewBanner() }
        actions.dismissSetupReview = { setupCenter.dismissReviewBanner() }
        actions.connect = { ring in
            guard let host = ring.peer?.host, let port = ring.peer?.port else { return }
            pairing.pair(host: host, port: port, peerName: ring.name)
        }
        actions.disconnect = { pairing.dismiss() }
        actions.disconnectDevice = { pairing.disconnect(deviceID: $0) }
        actions.selectDevice = { pairing.selectDevice($0) }
        actions.confirm = { pairing.confirm() }
        actions.cancel = { pairing.cancel() }
        actions.openLocalNetworkSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                NSWorkspace.shared.open(url)
            }
        }
        actions.sendClipboard = { pairing.sendClipboard() }
        actions.dropFiles = { pairing.sendDroppedFiles($0) }
        actions.chooseFile = { pairing.chooseAndSendFile() }
        actions.openDropWindow = { pairing.showFileDropWindow() }
        actions.showTransfers = { pairing.showFileTransferWindow() }
        actions.sendLink = { quickActions.sendClipboardLink() }
        actions.call = { pairing.sendCallFromClipboard() }
        actions.ping = { pairing.sendPing() }
        actions.find = { pairing.findAndroid() }
        actions.stopFinding = { pairing.stopFinding() }
        actions.setPlayer = { media.player = $0 }
        actions.refreshMedia = { media.refresh() }
        actions.openLink = { quickActions.openLink() }
        actions.dismissLink = { quickActions.dismissLink() }
        actions.cancelTransfer = { pairing.cancelFileTransfer(id: $0) }
        actions.cancelAllTransfers = { pairing.cancelFileTransfer() }
        actions.retryTransfer = { pairing.retryFileTransfer(id: $0) }
        actions.resumeTransfer = { pairing.resumeFolderTransfer(id: $0) }
        actions.callAction = { pairing.performRemoteCallAction($0) }
        actions.copyCode = { pairing.copyCode(reference: $0) }
        actions.dismissCode = { pairing.dismissLiveCode() }
        actions.codeModel = CodeModelPanelActions(
            pause: { codeModel.pause() }, resume: { codeModel.resume() }, cancel: { codeModel.cancel() },
            retry: { codeModel.retry() }, dismiss: { codeModel.dismissFinished() }
        )
        actions.enableNotifications = { pairing.enableNotifications() }
        actions.retryDevice = { pairing.retryNow(deviceID: $0) }
        actions.lookForDevices = { pairing.lookForDevices() }
        actions.update = updater.flowActions
        actions.retryPairingStore = { pairing.retryPairingStore() }
        return actions
    }
}

/// What the send bar shows: the first line of the clipboard, never stored.
struct PasteboardPreview: Equatable {
    var changeCount = -1
    var line: String?
    var hidden = false

    @MainActor static func current(previous: PasteboardPreview? = nil) -> PasteboardPreview {
        let pasteboard = NSPasteboard.general
        if let previous, previous.changeCount == pasteboard.changeCount { return previous }
        // A clipboard offer from the phone: describe it; reading it would fetch it.
        if ClipboardOwnWrite.matches(pasteboard.changeCount) {
            return PasteboardPreview(changeCount: pasteboard.changeCount, line: ClipboardOwnWrite.description(), hidden: false)
        }
        let types = (pasteboard.types ?? []).map(\.rawValue)
        if clipboardTypesAreSecret(types) {
            return PasteboardPreview(changeCount: pasteboard.changeCount, line: "", hidden: true)
        }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            let names = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:))?.lastPathComponent }
            if names.count > 1 {
                let line = String.localizedStringWithFormat(L10n.text("send.own.files", fallback: "%d files"), names.count)
                return PasteboardPreview(changeCount: pasteboard.changeCount, line: line, hidden: false)
            }
            if let name = names.first {
                return PasteboardPreview(changeCount: pasteboard.changeCount, line: ActivityHistory.preview(name), hidden: false)
            }
        }
        let text = pasteboard.string(forType: .string).map { String($0.prefix(2_000)) }
        if text == nil, ClipboardContentReader.imageTypes.contains(where: { types.contains($0.type.rawValue) }) {
            return PasteboardPreview(changeCount: pasteboard.changeCount, line: L10n.text("send.own.image", fallback: "Image"), hidden: false)
        }
        return PasteboardPreview(changeCount: pasteboard.changeCount, line: ActivityHistory.preview(text), hidden: false)
    }
}
