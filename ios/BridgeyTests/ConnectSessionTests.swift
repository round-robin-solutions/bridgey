@testable import Bridgey
import XCTest

/// Connect away from home runs on iOS: the core's node starts in the simulator, two clients set up a pair secret
/// over their session (connect.setup) and learn each other's addresses (connect.addresses), with no control service,
/// so nothing leaves this Mac. Tunnels themselves, with the local network cut, are covered by
/// `cargo test -p bridgey-client --test connect` (the switch that cuts it is not in the C ABI).
final class ConnectSessionTests: XCTestCase {
    typealias Log = CoreBridgeTests.Log

    private var cores: [BridgeyCore] = []

    override func tearDown() {
        for core in cores {
            try? core.setConnect(false, controlURL: nil)
            core.stop()
        }
        cores = []
    }

    private func start(_ name: String) throws -> (BridgeyCore, Log, UInt16) {
        let log = Log()
        var options = CoreOptions(deviceName: name)
        options.port = CoreBridgeTests.freePort()
        let core = try BridgeyCore.start(options, store: MemorySecretStore()) { [log] e in log.add(e) }
        try core.setFeature(deviceID: nil, key: "clipboard", on: true)
        cores.append(core)
        return (core, log, options.port)
    }

    func testTheNodeRunsAndDevicesSetUpConnectAwayFromHome() throws {
        let (a, logA, _) = try start("Test iPhone")
        let (b, logB, portB) = try start("Test Mac")
        // Learned addresses only: no control service is named, so the node never dials out.
        try a.setConnect(true, controlURL: nil)
        try b.setConnect(true, controlURL: nil)
        XCTAssertEqual(try logA.wait("this device's state") { $0.kind == .connectState ? $0.text : nil }, "disabled")
        XCTAssertEqual(try a.snapshot().connect?.state, "disabled")

        try b.allowPairing(seconds: 120)
        let pairing = try a.pair(deviceID: nil, host: "127.0.0.1", port: portB)
        _ = try logA.wait("code on A") { $0.kind == .pairingCode && $0.id == pairing ? true : nil }
        let codeB = try logB.wait("code on B") { $0.kind == .pairingCode ? $0.id : nil }
        try a.confirmPairing(pairing, accept: true)
        try b.confirmPairing(codeB, accept: true)

        // Each shows the other connect_draft1 while its node runs.
        _ = try logA.wait("B's map shows Connect away from home") { $0.kind == .features && ($0.extra ?? "").contains(#""connect_draft1":true"#) ? true : nil }
        _ = try logB.wait("A's map shows Connect away from home") { $0.kind == .features && ($0.extra ?? "").contains(#""connect_draft1":true"#) ? true : nil }

        // connect.setup over the session: both keep a pair secret for the other.
        let deadline = Date().addingTimeInterval(20)
        while !(try a.snapshot().devices.first?.away == true && b.snapshot().devices.first?.away == true) {
            XCTAssertLessThan(Date(), deadline, "the pair secret was not set up")
            if Date() >= deadline { return }
            Thread.sleep(forTimeInterval: 0.2)
        }

        try a.setConnect(false, controlURL: nil)
        XCTAssertEqual(try a.snapshot().connect?.state, "off")
    }
}
