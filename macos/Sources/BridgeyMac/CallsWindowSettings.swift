import SwiftUI

/*
 * Settings > Calls > Calls window: the switch, the phones this Mac may call through (each off until
 * allowed), the SIM to call from, whether WhatsApp calls show, and how many recent calls the window
 * lists. Drawn from `SettingsModel`, so the screenshots render it from sample state.
 */

/// The Calls window's settings this pane reads (filled by LiveSettingsView).
struct CallsWindowSettings: Equatable {
    var sim: CallsSimPreference = .ask
    var showWhatsApp = true
    var recentCount = 20
    /// WhatsApp Desktop opens whatsapp: links on this Mac.
    var whatsAppOnMac = false
}

struct CallsWindowCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        let on = model.globalFeatures[.dialer] == true
        SettingsCard(footnote: L10n.text("calls.window.footnote", fallback: "Your phone places each call, so call audio stays on the phone or its earbuds. Android doesn\u{2019}t let apps send it to a Mac. Each phone also needs this Mac allowed in Bridgey there.")) {
            SettingsToggle(title: BridgeyFeature.dialer.title, subtitle: BridgeyFeature.dialer.subtitle, divider: false,
                           isOn: on, set: { actions.setGlobal(.dialer, $0) })
            if on {
                ForEach(phones) { device in
                    CallsPhoneGrantToggle(device: device, model: model, actions: actions)
                }
                SettingsRow(title: L10n.text("calls.window.sim", fallback: "Call from"),
                            subtitle: L10n.text("calls.window.sim.detail", fallback: "On a phone with two SIMs")) {
                    ChoiceButton(value: callsSimTitle(model.callsWindow.sim)) {
                        CallsSimPreference.allCases.map { choice in
                            PopUpMenuItem(title: callsSimTitle(choice), checked: choice == model.callsWindow.sim) { actions.setCallsSim(choice) }
                        }
                    }
                }
                SettingsToggle(title: L10n.text("calls.window.whatsapp", fallback: "Show WhatsApp calls"),
                               subtitle: model.callsWindow.whatsAppOnMac
                                ? L10n.text("calls.window.whatsapp.mac", fallback: "Voice and video through the phone\u{2019}s WhatsApp, or open a chat in WhatsApp on this Mac")
                                : L10n.text("calls.window.whatsapp.detail", fallback: "Voice and video through the phone\u{2019}s WhatsApp"),
                               isOn: model.callsWindow.showWhatsApp, set: actions.setCallsShowWhatsApp)
                SettingsRow(title: L10n.text("calls.window.recents", fallback: "Recent calls"), subtitle: nil) {
                    ChoiceButton(value: String(format: L10n.text("calls.window.recents.count", fallback: "Last %d"), model.callsWindow.recentCount)) {
                        BridgeySettings.callsRecentChoices.map { count in
                            PopUpMenuItem(title: String(format: L10n.text("calls.window.recents.count", fallback: "Last %d"), count),
                                          checked: count == model.callsWindow.recentCount) { actions.setCallsRecentCount(count) }
                        }
                    }
                }
                SettingsRow(title: L10n.text("calls.window.open", fallback: "Open the Calls window"),
                            subtitle: L10n.text("calls.window.open.detail", fallback: "Also in the menu bar panel")) {
                    Button(L10n.text("calls.window.openButton", fallback: "Open"), action: actions.openCalls)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
            }
        }
        .settingsSearchAnchor(BridgeyFeature.dialer.title)
    }

    /// Paired phones and restricted devices are left out; a Mac cannot place calls.
    private var phones: [TrustedDeviceInfo] {
        model.trustedDevices.filter { !model.restrictedDevices.contains($0.id) && !model.macDevices.contains($0.id) }
    }
}

/// One phone's permission, off by default.
private struct CallsPhoneGrantToggle: View {
    let device: TrustedDeviceInfo
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        let granted = model.deviceFeatures[device.id]?[.dialer] == true
        let phoneOff = granted && model.phoneFeatures[device.id]?[.dialer] == false
        SettingsToggle(
            title: device.name,
            subtitle: phoneOff
                ? String(format: L10n.text("calls.window.phone.off", fallback: "Allow this Mac in Bridgey on %@: Settings > Calls"), device.name)
                : granted
                    ? L10n.text("calls.window.phone.on", fallback: "Calls, contacts and recent calls through this phone")
                    : L10n.text("calls.window.phone.allow", fallback: "Off until you allow it"),
            subtitleIsWarning: phoneOff,
            isOn: granted,
            set: { actions.setForDevice(device.id, .dialer, $0) }
        )
    }
}

func callsSimTitle(_ preference: CallsSimPreference) -> String {
    switch preference {
    case .ask: L10n.text("calls.window.sim.ask", fallback: "Ask each time")
    case .sim1: String(format: L10n.text("calls.sim", fallback: "SIM %d"), 1)
    case .sim2: String(format: L10n.text("calls.sim", fallback: "SIM %d"), 2)
    }
}
