import Foundation

/// bridgey_core's storage on iOS: the identity, the trusted devices and Connect anywhere's keys and state in the
/// Keychain (KeychainStore); larger data the library keeps for features, such as the phone's conversations
/// (`sms-<device>`) and interrupted files (`file-resume`), in files only this app reads, protected until the first
/// unlock and left out of backups.
final class HybridStore: SecretStore, @unchecked Sendable {
    /// Keys that hold secrets or pairing data.
    static let keychainKeys: Set<String> = ["identity", "trust", "node", "connect-state"]

    let keychain: SecretStore
    let folder: URL
    private let lock = NSLock()

    init(keychain: SecretStore = KeychainStore(), folder: URL = HybridStore.defaultFolder) {
        self.keychain = keychain
        self.folder = folder
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Core", isDirectory: true)
    }

    /// The library's keys are short ASCII names; anything else is refused rather than turned into a path.
    private func file(_ key: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !key.isEmpty, key.count <= 128, !key.hasPrefix("."), key.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return folder.appendingPathComponent(key, isDirectory: false)
    }

    func load(_ key: String) throws -> Data? {
        if Self.keychainKeys.contains(key) { return try keychain.load(key) }
        let url = try file(key)
        return lock.withLock { FileManager.default.fileExists(atPath: url.path) ? try? Data(contentsOf: url) : nil }
    }

    func store(_ key: String, _ value: Data) throws {
        if Self.keychainKeys.contains(key) { return try keychain.store(key, value) }
        let url = try file(key)
        try lock.withLock {
            var dir = folder
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dir.setResourceValues(values)
            }
            try value.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func remove(_ key: String) throws {
        if Self.keychainKeys.contains(key) { return try keychain.remove(key) }
        let url = try file(key)
        try lock.withLock {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Forget all devices: the conversations and partial files kept for them go too.
    static func removeFeatureData(folder: URL = defaultFolder) {
        try? FileManager.default.removeItem(at: folder)
    }
}
