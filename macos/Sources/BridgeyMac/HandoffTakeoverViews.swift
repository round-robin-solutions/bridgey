import SwiftUI

/// What Settings > Clipboard shows for Let Bridgey handle copy and paste.
struct HandoffDisplay: Equatable {
    var takeover = false
    /// Handoff now; nil before the first read or when it cannot be read.
    var state: HandoffState?
    var overridden = false
    var failed = false

    /// "Apple Handoff: off", or nil before the first read.
    var stateLine: String? {
        guard let state else { return nil }
        if state.isOff { return L10n.text("settings.handoff.stateOff", fallback: "Apple Handoff: off") }
        if state.advertising.allows && state.receiving.allows { return L10n.text("settings.handoff.stateOn", fallback: "Apple Handoff: on") }
        return L10n.text("settings.handoff.statePartly", fallback: "Apple Handoff: partly on")
    }
}

enum HandoffText {
    static var title: String { L10n.text("settings.handoff.title", fallback: "Let Bridgey handle copy and paste") }
    static var detail: String {
        L10n.text("settings.handoff.detail",
                  fallback: "Turns off Apple Handoff on this Mac, so it does not clash with Bridgey when you copy. AirDrop keeps working. Turn this off to put Handoff back the way it was.")
    }
    static var overridden: String { L10n.text("settings.handoff.overridden", fallback: "Handoff was turned back on in System Settings.") }
    static var reapply: String { L10n.text("settings.handoff.reapply", fallback: "Turn off again") }
    static var failed: String {
        L10n.text("settings.handoff.failed", fallback: "Could not change Handoff. Try again, or change it in System Settings > General > AirDrop & Handoff.")
    }
}

/// Settings > Clipboard: the switch, Handoff now, and what to do when System Settings turned it back on.
struct HandoffTakeoverRows: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        let handoff = model.handoff
        SettingsToggle(title: HandoffText.title, subtitle: HandoffText.detail, synced: model.syncs(.handoffTakeover),
                       isOn: handoff.takeover, set: actions.setHandoffTakeover)
        if handoff.failed {
            line(HandoffText.failed, warning: true, button: nil) {}
        } else if handoff.overridden {
            line(HandoffText.overridden, warning: true, button: HandoffText.reapply, action: actions.reapplyHandoffTakeover)
        } else if let state = handoff.stateLine {
            line(state, warning: false, button: nil) {}
        }
        SyncStatusLine(key: .handoffTakeover, model: model, actions: actions)
    }

    private func line(_ text: String, warning: Bool, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: warning ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? c.tpi : c.on2)
            Text(text)
                .font(BrandFont.body(12))
                .foregroundStyle(warning ? c.tpi : c.on2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Button(button, action: action)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 24))
            }
        }
        .padding(.bottom, 8)
    }
}
