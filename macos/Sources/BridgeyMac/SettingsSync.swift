import AppKit
import Combine
import Foundation

/*
 * Settings sync, draft `settings_sync_draft1` (docs/folders-and-settings-sync.md, sections 4.9, 8, 8.4 "As built"
 * and 8.5 "Threat model"). Feature switches and shared preferences stay the same on paired devices, the way
 * T3 Code saves a setting to every connected device: a change goes out at once, a snapshot on connect never
 * overwrites a chosen value (it shows "Different on <device>" with Apply to all), and permissions are never
 * granted remotely (a setting that is on but lacks one is listed as waiting).
 *
 * Never synced: pairing, trust, secrets, permissions, per-device grants and overrides, names, folders and paths.
 * Android has the same rules in settingssync/SettingsSync.kt; the golden vectors (settingsPayload,
 * settingsMerge, settingsSnapshot, settingsStamp) pin both.
 */

let settingsSyncFeatureKey = "settings_sync_draft1"

/// The settings sync message kinds.
enum SettingsSyncKinds {
    static let snapshot = "settings.snapshot"
    static let update = "settings.update"
    static let ack = "settings.ack"
    static let error = "settings.error"
}

enum SettingsSyncLimits {
    static let schema = 1
    /// settings.snapshot and settings.update plaintext.
    static let payloadBytes = 16_384
    /// settings.ack and settings.error plaintext.
    static let replyBytes = 8_192
    static let maximumRecords = 32
    static let maximumWaiting = 32
    static let maximumChangedByBytes = 128
    static let maximumInteger: Int64 = 9_007_199_254_740_991
    /// Local edits wait this long, so a burst of changes goes out as one update.
    static let debounce: TimeInterval = 0.5
    /// At most this many settings.* messages from one device per window; more are dropped.
    static let rateLimit = 20
    static let rateWindowMillis: Int64 = 10_000
}

/// A synced value: booleans, and one of a few strings for the two folder keys.
enum SyncValue: Equatable, Hashable {
    case bool(Bool)
    case string(String)

    var json: Any {
        switch self {
        case let .bool(value): value
        case let .string(value): value
        }
    }
}

/// The schema 1 allowlist, in schema order (also the order of activity tokens and of the waiting list).
/// `pair.clipboard.automatic` and every per-device or local-only setting are never synced.
enum SyncKey: String, CaseIterable, Comparable {
    case folderDestination = "files.folder_destination"
    case folderConflict = "files.folder_conflict"
    case activityPreviews = "activity.previews"
    case reduceMotion = "display.reduce_motion"
    case featureClipboard = "feature.clipboard"
    case featureFiles = "feature.files"
    case featureNotifications = "feature.notifications"
    case featureBattery = "feature.battery"
    case featureFindDevice = "feature.find_device"
    case featurePing = "feature.ping"
    case featureLinks = "feature.links"
    case featureMedia = "feature.media"
    case featureCalls = "feature.calls"
    case featureRemoteInput = "feature.remote_input"
    case featureMacActions = "feature.mac_actions"
    case featureCamera = "feature.camera"
    case autoClipboard = "clipboard.automatic"
    case clipboardFiles = "clipboard.files"
    case focusShare = "focus.share"
    case focusFollow = "focus.follow"
    case codesEnabled = "codes.enabled"

    static func < (lhs: SyncKey, rhs: SyncKey) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The allowed strings, in the order the activity tokens number them; nil for booleans.
    var choices: [String]? {
        switch self {
        case .folderDestination: ["sender_picks", "receiver_asks", "fixed"]
        case .folderConflict: ["ask", "merge", "replace", "new_folder"]
        default: nil
        }
    }

    /// The value of a never-chosen record for a key this device only stores and relays.
    var defaultValue: SyncValue {
        switch self {
        case .folderDestination: .string("sender_picks")
        case .folderConflict: .string("ask")
        case .activityPreviews: .bool(true)
        default: .bool(false)
        }
    }

    /// The Mac's global switch this key mirrors (never a per-phone grant or override).
    var feature: BridgeyFeature? {
        switch self {
        case .featureClipboard: .clipboard
        case .featureFiles: .files
        case .featureNotifications: .notifications
        case .featureBattery: .battery
        case .featureFindDevice: .findDevice
        case .featurePing: .ping
        case .featureLinks: .links
        case .featureMedia: .media
        case .featureCalls: .calls
        case .featureRemoteInput: .remoteInput
        case .featureMacActions: .macActions
        default: nil
        }
    }

    /// Turning it on shares more: a remote change that turns it on is announced with a banner.
    var sharesWhenOn: Bool {
        switch self {
        case .folderDestination, .folderConflict, .activityPreviews, .reduceMotion: false
        default: true
        }
    }

    /// The activity detail token (shared with Android, at most 24 characters).
    var token: String {
        switch self {
        case .folderDestination: "folder_destination"
        case .folderConflict: "folder_conflict"
        case .activityPreviews: "previews"
        case .reduceMotion: "reduce_motion"
        case .autoClipboard: "auto_clipboard"
        case .clipboardFiles: "clipboard_files"
        case .focusShare: "focus_share"
        case .focusFollow: "focus_follow"
        case .codesEnabled: "codes"
        default: String(rawValue.dropFirst("feature.".count))
        }
    }

    /// The setting's name in Choose what syncs, change labels and banners.
    var name: String {
        switch self {
        case .folderDestination: L10n.text("sync.name.folderDestination", fallback: "Folders sent to this device")
        case .folderConflict: L10n.text("sync.name.folderConflict", fallback: "When a folder already exists")
        case .activityPreviews: L10n.text("sync.name.previews", fallback: "Activity previews")
        case .reduceMotion: L10n.text("sync.name.reduceMotion", fallback: "Reduce motion")
        case .featureClipboard: L10n.text("sync.name.clipboard", fallback: "Clipboard")
        case .featureFiles: L10n.text("sync.name.files", fallback: "File transfer")
        case .featureNotifications: L10n.text("sync.name.notifications", fallback: "Notification forwarding")
        case .featureBattery: L10n.text("sync.name.battery", fallback: "Battery status")
        case .featureFindDevice: L10n.text("sync.name.findDevice", fallback: "Find device")
        case .featurePing: L10n.text("sync.name.ping", fallback: "Ping")
        case .featureLinks: L10n.text("sync.name.links", fallback: "Web links")
        case .featureMedia: L10n.text("sync.name.media", fallback: "Media controls")
        case .featureCalls: L10n.text("sync.name.calls", fallback: "Calls")
        case .featureRemoteInput: L10n.text("sync.name.remoteInput", fallback: "Remote control")
        case .featureMacActions: L10n.text("sync.name.macActions", fallback: "Mac actions")
        case .featureCamera: L10n.text("sync.name.camera", fallback: "Photos for the Mac")
        case .autoClipboard: L10n.text("sync.name.autoClipboard", fallback: "Automatic clipboard")
        case .clipboardFiles: L10n.text("sync.name.clipboardFiles", fallback: "Copy images and files")
        case .focusShare: L10n.text("sync.name.focusShare", fallback: "Focus sharing")
        case .focusFollow: L10n.text("sync.name.focusFollow", fallback: "Focus following")
        case .codesEnabled: L10n.text("sync.name.codes", fallback: "Codes from messages")
        }
    }

