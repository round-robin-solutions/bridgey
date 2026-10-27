import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import os
import Security
import Carbon
import UserNotifications
import UniformTypeIdentifiers

enum PairingState: Equatable {
    case idle
    case connecting(String)
    case verification(peerName: String, code: String)
    case connected(deviceID: String, peerName: String)
    case failed(String)
}

struct RemoteBatteryStatus: Equatable {
    let level: Int
    let isCharging: Bool
}

struct RemoteCallAction: Identifiable, Equatable {
    let id: String
    let title: String
}

struct RemoteCallStatus: Equatable {
    let notificationID: String
    let deviceID: String
    let applicationName: String
    let caller: String
    let detail: String
    let type: String
    let actions: [RemoteCallAction]
}

struct FileTransferRow: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let active: Bool
    let startedAt: Date
    let retryable: Bool
    let queued: Bool
    /// Set for a folder transfer (one row per folder): progress, destination, failures, last names.
    let folder: FolderRowSummary?
    /// The item on this Mac, for "Show in Finder": what was received, or the source of a send. Nil when unknown.
    let localURL: URL?

    init(
        id: String,
        name: String,
        status: String,
        active: Bool,
        startedAt: Date = Date(),
        retryable: Bool = false,
        queued: Bool = false,
        folder: FolderRowSummary? = nil,
        localURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.active = active
        self.startedAt = startedAt
        self.retryable = retryable
        self.queued = queued
        self.folder = folder
        self.localURL = localURL
    }
}


struct TrustedDeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
}

private struct BatteryPayload: Codable {
    let level: Int
    let isCharging: Bool
}

private struct RemoteNotificationPayload: Codable {
    let packageName: String
    let applicationName: String
    let notificationId: String
    let title: String
    let text: String
    let timestamp: Int64
    let actions: [RemoteNotificationActionPayload]?
    let applicationIcon: String?
    let callType: String?
    /// Edition (sms_codes_draft1): the notification came from the phone's default SMS app.
    var smsDefaultApp: Bool? = nil
    /// Edition (sms_codes_draft1): Android hid the text from Bridgey ("Sensitive notification content hidden").
    var redacted: Bool? = nil
}

private struct RemoteNotificationActionPayload: Codable {
    let actionToken: String
    let title: String
    let allowsReply: Bool
}

private struct NotificationReferencePayload: Codable {
    let notificationId: String
    /// notifications.remove only: the phone saw the call end, so its card goes at once.
    var callEnded: Bool? = nil
}

private struct NotificationActionCommandPayload: Codable {
    let notificationId: String
    let actionToken: String
    let replyText: String?
}

private struct FileOfferPayload: Codable {
    let transferId: String
    let name: String
    let mimeType: String
    let size: Int64
    let sha256: String
    /// Edition (camera_draft1): the photo answers this Mac's camera.request.
    var cameraRequestId: String? = nil
}

private struct FileCompletePayload: Codable {
    let transferId: String
    let sha256: String
}

private struct FindDevicePayload: Codable {
    let alertId: String
}

private struct PingPayload: Codable {
    let version: Int
}

private struct CallRequestPayload: Codable {
    let number: String
}

private struct FeatureStatePayload: Codable {
    let version: Int
    let features: [String: Bool]
}

private func defaultRemoteFeatureState() -> [BridgeyFeature: Bool] {
    Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, featureEnabledByLegacyPeer($0)) })
}

private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    var onDismiss: ((String, String) -> Void)?
    var onAction: ((String, String, String, String?) -> Void)?
    /// Copy code, or a click on a code banner: the in-memory reference of the code to copy.
    var onCopyCode: ((String) -> Void)?
    /// Open or Show in Finder on a received-file notification (Files 2.0).
    var onReceived: ((ReceivedNotificationAction) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        if response.notification.request.content.categoryIdentifier == receivedNotificationCategory {
            onReceived?(ReceivedNotificationAction.route(actionIdentifier: response.actionIdentifier, userInfo: userInfo))
            return
        }
        if let codeReference = userInfo[codeReferenceUserInfoKey] as? String,
           response.actionIdentifier == codeCopyActionIdentifier || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            onCopyCode?(codeReference)
            return
        }
        guard let notificationID = response.notification.request.content.userInfo["androidNotificationId"] as? String,
              let deviceID = response.notification.request.content.userInfo["androidDeviceId"] as? String else { return }
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            onDismiss?(notificationID, deviceID)
        } else if response.actionIdentifier != UNNotificationDefaultActionIdentifier {
            let replyText = (response as? UNTextInputNotificationResponse)?.userText
            onAction?(notificationID, deviceID, response.actionIdentifier, replyText)
        }
    }
}

@MainActor
final class PairingCoordinator: ObservableObject {
    /// Aggregate: connected (to the selected phone) while any phone is connected, else the pairing flow.
    @Published private(set) var state: PairingState = .idle {
        didSet { refreshAutoClipboard() }
    }
    /// The pairing in progress only: connecting, verification or failed, else idle. Owns the prompt.
    @Published private(set) var pairingFlow: PairingState = .idle
    /// Every connected phone with its own features, battery and ringing state, in connection order.
    @Published private(set) var connectedPhones: [PhoneConnection] = []
    /// The phone outgoing actions aim at (nil: the latest connection).
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var trustedDeviceIDs: Set<String>
    /// Set while the pairing file cannot be loaded (for example the one-time Keychain move was
    /// denied). Pairing and reconnects wait until it clears; the panel explains why.
    @Published private(set) var pairingStoreIssue: PairingStoreIssue?
    @Published private(set) var clipboardStatus: String? = nil
    @Published private(set) var remoteBattery: RemoteBatteryStatus? = nil
    @Published private(set) var notificationsAuthorized = false
    @Published private(set) var notificationPermissionDetermined = false
    @Published private(set) var fileTransferStatus: String? = nil
    @Published private(set) var fileTransferActive = false
    @Published private(set) var fileTransfers: [String: FileTransferRow] = [:]
    @Published private(set) var macRinging = false
    @Published private(set) var androidRinging = false
    @Published private(set) var remoteFeatures = defaultRemoteFeatureState()
    @Published private(set) var notificationHistory: [NotificationHistoryItem] = []
    @Published private(set) var remoteCall: RemoteCallStatus?
    @Published private(set) var callStatus: String?
    @Published private(set) var pingStatus: String?
    let quickActions = QuickActions()
    /// The private local activity stream shown in the panel.
    let activity: ActivityLog
    let mediaController = MediaController()
    let shortcuts = ShortcutSettings()
    /// Remote input (draft): a paired phone as touchpad, keyboard and presentation remote.
    let remoteInput: RemoteInputHost
    /// Files 2.0: every finished transfer, for the History window and Show in Finder (owner-only, 30 days).
    let transferHistory = TransferHistoryStore()
    /// Notifications for files and folders that arrive from a phone (Files 2.0 quick win).
    private let receivedNotifier = ReceivedNotifier()
    private var freeSpaceThrottle = FreeSpaceThrottle()
    private var freeSpaceTrailing: [String: DispatchWorkItem] = [:]
    /// Free space each connected phone reported for its default destination (FreeSpace.swift).
    @Published private(set) var phoneFreeSpace: [String: PhoneFreeSpace] = [:]
    /// Files 2.0: browsing, thumbnails, downloads and uploads for the Phone files window.
    var phoneFiles: PhoneFilesService { phoneFilesController }
    private(set) lazy var phoneFilesController = PhoneFilesController(host: self)
    /// Mac actions (draft): lock, sleep, screen saver, volume, listed apps and Shortcuts for phones you allow.
    let macActions: MacActionsHost
    /// Send the current Safari or Chrome tab to the phone.
    let browserTab = BrowserTabReader()
    /// "OnePlus 11 at 15%" and "OnePlus 11 fully charged", per phone thresholds.
    let batteryAlerts = BatteryAlerts()
    /// Focus and Do Not Disturb sync with phones (draft focus_sync_draft1), off by default.
    let focusSync = FocusSync()
    /// Settings sync with phones (draft settings_sync_draft1): folder, preview and motion preferences.
    private(set) lazy var settingsSync = SettingsSyncController.live(localDeviceID: deviceID, settings: settings, focus: focusSync, codes: codesSyncGate)
    /// Codes from messages turned on from another device waits here until this Mac gives its own consent.
    private(set) lazy var codesSyncGate = CodesSyncGate(
        isOn: { [unowned self] in self.settings.codesEnabled },
        setOn: { [unowned self] in self.settings.setCodesEnabled($0) },
        // The cloud relay asks every time it is turned on; the local engine needs its model (terms accepted on download).
        canEnable: { [unowned self] in self.settings.codesEngine == .local && self.codeModel.installed != nil }
    )
    private var settingsSyncCancellables: Set<AnyCancellable> = []
    private let syncQuestionWindows = SyncQuestionWindows()
    /// "Take Photo with OnePlus 11" (draft camera_draft1).
    let camera = PhoneCamera()
    /// Incoming transfers that are camera photos, by transfer ID, with their request ID.
    private var cameraTransfers: [String: String] = [:]
    /// Connection health per paired phone (no addresses, names or content).
    @Published private(set) var connectionHealth: [String: ConnectionHealthSnapshot] = [:]
    private var healthRecords: [String: DeviceHealthRecord] = [:]
    /// Bonjour's state, for the health view.
    var discoveryHealth: () -> DiscoveryHealth = { .browsing }

