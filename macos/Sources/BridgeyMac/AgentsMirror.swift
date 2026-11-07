import Foundation

/*
 * Agent devices, the Mac's side (docs/protocol.md "Draft: agent devices", "Messages between the phone and the Mac").
 * Agents (the bridgey command on servers) pair only with the phone, which holds every grant. This Mac:
 * - advertises agents_mirror_draft1 to each phone,
 * - sends codes.found to the phone a code came from, for every code it shows from that phone's text messages or
 *   mail, but only while that phone's latest agents.state (received in this session) lists an agent with Codes on,
 * - shows agents.state on Settings > Devices ("Agents on <phone>"), switches sending agents.grant_set,
 * - keeps codes.read in a small owner-only log (agents-codes-activity.json), never the code.
 * Codes and message text are never logged here.
 */

/// The six agent draft keys, in the order knownDraftFeatureKeys lists them.
let agentFeatureKey = "agent_draft1"
let agentNotifyFeatureKey = "notify_draft1"
let agentAskFeatureKey = "ask_draft1"
let agentClipboardRequestFeatureKey = "clipboard_request_draft1"
let agentCodesFeatureKey = "agent_codes_draft1"
/// The phone and this Mac set it for each other whenever both support it: agents.*, codes.found, codes.read.
let agentsMirrorFeatureKey = "agents_mirror_draft1"
/// Detect codes (docs/mesh-and-codes.md): between the phone and its agents only; the Mac reads it and shows the grant.
let codesDetectFeatureKey = "codes_detect_draft1"

// MARK: - Grants

/// A grant, in the order of the wording table (docs/agent-cli-wording.md), which is the order rows are shown.
enum AgentGrantKey: String, CaseIterable, Codable, Equatable {
    case files, clipboard
    case clipboardRequest = "clipboard_request"
    case notify, ask, ring, battery, codes
    case codesDetect = "codes_detect"
    case notifications

    /// Supported grants remain off until the phone owner enables them.
    var grantable: Bool { true }

    /// Detect codes sends code text messages to a server, so only a tap on the phone changes it; this Mac shows it.
    var changeableFromMac: Bool { grantable && self != .codesDetect }
}

enum AgentGrantState: String, Codable, Equatable {
    case on, off, waiting
}

/// How long a grant stays on. `today` ends at midnight on the phone.
enum AgentGrantWindow: String, CaseIterable, Codable, Equatable {
    case oneHour = "1h"
    case today
    case sevenDays = "7d"
    case forever
}

struct AgentGrant: Codable, Equatable {
    let key: AgentGrantKey
    let state: AgentGrantState
    var window: AgentGrantWindow?
    var grantedAt: Int64?
    var expiresAt: Int64?
    /// Files: the folder on the phone.
    var scope: String?

    /// On at `now`: a grant whose window has ended reads as off until the phone says so.
    func isOn(at now: Date) -> Bool {
        state == .on && (expiresAt.map { $0 > unixMillis(now) } ?? true)
    }

    /// The fields a decoder keeps, as in protocol/test-vectors/agent-v1.json.
    var wireObject: [String: Any] {
        var object: [String: Any] = ["key": key.rawValue, "state": state.rawValue]
        if let window { object["window"] = window.rawValue }
        if let grantedAt { object["grantedAt"] = grantedAt }
        if let expiresAt { object["expiresAt"] = expiresAt }
        if let scope { object["scope"] = scope }
        return object
    }
}

/// One audit entry from the phone (the newest 50 per agent ride in agents.state). Never codes or message text.
struct AgentActivityEntry: Codable, Equatable {
    static let actions: Set<String> = [
        "pair", "grant.change", "grant.request", "grant.expired", "notify", "ask", "answer", "ring", "ping", "battery",
        "clipboard.set", "clipboard.request", "files.receive", "codes.read", "codes.detect", "notifications.read", "forget",
    ]

    let at: Int64
    let action: String
    let outcome: String
    var detail: String?
}

