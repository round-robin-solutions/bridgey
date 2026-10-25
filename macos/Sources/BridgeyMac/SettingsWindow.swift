import AppKit
import Combine
import SwiftUI

/*
 * Direction B Settings window: a sidebar like System Settings (in light mode the sidebar is
 * the midnight band), one pane at a time, cards of rows inside. The panes draw from a plain
 * `SettingsModel`, so screenshots render them from sample state.
 */

/// Grouped by what people come to change, most used first. Each feature pane starts with that
/// feature's switch, followed by its options. Android uses the same order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case thisMac, devices, clipboard, notifications, calls, files, media, privacy, updates, general, about

    var id: String { rawValue }

    /// The pane's heading.
    var title: String {
        switch self {
        case .thisMac: L10n.text("settings.thisMac", fallback: "This Mac")
        case .devices: L10n.text("settings.devicesPermissions", fallback: "Devices and permissions")
        case .clipboard: L10n.text("settings.clipboard", fallback: "Clipboard")
        case .notifications: L10n.text("settings.notifications", fallback: "Notifications")
        case .calls: L10n.text("settings.calls", fallback: "Calls")
        case .files: L10n.text("settings.files", fallback: "Files")
        case .media: L10n.text("settings.mediaActions", fallback: "Media and quick actions")
        case .privacy: L10n.text("settings.privacy", fallback: "Privacy")
        case .updates: L10n.text("settings.updates", fallback: "Updates")
        case .general: L10n.text("settings.general", fallback: "General")
        case .about: L10n.text("settings.about", fallback: "About")
        }
    }

    /// The shorter name in the sidebar.
    var sidebarTitle: String {
        switch self {
        case .devices: L10n.text("settings.devices", fallback: "Devices")
        case .media: L10n.text("settings.mediaActions.short", fallback: "Media and actions")
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .thisMac: "laptopcomputer"
        case .devices: "laptopcomputer.and.iphone"
        case .clipboard: "doc.on.clipboard"
        case .notifications: "bell"
        case .calls: "phone"
        case .files: "folder"
        case .media: "music.note"
        case .privacy: "hand.raised"
        case .updates: "arrow.triangle.2.circlepath"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }

    /// The sidebar list; This Mac is the compact header above it.
    static let sidebarItems: [SettingsPane] = allCases.filter { $0 != .thisMac }
}

struct SettingsModel {
    var deviceName = "Mac"
    var state: PairingState = .idle
    var trustedDevices: [TrustedDeviceInfo] = []
    var rings: [DeviceRing] = []
    var globalFeatures: [BridgeyFeature: Bool] = [:]
    var deviceFeatures: [String: [BridgeyFeature: Bool]] = [:]
    var remoteFeatures: [BridgeyFeature: Bool] = [:]
    var autoClipboard = true
    var autoClipboardDevices: [String: Bool] = [:]
    var launchAtLogin = false
    var loginItemMessage: String?
    var receiveFolderPath = ""
    var notificationsAuthorized = true
    var notificationPermissionDetermined = true
    var historyEnabled = false
    var history: [NotificationHistoryItem] = []
    var shortcutKeys: [ShortcutAction: String] = [:]
    var shortcutShift = false
    var shortcutError: String?
    var mediaPlayer: MediaPlayer = .off
    var pauseForCalls = false
    var mediaDetail = ""
    var showPreviews = true
    var reduceMotion = false
    var activityCount = 0
    var channel: UpdateChannel = .stable
    var automaticallyChecks = false
    var lastCheck: Date?
    var updatesAvailable = false
    var canCheckForUpdates = false
    var shortVersion = "Development"
    var versionDescription = "Development"
    var phoneLinkStatus: String?
    var now = Date()

    var connectedDeviceID: String? {
        if case let .connected(id, _) = state { return id }
        return nil
    }

    func isEnabled(_ feature: BridgeyFeature, for deviceID: String) -> Bool {
        globalFeatures[feature] != false && deviceFeatures[deviceID]?[feature] != false
    }

    func isAutoClipboardEnabled(for deviceID: String) -> Bool {
        autoClipboard && autoClipboardDevices[deviceID] != false
    }
}

