import XCTest
@testable import BridgeyMac

final class ConnectionHealthTests: XCTestCase {
    func testRouteClasses() {
        for host in ["192.168.1.20", "10.0.0.2", "172.16.4.1", "172.31.255.1", "169.254.3.4", "fe80::1%en0", "fd12:3456::1", "Pixel.local", "::ffff:192.168.1.9"] {
            XCTAssertEqual(connectionRoute(forHost: host), .sameNetwork, host)
        }
        for host in ["100.64.0.1", "100.101.102.103", "100.127.255.254", "fd7a:115c:a1e0::1234", "[fd7a:115c:a1e0:ab12::1]"] {
            XCTAssertEqual(connectionRoute(forHost: host), .privateNetwork, host)
        }
        for host in ["8.8.8.8", "100.128.0.1", "172.32.0.1", "2001:db8::1"] {
            XCTAssertEqual(connectionRoute(forHost: host), .otherNetwork, host)
        }
        XCTAssertEqual(connectionRoute(forHost: nil), .unknown)
        XCTAssertEqual(connectionRoute(forHost: "example.com"), .unknown)
    }

    func testRoundTripsComeOnlyFromOurPings() {
        var trips = HeartbeatRoundTrips()
        let start = Date(timeIntervalSince1970: 100)
        trips.sent("a", at: start)
        XCTAssertNil(trips.received("someone-else", at: start.addingTimeInterval(0.1)))
        XCTAssertNil(trips.received(nil, at: start))
        XCTAssertEqual(trips.received("a", at: start.addingTimeInterval(0.012))!, 0.012, accuracy: 0.0001)
        XCTAssertNil(trips.received("a", at: start.addingTimeInterval(0.5)), "a pong counts once")
        for (index, ms) in [30, 10, 20].enumerated() {
            trips.sent("p\(index)", at: start)
            trips.received("p\(index)", at: start.addingTimeInterval(Double(ms) / 1000))
        }
        XCTAssertEqual(trips.last!, 0.020, accuracy: 0.0001)
        XCTAssertEqual(trips.median!, 0.016, accuracy: 0.0001)
        for index in 0..<20 {
            trips.sent("q\(index)", at: start)
            trips.received("q\(index)", at: start.addingTimeInterval(0.001))
        }
        XCTAssertEqual(trips.samples.count, HeartbeatRoundTrips.maximumSamples)
    }

    func testReconnectsCountStartsAgainAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 50))!
        var counter = DailyCounter()
        counter.increment(now: evening, calendar: calendar)
        counter.increment(now: evening, calendar: calendar)
        XCTAssertEqual(counter.value(now: evening, calendar: calendar), 2)
        let morning = evening.addingTimeInterval(20 * 60)
        XCTAssertEqual(counter.value(now: morning, calendar: calendar), 0)
        counter.increment(now: morning, calendar: calendar)
        XCTAssertEqual(counter.value(now: morning, calendar: calendar), 1)
    }

    func testDiagnosticsHoldNoAddressesNamesOrContent() throws {
        var record = DeviceHealthRecord()
        record.connectedSince = Date(timeIntervalSince1970: 1_800_000_000)
        record.route = connectionRoute(forHost: "192.168.1.20")
        record.outbound = true
        record.roundTrips.sent("x", at: Date(timeIntervalSince1970: 1_800_000_010))
        record.roundTrips.received("x", at: Date(timeIntervalSince1970: 1_800_000_010.025))
        record.lastDropReason = healthToken("heartbeat_timeout")
        record.lastDropAt = Date(timeIntervalSince1970: 1_799_999_000)
        record.reconnects.increment(now: Date())
        let snapshot = ConnectionHealthSnapshot(deviceID: "11111111-2222-3333-4444-555555555555", record: record, connected: true,
                                                discoveryVisible: true, discovery: .browsing, now: Date())
        let text = String(data: try JSONSerialization.data(withJSONObject: snapshot.diagnostics(), options: [.sortedKeys]), encoding: .utf8)!
        XCTAssertFalse(text.contains("192.168"), text)
        XCTAssertFalse(text.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil, text)
        XCTAssertFalse(text.contains("OnePlus"), text)
        XCTAssertFalse(text.contains("2222-3333"), "no full device id: \(text)")
        XCTAssertTrue(text.contains("\"route\":\"same_network\""), text)
        XCTAssertTrue(text.contains("\"roundTripMs\":25"), text)
        XCTAssertTrue(text.contains("\"reconnectsToday\":1"), text)
        XCTAssertTrue(text.contains("\"lastDisconnectReason\":\"heartbeat_timeout\""), text)
        XCTAssertEqual(healthToken("Reset by 10.0.0.2 \"OnePlus\""), "reset_by_10_0_0_2__oneplus_", "tokens cannot carry punctuation")
    }

    func testOfflineSnapshotDropsLiveFields() {
        var record = DeviceHealthRecord()
        record.route = .privateNetwork
        record.connectedSince = Date()
        let snapshot = ConnectionHealthSnapshot(deviceID: "a", record: record, connected: false, discoveryVisible: false, discovery: .denied, now: Date())
        XCTAssertEqual(snapshot.route, .unknown)
        XCTAssertNil(snapshot.connectedSince)
        XCTAssertEqual(snapshot.discovery, .denied)
    }
}
