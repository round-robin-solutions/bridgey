import AppKit
import Foundation

/*
 * Mac actions, draft `mac_actions_draft1` (docs/protocol.md, "Mac actions"; design in
 * docs/automation.md). A paired phone picks one entry from the list this Mac published for it;
 * the Mac maps it to a fixed local operation. No shell, no arguments, no free-form text: the only
 * operand on the wire is the 0...100 level of `volume_set`.
 */

/// The feature key in `features.update`. Mirrors `BridgeyFeature.macActions`.
let macActionsFeatureKey = "mac_actions_draft1"
/// The Mac understands `quick.request` links `open` (Open on Mac from the phone's share sheet).
let linksOpenFeatureKey = "links_open_draft1"

enum MacSystemAction: String, CaseIterable, Equatable {
    case lock
    case sleep
    case screensaver
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case volumeMute = "volume_mute"
    case volumeSet = "volume_set"

    /// The Settings switch that allows it; the four volume actions share one.
    var setting: MacActionSwitch {
        switch self {
        case .lock: .lock
        case .sleep: .sleep
        case .screensaver: .screensaver
        case .volumeUp, .volumeDown, .volumeMute, .volumeSet: .volume
        }
    }

    var isVolume: Bool { setting == .volume }
}

/// The switches in Settings > Media and actions > Mac actions. All off until the person turns them on.
enum MacActionSwitch: String, CaseIterable, Codable, Identifiable {
    case lock, sleep, screensaver, volume
    var id: String { rawValue }
}

/// One identifier from the wire, parsed. Anything else is not an action.
enum MacActionID: Equatable {
    case system(MacSystemAction)
    case app(bundleID: String)
    case shortcut(handle: String)

    init?(wire: String) {
        guard wire.utf8.count <= 200 else { return nil }
        if let action = MacSystemAction(rawValue: wire) { self = .system(action); return }
        if wire.hasPrefix("app:") {
            let bundleID = String(wire.dropFirst(4))
            guard isValidBundleID(bundleID) else { return nil }
            self = .app(bundleID: bundleID)
            return
        }
        if wire.hasPrefix("shortcut:") {
            let handle = String(wire.dropFirst(9))
            guard isShortcutHandle(handle) else { return nil }
            self = .shortcut(handle: handle)
            return
        }
        return nil
    }

    var wire: String {
        switch self {
        case let .system(action): action.rawValue
        case let .app(bundleID): "app:\(bundleID)"
        case let .shortcut(handle): "shortcut:\(handle)"
        }
    }

    var isVolume: Bool { if case let .system(action) = self { return action.isVolume } else { return false } }
    var isShortcut: Bool { if case .shortcut = self { return true } else { return false } }
}

func isValidBundleID(_ value: String) -> Bool {
    guard (1...155).contains(value.utf8.count) else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-")
    }
}

/// A lowercase UUID, the local handle of an allowed Shortcut.
func isShortcutHandle(_ value: String) -> Bool {
    value.count == 36 && value == value.lowercased() && UUID(uuidString: value) != nil
}

/// A name for the wire and the list: control characters dropped, whitespace collapsed, at most 64.
func macActionTitle(_ value: String) -> String {
    let cleaned = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let text = String(String.UnicodeScalarView(cleaned))
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    return String(text.prefix(64))
}

struct AllowedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

struct AllowedShortcut: Codable, Equatable, Identifiable {
    /// The local handle (lowercase UUID) the phone sends; the name never goes on the wire from the phone.
    let id: String
    let name: String
}

/// What this Mac lets phones run. Kept in UserDefaults; nothing on by default.
struct MacActionsConfig: Codable, Equatable {
    static let maximumApps = 32
    static let maximumShortcuts = 32

    var switches: [MacActionSwitch: Bool] = [:]
    var apps: [AllowedApp] = []
    var shortcuts: [AllowedShortcut] = []

    func isOn(_ action: MacActionSwitch) -> Bool { switches[action] == true }

