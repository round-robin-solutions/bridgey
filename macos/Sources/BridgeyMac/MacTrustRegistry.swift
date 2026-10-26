import Foundation
import Security

struct MacTrustedDevice: Codable, Equatable {
    let id: String
    let name: String
    let identityKey: String
}

/// Everything Bridgey keeps in the Keychain, in one item.
///
/// The app is not signed with an Apple-issued certificate, so macOS files each Keychain item
/// under the exact build that created it (partition `cdhash:<build hash>`). After an update the
/// first read of each item asks for the login password. One item means one question per update,
/// not one per item. See docs/rr-mac-signing.md.
struct MacKeychainContents: Codable, Equatable {
    /// Raw P-256 signing key of this Mac.
    var identityKey: Data?
    var devices: [String: MacTrustedDevice] = [:]
}

struct KeychainItemName: Equatable {
    let service: String
    let account: String
}

final class MacKeychainState {
    enum LoadResult: Equatable {
        case loaded
        case empty
        /// The item exists but could not be read (for example the user chose Deny). Nothing is
        /// written or deleted in this state, so the next launch can still read what is stored.
        case unavailable(OSStatus)
    }

    /// The app's only reader of its Keychain item; created on first use.
    static let shared = MacKeychainState()

    static let current = KeychainItemName(service: Edition.trustKeychainService, account: "state-v2")
    static let legacyTrust = KeychainItemName(service: Edition.trustKeychainService, account: "trusted-devices-v1")
    static let legacyIdentity = KeychainItemName(service: Edition.identityKeychainService, account: "p256-signing-v1")

    private let item: KeychainItemName
    private let legacyTrust: KeychainItemName?
    private let legacyIdentity: KeychainItemName?
    private(set) var contents = MacKeychainContents()
    private(set) var loadResult: LoadResult = .empty

    init(
        item: KeychainItemName = MacKeychainState.current,
        legacyTrust: KeychainItemName? = MacKeychainState.legacyTrust,
        legacyIdentity: KeychainItemName? = MacKeychainState.legacyIdentity
    ) {
        self.item = item
        self.legacyTrust = legacyTrust
        self.legacyIdentity = legacyIdentity
        load()
    }

    var canWrite: Bool {
        if case .unavailable = loadResult { return false }
        return true
    }

    /// Applies a change and saves it. Unchanged contents are not written again.
    @discardableResult
    func update(_ change: (inout MacKeychainContents) -> Void) -> Bool {
        var next = contents
        change(&next)
        if next == contents { return true }
        guard canWrite, Self.write(next, to: item) else { return false }
        contents = next
        return true
    }

    func deleteStorageForTesting() {
        [item, legacyTrust, legacyIdentity].compactMap { $0 }.forEach(Self.delete)
        contents = MacKeychainContents()
    }

    private func load() {
        switch Self.read(item) {
        case .found(let data):
            guard let decoded = try? JSONDecoder().decode(MacKeychainContents.self, from: data) else {
                loadResult = .unavailable(errSecDecode)
                return
            }
            contents = Self.sanitized(decoded)
            loadResult = .loaded
        case .failed(let status):
            loadResult = .unavailable(status)
        case .missing:
            migrateLegacyItems()
        }
    }

    /// One-time move from the two pre-v2 items (trust, identity) into the v2 item.
    private func migrateLegacyItems() {
        var migrated = MacKeychainContents()
        var found = false
        if let legacyTrust {
            switch Self.read(legacyTrust) {
            case .found(let data):
                found = true
                migrated.devices = (try? JSONDecoder().decode([String: MacTrustedDevice].self, from: data)) ?? [:]
            case .failed(let status):
                loadResult = .unavailable(status)
                return
            case .missing:
                break
            }
        }
        if let legacyIdentity {
            switch Self.read(legacyIdentity) {
            case .found(let data):
                found = true
                migrated.identityKey = data
            case .failed(let status):
                loadResult = .unavailable(status)
                return
            case .missing:
                break
            }
        }
        guard found else {
            loadResult = .empty
            return
        }
        contents = Self.sanitized(migrated)
        loadResult = .loaded
        if Self.write(contents, to: item) {
            [legacyTrust, legacyIdentity].compactMap { $0 }.forEach(Self.delete)
        }
    }

