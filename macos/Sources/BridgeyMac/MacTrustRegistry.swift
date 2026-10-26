import Foundation

struct MacTrustedDevice: Codable, Equatable {
    let id: String
    let name: String
    let identityKey: String
}

/// The phones this Mac trusts, kept in the private pairing file (`MacPairingStore`).
final class MacTrustRegistry {
    private let store: MacPairingStore

    init(store: MacPairingStore = .shared, migrating defaultsStores: [UserDefaults] = [.standard]) {
        self.store = store
        defaultsStores.forEach(migrateDefaults)
    }

    var deviceIDs: Set<String> { Set(store.contents.map { Array($0.devices.keys) } ?? []) }

    var devices: [MacTrustedDevice] { store.contents.map { Array($0.devices.values) } ?? [] }

    func identityKey(for deviceID: String) -> String? {
        store.contents?.devices[deviceID]?.identityKey
    }

    @discardableResult
    func remember(deviceID: String, name: String, identityKey: String) -> Bool {
        guard UUID(uuidString: deviceID) != nil,
              !name.isEmpty,
              Data(base64Encoded: identityKey) != nil else { return false }
        let device = MacTrustedDevice(id: deviceID, name: name, identityKey: identityKey)
        return store.updateDevices { $0[deviceID] = device }
    }

    func remove(deviceID: String) {
        store.updateDevices { $0.removeValue(forKey: deviceID) }
    }

    /// Pre-Keychain versions kept trust in UserDefaults.
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
              store.updateDevices({ $0.merge(imported) { _, new in new } }) else { return }
        importedKeys.forEach(defaults.removeObject(forKey:))
        defaults.removeObject(forKey: "trustedDeviceIDs")
    }
}