    var trustedDevices: [TrustedDeviceInfo] {
        trustRegistry.devices.map { device in
            TrustedDeviceInfo(id: device.id, name: device.name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private let deviceID: String
    private var deviceName: String
    private let settings: BridgeySettings
    private var identity: MacIdentity?
    private let pairingStore: MacPairingStore
    private let trustRegistry: MacTrustRegistry
    private var listener: NWListener?
    /// Multi-device sessions: pending (handshaking or pairing) and one per phone.
    private lazy var registry = SessionRegistry<Session>(localDeviceID: deviceID)
    /// The session whose code is on screen, or the pairing the user started.
    private var pairingSession: Session?
    private var publishedTarget: String?
    /// The selected phone's session: what single-target actions (send, ping, find, files) use.
    private var session: Session? {
        registry.target(selected: selectedDeviceID).flatMap { registry.session(for: $0) }
    }
    private var discoveryCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var lastPeers: [DiscoveredPeer] = []
    /// Reconnects. Both sides keep trying a dropped trusted phone at its known addresses, whoever
    /// dialled before; the session registry keeps one socket when both dial at once.
    private let clock: ReconnectClock = MainQueueClock()
    private lazy var reconnect = ReconnectEngine(addressBook: KnownAddressBook(store: UserDefaultsAddressBookStore()), clock: clock)
    private var discoveryRestartTimer: ScheduledTask?
    private var lastDiscoveryRestart = Date.distantPast
    /// Periodic discovery restarts run for `discoveryRestartWindow` after this moment.
    private var discoveryWindowStart: Date?
    private let linkMonitor = LinkEventMonitor()
    private lazy var linkDebouncer = EventDebouncer(clock: clock) { [weak self] reasons in self?.linkChanged(reasons) }
    private var restartDiscovery: ((String) -> Void)?
    /// Each disconnected trusted phone's reconnect state, for the rings and chips.
    @Published private(set) var reconnectStates: [String: ReconnectDisplay] = [:]
    /// "Look for devices again": its feedback line, and the run in progress.
    @Published private(set) var rediscoverStatus: String?
    private var rediscoverRun: (missing: [String: String], nearbyBefore: Set<String>, finish: ScheduledTask)?
    private var rediscoverStatusClear: ScheduledTask?
    /// Which phone each file transfer belongs to.
    private var transferDevices: [String: String] = [:]
    private var macRingingFrom: String?
    private var quickReplyTarget: Session?
    private var callRequestID: String?
    private var callTimeoutWorkItem: DispatchWorkItem?
    private var callStatusClearWorkItem: DispatchWorkItem?
    private var pingRequestID: String?
    private var pingStatusClearWorkItem: DispatchWorkItem?
    private var pendingCallNumber: String?
    private var pendingCallExpiryWorkItem: DispatchWorkItem?
    /// The selected phone sent its features.update. Per phone: `connectedPhones`.
    private var remoteFeatureStateReceived = false
    /// The selected phone advertised `clipboard_files_draft1` in its last features.update.
    private(set) var remoteClipboardFiles = false
    private let clipboardCache = ClipboardCache()
    private lazy var clipboardInbox = ClipboardInbox(cache: clipboardCache)
    private lazy var clipboardOutbox = ClipboardOutbox(cache: clipboardCache)
    private var clipboardFilesCancellable: AnyCancellable?
    /// The outgoing offer waiting for clipboard.ack: its message ID and what the stream records.
    private var pendingOfferAck: (messageID: String, summary: ClipboardOfferSummary, automatic: Bool, timeout: DispatchWorkItem)?
    private var clipboardSendID: String?
    private var clipboardTimeoutWorkItem: DispatchWorkItem?
    private let notificationPresenter = NotificationPresenter()
    /// Codes from messages: the newest code card in the panel (ten minutes), and its link status line.
    @Published private(set) var liveCode: LiveCodeCard?
    @Published private(set) var codeLinkStatus: String?
    /// Codes from messages > On this Mac: the model file, its download and the engine.
    let codeModel: CodeModelStore
    /// Reads waiting for the engine, by notification request identifier.
    private var codeReads: [String: Task<Void, Never>] = [:]
    /// Codes that can still be copied, in memory only.
    private var liveCodes: [String: LiveCodeCard] = [:]
    private var liveCodeOrder: [String] = []
    private let liveCodeLifetime: TimeInterval = 10 * 60
    private let codeClipboard = CodeClipboard()
    private let companionAdvertiser = CompanionLinkAdvertiser()
    private var remoteNotificationCategories: [String: UNNotificationCategory] = [:]
    private var incomingFiles: [String: IncomingFileTransfer] = [:]
    private var outgoingFiles: [String: OutgoingFileTransfer] = [:]
    private var outgoingFileSources: [String: URL] = [:]
    /// One sequential send queue per phone: a phone gets one file at a time.
    private var fileSendQueues: [String: FileSendQueue<OutgoingQueueItem>] = [:]
    /// Folders this Mac sends (Files 2.0); one item each in the phone's queue.
    private lazy var folders = FolderSender(host: self)
    /// Folders sent to this Mac, and downloads from the Phone files window (Files 2.0 browse).
    private lazy var folderReceiver = FolderReceiver(host: self)
    /// Hashing in progress, per queued file, so Cancel stops it.
    private var filePreparationCancellations: [String: FileCancellationToken] = [:]
    private var fileTransferWindow: FileTransferWindowController?
    private var fileDropWindow: FileDropWindowController?
    private lazy var callOverlayWindow = CallOverlayWindowController(pairing: self)
    private var activeRemoteCalls = ActiveRemoteCalls()
    private var hiddenCallOverlayIdentities = Set<String>()
    private var audibleCallIdentities = Set<String>()
    private var recordedCallIdentities = Set<String>()
    /// Calls the user hid or acted on from the Mac: they no longer ring.
    private var silencedCallIdentities = Set<String>()
    private let callRinger = CallRinger()
    /// The clipboard being sent, as a stream preview, until the phone acknowledges it.
    private var pendingClipboardActivity: (preview: String?, sensitive: Bool, automatic: Bool)?
    private let autoClipboard = AutoClipboardWatcher()
    private var autoClipboardCancellable: AnyCancellable?
    /// Accessibility allowed or removed: Lock's "needs permission" mark changes in the catalogs.
    private var accessibilityCancellable: AnyCancellable?
    private var alertedNotificationIdentifiers = AlertedNotificationIdentifiers()
    private var cancelledTransferIDs = Set<String>()
    private var findDeviceSound: NSSound?
    private var lastSentBattery: LocalBatteryStatus?
    /// Kept on disk, so the night's drops and retries are still in a report exported next morning.
    private let diagnostics = BridgeyDiagnostics(limit: 1_000, fileURL: BridgeyDiagnostics.defaultFileURL())
    private let notificationHistoryStore: NotificationHistoryStore

    init(deviceID: String, deviceName: String, settings: BridgeySettings) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.settings = settings
        let notificationHistoryStore = NotificationHistoryStore()
        self.notificationHistoryStore = notificationHistoryStore
        activity = ActivityLog(store: ActivityStore())
        remoteInput = RemoteInputHost.live()
        macActions = MacActionsHost.live()
        codeModel = CodeModelStore.live()
        if settings.notificationHistoryEnabled {
            notificationHistory = notificationHistoryStore.load()
        }
        // Identity and trust come from the private pairing file, never the Keychain (no prompts
        // after updates). The first launch after a Keychain build moves the old items once.
        let pairingStore = MacPairingStore.shared
        self.pairingStore = pairingStore
        identity = pairingStore.contents.flatMap { MacIdentity(rawKey: $0.identityKey) }
        pairingStoreIssue = pairingStore.issue
        let trustRegistry = MacTrustRegistry(store: pairingStore)
        self.trustRegistry = trustRegistry
        trustedDeviceIDs = trustRegistry.deviceIDs
        notificationPresenter.onDismiss = { [weak self] notificationID, deviceID in
            Task { @MainActor [weak self] in
                self?.dismissAndroidNotification(notificationID, deviceID: deviceID)
            }
        }
        notificationPresenter.onCopyCode = { [weak self] reference in
            Task { @MainActor [weak self] in self?.copyCode(reference: reference) }
        }
        notificationPresenter.onAction = { [weak self] notificationID, deviceID, actionToken, replyText in
            Task { @MainActor [weak self] in
                self?.performAndroidNotificationAction(
                    notificationID,
                    deviceID: deviceID,
                    actionToken: actionToken,
                    replyText: replyText
                )
            }
        }
        let remoteNotificationCategory = UNNotificationCategory(
            identifier: "bridgey.android.notification",
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        remoteNotificationCategories[remoteNotificationCategory.identifier] = remoteNotificationCategory
        remoteNotificationCategories[receivedNotificationCategory] = ReceivedNotifier.category
        notificationPresenter.onReceived = { action in
            Task { @MainActor in action.perform() }
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(remoteNotificationCategories.values))
        UNUserNotificationCenter.current().delegate = notificationPresenter
        refreshNotificationAuthorization()
        if identity != nil { startListener() }
        folders.loadJournals()
        folderReceiver.loadJournals()
        quickActions.available = { [weak self] in self?.isFeatureAvailable($0) == true }
        quickActions.send = { [weak self] in self?.sendQuickPayload(kind: $0, payload: $1) == true }
        quickActions.onActivity = { [weak self] kind in self?.recordConnectedActivity(kind) }
        quickActions.openRightAway = { [weak self] in self?.settings.openLinksRightAway == true }
        macActions.isAllowed = { [weak self] id in self?.isFeatureAvailable(.macActions, for: id) == true }
        macActions.send = { [weak self] id, kind, payload in
            guard let self, let current = self.registry.session(for: id) else { return false }
            return self.sendQuickPayload(kind: kind, payload: payload, to: current)
        }
        macActions.onCatalogChange = { [weak self] in self?.sendActionsCatalogs() }
        focusSync.broadcast = { [weak self] active in
            guard let self else { return }
            for (_, current) in self.registry.broadcastTargets({ _, link in link.remoteFocusSync }) {
                _ = self.sendQuickPayload(kind: "focus.state", payload: focusStatePayload(active), to: current)
            }
        }
        focusSync.onSettingsChange = { [weak self] in self?.sendFeatureState() }
        wireSettingsSync()
        camera.send = { [weak self] id, payload in
            guard let self, let current = self.registry.session(for: id) else { return false }
            return self.sendQuickPayload(kind: "camera.request", payload: payload, to: current)
        }
        remoteInput.isAllowed = { [weak self] id in self?.isFeatureAvailable(.remoteInput, for: id) == true }
        remoteInput.send = { [weak self] id, kind, payload in
            guard let self, let current = self.registry.session(for: id) else { return false }
            return self.sendQuickPayload(kind: kind, payload: payload, to: current)
        }
        mediaController.allowed = { [weak self] in
            guard let self, case .connected = self.state else { return false }
            return self.isFeatureAvailable(.media)
        }
        mediaController.onState = { [weak self] payload in
            // Every phone with Media on shows this Mac's player.
            guard let self else { return }
            for (_, current) in self.registry.broadcastTargets({ id, _ in self.isFeatureAvailable(.media, for: id) }) {
                _ = self.sendQuickPayload(kind: "media.state", payload: payload, to: current)
            }
        }
        shortcuts.perform = { [weak self] action in
            switch action {
            case .clipboard: self?.sendClipboard()
            case .call: self?.sendCallFromClipboard()
            case .link: self?.quickActions.sendClipboardLink()
            case .ping: self?.sendPing()
            }
        }
        shortcuts.register()
        autoClipboard.onDecision = { [weak self] decision in self?.handleAutomaticClipboard(decision) }
        autoClipboard.offersAvailable = { [weak self] in self?.clipboardOffersAvailable == true }
        configureClipboardOffers()
        clipboardFilesCancellable = Publishers.CombineLatest(settings.$clipboardFilesEnabled, settings.$clipboardEagerLimit)
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.sendFeatureState() }
            }
        accessibilityCancellable = remoteInput.$accessibilityTrusted.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendActionsCatalogs() } }
        autoClipboardCancellable = Publishers.CombineLatest(settings.$autoClipboardEnabled, settings.$autoClipboardDevices)
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshAutoClipboard() }
            }
        settingsCancellable = Publishers.CombineLatest3(
            settings.$globalFeatures,
            settings.$deviceFeatures,
            settings.$notificationHistoryEnabled
        )
            .dropFirst()
            .sink { [weak self] value in
                DispatchQueue.main.async {
                    guard let self else { return }
                    for id in self.registry.connectedIDs where !self.settings.isEnabled(.battery, for: id) {
                        self.registry.update(id) { $0.battery = nil }
                    }
                    self.publish()
                    if !self.featureEnabled(.ping) { self.clearPingStatus() }
                    if !self.isFeatureAvailable(.links) { self.quickActions.reset() }
                    self.mediaController.reset()
                    if !self.featureEnabled(.clipboard) { self.clearClipboardSendStatus() }
                    for id in self.registry.connectedIDs where !self.settings.isEnabled(.notifications, for: id) {
                        self.clearRemoteCall(for: id, reason: "notifications_off_mac")
                    }
                    if !self.featureEnabled(.calls) {
                        self.clearPendingCall()
                        self.clearCallStatus()
                    }
                    if value.2 {
                        self.notificationHistory = self.notificationHistoryStore.load()
                    } else {
                        self.clearNotificationHistory()
                    }
                    self.sendFeatureState()
                    self.sendActionsCatalogs()
                    self.mediaController.refresh()
                    self.publishLocalBattery(force: true)
                    self.refreshAutoClipboard()
                }
            }
        startReconnecting()
    }

    func refreshNotificationAuthorization() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getNotificationSettings { [weak self] settings in
            let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                self?.notificationsAuthorized = authorized
                self?.notificationPermissionDetermined = settings.authorizationStatus != .notDetermined
            }
        }
    }

    func enableNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            if settings.authorizationStatus != .notDetermined {
                DispatchQueue.main.async { self.openNotificationSettings() }
                return
            }
            Task { @MainActor in self.requestNotificationAuthorization() }
        }
    }

    private func requestNotificationAuthorization() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.notificationsAuthorized = granted
                self?.notificationPermissionDetermined = true
            }
            if let error {
                BridgeyLog.notifications.error("notifications authorization failed error=\(String(describing: error), privacy: .public)")
            } else {
                BridgeyLog.notifications.notice("notifications authorization granted=\(granted, privacy: .public)")
            }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func observe(_ discovery: BonjourDiscovery) {
        restartDiscovery = { [weak discovery] reason in discovery?.restart(reason: reason) }
        discoveryHealth = { [weak discovery] in discovery?.health ?? .stopped }
        discoveryCancellable = discovery.$peers.sink { [weak self] peers in
            self?.connectTrustedPeerIfNeeded(peers)
        }
    }

    /// Try again from the panel card: reads the pairing file or the old Keychain items again
    /// (macOS may ask once), then starts pairing as a normal launch would.
    func retryPairingStore() {
        pairingStore.load()
        pairingStoreIssue = pairingStore.issue
        guard identity == nil, let contents = pairingStore.contents,
              let loaded = MacIdentity(rawKey: contents.identityKey) else {
            publish()
            return
        }
        identity = loaded
        trustedDeviceIDs = trustRegistry.deviceIDs
        if listener == nil { startListener() }
        publish()
        connectTrustedPeerIfNeeded(lastPeers)
    }

    /// A pairing (or reconnect) the user started. Never disturbs other connected phones.
    func pair(host: String, port: Int, peerName: String) {
        // Without the stored identity a pairing would bind the phone to a key we cannot keep.
        guard identity != nil else { return }
        diagnostics.record(category: "pairing", event: "connection_started")
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            failPairing(.couldNotConnect, detail: "Invalid peer port")
            return
        }
        if let previous = pairingSession {
            pairingSession = nil
            previous.send(PairingMessage(kind: "pairing.cancel", sessionId: previous.id))
            previous.close()
        }
        pairingFlow = .connecting(peerName)
        publish()
        BridgeyLog.pairing.notice("pairing started peer=\(peerName, privacy: .private)")
        pairingSession = dial(host: host, port: endpointPort, peerName: peerName, deviceID: nil)
    }

    /// Opens a session to a phone. `deviceID` marks a reconnect to a trusted phone (no prompt).
    @discardableResult
    private func dial(host: String, port: NWEndpoint.Port, peerName: String, deviceID dialDeviceID: String?) -> Session {
        let parameters: NWParameters
        if dialDeviceID != nil {
            // A reconnect gives up quickly on an address that does not answer; the schedule retries.
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = Int(ReconnectPolicy.connectTimeout)
            parameters = NWParameters(tls: nil, tcp: tcp)
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let current = Session(connection: connection, peerName: peerName)
        current.initiatedLocally = true
        current.endpoint = (host, Int(port.rawValue), peerName)
        current.remoteHost = host
        current.dialDeviceID = dialDeviceID
        current.id = UUID().uuidString.lowercased()
        current.privateKey = P256.KeyAgreement.PrivateKey()
        current.localEphemeralKey = current.privateKey!.publicKey.x963Representation.base64EncodedString()
        registry.addPending(current, initiatedLocally: true)
        scheduleConnectionTimeout(for: current)
        configure(current) { [weak self, weak current] in
            guard let self, let current, current.privateKey != nil else { return }
            current.send(PairingMessage(
                kind: "pairing.offer",
                sessionId: current.id,
                deviceId: self.deviceID,
                deviceName: self.deviceName,
                publicKey: current.localEphemeralKey,
                targetDeviceId: current.dialDeviceID
            ))
        }
        return current
    }

    func confirm() {
        guard let current = pairingSession, current.pairingKey != nil, !current.localConfirmed else { return }
        confirm(current)
    }

    private func confirm(_ current: Session) {
        guard !current.localConfirmed, !current.ended else { return }
        guard let identity else {
            current.close()
            return
        }
        current.localConfirmed = true
        let identityKey = identity.publicKey
        current.send(PairingMessage(
            kind: "pairing.confirm",
            sessionId: current.id,
            deviceId: deviceID,
            identityKey: identityKey,
            proof: confirmationProof(
                key: current.pairingKey!,
                sessionID: current.id,
                deviceID: deviceID,
                identityKey: identityKey
            ),
            signature: identity.sign(authTranscript(current))
        ))
        completeIfConfirmed(current)
    }

    /// Cancels the pairing in progress (or clears its failure). Connected phones stay connected.
    func cancel() {
        if let current = pairingSession {
            pairingSession = nil
            current.send(PairingMessage(kind: "pairing.cancel", sessionId: current.id))
            current.close()
        }
        pairingFlow = .idle
        publish()
    }

    /// Disconnect (panel, Settings): clears a pairing failure, else disconnects the selected phone.
    func dismiss() {
        if case .failed = pairingFlow {
            cancel()
            return
        }
        guard let id = registry.target(selected: selectedDeviceID) else {
            cancel()
            return
        }
        disconnect(deviceID: id)
    }

    /// Disconnects one phone; the others stay connected. As before, the link comes back through
    /// the normal reconnect (the phone redials too); Forget is what stops it for good.
    func disconnect(deviceID id: String) {
        guard let current = registry.session(for: id) else { return }
        current.ended = true
        current.connectionTimeout?.cancel()
        current.heartbeat?.cancel()
        registry.remove(current)
        current.close()
        deviceDisconnected(id, reason: "user_disconnect")
    }

    /// The send target for single-phone actions (panel chip menu).
    func selectDevice(_ id: String?) {
        selectedDeviceID = id
        publish()
    }

    func forget(deviceID: String) {
        folders.forget(deviceID)
        folderReceiver.forget(deviceID)
        transferHistory.forget(deviceID: deviceID)
        clearClipboardCache()
        trustRegistry.remove(deviceID: deviceID)
        trustedDeviceIDs.remove(deviceID)
        settings.removeDevice(deviceID)
        batteryAlerts.forget(deviceID)
        focusSync.forget(deviceID)
        settingsSync.forget(deviceID)
        reconnect.forget(deviceID)
        disconnect(deviceID: deviceID)
        BridgeyLog.pairing.notice("pairing revoked peer=\(shortDeviceID(deviceID), privacy: .public)")
    }

    /// Recomputes the per-phone list and the selected phone's mirrors (state, features, battery).
    private func publish() {
        defer { phoneFilesController.phonesChanged() }
        publishHealth()
        let phones = registry.connections
        if connectedPhones != phones { connectedPhones = phones }
        let targetID = registry.target(selected: selectedDeviceID)
        let target = phones.first { $0.id == targetID }
        let newState: PairingState = target.map { .connected(deviceID: $0.id, peerName: $0.name) } ?? pairingFlow
        if state != newState { state = newState }
        let link = target?.state ?? PhoneLinkState()
        if remoteFeatures != link.remoteFeatures { remoteFeatures = link.remoteFeatures }
        if remoteBattery != link.battery { remoteBattery = link.battery }
        if androidRinging != link.ringing { androidRinging = link.ringing }
        remoteFeatureStateReceived = link.featureStateReceived
        remoteClipboardFiles = link.remoteClipboardFiles
        if targetID != publishedTarget {
            publishedTarget = targetID
            quickActions.reset()
            refreshAutoClipboard()
        }
    }

    /// One phone's session ended: only its calls, transfers and clipboard fetches go, and its
    /// reconnect starts.
    private func deviceDisconnected(_ id: String, reason: String) {
        cancelTransfers(for: id)
        remoteInput.disconnected(deviceID: id)
        macActions.disconnected(deviceID: id)
        camera.disconnected(id)
        updatesPhoneDisconnected(id)
        settingsSync.sessionEnded(id)
        var record = healthRecords[id] ?? DeviceHealthRecord()
        record.connectedSince = nil
        record.lastDropReason = healthToken(reason)
        record.lastDropAt = Date()
        record.roundTrips = HeartbeatRoundTrips()
        healthRecords[id] = record
        if clipboardInbox.current?.deviceID == id || clipboardOutbox.current?.deviceID == id {
            clipboardConnectionLost()
        }
        clearRemoteCall(for: id, reason: "disconnected")
        if macRingingFrom == id { stopMacSound() }
        if registry.connectedIDs.isEmpty {
            clearClipboardSendStatus()
            clearCallStatus()
            clearPingStatus()
            mediaController.reset()
            lastSentBattery = nil
        }
        publish()
        BridgeyLog.transport.notice("disconnected peer=\(shortDeviceID(id), privacy: .public) reason=\(reason, privacy: .public)")
        diagnostics.record(category: "transport", event: "disconnected", outcome: reason, device: id)
        guard trustedDeviceIDs.contains(id) else { return }
        reconnect.disconnected(id)
        discoveryWindowStart = clock.now
        armDiscoveryRestartTimer()
    }

    /// Shows `reason` for the user's pairing; never touches connected phones.
    private func failPairing(_ reason: PairingFailure, detail: String? = nil) {
        pairingSession = nil
        pairingFlow = .failed(detail.map { "\($0). \(reason.message)" } ?? reason.message)
        diagnostics.record(category: "pairing", event: "failed", outcome: reason.rawValue)
        publish()
    }

    func updateDeviceName(_ value: String) {
        deviceName = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    }

    func sendCallFromClipboard() {
        guard !ClipboardOwnWrite.isLazy(NSPasteboard.general.changeCount),
              let value = NSPasteboard.general.string(forType: .string) else {
            setTransientCallStatus("Copy a phone number first")
            return
        }
        sendCall(value)
    }

    func sendCallWhenConnected(_ value: String) {
        guard let number = normalizedPhoneNumber(value) else {
            setTransientCallStatus("Phone link does not contain a valid number")
            return
        }
        pendingCallNumber = number
        pendingCallExpiryWorkItem?.cancel()
        if flushPendingCallIfPossible() { return }
        callStatusClearWorkItem?.cancel()
        callStatusClearWorkItem = nil
        callStatus = "Waiting for Android connection…"
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.pendingCallNumber == number else { return }
            self.pendingCallNumber = nil
            self.pendingCallExpiryWorkItem = nil
            self.setTransientCallStatus("Android did not connect in time")
        }
        pendingCallExpiryWorkItem = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiry)
    }

    func sendCall(_ value: String) {
        callStatusClearWorkItem?.cancel()
        callStatusClearWorkItem = nil
        guard isFeatureAvailable(.calls) else {
            setTransientCallStatus("Calls are turned off or require Bridgey alpha.5 on both devices")
            return
        }
        guard let number = normalizedPhoneNumber(value) else {
            setTransientCallStatus("Clipboard does not contain a valid phone number")
            return
        }
        guard let current = session, case .connected = state,
              let plaintext = try? JSONEncoder().encode(CallRequestPayload(number: number)),
              let encrypted = try? encrypt(plaintext, key: current.pairingKey!) else {
            setTransientCallStatus("Android is not connected")
            return
        }
        let messageID = UUID().uuidString.lowercased()
        callRequestID = messageID
        callStatus = "Sending call request…"
        current.send(PairingMessage(
            kind: "calls.request",
            sessionId: current.id,
            messageId: messageID,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        ))
        callTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.callRequestID == messageID else { return }
            self?.callRequestID = nil
            self?.setTransientCallStatus("Android did not confirm the call request")
        }
        callTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func clearCallStatus() {
        callTimeoutWorkItem?.cancel()
        callTimeoutWorkItem = nil
        callStatusClearWorkItem?.cancel()
        callStatusClearWorkItem = nil
        callRequestID = nil
        callStatus = nil
    }

    @discardableResult
    private func flushPendingCallIfPossible() -> Bool {
        let isConnected: Bool
        if case .connected = state { isConnected = true } else { isConnected = false }
        guard let number = pendingCallNumber,
              pendingPhoneCallCanDispatch(
                isConnected: isConnected,
                featureStateReceived: remoteFeatureStateReceived
              ) else { return false }
        pendingCallNumber = nil
        pendingCallExpiryWorkItem?.cancel()
        pendingCallExpiryWorkItem = nil
        sendCall(number)
        return true
    }

    private func clearPendingCall() {
        pendingCallNumber = nil
        pendingCallExpiryWorkItem?.cancel()
        pendingCallExpiryWorkItem = nil
    }

    private func setTransientCallStatus(_ status: String) {
        callStatusClearWorkItem?.cancel()
        callStatus = status
        let work = DispatchWorkItem { [weak self] in
            self?.callStatus = nil
            self?.callStatusClearWorkItem = nil
        }
        callStatusClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func featureEnabled(_ feature: BridgeyFeature, current: Session? = nil) -> Bool {
        let id = (current ?? session)?.remoteDeviceID
        return settings.isEnabled(feature, for: id?.isEmpty == false ? id : nil)
    }

    func isFeatureAvailable(_ feature: BridgeyFeature) -> Bool {
        effectiveFeatureAvailable(
            localEnabled: featureEnabled(feature),
            remoteEnabled: remoteFeatures[feature] != false
        )
    }

    /// `feature` is on here for the phone and on the phone itself.
    func isFeatureAvailable(_ feature: BridgeyFeature, for id: String) -> Bool {
        guard let link = registry.state(for: id) else { return false }
        return effectiveFeatureAvailable(
            localEnabled: settings.isEnabled(feature, for: id),
            remoteEnabled: link.remoteFeatures[feature] != false
        )
    }

    func sendClipboard() {
        guard let current = session, case .connected = state else { return }
        guard isFeatureAvailable(.clipboard) else {
            clipboardStatus = "Clipboard is turned off on one of your devices"
            return
        }
        let pasteboard = NSPasteboard.general
        if ClipboardOwnWrite.matches(pasteboard.changeCount) {
            // It came from the phone; reading it would fetch it back.
            clipboardStatus = "This clip came from \(current.peerName)"
            return
        }
        if clipboardOffersAvailable {
            let snapshot = ClipboardContentReader.snapshot(of: pasteboard, changeCount: pasteboard.changeCount, offersAvailable: true)
            let decision = AutoClipboardFilter.content(of: snapshot)
            switch decision {
            case .offerText, .offerImages, .offerFiles:
                autoClipboard.noteSent(decision)
                sendClipboardOffer(decision, sensitive: pasteboardIsConcealed(pasteboard), automatic: false, in: current)
                return
            case .skip(.folder):
                clipboardStatus = "Folders aren\u{2019}t sent yet"
                return
            default:
                break
            }
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            clipboardStatus = "Clipboard is empty or unavailable"
            return
        }
        guard clipboardTextFits(text) else {
            clipboardStatus = "Clipboard exceeds 32 KiB. Send large text or diagnostics as a file."
            return
        }
        let html = NSPasteboard.general.data(forType: .html)
            .flatMap { String(data: $0, encoding: .utf8) }
        sendClipboardContent(text: text, html: html, concealed: pasteboardIsConcealed(NSPasteboard.general), automatic: false, in: current)
    }

    /// Automatic clipboard: a settled pasteboard change that passed AutoClipboardFilter.
    /// Text goes to every connected phone with Clipboard and Automatic clipboard on.
    private func sendAutomaticClipboard(text: String, html: String?) {
        let targets = registry.broadcastTargets { id, _ in
            self.isFeatureAvailable(.clipboard, for: id) && self.settings.isAutoClipboardEnabled(for: id)
        }
        for (_, current) in targets {
            sendClipboardContent(text: text, html: html, concealed: false, automatic: true, in: current)
        }
    }

    /// A settled pasteboard change that passed AutoClipboardFilter.
    private func handleAutomaticClipboard(_ decision: AutoClipboardDecision) {
        switch decision {
        case let .send(text, html):
            sendAutomaticClipboard(text: text, html: html)
        case .offerText, .offerImages, .offerFiles:
            guard let current = session, case .connected = state, clipboardOffersAvailable,
                  settings.isAutoClipboardEnabled(for: current.remoteDeviceID) else { return }
            sendClipboardOffer(decision, sensitive: false, automatic: true, in: current)
        case .skip(.tooLarge):
            clipboardStatus = "Clipboard is over 32 KiB, so it was not sent automatically"
        case .skip(.folder):
            clipboardStatus = "Folders aren\u{2019}t sent yet"
        case .skip:
            break
        }
    }

    /// Clipboard offers (docs/protocol.md) with the connected phone: Clipboard on for both, and
    /// Copy images and files on here and advertised by the phone.
    var clipboardOffersAvailable: Bool {
        guard case .connected = state, session != nil else { return false }
        return isFeatureAvailable(.clipboard) && settings.clipboardFilesEnabled && remoteClipboardFiles
    }

    /// Clipboard offers are allowed here for the session's device (what features.update says).
    private func clipboardOffersEnabledLocally(_ current: Session? = nil) -> Bool {
        featureEnabled(.clipboard, current: current) && settings.clipboardFilesEnabled
    }

    private func configureClipboardOffers() {
        clipboardCache.removePartials()
        clipboardCache.enforceLimits()
        clipboardInbox.progress = ClipboardPasteProgressPanel()
        clipboardInbox.protectedOfferIDs = { [weak self] in
            self?.clipboardOutbox.current.map { [$0.offer.offerId] } ?? []
        }
        // Fetches go to the phone the clip came from, whichever phone is selected.
        clipboardInbox.transport = ClipboardInboxTransport(
            isConnected: { [weak self] in self?.inboxSession != nil },
            sendFetch: { [weak self] fetch in
                guard let self, let data = try? JSONEncoder().encode(fetch) else { return false }
                return self.sendEncryptedClipboardMessage(kind: "clipboard.fetch", payload: data, transferID: fetch.transferId, to: self.inboxSession)
            },
            sendAccept: { [weak self] in self?.sendTransferControl(kind: "files.accept", transferID: $0, to: self?.inboxSession) },
            sendCompleteAck: { [weak self] in self?.sendTransferControl(kind: "files.complete.ack", transferID: $0, to: self?.inboxSession) },
            sendCancel: { [weak self] in self?.sendTransferControl(kind: "files.cancel", transferID: $0, to: self?.inboxSession) }
        )
        clipboardInbox.onPasteboardWritten = { [weak self] changeCount, received in
            self?.autoClipboard.noteOwnWrite(changeCount: changeCount)
            ClipboardOwnWrite.record(changeCount: changeCount, offer: received.offer, peerName: received.peerName)
        }
        clipboardInbox.onPasted = { [weak self] summary, received in
            self?.diagnostics.record(category: "clipboard", event: "paste_fetched")
            self?.recordClipActivity(.clipPasted, summary: summary, deviceID: received.deviceID, deviceName: received.peerName)
        }
        clipboardInbox.onPasteFailed = { [weak self] failure, received in
            self?.diagnostics.record(category: "clipboard", event: "paste_failed")
            self?.recordClipActivity(.clipPasteFailed, summary: ClipboardOfferSummary(received.offer),
                                     deviceID: received.deviceID, deviceName: received.peerName)
            self?.postPasteFailure(failure, peerName: received.peerName)
        }
        clipboardOutbox.available = { [weak self] in self?.clipboardOffersEnabledLocally() == true }
        // The outbox serves the phone its offer went to.
        clipboardOutbox.transport = ClipboardOutboxTransport(
            isConnected: { [weak self] in self?.outboxSession != nil },
            sendEncrypted: { [weak self] kind, payload, transferID in
                guard let self else { return false }
                return self.sendEncryptedClipboardMessage(kind: kind, payload: payload, transferID: transferID, to: self.outboxSession)
            },
            sendCancel: { [weak self] in self?.sendTransferControl(kind: "files.cancel", transferID: $0, to: self?.outboxSession) },
            chunkSender: { [weak self] in
                guard let self, let current = self.outboxSession, let key = current.pairingKey else { return nil }
                return ClipboardChunkSender { chunk, sequence, transferID in
                    guard let sealed = try? encrypt(chunk, key: key) else { return false }
                    return current.sendAndWait(PairingMessage(
                        kind: "files.chunk",
                        sessionId: current.id,
                        messageId: UUID().uuidString.lowercased(),
                        nonce: sealed.nonce,
                        ciphertext: sealed.ciphertext,
                        transferId: transferID,
                        sequence: sequence
                    ))
                }
            }
        )
    }

    /// The session of the phone whose clip the inbox holds.
    private var inboxSession: Session? {
        clipboardInbox.current.flatMap { registry.session(for: $0.deviceID) }
    }

    /// The session of the phone the outbox's offer went to.
    private var outboxSession: Session? {
        clipboardOutbox.current.flatMap { registry.session(for: $0.deviceID) }
    }

    /// Encrypts a clipboard-offer payload for `target` (a live phone session) and sends it.
    @discardableResult
    private func sendEncryptedClipboardMessage(kind: String, payload: Data, transferID: String?, messageID: String? = nil, to target: Session?) -> Bool {
        guard let current = target, registry.isActive(current), let key = current.pairingKey,
              let encrypted = try? encrypt(payload, key: key) else { return false }
        current.send(PairingMessage(
            kind: kind,
            sessionId: current.id,
            messageId: messageID ?? UUID().uuidString.lowercased(),
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            transferId: transferID
        ))
        return true
    }

    private func sendTransferControl(kind: String, transferID: String, to target: Session?) {
        guard let current = target, registry.isActive(current) else { return }
        current.send(PairingMessage(kind: kind, sessionId: current.id, transferId: transferID))
    }

    /// Builds and sends a clipboard offer; the stream records it once the phone acknowledges.
    private func sendClipboardOffer(_ decision: AutoClipboardDecision, sensitive: Bool, automatic: Bool, in current: Session) {
        let built: (ClipboardOffer, [ClipboardOutgoingSource])?
        switch decision {
        case let .offerText(text, html): built = ClipboardOfferBuilder.text(text, html: html, sensitive: sensitive)
        case let .offerImages(images): built = ClipboardOfferBuilder.images(images, cache: clipboardCache)
        case let .offerFiles(files, skippedFolders):
            built = ClipboardOfferBuilder.files(files)
            if skippedFolders { clipboardStatus = "Folders aren\u{2019}t sent yet" }
        default: built = nil
        }
        guard let (draft, allSources) = built, let (offer, plaintext) = draft.encodedForSending() else {
            clipboardStatus = "Could not prepare the clipboard"
            return
        }
        let sources = Array(allSources.prefix(offer.items.count))
        clipboardInbox.supersede()
        clipboardOutbox.begin(offer: offer, sources: sources, changeCount: NSPasteboard.general.changeCount, deviceID: current.remoteDeviceID)
        clearClipboardSendStatus()
        let messageID = UUID().uuidString.lowercased()
        guard sendEncryptedClipboardMessage(kind: "clipboard.offer", payload: plaintext, transferID: nil, messageID: messageID, to: current) else {
            clipboardStatus = "Encryption failed"
            return
        }
        pendingOfferAck?.timeout.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pendingOfferAck?.messageID == messageID else { return }
            self.pendingOfferAck = nil
            self.clipboardStatus = "No delivery acknowledgement"
            self.sendFeatureState()
        }
        pendingOfferAck = (messageID, ClipboardOfferSummary(offer), automatic, timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        clipboardStatus = automatic ? nil : "Sending\u{2026}"
        diagnostics.record(category: "clipboard", event: "offer_sent")
        BridgeyLog.line(BridgeyLog.clipboard, LogLines.clipboard(BridgeyLog.policy, event: "offer sent automatic=\(automatic)"))
    }

    private func receiveClipboardOffer(_ message: PairingMessage, in current: Session) {
        guard clipboardOffersEnabledLocally(current) else {
            current.send(PairingMessage(kind: "clipboard.rejected", sessionId: current.id, messageId: message.messageId))
            sendFeatureState()
            return
        }
        guard registry.isActive(current), message.sessionId == current.id,
              let messageID = message.messageId, current.acceptMessageID(messageID),
              let nonce = message.nonce, let ciphertext = message.ciphertext, let key = current.pairingKey,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key),
              let offer = ClipboardOffer.decode(plaintext),
              offer.offerId != clipboardInbox.current?.offer.offerId else { return }
        clipboardOutbox.supersede()
        clearClipboardSendStatus()
        clipboardInbox.accept(offer, deviceID: current.remoteDeviceID, peerName: current.peerName)
        recordClipActivity(.clipOfferReceived, summary: ClipboardOfferSummary(offer), deviceID: current.remoteDeviceID, deviceName: current.peerName)
        diagnostics.record(category: "clipboard", event: "offer_received")
        current.send(PairingMessage(kind: "clipboard.ack", sessionId: current.id, messageId: messageID))
        BridgeyLog.line(BridgeyLog.clipboard, LogLines.clipboard(BridgeyLog.policy, event: "offer received"))
    }

    private func receiveClipboardFetch(_ message: PairingMessage, in current: Session) {
        guard registry.isActive(current), message.sessionId == current.id,
              let messageID = message.messageId, current.acceptMessageID(messageID),
              let nonce = message.nonce, let ciphertext = message.ciphertext, let key = current.pairingKey,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key),
              let fetch = (try? JSONDecoder().decode(ClipboardFetchPayload.self, from: plaintext))?.validated(),
              message.transferId == nil || message.transferId == fetch.transferId else { return }
        guard clipboardOutbox.current?.deviceID == current.remoteDeviceID else {
            if let data = try? JSONEncoder().encode(ClipboardErrorPayload(offerId: fetch.offerId, index: fetch.index, transferId: fetch.transferId, code: .expired)) {
                sendEncryptedClipboardMessage(kind: "clipboard.error", payload: data, transferID: fetch.transferId, to: current)
            }
            return
        }
        diagnostics.record(category: "clipboard", event: "fetch_received")
        clipboardOutbox.handleFetch(fetch)
    }

    private func receiveClipboardError(_ message: PairingMessage, in current: Session) {
        guard registry.isActive(current), message.sessionId == current.id,
              let messageID = message.messageId, current.acceptMessageID(messageID),
              let nonce = message.nonce, let ciphertext = message.ciphertext, let key = current.pairingKey,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key),
              let payload = try? JSONDecoder().decode(ClipboardErrorPayload.self, from: plaintext),
              payload.version == 1 else { return }
        clipboardInbox.handleError(payload)
    }

    /// A `files.offer` that belongs to the clipboard: the answer to a fetch, or an eager push.
    /// Returns false for an ordinary file offer, which then goes through the Files path. The
    /// message ID is only consumed for clipboard offers, so the Files path still accepts it.
    private func receiveClipboardTransferOffer(_ message: PairingMessage, in current: Session) -> Bool {
        guard registry.isActive(current), message.sessionId == current.id,
              let nonce = message.nonce, let ciphertext = message.ciphertext, let key = current.pairingKey,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { return false }
        let owned = clipboardInbox.owns(message.transferId)
        guard owned || (try? JSONDecoder().decode(FileOfferPurposeProbe.self, from: plaintext))?.purpose == "clipboard" else { return false }
        guard let messageID = message.messageId, current.acceptMessageID(messageID) else { return true }
        guard let offer = try? JSONDecoder().decode(ClipboardTransferOffer.self, from: plaintext), offer.purpose == "clipboard" else {
            if let transferID = message.transferId { sendTransferControl(kind: "files.cancel", transferID: transferID, to: current) }
            return true
        }
        guard clipboardOffersEnabledLocally(current) else {
            sendTransferControl(kind: "files.cancel", transferID: offer.transferId, to: current)
            return true
        }
        clipboardInbox.handleTransferOffer(offer, outerTransferID: message.transferId)
        return true
    }

    private func recordClipActivity(_ kind: ActivityKind, summary: ClipboardOfferSummary, deviceID: String, deviceName: String, automatic: Bool = false) {
        recordActivity(kind, deviceID: deviceID, deviceName: deviceName, fileName: summary.fileName,
                       automatic: automatic, count: summary.count, bytes: summary.bytes, content: summary.content)
    }

    private func postPasteFailure(_ failure: ClipboardPasteFailure, peerName: String) {
        let content = UNMutableNotificationContent()
        content.title = failure == .notConnected
            ? String(format: L10n.text("paste.failed.offline", fallback: "Couldn\u{2019}t paste: %@ is not connected"), peerName)
            : String(format: L10n.text("paste.failed", fallback: "Couldn\u{2019}t paste from %@"), peerName)
        content.body = L10n.text("stream.clip.failed.detail", fallback: "Copy it again and paste")
        let request = UNNotificationRequest(identifier: "bridgey.clipboard.paste-failed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The session is gone: clipboard transfers stop; the offers stay for the next connection.
    private func clipboardConnectionLost() {
        pendingOfferAck?.timeout.cancel()
        pendingOfferAck = nil
        clipboardInbox.connectionLost()
        clipboardOutbox.connectionLost()
    }

    /// Clear activity and Forget device delete the clipboard cache.
    private func clearClipboardCache() {
        clipboardInbox.clearAll()
        clipboardOutbox.clearAll()
        clipboardCache.clear()
    }

    /// Sends through the existing clipboard.update / clipboard.rich messages and acknowledgement.
    private func sendClipboardContent(text: String, html: String?, concealed: Bool, automatic: Bool, in current: Session) {
        // Any clipboard text supersedes the clipboard offers in both directions.
        clipboardOutbox.supersede()
        clipboardInbox.supersede()
        let richContent = RichClipboardContent(text: text, html: html)
        let plaintext = richContent.flatMap { try? JSONEncoder().encode($0) } ?? Data(text.utf8)
        guard let encrypted = try? encrypt(plaintext, key: current.pairingKey!) else {
            clipboardStatus = "Encryption failed"
            return
        }
        let messageID = UUID().uuidString.lowercased()
        current.send(PairingMessage(
            kind: richContent == nil ? "clipboard.update" : "clipboard.rich",
            sessionId: current.id,
            messageId: messageID,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        ))
        autoClipboard.noteSent(text: text)
        clipboardTimeoutWorkItem?.cancel()
        clipboardSendID = messageID
        pendingClipboardActivity = (concealed ? nil : ActivityHistory.preview(text), concealed, automatic)
        // Automatic sends stay quiet; only problems show in the send bar.
        clipboardStatus = automatic ? nil : "Sending…"
        let timeout = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, self.registry.isActive(current),
                  self.clipboardSendID == messageID else { return }
            self.clipboardSendID = nil
            self.clipboardTimeoutWorkItem = nil
            self.clipboardStatus = "No delivery acknowledgement"
            self.sendFeatureState()
        }
        clipboardTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        BridgeyLog.line(BridgeyLog.clipboard, LogLines.clipboard(BridgeyLog.policy, event: "sent automatic=\(automatic)"))
    }

    /// Runs the pasteboard watcher only while connected, with Clipboard available on both sides
    /// and Automatic clipboard on for this device.
    private func refreshAutoClipboard() {
        // Any connected phone with Automatic clipboard on keeps the watcher running.
        let active = registry.connectedIDs.contains {
            isFeatureAvailable(.clipboard, for: $0) && settings.isAutoClipboardEnabled(for: $0)
        }
        autoClipboard.setActive(active)
    }

    private func clearClipboardSendStatus() {
        clipboardTimeoutWorkItem?.cancel()
        clipboardTimeoutWorkItem = nil
        clipboardSendID = nil
        pendingClipboardActivity = nil
        clipboardStatus = nil
    }

    func sendPing() {
        guard let current = session, case .connected = state else {
            setTransientPingStatus("Android is not connected")
            return
        }
        guard isFeatureAvailable(.ping) else {
            setTransientPingStatus("Ping requires Bridgey 0.6 on both devices")
            return
        }
        guard let plaintext = try? JSONEncoder().encode(PingPayload(version: 1)),
              let encrypted = try? encrypt(plaintext, key: current.pairingKey!) else {
            setTransientPingStatus("Ping could not be encrypted")
            return
        }
        let messageID = UUID().uuidString.lowercased()
        pingRequestID = messageID
        pingStatusClearWorkItem?.cancel()
        pingStatus = "Pinging Android…"
        current.send(PairingMessage(
            kind: "ping.request",
            sessionId: current.id,
            messageId: messageID,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        ))
        let timeout = DispatchWorkItem { [weak self] in
            guard self?.pingRequestID == messageID else { return }
            self?.pingRequestID = nil
            self?.setTransientPingStatus("Android did not acknowledge the ping")
        }
        pingStatusClearWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func receivePing(_ message: PairingMessage, in current: Session) throws {
        guard featureEnabled(.ping, current: current) else {
            sendFeatureState()
            return
        }
        guard registry.isActive(current),
              message.sessionId == current.id,
              let messageID = message.messageId,
              current.acceptMessageID(messageID),
              let nonce = message.nonce,
              let ciphertext = message.ciphertext,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
              let payload = try? JSONDecoder().decode(PingPayload.self, from: plaintext),
              payload.version == 1 else { throw PairingError.invalidMessage }
        NSSound(named: NSSound.Name("Glass"))?.play()
        setTransientPingStatus("Ping from \(current.peerName)")
        recordActivity(.pingReceived, in: current)
        current.send(PairingMessage(kind: "ping.ack", sessionId: current.id, messageId: messageID))
        BridgeyLog.plugin.info("ping received")
    }

    private func setTransientPingStatus(_ value: String) {
        pingStatusClearWorkItem?.cancel()
        pingStatus = value
        let work = DispatchWorkItem { [weak self] in
            self?.pingStatus = nil
            self?.pingStatusClearWorkItem = nil
        }
        pingStatusClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func clearPingStatus() {
        pingRequestID = nil
        pingStatusClearWorkItem?.cancel()
        pingStatusClearWorkItem = nil
        pingStatus = nil
    }

    /// Quick actions go to the selected phone, or to `target` (a reply to the phone that asked).
    private func sendQuickPayload(kind: String, payload: [String: Any], to target: Session? = nil) -> Bool {
        guard let current = target ?? quickReplyTarget ?? session, registry.isActive(current), let key = current.pairingKey,
              let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 32768,
              let encrypted = try? encrypt(data, key: key) else { return false }
        current.send(PairingMessage(kind: kind, sessionId: current.id,
            messageId: UUID().uuidString.lowercased(), nonce: encrypted.nonce, ciphertext: encrypted.ciphertext))
        return true
    }

    /// Remote input: decrypted here, checked and sequenced by the host. These high-rate messages
    /// skip the shared message-ID window (see docs/protocol.md) and never close the session.
    private func receiveRemoteInput(_ message: PairingMessage, in current: Session) {
        guard registry.isActive(current), message.sessionId == current.id, let key = current.pairingKey,
              let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { return }
        remoteInput.receive(kind: message.kind, payload: data, deviceID: current.remoteDeviceID, deviceName: current.peerName)
    }

    private func receiveQuickPayload(_ message: PairingMessage, current: Session) {
        guard registry.isActive(current), message.sessionId == current.id,
              let key = current.pairingKey, let id = message.messageId, current.acceptMessageID(id),
              let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key), data.count <= 8192,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              payload["version"] as? Int == 1 else { return }
        if message.kind == "quick.request" {
            guard let feature = payload["feature"] as? String, let sequence = payload["sequence"] as? Int,
                  current.quickSequence.accept(feature: feature, sequence: sequence) else { return }
        }
        if message.kind == "quick.request", payload["feature"] as? String == "media" {
            guard let requestID = payload["requestId"] as? String, UUID(uuidString: requestID) != nil else { return }
            let reply: (Bool) -> Void = { [weak self, weak current] accepted in
                guard let self, let current, self.registry.isActive(current) else { return }
                _ = self.sendQuickPayload(kind: "quick.result", payload: [
                    "version": 1, "requestId": requestID, "feature": "media", "accepted": accepted
                ], to: current)
            }
            guard isFeatureAvailable(.media, for: current.remoteDeviceID), let action = payload["action"] as? String,
                  let value = payload["value"] as? String else { reply(false); return }
            mediaController.command(action: action, value: value, completion: reply)
        } else {
            // A link from any phone shows; QuickActions answers it through sendQuickPayload,
            // which goes back to the phone that asked.
            quickReplyTarget = current
            quickActions.receive(message.kind, payload: payload, from: current.remoteDeviceID)
            quickReplyTarget = nil
        }
    }

    /// The Mac's battery goes to every connected phone with Battery on.
    private func publishLocalBattery(force: Bool = false) {
        let targets = registry.broadcastTargets { id, _ in self.isFeatureAvailable(.battery, for: id) }
        guard !targets.isEmpty,
              let status = currentMacBatteryStatus(),
              force || status != lastSentBattery,
              let plaintext = try? JSONEncoder().encode(BatteryPayload(
                level: status.level,
                isCharging: status.isCharging
              )) else { return }
        lastSentBattery = status
        for (_, current) in targets {
            guard let key = current.pairingKey, let encrypted = try? encrypt(plaintext, key: key) else { continue }
            current.send(PairingMessage(
                kind: "battery.update",
                sessionId: current.id,
                messageId: UUID().uuidString.lowercased(),
                nonce: encrypted.nonce,
                ciphertext: encrypted.ciphertext
            ))
        }
        BridgeyLog.plugin.debug("battery sent level=\(status.level, privacy: .public) charging=\(status.isCharging, privacy: .public)")
    }

    func findAndroid() {
        _ = sendFindCommand(kind: "find.start")
    }

    /// Stops this Mac ringing and every phone that rings.
    func stopFinding() {
        stopMacSound()
        for (_, current) in registry.broadcastTargets({ _, _ in true }) {
            _ = sendFindCommand(kind: "find.stop", to: current)
        }
    }

    private func sendFindCommand(kind: String, to target: Session? = nil) -> Bool {
        guard let current = target ?? session, registry.isActive(current),
              (kind != "find.start" || isFeatureAvailable(.findDevice, for: current.remoteDeviceID)),
              let payload = try? JSONEncoder().encode(FindDevicePayload(alertId: "active")),
              let encrypted = try? encrypt(payload, key: current.pairingKey!) else { return false }
        current.send(PairingMessage(
            kind: kind,
            sessionId: current.id,
            messageId: UUID().uuidString.lowercased(),
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        ))
        return true
    }

    private func receiveFindCommand(_ message: PairingMessage, in current: Session, start: Bool) throws {
        if start && !featureEnabled(.findDevice, current: current) { return }
        guard registry.isActive(current),
              message.sessionId == current.id,
              let messageID = message.messageId,
              current.acceptMessageID(messageID),
              let nonce = message.nonce,
              let ciphertext = message.ciphertext,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
              let payload = try? JSONDecoder().decode(FindDevicePayload.self, from: plaintext),
              payload.alertId == "active" else { throw PairingError.invalidMessage }
        if start {
            if !macRinging && featureEnabled(.findDevice, current: current) { recordActivity(.findMac, in: current) }
            startMacSound()
            if macRinging { macRingingFrom = current.remoteDeviceID }
            _ = sendFindCommand(kind: macRinging ? "find.started" : "find.stopped", to: current)
        } else {
            stopMacSound()
            registry.update(current.remoteDeviceID) { $0.ringing = false }
            publish()
            _ = sendFindCommand(kind: "find.stopped", to: current)
        }
        BridgeyLog.plugin.notice("find-device \(start ? "started" : "stopped", privacy: .public)")
    }

    private func receiveFindAcknowledgement(
        _ message: PairingMessage,
        in current: Session,
        started: Bool
    ) throws {
        guard registry.isActive(current),
              message.sessionId == current.id,
              let messageID = message.messageId,
              current.acceptMessageID(messageID),
              let nonce = message.nonce,
              let ciphertext = message.ciphertext,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
              let payload = try? JSONDecoder().decode(FindDevicePayload.self, from: plaintext),
              payload.alertId == "active" else { throw PairingError.invalidMessage }
        let wasRinging = registry.state(for: current.remoteDeviceID)?.ringing == true
        if started && !wasRinging { recordActivity(.findPhone, in: current) }
        registry.update(current.remoteDeviceID) { $0.ringing = started }
        publish()
    }

    private func startMacSound() {
        guard !macRinging else { return }
        guard let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Funk.aiff", byReference: true) else { return }
        sound.loops = true
        findDeviceSound = sound
        macRinging = true
        sound.play()
    }

    private func stopMacSound() {
        macRingingFrom = nil
        findDeviceSound?.stop()
        findDeviceSound = nil
        macRinging = false
    }

    func chooseAndSendFile() {
        guard session != nil, case .connected = state else {
            fileTransferStatus = "Not connected, so the file was not sent"
            return
        }
        guard isFeatureAvailable(.files) else {
            fileTransferStatus = "File transfer is turned off on one of your devices"
            return
        }
        // MenuBarExtra closes its transient window after invoking the action.
        // Present the picker on the next run-loop turn as an app-modal panel so
        // an LSUIElement app can reliably bring it in front of other windows.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = L10n.text("files.panel.title", fallback: "Send Files or Folders")
            panel.prompt = L10n.text("folders.sheet.send", fallback: "Send")
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.treatsFilePackagesAsDirectories = false
            panel.allowsMultipleSelection = true
            panel.level = .floating
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            guard self.session != nil, case .connected = self.state, self.isFeatureAvailable(.files) else { return }
            self.sendItems(panel.urls)
        }
    }

    /// Files go to the queue one by one; each folder becomes one queue item (packages are folders too).
    @discardableResult
    private func sendItems(_ urls: [URL]) -> Bool {
        guard let targetID = session?.remoteDeviceID, case .connected = state else { return false }
        return sendItems(urls, to: targetID)
    }

    @discardableResult
    private func sendItems(_ urls: [URL], to targetID: String) -> Bool {
        var files: [URL] = []
        var directories: [URL] = []
        for url in urls where url.isFileURL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                directories.append(url)
            } else if values?.isRegularFile == true {
                files.append(url)
            } else if values?.isSymbolicLink == true, (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // A link the user dropped on purpose: send the folder it points to. Links inside are skipped.
                directories.append(url.resolvingSymlinksInPath())
            } else if values?.isSymbolicLink == true {
                files.append(url.resolvingSymlinksInPath())
            }
        }
        guard !files.isEmpty || !directories.isEmpty else { return false }
        if !files.isEmpty { queueFiles(files, to: targetID) }
        // A phone without folder support gets the files only; the status says why the folders stayed here.
        let foldersAccepted = !directories.isEmpty && folders.send(directories, to: targetID)
        if foldersAccepted { beginFileTransferUI() }
        return !files.isEmpty || foldersAccepted
    }

    @discardableResult
    func sendDroppedFiles(_ urls: [URL]) -> Bool {
        guard session != nil, case .connected = state else {
            fileTransferStatus = "Not connected, so the file was not sent"
            return false
        }
        guard isFeatureAvailable(.files) else {
            fileTransferStatus = "File transfer is turned off on one of your devices"
            return false
        }
        return sendItems(urls)
    }

    /// Sends files and folders to one phone (drop tiles, Tray, send sheet). Nil: the selected phone.
    @discardableResult
    func sendDroppedFiles(_ urls: [URL], to deviceID: String?) -> Bool {
        guard let id = deviceID else { return sendDroppedFiles(urls) }
        guard registry.session(for: id) != nil else {
            fileTransferStatus = "Not connected, so the file was not sent"
            return false
        }
        guard isFeatureAvailable(.files, for: id) else {
            fileTransferStatus = "File transfer is turned off on one of your devices"
            return false
        }
        return sendItems(urls, to: id)
    }

    /// Sends text as a clipboard update to one phone (Tray text and links). Nil: the selected phone.
    @discardableResult
    func sendText(_ text: String, to deviceID: String?) -> Bool {
        let target = deviceID.flatMap { registry.session(for: $0) } ?? session
        guard let current = target, registry.isActive(current), !text.isEmpty else { return false }
        guard isFeatureAvailable(.clipboard, for: current.remoteDeviceID) else {
            clipboardStatus = "Clipboard is turned off on one of your devices"
            return false
        }
        guard clipboardTextFits(text) else {
            clipboardStatus = "Clipboard exceeds 32 KiB. Send large text or diagnostics as a file."
            return false
        }
        sendClipboardContent(text: text, html: nil, concealed: false, automatic: false, in: current)
        return true
    }

    /// Asks the phone for its free space (places.list), at most once per 20 s per phone. Send surfaces call it
    /// when they open; the answer lands in `phoneFreeSpace`. A call inside the window asks once at its end.
    func refreshPhoneFreeSpace(_ phoneID: String) {
        // Only phones that serve places answer places.list (any destination mode).
        guard folderSupport(for: phoneID)?.places == true else { return }
        switch freeSpaceThrottle.request(phoneID, now: Date()) {
        case .alreadyWaiting:
            return
        case let .later(delay):
            freeSpaceTrailing[phoneID]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.freeSpaceTrailing.removeValue(forKey: phoneID)
                self.freeSpaceThrottle.trailingDone(phoneID)
                self.refreshPhoneFreeSpace(phoneID)
            }
            freeSpaceTrailing[phoneID] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .ask:
            guard let wire = folderTransport(for: phoneID) else { return }
            folders.places.list(phoneID: phoneID, send: { kind, payload in
                wire.transport.send(kind: kind, payload: payload, transferID: nil, sequence: nil)
            }) { [weak self] result in
                guard let self, case let .success(listed) = result, let free = FreeSpaceReading.bytes(from: listed) else { return }
                self.phoneReportedFreeSpace(phoneID, bytes: free)
            }
        }
    }

    func phoneReportedFreeSpace(_ phoneID: String, bytes: Int64) {
        guard registry.session(for: phoneID) != nil else { return }
        phoneFreeSpace[phoneID] = PhoneFreeSpace(bytes: bytes, checkedAt: Date())
    }

    /// Disconnect: the value is stale at once, and nothing is asked for that phone any more.
    private func forgetPhoneFreeSpace(_ phoneID: String) {
        phoneFreeSpace.removeValue(forKey: phoneID)
        freeSpaceTrailing.removeValue(forKey: phoneID)?.cancel()
        freeSpaceThrottle.forget(phoneID)
    }

    /// A row in the transfer list for work before a send (Tray and send-sheet optimisation: "Optimising 3 of 12").
    func showPreparationRow(id: String, name: String, status: String, active: Bool) {
        updateFileTransfer(id: id, name: name, status: status, active: active)
    }

    func removePreparationRow(id: String) {
        fileTransfers.removeValue(forKey: id)
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
    }

    /// Settings > Privacy > Logging > Clear logs: the diagnostics log on this Mac. The unified log
    /// is the system's and ages out on its own.
    func clearDiagnostics() {
        diagnostics.clear()
    }

    func exportDiagnostics() {
        let stateName: String
        switch state {
        case .idle: stateName = "idle"
        case .connecting: stateName = "connecting"
        case .verification: stateName = "verification"
        case .connected: stateName = "connected"
        case .failed: stateName = "failed"
        }
        let localFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map {
            ($0, settings.isEnabled($0, for: nil))
        })
        guard let report = try? diagnostics.report(
            connectionState: stateName,
            transfers: Array(fileTransfers.values),
            localFeatures: localFeatures,
            remoteFeatures: remoteFeatures,
            devices: diagnosticDevices()
        ) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Bridgey Diagnostics"
        panel.nameFieldStringValue = "Bridgey-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.write(to: url, options: .atomic)
    }

    /// Adds files to the selected phone's outgoing queue. Files are offered one after another,
    /// each as its own transfer, so a failure or cancellation affects only that file.
    private func queueFiles(_ urls: [URL]) {
        guard let targetID = session?.remoteDeviceID, case .connected = state else { return }
        queueFiles(urls, to: targetID)
    }

    private func queueFiles(_ urls: [URL], to targetID: String) {
        let queuedAt = Date()
        let status = L10n.text("files.queued", fallback: "Queued")
        var queue = fileSendQueues[targetID] ?? FileSendQueue<OutgoingQueueItem>()
        for (index, url) in urls.enumerated() {
            let transferID = UUID().uuidString.lowercased()
            outgoingFileSources[transferID] = url
            transferDevices[transferID] = targetID
            fileTransfers[transferID] = FileTransferRow(
                id: transferID,
                name: url.lastPathComponent,
                status: status,
                active: true,
                startedAt: queuedAt.addingTimeInterval(Double(index) / 1_000),
                queued: true
            )
            queue.enqueue(id: transferID, item: .file(url))
        }
        fileSendQueues[targetID] = queue
        pruneTransferHistory()
        beginFileTransferUI()
        startNextQueuedFile(for: targetID)
    }

    private func startNextQueuedFile(for targetID: String) {
        guard registry.session(for: targetID) != nil else { return }
        guard isFeatureAvailable(.files, for: targetID) else {
            stopFileQueue(for: targetID, status: "File transfer is turned off on one of your devices")
            return
        }
        guard let next = fileSendQueues[targetID]?.startNext() else { return }
        switch next.item {
        case let .file(url): prepareFile(url, transferID: next.id, targetID: targetID)
        case .folder: folders.start(next.id)
        }
    }

    private func finishQueuedFile(_ transferID: String) {
        filePreparationCancellations.removeValue(forKey: transferID)
        guard let targetID = transferDevices[transferID],
              fileSendQueues[targetID]?.finish(id: transferID) == true else { return }
        startNextQueuedFile(for: targetID)
    }

    /// Ends every file of one phone that has not started yet with the given status. They remain retryable.
    private func stopFileQueue(for targetID: String, status: String) {
        fileSendQueues[targetID]?.removeAllPending().forEach { id in
            if folders.owns(id) {
                folders.removedFromQueue(id, text: status)
            } else {
                markFileTransferFinished(id: id, status: status)
            }
        }
    }

    private func prepareFile(_ url: URL, transferID: String, targetID: String) {
        let preparationCancellation = FileCancellationToken()
        filePreparationCancellations[transferID] = preparationCancellation
        beginFileTransferUI()
        fileTransferStatus = "Preparing \(url.lastPathComponent)…"
        updateFileTransfer(id: transferID, name: url.lastPathComponent, status: fileTransferStatus!, active: true)
        diagnostics.record(category: "transfer", event: "send_started")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let transfer = try OutgoingFileTransfer(url: url, transferID: transferID, cancellation: preparationCancellation)
                DispatchQueue.main.async {
                    // The file goes to the phone it was meant for, even if another is selected now.
                    guard let self, self.fileSendQueues[targetID]?.currentID == transferID else { return }
                    self.filePreparationCancellations.removeValue(forKey: transferID)
                    guard let current = self.registry.session(for: targetID) else {
                        self.markFileTransferFinished(id: transferID, status: "Transfer interrupted; reconnect to retry")
                        self.finishQueuedFile(transferID)
                        return
                    }
                    do {
                        let payload = try JSONEncoder().encode(transfer.offer)
                        let encrypted = try encrypt(payload, key: current.pairingKey!)
                        self.outgoingFiles[transfer.transferID] = transfer
                        self.outgoingFileSources[transfer.transferID] = url
                        self.transferDevices[transfer.transferID] = current.remoteDeviceID
                        self.updateFileTransfer(
                            id: transfer.transferID,
                            name: transfer.displayName,
                            status: "Waiting for Android…",
                            active: true
                        )
                        current.send(PairingMessage(
                            kind: "files.offer",
                            sessionId: current.id,
                            messageId: UUID().uuidString.lowercased(),
                            nonce: encrypted.nonce,
                            ciphertext: encrypted.ciphertext,
                            transferId: transfer.transferID
                        ))
                        self.fileTransferStatus = "Waiting for Android…"
                    } catch {
                        self.fileTransferStatus = "Could not prepare the selected file"
                        self.markFileTransferFinished(id: transferID, status: self.fileTransferStatus!)
                        self.finishQueuedFile(transferID)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.fileSendQueues[targetID]?.currentID == transferID else { return }
                    self.fileTransferStatus = "Could not read the selected file"
                    self.markFileTransferFinished(id: transferID, status: self.fileTransferStatus!)
                    self.finishQueuedFile(transferID)
                }
            }
        }
    }

    func cancelFileTransfer() {
        filePreparationCancellations.values.forEach { $0.cancel() }
        filePreparationCancellations.removeAll()
        let queued = fileSendQueues.values.flatMap { queue in
            var queue = queue
            return queue.removeAll()
        }
        fileSendQueues.removeAll()
        queued.filter { !folders.owns($0) }.forEach { markFileTransferFinished(id: $0, status: "Transfer cancelled") }
        // Folders: the running one sends folders.cancel; the waiting ones end here.
        folders.cancelAll()
        folderReceiver.cancelAll()
        let transferIDs = Set(incomingFiles.keys).union(outgoingFiles.keys)
        transferIDs.forEach { transferID in
            markTransferCancelled(transferID)
            sendFileCancel(transferID)
        }
        incomingFiles.values.forEach { $0.cancel() }
        incomingFiles.removeAll()
        outgoingFiles.values.forEach { $0.cancel() }
        outgoingFiles.removeAll()
        transferIDs.forEach { markFileTransferFinished(id: $0, status: "Transfer cancelled") }
        fileTransferActive = false
        fileTransferStatus = "Transfer cancelled"
    }

    /// files.cancel goes to the phone the transfer belongs to.
    private func sendFileCancel(_ transferID: String) {
        guard let current = transferDevices[transferID].flatMap({ registry.session(for: $0) }) ?? session else { return }
        current.send(PairingMessage(kind: "files.cancel", sessionId: current.id, transferId: transferID))
    }

    func cancelFileTransfer(id transferID: String) {
        if folderReceiver.owns(transferID) {
            folderReceiver.cancel(transferID)
            return
        }
        if folders.owns(transferID) {
            if let targetID = transferDevices[transferID], fileSendQueues[targetID]?.removePending(id: transferID) == true {
                folders.removedFromQueue(transferID, text: nil)
            } else {
                folders.cancel(transferID)
            }
            return
        }
        if let targetID = transferDevices[transferID], fileSendQueues[targetID]?.removePending(id: transferID) == true {
            markFileTransferFinished(id: transferID, status: "Transfer cancelled")
            return
        }
        filePreparationCancellations.removeValue(forKey: transferID)?.cancel()
        markTransferCancelled(transferID)
        sendFileCancel(transferID)
        incomingFiles.removeValue(forKey: transferID)?.cancel()
        outgoingFiles.removeValue(forKey: transferID)?.cancel()
        markFileTransferFinished(id: transferID, status: "Transfer cancelled")
        fileTransferStatus = "Transfer cancelled"
        finishQueuedFile(transferID)
    }

    func retryFileTransfer(id transferID: String) {
        if folders.owns(transferID) {
            transferDevices.removeValue(forKey: transferID)
            folders.sendAgain(transferID)
            return
        }
        guard let url = outgoingFileSources[transferID] else { return }
        // A retry goes to the phone the file first went to.
        guard let targetID = transferDevices[transferID] ?? session?.remoteDeviceID,
              registry.session(for: targetID) != nil else {
            markFileTransferFinished(id: transferID, status: "Reconnect before retrying")
            return
        }
        guard isFeatureAvailable(.files, for: targetID) else {
            markFileTransferFinished(id: transferID, status: "File transfer is turned off on one of your devices")
            return
        }
        fileTransfers.removeValue(forKey: transferID)
        outgoingFileSources.removeValue(forKey: transferID)
        transferDevices.removeValue(forKey: transferID)
        diagnostics.record(category: "transfer", event: "retry_started")
        queueFiles([url], to: targetID)
    }

    /// Resume on a folder row: the same transfer, offered again with resume.
    func resumeFolderTransfer(id transferID: String) {
        folders.resume(transferID)
    }

    func clearTransferHistory() {
        // Interrupted folders that can still resume keep their rows.
        let keep: (FileTransferRow) -> Bool = { $0.active || $0.folder?.canResume == true }
        let inactiveIDs = fileTransfers.values.filter { !keep($0) }.map(\.id)
        inactiveIDs.forEach { outgoingFileSources.removeValue(forKey: $0) }
        folders.clearFinished()
        folderReceiver.clearFinished()
        fileTransfers = fileTransfers.filter { keep($0.value) }
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
    }

    func showFileTransferWindow() {
        if fileTransferWindow == nil {
            fileTransferWindow = FileTransferWindowController(pairing: self)
        }
        fileTransferWindow?.show()
    }

    func showFileDropWindow() {
        if fileDropWindow == nil {
            fileDropWindow = FileDropWindowController(pairing: self)
        }
        fileDropWindow?.show()
    }

    private func beginFileTransferUI() {
        fileTransferActive = true
        showFileTransferWindow()
    }

    private func startListener() {
        diagnostics.record(category: "transport", event: "listener_started")
        do {
            let listener = try NWListener(using: .tcp, on: 42_458)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { newState in
                if case let .failed(error) = newState {
                    BridgeyLog.transport.error("listener failed error=\(String(describing: error), privacy: .public)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            failPairing(.couldNotConnect, detail: "Could not start pairing listener")
        }
    }

    /// Every incoming connection is its own pending session: a pairing in its verification step
    /// and reconnects from other trusted phones run side by side.
    private func accept(_ connection: NWConnection) {
        let current = Session(connection: connection, peerName: "Android device")
        current.initiatedLocally = false
        // Where the phone connected from: once it authenticates, the next reconnect can dial it there.
        current.remoteHost = endpointHost(connection.endpoint)
        BridgeyLog.transport.notice("inbound connection address=\(current.remoteHost.map(addressTag) ?? "unknown", privacy: .public)")
        registry.addPending(current, initiatedLocally: false)
        scheduleConnectionTimeout(for: current)
        configure(current, onReady: {})
    }

    private func configure(_ current: Session, onReady: @escaping () -> Void) {
        current.onMessage = { [weak self, weak current] message in
            guard let self, let current else { return }
            self.receive(message, in: current)
        }
        current.onFailure = { [weak self, weak current] in
            guard let self, let current, !current.ended else { return }
            current.ended = true
            current.connectionTimeout?.cancel()
            current.heartbeat?.cancel()
            self.dialFinished(current)
            let reason = current.dropReason ?? "closed"
            if let id = self.registry.remove(current) {
                self.deviceDisconnected(id, reason: reason)
            } else if self.pairingSession === current {
                self.failPairing(current.failure ?? .connectionLost)
            } else if let dialed = current.dialDeviceID, !current.authenticated {
                // A reconnect that never authenticated: the schedule tries again.
                BridgeyLog.reconnect.notice("dial failed peer=\(shortDeviceID(dialed), privacy: .public) reason=\(reason, privacy: .public)")
                self.diagnostics.record(category: "reconnect", event: "dial_failed", outcome: reason, device: dialed)
            }
        }
        current.connection.stateUpdateHandler = { [weak self, weak current] newState in
            DispatchQueue.main.async {
                guard let self, let current else { return }
                switch newState {
                case .ready:
                    BridgeyLog.transport.info("socket ready outbound=\(current.initiatedLocally, privacy: .public)")
                    current.receive()
                    onReady()
                case let .failed(error):
                    if current.dropReason == nil { current.dropReason = connectionDropReason(error) }
                    if current.failure == nil, self.pairingSession === current {
                        current.failure = current.pairingKey == nil ? .couldNotConnect : .connectionLost
                    }
                    current.onFailure?()
                case .cancelled:
                    current.onFailure?()
                case let .waiting(error) where localNetworkPermissionDenied(error):
                    current.failure = .localNetworkDenied
                    current.dropReason = "local_network_denied"
                    current.close()
                    self.diagnostics.record(category: "transport", event: "local_network_denied", outcome: "permission_required")
                case let .waiting(error) where current.dialDeviceID != nil && !current.authenticated:
                    // Network.framework would wait for a better path; the reconnect schedule owns
                    // retries, so this dial ends here.
                    current.dropReason = connectionDropReason(error)
                    current.close()
                default:
                    break
                }
            }
        }
        current.connection.start(queue: .main)
    }

    private func receive(_ message: PairingMessage, in current: Session) {
        do {
            switch message.kind {
            case "quick.request", "quick.result":
                receiveQuickPayload(message, current: current)
            case "heartbeat.ping":
                guard message.sessionId == current.id, registry.isActive(current) else { return }
                current.heartbeatSupported = true
                current.send(PairingMessage(kind: "heartbeat.pong", sessionId: current.id, messageId: message.messageId))
            case "heartbeat.pong":
                guard message.sessionId == current.id, registry.isActive(current) else { return }
                current.heartbeatSupported = true
                if healthRecords[current.remoteDeviceID]?.roundTrips.received(message.messageId, at: Date()) != nil {
                    publishHealth()
                }
            case "pairing.offer":
                guard !current.initiatedLocally, current.pairingKey == nil else { return }
                // A reconnect meant for another device (it dialled an address that is now ours):
                // close without a pairing prompt.
                if let target = message.targetDeviceId, target.lowercased() != deviceID.lowercased() {
                    current.dropReason = "not_for_this_device"
                    current.close()
                    return
                }
                guard let publicKey = message.publicKey else { throw PairingError.invalidMessage }
                current.id = message.sessionId
                current.peerName = message.deviceName ?? "Android device"
                guard let remoteDeviceID = message.deviceId else { throw PairingError.invalidMessage }
                current.remoteDeviceID = remoteDeviceID
                current.remoteEphemeralKey = publicKey
                let key = P256.KeyAgreement.PrivateKey()
                current.privateKey = key
                current.localEphemeralKey = key.publicKey.x963Representation.base64EncodedString()
                let material = try pairingMaterial(privateKey: key, remoteKey: publicKey, sessionID: current.id)
                current.code = material.code
                current.pairingKey = material.key
                current.send(PairingMessage(
                    kind: "pairing.answer",
                    sessionId: current.id,
                    deviceId: deviceID,
                    deviceName: deviceName,
                    publicKey: current.localEphemeralKey
                ))
                authenticateOrPrompt(current)
            case "pairing.answer":
                guard current.pairingKey == nil else { return }
                // A reconnect reached some other device at the old address: never prompt to pair it.
                if let expected = current.dialDeviceID, expected.lowercased() != message.deviceId?.lowercased() {
                    current.dropReason = "wrong_device"
                    current.close()
                    return
                }
                guard message.sessionId == current.id,
                      let key = current.privateKey,
                      let publicKey = message.publicKey,
                      let remoteDeviceID = message.deviceId else { throw PairingError.invalidMessage }
                current.peerName = message.deviceName ?? current.peerName
                current.remoteDeviceID = remoteDeviceID
                current.remoteEphemeralKey = publicKey
                let material = try pairingMaterial(privateKey: key, remoteKey: publicKey, sessionID: current.id)
                current.code = material.code
                current.pairingKey = material.key
                authenticateOrPrompt(current)
            case "pairing.confirm":
                guard message.sessionId == current.id, current.pairingKey != nil,
                      let remoteID = message.deviceId,
                      remoteID == current.remoteDeviceID,
                      let identityKey = message.identityKey,
                      let proof = message.proof,
                      let signature = message.signature else { throw PairingError.invalidMessage }
                guard trustedIdentityKey(remoteID).map({ $0 == identityKey }) ?? true else {
                    current.failure = .identityChanged
                    throw PairingError.invalidMessage
                }
                current.failure = .codeRejected
                guard verifyConfirmationProof(
                        proof,
                        key: current.pairingKey!,
                        sessionID: current.id,
                        deviceID: remoteID,
                        identityKey: identityKey
                      ),
                      verifySignature(signature, identityKey: identityKey, data: authTranscript(current))
                else { throw PairingError.invalidMessage }
                current.failure = nil
                current.remoteIdentityKey = identityKey
                current.remoteConfirmed = true
                completeIfConfirmed(current)
            case "pairing.cancel":
                // Only ever ends the session it arrived on: never another phone's.
                guard message.sessionId == current.id || current.id.isEmpty else { return }
                current.failure = .cancelledRemote
                current.close()
            case "features.update":
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let messageID = message.messageId,
                      current.acceptMessageID(messageID),
                      let nonce = message.nonce,
                      let ciphertext = message.ciphertext,
                      let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!) else {
                    throw PairingError.invalidMessage
                }
                // Unknown keys are ignored; an unknown version keeps the previous state (docs/protocol-contract.md).
                let features: [BridgeyFeature: Bool]
                let draftKeys: [String: Bool]
                switch decodeFeatureState(plaintext) {
                case .invalid: throw PairingError.invalidMessage
                case .ignored: return
                case let .state(decoded, drafts):
                    features = decoded
                    draftKeys = drafts
                }
                let clipboardFiles = draftKeys[clipboardFilesFeatureKey] == true
                let phoneID = current.remoteDeviceID
                registry.update(phoneID) { link in
                    link.remoteFeatures = features
                    link.featureStateReceived = true
                    link.remoteClipboardFiles = clipboardFiles
                    link.remoteFolders = draftKeys[foldersFeatureKey] == true
                    link.remotePlaces = draftKeys[placesFeatureKey] == true
                    link.remoteBrowse = draftKeys[filesBrowseFeatureKey] == true
                    link.remoteSmsCodes = draftKeys[smsCodesFeatureKey] == true
                    link.remoteFocusSync = draftKeys[focusSyncFeatureKey] == true
                    link.remoteCamera = draftKeys[cameraFeatureKey] == true
                    link.remoteUpdates = draftKeys[updatesFeatureKey] == true
                    if !link.remoteUpdates { link.updateStatus = nil }
                    link.remoteSettingsSync = draftKeys[settingsSyncFeatureKey] == true
                    if features[.battery] == false { link.battery = nil }
                    if features[.findDevice] == false { link.ringing = false }
                }
                publish()
                // The phone turned Files off: files it has not been offered yet stay here, retryable.
                if features[.files] == false { stopFileQueue(for: phoneID, status: "File transfer is turned off on \(current.peerName)") }
                let isTarget = current === session
                if isTarget {
                    if !isFeatureAvailable(.links) { quickActions.reset() }
                    if features[.ping] == false { clearPingStatus() }
                    if features[.clipboard] == false { clearClipboardSendStatus() }
                    if features[.calls] == false { clearCallStatus() }
                    if features[.files] == false && fileTransferActive {
                        cancelFileTransfer()
                        fileTransferStatus = nil
                    }
                }
                mediaController.reset()
                mediaController.refresh()
                if features[.notifications] == false { clearRemoteCall(for: phoneID, reason: "notifications_off_phone") }
                if features[.findDevice] == false && macRingingFrom == phoneID { stopMacSound() }
                flushPendingCallIfPossible()
                publishLocalBattery(force: true)
                refreshAutoClipboard()
                // Folders interrupted for this phone resume now (within 24 hours of their last progress).
                folders.phoneReady(phoneID)
                refreshPhoneFreeSpace(phoneID)
                sendActionsCatalog(to: current)
                if draftKeys[focusSyncFeatureKey] == true, let active = focusSync.stateForNewPhone {
                    _ = sendQuickPayload(kind: "focus.state", payload: focusStatePayload(active), to: current)
                }
                // Update all: a phone that understands it hears this Mac's version and update state.
                if draftKeys[updatesFeatureKey] == true { updatesPeerReady(phoneID) }
                // Settings sync: a snapshot once both sides show the key, or the end of syncing when one stops.
                settingsSync.refresh(phoneID)
            case "ping.request":
                try receivePing(message, in: current)
            case "ping.ack":
                guard message.sessionId == current.id,
                      message.messageId == pingRequestID else { return }
                pingRequestID = nil
                setTransientPingStatus("Ping delivered")
                recordActivity(.pingSent, in: current)
            case "clipboard.offer":
                receiveClipboardOffer(message, in: current)
            case "clipboard.fetch":
                receiveClipboardFetch(message, in: current)
            case "clipboard.error":
                receiveClipboardError(message, in: current)
            case "clipboard.update", "clipboard.rich":
                guard featureEnabled(.clipboard, current: current) else {
                    current.send(PairingMessage(
                        kind: "clipboard.rejected",
                        sessionId: current.id,
                        messageId: message.messageId
                    ))
                    sendFeatureState()
                    return
                }
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let messageID = message.messageId,
                      current.acceptMessageID(messageID),
                      let nonce = message.nonce,
                      let ciphertext = message.ciphertext,
                      let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!) else {
                    throw PairingError.invalidMessage
                }
                let text: String
                let html: String?
                if message.kind == "clipboard.rich" {
                    guard let content = decodeRichClipboard(plaintext) else { throw PairingError.invalidMessage }
                    text = content.text
                    html = content.html
                } else {
                    guard let decoded = String(data: plaintext, encoding: .utf8),
                          clipboardTextFits(decoded) else { throw PairingError.invalidMessage }
                    text = decoded
                    html = nil
                }
                // Clipboard text from the phone supersedes the clipboard offers in both directions.
                clipboardOutbox.supersede()
                clipboardInbox.supersede()
                // A paste waiting for the phone must not see the pasteboard change under it.
                clipboardInbox.performPasteboardWrite { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    if let html { NSPasteboard.general.setData(Data(html.utf8), forType: .html) }
                    // Automatic clipboard must not send this clip back to the phone.
                    self?.autoClipboard.noteReceived(text: text, changeCount: NSPasteboard.general.changeCount)
                }
                diagnostics.record(category: "clipboard", event: html == nil ? "text_received" : "rich_received")
                recordActivity(.clipboardReceived, in: current, preview: text)
                BridgeyLog.line(BridgeyLog.clipboard, LogLines.clipboard(BridgeyLog.policy, event: "received", preview: text))
                current.send(PairingMessage(kind: "clipboard.ack", sessionId: current.id, messageId: messageID))
            case "clipboard.ack":
                if let pending = pendingOfferAck, message.messageId == pending.messageID {
                    pending.timeout.cancel()
                    pendingOfferAck = nil
                    clipboardStatus = pending.automatic ? nil : "Delivered"
                    recordClipActivity(.clipOfferSent, summary: pending.summary, deviceID: current.remoteDeviceID,
                                       deviceName: current.peerName, automatic: pending.automatic)
                    clipboardOutbox.startEagerPushes(limit: settings.clipboardEagerLimit)
                    return
                }
                guard message.messageId == clipboardSendID else { return }
                clipboardTimeoutWorkItem?.cancel()
                clipboardTimeoutWorkItem = nil
                clipboardSendID = nil
                if let pending = pendingClipboardActivity {
                    clipboardStatus = pending.automatic ? nil : "Delivered"
                    recordActivity(.clipboardSent, in: current, preview: pending.preview, sensitive: pending.sensitive, automatic: pending.automatic)
                } else {
                    clipboardStatus = "Delivered"
                }
                pendingClipboardActivity = nil
                BridgeyLog.line(BridgeyLog.clipboard, LogLines.clipboard(BridgeyLog.policy, event: "acknowledged"))
            case "clipboard.rejected":
                if let pending = pendingOfferAck, message.messageId == pending.messageID {
                    pending.timeout.cancel()
                    pendingOfferAck = nil
                    clipboardOutbox.supersede()
                    clipboardStatus = "Copy images and files is turned off on Android"
                    return
                }
                guard message.messageId == clipboardSendID else { return }
                clipboardTimeoutWorkItem?.cancel()
                clipboardTimeoutWorkItem = nil
                clipboardSendID = nil
                clipboardStatus = "Clipboard is turned off on Android"
            case "find.start":
                try receiveFindCommand(message, in: current, start: true)
            case "find.stop":
                try receiveFindCommand(message, in: current, start: false)
            case "find.started":
                try receiveFindAcknowledgement(message, in: current, started: true)
            case "find.stopped":
                try receiveFindAcknowledgement(message, in: current, started: false)
            case "battery.update":
                guard featureEnabled(.battery, current: current) else { return }
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let messageID = message.messageId,
                      current.acceptMessageID(messageID),
                      let nonce = message.nonce,
                      let ciphertext = message.ciphertext,
                      let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
                      let payload = decodeBatteryStatus(plaintext) else {
                    throw PairingError.invalidMessage
                }
                registry.update(current.remoteDeviceID) { $0.battery = payload }
                publish()
                batteryAlerts.received(level: payload.level, charging: payload.isCharging, deviceID: current.remoteDeviceID, phone: current.peerName)
                BridgeyLog.plugin.debug("battery received level=\(payload.level, privacy: .public) charging=\(payload.isCharging, privacy: .public)")
            case "notifications.post":
                guard featureEnabled(.notifications, current: current) else { return }
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let messageID = message.messageId,
                      current.acceptMessageID(messageID),
                      let nonce = message.nonce,
                      let ciphertext = message.ciphertext,
                      let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
                      let payload = try? JSONDecoder().decode(RemoteNotificationPayload.self, from: plaintext),
                      !payload.packageName.isEmpty,
                      !payload.applicationName.isEmpty,
                      payload.callType == nil || normalizedRemoteCallType(payload.callType) != nil,
                      (!payload.title.isEmpty || !payload.text.isEmpty) else {
                    throw PairingError.invalidMessage
                }
                if payload.callType == nil {
                    recordActivity(.notificationsShown, in: current, appName: payload.applicationName)
                }
                updateRemoteCall(payload, deviceID: current.remoteDeviceID)
                if shouldUseSystemNotification(callType: payload.callType) {
                    deliverNotification(payload, deviceID: current.remoteDeviceID, deviceName: current.peerName)
                } else {
                    recordNotificationHistory(payload, deviceID: current.remoteDeviceID)
                }
            case "notifications.remove":
                guard featureEnabled(.notifications, current: current),
                      let reference = try receiveNotificationReference(message, in: current) else { return }
                removeRemoteNotification(
                    reference.notificationId,
                    deviceID: current.remoteDeviceID,
                    callEnded: reference.callEnded == true
                )
            case "calls.started", "calls.confirmation_required", "calls.rejected":
                guard message.messageId == callRequestID else { return }
                callTimeoutWorkItem?.cancel()
                callTimeoutWorkItem = nil
                callRequestID = nil
                switch message.kind {
                case "calls.started":
                    setTransientCallStatus("Call started on Android")
                    recordActivity(.callStarted, in: current)
                case "calls.confirmation_required": setTransientCallStatus("Confirm the call from the Android notification")
                default: setTransientCallStatus("Android rejected the call request")
                }
            case "files.offer":
                if receiveClipboardTransferOffer(message, in: current) { return }
                guard featureEnabled(.files, current: current) else {
                    current.send(PairingMessage(
                        kind: "files.rejected",
                        sessionId: current.id,
                        transferId: message.transferId
                    ))
                    sendFeatureState()
                    return
                }
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let messageID = message.messageId,
                      current.acceptMessageID(messageID),
                      let nonce = message.nonce,
                      let ciphertext = message.ciphertext,
                      let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
                      let offer = try? JSONDecoder().decode(FileOfferPayload.self, from: plaintext),
                      UUID(uuidString: offer.transferId) != nil,
                      !offer.name.isEmpty,
                      offer.size >= 0,
                      offer.size <= 10 * 1024 * 1024 * 1024,
                      Data(base64Encoded: offer.sha256)?.count == 32 else {
                    throw PairingError.invalidMessage
                }
                guard incomingFiles[offer.transferId] == nil else { throw PairingError.invalidMessage }
                // A file inside a folder coming to this Mac (4.6): the folder session checks it against the manifest.
                if (try? JSONDecoder().decode(FolderFileProbe.self, from: plaintext))?.folderTransferId != nil {
                    if !folderReceiver.fileOffer(plaintext, from: current.remoteDeviceID) {
                        current.send(PairingMessage(kind: "files.cancel", sessionId: current.id, transferId: offer.transferId))
                    }
                    return
                }
                if let requestID = offer.cameraRequestId, camera.matches(requestID, from: current.remoteDeviceID) {
                    cameraTransfers[offer.transferId] = requestID
                }
                let transfer = try IncomingFileTransfer(offer: offer, directoryAccess: settings.receiveDirectoryAccess())
                incomingFiles[offer.transferId] = transfer
                transferDevices[offer.transferId] = current.remoteDeviceID
                beginFileTransferUI()
                fileTransferStatus = "Receiving \(transfer.displayName): \(transfer.progressStatus(force: true)!)"
                updateFileTransfer(id: offer.transferId, name: transfer.displayName, status: fileTransferStatus!, active: true)
                current.send(PairingMessage(
                    kind: "files.accept",
                    sessionId: current.id,
                    transferId: offer.transferId
                ))
                BridgeyLog.line(BridgeyLog.files, LogLines.file(BridgeyLog.policy, event: "accepted", transfer: offer.transferId, name: transfer.displayName, extra: "size=\(offer.size)"))
            case "files.chunk":
                if clipboardInbox.owns(message.transferId) {
                    guard registry.isActive(current), message.sessionId == current.id,
                          let messageID = message.messageId, current.acceptMessageID(messageID),
                          let transferID = message.transferId, let sequence = message.sequence,
                          let nonce = message.nonce, let ciphertext = message.ciphertext, let key = current.pairingKey,
                          let chunk = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { return }
                    clipboardInbox.handleChunk(transferID: transferID, sequence: sequence, data: chunk)
                    return
                }
                if folderReceiver.ownsFile(message.transferId) {
                    guard registry.isActive(current), message.sessionId == current.id,
                          let messageID = message.messageId, current.acceptMessageID(messageID),
                          let transferID = message.transferId, let sequence = message.sequence,
                          let nonce = message.nonce, let ciphertext = message.ciphertext, let key = current.pairingKey else { return }
                    guard let chunk = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { throw PairingError.invalidMessage }
                    _ = folderReceiver.chunk(transferID, sequence: sequence, data: chunk, from: current.remoteDeviceID)
                    return
                }
                if let transferID = message.transferId,
                   incomingFiles[transferID] == nil,
                   cancelledTransferIDs.contains(transferID) { return }
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let messageID = message.messageId,
                      current.acceptMessageID(messageID),
                      let transferID = message.transferId,
                      let sequence = message.sequence,
                      let transfer = incomingFiles[transferID],
                      let nonce = message.nonce,
                      let ciphertext = message.ciphertext,
                      let chunk = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!) else {
                    throw PairingError.invalidMessage
                }
                try transfer.append(chunk, sequence: sequence)
                if let progress = transfer.progressStatus() {
                    fileTransferStatus = "Receiving \(transfer.displayName): \(progress)"
                    updateFileTransfer(id: transferID, name: transfer.displayName, status: fileTransferStatus!, active: true)
                }
            case "files.complete":
                if clipboardInbox.owns(message.transferId) {
                    guard registry.isActive(current), message.sessionId == current.id,
                          let messageID = message.messageId, current.acceptMessageID(messageID),
                          let nonce = message.nonce, let ciphertext = message.ciphertext, let key = current.pairingKey,
                          let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key),
                          let completion = try? JSONDecoder().decode(ClipboardTransferComplete.self, from: plaintext),
                          completion.transferId == message.transferId else { return }
                    clipboardInbox.handleComplete(transferID: completion.transferId, sha256: completion.sha256)
                    return
                }
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let messageID = message.messageId,
                      current.acceptMessageID(messageID),
                      let nonce = message.nonce,
                      let ciphertext = message.ciphertext,
                      let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
                      let completion = try? JSONDecoder().decode(FileCompletePayload.self, from: plaintext) else {
                    throw PairingError.invalidMessage
                }
                if folderReceiver.fileComplete(completion.transferId, sha256: completion.sha256, from: current.remoteDeviceID) { return }
                guard let transfer = incomingFiles.removeValue(forKey: completion.transferId) else {
                    if cancelledTransferIDs.contains(completion.transferId) { return }
                    throw PairingError.invalidMessage
                }
                do {
                    let destination = try transfer.finish(expectedHash: completion.sha256)
                    let folder = destination.deletingLastPathComponent().path
                    FinderMetadata.finish([destination], phoneName: current.peerName, tag: settings.tagReceivedFiles)
                    fileTransferStatus = "Saved \(transfer.displayName) to \(folder)"
                    updateFileTransfer(id: completion.transferId, name: transfer.displayName, status: fileTransferStatus!, active: false, localURL: destination)
                    recordFileHistory(completion.transferId, direction: .received, outcome: .completed, name: destination.lastPathComponent,
                                      bytes: transfer.expectedSize, localURL: destination, phoneID: current.remoteDeviceID)
                    fileTransferActive = fileTransfers.values.contains(where: { $0.active })
                    current.send(PairingMessage(
                        kind: "files.complete.ack",
                        sessionId: current.id,
                        transferId: completion.transferId
                    ))
                    recordActivity(.fileReceived, in: current, fileName: transfer.displayName)
                    if let requestID = cameraTransfers.removeValue(forKey: completion.transferId) {
                        camera.photoArrived(destination, requestID: requestID, from: current.remoteDeviceID, phoneName: current.peerName)
                    }
                    announceReceived([ReceivedItem(url: destination, isFolder: false)], phoneID: current.remoteDeviceID, revealIfSilent: true)
                    BridgeyLog.line(BridgeyLog.files, LogLines.file(BridgeyLog.policy, event: "received", transfer: completion.transferId, name: transfer.displayName))
                } catch {
                    transfer.cancel()
                    fileTransferStatus = "File verification failed"
                    recordActivity(.fileFailed, in: current, fileName: transfer.displayName)
                    recordFileHistory(completion.transferId, direction: .received, outcome: .failed, name: transfer.displayName,
                                      bytes: transfer.receivedSize, localURL: nil, phoneID: current.remoteDeviceID)
                    throw error
                }
            case "files.accept":
                if clipboardOutbox.owns(message.transferId), let transferID = message.transferId {
                    clipboardOutbox.handleAccept(transferID)
                    return
                }
                if folders.receiveFile(kind: message.kind, transferID: message.transferId, sequence: nil, from: current.remoteDeviceID) { return }
                if let transferID = message.transferId,
                   outgoingFiles[transferID] == nil,
                   cancelledTransferIDs.contains(transferID) { return }
                guard registry.isActive(current),
                      message.sessionId == current.id,
                      let transferID = message.transferId,
                      let transfer = outgoingFiles[transferID] else { throw PairingError.invalidMessage }
                updateFileTransfer(id: transferID, name: transfer.displayName, status: "Sending \(transfer.displayName)…", active: true)
                transfer.send(
                    through: current,
                    key: current.pairingKey!,
                    status: { [weak self] value in
                        guard let self, self.outgoingFiles[transferID] === transfer,
                              !transfer.isCancelled,
                              !self.cancelledTransferIDs.contains(transferID) else { return }
                        self.fileTransferStatus = value
                        self.updateFileTransfer(id: transferID, name: transfer.displayName, status: value, active: true)
                    },
                    completion: { [weak self, weak current] result in
                        guard let self, let current, self.registry.isActive(current) else { return }
                        switch result {
                        case let .success(completion):
                            guard !transfer.isCancelled,
                                  self.outgoingFiles[transferID] === transfer,
                                  !self.cancelledTransferIDs.contains(transferID) else { return }
                            current.send(completion)
                        case .failure:
                            self.outgoingFiles.removeValue(forKey: transferID)
                            self.recordFileHistory(transferID, direction: .sent, outcome: transfer.isCancelled ? .cancelled : .failed, name: transfer.displayName,
                                                   bytes: 0, localURL: self.outgoingFileSources[transferID], phoneID: current.remoteDeviceID)
                            if transfer.isCancelled {
                                self.fileTransferStatus = "Transfer cancelled"
                                self.markFileTransferFinished(id: transferID, status: "Transfer cancelled")
                                self.finishQueuedFile(transferID)
                                return
                            } else {
                                self.fileTransferStatus = "File transfer failed"
                            }
                            self.fileTransferActive = self.fileTransfers.values.contains(where: { $0.active })
                            self.updateFileTransfer(id: transferID, name: transfer.displayName, status: self.fileTransferStatus!, active: false)
                            self.finishQueuedFile(transferID)
                        }
                    }
                )
            case "files.rejected":
                if clipboardOutbox.owns(message.transferId), let transferID = message.transferId {
                    clipboardOutbox.handleCancel(transferID)
                    return
                }
                if folders.receiveFile(kind: message.kind, transferID: message.transferId, sequence: nil, from: current.remoteDeviceID) { return }
                guard let transferID = message.transferId,
                      let transfer = outgoingFiles.removeValue(forKey: transferID) else { return }
                transfer.cancel()
                markTransferCancelled(transferID)
                markFileTransferFinished(id: transferID, status: "File transfer is turned off on Android")
                fileTransferStatus = "File transfer is turned off on Android"
                stopFileQueue(for: current.remoteDeviceID, status: "File transfer is turned off on Android")
                finishQueuedFile(transferID)
            case "files.complete.ack":
                if clipboardOutbox.owns(message.transferId), let transferID = message.transferId {
                    clipboardOutbox.handleCompleteAck(transferID)
                    return
                }
                if folders.receiveFile(kind: message.kind, transferID: message.transferId, sequence: nil, from: current.remoteDeviceID) { return }
                guard let transferID = message.transferId,
                      let transfer = outgoingFiles.removeValue(forKey: transferID) else { return }
                let source = outgoingFileSources.removeValue(forKey: transferID)
                recordFileHistory(transferID, direction: .sent, outcome: .completed, name: transfer.displayName, bytes: transfer.offer.size,
                                  localURL: source, phoneID: current.remoteDeviceID)
                refreshPhoneFreeSpace(current.remoteDeviceID)
                fileTransferStatus = "\(transfer.displayName) saved on Android"
                recordActivity(.fileSent, in: current, fileName: transfer.displayName)
                updateFileTransfer(id: transferID, name: transfer.displayName, status: fileTransferStatus!, active: false)
                fileTransferActive = fileTransfers.values.contains(where: { $0.active })
                BridgeyLog.files.notice("file sent transfer=\(String(transferID.prefix(8)), privacy: .public)")
                finishQueuedFile(transferID)
            case "files.cancel":
                guard let transferID = message.transferId else { return }
                if clipboardInbox.owns(transferID) || clipboardOutbox.owns(transferID) {
                    clipboardInbox.handleCancel(transferID: transferID)
                    clipboardOutbox.handleCancel(transferID)
                    current.send(PairingMessage(kind: "files.cancel.ack", sessionId: current.id, transferId: transferID))
                    return
                }
                if folders.receiveFile(kind: message.kind, transferID: transferID, sequence: nil, from: current.remoteDeviceID) { return }
                if folderReceiver.fileCancelled(transferID, from: current.remoteDeviceID) { return }
                if let incoming = incomingFiles[transferID] {
                    recordFileHistory(transferID, direction: .received, outcome: .cancelled, name: incoming.displayName, bytes: incoming.receivedSize,
                                      localURL: nil, phoneID: current.remoteDeviceID)
                } else if let outgoing = outgoingFiles[transferID] {
                    recordFileHistory(transferID, direction: .sent, outcome: .cancelled, name: outgoing.displayName, bytes: 0,
                                      localURL: outgoingFileSources[transferID], phoneID: current.remoteDeviceID)
                }
                markTransferCancelled(transferID)
                incomingFiles.removeValue(forKey: transferID)?.cancel()
                outgoingFiles.removeValue(forKey: transferID)?.cancel()
                markFileTransferFinished(id: transferID, status: "Transfer cancelled by Android")
                fileTransferStatus = "Transfer cancelled by Android"
                current.send(PairingMessage(kind: "files.cancel.ack", sessionId: current.id, transferId: transferID))
                BridgeyLog.files.notice("file cancellation received transfer=\(String(transferID.prefix(8)), privacy: .public)")
                finishQueuedFile(transferID)
            case "files.cancel.ack":
                if clipboardInbox.owns(message.transferId) || clipboardOutbox.owns(message.transferId) { return }
                if let transferID = message.transferId {
                    markFileTransferFinished(id: transferID, status: "Transfer cancelled")
                }
            case "files.chunk.ack":
                if folders.receiveFile(kind: message.kind, transferID: message.transferId, sequence: message.sequence, from: current.remoteDeviceID) { return }
                if let transferID = message.transferId, let sequence = message.sequence {
                    outgoingFiles[transferID]?.acknowledge(sequence: sequence)
                    clipboardOutbox.handleChunkAck(transferID, sequence: sequence)
                }
            case let kind where BrowseKind.answerKinds.contains(kind):
                try receiveBrowseMessage(message, in: current)
            case let kind where FolderKind.folderKinds.contains(kind) || FolderKind.placesKinds.contains(kind):
                try receiveFolderMessage(message, in: current)
            case let kind where kind.hasPrefix("input."):
                receiveRemoteInput(message, in: current)
            case let kind where kind.hasPrefix("codes."):
                receiveCodesMessage(message, in: current)
            case let kind where kind.hasPrefix("actions."):
                receiveActionsMessage(message, in: current)
            case "focus.state":
                receiveFocusState(message, in: current)
            case "camera.status":
                receiveCameraStatus(message, in: current)
            case "updates.status", "updates.start", "updates.result":
                receiveUpdatesMessage(message, in: current)
            case "settings.snapshot", "settings.update", "settings.ack", "settings.error":
                try receiveSettingsMessage(message, in: current)
            default:
                break
            }
        } catch {
            // Only this session closes; a pairing shows why, other phones stay connected.
            if current.failure == nil { current.failure = .invalid }
            current.close()
            diagnostics.record(category: "protocol", event: "message_rejected", outcome: "session_closed")
        }
    }

    private func completeIfConfirmed(_ current: Session) {
        guard current.localConfirmed, current.remoteConfirmed, !current.authenticated, !current.ended else { return }
        let id = current.remoteDeviceID
        switch registry.authenticate(current, deviceID: id, peerName: current.peerName) {
        case .rejected:
            // A live session for this phone wins the duplicate rule; this socket closes quietly.
            BridgeyLog.transport.notice("duplicate session closed peer=\(shortDeviceID(id), privacy: .public)")
            diagnostics.record(category: "transport", event: "duplicate_closed", device: id)
            if pairingSession === current {
                pairingSession = nil
                pairingFlow = .idle
            }
            current.ended = true
            current.connectionTimeout?.cancel()
            dialFinished(current)
            current.close()
            publish()
            return
        case let .accepted(replaced):
            if let replaced {
                BridgeyLog.transport.notice("duplicate session replaced peer=\(shortDeviceID(id), privacy: .public)")
                diagnostics.record(category: "transport", event: "duplicate_replaced", device: id)
                replaced.dropReason = "replaced"
                replaced.connectionTimeout?.cancel()
                replaced.heartbeat?.cancel()
                replaced.close()
            }
        }
        current.authenticated = true
        current.connectionTimeout?.cancel()
        dialFinished(current)
        saveTrust(current)
        let source: AddressSource = current.initiatedLocally ? .outbound : .inbound
        let port = current.initiatedLocally ? current.endpoint?.port ?? ReconnectPolicy.listeningPort : ReconnectPolicy.listeningPort
        let attempts = reconnect.schedule.entry(id)?.attempts ?? 0
        reconnect.connected(id, host: current.remoteHost, port: port, source: source)
        if disconnectedTrustedIDs.isEmpty { discoveryWindowStart = nil }
        BridgeyLog.reconnect.notice("connected peer=\(shortDeviceID(id), privacy: .public) via=\(source.rawValue, privacy: .public) address=\(current.remoteHost.map(addressTag) ?? "unknown", privacy: .public) attempts=\(attempts, privacy: .public)")
        diagnostics.record(category: "transport", event: "connected", outcome: source.rawValue, device: id, detail: "after_\(attempts)_attempts")
        var record = healthRecords[id] ?? DeviceHealthRecord()
        record.connectedSince = Date()
        record.route = connectionRoute(forHost: current.remoteHost)
        record.outbound = current.initiatedLocally
        record.roundTrips = HeartbeatRoundTrips()
        healthRecords[id] = record
        macActions.disconnected(deviceID: id)
        if pairingSession === current {
            pairingSession = nil
            pairingFlow = .idle
        }
        publish()
        diagnostics.record(category: "pairing", event: "connected")
        sendFeatureState(to: current)
        publishLocalBattery(force: true)
        scheduleHeartbeat(for: current)
        refreshAutoClipboard()
        BridgeyLog.pairing.notice("verified peer=\(shortDeviceID(id), privacy: .public) name=\(current.peerName, privacy: .private)")
        finishRediscoverIfEveryoneAnswered()
    }

    /// A dial is over (it connected, lost the duplicate rule or failed): it no longer blocks the
    /// next attempt to its phone.
    private func dialFinished(_ current: Session) {
        guard let dialed = current.dialDeviceID, !current.dialFinished else { return }
        current.dialFinished = true
        reconnect.dialEnded(dialed)
    }

    /// Feature state goes to every connected phone (each gets its own per-device settings).
    private func sendFeatureState() {
        for (_, current) in registry.broadcastTargets({ _, _ in true }) { sendFeatureState(to: current) }
    }

    private func sendFeatureState(to current: Session) {
        guard registry.isActive(current), let key = current.pairingKey else { return }
        var features = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map {
            ($0.rawValue, settings.isEnabled($0, for: current.remoteDeviceID))
        })
        features[clipboardFilesFeatureKey] = clipboardOffersEnabledLocally(current)
        // Draft, edition only: this Mac sends folders (receiving them comes with phone to Mac). It serves no
        // places, so places_draft1 is false.
        features[foldersFeatureKey] = settings.isEnabled(.files, for: current.remoteDeviceID)
        features[placesFeatureKey] = false
        // Files 2.0 browse (draft): this Mac receives folders from the phone; it browses but serves nothing.
        features[foldersReceiveFeatureKey] = settings.isEnabled(.files, for: current.remoteDeviceID)
        features[filesBrowseFeatureKey] = false
        // Draft, edition only: this Mac reads codes from SMS and can advertise for the phone's companion link.
        features[smsCodesFeatureKey] = settings.isEnabled(.notifications, for: current.remoteDeviceID)
        // Draft, edition only: this Mac understands links "open" (Open on Mac from the phone).
        features[linksOpenFeatureKey] = settings.isEnabled(.links, for: current.remoteDeviceID)
        // Draft, edition only: focus.state, while either Focus direction is on.
        features[focusSyncFeatureKey] = focusSync.advertised
        // Draft, edition only: this Mac can ask for photos; they arrive as files.
        features[cameraFeatureKey] = settings.isEnabled(.files, for: current.remoteDeviceID)
        // Draft, edition only: Update all. Always on; whether phones may start this Mac's update is in updates.status.
        features[updatesFeatureKey] = true
        // Draft, edition only: settings sync, while the global and this phone's switches are on.
        features[settingsSyncFeatureKey] = settingsSync.advertised(for: current.remoteDeviceID)
        guard let payload = try? JSONEncoder().encode(FeatureStatePayload(version: 1, features: features)),
              let encrypted = try? encrypt(payload, key: key) else { return }
        current.send(PairingMessage(
            kind: "features.update",
            sessionId: current.id,
            messageId: UUID().uuidString.lowercased(),
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        ))
    }

    /// One phone disconnected: only its file transfers stop, and its queue is interrupted (retryable).
    /// Its folders stop where they are and resume when it reconnects.
    private func cancelTransfers(for id: String) {
        folders.phoneDisconnected(id)
        folderReceiver.phoneDisconnected(id)
        forgetPhoneFreeSpace(id)
        receivedNotifier.forget(id)
        phoneFilesController.phoneDisconnected(id)
        let ids = Set(transferDevices.filter { $0.value == id && !folders.owns($0.key) }.keys)
        let hadActiveTransfers = fileTransfers.values.contains(where: { $0.active && ids.contains($0.id) })
        if var queue = fileSendQueues.removeValue(forKey: id) {
            queue.removeAll().filter { !folders.owns($0) }.forEach {
                filePreparationCancellations.removeValue(forKey: $0)?.cancel()
                markFileTransferFinished(id: $0, status: "Transfer interrupted; reconnect to retry")
            }
        }
        for transferID in ids {
            incomingFiles.removeValue(forKey: transferID)?.cancel()
            outgoingFiles.removeValue(forKey: transferID)?.cancel()
        }
        let affected = fileTransfers.filter { ids.contains($0.key) }
        fileTransfers = fileTransfers.filter { !ids.contains($0.key) }.merging(recoverInterruptedTransfers(affected)) { $1 }
        pruneTransferHistory()
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
        if hadActiveTransfers {
            fileTransferStatus = "File transfer interrupted"
            diagnostics.record(category: "transfer", event: "interrupted", outcome: "retry_available")
        }
    }

    private func markTransferCancelled(_ transferID: String) {
        cancelledTransferIDs.insert(transferID)
        if cancelledTransferIDs.count > 64, let first = cancelledTransferIDs.first {
            cancelledTransferIDs.remove(first)
        }
    }

    private func updateFileTransfer(id: String, name: String, status: String, active: Bool, localURL: URL? = nil) {
        let previous = fileTransfers[id]
        fileTransfers[id] = FileTransferRow(
            id: id,
            name: name,
            status: status,
            active: active,
            startedAt: previous?.startedAt ?? Date(),
            retryable: !active && outgoingFileSources[id] != nil,
            localURL: localURL ?? previous?.localURL ?? outgoingFileSources[id]
        )
        pruneTransferHistory()
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
    }

    /// The History window's record of one finished file (Files 2.0).
    private func recordFileHistory(_ id: String, direction: TransferHistoryEntry.Direction, outcome: TransferHistoryEntry.Outcome, name: String,
                                   bytes: Int64, localURL: URL?, phoneID: String) {
        transferHistory.record(TransferHistoryEntry(
            id: id, date: Date(), direction: direction, deviceID: phoneID, deviceName: phoneName(phoneID), name: name,
            bytes: bytes, outcome: outcome, localPath: localURL?.path
        ))
    }

    private func markFileTransferFinished(id: String, status: String) {
        guard let transfer = fileTransfers[id] else { return }
        fileTransfers[id] = FileTransferRow(
            id: transfer.id,
            name: transfer.name,
            status: status,
            active: false,
            startedAt: transfer.startedAt,
            retryable: outgoingFileSources[id] != nil,
            localURL: transfer.localURL
        )
        pruneTransferHistory()
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
    }

    private func pruneTransferHistory() {
        let active = fileTransfers.values.filter { $0.active }
        let history = fileTransfers.values.filter { !$0.active }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(maximumTransferHistory)
        fileTransfers = Dictionary(uniqueKeysWithValues: (active + Array(history)).map { ($0.id, $0) })
    }

    private func authenticateOrPrompt(_ current: Session) {
        if trustedIdentityKey(current.remoteDeviceID) != nil {
            confirm(current)
            return
        }
        // A new phone needs the code prompt, which belongs to one pairing at a time.
        if let existing = pairingSession, existing !== current, existing.code != nil, !existing.ended {
            BridgeyLog.pairing.notice("rejected: another pairing is waiting for confirmation")
            current.send(PairingMessage(kind: "pairing.cancel", sessionId: current.id))
            current.close()
            return
        }
        pairingSession = current
        pairingFlow = .verification(peerName: current.peerName, code: current.code!)
        publish()
    }

    private func authTranscript(_ current: Session) -> Data {
        let fields = current.initiatedLocally
            ? [deviceID, current.remoteDeviceID, current.localEphemeralKey, current.remoteEphemeralKey]
            : [current.remoteDeviceID, deviceID, current.remoteEphemeralKey, current.localEphemeralKey]
        return Data((["bridgey-auth-v1", current.id] + fields).joined(separator: "\0").utf8)
    }

    private func trustedIdentityKey(_ deviceID: String) -> String? {
        trustRegistry.identityKey(for: deviceID)
    }

    private func verifySignature(_ value: String, identityKey: String, data: Data) -> Bool {
        guard let publicData = Data(base64Encoded: identityKey),
              let signatureData = Data(base64Encoded: value),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    // MARK: - Reconnect

    /// Discovery changed: the engine remembers trusted phones' addresses and tries new arrivals.
    func connectTrustedPeerIfNeeded(_ peers: [DiscoveredPeer]) {
        lastPeers = peers
        publishHealth()
        reconnect.discoveryChanged(peers)
    }

    /// At launch every trusted phone that is not connected is tried straight away at its last
    /// known addresses, and wake and network changes start being watched.
    private func startReconnecting() {
        reconnect.isTrusted = { [weak self] in self?.trustedDeviceIDs.contains($0) == true }
        reconnect.isConnected = { [weak self] in self?.registry.session(for: $0) != nil }
        reconnect.dial = { [weak self] id, address in
            guard let self, let port = NWEndpoint.Port(rawValue: UInt16(clamping: address.port)) else {
                self?.reconnect.dialEnded(id)
                return
            }
            self.dial(host: address.host, port: port, peerName: self.trustedName(id), deviceID: id)
        }
        reconnect.onEvent = { [weak self] event in self?.recordReconnect(event) }
        reconnect.onChange = { [weak self] in self?.publishReconnectStates() }
        reconnect.addressBook.retain(trustedDeviceIDs)
        let ids = disconnectedTrustedIDs
        for id in ids { reconnect.disconnected(id, seenNow: false) }
        reconnect.resetAll(ids)
        discoveryWindowStart = ids.isEmpty ? nil : clock.now
        // Discovery has only just started; the first periodic restart is five minutes away.
        lastDiscoveryRestart = clock.now
        linkMonitor.onEvent = { [weak self] reason in self?.linkEvent(reason) }
        linkMonitor.start()
        armDiscoveryRestartTimer()
    }

    private var disconnectedTrustedIDs: [String] {
        trustedDeviceIDs.filter { registry.session(for: $0) == nil }.sorted()
    }

    private func trustedName(_ id: String) -> String {
        lastPeers.first { $0.deviceIDHint == id }?.deviceNameHint
            ?? trustRegistry.devices.first { $0.id == id }?.name
            ?? "Android device"
    }

    private func recordReconnect(_ event: ReconnectEvent) {
        switch event {
        case let .dial(id, address, attempt, reason):
            healthRecords[id, default: DeviceHealthRecord()].reconnects.increment(now: Date())
            publishHealth()
            let tag = addressTag(address.host)
            BridgeyLog.reconnect.notice("dial peer=\(shortDeviceID(id), privacy: .public) attempt=\(attempt, privacy: .public) reason=\(reason, privacy: .public) source=\(address.source.rawValue, privacy: .public) address=\(tag, privacy: .public)")
            diagnostics.record(category: "reconnect", event: "dial", outcome: reason, device: id, detail: "n\(attempt)_\(address.source.rawValue)_\(tag)")
        case let .noAddress(id, attempt, reason):
            BridgeyLog.reconnect.notice("no dialable address peer=\(shortDeviceID(id), privacy: .public) attempt=\(attempt, privacy: .public) reason=\(reason, privacy: .public)")
            diagnostics.record(category: "reconnect", event: "no_address", outcome: reason, device: id, detail: "n\(attempt)")
        case let .foundByDiscovery(id, addresses):
            BridgeyLog.reconnect.notice("discovery found peer=\(shortDeviceID(id), privacy: .public) addresses=\(addresses, privacy: .public)")
            diagnostics.record(category: "discovery", event: "found_trusted", device: id, detail: "\(addresses)_addresses")
        }
    }

    /// "Look for devices again" is running.
    var isRediscovering: Bool { rediscoverRun != nil }

    /// "Retry now" on a disconnected phone: every known address at once.
    func retryNow(deviceID id: String) {
        BridgeyLog.reconnect.notice("retry now peer=\(shortDeviceID(id), privacy: .public)")
        reconnect.dialEverywhere(id, reason: "retry_now")
    }

    private func publishReconnectStates() {
        var states: [String: ReconnectDisplay] = [:]
        for id in trustedDeviceIDs {
            if let display = reconnect.display(for: id) { states[id] = display }
        }
        if reconnectStates != states { reconnectStates = states }
    }

    // MARK: Wake, network and discovery restarts

    private func linkEvent(_ reason: String) {
        BridgeyLog.reconnect.notice("link event \(reason, privacy: .public)")
        diagnostics.record(category: "link", event: reason)
        linkDebouncer.note(reason)
    }

    /// The Mac woke or its network changed: look again and try every dropped phone now.
    private func linkChanged(_ reasons: [String]) {
        let reason = reasons.joined(separator: "+")
        let now = clock.now
        let ids = disconnectedTrustedIDs
        BridgeyLog.reconnect.notice("recovering after \(reason, privacy: .public) disconnected=\(ids.count, privacy: .public)")
        if now.timeIntervalSince(lastDiscoveryRestart) >= ReconnectPolicy.eventRestartSpacing {
            restartDiscoveryNow(reason: reason)
        }
        reconnect.resetAll(ids)
        discoveryWindowStart = ids.isEmpty ? nil : now
        armDiscoveryRestartTimer()
    }

    private func restartDiscoveryNow(reason: String) {
        lastDiscoveryRestart = clock.now
        diagnostics.record(category: "discovery", event: "restart", outcome: reason)
        restartDiscovery?(reason)
    }

    /// Every five minutes while a trusted phone is away, for the first hour.
    private func armDiscoveryRestartTimer() {
        discoveryRestartTimer?.cancel()
        discoveryRestartTimer = nil
        let now = clock.now
        guard !disconnectedTrustedIDs.isEmpty, let start = discoveryWindowStart,
              now.timeIntervalSince(start) < ReconnectPolicy.discoveryRestartWindow else { return }
        // At most one restart per interval; after a drop, the first one waits 30 s so a quick
        // reconnect needs none.
        let next = max(lastDiscoveryRestart.addingTimeInterval(ReconnectPolicy.discoveryRestartInterval), now.addingTimeInterval(30))
        discoveryRestartTimer = clock.schedule(after: next.timeIntervalSince(now)) { [weak self] in
            guard let self else { return }
            self.discoveryRestartTimer = nil
            guard !self.disconnectedTrustedIDs.isEmpty, let start = self.discoveryWindowStart,
                  self.clock.now.timeIntervalSince(start) < ReconnectPolicy.discoveryRestartWindow else { return }
            self.restartDiscoveryNow(reason: "periodic")
            self.armDiscoveryRestartTimer()
        }
    }

    // MARK: Look for devices again

    /// Restarts discovery, re-announces this Mac, resets every backoff and dials every known
    /// address of each disconnected trusted phone. One run at a time.
    func lookForDevices() {
        guard rediscoverRun == nil else { return }
        let missing = Dictionary(uniqueKeysWithValues: disconnectedTrustedIDs.map { ($0, trustedName($0)) })
        rediscoverStatusClear?.cancel()
        rediscoverStatus = L10n.text("rediscover.looking", fallback: "Looking for devices\u{2026}")
        BridgeyLog.reconnect.notice("look for devices again disconnected=\(missing.count, privacy: .public)")
        diagnostics.record(category: "discovery", event: "manual", detail: "\(missing.count)_disconnected")
        let nearbyBefore = Set(lastPeers.compactMap(\.deviceIDHint))
        restartDiscoveryNow(reason: "manual")
        discoveryWindowStart = missing.isEmpty ? nil : clock.now
        for id in missing.keys.sorted() { reconnect.dialEverywhere(id, reason: "manual") }
        armDiscoveryRestartTimer()
        let finish = clock.schedule(after: ReconnectPolicy.rediscoverWindow) { [weak self] in self?.finishRediscover() }
        rediscoverRun = (missing, nearbyBefore, finish)
    }

    private func finishRediscoverIfEveryoneAnswered() {
        guard let run = rediscoverRun, !run.missing.isEmpty,
              run.missing.keys.allSatisfy({ registry.session(for: $0) != nil }) else { return }
        finishRediscover()
    }

    private func finishRediscover() {
        guard let run = rediscoverRun else { return }
        run.finish.cancel()
        rediscoverRun = nil
        let found = run.missing.filter { registry.session(for: $0.key) != nil }.map(\.value).sorted()
        let stillMissing = run.missing.filter { registry.session(for: $0.key) == nil }.map(\.value).sorted()
        let newNearby = lastPeers.filter { peer in
            guard let id = peer.deviceIDHint else { return false }
            return !trustedDeviceIDs.contains(id) && !run.nearbyBefore.contains(id)
        }.map(\.deviceNameHint)
        rediscoverStatus = rediscoverSummary(found: found + newNearby, stillMissing: stillMissing)
        diagnostics.record(category: "discovery", event: "manual_done", detail: "\(found.count)_found_\(stillMissing.count)_missing")
        rediscoverStatusClear = clock.schedule(after: 6) { [weak self] in self?.rediscoverStatus = nil }
    }

    /// Per trusted phone, for the diagnostics report: no names and no addresses.
    private func diagnosticDevices() -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return trustedDeviceIDs.sorted().map { id in
            var entry: [String: Any] = [
                "device": shortDeviceID(id),
                "connected": registry.session(for: id) != nil,
                "knownAddresses": reconnect.addressBook.addresses(for: id).count,
                "addressSources": reconnect.addressBook.addresses(for: id).map(\.source.rawValue),
                "reconnectAttempts": reconnect.schedule.entry(id)?.attempts ?? 0,
            ]
            if let seen = reconnect.addressBook.lastConnected(id) { entry["lastConnectedAt"] = formatter.string(from: seen) }
            if let next = reconnect.schedule.entry(id)?.nextAt { entry["nextAttemptAt"] = formatter.string(from: next) }
            entry["health"] = healthSnapshot(for: id).diagnostics()
            return entry
        }
    }

    /// A pending session gets 20 s for the handshake, or two minutes while its code is on screen.
    private func scheduleConnectionTimeout(for current: Session, after delay: TimeInterval = 20) {
        current.connectionTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, !current.ended, !self.registry.isActive(current) else { return }
            let awaitingCode = current.code != nil && self.trustedIdentityKey(current.remoteDeviceID) == nil
            if awaitingCode && Date().timeIntervalSince(current.createdAt) < 120 {
                self.scheduleConnectionTimeout(for: current, after: 5)
                return
            }
            BridgeyLog.transport.notice("pending session timed out")
            current.failure = .timeout
            current.dropReason = "handshake_timeout"
            current.close()
        }
        current.connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timeout)
    }

    private func scheduleHeartbeat(for current: Session) {
        current.heartbeat?.cancel()
        let work = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, self.registry.isActive(current) else { return }
            if heartbeatExpired(supported: current.heartbeatSupported, lastReceivedAt: current.lastReceivedAt) {
                BridgeyLog.transport.notice("heartbeat timed out peer=\(shortDeviceID(current.remoteDeviceID), privacy: .public)")
                current.dropReason = "heartbeat_timeout"
                current.close()
                return
            }
            let pingID = UUID().uuidString.lowercased()
            self.healthRecords[current.remoteDeviceID, default: DeviceHealthRecord()].roundTrips.sent(pingID, at: Date())
            current.send(PairingMessage(
                kind: "heartbeat.ping",
                sessionId: current.id,
                messageId: pingID
            ))
            self.reconnect.stillConnected(current.remoteDeviceID)
            self.publishLocalBattery()
            self.mediaController.refresh()
            self.scheduleHeartbeat(for: current)
        }
        current.heartbeat = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ReconnectPolicy.heartbeatInterval, execute: work)
    }

    private func postNotification(_ payload: RemoteNotificationPayload, deviceID: String) {
        let identifier = remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: payload.notificationId)
        let content = UNMutableNotificationContent()
        content.title = payload.callType == nil ? payload.applicationName : remoteCallStatusTitle(payload.callType)
        content.subtitle = payload.title
        content.body = payload.callType == nil ? payload.text : remoteCallDetail(payload.text, type: payload.callType)
        content.sound = alertedNotificationIdentifiers.insert(identifier) ? .default : nil
        content.categoryIdentifier = notificationCategoryIdentifier(for: payload, deviceID: deviceID)
        if let attachment = notificationIconAttachment(for: payload) {
            content.attachments = [attachment]
        }
        content.userInfo = [
            "androidPackage": payload.packageName,
            "androidNotificationId": payload.notificationId,
            "androidDeviceId": deviceID,
        ]
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        // Text messages can carry codes: their content never reaches the log, whatever Logging says.
        let fromSmsApp = isSmsNotification(packageName: payload.packageName, smsDefaultApp: payload.smsDefaultApp)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                BridgeyLog.notifications.error("notification delivery failed error=\(String(describing: error), privacy: .private)")
            } else {
                BridgeyLog.line(BridgeyLog.notifications, LogLines.notification(
                    BridgeyLog.policy, event: "shown", appName: payload.applicationName,
                    title: fromSmsApp ? nil : payload.title, text: fromSmsApp ? nil : payload.text
                ))
            }
        }
    }

    // MARK: Codes from messages

    /// A forwarded notification: an SMS that may hold a code waits up to two seconds for the code
    /// reader; everything else (and every failure) posts the plain notification as before.
    private func deliverNotification(_ payload: RemoteNotificationPayload, deviceID: String, deviceName: String) {
        let identifier = remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: payload.notificationId)
        codeReads.removeValue(forKey: identifier)?.cancel()
        if payload.redacted == true, isSmsNotification(packageName: payload.packageName, smsDefaultApp: payload.smsDefaultApp) {
            // Android hid the text from Bridgey on the phone: Settings shows it until the phone reports otherwise.
            registry.update(deviceID) { $0.codeAccess = .hidden }
            publish()
        }
        guard settings.codesEnabled,
              isCodeCandidate(packageName: payload.packageName, smsDefaultApp: payload.smsDefaultApp, redacted: payload.redacted, text: payload.text) else {
            recordNotificationHistory(payload, deviceID: deviceID)
            postNotification(payload, deviceID: deviceID)
            return
        }
        let reader = codeReader(engine: settings.codesEngine, local: codeModel.engine, relay: CodeRelay.baseURL, installID: settings.codesInstallID)
        codeReads[identifier] = Task { @MainActor [weak self] in
            let outcome = await reader.read(text: payload.text, sender: payload.title)
            guard let self, !Task.isCancelled else { return }
            self.codeReads.removeValue(forKey: identifier)
            self.diagnostics.record(category: "notification", event: "code_read", outcome: outcome.diagnosticName)
            if case let .code(code) = outcome {
                self.recordNotificationHistory(payload, deviceID: deviceID, codeShown: true)
                self.postCodeNotification(payload, code: code, deviceID: deviceID, deviceName: deviceName)
            } else {
                self.recordNotificationHistory(payload, deviceID: deviceID)
                self.postNotification(payload, deviceID: deviceID)
            }
        }
    }

    private func isSmsNotification(packageName: String, smsDefaultApp: Bool?) -> Bool {
        smsDefaultApp ?? knownSmsPackages.contains(packageName)
    }

    /// "Code 482913 from HDFC Bank" in place of the plain notification (same identifier, so never two
    /// banners), with Copy code. The code itself stays in memory; the notification only carries a reference.
    private func postCodeNotification(_ payload: RemoteNotificationPayload, code: String, deviceID: String, deviceName: String) {
        let identifier = remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: payload.notificationId)
        let card = LiveCodeCard(
            id: UUID().uuidString.lowercased(),
            code: code,
            sender: payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? payload.applicationName : payload.title,
            deviceName: deviceName,
            receivedAt: Date()
        )
        rememberCode(card)
        let content = UNMutableNotificationContent()
        content.title = codeNotificationTitle(code: code, sender: payload.title, applicationName: payload.applicationName)
        content.body = payload.text
        content.sound = alertedNotificationIdentifiers.insert(identifier) ? .default : nil
        content.categoryIdentifier = notificationCategoryIdentifier(for: payload, deviceID: deviceID, copyCode: true)
        if let attachment = notificationIconAttachment(for: payload) {
            content.attachments = [attachment]
        }
        content.userInfo = [
            "androidPackage": payload.packageName,
            "androidNotificationId": payload.notificationId,
            "androidDeviceId": deviceID,
            codeReferenceUserInfoKey: card.id,
        ]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                BridgeyLog.notifications.error("code notification delivery failed error=\(String(describing: error), privacy: .private)")
            } else {
                BridgeyLog.line(BridgeyLog.notifications, LogLines.notification(BridgeyLog.policy, event: "code_shown", appName: payload.applicationName))
            }
        }
        if shouldAutoCopyCode(enabled: settings.codesAutoCopy, screenLocked: macScreenIsLocked(), idleSeconds: macIdleSeconds()) {
            copyCode(reference: card.id, automatic: true)
        }
    }

    /// Codes stay in memory for ten minutes (the panel card's life); the newest five can be copied.
    private func rememberCode(_ card: LiveCodeCard) {
        liveCodes[card.id] = card
        liveCodeOrder.append(card.id)
        while liveCodeOrder.count > 5 { liveCodes.removeValue(forKey: liveCodeOrder.removeFirst()) }
        liveCode = card
        let expiry = DispatchWorkItem { [weak self] in self?.expireCode(card.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + liveCodeLifetime, execute: expiry)
    }

    private func expireCode(_ reference: String) {
        liveCodes.removeValue(forKey: reference)
        liveCodeOrder.removeAll { $0 == reference }
        if liveCode?.id == reference { liveCode = nil }
    }

    /// Copy code (banner, button or panel card): concealed, this Mac only, cleared after 60 s if unchanged.
    func copyCode(reference: String, automatic: Bool = false) {
        guard let card = liveCodes[reference] else { return }
        codeClipboard.copy(card.code)
        var copied = card
        copied.copiedAt = Date()
        copied.copiedAutomatically = automatic
        liveCodes[reference] = copied
        if liveCode?.id == reference { liveCode = copied }
        diagnostics.record(category: "notification", event: automatic ? "code_copied_auto" : "code_copied")
    }

    /// The panel card's Dismiss: the card goes; the notification and the copy stay as they are.
    func dismissLiveCode() {
        liveCode = nil
    }

    /// Settings > Notifications > Link this phone to the Mac: asks the selected phone to start the
    /// companion link (it shows a notification to tap, then Android's own dialog).
    func requestCompanionLink() {
        guard let current = session, let link = registry.state(for: current.remoteDeviceID), link.remoteSmsCodes else {
            codeLinkStatus = L10n.text("codes.link.unsupported", fallback: "Update Bridgey on the phone to link it.")
            return
        }
        if sendQuickPayload(kind: "codes.link_request", payload: ["version": 1], to: current) {
            let line = L10n.text("codes.link.requested", fallback: "On the phone, tap the Bridgey notification, then Allow.")
            codeLinkStatus = line
            // The phone's notification times out after five minutes; so does this hint.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60) { [weak self] in
                if self?.codeLinkStatus == line { self?.codeLinkStatus = nil }
            }
        }
    }

    // MARK: Mac actions (draft mac_actions_draft1)

    /// actions.catalog to one phone, when Mac actions is on and granted here and on there.
    private func sendActionsCatalog(to current: Session) {
        guard registry.isActive(current), isFeatureAvailable(.macActions, for: current.remoteDeviceID) else { return }
        _ = sendQuickPayload(kind: "actions.catalog", payload: macActions.catalogPayload(), to: current)
    }

    /// The list, a switch, a grant or Accessibility changed: every phone that may use it hears.
    func sendActionsCatalogs() {
        for (_, current) in registry.broadcastTargets({ id, _ in self.isFeatureAvailable(.macActions, for: id) }) {
            sendActionsCatalog(to: current)
        }
    }

    /// actions.run from a phone: decrypted and replay-checked here, everything else in the host.
    private func receiveActionsMessage(_ message: PairingMessage, in current: Session) {
        guard message.kind == "actions.run", registry.isActive(current), message.sessionId == current.id,
              let key = current.pairingKey, let id = message.messageId, current.acceptMessageID(id),
              let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key),
              // Strict JSON at most 1 KiB, as the phone writes it (docs/protocol-contract.md).
              let run = MacActionRun.decode(data) else { return }
        macActions.receive(run, deviceID: current.remoteDeviceID, deviceName: current.peerName)
    }

    /// Menu bar panel > Link > Send current browser tab: Safari or Chrome's front tab to the selected phone.
    func sendBrowserTab() {
        guard isFeatureAvailable(.links) else {
            quickActionsStatus(L10n.text("browser.unavailable", fallback: "Web links are unavailable on one of your devices"))
            return
        }
        browserTab.currentTab { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(link): self.quickActions.sendLink(link)
            case .failure(.noBrowser):
                self.quickActionsStatus(L10n.text("browser.none", fallback: "Open Safari or Chrome first"))
            case .failure(.noTab):
                self.quickActionsStatus(L10n.text("browser.noTab", fallback: "The front browser tab has no web address"))
            case .failure(.automation):
                self.quickActionsStatus(L10n.text("browser.automation", fallback: "Allow Bridgey to control the browser in System Settings > Privacy & Security > Automation"))
            }
        }
    }

    private func quickActionsStatus(_ text: String) { quickActions.showStatus(text) }

    // MARK: Update all (draft updates_draft1)

    /// A phone's features.update showed `updates_draft1`: send it this Mac's status now.
    var updatesPeerReady: (_ deviceID: String) -> Void = { _ in }
    /// A phone's `updates.status` (also kept in its link state).
    var updatesStatusReceived: (_ deviceID: String, _ status: PeerUpdateStatus) -> Void = { _, _ in }
    /// A phone asks this Mac to update itself. Returns the answer this Mac sends.
    var updatesStartReceived: (_ deviceID: String, _ request: UpdateStartRequest) -> UpdateStartResult = { _, request in
        UpdateStartResult(requestID: request.requestID, refusal: .manual)
    }
    /// A phone answered this Mac's `updates.start`.
    var updatesResultReceived: (_ deviceID: String, _ result: UpdateStartResult) -> Void = { _, _ in }
    var updatesPhoneDisconnected: (_ deviceID: String) -> Void = { _ in }

    /// The phone advertised `updates_draft1` in its latest map (this Mac always does).
    func phoneSupportsUpdates(_ deviceID: String) -> Bool { registry.state(for: deviceID)?.remoteUpdates == true }

    /// `updates.status` to one phone, only while its latest map shows the key.
    @discardableResult
    func sendUpdatesStatus(_ status: PeerUpdateStatus, to deviceID: String) -> Bool {
        guard phoneSupportsUpdates(deviceID), let current = registry.session(for: deviceID) else { return false }
        return sendQuickPayload(kind: "updates.status", payload: status.payload, to: current)
    }

    /// `updates.start` to one phone (Update all, or Retry for that phone).
    @discardableResult
    func sendUpdatesStart(_ request: UpdateStartRequest, to deviceID: String) -> Bool {
        guard phoneSupportsUpdates(deviceID), let current = registry.session(for: deviceID) else { return false }
        return sendQuickPayload(kind: "updates.start", payload: request.payload, to: current)
    }

    /// The Update all messages: decrypted, replay-checked and bounded; a malformed one is dropped and the
    /// session stays. A start from a phone whose map does not show the key is dropped without an answer.
    private func receiveUpdatesMessage(_ message: PairingMessage, in current: Session) {
        guard registry.isActive(current), message.sessionId == current.id,
              let key = current.pairingKey, let id = message.messageId, current.acceptMessageID(id),
              let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { return }
        let phoneID = current.remoteDeviceID
        guard phoneSupportsUpdates(phoneID) else { return }
        switch message.kind {
        case "updates.status":
            guard let status = PeerUpdateStatus.decode(data) else { return }
            registry.update(phoneID) { $0.updateStatus = status }
            publish()
            updatesStatusReceived(phoneID, status)
        case "updates.start":
            guard let request = UpdateStartRequest.decode(data) else { return }
            let answer = updatesStartReceived(phoneID, request)
            diagnostics.record(category: "updates", event: "start_received", outcome: answer.refusal?.rawValue ?? "accepted", device: phoneID)
            _ = sendQuickPayload(kind: "updates.result", payload: answer.payload, to: current)
        default:
            guard let result = UpdateStartResult.decode(data) else { return }
            updatesResultReceived(phoneID, result)
        }
    }

    /// focus.state from a phone: its Do Not Disturb, applied only when Follow is on here.
    private func receiveFocusState(_ message: PairingMessage, in current: Session) {
        guard registry.isActive(current), message.sessionId == current.id,
              let key = current.pairingKey, let id = message.messageId, current.acceptMessageID(id),
              let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key),
              let active = decodeFocusState(data) else { return }
        focusSync.received(active: active, from: current.remoteDeviceID)
    }

    /// Settings sync's transport, names, permission checks, activity item and banner.
    private func wireSettingsSync() {
        settingsSync.send = { [weak self] id, kind, payload, messageID in
            guard let self, let current = self.registry.session(for: id), self.registry.isActive(current), let key = current.pairingKey,
                  let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= SettingsSyncLimits.payloadBytes,
                  let encrypted = try? encrypt(data, key: key) else { return false }
            current.send(PairingMessage(kind: kind, sessionId: current.id, messageId: messageID, nonce: encrypted.nonce, ciphertext: encrypted.ciphertext))
            return true
        }
        settingsSync.remoteEnabled = { [weak self] id in self?.registry.state(for: id)?.remoteSettingsSync == true }
        settingsSync.connectedPhones = { [weak self] in self?.registry.connectedIDs ?? [] }
        settingsSync.peerName = { [weak self] id in self?.settingsSyncPeerName(id) ?? "" }
        // Permissions are never granted remotely: a synced feature that is on here but lacks one waits.
        // Focus sharing needs no permission on the Mac (the Focus filter and the Shortcuts action report it).
        settingsSync.lacksPermission = { [weak self] key in
            guard let self else { return false }
            switch key {
            case .featureNotifications: return !self.notificationsAuthorized
            case .featureRemoteInput: return !self.remoteInput.accessibilityTrusted
            case .codesEnabled: return self.codesSyncGate.pending
            default: return false
            }
        }
        settingsSync.onSwitchChange = { [weak self] in self?.sendFeatureState() }
        codesSyncGate.onChange = { [weak self] in self?.settingsSync.permissionsChanged() }
        settingsSync.onQuestionsChange = { [weak self] in
            guard let self else { return }
            self.syncQuestionWindows.update(questions: self.settingsSync.questions, name: { [weak self] in self?.settingsSyncPeerName($0) ?? "" },
                                            reduceMotion: self.settings.reduceMotion) { [weak self] id, use in self?.settingsSync.answer(id, use: use) }
        }
        settings.$codesEnabled
            .sink { [weak self] on in self?.codesSyncGate.codesChanged(on: on) }
            .store(in: &settingsSyncCancellables)
        settingsSync.onApplied = { [weak self] id, content in
            guard let self else { return }
            self.recordActivity(.settingsSynced, deviceID: id, deviceName: self.settingsSyncPeerName(id), content: content)
        }
        settingsSync.onTurnedOn = { [weak self] id, key, waiting in
            guard let self else { return }
            let content = UNMutableNotificationContent()
            content.title = String(format: L10n.text("sync.banner.title", fallback: "%1$@ turned on from %2$@"), key.name, self.settingsSyncPeerName(id))
            content.body = waiting
                ? L10n.text("sync.banner.waiting", fallback: "Needs permission on this Mac: open Settings to allow it.")
                : L10n.text("sync.banner.body", fallback: "Turn it off in Settings if you did not expect it.")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bridgey.settings-sync.\(key.rawValue)", content: content, trigger: nil))
        }
        settingsSync.onEvent = { [weak self] event, outcome, id in
            self?.diagnostics.record(category: "settings_sync", event: event, outcome: outcome ?? "ok", device: id)
        }
        Publishers.Merge($notificationsAuthorized.map { _ in () }, remoteInput.$accessibilityTrusted.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsSync.permissionsChanged() }
            .store(in: &settingsSyncCancellables)
        // Permissions change in System Settings: check again whenever Bridgey comes to the front.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshNotificationAuthorization()
                self.remoteInput.refreshAccessibility()
                self.settingsSync.permissionsChanged()
            }
            .store(in: &settingsSyncCancellables)
    }

    private func settingsSyncPeerName(_ id: String) -> String {
        registry.connections.first { $0.id == id }?.name ?? trustedDevices.first { $0.id == id }?.name ?? ""
    }

    /// settings.* from a phone: replay-checked and decrypted here (a payload that does not decrypt closes
    /// the session, docs/protocol-contract.md rule 8); the controller checks limits and the rules.
    private func receiveSettingsMessage(_ message: PairingMessage, in current: Session) throws {
        guard registry.isActive(current), message.sessionId == current.id, let key = current.pairingKey,
              let id = message.messageId, current.acceptMessageID(id) else { return }
        guard let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { throw PairingError.invalidMessage }
        let limit = message.kind == SettingsSyncKinds.snapshot || message.kind == SettingsSyncKinds.update
            ? SettingsSyncLimits.payloadBytes : SettingsSyncLimits.replyBytes
        // An oversized snapshot or update is answered invalid_message by the decoder; an oversized reply is dropped.
        guard data.count <= limit || limit == SettingsSyncLimits.payloadBytes else { return }
        settingsSync.receive(kind: message.kind, messageID: id, plaintext: data, from: current.remoteDeviceID)
    }

    /// camera.status from a phone, for this Mac's open request.
    private func receiveCameraStatus(_ message: PairingMessage, in current: Session) {
        guard registry.isActive(current), message.sessionId == current.id,
              let key = current.pairingKey, let id = message.messageId, current.acceptMessageID(id),
              let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key),
              let decoded = decodeCameraStatus(data) else { return }
        camera.received(status: decoded.status.rawValue, requestID: decoded.requestID, from: current.remoteDeviceID, phoneName: current.peerName)
    }

    /// The phone takes photos for this Mac and Files is on for it.
    func cameraAvailable(for id: String) -> Bool {
        registry.state(for: id)?.remoteCamera == true && isFeatureAvailable(.files, for: id)
    }

    /// Panel > File > Take Photo with [phone], or the Shortcuts action: the request ID, if sent.
    @discardableResult
    func takePhoto(with id: String? = nil) -> String? {
        guard let target = id ?? registry.target(selected: selectedDeviceID), cameraAvailable(for: target) else { return nil }
        return camera.request(from: target, phoneName: intentName(target))
    }

    // MARK: Shortcuts and Siri (App Intents)

    /// Paired phones for the Shortcuts phone picker.
    func intentPhones() -> [PhoneEntity] {
        trustedDevices.map { PhoneEntity(id: $0.id, name: $0.name) }
    }

    /// The connected phone an intent aims at: the named one, else the panel's selection.
    func intentTarget(_ id: String?) -> String? {
        if let id { return registry.session(for: id) != nil ? id : nil }
        return registry.target(selected: selectedDeviceID)
    }

    func intentName(_ id: String) -> String {
        connectedPhones.first { $0.id == id }?.name ?? trustedName(id)
    }

    func intentBattery(for id: String) -> PhoneBatteryEntity? {
        guard isFeatureAvailable(.battery, for: id), let battery = registry.state(for: id)?.battery else { return nil }
        return PhoneBatteryEntity(id: id, phone: intentName(id), level: battery.level, charging: battery.isCharging)
    }

    /// Runs a single-phone action aimed at `id`, then puts the panel's selection back. The panel
    /// keeps its link card: a temporary target change does not reset quick actions.
    @discardableResult
    func withIntentTarget<T>(_ id: String, _ body: () -> T) -> T {
        let previous = selectedDeviceID
        let previousTarget = publishedTarget
        selectedDeviceID = id
        publishedTarget = registry.target(selected: id)
        publish()
        let result = body()
        selectedDeviceID = previous
        publishedTarget = previousTarget
        publish()
        return result
    }

    /// Send text to phone: the phone's clipboard, without touching this Mac's pasteboard.
    func sendText(_ text: String, to id: String) -> Bool {
        guard let current = registry.session(for: id), registry.isActive(current), isFeatureAvailable(.clipboard, for: id),
              !text.isEmpty, clipboardTextFits(text) else { return false }
        sendClipboardContent(text: text, html: nil, concealed: false, automatic: false, in: current)
        return true
    }

    // MARK: Connection health

    /// Reset > Activity and logs: round trips, the last disconnect and today's reconnects go; whether each
    /// phone is connected now, its route and who dialled stay.
    func clearConnectionHealth() {
        for id in healthRecords.keys {
            healthRecords[id]?.roundTrips = HeartbeatRoundTrips()
            healthRecords[id]?.lastDropReason = nil
            healthRecords[id]?.lastDropAt = nil
            healthRecords[id]?.reconnects = DailyCounter()
        }
        publishHealth()
    }

    func healthSnapshot(for id: String) -> ConnectionHealthSnapshot {
        ConnectionHealthSnapshot(
            deviceID: id, record: healthRecords[id], connected: registry.session(for: id) != nil,
            discoveryVisible: lastPeers.contains { $0.deviceIDHint == id }, discovery: discoveryHealth(), now: Date()
        )
    }

    private func publishHealth() {
        var snapshots: [String: ConnectionHealthSnapshot] = [:]
        for id in trustedDeviceIDs { snapshots[id] = healthSnapshot(for: id) }
        if snapshots != connectionHealth { connectionHealth = snapshots }
    }

    /// codes.* (sms_codes_draft1): code access reports and the companion link's advertising.
    private func receiveCodesMessage(_ message: PairingMessage, in current: Session) {
        guard registry.isActive(current), message.sessionId == current.id,
              let key = current.pairingKey, let id = message.messageId, current.acceptMessageID(id),
              let nonce = message.nonce, let ciphertext = message.ciphertext,
              let data = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key), data.count <= 1024,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              payload["version"] as? Int == 1 else { return }
        let phoneID = current.remoteDeviceID
        switch message.kind {
        case "codes.status":
            guard let wire = payload["status"] as? String, let status = CodeAccessStatus(wire: wire) else { return }
            registry.update(phoneID) { $0.codeAccess = status }
            if status == .allowed { codeLinkStatus = nil }
            publish()
        case "codes.advertise":
            guard settings.isEnabled(.notifications, for: phoneID),
                  let raw = payload["serviceUuid"] as? String, let uuid = UUID(uuidString: raw) else { return }
            let waiting = L10n.text("codes.link.advertising", fallback: "Waiting for the phone. Tap Allow there.")
            codeLinkStatus = waiting
            DispatchQueue.main.asyncAfter(deadline: .now() + CompanionLinkAdvertiser.duration + 30) { [weak self] in
                if self?.codeLinkStatus == waiting { self?.codeLinkStatus = nil }
            }
            companionAdvertiser.start(uuid: uuid, localName: "Bridgey") { [weak self, weak current] failure in
                guard let self, let current else { return }
                var reply: [String: Any] = ["version": 1, "serviceUuid": raw, "ok": failure == nil]
                if let failure {
                    reply["reason"] = failure.rawValue
                    self.codeLinkStatus = companionAdvertiseFailureText(failure)
                }
                _ = self.sendQuickPayload(kind: "codes.advertise_result", payload: reply, to: current)
            }
        case "codes.advertise_stop":
            guard let raw = payload["serviceUuid"] as? String, let uuid = UUID(uuidString: raw) else { return }
            companionAdvertiser.stop(uuid: uuid)
            // Linked, cancelled or failed: the phone shows what happened; the row goes back to the status.
            codeLinkStatus = nil
        default:
            break
        }
    }

    /// Code access for Settings: the selected phone's report, or why there is none.
    var codeAccessForSelectedPhone: CodeAccessDisplay {
        guard let current = session, let link = registry.state(for: current.remoteDeviceID) else { return .noPhone }
        guard link.remoteSmsCodes else { return .phoneTooOld }
        return link.codeAccess.map(CodeAccessDisplay.status) ?? .waiting
    }

    func performRemoteCallAction(_ action: RemoteCallAction) {
        guard let call = remoteCall else { return }
        // Answering or declining from the Mac stops the ring right away; the phone confirms the rest.
        silencedCallIdentities.insert(callOverlayIdentity(call.notificationID, deviceID: call.deviceID))
        logCall("action", call, reason: String(describing: callActionRole(action.title)))
        refreshCallRinging()
        performAndroidNotificationAction(
            call.notificationID,
            deviceID: call.deviceID,
            actionToken: action.id,
            replyText: nil
        )
    }

    /// Hide is the only way the call card leaves the screen before the call ends; the menu bar
    /// panel keeps the call. Hiding also stops the ring for that call.
    func hideCallOverlay() {
        if let call = remoteCall {
            let identity = callOverlayIdentity(call.notificationID, deviceID: call.deviceID)
            hiddenCallOverlayIdentities.insert(identity)
            silencedCallIdentities.insert(identity)
            logCall("overlay_hidden", call, reason: "user")
        }
        callOverlayWindow.hide()
        refreshCallRinging()
    }

    /// Settings > Calls > Ring for incoming calls changed.
    func refreshCallRinging() {
        let ringing = ringingRemoteCallIdentities(
            activeRemoteCalls.all,
            enabled: settings.ringForIncomingCalls,
            silenced: silencedCallIdentities
        ) { self.callOverlayIdentity($0.notificationID, deviceID: $0.deviceID) }
        callRinger.update(ringing: !ringing.isEmpty)
    }

    private func updateRemoteCall(_ payload: RemoteNotificationPayload, deviceID: String) {
        guard let callType = normalizedRemoteCallType(payload.callType) else { return }
        let identity = callOverlayIdentity(payload.notificationId, deviceID: deviceID)
        clearCallStatus()
        let actions = (payload.actions ?? []).filter { !$0.allowsReply }.prefix(4).map {
            RemoteCallAction(id: $0.actionToken, title: $0.title)
        }
        let previousType = activeRemoteCalls.all.first {
            $0.deviceID == deviceID && $0.notificationID == payload.notificationId
        }?.type
        let resumed = activeRemoteCalls.update(RemoteCallStatus(
            notificationID: payload.notificationId,
            deviceID: deviceID,
            applicationName: payload.applicationName,
            caller: payload.title,
            detail: remoteCallDetail(payload.text, type: callType),
            type: callType,
            actions: actions
        ))
        if resumed {
            logCall("removal_cancelled", notificationID: payload.notificationId, deviceID: deviceID, reason: "reposted")
        }
        if previousType != callType {
            logCall(
                previousType == nil ? "shown" : "state",
                notificationID: payload.notificationId, deviceID: deviceID, reason: callType, caller: payload.title
            )
        }
        publishRemoteCall()
        if !recordedCallIdentities.contains(identity) {
            recordedCallIdentities.insert(identity)
            let name = trustedDevices.first { $0.id == deviceID }?.name ?? session?.peerName ?? ""
            let caller = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            recordActivity(.callShown, deviceID: deviceID, deviceName: name, preview: caller.isEmpty ? nil : caller)
        }
        // With ringing off, an incoming call still beeps once (the ring itself is in refreshCallRinging).
        if callType == "incoming", !settings.ringForIncomingCalls, !audibleCallIdentities.contains(identity) {
            NSSound.beep()
            audibleCallIdentities.insert(identity)
        }
    }

    /// Only call events reach this: an ordinary notification never shows, hides or moves the card.
    private func publishRemoteCall() {
        remoteCall = activeRemoteCalls.mostRelevant
        mediaController.callChanged(active: activeRemoteCalls.pausesMedia)
        if let call = remoteCall,
           !hiddenCallOverlayIdentities.contains(callOverlayIdentity(call.notificationID, deviceID: call.deviceID)) {
            callOverlayWindow.show()
        } else {
            callOverlayWindow.hide()
        }
        refreshCallRinging()
    }

    /// Call lifecycle for the unified log and the exported diagnostics. Diagnostics get the event,
    /// reason and 8-character ids only; the local log adds the caller when Logging allows it
    /// (numbers masked unless "Include phone numbers" is on).
    private func logCall(_ event: String, notificationID: String, deviceID: String, reason: String, caller: String? = nil) {
        BridgeyLog.line(BridgeyLog.calls, LogLines.call(
            BridgeyLog.policy, event: event, id: notificationID, peer: deviceID, reason: reason, caller: caller
        ))
        diagnostics.record(category: "call", event: event, device: deviceID, detail: reason)
    }

    private func logCall(_ event: String, _ call: RemoteCallStatus, reason: String) {
        logCall(event, notificationID: call.notificationID, deviceID: call.deviceID, reason: reason)
    }

    // MARK: Activity stream

    func clearActivity() {
        activity.clear()
        clearClipboardCache()
    }

    private func pasteboardIsConcealed(_ pasteboard: NSPasteboard) -> Bool {
        clipboardTypesAreSecret((pasteboard.types ?? []).map(\.rawValue))
    }

    private func recordActivity(
        _ kind: ActivityKind,
        in current: Session,
        fileName: String? = nil,
        preview: String? = nil,
        appName: String? = nil,
        sensitive: Bool = false,
        automatic: Bool = false
    ) {
        recordActivity(
            kind, deviceID: current.remoteDeviceID, deviceName: current.peerName,
            fileName: fileName, preview: preview, appName: appName, sensitive: sensitive, automatic: automatic
        )
    }

    private func recordActivity(
        _ kind: ActivityKind,
        deviceID: String?,
        deviceName: String,
        fileName: String? = nil,
        preview: String? = nil,
        appName: String? = nil,
        sensitive: Bool = false,
        automatic: Bool = false,
        count: Int = 1,
        bytes: Int64? = nil,
        content: String? = nil
    ) {
        activity.record(
            kind,
            deviceID: deviceID?.isEmpty == false ? deviceID : nil,
            deviceName: deviceName,
            fileName: fileName,
            preview: preview,
            appName: appName,
            sensitive: sensitive,
            automatic: automatic,
            count: count,
            bytes: bytes,
            content: content,
            previews: settings.showActivityPreviews
        )
    }

    private func recordConnectedActivity(_ kind: ActivityKind) {
        guard case let .connected(deviceID, name) = state else { return }
        recordActivity(kind, deviceID: deviceID, deviceName: name)
    }

    func clearNotificationHistory() {
        notificationHistoryStore.clear()
        notificationHistory = []
    }

    /// With [codeShown], history keeps "Sent a one-time code" instead of the message, never the code.
    private func recordNotificationHistory(_ payload: RemoteNotificationPayload, deviceID: String, codeShown: Bool = false) {
        guard settings.notificationHistoryEnabled else { return }
        let item = NotificationHistoryItem(
            id: remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: payload.notificationId),
            packageName: String(payload.packageName.prefix(256)),
            applicationName: String(payload.applicationName.prefix(128)),
            title: String(payload.title.prefix(1_024)),
            text: codeShown ? L10n.text("codes.history", fallback: "Sent a one-time code") : String(payload.text.prefix(8_192)),
            receivedAt: Date()
        )
        notificationHistory = notificationHistoryStore.record(item, in: notificationHistory)
    }

    private func notificationIconAttachment(for payload: RemoteNotificationPayload) -> UNNotificationAttachment? {
        guard let data = remoteNotificationIconData(payload.applicationIcon) else { return nil }
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("\(Edition.supportFolderName)/NotificationIcons", isDirectory: true)
        let file = directory.appendingPathComponent(
            remoteNotificationIconFileName(packageName: payload.packageName, data: data)
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
            return try UNNotificationAttachment(
                identifier: "android-app-icon",
                url: file,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.png.identifier]
            )
        } catch {
            BridgeyLog.notifications.error("notification icon attachment failed error=\(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func notificationCategoryIdentifier(for payload: RemoteNotificationPayload, deviceID: String, copyCode: Bool = false) -> String {
        var actions = (payload.actions ?? []).prefix(4).compactMap { action -> UNNotificationAction? in
            guard action.actionToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  !action.title.isEmpty,
                  action.title.count <= 64 else { return nil }
            if action.allowsReply {
                return UNTextInputNotificationAction(
                    identifier: action.actionToken,
                    title: action.title,
                    options: [],
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Reply"
                )
            }
            return UNNotificationAction(identifier: action.actionToken, title: action.title, options: [])
        }
        if copyCode {
            actions.insert(UNNotificationAction(
                identifier: codeCopyActionIdentifier,
                title: L10n.text("codes.copy", fallback: "Copy code"),
                options: []
            ), at: 0)
        }
        guard !actions.isEmpty else { return "bridgey.android.notification" }
        let categoryID = remoteNotificationCategoryIdentifier(
            deviceID: deviceID,
            notificationID: payload.notificationId,
            actionTokens: actions.map(\.identifier)
        )
        remoteNotificationCategories[categoryID] = UNNotificationCategory(
            identifier: categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        while remoteNotificationCategories.count > 129,
              let staleID = remoteNotificationCategories.keys.first(where: { $0 != "bridgey.android.notification" }) {
            remoteNotificationCategories.removeValue(forKey: staleID)
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(remoteNotificationCategories.values))
        return categoryID
    }

    private func dismissAndroidNotification(_ notificationID: String, deviceID: String) {
        // Back to the phone the notification came from, whichever phone is selected.
        guard let current = registry.session(for: deviceID),
              featureEnabled(.notifications, current: current),
              !notificationID.isEmpty,
              notificationID.count <= 512,
              let plaintext = try? JSONEncoder().encode(NotificationReferencePayload(notificationId: notificationID)),
              let encrypted = try? encrypt(plaintext, key: current.pairingKey!) else { return }
        current.send(PairingMessage(
            kind: "notifications.dismiss",
            sessionId: current.id,
            messageId: UUID().uuidString.lowercased(),
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        ))
        diagnostics.record(category: "notification", event: "dismiss_sent")
    }

    private func performAndroidNotificationAction(
        _ notificationID: String,
        deviceID: String,
        actionToken: String,
        replyText: String?
    ) {
        guard let current = registry.session(for: deviceID),
              featureEnabled(.notifications, current: current),
              !notificationID.isEmpty,
              notificationID.count <= 512,
              actionToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (replyText?.count ?? 0) <= 4_096,
              let plaintext = try? JSONEncoder().encode(NotificationActionCommandPayload(
                notificationId: notificationID,
                actionToken: actionToken,
                replyText: replyText
              )),
              let encrypted = try? encrypt(plaintext, key: current.pairingKey!) else { return }
        current.send(PairingMessage(
            kind: "notifications.action",
            sessionId: current.id,
            messageId: UUID().uuidString.lowercased(),
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext
        ))
        diagnostics.record(category: "notification", event: replyText == nil ? "action_sent" : "reply_sent")
    }

    private func receiveNotificationReference(_ message: PairingMessage, in current: Session) throws -> NotificationReferencePayload? {
        guard registry.isActive(current),
              message.sessionId == current.id,
              let messageID = message.messageId,
              current.acceptMessageID(messageID),
              let nonce = message.nonce,
              let ciphertext = message.ciphertext,
              let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
              let payload = try? JSONDecoder().decode(NotificationReferencePayload.self, from: plaintext),
              !payload.notificationId.isEmpty,
              payload.notificationId.count <= 512 else {
            throw PairingError.invalidMessage
        }
        return payload
    }

    /// A call card is persistent: a retraction the phone did not mark as the call's end keeps the
    /// card for `remoteCallRemovalGrace`, and a re-post of the call meanwhile keeps it for good.
    private func removeRemoteNotification(_ notificationID: String, deviceID: String, callEnded: Bool = false) {
        if activeRemoteCalls.contains(notificationID: notificationID, deviceID: deviceID) {
            if !callEnded {
                if !activeRemoteCalls.isPendingRemoval(notificationID: notificationID, deviceID: deviceID) {
                    activeRemoteCalls.scheduleRemoval(
                        notificationID: notificationID,
                        deviceID: deviceID,
                        deadline: Date().addingTimeInterval(remoteCallRemovalGrace)
                    )
                    logCall("removal_deferred", notificationID: notificationID, deviceID: deviceID, reason: "no_end_flag")
                    DispatchQueue.main.asyncAfter(deadline: .now() + remoteCallRemovalGrace + 0.05) { [weak self] in
                        self?.finishExpiredCallRemovals()
                    }
                }
                return
            }
            if let call = activeRemoteCalls.remove(notificationID: notificationID, deviceID: deviceID) {
                forgetCallIdentity(call)
                logCall("ended", call, reason: "phone_confirmed")
                publishRemoteCall()
            }
        }
        let identifier = remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: notificationID)
        codeReads.removeValue(forKey: identifier)?.cancel()
        alertedNotificationIdentifiers.remove(identifier)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        diagnostics.record(category: "notification", event: "removed_remotely")
    }

    private func finishExpiredCallRemovals() {
        let calls = activeRemoteCalls.removeExpired(now: Date())
        guard !calls.isEmpty else { return }
        for call in calls {
            forgetCallIdentity(call)
            logCall("ended", call, reason: "removal_grace")
        }
        let identifiers = calls.map {
            remoteNotificationRequestIdentifier(deviceID: $0.deviceID, notificationID: $0.notificationID)
        }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        publishRemoteCall()
    }

    private func forgetCallIdentity(_ call: RemoteCallStatus) {
        let identity = callOverlayIdentity(call.notificationID, deviceID: call.deviceID)
        hiddenCallOverlayIdentities.remove(identity)
        audibleCallIdentities.remove(identity)
        recordedCallIdentities.remove(identity)
        silencedCallIdentities.remove(identity)
    }

    /// One phone's calls go when it disconnects or turns notifications off; the others stay.
    private func clearRemoteCall(for id: String, reason: String) {
        let calls = activeRemoteCalls.removeAll(deviceID: id)
        guard !calls.isEmpty else { return }
        for call in calls {
            forgetCallIdentity(call)
            logCall("cleared", call, reason: reason)
        }
        let identifiers = calls.map {
            remoteNotificationRequestIdentifier(deviceID: $0.deviceID, notificationID: $0.notificationID)
        }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        publishRemoteCall()
    }

    private func clearRemoteCall() {
        mediaController.callChanged(active: false)
        let calls = activeRemoteCalls.removeAll()
        remoteCall = nil
        hiddenCallOverlayIdentities.removeAll()
        audibleCallIdentities.removeAll()
        recordedCallIdentities.removeAll()
        silencedCallIdentities.removeAll()
        callRinger.update(ringing: false)
        guard !calls.isEmpty else { return }
        callOverlayWindow.hide()
        let identifiers = calls.map {
            remoteNotificationRequestIdentifier(deviceID: $0.deviceID, notificationID: $0.notificationID)
        }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func callOverlayIdentity(_ notificationID: String, deviceID: String) -> String {
        "\(deviceID)\u{0}\(notificationID)"
    }

    private func saveTrust(_ current: Session) {
        guard let identityKey = current.remoteIdentityKey else { return }
        if trustRegistry.remember(
            deviceID: current.remoteDeviceID,
            name: current.peerName,
            identityKey: identityKey
        ) {
            trustedDeviceIDs.insert(current.remoteDeviceID)
            recordActivity(.paired, in: current)
        }
    }

}

// MARK: - Folders (Files 2.0)

extension PairingCoordinator: FolderSenderHost {
    /// folders.* and places.* (draft): checked like other encrypted messages, then handed to the folder
    /// sender. A payload that does not decrypt closes the session; one that decrypts but is invalid is ignored.
    fileprivate func receiveFolderMessage(_ message: PairingMessage, in current: Session) throws {
        guard registry.isActive(current), message.sessionId == current.id else { return }
        let phoneID = current.remoteDeviceID
        // This Mac advertises folders only while Files is on for the phone. A folder offered meanwhile gets the
        // outer-only folders.rejected (no decryption), then the features again; a running folder may finish.
        let running = message.transferId.map { folderReceiver.owns($0) || folders.owns($0) } ?? false
        guard settings.isEnabled(.files, for: phoneID) || (running && message.kind != FolderKind.offer) else {
            if message.kind == FolderKind.offer, let id = message.transferId, FolderJSON.isWireID(id) {
                current.send(PairingMessage(kind: FolderKind.rejected, sessionId: current.id, transferId: id))
                sendFeatureState(to: current)
            }
            return
        }
        guard let ciphertext = message.ciphertext else {
            if folderReceiver.receive(kind: message.kind, payload: nil, outerTransferID: message.transferId, from: phoneID) { return }
            folders.receive(kind: message.kind, payload: nil, outerTransferID: message.transferId, from: phoneID)
            return
        }
        guard let messageID = message.messageId, current.acceptMessageID(messageID),
              let nonce = message.nonce, let key = current.pairingKey else { return }
        guard let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { throw PairingError.invalidMessage }
        guard plaintext.count <= FolderKind.plaintextLimit(message.kind) else { return }
        // Browse answers (places.listed for browsing, places.error) go to the browse client first.
        if FolderKind.placesKinds.contains(message.kind), phoneFilesController.handle(kind: message.kind, payload: plaintext, from: phoneID) { return }
        // Folders coming to this Mac (phone to Mac, downloads).
        if FolderKind.folderKinds.contains(message.kind), folderReceiver.receive(kind: message.kind, payload: plaintext, outerTransferID: message.transferId, from: phoneID) { return }
        folders.receive(kind: message.kind, payload: plaintext, outerTransferID: message.transferId, from: phoneID)
    }

    /// Answers to this Mac's browse requests (draft): checked like other encrypted messages.
    fileprivate func receiveBrowseMessage(_ message: PairingMessage, in current: Session) throws {
        guard registry.isActive(current), message.sessionId == current.id, let ciphertext = message.ciphertext,
              let messageID = message.messageId, current.acceptMessageID(messageID),
              let nonce = message.nonce, let key = current.pairingKey else { return }
        guard let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else { throw PairingError.invalidMessage }
        guard plaintext.count <= BrowseKind.plaintextLimit(message.kind) else { return }
        phoneFilesController.handle(kind: message.kind, payload: plaintext, from: current.remoteDeviceID)
    }

    func folderTransport(for phoneID: String) -> (transport: FolderTransport, session: ObjectIdentifier)? {
        guard let current = registry.session(for: phoneID), let key = current.pairingKey, !current.ended else { return nil }
        return (SessionFolderTransport(session: current, key: key), ObjectIdentifier(current))
    }

    func folderSupport(for phoneID: String) -> (folders: Bool, places: Bool)? {
        guard let link = registry.state(for: phoneID), link.featureStateReceived, isFeatureAvailable(.files, for: phoneID) else { return nil }
        return (link.remoteFolders, link.remoteFolders && link.remotePlaces)
    }

    func phoneName(_ phoneID: String) -> String {
        registry.connections.first { $0.id == phoneID }?.name ?? trustedName(phoneID)
    }

    func folderRowChanged(_ row: FileTransferRow) {
        fileTransfers[row.id] = row
        pruneTransferHistory()
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
    }

    func folderRowRemoved(_ id: String) {
        fileTransfers.removeValue(forKey: id)
        transferDevices.removeValue(forKey: id)
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
    }

    func enqueueFolder(_ id: String, phoneID: String) {
        transferDevices[id] = phoneID
        var queue = fileSendQueues[phoneID] ?? FileSendQueue<OutgoingQueueItem>()
        queue.enqueue(id: id, item: .folder)
        fileSendQueues[phoneID] = queue
        startNextQueuedFile(for: phoneID)
    }

    func folderEnded(_ id: String) {
        if let phoneID = transferDevices[id] { refreshPhoneFreeSpace(phoneID) }
        finishQueuedFile(id)
    }

    func folderStatus(_ text: String) {
        fileTransferStatus = text
    }

    func recordFolderActivity(_ kind: ActivityKind, phoneID: String, name: String, fileCount: Int, bytes: Int64, destination: String?, detail: FolderActivityDetail) {
        activity.record(
            kind, deviceID: phoneID, deviceName: phoneName(phoneID), fileName: name, bytes: bytes, content: detail.encoded,
            fileCount: fileCount, destination: destination, previews: settings.showActivityPreviews
        )
    }

    var folderReduceMotion: Bool { settings.reduceMotion }
    var folderScanDefaults: FolderScanOptions { settings.folderScanOptions }
}

// MARK: - Folders to this Mac (Files 2.0 browse)

extension PairingCoordinator: FolderReceiverHost {
    var folderReceiveMode: MacFolderReceiveMode { settings.folderReceiveMode }
    var folderConflictPolicy: MacFolderConflictPolicy { settings.folderConflictPolicy }
    var tagsReceivedFiles: Bool { settings.tagReceivedFiles }
    func receiveDirectoryAccess() -> ReceiveDirectoryAccess { settings.receiveDirectoryAccess() }
    func recordHistory(_ entry: TransferHistoryEntry) { transferHistory.record(entry) }

    func receivedItems(_ urls: [URL], phoneID: String, purpose: PhoneDownloadPurpose?) {
        // Previews are private; a Finder drop is already where the user put it.
        guard purpose != .preview, purpose != .dragOut, !urls.isEmpty else { return }
        // Pushed folders fall back to revealing in Finder; downloads from the Phone files window keep their row.
        announceReceived(urls.map { ReceivedItem(url: $0, isFolder: $0.hasDirectoryPath) }, phoneID: phoneID, revealIfSilent: purpose == nil)
    }

    /// A notification with Open and Show in Finder while macOS allows Bridgey's notifications; otherwise the
    /// old behaviour, revealing the item in Finder.
    func announceReceived(_ items: [ReceivedItem], phoneID: String, revealIfSilent: Bool) {
        if notificationsAuthorized {
            receivedNotifier.post(items, phoneID: phoneID, phoneName: phoneName(phoneID))
        } else if revealIfSilent {
            NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
        }
    }
}

private struct FolderFileProbe: Decodable {
    let folderTransferId: String?
}

// MARK: - Phone files (Files 2.0 browse)

extension PairingCoordinator: PhoneFilesHost {
    func browseTransport(for phoneID: String) -> FolderTransport? { folderTransport(for: phoneID)?.transport }

    func browsePhones() -> [BrowsablePhone] {
        registry.connections.map { phone in
            let link = registry.state(for: phone.id)
            let browsable = link?.featureStateReceived == true && link?.remoteBrowse == true && isFeatureAvailable(.files, for: phone.id)
            return BrowsablePhone(id: phone.id, name: phone.name, browsable: browsable,
                                  route: PhoneRouteClassifier.route(host: registry.session(for: phone.id)?.remoteHost))
        }
    }

    func expectDownload(_ download: ExpectedDownload) {
        folderReceiver.expect(download)
    }

    func cancelDownload(_ download: ExpectedDownload) {
        folderReceiver.cancelExpected(download)
    }

    func startUpload(_ upload: UploadRequest) -> String? {
        folders.upload(upload)
    }

    func cancelUpload(_ id: String) {
        folders.cancel(id)
    }
}

/// Folder messages to one phone over the session they started on. Safe from any queue: it only encrypts
/// and hands the frame to the connection.
private final class SessionFolderTransport: SequencedFolderTransport {
    private let session: Session
    private let key: Data

    init(session: Session, key: Data) {
        self.session = session
        self.key = key
    }

    @discardableResult
    func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
        guard let sealed = try? encrypt(payload, key: key) else { return false }
        session.send(PairingMessage(
            kind: kind,
            sessionId: session.id,
            messageId: UUID().uuidString.lowercased(),
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            transferId: transferID,
            sequence: sequence
        ))
        return true
    }

    func sendOuter(kind: String, transferID: String) {
        session.send(PairingMessage(kind: kind, sessionId: session.id, transferId: transferID))
    }

    func sendOuterSequenced(kind: String, transferID: String, sequence: Int64) {
        session.send(PairingMessage(kind: kind, sessionId: session.id, transferId: transferID, sequence: sequence))
    }
}

