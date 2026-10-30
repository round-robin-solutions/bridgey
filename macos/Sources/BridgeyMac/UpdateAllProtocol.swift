import Foundation

/*
 * Update all, draft `updates_draft1` (docs/protocol.md "Update all"). Each device tells the devices
 * connected to it its version, channel and where its own update stands (`updates.status`); Update all
 * asks a device to update itself from its own channel (`updates.start`, answered by `updates.result`).
 * The start names no version, URL or file: the receiver checks its own feed and installs only through
 * its own signed updater (Sparkle with EdDSA on the Mac), so a downgrade is impossible this way.
 * Android has the same decoders in UpdateAllProtocol.kt; both read protocol/test-vectors alike.
 */

let updatesFeatureKey = "updates_draft1"

enum UpdatePlatform: String, Codable, Equatable {
    case android, macos
}

enum PeerUpdateState: String, Codable, Equatable {
    case current, checking, available, downloading, ready, installing
    case needsUser = "needs_user"
    case failed, manual
}

/// Why a device needs its person (`needs_user`) or why its last attempt stopped (`failed`).
enum PeerUpdateReason: String, Codable, Equatable {
    case confirm, permission, check, download, safety, installer, cancelled
    case notApplied = "not_applied"
    case other
}

/// What the person is doing on a device, so an automatic Update all waits (`updates.status` `busy`).
/// Unknown values read as `other`, which still counts as busy.
enum UpdateBusy: String, Codable, Equatable, CaseIterable {
    case call
    case screenShare = "screen_share"
    case remoteControl = "remote_control"
    case transfer
    case phoneFiles = "phone_files"
    case setup
    case other

    /// The one a device reports when several are going: a call first, then control, sharing, setup, downloads, transfers.
    static let order: [UpdateBusy] = [.call, .remoteControl, .screenShare, .setup, .phoneFiles, .transfer, .other]

    static func mostImportant(_ active: Set<UpdateBusy>) -> UpdateBusy? { order.first { active.contains($0) } }
}

enum UpdateLimits {
    static let statusBytes = 1024
    static let startBytes = 512
    static let resultBytes = 512
    static let maximumInteger = 9_007_199_254_740_991
}

/// A UUID read the way both platforms read request IDs: 36 characters with dashes, lowercased.
func updateRequestID(_ value: Any?) -> String? {
    guard let text = value as? String, text.utf8.count == 36, UUID(uuidString: text) != nil else { return nil }
    return text.lowercased()
}

private func updateObject(_ data: Data, limit: Int) -> [String: Any]? {
    guard data.count <= limit, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          jsonInteger(object["version"]) == 1 else { return nil }
    return object
}

/// A string of 1 to `maxBytes` UTF-8 bytes; nil for anything else.
private func boundedString(_ value: Any?, maxBytes: Int) -> String? {
    guard let text = value as? String, (1...maxBytes).contains(text.utf8.count) else { return nil }
    return text
}

/// An optional field: absent or null is `.absent`, a valid value `.value`, anything else `.invalid`.
private enum Optional3<T> {
    case absent, value(T), invalid
}

private func optional<T>(_ value: Any?, _ read: (Any?) -> T?) -> Optional3<T> {
    if value == nil || value is NSNull { return .absent }
    if let read = read(value) { return .value(read) }
    return .invalid
}

/// One device's `updates.status`.
struct PeerUpdateStatus: Codable, Equatable {
    var platform: UpdatePlatform
    var edition: String
    var app: String
    var build: Int
    var channel: UpdateChannel
    var state: PeerUpdateState
    var target: String?
    var targetBuild: Int?
    var progress: Int?
    var reason: PeerUpdateReason?
    var remoteStart: Bool
    /// Unix milliseconds of the last successful check, 0 for never.
    var checkedAt: Int
    /// "Update all devices automatically" is on there (and its updater can run).
    var auto = false
    /// What its person is doing, or nil: an automatic Update all waits while any device is busy.
    var busy: UpdateBusy?

    /// Equal apart from download progress: progress alone is sent at most once a second.
    func sameApartFromProgress(_ other: PeerUpdateStatus) -> Bool {
        var mine = self
        var theirs = other
        mine.progress = nil
        theirs.progress = nil
        return mine == theirs
    }

