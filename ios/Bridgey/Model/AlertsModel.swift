import AVFoundation
import Combine
import Foundation
import UIKit

/// One of a notification's own buttons (Reply, Mark as read, Answer, Decline, Hang up), in the phone's words.
struct AlertAction: Equatable, Identifiable {
    let token: String
    let title: String
    let allowsReply: Bool

    var id: String { token }

    /// Titles are only a hint for the colour: Android sends a call's own actions first, in its own order
    /// (CallsWords in the Windows app, NotificationCall.swift on the Mac).
    enum Role { case answer, end, other }

    var role: Role {
        let t = title.lowercased()
        if ["decline", "reject", "hang up", "hangup", "end call", "отклонить", "сбросить", "завершить"].contains(where: t.contains) { return .end }
        if ["answer", "accept", "ответить", "принять"].contains(where: t.contains) { return .answer }
        return .other
    }
}

/// A one-time code found in a notification, on this device (codes.rs).
struct FoundCode: Equatable {
    let code: String
    let service: String
}

/// A phone notification while it is still on the phone. Kept in memory only, while Bridgey is open.
struct PhoneAlert: Identifiable, Equatable {
    let deviceID: String
    let notificationID: String
    var deviceName: String
    var packageName = ""
    var appName = ""
    var title = ""
    var text = ""
    var date = Date()
    /// The app's icon (PNG).
    var icon: Data?
    /// incoming, ongoing, screening or unknown for a call; nil for anything else.
    var callType: String?
    var actions: [AlertAction] = []
    /// The phone is alerting on another device: shown here, never announced.
    var quiet = false
    var code: FoundCode?
    /// Text messages: the phone answers this SMS itself when its app has no Reply of its own.
    var smsReply = false
    var smsThreadID: Int64?

    var id: String { deviceID + "\u{0}" + notificationID }
    var replyAction: AlertAction? { actions.first { $0.allowsReply } }
    var buttons: [AlertAction] { actions.filter { !$0.allowsReply } }
    var canReply: Bool { replyAction != nil || (smsReply && callType == nil) }
    var source: String { appName.isEmpty ? packageName : appName }

