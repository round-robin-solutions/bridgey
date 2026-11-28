import Foundation
import Network
import SwiftUI
import UIKit

/// Test and screenshot hooks, read once at start. Debug builds only: a release build ignores the environment.
struct LaunchOptions {
    /// Pairing data in memory, settings in a throwaway domain, nothing saved.
    var ephemeral = false
    var port: UInt16 = 0
    var discovery = true
    var skipSetup = false
    /// Sample devices and activity for screenshots (no network).
    var demo: String?
    var appearance: Appearance?
    /// Hosting unit tests: the app itself stays off the network.
    var idle = false
    /// Devices a test says are on the network (BRIDGEY_FOUND: `id|name|platform|host|port`, `;` between devices), so
    /// a test can pair with a scripted peer as a phone or a Mac without Bonjour.
    var found: [FoundDevice] = []

    static let current: LaunchOptions = {
        var o = LaunchOptions()
        let env = ProcessInfo.processInfo.environment
        o.idle = env["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        o.ephemeral = env["BRIDGEY_DATA"] == "memory"
        o.port = env["BRIDGEY_PORT"].flatMap(UInt16.init) ?? 0
        o.discovery = env["BRIDGEY_DISCOVERY"] != "0"
        o.skipSetup = env["BRIDGEY_SKIP_SETUP"] == "1"
        o.demo = env["BRIDGEY_DEMO"].flatMap { $0.isEmpty ? nil : $0 }
        o.appearance = env["BRIDGEY_APPEARANCE"].flatMap(Appearance.init(rawValue:))
        o.found = (env["BRIDGEY_FOUND"] ?? "").split(separator: ";").compactMap { entry in
            let f = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, let port = UInt16(f[4]) else { return nil }
            return FoundDevice(service: f[1], deviceID: f[0].isEmpty ? nil : f[0], name: f[1], platform: f[2].isEmpty ? nil : f[2], host: f[3], port: port)
        }
        #endif
        return o
    }()
}

/// What the app writes to and opens; tests replace them.
protocol SystemServices: AnyObject {
    func copy(_ text: String)
    func open(_ url: URL)
}

final class LiveSystemServices: SystemServices {
    func copy(_ text: String) { UIPasteboard.general.string = text }
    func open(_ url: URL) { UIApplication.shared.open(url) }
}

typealias ClientFactory = (CoreOptions, @escaping @Sendable (CoreEvent) -> Void) throws -> CoreClient

/// The app's state: paired devices and their status, devices nearby, the activity stream, transfers, links and
/// pairing. bridgey_core runs while the app is open; its events arrive in order on the main thread.
@MainActor
final class AppModel: ObservableObject {
    static let activityLimit = 200

    let settings: AppSettings
    let options: LaunchOptions
    private let makeClient: ClientFactory
    private let system: SystemServices
    private let activityFile: URL?
    private(set) var client: CoreClient?
    private var discovery: BonjourDiscovery?
    private var pathMonitor: NWPathMonitor?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var allowRefresh: Timer?
    /// Pairing screens open: other devices may pair while any is.
    private var pairingScreens = 0
    private var cardTimers: [UInt64: Timer] = [:]

    @Published private(set) var devices: [DeviceItem] = []
    @Published private(set) var nearby: [NearbyItem] = []
    @Published private(set) var activity: [ActivityItem] = []
    @Published private(set) var transfers: [TransferItem] = []
    @Published private(set) var links: [LinkCard] = []
    @Published private(set) var pairing: PairingState = .idle
    @Published private(set) var pairingRequest: PairingRequest?
    @Published private(set) var localNetwork: DiscoveryHealth = .idle
    @Published private(set) var running = false
    @Published var notice: String?
    @Published var draft = ""
    @Published var targetID: String? {
        didSet { if let targetID { settings.lastDeviceID = targetID } }
    }
    /// The stream's navigation (Messages, the phone's files).
    @Published var path: [Route] = []

    let screen = ScreenModel()
    let messages = MessagesModel()
    let phoneFiles = PhoneFilesModel()
    let alerts = AlertsModel()
    private var features: [SessionFeature] { [screen, messages, phoneFiles, alerts] }