struct SettingsActions {
    var setDeviceName: (String) -> Void = { _ in }
    var disconnect: () -> Void = {}
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var chooseReceiveFolder: () -> Void = {}
    var setGlobal: (BridgeyFeature, Bool) -> Void = { _, _ in }
    var setForDevice: (String, BridgeyFeature, Bool) -> Void = { _, _, _ in }
    var setAutoClipboard: (Bool) -> Void = { _ in }
    var setAutoClipboardForDevice: (String, Bool) -> Void = { _, _ in }
    var forget: (String) -> Void = { _ in }
    var pair: (DeviceRing) -> Void = { _ in }
    var enableNotifications: () -> Void = {}
    var setHistoryEnabled: (Bool) -> Void = { _ in }
    var clearHistory: () -> Void = {}
    var setShortcut: (ShortcutAction, String) -> Void = { _, _ in }
    var setShortcutShift: (Bool) -> Void = { _ in }
    var setPlayer: (MediaPlayer) -> Void = { _ in }
    var setPauseForCalls: (Bool) -> Void = { _ in }
    var refreshPlayer: () -> Void = {}
    var setShowPreviews: (Bool) -> Void = { _ in }
    var clearActivity: () -> Void = {}
    var exportDiagnostics: () -> Void = {}
    var setReduceMotion: (Bool) -> Void = { _ in }
    var usePhoneLinks: () -> Void = {}
    var setChannel: (UpdateChannel) -> Void = { _ in }
    var setAutomaticallyChecks: (Bool) -> Void = { _ in }
    var checkForUpdates: () -> Void = {}
    var openURL: (URL) -> Void = { _ in }
}

enum SettingsLinks {
    static let releases = URL(string: "https://github.com/round-robin-solutions/bridgey/releases")!
}

struct SettingsWindowView: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Binding var pane: SettingsPane
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    static let size = CGSize(width: 880, height: 600)

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model, pane: $pane)
            VStack(alignment: .leading, spacing: 0) {
                BoundedScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(pane.title)
                            .font(BrandFont.heading(24))
                            .foregroundStyle(c.on)
                            .frame(height: 30)
                            .accessibilityAddTraits(.isHeader)
                        SettingsPaneView(pane: pane, model: model, actions: actions)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 32)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.isDark ? Color(hex: 0x0A101D) : c.bg)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var footer: some View {
        HStack {
            Text(L10n.text("about.credit.short", fallback: "Built on Bridgey by Semyon Mikhailov (MIT)"))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
            Spacer()
            // Updates shows Release notes in its What's new card; elsewhere only About links to them.
            if pane == .about {
                Button(L10n.text("updates.releaseNotes", fallback: "Release notes")) { actions.openURL(SettingsLinks.releases) }
                    .buttonStyle(.plain)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.pri)
            }
        }
        .padding(.horizontal, 40)
        .frame(height: 40)
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let model: SettingsModel
    @Binding var pane: SettingsPane
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        let side = c.isDark ? c : BrandPalette.band
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if snapshot {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 44)
            ThisMacHeader(model: model, selected: pane == .thisMac) { select(.thisMac) }
                .padding(.bottom, 8)
            ForEach(SettingsPane.sidebarItems) { item in
                Button {
                    select(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(item == pane ? side.tbi : side.on2)
                            .frame(width: 18)
                        Text(item.sidebarTitle)
                            .font(BrandFont.body(13, .medium))
                            .foregroundStyle(side.on)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(item == pane ? side.tb : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == pane ? .isSelected : [])
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                AuroraMark(size: 24)
                Text("\(Edition.displayName)\n\(model.shortVersion)")
                    .font(BrandFont.body(12))
                    .foregroundStyle(side.on2)
                    .lineSpacing(1)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background {
            if c.isDark {
                c.s1
            } else {
                SidebarBand()
            }
        }
        .overlay(alignment: .trailing) { if c.isDark { Rectangle().fill(c.olv).frame(width: 1) } }
        .environment(\.brand, side)
    }

    private func select(_ item: SettingsPane) {
        withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { pane = item }
    }
}

/// The compact header at the top of the sidebar: this Mac's name and connection.
private struct ThisMacHeader: View {
    let model: SettingsModel
    let selected: Bool
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                DeviceRingView(state: model.connectedDeviceID == nil ? .offline : .connected, platform: "macos", size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.deviceName)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(c.on)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        if case let .connected(_, name) = model.state {
                            Image(systemName: "link").font(.system(size: 9, weight: .bold))
                            Text(name)
                        } else {
                            Text(connectionText(model))
                        }
                    }
                    .font(BrandFont.body(11))
                    .foregroundStyle(model.connectedDeviceID == nil ? c.on2 : c.tgi)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? c.tb : c.s2.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.deviceName), \(connectionText(model))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Connected to OnePlus 11", "Connecting to …" or "Not connected".
func connectionText(_ model: SettingsModel) -> String {
    switch model.state {
    case let .connected(_, name): String(format: L10n.text("thisMac.connected", fallback: "Connected to %@"), name)
    case let .connecting(name), let .verification(name, _): String(format: L10n.text("panel.connecting", fallback: "Connecting to %@"), name)
    case .failed: L10n.text("thisMac.failed", fallback: "Couldn\u{2019}t connect")
    case .idle: L10n.text("thisMac.idle", fallback: "Not connected")
    }
}