private final class Session {
    let connection: NWConnection
    var peerName: String
    var remoteDeviceID = ""
    var remoteIdentityKey: String?
    var initiatedLocally = false
    var localEphemeralKey = ""
    var remoteEphemeralKey = ""
    var id = ""
    var privateKey: P256.KeyAgreement.PrivateKey?
    var code: String?
    var pairingKey: Data?
    var localConfirmed = false
    var remoteConfirmed = false
    /// Authenticated and registered as its phone's session.
    var authenticated = false
    /// onFailure ran (or the session was closed on purpose): ignore later callbacks.
    var ended = false
    /// Why the session ended, for the pairing flow.
    var failure: PairingFailure?
    /// A reconnect to this trusted phone (no prompt); nil for pairings and incoming sessions.
    var dialDeviceID: String?
    /// The dial no longer counts as in flight.
    var dialFinished = false
    var endpoint: (host: String, port: Int, name: String)?
    /// The phone's address: where this Mac dialled, or where the phone connected from.
    var remoteHost: String?
    /// Why the socket ended, for logs and diagnostics ("reset_by_peer", "heartbeat_timeout").
    var dropReason: String?
    let createdAt = Date()
    var connectionTimeout: DispatchWorkItem?
    var heartbeat: DispatchWorkItem?
    var lastReceivedAt = Date()
    var heartbeatSupported = false
    var onMessage: ((PairingMessage) -> Void)?
    var onFailure: (() -> Void)?
    private var frames = ProtocolFrameReader()
    private var seenMessageIDs = ReplayWindow()
    var quickSequence = QuickRequestSequence()

