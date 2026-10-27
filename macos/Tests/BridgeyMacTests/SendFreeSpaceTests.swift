import XCTest
@testable import BridgeyMac

final class SendFreeSpaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gb: Int64 = 1_000_000_000

    private func gate(_ needed: Int64, free: Int64?, age: TimeInterval = 0) -> FreeSpaceGate {
        FreeSpaceGate(FreeSpaceCheck.evaluate(needed: needed, free: free.map { PhoneFreeSpace(bytes: $0, checkedAt: now.addingTimeInterval(-age)) }, now: now),
                      phoneName: "OnePlus 11")
    }

    func testBlockRefusesWithTheLine() {
        let result = gate(2_300_000_000, free: 1_100_000_000)
        XCTAssertTrue(result.refuses)
        XCTAssertEqual(result.message, "Needs 2.3 GB, OnePlus 11 has 1.1 GB free")
    }

    func testWarnSendsWithTheLine() {
        let result = gate(2 * gb, free: 2 * gb + 500_000_000)
        XCTAssertEqual(result, .sendWithWarning("Needs 2 GB, OnePlus 11 has 2.5 GB free"))
        XCTAssertFalse(result.refuses)
    }

    func testOkAndNoData() {
        XCTAssertEqual(gate(1 * gb, free: 50 * gb), .send)
        XCTAssertEqual(gate(5 * gb, free: nil), .send, "no data never blocks")
        XCTAssertEqual(gate(0, free: 10), .send)
    }

    func testStaleNumbersOnlyWarn() {
        let result = gate(2_300_000_000, free: 1_100_000_000, age: 10 * 60)
        XCTAssertFalse(result.refuses)
        XCTAssertNotNil(result.message)
    }

    func testNeededUsesTheOptimisedEstimate() {
        XCTAssertEqual(SendSizing.needed(original: 1_000, saving: nil), 1_000)
        XCTAssertEqual(SendSizing.needed(original: 1_000, saving: 0.68), 320)
        XCTAssertEqual(SendSizing.needed(original: 1_000, saving: 2), 0)
        // An optimised send that fits where the originals would not.
        XCTAssertTrue(gate(SendSizing.needed(original: 3 * gb, saving: nil), free: 2 * gb).refuses)
        XCTAssertFalse(gate(SendSizing.needed(original: 3 * gb, saving: 0.7), free: 2 * gb).refuses)
    }

    func testPayloadBytesCountFilesNotText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("free-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 300).write(to: folder.appendingPathComponent("sub/a.bin"))
        let loose = folder.appendingPathComponent("b.bin")
        try Data(count: 200).write(to: loose)
        XCTAssertEqual(SendSizing.bytes([.files([folder.appendingPathComponent("sub"), loose]), .image(Data(count: 7), ext: "png"),
                                         .text("hello"), .link(URL(string: "https://example.com")!)]), 507)
    }

    func testSheetAndTrayRefuseToSendWhenBlocked() {
        var sheet = SendSheetState()
        sheet.targetID = "phone"
        sheet.recent = [SendCandidate(url: URL(fileURLWithPath: "/big"), name: "big", size: 10, date: Date(), isDirectory: false)]
        sheet.selection = [URL(fileURLWithPath: "/big")]
        XCTAssertTrue(sheet.canSend)
        sheet.freeSpace = .sendWithWarning("x")
        XCTAssertTrue(sheet.canSend)
        sheet.freeSpace = .refuse("x")
        XCTAssertFalse(sheet.canSend)

        var tray = TrayViewState()
        tray.targetID = "phone"
        tray.items = [TrayItem(id: "1", kind: .file, name: "a", size: 1_000, addedAt: Date()), TrayItem(id: "2", kind: .text, name: "t", size: 50, addedAt: Date(), text: "t")]
        XCTAssertEqual(tray.neededBytes, 1_000)
        tray.freeSpace = .refuse("x")
        XCTAssertFalse(tray.canSend)
    }
}
