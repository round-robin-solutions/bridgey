import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UserNotifications

/*
 * The live side of setup, permissions, reset and What's new: decides at launch what to show,
 * owns the setup and What's new windows, reads permission states from the system and runs a
 * reset. One instance for the app (`shared`), so the panel and Settings can observe it without
 * new plumbing through their initialisers.
 */

@MainActor
final class SetupCenter: ObservableObject {
    static let shared = SetupCenter()

    @Published private(set) var flow = SetupFlow()
    @Published private(set) var showsReviewBanner = false
    @Published private(set) var permissions: [PermissionStatus] = SetupSettingsModel().permissions
    @Published private(set) var requested: Set<SetupPermission> = []
    @Published private(set) var resetMessage: String?

    /// Settings sync hook (settings_sync_draft1): gets the choices when setup finishes. Deferred.
    weak var choicesSink: SetupChoicesSink?

    let store: SetupStore
    let whatsNewStore: WhatsNewStore
    private(set) var launchDecision: SetupLaunchDecision = .none
    private var freshInstall = false

    private weak var discovery: BonjourDiscovery?
    private weak var pairing: PairingCoordinator?
    private weak var settings: BridgeySettings?
    private weak var updater: AppUpdater?
    private var openSettingsWindow: () -> Void = {}
    private var setupWindow: NSWindow?
    private lazy var windowDelegate = SetupWindowDelegate(center: self)
    /// The window is closing because setup finished or was left on purpose.
    private var closingSetup = false
    private var whatsNewWindow: NSWindow?
    private let localNetwork = LocalNetworkProbe()
    private var bluetoothRequest: BluetoothPermissionRequest?
    private var cancellables = Set<AnyCancellable>()
    private var systemStates: [SetupPermission: PermissionSystemState] = [:]

    init(defaults: UserDefaults = .standard) {
        store = SetupStore(defaults: defaults)
        whatsNewStore = WhatsNewStore(defaults: defaults)
    }

    // MARK: Launch

    /// First thing at launch, before any store loads: finishes a reset that needed a restart,
    /// then decides between setup, the review banner and nothing.
    func prepareLaunch() {
        LocalDataReset(defaults: store.defaults).performPending()
        let trustFile = MacPairingStore.defaultDirectory.appendingPathComponent(MacPairingStore.fileName)
        let hadWhatsNewRecord = whatsNewStore.lastBuild != nil
        let trustFileExists = FileManager.default.fileExists(atPath: trustFile.path)
        // Before BridgeySettings reads its switches: an install that ran before keeps its feature defaults.
        DefaultsGeneration.settle(store.defaults, priorInstall: SetupLaunch.hasStoredState(keys: store.defaults.dictionaryRepresentation().keys,
                                                                                           trustFileExists: trustFileExists))
        launchDecision = SetupLaunch.evaluate(store, trustFileExists: trustFileExists)
        freshInstall = launchDecision == .runSetup && !hadWhatsNewRecord
    }

    func configure(discovery: BonjourDiscovery, pairing: PairingCoordinator, settings: BridgeySettings, updater: AppUpdater,
                   openSettings: @escaping () -> Void) {
        self.discovery = discovery
        self.pairing = pairing
        self.settings = settings
        self.updater = updater
        openSettingsWindow = openSettings
        localNetwork.onChange = { [weak self] in self?.refreshPermissions() }
        localNetwork.start()
        // Keep the notes Sparkle offers, so the new build can show them once it is installed.
        updater.$flow
            .sink { [weak self] flow in
                if case let .available(offer) = flow, let notes = offer.notes { self?.whatsNewStore.rememberOffered(version: offer.version, notes: notes) }
            }
            .store(in: &cancellables)
        Publishers.Merge3(discovery.$peers.map { _ in () }, pairing.$connectedPhones.map { _ in () }, settings.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refreshPermissions() }
            .store(in: &cancellables)
        refreshPermissions()
        DispatchQueue.main.async { [weak self] in self?.showAtLaunch() }
    }