    /// The plaintext: version 1, null optionals left out.
    var payload: [String: Any] {
        var payload: [String: Any] = [
            "version": 1, "platform": platform.rawValue, "edition": edition, "app": app, "build": build,
            "channel": channel.rawValue, "state": state.rawValue, "remoteStart": remoteStart, "checkedAt": checkedAt,
        ]
        if let target { payload["target"] = target }
        if let targetBuild { payload["targetBuild"] = targetBuild }
        if let progress { payload["progress"] = progress }
        if let reason { payload["reason"] = reason.rawValue }
        if auto { payload["auto"] = true }
        if let busy { payload["busy"] = busy.rawValue }
        return payload
    }

    /// At most 1,024 bytes of strict JSON; nil when malformed, over a limit, or with an unknown state,
    /// platform or channel. An unknown reason reads as `other`.
    static func decode(_ data: Data) -> PeerUpdateStatus? {
        guard let object = updateObject(data, limit: UpdateLimits.statusBytes),
              let platform = (object["platform"] as? String).flatMap(UpdatePlatform.init(rawValue:)),
              let edition = boundedString(object["edition"], maxBytes: 32),
              let app = boundedString(object["app"], maxBytes: 64),
              let build = jsonInteger(object["build"]), (1...UpdateLimits.maximumInteger).contains(build),
              let channel = (object["channel"] as? String).flatMap(UpdateChannel.init(rawValue:)),
              let state = (object["state"] as? String).flatMap(PeerUpdateState.init(rawValue:)),
              let remoteStart = jsonBool(object["remoteStart"]),
              let checkedAt = jsonInteger(object["checkedAt"]), (0...UpdateLimits.maximumInteger).contains(checkedAt) else { return nil }
        var status = PeerUpdateStatus(platform: platform, edition: edition, app: app, build: build, channel: channel, state: state,
                                      remoteStart: remoteStart, checkedAt: checkedAt)
        switch optional(object["target"], { boundedString($0, maxBytes: 64) }) {
        case .invalid: return nil
        case let .value(value): status.target = value
        case .absent: break
        }
        switch optional(object["targetBuild"], { jsonInteger($0).flatMap { (1...UpdateLimits.maximumInteger).contains($0) ? $0 : nil } }) {
        case .invalid: return nil
        case let .value(value): status.targetBuild = value
        case .absent: break
        }
        switch optional(object["progress"], { jsonInteger($0).flatMap { (0...100).contains($0) ? $0 : nil } }) {
        case .invalid: return nil
        case let .value(value): status.progress = value
        case .absent: break
        }
        switch optional(object["reason"], { $0 as? String }) {
        case .invalid: return nil
        case let .value(value): status.reason = PeerUpdateReason(rawValue: value) ?? .other
        case .absent: break
        }
        switch optional(object["auto"], jsonBool) {
        case .invalid: return nil
        case let .value(value): status.auto = value
        case .absent: break
        }
        switch optional(object["busy"], { $0 as? String }) {
        case .invalid: return nil
        case let .value(value): status.busy = UpdateBusy(rawValue: value) ?? .other
        case .absent: break
        }
        return status
    }
}

/// `updates.start`: update yourself now. Nothing else is read from it. `auto`: nobody clicked Update all
/// (Update all devices automatically started it).
struct UpdateStartRequest: Equatable {
    let requestID: String
    var retry = false
    var auto = false

    var payload: [String: Any] {
        var payload: [String: Any] = ["version": 1, "requestId": requestID]
        if retry { payload["retry"] = true }
        if auto { payload["auto"] = true }
        return payload
    }

    static func decode(_ data: Data) -> UpdateStartRequest? {
        guard let object = updateObject(data, limit: UpdateLimits.startBytes),
              let requestID = updateRequestID(object["requestId"]) else { return nil }
        var request = UpdateStartRequest(requestID: requestID)
        switch optional(object["retry"], jsonBool) {
        case .invalid: return nil
        case let .value(retry): request.retry = retry
        case .absent: break
        }
        switch optional(object["auto"], jsonBool) {
        case .invalid: return nil
        case let .value(auto): request.auto = auto
        case .absent: break
        }
        return request
    }
}

enum UpdateStartRefusal: String, Codable, Equatable {
    case disabled
    case rateLimited = "rate_limited"
    case manual
    case notApplied = "not_applied"
    case busy
    case other
}

