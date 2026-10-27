import XCTest
@testable import BridgeyMac

@MainActor
final class TrayStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tray-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, bytes: Int = 10) throws -> URL {
        let url = root.appendingPathComponent("source/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testItemsPersistAcrossRestarts() throws {
        let directory = root.appendingPathComponent("Tray", isDirectory: true)
        let report = try file("report.pdf", bytes: 1_000)
        let store = TrayStore(directory: directory)
        store.add([.files([report]), .image(Data([1, 2, 3, 4]), ext: "png"), .text("Gate 14"), .link(URL(string: "https://example.com")!)])
        XCTAssertEqual(store.items.map(\.kind), [.file, .data, .text, .link])
        XCTAssertEqual(store.totalBytes, 1_000 + 4 + 7)

        let reopened = TrayStore(directory: directory)
        XCTAssertEqual(reopened.items, store.items)
        let sendables = reopened.sendables()
        XCTAssertEqual(sendables.urls.count, 2)
        XCTAssertEqual(sendables.urls.first?.standardizedFileURL.path, report.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: sendables.urls[1]), Data([1, 2, 3, 4]))
        XCTAssertEqual(sendables.texts, ["Gate 14", "https://example.com"])

        let json = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("tray.json").path)
        XCTAssertEqual((json[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let copy = try FileManager.default.attributesOfItem(atPath: sendables.urls[1].path)
        XCTAssertEqual((copy[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFilesAreBookmarksNotCopiesAndFollowARename() throws {
        let directory = root.appendingPathComponent("Tray", isDirectory: true)
        let original = try file("photo.jpg")
        let store = TrayStore(directory: directory)
        store.add([.files([original])])
        let moved = original.deletingLastPathComponent().appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: original, to: moved)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.url(for: item)?.standardizedFileURL.resolvingSymlinksInPath().path, moved.standardizedFileURL.resolvingSymlinksInPath().path)
        let itemsFolder = directory.appendingPathComponent("Items")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: itemsFolder.path)) ?? []).isEmpty)
    }

    func testDuplicatesAreSkipped() throws {
        let store = TrayStore(directory: root.appendingPathComponent("Tray", isDirectory: true))
        let url = try file("a.txt")
        store.add([.files([url, url])])
        store.add([.files([url])])
        XCTAssertEqual(store.items.count, 1)
    }

    func testClearThenUndoThenPurge() throws {
        let directory = root.appendingPathComponent("Tray", isDirectory: true)
        let store = TrayStore(directory: directory)
        store.add([.image(Data([9]), ext: "png"), .text("hi")])
        let removed = store.clear()
        XCTAssertTrue(store.isEmpty)
        store.restore(removed)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertNotNil(store.url(for: store.items[0]).flatMap { try? Data(contentsOf: $0) })

        let gone = store.clear()
        store.purge()
        XCTAssertNil(gone.first.flatMap { store.url(for: $0) }.flatMap { try? Data(contentsOf: $0) })
        XCTAssertTrue(TrayStore(directory: directory).isEmpty)
    }

    func testSendingMovesImageCopiesOutOfTheTray() throws {
        let store = TrayStore(directory: root.appendingPathComponent("Tray", isDirectory: true))
        store.add([.image(Data([5, 6]), ext: "png")])
        let sent = store.sendables(forSending: true).urls
        defer { sent.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        _ = store.clear()
        store.purge()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(sent.first)), Data([5, 6]))
    }

    func testRemoveDeletesTheCopy() throws {
        let store = TrayStore(directory: root.appendingPathComponent("Tray", isDirectory: true))
        store.add([.image(Data([1]), ext: "png")])
        let item = try XCTUnwrap(store.items.first)
        let url = try XCTUnwrap(store.url(for: item))
        store.remove(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBoundedToTheNewestItems() {
        let store = TrayStore(directory: root.appendingPathComponent("Tray", isDirectory: true))
        store.add((0..<(TrayStore.maximumItems + 5)).map { DropPayload.text("note \($0)") })
        XCTAssertEqual(store.items.count, TrayStore.maximumItems)
        XCTAssertEqual(store.items.last?.text, "note \(TrayStore.maximumItems + 4)")
    }
}