    /// From a Notification event's JSON (bridgey_core.h, BRIDGEY_EVENT_KIND_NOTIFICATION).
    init?(deviceID: String, deviceName: String, json j: [String: Any], quiet: Bool) {
        guard let id = j["notificationId"] as? String, !id.isEmpty else { return nil }
        self.deviceID = deviceID
        notificationID = id
        self.deviceName = deviceName
        packageName = j["packageName"] as? String ?? ""
        appName = j["applicationName"] as? String ?? ""
        title = (j["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        text = (j["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let ms = (j["timestamp"] as? NSNumber)?.int64Value, ms > 0 { date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
        icon = (j["icon"] as? String).flatMap { Data(base64Encoded: $0) }
        callType = j["callType"] as? String
        actions = (j["actions"] as? [[String: Any]] ?? []).compactMap { a in
            guard let token = a["token"] as? String, let title = a["title"] as? String, !token.isEmpty else { return nil }
            return AlertAction(token: token, title: title, allowsReply: a["allowsReply"] as? Bool ?? false)
        }
        self.quiet = quiet || j["quiet"] as? Bool == true
        if let c = j["code"] as? [String: Any], let code = c["code"] as? String, !code.isEmpty {
            self.code = FoundCode(code: code, service: c["service"] as? String ?? "")
        }
        smsReply = j["smsReply"] as? Bool ?? false
        smsThreadID = (j["smsThreadId"] as? NSNumber)?.int64Value
    }

    init(deviceID: String, notificationID: String, deviceName: String) {
        self.deviceID = deviceID
        self.notificationID = notificationID
        self.deviceName = deviceName
    }
}

/// The phone's call on its own card, with the phone's own buttons.
struct CallCard: Identifiable, Equatable {
    var alert: PhoneAlert
    /// When this device first saw it ongoing, for the timer.
    var since: Date?
    /// The phone took the notification away without saying the call ended: kept a moment, in case it posts again.
    var leaving = false

    var id: String { alert.id }
    var caller: String { alert.title.isEmpty ? alert.source : alert.title }
    var incoming: Bool { alert.callType == "incoming" }

    /// Up to two of the call's buttons, keeping an end button when there is one further on (CallsWords.VisibleActions).
    var buttons: [AlertAction] {
        var visible = Array(alert.actions.prefix(2))
        if !visible.isEmpty, !visible.contains(where: { $0.role == .end }), let end = alert.actions.dropFirst(2).first(where: { $0.role == .end }) {
            visible[visible.count - 1] = end
        }
        return visible
    }
}

/// A device this one is ringing, or that rings this one.
struct RingCard: Identifiable, Equatable {
    enum Direction: Equatable { case outgoing, incoming }
    let deviceID: String
    var deviceName: String
    var direction: Direction
    /// Outgoing: the other device said it is ringing (find.started).
    var confirmed = false

    var id: String { "\(direction == .outgoing ? "out" : "in")-\(deviceID)" }
}

/// The phone asks this device to advertise a Bluetooth LE service so Android's companion link can find it (codes).
protocol CompanionAdvertiser: AnyObject {
    /// Answers ok, or false with bluetooth_off, unauthorized, unsupported or failed.
    func start(service: String, seconds: TimeInterval, done: @escaping @MainActor (Bool, String?) -> Void)
    func stop(service: String)
}

/// The sound for a device ringing this one.
protocol Ringer: AnyObject {
    func start()
    func stop()
}

/// What the phone and other devices tell this one while it is open: notifications (with codes), the phone's call,
/// a device ringing this one, and this device's own battery and presence for them. Nothing is kept once Bridgey
/// stops: iOS ends the session soon after the app leaves the screen.
@MainActor
final class AlertsModel: ObservableObject, SessionFeature {
    /// Notifications kept while open, newest first.
    static let limit = 50
    /// How long a call stays after the phone took its notification away without saying it ended.
    static let removalGrace: TimeInterval = 2

    private(set) weak var app: AppModel?
    private var client: CoreClient?
    private var watchers: Set<AnyCancellable> = []
    private var removals: [String: Task<Void, Never>] = [:]

    @Published private(set) var notifications: [PhoneAlert] = []
    @Published private(set) var calls: [CallCard] = []
    @Published private(set) var rings: [RingCard] = []
    /// Whether each phone shows Bridgey the text of code messages: allowed, hidden or not_linked.
    @Published private(set) var codesStatus: [String: String] = [:]
    /// Connect away from home: off, disabled, connecting, unreachable or online.
    @Published private(set) var connectState = "off"
    /// Paired devices the control service says are online.
    @Published private(set) var connectOnline: [String] = []
    /// Reply drafts by notification.
    @Published var replies: [String: String] = [:]

    // Replaceable for tests.
    var copy: (String) -> Void = { UIPasteboard.general.string = $0 }
    var announce: (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }
    lazy var ringer: Ringer = ToneRinger()
    lazy var advertiser: CompanionAdvertiser = BluetoothAdvertiser()
    /// This device's battery: level 0 to 100 and charging, or nil when it can't tell (the simulator).
    var batteryReading: () -> (Int, Bool)? = {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        guard device.batteryLevel >= 0, device.batteryState != .unknown else { return nil }
        return (Int((device.batteryLevel * 100).rounded()), device.batteryState == .charging || device.batteryState == .full)
    }

    func attach(_ app: AppModel) {
        self.app = app
        let settings = app.settings
        settings.$battery.dropFirst().sink { [weak self] on in
            DispatchQueue.main.async { self?.reportBattery(on: on) }
        }.store(in: &watchers)
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reportBattery() }
            }.store(in: &watchers)
        }
    }

    func clientChanged(_ client: CoreClient?) {
        self.client = client
        guard client != nil else {
            // The session ended: nothing here can be acted on any more.
            stopRinging()
            for task in removals.values { task.cancel() }
            removals = [:]
            notifications = []
            calls = []
            rings = []
            replies = [:]
            codesStatus = [:]
            connectState = "off"
            connectOnline = []
            return
        }
        reportBattery()
        // Bridgey is open on screen: someone is using this device.
        try? client?.setPresence(state: 0, idleSeconds: 0)
    }

