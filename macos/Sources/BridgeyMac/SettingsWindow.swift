import AppKit
import Combine
import SwiftUI

/*
 * The Settings window (direction A, 26 Nov 2026): a sidebar with search and six groups (SettingsGroup), and the
 * chosen group's feature cards on the right (SettingsGroupViews.swift). The cards draw from a plain
 * `SettingsModel`, so screenshots render them from sample state.
 */

/// The panes Settings had before the six groups. They stay as ids: deep links, notifications (their raw value is in
/// the notification's userInfo), setup's More options and the test hooks name them. Each maps to a group and the
/// card it scrolls to (SettingsCards.swift).
enum SettingsPane: String, CaseIterable, Identifiable {
    case thisMac, devices, clipboard, notifications, messages, calls, files, media, remoteControl, privacy, updates, general, about
    /// Were Privacy sub-pages; now cards in Privacy.
    case permissions, reset
    /// Was a Devices sub-page; now a card in Devices.
    case away
    /// The card at the end of App, while the version in About has been clicked five times (DeveloperMenu.swift).
    case developer

    var id: String { rawValue }

    /// The pane's name: setup's More options heading.
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
        case .permissions: L10n.setup("permissions.title", fallback: "Permissions")
        case .reset: L10n.setup("reset.title", fallback: "Reset Bridgey on this device")
        case .away: L10n.text("settings.away", fallback: "Connect away from home")
        case .developer: L10n.text("settings.developer", fallback: "Developer and experimental")
        }
    }
}

/// A link to an old pane: the card to show. `token` makes the same link scroll again.
struct SettingsCardRequest: Equatable {
    let card: SettingsCardID
    var token = UUID()
}

struct SettingsModel {
    var deviceName = "Mac"
    var state: PairingState = .idle
    /// The pairing in progress only (setup's pair step draws it).
    var pairingFlow: PairingState = .idle
    /// Connected phones; more than one shows as a count.
    var connectedCount = 0
    var trustedDevices: [TrustedDeviceInfo] = []
    /// Devices that get nothing here (a server, or paired over the tailnet and not trusted yet).
    var restrictedDevices: Set<String> = []
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
    /// Clipboard > Let Bridgey handle copy and paste (HandoffTakeover.swift) and what Handoff is now.
    var handoff = HandoffDisplay()
    var folderIncludeHidden = false
    var folderIncludeSystem = false
    var folderReceiveMode: MacFolderReceiveMode = .fixed
    var folderConflictPolicy: MacFolderConflictPolicy = .ask
    var tagReceivedFiles = false
    var autoResumeFiles = true
    var launchAtLogin = false
    var loginItemMessage: String?
    var receiveFolderPath = ""
    var notificationsAuthorized = true
    var notificationPermissionDetermined = true
    var shareActivityStatus = true
    var historyEnabled = false
    var history: [NotificationHistoryItem] = []
    /// Notifications > Codes from messages.
    var codesEnabled = false
    var codesAutoCopy = false
    /// Also read codes in email (on until chosen).
    var codesEmail = true
    var codesFloat: CodeFloatSetting = .default
    var localAgentCodeOptions = LocalAgentCodeOptions()
    var localAgentCodesUnavailable = false
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
    var mediaChoices: [MediaPlayer] = MediaPlayer.fixed
    var pauseForCalls = false
    var callMediaMode: CallMediaMode = .pauseThenMute
    var callMediaRestoration: CallMediaRestoration = .restoreAndResume
    var callMediaManual = false
    var callMediaStatuses: [String: String] = [:]
    var callMediaRecovery: [CallMediaRecoveryItem] = []
    var callMediaCanRestoreSound = false
    var ringForCalls = true
    var otherAppCallPolicy: MacOtherAppCallPolicy = .ask
    var logging = LoggingPolicy()
    var mediaDetail = ""
    var showPreviews = true
    var reduceMotion = false
    var panelMoves = true
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
    var openLinksRightAway = true
    /// Media and actions > Browsers (BrowserSupport.swift).
    var browserSupport = BrowserSupportDisplay()
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
    /// Remote control > This Mac's screen (screen_control_draft1): what each device gets now, Off when missing.
    var screenGrants: [String: MacScreenGrantMode] = [:]
    /// Each device's own choice; a missing device is on Default (it follows Unattended access).
    var screenGrantChoices: [String: MacScreenGrantMode] = [:]
    /// Unattended access: devices on Default see this Mac without asking. On by default.
    var screenUnattended = true
    var screenDisplays: [ScreenDisplayChoice] = []
    var screenDisplayID: UInt32?
    var screenRecordingAllowed = false
    var screenSession: MacScreenShare.Session?
    /// Connected phones that show screen_control_draft1 (See Mac screens is on there).
    var phoneScreenControl: [String: Bool] = [:]
    /// Settings > Text messages (draft sms_draft1).
    var smsEnabled = false
    var smsKeepOnMac = true
    var smsPhone: SmsPhoneDisplay = .noPhone
    /// Settings > Calls > Calls window (draft dialer_draft1).
    var callsWindow = CallsWindowSettings()
    /// Paired devices known to be Macs (they cannot place calls).
    var macDevices: Set<String> = []
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
    var tailscaleSetup = TailscaleSetupDisplay()
    /// Devices > Agents on <phone> (agents_mirror_draft1, AgentsView.swift).
    var agents = AgentsDisplay()

    var connectedDeviceID: String? {
        if case let .connected(id, _) = state { return id }
        return nil
    }