    private func showAtLaunch() {
        switch launchDecision {
        case .runSetup:
            recordWhatsNewSeen()
            startSetup()
        case .offerReview:
            showsReviewBanner = true
        case .none:
            switch WhatsNewLogic.decide(currentBuild: Self.currentBuild, lastBuild: whatsNewStore.lastBuild, freshInstall: freshInstall,
                                        hasNotes: currentNotes != nil, reviewSetup: false) {
            case .show: showWhatsNew(reviewSetup: false)
            case .skip(record: true): recordWhatsNewSeen()
            case .skip(record: false): break
            }
        }
    }

    static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    private var currentNotes: String? {
        whatsNewStore.notes(version: Self.currentVersion, bundled: WhatsNewStore.bundledNotes())
    }

    private func recordWhatsNewSeen() {
        whatsNewStore.record(build: Self.currentBuild, version: Self.currentVersion)
    }

    // MARK: Setup

    /// `review`: Settings > What's new > Review setup, which starts at the questions. A first-run
    /// setup left part way (window closed, or Bridgey quit) comes back at the same step.
    func startSetup(review: Bool = false) {
        if review {
            flow = .review()
        } else if launchDecision == .runSetup, let saved = store.savedFlow, saved.screen != .done {
            flow = saved
        } else {
            flow = SetupFlow()
        }
        requested = []
        allowQueue = []
        allowCurrent = nil
        refreshPermissions()
        showSetupWindow()
    }

    /// Applies what the event sets (picks, an answer, a switch, the Essentials, a refused
    /// permission's undo, a summary switch), then moves the flow on and keeps it for later.
    func send(_ event: SetupEvent, facts: SetupFacts) {
        for change in flow.changes(for: event, facts: facts) { apply(change) }
        flow.send(event, facts: facts)
        if flow.path == .advanced || flow.hasProgress { store.savedFlow = flow }
    }

    func finishSetup(openSettings: Bool) {
        allowQueue = []
        allowCurrent = nil
        store.finish(flow.choices)
        settings?.completeOnboarding()
        recordWhatsNewSeen()
        showsReviewBanner = false
        choicesSink?.setupFinished(with: flow.choices)
        closeSetupWindow()
        if openSettings { openSettingsWindow() }
    }

    /// Leaves setup without finishing: what was answered stays, and a fresh setup runs again next launch.
    func leaveSetup() {
        if flow.confirmLeave { flow.send(.keepGoing) }
        if flow.hasProgress { store.savedFlow = flow }
        allowQueue = []
        allowCurrent = nil
        closeSetupWindow()
    }

    private func closeSetupWindow() {
        closingSetup = true
        BridgeyWindows.close(setupWindow)
        closingSetup = false
        stopPolling()
    }

