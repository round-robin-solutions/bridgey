import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BridgeyMac

/// Old Keychain items served from fixtures. Never touches a real keychain.
private final class FixtureKeychain: LegacyKeychainSource {
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
        items[name] = SystemKeychainSource.retiredMarker
        return true
    }
}

/// Mac pairing state from every edition release: the Keychain items of Beta 1 to Beta 7, the
/// single `state-v2` item of the rr/mac-signing-updates branch builds, and `trust-v3.json` from
/// Beta 8 on. The Keychain-to-file move runs through the `LegacyKeychainSource` seam.
final class MigrationTrustTests: XCTestCase {
    private typealias F = MigrationFixtures
    private let names = LegacyKeychainItems.edition
    private var root: URL!
    private var directory: URL { root.appendingPathComponent("in.roundrobin.bridgey", isDirectory: true) }
    private var file: URL { directory.appendingPathComponent(MacPairingStore.fileName) }

    override func setUpWithError() throws {
        root = try F.temporaryDirectory("trust")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(_ keychain: FixtureKeychain, newKey: Data? = nil) -> MacPairingStore {
        MacPairingStore(directory: directory, keychain: keychain, makeIdentityKey: {
            newKey ?? P256.Signing.PrivateKey().rawRepresentation
        })
    }

    private func beta1Keychain() throws -> FixtureKeychain {
        let keychain = FixtureKeychain()
        keychain.items[names.trust] = try F.data("trust/keychain-beta.1/in.roundrobin.bridgey.trust--trusted-devices-v1.json")
        let identity = try String(contentsOf: F.url("trust/keychain-beta.1/in.roundrobin.bridgey.identity--p256-signing-v1.base64"), encoding: .utf8)
        keychain.items[names.identity] = try XCTUnwrap(Data(base64Encoded: identity.trimmingCharacters(in: .whitespacesAndNewlines)))
        return keychain
    }

    private func installFile(_ fixture: String) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try F.data(fixture)
        try data.write(to: file)
        chmod(file.path, 0o600)
        return data
    }

    private func publicKey(of store: MacPairingStore) throws -> String {
        let key = try XCTUnwrap(store.contents?.identityKey)
        return try P256.Signing.PrivateKey(rawRepresentation: key).publicKey.x963Representation.base64EncodedString()
    }

    // MARK: Beta 1 to Beta 7: two Keychain items

    func testBeta1KeychainItemsMoveIntoTheFileWithTheSameIdentityAndPhones() throws {
        let keychain = try beta1Keychain()
        let store = store(keychain)
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.issue)
        XCTAssertEqual(try publicKey(of: store), F.macPublicKey, "phones must still recognise this Mac")
        let registry = MacTrustRegistry(store: store, migrating: [])
        XCTAssertEqual(registry.deviceIDs, [F.phoneA, F.phoneB], "the entry keyed under another id is dropped")
        XCTAssertEqual(registry.identityKey(for: F.phoneA), F.keyA)
        XCTAssertEqual(registry.identityKey(for: F.phoneB), F.keyB)
        XCTAssertEqual(Set(registry.devices.map(\.name)), ["Test Phone A", "Test Phone B"])

        // Written once, private, and both old items retired.
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(Set(keychain.retired), [names.trust, names.identity])

