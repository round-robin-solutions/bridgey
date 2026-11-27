@testable import Bridgey
import XCTest

/// Real bridgey_core sessions through the Swift wrapper: this device against a client that answers as a simulated
/// Android phone and a simulated Mac (simulatePhoneForTests). Each screen is asked for, its frames pulled by the
/// frame pump and decoded by VideoToolbox in the simulator, control begun, and the input checked at the other end.
final class ScreenSessionTests: XCTestCase {
    typealias Log = CoreBridgeTests.Log

    private struct Peer {
        let core: BridgeyCore
        let log: Log
        let port: UInt16
    }

    private var peers: [Peer] = []
    private var pumps: [FramePump] = []

    private func start(_ name: String) throws -> Peer {
        let log = Log()
        var options = CoreOptions(deviceName: name)
        options.port = CoreBridgeTests.freePort()
        let core = try BridgeyCore.start(options, store: MemorySecretStore()) { [log] e in log.add(e) }
        // The phone's and the Mac's screen keys, as each side sends them for a phone and a Mac.
        for key in ["clipboard"] + ScreenRoles.keys { try core.setFeature(deviceID: nil, key: key, on: true) }
        let peer = Peer(core: core, log: log, port: options.port)
        peers.append(peer)
        return peer
    }

    override func tearDown() {
        for p in pumps { p.stop() }
        for p in peers { p.core.stop() }
        pumps = []
        peers = []
    }

    private func pair(_ a: Peer, _ b: Peer) throws {
        try b.core.allowPairing(seconds: 120)
        let pairing = try a.core.pair(deviceID: nil, host: "127.0.0.1", port: b.port)
        _ = try a.log.wait("code on A") { $0.kind == .pairingCode && $0.id == pairing ? true : nil }
        let codeB = try b.log.wait("code on B") { $0.kind == .pairingCode ? $0.id : nil }
        try a.core.confirmPairing(pairing, accept: true)
        try b.core.confirmPairing(codeB, accept: true)
        _ = try a.log.wait("B's screen keys at A") { $0.kind == .features && ($0.extra ?? "").contains(#""screen_control_draft1":true"#) ? true : nil }
    }

    private func command(_ peer: Peer, _ area: PhoneArea, _ device: String, _ command: [String: Any]) throws -> [String: Any] {
        let answer = peer.core.phone(area, deviceID: device, command: command)
        XCTAssertEqual(answer["ok"] as? Bool, true, "\(command): \(answer)")
        return answer
    }

    private func json(_ e: CoreEvent) -> [String: Any] { e.json }

    /// Asks for the area's screen, pumps and decodes frames, begins control and returns the stream handle.
    private func showAndControl(_ area: PhoneArea, here: Peer, other: Peer) throws -> UInt64 {
        let device = other.core.deviceID
        _ = try command(here, area, device, ["op": "request"])
        let started = try here.log.wait("\(area) started") { $0.kind == area.eventKind && $0.name == "started" ? $0 : nil }
        let detail = json(started)
        let control = detail["control"] as? [String: Any] ?? [:]
        XCTAssertEqual(control["capable"] as? Bool, true)
        XCTAssertEqual(detail["screenshots"] as? Bool, area == .screen, "the simulated phone sends screenshots: Slower mode")

        let sink = CountingSink()
        let pump = FramePump(client: here.core, area: area, deviceID: device, stream: started.id, sink: sink)
        pumps.append(pump)
        pump.start()
        let deadline = Date().addingTimeInterval(20)
        while sink.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThanOrEqual(sink.count, 2, "VideoToolbox decoded the \(area) stream's frames")

        _ = try command(here, area, device, ["op": "control_begin"])
        _ = try here.log.wait("\(area) control active") {
            $0.kind == area.eventKind && $0.name == "control" && (json($0)["phase"] as? String) == "active" ? true : nil
        }
        return started.id
    }

    private func waitInput(_ other: Peer, _ area: PhoneArea, op: String) throws {
        _ = try other.log.wait("\(op) at the simulated side") {
            $0.kind == area.eventKind && $0.name == "sim_input" && (json($0)["op"] as? String) == op ? true : nil
        }
    }

    func testAPhonesScreenIsShownAndControlled() throws {
        let here = try start("Test iPhone"), phone = try start("Test phone")
        try phone.core.simulatePhoneForTests(true)
        try pair(here, phone)
        _ = try showAndControl(.screen, here: here, other: phone)
        let device = phone.core.deviceID
        for c in [ScreenCommands.touch(contact: 0, phase: "down", at: CGPoint(x: 0.5, y: 0.5)),
                  ScreenCommands.touch(contact: 0, phase: "up", at: CGPoint(x: 0.5, y: 0.5))] {
            XCTAssertEqual(try command(here, .screen, device, c)["taken"] as? Bool, true)
        }
        try waitInput(phone, .screen, op: "touch")
        _ = try command(here, .screen, device, ScreenCommands.typed("hi")[0])
        try waitInput(phone, .screen, op: "text")
        _ = try command(here, .screen, device, ["op": "stop"])
        _ = try phone.log.wait("the phone hears Stop") { $0.kind == .screen && $0.name == "sim_stop" ? true : nil }
    }

    func testAMacsScreenIsShownAndControlled() throws {
        let here = try start("Test iPhone"), mac = try start("Test Mac")
        try mac.core.simulatePhoneForTests(true)
        try pair(here, mac)
        _ = try showAndControl(.display, here: here, other: mac)
        let device = mac.core.deviceID
        for c in ScreenCommands.click(at: CGPoint(x: 0.25, y: 0.75)) {
            XCTAssertEqual(try command(here, .display, device, c)["taken"] as? Bool, true)
        }
        try waitInput(mac, .display, op: "button")
        _ = try command(here, .display, device, ScreenCommands.scroll(dx: 0, dy: -40, at: CGPoint(x: 0.5, y: 0.5)))
        try waitInput(mac, .display, op: "scroll")
        _ = try command(here, .display, device, ScreenCommands.press("enter"))
        try waitInput(mac, .display, op: "key")
        // A Mac never takes a phone's touches.
        XCTAssertEqual(here.core.phone(.display, deviceID: device, command: ScreenCommands.touch(contact: 0, phase: "down", at: .zero))["error"] as? String, "unsupported")
        _ = try command(here, .display, device, ["op": "stop", "reason": "left_screen"])
        _ = try mac.log.wait("the Mac hears Stop") { $0.kind == .display && $0.name == "sim_stop" ? true : nil }
    }
}
