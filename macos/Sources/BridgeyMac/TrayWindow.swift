import AppKit
import SwiftUI

// The Tray window and the panel's send entries land in the next commit.

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