private struct SidebarBand: View {
    var body: some View {
        ZStack {
            BrandPalette.midnight
            RadialGradient(colors: [BrandPalette.auroraPurple.opacity(0.3), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
        }
    }
}

// MARK: - Building blocks

struct SettingsCard<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder let content: Content
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on2)
                    .padding(.bottom, 6)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
            if let footnote {
                Text(footnote)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A row: title and optional subtitle on the left, a control on the right; a hairline above
/// every row but the first.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleIsWarning = false
    var divider = true
    @ViewBuilder let trailing: Trailing
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            RowText(title: title, subtitle: subtitle, warning: subtitleIsWarning)
            trailing
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
    }
}

struct RowText: View {
    let title: String
    var subtitle: String?
    var warning = false
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(BrandFont.body(13, .medium))
                .foregroundStyle(c.on)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(BrandFont.body(12))
                    .foregroundStyle(warning ? c.tpi : c.on2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A switch row.
struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    var subtitleIsWarning = false
    var divider = true
    let isOn: Bool
    let set: (Bool) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            RowText(title: title, subtitle: subtitle, warning: subtitleIsWarning)
        }
        .toggleStyle(BrandSwitchStyle())
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
    }
}

/// A value with a chevron that opens a native menu of choices.
struct ChoiceButton: View {
    let value: String
    let items: () -> [PopUpMenuItem]
    @Environment(\.brand) private var c

    var body: some View {
        PopUpMenuButton(items: items) {
            HStack(spacing: 6) {
                Text(value)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(c.on2)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(c.s3))
            .contentShape(Capsule())
        }
    }
}

// MARK: - Panes

struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        switch pane {
        case .thisMac: ThisMacPane(model: model, actions: actions)
        case .devices: DevicesPane(model: model, actions: actions)
        case .clipboard: ClipboardPane(model: model, actions: actions)
        case .notifications: NotificationsPane(model: model, actions: actions)
        case .calls: CallsPane(model: model, actions: actions)
        case .files: FilesPane(model: model, actions: actions)
        case .media: MediaActionsPane(model: model, actions: actions)
        case .privacy: PrivacyPane(model: model, actions: actions)
        case .updates: UpdatesPane(model: model, actions: actions)
        case .general: GeneralPane(model: model, actions: actions)
        case .about: AboutPane(model: model, actions: actions)
        }
    }
}

struct AutoClipboardToggle: View {
    let isOn: Bool
    var subtitle: String?
    var subtitleIsWarning = false
    let set: (Bool) -> Void

    var body: some View {
        SettingsToggle(title: L10n.text("settings.autoClipboard", fallback: "Automatic clipboard"),
                       subtitle: subtitle ?? L10n.text("settings.autoClipboard.detail", fallback: "Copy on one device, paste on the other."),
                       subtitleIsWarning: subtitleIsWarning,
                       isOn: isOn, set: set)
    }
}

/// The global switch that leads a feature pane.
private struct FeatureSwitch: View {
    let feature: BridgeyFeature
    let model: SettingsModel
    let actions: SettingsActions
    var divider = false

    var body: some View {
        SettingsToggle(title: feature.title, subtitle: feature.subtitle, divider: divider,
                       isOn: model.globalFeatures[feature] != false,
                       set: { actions.setGlobal(feature, $0) })
    }
}

private struct ThisMacPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            DeviceNameRow(name: model.deviceName, onSave: actions.setDeviceName)
            SettingsRow(title: L10n.text("thisMac.connection", fallback: "Connection"), subtitle: connectionText(model)) {
                if model.connectedDeviceID != nil {
                    Button(L10n.text("thisMac.disconnect", fallback: "Disconnect"), action: actions.disconnect)
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
            }
        }
    }
}

private struct ClipboardPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard(footnote: L10n.text("settings.autoClipboard.note", fallback: "Works while both devices are connected and Clipboard is on for both. Passwords and other concealed clips are never sent; text over 32 KiB is skipped.")) {
            FeatureSwitch(feature: .clipboard, model: model, actions: actions)
            AutoClipboardToggle(isOn: model.autoClipboard, set: actions.setAutoClipboard)
                .disabled(model.globalFeatures[.clipboard] == false)
        }
        ShortcutsCard(model: model, actions: actions, only: [.clipboard])
    }
}

private struct NotificationsPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            FeatureSwitch(feature: .notifications, model: model, actions: actions)
            NotificationPermissionRow(model: model, actions: actions)
        }
        NotificationHistoryCard(model: model, actions: actions)
    }
}

private struct CallsPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            FeatureSwitch(feature: .calls, model: model, actions: actions)
            PhoneLinksRow(status: model.phoneLinkStatus, use: actions.usePhoneLinks)
            PauseForCallsToggle(model: model, actions: actions)
        }
        ShortcutsCard(model: model, actions: actions, only: [.call])
    }
}

private struct FilesPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            FeatureSwitch(feature: .files, model: model, actions: actions)
            ReceiveFolderRow(path: model.receiveFolderPath, choose: actions.chooseReceiveFolder)
        }
    }
}

