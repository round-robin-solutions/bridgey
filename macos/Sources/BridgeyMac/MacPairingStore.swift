import CryptoKit
import Darwin
import Foundation
import Security

/// This Mac's pairing state: its long-term P-256 signing key and the phones it trusts.
///
/// Stored in `~/Library/Application Support/in.roundrobin.bridgey/trust-v3.json` (folder 0700,
/// file 0600, excluded from backups), the same model as `~/.ssh`. The login Keychain is not
/// used: for code without an Apple-issued certificate, every build gets its own Keychain
/// partition (`cdhash:`), so each update asked for the login password. See
/// docs/rr-mac-signing.md and SECURITY.md.
struct MacPairingContents: Equatable {
    /// Raw 32-byte P-256 signing key.
    var identityKey: Data
    var devices: [String: MacTrustedDevice]
}

enum PairingStoreIssue: Equatable {
    /// Moving the old Keychain items needs one Keychain read, which was denied or cancelled.
    case keychainAccessDenied(OSStatus)
    /// The pairing file or its folder is damaged, owned by someone else, or a symlink.
    case fileUnreadable(String)
}

// MARK: - Keychain (migration source only)

struct KeychainItemName: Equatable, Hashable {
    let service: String
    let account: String
}

/// The Keychain items older versions wrote.
struct LegacyKeychainItems {
    /// Built from rr/mac-signing-updates only: identity and trust in one JSON item.
    var v2: KeychainItemName
    /// 0.2 to 0.6.0-rr.1-beta.7: JSON map of trusted phones.
    var trust: KeychainItemName
    /// 0.2 to 0.6.0-rr.1-beta.7: raw P-256 signing key.
    var identity: KeychainItemName

    static let edition = LegacyKeychainItems(
        v2: KeychainItemName(service: Edition.trustKeychainService, account: "state-v2"),
        trust: KeychainItemName(service: Edition.trustKeychainService, account: "trusted-devices-v1"),
        identity: KeychainItemName(service: Edition.identityKeychainService, account: "p256-signing-v1")
    )

    var all: [KeychainItemName] { [v2, trust, identity] }
}

enum KeychainReadResult: Equatable {
    case found(Data)
    case missing
    case failed(OSStatus)
}

/// Read-and-retire access to the Keychain items older versions wrote. Injected so tests never
/// touch a real keychain.
protocol LegacyKeychainSource {
    func read(_ name: KeychainItemName) -> KeychainReadResult
    /// Removes the secret without asking the user: overwrite with an empty marker, then try to
    /// delete. Returns true when the item is gone or holds nothing secret any more.
    func retire(_ name: KeychainItemName) -> Bool
}

/// The only Keychain calls left in the app. Used once, to move pre-v3 items into the file.
struct SystemKeychainSource: LegacyKeychainSource {
    func read(_ name: KeychainItemName) -> KeychainReadResult {
        var query = Self.query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = item as? Data else { return .failed(errSecDecode) }
        return .found(data)
    }

    func retire(_ name: KeychainItemName) -> Bool {
        // An item made by an older build can be overwritten without a prompt, but deleting it
        // could ask the user again (it belongs to that build). So overwrite first, then try the
        // delete with prompts switched off.
        KeychainInteraction.withoutUserInteraction {
            let query = Self.query(name)
            // An empty value is ignored by the file keychain, so the marker has to have content.
            let wiped = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Self.retiredMarker] as CFDictionary)
            let deleted = SecItemDelete(query as CFDictionary)
            NSLog("PAIRING_STORE retire overwrite=%d delete=%d", wiped, deleted)
            return deleted == errSecSuccess || deleted == errSecItemNotFound || wiped == errSecSuccess
        }
    }

    /// What a retired item holds when macOS will not let this build delete it.
    static let retiredMarker = Data("moved-to-trust-v3.json".utf8)

    private static func query(_ name: KeychainItemName) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: name.service,
            kSecAttrAccount as String: name.account,
        ]
    }
}

/// `SecKeychainSetUserInteractionAllowed` is deprecated but is the only switch for the file
/// keychain. Called through a protocol so the deprecation stays in one place.
private protocol KeychainInteractionSwitch { func set(_ allowed: Bool) }
private struct LegacyKeychainInteractionSwitch: KeychainInteractionSwitch {
    @available(macOS, deprecated: 10.10)
    func set(_ allowed: Bool) { SecKeychainSetUserInteractionAllowed(allowed) }
}
private enum KeychainInteraction {
    static func withoutUserInteraction<T>(_ body: () -> T) -> T {
        let toggle: KeychainInteractionSwitch = LegacyKeychainInteractionSwitch()
        toggle.set(false)
        defer { toggle.set(true) }
        return body()
    }
}

// MARK: - Store

