import Foundation
import XCTest
@testable import BridgeyMac

private final class FixtureAddressBookStore: AddressBookStore {
    var data: Data?
    init(_ data: Data?) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

/// Smaller stores from older releases: the reconnect address book (Beta 8), sender folder journals
/// (Beta 10), the code model records (Beta 13), the clipboard cache layout (Beta 5) and the screen grants (1.0 Beta 5).
final class MigrationStoresTests: XCTestCase {
    private typealias F = MigrationFixtures
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try F.temporaryDirectory("stores")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Reconnect address book (UserDefaults data under reconnect.addressBook.v1)

    func testAddressBookFromBeta8Loads() throws {
        let store = FixtureAddressBookStore(try F.data("reconnect/reconnect.addressBook.v1.json"))
        let book = KnownAddressBook(store: store)
        XCTAssertEqual(book.addresses(for: F.phoneA).map(\.host), ["192.168.1.30", "test-phone-a.local", "fd00::30"])
        XCTAssertEqual(book.addresses(for: F.phoneA).map(\.source), [.outbound, .discovery, .inbound])
        XCTAssertEqual(book.lastConnected(F.phoneA), F.base)
        XCTAssertEqual(book.addresses(for: F.phoneB).map(\.host), ["10.0.0.8"])
        XCTAssertNil(book.lastConnected(F.phoneB))

        // A write in this build keeps the other records.
        book.markSeen(F.phoneB, at: F.base)
        let reloaded = KnownAddressBook(store: FixtureAddressBookStore(store.data))
        XCTAssertEqual(reloaded.addresses(for: F.phoneA).count, 3)
        XCTAssertEqual(reloaded.lastConnected(F.phoneB), F.base)
    }

    func testTheAddressBookKeyIsPinned() throws {
        let suiteName = "in.roundrobin.bridgey.migration-tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let data = try F.data("reconnect/reconnect.addressBook.v1.json")
        suite.set(data, forKey: "reconnect.addressBook.v1")
        XCTAssertEqual(UserDefaultsAddressBookStore(defaults: suite).load(), data)
    }

    func testAnAddressSourceThisBuildDoesNotKnowCostsOnlyTheCache() throws {
        // The book is a cache rebuilt from Bonjour and connections. Today one unknown source drops the
        // whole book (strict Codable); it must never crash, and the next write starts a clean book.
        let store = FixtureAddressBookStore(try F.data("reconnect/reconnect.addressBook.unknown-source.json"))
        let book = KnownAddressBook(store: store)
        XCTAssertTrue(book.records.isEmpty)
        XCTAssertTrue(book.learn(F.phoneB, host: "10.0.0.8", port: 42_458, source: .inbound, at: F.base))
        XCTAssertEqual(KnownAddressBook(store: FixtureAddressBookStore(store.data)).addresses(for: F.phoneB).map(\.host), ["10.0.0.8"])
    }

    // MARK: Folder transfer journals (FolderTransfers/<id>.json)

    private let journalID = "69c301e2-8dd2-48b9-a0d1-3cb747960e0b"
    private let newerVersionID = "489e2368-cdce-479e-975a-c77d1e543687"
    private let renamedID = "4f6ba53d-d0e1-44af-a041-8ca59d2399af"

    private func installJournals() throws -> URL {
        let folder = directory.appendingPathComponent("FolderTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in [journalID, newerVersionID, renamedID] {
            try FileManager.default.copyItem(at: F.url("folder-transfers/\(id).json"), to: folder.appendingPathComponent("\(id).json"))
        }
        return folder
    }