    func isEnabled(_ feature: BridgeyFeature, for deviceID: String) -> Bool {
        if feature.needsDeviceGrant { return globalFeatures[feature] == true && deviceFeatures[deviceID]?[feature] == true }
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
    var setShareActivityStatus: (Bool) -> Void = { _ in }
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
    var setHandoffTakeover: (Bool) -> Void = { _ in }
    var reapplyHandoffTakeover: () -> Void = {}
    var setFolderIncludeHidden: (Bool) -> Void = { _ in }
    var setFolderIncludeSystem: (Bool) -> Void = { _ in }
    var setFolderReceiveMode: (MacFolderReceiveMode) -> Void = { _ in }
    var setFolderConflictPolicy: (MacFolderConflictPolicy) -> Void = { _ in }
    var setTagReceivedFiles: (Bool) -> Void = { _ in }
    var setAutoResumeFiles: (Bool) -> Void = { _ in }
    /// Opens the Phone files window on a phone (Devices page).
    var openPhoneFiles: (String) -> Void = { _ in }
    var forget: (String) -> Void = { _ in }
    var pair: (DeviceRing) -> Void = { _ in }
    /// Pair by a tailnet name or address typed in Pair a new device.
    var pairAddress: (String) -> Void = { _ in }
    var trustAsMyDevice: (String) -> Void = { _ in }
    var retryDevice: (String) -> Void = { _ in }
    var lookForDevices: () -> Void = {}
    var openTailscaleSetup: () -> Void = {}
    var checkTailscale: () -> Void = {}
    var enableNotifications: () -> Void = {}
    var setHistoryEnabled: (Bool) -> Void = { _ in }
    var setCodesEnabled: (Bool) -> Void = { _ in }
    var setCodesAutoCopy: (Bool) -> Void = { _ in }
    var setCodesEmail: (Bool) -> Void = { _ in }
    var setCodesFloat: (CodeFloatSetting) -> Void = { _ in }
    var setLocalAgentCodes: (LocalAgentCodeOptions) -> Void = { _ in }
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
    var setCallMediaMode: (CallMediaMode) -> Void = { _ in }
    var setCallMediaRestoration: (CallMediaRestoration) -> Void = { _ in }
    var setManualCall: (Bool) -> Void = { _ in }
    var checkCallMediaRecovery: () -> Void = {}
    var restoreCallMediaSound: () -> Void = {}
    var setRingForCalls: (Bool) -> Void = { _ in }
    var setOtherAppCallPolicy: (MacOtherAppCallPolicy) -> Void = { _ in }
    var setLogging: (LoggingPolicy) -> Void = { _ in }
    var clearLogs: () -> Void = {}
    var refreshPlayer: () -> Void = {}
    var setShowPreviews: (Bool) -> Void = { _ in }
    var clearActivity: () -> Void = {}
    var exportDiagnostics: () -> Void = {}
    var setReduceMotion: (Bool) -> Void = { _ in }
    var setPanelMoves: (Bool) -> Void = { _ in }
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
    var installBrowserSupport: () -> Void = {}
    var removeBrowserSupport: () -> Void = {}
    var openBrowserGuide: () -> Void = {}
    var setBatteryAlerts: (String, BatteryAlertThresholds) -> Void = { _, _ in }
    var setFocusSync: ((inout FocusSyncSettings) -> Void) -> Void = { _ in }
    var setCameraCopyToClipboard: (Bool) -> Void = { _ in }
    var setPhoneScreen: (Bool) -> Void = { _ in }
    /// Remote control > This Mac's screen: a device's choice, nil for Default; and Unattended access.
    var setScreenGrant: (String, MacScreenGrantMode?) -> Void = { _, _ in }
    var setScreenUnattended: (Bool) -> Void = { _ in }
    var setScreenDisplay: (UInt32) -> Void = { _ in }
    var openScreenRecordingSettings: () -> Void = {}
    var stopScreenShare: () -> Void = {}
    /// Settings > Text messages.
    var setSmsEnabled: (Bool) -> Void = { _ in }
    var setSmsKeepOnMac: (Bool) -> Void = { _ in }
    var deleteMessages: () -> Void = {}
    /// The Messages window, on a phone and conversation when given (the history's Reply).
    var openMessages: (String?, Int?) -> Void = { _, _ in }
    /// Settings > Calls > Calls window.
    var setCallsSim: (CallsSimPreference) -> Void = { _ in }
    var setCallsShowWhatsApp: (Bool) -> Void = { _ in }
    var setCallsRecentCount: (Int) -> Void = { _ in }
    var openCalls: () -> Void = {}
    var setSettingsSync: (Bool) -> Void = { _ in }
    var setSettingsSyncForDevice: (String, Bool) -> Void = { _, _ in }
    /// Choose what syncs.
    var setSyncs: (SyncKey, Bool) -> Void = { _, _ in }
    /// "Different on <phone>": send this Mac's value to every phone.
    var applyToAll: (SyncKey) -> Void = { _ in }
    /// "On, waiting for permission": open where it is allowed.
    var allowPermission: (SyncKey) -> Void = { _ in }
    var setConnectAway: (Bool) -> Void = { _ in }
    /// Agents on <phone>: a permission switch (phone, agent, grant, on, window); the phone applies it.
    var setAgentGrant: (String, String, AgentGrantKey, Bool, AgentGrantWindow?) -> Void = { _, _, _, _, _ in }
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
    @Binding var group: SettingsGroup
    /// A link to an old pane: the card to scroll to (screenshots start the group at it).
    let request: SettingsCardRequest?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot
    @Environment(\.brandReduceMotion) private var reduce
    @State private var query: String
    @State private var selected: Int
    @State private var target: SettingsSearchTarget?
    @FocusState private var searchFocused: Bool
    @StateObject private var keys = SettingsSearchKeys()
    /// Screenshots draw the search field as focused.
    private let showsSearchFocus: Bool

    static let size = CGSize(width: 880, height: 600)

    /// `searchQuery`, `searchSelection` and `searchTarget` start the window mid-search, for screenshots.
    init(model: SettingsModel, actions: SettingsActions, group: Binding<SettingsGroup>, request: SettingsCardRequest? = nil,
         searchQuery: String = "", searchSelection: Int = 0, searchTarget: SettingsSearchTarget? = nil, showsSearchFocus: Bool = false) {
        self.model = model
        self.actions = actions
        _group = group
        self.request = request
        _query = State(initialValue: searchQuery)
        _selected = State(initialValue: searchSelection)
        _target = State(initialValue: searchTarget)
        self.showsSearchFocus = showsSearchFocus
    }

    /// The window opened at an old pane: its group, scrolled to its card.
    init(model: SettingsModel, actions: SettingsActions, pane: Binding<SettingsPane>,
         searchQuery: String = "", searchSelection: Int = 0, searchTarget: SettingsSearchTarget? = nil, showsSearchFocus: Bool = false) {
        let start = pane.wrappedValue
        self.init(model: model, actions: actions, group: .constant(start.group),
                  request: start.card == start.group.cards(developer: true).first ? nil : SettingsCardRequest(card: start.card),
                  searchQuery: searchQuery, searchSelection: searchSelection, searchTarget: searchTarget, showsSearchFocus: showsSearchFocus)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let outcome = searching ? SettingsSearchOutcome.run(query, entries: SettingsSearchRegistry.entries(model)) : SettingsSearchOutcome()
        HStack(spacing: 0) {
            SettingsSidebar(model: model, group: $group, query: $query, focused: $searchFocused, showsFocus: showsSearchFocus || searchFocused,
                            outcome: outcome, selected: selected, open: open, hover: { selected = $0 },
                            choose: { target = nil })
            VStack(alignment: .leading, spacing: 0) {
                ScrollViewReader { proxy in
                    BoundedScroll {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(group.title)
                                    .font(BrandFont.heading(24))
                                    .foregroundStyle(c.on)
                                    .frame(height: 30)
                                    .accessibilityAddTraits(.isHeader)
                                SettingsGroupView(group: group, model: model, actions: actions,
                                                  startCard: snapshot ? (request?.card ?? target?.card) : nil)
                            }
                            .padding(.horizontal, 40)
                            .padding(.top, 32)
                            .padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(group)
                            .transition(reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                        }
                    }
                    .onChange(of: target) { shown in reveal(shown, proxy: proxy) }
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.isDark ? Color(hex: 0x0A101D) : c.bg)
            .environment(\.settingsSearchHighlight, target?.group == group ? target : nil)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onChange(of: query) { _ in
            selected = 0
            keys.hasQuery = searching
        }
        .onChange(of: searchFocused) { keys.fieldFocused = $0 }
        .onChange(of: request) { showCard($0) }
        .onReceive(keys.commands) { command in handle(command, outcome: outcome) }
        #if DEBUG
        .task(id: SettingsTestHooks.Probe(query: query, selected: selected, pane: group.rawValue, target: target?.title,
                                          fieldFocused: searchFocused, choosable: outcome.choosable.map(\.id))) {
            if TestInstance.enabled {
                SettingsTestHooks.shared.probe = SettingsTestHooks.Probe(query: query, selected: selected, pane: group.rawValue, target: target?.title,
                                                                         fieldFocused: searchFocused, choosable: outcome.choosable.map(\.id))
            }
        }
        #endif
        .onAppear {
            if !snapshot {
                keys.install()
                showCard(request)
            }
        }
        .onDisappear { keys.remove() }
    }

    private var footer: some View {
        HStack {
            Text(L10n.text("about.credit.short", fallback: "Built on Bridgey by Semyon Mikhailov (MIT)"))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
            Spacer()
            // Updates links to the offered release's notes in its status card; elsewhere only App links to them.
            if group == .app {
                Button(L10n.text("updates.releaseNotes", fallback: "Release notes")) { actions.openURL(SettingsLinks.releases) }
                    .buttonStyle(.plain)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.pri)
            }
        }
        .padding(.horizontal, 40)
        .frame(height: 40)
    }

    // MARK: Search

    /// Opens the result's group and shows its row, opening its card's More options first when the row is in them; the
    /// results stay, as in System Settings, until Escape.
    private func open(_ row: SettingsSearchRow) {
        let entry = row.entry
        withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { group = entry.group }
        // A row hidden until its switch is on (the Calls window's options) shows that switch instead.
        target = SettingsSearchTarget(group: entry.group, scope: entry.scope, title: entry.anchorTitle(in: model), card: entry.card,
                                      expand: entry.expands(in: model))
    }

    /// A link to an old pane: its group, scrolled to the top of its card.
    private func showCard(_ request: SettingsCardRequest?) {
        guard let request else { return }
        group = request.card.group
        target = SettingsSearchTarget(group: request.card.group, card: request.card)
    }

    /// Scrolls the found row to the middle (or a linked card to the top) once its group has laid out; the row pulses
    /// by itself (SearchPulse). The highlight is dropped after it has faded, so coming back later shows no stale mark.
    private func reveal(_ shown: SettingsSearchTarget?, proxy: ScrollViewProxy) {
        guard let shown else { return }
        let id: AnyHashable?
        let anchor: UnitPoint
        if let title = shown.title {
            id = SearchAnchorID(scope: shown.scope, title: title)
            anchor = .center
        } else if let card = shown.card {
            id = SettingsCardScrollID(card: card)
            anchor = .top
        } else {
            id = nil
            anchor = .top
        }
        if let id {
            // An agent's card opens first (AgentBlock), and so do More options: their rows exist only once they have.
            let settle = shown.scope?.hasPrefix("agent:") == true ? 0.45 : shown.expand != nil ? 0.3 : 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                if reduce {
                    proxy.scrollTo(id, anchor: anchor)
                } else {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: anchor) }
                    // An animation that cannot run (the window hidden behind the lock screen or another Space) leaves the
                    // group where it was: land on the row anyway once the animation would have ended.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if target?.token == shown.token { proxy.scrollTo(id, anchor: anchor) }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if target?.token == shown.token { target = nil }
        }
    }