final class MacPairingStore {
    static let shared = MacPairingStore()

    static let fileName = "trust-v3.json"

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private let keychain: LegacyKeychainSource
    private let legacy: LegacyKeychainItems
    private let makeIdentityKey: () -> Data
    /// Test hook: runs after the temp file is written and synced, before the rename.
    var beforeRename: ((URL) throws -> Void)?

    private(set) var contents: MacPairingContents?
    private(set) var issue: PairingStoreIssue?

    var isReady: Bool { contents != nil }

    init(
        directory: URL = MacPairingStore.defaultDirectory,
        keychain: LegacyKeychainSource = SystemKeychainSource(),
        legacy: LegacyKeychainItems = .edition,
        makeIdentityKey: @escaping () -> Data = { P256.Signing.PrivateKey().rawRepresentation },
        loadNow: Bool = true
    ) {
        self.directory = directory
        self.keychain = keychain
        self.legacy = legacy
        self.makeIdentityKey = makeIdentityKey
        if loadNow { load() }
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Edition.supportFolderName, isDirectory: true)
    }

    /// Loads the file, or moves the old Keychain items into a new one. Safe to call again
    /// (for example from the panel's Try again) while `issue` is set.
    func load() {
        guard contents == nil else { return }
        do {
            try PairingFile.prepareDirectory(directory)
            PairingFile.removeStaleTemporaryFiles(in: directory, for: Self.fileName)
            if let data = try PairingFile.readIfPresent(fileURL) {
                contents = try PairingFileFormat.decode(data)
                PairingFile.excludeFromBackup(fileURL)
                issue = nil
                return
            }
        } catch {
            NSLog("PAIRING_STORE file unreadable: %@", String(describing: error))
            issue = .fileUnreadable(String(describing: error))
            return
        }
        migrateFromKeychain()
    }

    /// Applies a change to the trusted devices and saves it. Unchanged contents are not written.
    @discardableResult
    func updateDevices(_ change: (inout [String: MacTrustedDevice]) -> Void) -> Bool {
        guard var next = contents else { return false }
        change(&next.devices)
        if next == contents { return true }
        do {
            try save(next)
            contents = next
            return true
        } catch {
            NSLog("PAIRING_STORE save failed: %@", String(describing: error))
            return false
        }
    }

    private func save(_ value: MacPairingContents) throws {
        try PairingFile.writeAtomically(PairingFileFormat.encode(value), to: fileURL, beforeRename: beforeRename)
    }

    /// First launch after an update from a Keychain build. A failed read never leads to a new
    /// identity: nothing is written or retired until every existing item has been read.
    private func migrateFromKeychain() {
        var found: [KeychainItemName: Data] = [:]
        for name in legacy.all {
            switch keychain.read(name) {
            case .found(let data): found[name] = data
            case .missing: continue
            case .failed(let status):
                NSLog("PAIRING_STORE keychain read failed status=%d; will retry", status)
                issue = .keychainAccessDenied(status)
                return
            }
        }
        var migrated = MacPairingContents(identityKey: Data(), devices: [:])
        if let v2 = found[legacy.v2],
           let decoded = try? JSONDecoder().decode(KeychainStateV2.self, from: v2) {
            migrated.identityKey = decoded.identityKey ?? Data()
            migrated.devices = decoded.devices
        }
        if migrated.devices.isEmpty, let trust = found[legacy.trust] {
            migrated.devices = (try? JSONDecoder().decode([String: MacTrustedDevice].self, from: trust)) ?? [:]
        }
        if migrated.identityKey.isEmpty, let identity = found[legacy.identity] {
            migrated.identityKey = identity
        }
        if (try? P256.Signing.PrivateKey(rawRepresentation: migrated.identityKey)) == nil {
            // Nothing stored (a new install) or a stored key that is not a P-256 key at all.
            if !migrated.identityKey.isEmpty { NSLog("PAIRING_STORE stored identity key was invalid; creating a new one") }
            migrated.identityKey = makeIdentityKey()
        }
        migrated.devices = PairingFileFormat.validDevices(migrated.devices)
        do {
            try save(migrated)
            guard let written = try PairingFile.readIfPresent(fileURL),
                  try PairingFileFormat.decode(written) == migrated else {
                throw PairingFileError.verifyFailed
            }
        } catch {
            NSLog("PAIRING_STORE could not write the pairing file: %@", String(describing: error))
            issue = .fileUnreadable(String(describing: error))
            return
        }
        contents = migrated
        issue = nil
        for name in found.keys where !keychain.retire(name) {
            NSLog("PAIRING_STORE could not retire a Keychain item; it is left in place")
        }
        if !found.isEmpty {
            NSLog("PAIRING_STORE moved %d Keychain item(s) to %@", found.count, Self.fileName)
        }
    }

    /// Test helper.
    func deleteStorageForTesting() {
        try? FileManager.default.removeItem(at: fileURL)
        contents = nil
    }
}