    func testABeta10JournalResumesAndOthersAreCleanedUp() throws {
        let folder = try installJournals()
        let journals = FolderJournalStore(directory: folder).load(now: F.base.addingTimeInterval(3_600))
        XCTAssertEqual(journals.count, 1)
        let journal = try XCTUnwrap(journals.first)
        XCTAssertEqual(journal.folderTransferId, journalID)
        XCTAssertEqual(journal.deviceID, F.phoneA)
        XCTAssertEqual(journal.rootPath, "/Users/test/Pictures/Trip 2026")
        XCTAssertNil(journal.bookmark)
        XCTAssertEqual(journal.options, FolderScanOptions(includeHidden: false, includeSystem: true))
        XCTAssertEqual(journal.destination, FolderDestination(placeId: "default", path: "Trip 2026"))
        XCTAssertEqual(journal.destinationLabel, "Download/Bridgey")
        XCTAssertEqual(journal.fileCount, 12)
        XCTAssertEqual(journal.totalSize, 52_428_800)
        XCTAssertEqual(journal.createdAt, F.base)
        XCTAssertEqual(journal.lastProgressAt, F.base.addingTimeInterval(600))
        XCTAssertEqual(journal.completed, [0, 1, 2, 5])
        XCTAssertEqual(journal.resolveRoot().path, "/Users/test/Pictures/Trip 2026")
        // A journal of a version this build does not know, and one under another name, are removed.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, ["\(journalID).json"])
    }

    func testAJournalPastTheResumeWindowIsRemoved() throws {
        let folder = try installJournals()
        XCTAssertEqual(FolderJournalStore(directory: folder).load(now: F.base.addingTimeInterval(25 * 3_600)), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: Code model records (Models/installed.json and download.json)

    private let prefix = "https://github.com/round-robin-solutions/bridgey/releases/download/"

    @MainActor
    private func codeModelStore(_ models: URL, pinned: [CodeModelManifest] = CodeModelManifest.pinned) -> CodeModelStore {
        CodeModelStore(files: CodeModelFiles(directory: models), transport: FakeModelTransport(data: Data()), bundledManifest: nil,
                       manifestURL: nil, assetURLPrefix: prefix, spaceQuery: { _ in 10_000_000_000 },
                       makeRunner: { FakeRunner(output: "") }, pinned: pinned)
    }

    /// The fixtures' own models as pins: the installed v1 record and the paused v2 download (made-up hashes).
    private func fixturePins() throws -> [CodeModelManifest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let installed = try decoder.decode(InstalledCodeModel.self, from: Data(contentsOf: F.url("models/installed.json")))
        let download = try decoder.decode(CodeModelDownloadRecord.self, from: Data(contentsOf: F.url("models/download.json")))
        let one = CodeModelManifest(schema: 1, version: installed.version, name: installed.name, url: prefix + "models/" + installed.fileName,
                                    size: installed.size, sha256: installed.sha256, termsVersion: download.manifest.termsVersion,
                                    licenceURL: download.manifest.licenceURL, prohibitedUseURL: download.manifest.prohibitedUseURL)
        return [one, download.manifest]
    }

    private func installModelFixtures() throws -> URL {
        let models = directory.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: F.url("models/installed.json"), to: models.appendingPathComponent("installed.json"))
        try FileManager.default.copyItem(at: F.url("models/download.json"), to: models.appendingPathComponent("download.json"))
        try Data(count: 4_096).write(to: models.appendingPathComponent("bridgey-otp-v1.gguf"))
        try Data(count: 1_000).write(to: models.appendingPathComponent("bridgey-otp-v2.gguf.part"))
        return models
    }

    /// M3: records from an older build whose models this build does not pin restore nothing; the old file goes.
    @MainActor
    func testUnpinnedModelRecordsAreNotRestored() throws {
        let models = try installModelFixtures()
        let store = codeModelStore(models)
        XCTAssertFalse(store.isReady)
        XCTAssertNil(store.modelPath)
        XCTAssertNil(store.download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("bridgey-otp-v1.gguf").path))
    }

    @MainActor
    func testAnInstalledModelAndAPausedDownloadAreRestored() throws {
        let models = try installModelFixtures()
        let store = codeModelStore(models, pinned: try fixturePins())
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.installed?.version, 1)
        XCTAssertEqual(store.installed?.installedAt, ISO8601DateFormatter().date(from: "2026-10-26T09:00:00Z"))
        XCTAssertEqual(store.modelPath, models.appendingPathComponent("bridgey-otp-v1.gguf").path)
        XCTAssertEqual(store.download?.manifest.version, 2)
        XCTAssertEqual(store.download?.received, 1_000)
        XCTAssertEqual(store.download?.state, .paused, "a download the user paused stays paused")
        XCTAssertEqual(store.update?.version, 2)
    }

