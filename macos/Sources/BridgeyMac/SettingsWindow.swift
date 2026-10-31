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
    case thisMac, devices, clipboard, notifications, messages, calls, files, media, remoteControl, privacy, updates, general, about
    /// Privacy sub-pages (PermissionsView.swift, ResetView.swift); not in the sidebar.
    case permissions, reset
    /// Devices sub-page: Connect away from home (ConnectSettingsView.swift).
    case away
    /// Hidden until the version in About is clicked five times (DeveloperMenu.swift); then the last sidebar item.
    case developer

    var id: String { rawValue }

    /// The pane's heading.
    var title: String {
        switch self {
        case .thisMac: L10n.text("settings.thisMac", fallback: "This Mac")
        case .devices: L10n.text("settings.devicesPermissions", fallback: "Devices and permissions")
        case .clipboard: L10n.text("settings.clipboard", fallback: "Clipboard")
        case .notifications: L10n.text("settings.notifications", fallback: "Notifications")
        case .messages: L10n.text("sms.title", fallback: "Text messages")
        case .calls: L10n.text("settings.calls", fallback: "Calls")
        case .files: L10n.text("settings.files", fallback: "Files")
        case .media: L10n.text("settings.mediaActions", fallback: "Media and quick actions")
        case .remoteControl: L10n.text("settings.remoteControl", fallback: "Remote control")
        case .privacy: L10n.text("settings.privacy", fallback: "Privacy")
        case .updates: L10n.text("settings.updates", fallback: "Updates")
        case .general: L10n.text("settings.general", fallback: "General")
        case .about: L10n.text("settings.about", fallback: "About")
        case .permissions, .reset: subpageTitle
        case .away: L10n.text("settings.away", fallback: "Connect away from home")
        case .developer: L10n.text("settings.developer", fallback: "Developer and experimental")
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
        case .messages: "message"
        case .calls: "phone"
        case .files: "folder"
        case .media: "music.note"
        case .remoteControl: "cursorarrow.rays"
        case .privacy: "hand.raised"
        case .updates: "arrow.triangle.2.circlepath"
        case .general: "gearshape"
        case .about: "info.circle"
        case .permissions: "lock.shield"
        case .reset: "arrow.counterclockwise"
        case .away: "globe"
        case .developer: "hammer"
        }
    }

    /// The sidebar list; This Mac is the compact header above it.
    static let sidebarItems: [SettingsPane] = allCases.filter { $0 != .thisMac && $0 != .developer && $0.parentPane == nil }

    /// The sidebar with Developer and experimental at the end while it is on.
    static func sidebar(developer: Bool) -> [SettingsPane] { developer ? sidebarItems + [.developer] : sidebarItems }
}

struct SettingsModel {
    var deviceName = "Mac"
    var state: PairingState = .idle
    /// The pairing in progress only (setup's pair step draws it).
    var pairingFlow: PairingState = .idle
    /// Connected phones; more than one shows as a count.
    var connectedCount = 0
    var trustedDevices: [TrustedDeviceInfo] = []
    var rings: [DeviceRing] = []
    /// Connected phones that can run the speed test (they advertise files_fast_draft1).
    var speedPhones: [SpeedPhone] = []
    /// The hidden Developer and experimental pane is on (DeveloperMenu.swift); never synced.
    var developerMenu = false
    /// Developer pane: how files travel to each connected phone.
    var transferPaths: [TransferPathRow] = []
    var globalFeatures: [BridgeyFeature: Bool] = [:]
    var deviceFeatures: [String: [BridgeyFeature: Bool]] = [:]
    var remoteFeatures: [BridgeyFeature: Bool] = [:]
    /// Each connected phone's own feature state.
    var phoneFeatures: [String: [BridgeyFeature: Bool]] = [:]
    var autoClipboard = true
    var autoClipboardDevices: [String: Bool] = [:]
    var clipboardFiles = true
    var clipboardEagerLimit: ClipboardEagerLimit = .default
    var folderIncludeHidden = false
    var folderIncludeSystem = false
    var folderReceiveMode: MacFolderReceiveMode = .fixed
    var folderConflictPolicy: MacFolderConflictPolicy = .ask
    var tagReceivedFiles = false
    var launchAtLogin = false
    var loginItemMessage: String?
    var receiveFolderPath = ""
    var notificationsAuthorized = true
    var notificationPermissionDetermined = true
    var historyEnabled = false
    var history: [NotificationHistoryItem] = []
    /// Notifications > Codes from messages.
    var codesEnabled = false
    var codesAutoCopy = false
    var codesFloat: CodeFloatSetting = .default
    /// The build has a relay address (rr-edition.properties OTP_PROXY_URL).
    var codesAvailable = true
    var codesEngine: CodeEngine = .local
    /// On this Mac: the model's download and state.
    var codeModel = CodeModelDisplay()
    var codeAccess: CodeAccessDisplay = .noPhone
    var codeLinkStatus: String?
    var shortcutKeys: [ShortcutAction: String] = [:]
    var shortcutShift = false
    var shortcutError: String?
    var mediaPlayer: MediaPlayer = .off
    var pauseForCalls = false
    var ringForCalls = true
    var otherAppCallPolicy: MacOtherAppCallPolicy = .ask
    var logging = LoggingPolicy()
    var mediaDetail = ""
    var showPreviews = true
    var reduceMotion = false
    var activityCount = 0
    var channel: UpdateChannel = .stable
    var automaticallyChecks = false
    var lastCheck: Date?
    var updatesAvailable = false
    var canCheckForUpdates = false
    var updateFlow: UpdateFlow = .idle
    var updateDeferral: UpdateDeferral?
    /// Update all: this Mac and its connected phones; and whether phones may start this Mac's update.
    var updateAll = UpdateAllDisplay()
    var remoteStartUpdates = true
    /// Update all devices automatically: the switch and its status lines.
    var autoUpdate = AutoUpdateDisplay()
    var shortVersion = "Development"
    var versionDescription = "Development"
    var phoneLinkStatus: String?
    /// "Look for devices again": running, and its feedback line.
    var rediscovering = false
    var rediscoverStatus: String?
    var now = Date()
    /// Remote control: the running session, Accessibility, and the private session log.
    var remoteSession: RemoteInputHost.ActiveSession?
    var accessibilityTrusted = false
    var remoteAudit: [RemoteControlAuditEntry] = []
    /// Permissions and Reset (SetupCenter).
    var setup = SetupSettingsModel()
    /// Media and actions > Mac actions: what phones may run, the Shortcuts on this Mac (nil until
    /// read), and the private action log.
    var macActions = MacActionsConfig()
    var availableShortcuts: [String]?
    var macActionsAudit: [MacActionAuditEntry] = []
    /// Media and actions > Open links from phones right away.
    var openLinksRightAway = false
    /// Devices > [phone] > Connection health.
    var health: [String: ConnectionHealthSnapshot] = [:]
    /// Devices > [phone] > Battery alerts; a missing phone uses the defaults.
    var batteryAlerts: [String: BatteryAlertThresholds] = [:]
    /// Notifications > Focus.
    var focusSync = FocusSyncSettings()
    /// Files > Copy photos from the phone camera to the clipboard.
    var cameraCopyToClipboard = false
    /// Remote control > Show phone screens (screen_draft1). Off by default.
    var phoneScreenEnabled = false
    /// Settings > Text messages (draft sms_draft1).
    var smsEnabled = false
    var smsKeepOnMac = true
    var smsPhone: SmsPhoneDisplay = .noPhone
    /// General > Sync settings with paired devices, and each phone's own switch (missing is on).
    var settingsSyncEnabled = true
    var settingsSyncDevices: [String: Bool] = [:]
    /// Each connected phone's settings_sync_draft1, once its features arrived.
    var phoneSettingsSync: [String: Bool] = [:]
    /// Choose what syncs: settings kept on this Mac.
    var syncExcluded: Set<SyncKey> = []
    /// What each synced row shows under it (waiting for permission, different on a phone).
    var syncStatus: [SyncKey: SyncRowStatus] = [:]
    /// A paired device turned Codes from messages on; it waits for this Mac's own consent.
    var codesPendingSync = false
    /// Devices > Connect away from home: the switch and the core's state.
    var connectAway = false
    var connect = ConnectDisplay()