/// Shape of the short-lived `state-v2` Keychain item (built from rr/mac-signing-updates only).
private struct KeychainStateV2: Decodable {
    var identityKey: Data?
    var devices: [String: MacTrustedDevice] = [:]
}

// MARK: - File format

enum PairingFileError: Error, Equatable {
    case notADirectory
    case notARegularFile
    case symlink
    case wrongOwner
    case tooLarge
    case unsupportedVersion(Int)
    case invalidIdentityKey
    case verifyFailed
    case system(String, Int32)
}

enum PairingFileFormat {
    static let version = 3

    private struct File: Codable {
        let version: Int
        /// Raw P-256 private key bytes, base64.
        let identityKey: String
        let devices: [MacTrustedDevice]
    }

    static func encode(_ value: MacPairingContents) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let devices = value.devices.values.sorted { $0.id < $1.id }
        return try encoder.encode(File(version: version, identityKey: value.identityKey.base64EncodedString(), devices: devices))
    }

    static func decode(_ data: Data) throws -> MacPairingContents {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == version else { throw PairingFileError.unsupportedVersion(file.version) }
        guard let key = Data(base64Encoded: file.identityKey),
              (try? P256.Signing.PrivateKey(rawRepresentation: key)) != nil else {
            throw PairingFileError.invalidIdentityKey
        }
        let byID = Dictionary(file.devices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return MacPairingContents(identityKey: key, devices: validDevices(byID))
    }

    static func validDevices(_ devices: [String: MacTrustedDevice]) -> [String: MacTrustedDevice] {
        devices.filter { id, device in
            id == device.id && UUID(uuidString: id) != nil && !device.name.isEmpty
                && Data(base64Encoded: device.identityKey) != nil
        }
    }
}

// MARK: - Private file I/O (POSIX, so modes and sync are explicit)

enum PairingFile {
    static let maximumSize = 1 << 20

    /// Creates the folder 0700, or checks it is ours and tightens it to 0700.
    static func prepareDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw PairingFileError.system("lstat folder", errno) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &info) == 0 else { throw PairingFileError.system("lstat folder", errno) }
        }
        if info.st_mode & S_IFMT == S_IFLNK { throw PairingFileError.symlink }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw PairingFileError.notADirectory }
        guard info.st_uid == getuid() else { throw PairingFileError.wrongOwner }
        if info.st_mode & 0o777 != 0o700 {
            NSLog("PAIRING_STORE folder mode %@ is not 700; repairing", String(info.st_mode & 0o777, radix: 8))
            guard chmod(url.path, 0o700) == 0 else { throw PairingFileError.system("chmod folder", errno) }
        }
    }

    /// Reads the file if it exists. Refuses symlinks and other owners; tightens a loose mode.
    static func readIfPresent(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw PairingFileError.symlink }
            throw PairingFileError.system("open", errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw PairingFileError.system("fstat", errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw PairingFileError.notARegularFile }
        guard info.st_uid == getuid() else { throw PairingFileError.wrongOwner }
        guard info.st_size <= maximumSize else { throw PairingFileError.tooLarge }
        if info.st_mode & 0o777 != 0o600 {
            NSLog("PAIRING_STORE file mode %@ is not 600; repairing", String(info.st_mode & 0o777, radix: 8))
            guard fchmod(fd, 0o600) == 0 else { throw PairingFileError.system("fchmod", errno) }
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw PairingFileError.system("read", errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximumSize else { throw PairingFileError.tooLarge }
        }
        return data
    }

    /// temp file (0600, O_EXCL) -> write -> F_FULLFSYNC -> rename over the target -> fsync folder.
    /// On any failure the temp file is removed and the old file is untouched.
    static func writeAtomically(_ data: Data, to url: URL, beforeRename: ((URL) throws -> Void)? = nil) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PairingFileError.system("create temp", errno) }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }
        do {
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0 else { throw PairingFileError.system("fchmod temp", errno) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw PairingFileError.system("write", errno)
                    }
                    offset += written
                }
            }
            // F_FULLFSYNC asks the drive to flush its cache too; plain fsync is the fallback.
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw PairingFileError.system("fsync", errno) }
        }
        excludeFromBackup(temp)
        try beforeRename?(temp)
        guard rename(temp.path, url.path) == 0 else { throw PairingFileError.system("rename", errno) }
        renamed = true
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            close(directoryFD)
        }
    }

    /// A crash between write and rename leaves `.trust-v3.json.tmp-*` behind; it is never read.
    static func removeStaleTemporaryFiles(in directory: URL, for fileName: String) {
        let prefix = ".\(fileName).tmp-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