private struct MediaActionsPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard(footnote: model.mediaDetail.isEmpty ? L10n.text("settings.media.detail", fallback: "macOS asks for Automation access to the player. Open the player on this Mac first.") : model.mediaDetail) {
            FeatureSwitch(feature: .media, model: model, actions: actions)
            MediaPlayerRow(model: model, actions: actions)
        }
        SettingsCard(title: L10n.text("settings.quickActions", fallback: "Quick actions")) {
            ForEach(Array([BridgeyFeature.links, .ping, .findDevice, .battery].enumerated()), id: \.element) { index, feature in
                FeatureSwitch(feature: feature, model: model, actions: actions, divider: index > 0)
            }
        }
        ShortcutsCard(model: model, actions: actions, only: [.link, .ping])
    }
}

private struct GeneralPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard(footnote: L10n.text("settings.shortcuts.detail", fallback: "Shortcuts use Control + Option and the key you choose.")) {
            SettingsToggle(title: L10n.text("settings.launchAtLogin", fallback: "Launch at login"),
                           subtitle: model.loginItemMessage, subtitleIsWarning: model.loginItemMessage != nil, divider: false,
                           isOn: model.launchAtLogin, set: actions.setLaunchAtLogin)
            SettingsToggle(title: L10n.text("settings.reduceMotion", fallback: "Reduce motion"),
                           subtitle: L10n.text("settings.reduceMotion.detail", fallback: "Fade between screens; nothing moves or bounces"),
                           isOn: model.reduceMotion, set: actions.setReduceMotion)
            SettingsToggle(title: L10n.text("settings.shortcuts.shift", fallback: "Also require Shift for shortcuts"),
                           isOn: model.shortcutShift, set: actions.setShortcutShift)
        }
    }
}

struct DeviceNameRow: View {
    let name: String
    let onSave: (String) -> Void
    var divider = false
    @State private var editing = false
    @State private var draft = ""
    @Environment(\.brand) private var c

    var body: some View {
        SettingsRow(title: L10n.text("settings.deviceName", fallback: "Device name"),
                    subtitle: editing ? nil : name,
                    divider: divider) {
            if editing {
                TextField(L10n.text("settings.deviceName", fallback: "Device name"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
                Button(L10n.text("action.cancel", fallback: "Cancel")) { editing = false }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                Button(L10n.text("action.save", fallback: "Save"), action: save)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                    .disabled(trimmed.isEmpty || trimmed == name)
            } else {
                Button(L10n.text("action.rename", fallback: "Rename")) {
                    draft = name
                    editing = true
                }
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
        }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty, trimmed != name else { return }
        onSave(trimmed)
        editing = false
    }
}

struct ReceiveFolderRow: View {
    let path: String
    let choose: () -> Void
    var divider = true

    var body: some View {
        SettingsRow(title: L10n.text("settings.receivedFiles", fallback: "Received files"),
                    subtitle: (path as NSString).abbreviatingWithTildeInPath, divider: divider) {
            Button(L10n.text("action.choose", fallback: "Choose\u{2026}"), action: choose)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
        }
    }
}

struct PhoneLinksRow: View {
    let status: String?
    let use: () -> Void

    var body: some View {
        SettingsRow(title: L10n.text("settings.phoneLinks", fallback: "Phone links"),
                    subtitle: status ?? L10n.text("settings.phoneLinks.detail", fallback: "Open tel: links from browsers and other apps with Bridgey, to call from the phone. The browser still asks first.")) {
            Button(L10n.text("settings.phoneLinks.use", fallback: "Use Bridgey"), action: use)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
        }
    }
}

struct ShortcutsCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    let only: [ShortcutAction]

    var body: some View {
        SettingsCard(title: L10n.text("settings.shortcut", fallback: "Keyboard shortcut"),
                     footnote: model.shortcutError) {
            ForEach(Array(only.enumerated()), id: \.element) { index, action in
                SettingsRow(title: action.displayTitle, divider: index > 0) {
                    ChoiceButton(value: shortcutLabel(action)) {
                        [PopUpMenuItem(title: L10n.text("shortcut.off", fallback: "Off"), checked: key(action) == "Off") { actions.setShortcut(action, "Off") }]
                            + ShortcutSettings.keys.map { entry in
                                PopUpMenuItem(title: entry.0, checked: key(action) == entry.0) { actions.setShortcut(action, entry.0) }
                            }
                    }
                }
            }
        }
    }

    private func key(_ action: ShortcutAction) -> String { model.shortcutKeys[action] ?? "Off" }

    private func shortcutLabel(_ action: ShortcutAction) -> String {
        let value = key(action)
        guard value != "Off" else { return L10n.text("shortcut.off", fallback: "Off") }
        return (model.shortcutShift ? "\u{2303}\u{2325}\u{21E7}" : "\u{2303}\u{2325}") + value
    }
}

extension ShortcutAction {
    var displayTitle: String {
        switch self {
        case .clipboard: L10n.text("shortcut.clipboard", fallback: "Send clipboard")
        case .call: L10n.text("shortcut.call", fallback: "Call the copied number")
        case .link: L10n.text("shortcut.link", fallback: "Send the copied link")
        case .ping: L10n.text("shortcut.ping", fallback: "Ping the phone")
        }
    }
}

extension BridgeyFeature {
    var subtitle: String {
        switch self {
        case .clipboard: L10n.text("feature.clipboard.detail", fallback: "Copy here, paste there")
        case .files: L10n.text("feature.files.detail", fallback: "Send and receive files")
        case .notifications: L10n.text("feature.notifications.detail", fallback: "Show the phone\u{2019}s notifications on this Mac")
        case .battery: L10n.text("feature.battery.detail", fallback: "Share battery level both ways")
        case .findDevice: L10n.text("feature.find.detail", fallback: "Ring the phone from here, and back")
        case .ping: L10n.text("feature.ping.detail", fallback: "A short alert, both ways")
        case .links: L10n.text("feature.links.detail", fallback: "Open links in either direction")
        case .media: L10n.text("feature.media.detail", fallback: "Control this Mac\u{2019}s music from the phone")
        case .calls: L10n.text("feature.calls.detail", fallback: "Start calls on the phone from this Mac")
        }
    }
}

private struct DevicesPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        if model.trustedDevices.isEmpty {
            SettingsCard {
                SettingsRow(title: L10n.text("devices.none", fallback: "No paired devices yet"),
                            subtitle: L10n.text("devices.none.detail", fallback: "Pair a device below. Both screens show a code; confirm it only if they match."),
                            divider: false) { EmptyView() }
            }
        }
        ForEach(model.trustedDevices) { device in
            DeviceCard(device: device, model: model, actions: actions)
        }
        PairNewCard(model: model, actions: actions)
    }
}