    func accepts(_ value: SyncValue) -> Bool {
        switch (value, choices) {
        case (.bool, nil): true
        case let (.string(text), list?): list.contains(text)
        default: false
        }
    }

    /// A JSON value of this key's type, or nil.
    func value(fromJSON raw: Any?) -> SyncValue? {
        let value: SyncValue?
        if choices == nil {
            value = jsonBool(raw).map(SyncValue.bool)
        } else if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            value = nil
        } else {
            value = (raw as? String).map(SyncValue.string)
        }
        guard let value, accepts(value) else { return nil }
        return value
    }

    /// The activity token value: 0 or 1 for booleans (1 is on), the position in `choices` for strings.
    func index(of value: SyncValue) -> Int? {
        switch value {
        case let .bool(on): on ? 1 : 0
        case let .string(text): choices?.firstIndex(of: text)
        }
    }

    func value(atIndex index: Int) -> SyncValue? {
        if let choices { return choices.indices.contains(index) ? .string(choices[index]) : nil }
        return index == 0 || index == 1 ? .bool(index == 1) : nil
    }
}

/// When and where a record was made. Two records with the same stamp are the same record.
struct SyncStamp: Equatable, Hashable {
    let changedAt: Int64
    let version: Int64
    let changedBy: String
}

struct SyncRecord: Equatable {
    let value: SyncValue
    let changedAt: Int64
    let version: Int64
    let changedBy: String

    var stamp: SyncStamp { SyncStamp(changedAt: changedAt, version: version, changedBy: changedBy) }
    /// Someone chose this value (an edit, Apply to all or the upgrade stamp); version 0 is never chosen.
    var chosen: Bool { version > 0 }

    static func neverChosen(_ value: SyncValue) -> SyncRecord {
        SyncRecord(value: value, changedAt: 0, version: 0, changedBy: "")
    }

    static func defaultRecord(_ key: SyncKey) -> SyncRecord { neverChosen(key.defaultValue) }

    var json: [String: Any] {
        ["value": value.json, "changedAt": NSNumber(value: changedAt), "version": NSNumber(value: version), "changedBy": changedBy]
    }

    /// A record of `key` from its JSON object, or nil when anything is missing, of the wrong type or out of range.
    init?(key: SyncKey, json raw: Any?) {
        guard let object = raw as? [String: Any],
              let value = key.value(fromJSON: object["value"]),
              let changedAt = syncInteger(object["changedAt"]),
              let version = syncInteger(object["version"]),
              let changedBy = object["changedBy"] as? String,
              changedBy.utf8.count <= SettingsSyncLimits.maximumChangedByBytes else { return nil }
        self.init(value: value, changedAt: changedAt, version: version, changedBy: changedBy)
    }

    init(value: SyncValue, changedAt: Int64, version: Int64, changedBy: String) {
        self.value = value
        self.changedAt = changedAt
        self.version = version
        self.changedBy = changedBy
    }
}

/// An integral JSON number in 0...2^53-1 (3.0 counts; booleans and strings do not).
func syncInteger(_ value: Any?) -> Int64? {
    guard let number = jsonInteger(value), number >= 0, Int64(number) <= SettingsSyncLimits.maximumInteger else { return nil }
    return Int64(number)
}

/// Compares UTF-8 bytes, so both platforms order `changedBy` alike (Swift's String order is not byte order).
func compareUTF8(_ a: String, _ b: String) -> Int {
    let left = Array(a.utf8), right = Array(b.utf8)
    for (x, y) in zip(left, right) where x != y { return x < y ? -1 : 1 }
    return left.count == right.count ? 0 : (left.count < right.count ? -1 : 1)
}

/// Updates (section 8.2): above zero when `a` wins. The higher changedAt, then the higher version, then the
/// larger changedBy in UTF-8 byte order. Zero for the same record.
func compareSyncRecords(_ a: SyncRecord, _ b: SyncRecord) -> Int {
    if a.changedAt != b.changedAt { return a.changedAt > b.changedAt ? 1 : -1 }
    if a.version != b.version { return a.version > b.version ? 1 : -1 }
    return compareUTF8(a.changedBy, b.changedBy)
}

/// What a snapshot record does here (section 8.4): a snapshot never overwrites a chosen value.
enum SnapshotOutcome: String {
    /// Never chosen here, chosen there: take the peer's record.
    case adopt
    /// Both chose different values: nothing changes; Settings shows "Different on <device>".
    case different
    case same
}

/// `alreadyMeans` says this device already does what the remote value means (the Mac reads
/// `sender_picks` as `fixed`), so such values never count as different.
func snapshotOutcome(local: SyncRecord, remote: SyncRecord, alreadyMeans: ((SyncValue) -> Bool)? = nil) -> SnapshotOutcome {
    if local.stamp == remote.stamp { return .same }
    if !local.chosen && remote.chosen { return .adopt }
    if local.chosen && remote.chosen && local.value != remote.value && alreadyMeans?(remote.value) != true { return .different }
    return .same
}

/// A local edit or Apply to all: timestamps never go backwards on this device, so an edit made after seeing
/// another device's record always wins over it, even when that device's clock runs ahead.
func stampLocalEdit(_ current: SyncRecord, value: SyncValue, now: Int64, device: String) -> SyncRecord {
    let next = current.changedAt >= SettingsSyncLimits.maximumInteger ? SettingsSyncLimits.maximumInteger : current.changedAt + 1
    let changedAt = min(SettingsSyncLimits.maximumInteger, max(now, next))
    return SyncRecord(value: value, changedAt: changedAt, version: min(SettingsSyncLimits.maximumInteger, current.version + 1), changedBy: device)
}

/// The first build with sync stamps each setting once: a value the person stored before is chosen
/// (`changedAt 1, version 1`); one never stored stays at 0 with the value this device has now.
func upgradeSyncRecords(stored: [SyncKey: SyncValue], current: [SyncKey: SyncValue], device: String) -> [SyncKey: SyncRecord] {
    var records: [SyncKey: SyncRecord] = [:]
    for key in SyncKey.allCases {
        if let value = stored[key], key.accepts(value) {
            records[key] = SyncRecord(value: value, changedAt: 1, version: 1, changedBy: device)
        } else if let value = current[key], key.accepts(value) {
            records[key] = .neverChosen(value)
        } else {
            records[key] = .defaultRecord(key)
        }
    }
    return records
}

/// The values a Mac from before settings sync explicitly stored, read from its defaults. Wrong types and
/// unknown values count as never chosen.
func settingsSyncStoredValues(_ defaults: [String: Any]) -> [SyncKey: SyncValue] {
    var values: [SyncKey: SyncValue] = [:]
    switch defaults["settings.folders.receiveMode"] as? String {
    case MacFolderReceiveMode.ask.rawValue?: values[.folderDestination] = .string("receiver_asks")
    case MacFolderReceiveMode.fixed.rawValue?: values[.folderDestination] = .string("fixed")
    default: break
    }
    if let conflict = defaults["settings.folders.conflict"] as? String, MacFolderConflictPolicy(rawValue: conflict) != nil {
        values[.folderConflict] = .string(conflict)
    }
    func bool(_ key: SyncKey, _ name: String) {
        if let value = jsonBool(defaults[name]) { values[key] = .bool(value) }
    }
    bool(.activityPreviews, "settings.activity.previews")
    bool(.reduceMotion, "settings.reduceMotion")
    for key in SyncKey.allCases {
        if let feature = key.feature { bool(key, "settings.global.\(feature.rawValue)") }
    }
    bool(.autoClipboard, "settings.autoClipboard.enabled")
    bool(.clipboardFiles, "settings.clipboardFiles.enabled")
    bool(.codesEnabled, "settings.codes.enabled")
    if let data = defaults["settings.focusSync"] as? Data, let focus = try? JSONDecoder().decode(FocusSyncSettings.self, from: data) {
        values[.focusShare] = .bool(focus.share)
        values[.focusFollow] = .bool(focus.follow)
    }
    return values
}

