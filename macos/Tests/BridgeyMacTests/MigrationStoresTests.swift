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
/// (Beta 10), the code model records (Beta 13) and the clipboard cache layout (Beta 5).
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
    private func codeModelStore(_ models: URL) -> CodeModelStore {
        CodeModelStore(files: CodeModelFiles(directory: models), transport: FakeModelTransport(data: Data()), bundledManifest: nil,
                       manifestURL: nil, assetURLPrefix: prefix, spaceQuery: { _ in 10_000_000_000 },
                       makeRunner: { FakeRunner(output: "") })
    }

    @MainActor
    func testAnInstalledModelAndAPausedDownloadAreRestored() throws {
        let models = directory.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: F.url("models/installed.json"), to: models.appendingPathComponent("installed.json"))
        try FileManager.default.copyItem(at: F.url("models/download.json"), to: models.appendingPathComponent("download.json"))
        try Data(count: 4_096).write(to: models.appendingPathComponent("bridgey-otp-v1.gguf"))
        try Data(count: 1_000).write(to: models.appendingPathComponent("bridgey-otp-v2.gguf.part"))

        let store = codeModelStore(models)
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
}