    /// The entry is on this Mac's list right now (its switch is on, or the app or Shortcut is listed).
    func allows(_ id: MacActionID) -> Bool {
        switch id {
        case let .system(action): isOn(action.setting)
        case let .app(bundleID): apps.contains { $0.bundleID == bundleID }
        case let .shortcut(handle): shortcuts.contains { $0.id == handle }
        }
    }

    mutating func addApp(_ app: AllowedApp) -> Bool {
        guard isValidBundleID(app.bundleID), !apps.contains(where: { $0.bundleID == app.bundleID }),
              apps.count < Self.maximumApps else { return false }
        apps.append(AllowedApp(bundleID: app.bundleID, name: macActionTitle(app.name).isEmpty ? app.bundleID : macActionTitle(app.name)))
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return true
    }

    mutating func addShortcut(named name: String, handle: String = UUID().uuidString.lowercased()) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1024, isShortcutHandle(handle),
              !shortcuts.contains(where: { $0.name == trimmed }), shortcuts.count < Self.maximumShortcuts else { return false }
        shortcuts.append(AllowedShortcut(id: handle, name: trimmed))
        shortcuts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return true
    }
}

extension MacActionsConfig {
    private enum StoredKeys: String, CodingKey { case switches, apps, shortcuts }

    /// Reads a stored config entry by entry (docs/upgrade-policy.md): a switch this build does not know (a newer
    /// build's), or an app or Shortcut that does not decode, is dropped on its own instead of every choice.
    /// `switches` is stored as JSONEncoder writes a dictionary with enum keys: a flat `[name, Bool, ...]` array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StoredKeys.self)
        var switches: [MacActionSwitch: Bool] = [:]
        if var list = try? container.nestedUnkeyedContainer(forKey: .switches) {
            while !list.isAtEnd {
                let name = try list.decode(LenientElement<String>.self).value
                guard !list.isAtEnd else { break }
                let value = try list.decode(LenientElement<Bool>.self).value
                if let name, let value, let item = MacActionSwitch(rawValue: name) { switches[item] = value }
            }
        }
        self.switches = switches
        apps = ((try? container.decode([LenientElement<AllowedApp>].self, forKey: .apps)) ?? []).compactMap(\.value)
            .filter { isValidBundleID($0.bundleID) }
        shortcuts = ((try? container.decode([LenientElement<AllowedShortcut>].self, forKey: .shortcuts)) ?? []).compactMap(\.value)
            .filter { isShortcutHandle($0.id) }
    }
}

struct MacVolumeState: Equatable {
    var level: Int
    var muted: Bool
    var payload: [String: Any] { ["level": min(max(level, 0), 100), "muted": muted] }
}

enum MacActionRefusal: String, Equatable {
    case notAllowed = "not_allowed"
    case invalid
    case rateLimited = "rate_limited"
    case busy
    case permissionRequired = "permission_required"
    case unavailable
    case failed
}

enum MacActionOutcome: Equatable {
    case done(volume: MacVolumeState? = nil)
    case refused(MacActionRefusal)
}

enum ShortcutRunOutcome: Equatable { case done, failed, timedOut, notFound }

/// The operating system side, behind a protocol so tests never lock, sleep or change the volume.
@MainActor
protocol MacSystemActing: AnyObject {
    /// macOS Accessibility, which posting the Lock Screen shortcut needs.
    var accessibilityTrusted: Bool { get }
    func lockScreen() -> Bool
    func sleepSystem() -> Bool
    func startScreenSaver() -> Bool
    func volume() -> MacVolumeState?
    func stepVolume(up: Bool) -> MacVolumeState?
    func toggleMute() -> MacVolumeState?
    func setVolume(_ level: Int) -> MacVolumeState?
    func isInstalled(bundleID: String) -> Bool
    func openApp(bundleID: String, completion: @escaping (Bool) -> Void)
    func runShortcut(named name: String, completion: @escaping (ShortcutRunOutcome) -> Void)
}

/// One `actions.run` as the Mac reads it (docs/protocol-contract.md): `version` 1, a UUID `requestId`, a
/// `sequence` from 1 to 2^53-1. `action` and `value` are checked later, against the catalog, so that a bad
/// identifier or level is answered `not_allowed` or `invalid` instead of being dropped.
struct MacActionRun: Equatable {
    static let maximumBytes = 1024

