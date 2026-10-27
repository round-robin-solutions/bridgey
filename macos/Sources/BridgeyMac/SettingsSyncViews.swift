import AppKit
import SwiftUI

extension SyncKey {
    /// The key that syncs a feature's global switch on this Mac.
    static func key(for feature: BridgeyFeature) -> SyncKey? { allCases.first { $0.feature == feature } }
}

/// Settings > General: the one switch that turns settings sync off for every device, and Choose what syncs.
struct SettingsSyncCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var choosing = false

    var body: some View {
        SettingsCard {
            SettingsToggle(title: L10n.text("settings.sync", fallback: "Sync settings with paired devices"),
                           subtitle: L10n.text("settings.sync.detail", fallback: "Keeps settings and features the same on your devices. Permissions, pairing and folders stay on each device."),
                           divider: false, isOn: model.settingsSyncEnabled, set: actions.setSettingsSync)
            SettingsRow(title: L10n.text("sync.choose.title", fallback: "What syncs"),
                        subtitle: syncedCountText) {
                Button(L10n.text("sync.choose", fallback: "Choose what syncs\u{2026}")) { choosing = true }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
            .disabled(!model.settingsSyncEnabled)
        }
        .sheet(isPresented: $choosing) {
            BrandRoot(reduceMotion: model.reduceMotion) {
                SyncChoicesView(model: model, actions: actions) { choosing = false }
            }
        }
    }

    private var syncedCountText: String {
        let count = SyncKey.allCases.count - model.syncExcluded.count
        return String(format: L10n.text("sync.choose.count", fallback: "%1$d of %2$d settings"), count, SyncKey.allCases.count)
    }
}

/// Choose what syncs: one check per setting. An unchecked setting stays on this Mac.
struct SyncChoicesView: View {
    let model: SettingsModel
    let actions: SettingsActions
    let done: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("sync.choose.heading", fallback: "Choose what syncs"))
                .font(BrandFont.heading(20))
                .foregroundStyle(c.on)
            Text(L10n.text("sync.choose.detail", fallback: "Checked settings stay the same on your devices. An unchecked one stays as it is on this Mac and is not sent."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SyncKey.allCases, id: \.self) { key in
                    Toggle(isOn: Binding(get: { !model.syncExcluded.contains(key) }, set: { actions.setSyncs(key, $0) })) {
                        Text(key.name).font(BrandFont.body(13)).foregroundStyle(c.on)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("action.done", fallback: "Done"), action: done)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400, alignment: .leading)
        .background(c.bg)
    }
}

/// Under a synced row: "On, waiting for permission" with Allow, "Different on <phone>" with Apply to all,
/// and "Turned on, needs permission on <phone>".
struct SyncStatusLine: View {
    let key: SyncKey
    let model: SettingsModel
    let actions: SettingsActions
    /// What Allow does, when the row has its own consent step (Codes from messages); else the Permissions pane.
    var allow: (() -> Void)?
    @Environment(\.brand) private var c

    var body: some View {
        let status = model.syncs(key) ? (model.syncStatus[key] ?? SyncRowStatus()) : SyncRowStatus()
        if status.localWaiting {
            line(L10n.text("sync.status.waiting", fallback: "On, waiting for permission"), warning: true,
                 button: L10n.text("sync.status.allow", fallback: "Allow")) { if let allow { allow() } else { actions.allowPermission(key) } }
        }
        if !status.differentOn.isEmpty {
            line(String(format: L10n.text("sync.status.different", fallback: "Different on %@"), names(status.differentOn)), warning: false,
                 button: L10n.text("sync.status.applyToAll", fallback: "Apply to all")) { actions.applyToAll(key) }
        }
        if !status.peerWaiting.isEmpty {
            line(String(format: L10n.text("sync.status.peerWaiting", fallback: "Turned on, needs permission on %@"), names(status.peerWaiting)),
                 warning: false, button: nil) {}
        }
    }

    /// "OnePlus 11", or "OnePlus 11 and 2 more".
    private func names(_ list: [String]) -> String {
        guard let first = list.first else { return "" }
        if list.count == 1 { return first }
        return String(format: L10n.text("sync.status.andMore", fallback: "%1$@ and %2$d more"), first, list.count - 1)
    }

    private func line(_ text: String, warning: Bool, button: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: warning ? "exclamationmark.circle" : "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warning ? c.tpi : c.on2)
            Text(text)
                .font(BrandFont.body(12))
                .foregroundStyle(warning ? c.tpi : c.on2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                Button(button, action: action)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 24))
            }
        }
        .padding(.bottom, 8)
    }
}

/// Devices > [phone]: settings sync with this phone only.
struct SettingsSyncDeviceToggle: View {
    let device: TrustedDeviceInfo
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        let warning = note
        SettingsToggle(
            title: L10n.text("settings.sync.device", fallback: "Sync settings with this device"),
            subtitle: warning,
            subtitleIsWarning: warning != nil,
            isOn: model.isSettingsSyncEnabled(for: device.id),
            set: { actions.setSettingsSyncForDevice(device.id, $0) }
        )
        .disabled(!model.settingsSyncEnabled)
    }

    /// "Off for every device" when General is off; "Off on OnePlus 11" when the phone has it off.
    private var note: String? {
        if !model.settingsSyncEnabled { return L10n.text("permission.offEverywhere", fallback: "Off for every device") }
        guard model.isSettingsSyncEnabled(for: device.id), model.phoneSettingsSync[device.id] == false else { return nil }
        return String(format: L10n.text("permission.offRemote", fallback: "Off on %@"), device.name)
    }
}

/// First connect (8.4): "Use the same settings as <phone>?", once per phone.
struct SyncQuestionView: View {
    let phone: String
    let use: () -> Void
    let keep: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(c.pri)
            Text(String(format: L10n.text("sync.question.title", fallback: "Use the same settings as %@?"), phone))
                .font(BrandFont.heading(18))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: L10n.text("sync.question.body", fallback: "Use these takes %1$@\u{2019}s settings and features on this Mac. Keep mine keeps this Mac\u{2019}s and shows where they differ."), phone))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.text("sync.question.keep", fallback: "Keep mine"), action: keep)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 30))
                Button(L10n.text("sync.question.use", fallback: "Use these"), action: use)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 400, alignment: .leading)
        .background(c.bg)
    }
}

/// One small window per open first-connect question. It closes only through an answer, or when the session ends.
@MainActor
final class SyncQuestionWindows {
    private var windows: [String: NSWindow] = [:]

    func update(questions: [String], name: (String) -> String, reduceMotion: Bool, answer: @escaping (String, Bool) -> Void) {
        for (id, window) in windows where !questions.contains(id) {
            window.close()
            windows.removeValue(forKey: id)
        }
        for id in questions where windows[id] == nil {
            let phone = name(id)
            let root = BrandRoot(reduceMotion: reduceMotion) {
                SyncQuestionView(phone: phone, use: { answer(id, true) }, keep: { answer(id, false) })
            }
            let panel = NSPanel(contentViewController: NSHostingController(rootView: root))
            panel.title = L10n.text("sync.question.window", fallback: "Settings sync")
            panel.styleMask = [.titled]
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.center()
            windows[id] = panel
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