struct DeviceCard: View {
    let device: TrustedDeviceInfo
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmForget = false
    @Environment(\.brand) private var c

    var body: some View {
        let ring = model.rings.first { $0.deviceID == device.id }
        SettingsCard {
            HStack(spacing: 12) {
                DeviceRingView(state: ring?.state ?? .offline, platform: ring?.platform, size: 36)
                RowText(title: device.name, subtitle: ring.map(ringStatusText) ?? L10n.text("ring.offline", fallback: "Offline"))
                Button(L10n.text("action.forget", fallback: "Forget")) { confirmForget = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
            }
            .padding(.vertical, 8)
            Text(String(format: L10n.text("devices.permissions.intro", fallback: "What this Mac shares with %@."), device.name))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .padding(.bottom, 4)
            ForEach(BridgeyFeature.allCases) { feature in
                SettingsToggle(
                    title: feature.title,
                    subtitle: note(feature),
                    subtitleIsWarning: note(feature) != nil,
                    isOn: model.isEnabled(feature, for: device.id),
                    set: { actions.setForDevice(device.id, feature, $0) }
                )
                .disabled(model.globalFeatures[feature] == false)
                if feature == .clipboard {
                    AutoClipboardToggle(
                        isOn: model.isAutoClipboardEnabled(for: device.id),
                        subtitle: model.autoClipboard ? nil : L10n.text("settings.autoClipboard.offEverywhere", fallback: "Off for every device, in Clipboard"),
                        subtitleIsWarning: !model.autoClipboard,
                        set: { actions.setAutoClipboardForDevice(device.id, $0) }
                    )
                    .disabled(!model.autoClipboard || !model.isEnabled(.clipboard, for: device.id))
                }
            }
        }
        .confirmationDialog(
            String(format: L10n.text("devices.forget.title", fallback: "Forget %@?"), device.name),
            isPresented: $confirmForget
        ) {
            Button(L10n.text("action.forget", fallback: "Forget"), role: .destructive) { actions.forget(device.id) }
        } message: {
            Text(L10n.text("devices.forget.body", fallback: "This Mac stops trusting it. To use it again, pair and compare the code once more."))
        }
    }

    private func note(_ feature: BridgeyFeature) -> String? {
        if model.globalFeatures[feature] == false { return L10n.text("permission.offEverywhere", fallback: "Off for every device") }
        if model.connectedDeviceID == device.id && model.remoteFeatures[feature] == false {
            return String(format: L10n.text("permission.offRemote", fallback: "Off on %@"), device.name)
        }
        return nil
    }
}

struct PairNewCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        let nearby = model.rings.filter { !$0.trusted }
        SettingsCard(title: L10n.text("devices.pair", fallback: "Pair a new device"),
                     footnote: L10n.text("devices.pair.detail", fallback: "Open Bridgey on the phone, on the same Wi-Fi as this Mac. Both screens then show the same code.")) {
            if nearby.isEmpty {
                SettingsRow(title: L10n.text("devices.pair.searching", fallback: "Looking for devices on this network\u{2026}"), divider: false) { EmptyView() }
            }
            ForEach(Array(nearby.enumerated()), id: \.element.id) { index, ring in
                SettingsRow(title: ring.name, subtitle: ringStatusText(ring), divider: index > 0) {
                    Button(L10n.text("action.pair", fallback: "Pair")) { actions.pair(ring) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                        .disabled(!ring.canConnect)
                }
            }
        }
    }
}

