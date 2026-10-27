import Foundation
import XCTest
@testable import BridgeyMac

/// Files 2.0 (0.8.0-rr.1) stores on the Mac: the Tray, the transfer history, receive journals (folders from
/// phones and downloads), upload journals, and the new settings, send and Phone files keys. The fixtures in
/// `protocol/test-vectors/migrations/macos` are this build's formats, pinned so a later build keeps reading
/// them (docs/upgrade-policy.md). Settings go through `UserDefaults.standard` as in MigrationSettingsTests.
final class MigrationFiles2Tests: XCTestCase {
    private typealias F = MigrationFixtures
    private static var runnerDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    private let journalA = "3b2f6c1a-8e4d-4f7a-b1c2-0d9e8f7a6b51"
    private let journalB = "3b2f6c1a-8e4d-4f7a-b1c2-0d9e8f7a6b52"
    private let journalUnknownVersion = "3b2f6c1a-8e4d-4f7a-b1c2-0d9e8f7a6b53"
    private let journalDamaged = "3b2f6c1a-8e4d-4f7a-b1c2-0d9e8f7a6b54"
    private let uploadJournal = "7a1b2c3d-4e5f-4a6b-9c7d-8e9f0a1b2c3d"
    private let trayImageID = "0a8c2f3e-1d4b-4c6e-9f70-5a1b2c3d4e03"