    var connectedDeviceID: String? {
        if case let .connected(id, _) = state { return id }
        return nil
    }

    func isEnabled(_ feature: BridgeyFeature, for deviceID: String) -> Bool {
        if feature.needsDeviceGrant { return globalFeatures[feature] == true && remoteGrant(for: deviceID) }
        return globalFeatures[feature] != false && deviceFeatures[deviceID]?[feature] != false
    }

    /// Remote control is granted to each phone on its own; nothing is granted by default.
    func remoteGrant(for deviceID: String) -> Bool {
        deviceFeatures[deviceID]?[.remoteInput] == true
    }

    func isAutoClipboardEnabled(for deviceID: String) -> Bool {
        autoClipboard && autoClipboardDevices[deviceID] != false
    }

    func isSettingsSyncEnabled(for deviceID: String) -> Bool {
        settingsSyncEnabled && settingsSyncDevices[deviceID] != false
    }

    /// The row's value is kept the same on paired devices (sync on, and the setting not kept on this Mac).
    func syncs(_ key: SyncKey?) -> Bool {
        guard let key else { return false }
        return settingsSyncEnabled && !syncExcluded.contains(key)
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
    var setClipboardFiles: (Bool) -> Void = { _ in }
    var setClipboardEagerLimit: (ClipboardEagerLimit) -> Void = { _ in }
    var setFolderIncludeHidden: (Bool) -> Void = { _ in }
    var setFolderIncludeSystem: (Bool) -> Void = { _ in }
    var setFolderReceiveMode: (MacFolderReceiveMode) -> Void = { _ in }
    var setFolderConflictPolicy: (MacFolderConflictPolicy) -> Void = { _ in }
    var setTagReceivedFiles: (Bool) -> Void = { _ in }
    /// Opens the Phone files window on a phone (Devices page).
    var openPhoneFiles: (String) -> Void = { _ in }
    var forget: (String) -> Void = { _ in }
    var pair: (DeviceRing) -> Void = { _ in }
    var retryDevice: (String) -> Void = { _ in }
    var lookForDevices: () -> Void = {}
    var enableNotifications: () -> Void = {}
    var setHistoryEnabled: (Bool) -> Void = { _ in }
    var setCodesEnabled: (Bool) -> Void = { _ in }
    var setCodesAutoCopy: (Bool) -> Void = { _ in }
    var setCodesFloat: (CodeFloatSetting) -> Void = { _ in }
    var setCodesEngine: (CodeEngine) -> Void = { _ in }
    /// Records the acceptance of the model's terms, then downloads the newest model.
    var acceptAndDownloadCodeModel: () -> Void = {}
    /// An update whose terms were already accepted.
    var downloadCodeModel: () -> Void = {}
    var pauseCodeModel: () -> Void = {}
    var resumeCodeModel: () -> Void = {}
    var cancelCodeModel: () -> Void = {}
    var retryCodeModel: () -> Void = {}
    var removeCodeModel: () -> Void = {}
    var testCodeModel: () -> Void = {}
    /// Free space and the manifest (for updates), when the card appears.
    var refreshCodeModel: () -> Void = {}
    var linkPhone: () -> Void = {}
    var clearHistory: () -> Void = {}
    var setShortcut: (ShortcutAction, String) -> Void = { _, _ in }
    var setShortcutShift: (Bool) -> Void = { _ in }
    var setPlayer: (MediaPlayer) -> Void = { _ in }
    var setPauseForCalls: (Bool) -> Void = { _ in }
    var setRingForCalls: (Bool) -> Void = { _ in }
    var setOtherAppCallPolicy: (MacOtherAppCallPolicy) -> Void = { _ in }
    var setLogging: (LoggingPolicy) -> Void = { _ in }
    var clearLogs: () -> Void = {}
    var refreshPlayer: () -> Void = {}
    var setShowPreviews: (Bool) -> Void = { _ in }
    var clearActivity: () -> Void = {}
    var exportDiagnostics: () -> Void = {}
    var setReduceMotion: (Bool) -> Void = { _ in }
    var usePhoneLinks: () -> Void = {}
    var setChannel: (UpdateChannel) -> Void = { _ in }
    var setAutomaticallyChecks: (Bool) -> Void = { _ in }
    var checkForUpdates: () -> Void = {}
    var update = UpdateFlowActions()
    var updateAll = UpdateAllActions()
    var setRemoteStartUpdates: (Bool) -> Void = { _ in }
    var setAutoUpdate: (Bool) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var stopRemoteControl: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var clearRemoteAudit: () -> Void = {}
    /// Permissions, Reset and Run setup again (SetupCenter).
    var setup = SetupSettingsActions()
    var setMacActionSwitch: (MacActionSwitch, Bool) -> Void = { _, _ in }
    var addMacActionApps: () -> Void = {}
    var removeMacActionApp: (String) -> Void = { _ in }
    var addMacActionShortcut: (String) -> Void = { _ in }
    var removeMacActionShortcut: (String) -> Void = { _ in }
    var clearMacActionsAudit: () -> Void = {}
    var setOpenLinksRightAway: (Bool) -> Void = { _ in }
    var setBatteryAlerts: (String, BatteryAlertThresholds) -> Void = { _, _ in }
    var setFocusSync: ((inout FocusSyncSettings) -> Void) -> Void = { _ in }
    var setCameraCopyToClipboard: (Bool) -> Void = { _ in }
    var setPhoneScreen: (Bool) -> Void = { _ in }
    /// Settings > Text messages.
    var setSmsEnabled: (Bool) -> Void = { _ in }
    var setSmsKeepOnMac: (Bool) -> Void = { _ in }
    var deleteMessages: () -> Void = {}
    /// The Messages window, on a phone and conversation when given (the history's Reply).
    var openMessages: (String?, Int?) -> Void = { _, _ in }
    var setSettingsSync: (Bool) -> Void = { _ in }
    var setSettingsSyncForDevice: (String, Bool) -> Void = { _, _ in }
    /// Choose what syncs.
    var setSyncs: (SyncKey, Bool) -> Void = { _, _ in }
    /// "Different on <phone>": send this Mac's value to every phone.
    var applyToAll: (SyncKey) -> Void = { _ in }
    /// "On, waiting for permission": open where it is allowed.
    var allowPermission: (SyncKey) -> Void = { _ in }
    var setConnectAway: (Bool) -> Void = { _ in }
    /// About > Version: counts toward the Developer and experimental pane, or opens it once on.
    var versionTapped: () -> DeveloperMenu.Tap = { .counting }
    /// Developer and experimental > Hide this pane.
    var turnOffDeveloper: () -> Void = {}
    var resetConnectIdentity: () -> Void = {}
    /// Debug only (BridgeyConnectDebug): the control service URL and relay only.
    var setConnectControlURL: (String) -> Void = { _ in }
    var setConnectRelayOnly: (Bool) -> Void = { _ in }
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
                        SettingsBackButton(pane: $pane)
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
            // Updates links to the offered release's notes in its status card; elsewhere only About links to them.
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
            ForEach(SettingsPane.sidebar(developer: model.developerMenu)) { item in
                Button {
                    select(item)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(item == pane.sidebarPane ? side.tbi : side.on2)
                            .frame(width: 18)
                        Text(item.sidebarTitle)
                            .font(BrandFont.body(13, .medium))
                            .foregroundStyle(side.on)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(item == pane.sidebarPane ? side.tb : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == pane.sidebarPane ? .isSelected : [])
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
    if model.connectedCount > 1 {
        return String(format: L10n.text("thisMac.connectedMany", fallback: "Connected to %d devices"), model.connectedCount)
    }
    return switch model.state {
    case let .connected(_, name): String(format: L10n.text("thisMac.connected", fallback: "Connected to %@"), name)
    case let .connecting(name), let .waitingForAllow(name): String(format: L10n.text("panel.connecting", fallback: "Connecting to %@"), name)
    case let .verification(prompt): String(format: L10n.text("panel.connecting", fallback: "Connecting to %@"), prompt.peerName)
    case .failed: L10n.text("thisMac.failed", fallback: "Couldn\u{2019}t connect")
    case .idle, .paired: L10n.text("thisMac.idle", fallback: "Not connected")
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
    /// Settings sync: this row changes the other devices too.
    var synced = false
    @ViewBuilder let trailing: Trailing
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            RowText(title: title, subtitle: subtitle, warning: subtitleIsWarning, synced: synced)
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
    /// A small sync mark after the title: the row is kept the same on paired devices.
    var synced = false
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                if synced { SyncedMark() }
            }
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
    var synced = false
    let isOn: Bool
    let set: (Bool) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            RowText(title: title, subtitle: subtitle, warning: subtitleIsWarning, synced: synced)
        }
        .toggleStyle(BrandSwitchStyle())
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
    }
}

/// Settings sync's mark on a row whose value paired devices share.
struct SyncedMark: View {
    @Environment(\.brand) private var c

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(c.on2)
            .help(L10n.text("settings.sync.mark", fallback: "Synced with your devices"))
            .accessibilityLabel(L10n.text("settings.sync.mark", fallback: "Synced with your devices"))
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
        case .messages: TextMessagesPane(model: model, actions: actions)
        case .calls: CallsPane(model: model, actions: actions)
        case .files: FilesPane(model: model, actions: actions)
        case .media: MediaActionsPane(model: model, actions: actions)
        case .remoteControl: RemoteControlPane(model: model, actions: actions)
        case .privacy: PrivacyPane(model: model, actions: actions)
        case .updates: UpdatesPane(model: model, actions: actions)
        case .general: GeneralPane(model: model, actions: actions)
        case .about: AboutPane(model: model, actions: actions)
        case .permissions: PermissionsPane(model: model, actions: actions)
        case .reset: ResetPane(model: model, actions: actions)
        case .away: ConnectAwayPane(model: model, actions: actions)
        case .developer: DeveloperPane(model: model, actions: actions)
        }
    }
}

