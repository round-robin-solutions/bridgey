import Foundation
import Network
import XCTest
@testable import BridgeyMac

/// Security review 1.0: any connected paired phone could start a speed test on this Mac at any time, with Files off,
/// and repeat it at once, so the Mac kept sending at full speed (over a relay too).
@MainActor
final class SpeedTestIncomingTests: XCTestCase {
    private final class Link: SpeedTestLink {
        var ready: [(status: String, link: SpeedLink?)] = []
        func sendEncrypted(kind: String, payload: Data) -> Bool {
            if kind == SpeedKind.ready, case let .ready(_, status, link) = SpeedPayload.decode(kind: kind, plaintext: payload) {
                ready.append((status, link))
            }
            return true
        }
        func sendOuter(kind: String, testId: String, sequence: Int64?) {}
        func sendData(testId: String, sequence: Int64, plaintext: Data) -> Bool { true }
        var path: NWPath? { nil }
    }

    private final class Host: SpeedTestHost {
        let link = Link()
        var filesOn = false
        var connected = true
        func speedLink(for phoneID: String) -> SpeedTestLink? { connected ? link : nil }
        var speedPhones: [(id: String, name: String)] { [("phone", "Pixel"), ("other", "Pixel 2")] }
        func speedTestAllowed(from phoneID: String) -> Bool { filesOn }
    }

    private func start(_ test: SpeedTest, from phone: String) throws {
        let link = SpeedLink(platform: "android", network: "wifi", band: nil, linkMbps: nil, standard: nil, widthMhz: nil)
        let payload = try XCTUnwrap(SpeedPayload.start(testId: UUID().uuidString.lowercased(), seconds: 7, link: link).json)
        test.receive(kind: SpeedKind.start, plaintext: payload, testId: nil, sequence: nil, from: phone)
    }

    func testTestsFromAPhoneNeedFilesAndAreLimited() throws {
        let host = Host()
        let test = SpeedTest()
        test.host = host
        var now: TimeInterval = 10_000
        test.clock = { now }
        try start(test, from: "phone")
        XCTAssertEqual(host.link.ready.last?.status, "disabled", "Files off for that phone")
        XCTAssertNil(host.link.ready.last?.link, "nothing about this Mac's network goes with a refusal")
        host.filesOn = true
        // Starts that arrive with no session to answer on do not use up the allowance.
        host.connected = false
        for _ in 0..<10 { try start(test, from: "phone") }
        host.connected = true
        try start(test, from: "phone")
        XCTAssertEqual(host.link.ready.last?.status, "ready")
        test.phoneDisconnected("phone")
        try start(test, from: "phone")
        XCTAssertEqual(host.link.ready.last?.status, "busy", "again at once")
        for _ in 0..<5 {
            now += SpeedLimits.incomingSpacing
            try start(test, from: "phone")
            XCTAssertEqual(host.link.ready.last?.status, "ready")
            test.phoneDisconnected("phone")
        }
        now += SpeedLimits.incomingSpacing
        try start(test, from: "phone")
        XCTAssertEqual(host.link.ready.last?.status, "busy", "six an hour")
        try start(test, from: "other")
        XCTAssertEqual(host.link.ready.last?.status, "ready", "each phone has its own allowance")
        test.phoneDisconnected("other")
        now += 3_600
        try start(test, from: "phone")
        XCTAssertEqual(host.link.ready.last?.status, "ready")
        test.phoneDisconnected("phone")
    }
}