        // The next launch reads only the file.
        let next = FixtureKeychain()
        let reloaded = self.store(next)
        XCTAssertEqual(reloaded.contents, store.contents)
        XCTAssertTrue(next.reads.isEmpty)
    }

    func testABeta1MacWithNoPairedPhoneKeepsItsIdentity() throws {
        let keychain = try beta1Keychain()
        keychain.items[names.trust] = nil
        let store = store(keychain)
        XCTAssertEqual(try publicKey(of: store), F.macPublicKey)
        XCTAssertEqual(store.contents?.devices, [:])
    }

    func testADeniedKeychainReadChangesNothingAndNeverMakesANewIdentity() throws {
        let keychain = try beta1Keychain()
        keychain.failures[names.trust] = errSecAuthFailed
        let store = store(keychain, newKey: P256.Signing.PrivateKey().rawRepresentation)
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.issue, .keychainAccessDenied(errSecAuthFailed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(keychain.retired.isEmpty)

        // Retry after the user allows it: the original identity, not a stand-in.
        keychain.failures = [:]
        store.load()
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(try publicKey(of: store), F.macPublicKey)
    }

    func testRetiredMarkersAreNotReadAsAKeyWhenTheFileIsMissing() throws {
        // The file was deleted by hand after a move: the markers hold no key and no phones, so this
        // is a fresh start, never a crash.
        let keychain = FixtureKeychain()
        keychain.items[names.trust] = SystemKeychainSource.retiredMarker
        keychain.items[names.identity] = SystemKeychainSource.retiredMarker
        let fresh = P256.Signing.PrivateKey().rawRepresentation
        let store = store(keychain, newKey: fresh)
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.contents?.identityKey, fresh)
        XCTAssertEqual(store.contents?.devices, [:])
    }

    // MARK: Branch builds: one state-v2 item

    func testStateV2ItemMoves() throws {
        let keychain = FixtureKeychain()
        keychain.items[names.v2] = try F.data("trust/keychain-branch/in.roundrobin.bridgey.trust--state-v2.json")
        let store = store(keychain)
        XCTAssertEqual(store.contents?.identityKey, Data(base64Encoded: F.branchIdentityKey))
        XCTAssertEqual(MacTrustRegistry(store: store, migrating: []).identityKey(for: F.phoneC), F.keyC)
        XCTAssertEqual(keychain.retired, [names.v2])
    }

    // MARK: Beta 8 on: trust-v3.json

    func testTrustV3FromBeta8Loads() throws {
        _ = try installFile("trust/trust-v3.beta.8.json")
        let keychain = FixtureKeychain()
        let store = store(keychain)
        XCTAssertTrue(keychain.reads.isEmpty, "once the file exists the Keychain is never read")
        XCTAssertEqual(try publicKey(of: store), F.macPublicKey)
        let registry = MacTrustRegistry(store: store, migrating: [])
        XCTAssertEqual(registry.deviceIDs, [F.phoneA, F.phoneB])
        XCTAssertEqual(registry.identityKey(for: F.phoneB), F.keyB)

        // Saving in this build keeps everything that was there.
        XCTAssertTrue(registry.remember(deviceID: F.phoneC, name: "Test Phone C", identityKey: F.keyC))
        let reloaded = MacTrustRegistry(store: self.store(FixtureKeychain()), migrating: [])
        XCTAssertEqual(reloaded.deviceIDs, [F.phoneA, F.phoneB, F.phoneC])
    }

    func testInvalidDeviceEntriesAndUnknownFieldsAreDroppedOneByOne() throws {
        _ = try installFile("trust/trust-v3.unknown-entries.json")
        let store = store(FixtureKeychain())
        XCTAssertNil(store.issue)
        XCTAssertEqual(Set(store.contents.map { Array($0.devices.keys) } ?? []), [F.phoneA, F.phoneB])
        XCTAssertEqual(store.contents?.devices[F.phoneB]?.identityKey, F.keyB)
    }

    func testAFileThisBuildCannotReadIsLeftUntouchedAndPairingWaits() throws {
        for fixture in ["trust/trust-v3.version-4.json", "trust/trust-v3.missing-field.json", "trust/trust-v3.bad-identity.json"] {
            let original = try installFile(fixture)
            let keychain = try beta1Keychain()
            let store = store(keychain)
            XCTAssertFalse(store.isReady, fixture)
            guard case .fileUnreadable = store.issue else { return XCTFail("\(fixture): \(String(describing: store.issue))") }
            XCTAssertTrue(keychain.reads.isEmpty, "\(fixture): a damaged file never falls back to the Keychain")
            XCTAssertEqual(try Data(contentsOf: file), original, "\(fixture): never overwritten")
            XCTAssertFalse(MacTrustRegistry(store: store, migrating: []).remember(deviceID: F.phoneC, name: "Test Phone C", identityKey: F.keyC))
            XCTAssertEqual(try Data(contentsOf: file), original, fixture)
        }
    }

    // MARK: Names older releases wrote under

    func testStorageNamesArePinned() {
        XCTAssertEqual(MacPairingStore.fileName, "trust-v3.json")
        XCTAssertEqual(names.trust, KeychainItemName(service: "in.roundrobin.bridgey.trust", account: "trusted-devices-v1"))
        XCTAssertEqual(names.identity, KeychainItemName(service: "in.roundrobin.bridgey.identity", account: "p256-signing-v1"))
        XCTAssertEqual(names.v2, KeychainItemName(service: "in.roundrobin.bridgey.trust", account: "state-v2"))
        XCTAssertEqual(MacPairingStore.defaultDirectory.lastPathComponent, "in.roundrobin.bridgey")
        XCTAssertEqual(ActivityStore.fileName, "activity-stream.json")
        XCTAssertEqual(RemoteControlAuditStore.fileName, "remote-control-audit.json")
        XCTAssertEqual(FolderJournalStore.defaultDirectory().lastPathComponent, "FolderTransfers")
        XCTAssertEqual(ClipboardCache.defaultRoot().lastPathComponent, "ClipboardCache")
        XCTAssertEqual(CodeModelFiles.standard().directory.lastPathComponent, "Models")
        XCTAssertEqual(UpdateChannel.defaultsKey, "updates.channel")
    }
}