struct AutoClipboardToggle: View {
    let isOn: Bool
    var subtitle: String?
    var subtitleIsWarning = false
    /// Only the global switch syncs; a device's own switch never does.
    var synced = false
    let set: (Bool) -> Void

    var body: some View {
        SettingsToggle(title: L10n.text("settings.autoClipboard", fallback: "Automatic clipboard"),
                       subtitle: subtitle ?? L10n.text("settings.autoClipboard.detail", fallback: "Copy on one device, paste on the other."),
                       subtitleIsWarning: subtitleIsWarning, synced: synced,
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
        let key = SyncKey.key(for: feature)
        SettingsToggle(title: feature.title, subtitle: feature.subtitle, divider: divider, synced: model.syncs(key),
                       isOn: model.globalFeatures[feature] != false,
                       set: { actions.setGlobal(feature, $0) })
        if let key { SyncStatusLine(key: key, model: model, actions: actions) }
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
        let clipboardOn = model.globalFeatures[.clipboard] != false
        SettingsCard(footnote: L10n.text("settings.autoClipboard.note", fallback: "Works while both devices are connected and Clipboard is on for both. Passwords and other concealed clips are never sent. With an older Bridgey on the other device, or with Copy images and files off, only text up to 32 KiB moves.")) {
            FeatureSwitch(feature: .clipboard, model: model, actions: actions)
            AutoClipboardToggle(isOn: model.autoClipboard, synced: model.syncs(.autoClipboard), set: actions.setAutoClipboard)
                .disabled(!clipboardOn)
            SyncStatusLine(key: .autoClipboard, model: model, actions: actions)
            SettingsToggle(title: L10n.text("settings.clipboardFiles", fallback: "Copy images and files"),
                           subtitle: L10n.text("settings.clipboardFiles.detail", fallback: "Images, videos, files and long text. Big items move when you paste."),
                           synced: model.syncs(.clipboardFiles), isOn: model.clipboardFiles, set: actions.setClipboardFiles)
                .disabled(!clipboardOn)
            SyncStatusLine(key: .clipboardFiles, model: model, actions: actions)
            SettingsRow(title: L10n.text("settings.clipboardEager", fallback: "Send right away up to"),
                        subtitle: L10n.text("settings.clipboardEager.detail", fallback: "Smaller copies move as soon as you copy, so pasting is instant.")) {
                ChoiceButton(value: eagerLimitTitle(model.clipboardEagerLimit)) {
                    ClipboardEagerLimit.allCases.map { limit in
                        PopUpMenuItem(title: eagerLimitTitle(limit), checked: limit == model.clipboardEagerLimit) {
                            actions.setClipboardEagerLimit(limit)
                        }
                    }
                }
            }
            .disabled(!clipboardOn || !model.clipboardFiles)
            .opacity(clipboardOn && model.clipboardFiles ? 1 : 0.5)
        }
        ShortcutsCard(model: model, actions: actions, only: [.clipboard])
    }
}

func eagerLimitTitle(_ limit: ClipboardEagerLimit) -> String {
    switch limit {
    case .fiveMB: L10n.text("settings.clipboardEager.5", fallback: "5 MB")
    case .twentyFiveMB: L10n.text("settings.clipboardEager.25", fallback: "25 MB")
    case .hundredMB: L10n.text("settings.clipboardEager.100", fallback: "100 MB")
    case .askWhenPasting: L10n.text("settings.clipboardEager.ask", fallback: "Always ask when pasting")
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
        CodesCard(model: model, actions: actions)
        FocusSyncCard(model: model, actions: actions)
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
            OtherAppCallsRow(model: model, actions: actions)
            RingForCallsToggle(model: model, actions: actions)
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
        SettingsCard(footnote: L10n.text("settings.folders.note", fallback: "These are the defaults; the send sheet can change them for one folder. Links and Finder aliases are never sent.")) {
            SettingsToggle(title: L10n.text("settings.folders.hidden", fallback: "Include hidden files when sending folders"),
                           subtitle: L10n.text("settings.folders.hidden.detail", fallback: "Files and folders whose names start with a dot, such as .gitignore or .config."),
                           divider: false, synced: model.syncs(.folderIncludeHidden), isOn: model.folderIncludeHidden, set: actions.setFolderIncludeHidden)
            SyncStatusLine(key: .folderIncludeHidden, model: model, actions: actions)
            SettingsToggle(title: L10n.text("settings.folders.system", fallback: "Include system files when sending folders"),
                           subtitle: L10n.text("settings.folders.system.detail", fallback: "Clutter the system makes, such as .DS_Store, ._ files and Thumbs.db."),
                           synced: model.syncs(.folderIncludeSystem), isOn: model.folderIncludeSystem, set: actions.setFolderIncludeSystem)
            SyncStatusLine(key: .folderIncludeSystem, model: model, actions: actions)
        }
        SettingsCard(footnote: L10n.text("settings.folders.receive.note", fallback: "Folders from your phone keep their structure. Received files get a Where from line in Finder.")) {
            SettingsRow(title: L10n.text("settings.folders.receive", fallback: "Folders sent to this Mac"),
                        subtitle: nil, divider: false, synced: model.syncs(.folderDestination)) {
                ChoiceButton(value: folderReceiveModeTitle(model.folderReceiveMode)) {
                    MacFolderReceiveMode.allCases.map { mode in
                        PopUpMenuItem(title: folderReceiveModeTitle(mode), checked: mode == model.folderReceiveMode) { actions.setFolderReceiveMode(mode) }
                    }
                }
            }
            SyncStatusLine(key: .folderDestination, model: model, actions: actions)
            SettingsRow(title: L10n.text("settings.folders.conflict", fallback: "When a folder already exists"), subtitle: nil,
                        synced: model.syncs(.folderConflict)) {
                ChoiceButton(value: folderConflictTitle(model.folderConflictPolicy)) {
                    MacFolderConflictPolicy.allCases.map { policy in
                        PopUpMenuItem(title: folderConflictTitle(policy), checked: policy == model.folderConflictPolicy) { actions.setFolderConflictPolicy(policy) }
                    }
                }
            }
            SyncStatusLine(key: .folderConflict, model: model, actions: actions)
            SettingsToggle(title: L10n.text("settings.files.tag", fallback: "Tag received files in Finder"),
                           subtitle: L10n.text("settings.files.tag.detail", fallback: "Adds the Bridgey tag, so Finder can list everything that came from your phone."),
                           isOn: model.tagReceivedFiles, set: actions.setTagReceivedFiles)
        }
        SettingsCard(footnote: L10n.text("camera.settings.note", fallback: "In the menu bar panel, File > Take Photo with your phone. The phone opens its camera once it is unlocked; the photo lands in Received files.")) {
            SettingsToggle(title: L10n.text("camera.settings.clipboard", fallback: "Copy photos from the phone camera to the clipboard"),
                           subtitle: L10n.text("camera.settings.clipboard.detail", fallback: "Ready to paste as soon as the photo arrives"),
                           divider: false, isOn: model.cameraCopyToClipboard, set: actions.setCameraCopyToClipboard)
        }
        // Send options (Before sending, menu-bar drops): SendOptionsSettings.swift.
        SendOptionsSettingsSection()
    }
}

func folderReceiveModeTitle(_ mode: MacFolderReceiveMode) -> String {
    switch mode {
    case .fixed: return L10n.text("settings.folders.receive.fixed", fallback: "Always save to Received files")
    case .ask: return L10n.text("settings.folders.receive.ask", fallback: "Ask on this Mac each time")
    }
}

func folderConflictTitle(_ policy: MacFolderConflictPolicy) -> String {
    switch policy {
    case .ask: return L10n.text("settings.folders.conflict.ask", fallback: "Ask each time")
    case .merge: return L10n.text("settings.folders.conflict.merge", fallback: "Merge")
    case .replace: return L10n.text("settings.folders.conflict.replace", fallback: "Replace files")
    case .newFolder: return L10n.text("settings.folders.conflict.newFolder", fallback: "Save as new folder")
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
                if feature == .links {
                    SettingsToggle(title: L10n.text("settings.links.openRightAway", fallback: "Open links from phones right away"),
                                   subtitle: L10n.text("settings.links.openRightAway.detail", fallback: "Open on Mac from the phone\u{2019}s share sheet opens the link in your browser. Off: it waits for you to open it here."),
                                   isOn: model.openLinksRightAway, set: actions.setOpenLinksRightAway)
                        .disabled(model.globalFeatures[.links] == false)
                }
            }
        }
        MacActionsCards(model: model, actions: actions)
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
                           synced: model.syncs(.reduceMotion), isOn: model.reduceMotion, set: actions.setReduceMotion)
            SyncStatusLine(key: .reduceMotion, model: model, actions: actions)
            SettingsToggle(title: L10n.text("settings.shortcuts.shift", fallback: "Also require Shift for shortcuts"),
                           isOn: model.shortcutShift, set: actions.setShortcutShift)
        }
        SettingsSyncCard(model: model, actions: actions)
        RunSetupAgainCard(actions: actions)
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
        case .remoteInput: L10n.text("feature.remoteInput.detail", fallback: "Let a phone you allow move the pointer, type and change slides")
        case .macActions: L10n.text("feature.macActions.detail", fallback: "Lock, sleep, volume, apps and Shortcuts from a phone you allow")
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
        SettingsCard {
            SettingsRow(
                title: L10n.text("panel.lookAgain", fallback: "Look for devices again"),
                subtitle: model.rediscoverStatus ?? L10n.text("devices.lookAgain.detail", fallback: "Announces this Mac again and retries every paired device now"),
                divider: false
            ) {
                Button(L10n.text("devices.lookAgain.action", fallback: "Look again")) { actions.lookForDevices() }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                    .disabled(model.rediscovering)
            }
        }
        ConnectAwayCard(model: model, actions: actions)
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
                RowText(title: device.name, subtitle: ring.map { ringStatusDetail($0, now: model.now) } ?? L10n.text("ring.offline", fallback: "Offline"))
                if let chip = routeChipText(model.health[device.id]) { RouteChip(text: chip) }
                if ring?.canRetry == true {
                    Button(L10n.text("panel.retryNow", fallback: "Retry now")) { actions.retryDevice(device.id) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                        .help(ring.map(ringRetryHelp) ?? "")
                }
                // Phone files window (Files 2.0): PhoneFilesDeviceEntry.swift.
                PhoneFilesDeviceEntry(deviceID: device.id, model: model, actions: actions)
                Button(L10n.text("action.forget", fallback: "Forget")) { confirmForget = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
            }
            .padding(.vertical, 8)
            Text(String(format: L10n.text("devices.permissions.intro", fallback: "What this Mac shares with %@."), device.name))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .padding(.bottom, 4)
            ConnectionHealthRow(health: model.health[device.id], now: model.now)
            ForEach(BridgeyFeature.allCases.filter { !$0.needsDeviceGrant }) { feature in
                SettingsToggle(
                    title: feature.title,
                    subtitle: note(feature),
                    subtitleIsWarning: note(feature) != nil,
                    isOn: model.isEnabled(feature, for: device.id),
                    set: { actions.setForDevice(device.id, feature, $0) }
                )
                .disabled(model.globalFeatures[feature] == false)
                if feature == .battery {
                    BatteryAlertsRow(thresholds: model.batteryAlerts[device.id] ?? .default,
                                     enabled: model.isEnabled(.battery, for: device.id)) { actions.setBatteryAlerts(device.id, $0) }
                }
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
            // Granted on its own, off by default; see Settings > Remote control.
            RemoteControlGrantToggle(device: device, model: model, actions: actions)
            // The same for Mac actions; see Settings > Media and actions.
            MacActionsGrantToggle(device: device, model: model, actions: actions)
            SettingsSyncDeviceToggle(device: device, model: model, actions: actions)
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
        let remote = model.phoneFeatures[device.id] ?? (model.connectedDeviceID == device.id ? model.remoteFeatures : [:])
        if remote[feature] == false {
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

/// Settings > Calls > When another app asks to call: tel: links and the Call with Bridgey Service.
struct OtherAppCallsRow: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsRow(title: L10n.text("settings.calls.otherApps", fallback: "When another app asks to call"),
                    subtitle: L10n.text("settings.calls.otherApps.detail", fallback: "Covers tel: links and the Call with Bridgey RR item in the Services menu. Calls you start in Bridgey go through without asking.")) {
            ChoiceButton(value: otherAppCallPolicyTitle(model.otherAppCallPolicy)) {
                MacOtherAppCallPolicy.allCases.map { policy in
                    PopUpMenuItem(title: otherAppCallPolicyTitle(policy), checked: policy == model.otherAppCallPolicy) { actions.setOtherAppCallPolicy(policy) }
                }
            }
        }
    }
}

func otherAppCallPolicyTitle(_ policy: MacOtherAppCallPolicy) -> String {
    switch policy {
    case .ask: return L10n.text("settings.calls.otherApps.ask", fallback: "Ask every time")
    case .callNow: return L10n.text("settings.calls.otherApps.callNow", fallback: "Call right away")
    case .refuse: return L10n.text("settings.calls.otherApps.refuse", fallback: "Don\u{2019}t allow")
    }
}

struct RingForCallsToggle: View {
    let model: SettingsModel
    let actions: SettingsActions
    var divider = true

    var body: some View {
        SettingsToggle(title: L10n.text("settings.calls.ring", fallback: "Ring for incoming calls"),
                       subtitle: L10n.text("settings.calls.ring.detail", fallback: "A soft ring repeats until you answer, decline or hide the call."),
                       divider: divider, isOn: model.ringForCalls, set: actions.setRingForCalls)
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
                            // Text messages: Reply opens the conversation in the Messages window.
                            if model.smsEnabled, item.opensConversation {
                                Button(L10n.text("sms.reply", fallback: "Reply")) { actions.openMessages(item.deviceID, item.smsThreadID) }
                                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 24))
                                    .padding(.top, 4)
                            }
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

/// Settings > Text messages, its own page as on the phone (Rahul, 2026-10-27). One card per topic, so
/// later phone features that belong with texts (call settings, for example) join as cards of their own
/// without reshaping the page.
struct TextMessagesPane: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        TextMessagesCard(model: model, actions: actions)
        if model.smsEnabled { TextMessagesStorageCard(model: model, actions: actions) }
    }
}