    enum Value: Equatable {
        case absent
        case integer(Int)
        /// Present but not an integral number (a string, a fraction, a boolean, an object).
        case other
    }

    let requestID: String
    let action: String?
    let sequence: Int
    let value: Value

    init?(payload: [String: Any]) {
        guard jsonInteger(payload["version"]) == 1,
              let requestID = payload["requestId"] as? String, UUID(uuidString: requestID) != nil,
              let sequence = jsonInteger(payload["sequence"]), (1...9_007_199_254_740_991).contains(sequence) else { return nil }
        self.requestID = requestID
        action = payload["action"] as? String
        self.sequence = sequence
        switch payload["value"] {
        case nil, is NSNull: value = .absent
        case let raw: value = jsonInteger(raw).map(Value.integer) ?? .other
        }
    }

    /// The decrypted plaintext: at most 1 KiB of strict JSON, else nil (dropped without an answer).
    static func decode(_ data: Data) -> MacActionRun? {
        guard data.count <= maximumBytes, isStrictJSONObject(data),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return MacActionRun(payload: payload)
    }
}

/// The `actions.result` plaintext for one run: `status` done or refused, the reason, and the new volume.
func macActionResultPayload(_ outcome: MacActionOutcome, requestID: String, wire: String) -> [String: Any] {
    var reply: [String: Any] = ["version": 1, "requestId": requestID, "action": String(wire.prefix(200))]
    switch outcome {
    case let .done(volume):
        reply["status"] = "done"
        if let volume { reply["volume"] = volume.payload }
    case let .refused(refusal):
        reply["status"] = "refused"
        reply["reason"] = refusal.rawValue
    }
    return reply
}

/// Per phone: volume 10 at once then 5 a second; everything else 3 at once then one every 2 seconds.
struct MacActionRateLimiter: Equatable {
    private var volume = TokenBucket(ratePerSecond: 5, capacity: 10)
    private var other = TokenBucket(ratePerSecond: 0.5, capacity: 3)

    mutating func allow(_ id: MacActionID, at now: TimeInterval) -> Bool {
        id.isVolume ? volume.allow(at: now) : other.allow(at: now)
    }
}

/// The `actions.catalog` entries this Mac would send a phone now.
func macActionsCatalogEntries(_ config: MacActionsConfig, accessibilityTrusted: Bool) -> [[String: Any]] {
    var entries: [[String: Any]] = []
    for action in [MacSystemAction.lock, .sleep, .screensaver] where config.isOn(action.setting) {
        var entry: [String: Any] = ["id": action.rawValue, "title": macSystemActionTitle(action)]
        if action == .lock && !accessibilityTrusted { entry["blocked"] = MacActionRefusal.permissionRequired.rawValue }
        entries.append(entry)
    }
    if config.isOn(.volume) {
        for action in [MacSystemAction.volumeDown, .volumeMute, .volumeUp, .volumeSet] {
            entries.append(["id": action.rawValue, "title": macSystemActionTitle(action)])
        }
    }
    for app in config.apps { entries.append(["id": MacActionID.app(bundleID: app.bundleID).wire, "title": macActionTitle(app.name)]) }
    for shortcut in config.shortcuts {
        let title = macActionTitle(shortcut.name)
        entries.append(["id": MacActionID.shortcut(handle: shortcut.id).wire, "title": title.isEmpty ? "Shortcut" : title])
    }
    return Array(entries.prefix(64))
}

func macSystemActionTitle(_ action: MacSystemAction) -> String {
    switch action {
    case .lock: L10n.text("actions.lock", fallback: "Lock screen")
    case .sleep: L10n.text("actions.sleep", fallback: "Sleep")
    case .screensaver: L10n.text("actions.screensaver", fallback: "Start screen saver")
    case .volumeUp: L10n.text("actions.volumeUp", fallback: "Volume up")
    case .volumeDown: L10n.text("actions.volumeDown", fallback: "Volume down")
    case .volumeMute: L10n.text("actions.volumeMute", fallback: "Mute")
    case .volumeSet: L10n.text("actions.volumeSet", fallback: "Set volume")
    }
}