    private static func sanitized(_ value: MacKeychainContents) -> MacKeychainContents {
        var result = value
        result.devices = value.devices.filter { id, device in
            id == device.id && UUID(uuidString: id) != nil && Data(base64Encoded: device.identityKey) != nil
        }
        return result
    }

    private enum ReadResult {
        case found(Data)
        case missing
        case failed(OSStatus)
    }

    private static func read(_ name: KeychainItemName) -> ReadResult {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = item as? Data else { return .failed(errSecDecode) }
        return .found(data)
    }

    private static func write(_ value: MacKeychainContents, to name: KeychainItemName) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let base = query(name)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = base
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(_ name: KeychainItemName) {
        SecItemDelete(query(name) as CFDictionary)
    }

    private static func query(_ name: KeychainItemName) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: name.service,
            kSecAttrAccount as String: name.account,
        ]
    }
}

final class MacTrustRegistry {
    private let state: MacKeychainState

    init(state: MacKeychainState = .shared, migrating defaultsStores: [UserDefaults] = [.standard]) {
        self.state = state
        defaultsStores.forEach(migrateDefaults)
    }

    /// Test convenience: a private store under its own service name.
    convenience init(service: String, migrating defaultsStores: [UserDefaults] = [.standard]) {
        self.init(
            state: MacKeychainState(
                item: KeychainItemName(service: service, account: MacKeychainState.current.account),
                legacyTrust: KeychainItemName(service: service, account: MacKeychainState.legacyTrust.account),
                legacyIdentity: nil
            ),
            migrating: defaultsStores
        )
    }

    var deviceIDs: Set<String> { Set(state.contents.devices.keys) }

    var devices: [MacTrustedDevice] { Array(state.contents.devices.values) }

    func identityKey(for deviceID: String) -> String? {
        state.contents.devices[deviceID]?.identityKey
    }

    @discardableResult
    func remember(deviceID: String, name: String, identityKey: String) -> Bool {
        guard UUID(uuidString: deviceID) != nil,
              !name.isEmpty,
              Data(base64Encoded: identityKey) != nil else { return false }
        let device = MacTrustedDevice(id: deviceID, name: name, identityKey: identityKey)
        return state.update { $0.devices[deviceID] = device }
    }

    func remove(deviceID: String) {
        state.update { $0.devices.removeValue(forKey: deviceID) }
    }

    private func migrateDefaults(_ defaults: UserDefaults) {
        let ids = defaults.stringArray(forKey: "trustedDeviceIDs") ?? []
        var imported: [String: MacTrustedDevice] = [:]
        var importedKeys: [String] = []
        for id in ids where UUID(uuidString: id) != nil {
            let identityKeyName = "trusted.\(id).identityKey"
            let nameKey = "trusted.\(id).name"
            guard let identityKey = defaults.string(forKey: identityKeyName),
                  Data(base64Encoded: identityKey) != nil else { continue }
            let name = defaults.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            imported[id] = MacTrustedDevice(
                id: id,
                name: name?.isEmpty == false ? name! : "Unknown device",
                identityKey: identityKey
            )
            importedKeys.append(contentsOf: [identityKeyName, nameKey])
        }
        guard !imported.isEmpty,
              state.update({ $0.devices.merge(imported) { _, new in new } }) else { return }
        importedKeys.forEach(defaults.removeObject(forKey:))
        defaults.removeObject(forKey: "trustedDeviceIDs")
    }

    func deleteStorageForTesting() {
        state.deleteStorageForTesting()
    }
}