/// One agent device as the phone describes it in agents.state.
struct AgentDevice: Codable, Equatable, Identifiable {
    let deviceId: String
    let name: String
    let platform: String
    let app: String
    let os: String
    let pairedAt: Int64
    var lastSeenAt: Int64?
    let online: Bool
    var route: String?
    let grants: [AgentGrant]
    let activity: [AgentActivityEntry]

    var id: String { deviceId }

    func grant(_ key: AgentGrantKey) -> AgentGrant? { grants.first { $0.key == key } }
}

/// codes.read from the phone: an agent read codes this Mac found. Never the code.
struct AgentCodesRead: Equatable {
    let deviceId: String
    let deviceName: String
    let service: String
    let source: CodeChannel
    let app: String
    let at: Int64
    let count: Int
}

func unixMillis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

// MARK: - Wire

enum AgentsMirrorWire {
    /// Plaintext limits (protocol/messages.json).
    static let agentsStateMaximumBytes = 49_152
    static let codesReadMaximumBytes = 1_024
    static let codesFoundMaximumBytes = 1_024
    static let grantSetMaximumBytes = 512
    static let maximumActivity = 50

    /// The mail apps codes.found names, by Android package.
    static let mailApps: [String: String] = [
        "com.google.android.gm": "gmail",
        "com.microsoft.office.outlook": "outlook",
        "ch.protonmail.android": "proton",
        "com.readdle.spark": "spark",
    ]
    static let apps: Set<String> = ["messages", "gmail", "outlook", "proton", "spark"]

    /// codes.found's `app`: `messages` for a text message, the mail app for mail, nil for a mail app it cannot name.
    static func app(packageName: String, channel: CodeChannel) -> String? {
        channel == .sms ? "messages" : mailApps[packageName]
    }

    /// A grants array (agent.grants and each agent in agents.state): unknown keys and fields are skipped, an unknown
    /// state reads as off. Nil when it is not an array.
    static func grants(_ value: Any?) -> [AgentGrant]? {
        guard let items = value as? [Any] else { return nil }
        var grants: [AgentGrant] = []
        for item in items {
            guard let object = item as? [String: Any], let raw = object["key"] as? String,
                  let key = AgentGrantKey(rawValue: raw), !grants.contains(where: { $0.key == key }) else { continue }
            let state = (object["state"] as? String).flatMap(AgentGrantState.init(rawValue:)) ?? .off
            var grant = AgentGrant(key: key, state: state)
            grant.window = (object["window"] as? String).flatMap(AgentGrantWindow.init(rawValue:))
            grant.grantedAt = jsonInteger(object["grantedAt"]).map(Int64.init)
            grant.expiresAt = jsonInteger(object["expiresAt"]).map(Int64.init)
            if let scope = object["scope"] as? String { grant.scope = cleanText(scope, limit: 256) }
            grants.append(grant)
        }
        return grants
    }

    /// The `{version, grants}` plaintext of agent.grants, decoded as this Mac decodes each agent's grants.
    static func grantsPayload(_ plaintext: Data) -> [AgentGrant]? {
        guard let object = jsonObject(plaintext, limit: 8_192), jsonInteger(object["version"]) == 1 else { return nil }
        return grants(object["grants"])
    }

    /// agents.state: nil drops the message (the previous state stays). An agent without an ID, a name, `online`
    /// or a grants array is skipped; unknown activity actions are skipped.
    static func agentsState(_ plaintext: Data) -> [AgentDevice]? {
        guard let object = jsonObject(plaintext, limit: agentsStateMaximumBytes), jsonInteger(object["version"]) == 1,
              let items = object["agents"] as? [Any] else { return nil }
        var agents: [AgentDevice] = []
        for item in items {
            guard let agent = item as? [String: Any],
                  let id = agent["deviceId"] as? String, !id.isEmpty, id.count <= 128,
                  !agents.contains(where: { $0.deviceId == id }),
                  let online = jsonBool(agent["online"]),
                  let grants = grants(agent["grants"]) else { continue }
            let activity = (agent["activity"] as? [Any] ?? []).compactMap(activityEntry).prefix(maximumActivity)
            agents.append(AgentDevice(
                deviceId: id,
                name: sanitizedPeerName(agent["name"] as? String, fallback: "Agent"),
                platform: cleanText(agent["platform"] as? String ?? "cli", limit: 16),
                app: cleanText(agent["app"] as? String ?? "", limit: 64),
                os: cleanText(agent["os"] as? String ?? "", limit: 64),
                pairedAt: jsonInteger(agent["pairedAt"]).map(Int64.init) ?? 0,
                lastSeenAt: jsonInteger(agent["lastSeenAt"]).map(Int64.init),
                online: online,
                route: (agent["route"] as? String).map { cleanText($0, limit: 32) },
                grants: grants,
                activity: Array(activity)
            ))
        }
        return agents
    }