struct MediaPlayerRow: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsRow(title: L10n.text("settings.media.player", fallback: "Player"),
                    subtitle: L10n.text("settings.media.player.detail", fallback: "The Mac player the phone controls")) {
            ChoiceButton(value: model.mediaPlayer.title) {
                MediaPlayer.allCases.map { player in
                    PopUpMenuItem(title: player.title, checked: player == model.mediaPlayer) { actions.setPlayer(player) }
                }
            }
            Button(L10n.text("settings.media.refresh", fallback: "Refresh"), action: actions.refreshPlayer)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                .disabled(model.mediaPlayer == .off)
        }
    }
}

struct PauseForCallsToggle: View {
    let model: SettingsModel
    let actions: SettingsActions
    var divider = true

    var body: some View {
        SettingsToggle(title: L10n.text("settings.media.pauseForCalls", fallback: "Pause media during phone calls"),
                       subtitle: L10n.text("settings.media.pauseForCalls.detail", fallback: "Playback stays paused after the call; resume it when ready."),
                       divider: divider, isOn: model.pauseForCalls, set: actions.setPauseForCalls)
    }
}

struct NotificationPermissionRow: View {
    let model: SettingsModel
    let actions: SettingsActions
    var divider = true

    var body: some View {
        SettingsRow(title: L10n.text("settings.macNotifications", fallback: "Mac notifications"),
                    subtitle: model.notificationsAuthorized
                        ? L10n.text("settings.macNotifications.on", fallback: "Allowed, so Android alerts appear here")
                        : L10n.text("settings.macNotifications.off", fallback: "Not allowed yet; Android alerts can\u{2019}t appear"),
                    subtitleIsWarning: !model.notificationsAuthorized,
                    divider: divider) {
            if !model.notificationsAuthorized {
                Button(model.notificationPermissionDetermined
                       ? L10n.text("panel.notifications.settings", fallback: "Open Settings")
                       : L10n.text("panel.notifications.enable", fallback: "Allow"),
                       action: actions.enableNotifications)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            }
        }
    }
}

struct NotificationHistoryCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        SettingsCard(title: L10n.text("settings.history", fallback: "Notification history")) {
            SettingsToggle(title: L10n.text("settings.history.toggle", fallback: "Keep a private local history"),
                           subtitle: L10n.text("settings.history.detail", fallback: "Off by default. Keeps at most 200 notifications, with their text, for 7 days on this Mac. Turning it off deletes the history."),
                           divider: false, isOn: model.historyEnabled, set: actions.setHistoryEnabled)
            if model.historyEnabled {
                if model.history.isEmpty {
                    SettingsRow(title: L10n.text("settings.history.empty", fallback: "No forwarded notifications yet."), divider: true) { EmptyView() }
                } else {
                    ForEach(Array(model.history.prefix(20))) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.applicationName).font(BrandFont.body(13, .semibold)).foregroundStyle(c.on)
                                Spacer()
                                Text(item.receivedAt, format: .dateTime.day().month().hour().minute())
                                    .font(BrandFont.body(12)).foregroundStyle(c.on2)
                            }
                            if !item.title.isEmpty { Text(item.title).font(BrandFont.body(13, .medium)).foregroundStyle(c.on) }
                            if !item.text.isEmpty { Text(item.text).font(BrandFont.body(12)).foregroundStyle(c.on2).lineLimit(3) }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
                    }
                    SettingsRow(title: "", divider: true) {
                        Button(L10n.text("settings.history.clear", fallback: "Clear history"), action: actions.clearHistory)
                            .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                    }
                }
            }
        }
    }
}

