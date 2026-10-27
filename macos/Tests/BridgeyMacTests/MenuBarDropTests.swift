import AppKit
import XCTest
@testable import BridgeyMac

final class MenuBarDropTests: XCTestCase {
    private let a = "phone-a"
    private let b = "phone-b"

    func testSpringOpenModeSendsQuickDropsToTheDefaultDeviceWithUndo() {
        XCTAssertTrue(DropRouter.springOpens(.springOpen))
        XCTAssertEqual(DropRouter.decide(.icon, mode: .springOpen, connected: [a, b], defaultDevice: b), .send(deviceID: b, undoToast: true))
        XCTAssertEqual(DropRouter.decide(.device(a), mode: .springOpen, connected: [a, b], defaultDevice: b), .send(deviceID: a, undoToast: false))
        XCTAssertEqual(DropRouter.decide(.tray, mode: .springOpen, connected: [a, b], defaultDevice: b), .collect(notConnected: false))
    }

    func testTrayModeAlwaysCollects() {
        XCTAssertFalse(DropRouter.springOpens(.tray))
        XCTAssertEqual(DropRouter.decide(.icon, mode: .tray, connected: [a], defaultDevice: a), .collect(notConnected: false))
    }

    func testInstantModeSendsWithoutOpening() {
        XCTAssertFalse(DropRouter.springOpens(.instant))
        XCTAssertEqual(DropRouter.decide(.icon, mode: .instant, connected: [a], defaultDevice: a), .send(deviceID: a, undoToast: true))
    }

    func testNothingConnectedCollectsInTheTray() {
        for mode in MenuBarDropMode.allCases where mode != .tray {
            XCTAssertEqual(DropRouter.decide(.icon, mode: mode, connected: [], defaultDevice: a), .collect(notConnected: true), mode.rawValue)
        }
        XCTAssertEqual(DropRouter.decide(.device(a), mode: .springOpen, connected: [b], defaultDevice: b), .collect(notConnected: true))
    }

    func testPasteboardPayloads() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("bridgey.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drop-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        board.clearContents()
        board.writeObjects([file as NSURL])
        XCTAssertEqual(DropPayload.from(pasteboard: board), [.files([file])])

        board.clearContents()
        board.writeObjects([URL(string: "https://example.com/a")! as NSURL])
        XCTAssertEqual(DropPayload.from(pasteboard: board), [.link(URL(string: "https://example.com/a")!)])

        board.clearContents()
        board.setString("  meet at 4  ", forType: .string)
        XCTAssertEqual(DropPayload.from(pasteboard: board), [.text("meet at 4")])

        board.clearContents()
        board.setString("https://example.com/b", forType: .string)
        XCTAssertEqual(DropPayload.from(pasteboard: board), [.link(URL(string: "https://example.com/b")!)])

        board.clearContents()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        XCTAssertEqual(DropPayload.from(pasteboard: board), [.image(Data([0x89, 0x50, 0x4E, 0x47]), ext: "png")])
    }

    func testDroppedImagesAreOwnerOnly() throws {
        let url = try XCTUnwrap(DroppedData.write(Data([1, 2, 3]), ext: "png"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