/// Text messages: the switch, the phone's state and the Messages window.
struct TextMessagesCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            SettingsToggle(title: L10n.text("sms.toggle", fallback: "Your phone\u{2019}s texts on this Mac"),
                           subtitle: L10n.text("sms.toggle.detail", fallback: "Read and answer conversations in the Messages window, and reply from text notifications. Off by default. Messages travel only between your phone and this Mac, encrypted; Bridgey never becomes the phone\u{2019}s default SMS app."),
                           divider: false, synced: model.syncs(.featureSms), isOn: model.smsEnabled, set: actions.setSmsEnabled)
            SyncStatusLine(key: .featureSms, model: model, actions: actions)
            if model.smsEnabled {
                SettingsRow(title: phoneTitle, subtitle: phoneDetail, subtitleIsWarning: phoneWarning, divider: true) {
                    Button(L10n.text("sms.open", fallback: "Open Messages")) { actions.openMessages(nil, nil) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
                SettingsRow(title: L10n.text("sms.limits", fallback: "Group conversations and pictures"),
                            subtitle: L10n.text("sms.limits.detail", fallback: "You can read them here. Reply to groups and send pictures from your phone."), divider: true) { EmptyView() }
            }
        }
    }

    private var phoneTitle: String {
        switch model.smsPhone {
        case .noPhone: L10n.text("sms.state.noPhone", fallback: "No phone connected")
        case let .phoneOff(name), let .waiting(name), let .ready(name, _): name
        }
    }

    private var phoneWarning: Bool {
        switch model.smsPhone {
        case .phoneOff: true
        case let .ready(_, status): !status.read
        default: false
        }
    }

    private var phoneDetail: String {
        switch model.smsPhone {
        case .noPhone: return L10n.text("sms.state.noPhone.detail", fallback: "Conversations show while your phone is connected.")
        case .phoneOff: return L10n.text("sms.state.phoneOff", fallback: "Off on the phone. Turn on Text messages in Bridgey there.")
        case .waiting: return L10n.text("sms.state.waiting", fallback: "Waiting for the phone\u{2026}")
        case let .ready(_, status):
            guard status.read else { return L10n.text("sms.state.permission", fallback: "SMS is not allowed on the phone yet. Allow it on Bridgey\u{2019}s Permissions page there.") }
            var lines = [status.send ? L10n.text("sms.state.ready", fallback: "Reading and sending allowed")
                                     : L10n.text("sms.state.readOnly", fallback: "Reading allowed; sending is not allowed on the phone")]
            if !status.contacts { lines.append(L10n.text("sms.state.noContacts", fallback: "Names hidden until Contacts is allowed on the phone")) }
            if status.sims.count > 1 {
                lines.append(String(format: L10n.text("sms.state.sims", fallback: "SIMs: %@"), status.sims.map(simTitle).joined(separator: ", ")))
            }
            return lines.joined(separator: ". ")
        }
    }
}