    init(connection: NWConnection, peerName: String) {
        self.connection = connection
        self.peerName = peerName
    }

    func send(_ message: PairingMessage) {
        guard let encoded = try? JSONEncoder().encode(message) else { return }
        connection.send(content: encoded + Data([0x0A]), completion: .contentProcessed { error in
            if let error { BridgeyLog.transport.error("send failed kind=\(message.kind, privacy: .public) error=\(String(describing: error), privacy: .public)") }
        })
    }

    func sendAndWait(_ message: PairingMessage) -> Bool {
        guard let encoded = try? JSONEncoder().encode(message) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        connection.send(content: encoded + Data([0x0A]), completion: .contentProcessed { error in
            succeeded = error == nil
            if let error { BridgeyLog.transport.error("send failed kind=\(message.kind, privacy: .public) error=\(String(describing: error), privacy: .public)") }
            semaphore.signal()
        })
        return semaphore.wait(timeout: .now() + 15) == .success && succeeded
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data { self.frames.append(data) }
                while true {
                    do {
                        guard let message = try self.frames.next() else { break }
                        self.lastReceivedAt = Date()
                        self.onMessage?(message)
                    } catch {
                        BridgeyLog.transport.error("invalid message error=\(String(describing: error), privacy: .public)")
                        self.dropReason = self.frames.overLimit ? "frame_too_large" : "protocol_error"
                        self.close()
                        self.onFailure?()
                        return
                    }
                }
                guard !self.frames.overLimit else {
                    BridgeyLog.transport.error("protocol frame exceeded size limit")
                    self.dropReason = "frame_too_large"
                    self.close()
                    self.onFailure?()
                    return
                }
                if complete || error != nil {
                    if self.dropReason == nil {
                        self.dropReason = error.map(connectionDropReason) ?? "closed_by_peer"
                    }
                    self.onFailure?()
                } else {
                    self.receive()
                }
            }
        }
    }

    func close() { connection.cancel() }

    func acceptMessageID(_ id: String) -> Bool { seenMessageIDs.accept(id) }
}