    static func activityEntry(_ value: Any) -> AgentActivityEntry? {
        guard let object = value as? [String: Any], let at = jsonInteger(object["at"]),
              let action = object["action"] as? String, AgentActivityEntry.actions.contains(action),
              let outcome = object["outcome"] as? String else { return nil }
        return AgentActivityEntry(at: Int64(at), action: action, outcome: cleanText(outcome, limit: 64),
                                  detail: (object["detail"] as? String).map { cleanText($0, limit: 240) })
    }

    /// codes.read: nil when malformed.
    static func codesRead(_ plaintext: Data) -> AgentCodesRead? {
        guard let object = jsonObject(plaintext, limit: codesReadMaximumBytes), jsonInteger(object["version"]) == 1,
              let id = object["deviceId"] as? String, !id.isEmpty, id.count <= 128,
              let service = object["service"] as? String, service.count <= 64,
              let source = (object["source"] as? String).flatMap(CodeChannel.init(rawValue:)),
              let app = object["app"] as? String, app.count <= 32,
              let at = jsonInteger(object["at"]), at > 0,
              let count = jsonInteger(object["count"]), (1...1_000).contains(count) else { return nil }
        return AgentCodesRead(deviceId: id, deviceName: sanitizedPeerName(object["deviceName"] as? String, fallback: "Agent"),
                              service: cleanText(service, limit: 64), source: source, app: cleanText(app, limit: 32),
                              at: Int64(at), count: count)
    }

