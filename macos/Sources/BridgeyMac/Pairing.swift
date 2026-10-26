import AppKit
import Combine
import CryptoKit
import Foundation
import Network
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

    init(
        id: String,
        name: String,
        status: String,
        active: Bool,
        startedAt: Date = Date(),
        retryable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.active = active
        self.startedAt = startedAt
        self.retryable = retryable
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
}

private struct RemoteNotificationActionPayload: Codable {
    let actionToken: String
    let title: String
    let allowsReply: Bool
}

private struct NotificationReferencePayload: Codable {
    let notificationId: String
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

/// Reads one key of a features.update map without requiring the rest to be booleans.
private struct ClipboardFeatureProbe: Decodable {
    let features: [String: Bool]
}

private func defaultRemoteFeatureState() -> [BridgeyFeature: Bool] {
    Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, featureEnabledByLegacyPeer($0)) })
}

private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    var onDismiss: ((String, String) -> Void)?
    var onAction: ((String, String, String, String?) -> Void)?

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

    var trustedDevices: [TrustedDeviceInfo] {
        trustRegistry.devices.map { device in
            TrustedDeviceInfo(id: device.id, name: device.name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private let deviceID: String
    private var deviceName: String
    private let settings: BridgeySettings
    private let identity: MacIdentity
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
    /// Per phone: where this Mac dialled it, reconnect attempts and the pending reconnect.
    private var trustedEndpoints: [String: (host: String, port: Int, name: String)] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var reconnectWorkItems: [String: DispatchWorkItem] = [:]
    private var dialing = Set<String>()
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
    private var remoteNotificationCategories: [String: UNNotificationCategory] = [:]
    private var incomingFiles: [String: IncomingFileTransfer] = [:]
    private var outgoingFiles: [String: OutgoingFileTransfer] = [:]
    private var outgoingFileSources: [String: URL] = [:]
    private var fileOperationID: UUID?
    private var filePreparationCancellation: FileCancellationToken?
    private var fileTransferWindow: FileTransferWindowController?
    private var fileDropWindow: FileDropWindowController?
    private lazy var callOverlayWindow = CallOverlayWindowController(pairing: self)
    private var activeRemoteCalls = ActiveRemoteCalls()
    private var hiddenCallOverlayIdentities = Set<String>()
    private var audibleCallIdentities = Set<String>()
    private var recordedCallIdentities = Set<String>()
    /// The clipboard being sent, as a stream preview, until the phone acknowledges it.
    private var pendingClipboardActivity: (preview: String?, sensitive: Bool, automatic: Bool)?
    private let autoClipboard = AutoClipboardWatcher()
    private var autoClipboardCancellable: AnyCancellable?
    private var alertedNotificationIdentifiers = AlertedNotificationIdentifiers()
    private var cancelledTransferIDs = Set<String>()
    private var findDeviceSound: NSSound?
    private var lastSentBattery: LocalBatteryStatus?
    private let diagnostics = BridgeyDiagnostics()
    private let notificationHistoryStore: NotificationHistoryStore

    init(deviceID: String, deviceName: String, settings: BridgeySettings) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.settings = settings
        let notificationHistoryStore = NotificationHistoryStore()
        self.notificationHistoryStore = notificationHistoryStore
        activity = ActivityLog(store: ActivityStore())
        if settings.notificationHistoryEnabled {
            notificationHistory = notificationHistoryStore.load()
        }
        // One Keychain read for identity and trust, so macOS asks at most once after an update.
        let keychainState = MacKeychainState.shared
        identity = MacIdentity(state: keychainState)
        let trustRegistry = MacTrustRegistry(state: keychainState)
        self.trustRegistry = trustRegistry
        trustedDeviceIDs = trustRegistry.deviceIDs
        notificationPresenter.onDismiss = { [weak self] notificationID, deviceID in
            Task { @MainActor [weak self] in
                self?.dismissAndroidNotification(notificationID, deviceID: deviceID)
            }
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
        UNUserNotificationCenter.current().setNotificationCategories(Set(remoteNotificationCategories.values))
        UNUserNotificationCenter.current().delegate = notificationPresenter
        refreshNotificationAuthorization()
        startListener()
        quickActions.available = { [weak self] in self?.isFeatureAvailable($0) == true }
        quickActions.send = { [weak self] in self?.sendQuickPayload(kind: $0, payload: $1) == true }
        quickActions.onActivity = { [weak self] kind in self?.recordConnectedActivity(kind) }
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
                        self.clearRemoteCall(for: id)
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
                    self.mediaController.refresh()
                    self.publishLocalBattery(force: true)
                    self.refreshAutoClipboard()
                }
            }
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
                NSLog("PLUGIN notifications authorization failed error=%@", String(describing: error))
            } else {
                NSLog("PLUGIN notifications authorization granted=%@", String(granted))
            }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func observe(_ discovery: BonjourDiscovery) {
        discoveryCancellable = discovery.$peers.sink { [weak self] peers in
            self?.connectTrustedPeerIfNeeded(peers)
        }
    }

    /// A pairing (or reconnect) the user started. Never disturbs other connected phones.
    func pair(host: String, port: Int, peerName: String) {
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
        NSLog("PAIRING started peer=%@", peerName)
        pairingSession = dial(host: host, port: endpointPort, peerName: peerName, deviceID: nil)
    }

    /// Opens a session to a phone. `deviceID` marks a reconnect to a trusted phone (no prompt).
    @discardableResult
    private func dial(host: String, port: NWEndpoint.Port, peerName: String, deviceID dialDeviceID: String?) -> Session {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let current = Session(connection: connection, peerName: peerName)
        current.initiatedLocally = true
        current.endpoint = (host, Int(port.rawValue), peerName)
        current.dialDeviceID = dialDeviceID
        current.id = UUID().uuidString.lowercased()
        current.privateKey = P256.KeyAgreement.PrivateKey()
        current.localEphemeralKey = current.privateKey!.publicKey.x963Representation.base64EncodedString()
        if let dialDeviceID { dialing.insert(dialDeviceID) }
        registry.addPending(current, initiatedLocally: true)
        scheduleConnectionTimeout(for: current)
        configure(current) { [weak self, weak current] in
            guard let self, let current, current.privateKey != nil else { return }
            current.send(PairingMessage(
                kind: "pairing.offer",
                sessionId: current.id,
                deviceId: self.deviceID,
                deviceName: self.deviceName,
                publicKey: current.localEphemeralKey
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

    /// Disconnects one phone; the others stay connected. It reconnects when it next appears.
    func disconnect(deviceID id: String) {
        guard let current = registry.session(for: id) else { return }
        current.ended = true
        current.connectionTimeout?.cancel()
        current.heartbeat?.cancel()
        registry.remove(current)
        current.close()
        deviceDisconnected(id)
    }

    /// The send target for single-phone actions (panel chip menu).
    func selectDevice(_ id: String?) {
        selectedDeviceID = id
        publish()
    }

    func forget(deviceID: String) {
        clearClipboardCache()
        trustRegistry.remove(deviceID: deviceID)
        trustedDeviceIDs.remove(deviceID)
        settings.removeDevice(deviceID)
        trustedEndpoints.removeValue(forKey: deviceID)
        reconnectWorkItems.removeValue(forKey: deviceID)?.cancel()
        disconnect(deviceID: deviceID)
        NSLog("PAIRING revoked peerId=%@", String(deviceID.prefix(8)))
    }

    /// Recomputes the per-phone list and the selected phone's mirrors (state, features, battery).
    private func publish() {
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

    /// One phone's session ended: only its calls, transfers and clipboard fetches go.
    private func deviceDisconnected(_ id: String) {
        cancelTransfers(for: id)
        if clipboardInbox.current?.deviceID == id || clipboardOutbox.current?.deviceID == id {
            clipboardConnectionLost()
        }
        clearRemoteCall(for: id)
        if macRingingFrom == id { stopMacSound() }
        if registry.connectedIDs.isEmpty {
            clearClipboardSendStatus()
            clearCallStatus()
            clearPingStatus()
            mediaController.reset()
            lastSentBattery = nil
        }
        publish()
        NSLog("TRANSPORT disconnected peerId=%@", String(id.prefix(8)))
        diagnostics.record(category: "transport", event: "disconnected", outcome: "reconnecting")
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
        NSLog("PLUGIN clipboard offer sent automatic=%@", String(automatic))
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
        NSLog("PLUGIN clipboard offer received")
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
        NSLog("PLUGIN clipboard sent automatic=%@", String(automatic))
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
        NSLog("PLUGIN ping received")
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
            quickActions.receive(message.kind, payload: payload)
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
        NSLog("PLUGIN battery sent level=%d charging=%@", status.level, String(status.isCharging))
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
        NSLog("PLUGIN find-device %@", start ? "started" : "stopped")
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
            panel.title = "Send File to Android"
            panel.prompt = "Send"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.level = .floating
            guard panel.runModal() == .OK, let url = panel.url else { return }
            self.prepareFile(url)
        }
    }

    @discardableResult
    func sendDroppedFile(_ url: URL) -> Bool {
        guard session != nil, case .connected = state else {
            fileTransferStatus = "Not connected, so the file was not sent"
            return false
        }
        guard isFeatureAvailable(.files) else {
            fileTransferStatus = "File transfer is turned off on one of your devices"
            return false
        }
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            fileTransferStatus = "Drop a file, not a folder"
            return false
        }
        prepareFile(url)
        return true
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
            remoteFeatures: remoteFeatures
        ) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Bridgey Diagnostics"
        panel.nameFieldStringValue = "Bridgey-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.write(to: url, options: .atomic)
    }

    private func prepareFile(_ url: URL) {
        guard let targetID = session?.remoteDeviceID, case .connected = state else { return }
        let operationID = UUID()
        let preparationCancellation = FileCancellationToken()
        fileOperationID = operationID
        filePreparationCancellation = preparationCancellation
        beginFileTransferUI()
        fileTransferStatus = "Preparing \(url.lastPathComponent)…"
        diagnostics.record(category: "transfer", event: "send_started")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let transfer = try OutgoingFileTransfer(url: url, cancellation: preparationCancellation)
                DispatchQueue.main.async {
                    // The file goes to the phone it was meant for, even if another is selected now.
                    guard let self, self.fileOperationID == operationID,
                          let current = self.registry.session(for: targetID) else { return }
                    self.filePreparationCancellation = nil
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
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.fileOperationID == operationID else { return }
                    self?.fileTransferStatus = "Could not read the selected file"
                    self?.fileTransferActive = self?.fileTransfers.values.contains(where: { $0.active }) == true
                    self?.filePreparationCancellation = nil
                }
            }
        }
    }

    func cancelFileTransfer() {
        filePreparationCancellation?.cancel()
        filePreparationCancellation = nil
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
        fileOperationID = nil
        fileTransferActive = false
        fileTransferStatus = "Transfer cancelled"
    }

    /// files.cancel goes to the phone the transfer belongs to.
    private func sendFileCancel(_ transferID: String) {
        guard let current = transferDevices[transferID].flatMap({ registry.session(for: $0) }) ?? session else { return }
        current.send(PairingMessage(kind: "files.cancel", sessionId: current.id, transferId: transferID))
    }

    func cancelFileTransfer(id transferID: String) {
        markTransferCancelled(transferID)
        sendFileCancel(transferID)
        incomingFiles.removeValue(forKey: transferID)?.cancel()
        outgoingFiles.removeValue(forKey: transferID)?.cancel()
        markFileTransferFinished(id: transferID, status: "Transfer cancelled")
        fileTransferStatus = "Transfer cancelled"
    }

    func retryFileTransfer(id transferID: String) {
        guard let url = outgoingFileSources[transferID] else { return }
        guard session != nil, case .connected = state else {
            markFileTransferFinished(id: transferID, status: "Reconnect before retrying")
            return
        }
        guard isFeatureAvailable(.files) else {
            markFileTransferFinished(id: transferID, status: "File transfer is turned off on one of your devices")
            return
        }
        fileTransfers.removeValue(forKey: transferID)
        outgoingFileSources.removeValue(forKey: transferID)
        diagnostics.record(category: "transfer", event: "retry_started")
        prepareFile(url)
    }

    func clearTransferHistory() {
        let inactiveIDs = fileTransfers.values.filter { !$0.active }.map(\.id)
        inactiveIDs.forEach { outgoingFileSources.removeValue(forKey: $0) }
        fileTransfers = fileTransfers.filter { $0.value.active }
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
                    NSLog("PAIRING listener failed error=%@", String(describing: error))
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
            if let dialed = current.dialDeviceID { self.dialing.remove(dialed) }
            if let id = self.registry.remove(current) {
                self.deviceDisconnected(id)
                self.scheduleReconnect(id)
            } else if self.pairingSession === current {
                self.failPairing(current.failure ?? .connectionLost)
            } else if let dialed = current.dialDeviceID {
                // A reconnect that never authenticated: try again later.
                self.scheduleReconnect(dialed)
            }
        }
        current.connection.stateUpdateHandler = { [weak self, weak current] newState in
            DispatchQueue.main.async {
                guard let self, let current else { return }
                switch newState {
                case .ready:
                    NSLog("TRANSPORT connected")
                    current.receive()
                    onReady()
                case .failed, .cancelled:
                    if current.failure == nil, self.pairingSession === current, case .failed = newState {
                        current.failure = current.pairingKey == nil ? .couldNotConnect : .connectionLost
                    }
                    current.onFailure?()
                case let .waiting(error) where localNetworkPermissionDenied(error):
                    current.failure = .localNetworkDenied
                    current.close()
                    self.diagnostics.record(category: "transport", event: "local_network_denied", outcome: "permission_required")
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
            case "pairing.offer":
                guard !current.initiatedLocally, current.pairingKey == nil else { return }
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
                      let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: current.pairingKey!),
                      let payload = try? JSONDecoder().decode(FeatureStatePayload.self, from: plaintext),
                      payload.version == 1,
                      BridgeyFeature.allCases.filter(featureEnabledByLegacyPeer).allSatisfy({ payload.features[$0.rawValue] != nil }) else {
                    throw PairingError.invalidMessage
                }
                let features = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map {
                    ($0, payload.features[$0.rawValue] ?? false)
                })
                let clipboardFiles = (try? JSONDecoder().decode(ClipboardFeatureProbe.self, from: plaintext))?.features[clipboardFilesFeatureKey] == true
                let phoneID = current.remoteDeviceID
                registry.update(phoneID) { link in
                    link.remoteFeatures = features
                    link.featureStateReceived = true
                    link.remoteClipboardFiles = clipboardFiles
                    if features[.battery] == false { link.battery = nil }
                    if features[.findDevice] == false { link.ringing = false }
                }
                publish()
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
                if features[.notifications] == false { clearRemoteCall(for: phoneID) }
                if features[.findDevice] == false && macRingingFrom == phoneID { stopMacSound() }
                flushPendingCallIfPossible()
                publishLocalBattery(force: true)
                refreshAutoClipboard()
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
                    guard let payload = try? JSONDecoder().decode(RichClipboardContent.self, from: plaintext),
                          let content = payload.validated() else { throw PairingError.invalidMessage }
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
                NSLog("PLUGIN clipboard received")
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
                NSLog("PLUGIN clipboard acknowledged")
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
                      let payload = try? JSONDecoder().decode(BatteryPayload.self, from: plaintext),
                      (0...100).contains(payload.level) else {
                    throw PairingError.invalidMessage
                }
                registry.update(current.remoteDeviceID) {
                    $0.battery = RemoteBatteryStatus(level: payload.level, isCharging: payload.isCharging)
                }
                publish()
                NSLog("PLUGIN battery received level=%d charging=%@", payload.level, String(payload.isCharging))
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
                recordNotificationHistory(payload, deviceID: current.remoteDeviceID)
                if payload.callType == nil {
                    recordActivity(.notificationsShown, in: current, appName: payload.applicationName)
                }
                updateRemoteCall(payload, deviceID: current.remoteDeviceID)
                if shouldUseSystemNotification(callType: payload.callType) {
                    postNotification(payload, deviceID: current.remoteDeviceID)
                }
            case "notifications.remove":
                guard featureEnabled(.notifications, current: current),
                      let reference = try receiveNotificationReference(message, in: current) else { return }
                removeRemoteNotification(reference.notificationId, deviceID: current.remoteDeviceID)
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
                let transfer = try IncomingFileTransfer(offer: offer, directoryAccess: settings.receiveDirectoryAccess())
                incomingFiles[offer.transferId] = transfer
                transferDevices[offer.transferId] = current.remoteDeviceID
                fileOperationID = UUID()
                beginFileTransferUI()
                fileTransferStatus = "Receiving \(transfer.displayName): \(transfer.progressStatus(force: true)!)"
                updateFileTransfer(id: offer.transferId, name: transfer.displayName, status: fileTransferStatus!, active: true)
                current.send(PairingMessage(
                    kind: "files.accept",
                    sessionId: current.id,
                    transferId: offer.transferId
                ))
                NSLog("PLUGIN file accepted name=%@ size=%lld", transfer.displayName, offer.size)
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
                guard let transfer = incomingFiles.removeValue(forKey: completion.transferId) else {
                    if cancelledTransferIDs.contains(completion.transferId) { return }
                    throw PairingError.invalidMessage
                }
                do {
                    let destination = try transfer.finish(expectedHash: completion.sha256)
                    let folder = destination.deletingLastPathComponent().path
                    fileTransferStatus = "Saved \(transfer.displayName) to \(folder)"
                    updateFileTransfer(id: completion.transferId, name: transfer.displayName, status: fileTransferStatus!, active: false)
                    fileTransferActive = fileTransfers.values.contains(where: { $0.active })
                    fileOperationID = nil
                    current.send(PairingMessage(
                        kind: "files.complete.ack",
                        sessionId: current.id,
                        transferId: completion.transferId
                    ))
                    recordActivity(.fileReceived, in: current, fileName: transfer.displayName)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    NSLog("PLUGIN file received name=%@", transfer.displayName)
                } catch {
                    transfer.cancel()
                    fileTransferStatus = "File verification failed"
                    recordActivity(.fileFailed, in: current, fileName: transfer.displayName)
                    throw error
                }
            case "files.accept":
                if clipboardOutbox.owns(message.transferId), let transferID = message.transferId {
                    clipboardOutbox.handleAccept(transferID)
                    return
                }
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
                            if transfer.isCancelled {
                                self.fileTransferStatus = "Transfer cancelled"
                                self.markFileTransferFinished(id: transferID, status: "Transfer cancelled")
                                return
                            } else {
                                self.fileTransferStatus = "File transfer failed"
                            }
                            self.fileTransferActive = self.fileTransfers.values.contains(where: { $0.active })
                            self.fileOperationID = nil
                            self.updateFileTransfer(id: transferID, name: transfer.displayName, status: self.fileTransferStatus!, active: false)
                        }
                    }
                )
            case "files.rejected":
                if clipboardOutbox.owns(message.transferId), let transferID = message.transferId {
                    clipboardOutbox.handleCancel(transferID)
                    return
                }
                guard let transferID = message.transferId,
                      let transfer = outgoingFiles.removeValue(forKey: transferID) else { return }
                transfer.cancel()
                markTransferCancelled(transferID)
                markFileTransferFinished(id: transferID, status: "File transfer is turned off on Android")
                fileOperationID = nil
                filePreparationCancellation = nil
                fileTransferStatus = "File transfer is turned off on Android"
            case "files.complete.ack":
                if clipboardOutbox.owns(message.transferId), let transferID = message.transferId {
                    clipboardOutbox.handleCompleteAck(transferID)
                    return
                }
                guard let transferID = message.transferId,
                      let transfer = outgoingFiles.removeValue(forKey: transferID) else { return }
                outgoingFileSources.removeValue(forKey: transferID)
                fileTransferStatus = "\(transfer.displayName) saved on Android"
                recordActivity(.fileSent, in: current, fileName: transfer.displayName)
                updateFileTransfer(id: transferID, name: transfer.displayName, status: fileTransferStatus!, active: false)
                fileTransferActive = fileTransfers.values.contains(where: { $0.active })
                fileOperationID = nil
                filePreparationCancellation = nil
                NSLog("PLUGIN file sent name=%@", transfer.displayName)
            case "files.cancel":
                guard let transferID = message.transferId else { return }
                if clipboardInbox.owns(transferID) || clipboardOutbox.owns(transferID) {
                    clipboardInbox.handleCancel(transferID: transferID)
                    clipboardOutbox.handleCancel(transferID)
                    current.send(PairingMessage(kind: "files.cancel.ack", sessionId: current.id, transferId: transferID))
                    return
                }
                markTransferCancelled(transferID)
                incomingFiles.removeValue(forKey: transferID)?.cancel()
                outgoingFiles.removeValue(forKey: transferID)?.cancel()
                markFileTransferFinished(id: transferID, status: "Transfer cancelled by Android")
                fileOperationID = nil
                fileTransferStatus = "Transfer cancelled by Android"
                current.send(PairingMessage(kind: "files.cancel.ack", sessionId: current.id, transferId: transferID))
                NSLog("PLUGIN file cancellation received transfer=%@", String(transferID.prefix(8)))
            case "files.cancel.ack":
                if clipboardInbox.owns(message.transferId) || clipboardOutbox.owns(message.transferId) { return }
                if let transferID = message.transferId {
                    markFileTransferFinished(id: transferID, status: "Transfer cancelled")
                }
            case "files.chunk.ack":
                if let transferID = message.transferId, let sequence = message.sequence {
                    outgoingFiles[transferID]?.acknowledge(sequence: sequence)
                    clipboardOutbox.handleChunkAck(transferID, sequence: sequence)
                }
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
            NSLog("TRANSPORT duplicate session closed peerId=%@", String(id.prefix(8)))
            if pairingSession === current {
                pairingSession = nil
                pairingFlow = .idle
            }
            current.ended = true
            current.close()
            publish()
            return
        case let .accepted(replaced):
            if let replaced {
                NSLog("TRANSPORT duplicate session replaced peerId=%@", String(id.prefix(8)))
                replaced.connectionTimeout?.cancel()
                replaced.heartbeat?.cancel()
                replaced.close()
            }
        }
        current.authenticated = true
        current.connectionTimeout?.cancel()
        if let dialed = current.dialDeviceID { dialing.remove(dialed) }
        saveTrust(current)
        if current.initiatedLocally, let endpoint = current.endpoint { trustedEndpoints[id] = endpoint }
        reconnectAttempts[id] = 0
        reconnectWorkItems.removeValue(forKey: id)?.cancel()
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
        NSLog("PAIRING verified peer=%@", current.peerName)
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

    /// One phone disconnected: only its file transfers stop.
    private func cancelTransfers(for id: String) {
        let ids = Set(transferDevices.filter { $0.value == id }.keys)
        let hadActiveTransfers = fileTransfers.values.contains(where: { $0.active && ids.contains($0.id) })
        for transferID in ids {
            incomingFiles.removeValue(forKey: transferID)?.cancel()
            outgoingFiles.removeValue(forKey: transferID)?.cancel()
        }
        let affected = fileTransfers.filter { ids.contains($0.key) }
        fileTransfers = fileTransfers.filter { !ids.contains($0.key) }.merging(recoverInterruptedTransfers(affected)) { $1 }
        pruneTransferHistory()
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
        if !fileTransferActive {
            fileOperationID = nil
            filePreparationCancellation = nil
        }
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

    private func updateFileTransfer(id: String, name: String, status: String, active: Bool) {
        let previous = fileTransfers[id]
        fileTransfers[id] = FileTransferRow(
            id: id,
            name: name,
            status: status,
            active: active,
            startedAt: previous?.startedAt ?? Date(),
            retryable: !active && outgoingFileSources[id] != nil
        )
        pruneTransferHistory()
        fileTransferActive = fileTransfers.values.contains(where: { $0.active })
    }

    private func markFileTransferFinished(id: String, status: String) {
        guard let transfer = fileTransfers[id] else { return }
        fileTransfers[id] = FileTransferRow(
            id: transfer.id,
            name: transfer.name,
            status: status,
            active: false,
            startedAt: transfer.startedAt,
            retryable: outgoingFileSources[id] != nil
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
            NSLog("PAIRING rejected: another pairing is waiting for confirmation")
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

    /// Dials every trusted phone this Mac should dial (lower device id) that is not connected,
    /// being dialled or waiting for its reconnect backoff.
    func connectTrustedPeerIfNeeded(_ peers: [DiscoveredPeer]) {
        lastPeers = peers
        for peer in peers {
            guard let id = peer.deviceIDHint, trustedDeviceIDs.contains(id), deviceID < id,
                  registry.session(for: id) == nil, !dialing.contains(id), reconnectWorkItems[id] == nil,
                  let host = peer.host, let port = peer.port,
                  let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { continue }
            reconnectAttempts[id, default: 0] += 1
            dial(host: host, port: endpointPort, peerName: peer.deviceNameHint, deviceID: id)
        }
    }

    /// Backoff per phone: reconnects to where this Mac last dialled it, or where discovery sees it.
    private func scheduleReconnect(_ id: String) {
        guard trustedDeviceIDs.contains(id) else { return }
        let seen = lastPeers.first { $0.deviceIDHint == id && deviceID < id }
        let endpoint = trustedEndpoints[id] ?? seen.flatMap { peer in
            peer.host.flatMap { host in peer.port.map { (host: host, port: $0, name: peer.deviceNameHint) } }
        }
        guard let endpoint, let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return }
        reconnectWorkItems[id]?.cancel()
        let attempt = reconnectAttempts[id] ?? 0
        reconnectAttempts[id] = attempt + 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItems.removeValue(forKey: id)
            guard self.registry.session(for: id) == nil, !self.dialing.contains(id), self.trustedDeviceIDs.contains(id) else { return }
            self.dial(host: endpoint.host, port: port, peerName: endpoint.name, deviceID: id)
        }
        reconnectWorkItems[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay(attempt: attempt), execute: work)
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
            NSLog("TRANSPORT pending session timed out")
            current.failure = .timeout
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
                NSLog("TRANSPORT heartbeat timed out")
                current.close()
                return
            }
            current.send(PairingMessage(
                kind: "heartbeat.ping",
                sessionId: current.id,
                messageId: UUID().uuidString.lowercased()
            ))
            self.publishLocalBattery()
            self.mediaController.refresh()
            self.scheduleHeartbeat(for: current)
        }
        current.heartbeat = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
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
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("PLUGIN notification delivery failed package=%@ error=%@", payload.packageName, String(describing: error))
            } else {
                NSLog("PLUGIN notification received package=%@", payload.packageName)
            }
        }
    }

    func performRemoteCallAction(_ action: RemoteCallAction) {
        guard let call = remoteCall else { return }
        performAndroidNotificationAction(
            call.notificationID,
            deviceID: call.deviceID,
            actionToken: action.id,
            replyText: nil
        )
    }

    func hideCallOverlay() {
        if let call = remoteCall {
            hiddenCallOverlayIdentities.insert(callOverlayIdentity(call.notificationID, deviceID: call.deviceID))
        }
        callOverlayWindow.hide()
    }

    private func updateRemoteCall(_ payload: RemoteNotificationPayload, deviceID: String) {
        guard let callType = normalizedRemoteCallType(payload.callType) else { return }
        let identity = callOverlayIdentity(payload.notificationId, deviceID: deviceID)
        clearCallStatus()
        let actions = (payload.actions ?? []).filter { !$0.allowsReply }.prefix(4).map {
            RemoteCallAction(id: $0.actionToken, title: $0.title)
        }
        activeRemoteCalls.update(RemoteCallStatus(
            notificationID: payload.notificationId,
            deviceID: deviceID,
            applicationName: payload.applicationName,
            caller: payload.title,
            detail: remoteCallDetail(payload.text, type: callType),
            type: callType,
            actions: actions
        ))
        publishRemoteCall()
        if !recordedCallIdentities.contains(identity) {
            recordedCallIdentities.insert(identity)
            let name = trustedDevices.first { $0.id == deviceID }?.name ?? session?.peerName ?? ""
            let caller = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            recordActivity(.callShown, deviceID: deviceID, deviceName: name, preview: caller.isEmpty ? nil : caller)
        }
        if callType == "incoming", !audibleCallIdentities.contains(identity) {
            NSSound.beep()
            audibleCallIdentities.insert(identity)
        }
    }

    private func publishRemoteCall() {
        remoteCall = activeRemoteCalls.mostRelevant
        mediaController.callChanged(active: activeRemoteCalls.pausesMedia)
        if let call = remoteCall,
           !hiddenCallOverlayIdentities.contains(callOverlayIdentity(call.notificationID, deviceID: call.deviceID)) {
            callOverlayWindow.show()
        } else {
            callOverlayWindow.hide()
        }
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

    private func recordNotificationHistory(_ payload: RemoteNotificationPayload, deviceID: String) {
        guard settings.notificationHistoryEnabled else { return }
        let item = NotificationHistoryItem(
            id: remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: payload.notificationId),
            packageName: String(payload.packageName.prefix(256)),
            applicationName: String(payload.applicationName.prefix(128)),
            title: String(payload.title.prefix(1_024)),
            text: String(payload.text.prefix(8_192)),
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
            NSLog("PLUGIN notification icon attachment failed package=%@ error=%@", payload.packageName, String(describing: error))
            return nil
        }
    }

    private func notificationCategoryIdentifier(for payload: RemoteNotificationPayload, deviceID: String) -> String {
        let actions = (payload.actions ?? []).prefix(4).compactMap { action -> UNNotificationAction? in
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

    private func removeRemoteNotification(_ notificationID: String, deviceID: String) {
        if activeRemoteCalls.remove(notificationID: notificationID, deviceID: deviceID) != nil {
            let identity = callOverlayIdentity(notificationID, deviceID: deviceID)
            hiddenCallOverlayIdentities.remove(identity)
            audibleCallIdentities.remove(identity)
            recordedCallIdentities.remove(identity)
            publishRemoteCall()
        }
        let identifier = remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: notificationID)
        alertedNotificationIdentifiers.remove(identifier)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        diagnostics.record(category: "notification", event: "removed_remotely")
    }

    /// One phone's calls go when it disconnects or turns notifications off; the others stay.
    private func clearRemoteCall(for id: String) {
        let calls = activeRemoteCalls.removeAll(deviceID: id)
        guard !calls.isEmpty else { return }
        for call in calls {
            let identity = callOverlayIdentity(call.notificationID, deviceID: call.deviceID)
            hiddenCallOverlayIdentities.remove(identity)
            audibleCallIdentities.remove(identity)
            recordedCallIdentities.remove(identity)
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
    var endpoint: (host: String, port: Int, name: String)?
    let createdAt = Date()
    var connectionTimeout: DispatchWorkItem?
    var heartbeat: DispatchWorkItem?
    var lastReceivedAt = Date()
    var heartbeatSupported = false
    var onMessage: ((PairingMessage) -> Void)?
    var onFailure: (() -> Void)?
    private var buffer = Data()
    private var seenMessageIDs = Set<String>()
    var quickSequence = QuickRequestSequence()

    init(connection: NWConnection, peerName: String) {
        self.connection = connection
        self.peerName = peerName
    }

    func send(_ message: PairingMessage) {
        guard let encoded = try? JSONEncoder().encode(message) else { return }
        connection.send(content: encoded + Data([0x0A]), completion: .contentProcessed { error in
            if let error { NSLog("TRANSPORT send failed kind=%@ error=%@", message.kind, String(describing: error)) }
        })
    }

    func sendAndWait(_ message: PairingMessage) -> Bool {
        guard let encoded = try? JSONEncoder().encode(message) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        connection.send(content: encoded + Data([0x0A]), completion: .contentProcessed { error in
            succeeded = error == nil
            if let error { NSLog("TRANSPORT send failed kind=%@ error=%@", message.kind, String(describing: error)) }
            semaphore.signal()
        })
        return semaphore.wait(timeout: .now() + 15) == .success && succeeded
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[..<newline]
                    self.buffer.removeSubrange(...newline)
                    do {
                        let message = try decodeProtocolMessage(Data(line))
                        self.lastReceivedAt = Date()
                        self.onMessage?(message)
                    } catch {
                        NSLog("TRANSPORT invalid message error=%@", String(describing: error))
                        self.close()
                        self.onFailure?()
                        return
                    }
                }
                guard self.buffer.count <= maximumProtocolFrameBytes else {
                    NSLog("TRANSPORT protocol frame exceeded size limit")
                    self.close()
                    self.onFailure?()
                    return
                }
                if complete || error != nil { self.onFailure?() } else { self.receive() }
            }
        }
    }

    func close() { connection.cancel() }

    func acceptMessageID(_ id: String) -> Bool {
        guard seenMessageIDs.insert(id).inserted else { return false }
        if seenMessageIDs.count > 256 { seenMessageIDs.remove(seenMessageIDs.first!) }
        return true
    }
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
    let transferID = UUID().uuidString.lowercased()
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

    init(url: URL, cancellation: FileCancellationToken) throws {
        self.url = url
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
        finalURL = Self.uniqueURL(directory.appendingPathComponent(sanitized))
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

    private static func uniqueURL(_ requested: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let extensionPart = requested.pathExtension
        let stem = requested.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            let name = extensionPart.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(extensionPart)"
            let candidate = requested.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return requested.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
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

    /// Reads the key from the shared Keychain item. A new key is created only when nothing is
    /// stored. If the item cannot be read (the user chose Deny), this launch uses a temporary key
    /// and the stored one is left alone, so allowing access next time restores pairing.
    init(state: MacKeychainState) {
        if let data = state.contents.identityKey,
           let stored = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            key = stored
            return
        }
        let generated = P256.Signing.PrivateKey()
        key = generated
        if state.canWrite {
            state.update { $0.identityKey = generated.rawRepresentation }
        }
    }

    var publicKey: String { key.publicKey.x963Representation.base64EncodedString() }

    func sign(_ data: Data) -> String {
        (try? key.signature(for: data).derRepresentation.base64EncodedString()) ?? ""
    }
}
