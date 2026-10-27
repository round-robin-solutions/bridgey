import SwiftUI

// Settings > Files: "When I drop on the menu-bar icon" and "Before sending" (optimisation with a live
// preview). Stored in SendPreferences, on this Mac only.

struct SendOptionsSettingsSection: View {
    @ObservedObject private var preferences = SendPreferences.shared

    var body: some View {
        SettingsCard(footnote: L10n.text("settings.drop.note", fallback: "Hovering over the icon while dragging opens the panel with a tile for each device and the Tray.")) {
            SettingsRow(title: L10n.text("settings.drop", fallback: "When I drop on the menu-bar icon"), subtitle: nil, divider: false) {
                ChoiceButton(value: menuBarDropModeTitle(preferences.menuBarDropMode)) {
                    MenuBarDropMode.allCases.map { mode in
                        PopUpMenuItem(title: menuBarDropModeTitle(mode), checked: mode == preferences.menuBarDropMode) {
                            preferences.setMenuBarDropMode(mode)
                        }
                    }
                }
            }
        }
    }
}

func menuBarDropModeTitle(_ mode: MenuBarDropMode) -> String {
    switch mode {
    case .springOpen: L10n.text("settings.drop.spring", fallback: "Show devices and Tray")
    case .tray: L10n.text("settings.drop.tray", fallback: "Always collect in the Tray")
    case .instant: L10n.text("settings.drop.instant", fallback: "Send right away")
    }
}
