import XCTest
@testable import BridgeyMac

/// Pairing over the tailnet (docs/mesh-and-codes.md, phase 2): what is listed, what is dialled, and a server paired
/// this way getting nothing on this Mac.
final class TailnetPairingTests: XCTestCase {
    private let status = Data("""
    {"BackendState":"Running","Self":{"HostName":"personal","TailscaleIPs":["100.77.183.42"]},"Peer":{
     "a":{"HostName":"contabo-europe","DNSName":"contabo-europe.tail1234.ts.net.","TailscaleIPs":["100.121.85.33","fd7a:115c:a1e0::a033:5522"],"OS":"linux","Online":true},
     "b":{"HostName":"work","DNSName":"work.tail1234.ts.net.","TailscaleIPs":["100.90.0.3"],"OS":"macOS","Online":true},
     "c":{"HostName":"OnePlus 11 5G","DNSName":"oneplus-11-5g.tail1234.ts.net.","TailscaleIPs":["100.80.1.2"],"OS":"android","Online":false},
     "d":{"HostName":"elsewhere","TailscaleIPs":["8.8.8.8"],"Online":true}}}
    """.utf8)

    func testTailnetRanges() {
        XCTAssertTrue(TailnetStatus.isTailnet("100.64.0.1"))
        XCTAssertTrue(TailnetStatus.isTailnet("100.127.255.254"))
        XCTAssertFalse(TailnetStatus.isTailnet("100.128.0.1"))
        XCTAssertFalse(TailnetStatus.isTailnet("192.168.1.10"))
        XCTAssertTrue(TailnetStatus.isTailnet("fd7a:115c:a1e0::a033:5522"))
        XCTAssertFalse(TailnetStatus.isTailnet("fd7a:115c:a1e1::1"))
        XCTAssertFalse(TailnetStatus.isTailnet("not an address"))
    }

    func testStatusIsParsedOnlineFirstWithoutOutsideAddresses() {
        let peers = TailnetStatus.parse(status)
        XCTAssertEqual(peers.map(\.name), ["contabo-europe", "work", "OnePlus 11 5G"])
        XCTAssertEqual(peers.first?.address, "100.121.85.33", "IPv4 first")
        XCTAssertEqual(TailnetStatus.find(peers, name: "Work")?.address, "100.90.0.3")
        XCTAssertEqual(TailnetStatus.find(peers, name: "contabo-europe.tail1234.ts.net")?.name, "contabo-europe")
        XCTAssertEqual(TailnetStatus.find(peers, name: "oneplus-11-5g")?.os, "android")
        XCTAssertTrue(TailnetStatus.parse(Data(#"{"BackendState":"Stopped","Peer":{}}"#.utf8)).isEmpty)
        XCTAssertTrue(TailnetStatus.isTailnet("::ffff:100.90.0.3"))
        let twins = TailnetStatus.parse(Data(#"{"Peer":{"a":{"HostName":"twin","TailscaleIPs":["100.90.0.4"],"Online":true},"b":{"HostName":"twin","TailscaleIPs":["100.90.0.5"],"Online":true}}}"#.utf8))
        XCTAssertNil(TailnetStatus.find(twins, name: "twin"), "a name two peers answer to dials neither")
    }

    /// Only online peers that answered on Bridgey's port are listed, and none already known for a trusted device.
    func testOnlyAnsweringUnknownPeersAreListed() {
        let peers = TailnetStatus.parse(status)
        let listed = TailnetStatus.discovered(peers, answering: ["100.121.85.33", "100.90.0.3", "100.80.1.2"], known: ["100.90.0.3"], port: 42458)
        XCTAssertEqual(listed.map(\.deviceNameHint), ["contabo-europe"])
        XCTAssertEqual(listed.first?.host, "100.121.85.33")
        XCTAssertEqual(listed.first?.port, 42458)
        XCTAssertEqual(listed.first?.tailnet, true)
        XCTAssertNil(listed.first?.deviceIDHint, "nothing about it is trusted before the pairing")
        let ring = DeviceRing(id: "peer:x", deviceID: nil, name: "contabo-europe", state: .nearby, trusted: false, platform: nil, peer: listed.first)
        XCTAssertEqual(ringStatusText(ring), "On your tailnet")
        XCTAssertTrue(ring.canConnect)
    }

    /// A server marks itself in its own map; a phone's map to a Mac never carries these keys.
    func testAServerIsAnAgentAndMaySendOnlyTheSession() {
        XCTAssertTrue(AgentPeerRules.isAgent([agentFeatureKey: true, agentNotifyFeatureKey: true, agentAskFeatureKey: true]))
        XCTAssertFalse(AgentPeerRules.isAgent([agentFeatureKey: true]))
        XCTAssertFalse(AgentPeerRules.isAgent([agentsMirrorFeatureKey: true, smsCodesFeatureKey: true]))
        for kind in ["heartbeat.ping", "features.update", "connect.setup", "connect.addresses", "pairing.confirm"] {
            XCTAssertTrue(AgentPeerRules.macAccepts(kind), kind)
        }
        for kind in ["clipboard.update", "files.offer", "notifications.post", "quick.request", "notify.post", "updates.start", "settings.update", "actions.run"] {
            XCTAssertFalse(AgentPeerRules.macAccepts(kind), kind)
        }
    }

    /// Every feature reads off for a server paired with this Mac, whatever the switches say.
    @MainActor
    func testEverythingIsOffForAServer() {
        let settings = BridgeySettings()
        let id = UUID().uuidString.lowercased()
        defer { settings.removeDevice(id) }
        settings.markAgent(id)
        XCTAssertTrue(settings.isAgent(id))
        for feature in BridgeyFeature.allCases {
            XCTAssertFalse(settings.isEnabled(feature, for: id), feature.rawValue)
        }
        settings.unmarkAgent(id)
        XCTAssertFalse(settings.isAgent(id), "Trust as my device lifts it")
        settings.markAgent(id)
        settings.removeDevice(id)
        XCTAssertFalse(settings.isAgent(id))
    }
}
