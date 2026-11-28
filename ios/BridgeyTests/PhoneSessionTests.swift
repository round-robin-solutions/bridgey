@testable import Bridgey
import XCTest

/// Real bridgey_core sessions through the Swift wrapper: this device and a client that answers as an Android phone
/// (simulatePhoneForTests: canned conversations and a few folders), paired over the loopback. Text messages and the
/// phone's files go through the same calls the app makes.
final class PhoneSessionTests: XCTestCase {
    typealias Log = CoreBridgeTests.Log

    struct Device {
        let core: BridgeyCore
        let log: Log
        let port: UInt16
        let received: URL
    }

    private var devices: [Device] = []

    private func start(_ name: String, phone: Bool) throws -> Device {
        let log = Log()
        let received = FileManager.default.temporaryDirectory.appendingPathComponent("phone-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        var options = CoreOptions(deviceName: name)
        options.port = CoreBridgeTests.freePort()
        options.receiveDirectory = received
        let core = try BridgeyCore.start(options, store: MemorySecretStore()) { [log] e in log.add(e) }
        for key in ["clipboard", "files", "sms_draft1"] { try core.setFeature(deviceID: nil, key: key, on: true) }
        if phone {
            try core.simulatePhoneForTests(true)
            try core.setFeature(deviceID: nil, key: "files_browse_draft1", on: true)
        } else {
            try core.setFeature(deviceID: nil, key: "folders_receive_draft1", on: true)
        }
        let device = Device(core: core, log: log, port: options.port, received: received)
        devices.append(device)
        return device
    }

    override func tearDown() {
        for d in devices {
            d.core.stop()
            try? FileManager.default.removeItem(at: d.received)
        }
        devices = []
    }

    private func pair(_ a: Device, _ b: Device) throws {
        try b.core.allowPairing(seconds: 120)
        let pairing = try a.core.pair(deviceID: nil, host: "127.0.0.1", port: b.port)
        _ = try a.log.wait("code on A") { $0.kind == .pairingCode && $0.id == pairing ? true : nil }
        let other = try b.log.wait("code on B") { $0.kind == .pairingCode ? $0.id : nil }
        try a.core.confirmPairing(pairing, accept: true)
        try b.core.confirmPairing(other, accept: true)
        _ = try a.log.wait("A paired") { $0.kind == .pairingFinished && $0.status == 0 ? true : nil }
        _ = try a.log.wait("the phone's switches") { $0.kind == .features && ($0.extra ?? "").contains(#""sms_draft1":true"#) ? true : nil }
    }

    /// An area event `name` whose JSON matches.
    private func wait(_ d: Device, _ kind: CoreEventKind, _ name: String, _ match: @escaping ([String: Any]) -> Bool = { _ in true }) throws -> [String: Any] {
        try d.log.wait("\(kind) \(name)") { e in
            guard e.kind == kind, e.name == name else { return nil }
            let json = e.json
            return match(json) ? json : nil
        }
    }

    func testTextMessagesThroughTheWrapper() throws {
        let iphone = try start("Test iPhone", phone: false)
        let phone = try start("Test phone", phone: true)
        try pair(iphone, phone)
        let id = phone.core.deviceID
        _ = try wait(iphone, .sms, "status") { ($0["phone"] as? [String: Any])?["read"] as? Bool == true }
        _ = try wait(iphone, .sms, "changed") { $0["threads"] as? Bool == true }

        let threads = iphone.core.phone(.sms, deviceID: id, command: ["op": "threads"])
        XCTAssertEqual(threads["ok"] as? Bool, true)
        let rows = try XCTUnwrap(threads["threads"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { MessagesModel.int($0["threadId"]) }, [12, 7, 3], "unread first")
        XCTAssertEqual(MessagesModel.conversation(rows[0])?.title, "Asha")

        _ = iphone.core.phone(.sms, deviceID: id, command: ["op": "open", "threadId": 12])
        _ = try wait(iphone, .sms, "changed") { MessagesModel.int($0["threadId"]) == 12 }
        let page = iphone.core.phone(.sms, deviceID: id, command: ["op": "messages", "threadId": 12])
        let bodies = (page["messages"] as? [[String: Any]] ?? []).compactMap(MessagesModel.message).map(\.body)
        XCTAssertEqual(bodies, ["See you at 6", "Are you coming?", "Running late"])
        XCTAssertEqual(page["canSend"] as? Bool, true)

        let send = iphone.core.phone(.sms, deviceID: id, command: ["op": "send", "threadId": 12, "body": "On my way"])
        let request = try XCTUnwrap(send["requestId"] as? String)
        _ = try wait(iphone, .sms, "send") { $0["requestId"] as? String == request && $0["state"] as? String == "delivered" }

        _ = iphone.core.phone(.sms, deviceID: id, command: ["op": "contacts", "query": "As"])
        let contacts = try wait(iphone, .sms, "contacts")
        XCTAssertEqual((contacts["contacts"] as? [[String: Any]])?.first?["name"] as? String, "Asha")

        _ = iphone.core.phone(.sms, deviceID: id, command: ["op": "image", "partId": "p42"])
        let image = try wait(iphone, .sms, "image") { $0["partId"] as? String == "p42" }
        XCTAssertNotNil((image["data"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:)), "a picture the app can show")
    }

    func testPhoneFilesThroughTheWrapper() throws {
        let iphone = try start("Test iPhone", phone: false)
        let phone = try start("Test phone", phone: true)
        try pair(iphone, phone)
        let id = phone.core.deviceID
        let deadline = Date().addingTimeInterval(20)
        while iphone.core.phone(.phoneFiles, deviceID: id, command: ["op": "status"])["available"] as? Bool != true {
            XCTAssertLessThan(Date(), deadline, "the phone's files never became available")
            Thread.sleep(forTimeInterval: 0.05)
        }

        let places = try XCTUnwrap(iphone.core.phone(.phoneFiles, deviceID: id, command: ["op": "places"])["requestId"] as? String)
        let listed = try wait(iphone, .phoneFiles, "places") { $0["requestId"] as? String == places }
        XCTAssertEqual((listed["places"] as? [[String: Any]])?.compactMap(PhoneFilesModel.place).map(\.name), ["Download/Bridgey", "Pictures"])

        let list = try XCTUnwrap(iphone.core.phone(.phoneFiles, deviceID: id, command: ["op": "list", "placeId": "default", "path": "Trip"])["requestId"] as? String)
        let trip = try wait(iphone, .phoneFiles, "list") { $0["requestId"] as? String == list }
        XCTAssertEqual((trip["entries"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Beach", "IMG_0001.jpg", "IMG_0002.jpg"])

        // A download lands verified in this device's received files.
        let download = iphone.core.phone(.phoneFiles, deviceID: id, command: ["op": "download", "items": [["placeId": "default", "path": "", "name": "notes.txt"]]])
        let request = try XCTUnwrap(download["requestId"] as? String)
        let done = try wait(iphone, .phoneFiles, "download") { $0["requestId"] as? String == request && !["started", "receiving"].contains($0["state"] as? String ?? "") }
        XCTAssertEqual(done["state"] as? String, "done")
        XCTAssertEqual(try String(contentsOf: iphone.received.appendingPathComponent("notes.txt"), encoding: .utf8), "Bring the charger.\n")

        // An upload goes into the folder being browsed: the phone's receive folder here.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Plan \(UUID().uuidString.prefix(6)).txt")
        try Data("Pack light".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let upload = iphone.core.phone(.phoneFiles, deviceID: id, command: ["op": "upload", "placeId": "default", "path": "", "files": [["path": source.path]]])
        let uploadID = try XCTUnwrap(upload["uploadId"] as? String)
        let finished = try wait(iphone, .phoneFiles, "upload") { $0["uploadId"] as? String == uploadID && ["done", "incomplete", "failed", "cancelled"].contains($0["state"] as? String ?? "") }
        XCTAssertEqual(finished["state"] as? String, "done")
        XCTAssertEqual(try Data(contentsOf: phone.received.appendingPathComponent(source.lastPathComponent)), Data("Pack light".utf8))
    }
}