struct PrivacyPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmClear = false

    var body: some View {
        SettingsCard(title: L10n.text("settings.activity", fallback: "Activity")) {
            SettingsToggle(title: L10n.text("settings.previews", fallback: "Show previews in activity"),
                           subtitle: L10n.text("settings.previews.detail", fallback: "Clipboard text, app names and callers. Off keeps only what happened."),
                           divider: false, isOn: model.showPreviews, set: actions.setShowPreviews)
            SettingsRow(title: L10n.text("settings.activity.clear", fallback: "Clear activity"),
                        subtitle: L10n.text("settings.activity.detail", fallback: "Kept only on this Mac, for 7 days. Never in diagnostics.")) {
                Button(L10n.text("action.clear", fallback: "Clear")) { confirmClear = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                    .disabled(model.activityCount == 0)
            }
        }
        .confirmationDialog(L10n.text("settings.activity.clear.title", fallback: "Clear activity?"), isPresented: $confirmClear) {
            Button(L10n.text("action.clear", fallback: "Clear"), role: .destructive, action: actions.clearActivity)
        } message: {
            Text(L10n.text("settings.activity.clear.body", fallback: "This removes the stream from this Mac. Your other devices keep their own history."))
        }
        SettingsCard(title: L10n.text("settings.diagnostics", fallback: "Diagnostics")) {
            SettingsRow(title: L10n.text("settings.diagnostics.export", fallback: "Export diagnostics"),
                        subtitle: L10n.text("settings.diagnostics.detail", fallback: "A bounded event log without clipboard text, notification content, file names, addresses or device identifiers."),
                        divider: false) {
                Button(L10n.text("action.export", fallback: "Export\u{2026}"), action: actions.exportDiagnostics)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
        }
    }
}

struct AboutPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        SettingsCard {
            HStack(spacing: 14) {
                AuroraMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Edition.displayName).font(BrandFont.heading(17)).foregroundStyle(c.on)
                    Text(String(format: L10n.text("updates.version", fallback: "Version %@"), model.versionDescription))
                        .font(BrandFont.body(12)).foregroundStyle(c.on2)
                }
            }
            .padding(.vertical, 10)
            SettingsRow(title: L10n.text("about.credit", fallback: "Built on Bridgey by Semyon Mikhailov (MIT)"),
                        subtitle: L10n.text("about.license", fallback: "Open source under the MIT License.")) {
                Button(L10n.text("about.original", fallback: "Original project")) { actions.openURL(Edition.upstreamProjectURL) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
            SettingsRow(title: L10n.text("about.fonts", fallback: "Fonts"),
                        subtitle: L10n.text("about.fonts.detail", fallback: "Space Grotesk and Inter, under the SIL Open Font License 1.1.")) { EmptyView() }
            SettingsRow(title: L10n.text("about.network", fallback: "Your data"),
                        subtitle: L10n.text("about.network.detail", fallback: "Bridgey talks directly over your local network. Clipboard, files and notification content are encrypted in transit.")) { EmptyView() }
        }
    }
}

// MARK: - Live settings

@MainActor
final class SettingsWindowController {
    private let discovery: BonjourDiscovery
    private let pairing: PairingCoordinator
    private let settings: BridgeySettings
    private let updater: AppUpdater
    private var window: NSWindow?

    init(discovery: BonjourDiscovery, pairing: PairingCoordinator, settings: BridgeySettings, updater: AppUpdater) {
        self.discovery = discovery
        self.pairing = pairing
        self.settings = settings
        self.updater = updater
    }