struct PairingMessage: Codable {
    let kind: String
    let sessionId: String
    var deviceId: String? = nil
    var deviceName: String? = nil
    var publicKey: String? = nil
    var identityKey: String? = nil
    var proof: String? = nil
    var signature: String? = nil
    var messageId: String? = nil
    var nonce: String? = nil
    var ciphertext: String? = nil
    var transferId: String? = nil
    var sequence: Int64? = nil
    /// On a reconnect offer: the trusted device it is meant for. Any other device declines quietly.
    var targetDeviceId: String? = nil
}

enum PairingError: Error { case invalidMessage, cancelled }

private final class FileCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private final class OutgoingFileTransfer {
    private static let chunkSize = 24 * 1024
    private static let acknowledgementWindow: Int64 = 64
    let transferID: String
    let displayName: String
    let offer: FileOfferPayload
    private let url: URL
    private let lock = NSLock()
    private var cancelled = false
    private let acknowledgement = NSCondition()
    private var acknowledgedSequence: Int64 = -1
    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
        acknowledgement.lock()
        acknowledgement.broadcast()
        acknowledgement.unlock()
    }

    func acknowledge(sequence: Int64) {
        acknowledgement.lock()
        acknowledgedSequence = max(acknowledgedSequence, sequence)
        acknowledgement.broadcast()
        acknowledgement.unlock()
    }

    private func waitForAcknowledgement(sequence: Int64) throws {
        acknowledgement.lock()
        defer { acknowledgement.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while acknowledgedSequence < sequence && !isCancelled {
            if !acknowledgement.wait(until: deadline) { throw PairingError.invalidMessage }
        }
        if isCancelled { throw PairingError.cancelled }
    }

    init(url: URL, transferID: String, cancellation: FileCancellationToken) throws {
        self.url = url
        self.transferID = transferID
        displayName = url.lastPathComponent
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = Int64(values.fileSize ?? -1)
        guard size >= 0, size <= 10 * 1024 * 1024 * 1024 else { throw PairingError.invalidMessage }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            guard !cancellation.isCancelled else { throw PairingError.cancelled }
            digest.update(data: data)
        }
        offer = FileOfferPayload(
            transferId: transferID,
            name: displayName,
            mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
            size: size,
            sha256: Data(digest.finalize()).base64EncodedString()
        )
    }

    func send(
        through session: Session,
        key: Data,
        status: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (Result<PairingMessage, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handle = try FileHandle(forReadingFrom: self.url)
                defer { try? handle.close() }
                var sent: Int64 = 0
                var sequence: Int64 = 0
                let progress = MacTransferProgress(totalBytes: self.offer.size)
                while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    guard !self.isCancelled else { throw PairingError.cancelled }
                    let sealed = try Self.encrypt(chunk, key: key)
                    guard session.sendAndWait(PairingMessage(
                        kind: "files.chunk",
                        sessionId: session.id,
                        messageId: UUID().uuidString.lowercased(),
                        nonce: sealed.nonce,
                        ciphertext: sealed.ciphertext,
                        transferId: self.transferID,
                        sequence: sequence
                    )) else { throw PairingError.invalidMessage }
                    if sequence >= Self.acknowledgementWindow - 1 {
                        try self.waitForAcknowledgement(sequence: sequence - (Self.acknowledgementWindow - 1))
                    }
                    sequence += 1
                    sent += Int64(chunk.count)
                    if let detail = progress.status(transferred: sent) {
                        DispatchQueue.main.async { status("Sending \(self.displayName): \(detail)") }
                    }
                }
                if sequence > 0 { try self.waitForAcknowledgement(sequence: sequence - 1) }
                guard !self.isCancelled else { throw PairingError.cancelled }
                let completionData = try JSONEncoder().encode(FileCompletePayload(
                    transferId: self.transferID,
                    sha256: self.offer.sha256
                ))
                let sealed = try Self.encrypt(completionData, key: key)
                let message = PairingMessage(
                    kind: "files.complete",
                    sessionId: session.id,
                    messageId: UUID().uuidString.lowercased(),
                    nonce: sealed.nonce,
                    ciphertext: sealed.ciphertext
                )
                guard !self.isCancelled else { throw PairingError.cancelled }
                DispatchQueue.main.async { status("Verifying \(self.displayName) on Android…") }
                DispatchQueue.main.async { completion(.success(message)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func encrypt(_ plaintext: Data, key: Data) throws -> (nonce: String, ciphertext: String) {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
        return (Data(sealed.nonce).base64EncodedString(), (sealed.ciphertext + sealed.tag).base64EncodedString())
    }
}

private final class MacTransferProgress {
    private let totalBytes: Int64
    private var lastAt = ProcessInfo.processInfo.systemUptime
    private var lastBytes: Int64 = 0
    private var smoothed = 0.0

    init(totalBytes: Int64) { self.totalBytes = totalBytes }

    func status(transferred: Int64, force: Bool = false) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastAt
        if !force && elapsed < 0.25 && transferred < totalBytes { return nil }
        if elapsed > 0 {
            let sample = Double(max(0, transferred - lastBytes)) / elapsed
            smoothed = smoothed == 0 ? sample : smoothed * 0.7 + sample * 0.3
        }
        lastAt = now
        lastBytes = transferred
        let percent = totalBytes == 0 ? 100 : min(100, Int(transferred * 100 / totalBytes))
        let remaining = max(0, totalBytes - transferred)
        let eta: String
        if smoothed >= 1 && remaining > 0 {
            let seconds = Int64(Double(remaining) / smoothed)
            eta = seconds < 60 ? "\(max(1, seconds)) sec" : "\(seconds / 60) min \(seconds % 60) sec"
        } else { eta = "calculating…" }
        return "\(percent)% · \(ByteCountFormatter.string(fromByteCount: transferred, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(smoothed), countStyle: .file))/s · \(eta) left"
    }
}

/// Finder-style collision handling: "name.ext", then "name 2.ext", "name 3.ext", and so on.
/// A name whose partial file is still being received counts as taken.
func uniqueReceivedFileURL(_ requested: URL) -> URL {
    func isTaken(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) ||
            FileManager.default.fileExists(atPath: url.appendingPathExtension("bridgey-part").path)
    }
    guard isTaken(requested) else { return requested }
    let extensionPart = requested.pathExtension
    let stem = requested.deletingPathExtension().lastPathComponent
    for number in 2...10_000 {
        let name = extensionPart.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(extensionPart)"
        let candidate = requested.deletingLastPathComponent().appendingPathComponent(name)
        if !isTaken(candidate) { return candidate }
    }
    return requested.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
}