/// Persists `MacActionsConfig` (one JSON value) and the Open links right away switch.
final class MacActionsConfigStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "settings.macActions.config") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> MacActionsConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(MacActionsConfig.self, from: data) else { return MacActionsConfig() }
        return config
    }

    func save(_ config: MacActionsConfig) {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: key) }
    }
}

/**
 * The Mac side of Mac actions. Requests arrive decrypted from the coordinator (after the outer
 * replay window); this checks the sequence, the grant, the list and the rate limit, runs the
 * operation through `MacSystemActing`, answers `actions.result` and writes the audit log.
 */
@MainActor
final class MacActionsHost: ObservableObject {
    @Published private(set) var config: MacActionsConfig
    let audit: MacActionsAuditLog

    /// Mac actions is on here for this phone (global and granted) and on the phone (its key).
    var isAllowed: (String) -> Bool = { _ in false }
    /// Sends a payload to one phone; false when it is not connected.
    var send: (String, String, [String: Any]) -> Bool = { _, _, _ in false }
    /// The list or a switch changed: the coordinator sends a fresh catalog to every phone.
    var onCatalogChange: () -> Void = {}

    private let system: MacSystemActing
    private let store: MacActionsConfigStore?
    private let clock: () -> Date
    private let sleepDelay: TimeInterval
    private var sequences: [String: Int] = [:]
    private var limiters: [String: MacActionRateLimiter] = [:]
    private var shortcutRunning = false

    init(system: MacSystemActing, store: MacActionsConfigStore? = MacActionsConfigStore(),
         audit: MacActionsAuditLog? = nil, clock: @escaping () -> Date = Date.init,
         sleepDelay: TimeInterval = 1) {
        self.system = system
        self.store = store
        self.audit = audit ?? MacActionsAuditLog()
        self.clock = clock
        self.sleepDelay = sleepDelay
        config = store?.load() ?? MacActionsConfig()
    }

    static func live() -> MacActionsHost { MacActionsHost(system: LiveMacSystemActions()) }

    var accessibilityTrusted: Bool { system.accessibilityTrusted }

    /// The `actions.catalog` payload for a phone. Volume is included when it is allowed and readable.
    func catalogPayload() -> [String: Any] {
        var payload: [String: Any] = ["version": 1, "actions": macActionsCatalogEntries(config, accessibilityTrusted: system.accessibilityTrusted)]
        if config.isOn(.volume), let volume = system.volume() { payload["volume"] = volume.payload }
        return payload
    }

    // MARK: Settings

    func setSwitch(_ action: MacActionSwitch, enabled: Bool) {
        config.switches[action] = enabled
        changed()
    }

    /// Adds apps chosen in the open panel; returns how many were added.
    @discardableResult
    func addApps(_ apps: [AllowedApp]) -> Int {
        var added = 0
        for app in apps where config.addApp(app) { added += 1 }
        if added > 0 { changed() }
        return added
    }

    func removeApp(bundleID: String) {
        config.apps.removeAll { $0.bundleID == bundleID }
        changed()
    }

    @discardableResult
    func addShortcut(named name: String) -> Bool {
        guard config.addShortcut(named: name) else { return false }
        changed()
        return true
    }

    func removeShortcut(id: String) {
        config.shortcuts.removeAll { $0.id == id }
        changed()
    }

    private func changed() {
        store?.save(config)
        onCatalogChange()
    }

    // MARK: Requests

    /// A phone's session ended: its sequence starts again with the next session.
    func disconnected(deviceID: String) {
        sequences.removeValue(forKey: deviceID)
    }

    func receive(kind: String, payload: [String: Any], deviceID: String, deviceName: String) {
        guard kind == "actions.run", let run = MacActionRun(payload: payload) else { return }
        receive(run, deviceID: deviceID, deviceName: deviceName)
    }

