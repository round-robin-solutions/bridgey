import Foundation

/// Where the app and its Share extension keep shared things: the App Group container when the build has the
/// entitlement, else the app's own Application Support (unsigned simulator builds; the extension then sends
/// directly or not at all).
enum SharedStorage {
    static var groupContainer: URL? {
        Edition.appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var root: URL {
        if let group = groupContainer { return group }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Bridgey", isDirectory: true)
    }

    /// Settings both read (the device name, the last device sent to).
    static var defaults: UserDefaults {
        Edition.appGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Received files: the app's Documents folder, which the Files app shows as On My iPhone > Bridgey.
    static var receivedFiles: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Copies of files picked to send, removed once sent.
    static var sendCopies: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Sending", isDirectory: true)
    }
}

/// Something shared from another app that could not go straight away. The app sends it the next time the device
/// it was meant for connects.
struct OutboxItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text, link, file
    }

    var id = UUID()
    var deviceID: String
    var deviceName: String
    var kind: Kind
    /// Text or the link; for a file, its name.
    var value: String
    var created = Date()
}

/// One folder per item under the shared container's Outbox folder: item.json and, for a file, the file itself.
/// Separate folders mean the app and the extension never write the same file.
enum Outbox {
    static var directory: URL { SharedStorage.root.appendingPathComponent("Outbox", isDirectory: true) }

    /// A file name another app suggested, as one plain name in the item's folder: its last component, without `/`,
    /// `:` or control characters, never empty, `.` or `..` (security review 1.0: a sharing app's name could otherwise
    /// put the copy outside the item's folder).
    static func safeFileName(_ name: String?, fallback: String = "file") -> String {
        let last = (name ?? "").split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { $0 != ":" && !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return fallback == "file" ? "file" : safeFileName(fallback)
        }
        return String(cleaned.prefix(200))
    }

    static func add(_ item: OutboxItem, file: URL? = nil) throws {
        let folder = directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
        if file != nil, safeFileName(item.value) != item.value { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file {
            try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(item.value))
        }
        // Written last, so a half-copied item is never read.
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("item.json"), options: .atomic)
    }

    static func items() -> [OutboxItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("item.json"))).flatMap { try? JSONDecoder().decode(OutboxItem.self, from: $0) }
        }
        .sorted { $0.created < $1.created }
    }

    /// The file of a file item.
    static func file(of item: OutboxItem) -> URL {
        directory.appendingPathComponent(item.id.uuidString, isDirectory: true).appendingPathComponent(item.value)
    }

    static func remove(_ item: OutboxItem) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.id.uuidString, isDirectory: true))
    }
}
