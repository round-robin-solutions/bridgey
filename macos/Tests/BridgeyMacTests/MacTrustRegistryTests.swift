import Foundation
import XCTest
@testable import BridgeyMac

final class MacTrustRegistryTests: XCTestCase {
    func testMigratesTrustRecordsFromUserDefaultsIntoThePairingFile() throws {
        let namespace = UUID().uuidString
        let suiteName = "dev.bridgey.tests.\(namespace)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-trust-\(namespace)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let deviceID = UUID().uuidString.lowercased()
        let identityKey = Data("test-public-key".utf8).base64EncodedString()
        defaults.set([deviceID], forKey: "trustedDeviceIDs")
        defaults.set("Test phone", forKey: "trusted.\(deviceID).name")
        defaults.set(identityKey, forKey: "trusted.\(deviceID).identityKey")

        let registry = MacTrustRegistry(store: MacPairingStore(directory: directory, keychain: FakeKeychain()), migrating: [defaults])

        XCTAssertEqual(registry.deviceIDs, [deviceID])
        XCTAssertEqual(registry.identityKey(for: deviceID), identityKey)
        XCTAssertEqual(registry.devices.first?.name, "Test phone")
        XCTAssertNil(defaults.array(forKey: "trustedDeviceIDs"))
        XCTAssertNil(defaults.string(forKey: "trusted.\(deviceID).identityKey"))

        let reloaded = MacTrustRegistry(store: MacPairingStore(directory: directory, keychain: FakeKeychain()), migrating: [])
        XCTAssertEqual(reloaded.deviceIDs, [deviceID])
        XCTAssertEqual(reloaded.identityKey(for: deviceID), identityKey)
    }

    func testDefaultsAreReadOnceAndNeverReplaceAPinnedKey() throws {
        let namespace = UUID().uuidString
        let suiteName = "dev.bridgey.tests.\(namespace)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-trust-\(namespace)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacPairingStore(directory: directory, keychain: FakeKeychain())
        let deviceID = UUID().uuidString.lowercased()
        let pinned = Data("pinned-key".utf8).base64EncodedString()
        XCTAssertTrue(MacTrustRegistry(store: store, migrating: []).remember(deviceID: deviceID, name: "Phone", identityKey: pinned))

        let planted = Data("planted-key".utf8).base64EncodedString()
        defaults.set([deviceID], forKey: "trustedDeviceIDs")
        defaults.set(planted, forKey: "trusted.\(deviceID).identityKey")
        let registry = MacTrustRegistry(store: store, migrating: [defaults])
        XCTAssertEqual(registry.identityKey(for: deviceID), pinned, "an existing pin wins")
        XCTAssertTrue(defaults.bool(forKey: MacTrustRegistry.defaultsMigratedKey))

        let other = UUID().uuidString.lowercased()
        defaults.set([other], forKey: "trustedDeviceIDs")
        defaults.set(planted, forKey: "trusted.\(other).identityKey")
        XCTAssertNil(MacTrustRegistry(store: store, migrating: [defaults]).identityKey(for: other), "read once only")
    }

    func testAForgottenPhoneStaysUntrustedWhenTheFileCannotBeWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-trust-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let registry = MacTrustRegistry(store: MacPairingStore(directory: directory, keychain: FakeKeychain()), migrating: [])
        let deviceID = UUID().uuidString.lowercased()
        XCTAssertTrue(registry.remember(deviceID: deviceID, name: "Phone", identityKey: Data("key".utf8).base64EncodedString()))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        registry.remove(deviceID: deviceID)
        XCTAssertNil(registry.identityKey(for: deviceID))
        XCTAssertFalse(registry.deviceIDs.contains(deviceID))
        XCTAssertTrue(registry.devices.isEmpty)
    }
}