    func handle(_ e: CoreEvent) {
        switch e.kind {
        case .notification:
            guard let id = e.deviceID, let alert = PhoneAlert(deviceID: id, deviceName: name(id), json: e.json, quiet: e.status == 1) else { break }
            if alert.callType != nil { posted(call: alert) } else { posted(alert) }
        case .notificationRemoved:
            guard let id = e.deviceID, let notificationID = e.text else { break }
            removed(deviceID: id, notificationID: notificationID, callEnded: e.status == 1)
        case .codesStatus:
            if let id = e.deviceID, let status = e.text { codesStatus[id] = status }
        case .codesAdvertise:
            guard let id = e.deviceID, let service = e.text else { break }
            if e.status == 1 { advertise(deviceID: id, service: service) } else { advertiser.stop(service: service) }
        case .findRequested:
            guard let id = e.deviceID else { break }
            if e.status == 1 { ringHere(from: id) } else { stoppedHere(from: id) }
        case .findState:
            guard let id = e.deviceID else { break }
            if e.status == 1 {
                if let i = rings.firstIndex(where: { $0.deviceID == id && $0.direction == .outgoing }) {
                    rings[i].confirmed = true
                } else {
                    rings.append(RingCard(deviceID: id, deviceName: name(id), direction: .outgoing, confirmed: true))
                }
            } else {
                rings.removeAll { $0.deviceID == id && $0.direction == .outgoing }
            }
        case .connectState:
            connectState = e.text ?? "off"
            connectOnline = (e.extra?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        case .disconnected:
            guard let id = e.deviceID else { break }
            notifications.removeAll { $0.deviceID == id }
            calls.removeAll { $0.alert.deviceID == id }
            rings.removeAll { $0.deviceID == id && $0.direction == .outgoing }
            stoppedHere(from: id)
        case .trustChanged where e.status == 0:
            if let id = e.deviceID { codesStatus[id] = nil }
        case .features:
            // Battery may have just been turned on at either end.
            if e.deviceID != nil { reportBattery() }
        default:
            break
        }
    }

    private func name(_ id: String) -> String { app?.deviceName(id) ?? String(localized: "a device") }

    private func notice(_ text: String) { app?.notice = text }

    // MARK: Notifications

    private func posted(_ alert: PhoneAlert) {
        notifications.removeAll { $0.id == alert.id }
        notifications.insert(alert, at: 0)
        if notifications.count > Self.limit { notifications.removeLast(notifications.count - Self.limit) }
        // Quiet: the phone is alerting on the device in use.
        guard !alert.quiet else { return }
        if let code = alert.code {
            announce(String(localized: "Code \(code.code) from \(code.service.isEmpty ? alert.source : code.service)"))
        } else {
            announce(alert.title.isEmpty ? alert.source : String(localized: "\(alert.source): \(alert.title)"))
        }
    }

    private func removed(deviceID: String, notificationID: String, callEnded: Bool) {
        let key = deviceID + "\u{0}" + notificationID
        notifications.removeAll { $0.id == key }
        replies[key] = nil
        guard let i = calls.firstIndex(where: { $0.id == key }) else { return }
        if callEnded {
            calls.remove(at: i)
            return
        }
        // The dialer sometimes takes a call's notification away and posts it again: the card waits a moment.
        calls[i].leaving = true
        removals[key]?.cancel()
        removals[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.removalGrace))
            guard !Task.isCancelled else { return }
            self?.calls.removeAll { $0.id == key && $0.leaving }
            self?.removals[key] = nil
        }
    }

    /// Runs one of the phone's own buttons.
    func run(_ action: AlertAction, on alert: PhoneAlert) {
        do {
            try requireClient().notificationAction(alert.deviceID, notificationID: alert.notificationID, token: action.token, reply: nil)
        } catch {
            notice(failure(error, alert))
        }
    }

    /// Sends the reply typed under a notification: its app's own Reply, or Text messages through the phone.
    func reply(to alert: PhoneAlert) {
        let text = (replies[alert.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if let action = alert.replyAction {
                try requireClient().notificationAction(alert.deviceID, notificationID: alert.notificationID, token: action.token, reply: text)
            } else if alert.smsReply, let client {
                let answer = client.phone(.sms, deviceID: alert.deviceID, command: ["op": "send", "notificationId": alert.notificationID, "body": text])
                guard answer["ok"] as? Bool == true else {
                    notice(String(localized: "The reply didn’t go. Open Messages to try again."))
                    return
                }
            } else {
                return
            }
            replies[alert.id] = nil
            notice(String(localized: "Reply sent"))
        } catch {
            notice(failure(error, alert))
        }
    }

    func dismiss(_ alert: PhoneAlert) {
        notifications.removeAll { $0.id == alert.id }
        replies[alert.id] = nil
        try? client?.dismissNotification(alert.deviceID, notificationID: alert.notificationID)
    }

    func copyCode(_ alert: PhoneAlert) {
        guard let code = alert.code else { return }
        copy(code.code)
        notice(String(localized: "Code copied"))
    }

    private func failure(_ error: Error, _ alert: PhoneAlert) -> String {
        if let core = error as? CoreError, core.code == CoreError.notConnected || core.code == CoreError.stopped {
            return String(localized: "\(alert.deviceName) isn’t connected.")
        }
        return (error as? CoreError)?.localizedDescription ?? error.localizedDescription
    }

    // MARK: Calls

    private func posted(call alert: PhoneAlert) {
        removals[alert.id]?.cancel()
        removals[alert.id] = nil
        if let i = calls.firstIndex(where: { $0.id == alert.id }) {
            let wasIncoming = calls[i].incoming
            calls[i].alert = alert
            calls[i].leaving = false
            if alert.callType == "ongoing", calls[i].since == nil { calls[i].since = Date() }
            if !wasIncoming, calls[i].incoming, !alert.quiet { announceCall(calls[i]) }
        } else {
            let card = CallCard(alert: alert, since: alert.callType == "ongoing" ? Date() : nil)
            calls.append(card)
            if calls.count > 8 { calls.removeFirst(calls.count - 8) }
            if card.incoming, !alert.quiet { announceCall(card) }
        }
    }

    private func announceCall(_ card: CallCard) {
        announce(String(localized: "Incoming call on \(card.alert.deviceName): \(card.caller)"))
    }

    /// The card shown: an incoming call first, else the newest call the phone is alerting here.
    var call: CallCard? {
        calls.last { !$0.alert.quiet && $0.incoming } ?? calls.last { !$0.alert.quiet }
    }

    // MARK: Find device

    /// Rings a device until it is stopped there or here.
    func ring(_ device: DeviceItem) {
        do {
            try requireClient().find(device.id, ring: true)
            if !rings.contains(where: { $0.deviceID == device.id && $0.direction == .outgoing }) {
                rings.append(RingCard(deviceID: device.id, deviceName: device.name, direction: .outgoing))
            }
        } catch {
            if (error as? CoreError)?.code == CoreError.featureOff {
                notice(String(localized: "Find device is off on \(device.name) or on this \(UIDevice.current.localizedModel)."))
            } else {
                notice(String(localized: "\(device.name) isn’t connected."))
            }
        }
    }

    /// Stop on a ringing card: an outgoing ring stops there; a device ringing this one is told the person stopped it.
    func stop(_ ring: RingCard) {
        switch ring.direction {
        case .outgoing:
            try? client?.find(ring.deviceID, ring: false)
            rings.removeAll { $0.id == ring.id }
        case .incoming:
            try? client?.findStopped(ring.deviceID)
            stoppedHere(from: ring.deviceID)
        }
    }

    private func ringHere(from deviceID: String) {
        guard !rings.contains(where: { $0.deviceID == deviceID && $0.direction == .incoming }) else { return }
        rings.insert(RingCard(deviceID: deviceID, deviceName: name(deviceID), direction: .incoming), at: 0)
        ringer.start()
        announce(String(localized: "\(name(deviceID)) is ringing this \(UIDevice.current.localizedModel)"))
    }

    private func stoppedHere(from deviceID: String) {
        rings.removeAll { $0.deviceID == deviceID && $0.direction == .incoming }
        if !rings.contains(where: { $0.direction == .incoming }) { ringer.stop() }
    }

    private func stopRinging() {
        rings.removeAll { $0.direction == .incoming }
        ringer.stop()
    }

    // MARK: Codes

    /// The phone hides code messages from Bridgey until this device is linked as a companion on it.
    func needsLink(_ deviceID: String) -> Bool { ["hidden", "not_linked"].contains(codesStatus[deviceID]) }

    func link(_ deviceID: String) {
        do {
            try requireClient().codesLinkRequest(deviceID)
            notice(String(localized: "On \(name(deviceID)), tap Bridgey’s notification, then Allow."))
        } catch {
            notice(String(localized: "\(name(deviceID)) isn’t connected."))
        }
    }

    private func advertise(deviceID: String, service: String) {
        advertiser.start(service: service, seconds: 60) { [weak self] ok, reason in
            try? self?.client?.codesAdvertiseResult(deviceID, serviceUUID: service, ok: ok, reason: ok ? nil : reason)
            if !ok, reason == "bluetooth_off" {
                self?.notice(String(localized: "Turn on Bluetooth to link this \(UIDevice.current.localizedModel), then try again."))
            }
        }
    }

    // MARK: Battery

    /// This device's battery to paired devices, when Settings > Battery is on.
    func reportBattery(on: Bool? = nil) {
        guard let client else { return }
        let on = on ?? app?.settings.battery ?? true
        let reading = on ? batteryReading() : nil
        try? client.setBattery(level: reading?.0, charging: reading?.1 ?? false)
    }

    // MARK: Connect away from home

    /// The short status under Settings > Connect away from home.
    var connectText: String {
        switch connectState {
        case "online": String(localized: "On. Your devices can reach this \(UIDevice.current.localizedModel) from other networks while Bridgey is open.")
        case "connecting": String(localized: "Connecting…")
        case "unreachable": String(localized: "Can’t reach the Round Robin service right now. Devices on this Wi-Fi still connect.")
        case "disabled": String(localized: "On for devices this one has already reached.")
        default: String(localized: "Off. Only devices on this Wi-Fi connect.")
        }
    }

    private func requireClient() throws -> CoreClient {
        guard let client else { throw CoreError(code: CoreError.stopped) }
        return client
    }
}

