import Foundation

/// One Mac action a phone asked for: run or refused. Never the volume level.
struct MacActionAuditEntry: Codable, Identifiable, Equatable {
    /// The request ID.
    let id: String
    let deviceID: String
    let deviceName: String
    /// The wire identifier (`lock`, `app:com.apple.Safari`, `shortcut:<handle>`), or `unknown`.
    let action: String
    /// The app or Shortcut name, or the action's title, when known.
    let title: String
    /// `done` or a refusal reason (`not_allowed`, `rate_limited`, ...).
    let outcome: String
    let at: Date

    var accepted: Bool { outcome == "done" }
}

/// `mac-actions-audit.json` in Application Support: owner-only, 30 days, at most 500 entries.
final class MacActionsAuditStore {
    static let fileName = "mac-actions-audit.json"
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let maximumEntries = 500

    let fileURL: URL

    init(fileURL: URL = MacActionsAuditStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load(now: Date) -> [MacActionAuditEntry] {
        // An entry that does not decode is dropped on its own (docs/upgrade-policy.md), not the whole log.
        guard let data = try? Data(contentsOf: fileURL),
              let elements = try? Self.decoder.decode([LenientElement<MacActionAuditEntry>].self, from: data) else { return [] }
        let decoded = elements.compactMap(\.value)
        let kept = Self.pruned(decoded, now: now)
        if kept != decoded || elements.count != decoded.count { save(kept) }
        return kept
    }

    func save(_ entries: [MacActionAuditEntry]) {
        guard let data = try? Self.encoder.encode(entries) else { return }
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

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Newest first, nothing older than 30 days, at most 500 entries.
    static func pruned(_ entries: [MacActionAuditEntry], now: Date) -> [MacActionAuditEntry] {
        let oldest = now.addingTimeInterval(-maximumAge)
        return Array(entries.filter { $0.at >= oldest }.sorted { $0.at > $1.at }.prefix(maximumEntries))
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/\(fileName)")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

/// The action log in memory, shown in Settings > Media and actions and cleared there.
@MainActor
final class MacActionsAuditLog: ObservableObject {
    @Published private(set) var entries: [MacActionAuditEntry]

    private let store: MacActionsAuditStore?
    private let clock: () -> Date

    init(store: MacActionsAuditStore? = MacActionsAuditStore(), clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
        entries = store?.load(now: clock()) ?? []
    }

    func record(_ entry: MacActionAuditEntry) {
        BridgeyLog.remote.notice(
            "mac action peer=\(shortDeviceID(entry.deviceID), privacy: .public) action=\(entry.action.hasPrefix("shortcut:") ? "shortcut" : entry.action, privacy: .public) outcome=\(entry.outcome, privacy: .public)"
        )
        entries = MacActionsAuditStore.pruned([entry] + entries.filter { $0.id != entry.id }, now: clock())
        store?.save(entries)
    }

    func clear() {
        entries = []
        store?.clear()
    }

    func prune() {
        let kept = MacActionsAuditStore.pruned(entries, now: clock())
        guard kept != entries else { return }
        entries = kept
        store?.save(kept)
    }
}
