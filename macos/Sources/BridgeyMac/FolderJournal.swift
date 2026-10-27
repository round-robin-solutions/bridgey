import Foundation

// Section 4.7 and 7.4, sender side: one small journal per folder transfer, so an interrupted folder resumes
// after a reconnect or an app restart without sending finished files again. Owner-only files (0600) in an
// owner-only folder (0700). Folder names and paths stay on this Mac, like the activity stream.

struct FolderJournal: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let deviceID: String
    var deviceName: String
    /// The folder on this Mac, and bookmark data so a moved folder is still found.
    let rootPath: String
    let bookmark: Data?
    let displayName: String
    let rootName: String
    let options: FolderScanOptions
    let destination: FolderDestination?
    var destinationLabel: String?
    let manifestSha256: String
    let fileCount: Int
    let totalSize: Int64
    let createdAt: Date
    var lastProgressAt: Date
    /// Entries whose files.complete.ack arrived.
    var completed: [Int]
    /// Files 2.0 browse: an upload of several items (`into`): their paths, scanned again on resume.
    var roots: [String]? = nil
    var into: Bool? = nil

    func canResume(now: Date) -> Bool { FolderTimeouts.canResume(lastProgress: lastProgressAt, now: now) }

    /// The folder as it is now: the bookmark first (it follows a move), else the stored path.
    func resolveRoot() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(fileURLWithPath: rootPath, isDirectory: true)
    }
}

final class FolderJournalStore {
    let directory: URL

    init(directory: URL = FolderJournalStore.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/FolderTransfers", isDirectory: true)
    }

    private func fileURL(_ id: String) -> URL? {
        guard FolderJSON.isWireID(id) else { return nil }
        return directory.appendingPathComponent("\(id).json")
    }

    func save(_ journal: FolderJournal) {
        guard let target = fileURL(journal.folderTransferId) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(journal) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(journal.folderTransferId).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, target.path) != 0 {
            try? manager.removeItem(at: temporary)
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Every journal that can still resume. Expired, unreadable and foreign files are deleted.
    func load(now: Date) -> [FolderJournal] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var journals: [FolderJournal] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: url),
                  data.count <= 1024 * 1024,
                  let journal = try? decoder.decode(FolderJournal.self, from: data),
                  journal.version == 1,
                  name == "\(journal.folderTransferId).json",
                  journal.canResume(now: now) else {
                try? manager.removeItem(at: url)
                continue
            }
            journals.append(journal)
        }
        return journals.sorted { $0.createdAt < $1.createdAt }
    }

    func delete(_ id: String) {
        guard let target = fileURL(id) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// Forget device.
    func deleteAll(deviceID: String, now: Date = Date()) {
        for journal in load(now: now) where journal.deviceID == deviceID { delete(journal.folderTransferId) }
    }
}

/// `folders.lastDestination.<deviceId>`: the place and path last chosen for each phone. Mac only, never synced.
struct FolderDestinationMemory {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func key(_ deviceID: String) -> String { "folders.lastDestination.\(deviceID)" }

    func last(for deviceID: String) -> FolderDestination? {
        guard let value = defaults.dictionary(forKey: Self.key(deviceID)),
              let placeId = value["placeId"] as? String, FolderJSON.isPlaceID(placeId),
              let path = value["path"] as? String, FolderPaths.isValidExistingPath(path) else { return nil }
        return FolderDestination(placeId: placeId, path: path)
    }

    func remember(_ destination: FolderDestination, for deviceID: String) {
        defaults.set(["placeId": destination.placeId, "path": destination.path], forKey: Self.key(deviceID))
    }

    func forget(_ deviceID: String) { defaults.removeObject(forKey: Self.key(deviceID)) }
}
