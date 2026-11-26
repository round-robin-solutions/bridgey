import SwiftUI

/*
 * Phone > Calls window: the switch, opening the window, the SIM to call from, the phones this Mac may call
 * through (the Devices row, each off until allowed), then whether WhatsApp calls show and how many recent calls
 * the window lists. Drawn from `SettingsModel`, so the screenshots render it from sample state.
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
        FeatureCard(card: .callsWindow, toggle: featureToggle(.dialer, model, actions),
                    footnote: L10n.text("calls.window.footnote", fallback: "Your phone places each call, so call audio stays on the phone or its earbuds. Android doesn\u{2019}t let apps send it to a Mac. Each phone also needs this Mac allowed in Bridgey there.")) {
            if on {
                SettingsRow(title: L10n.text("calls.window.open", fallback: "Open the Calls window"),
                            subtitle: L10n.text("calls.window.open.detail", fallback: "Also in the menu bar panel")) {
                    Button(L10n.text("calls.window.openButton", fallback: "Open"), action: actions.openCalls)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
                SettingsRow(title: L10n.text("calls.window.sim", fallback: "Call from"),
                            subtitle: L10n.text("calls.window.sim.detail", fallback: "On a phone with two SIMs")) {
                    ChoiceButton(value: callsSimTitle(model.callsWindow.sim)) {
                        CallsSimPreference.allCases.map { choice in
                            PopUpMenuItem(title: callsSimTitle(choice), checked: choice == model.callsWindow.sim) { actions.setCallsSim(choice) }
                        }
                    }
                }
                DeviceChoicesRow(feature: SettingsCardID.callsWindow.title, chips: DeviceChoices.callsWindow(model, actions))
            }
        } more: {
            if on {
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
            }
        }
    }
}

func callsSimTitle(_ preference: CallsSimPreference) -> String {
    switch preference {
    case .ask: L10n.text("calls.window.sim.ask", fallback: "Ask each time")
    case .sim1: String(format: L10n.text("calls.sim", fallback: "SIM %d"), 1)
    case .sim2: String(format: L10n.text("calls.sim", fallback: "SIM %d"), 2)
    }
}