/// `updates.result`: accepted when `refusal` is nil.
struct UpdateStartResult: Equatable {
    let requestID: String
    var refusal: UpdateStartRefusal?

    var payload: [String: Any] {
        var payload: [String: Any] = ["version": 1, "requestId": requestID, "status": refusal == nil ? "accepted" : "refused"]
        if let refusal { payload["reason"] = refusal.rawValue }
        return payload
    }

    static func decode(_ data: Data) -> UpdateStartResult? {
        guard let object = updateObject(data, limit: UpdateLimits.resultBytes),
              let requestID = updateRequestID(object["requestId"]),
              let status = object["status"] as? String else { return nil }
        switch status {
        case "accepted": return UpdateStartResult(requestID: requestID)
        case "refused":
            let reason = (object["reason"] as? String).flatMap(UpdateStartRefusal.init(rawValue:)) ?? .other
            return UpdateStartResult(requestID: requestID, refusal: reason)
        default: return nil
        }
    }
}

// MARK: - Receiving a start

/// Whether this Mac takes a phone's `updates.start`. Pure, so the rules are unit tested.
struct UpdateStartGate {
    static let spacing: TimeInterval = 30
    static let perHour = 5

    enum Decision: Equatable {
        case accept
        case refuse(UpdateStartRefusal)
    }

    /// Starts that counted, per device (rate-limited ones do not).
    private(set) var history: [String: [Date]] = [:]

    /// `auto` and `personBusy`: an automatic start (`updates.start` `auto`) waits while the person here is busy.
    mutating func decide(
        deviceID: String,
        retry: Bool,
        now: Date,
        allowed: Bool,
        updaterAvailable: Bool,
        notApplied: Bool,
        canStart: Bool,
        auto: Bool = false,
        personBusy: UpdateBusy? = nil
    ) -> Decision {
        guard allowed else { return .refuse(.disabled) }
        guard updaterAvailable else { return .refuse(.manual) }
        let recent = (history[deviceID] ?? []).filter { now.timeIntervalSince($0) < 3600 && now >= $0 }
        if let last = recent.last, now.timeIntervalSince(last) < Self.spacing { return .refuse(.rateLimited) }
        if recent.count >= Self.perHour { return .refuse(.rateLimited) }
        history[deviceID] = recent + [now]
        if notApplied && !retry { return .refuse(.notApplied) }
        guard canStart else { return .refuse(.busy) }
        if auto && personBusy != nil { return .refuse(.busy) }
        return .accept
    }

    mutating func forget(_ deviceID: String) { history.removeValue(forKey: deviceID) }
}

// MARK: - Not applied

/// Remembers the build handed to Sparkle, so a relaunch on the old build is reported as "didn't apply"
/// and never tried again on its own, even when a phone asks (only Retry or a local install does).
struct UpdateAttemptStore {
    struct Attempt: Codable, Equatable {
        let build: Int
        let version: String
        let at: Date
    }

    static let pendingKey = "updates.pendingInstall"
    static let notAppliedKey = "updates.notApplied"
    /// A relaunch on the old build counts as "didn't apply" only this soon after the install.
    static let window: TimeInterval = 3600

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var pending: Attempt? { read(Self.pendingKey) }
    var notApplied: Attempt? { read(Self.notAppliedKey) }

    /// Right before Sparkle is told to install and relaunch.
    func recordInstall(build: Int, version: String, now: Date) {
        write(Attempt(build: build, version: version, at: now), Self.pendingKey)
    }

    /// At launch: the pending install either arrived, or this is the old build again.
    func launched(installedBuild: Int, now: Date) {
        guard let pending else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        if installedBuild >= pending.build {
            clearNotApplied()
        } else if now.timeIntervalSince(pending.at) < Self.window, now >= pending.at {
            write(pending, Self.notAppliedKey)
        }
    }

    func clearNotApplied() { defaults.removeObject(forKey: Self.notAppliedKey) }

    /// Sparkle offers another build than the one that did not apply: that one may install.
    func offered(build: Int?) {
        guard let build, let notApplied, notApplied.build != build else { return }
        clearNotApplied()
    }

    private func read(_ key: String) -> Attempt? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Attempt.self, from: $0) }
    }

    private func write(_ attempt: Attempt, _ key: String) {
        if let data = try? JSONEncoder().encode(attempt) { defaults.set(data, forKey: key) }
    }
}

extension UpdateChannel: Codable {}
