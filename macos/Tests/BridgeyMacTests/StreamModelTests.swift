import Foundation
import XCTest
@testable import BridgeyMac

final class StreamModelTests: XCTestCase {
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"
    private let newID = "33333333-3333-3333-3333-333333333333"

    private func peer(_ id: String?, _ name: String, host: String? = "10.0.0.2") -> DiscoveredPeer {
        DiscoveredPeer(serviceName: name, deviceIDHint: id, deviceNameHint: name, platformHint: "android",
                       protocolVersionHint: 1, host: host, port: host == nil ? nil : 4000)
    }

    func testRingsShowConnectedNearbyOfflineAndNewInReadingOrder() {
        let trusted = [
            TrustedDeviceInfo(id: tabletID, name: "Pixel Tablet"),
            TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"),
            TrustedDeviceInfo(id: "44444444-4444-4444-4444-444444444444", name: "Old Phone"),
        ]
        let peers = [peer(newID, "Galaxy"), peer(tabletID, "Pixel Tablet"), peer(phoneID, "OnePlus 11")]
        let rings = deviceRings(trusted: trusted, peers: peers, state: .connected(deviceID: phoneID, peerName: "OnePlus 11"))
        XCTAssertEqual(rings.map(\.name), ["OnePlus 11", "Pixel Tablet", "Old Phone", "Galaxy"])
        XCTAssertEqual(rings.map(\.state), [.connected, .nearby, .offline, .nearby])
        XCTAssertEqual(rings.map(\.trusted), [true, true, true, false])
        XCTAssertTrue(rings[1].canConnect)
        XCTAssertFalse(rings[2].canConnect)
        XCTAssertEqual(ringStatusText(rings[3]), "New device")
        XCTAssertEqual(ringStatusText(rings[1]), "Nearby")
        XCTAssertEqual(ringStatusText(rings[2]), "Offline")
        XCTAssertFalse(rings.contains { $0.state == .relay || $0.state == .privateNetwork }, "no relay or private network states without those routes")
    }

    func testRingsShowConnectingAndAnUntrustedConnectedPeer() {
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
        let connecting = deviceRings(trusted: trusted, peers: [peer(phoneID, "OnePlus 11")], state: .connecting("OnePlus 11"))
        XCTAssertEqual(connecting.map(\.state), [.connecting])
        let verifying = deviceRings(trusted: [], peers: [peer(newID, "Galaxy")], state: .verification(peerName: "Galaxy", code: "123456"))
        XCTAssertEqual(verifying.map(\.state), [.connecting])
        let fresh = deviceRings(trusted: [], peers: [], state: .connected(deviceID: newID, peerName: "Galaxy"))
        XCTAssertEqual(fresh.map(\.name), ["Galaxy"])
        XCTAssertEqual(fresh.map(\.state), [.connected])
        XCTAssertTrue(deviceRings(trusted: [], peers: [], state: .idle).isEmpty)
    }

    func testPeersWithoutAddressesCannotConnect() {
        let rings = deviceRings(trusted: [], peers: [peer(newID, "Galaxy", host: nil)], state: .idle)
        XCTAssertFalse(rings[0].canConnect)
    }

    func testLiveTransfersAreRunningOrRetryableNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000)
        let transfers = [
            "a": FileTransferRow(id: "a", name: "a.pdf", status: "Sending", active: true, startedAt: base),
            "b": FileTransferRow(id: "b", name: "b.pdf", status: "File transfer failed", active: false, startedAt: base.addingTimeInterval(5), retryable: true),
            "c": FileTransferRow(id: "c", name: "c.pdf", status: "c.pdf saved on Android", active: false, startedAt: base.addingTimeInterval(9)),
        ]
        XCTAssertEqual(liveTransfers(transfers).map(\.id), ["b", "a"])
    }

    func testTransferDetailDropsTheRepeatedFileName() {
        func row(_ status: String) -> FileTransferRow { FileTransferRow(id: "t", name: "a.zip", status: status, active: true) }
        XCTAssertEqual(transferDetail(row("Sending a.zip: 42% (1 MB of 2 MB)")), "Sending, 42% (1 MB of 2 MB)")
        XCTAssertEqual(transferDetail(row("Receiving a.zip: 10%")), "Receiving, 10%")
        XCTAssertEqual(transferDetail(row("Sending a.zip\u{2026}")), "Sending\u{2026}")
        XCTAssertEqual(transferDetail(row("Waiting for Android\u{2026}")), "Waiting for Android\u{2026}")
    }

    func testTitlesMatchTheDesignCopy() {
        let now = Date()
        func item(_ kind: ActivityKind, preview: String? = nil, app: String? = nil, file: String? = nil, count: Int = 1, automatic: Bool = false) -> ActivityItem {
            ActivityItem(id: 1, kind: kind, deviceID: "d", deviceName: "OnePlus 11", fileName: file, preview: preview, appName: app,
                         sensitive: false, automatic: automatic, count: count, at: now)
        }
        XCTAssertEqual(ActivityText.title(item(.clipboardReceived, preview: "x"), showPreviews: true), "Copied text from OnePlus 11")
        XCTAssertEqual(ActivityText.detail(item(.clipboardReceived, preview: "Room 2 at 4"), showPreviews: true), "\u{201C}Room 2 at 4\u{201D}")
        XCTAssertEqual(ActivityText.detail(item(.clipboardSent, preview: "Hi", automatic: true), showPreviews: true), "Automatic \u{00B7} \u{201C}Hi\u{201D}")
        XCTAssertEqual(ActivityText.detail(item(.clipboardSent, preview: "Hi", automatic: true), showPreviews: false), "Automatic")
        XCTAssertNil(ActivityText.detail(item(.clipboardSent, preview: "Hi"), showPreviews: false))
        XCTAssertEqual(ActivityText.title(item(.callShown, preview: "Mum"), showPreviews: true), "Call from Mum")
        XCTAssertEqual(ActivityText.title(item(.callShown, count: 3), showPreviews: true), "3 calls")
        XCTAssertEqual(ActivityText.title(item(.fileSent, file: "invoice-oct.pdf"), showPreviews: true), "invoice-oct.pdf sent")
        XCTAssertEqual(ActivityText.title(item(.notificationsShown, app: "WhatsApp", count: 4), showPreviews: true), "4 WhatsApp alerts")
        XCTAssertEqual(ActivityText.title(item(.notificationsShown, app: "WhatsApp", count: 4), showPreviews: false), "4 alerts")
        XCTAssertEqual(ActivityText.title(item(.linkReceived), showPreviews: true), "Link from OnePlus 11")
        XCTAssertEqual(ActivityText.title(item(.findMac), showPreviews: true), "OnePlus 11 rang this Mac")
        XCTAssertEqual(ActivityText.time(now.addingTimeInterval(-20), now: now, section: .today), "Now")
    }
}