    /// While the permissions page shows, its statuses follow System Settings live.
    private var pollTimer: Timer?

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.setupWindow?.isVisible == true, self.flow.screen == .permissions else { return }
                self.refreshPermissions()
            }
        }
    }

    fileprivate func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    var setupActions: SetupActions {
        var actions = SetupActions()
        actions.dispatch = { [weak self] event, facts in self?.send(event, facts: facts) }
        actions.allow = { [weak self] in self?.manage($0) }
        actions.requestFromPage = { [weak self] in self?.requestFromPage($0) }
        actions.allowAll = { [weak self] in self?.allowAll($0) }
        actions.confirmPairing = { [weak self] in self?.pairing?.confirm() }
        actions.cancelPairing = { [weak self] in self?.pairing?.cancel() }
        actions.openSettings = { [weak self] in self?.finishSetup(openSettings: true) }
        actions.start = { [weak self] in self?.finishSetup(openSettings: false) }
        actions.leave = { [weak self] in self?.leaveSetup() }
        return actions
    }

    /// A row on setup's permissions page: the row already says why, so macOS asks now (or the
    /// exact System Settings page opens). The page shows the live status when Bridgey is back.
    private func requestFromPage(_ permission: SetupPermission) {
        store.markExplained(permission)
        flow.send(.asked([permission]))
        request(permission)
    }

    // MARK: Allow all

    /// Allow all on the permissions page: each row that is not allowed, in order. The next one
    /// starts when macOS has answered, when Bridgey is back from System Settings, or after a while.
    private var allowQueue: [SetupPermission] = []
    private var allowCurrent: SetupPermission?
    private var allowLeftWindow = false
    private var allowToken = 0

    func allowAll(_ permissions: [SetupPermission]) {
        allowQueue = permissions.filter { status($0).system != .allowed }
        allowNext()
    }

    private func allowNext() {
        allowToken += 1
        guard !allowQueue.isEmpty else {
            allowCurrent = nil
            return
        }
        let next = allowQueue.removeFirst()
        allowCurrent = next
        allowLeftWindow = false
        requestFromPage(next)
        let token = allowToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.allowToken == token, !self.allowLeftWindow else { return }
            self.allowNext()
        }
    }

    /// macOS answered the current one (allowed or not): on to the next.
    private func allowAnswered() {
        guard let current = allowCurrent, status(current).system != .notDetermined else { return }
        let token = allowToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.allowToken == token else { return }
            self.allowNext()
        }
    }

    /// Sets one setting an answer chose. Permissions (`macNotifications`, `accessibility`) are asked
    /// by the question's permission step; More options settings are never set here.
    func apply(_ change: SettingChange) {
        guard let settings, let pairing else { return }
        let on = change.value == "true"
        switch change.setting {
        case .featureClipboard: settings.setGlobal(.clipboard, enabled: on)
        case .autoClipboard: settings.setAutoClipboard(on)
        case .clipboardFiles: settings.setClipboardFilesEnabled(on)
        case .featureNotifications: settings.setGlobal(.notifications, enabled: on)
        case .codesEnabled: settings.setCodesEnabled(on)
        case .codesEngine: CodeEngine(rawValue: change.value).map(settings.setCodesEngine)
        case .notificationHistory: settings.setNotificationHistoryEnabled(on)
        case .featureMessages: pairing.setTextMessagesEnabled(on)
        case .smsKeepOnMac: pairing.setTextMessagesKeepOnMac(on)
        case .focusShare: pairing.focusSync.update { $0.share = on }
        case .focusFollow: pairing.focusSync.update { $0.follow = on }
        case .featureCalls: settings.setGlobal(.calls, enabled: on)
        case .ringForCalls:
            settings.setRingForIncomingCalls(on)
            pairing.refreshCallRinging()
        case .pauseForCalls: pairing.mediaController.pauseForCalls = on
        case .phoneLinks: if on { Self.usePhoneLinks() }
        case .featureFiles: settings.setGlobal(.files, enabled: on)
        case .folderReceiveMode: MacFolderReceiveMode(rawValue: change.value).map(settings.setFolderReceiveMode)
        case .sendImageMode:
            var optimization = SendPreferences.shared.optimization
            optimization.imageMode = SendOptimization.ImageMode(rawValue: change.value) ?? .original
            SendPreferences.shared.setOptimization(optimization)
        case .cameraCopyToClipboard: pairing.camera.setCopyToClipboard(on)
        case .featureRemoteInput:
            settings.setGlobal(.remoteInput, enabled: on)
            pairing.remoteInput.policyChanged()
        case .remoteGrant:
            for device in pairing.trustedDevices { settings.setForDevice(device.id, feature: .remoteInput, enabled: on) }
            pairing.remoteInput.policyChanged()
        case .featureScreen: pairing.phoneScreen.setEnabled(on)
        case .featureMacActions: settings.setGlobal(.macActions, enabled: on)
        case .macActionsGrant:
            for device in pairing.trustedDevices { settings.setForDevice(device.id, feature: .macActions, enabled: on) }
        case .macActionSwitches:
            let listed = Set(change.value.split(separator: ",").map(String.init))
            for item in [MacActionSwitch.lock, .sleep, .volume] { pairing.macActions.setSwitch(item, enabled: listed.contains(item.rawValue)) }
        case .featureMedia:
            settings.setGlobal(.media, enabled: on)
            // Turned on without a player: Music, which a follow-up or Settings can change.
            if on && pairing.mediaController.player == .off { pairing.mediaController.player = .music }
        case .mediaPlayer: MediaPlayer(rawValue: change.value).map { pairing.mediaController.player = $0 }
        case .featureLinks: settings.setGlobal(.links, enabled: on)
        case .openLinksRightAway: settings.setOpenLinksRightAway(on)
        case .featureFindDevice:
            settings.setGlobal(.findDevice, enabled: on)
            if !on { pairing.stopFinding() }
        case .featurePing: settings.setGlobal(.ping, enabled: on)
        case .featureBattery: settings.setGlobal(.battery, enabled: on)
        case .showPreviews: settings.setShowActivityPreviews(on)
        case .loggingConnection:
            var logging = settings.logging
            logging.connection = on
            settings.setLogging(logging)
        case .updateChannel: UpdateChannel(rawValue: change.value).map { updater?.setChannel($0) }
        case .updatesAutomatic: updater?.setAutomaticallyChecks(on)
        case .launchAtLogin: settings.setLaunchAtLogin(on)
        case .reduceMotion: settings.setReduceMotion(on)
        case .settingsSync: pairing.settingsSync.setEnabled(on)
        case .pairing, .macNotifications, .accessibility, .deviceFeatures, .deviceAutoClipboard, .batteryAlerts,
             .clipboardEagerLimit, .shortcutClipboard, .codesAutoCopy, .codesModel, .codesPhoneLink, .focusShortcuts,
             .shortcutCall, .receiveFolder, .folderIncludeHidden, .folderIncludeSystem, .folderConflict, .tagReceivedFiles,
             .sendOptionsDetail, .menuBarDropMode, .macActionApps, .macActionShortcuts, .macActionsLog, .shortcutLink,
             .shortcutPing, .remoteLog, .loggingDetail, .shortcutShift:
            break
        }
    }

    /// Calls numbers you click: Bridgey becomes the app for tel: links (the browser still asks first).
    private static func usePhoneLinks() {
        let application = Bundle.main.bundleURL
        guard application.pathExtension == "app" else { return }
        NSWorkspace.shared.setDefaultApplication(at: application, toOpenURLsWithScheme: "tel") { _ in }
    }

    private func showSetupWindow() {
        guard let discovery, let pairing, let settings, let updater else { return }
        if setupWindow == nil {
            let content = LiveSettingsView(discovery: discovery, pairing: pairing, settings: settings, updater: updater, inSetup: true)
            let created = NSWindow(contentViewController: NSHostingController(rootView: content))
            created.title = L10n.setup("setup.window", fallback: "Set up Bridgey")
            created.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.setContentSize(NSSize(width: SetupWindowView.size.width, height: SetupWindowView.size.height))
            created.isReleasedWhenClosed = false
            created.center()
            created.delegate = windowDelegate
            setupWindow = created
        }
        startPolling()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// The close button mid-way asks "Leave setup?" first; on the first screen with nothing chosen it closes.
    fileprivate func setupWindowShouldClose() -> Bool {
        if closingSetup || !SetupBack.closeAsks(flow) { return true }
        flow.send(.askLeave)
        return false
    }

    /// Back in the app after System Settings: read the permissions again, and Allow all goes on.
    fileprivate func setupWindowBecameKey() {
        refreshPermissions()
        if allowCurrent != nil && allowLeftWindow {
            allowLeftWindow = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.allowNext() }
        }
    }

    /// System Settings (or a macOS prompt) took the focus while Allow all waits.
    fileprivate func setupWindowResignedKey() {
        if allowCurrent != nil { allowLeftWindow = true }
    }

    // MARK: Review banner and What's new

    func openReviewBanner() {
        showsReviewBanner = false
        store.markSetupSeen()
        showWhatsNew(reviewSetup: true)
    }

    func dismissReviewBanner() {
        showsReviewBanner = false
        store.markSetupSeen()
        recordWhatsNewSeen()
    }

    func showWhatsNew(reviewSetup: Bool) {
        let content = WhatsNewContent.make(version: Self.currentVersion, notes: currentNotes, reviewSetup: reviewSetup)
        BridgeyWindows.close(whatsNewWindow)
        let view = BrandRoot(reduceMotion: settings?.reduceMotion ?? false) {
            WhatsNewView(
                content: content,
                onReviewSetup: { [weak self] in
                    self?.closeWhatsNew()
                    self?.startSetup(review: true)
                },
                onOpenNotes: { NSWorkspace.shared.open(content.notesURL) },
                onDone: { [weak self] in self?.closeWhatsNew() }
            )
        }
        let created = NSWindow(contentViewController: NSHostingController(rootView: view))
        created.title = L10n.setup("whatsNew.title", fallback: "What\u{2019}s new")
        created.styleMask = [.titled, .closable, .fullSizeContentView]
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.isReleasedWhenClosed = false
        created.center()
        whatsNewWindow = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
        // Shown once: closing the window counts as Got it.
        recordWhatsNewSeen()
    }

    private func closeWhatsNew() {
        BridgeyWindows.close(whatsNewWindow)
        whatsNewWindow = nil
    }

    // MARK: Permissions

    var settingsModel: SetupSettingsModel {
        SetupSettingsModel(permissions: permissions, resetMessage: resetMessage)
    }

    private var needs: PermissionNeeds {
        guard let settings else { return PermissionNeeds() }
        return PermissionNeeds(
            notifications: settings.globalFeatures[.notifications] != false,
            calls: settings.globalFeatures[.calls] != false,
            codes: settings.codesEnabled,
            messages: settings.smsEnabled,
            remoteControl: settings.globalFeatures[.remoteInput] == true,
            media: settings.globalFeatures[.media] == true,
            mediaPlayer: pairing?.mediaController.player ?? .off,
            macActionsLock: settings.globalFeatures[.macActions] == true && pairing?.macActions.config.isOn(.lock) == true,
            browserTab: settings.globalFeatures[.links] != false
        )
    }

    /// The browser Send current browser tab would ask: the last one used that is running, else Safari.
    private var browserBundleID: String {
        pairing?.browserTab.browser?.rawValue ?? SupportedBrowser.safari.rawValue
    }

    private var automationBundleID: String {
        let player = pairing?.mediaController.player ?? .off
        return player == .off ? MediaPlayer.music.bundleID : player.bundleID
    }

    func refreshPermissions() {
        let reached = !(discovery?.peers.isEmpty ?? true) || !(pairing?.connectedPhones.isEmpty ?? true)
        systemStates[.localNetwork] = PermissionMapping.localNetwork(browseDenied: localNetwork.denied, reachedADevice: reached)
        systemStates[.bluetooth] = PermissionMapping.bluetooth(CBManager.authorization)
        systemStates[.accessibility] = PermissionMapping.accessibility(trusted: AccessibilityAccess.isTrusted())
        publishPermissions()
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let state = PermissionMapping.notifications(settings.authorizationStatus)
            Task { @MainActor in
                self?.systemStates[.notifications] = state
                self?.publishPermissions()
            }
        }
        for (permission, bundleID) in [(SetupPermission.automation, automationBundleID), (.browserAutomation, browserBundleID)] {
            let lastKnown = store.lastAutomation(bundleID)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let state = PermissionMapping.automation(AutomationProbe.state(bundleID: bundleID, ask: false), lastKnown: lastKnown)
                Task { @MainActor in
                    self?.store.rememberAutomation(state, for: bundleID)
                    self?.systemStates[permission] = state
                    self?.publishPermissions()
                }
            }
        }
    }

    private func publishPermissions() {
        let needs = needs
        let next = SetupPermission.allCases.map {
            PermissionStatus(permission: $0, system: systemStates[$0] ?? .notDetermined, needed: needs.needed($0))
        }
        if next != permissions { permissions = next }
        allowAnswered()
    }

    private func status(_ permission: SetupPermission) -> PermissionStatus {
        permissions.first { $0.permission == permission }
            ?? PermissionStatus(permission: permission, system: .notDetermined, needed: true)
    }

    /// Manage (Permissions page) and Allow (quick step): the explainer the first time, then the
    /// macOS prompt if it has not asked yet, else the exact System Settings page.
    func manage(_ permission: SetupPermission) {
        explainThen(permission) { [weak self] in self?.request(permission) }
    }

    /// The (i) on the Permissions page: always shows the explainer.
    func explain(_ permission: SetupPermission) {
        explainThen(permission, always: true) { [weak self] in self?.request(permission) }
    }

    /// Runs `proceed` after the explainer, or at once when it was explained before or is allowed.
    func explainThen(_ permission: SetupPermission, always: Bool = false, _ proceed: @escaping () -> Void) {
        if !always && (store.wasExplained(permission) || status(permission).system == .allowed) {
            proceed()
            return
        }
        store.markExplained(permission)
        BrandSheet.present(reduceMotion: settings?.reduceMotion ?? false) { dismiss in
            PermissionExplainerView(permission: permission,
                                    onContinue: { dismiss(); proceed() },
                                    onNotNow: dismiss)
        }
    }

    func request(_ permission: SetupPermission) {
        requested.insert(permission)
        let current = status(permission)
        if current.manage == .openSettings && permission != .localNetwork {
            NSWorkspace.shared.open(permission.settingsURL)
            refreshSoon()
            return
        }
        switch permission {
        case .localNetwork:
            if current.system == .denied {
                NSWorkspace.shared.open(permission.settingsURL)
            } else {
                // The prompt appears on the first browse; asking again also finds the phone sooner.
                localNetwork.restart()
                pairing?.lookForDevices()
            }
        case .notifications:
            pairing?.enableNotifications()
        case .bluetooth:
            let request = BluetoothPermissionRequest()
            bluetoothRequest = request
            request.request { [weak self] in
                self?.bluetoothRequest = nil
                self?.refreshPermissions()
            }
        case .accessibility:
            AccessibilityAccess.request()
        case .automation, .browserAutomation:
            let bundleID = permission == .automation ? automationBundleID : browserBundleID
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                NSWorkspace.shared.open(permission.settingsURL)
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    _ = AutomationProbe.state(bundleID: bundleID, ask: true)
                    Task { @MainActor in self?.refreshPermissions() }
                }
            }
        }
        refreshSoon()
    }

    private func refreshSoon() {
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refreshPermissions() }
        }
    }

    // MARK: Reset

    func confirmReset(_ choice: ResetChoice) {
        resetMessage = nil
        BrandSheet.present(reduceMotion: settings?.reduceMotion ?? false) { [weak self] dismiss in
            ResetConfirmView(choice: choice,
                             onConfirm: { dismiss(); self?.performReset(choice) },
                             onCancel: dismiss)
        }
    }

    func performReset(_ choice: ResetChoice) {
        let reset = LocalDataReset(defaults: store.defaults)
        switch choice {
        case .activity:
            pairing?.activity.clear()
            pairing?.clearNotificationHistory()
            pairing?.clearDiagnostics()
            pairing?.remoteInput.audit.clear()
            pairing?.clearTransferHistory()
            // Files 2.0: the History window's entries, before the file goes.
            pairing?.transferHistory.clear()
            // v0.9: the Mac actions log and the connection health counters.
            pairing?.macActions.audit.clear()
            pairing?.clearConnectionHealth()
            // Text messages kept on this Mac, in memory and on disk.
            pairing?.textMessages.deleteAll()
            reset.perform(.activity)
        case .caches:
            pairing?.codeModel.remove()
            reset.perform(.caches)
        case .settings, .everything:
            // v0.9: a Focus that following a phone turned on is handed back while Bridgey still knows it did.
            pairing?.focusSync.update { $0.follow = false }
            if choice == .everything, let pairing {
                // Sessions end before their pairings go, and nothing new connects meanwhile.
                discovery?.stop()
                pairing.cancel()
                for phone in pairing.connectedPhones { pairing.disconnect(deviceID: phone.id) }
            }
            reset.perform(choice)
            reset.schedule(choice)
            resetMessage = choice.doneMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Self.relaunch() }
            return
        }
        resetMessage = choice.doneMessage
    }

    /// Quits, then opens the app again once this process has exited.
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                                 bundle.path, String(ProcessInfo.processInfo.processIdentifier)]
            try? process.run()
        }
        NSApp.terminate(nil)
    }

    // MARK: Settings window hooks

    /// The Settings actions with setup's hooks: the explainer before in-context requests, the
    /// Privacy sub-pages and Run setup again. `inSetup`: drawn inside the setup window.
    func hooked(_ base: SettingsActions, showPane: @escaping (SettingsPane) -> Void, inSetup: Bool) -> SettingsActions {
        var actions = base
        let enableNotifications = base.enableNotifications
        actions.enableNotifications = { [weak self] in
            guard let self else { return enableNotifications() }
            self.requested.insert(.notifications)
            self.explainThen(.notifications) { enableNotifications() }
        }
        let linkPhone = base.linkPhone
        actions.linkPhone = { [weak self] in
            guard let self else { return linkPhone() }
            self.explainThen(.bluetooth) { linkPhone() }
        }
        let setPlayer = base.setPlayer
        actions.setPlayer = { [weak self] player in
            guard let self, player != .off else { return setPlayer(player) }
            self.explainThen(.automation) { setPlayer(player) }
        }
        actions.setup.showPane = showPane
        actions.setup.managePermission = { [weak self] in self?.manage($0) }
        actions.setup.explainPermission = { [weak self] in self?.explain($0) }
        actions.setup.refreshPermissions = { [weak self] in self?.refreshPermissions() }
        actions.setup.confirmReset = { [weak self] in self?.confirmReset($0) }
        actions.setup.runSetupAgain = { [weak self] in self?.startSetup() }
        return actions
    }

    /// Remote control asks for Accessibility when turned on: the explainer comes first.
    func requestAccessibility(_ request: @escaping () -> Void) {
        explainThen(.accessibility, request)
    }
}

