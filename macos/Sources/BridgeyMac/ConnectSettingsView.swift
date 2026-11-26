import SwiftUI

/// Connect away from home: the state line under the switch.
func connectStatusText(_ display: ConnectDisplay, enabled: Bool) -> String {
    if !display.available { return L10n.text("connect.status.unavailable", fallback: "Not available in this build") }
    if !enabled { return L10n.text("connect.status.off", fallback: "Off") }
    if !display.running { return L10n.text("connect.status.starting", fallback: "Starting\u{2026}") }
    switch display.presence {
    case "online": return L10n.text("connect.status.online", fallback: "On. Your devices can reach this Mac from other networks.")
    case "disabled": return L10n.text("connect.status.noService", fallback: "On, for the same Wi-Fi and private networks only. This build has no Round Robin service.")
    case "unreachable": return L10n.text("connect.status.unreachable", fallback: "On, but the Round Robin service can't be reached. Same Wi-Fi and private networks still work; Bridgey keeps trying.")
    default: return L10n.text("connect.status.connecting", fallback: "On. Reaching the Round Robin service\u{2026}")
    }
}

/// Devices > Connect away from home (docs/connect-anywhere.md, section 12.1): the switch, its status, then in More
/// options the identity reset and, in test builds, the service address and relay only.
struct ConnectAwayCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var controlURL = ""

    var body: some View {
        FeatureCard(card: .away,
                    detail: L10n.text("connect.detail", fallback: "Reach your paired devices from any network. They connect directly when they can, or through a Round Robin relay that only sees encrypted data. No account needed."),
                    toggle: CardToggle(title: SettingsPane.away.title, isOn: model.connectAway && model.connect.available,
                                       enabled: model.connect.available, set: actions.setConnectAway),
                    footnote: L10n.text("connect.privacy", fallback: "Relays and the Round Robin service never see names, files or messages. Turning this off stops Bridgey\u{2019}s internet connection service. Same Wi-Fi and independently connected Tailscale devices can still connect.")) {
            SettingsRow(title: L10n.text("connect.status", fallback: "Status"), subtitle: connectStatusText(model.connect, enabled: model.connectAway)) { EmptyView() }
        } more: {
            SettingsRow(title: L10n.text("connect.reset", fallback: "Reset away-from-home identity"),
                        subtitle: L10n.text("connect.reset.detail", fallback: "A new key for the Round Robin service, and new secrets with your devices. Pairings stay.")) {
                Button(L10n.text("connect.reset.action", fallback: "Reset")) { actions.resetConnectIdentity() }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                    .disabled(!model.connect.running)
            }
            if model.connect.debug {
                SettingsCard(title: L10n.text("connect.debug", fallback: "Testing")) {
                    SettingsRow(title: L10n.text("connect.debug.url", fallback: "Service address"), subtitle: nil, divider: false) {
                        TextField("wss://", text: $controlURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .onSubmit { actions.setConnectControlURL(controlURL) }
                    }
                    SettingsToggle(title: L10n.text("connect.debug.relayOnly", fallback: "Relay only"),
                                   subtitle: L10n.text("connect.debug.relayOnly.detail", fallback: "Blocks every other route, to test the relay"),
                                   isOn: model.connect.relayOnly, set: actions.setConnectRelayOnly)
                }
                .onAppear { controlURL = model.connect.controlURL }
            }
        }
    }
}

/// Status is read from the official client, never inferred from installation or a generic VPN.
func tailscaleStatusText(_ display: TailscaleSetupDisplay) -> String {
    switch display.state {
    case .checking: return L10n.text("tailscale.status.checking", fallback: "Checking Tailscale…")
    case .notInstalled: return L10n.text("tailscale.status.notInstalled", fallback: "Set up Tailscale")
    case .needsLogin: return L10n.text("tailscale.status.needsLogin", fallback: "Sign in to Tailscale")
    case .stopped: return L10n.text("tailscale.status.stopped", fallback: "Tailscale is disconnected")
    case .needsApproval: return L10n.text("tailscale.status.needsApproval", fallback: "Waiting for device approval")
    case .starting: return L10n.text("tailscale.status.starting", fallback: "Tailscale is connecting…")
    case .running: return L10n.text("tailscale.status.running", fallback: "Tailscale is connected")
    case .unavailable: return L10n.text("tailscale.status.unavailable", fallback: "Couldn’t check Tailscale")
    }
}