    func receive(_ request: MacActionRun, deviceID: String, deviceName: String) {
        guard request.sequence > sequences[deviceID, default: 0] else { return }
        sequences[deviceID] = request.sequence
        let requestID = request.requestID
        let wire = request.action ?? ""
        let parsed = MacActionID(wire: wire)
        let finish: (MacActionOutcome) -> Void = { [weak self] outcome in
            self?.finish(outcome, requestID: requestID, wire: wire, id: parsed, deviceID: deviceID, deviceName: deviceName)
        }
        guard isAllowed(deviceID), let id = parsed, config.allows(id) else { finish(.refused(.notAllowed)); return }
        let level: Int?
        if case .system(.volumeSet) = id {
            guard case let .integer(number) = request.value, (0...100).contains(number) else { finish(.refused(.invalid)); return }
            level = number
        } else {
            guard request.value == .absent else { finish(.refused(.invalid)); return }
            level = nil
        }
        var limiter = limiters[deviceID] ?? MacActionRateLimiter()
        let allowed = limiter.allow(id, at: clock().timeIntervalSince1970)
        limiters[deviceID] = limiter
        guard allowed else { finish(.refused(.rateLimited)); return }
        run(id, level: level, completion: finish)
    }

    private func run(_ id: MacActionID, level: Int?, completion: @escaping (MacActionOutcome) -> Void) {
        switch id {
        case .system(.lock):
            guard system.accessibilityTrusted else { completion(.refused(.permissionRequired)); return }
            completion(system.lockScreen() ? .done() : .refused(.failed))
        case .system(.sleep):
            // Answer first: the network goes when the Mac sleeps.
            completion(.done())
            let system = system
            DispatchQueue.main.asyncAfter(deadline: .now() + sleepDelay) { _ = system.sleepSystem() }
        case .system(.screensaver):
            completion(system.startScreenSaver() ? .done() : .refused(.failed))
        case .system(.volumeUp), .system(.volumeDown):
            completion(volumeOutcome(system.stepVolume(up: id == .system(.volumeUp))))
        case .system(.volumeMute):
            completion(volumeOutcome(system.toggleMute()))
        case .system(.volumeSet):
            completion(volumeOutcome(system.setVolume(level ?? 0)))
        case let .app(bundleID):
            guard system.isInstalled(bundleID: bundleID) else { completion(.refused(.unavailable)); return }
            system.openApp(bundleID: bundleID) { completion($0 ? .done() : .refused(.failed)) }
        case let .shortcut(handle):
            guard let shortcut = config.shortcuts.first(where: { $0.id == handle }) else { completion(.refused(.notAllowed)); return }
            guard !shortcutRunning else { completion(.refused(.busy)); return }
            shortcutRunning = true
            system.runShortcut(named: shortcut.name) { [weak self] outcome in
                self?.shortcutRunning = false
                switch outcome {
                case .done: completion(.done())
                case .notFound: completion(.refused(.unavailable))
                case .failed, .timedOut: completion(.refused(.failed))
                }
            }
        }
    }

    private func volumeOutcome(_ state: MacVolumeState?) -> MacActionOutcome {
        state.map { .done(volume: $0) } ?? .refused(.unavailable)
    }

    private func finish(_ outcome: MacActionOutcome, requestID: String, wire: String, id: MacActionID?, deviceID: String, deviceName: String) {
        let reason: MacActionRefusal?
        if case let .refused(refusal) = outcome { reason = refusal } else { reason = nil }
        _ = send(deviceID, "actions.result", macActionResultPayload(outcome, requestID: requestID, wire: wire))
        audit.record(MacActionAuditEntry(
            id: requestID, deviceID: deviceID, deviceName: deviceName,
            action: id?.wire ?? "unknown", title: id.map(auditTitle) ?? "",
            outcome: reason?.rawValue ?? "done", at: clock()
        ))
    }

    private func auditTitle(_ id: MacActionID) -> String {
        switch id {
        case let .system(action): macSystemActionTitle(action)
        case let .app(bundleID): config.apps.first { $0.bundleID == bundleID }?.name ?? bundleID
        case let .shortcut(handle): config.shortcuts.first { $0.id == handle }.map { macActionTitle($0.name) } ?? ""
        }
    }
}