// MARK: - The ringing sound

/// A loud repeating two-tone beep, made once in memory, played in the playback category so it sounds with the
/// Ring/Silent switch on. Only while Bridgey is open: iOS doesn't let it ring once the app has left the screen.
final class ToneRinger: Ringer {
    private var player: AVAudioPlayer?

    func start() {
        guard player?.isPlaying != true else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        player = try? AVAudioPlayer(data: Self.tone)
        player?.numberOfLoops = -1
        player?.volume = 1
        player?.play()
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 16-bit mono WAV: two short beeps (1,400 Hz then 1,050 Hz) and a pause, 1.2 seconds a loop.
    static let tone: Data = {
        let rate = 22_050
        var samples: [Int16] = []
        func beep(_ frequency: Double, _ seconds: Double) {
            let count = Int(Double(rate) * seconds)
            for n in 0..<count {
                // A short fade at each end avoids clicks.
                let edge = min(1, Double(min(n, count - n)) / 200)
                let value = sin(2 * .pi * frequency * Double(n) / Double(rate)) * 0.9 * edge
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        func silence(_ seconds: Double) { samples.append(contentsOf: Array(repeating: 0, count: Int(Double(rate) * seconds))) }
        beep(1_400, 0.25)
        silence(0.08)
        beep(1_050, 0.25)
        silence(0.62)
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for s in samples { put(s) }
        return data
    }()
}