// MARK: Payloads

struct SettingsPayload: Equatable {
    /// The records of the 21 keys; skipped entries are counted, never kept.
    var records: [SyncKey: SyncRecord]
    /// The keys the sender has on but waiting for a permission there, in schema order.
    var waiting: [SyncKey]
    var skipped: Int
    /// First connect (8.4): the sender has no answer for the receiver yet.
    var first = false
    /// The sender has no answer for any device.
    var new = false
    /// The asker's update that ends the wait on the other side.
    var answered = false
}

enum SettingsPayloadDecoding: Equatable {
    case payload(SettingsPayload)
    /// A schema this build does not speak: answered `settings.error` `unsupported_schema`.
    case unsupportedSchema(Int)
    /// Dropped and answered `settings.error` `invalid_message`.
    case invalid
}

/// A settings.snapshot or settings.update plaintext.
func decodeSettingsPayload(_ data: Data) -> SettingsPayloadDecoding {
    guard data.count <= SettingsSyncLimits.payloadBytes, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let schema = jsonInteger(object["schema"]) else { return .invalid }
    guard schema == SettingsSyncLimits.schema else { return .unsupportedSchema(schema) }
    guard let entries = object["records"] as? [String: Any], entries.count <= SettingsSyncLimits.maximumRecords else { return .invalid }
    var waiting: [SyncKey] = []
    if let list = object["waiting"] as? [Any] {
        guard list.count <= SettingsSyncLimits.maximumWaiting else { return .invalid }
        let keys = Set(list.compactMap { ($0 as? String).flatMap(SyncKey.init(rawValue:)) })
        waiting = keys.sorted()
    }
    var records: [SyncKey: SyncRecord] = [:]
    var skipped = 0
    for (name, raw) in entries {
        guard let key = SyncKey(rawValue: name), let record = SyncRecord(key: key, json: raw) else {
            skipped += 1
            continue
        }
        records[key] = record
    }
    return .payload(SettingsPayload(records: records, waiting: waiting, skipped: skipped,
                                    first: jsonBool(object["first"]) == true, new: jsonBool(object["new"]) == true,
                                    answered: jsonBool(object["answered"]) == true))
}

func settingsRecordsPayload(_ records: [SyncKey: SyncRecord], waiting: [SyncKey], snapshot: Bool,
                            first: Bool = false, new: Bool = false, answered: Bool = false) -> [String: Any] {
    var payload: [String: Any] = [
        "schema": SettingsSyncLimits.schema,
        "records": Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value.json) }),
        "waiting": waiting.sorted().map(\.rawValue),
    ]
    if snapshot {
        payload["maxSchema"] = SettingsSyncLimits.schema
        payload["first"] = first
        payload["new"] = new
    }
    if answered { payload["answered"] = true }
    return payload
}

/// Who asks "Use the same settings as <device>?" on a first connect (8.4), from this device's side.
enum SettingsAsker: String {
    /// This device asks.
    case local
    /// The other device asks; this one waits for its answer.
    case remote
    /// Nobody asks; the usual snapshot rules apply at once.
    case none
}

/// Nobody asks unless both sides are on their first connect with each other. Then the device that never
/// synced with anyone asks; when both are new, the phone asks; when neither is, nobody does.
func settingsAsker(localFirst: Bool, localNew: Bool, isPhone: Bool, remoteFirst: Bool, remoteNew: Bool) -> SettingsAsker {
    guard localFirst && remoteFirst else { return .none }
    switch (localNew, remoteNew) {
    case (true, false): return .local
    case (false, true): return .remote
    case (true, true): return isPhone ? .local : .remote
    case (false, false): return .none
    }
}

func settingsAckPayload(ackOf messageID: String, applied: [SyncKey], kept: [SyncKey]) -> [String: Any] {
    ["schema": SettingsSyncLimits.schema, "ackOf": messageID, "applied": applied.sorted().map(\.rawValue), "kept": kept.sorted().map(\.rawValue)]
}