    /// codes.found's plaintext, or nil when a field is outside the contract (then nothing is sent).
    static func codesFound(foundId: String, code: String, service: String, serviceKey: String, source: CodeChannel,
                           app: String, notificationId: String, postedAt: Int64) -> Data? {
        guard (4...12).contains(code.count), apps.contains(app), (source == .sms) == (app == "messages"),
              !notificationId.isEmpty, notificationId.count <= 512, postedAt > 0 else { return nil }
        let shown = String(service.prefix(64))
        // A sender with no known service (a bare number) has no service key: the phone needs one, so the sender
        // itself, lowercased, stands in for it (the same code from the same sender still folds into one).
        let fallback = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = String((serviceKey.isEmpty ? fallback : serviceKey).prefix(64))
        guard !shown.isEmpty, !key.isEmpty else { return nil }
        let payload: [String: Any] = [
            "version": 1, "foundId": foundId, "code": code, "service": shown, "serviceKey": key,
            "source": source.rawValue, "app": app, "notificationId": notificationId, "postedAt": postedAt,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              data.count <= codesFoundMaximumBytes else { return nil }
        return data
    }

    /// agents.grant_set's payload, or nil: on needs a window; Detect codes stays phone-only.
    static func grantSet(requestId: String, deviceId: String, key: AgentGrantKey, on: Bool, window: AgentGrantWindow?) -> [String: Any]? {
        guard !deviceId.isEmpty, key != .codesDetect, !on || (window != nil && key.grantable) else { return nil }
        var payload: [String: Any] = ["version": 1, "requestId": requestId, "deviceId": deviceId, "key": key.rawValue, "on": on]
        if on, let window { payload["window"] = window.rawValue }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= grantSetMaximumBytes else { return nil }
        return payload
    }

    private static func jsonObject(_ data: Data, limit: Int) -> [String: Any]? {
        guard data.count <= limit, isStrictJSONObject(data) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Text from the phone shown as plain text: no control or bidi characters, at most `limit` characters.
    static func cleanText(_ text: String, limit: Int) -> String {
        let cleaned = sanitizedPeerName(text, fallback: "")
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }
}

// MARK: - Rules

enum AgentsMirrorRules {
    /// codes.found goes to a phone only while it supports the mirror and its latest agents.state, received in this
    /// session, lists an agent with Codes on.
    static func sendsCodesFound(peerSupports: Bool, stateThisSession: Bool, agents: [AgentDevice]?, now: Date) -> Bool {
        guard peerSupports, stateThisSession, let agents else { return false }
        return agents.contains { $0.grant(.codes)?.isOn(at: now) == true }
    }

    /// What a switch shows: a change waiting for the phone wins over the last state.
    static func shownOn(_ grant: AgentGrant?, pending: AgentGrantPending?, now: Date) -> Bool {
        pending?.on ?? (grant?.isOn(at: now) == true)
    }
}

/// A switch flipped here, waiting for the phone's next agents.state (5 seconds, then the switch goes back).
struct AgentGrantPending: Equatable {
    static let timeout: TimeInterval = 5

    let requestId: String
    let on: Bool
    let sentAt: Date
}

// MARK: - The codes.read log

/// One codes.read, kept on this Mac. Never the code.
struct AgentCodesReadEntry: Codable, Equatable, Identifiable {
    let id: String
    /// The phone it came through, and the agent.
    let phoneID: String
    let agentID: String
    let agentName: String
    let service: String
    let source: CodeChannel
    let app: String
    let at: Date
    let count: Int
}

extension CodeChannel: Codable {}

/// `agents-codes-activity.json` in Application Support: owner-only (0600), at most 2,000 entries or 90 days. Not part
/// of diagnostics.
final class AgentCodesReadStore {
    static let fileName = "agents-codes-activity.json"
    static let maximumAge: TimeInterval = 90 * 24 * 60 * 60
    static let maximumEntries = 2_000

    let fileURL: URL

    init(fileURL: URL = AgentsMirrorFiles.url(AgentCodesReadStore.fileName)) {
        self.fileURL = fileURL
    }

    func load(now: Date) -> [AgentCodesReadEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let elements = try? AgentsMirrorFiles.decoder.decode([LenientElement<AgentCodesReadEntry>].self, from: data) else { return [] }
        let decoded = elements.compactMap(\.value)
        let kept = Self.bounded(decoded, now: now)
        if kept != decoded || elements.count != decoded.count { save(kept) }
        return kept
    }

    func save(_ entries: [AgentCodesReadEntry]) {
        guard let data = try? AgentsMirrorFiles.encoder.encode(entries) else { return }
        AgentsMirrorFiles.writeOwnerOnly(data, to: fileURL)
    }

    func clear() { try? FileManager.default.removeItem(at: fileURL) }

    /// Newest first, nothing older than 90 days, at most 2,000.
    static func bounded(_ entries: [AgentCodesReadEntry], now: Date) -> [AgentCodesReadEntry] {
        let oldest = now.addingTimeInterval(-maximumAge)
        return Array(entries.filter { $0.at >= oldest }.sorted { $0.at > $1.at }.prefix(maximumEntries))
    }
}

/// The last agents.state from each phone, so a phone that is not connected shows its last known state (read-only).
/// `agents-state.json`, owner-only like the log. Never codes.
struct AgentsMirrorPhoneState: Codable, Equatable {
    var agents: [AgentDevice]
    var receivedAt: Date
}

final class AgentsMirrorStateStore {
    static let fileName = "agents-state.json"

    let fileURL: URL

    init(fileURL: URL = AgentsMirrorFiles.url(AgentsMirrorStateStore.fileName)) {
        self.fileURL = fileURL
    }

    func load() -> [String: AgentsMirrorPhoneState] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? AgentsMirrorFiles.decoder.decode([String: AgentsMirrorPhoneState].self, from: data)) ?? [:]
    }

