import AppKit
import SwiftUI

// Files 2.0: the Phone files window (Media, Files, Folders, Recent from phone). Placeholder entry points; the
// window itself lands in the browse UI commits.

@MainActor
enum PhoneFilesWindowController {
    /// Opens (or brings forward) the Phone files window on a phone; nil picks the selected phone.
    static func show(pairing: PairingCoordinator, phoneID: String?) {}
}

/// The panel's entry to Phone files and History, under the quick actions.
struct PhoneFilesPanelEntry: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View { EmptyView() }
}

/// The Devices page's entry to Phone files, in each device card's header.
struct PhoneFilesDeviceEntry: View {
    let deviceID: String
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View { EmptyView() }
}