/// Text messages > On this Mac: the cache and deleting it.
struct TextMessagesStorageCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmDelete = false

    var body: some View {
        SettingsCard(title: L10n.text("sms.onThisMac", fallback: "On this Mac")) {
            SettingsToggle(title: L10n.text("sms.keep", fallback: "Keep conversations on this Mac"),
                           subtitle: L10n.text("sms.keep.detail", fallback: "Up to 200 conversations, readable only by your account, so they open instantly. Off: they load from the phone each time. Images are never kept."),
                           divider: false, isOn: model.smsKeepOnMac, set: actions.setSmsKeepOnMac)
            SettingsRow(title: L10n.text("sms.delete", fallback: "Delete messages on this Mac"),
                        subtitle: L10n.text("sms.delete.detail", fallback: "Your phone keeps every message."), divider: true) {
                Button(L10n.text("sms.delete.button", fallback: "Delete")) { confirmDelete = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
            }
        }
        .confirmationDialog(L10n.text("sms.delete.confirm", fallback: "Delete messages on this Mac?"), isPresented: $confirmDelete) {
            Button(L10n.text("sms.delete.button", fallback: "Delete"), role: .destructive, action: actions.deleteMessages)
        } message: {
            Text(L10n.text("sms.delete.detail", fallback: "Your phone keeps every message."))
        }
    }
}

struct PrivacyPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmClear = false

    var body: some View {
        PrivacyPermissionsCard(model: model, actions: actions)
        SettingsCard(title: L10n.text("settings.activity", fallback: "Activity")) {
            SettingsToggle(title: L10n.text("settings.previews", fallback: "Show previews in activity"),
                           subtitle: L10n.text("settings.previews.detail", fallback: "Clipboard text, app names and callers. Off keeps only what happened."),
                           divider: false, synced: model.syncs(.activityPreviews), isOn: model.showPreviews, set: actions.setShowPreviews)
            SyncStatusLine(key: .activityPreviews, model: model, actions: actions)
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
        LoggingCard(model: model, actions: actions)
        PrivacyResetCard(actions: actions)
    }
}

