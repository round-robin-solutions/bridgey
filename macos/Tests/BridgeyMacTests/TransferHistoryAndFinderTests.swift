import Darwin
import Foundation
import XCTest
@testable import BridgeyMac

@MainActor
final class TransferHistoryAndFinderTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws { base = temporaryFolder("history") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func entry(_ id: String, _ date: Date, name: String = "a.txt", device: String = "phone-1", direction: TransferHistoryEntry.Direction = .received,
                       outcome: TransferHistoryEntry.Outcome = .completed, folder: Bool = false) -> TransferHistoryEntry {
        TransferHistoryEntry(id: id, date: date, direction: direction, deviceID: device, deviceName: device == "phone-1" ? "OnePlus 11" : "Pixel",
                             name: name, isFolder: folder, bytes: 10, outcome: outcome, localPath: "/tmp/\(name)")
    }

    func testHistoryKeepsThirtyDaysAndTwoThousandEntriesNewestFirst() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TransferHistoryStore(fileURL: nil, clock: { now })
        store.record(entry("old", now.addingTimeInterval(-31 * 86_400)))
        XCTAssertTrue(store.entries.isEmpty, "older than 30 days is never kept")
        for index in 0..<2_005 { store.record(entry(String(format: "e%05d", index), now.addingTimeInterval(Double(-index)))) }
        XCTAssertEqual(store.entries.count, 2_000)
        XCTAssertEqual(store.entries.first?.id, "e00000")
        XCTAssertEqual(store.entries.last?.id, "e01999")
        store.record(entry("e00000", now.addingTimeInterval(1), name: "replaced.txt"))
        XCTAssertEqual(store.entries.first?.name, "replaced.txt")
        XCTAssertEqual(store.entries.filter { $0.id == "e00000" }.count, 1)
        now = now.addingTimeInterval(30 * 86_400 + 10)
        store.prune()
        XCTAssertTrue(store.entries.allSatisfy { $0.date >= now.addingTimeInterval(-30 * 86_400) })
    }

    func testHistoryPersistsOwnerOnlyAndForgetsADevice() throws {
        let url = base.appendingPathComponent("Support/transfer-history.json")
        let store = TransferHistoryStore(fileURL: url)
        store.record(entry("a", Date()))
        store.record(entry("b", Date(), device: "phone-2"))
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(url.deletingLastPathComponent().path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let reloaded = TransferHistoryStore(fileURL: url)
        XCTAssertEqual(Set(reloaded.entries.map(\.id)), ["a", "b"])
        reloaded.forget(deviceID: "phone-2")
        XCTAssertEqual(TransferHistoryStore(fileURL: url).entries.map(\.id), ["a"])
        reloaded.clear()
        XCTAssertTrue(TransferHistoryStore(fileURL: url).entries.isEmpty)
    }

    func testHistoryFilters() {
        let store = TransferHistoryStore(fileURL: nil)
        let now = Date()
        store.record(entry("1", now, name: "Invoice May.pdf"))
        store.record(entry("2", now, name: "Photos", direction: .sent, folder: true))
        store.record(entry("3", now, name: "clip.mp4", device: "phone-2", outcome: .cancelled))
        XCTAssertEqual(store.filtered(TransferHistoryFilter(query: "invoice")).map(\.id), ["1"])
        XCTAssertEqual(store.filtered(TransferHistoryFilter(query: "pixel")).map(\.id), ["3"])
        XCTAssertEqual(store.filtered(TransferHistoryFilter(direction: .sent)).map(\.id), ["2"])
        XCTAssertEqual(store.filtered(TransferHistoryFilter(outcome: .cancelled)).map(\.id), ["3"])
        XCTAssertEqual(store.filtered(TransferHistoryFilter(foldersOnly: true)).map(\.id), ["2"])
        XCTAssertEqual(Set(store.filtered(TransferHistoryFilter(deviceID: "phone-1")).map(\.id)), ["1", "2"])
    }

    func testWhereFromAndTagAreWrittenAndReadBack() throws {
        let file = base.appendingPathComponent("IMG.jpg")
        try Data([1]).write(to: file)
        FinderMetadata.finish([file], phoneName: "OnePlus 11", tag: true)
        XCTAssertEqual(FinderMetadata.whereFroms(file), ["Bridgey: OnePlus 11"])
        XCTAssertEqual(FinderMetadata.tags(file), ["Bridgey"])
        // Spotlight's attribute is a binary property list, as Safari writes it.
        let size = getxattr(file.path, FinderMetadata.whereFromsAttribute, nil, 0, 0, 0)
        var raw = Data(count: size)
        _ = raw.withUnsafeMutableBytes { getxattr(file.path, FinderMetadata.whereFromsAttribute, $0.baseAddress, size, 0, 0) }
        XCTAssertTrue(raw.starts(with: Data("bplist00".utf8)))
        // Tagging twice keeps one tag.
        FinderMetadata.addTag(file)
        XCTAssertEqual(FinderMetadata.tags(file), ["Bridgey"])
    }

    func testDownloadsDetection() throws {
        let downloads = base.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent("Bridgey"), withIntermediateDirectories: true)
        XCTAssertTrue(FinderMetadata.isInDownloads(downloads.appendingPathComponent("Bridgey/a.txt"), downloads: downloads))
        XCTAssertFalse(FinderMetadata.isInDownloads(base.appendingPathComponent("DownloadsOther/a.txt"), downloads: downloads))
    }
}