// MARK: - The setup window's content

extension SetupWindowView {
    /// What LiveSettingsView shows in the setup window.
    @MainActor static func live(model: SettingsModel, actions: SettingsActions, center: SetupCenter) -> SetupWindowView {
        SetupWindowView(flow: center.flow, model: model, actions: actions, setup: center.setupActions, requested: center.requested,
                        sendImageMode: SendPreferences.shared.optimization.imageMode.rawValue)
    }
}

/// The setup window's delegate: the close button asks first mid-way, and coming back from System
/// Settings refreshes the permissions a question is waiting for.
@MainActor
final class SetupWindowDelegate: NSObject, NSWindowDelegate {
    private weak var center: SetupCenter?

    init(center: SetupCenter) { self.center = center }

    func windowShouldClose(_ sender: NSWindow) -> Bool { center?.setupWindowShouldClose() ?? true }

    func windowDidBecomeKey(_ notification: Notification) { center?.setupWindowBecameKey() }

    func windowDidResignKey(_ notification: Notification) { center?.setupWindowResignedKey() }

    func windowWillClose(_ notification: Notification) { center?.stopPolling() }
}

// MARK: - Sheets

/// Presents a SwiftUI dialog as a sheet on the key window (or on its own when there is none),
/// so the explainer and the reset confirm look the same everywhere and render in screenshots.
@MainActor
enum BrandSheet {
    static func present<Content: View>(reduceMotion: Bool, @ViewBuilder _ content: (@escaping () -> Void) -> Content) {
        let parent = NSApp.keyWindow.flatMap { $0 is NSPanel ? nil : $0 }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.isReleasedWhenClosed = false
        var dismissed = false
        let dismiss: () -> Void = { [weak sheet] in
            guard !dismissed, let sheet else { return }
            dismissed = true
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { BridgeyWindows.close(sheet) }
        }
        let host = NSHostingController(rootView: BrandRoot(reduceMotion: reduceMotion) { content(dismiss) })
        host.sizingOptions = .preferredContentSize
        sheet.contentViewController = host
        sheet.setContentSize(host.view.fittingSize)
        if let parent {
            parent.beginSheet(sheet)
        } else {
            sheet.level = .floating
            sheet.center()
            NSApp.activate(ignoringOtherApps: true)
            sheet.makeKeyAndOrderFront(nil)
        }
    }
}
