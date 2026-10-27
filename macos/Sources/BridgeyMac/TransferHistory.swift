import Combine
import Foundation

// Transfer history (Files 2.0): every finished send, receive, download and upload, newest first, for the
// History window's search and filters and for "Show in Finder". User-facing, so names are kept whatever the
// Privacy > Logging file-name switch says, but only in an owner-only file (0600 in a 0700 folder) on this
// Mac: never in logs or diagnostics. Bounded: 2,000 entries and 30 days.

struct TransferHistoryEntry: Codable, Equatable, Identifiable {
    enum Direction: String, Codable, CaseIterable {
        /// This Mac sent it (send sheet, drop, Tray, upload into a phone folder).
        case sent
        /// The phone sent it (share sheet, in-app send, a download this Mac asked for).
        case received
    }

    enum Outcome: String, Codable, CaseIterable {
        case completed, incomplete, failed, cancelled
    }

    let id: String
    let date: Date
    let direction: Direction
    let deviceID: String
    let deviceName: String
    /// The file or folder name (a folder transfer is one entry).
    let name: String
    let isFolder: Bool
    let fileCount: Int
    let bytes: Int64
    let outcome: Outcome
    /// Where it is on this Mac: the received item, or the sent source. Nil when unknown.
    let localPath: String?
    /// Where it went on the phone ("Pictures/Trip"), for sends.
    let destination: String?
    /// A download the Mac asked for from the Phone files window (not something the phone pushed).
    let download: Bool

    init(id: String, date: Date, direction: Direction, deviceID: String, deviceName: String, name: String,
         isFolder: Bool = false, fileCount: Int = 1, bytes: Int64, outcome: Outcome, localPath: String? = nil,
         destination: String? = nil, download: Bool = false) {
        self.id = id
        self.date = date
        self.direction = direction
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.name = name
        self.isFolder = isFolder
        self.fileCount = fileCount
        self.bytes = bytes
        self.outcome = outcome
        self.localPath = localPath
        self.destination = destination
        self.download = download
    }

    var localURL: URL? { localPath.map { URL(fileURLWithPath: $0) } }
}

/// What the History window filters on.
struct TransferHistoryFilter: Equatable {
    var query = ""
    var direction: TransferHistoryEntry.Direction?
    var deviceID: String?
    var outcome: TransferHistoryEntry.Outcome?
    var foldersOnly = false

    func matches(_ entry: TransferHistoryEntry) -> Bool {
        if let direction, entry.direction != direction { return false }
        if let deviceID, entry.deviceID != deviceID { return false }
        if let outcome, entry.outcome != outcome { return false }
        if foldersOnly, !entry.isFolder { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        return [entry.name, entry.deviceName, entry.destination ?? ""].contains {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

@MainActor
final class TransferHistoryStore: ObservableObject {
    nonisolated static let maximumEntries = 2_000
    nonisolated static let retention: TimeInterval = 30 * 24 * 60 * 60

    @Published private(set) var entries: [TransferHistoryEntry]

    private let fileURL: URL?
    private let clock: () -> Date

    /// `fileURL` nil keeps history in memory only (tests, screenshots).
    init(fileURL: URL? = TransferHistoryStore.defaultFileURL(), clock: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.clock = clock
        entries = Self.pruned(Self.load(fileURL), now: clock())
    }

    /// Adds or replaces (same id) an entry, newest first, then prunes and saves.
    func record(_ entry: TransferHistoryEntry) {
        var next = entries.filter { $0.id != entry.id }
        next.append(entry)
        entries = Self.pruned(next, now: clock())
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func prune() {
        let next = Self.pruned(entries, now: clock())
        guard next != entries else { return }
        entries = next
        save()
    }

    /// Forget device: its entries go too.
    func forget(deviceID: String) {
        entries.removeAll { $0.deviceID == deviceID }
        save()
    }

    func filtered(_ filter: TransferHistoryFilter) -> [TransferHistoryEntry] { entries.filter(filter.matches) }

    nonisolated static func pruned(_ list: [TransferHistoryEntry], now: Date) -> [TransferHistoryEntry] {
        let cutoff = now.addingTimeInterval(-retention)
        return Array(list.filter { $0.date >= cutoff && $0.date <= now.addingTimeInterval(24 * 60 * 60) }
            .sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
            .prefix(maximumEntries))
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        Self.write(data, to: fileURL)
    }

    private static func load(_ fileURL: URL?) -> [TransferHistoryEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([TransferHistoryEntry].self, from: data)) ?? []
    }

    /// Owner-only, atomic: a 0700 folder, a 0600 temporary file renamed over the old one.
    private static func write(_ data: Data, to target: URL) {
        let manager = FileManager.default
        let directory = target.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, target.path) != 0 {
            try? manager.removeItem(at: temporary)
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/transfer-history.json")
    }
}