    @MainActor
    func testAModelRecordWithoutItsFileIsNotTrusted() throws {
        let models = directory.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: F.url("models/installed.json"), to: models.appendingPathComponent("installed.json"))
        try Data(count: 10).write(to: models.appendingPathComponent("bridgey-otp-v1.gguf"))
        try Data("{ not json".utf8).write(to: models.appendingPathComponent("download.json"))
        let store = codeModelStore(models)
        XCTAssertFalse(store.isReady, "a size that does not match the record")
        XCTAssertNil(store.download)
    }

    // MARK: Clipboard cache (ClipboardCache/<offerId>/<index>/<name>)

    func testACachedItemFromBeta5StillPastes() throws {
        let offerID = "7128e2f0-3296-4d06-9af8-136a4a16cac5"
        let root = directory.appendingPathComponent("ClipboardCache", isDirectory: true)
        let item = root.appendingPathComponent("\(offerID)/0", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: item.appendingPathComponent("photo.png"))
        try Data().write(to: item.appendingPathComponent(".handed-out"))
        let partial = root.appendingPathComponent("\(offerID)/1", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: partial.appendingPathComponent("video.mp4.\(ClipboardCache.partialSuffix)"))

        let cache = ClipboardCache(root: root, clock: { F.base })
        XCTAssertEqual(cache.cachedFile(offerID: offerID, index: 0)?.lastPathComponent, "photo.png")
        XCTAssertTrue(cache.isHandedOut(offerID: offerID, index: 0))
        XCTAssertNil(cache.cachedFile(offerID: offerID, index: 1), "a partial file is never pasted")
    }

    // MARK: Screen grants (screen-grants-v1.json, 1.0 Beta 5)

    private func screenGrants(_ fixture: String) throws -> MacScreenGrants {
        try FileManager.default.copyItem(at: F.url("screen-grants/\(fixture)"), to: directory.appendingPathComponent(MacScreenGrants.fileName))
        return MacScreenGrants(directory: directory)
    }

    /// Written before unattended access: only Ask each time and Allow without asking were stored, Off was no entry.
    /// Both choices are kept, Unattended access reads as on, and a device without an entry follows it.
    func testScreenGrantsFrom1_0Beta5Load() throws {
        let grants = try screenGrants("screen-grants.1.0.0-beta.5.json")
        XCTAssertTrue(grants.unattended)
        XCTAssertEqual(grants.explicitMode(for: F.phoneA, identityKey: F.keyA), .always)
        XCTAssertEqual(grants.explicitMode(for: F.phoneB, identityKey: F.keyB), .ask)
        XCTAssertNil(grants.explicitMode(for: F.phoneC, identityKey: F.keyC))
        XCTAssertEqual(grants.mode(for: F.phoneC, identityKey: F.keyC), .always)
        XCTAssertNil(grants.explicitMode(for: F.phoneA, identityKey: F.keyB), "a choice stays bound to its key")

        // A write in this build keeps both choices and adds the switch.
        grants.set(.off, for: F.phoneC, identityKey: F.keyC)
        let reloaded = MacScreenGrants(directory: directory)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneA, identityKey: F.keyA), .always)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneB, identityKey: F.keyB), .ask)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneC, identityKey: F.keyC), .off)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reloaded.fileURL)) as? [String: Any])
        XCTAssertEqual(written["version"] as? Int, 1)
        XCTAssertEqual(written["unattended"] as? Bool, true)
    }

    /// An entry that does not decode is Off for its device whatever the device's key, never Default (which may be Allow),
    /// and stays Off through saves; the good entry next to it is kept.
    func testABadScreenGrantIsOffForItsDevice() throws {
        let grants = try screenGrants("screen-grants.bad-entries.json")
        XCTAssertTrue(grants.unattended)
        XCTAssertEqual(grants.explicitMode(for: F.phoneA, identityKey: F.keyA), .ask, "the good entry is kept")
        XCTAssertEqual(grants.explicitMode(for: F.phoneB, identityKey: F.keyB), .off, "a mode this build does not know")
        XCTAssertEqual(grants.explicitMode(for: F.phoneC, identityKey: F.keyC), .off, "a key that is not a digest")
        XCTAssertEqual(grants.explicitMode(for: F.phoneD, identityKey: F.keyA), .off, "an entry that is not an object")
        XCTAssertEqual(grants.mode(for: F.phoneB, identityKey: F.keyC), .off, "whatever the device's key")
        // A save keeps them Off; choosing again replaces one.
        grants.set(.always, for: F.phoneA, identityKey: F.keyA)
        grants.set(.ask, for: F.phoneC, identityKey: F.keyC)
        let reloaded = MacScreenGrants(directory: directory)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneA, identityKey: F.keyA), .always)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneB, identityKey: F.keyB), .off)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneC, identityKey: F.keyC), .ask)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneD, identityKey: F.keyB), .off)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reloaded.fileURL)) as? [String: Any])
        let entries = try XCTUnwrap(written["grants"] as? [String: [String: String]])
        XCTAssertEqual(entries[F.phoneB], ["mode": "off", "key": MacScreenGrants.anyKey])
    }

    /// A file that cannot be read turns the switch off, and every device ID still legible in it stays Off when the
    /// person turns the switch back on.
    func testAnUnreadableScreenGrantsFileKeepsItsDevicesOff() throws {
        let truncated = #"{"grants":{"\#(F.phoneA)":{"key":"b5b687073f14e2d770eb7c73b682ca25368e213808fcb4d7d924bd8083f084e2","mode":"always"},"\#(F.phoneB)":{"ke"#
        try Data(truncated.utf8).write(to: directory.appendingPathComponent(MacScreenGrants.fileName))
        let grants = MacScreenGrants(directory: directory)
        XCTAssertFalse(grants.unattended)
        XCTAssertTrue(grants.setUnattended(true))
        XCTAssertEqual(grants.mode(for: F.phoneA, identityKey: F.keyA), .off, "a lost Allow without asking does not come back as Allow")
        XCTAssertEqual(grants.mode(for: F.phoneB, identityKey: F.keyB), .off)
        XCTAssertEqual(grants.mode(for: F.phoneC, identityKey: F.keyC), .always, "a device the file never named follows the switch")
        let reloaded = MacScreenGrants(directory: directory)
        XCTAssertTrue(reloaded.unattended, "the save wrote a good file")
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneA, identityKey: F.keyB), .off)
        XCTAssertEqual(reloaded.explicitMode(for: F.phoneB, identityKey: F.keyA), .off)
        XCTAssertEqual(MacScreenGrants.salvagedDeviceIDs(Data("no ids here".utf8)), [])
    }

    /// Missing `unattended` is on (files from before it); present and not a Boolean, null included, is off.
    func testAnUnattendedThatIsNotABooleanReadsAsOff() throws {
        let url = directory.appendingPathComponent(MacScreenGrants.fileName)
        let entry = #"{"\#(F.phoneA)":{"key":"b5b687073f14e2d770eb7c73b682ca25368e213808fcb4d7d924bd8083f084e2","mode":"ask"}}"#
        for (value, expected) in [("null", false), ("\"yes\"", false), ("1", false), ("true", true), ("false", false)] {
            try? FileManager.default.removeItem(at: url)
            try Data(#"{"grants":\#(entry),"unattended":\#(value),"version":1}"#.utf8).write(to: url)
            let grants = MacScreenGrants(directory: directory)
            XCTAssertEqual(grants.unattended, expected, "unattended \(value)")
            XCTAssertEqual(grants.explicitMode(for: F.phoneA, identityKey: F.keyA), .ask, "the rest of the file is read (\(value))")
        }
    }
}
