import Foundation
import os

struct MacTrustedDevice: Codable, Equatable {
    let id: String
    let name: String
    let identityKey: String
}

/// The phones this Mac trusts, kept in the private pairing file (`MacPairingStore`).
final class MacTrustRegistry {
    private let store: MacPairingStore
    /// Phones forgotten in this run. They stay untrusted even if the pairing file could not be written.
    private var revoked = Set<String>()
    static let defaultsMigratedKey = "trust.defaultsMigrated"

    init(store: MacPairingStore = .shared, migrating defaultsStores: [UserDefaults] = [.standard]) {
        self.store = store
        defaultsStores.forEach(migrateDefaults)
    }

    var deviceIDs: Set<String> { Set(store.contents.map { Array($0.devices.keys) } ?? []).subtracting(revoked) }

    var devices: [MacTrustedDevice] { (store.contents.map { Array($0.devices.values) } ?? []).filter { !revoked.contains($0.id) } }

    func identityKey(for deviceID: String) -> String? {
        guard !revoked.contains(deviceID) else { return nil }
        return store.contents?.devices[deviceID]?.identityKey
    }

    @discardableResult
    func remember(deviceID: String, name: String, identityKey: String) -> Bool {
        guard UUID(uuidString: deviceID) != nil,
              !name.isEmpty,
              Data(base64Encoded: identityKey) != nil else { return false }
        let device = MacTrustedDevice(id: deviceID, name: name, identityKey: identityKey)
        guard store.updateDevices({ $0[deviceID] = device }) else { return false }
        revoked.remove(deviceID)
        return true
    }

    func remove(deviceID: String) {
        revoked.insert(deviceID)
        if !store.updateDevices({ $0.removeValue(forKey: deviceID) }) {
            Logger(subsystem: BridgeyLog.subsystem, category: "pairing").error("forgetting a phone could not be saved; it stays untrusted until Bridgey quits")
        }
    }

    /// Pre-Keychain versions kept trust in UserDefaults. Read once; a key already pinned in the
    /// pairing file is never replaced from there.
    private func migrateDefaults(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.defaultsMigratedKey) else { return }
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
        guard imported.isEmpty || store.updateDevices({ $0.merge(imported) { existing, _ in existing } }) else { return }
        importedKeys.forEach(defaults.removeObject(forKey:))
        defaults.removeObject(forKey: "trustedDeviceIDs")
        defaults.set(true, forKey: Self.defaultsMigratedKey)
    }
}
