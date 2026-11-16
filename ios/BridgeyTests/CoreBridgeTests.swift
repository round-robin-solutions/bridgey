@testable import Bridgey
import Darwin
import XCTest

/// Two real bridgey_core clients in this process, through the Swift wrapper and the C ABI: they pair over the
/// loopback, keep their identities in host storage, and send text, links and files both ways.
final class CoreBridgeTests: XCTestCase {
    /// Events from one client's thread, waited on by the test.
    final class Log: @unchecked Sendable {
        private let condition = NSCondition()
        private var events: [CoreEvent] = []

        func add(_ e: CoreEvent) {
            condition.lock()
            events.append(e)
            condition.broadcast()
            condition.unlock()
        }

        func wait<T>(_ what: String, timeout: TimeInterval = 20, _ match: (CoreEvent) -> T?) throws -> T {
            let deadline = Date().addingTimeInterval(timeout)
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let found = events.lazy.compactMap(match).first { return found }
                guard condition.wait(until: deadline) else {
                    throw NSError(domain: "CoreBridgeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(what): not seen in \(events.map(\.kind))"])
                }
            }
        }
    }

    /// A store that also counts writes, so the test sees the host callbacks used.
    final class CountingStore: SecretStore, @unchecked Sendable {
        let inner = MemorySecretStore()
        private let lock = NSLock()
        private(set) var keys: Set<String> = []
        func load(_ key: String) throws -> Data? { try inner.load(key) }
        func store(_ key: String, _ value: Data) throws {
            lock.withLock { _ = keys.insert(key) }
            try inner.store(key, value)
        }
        func remove(_ key: String) throws { try inner.remove(key) }
    }

    /// A port nothing listens on.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    struct Peer {
        let core: BridgeyCore
        let log: Log
        let port: UInt16
        let received: URL
        let store: CountingStore
    }

    private var peers: [Peer] = []

    private func start(_ name: String) throws -> Peer {
        let log = Log()
        let store = CountingStore()
        let received = FileManager.default.temporaryDirectory.appendingPathComponent("received-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        var options = CoreOptions(deviceName: name)
        options.port = Self.freePort()
        options.receiveDirectory = received
        let core = try BridgeyCore.start(options, store: store) { [log] e in
            log.add(e)
        }
        for key in ["clipboard", "files", "links"] { try core.setFeature(deviceID: nil, key: key, on: true) }
        let peer = Peer(core: core, log: log, port: options.port, received: received, store: store)
        peers.append(peer)
        return peer
    }

    override func tearDown() {
        for p in peers {
            p.core.stop()
            try? FileManager.default.removeItem(at: p.received)
        }
        peers = []
    }

    private func pair(_ a: Peer, _ b: Peer) throws {
        try b.core.allowPairing(seconds: 120)
        let pairing = try a.core.pair(deviceID: nil, host: "127.0.0.1", port: b.port)
        let codeA = try a.log.wait("code on A") { $0.kind == .pairingCode && $0.id == pairing ? $0.text : nil }
        let codeB = try b.log.wait("code on B") { $0.kind == .pairingCode ? ($0.text, $0.id) : nil }
        XCTAssertEqual(codeA, codeB.0, "both people see the same six digits")
        XCTAssertEqual(codeA.count, 6)
        try a.core.confirmPairing(pairing, accept: true)
        try b.core.confirmPairing(codeB.1, accept: true)
        _ = try a.log.wait("A paired") { $0.kind == .pairingFinished && $0.status == 0 ? true : nil }
        // Both have each other's switches before anything is sent.
        _ = try a.log.wait("B's switches at A") { $0.kind == .features && ($0.extra ?? "").contains(#""files":true"#) ? true : nil }
        _ = try b.log.wait("A's switches at B") { $0.kind == .features && ($0.extra ?? "").contains(#""files":true"#) ? true : nil }
    }

    func testABIAndVersion() {
        XCTAssertEqual(CoreLibrary.abiVersion, CoreLibrary.expectedABI)
        XCTAssertFalse(CoreLibrary.version.isEmpty)
    }

    func testTwoClientsPairAndSendTextLinksAndFilesBothWays() throws {
        let a = try start("Test iPhone"), b = try start("Test Mac")
        try pair(a, b)
        XCTAssertTrue(a.store.keys.isSuperset(of: ["identity", "trust"]), "identity and trust go through the host's storage")
        let snapshot = try a.core.snapshot()
        XCTAssertEqual(snapshot.devices.first?.deviceId, b.core.deviceID)
        XCTAssertEqual(snapshot.devices.first?.connected, true)

        // Text both ways, with an emoji and the exact length.
        let request = try a.core.sendClipboard(b.core.deviceID, text: "héllo from iOS ✓")
        XCTAssertEqual(try b.log.wait("text at B") { $0.kind == .clipboard ? $0.text : nil }, "héllo from iOS ✓")
        XCTAssertEqual(try a.log.wait("delivered") { $0.kind == .clipboardSent && $0.id == request ? $0.status : nil }, SendStatus.delivered.rawValue)
        _ = try b.core.sendClipboard(a.core.deviceID, text: "and back")
        XCTAssertEqual(try a.log.wait("text at A") { $0.kind == .clipboard ? $0.text : nil }, "and back")

        // A link: it arrives as a link to open, never opened by the library.
        let link = try a.core.sendLink(b.core.deviceID, url: "https://roundrobin.in/bridgey")
        XCTAssertEqual(try b.log.wait("link at B") { $0.kind == .link ? $0.text : nil }, "https://roundrobin.in/bridgey")
        XCTAssertEqual(try a.log.wait("link answered") { $0.kind == .linkSent && $0.id == link ? $0.status : nil }, SendStatus.delivered.rawValue)

        // A file each way.
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let t = try a.core.sendFile(b.core.deviceID, url: source, name: "photo.jpg", mime: nil)
        let saved = try b.log.wait("file at B") { $0.kind == .fileDone && $0.status == 1 ? $0.text : nil }
        XCTAssertEqual(URL(fileURLWithPath: saved).lastPathComponent, "photo.jpg")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: saved)), bytes)
        _ = try a.log.wait("A told it was saved") { $0.kind == .fileDone && $0.id == t && $0.status == 0 ? true : nil }
        let back = b.received.appendingPathComponent("from-mac.txt")
        try Data("notes".utf8).write(to: back)
        _ = try b.core.sendFile(a.core.deviceID, url: back, name: nil, mime: nil)
        let savedAtA = try a.log.wait("file at A") { $0.kind == .fileDone && $0.status == 1 ? $0.text : nil }
        XCTAssertEqual(try String(contentsOfFile: savedAtA, encoding: .utf8), "notes")
    }

    func testRefusalsComeBackAsErrors() throws {
        let a = try start("Test iPhone")
        XCTAssertThrowsError(try a.core.sendClipboard("0b9e3f5c-1d2a-4b6c-8e7f-9a0b1c2d3e4f", text: "x")) { error in
            XCTAssertEqual((error as? CoreError)?.code, CoreError.notConnected)
        }
        XCTAssertThrowsError(try a.core.pair(deviceID: nil, host: "not an address", port: 1)) { error in
            XCTAssertEqual((error as? CoreError)?.code, CoreError.invalidArgument)
        }
        try a.core.addDiscovered(deviceID: nil, name: "Somewhere", platform: "macos", host: "192.168.77.7", port: 42_458)
        XCTAssertEqual(try a.core.snapshot().nearby.first?.host, "192.168.77.7")
        try a.core.removeDiscovered(host: "192.168.77.7", port: 42_458)
        XCTAssertTrue(try a.core.snapshot().nearby.isEmpty)
        a.core.stop()
        XCTAssertThrowsError(try a.core.ping("x")) { error in
            XCTAssertEqual((error as? CoreError)?.code, CoreError.stopped)
        }
    }
}