private final class IncomingFileTransfer {
    let displayName: String
    let expectedSize: Int64
    private let expectedHash: String
    private let partialURL: URL
    private let finalURL: URL
    private let handle: FileHandle
    private let directoryAccess: ReceiveDirectoryAccess
    private var hasher = SHA256()
    private(set) var receivedSize: Int64 = 0
    private var nextSequence: Int64 = 0
    private var lastProgressAt = ProcessInfo.processInfo.systemUptime
    private var lastProgressBytes: Int64 = 0
    private var smoothedBytesPerSecond = 0.0

    init(offer: FileOfferPayload, directoryAccess: ReceiveDirectoryAccess) throws {
        expectedSize = offer.size
        expectedHash = offer.sha256
        self.directoryAccess = directoryAccess
        let sanitized = Self.sanitize(offer.name)
        displayName = sanitized
        let directory = directoryAccess.url
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        finalURL = uniqueReceivedFileURL(directory.appendingPathComponent(sanitized))
        partialURL = finalURL.appendingPathExtension("bridgey-part")
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: partialURL)
    }

    func append(_ data: Data, sequence: Int64) throws {
        guard sequence == nextSequence,
              data.count <= 24 * 1024,
              receivedSize + Int64(data.count) <= expectedSize else { throw PairingError.invalidMessage }
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        receivedSize += Int64(data.count)
        nextSequence += 1
    }

    func finish(expectedHash completionHash: String) throws -> URL {
        try handle.close()
        let actual = Data(hasher.finalize()).base64EncodedString()
        guard receivedSize == expectedSize,
              completionHash == expectedHash,
              actual == expectedHash else {
            try? FileManager.default.removeItem(at: partialURL)
            throw PairingError.invalidMessage
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }

    func progressStatus(force: Bool = false) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastProgressAt
        if !force && elapsed < 0.25 && receivedSize < expectedSize { return nil }
        if elapsed > 0 {
            let sample = Double(max(0, receivedSize - lastProgressBytes)) / elapsed
            smoothedBytesPerSecond = smoothedBytesPerSecond == 0 ? sample : smoothedBytesPerSecond * 0.7 + sample * 0.3
        }
        lastProgressAt = now
        lastProgressBytes = receivedSize
        let percent = expectedSize == 0 ? 100 : min(100, Int(receivedSize * 100 / expectedSize))
        let remaining = max(0, expectedSize - receivedSize)
        let eta = smoothedBytesPerSecond >= 1 && remaining > 0
            ? Self.formatDuration(Int64(Double(remaining) / smoothedBytesPerSecond))
            : "calculating…"
        return "\(percent)% · \(Self.formatBytes(receivedSize)) / \(Self.formatBytes(expectedSize)) · \(Self.formatBytes(Int64(smoothedBytesPerSecond)))/s · \(eta) left"
    }

    func cancel() {
        try? handle.close()
        try? FileManager.default.removeItem(at: partialURL)
    }

    private static func sanitize(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return String(leaf.prefix(255)).isEmpty ? "file" : String(leaf.prefix(255))
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formatDuration(_ seconds: Int64) -> String {
        if seconds < 1 { return "<1 sec" }
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3_600 { return "\(seconds / 60) min \(seconds % 60) sec" }
        return "\(seconds / 3_600) h \((seconds % 3_600) / 60) min"
    }
}

private final class MacIdentity {
    private let key: P256.Signing.PrivateKey

    /// The key always comes from the pairing file. It is created only by `MacPairingStore`, and
    /// never because a read failed.
    init?(rawKey: Data) {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: rawKey) else { return nil }
        self.key = key
    }

    var publicKey: String { key.publicKey.x963Representation.base64EncodedString() }

    func sign(_ data: Data) -> String {
        (try? key.signature(for: data).derRepresentation.base64EncodedString()) ?? ""
    }
}
