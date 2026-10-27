import Darwin
import Foundation

// Section 4.7 and 7.4, receiver side (phone to Mac, and downloads): one append-only journal per folder, so a
// folder interrupted by a disconnect or an app restart resumes without receiving finished files again.
// Owner-only (0600 files in a 0700 folder) under Application Support; it holds names and paths, so it never
// reaches logs or diagnostics. Lines:
//   v1 <base64 JSON header>
//   d <entry> <percent-encoded absolute path>   folder created or reused
//   p <entry> <percent-encoded absolute path>   part file being written
//   f <entry>                                   file verified and in place
//   x <entry>                                   part file abandoned (deleted)
// Written with plain write() before files.complete.ack goes out; that survives the app being killed.

struct ReceiveJournalHeader: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let peerID: String
    var peerName: String
    let manifestSha256: String
    let createdAt: Date
    /// The folder the transfer lands in.
    let directoryPath: String
    /// The transfer's own root folder (`into`: the same as `directoryPath`).
    let rootPath: String
    let rootName: String
    let choice: ConflictChoice
    let into: Bool
    let downloadRequestId: String?
    /// `save`, `dragOut` or `preview`; nil for folders the phone pushed.
    let purpose: String?
    let destinationLabel: String
    /// `into` only: the final name of each top-level entry that was renamed (manifest name to name on disk).
    let topNames: [String: String]
    let fileCount: Int
    let totalSize: Int64
    let displayName: String
}

struct ReceiveJournalRecord: Equatable {
    var header: ReceiveJournalHeader
    var dirs: [Int: String] = [:]
    var parts: [Int: String] = [:]
    var done: Set<Int> = []
    var abandoned: Set<Int> = []
    var lastProgressAt: Date

    func canResume(now: Date) -> Bool { FolderTimeouts.canResume(lastProgress: lastProgressAt, now: now) }
}

final class ReceiveJournalStore: @unchecked Sendable {
    let directory: URL

    init(directory: URL = ReceiveJournalStore.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/FolderReceives", isDirectory: true)
    }

    private func fileURL(_ id: String) -> URL? {
        guard FolderJSON.isWireID(id) else { return nil }
        return directory.appendingPathComponent("\(id).journal")
    }

    /// A new journal for an accepted folder. Nil when it cannot be written (the folder still arrives, but
    /// cannot resume).
    func create(_ header: ReceiveJournalHeader) -> Writer? {
        guard let url = fileURL(header.folderTransferId) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let json = try? encoder.encode(header) else { return nil }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let writer = Writer(fd: fd)
        writer.line("v1 \(json.base64EncodedString())")
        writer.sync()
        return writer
    }

    /// Appends to an existing journal (resume).
    func reopen(_ id: String) -> Writer? {
        guard let url = fileURL(id) else { return nil }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        return fd >= 0 ? Writer(fd: fd) : nil
    }

    func read(_ id: String) -> ReceiveJournalRecord? {
        guard let url = fileURL(id), let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
        return Self.parse(text, modified: modified)
    }

    func all() -> [ReceiveJournalRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".journal") }.compactMap { read(String($0.dropLast(8))) }
    }

    func delete(_ id: String) {
        guard let url = fileURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAll(peerID: String) {
        for record in all() where record.header.peerID == peerID {
            cleanParts(record)
            delete(record.header.folderTransferId)
        }
    }

    /// On start: journals older than 24 hours go; part files without a finished line are deleted. A journal this
    /// build cannot read (another version, damaged) goes too: it only held work in progress (docs/upgrade-policy.md).
    func recover(now: Date = Date()) -> [ReceiveJournalRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".journal") && read(String(name.dropLast(8))) == nil {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        var kept: [ReceiveJournalRecord] = []
        for record in all() {
            cleanParts(record)
            if record.canResume(now: now) {
                kept.append(record)
            } else {
                delete(record.header.folderTransferId)
            }
        }
        return kept
    }

    /// Deletes part files the journal names that never finished. Only `.bridgey-part` files, never others.
    func cleanParts(_ record: ReceiveJournalRecord) {
        for (entry, path) in record.parts where !record.done.contains(entry) {
            guard path.hasSuffix(".bridgey-part") else { continue }
            unlink(path)
        }
    }

    static func parse(_ text: String, modified: Date) -> ReceiveJournalRecord? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst()
        guard first.hasPrefix("v1 "), let json = Data(base64Encoded: String(first.dropFirst(3))) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let header = try? decoder.decode(ReceiveJournalHeader.self, from: json) else { return nil }
        var record = ReceiveJournalRecord(header: header, lastProgressAt: max(modified, header.createdAt))
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let entry = Int(parts[1]), entry >= 0 else { continue }
            switch parts[0] {
            case "d": if parts.count == 3, let path = parts[2].removingPercentEncoding { record.dirs[entry] = path }
            case "p": if parts.count == 3, let path = parts[2].removingPercentEncoding { record.parts[entry] = path }
            case "f": record.done.insert(entry)
            case "x": record.abandoned.insert(entry)
            default: continue
            }
        }
        return record
    }

    final class Writer: @unchecked Sendable {
        private var fd: Int32
        private var unsynced = 0

        init(fd: Int32) { self.fd = fd }

        deinit { close() }

        func dir(_ entry: Int, _ url: URL) { line("d \(entry) \(Self.encode(url.path))") }
        func part(_ entry: Int, _ url: URL) { line("p \(entry) \(Self.encode(url.path))") }
        func done(_ entry: Int) { line("f \(entry)") }
        func abandoned(_ entry: Int) { line("x \(entry)") }

        func line(_ text: String) {
            guard fd >= 0 else { return }
            let data = Array((text + "\n").utf8)
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            unsynced += 1
            if unsynced >= 100 { sync() }
        }

        func sync() {
            guard fd >= 0 else { return }
            fsync(fd)
            unsynced = 0
        }

        func close() {
            guard fd >= 0 else { return }
            sync()
            Darwin.close(fd)
            fd = -1
        }

        private static func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))) ?? value
        }
    }
}
