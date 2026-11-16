@testable import Bridgey
import XCTest

final class VersionsTests: XCTestCase {
    /// The same cases as scripts/rr/versions.py `display` and Versions.cs.
    func testDisplay() {
        XCTAssertEqual(Versions.display("1.0.0"), "1.0")
        XCTAssertEqual(Versions.display("1.0.1"), "1.0.1")
        XCTAssertEqual(Versions.display("1.1.0-beta.2"), "1.1 Beta 2")
        XCTAssertEqual(Versions.display("1.0.0-nightly.20261116"), "1.0 Nightly 16 Nov")
        XCTAssertEqual(Versions.display("0.11.0-rr.1-beta.3"), "0.11.0-rr.1 Beta 3")
        XCTAssertEqual(Versions.display("1.0.0-nightly.2026111"), "1.0.0-nightly.2026111")
        XCTAssertEqual(Versions.display("1.0.0-dev"), "1.0.0-dev")
    }

    func testThisBuildHasAVersion() {
        XCTAssertFalse(Edition.versionName.isEmpty)
        XCTAssertFalse(Edition.versionName.hasPrefix("$("))
        XCTAssertTrue(Versions.fullLabel.contains(Edition.buildNumber))
    }
}

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "in.roundrobin.bridgey.tests.\(UUID().uuidString)")

    override func tearDown() {
        store.removeAll()
    }

    func testStoreLoadReplaceRemove() throws {
        XCTAssertNil(try store.load("identity"))
        try store.store("identity", Data([1, 2, 3]))
        XCTAssertEqual(try store.load("identity"), Data([1, 2, 3]))
        try store.store("identity", Data([4]))
        XCTAssertEqual(try store.load("identity"), Data([4]))
        try store.remove("identity")
        XCTAssertNil(try store.load("identity"))
        try store.remove("identity")
    }

    func testEmptyValue() throws {
        try store.store("trust", Data())
        XCTAssertEqual(try store.load("trust"), Data())
    }
}

final class OutboxTests: XCTestCase {
    func testItemsRoundTripWithTheirFiles() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).txt")
        try Data("queued".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let text = OutboxItem(deviceID: "d", deviceName: "Mac", kind: .text, value: "hello")
        let file = OutboxItem(deviceID: "d", deviceName: "Mac", kind: .file, value: "notes.txt", created: Date().addingTimeInterval(1))
        try Outbox.add(text)
        try Outbox.add(file, file: source)
        defer {
            Outbox.remove(text)
            Outbox.remove(file)
        }
        let items = Outbox.items().filter { $0.id == text.id || $0.id == file.id }
        XCTAssertEqual(items.map(\.value), ["hello", "notes.txt"])
        XCTAssertEqual(try String(contentsOf: Outbox.file(of: file), encoding: .utf8), "queued")
        Outbox.remove(text)
        XCTAssertFalse(Outbox.items().contains { $0.id == text.id })
    }
}