/// Settings > Privacy > Logging: a switch per category, content switches under their category,
/// then Export diagnostics and Clear logs. Per Mac.
struct LoggingCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmClear = false

    private var policy: LoggingPolicy { model.logging }

    private func set(_ change: (inout LoggingPolicy) -> Void) {
        var next = policy
        change(&next)
        actions.setLogging(next)
    }

    var body: some View {
        SettingsCard(
            title: L10n.text("settings.logging", fallback: "Logging"),
            footnote: L10n.text("settings.logging.note", fallback: "Logs stay on this device; you choose what goes into exported diagnostics. Names and text only reach the local log.")
        ) {
            Group {
            SettingsToggle(title: L10n.text("settings.logging.connection", fallback: "Connection events"),
                           subtitle: L10n.text("settings.logging.connection.detail", fallback: "Discovery, pairing, connects and reconnects"),
                           divider: false, isOn: policy.connection) { on in set { $0.connection = on } }
            SettingsToggle(title: L10n.text("settings.logging.calls", fallback: "Call events"),
                           subtitle: L10n.text("settings.logging.calls.detail", fallback: "Call states and the caller\u{2019}s name, so call problems can be traced"),
                           isOn: policy.calls) { on in set { $0.calls = on } }
            SettingsToggle(title: L10n.text("settings.logging.callNumbers", fallback: "Include phone numbers"),
                           subtitle: L10n.text("settings.logging.callNumbers.detail", fallback: "Off masks numbers in call events"),
                           isOn: policy.callNumbers) { on in set { $0.callNumbers = on } }
                .disabled(!policy.calls)
                .padding(.leading, 16)
            SettingsToggle(title: L10n.text("settings.logging.notifications", fallback: "Notification events"),
                           subtitle: L10n.text("settings.logging.notifications.detail", fallback: "Which app posted and what happened to it"),
                           isOn: policy.notifications) { on in set { $0.notifications = on } }
            SettingsToggle(title: L10n.text("settings.logging.notificationContent", fallback: "Notification titles and text"),
                           subtitle: L10n.text("settings.logging.notificationContent.detail", fallback: "Adds what the notification says"),
                           isOn: policy.notificationContent) { on in set { $0.notificationContent = on } }
                .disabled(!policy.notifications)
                .padding(.leading, 16)
            }
            Group {
            SettingsToggle(title: L10n.text("settings.logging.clipboard", fallback: "Clipboard events"),
                           subtitle: L10n.text("settings.logging.clipboard.detail", fallback: "Sends and receipts, without the content"),
                           isOn: policy.clipboard) { on in set { $0.clipboard = on } }
            SettingsToggle(title: L10n.text("settings.logging.clipboardPreviews", fallback: "Clipboard previews"),
                           subtitle: L10n.text("settings.logging.clipboardPreviews.detail", fallback: "Adds the first 40 characters"),
                           isOn: policy.clipboardPreviews) { on in set { $0.clipboardPreviews = on } }
                .disabled(!policy.clipboard)
                .padding(.leading, 16)
            SettingsToggle(title: L10n.text("settings.logging.fileNames", fallback: "File names"),
                           subtitle: L10n.text("settings.logging.fileNames.detail", fallback: "Adds file and folder names to transfer events"),
                           isOn: policy.fileNames) { on in set { $0.fileNames = on } }
            SettingsToggle(title: L10n.text("settings.logging.remote", fallback: "Remote control sessions"),
                           subtitle: L10n.text("settings.logging.remote.detail", fallback: "When a session ends and why; the remote control audit keeps its own record"),
                           isOn: policy.remoteControl) { on in set { $0.remoteControl = on } }
            }
            SettingsRow(title: L10n.text("settings.diagnostics.export", fallback: "Export diagnostics"),
                        subtitle: L10n.text("settings.diagnostics.detail", fallback: "A bounded event log without clipboard text, notification content, file names, addresses or device identifiers.")) {
                Button(L10n.text("action.export", fallback: "Export\u{2026}"), action: actions.exportDiagnostics)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
            SettingsRow(title: L10n.text("settings.logging.clear", fallback: "Clear logs"),
                        subtitle: L10n.text("settings.logging.clear.detail", fallback: "Deletes the diagnostics log on this Mac")) {
                Button(L10n.text("action.clear", fallback: "Clear")) { confirmClear = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
            }
        }
        .confirmationDialog(L10n.text("settings.logging.clear.title", fallback: "Clear logs?"), isPresented: $confirmClear) {
            Button(L10n.text("action.clear", fallback: "Clear"), role: .destructive, action: actions.clearLogs)
        } message: {
            Text(L10n.text("settings.logging.clear.body", fallback: "This deletes the diagnostics log on this Mac. Your other devices keep their own."))
        }
    }
}

struct AboutPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c
    /// "2 more clicks to open the developer pane", for a moment after each click near the end of the count.
    @State private var tapNote: String?

    var body: some View {
        SettingsCard {
            HStack(spacing: 14) {
                AuroraMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Edition.displayName).font(BrandFont.heading(17)).foregroundStyle(c.on)
                    Text(String(format: L10n.text("updates.version", fallback: "Version %@"), model.versionDescription))
                        .font(BrandFont.body(12)).foregroundStyle(c.on2)
                        .contentShape(Rectangle())
                        // Five clicks turn on the Developer and experimental pane; once on, a click opens it.
                        .onTapGesture { versionTapped() }
                        .accessibilityAddTraits(.isButton)
                    if let tapNote {
                        Text(tapNote).font(BrandFont.body(11)).foregroundStyle(c.pri)
                    }
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
        LicencesCard()
    }

    private func versionTapped() {
        switch actions.versionTapped() {
        case .counting:
            tapNote = nil
        case let .remaining(left):
            tapNote = String(format: left == 1
                ? L10n.text("developer.tapsLeft.one", fallback: "%d more click to open the developer pane")
                : L10n.text("developer.tapsLeft", fallback: "%d more clicks to open the developer pane"), left)
        case .unlocked:
            tapNote = L10n.text("developer.on", fallback: "Developer and experimental pane is on")
        case .open:
            tapNote = nil
        }
    }
}

/// Developer and experimental (hidden, DeveloperMenu.swift): tests and facts for people chasing a problem, then the
/// experiments Rahul turns on before they are ready for everyone, then the way to hide the pane again.
struct DeveloperPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        SpeedTestCard(phones: model.speedPhones)
        PerfTestPanel()
        SettingsCard(title: L10n.text("developer.transfers", fallback: "How files travel now")) {
            if model.transferPaths.isEmpty {
                SettingsRow(title: L10n.text("developer.noPhones", fallback: "No phone connected"), subtitle: nil, divider: false) { EmptyView() }
            }
            ForEach(Array(model.transferPaths.enumerated()), id: \.element.id) { index, path in
                SettingsRow(title: path.name, subtitle: Self.describe(path), divider: index > 0) { EmptyView() }
            }
        }
        SettingsCard(title: L10n.text("developer.experimental", fallback: "Experimental features")) {
            SettingsRow(title: L10n.text("developer.experimental.empty", fallback: "Nothing to try right now. New experiments show up here before everyone gets them."),
                        subtitle: nil, divider: false) { EmptyView() }
        }
        SettingsCard {
            SettingsRow(title: L10n.text("developer.hide", fallback: "Hide this pane"),
                        subtitle: L10n.text("developer.hide.detail", fallback: "Click the version in About five times to bring it back"), divider: false) {
                Button(L10n.text("developer.hide.action", fallback: "Hide"), action: actions.turnOffDeveloper)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
        }
    }

    static func describe(_ path: TransferPathRow) -> String {
        let how = path.fast
            ? L10n.text("developer.path.fast", fallback: "Fast transfers: 256 KiB binary frames")
            : L10n.text("developer.path.json", fallback: "24 KiB chunks inside messages, as before fast transfers")
        let route: String
        switch path.tunnelRoute {
        case nil: route = L10n.text("developer.route.local", fallback: "Local network")
        case "relay": route = L10n.text("developer.route.relay", fallback: "Away from home, through a relay")
        default: route = L10n.text("developer.route.direct", fallback: "Away from home, direct")
        }
        return "\(how). \(route)"
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

struct LiveSettingsView: View {
    @ObservedObject var discovery: BonjourDiscovery
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var settings: BridgeySettings
    @ObservedObject var updater: AppUpdater
    @ObservedObject var activity: ActivityLog
    @ObservedObject var media: MediaController
    @ObservedObject var shortcuts: ShortcutSettings
    @ObservedObject var remoteInput: RemoteInputHost
    @ObservedObject var remoteAudit: RemoteControlAuditLog
    @ObservedObject var codeModel: CodeModelStore
    @ObservedObject var setupCenter = SetupCenter.shared
    /// The setup window (SetupWindow.swift) shows the same live settings, one group at a time.
    let inSetup: Bool
    @ObservedObject var macActions: MacActionsHost
    @ObservedObject var macActionsAudit: MacActionsAuditLog
    @ObservedObject var batteryAlerts: BatteryAlerts
    @ObservedObject var focusSync: FocusSync
    @ObservedObject var camera: PhoneCamera
    @ObservedObject var settingsSync: SettingsSyncController
    @ObservedObject var updateAll = UpdateAllCoordinator.shared
    @ObservedObject var autoUpdate = AutoUpdateCoordinator.shared
    @ObservedObject var phoneScreen: PhoneScreen
    @ObservedObject var connect: ConnectAnywhere
    @State private var pane: SettingsPane = .devices
    @State private var availableShortcuts: [String]?
    @State private var phoneLinkStatus: String?
    /// While Remote control is open: notices Accessibility being allowed in System Settings.
    private let accessibilityTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(discovery: BonjourDiscovery, pairing: PairingCoordinator, settings: BridgeySettings, updater: AppUpdater, inSetup: Bool = false) {
        self.discovery = discovery
        self.pairing = pairing
        self.settings = settings
        self.updater = updater
        self.inSetup = inSetup
        activity = pairing.activity
        media = pairing.mediaController
        shortcuts = pairing.shortcuts
        remoteInput = pairing.remoteInput
        remoteAudit = pairing.remoteInput.audit
        codeModel = pairing.codeModel
        macActions = pairing.macActions
        macActionsAudit = pairing.macActions.audit
        batteryAlerts = pairing.batteryAlerts
        focusSync = pairing.focusSync
        camera = pairing.camera
        phoneScreen = pairing.phoneScreen
        settingsSync = pairing.settingsSync
        connect = pairing.connect
    }

    private var codeModelDisplay: CodeModelDisplay {
        var display = CodeModelDisplay()
        display.available = codeModel.isAvailable
        display.manifest = codeModel.manifest
        display.installed = codeModel.installed
        display.download = codeModel.download
        display.update = codeModel.update
        display.availableSpace = codeModel.availableSpace
        display.testResult = codeModel.testResult
        display.testing = codeModel.testing
        display.acceptance = settings.codeModelAcceptances.last
        display.acceptanceCovers = codeModel.manifest.map { settings.codeModelAcceptance(for: $0) != nil } ?? false
        return display
    }

    var body: some View {
        BrandRoot(reduceMotion: settings.reduceMotion) {
            if inSetup {
                SetupWindowView.live(model: model, actions: actions, center: setupCenter)
            } else {
                SettingsWindowView(model: model, actions: actions, pane: $pane)
            }
        }
        .onAppear {
            pairing.refreshNotificationAuthorization()
            settings.refreshLoginItemStatus()
            remoteInput.refreshAccessibility()
            remoteAudit.prune()
            macActionsAudit.prune()
        }
        .onReceive(accessibilityTicker) { _ in
            if pane == .remoteControl || pane == .media { remoteInput.refreshAccessibility() }
        }
        .onChange(of: pane) { shown in
            if shown == .media || shown == .notifications { loadShortcuts() }
        }
    }

    private var model: SettingsModel {
        var model = SettingsModel()
        model.deviceName = settings.deviceName
        model.state = pairing.state
        model.pairingFlow = pairing.pairingFlow
        model.connectedCount = pairing.connectedPhones.count
        model.trustedDevices = pairing.trustedDevices
        model.rings = deviceRings(trusted: pairing.trustedDevices, peers: discovery.peers, connected: pairing.connectedPhones,
                                  pairing: pairing.pairingFlow, reconnecting: pairing.reconnectStates)
        model.speedPhones = pairing.speedPhones.map { SpeedPhone(id: $0.id, name: $0.name) }
        model.developerMenu = DeveloperMenu.shared.enabled || pane == .developer
        model.transferPaths = model.developerMenu ? pairing.transferPaths : []
        model.rediscovering = pairing.isRediscovering
        model.rediscoverStatus = pairing.rediscoverStatus
        model.globalFeatures = settings.globalFeatures
        model.deviceFeatures = settings.deviceFeatures
        model.remoteFeatures = pairing.remoteFeatures
        model.phoneFeatures = Dictionary(pairing.connectedPhones.map { ($0.id, $0.state.remoteFeatures) }, uniquingKeysWith: { $1 })
        model.autoClipboard = settings.autoClipboardEnabled
        model.autoClipboardDevices = settings.autoClipboardDevices
        model.clipboardFiles = settings.clipboardFilesEnabled
        model.folderIncludeHidden = settings.folderIncludeHidden
        model.folderIncludeSystem = settings.folderIncludeSystem
        model.folderReceiveMode = settings.folderReceiveMode
        model.folderConflictPolicy = settings.folderConflictPolicy
        model.tagReceivedFiles = settings.tagReceivedFiles
        model.clipboardEagerLimit = ClipboardEagerLimit(bytes: settings.clipboardEagerLimit)
        model.launchAtLogin = settings.launchAtLogin
        model.loginItemMessage = settings.loginItemMessage
        model.receiveFolderPath = settings.receiveFolderPath
        model.notificationsAuthorized = pairing.notificationsAuthorized
        model.notificationPermissionDetermined = pairing.notificationPermissionDetermined
        model.historyEnabled = settings.notificationHistoryEnabled
        model.history = pairing.notificationHistory
        model.codesEnabled = settings.codesEnabled
        model.codesAutoCopy = settings.codesAutoCopy
        model.codesFloat = settings.codesFloat
        model.codesAvailable = CodeRelay.baseURL != nil
        model.codesEngine = settings.codesEngine
        model.codeModel = codeModelDisplay
        model.codeAccess = pairing.codeAccessForSelectedPhone
        model.codeLinkStatus = pairing.codeLinkStatus
        model.shortcutKeys = shortcuts.keys
        model.shortcutShift = shortcuts.useShift
        model.shortcutError = shortcuts.error
        model.mediaPlayer = media.player
        model.pauseForCalls = media.pauseForCalls
        model.ringForCalls = settings.ringForIncomingCalls
        model.otherAppCallPolicy = settings.otherAppCallPolicy
        model.logging = settings.logging
        model.mediaDetail = media.snapshot.detail
        model.showPreviews = settings.showActivityPreviews
        model.reduceMotion = settings.reduceMotion
        model.activityCount = activity.items.count
        model.channel = updater.channel
        model.automaticallyChecks = updater.automaticallyChecks
        model.lastCheck = updater.lastCheck
        model.updatesAvailable = updater.isAvailable
        model.canCheckForUpdates = updater.canCheckForUpdates
        model.updateFlow = updater.flow
        model.updateDeferral = updater.deferral
        model.updateAll = updateAll.display()
        model.remoteStartUpdates = updateAll.remoteStartAllowed
        model.autoUpdate = AutoUpdateDisplay(enabled: autoUpdate.enabled, choice: autoUpdate.storedChoice, available: updater.isAvailable,
                                             checksOff: !updater.automaticallyChecks, channel: updater.channel,
                                             decision: autoUpdate.decision, lastRun: autoUpdate.lastRun, now: Date())
        model.shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        model.versionDescription = updater.versionDescription
        model.phoneLinkStatus = phoneLinkStatus
        model.now = Date()
        model.remoteSession = remoteInput.active
        model.accessibilityTrusted = remoteInput.accessibilityTrusted
        model.remoteAudit = remoteAudit.entries
        model.setup = setupCenter.settingsModel
        model.macActions = macActions.config
        model.availableShortcuts = availableShortcuts
        model.macActionsAudit = macActionsAudit.entries
        model.openLinksRightAway = settings.openLinksRightAway
        model.health = pairing.connectionHealth
        model.focusSync = focusSync.settings
        model.cameraCopyToClipboard = camera.copyToClipboard
        model.phoneScreenEnabled = phoneScreen.enabled
        model.smsEnabled = settings.smsEnabled
        model.smsKeepOnMac = settings.smsKeepOnMac
        model.smsPhone = pairing.textMessagesDisplay
        model.settingsSyncEnabled = settingsSync.enabled
        model.settingsSyncDevices = settingsSync.devices
        model.syncExcluded = settingsSync.excluded
        model.codesPendingSync = pairing.codesSyncGate.pending
        model.syncStatus = Dictionary(uniqueKeysWithValues: SyncKey.allCases.map { ($0, settingsSync.status($0)) })
        model.phoneSettingsSync = Dictionary(pairing.connectedPhones.filter(\.state.featureStateReceived).map { ($0.id, $0.state.remoteSettingsSync) },
                                             uniquingKeysWith: { $1 })
        model.connectAway = settings.connectAway
        model.connect = pairing.connectDisplay
        model.batteryAlerts = Dictionary(uniqueKeysWithValues: pairing.trustedDevices.map { ($0.id, batteryAlerts.thresholds(for: $0.id)) })
        return model
    }

    private var actions: SettingsActions {
        var actions = SettingsActions()
        actions.versionTapped = {
            let tap = DeveloperMenu.shared.tap()
            if tap == .unlocked || tap == .open { pane = .developer }
            return tap
        }
        actions.turnOffDeveloper = {
            DeveloperMenu.shared.turnOff()
            pane = .about
        }
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
            if feature == .remoteInput { remoteControlChanged(enabled: enabled) }
        }
        actions.setForDevice = { deviceID, feature, enabled in
            settings.setForDevice(deviceID, feature: feature, enabled: enabled)
            if feature == .findDevice && !enabled,
               pairing.connectedPhones.contains(where: { $0.id == deviceID }) { pairing.stopFinding() }
            if feature == .remoteInput { remoteControlChanged(enabled: enabled) }
        }
        actions.stopRemoteControl = { remoteInput.stopLocally() }
        actions.openAccessibilitySettings = { NSWorkspace.shared.open(AccessibilityAccess.settingsURL) }
        actions.clearRemoteAudit = { remoteAudit.clear() }
        actions.setMacActionSwitch = { item, enabled in
            macActions.setSwitch(item, enabled: enabled)
            // Lock needs Accessibility: macOS asks once, when Lock is turned on, never at launch. The
            // Permissions explainer comes first, as for remote control.
            if item == .lock && enabled {
                remoteInput.refreshAccessibility()
                if !remoteInput.accessibilityTrusted { setupCenter.requestAccessibility { AccessibilityAccess.request() } }
            }
        }
        actions.addMacActionApps = { macActions.addApps(chooseAllowedApps()) }
        actions.removeMacActionApp = { macActions.removeApp(bundleID: $0) }
        actions.addMacActionShortcut = { macActions.addShortcut(named: $0) }
        actions.removeMacActionShortcut = { macActions.removeShortcut(id: $0) }
        actions.clearMacActionsAudit = { macActionsAudit.clear() }
        actions.setOpenLinksRightAway = { settings.setOpenLinksRightAway($0) }
        actions.setBatteryAlerts = { id, thresholds in batteryAlerts.setThresholds(thresholds, for: id) }
        actions.setCameraCopyToClipboard = { camera.setCopyToClipboard($0) }
        actions.setPhoneScreen = { phoneScreen.setEnabled($0) }
        actions.setSmsEnabled = { pairing.setTextMessagesEnabled($0) }
        actions.setSmsKeepOnMac = { pairing.setTextMessagesKeepOnMac($0) }
        actions.deleteMessages = { pairing.deleteTextMessagesOnMac() }
        actions.openMessages = { phoneID, threadID in MessagesWindowController.show(pairing: pairing, phoneID: phoneID, threadID: threadID) }
        actions.setSettingsSync = { settingsSync.setEnabled($0) }
        actions.setSettingsSyncForDevice = { id, on in settingsSync.setEnabled(on, for: id) }
        actions.setSyncs = { key, on in settingsSync.setSyncs(key, on) }
        actions.applyToAll = { settingsSync.applyToAll($0) }
        // Codes waits for its own consent step on its card; the others for a system permission.
        actions.allowPermission = { key in pane = key == .codesEnabled ? .notifications : .permissions }
        actions.setConnectAway = { settings.setConnectAway($0) }
        actions.resetConnectIdentity = { pairing.resetConnectIdentity() }
        actions.setConnectControlURL = { url in
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: "BridgeyConnectControlURL") } else { UserDefaults.standard.set(trimmed, forKey: "BridgeyConnectControlURL") }
            if settings.connectAway { connect.stop(); connect.start() }
        }
        actions.setConnectRelayOnly = { connect.setRelayOnly($0) }
        actions.setFocusSync = { change in
            focusSync.update(change)
            if focusSync.settings.follow { loadShortcuts() }
        }
        actions.setAutoClipboard = { settings.setAutoClipboard($0) }
        actions.setAutoClipboardForDevice = { deviceID, enabled in settings.setAutoClipboard(enabled, for: deviceID) }
        actions.setClipboardFiles = { settings.setClipboardFilesEnabled($0) }
        actions.setFolderIncludeHidden = { settings.setFolderIncludeHidden($0) }
        actions.setFolderIncludeSystem = { settings.setFolderIncludeSystem($0) }
        actions.setFolderReceiveMode = { settings.setFolderReceiveMode($0) }
        actions.setFolderConflictPolicy = { settings.setFolderConflictPolicy($0) }
        actions.setTagReceivedFiles = { settings.setTagReceivedFiles($0) }
        actions.setClipboardEagerLimit = { settings.setClipboardEagerLimit($0) }
        actions.forget = { pairing.forget(deviceID: $0) }
        actions.openPhoneFiles = { PhoneFilesWindowController.show(pairing: pairing, phoneID: $0) }
        actions.pair = { ring in
            guard let host = ring.peer?.host, let port = ring.peer?.port else { return }
            pairing.pair(host: host, port: port, peerName: ring.name)
        }
        actions.retryDevice = { pairing.retryNow(deviceID: $0) }
        actions.lookForDevices = { pairing.lookForDevices() }
        actions.enableNotifications = { pairing.enableNotifications() }
        actions.setHistoryEnabled = { settings.setNotificationHistoryEnabled($0) }
        actions.setCodesEnabled = { on in
            // Off from the row that reads on while it waits: the wait ends and the off syncs as a normal edit.
            if !on { pairing.codesSyncGate.turnedOffLocally() }
            settings.setCodesEnabled(on)
        }
        actions.setCodesAutoCopy = { settings.setCodesAutoCopy($0) }
        actions.setCodesFloat = { settings.setCodesFloat($0) }
        actions.setCodesEngine = { settings.setCodesEngine($0) }
        actions.acceptAndDownloadCodeModel = {
            guard let manifest = codeModel.manifest else { return }
            settings.recordCodeModelAcceptance(manifest)
            codeModel.start()
        }
        actions.downloadCodeModel = {
            guard let manifest = codeModel.manifest, settings.codeModelAcceptance(for: manifest) != nil else { return }
            codeModel.start()
        }
        actions.pauseCodeModel = { codeModel.pause() }
        actions.resumeCodeModel = { codeModel.resume() }
        actions.cancelCodeModel = { codeModel.cancel() }
        actions.retryCodeModel = { codeModel.retry() }
        actions.removeCodeModel = {
            codeModel.remove()
            if settings.codesEngine == .local { settings.setCodesEnabled(false) }
        }
        actions.testCodeModel = { codeModel.runTest() }
        actions.refreshCodeModel = {
            codeModel.refreshSpace()
            Task { await codeModel.refreshManifest() }
        }
        actions.linkPhone = { pairing.requestCompanionLink() }
        actions.clearHistory = { pairing.clearNotificationHistory() }
        actions.setShortcut = { action, key in shortcuts.setKey(key, for: action) }
        actions.setShortcutShift = { shortcuts.setShift($0) }
        actions.setPlayer = { media.player = $0 }
        actions.setPauseForCalls = { media.pauseForCalls = $0 }
        actions.setRingForCalls = { enabled in
            settings.setRingForIncomingCalls(enabled)
            pairing.refreshCallRinging()
        }
        actions.setOtherAppCallPolicy = { settings.setOtherAppCallPolicy($0) }
        actions.refreshPlayer = { media.refresh() }
        actions.setShowPreviews = { settings.setShowActivityPreviews($0) }
        actions.setLogging = { settings.setLogging($0) }
        actions.clearLogs = { pairing.clearDiagnostics() }
        actions.clearActivity = { pairing.clearActivity() }
        actions.exportDiagnostics = { pairing.exportDiagnostics() }
        actions.setReduceMotion = { settings.setReduceMotion($0) }
        actions.usePhoneLinks = { makeDefaultPhoneLinkHandler() }
        actions.setChannel = { updater.setChannel($0) }
        actions.setAutomaticallyChecks = { updater.setAutomaticallyChecks($0) }
        actions.checkForUpdates = { updater.checkForUpdates() }
        actions.update = updater.flowActions
        actions.updateAll = updateAll.actions
        actions.setRemoteStartUpdates = { updateAll.setRemoteStartAllowed($0) }
        actions.setAutoUpdate = { autoUpdate.setEnabled($0) }
        actions.openURL = { NSWorkspace.shared.open($0) }
        return setupCenter.hooked(actions, showPane: { pane = $0 }, inSetup: inSetup)
    }

    /// A session whose grant went away ends now. Turning remote control on asks macOS for
    /// Accessibility, once it is usable (on for this Mac and allowed for a phone).
    private func remoteControlChanged(enabled: Bool) {
        remoteInput.policyChanged()
        let grants = settings.deviceFeatures.mapValues { $0[.remoteInput] == true }
        if enabled, remoteControlEffectivelyEnabled(globalEnabled: settings.globalFeatures[.remoteInput] == true, deviceGrants: grants) {
            setupCenter.requestAccessibility { remoteInput.remoteControlEnabled() }
        }
    }

    /// The Shortcuts on this Mac, read with `shortcuts list` off the main thread.
    private func loadShortcuts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let names = ShortcutsCLI.list() ?? []
            DispatchQueue.main.async { availableShortcuts = names }
        }
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