    init(settings: AppSettings, options: LaunchOptions = .current, system: SystemServices = LiveSystemServices(), activityFile: URL? = AppModel.defaultActivityFile, makeClient: @escaping ClientFactory) {
        self.settings = settings
        self.options = options
        self.system = system
        self.activityFile = options.ephemeral || options.demo != nil ? nil : activityFile
        self.makeClient = makeClient
        targetID = settings.lastDeviceID
        loadActivity()
        for feature in features { feature.attach(self) }
    }

    nonisolated static var defaultActivityFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("activity.json")
    }

    // MARK: Lifecycle

    /// Starts bridgey_core, Bonjour and the network monitor. Called when the app becomes active.
    func start() {
        guard !options.idle else { return }
        endBackgroundTask()
        guard client == nil else {
            try? client?.networkChanged()
            discovery?.restart()
            return
        }
        var core = CoreOptions(deviceName: settings.deviceName)
        core.port = options.port
        core.receiveDirectory = settings.files ? SharedStorage.receivedFiles : nil
        let relay = EventRelay(self)
        do {
            client = try makeClient(core) { event in relay.post(event) }
        } catch {
            notice = (error as? CoreError)?.code == CoreError.io
                ? String(localized: "Bridgey couldn’t listen for your devices. Another app may be using its port.")
                : error.localizedDescription
            return
        }
        running = true
        for feature in features { feature.clientChanged(client) }
        applyDefaults()
        refresh()
        for device in options.found { found(device) }
        if options.discovery, let client {
            let discovery = BonjourDiscovery(ownDeviceID: client.deviceID)
            discovery.onFound = { [weak self] device in self?.found(device) }
            discovery.onLost = { [weak self] device in try? self?.client?.removeDiscovered(host: device.host, port: device.port) ; self?.refreshNearby() }
            discovery.onHealth = { [weak self] health in self?.localNetwork = health }
            discovery.start()
            discovery.advertise(name: settings.deviceName, port: options.port == 0 ? 42_458 : options.port)
            self.discovery = discovery
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged() } }
            }
            monitor.start(queue: .global(qos: .utility))
            pathMonitor = monitor
        }
        if pairingScreens > 0 { allowPairing(true) }
    }

    /// The app went to the background. iOS suspends it soon, so the session ends now, or once the files on their
    /// way have finished (iOS gives a short grace period for that).
    func enterBackground() {
        guard client != nil else { return }
        if transfers.isEmpty {
            stop()
            return
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Bridgey transfers") { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        discovery?.stop()
        discovery = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        allowRefresh?.invalidate()
        allowRefresh = nil
        client?.stop()
        client = nil
        running = false
        for feature in features { feature.clientChanged(nil) }
        path = []
        nearby = []
        for i in devices.indices { devices[i].connected = false }
        transfers = []
        if pairing.isActive { pairing = .idle }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func networkChanged() {
        try? client?.networkChanged()
        discovery?.restart()
    }

    /// This device's switches for devices without their own, from Settings. The screen keys are per device
    /// (`applyScreenRoles`); media is never offered: iOS doesn't let an app control what other apps play.
    var featureDefaults: [(String, Bool)] {
        let s = settings
        return [
            ("clipboard", s.clipboard),
            ("files", s.files),
            // Folders from the phone: downloads from its files, and folders it sends.
            ("folders_receive_draft1", s.files),
            ("links", s.links),
            ("links_open_draft1", s.links),
            ("ping", true),
            ("battery", s.battery),
            ("find_device", s.findDevice),
            ("notifications", s.notifications),
            ("notification_routing_draft1", s.notifications),
            // Someone using Bridgey is using this device: the phone may send its alerts here while it is open.
            ("device_presence_draft1", s.notifications),
            ("sms_codes_draft1", s.notifications),
            ("email_codes_draft1", s.notifications && s.codesFromMessages && s.codesFromEmail),
            ("sms_draft1", s.textMessages),
            ("media", false),
            ("dialer_draft1", false),
            ("calls", false),
        ]
    }

    func applyDefaults() {
        guard let client else { return }
        for (key, on) in featureDefaults {
            try? client.setFeature(deviceID: nil, key: key, on: on)
        }
        try? client.setReceiveDirectory(settings.files ? SharedStorage.receivedFiles : nil)
        try? client.setLinksOpen(settings.openLinksRightAway)
        try? client.setCodes(sms: settings.notifications && settings.codesFromMessages, email: settings.notifications && settings.codesFromMessages && settings.codesFromEmail)
        // Tests and screenshots never reach the control service.
        let away = settings.connectAway && !options.ephemeral && options.demo == nil
        try? client.setConnect(away, controlURL: away ? Edition.connectControlURL : nil)
        applyScreenRoles()
    }

    /// Each device gets only the screen key its platform reads as "this device wants to see your screen"
    /// (ScreenRoles), unless Screens is off here or for that device.
    func applyScreenRoles() {
        guard let client else { return }
        for device in devices {
            let wanted = settings.screens && !settings.screensOff.contains(device.id)
            for (key, on) in ScreenRoles.keys(platform: device.platform, wanted: wanted) where (device.local[key] ?? false) != on {
                try? client.setFeature(deviceID: device.id, key: key, on: on)
                update(device.id) { $0.local[key] = on }
            }
        }
    }

    func renamed() {
        let name = settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try? client?.setDeviceName(name)
        if client != nil { discovery?.advertise(name: name, port: options.port == 0 ? 42_458 : options.port) }
    }

    // MARK: State from the library

    /// Reads everything again (at start and after dropped events).
    func refresh() {
        guard let snapshot = try? client?.snapshot() else { return }
        let batteries = Dictionary(devices.map { ($0.id, $0.battery) }, uniquingKeysWith: { a, _ in a })
        devices = snapshot.devices.map { d in
            var item = DeviceItem(id: d.deviceId, name: d.name, platform: d.platform, connected: d.connected, local: d.local, remote: d.remote)
            if d.connected { item.battery = batteries[d.deviceId] ?? nil }
            return item
        }
        refreshNearby(snapshot)
        fixTarget()
        applyScreenRoles()
    }

    private func refreshNearby(_ given: CoreSnapshot? = nil) {
        guard let snapshot = given ?? (try? client?.snapshot()) else { return }
        nearby = snapshot.nearby.compactMap { n in
            guard !n.trusted, let host = n.host else { return nil }
            return NearbyItem(deviceID: n.deviceId, name: n.name, platform: n.platform, host: host, port: UInt16(clamping: n.port ?? 42_458))
        }
    }

    private func found(_ device: FoundDevice) {
        try? client?.addDiscovered(deviceID: device.deviceID, name: device.name, platform: device.platform, host: device.host, port: device.port)
        refreshNearby()
    }

    /// The device the send bar sends to: the chosen one while it is connected, else the first connected.
    var target: DeviceItem? {
        devices.first { $0.id == targetID } ?? devices.first { $0.connected } ?? devices.first
    }

    private func fixTarget() {
        if let t = devices.first(where: { $0.id == targetID }), t.connected { return }
        if let connected = devices.first(where: { $0.connected }) { targetID = connected.id }
    }

    private func name(of deviceID: String?) -> String {
        devices.first { $0.id == deviceID }?.name ?? String(localized: "a device")
    }

    private func update(_ deviceID: String, _ change: (inout DeviceItem) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        change(&devices[i])
    }

    func handle(_ e: CoreEvent) {
        apply(e)
        for feature in features { feature.handle(e) }
        // In the background only to let files finish: stop once they have.
        if backgroundTask != .invalid, transfers.isEmpty { stop() }
    }

    private func apply(_ e: CoreEvent) {
        switch e.kind {
        case .deviceFound, .deviceLost:
            refreshNearby()
        case .pairingRequest:
            guard let id = e.deviceID, !pairing.isActive else { break }
            pairingRequest = PairingRequest(deviceID: id, name: e.name ?? String(localized: "A device"))
        case .pairingWaiting:
            if pairing.pairing == e.id { pairing = .waiting(pairing: e.id, name: e.name ?? pairingName) }
        case .pairingCode:
            pairingRequest = nil
            pairing = .code(pairing: e.id, name: e.name ?? pairingName, code: e.text ?? "")
        case .pairingFinished:
            guard pairing.pairing == e.id || !pairing.isActive else { break }
            let who = e.name ?? pairingName
            pairing = e.status == 0 ? .paired(name: who) : .failed(name: who, reason: e.text ?? "")
            if e.status == 0, let id = e.deviceID { targetID = id }
        case .connected:
            guard let id = e.deviceID else { break }
            if !devices.contains(where: { $0.id == id }) {
                refresh()
            }
            update(id) {
                $0.connected = true
                if let name = e.name { $0.name = name }
            }
            refreshNearby()
            fixTarget()
            sendOutbox(to: id)
        case .disconnected:
            guard let id = e.deviceID else { break }
            update(id) {
                $0.connected = false
                $0.remote = nil
                $0.battery = nil
            }
            fixTarget()
        case .features:
            guard let id = e.deviceID else { break }
            update(id) {
                if let local = Self.map(e.text) { $0.local = local }
                $0.remote = Self.map(e.extra)
                if $0.remote?["battery"] != true { $0.battery = nil }
            }
            applyScreenRoles()
            sendOutbox(to: id)
        case .clipboard:
            guard let text = e.text else { break }
            if settings.copyReceivedText { system.copy(text) }
            add(ActivityItem(direction: .received, kind: .text, deviceName: name(of: e.deviceID), value: text))
        case .clipboardSent, .linkSent:
            finishRequest(e.id, status: SendStatus(rawValue: e.status) ?? .failed, link: e.kind == .linkSent)
        case .ping:
            notice = String(localized: "\(name(of: e.deviceID)) pinged this \(UIDevice.current.localizedModel).")
        case .pingResult:
            if SendStatus(rawValue: e.status) != .delivered { notice = String(localized: "The ping wasn’t answered.") }
        case .trustChanged, .eventsDropped:
            refresh()
        case .error:
            if let text = e.text { notice = text }
        case .fileIncoming:
            transfers.append(TransferItem(id: e.id, deviceID: e.deviceID ?? "", deviceName: name(of: e.deviceID), name: e.name ?? "", incoming: true, total: e.total))
        case .fileProgress:
            if let i = transfers.firstIndex(where: { $0.id == e.id }) {
                transfers[i].bytes = e.bytes
                transfers[i].total = e.total
            }
        case .fileDone:
            let transfer = transfers.first { $0.id == e.id }
            transfers.removeAll { $0.id == e.id }
            if e.status == 1 {
                let saved = e.text.map { URL(fileURLWithPath: $0).lastPathComponent }
                add(ActivityItem(direction: .received, kind: .file, deviceName: name(of: e.deviceID), value: e.name ?? saved ?? "", savedName: saved))
            } else {
                finishFile(e.id, transfer: transfer, failure: nil)
            }
        case .fileFailed:
            let transfer = transfers.first { $0.id == e.id }
            transfers.removeAll { $0.id == e.id }
            let reason = Self.fileFailure(e.text ?? "")
            if e.status == 1 {
                // A cancel from this end already says so; anything else is worth a row.
                if e.text != "cancelled" {
                    add(ActivityItem(direction: .received, kind: .file, deviceName: name(of: e.deviceID), value: e.name ?? "", outcome: .failed, detail: reason))
                }
            } else {
                finishFile(e.id, transfer: transfer, failure: reason)
            }
        case .battery:
            guard let id = e.deviceID else { break }
            update(id) { $0.battery = e.status >= 0 ? BatteryLevel(level: Int(e.status), charging: e.id == 1) : nil }
        case .findRequested, .findState, .notification, .notificationRemoved, .codesStatus, .codesAdvertise, .mediaCommand,
             .connectState, .sms, .calls, .phoneFiles, .screen, .display:
            // The features handle these (AlertsModel, MessagesModel, PhoneFilesModel, ScreenModel).
            break
        case .link:
            guard let text = e.text, let url = URL(string: text) else { break }
            let from = name(of: e.deviceID)
            add(ActivityItem(direction: .received, kind: .link, deviceName: from, value: text))
            if settings.openLinksRightAway {
                system.open(url)
            } else {
                links.append(LinkCard(deviceName: from, url: url))
            }
        }
    }

    private var pairingName: String {
        switch pairing {
        case let .dialling(_, n), let .waiting(_, n), let .code(_, n, _), let .confirming(_, n, _): n
        default: String(localized: "the other device")
        }
    }

    private static func map(_ json: String?) -> [String: Bool]? {
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Bool].self, from: data)
    }

    static func fileFailure(_ reason: String) -> String {
        switch reason {
        case "rejected": String(localized: "Files is off on that device.")
        case "cancelled", "cancelled_remote": String(localized: "Cancelled.")
        case "not_accepted", "not_confirmed", "stalled": String(localized: "The other device stopped answering.")
        case "verification_failed", "invalid": String(localized: "The file didn’t arrive intact.")
        case "storage": String(localized: "There wasn’t room to save it.")
        case "unreadable", "changed": String(localized: "The file couldn’t be read.")
        case "interrupted", "not_connected", "stopped": String(localized: "The connection ended first.")
        default: String(localized: "It didn’t finish.")
        }
    }

    // MARK: Activity

    private func add(_ item: ActivityItem) {
        activity.insert(item, at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
        saveActivity()
    }

    private func finishRequest(_ request: UInt64, status: SendStatus, link: Bool) {
        guard let i = activity.firstIndex(where: { $0.request == request && $0.outcome == .sending }) else { return }
        activity[i].request = nil
        switch status {
        case .delivered:
            activity[i].outcome = .delivered
        case .rejected:
            activity[i].outcome = .failed
            activity[i].detail = link ? String(localized: "Links is off on that device.") : String(localized: "Clipboard is off on that device.")
        case .timedOut:
            activity[i].outcome = .failed
            activity[i].detail = String(localized: "No answer.")
        case .failed:
            activity[i].outcome = .failed
            activity[i].detail = String(localized: "The connection ended first.")
        }
        saveActivity()
    }

    private func finishFile(_ transfer: UInt64, transfer item: TransferItem?, failure: String?) {
        removeSendCopy(transfer)
        guard let i = activity.firstIndex(where: { $0.request == transfer }) else { return }
        activity[i].request = nil
        activity[i].outcome = failure == nil ? .delivered : .failed
        activity[i].detail = failure
        saveActivity()
    }

    /// Text is kept in memory only; files and links are remembered between launches.
    private func saveActivity() {
        guard let activityFile else { return }
        let kept = activity.filter { $0.kind != .text && $0.outcome != .sending }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: activityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: activityFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func loadActivity() {
        guard let activityFile, let data = try? Data(contentsOf: activityFile),
              let items = try? JSONDecoder().decode([ActivityItem].self, from: data) else { return }
        activity = items
    }

    func clearActivity() {
        activity.removeAll()
        saveActivity()
    }

    func copy(_ item: ActivityItem) {
        system.copy(item.value)
    }

    /// A received file in the Files folder, if it is still there.
    func fileURL(_ item: ActivityItem) -> URL? {
        guard let name = item.savedName else { return nil }
        let url = SharedStorage.receivedFiles.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Sending

    /// Sends the send bar's text: a link as a link when the device takes links, anything else as clipboard text.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let device = target, !text.isEmpty else { return }
        let sent = Self.isLink(text) && device.linksReady ? sendLink(text, to: device) : sendText(draft, to: device)
        if sent { draft = "" }
    }

    static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    @discardableResult
    func sendText(_ text: String, to device: DeviceItem) -> Bool {
        guard !text.isEmpty else { return false }
        do {
            let request = try requireClient().sendClipboard(device.id, text: text)
            add(ActivityItem(direction: .sent, kind: .text, deviceName: device.name, value: text, outcome: .sending, request: request))
            return true
        } catch {
            notice = message(error, feature: String(localized: "Clipboard"), device: device)
            return false
        }
    }

    @discardableResult
    func sendLink(_ url: String, to device: DeviceItem) -> Bool {
        do {
            let request = try requireClient().sendLink(device.id, url: url)
            add(ActivityItem(direction: .sent, kind: .link, deviceName: device.name, value: url, outcome: .sending, request: request))
            return true
        } catch {
            notice = message(error, feature: String(localized: "Links"), device: device)
            return false
        }
    }

    /// Files picked in the document picker or shared in: copied first (the picker's access ends, iCloud files are
    /// downloaded), then sent one at a time.
    func sendFiles(_ urls: [URL], to device: DeviceItem) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let copy = try Self.copyForSending(url)
                let transfer = try requireClient().sendFile(device.id, url: copy, name: url.lastPathComponent, mime: nil)
                sendCopies[transfer] = copy
                let size = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
                transfers.append(TransferItem(id: transfer, deviceID: device.id, deviceName: device.name, name: url.lastPathComponent, incoming: false, total: size))
                add(ActivityItem(direction: .sent, kind: .file, deviceName: device.name, value: url.lastPathComponent, outcome: .sending, request: transfer))
            } catch {
                notice = message(error, feature: String(localized: "Files"), device: device)
                return
            }
        }
    }

    private var sendCopies: [UInt64: URL] = [:]

    private func removeSendCopy(_ transfer: UInt64) {
        if let url = sendCopies.removeValue(forKey: transfer) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    static func copyForSending(_ url: URL) throws -> URL {
        let folder = SharedStorage.sendCopies.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }

    func cancel(_ transfer: TransferItem) {
        try? client?.cancelFile(transfer.id)
    }

    func ping(_ device: DeviceItem) {
        do { _ = try requireClient().ping(device.id) } catch { notice = message(error, feature: String(localized: "Ping"), device: device) }
    }

    private func requireClient() throws -> CoreClient {
        guard let client else { throw CoreError(code: CoreError.stopped) }
        return client
    }

    private func message(_ error: Error, feature: String, device: DeviceItem) -> String {
        guard let core = error as? CoreError else { return error.localizedDescription }
        switch core.code {
        case CoreError.featureOff: return String(localized: "\(feature) is off on \(device.name) or on this \(UIDevice.current.localizedModel).")
        case CoreError.notConnected, CoreError.stopped: return String(localized: "\(device.name) isn’t connected.")
        case CoreError.tooLarge: return String(localized: "That’s too long to send as text. Text can be up to 32 KB.")
        default: return core.localizedDescription
        }
    }

    // MARK: Links

    func open(_ card: LinkCard) {
        system.open(card.url)
        dismiss(card)
    }

    func copy(_ card: LinkCard) {
        system.copy(card.url.absoluteString)
        dismiss(card)
    }

    func dismiss(_ card: LinkCard) {
        links.removeAll { $0.id == card.id }
    }

    // MARK: Share extension items

    /// Items the Share extension couldn't send go once their device is connected.
    func sendOutbox(to deviceID: String) {
        guard let device = devices.first(where: { $0.id == deviceID }), device.connected, device.remote != nil else { return }
        for item in Outbox.items() where item.deviceID == deviceID {
            let ok: Bool
            switch item.kind {
            case .text: ok = device.clipboardReady && sendText(item.value, to: device)
            case .link: ok = device.linksReady && sendLink(item.value, to: device)
            case .file:
                ok = device.filesReady
                if ok { sendFiles([Outbox.file(of: item)], to: device) }
            }
            if ok { Outbox.remove(item) }
        }
    }

    // MARK: Pairing

    /// A pairing screen opened or closed. While one is open, other devices may pair with this one.
    func pairingScreen(open: Bool) {
        pairingScreens = max(0, pairingScreens + (open ? 1 : -1))
        allowPairing(pairingScreens > 0)
        if open {
            discovery?.restart()
        } else if !pairing.isActive {
            pairing = .idle
        }
    }

    private func allowPairing(_ on: Bool) {
        try? client?.allowPairing(seconds: on ? 120 : 0)
        allowRefresh?.invalidate()
        allowRefresh = nil
        guard on else { return }
        // Kept open for as long as the screen is: renewed before the two minutes run out.
        allowRefresh = Timer.scheduledTimer(withTimeInterval: 100, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.client?.allowPairing(seconds: 120) }
        }
    }

    func pair(_ device: NearbyItem) {
        startPairing(name: device.name) { try $0.pair(deviceID: device.deviceID, host: device.host, port: device.port) }
    }

    /// An address typed in: "192.168.1.20" or "192.168.1.20:42458".
    func pair(address: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = text, port: UInt16 = 0
        if let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1, let p = UInt16(text[text.index(after: colon)...]) {
            host = String(text[..<colon])
            port = p
        }
        guard !host.isEmpty else { return }
        startPairing(name: host) { try $0.pair(deviceID: nil, host: host, port: port) }
    }

    private func startPairing(name: String, _ dial: (CoreClient) throws -> UInt64) {
        if let p = pairing.pairing { try? client?.cancelPairing(p) }
        do {
            let id = try dial(requireClient())
            pairing = .dialling(pairing: id, name: name)
        } catch {
            pairing = .failed(name: name, reason: (error as? CoreError)?.code == CoreError.invalidArgument ? "unreachable" : "")
            if (error as? CoreError)?.code == CoreError.invalidArgument { notice = String(localized: "Enter an IP address, like 192.168.1.20.") }
        }
    }

    func confirmCode(_ matches: Bool) {
        guard case let .code(p, name, code) = pairing else { return }
        try? client?.confirmPairing(p, accept: matches)
        pairing = matches ? .confirming(pairing: p, name: name, code: code) : .failed(name: name, reason: "code_rejected")
    }

    func cancelPairing() {
        if let p = pairing.pairing { try? client?.cancelPairing(p) }
        pairing = .idle
    }

    func clearPairingResult() {
        if !pairing.isActive { pairing = .idle }
    }

    func allowPairingRequest() {
        try? client?.allowPairing(seconds: 120)
        pairingRequest = nil
    }

    func dismissPairingRequest() {
        pairingRequest = nil
    }

    // MARK: Devices

    func setFeature(_ device: DeviceItem, key: String, on: Bool) {
        do {
            try requireClient().setFeature(deviceID: device.id, key: key, on: on)
            update(device.id) { $0.local[key] = on }
        } catch {
            notice = (error as? CoreError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Screen for one device (Device settings): its key follows Settings > Screens unless turned off here.
    func setScreen(_ device: DeviceItem, on: Bool) {
        if on { settings.screensOff.remove(device.id) } else { settings.screensOff.insert(device.id) }
        applyScreenRoles()
    }

    /// A device's name for messages, or "a device".
    func deviceName(_ id: String?) -> String { name(of: id) }

    func device(_ id: String?) -> DeviceItem? { devices.first { $0.id == id } }

    /// Forget all devices: what the library kept for features goes too (conversations, partial files).
    func forgetFeatureData() {
        if !options.ephemeral { HybridStore.removeFeatureData() }
    }

    func forget(_ device: DeviceItem) {
        settings.screensOff.remove(device.id)
        try? client?.forget(device.id)
        devices.removeAll { $0.id == device.id }
        if targetID == device.id { targetID = nil }
        fixTarget()
    }

    #if DEBUG
    func replaceForDemo(devices: [DeviceItem]?, activity: [ActivityItem], transfers: [TransferItem], links: [LinkCard]) {
        if let devices { self.devices = devices }
        self.activity = activity
        self.transfers = transfers
        self.links = links
        localNetwork = .browsing
    }

    func showDemoCode() {
        pairing = .code(pairing: 1, name: "Living room iPad", code: "744419")
    }
    #endif
}

/// Hands events from bridgey_core's thread to the model on the main thread, in order.
private final class EventRelay: @unchecked Sendable {
    private weak var model: AppModel?

    init(_ model: AppModel) { self.model = model }

    func post(_ event: CoreEvent) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model?.handle(event) }
        }
    }
}