/// A settings.ack: the message it answers and the keys applied there, or nil when malformed.
func decodeSettingsAck(_ data: Data) -> (ackOf: String, applied: [SyncKey])? {
    guard data.count <= SettingsSyncLimits.replyBytes, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let ackOf = object["ackOf"] as? String else { return nil }
    let applied = (object["applied"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(SyncKey.init(rawValue:)) }
    return (ackOf, applied)
}

func settingsErrorPayload(_ code: String) -> [String: Any] {
    ["schema": SettingsSyncLimits.schema, "code": code, "maxSchema": SettingsSyncLimits.schema]
}

/// A settings.error code, or nil when malformed.
func decodeSettingsError(_ data: Data) -> String? {
    guard data.count <= SettingsSyncLimits.replyBytes, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let code = object["code"] as? String, code.utf8.count <= 64 else { return nil }
    return code
}

// MARK: Activity detail

/// The changes a sync applied here, as stored in an activity item: "previews=0,reduce_motion=1".
enum SettingsSyncDetail {
    private static let pattern = #"^[a-z_]{1,24}=[0-9]{1,2}(,[a-z_]{1,24}=[0-9]{1,2}){0,31}$"#

    static func encode(_ changes: [SyncKey: SyncValue]) -> String? {
        let parts = changes.keys.sorted().compactMap { key in key.index(of: changes[key]!).map { "\(key.token)=\($0)" } }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    static func clean(_ value: String?) -> String? {
        guard let value, value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func decode(_ value: String?) -> [(SyncKey, SyncValue)] {
        guard let value = clean(value) else { return [] }
        return value.split(separator: ",").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, let key = SyncKey.allCases.first(where: { $0.token == pair[0] }),
                  let index = Int(pair[1]), let synced = key.value(atIndex: index) else { return nil }
            return (key, synced)
        }
    }

    /// "Calls turned on", "Folders: ask where to save".
    static func label(_ key: SyncKey, _ value: SyncValue) -> String {
        switch (key, value) {
        case let (_, .bool(on)):
            return String(format: on ? L10n.text("stream.settings.turnedOn", fallback: "%@ turned on")
                                     : L10n.text("stream.settings.turnedOff", fallback: "%@ turned off"), key.name)
        case (.folderDestination, .string("receiver_asks")):
            return L10n.text("stream.settings.folders.ask", fallback: "Folders: ask where to save")
        case (.folderDestination, .string("fixed")):
            return L10n.text("stream.settings.folders.fixed", fallback: "Folders: save to the default folder")
        case (.folderDestination, _):
            return L10n.text("stream.settings.folders.sender", fallback: "Folders: sending device chooses")
        case (.folderConflict, .string("merge")):
            return L10n.text("stream.settings.conflict.merge", fallback: "Existing folders: merge")
        case (.folderConflict, .string("replace")):
            return L10n.text("stream.settings.conflict.replace", fallback: "Existing folders: replace files")
        case (.folderConflict, .string("new_folder")):
            return L10n.text("stream.settings.conflict.newFolder", fallback: "Existing folders: save as new folder")
        default:
            return L10n.text("stream.settings.conflict.ask", fallback: "Existing folders: ask each time")
        }
    }

    /// "Settings synced with OnePlus 11".
    static func title(device: String) -> String {
        String(format: L10n.text("stream.settings.synced", fallback: "Settings synced with %@"), device)
    }

    /// "Calls turned on, Reduce motion turned off".
    static func detail(_ content: String?) -> String? {
        let labels = decode(content).map { label($0.0, $0.1) }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }
}

// MARK: Engine

/// One synced setting as this Mac holds it.
struct SyncedSetting {
    /// The local setting as a wire value, for a local edit.
    var read: () -> SyncValue
    /// The local setting already does what `value` means here.
    var matches: (SyncValue) -> Bool
    /// Applies a value that won.
    var write: (SyncValue) -> Void

    init(read: @escaping () -> SyncValue, matches: ((SyncValue) -> Bool)? = nil, write: @escaping (SyncValue) -> Void) {
        self.read = read
        self.matches = matches ?? { $0 == read() }
        self.write = write
    }
}

/// What a received snapshot or update did here.
struct SettingsSyncReceipt: Equatable {
    var applied: [SyncKey] = []
    var kept: [SyncKey] = []
    /// The values that changed here, for the activity item.
    var changes: [SyncKey: SyncValue] = [:]
    /// This update ended the wait for the peer's first-connect answer.
    var answerReceived = false
}

/// The merge rules and per-peer bookkeeping, without transport or storage (sections 8.2 and 8.4).
///
/// Per peer and session: whether its snapshot arrived (`ready`: no update goes out before), the stamps sent to
/// it and received from it (a record goes out only when it matches neither, so nothing ping-pongs and relaying
/// reaches every peer), the record it holds (`known`, for "Different on"), its waiting list, the records of each
/// message not yet acknowledged, and the waiting list it last heard from here.
final class SettingsSyncEngine {
    let localDeviceID: String
    private(set) var records: [SyncKey: SyncRecord]
    var settings: [SyncKey: SyncedSetting]
    /// Settings that stay on this device: never sent, and records for them are skipped.
    var excluded: Set<SyncKey> = []
    /// The keys on here but waiting for a permission (before `excluded` is applied).
    var localWaiting: () -> [SyncKey] = { [] }
    private let clock: () -> Int64
    private let save: ([SyncKey: SyncRecord]) -> Void
    private var peers: [String: Peer] = [:]

    private struct Peer {
        var ready = false
        var sent: [SyncKey: SyncStamp] = [:]
        var received: [SyncKey: SyncStamp] = [:]
        var known: [SyncKey: SyncRecord] = [:]
        var waiting: Set<SyncKey> = []
        var inflight: [String: [SyncKey: SyncRecord]] = [:]
        var lastWaitingSent: [SyncKey] = []
        /// First connect: the flags this device put in its snapshot to the peer, and who asks.
        var sentFirst = false
        var sentNew = false
        var phase = Phase.normal
        /// The next update carries `answered: true`, and goes out even when it has nothing else.
        var sendAnswered = false
        /// Records this device took from the peer on Use these: sent back once so the peer knows they match.
        var echo: Set<SyncKey> = []
    }

    enum Phase {
        case normal
        /// This device asks the person; nothing syncs with the peer until the answer.
        case asking
        /// The peer asks; this device applies nothing until its answered update.
        case awaitingAnswer
    }

    init(localDeviceID: String, records: [SyncKey: SyncRecord], settings: [SyncKey: SyncedSetting],
         clock: @escaping () -> Int64, save: @escaping ([SyncKey: SyncRecord]) -> Void = { _ in }) {
        self.localDeviceID = localDeviceID
        var complete = records
        for key in SyncKey.allCases where complete[key] == nil { complete[key] = .defaultRecord(key) }
        self.records = complete
        self.settings = settings
        self.clock = clock
        self.save = save
    }

    func record(_ key: SyncKey) -> SyncRecord { records[key] ?? .defaultRecord(key) }

    var activePeers: [String] { peers.keys.sorted() }
    func isActive(_ peer: String) -> Bool { peers[peer] != nil }
    func isReady(_ peer: String) -> Bool { peers[peer]?.ready == true }
    func isAsking(_ peer: String) -> Bool { peers[peer]?.phase == .asking }
    func isAwaitingAnswer(_ peer: String) -> Bool { peers[peer]?.phase == .awaitingAnswer }
    /// The first and new flags this device sent the peer in its snapshot (the asker is decided from them).
    func sentFlags(_ peer: String) -> (first: Bool, new: Bool)? { peers[peer].map { ($0.sentFirst, $0.sentNew) } }

    /// This device already does what `value` means for `key`.
    func alreadyMeans(_ key: SyncKey, _ value: SyncValue) -> Bool {
        settings[key]?.matches(value) ?? (record(key).value == value)
    }

    /// The waiting list as it goes on the wire.
    var waitingList: [SyncKey] { Set(localWaiting()).subtracting(excluded).sorted() }

    private var shared: [SyncKey: SyncRecord] { records.filter { !excluded.contains($0.key) } }

    /// Stamps every setting that no longer matches its record (a local edit made anywhere, excluded ones too).
    @discardableResult
    func observeLocal() -> [SyncKey] {
        var stamped: [SyncKey] = []
        for key in SyncKey.allCases {
            guard let setting = settings[key] else { continue }
            let current = record(key)
            guard !setting.matches(current.value) else { continue }
            let value = setting.read()
            guard key.accepts(value) else { continue }
            records[key] = stampLocalEdit(current, value: value, now: clock(), device: localDeviceID)
            stamped.append(key)
        }
        if !stamped.isEmpty { save(records) }
        return stamped
    }

    /// Apply to all: this device's value again, as a new edit that wins everywhere. It is stamped above the
    /// newest record any peer holds, so a peer whose clock runs ahead still takes it.
    @discardableResult
    func applyToAll(_ key: SyncKey) -> SyncRecord {
        var base = record(key)
        for peer in peers.values {
            if let other = peer.known[key], compareSyncRecords(other, base) > 0 {
                base = SyncRecord(value: base.value, changedAt: other.changedAt, version: max(base.version, other.version), changedBy: base.changedBy)
            }
        }
        let stamped = stampLocalEdit(base, value: record(key).value, now: clock(), device: localDeviceID)
        records[key] = stamped
        save(records)
        return stamped
    }

    /// Sync became available with `peer`: its snapshot is every shared record and the waiting list.
    func start(_ peer: String, messageID: String, first: Bool = false, new: Bool = false) -> (records: [SyncKey: SyncRecord], waiting: [SyncKey]) {
        var state = Peer()
        state.sentFirst = first
        state.sentNew = new
        let out = shared
        for (key, record) in out { state.sent[key] = record.stamp }
        state.inflight[messageID] = out
        state.lastWaitingSent = waitingList
        peers[peer] = state
        return (out, state.lastWaitingSent)
    }

    /// Sync went off for `peer`, its session ended, or it answered settings.error.
    func stop(_ peer: String) {
        peers.removeValue(forKey: peer)
    }

    func receiveSnapshot(_ payload: SettingsPayload, from peer: String, asker: SettingsAsker = .none) -> SettingsSyncReceipt {
        var state = peers[peer] ?? Peer()
        var receipt = SettingsSyncReceipt()
        state.waiting = Set(payload.waiting)
        if asker != .none {
            // First connect with a question: take nothing from this snapshot, and sync nothing with the peer, until the answer.
            for key in payload.records.keys where !excluded.contains(key) {
                state.received[key] = payload.records[key]!.stamp
                state.known[key] = payload.records[key]!
            }
            state.phase = asker == .local ? .asking : .awaitingAnswer
            state.ready = false
            peers[peer] = state
            return receipt
        }
        for key in payload.records.keys.sorted() where !excluded.contains(key) {
            let remote = payload.records[key]!
            state.received[key] = remote.stamp
            state.known[key] = remote
            let local = record(key)
            switch snapshotOutcome(local: local, remote: remote, alreadyMeans: { self.alreadyMeans(key, $0) }) {
            case .adopt:
                if !alreadyMeans(key, remote.value) { receipt.changes[key] = remote.value }
                records[key] = remote
                receipt.applied.append(key)
            case .different:
                // Nothing changes, and the next flush must not push this value over theirs: Apply to all decides.
                state.sent[key] = local.stamp
                receipt.kept.append(key)
            case .same:
                break
            }
        }
        state.ready = true
        peers[peer] = state
        commit(receipt)
        return receipt
    }

    func receiveUpdate(_ payload: SettingsPayload, from peer: String) -> SettingsSyncReceipt {
        var state = peers[peer] ?? Peer()
        var receipt = SettingsSyncReceipt()
        state.waiting = Set(payload.waiting)
        if !state.ready {
            for key in payload.records.keys where !excluded.contains(key) {
                state.received[key] = payload.records[key]!.stamp
                state.known[key] = payload.records[key]!
            }
            guard state.phase == .awaitingAnswer && payload.answered else {
                // Not ready (its snapshot, or the person's answer, is still to come): nothing applies yet.
                peers[peer] = state
                return receipt
            }
            // The peer's person answered. Never push this device's value over that answer: where the values still
            // differ (Keep mine there), they stay different until Apply to all.
            peers[peer] = state
            pinDiffering(&state, peer)
            state.phase = .normal
            state.ready = true
            receipt.answerReceived = true
        }
        for key in payload.records.keys.sorted() where !excluded.contains(key) {
            let remote = payload.records[key]!
            state.received[key] = remote.stamp
            state.known[key] = remote
            let local = record(key)
            let order = compareSyncRecords(remote, local)
            if order > 0 {
                if !alreadyMeans(key, remote.value) { receipt.changes[key] = remote.value }
                records[key] = remote
                receipt.applied.append(key)
            } else if order < 0 {
                receipt.kept.append(key)
            }
        }
        peers[peer] = state
        commit(receipt)
        return receipt
    }

    /// The record is written first, so the setting's own observer sees a match and never stamps it again.
    private func commit(_ receipt: SettingsSyncReceipt) {
        guard !receipt.applied.isEmpty else { return }
        save(records)
        for key in receipt.applied {
            guard let setting = settings[key], !setting.matches(records[key]!.value) else { continue }
            setting.write(records[key]!.value)
        }
    }

    /// The update `peer` needs now (records it has neither sent nor been sent, or a new waiting list), marked
    /// sent; nil when there is nothing, or before its snapshot arrived.
    func nextUpdate(for peer: String, messageID: String) -> (records: [SyncKey: SyncRecord], waiting: [SyncKey], answered: Bool)? {
        guard var state = peers[peer], state.ready else { return nil }
        let waiting = waitingList
        var out: [SyncKey: SyncRecord] = [:]
        for (key, record) in shared where (state.sent[key] != record.stamp && state.received[key] != record.stamp) || state.echo.contains(key) {
            out[key] = record
        }
        let answered = state.sendAnswered
        guard !out.isEmpty || waiting != state.lastWaitingSent || answered else { return nil }
        for (key, record) in out { state.sent[key] = record.stamp }
        state.inflight[messageID] = out
        state.lastWaitingSent = waiting
        state.sendAnswered = false
        state.echo = []
        peers[peer] = state
        return (out, waiting, answered)
    }

    /// Keep mine (here or on the peer): every setting that still differs stays as it is on both sides. A value
    /// nobody chose here becomes chosen (`changedAt 1, version 1`, like the upgrade stamp), so a later snapshot
    /// shows it as different instead of quietly adopting the peer's; and it is never pushed over the peer's.
    private func pinDiffering(_ state: inout Peer, _ peer: String) {
        var pinned = false
        for key in differingKeys(peer) {
            if !record(key).chosen {
                records[key] = SyncRecord(value: record(key).value, changedAt: 1, version: 1, changedBy: localDeviceID)
                pinned = true
            }
            state.sent[key] = record(key).stamp
        }
        if pinned { save(records) }
    }

    /// Asking: the settings that differ between this device and the peer (what Use these would change).
    func differingKeys(_ peer: String) -> [SyncKey] {
        guard let state = peers[peer] else { return [] }
        return SyncKey.allCases.filter { key in
            guard !excluded.contains(key), let known = state.known[key] else { return false }
            return !alreadyMeans(key, known.value)
        }
    }

    /// The person answered "Use the same settings as <peer>?". Use these takes the peer's record for every
    /// setting that differs, unchanged; Keep mine keeps this device's and never pushes it over the peer's (they
    /// show "Different on" until Apply to all). Either way sync starts, and the next update says it was answered.
    func answer(_ peer: String, use: Bool) -> SettingsSyncReceipt {
        guard var state = peers[peer], state.phase == .asking else { return SettingsSyncReceipt() }
        var receipt = SettingsSyncReceipt()
        for key in differingKeys(peer) {
            if use, let known = state.known[key] {
                records[key] = known
                receipt.applied.append(key)
                receipt.changes[key] = known.value
                state.echo.insert(key)
            }
        }
        if !use { pinDiffering(&state, peer) }
        state.phase = .normal
        state.ready = true
        state.sendAnswered = true
        peers[peer] = state
        commit(receipt)
        return receipt
    }

    /// settings.ack: the peer now holds what it applied from that message.
    func acknowledged(from peer: String, messageID: String, applied: [SyncKey]) {
        guard var state = peers[peer], let sent = state.inflight.removeValue(forKey: messageID) else { return }
        for key in applied { if let record = sent[key] { state.known[key] = record } }
        peers[peer] = state
    }

    /// Ready peers whose value of `key` differs from what this device does.
    func differentOn(_ key: SyncKey) -> [String] {
        guard !excluded.contains(key) else { return [] }
        return peers.filter { $0.value.ready && $0.value.known[key].map { !alreadyMeans(key, $0.value) } == true }.keys.sorted()
    }

    /// Peers that have `key` on but wait for a permission there.
    func peerWaiting(_ key: SyncKey) -> [String] {
        guard !excluded.contains(key) else { return [] }
        return peers.filter { $0.value.waiting.contains(key) }.keys.sorted()
    }
}

// MARK: Consent gate

/// A remote change never gives a consent this Mac has to give itself. Codes from messages shows a consent or
/// terms step when it is turned on here (the cloud relay always asks; the local engine needs its model, whose
/// terms are accepted when it is downloaded). When a paired device turns codes on and that step is still
/// needed, codes stays off and the setting waits: it reads as on (so nothing stamps an "off" that would undo the
/// other device's choice), goes in the waiting list, and shows "On, waiting for permission" with Allow. The flag
/// clears when codes actually turns on here, or when the person turns it off.
@MainActor
final class CodesSyncGate {
    static let pendingKey = "settings.sync.pending.codes"

    private let defaults: UserDefaults
    private let isOn: () -> Bool
    private let setOn: (Bool) -> Void
    /// Codes can be turned on here without a dialog.
    private let canEnable: () -> Bool
    /// The waiting state changed (the waiting list may need to go out).
    var onChange: () -> Void = {}

    init(defaults: UserDefaults = .standard, isOn: @escaping () -> Bool, setOn: @escaping (Bool) -> Void, canEnable: @escaping () -> Bool) {
        self.defaults = defaults
        self.isOn = isOn
        self.setOn = setOn
        self.canEnable = canEnable
    }

    /// A paired device turned codes on, and this Mac still has to consent.
    private(set) var pending: Bool {
        get { defaults.bool(forKey: Self.pendingKey) }
        set {
            guard newValue != pending else { return }
            if newValue { defaults.set(true, forKey: Self.pendingKey) } else { defaults.removeObject(forKey: Self.pendingKey) }
            onChange()
        }
    }

    /// Codes turned on here (through the card's own consent step): the wait is over.
    func codesChanged(on: Bool) {
        if on { pending = false }
    }

    /// The person turned codes off here, from the row that reads on while waiting.
    func turnedOffLocally() {
        pending = false
    }

    var setting: SyncedSetting {
        SyncedSetting(
            read: { [unowned self] in .bool(isOn() || pending) },
            write: { [unowned self] value in
                guard case let .bool(on) = value else { return }
                if !on {
                    pending = false
                    setOn(false)
                } else if canEnable() {
                    setOn(true)
                } else {
                    pending = true
                }
            }
        )
    }
}

// MARK: Controller

/// What a synced row shows under it.
struct SyncRowStatus: Equatable {
    /// On here, but this Mac lacks the permission it needs.
    var localWaiting = false
    /// Names of connected phones where the value differs.
    var differentOn: [String] = []
    /// Names of connected phones where it is on but waits for a permission.
    var peerWaiting: [String] = []
}

/// Settings sync on this Mac: the switches, Choose what syncs, storage under `settings.sync.*` (so Reset >
/// Settings clears it), the session rules, the rate limit, the activity item and the banner. The pairing
/// coordinator owns transport.
@MainActor
final class SettingsSyncController: ObservableObject {
    static let recordsKey = "settings.sync.records"
    static let enabledKey = "settings.sync.enabled"
    static let devicesKey = "settings.sync.devices"
    static let excludedKey = "settings.sync.excluded"
    static let stampedKey = "settings.sync.stamped"
    /// First-connect answers per phone: "use", "keep", "peer" or "auto". Outside `settings.`, so Reset > Settings
    /// keeps them; Forget and Reset > Everything remove them.
    static let answersKey = "sync.answers"

    /// Settings > General > Sync settings with paired devices. On by default, on fresh installs too.
    @Published private(set) var enabled: Bool
    /// Devices > [phone] > Sync settings with this device; a missing entry is on.
    @Published private(set) var devices: [String: Bool]
    /// Choose what syncs: settings that stay on this Mac.
    @Published private(set) var excluded: Set<SyncKey>
    /// Bumped whenever a row's status may have changed, so Settings redraws.
    @Published private(set) var revision = 0
    /// First connect: phones whose "Use the same settings as <phone>?" waits for the person, in arrival order.
    @Published private(set) var questions: [String] = []

    /// Sends an encrypted message to a connected phone.
    var send: (_ deviceID: String, _ kind: String, _ payload: [String: Any], _ messageID: String) -> Bool = { _, _, _, _ in false }
    /// The phone's latest features.update showed settings_sync_draft1.
    var remoteEnabled: (_ deviceID: String) -> Bool = { _ in false }
    var connectedPhones: () -> [String] = { [] }
    var peerName: (_ deviceID: String) -> String = { _ in "" }
    /// The permission `key` needs on this Mac is missing.
    var lacksPermission: (_ key: SyncKey) -> Bool = { _ in false }
    /// A switch changed: features.update goes out again.
    var onSwitchChange: () -> Void = {}
    /// A sync changed values here (activity content tokens).
    var onApplied: (_ deviceID: String, _ content: String) -> Void = { _, _ in }
    /// A phone turned on something that waits for a permission or a consent on this Mac (the only notification).
    var onTurnedOn: (_ deviceID: String, _ key: SyncKey, _ waiting: Bool) -> Void = { _, _, _ in }
    /// A first-connect question opened or closed (the app shows or closes its window).
    var onQuestionsChange: () -> Void = {}
    /// Diagnostics: event names and counts only.
    var onEvent: (_ event: String, _ outcome: String?, _ deviceID: String?) -> Void = { _, _, _ in }

    /// When both sides are new, the phone asks. This Mac is never the phone; tests model a phone with it.
    var isPhone = false

    let engine: SettingsSyncEngine
    private let defaults: UserDefaults
    private let debounce: TimeInterval
    private let clock: () -> Int64
    private var failed: Set<String> = []
    private var arrivals: [String: [Int64]] = [:]
    private var rateErrorSent: [String: Int64] = [:]
    private var pendingFlush: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var lastWaiting: [SyncKey] = []

    init(localDeviceID: String, defaults: UserDefaults = .standard, settings: [SyncKey: SyncedSetting],
         clock: @escaping () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) },
         debounce: TimeInterval = SettingsSyncLimits.debounce) {
        self.defaults = defaults
        self.debounce = debounce
        self.clock = clock
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        devices = (defaults.dictionary(forKey: Self.devicesKey) ?? [:]).compactMapValues { $0 as? Bool }
        excluded = Set((defaults.array(forKey: Self.excludedKey) ?? []).compactMap { ($0 as? String).flatMap(SyncKey.init(rawValue:)) })
        var records: [SyncKey: SyncRecord]
        if defaults.bool(forKey: Self.stampedKey) {
            let stored = defaults.dictionary(forKey: Self.recordsKey) ?? [:]
            records = [:]
            for key in SyncKey.allCases {
                records[key] = SyncRecord(key: key, json: stored[key.rawValue]) ?? settings[key].map { .neverChosen($0.read()) } ?? .defaultRecord(key)
            }
        } else {
            // The first run of a build with sync: what the person stored before counts as chosen.
            records = upgradeSyncRecords(stored: settingsSyncStoredValues(defaults.dictionaryRepresentation()),
                                         current: settings.mapValues { $0.read() }, device: localDeviceID)
            Self.write(records, to: defaults)
            defaults.set(true, forKey: Self.stampedKey)
        }
        engine = SettingsSyncEngine(localDeviceID: localDeviceID, records: records, settings: settings, clock: clock) { [defaults] in
            Self.write($0, to: defaults)
        }
        engine.excluded = excluded
        engine.localWaiting = { [weak self] in self?.computeWaiting() ?? [] }
        // Anything changed while this build was not running is a local edit.
        engine.observeLocal()
    }

    private static func write(_ records: [SyncKey: SyncRecord], to defaults: UserDefaults) {
        defaults.set(Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value.json) }), forKey: recordsKey)
    }

    /// Keys on here whose permission is missing on this Mac.
    private func computeWaiting() -> [SyncKey] {
        SyncKey.allCases.filter { key in
            guard let setting = engine.settings[key], setting.read() == .bool(true) else { return false }
            return lacksPermission(key)
        }
    }

    /// The settings of this Mac, watched wherever they change (Settings, setup, Siri, reset).
    static func live(localDeviceID: String, settings: BridgeySettings, focus: FocusSync, codes: CodesSyncGate) -> SettingsSyncController {
        let controller = SettingsSyncController(localDeviceID: localDeviceID, settings: liveSettings(settings, focus: focus, codes: codes))
        let changes: [AnyPublisher<Void, Never>] = [
            settings.$folderReceiveMode.map { _ in () }.eraseToAnyPublisher(),
            settings.$folderConflictPolicy.map { _ in () }.eraseToAnyPublisher(),
            settings.$showActivityPreviews.map { _ in () }.eraseToAnyPublisher(),
            settings.$reduceMotion.map { _ in () }.eraseToAnyPublisher(),
            settings.$globalFeatures.map { _ in () }.eraseToAnyPublisher(),
            settings.$autoClipboardEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$clipboardFilesEnabled.map { _ in () }.eraseToAnyPublisher(),
            settings.$codesEnabled.map { _ in () }.eraseToAnyPublisher(),
            focus.$settings.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published fires before the property changes: read it on the next turn of the main queue.
        Publishers.MergeMany(changes)
            .dropFirst(changes.count)
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] in controller?.localChanged() }
            .store(in: &controller.cancellables)
        return controller
    }

    /// `codes`: Codes from messages goes through its consent gate; nil (tests) writes the switch directly.
    static func liveSettings(_ settings: BridgeySettings, focus: FocusSync, codes: CodesSyncGate? = nil) -> [SyncKey: SyncedSetting] {
        func bool(_ read: @escaping () -> Bool, _ write: @escaping (Bool) -> Void) -> SyncedSetting {
            SyncedSetting(read: { .bool(read()) }, write: { value in if case let .bool(on) = value { write(on) } })
        }
        var out: [SyncKey: SyncedSetting] = [
            // The Mac cannot let the phone pick a folder here, so "sending device chooses" saves to Received files.
            .folderDestination: SyncedSetting(
                read: { .string(settings.folderReceiveMode == .ask ? "receiver_asks" : "fixed") },
                matches: { macFolderReceiveMode(for: $0) == settings.folderReceiveMode },
                write: { settings.setFolderReceiveMode(macFolderReceiveMode(for: $0)) }
            ),
            .folderConflict: SyncedSetting(
                read: { .string(settings.folderConflictPolicy.rawValue) },
                write: { value in
                    if case let .string(raw) = value, let policy = MacFolderConflictPolicy(rawValue: raw) { settings.setFolderConflictPolicy(policy) }
                }
            ),
            .activityPreviews: bool({ settings.showActivityPreviews }, settings.setShowActivityPreviews),
            .reduceMotion: bool({ settings.reduceMotion }, settings.setReduceMotion),
            // Only the global switch; which phone may use a feature stays a grant or override made on this Mac.
            .autoClipboard: bool({ settings.autoClipboardEnabled }, { settings.setAutoClipboard($0) }),
            .clipboardFiles: bool({ settings.clipboardFilesEnabled }, settings.setClipboardFilesEnabled),
            .focusShare: bool({ focus.settings.share }, { on in focus.update { $0.share = on } }),
            .focusFollow: bool({ focus.settings.follow }, { on in focus.update { $0.follow = on } }),
            .codesEnabled: codes?.setting ?? bool({ settings.codesEnabled }, settings.setCodesEnabled),
        ]
        for key in SyncKey.allCases {
            guard let feature = key.feature else { continue }
            // Grant features read on only when their global switch is explicitly on.
            out[key] = bool({ feature.needsDeviceGrant ? settings.globalFeatures[feature] == true : settings.globalFeatures[feature] != false },
                            { settings.setGlobal(feature, enabled: $0) })
        }
        return out
    }

    // MARK: Switches

    /// settings_sync_draft1 for this phone's features.update.
    func advertised(for deviceID: String) -> Bool {
        enabled && devices[deviceID] != false
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        switchChanged()
    }

    func setEnabled(_ on: Bool, for deviceID: String) {
        guard on != (devices[deviceID] ?? true) else { return }
        devices[deviceID] = on
        defaults.set(devices, forKey: Self.devicesKey)
        switchChanged()
    }

    /// Choose what syncs: an unchecked setting stays on this Mac.
    func setSyncs(_ key: SyncKey, _ syncs: Bool) {
        guard syncs == excluded.contains(key) else { return }
        if syncs { excluded.remove(key) } else { excluded.insert(key) }
        defaults.set(excluded.sorted().map(\.rawValue), forKey: Self.excludedKey)
        engine.excluded = excluded
        changed()
        flush()
    }

    /// Turning sync off keeps every value; only the exchange stops.
    private func switchChanged() {
        onSwitchChange()
        refreshAll()
        changed()
    }

    private func changed() { revision &+= 1 }

    // MARK: First connect

    /// What this Mac answered (or decided) for each phone.
    var answers: [String: String] { (defaults.dictionary(forKey: Self.answersKey) ?? [:]).compactMapValues { $0 as? String } }

    private func storeAnswer(_ answer: String, for deviceID: String) {
        var all = answers
        all[deviceID] = answer
        defaults.set(all, forKey: Self.answersKey)
    }

    private func setQuestions(_ list: [String]) {
        guard list != questions else { return }
        questions = list
        onQuestionsChange()
    }

    /// The person answered "Use the same settings as <phone>?".
    func answer(_ deviceID: String, use: Bool) {
        guard engine.isAsking(deviceID) else { return }
        let receipt = engine.answer(deviceID, use: use)
        storeAnswer(use ? "use" : "keep", for: deviceID)
        setQuestions(questions.filter { $0 != deviceID })
        onEvent("first_connect", use ? "use" : "keep", deviceID)
        announce(receipt, from: deviceID)
        flush()
    }

    // MARK: Sessions

    /// Both sides advertise the key, and the phone has not answered `unsupported_schema` this session.
    func isAvailable(_ deviceID: String) -> Bool {
        advertised(for: deviceID) && remoteEnabled(deviceID) && !failed.contains(deviceID)
    }

    func refreshAll() {
        let connected = connectedPhones()
        for id in connected { refresh(id) }
        for id in engine.activePeers where !connected.contains(id) { engine.stop(id) }
    }

    /// The phone's features changed, or a switch here: start (snapshot) or stop syncing with it.
    func refresh(_ deviceID: String) {
        if isAvailable(deviceID) {
            if !engine.isActive(deviceID) { sendSnapshot(to: deviceID) }
        } else if engine.isActive(deviceID) {
            engine.stop(deviceID)
            changed()
        }
    }

    private func sendSnapshot(to deviceID: String) {
        let messageID = UUID().uuidString.lowercased()
        let all = answers
        let first = all[deviceID] == nil, new = all.isEmpty
        let snapshot = engine.start(deviceID, messageID: messageID, first: first, new: new)
        let payload = settingsRecordsPayload(snapshot.records, waiting: snapshot.waiting, snapshot: true, first: first, new: new)
        if send(deviceID, SettingsSyncKinds.snapshot, payload, messageID) {
            onEvent("snapshot_sent", nil, deviceID)
        }
        changed()
    }

    func sessionEnded(_ deviceID: String) {
        engine.stop(deviceID)
        // An open question goes with the session; the next one asks again.
        setQuestions(questions.filter { $0 != deviceID })
        failed.remove(deviceID)
        arrivals.removeValue(forKey: deviceID)
        rateErrorSent.removeValue(forKey: deviceID)
        changed()
    }

    /// Forget device: its switch and session state go; every value stays.
    func forget(_ deviceID: String) {
        sessionEnded(deviceID)
        var all = answers
        if all.removeValue(forKey: deviceID) != nil { defaults.set(all, forKey: Self.answersKey) }
        guard devices.removeValue(forKey: deviceID) != nil else { return }
        defaults.set(devices, forKey: Self.devicesKey)
    }

    // MARK: Messages

    /// More than 20 settings.* messages from one phone in 10 s: the extras are dropped, with one
    /// `rate_limited` reply per window.
    private func admit(_ deviceID: String) -> Bool {
        let now = clock()
        var times = (arrivals[deviceID] ?? []).filter { now - $0 < SettingsSyncLimits.rateWindowMillis }
        guard times.count < SettingsSyncLimits.rateLimit else {
            arrivals[deviceID] = times
            if now - (rateErrorSent[deviceID] ?? Int64.min / 2) >= SettingsSyncLimits.rateWindowMillis {
                rateErrorSent[deviceID] = now
                _ = send(deviceID, SettingsSyncKinds.error, settingsErrorPayload("rate_limited"), UUID().uuidString.lowercased())
                onEvent("rate_limited", nil, deviceID)
            }
            return false
        }
        times.append(now)
        arrivals[deviceID] = times
        return true
    }

    /// A decrypted settings.* plaintext from a phone. Ignored unless both sides advertise the key.
    func receive(kind: String, messageID: String, plaintext: Data, from deviceID: String) {
        guard isAvailable(deviceID), admit(deviceID) else { return }
        if !engine.isActive(deviceID) { sendSnapshot(to: deviceID) }
        defer { changed() }
        switch kind {
        case SettingsSyncKinds.snapshot, SettingsSyncKinds.update:
            switch decodeSettingsPayload(plaintext) {
            case .invalid:
                _ = send(deviceID, SettingsSyncKinds.error, settingsErrorPayload("invalid_message"), UUID().uuidString.lowercased())
                onEvent("rejected", "invalid_message", deviceID)
            case .unsupportedSchema:
                _ = send(deviceID, SettingsSyncKinds.error, settingsErrorPayload("unsupported_schema"), UUID().uuidString.lowercased())
                onEvent("rejected", "unsupported_schema", deviceID)
            case let .payload(payload):
                var asker = SettingsAsker.none
                if kind == SettingsSyncKinds.snapshot {
                    // Decided from the flags this Mac sent in its own snapshot, so both sides agree.
                    let sent = engine.sentFlags(deviceID) ?? (answers[deviceID] == nil, answers.isEmpty)
                    asker = settingsAsker(localFirst: sent.first, localNew: sent.new, isPhone: isPhone,
                                          remoteFirst: payload.first, remoteNew: payload.new)
                    if asker == .none && answers[deviceID] == nil { storeAnswer("auto", for: deviceID) }
                }
                let receipt = kind == SettingsSyncKinds.snapshot
                    ? engine.receiveSnapshot(payload, from: deviceID, asker: asker)
                    : engine.receiveUpdate(payload, from: deviceID)
                _ = send(deviceID, SettingsSyncKinds.ack, settingsAckPayload(ackOf: messageID, applied: receipt.applied, kept: receipt.kept),
                         UUID().uuidString.lowercased())
                if receipt.answerReceived {
                    storeAnswer("peer", for: deviceID)
                    onEvent("first_connect", "peer", deviceID)
                }
                if asker == .local {
                    if engine.differingKeys(deviceID).isEmpty {
                        // Nothing differs: no question, and the phone hears it is answered.
                        _ = engine.answer(deviceID, use: true)
                        storeAnswer("use", for: deviceID)
                    } else {
                        setQuestions(questions.filter { $0 != deviceID } + [deviceID])
                    }
                }
                announce(receipt, from: deviceID)
                // Winning records go back once, changes go on to the other phones, and the waiting list follows.
                flush()
            }
        case SettingsSyncKinds.ack:
            if let ack = decodeSettingsAck(plaintext) { engine.acknowledged(from: deviceID, messageID: ack.ackOf, applied: ack.applied) }
        case SettingsSyncKinds.error:
            let code = decodeSettingsError(plaintext) ?? "other"
            if code == "unsupported_schema" {
                failed.insert(deviceID)
                engine.stop(deviceID)
            }
            onEvent("peer_error", ["unsupported_schema", "invalid_message", "rate_limited"].contains(code) ? code : "other", deviceID)
        default:
            break
        }
    }

    private func announce(_ receipt: SettingsSyncReceipt, from deviceID: String) {
        guard let content = SettingsSyncDetail.encode(receipt.changes) else { return }
        onApplied(deviceID, content)
        onEvent("applied", String(receipt.changes.count), deviceID)
        // A remote turn-on is an activity entry; it notifies only when it waits for a permission or consent here.
        let waiting = Set(computeWaiting())
        for key in receipt.changes.keys.sorted() where key.sharesWhenOn && receipt.changes[key] == .bool(true) && waiting.contains(key) {
            onTurnedOn(deviceID, key, true)
        }
        lastWaiting = engine.waitingList
    }

    // MARK: Local edits and permissions

    /// A synced setting changed here (or was applied from a phone: then nothing is stamped).
    func localChanged() {
        let stamped = engine.observeLocal()
        let waitingChanged = engine.waitingList != lastWaiting
        changed()
        guard !stamped.isEmpty || waitingChanged else { return }
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// A permission may have changed (app activation, a permission check): the waiting list goes out if it moved.
    func permissionsChanged() {
        changed()
        guard engine.waitingList != lastWaiting else { return }
        flush()
    }

    /// "Different on <phone>": this Mac's value, sent to every connected phone as a new edit.
    func applyToAll(_ key: SyncKey) {
        engine.applyToAll(key)
        onEvent("apply_to_all", nil, nil)
        flush()
    }

    /// Sends every ready phone the records and waiting list it has not seen.
    func flush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        lastWaiting = engine.waitingList
        for id in engine.activePeers {
            let messageID = UUID().uuidString.lowercased()
            guard let update = engine.nextUpdate(for: id, messageID: messageID) else { continue }
            _ = send(id, SettingsSyncKinds.update, settingsRecordsPayload(update.records, waiting: update.waiting, snapshot: false,
                                                                          answered: update.answered), messageID)
        }
        changed()
    }

    // MARK: Status

    func status(_ key: SyncKey) -> SyncRowStatus {
        guard enabled, !excluded.contains(key) else { return SyncRowStatus() }
        return SyncRowStatus(
            localWaiting: computeWaiting().contains(key),
            differentOn: engine.differentOn(key).map(peerName),
            peerWaiting: engine.peerWaiting(key).map(peerName)
        )
    }
}

/// What a synced folder destination does on this Mac.
func macFolderReceiveMode(for value: SyncValue) -> MacFolderReceiveMode {
    value == .string("receiver_asks") ? .ask : .fixed
}