    func save(_ phones: [String: AgentsMirrorPhoneState]) {
        guard !phones.isEmpty else { return clear() }
        guard let data = try? AgentsMirrorFiles.encoder.encode(phones) else { return }
        AgentsMirrorFiles.writeOwnerOnly(data, to: fileURL)
    }

    func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

enum AgentsMirrorFiles {
    static func url(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/\(name)")
    }

    /// Written to a 0600 temporary file and renamed, so the file is never readable by others, even for a moment.
    static func writeOwnerOnly(_ data: Data, to fileURL: URL) {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, fileURL.path) != 0 {
            try? manager.removeItem(at: temporary)
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

// MARK: - The mirror

/// What this Mac knows about the agents on each phone, the changes waiting for the phone, and the codes.read log.
@MainActor
final class AgentsMirror: ObservableObject {
    @Published private(set) var phones: [String: AgentsMirrorPhoneState]
    @Published private(set) var codeReads: [AgentCodesReadEntry]
    /// Switches flipped here, by phone, agent and grant (`AgentsMirror.pendingKey`).
    @Published private(set) var pending: [String: AgentGrantPending] = [:]

    private let stateStore: AgentsMirrorStateStore?
    private let logStore: AgentCodesReadStore?
    private let clock: () -> Date

    init(stateStore: AgentsMirrorStateStore? = AgentsMirrorStateStore(), logStore: AgentCodesReadStore? = AgentCodesReadStore(),
         clock: @escaping () -> Date = Date.init) {
        self.stateStore = stateStore
        self.logStore = logStore
        self.clock = clock
        phones = stateStore?.load() ?? [:]
        codeReads = logStore?.load(now: clock()) ?? []
    }

    static func pendingKey(phone: String, agent: String, key: AgentGrantKey) -> String { "\(phone)|\(agent)|\(key.rawValue)" }

    func agents(on phoneID: String) -> [AgentDevice]? { phones[phoneID]?.agents }

    /// A new agents.state: it replaces the phone's agents and settles every change waiting for that phone.
    func received(_ agents: [AgentDevice], from phoneID: String) {
        phones[phoneID] = AgentsMirrorPhoneState(agents: agents, receivedAt: clock())
        pending = pending.filter { !$0.key.hasPrefix(phoneID + "|") }
        stateStore?.save(phones)
    }

    /// A switch flipped here; it goes back after five seconds unless agents.state settles it first.
    func setPending(phone: String, agent: String, key: AgentGrantKey, on: Bool, requestId: String) {
        let slot = Self.pendingKey(phone: phone, agent: agent, key: key)
        pending[slot] = AgentGrantPending(requestId: requestId, on: on, sentAt: clock())
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentGrantPending.timeout) { [weak self] in
            self?.expirePending(slot, requestId: requestId)
        }
    }

    func expirePending(_ slot: String, requestId: String) {
        if pending[slot]?.requestId == requestId { pending[slot] = nil }
    }

    func record(_ read: AgentCodesRead, phoneID: String) {
        let entry = AgentCodesReadEntry(id: UUID().uuidString.lowercased(), phoneID: phoneID, agentID: read.deviceId, agentName: read.deviceName,
                                        service: read.service, source: read.source, app: read.app,
                                        at: Date(timeIntervalSince1970: TimeInterval(read.at) / 1000), count: read.count)
        codeReads = AgentCodesReadStore.bounded([entry] + codeReads, now: clock())
        logStore?.save(codeReads)
    }

    /// A forgotten phone takes its agents and their log with it.
    func forget(_ phoneID: String) {
        phones[phoneID] = nil
        pending = pending.filter { !$0.key.hasPrefix(phoneID + "|") }
        codeReads.removeAll { $0.phoneID == phoneID }
        stateStore?.save(phones)
        logStore?.save(codeReads)
    }

    /// Settings > Privacy > Reset: activity and logs.
    func clear() {
        phones = [:]
        pending = [:]
        codeReads = []
        stateStore?.clear()
        logStore?.clear()
    }
}
