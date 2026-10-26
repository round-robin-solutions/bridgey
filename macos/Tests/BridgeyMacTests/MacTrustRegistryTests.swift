import Foundation
import Security
import XCTest
@testable import BridgeyMac

final class MacTrustRegistryTests: XCTestCase {
    func testMigratesTrustRecordsFromUserDefaultsToKeychain() throws {
        let namespace = UUID().uuidString
        let suiteName = "dev.bridgey.tests.\(namespace)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deviceID = UUID().uuidString.lowercased()
        let identityKey = Data("test-public-key".utf8).base64EncodedString()
        defaults.set([deviceID], forKey: "trustedDeviceIDs")
        defaults.set("Test phone", forKey: "trusted.\(deviceID).name")
        defaults.set(identityKey, forKey: "trusted.\(deviceID).identityKey")

        let service = "dev.bridgey.tests.trust.\(namespace)"
        let registry = MacTrustRegistry(service: service, migrating: [defaults])
        defer { registry.deleteStorageForTesting() }

        XCTAssertEqual(registry.deviceIDs, [deviceID])
        XCTAssertEqual(registry.identityKey(for: deviceID), identityKey)
        XCTAssertEqual(registry.devices.first?.name, "Test phone")
        XCTAssertNil(defaults.array(forKey: "trustedDeviceIDs"))
        XCTAssertNil(defaults.string(forKey: "trusted.\(deviceID).identityKey"))

        let reloaded = MacTrustRegistry(service: service, migrating: [])
        XCTAssertEqual(reloaded.deviceIDs, [deviceID])
        XCTAssertEqual(reloaded.identityKey(for: deviceID), identityKey)
    }

    func testMovesLegacyTrustAndIdentityIntoOneItem() throws {
        let namespace = UUID().uuidString
        let trust = KeychainItemName(service: "dev.bridgey.tests.trust.\(namespace)", account: "trusted-devices-v1")
        let identity = KeychainItemName(service: "dev.bridgey.tests.identity.\(namespace)", account: "p256-signing-v1")
        let current = KeychainItemName(service: trust.service, account: "state-v2")
        let deviceID = UUID().uuidString.lowercased()
        let device = MacTrustedDevice(id: deviceID, name: "Phone", identityKey: Data("key".utf8).base64EncodedString())
        let keyData = Data(repeating: 1, count: 32)
        func add(_ name: KeychainItemName, _ data: Data) {
            SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: name.service,
                kSecAttrAccount as String: name.account,
                kSecValueData as String: data,
            ] as CFDictionary, nil)
        }
        add(trust, try JSONEncoder().encode([deviceID: device]))
        add(identity, keyData)

        let state = MacKeychainState(item: current, legacyTrust: trust, legacyIdentity: identity)
        defer { state.deleteStorageForTesting() }
        XCTAssertEqual(state.loadResult, .loaded)
        XCTAssertEqual(state.contents.devices[deviceID], device)
        XCTAssertEqual(state.contents.identityKey, keyData)

        // The legacy items are gone and the next launch reads only the v2 item.
        let reloaded = MacKeychainState(item: current, legacyTrust: trust, legacyIdentity: identity)
        XCTAssertEqual(reloaded.contents, state.contents)
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identity.service,
            kSecAttrAccount as String: identity.account,
        ] as CFDictionary, &item), errSecItemNotFound)
    }
}
