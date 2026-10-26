import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BridgeyMac

/// Stand-in for the old Keychain items. Never touches a real keychain.
final class FakeKeychain: LegacyKeychainSource {
    var items: [KeychainItemName: Data] = [:]
    var failures: [KeychainItemName: OSStatus] = [:]
    private(set) var reads: [KeychainItemName] = []
    private(set) var retired: [KeychainItemName] = []

    func read(_ name: KeychainItemName) -> KeychainReadResult {
        reads.append(name)
        if let status = failures[name] { return .failed(status) }
        return items[name].map(KeychainReadResult.found) ?? .missing
    }

    func retire(_ name: KeychainItemName) -> Bool {
        retired.append(name)
        items.removeValue(forKey: name)
        return true
    }
}

final class MacPairingStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("in.roundrobin.bridgey", isDirectory: true) }
    private var file: URL { directory.appendingPathComponent(MacPairingStore.fileName) }
    private let names = LegacyKeychainItems.edition
    private let deviceID = UUID().uuidString.lowercased()
    private lazy var device = MacTrustedDevice(id: deviceID, name: "Phone", identityKey: Data("phone-key".utf8).base64EncodedString())

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ keychain: FakeKeychain = FakeKeychain(), makeKey: (() -> Data)? = nil) -> MacPairingStore {
        MacPairingStore(directory: directory, keychain: keychain,
                        makeIdentityKey: makeKey ?? { P256.Signing.PrivateKey().rawRepresentation })
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    private func temporaryFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains(".tmp-") }
    }

    // MARK: Round trip and file properties

    func testNewInstallCreatesAPrivateFileAndRoundTrips() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.issue)
        XCTAssertEqual(mode(directory), 0o700)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertTrue(keychain.retired.isEmpty, "nothing to retire on a new install")

        let registry = MacTrustRegistry(store: store, migrating: [])
        XCTAssertTrue(registry.remember(deviceID: deviceID, name: "Phone", identityKey: device.identityKey))

        let reloadedKeychain = FakeKeychain()
        let reloaded = makeStore(reloadedKeychain)
        XCTAssertEqual(reloaded.contents, store.contents)
        XCTAssertEqual(MacTrustRegistry(store: reloaded, migrating: []).identityKey(for: deviceID), device.identityKey)
        XCTAssertTrue(reloadedKeychain.reads.isEmpty, "once the file exists the Keychain is never read")

        // Raw 32-byte P-256 key, base64 in the file.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 3)
        let key = try XCTUnwrap(Data(base64Encoded: json?["identityKey"] as? String ?? ""))
        XCTAssertEqual(key.count, 32)
        XCTAssertNoThrow(try P256.Signing.PrivateKey(rawRepresentation: key))
    }

    func testUnchangedTrustIsNotRewritten() throws {
        let store = makeStore()
        let registry = MacTrustRegistry(store: store, migrating: [])
        registry.remember(deviceID: deviceID, name: "Phone", identityKey: device.identityKey)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        registry.remember(deviceID: deviceID, name: "Phone", identityKey: device.identityKey)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "an atomic rewrite would replace the inode")
    }

    // MARK: Permissions

    func testLoosePermissionsAreRepairedOnLoad() throws {
        let original = makeStore().contents
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertEqual(chmod(directory.path, 0o755), 0)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.contents, original)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(mode(directory), 0o700)
    }

    func testSymlinkedFileIsRefusedAndLeftAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try Data("not ours".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)

        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        XCTAssertFalse(store.isReady)
        guard case .fileUnreadable = store.issue else { return XCTFail("expected fileUnreadable, got \(String(describing: store.issue))") }
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data("not ours".utf8))
        XCTAssertTrue(keychain.reads.isEmpty)
    }

    func testDamagedFileIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{\"version\":3,\"identityKey\":\"bm90IGEga2V5\",\"devices\":[]}".utf8)
        try garbage.write(to: file)
        var generated = false
        let store = makeStore(makeKey: { generated = true; return Data(repeating: 1, count: 32) })
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.issue, .fileUnreadable(String(describing: PairingFileError.invalidIdentityKey)))
        XCTAssertFalse(generated)
        XCTAssertEqual(try Data(contentsOf: file), garbage)
    }

    // MARK: Atomic writes

    func testCrashBeforeRenameKeepsTheOldFile() throws {
        let store = makeStore()
        let registry = MacTrustRegistry(store: store, migrating: [])
        let before = try Data(contentsOf: file)

        struct SimulatedCrash: Error {}
        var tempSeen: URL?
        store.beforeRename = { temp in
            tempSeen = temp
            // The new bytes are complete and synced in the temp file at this point.
            XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
            throw SimulatedCrash()
        }
        XCTAssertFalse(registry.remember(deviceID: deviceID, name: "Phone", identityKey: device.identityKey))
        XCTAssertNotNil(tempSeen)
        XCTAssertEqual(try Data(contentsOf: file), before, "the old file is untouched")
        XCTAssertTrue(temporaryFiles().isEmpty)
        XCTAssertTrue(registry.deviceIDs.isEmpty, "the failed change is not kept in memory")
    }

    func testTempFileLeftByAKilledProcessIsIgnoredAndRemoved() throws {
        let original = makeStore().contents
        let stale = directory.appendingPathComponent(".\(MacPairingStore.fileName).tmp-\(UUID().uuidString)")
        try Data("{\"version\":3,\"identityK".utf8).write(to: stale)  // half-written

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.contents, original)
        XCTAssertTrue(temporaryFiles().isEmpty)
    }

    // MARK: Migration from the Keychain

    func testMovesTheTwoOldKeychainItemsThenRetiresThem() throws {
        let keychain = FakeKeychain()
        let key = P256.Signing.PrivateKey().rawRepresentation
        keychain.items[names.trust] = try JSONEncoder().encode([deviceID: device])
        keychain.items[names.identity] = key
        var generated = false

        let store = makeStore(keychain, makeKey: { generated = true; return Data() })
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(generated)
        XCTAssertEqual(store.contents?.identityKey, key)
        XCTAssertEqual(store.contents?.devices[deviceID], device)
        XCTAssertEqual(Set(keychain.retired), [names.trust, names.identity])

        let reloadedKeychain = FakeKeychain()
        XCTAssertEqual(makeStore(reloadedKeychain).contents, store.contents)
        XCTAssertTrue(reloadedKeychain.reads.isEmpty)
    }

    func testMovesTheStateV2Item() throws {
        struct V2: Encodable { let identityKey: Data; let devices: [String: MacTrustedDevice] }
        let keychain = FakeKeychain()
        let key = P256.Signing.PrivateKey().rawRepresentation
        keychain.items[names.v2] = try JSONEncoder().encode(V2(identityKey: key, devices: [deviceID: device]))

        let store = makeStore(keychain)
        XCTAssertEqual(store.contents?.identityKey, key)
        XCTAssertEqual(store.contents?.devices[deviceID], device)
        XCTAssertEqual(keychain.retired, [names.v2])
    }

    func testDeniedKeychainReadChangesNothingAndRetries() throws {
        let keychain = FakeKeychain()
        let key = P256.Signing.PrivateKey().rawRepresentation
        keychain.items[names.trust] = try JSONEncoder().encode([deviceID: device])
        keychain.items[names.identity] = key
        keychain.failures[names.identity] = errSecUserCanceled
        var generated = false

        let store = makeStore(keychain, makeKey: { generated = true; return P256.Signing.PrivateKey().rawRepresentation })
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.issue, .keychainAccessDenied(errSecUserCanceled))
        XCTAssertFalse(generated, "a failed read never creates a new identity")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(keychain.retired.isEmpty)
        XCTAssertNotNil(keychain.items[names.trust])
        XCTAssertFalse(MacTrustRegistry(store: store, migrating: []).remember(
            deviceID: deviceID, name: "Phone", identityKey: device.identityKey))

        // Next launch (or Try again), the user allows access.
        keychain.failures.removeAll()
        store.load()
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.issue)
        XCTAssertEqual(store.contents?.identityKey, key)
        XCTAssertFalse(generated)
        XCTAssertEqual(Set(keychain.retired), [names.trust, names.identity])
    }

    func testTrustWithoutAStoredIdentityGetsANewIdentity() throws {
        let keychain = FakeKeychain()
        keychain.items[names.trust] = try JSONEncoder().encode([deviceID: device])
        let fresh = P256.Signing.PrivateKey().rawRepresentation
        let store = makeStore(keychain, makeKey: { fresh })
        XCTAssertEqual(store.contents?.identityKey, fresh)
        XCTAssertEqual(store.contents?.devices[deviceID], device)
    }
}
