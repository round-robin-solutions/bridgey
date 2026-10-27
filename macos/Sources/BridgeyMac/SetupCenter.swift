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
        launchDecision = SetupLaunch.evaluate(store, trustFileExists: FileManager.default.fileExists(atPath: trustFile.path))
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

    func startSetup(at screen: SetupScreen = .welcome) {
        flow = SetupFlow(start: screen)
        requested = []
        refreshPermissions()
        showSetupWindow()
    }

    func send(_ event: SetupEvent) {
        flow.send(event)
    }

    func recordFeature(_ feature: BridgeyFeature, enabled: Bool) {
        if setupWindow?.isVisible == true { flow.recordFeature(feature.rawValue, enabled: enabled) }
    }

    func finishSetup(openSettings: Bool) {
        store.finish(flow.choices)
        settings?.completeOnboarding()
        recordWhatsNewSeen()
        showsReviewBanner = false
        choicesSink?.setupFinished(with: flow.choices)
        setupWindow?.close()
        if openSettings { openSettingsWindow() }
    }

    var setupActions: SetupActions {
        var actions = SetupActions()
        actions.send = { [weak self] in self?.send($0) }
        actions.allow = { [weak self] in self?.manage($0) }
        actions.confirmPairing = { [weak self] in self?.pairing?.confirm() }
        actions.cancelPairing = { [weak self] in self?.pairing?.cancel() }
        actions.openSettings = { [weak self] in self?.finishSetup(openSettings: true) }
        actions.start = { [weak self] in self?.finishSetup(openSettings: false) }
        return actions
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
            setupWindow = created
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
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
        whatsNewWindow?.close()
        let view = BrandRoot(reduceMotion: settings?.reduceMotion ?? false) {
            WhatsNewView(
                content: content,
                onReviewSetup: { [weak self] in
                    self?.closeWhatsNew()
                    self?.startSetup(at: .advanced(.devices))
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
        whatsNewWindow?.close()
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
            remoteControl: settings.globalFeatures[.remoteInput] == true,
            media: settings.globalFeatures[.media] == true,
            mediaPlayer: pairing?.mediaController.player ?? .off
        )
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
        let bundleID = automationBundleID
        let lastKnown = store.lastAutomation(bundleID)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = PermissionMapping.automation(AutomationProbe.state(bundleID: bundleID, ask: false), lastKnown: lastKnown)
            Task { @MainActor in
                self?.store.rememberAutomation(state, for: bundleID)
                self?.systemStates[.automation] = state
                self?.publishPermissions()
            }
        }
    }

    private func publishPermissions() {
        let needs = needs
        let next = SetupPermission.allCases.map {
            PermissionStatus(permission: $0, system: systemStates[$0] ?? .notDetermined, needed: needs.needed($0))
        }
        if next != permissions { permissions = next }
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

    private func request(_ permission: SetupPermission) {
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
        case .automation:
            let bundleID = automationBundleID
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
            reset.perform(.activity)
        case .caches:
            pairing?.codeModel.remove()
            reset.perform(.caches)
        case .settings, .everything:
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
    /// Privacy sub-pages, Run setup again, and (inside setup) the record of changed switches.
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
        let setGlobal = base.setGlobal
        actions.setGlobal = { [weak self] feature, enabled in
            setGlobal(feature, enabled)
            if inSetup { self?.recordFeature(feature, enabled: enabled) }
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
        SetupWindowView(flow: center.flow, model: model, actions: actions, setup: center.setupActions, requested: center.requested)
    }
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
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
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
