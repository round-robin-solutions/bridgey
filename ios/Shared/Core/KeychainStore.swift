import Foundation
import Security

/// bridgey_core's identity and trusted devices in the Keychain, shared by the app and its Share extension through
/// a Keychain access group. Items stay on this device (no backup to another phone: a copied identity would be two
/// devices with one ID) and are readable after the first unlock, so a share works from the lock screen's apps.
final class KeychainStore: SecretStore, @unchecked Sendable {
    let service: String
    private let lock = NSLock()
    /// nil when the build has no Keychain group entitlement (unsigned simulator builds): then app only.
    private var accessGroup: String?

    init(service: String = "in.roundrobin.bridgey.core", accessGroup: String? = Edition.keychainGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    private func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let group = lock.withLock({ accessGroup }) { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    /// Runs `body`; a build without the group entitlement drops the group once and tries again.
    private func withGroupFallback<T>(_ body: () -> (OSStatus, T)) -> (OSStatus, T) {
        let first = body()
        guard first.0 == errSecMissingEntitlement, lock.withLock({ accessGroup }) != nil else { return first }
        lock.withLock { accessGroup = nil }
        return body()
    }

    func load(_ key: String) throws -> Data? {
        let (status, data) = withGroupFallback { () -> (OSStatus, Data?) in
            var q = query(key)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            return (status, result as? Data)
        }
        switch status {
        case errSecSuccess: return data ?? Data()
        case errSecItemNotFound: return nil
        default: throw Failure(status: status)
        }
    }

    func store(_ key: String, _ value: Data) throws {
        let (status, _) = withGroupFallback { () -> (OSStatus, Void) in
            let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
            guard update == errSecItemNotFound else { return (update, ()) }
            var add = query(key)
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return (SecItemAdd(add as CFDictionary, nil), ())
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func remove(_ key: String) throws {
        let (status, _) = withGroupFallback { (SecItemDelete(query(key) as CFDictionary), ()) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// Settings > Reset: this device's identity and every pairing.
    func removeAll() {
        for key in ["identity", "trust"] { try? remove(key) }
    }
}
