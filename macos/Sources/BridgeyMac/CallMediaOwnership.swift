import Darwin
import Foundation

struct CallMediaMutedOwnership: Codable, Equatable {
    var before: CallMediaSession
    var after: CallMediaSession
}

@MainActor
protocol CallMediaOwnershipStore {
    func load() throws -> [CallMediaMutedOwnership]
    func save(_ leases: [CallMediaMutedOwnership]) throws
}

/// A write-ahead ledger for persistent per-player volume changes. No caller or media text is
/// recorded, and recovery never resumes playback. It is cleared after sound is restored or
/// the exact process/volume/route no longer matches. The journal is excluded from backups.
@MainActor
final class CallMediaFileOwnershipStore: CallMediaOwnershipStore {
    static var liveDefaultAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == Edition.identifier
    }
    private struct Record: Codable { var version = 1; var leases: [CallMediaMutedOwnership] }
    private let url: URL

    init(url: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.url = url ?? support.appendingPathComponent(Edition.supportFolderName, isDirectory: true)
            .appendingPathComponent("call-media-owned-sound.json")
    }

    func load() throws -> [CallMediaMutedOwnership] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1, record.leases.count <= 32,
              Set(record.leases.map { $0.before.id }).count == record.leases.count,
              record.leases.allSatisfy(Self.valid) else { throw CocoaError(.fileReadCorruptFile) }
        return record.leases
    }

    func save(_ leases: [CallMediaMutedOwnership]) throws {
        guard leases.count <= 32, Set(leases.map { $0.before.id }).count == leases.count,
              leases.allSatisfy(Self.valid) else { throw CocoaError(.fileWriteInvalidFileName) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Record(leases: leases))
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        let temporary = directory.appendingPathComponent(".call-media-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var renamed = false
        defer { close(fd); if !renamed { try? FileManager.default.removeItem(at: temporary) } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        let parent = open(directory.path, O_RDONLY)
        if parent >= 0 { defer { close(parent) }; guard fsync(parent) == 0 else { throw POSIXError(.EIO) } }
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }

    private static func valid(_ lease: CallMediaMutedOwnership) -> Bool {
        let before = lease.before
        let after = lease.after
        return before.id == after.id && before.bundleID == after.bundleID &&
            CallMediaMacScripts.isScripted(before.bundleID) && before.id.utf8.count <= 512 &&
            before.contentID.utf8.count <= 128 && after.contentID.utf8.count <= 128 &&
            before.routeID == after.routeID && !before.routeID.isEmpty && before.routeID != "unavailable" &&
            before.routeID.utf8.count <= 128 && (1...100).contains(before.volume ?? 0) && after.volume == 0
    }
}