    private func handle(_ command: SettingsSearchKeys.Command, outcome: SettingsSearchOutcome) {
        let rows = outcome.choosable
        switch command {
        case .focus:
            searchFocused = true
        case let .move(delta):
            guard !rows.isEmpty else { return }
            selected = min(max(selected + delta, 0), rows.count - 1)
        case .submit:
            if rows.indices.contains(selected) { open(rows[selected]) }
        case .clear:
            query = ""
            target = nil
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let model: SettingsModel
    @Binding var group: SettingsGroup
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let showsFocus: Bool
    let outcome: SettingsSearchOutcome
    let selected: Int
    let open: (SettingsSearchRow) -> Void
    let hover: (Int) -> Void
    /// A group chosen from the list: the search highlight is dropped.
    let choose: () -> Void
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot
    @Environment(\.brandReduceMotion) private var reduce

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if snapshot {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 44)
            SettingsSearchField(query: $query, focused: focused, showsFocus: showsFocus)
                .padding(.bottom, 12)
            ZStack(alignment: .topLeading) {
                if searching {
                    SettingsSearchResultsList(query: query, outcome: outcome, selected: selected, open: open, hover: hover)
                        .transition(.opacity)
                } else {
                    BoundedScroll { groupButtons }
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(BrandMotion.fade, value: searching)
            HStack(spacing: 8) {
                AuroraMark(size: 24)
                Text("\(Edition.displayName)\n\(UpdateFlowText.label(model.shortVersion))")
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .lineSpacing(1)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 10)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(c.isDark ? c.s1 : c.s2)
        .overlay(alignment: .trailing) { Rectangle().fill(c.isDark ? c.olv : c.ol).frame(width: 1) }
    }

    private var groupButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsGroup.allCases) { item in
                let chosen = item == group
                Button {
                    select(item)
                } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: item.symbol, tint: item.tint, size: 26, corner: 7)
                        Text(item.title)
                            .font(BrandFont.body(13, .medium))
                            .foregroundStyle(c.on)
                            .lineLimit(1)
                            // Russian "Конфиденциальность" is a few letters wider than the sidebar: shrink a little
                            // rather than cut the word.
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        if item == .devices, !model.trustedDevices.isEmpty {
                            Text("\(model.trustedDevices.count)")
                                .font(BrandFont.body(12, .medium))
                                .foregroundStyle(c.on2)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(chosen ? (c.isDark ? c.s3 : c.s4.opacity(0.7)) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item == .devices && !model.trustedDevices.isEmpty
                                    ? String(format: L10n.text("settings.group.devices.count", fallback: "%1$@, %2$d paired"), item.title, model.trustedDevices.count)
                                    : item.title)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func select(_ item: SettingsGroup) {
        choose()
        withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { group = item }
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

// MARK: - Building blocks

/// A box of rows. Inside a feature card (`settingsCardFlat`) it draws as a section of that card instead: its title
/// as a small label, its rows, its footnote, under a hairline.
struct SettingsCard<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder let content: Content
    @Environment(\.brand) private var c
    @Environment(\.settingsCardFlat) private var flat

    var body: some View {
        if flat { section } else { box }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.on2)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            if let footnote {
                Text(footnote)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    private var box: some View {
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
        .settingsSearchAnchor(title)
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
        .settingsSearchAnchor(title)
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
                    // The chosen value is read whole ("По умолчанию (Разрешать без вопроса)"); the row title wraps instead.
                    .fixedSize(horizontal: true, vertical: false)
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

/// What an old pane held: its cards, in order (setup's More options, screenshots of one feature).
struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCardsView(cards: pane.cards.filter { $0 != .developer || model.developerMenu }, model: model, actions: actions)
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

func eagerLimitTitle(_ limit: ClipboardEagerLimit) -> String {
    switch limit {
    case .fiveMB: L10n.text("settings.clipboardEager.5", fallback: "5 MB")
    case .twentyFiveMB: L10n.text("settings.clipboardEager.25", fallback: "25 MB")
    case .hundredMB: L10n.text("settings.clipboardEager.100", fallback: "100 MB")
    case .askWhenPasting: L10n.text("settings.clipboardEager.ask", fallback: "Always ask when pasting")
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
/// Media and actions > Browsers: install or remove browser support (docs/browser-extensions.md).
struct BrowserSupportCard: View {
    let display: BrowserSupportDisplay
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            SettingsRow(title: BrowserSupportText.title, subtitle: BrowserSupportText.subtitle(display),
                        subtitleIsWarning: display.problem != nil && display.problem != .unavailable, divider: false) {
                if display.problem != .unavailable && display.problem != .translocated {
                    if display.enabled {
                        if display.problem == .noBrowser {
                            Button(L10n.text("browser.support.install", fallback: "Install"), action: actions.installBrowserSupport)
                                .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                        } else {
                            Button(L10n.text("browser.support.guide", fallback: "Get the extension"), action: actions.openBrowserGuide)
                                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                        }
                        Button(L10n.text("browser.support.remove", fallback: "Remove"), action: actions.removeBrowserSupport)
                            .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                    } else {
                        Button(L10n.text("browser.support.install", fallback: "Install"), action: actions.installBrowserSupport)
                            .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                    }
                }
            }
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
        case .callQuiet: L10n.text("callMedia.detail", fallback: "Quiet supported media on allowed devices when a call starts. Later manual playback stays allowed.")
        case .remoteInput: L10n.text("feature.remoteInput.detail", fallback: "Let a phone you allow move the pointer, type and change slides")
        case .macActions: L10n.text("feature.macActions.detail", fallback: "Lock, sleep, volume, apps and Shortcuts from a phone you allow")
        case .dialer: L10n.text("calls.window.detail", fallback: "A keypad, your phone\u{2019}s contacts and recent calls. Calls go through the phone.")
        }
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
                if model.restrictedDevices.contains(device.id) {
                    Button(L10n.text("devices.trustAsMine", fallback: "Trust as my device")) { actions.trustAsMyDevice(device.id) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                        .help(L10n.text("devices.restricted.detail", fallback: "Paired over your tailnet or a server: nothing is shared with it until you trust it."))
                }
                Button(L10n.text("action.forget", fallback: "Forget")) { confirmForget = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
            }
            .padding(.vertical, 8)
            .settingsSearchAnchor(device.name)
            ConnectionHealthRow(health: model.health[device.id], now: model.now)
            // What this Mac shares with the device is now chosen in each feature's card (its Devices row).
        }
        // Rows here have the same titles in every device's card: search tells them apart by device.
        .settingsSearchScope(device.id)
        .confirmationDialog(
            String(format: L10n.text("devices.forget.title", fallback: "Forget %@?"), device.name),
            isPresented: $confirmForget
        ) {
            Button(L10n.text("action.forget", fallback: "Forget"), role: .destructive) { actions.forget(device.id) }
        } message: {
            Text(L10n.text("devices.forget.body", fallback: "This Mac stops trusting it. To use it again, pair and compare the code once more."))
        }
    }
}

/// Look for devices again, the devices nearby that can pair, and pairing by a tailnet name or address.
struct PairNewCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        let nearby = model.rings.filter { !$0.trusted }
        FeatureCard(card: .pair, headerAnchor: SettingsCardID.pair.title,
                    footnote: L10n.text("devices.pair.detail", fallback: "Open Bridgey on both devices, on the same Wi-Fi or Tailscale network. Confirm only if the codes match.")) {
            SettingsRow(
                title: L10n.text("panel.lookAgain", fallback: "Look for devices again"),
                subtitle: model.rediscoverStatus ?? L10n.text("devices.lookAgain.detail", fallback: "Announces this Mac again and retries every paired device now")
            ) {
                Button(L10n.text("devices.lookAgain.action", fallback: "Look again")) { actions.lookForDevices() }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                    .disabled(model.rediscovering)
            }
            Group {
                if nearby.isEmpty {
                    SettingsRow(title: L10n.text("devices.pair.searching", fallback: "Looking for Bridgey devices on Wi-Fi and Tailscale\u{2026}")) { EmptyView() }
                }
                ForEach(nearby) { ring in
                    SettingsRow(title: ring.name, subtitle: ringStatusText(ring)) {
                        Button(L10n.text("action.pair", fallback: "Pair")) { actions.pair(ring) }
                            .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                            .disabled(!ring.canConnect)
                    }
                }
            }
            .settingsSearchSkip()
            PairAddressRow(actions: actions)
        }
    }
}

/// Pair a new device > a tailnet name or address: for a device on your tailnet that is not listed (the other device
/// taps Allow pairing, or runs bridgey pair --allow; both then show the same code).
struct PairAddressRow: View {
    let actions: SettingsActions
    @State private var address = ""
    @Environment(\.snapshotRendering) private var snapshot
    @Environment(\.brand) private var c

    var body: some View {
        SettingsRow(title: L10n.text("devices.pair.address", fallback: "Pair by tailnet name or address"),
                    subtitle: L10n.text("devices.pair.address.detail", fallback: "For a device on your tailnet. Tap Allow pairing there first."), divider: true) {
            if snapshot {
                // ImageRenderer cannot draw an AppKit text field: screenshots show its placeholder instead.
                Text(L10n.text("devices.pair.address.placeholder", fallback: "work or 100.64.0.10"))
                    .font(BrandFont.body(13))
                    .foregroundStyle(c.on2)
                    .padding(.horizontal, 8)
                    .frame(width: 170, height: 24, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(c.s2))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c.ol, lineWidth: 1))
            } else {
                TextField(L10n.text("devices.pair.address.placeholder", fallback: "work or 100.64.0.10"), text: $address)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .accessibilityLabel(L10n.text("devices.pair.address", fallback: "Pair by tailnet name or address"))
                    .onSubmit { submit() }
            }
            Button(L10n.text("action.pair", fallback: "Pair")) { submit() }
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        actions.pairAddress(typed)
        address = ""
    }
}

struct MediaPlayerRow: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsRow(title: L10n.text("settings.media.player", fallback: "Player"),
                    subtitle: L10n.text("settings.media.player.detail", fallback: "Automatic follows whatever is playing on this Mac. Or pick one app.")) {
            ChoiceButton(value: model.mediaPlayer.buttonTitle) {
                model.mediaChoices.map { player in
                    PopUpMenuItem(title: player.menuTitle, checked: player == model.mediaPlayer) { actions.setPlayer(player) }
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
                        .settingsSearchSkip()
                } else {
                    ForEach(Array(model.history.prefix(20))) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.applicationName).font(BrandFont.body(13, .semibold)).foregroundStyle(c.on)
                                Spacer()
                                if let age = item.codeAge(now: Date()) {
                                    Text(age).font(BrandFont.body(12)).foregroundStyle(c.on2)
                                } else {
                                    Text(item.receivedAt, format: .dateTime.day().month().hour().minute())
                                        .font(BrandFont.body(12)).foregroundStyle(c.on2)
                                }
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

/// Text messages: the switch in the header, the phone's state and the Messages window.
struct TextMessagesCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .messages,
                    toggle: CardToggle(title: L10n.text("sms.toggle", fallback: "Your phone\u{2019}s texts on this Mac"), isOn: model.smsEnabled,
                                       synced: model.syncs(.featureSms), set: actions.setSmsEnabled),
                    footnote: L10n.text("sms.toggle.detail", fallback: "Read and answer conversations in the Messages window, and reply from text notifications. Off by default. Messages travel only between your phone and this Mac, encrypted; Bridgey never becomes the phone\u{2019}s default SMS app.")) {
            SyncStatusLine(key: .featureSms, model: model, actions: actions)
            if model.smsEnabled {
                SettingsRow(title: phoneTitle, subtitle: phoneDetail, subtitleIsWarning: phoneWarning, divider: true) {
                    Button(L10n.text("sms.open", fallback: "Open Messages")) { actions.openMessages(nil, nil) }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
                .settingsSearchSkip()
                SettingsRow(title: L10n.text("sms.limits", fallback: "Group conversations and pictures"),
                            subtitle: L10n.text("sms.limits.detail", fallback: "You can read them here. Reply to groups and send pictures from your phone."), divider: true) { EmptyView() }
            }
        } more: {
            if model.smsEnabled { TextMessagesStorageCard(model: model, actions: actions) }
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

/// Privacy > Logging: Export diagnostics and Clear logs, then in More options a switch per category, content
/// switches under their category. Per Mac.
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
        FeatureCard(card: .logging,
                    footnote: L10n.text("settings.logging.note", fallback: "Logs stay on this device; you choose what goes into exported diagnostics. Names and text only reach the local log.")) {
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
        } more: {
            Group {
            SettingsToggle(title: L10n.text("settings.logging.connection", fallback: "Connection events"),
                           subtitle: L10n.text("settings.logging.connection.detail", fallback: "Discovery, pairing, connects and reconnects"),
                           isOn: policy.connection) { on in set { $0.connection = on } }
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
    /// "2 more clicks to open the developer settings", for a moment after each click near the end of the count.
    @State private var tapNote: String?

    var body: some View {
        FeatureCard(card: .about) {
            HStack(spacing: 14) {
                AuroraMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Edition.displayName).font(BrandFont.heading(17)).foregroundStyle(c.on)
                    Text(String(format: L10n.text("updates.version", fallback: "Version %@"), model.versionDescription))
                        .font(BrandFont.body(12)).foregroundStyle(c.on2)
                        .contentShape(Rectangle())
                        // Five clicks turn on the Developer and experimental settings; once on, a click opens them.
                        .onTapGesture { versionTapped() }
                        .accessibilityAddTraits(.isButton)
                    if let tapNote {
                        Text(tapNote).font(BrandFont.body(11)).foregroundStyle(c.pri)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSearchAnchor(SettingsSearchRegistry.version)
            .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
            SettingsRow(title: Edition.credit,
                        subtitle: L10n.text("about.license", fallback: "Open source under the MIT License.")) {
                Button(L10n.text("about.original", fallback: "Original project")) { actions.openURL(Edition.upstreamProjectURL) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
        } more: {
            SettingsRow(title: L10n.text("about.fonts", fallback: "Fonts"),
                        subtitle: L10n.text("about.fonts.detail", fallback: "Space Grotesk and Inter, under the SIL Open Font License 1.1.")) { EmptyView() }
            SettingsRow(title: L10n.text("about.network", fallback: "Your data"),
                        subtitle: L10n.text("about.network.detail", fallback: "Bridgey talks directly over your local network. Clipboard, files and notification content are encrypted in transit.")) { EmptyView() }
            LicencesCard()
        }
    }

    private func versionTapped() {
        switch actions.versionTapped() {
        case .counting:
            tapNote = nil
        case let .remaining(left):
            tapNote = L10n.plural("developer.tapsLeft", fallback: "%d more clicks to open the developer settings", left)
        case .unlocked:
            tapNote = L10n.text("developer.on", fallback: "Developer and experimental settings are on")
        case .open:
            tapNote = nil
        }
    }
}

/// Developer and experimental (hidden, DeveloperMenu.swift): tests and facts for people chasing a problem, then the
/// experiments Rahul turns on before they are ready for everyone, then the way to hide the card again.
struct DeveloperPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        FeatureCard(card: .developer) {
            SpeedTestCard(phones: model.speedPhones)
            PerfTestPanel()
            // Facts and an empty list, not settings: search skips them.
            SettingsCard(title: L10n.text("developer.transfers", fallback: "How files travel now")) {
                if model.transferPaths.isEmpty {
                    SettingsRow(title: L10n.text("developer.noPhones", fallback: "No phone connected"), subtitle: nil, divider: false) { EmptyView() }
                }
                ForEach(Array(model.transferPaths.enumerated()), id: \.element.id) { index, path in
                    SettingsRow(title: path.name, subtitle: Self.describe(path), divider: index > 0) { EmptyView() }
                }
            }
            .settingsSearchSkip()
            SettingsCard(title: L10n.text("developer.experimental", fallback: "Experimental features")) {
                SettingsRow(title: L10n.text("developer.experimental.empty", fallback: "Nothing to try right now. New experiments show up here before everyone gets them."),
                            subtitle: nil, divider: false) { EmptyView() }
            }
            .settingsSearchSkip()
            SettingsRow(title: L10n.text("developer.hide", fallback: "Hide developer settings"),
                        subtitle: L10n.text("developer.hide.detail", fallback: "Click the version in About five times to bring it back")) {
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
            let created = SettingsWindow.make(content: NSHostingController(rootView: content),
                                              title: L10n.text("settings.window", fallback: "Bridgey Settings"))
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        (window as? SettingsWindow)?.trace("show")
    }

    /// Opens Settings at `pane` (a notification that points at a setting, such as the email code model prompt).
    func show(pane: SettingsPane) {
        SettingsPaneRequest.shared.pane = pane
        show()
    }
}

/// A pane the Settings window should switch to; the window takes it and clears it.
@MainActor
final class SettingsPaneRequest: ObservableObject {
    static let shared = SettingsPaneRequest()
    @Published var pane: SettingsPane?
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
    @ObservedObject var handoff = HandoffTakeover.shared
    @ObservedObject var phoneScreen: PhoneScreen
    @ObservedObject var macScreen: MacScreenShare
    @ObservedObject var connect: ConnectAnywhere
    @ObservedObject var agentsMirror: AgentsMirror
    @ObservedObject var localAgentCodes: LocalAgentCodes
    @ObservedObject var browserSupport: BrowserSupport
    @State private var group: SettingsGroup = .devices
    /// A link to an old pane (a notification, setup, Allow on a sync line): the card to scroll to.
    @State private var cardRequest: SettingsCardRequest?
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
        macScreen = pairing.macScreen
        settingsSync = pairing.settingsSync
        connect = pairing.connect
        agentsMirror = pairing.agentsMirror
        localAgentCodes = pairing.localAgentCodes
        browserSupport = pairing.browserSupport
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
                SettingsWindowView(model: model, actions: actions, group: $group, request: cardRequest)
            }
        }
        .onAppear {
            if inSetup { handoff.refresh() } else { handoff.watch(group == .sharing) }
            pairing.refreshNotificationAuthorization()
            settings.refreshLoginItemStatus()
            remoteInput.refreshAccessibility()
            remoteAudit.prune()
            macActionsAudit.prune()
            Task { await pairing.refreshTailnet() }
        }
        .onReceive(accessibilityTicker) { _ in
            if group == .control { remoteInput.refreshAccessibility() }
            if group == .control { macScreen.refreshDisplays() }
        }
        .onChange(of: group) { shown in
            if shown == .devices { Task { await pairing.refreshTailnet() } }
            if shown == .control || shown == .phone { loadShortcuts() }
            if !inSetup { handoff.watch(shown == .sharing) }
        }
        .onDisappear { handoff.watch(false) }
        .onReceive(SettingsPaneRequest.shared.$pane.compactMap { $0 }) { requested in
            guard !inSetup else { return }
            open(requested)
            SettingsPaneRequest.shared.pane = nil
        }
    }

    private var model: SettingsModel {
        var model = SettingsModel()
        model.deviceName = settings.deviceName
        model.state = pairing.state
        model.pairingFlow = pairing.pairingFlow
        model.connectedCount = pairing.connectedPhones.count
        model.trustedDevices = pairing.trustedDevices
        model.restrictedDevices = settings.agentDevices
        model.rings = deviceRings(trusted: pairing.trustedDevices, peers: discovery.peers + pairing.tailnetPeers, connected: pairing.connectedPhones,
                                  pairing: pairing.pairingFlow, reconnecting: pairing.reconnectStates)
        model.speedPhones = pairing.speedPhones.map { SpeedPhone(id: $0.id, name: $0.name) }
        model.developerMenu = DeveloperMenu.shared.enabled
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
        model.handoff = HandoffDisplay(takeover: handoff.takeover, state: handoff.state, overridden: handoff.overridden, failed: handoff.failed)
        model.folderIncludeHidden = settings.folderIncludeHidden
        model.folderIncludeSystem = settings.folderIncludeSystem
        model.folderReceiveMode = settings.folderReceiveMode
        model.folderConflictPolicy = settings.folderConflictPolicy
        model.tagReceivedFiles = settings.tagReceivedFiles
        model.autoResumeFiles = settings.autoResumeFiles
        model.clipboardEagerLimit = ClipboardEagerLimit(bytes: settings.clipboardEagerLimit)
        model.launchAtLogin = settings.launchAtLogin
        model.loginItemMessage = settings.loginItemMessage
        model.receiveFolderPath = settings.receiveFolderPath
        model.notificationsAuthorized = pairing.notificationsAuthorized
        model.notificationPermissionDetermined = pairing.notificationPermissionDetermined
        model.historyEnabled = settings.notificationHistoryEnabled
        model.shareActivityStatus = settings.shareActivityStatus
        model.history = pairing.notificationHistory
        model.codesEnabled = settings.codesEnabled
        model.codesAutoCopy = settings.codesAutoCopy
        model.codesEmail = settings.codesEmail
        model.codesFloat = settings.codesFloat
        model.localAgentCodeOptions = localAgentCodes.options
        model.browserSupport = browserSupport.display
        model.localAgentCodesUnavailable = localAgentCodes.unavailable
        model.codesAvailable = CodeRelay.baseURL != nil
        model.codesEngine = settings.codesEngine
        model.codeModel = codeModelDisplay
        model.codeAccess = pairing.codeAccessForSelectedPhone
        model.codeLinkStatus = pairing.codeLinkStatus
        model.shortcutKeys = shortcuts.keys
        model.shortcutShift = shortcuts.useShift
        model.shortcutError = shortcuts.error
        model.mediaPlayer = media.player
        model.mediaChoices = media.choices
        model.pauseForCalls = media.pauseForCalls
        model.callMediaMode = settings.callMediaMode
        model.callMediaRestoration = settings.callMediaRestoration
        model.callMediaManual = pairing.callMedia.manualActive
        model.callMediaStatuses = Dictionary(uniqueKeysWithValues: pairing.trustedDevices.map { ($0.id, pairing.callMedia.resultSummary($0.id)) })
        model.callMediaRecovery = pairing.callMedia.recoveryItems
        model.callMediaCanRestoreSound = pairing.callMedia.canRestoreSound
        model.ringForCalls = settings.ringForIncomingCalls
        model.otherAppCallPolicy = settings.otherAppCallPolicy
        model.logging = settings.logging
        model.mediaDetail = media.snapshot.detail
        model.showPreviews = settings.showActivityPreviews
        model.reduceMotion = settings.reduceMotion
        model.panelMoves = settings.panelMotion == .move
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
        _ = macScreen.grantsVersion
        model.screenGrants = Dictionary(uniqueKeysWithValues: pairing.trustedDevices.map { ($0.id, macScreen.grantMode(for: $0.id)) })
        model.screenGrantChoices = Dictionary(uniqueKeysWithValues: pairing.trustedDevices.compactMap { device in
            macScreen.explicitGrant(for: device.id).map { (device.id, $0) }
        })
        model.screenUnattended = macScreen.unattended
        model.screenDisplays = macScreen.displayList.map { ScreenDisplayChoice(id: $0.id, name: $0.name) }
        model.screenDisplayID = macScreen.selectedDisplay?.id
        model.screenRecordingAllowed = macScreen.environment.captureAllowed()
        model.screenSession = macScreen.active
        model.phoneScreenControl = Dictionary(pairing.connectedPhones.filter(\.state.featureStateReceived).map { ($0.id, $0.state.remoteScreenControl) },
                                              uniquingKeysWith: { $1 })
        model.smsEnabled = settings.smsEnabled
        model.smsKeepOnMac = settings.smsKeepOnMac
        model.smsPhone = pairing.textMessagesDisplay
        model.callsWindow = CallsWindowSettings(sim: settings.callsSim, showWhatsApp: settings.callsShowWhatsApp,
                                                recentCount: settings.callsRecentCount, whatsAppOnMac: WhatsAppOnMac.isInstalled)
        model.macDevices = Set(model.rings.filter { $0.platform == "macos" }.compactMap(\.deviceID))
            .union(pairing.connectedPhones.filter { $0.state.remoteHandoffTakeover }.map(\.id))
        model.settingsSyncEnabled = settingsSync.enabled
        model.settingsSyncDevices = settingsSync.devices
        model.syncExcluded = settingsSync.excluded
        model.codesPendingSync = pairing.codesSyncGate.pending
        model.syncStatus = Dictionary(uniqueKeysWithValues: SyncKey.allCases.map { ($0, settingsSync.status($0)) })
        model.phoneSettingsSync = Dictionary(pairing.connectedPhones.filter(\.state.featureStateReceived).map { ($0.id, $0.state.remoteSettingsSync) },
                                             uniquingKeysWith: { $1 })
        model.tailscaleSetup = pairing.tailscaleSetup
        model.connectAway = settings.connectAway
        model.agents = AgentsDisplay(phones: agentsMirror.phones, pending: agentsMirror.pending, codeReads: agentsMirror.codeReads,
                                     live: pairing.agentsMirrorPhones)
        model.connect = pairing.connectDisplay
        model.batteryAlerts = Dictionary(uniqueKeysWithValues: pairing.trustedDevices.map { ($0.id, batteryAlerts.thresholds(for: $0.id)) })
        return model
    }

    private var actions: SettingsActions {
        var actions = SettingsActions()
        actions.versionTapped = {
            let tap = DeveloperMenu.shared.tap()
            if tap == .unlocked || tap == .open { open(.developer) }
            return tap
        }
        actions.turnOffDeveloper = {
            DeveloperMenu.shared.turnOff()
            open(.about)
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
        actions.setScreenGrant = { id, mode in _ = macScreen.setGrant(mode, for: id) }
        actions.setScreenUnattended = { _ = macScreen.setUnattended($0) }
        actions.setScreenDisplay = { macScreen.setSelectedDisplay($0) }
        actions.openScreenRecordingSettings = { NSWorkspace.shared.open(ScreenRecordingAccess.settingsURL) }
        actions.stopScreenShare = { macScreen.stopLocally() }
        actions.setSmsEnabled = { pairing.setTextMessagesEnabled($0) }
        actions.setSmsKeepOnMac = { pairing.setTextMessagesKeepOnMac($0) }
        actions.deleteMessages = { pairing.deleteTextMessagesOnMac() }
        actions.openMessages = { phoneID, threadID in MessagesWindowController.show(pairing: pairing, phoneID: phoneID, threadID: threadID) }
        actions.setCallsSim = { settings.setCallsSim($0) }
        actions.setCallsShowWhatsApp = { settings.setCallsShowWhatsApp($0) }
        actions.setCallsRecentCount = { settings.setCallsRecentCount($0) }
        actions.openCalls = { CallsWindowController.show(pairing: pairing) }
        actions.setSettingsSync = { settingsSync.setEnabled($0) }
        actions.setSettingsSyncForDevice = { id, on in settingsSync.setEnabled(on, for: id) }
        actions.setSyncs = { key, on in settingsSync.setSyncs(key, on) }
        actions.applyToAll = { settingsSync.applyToAll($0) }
        // Codes waits for its own consent step on its card; the others for a system permission.
        actions.allowPermission = { key in show(key == .codesEnabled ? .codes : .permissions) }
        actions.setConnectAway = { settings.setConnectAway($0) }
        actions.setAgentGrant = { phone, agent, key, on, window in pairing.setAgentGrant(phone: phone, agent: agent, key: key, on: on, window: window) }
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
        actions.setHandoffTakeover = { handoff.set($0) }
        actions.reapplyHandoffTakeover = { handoff.reapply() }
        actions.setFolderIncludeHidden = { settings.setFolderIncludeHidden($0) }
        actions.setFolderIncludeSystem = { settings.setFolderIncludeSystem($0) }
        actions.setFolderReceiveMode = { settings.setFolderReceiveMode($0) }
        actions.setFolderConflictPolicy = { settings.setFolderConflictPolicy($0) }
        actions.setTagReceivedFiles = { settings.setTagReceivedFiles($0) }
        actions.setAutoResumeFiles = { settings.setAutoResumeFiles($0) }
        actions.setClipboardEagerLimit = { settings.setClipboardEagerLimit($0) }
        actions.forget = { pairing.forget(deviceID: $0) }
        actions.openPhoneFiles = { PhoneFilesWindowController.show(pairing: pairing, phoneID: $0) }
        actions.pair = { ring in
            guard let host = ring.peer?.host, let port = ring.peer?.port else { return }
            pairing.pair(host: host, port: port, peerName: ring.name, deviceIDHint: ring.peer?.deviceIDHint,
                         addresses: ring.peer?.addresses ?? [])
        }
        actions.pairAddress = { pairing.pairTailnet($0) }
        actions.trustAsMyDevice = { pairing.trustAsMyDevice($0) }
        actions.retryDevice = { pairing.retryNow(deviceID: $0) }
        actions.lookForDevices = { pairing.lookForDevices() }
        actions.openTailscaleSetup = { pairing.openTailscaleSetup() }
        actions.checkTailscale = { Task { await pairing.refreshTailnet() } }
        actions.enableNotifications = { pairing.enableNotifications() }
        actions.setShareActivityStatus = { settings.setShareActivityStatus($0) }
        actions.setHistoryEnabled = { settings.setNotificationHistoryEnabled($0) }
        actions.setCodesEnabled = { on in
            // Off from the row that reads on while it waits: the wait ends and the off syncs as a normal edit.
            if !on { pairing.codesSyncGate.turnedOffLocally() }
            settings.setCodesEnabled(on)
        }
        actions.setCodesAutoCopy = { settings.setCodesAutoCopy($0) }
        actions.setCodesEmail = { settings.setCodesEmail($0) }
        actions.setCodesFloat = { settings.setCodesFloat($0) }
        actions.setLocalAgentCodes = { localAgentCodes.set($0) }
        actions.installBrowserSupport = { browserSupport.install() }
        actions.removeBrowserSupport = { browserSupport.remove() }
        actions.openBrowserGuide = { NSWorkspace.shared.open(BrowserSupport.guideURL) }
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
        actions.setCallMediaMode = { settings.setCallMediaMode($0) }
        actions.setCallMediaRestoration = { settings.setCallMediaRestoration($0) }
        actions.setManualCall = { pairing.callMedia.setManualCall($0) }
        actions.checkCallMediaRecovery = { pairing.callMedia.checkSoundRecovery() }
        actions.restoreCallMediaSound = { pairing.callMedia.restoreSoundNow() }
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
        actions.setPanelMoves = { settings.setPanelMotion($0 ? .move : .fade) }
        actions.usePhoneLinks = { makeDefaultPhoneLinkHandler() }
        actions.setChannel = { updater.setChannel($0) }
        actions.setAutomaticallyChecks = { updater.setAutomaticallyChecks($0) }
        actions.checkForUpdates = { updater.checkForUpdates() }
        actions.update = updater.flowActions
        actions.updateAll = updateAll.actions
        actions.setRemoteStartUpdates = { updateAll.setRemoteStartAllowed($0) }
        actions.setAutoUpdate = { autoUpdate.setEnabled($0) }
        actions.openURL = { NSWorkspace.shared.open($0) }
        return setupCenter.hooked(actions, showPane: { open($0) }, inSetup: inSetup)
    }

    /// Shows an old pane: its group, scrolled to its card.
    private func open(_ pane: SettingsPane) { show(pane.card) }

    private func show(_ card: SettingsCardID) {
        group = card.group
        cardRequest = SettingsCardRequest(card: card)
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