func tailscaleSetupDetail(_ display: TailscaleSetupDisplay) -> String {
    if display.hasCommandLine && !display.hasApplication {
        return L10n.text("tailscale.detail.cli", fallback: "A command-line installation is detected. Connect it to your Tailscale network, then check again. Bridgey does not change its settings.")
    }
    switch display.state {
    case .checking: return L10n.text("tailscale.detail.checking", fallback: "Checking the official Tailscale app on this Mac.")
    case .notInstalled: return L10n.text("tailscale.detail.notInstalled", fallback: "Optional: install the official Tailscale app on both devices and sign in to the same Tailscale network. Bridgey also works over Wi-Fi and Connect away from home.")
    case .needsLogin: return L10n.text("tailscale.detail.needsLogin", fallback: "Open Tailscale and sign in. Use the same Tailscale network on your other device, then return here.")
    case .stopped: return L10n.text("tailscale.detail.stopped", fallback: "Open Tailscale and connect. Keep it connected on both devices, then return here.")
    case .needsApproval: return L10n.text("tailscale.detail.needsApproval", fallback: "Your Tailscale administrator needs to approve this Mac before it can connect.")
    case .starting: return L10n.text("tailscale.detail.starting", fallback: "Tailscale is starting. Check again in a moment; Wi-Fi connections keep working.")
    case .running: return L10n.text("tailscale.detail.running", fallback: "Bridgey looks for devices on this Tailscale network automatically. Open Bridgey on the other device and allow pairing, then compare the codes.")
    case .unavailable: return L10n.text("tailscale.detail.unavailable", fallback: "Open Tailscale to check its connection, then try again. Bridgey has not changed your Tailscale settings.")
    }
}

struct TailscaleSetupCard: View {
    let display: TailscaleSetupDisplay
    let actions: SettingsActions
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduceMotion

    var body: some View {
        FeatureCard(card: .tailscale, headerAnchor: "Tailscale") {
            VStack(alignment: .leading, spacing: 10) {
                Text(tailscaleStatusText(display))
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on)
                    .accessibilityIdentifier("tailscale-status")
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: display.state)
                Text(tailscaleSetupDetail(display))
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 90, alignment: .topLeading)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: display.state)
                HStack(spacing: 8) {
                    Button(primaryTitle, action: actions.openTailscaleSetup)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                        .disabled(display.state == .checking)
                        .accessibilityIdentifier("tailscale-open")
                    Button(L10n.text("tailscale.action.check", fallback: "Check again"), action: actions.checkTailscale)
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                        .disabled(display.refreshing)
                        .accessibilityIdentifier("tailscale-check")
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
        }
    }

    private var primaryTitle: String {
        if display.hasApplication { return L10n.text("tailscale.action.open", fallback: "Open Tailscale") }
        if display.hasCommandLine { return L10n.text("tailscale.action.help", fallback: "Setup guide") }
        return L10n.text("tailscale.action.install", fallback: "Get Tailscale")
    }
}

/// "Same Wi-Fi", "Private network", "Direct" or "Relay (Mumbai)" next to a connected device.
struct RouteChip: View {
    let text: String
    @Environment(\.brand) private var c

    var body: some View {
        Text(text)
            .font(BrandFont.body(11, .semibold))
            .foregroundStyle(c.tbi)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(c.tb))
            .fixedSize()
            .accessibilityLabel(String(format: L10n.text("connect.route.accessibility", fallback: "Connected through %@"), text))
    }
}
