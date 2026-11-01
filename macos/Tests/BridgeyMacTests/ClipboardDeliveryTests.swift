import Foundation
import XCTest
@testable import BridgeyMac

/// One copy, one activity item: per-device acknowledgements, arrivals through two paths, and the words.
final class ClipboardDeliveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func group(_ kind: ActivityKind = .clipboardSent, automatic: Bool = true) -> ClipboardSendGroup {
        ClipboardSendGroup(id: "g1", kind: kind, preview: "hello", sensitive: false, automatic: automatic, summary: nil)
    }

    func testEachDeviceHasItsOwnAcknowledgement() {
        var tracker = ClipboardDeliveryTracker()
        tracker.begin(group())
        tracker.add(messageID: "m-phone", deviceID: "phone", deviceName: "OnePlus 11 5G", to: "g1")
        tracker.add(messageID: "m-mac", deviceID: "mac", deviceName: "MacBook Pro", to: "g1")
        XCTAssertEqual(tracker.groups["g1"]?.peers.map(\.state), [.pending, .pending])

        // The phone answers first; the Mac's answer still counts (the old code only matched the last send).
        let afterPhone = tracker.resolve(messageID: "m-phone", state: .delivered, from: "phone")
        XCTAssertEqual(afterPhone?.peers.map(\.state), [.delivered, .pending])
        XCTAssertFalse(afterPhone!.isSettled)
        let afterMac = tracker.resolve(messageID: "m-mac", state: .delivered, from: "mac")
        XCTAssertEqual(afterMac?.peers.map(\.state), [.delivered, .delivered])
        XCTAssertTrue(afterMac!.isSettled)

        // A repeated or late answer changes nothing.
        XCTAssertNil(tracker.resolve(messageID: "m-phone", state: .failed))
    }

    func testAnAnswerFromAnotherDeviceIsIgnored() {
        var tracker = ClipboardDeliveryTracker()
        tracker.begin(group())
        tracker.add(messageID: "m-phone", deviceID: "phone", deviceName: "OnePlus", to: "g1")
        XCTAssertNil(tracker.resolve(messageID: "m-phone", state: .delivered, from: "mac"))
        XCTAssertTrue(tracker.contains(messageID: "m-phone"))
    }

    func testAnEndedSessionFailsOnlyItsOwnMessages() {
        var tracker = ClipboardDeliveryTracker()
        tracker.begin(group())
        tracker.add(messageID: "a", deviceID: "phone", deviceName: "OnePlus", to: "g1")
        tracker.add(messageID: "b", deviceID: "mac", deviceName: "MacBook Pro", to: "g1")
        let changed = tracker.sessionEnded(deviceID: "mac")
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].peers.map(\.state), [.pending, .failed])
        XCTAssertTrue(tracker.contains(messageID: "a"))
        XCTAssertFalse(tracker.contains(messageID: "b"))
    }

    func testOldGroupsAreDropped() {
        var tracker = ClipboardDeliveryTracker()
        for index in 0..<(ClipboardDeliveryTracker.keptGroups + 2) {
            tracker.begin(ClipboardSendGroup(id: "g\(index)", kind: .clipboardSent, preview: nil, sensitive: false, automatic: true, summary: nil))
            tracker.add(messageID: "m\(index)", deviceID: "phone", deviceName: "OnePlus", to: "g\(index)")
        }
        XCTAssertEqual(tracker.groups.count, ClipboardDeliveryTracker.keptGroups)
        XCTAssertFalse(tracker.contains(messageID: "m0"))
        XCTAssertTrue(tracker.contains(messageID: "m9"))
    }

    // MARK: Arrivals

    func testTheSameClipFromASecondDeviceJoinsTheFirstItem() {
        var arrivals = ClipboardArrivals()
        let phone = ActivityPeer(deviceID: "phone", deviceName: "OnePlus", state: .delivered)
        let mac = ActivityPeer(deviceID: "mac", deviceName: "MacBook Pro", state: .delivered)
        XCTAssertNil(arrivals.match(hash: "h", deviceID: "phone", now: now))
        arrivals.record(hash: "h", activityID: 5, peer: phone, now: now)
        // The same device again is a new copy.
        XCTAssertNil(arrivals.match(hash: "h", deviceID: "phone", now: now.addingTimeInterval(2)))
        // Another device within the minute joins it.
        let match = arrivals.match(hash: "h", deviceID: "mac", now: now.addingTimeInterval(2))
        XCTAssertEqual(match?.activityID, 5)
        XCTAssertEqual(arrivals.add(peer: mac, to: 5)?.map(\.deviceName), ["OnePlus", "MacBook Pro"])
        // Other text, or after the window, is its own item.
        XCTAssertNil(arrivals.match(hash: "other", deviceID: "mac2", now: now))
        XCTAssertNil(arrivals.match(hash: "h", deviceID: "mac2", now: now.addingTimeInterval(ClipboardArrivals.window + 1)))
    }

    @MainActor func testOneCopyIsOneItemThatFollowsEachAnswer() {
        let log = ActivityLog(store: nil) { self.now }
        let peers = [ActivityPeer(deviceID: "phone", deviceName: "OnePlus 11 5G", state: .delivered),
                     ActivityPeer(deviceID: "mac", deviceName: "MacBook Pro", state: .pending)]
        let id = log.record(.clipboardSent, deviceID: "phone", deviceName: "OnePlus 11 5G", preview: "hello", automatic: true,
                            peers: peers, previews: true)
        XCTAssertNotNil(id)
        var delivered = peers
        delivered[1].state = .delivered
        log.updatePeers(id: id!, peers: delivered)
        XCTAssertEqual(log.items.count, 1)
        XCTAssertEqual(ActivityText.title(log.items[0], showPreviews: true), "Copied to OnePlus 11 5G and MacBook Pro")
        XCTAssertEqual(ActivityText.detail(log.items[0], showPreviews: true), "Automatic \u{00B7} \u{201C}hello\u{201D}")
    }

    func testRowWordsShowEachDevicesState() {
        func item(_ kind: ActivityKind, _ peers: [ActivityPeer]?) -> ActivityItem {
            ActivityItem(id: 1, kind: kind, deviceID: "phone", deviceName: "OnePlus", fileName: nil, preview: "hi", appName: nil,
                         sensitive: false, automatic: true, count: 1, at: now, bytes: 10, content: "image", peers: peers)
        }
        let mixed = item(.clipboardSent, [ActivityPeer(deviceID: "a", deviceName: "OnePlus", state: .delivered),
                                          ActivityPeer(deviceID: "b", deviceName: "MacBook Pro", state: .failed),
                                          ActivityPeer(deviceID: "c", deviceName: "Pixel", state: .off),
                                          ActivityPeer(deviceID: "d", deviceName: "Work Mac", state: .pending)])
        XCTAssertEqual(ActivityText.title(mixed, showPreviews: true), "Copied to OnePlus")
        XCTAssertEqual(ActivityText.detail(mixed, showPreviews: true),
                       "Automatic \u{00B7} Waiting for Work Mac \u{00B7} Not delivered to MacBook Pro \u{00B7} Clipboard is off on Pixel \u{00B7} \u{201C}hi\u{201D}")
        // Items from before keep their old words.
        XCTAssertEqual(ActivityText.title(item(.clipboardSent, nil), showPreviews: true), "Clipboard sent to OnePlus")
        let offer = item(.clipOfferSent, [ActivityPeer(deviceID: "a", deviceName: "OnePlus", state: .delivered),
                                          ActivityPeer(deviceID: "b", deviceName: "MacBook Pro", state: .delivered)])
        XCTAssertEqual(ActivityText.detail(offer, showPreviews: true), "Automatic, ready to paste on OnePlus and MacBook Pro")
        let arrival = item(.clipboardReceived, [ActivityPeer(deviceID: "a", deviceName: "OnePlus", state: .delivered),
                                                ActivityPeer(deviceID: "b", deviceName: "MacBook Pro", state: .delivered)])
        XCTAssertEqual(ActivityText.detail(arrival, showPreviews: false), "Automatic \u{00B7} Also came through MacBook Pro")
        XCTAssertEqual(DeviceList.join(["A", "B", "C"]), "A, B and C")
    }

    func testPeersRoundTripAndBadOnesAreDropped() throws {
        let items = ActivityHistory.add([], kind: .clipboardSent, deviceID: "a", deviceName: "OnePlus", preview: "x",
                                        peers: [ActivityPeer(deviceID: "a", deviceName: "OnePlus", state: .delivered)], now: now, nextID: 1)
        XCTAssertEqual(ActivityHistory.decode(try ActivityHistory.encode(items), now: now), items)
        let json = """
        [{"id":1,"kind":"clipboard_sent","deviceName":"A","sensitive":false,"automatic":true,"count":1,"at":\(Int(now.timeIntervalSince1970 * 1000)),
          "peers":[{"deviceID":"a","deviceName":"A","state":"delivered"},{"deviceName":"B","state":"teleported"}]}]
        """
        XCTAssertEqual(ActivityHistory.decode(Data(json.utf8), now: now).first?.peers?.map(\.deviceName), ["A"])
        // Other kinds never keep peers.
        let ping = ActivityHistory.add([], kind: .pingSent, deviceID: "a", deviceName: "A",
                                       peers: [ActivityPeer(deviceID: "a", deviceName: "A", state: .delivered)], now: now, nextID: 1)
        XCTAssertNil(ping[0].peers)
    }

    func testSendBarStatus() {
        var manual = group(automatic: false)
        manual.peers = [ActivityPeer(deviceID: "a", deviceName: "OnePlus", state: .pending)]
        XCTAssertEqual(ClipDeliveryText.status(manual), "Sending\u{2026}")
        manual.peers[0].state = .delivered
        XCTAssertEqual(ClipDeliveryText.status(manual), "Delivered")
        manual.peers[0].state = .failed
        XCTAssertEqual(ClipDeliveryText.status(manual), "No delivery acknowledgement")
        manual.peers[0].state = .off
        XCTAssertEqual(ClipDeliveryText.status(manual), "Clipboard is turned off on OnePlus")

        var automatic = group()
        automatic.peers = [ActivityPeer(deviceID: "a", deviceName: "OnePlus", state: .delivered),
                           ActivityPeer(deviceID: "b", deviceName: "MacBook Pro", state: .pending)]
        XCTAssertNil(ClipDeliveryText.status(automatic))
        automatic.peers[1].state = .failed
        XCTAssertEqual(ClipDeliveryText.status(automatic), "Not delivered to MacBook Pro")
        automatic.peers[1].state = .delivered
        XCTAssertNil(ClipDeliveryText.status(automatic))
        for text in [ClipDeliveryText.status(manual), ClipDeliveryText.status(automatic)].compactMap({ $0 }) {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"))
        }
    }
}
