import AppKit
import SwiftUI

// Files 2.0: the Send to phone sheet (recent files, screenshots, drop, Browse...) and the Tray. Placeholder
// entry points: until the sheet lands, Send Files or Folders opens the system panel as before.

@MainActor
enum SendSheetController {
    static func show(pairing: PairingCoordinator) { pairing.chooseAndSendFile() }
}

@MainActor
enum TrayController {
    static func show(pairing: PairingCoordinator) {}
}

/// The panel's entry to the send sheet and the Tray, above the send bar.
struct SendPanelEntry: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View { EmptyView() }
}

/// Drop tiles over the panel while a drag hovers the menu-bar icon: one per connected device, plus Tray.
struct DropTilesOverlay: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View { EmptyView() }
}