    func show() {
        if window == nil {
            let content = LiveSettingsView(discovery: discovery, pairing: pairing, settings: settings, updater: updater)
            let created = NSWindow(contentViewController: NSHostingController(rootView: content))
            created.title = L10n.text("settings.window", fallback: "Bridgey Settings")
            created.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.setContentSize(NSSize(width: SettingsWindowView.size.width, height: SettingsWindowView.size.height))
            created.isReleasedWhenClosed = false
            created.setFrameAutosaveName("BridgeySettingsWindowB")
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct LiveSettingsView: View {
    @ObservedObject var discovery: BonjourDiscovery
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var settings: BridgeySettings
    @ObservedObject var updater: AppUpdater
    @ObservedObject var activity: ActivityLog
    @ObservedObject var media: MediaController
    @ObservedObject var shortcuts: ShortcutSettings
    @State private var pane: SettingsPane = .devices
    @State private var phoneLinkStatus: String?

    init(discovery: BonjourDiscovery, pairing: PairingCoordinator, settings: BridgeySettings, updater: AppUpdater) {
        self.discovery = discovery
        self.pairing = pairing
        self.settings = settings
        self.updater = updater
        activity = pairing.activity
        media = pairing.mediaController
        shortcuts = pairing.shortcuts
    }

    var body: some View {
        BrandRoot(reduceMotion: settings.reduceMotion) {
            SettingsWindowView(model: model, actions: actions, pane: $pane)
        }
        .onAppear {
            pairing.refreshNotificationAuthorization()
            settings.refreshLoginItemStatus()
        }
    }

    private var model: SettingsModel {
        var model = SettingsModel()
        model.deviceName = settings.deviceName
        model.state = pairing.state
        model.trustedDevices = pairing.trustedDevices
        model.rings = deviceRings(trusted: pairing.trustedDevices, peers: discovery.peers, state: pairing.state)
        model.globalFeatures = settings.globalFeatures
        model.deviceFeatures = settings.deviceFeatures
        model.remoteFeatures = pairing.remoteFeatures
        model.autoClipboard = settings.autoClipboardEnabled
        model.autoClipboardDevices = settings.autoClipboardDevices
        model.launchAtLogin = settings.launchAtLogin
        model.loginItemMessage = settings.loginItemMessage
        model.receiveFolderPath = settings.receiveFolderPath
        model.notificationsAuthorized = pairing.notificationsAuthorized
        model.notificationPermissionDetermined = pairing.notificationPermissionDetermined
        model.historyEnabled = settings.notificationHistoryEnabled
        model.history = pairing.notificationHistory
        model.shortcutKeys = shortcuts.keys
        model.shortcutShift = shortcuts.useShift
        model.shortcutError = shortcuts.error
        model.mediaPlayer = media.player
        model.pauseForCalls = media.pauseForCalls
        model.mediaDetail = media.snapshot.detail
        model.showPreviews = settings.showActivityPreviews
        model.reduceMotion = settings.reduceMotion
        model.activityCount = activity.items.count
        model.channel = updater.channel
        model.automaticallyChecks = updater.automaticallyChecks
        model.lastCheck = updater.lastCheck
        model.updatesAvailable = updater.isAvailable
        model.canCheckForUpdates = updater.canCheckForUpdates
        model.shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        model.versionDescription = updater.versionDescription
        model.phoneLinkStatus = phoneLinkStatus
        model.now = Date()
        return model
    }

    private var actions: SettingsActions {
        var actions = SettingsActions()
        actions.setDeviceName = { name in
            settings.setDeviceName(name)
            pairing.updateDeviceName(settings.deviceName)
            discovery.updateDeviceName(settings.deviceName)
        }
        actions.disconnect = { pairing.dismiss() }
        actions.setLaunchAtLogin = { settings.setLaunchAtLogin($0) }
        actions.chooseReceiveFolder = { settings.chooseReceiveFolder() }
        actions.setGlobal = { feature, enabled in
            settings.setGlobal(feature, enabled: enabled)
            if feature == .findDevice && !enabled { pairing.stopFinding() }
        }
        actions.setForDevice = { deviceID, feature, enabled in
            settings.setForDevice(deviceID, feature: feature, enabled: enabled)
            if feature == .findDevice && !enabled,
               case let .connected(connectedID, _) = pairing.state,
               connectedID == deviceID { pairing.stopFinding() }
        }
        actions.setAutoClipboard = { settings.setAutoClipboard($0) }
        actions.setAutoClipboardForDevice = { deviceID, enabled in settings.setAutoClipboard(enabled, for: deviceID) }
        actions.forget = { pairing.forget(deviceID: $0) }
        actions.pair = { ring in
            guard let host = ring.peer?.host, let port = ring.peer?.port else { return }
            pairing.pair(host: host, port: port, peerName: ring.name)
        }
        actions.enableNotifications = { pairing.enableNotifications() }
        actions.setHistoryEnabled = { settings.setNotificationHistoryEnabled($0) }
        actions.clearHistory = { pairing.clearNotificationHistory() }
        actions.setShortcut = { action, key in shortcuts.setKey(key, for: action) }
        actions.setShortcutShift = { shortcuts.setShift($0) }
        actions.setPlayer = { media.player = $0 }
        actions.setPauseForCalls = { media.pauseForCalls = $0 }
        actions.refreshPlayer = { media.refresh() }
        actions.setShowPreviews = { settings.setShowActivityPreviews($0) }
        actions.clearActivity = { pairing.clearActivity() }
        actions.exportDiagnostics = { pairing.exportDiagnostics() }
        actions.setReduceMotion = { settings.setReduceMotion($0) }
        actions.usePhoneLinks = { makeDefaultPhoneLinkHandler() }
        actions.setChannel = { updater.setChannel($0) }
        actions.setAutomaticallyChecks = { updater.setAutomaticallyChecks($0) }
        actions.checkForUpdates = { updater.checkForUpdates() }
        actions.openURL = { NSWorkspace.shared.open($0) }
        return actions
    }

    private func makeDefaultPhoneLinkHandler() {
        let applicationURL = Bundle.main.bundleURL
        guard applicationURL.pathExtension == "app" else {
            phoneLinkStatus = L10n.text("settings.phoneLinks.notBundle", fallback: "Could not register: run the installed Bridgey app.")
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpenURLsWithScheme: "tel") { error in
            DispatchQueue.main.async {
                phoneLinkStatus = error.map {
                    String(format: L10n.text("settings.phoneLinks.failed", fallback: "Could not register Bridgey: %@"), $0.localizedDescription)
                } ?? L10n.text("settings.phoneLinks.done", fallback: "Bridgey now opens phone links.")
            }
        }
    }
}