    private var directory: URL!
    private var savedSettings: [String: Any] = [:]
    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        directory = try F.temporaryDirectory("files2")
        savedSettings = (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).filter { $0.key.hasPrefix("settings.") }
        clearStandardSettings()
        suiteName = "in.roundrobin.bridgey.migration-tests.\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        clearStandardSettings()
        for (key, value) in savedSettings { UserDefaults.standard.set(value, forKey: key) }
        suite.removePersistentDomain(forName: suiteName)
        BridgeyLog.policy = LoggingPolicy()
        try? FileManager.default.removeItem(at: directory)
    }

    private func clearStandardSettings() {
        for key in (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).keys where key.hasPrefix("settings.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// `settings.*` into the standard domain (BridgeySettings), everything else into the suite.
    private func install(_ fixture: String) throws {
        clearStandardSettings()
        suite.removePersistentDomain(forName: suiteName)
        for (key, value) in try F.defaults(fixture) {
            if key.hasPrefix("settings.") { UserDefaults.standard.set(value, forKey: key) } else { suite.set(value, forKey: key) }
        }
    }

    private func contents(_ folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    // MARK: Settings, send options and the Phone files window (UserDefaults)

    @MainActor
    private func phoneFilesModel() -> PhoneFilesModel {
        PhoneFilesModel(service: UIFakePhoneFiles(), cache: PhoneThumbnailCache(directory: nil), defaults: suite,
                        listingCache: PhoneListingCache(directory: nil), receivedFolder: { self.directory },
                        previewFolder: directory.appendingPathComponent("originals"))
    }

    @MainActor
    func testFiles2SettingsLoad() throws {
        try install("settings/defaults.0.8.0-rr.1.plist")
        let settings = BridgeySettings()
        XCTAssertEqual(settings.folderReceiveMode, .ask)
        XCTAssertEqual(settings.folderConflictPolicy, .newFolder)
        XCTAssertTrue(settings.tagReceivedFiles)
        // The older keys in the same snapshot still read.
        XCTAssertEqual(settings.deviceName, "Test Mac")
        XCTAssertTrue(settings.codesEnabled)

        let send = SendPreferences(defaults: suite)
        XCTAssertEqual(send.menuBarDropMode, .tray)
        XCTAssertEqual(send.lastDeviceID, F.phoneA)
        XCTAssertEqual(send.optimization, SendOptimization(imageMode: .optimize, maxEdge: 1280, format: .webp, quality: 70, stripLocation: true,
                                                           stripCamera: true, stripDates: false, videoMode: .hd720Small, folderMode: .zip))

        let model = phoneFilesModel()
        XCTAssertEqual(model.sort, .modified)
        XCTAssertTrue(model.descending)
        XCTAssertEqual(model.section, .folders)
        XCTAssertEqual(suite.string(forKey: "phoneFiles.last.phone"), F.phoneA)
        XCTAssertEqual(suite.string(forKey: "phoneFiles.last.place.\(F.phoneA)"), "q3Jx0bVv1eG7tq8Wm2l5wA")
    }

    @MainActor
    func testSnapshotsFromBeforeFiles2GetItsDefaults() throws {
        for release in [10, 11, 13] {
            try install("settings/defaults.beta.\(release).plist")
            let label = "beta.\(release)"
            let settings = BridgeySettings()
            XCTAssertEqual(settings.folderReceiveMode, .fixed, label)
            XCTAssertEqual(settings.folderConflictPolicy, .ask, label)
            XCTAssertFalse(settings.tagReceivedFiles, label)
            let send = SendPreferences(defaults: suite)
            XCTAssertEqual(send.menuBarDropMode, .springOpen, label)
            XCTAssertNil(send.lastDeviceID, label)
            XCTAssertEqual(send.optimization, .default, label)
            XCTAssertTrue(send.optimization.stripLocation, "location is stripped by default (files-browse.md B10)")
            let model = phoneFilesModel()
            XCTAssertEqual(model.sort, .name, label)
            XCTAssertFalse(model.descending, label)
            XCTAssertEqual(model.section, .media, label)
        }
    }

    @MainActor
    func testFiles2WrongValuesFallBackToDefaultsWithoutCrashing() throws {
        try install("settings/defaults.files2-wrong-values.plist")
        let settings = BridgeySettings()
        XCTAssertEqual(settings.folderReceiveMode, .fixed)
        XCTAssertEqual(settings.folderConflictPolicy, .ask)
        XCTAssertFalse(settings.tagReceivedFiles)
        let send = SendPreferences(defaults: suite)
        XCTAssertEqual(send.menuBarDropMode, .springOpen)
        XCTAssertEqual(send.optimization, .default)
        let model = phoneFilesModel()
        XCTAssertEqual(model.sort, .name)
        XCTAssertEqual(model.section, .media)
    }

    // MARK: Tray (Tray/tray.json and Tray/Items/<id>/<name>)

    private func installTray(_ fixture: String) throws -> URL {
        let tray = directory.appendingPathComponent("Tray", isDirectory: true)
        try FileManager.default.createDirectory(at: tray, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: F.url("tray/\(fixture)"), to: tray.appendingPathComponent("tray.json"))
        return tray
    }

    @MainActor
    func testTrayFrom080Loads() throws {
        let tray = try installTray("tray.0.8.0-rr.1.json")
        let image = tray.appendingPathComponent("Items/\(trayImageID)/Image 2026-10-26 at 09.00.02.png")
        let orphan = tray.appendingPathComponent("Items/ffffffff-0000-4000-8000-000000000000/Image.png")
        for url in [image, orphan] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: 64).write(to: url)
        }
        let store = TrayStore(directory: tray)
        XCTAssertEqual(store.items.map(\.kind), [.file, .folder, .data, .text, .link])
        XCTAssertEqual(store.items[0].path, "/Users/test/Documents/Invoice 2026-10.pdf")
        XCTAssertEqual(store.items[0].addedAt, F.base)
        XCTAssertEqual(store.totalBytes, 184_320 + 52_428_800 + 64 + 22)
        XCTAssertEqual(store.url(for: store.items[2])?.path, image.path)
        XCTAssertEqual(store.sendables(Array(store.items[3...])).texts, ["Meet at the north gate", "https://example.com/tickets"])
        // The dropped image stays; a copy no item points at is cleaned up.
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        // A write in this build keeps the others.
        store.remove(store.items[0].id)
        XCTAssertEqual(TrayStore(directory: tray).items.map(\.kind), [.folder, .data, .text, .link])
    }

    @MainActor
    func testTrayEntriesThisBuildCannotReadAreDroppedOneByOne() throws {
        let tray = try installTray("tray.unknown-entries.json")
        let store = TrayStore(directory: tray)
        XCTAssertEqual(store.items.map(\.id), ["0a8c2f3e-1d4b-4c6e-9f70-5a1b2c3d4e01", "0a8c2f3e-1d4b-4c6e-9f70-5a1b2c3d4e02",
                                               "0a8c2f3e-1d4b-4c6e-9f70-5a1b2c3d4e04"])
    }

    // MARK: Transfer history (transfer-history.json)

    @MainActor
    func testTransferHistoryFrom080Loads() throws {
        let file = directory.appendingPathComponent(TransferHistoryStore.fileName)
        try FileManager.default.copyItem(at: F.url("transfer-history/transfer-history.0.8.0-rr.1.json"), to: file)
        let store = TransferHistoryStore(fileURL: file, clock: { F.base.addingTimeInterval(3_600) })
        XCTAssertEqual(store.entries.map(\.id), ["h-0004", "h-0003", "h-0002", "h-0001"], "newest first")
        let folder = try XCTUnwrap(store.entries.last)
        XCTAssertEqual(folder.date, F.base)
        XCTAssertEqual(folder.direction, .sent)
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(folder.fileCount, 12)
        XCTAssertEqual(folder.localURL?.path, "/Users/test/Pictures/Trip 2026")
        XCTAssertEqual(folder.destination, "Download/Bridgey/Trip 2026")
        XCTAssertEqual(store.entries.first { $0.id == "h-0002" }?.download, true)
        XCTAssertEqual(store.entries.first { $0.id == "h-0003" }?.outcome, .incomplete)
        XCTAssertEqual(store.filtered(TransferHistoryFilter(query: "trip")).map(\.id), ["h-0001"])
        // A write in this build keeps the others; after 30 days they go.
        store.remove("h-0004")
        XCTAssertEqual(TransferHistoryStore(fileURL: file, clock: { F.base.addingTimeInterval(3_600) }).entries.count, 3)
        XCTAssertEqual(TransferHistoryStore(fileURL: file, clock: { F.base.addingTimeInterval(31 * 86_400) }).entries, [])
    }

    @MainActor
    func testTransferHistoryEntriesThisBuildCannotReadAreDroppedOneByOne() throws {
        let file = directory.appendingPathComponent(TransferHistoryStore.fileName)
        try FileManager.default.copyItem(at: F.url("transfer-history/transfer-history.unknown-entries.json"), to: file)
        let store = TransferHistoryStore(fileURL: file, clock: { F.base.addingTimeInterval(3_600) })
        XCTAssertEqual(store.entries.map(\.id), ["h-0004", "h-0003", "h-0002", "h-0001"])
    }

    // MARK: Receive journals (FolderReceives/<id>.journal)

    func testReceiveJournalsFrom080ResumeAndUnreadableOnesGo() throws {
        let folder = directory.appendingPathComponent("FolderReceives", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in [journalA, journalB, journalUnknownVersion, journalDamaged] {
            let target = folder.appendingPathComponent("\(id).journal")
            try FileManager.default.copyItem(at: F.url("folder-receives/\(id).journal"), to: target)
            try FileManager.default.setAttributes([.modificationDate: F.base.addingTimeInterval(600)], ofItemAtPath: target.path)
        }
        let store = ReceiveJournalStore(directory: folder)
        let records = store.recover(now: F.base.addingTimeInterval(3_600)).sorted { $0.header.createdAt < $1.header.createdAt }
        XCTAssertEqual(records.map(\.header.folderTransferId), [journalA, journalB])

        let pushed = records[0]
        XCTAssertEqual(pushed.header.peerID, F.phoneA)
        XCTAssertEqual(pushed.header.choice, .merge)
        XCTAssertFalse(pushed.header.into)
        XCTAssertNil(pushed.header.downloadRequestId)
        XCTAssertNil(pushed.header.purpose)
        XCTAssertEqual(pushed.header.rootPath, "/Users/test/Downloads/Bridgey/Camera 2026")
        XCTAssertEqual(pushed.header.createdAt, F.base)
        XCTAssertEqual(pushed.dirs, [0: "/Users/test/Downloads/Bridgey/Camera 2026"])
        XCTAssertEqual(Set(pushed.parts.keys), [1, 2, 3])
        XCTAssertEqual(pushed.done, [1])
        XCTAssertEqual(pushed.abandoned, [2])
        XCTAssertEqual(pushed.lastProgressAt, F.base.addingTimeInterval(600))

        let download = records[1]
        XCTAssertEqual(download.header.peerID, F.phoneB)
        XCTAssertTrue(download.header.into)
        XCTAssertEqual(download.header.choice, ConflictChoice.none)
        XCTAssertEqual(download.header.downloadRequestId, "9f8e7d6c-5b4a-4321-8fed-cba987654321")
        XCTAssertEqual(download.header.purpose, "save")
        XCTAssertEqual(download.header.topNames, ["IMG_0001.jpg": "IMG_0001 (1).jpg"])
        XCTAssertEqual(download.done, [0])

        // Another version and a damaged file only held work in progress: removed.
        XCTAssertEqual(try contents(folder), ["\(journalA).journal", "\(journalB).journal"])
        // 24 hours after the last progress the rest go too.
        XCTAssertEqual(store.recover(now: F.base.addingTimeInterval(25 * 3_600)), [])
        XCTAssertEqual(try contents(folder), [])
    }

    // MARK: Upload journals (FolderTransfers/<id>.json with roots and into)

    func testAnUploadJournalFrom080ResumesAndOlderJournalsReadWithoutTheNewFields() throws {
        let folder = directory.appendingPathComponent("FolderTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: F.url("folder-transfers-0.8/\(uploadJournal).json"), to: folder.appendingPathComponent("\(uploadJournal).json"))
        let beta10 = "69c301e2-8dd2-48b9-a0d1-3cb747960e0b"
        try FileManager.default.copyItem(at: F.url("folder-transfers/\(beta10).json"), to: folder.appendingPathComponent("\(beta10).json"))
        let journals = FolderJournalStore(directory: folder).load(now: F.base.addingTimeInterval(3_600))
        XCTAssertEqual(journals.map(\.folderTransferId), [beta10, uploadJournal].sorted())
        let upload = try XCTUnwrap(journals.first { $0.folderTransferId == uploadJournal })
        XCTAssertEqual(upload.into, true)
        XCTAssertEqual(upload.roots, ["/Users/test/Documents/Invoice 2026-10.pdf", "/Users/test/Documents/Receipts"])
        XCTAssertEqual(upload.destination, FolderDestination(placeId: "q3Jx0bVv1eG7tq8Wm2l5wA", path: "Documents"))
        XCTAssertEqual(upload.completed, [0])
        let older = try XCTUnwrap(journals.first { $0.folderTransferId == beta10 })
        XCTAssertNil(older.into)
        XCTAssertNil(older.roots)
    }

    // MARK: Names

    @MainActor
    func testFiles2StorageNamesArePinned() {
        XCTAssertEqual(TrayStore.defaultDirectory().lastPathComponent, "Tray")
        XCTAssertEqual(TrayStore.defaultDirectory().deletingLastPathComponent().lastPathComponent, "in.roundrobin.bridgey")
        XCTAssertEqual(TransferHistoryStore.defaultFileURL().lastPathComponent, "transfer-history.json")
        XCTAssertEqual(ReceiveJournalStore.defaultDirectory().lastPathComponent, "FolderReceives")
        XCTAssertEqual(DroppedData.directory().lastPathComponent, "Dropped")
        XCTAssertEqual(PhoneThumbnailCache.defaultDirectory().lastPathComponent, "PhoneFiles")
        XCTAssertEqual(SendOptimizer.cacheDirectory().lastPathComponent, "SendOptimized")
    }
}
