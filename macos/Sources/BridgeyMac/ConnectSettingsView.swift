import SwiftUI

/// Connect away from home: the state line under the switch.
func connectStatusText(_ display: ConnectDisplay, enabled: Bool) -> String {
    if !display.available { return L10n.text("connect.status.unavailable", fallback: "Not available in this build") }
    if !enabled { return L10n.text("connect.status.off", fallback: "Off") }
    if !display.running { return L10n.text("connect.status.starting", fallback: "Starting\u{2026}") }
    switch display.presence {
    case "online": return L10n.text("connect.status.online", fallback: "On. Your devices can reach this Mac from other networks.")
    case "disabled": return L10n.text("connect.status.noService", fallback: "On, for the same Wi-Fi and private networks only. This build has no Round Robin service.")
    default: return L10n.text("connect.status.connecting", fallback: "On. Reaching the Round Robin service\u{2026}")
    }
}

/// Devices: the row that opens Connect away from home.
struct ConnectAwayCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            SettingsRow(title: SettingsPane.away.title, subtitle: connectStatusText(model.connect, enabled: model.connectAway), divider: false) {
                Button(L10n.text("connect.open", fallback: "Open")) { actions.setup.showPane(.away) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
        }
    }
}

/// Devices > Connect away from home (docs/connect-anywhere.md, section 12.1).
struct ConnectAwayPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var controlURL = ""
    @Environment(\.brand) private var c

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: SettingsPane.away.title,
                subtitle: L10n.text("connect.detail", fallback: "Reach your paired devices from any network. They connect directly when they can, or through a Round Robin relay that only sees encrypted data. No account needed."),
                divider: false,
                isOn: model.connectAway && model.connect.available,
                set: actions.setConnectAway
            )
            .disabled(!model.connect.available)
            SettingsRow(title: L10n.text("connect.status", fallback: "Status"), subtitle: connectStatusText(model.connect, enabled: model.connectAway)) { EmptyView() }
            SettingsRow(title: L10n.text("connect.reset", fallback: "Reset away-from-home identity"),
                        subtitle: L10n.text("connect.reset.detail", fallback: "A new key for the Round Robin service, and new secrets with your devices. Pairings stay.")) {
                Button(L10n.text("connect.reset.action", fallback: "Reset")) { actions.resetConnectIdentity() }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                    .disabled(!model.connect.running)
            }
        }
        Text(L10n.text("connect.privacy", fallback: "Relays and the Round Robin service never see names, files or messages. Turning this off stops every route away from home; the same Wi-Fi keeps working."))
            .font(BrandFont.body(12))
            .foregroundStyle(c.on2)
            .fixedSize(horizontal: false, vertical: true)
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
