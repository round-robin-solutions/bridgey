import AppKit
import Foundation
import XCTest
@testable import BridgeyMac

/// LAN first (lan_first_draft1): the tier table, the upgrade schedule and what connect.addresses may offer. Android
/// runs the same table: both ends must classify one session alike.
final class LanFirstTests: XCTestCase {
    func testTierTable() {
        for host in ["10.0.0.4", "172.16.0.1", "172.31.255.254", "192.168.29.7", "169.254.10.1", "127.0.0.1",
                     "fe80::1", "fe80::1%en0", "[fe80::aa:bb]", "fd12:3456::1", "fc00::5", "::1", "::ffff:192.168.1.5"] {
            XCTAssertEqual(sessionTier(tunnel: false, remoteHost: host), .lan, host)
        }
        for host in ["100.101.102.103", "100.64.0.1", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::5", "8.8.8.8", "172.32.0.1",
                     "192.169.0.1", "11.0.0.1", "2405:201:4043:a872::1", "::ffff:100.101.1.2", "::ffff:8.8.8.8",
                     "work-mac.local", "not an address", ""] {
            XCTAssertEqual(sessionTier(tunnel: false, remoteHost: host), .socket, host)
        }
        XCTAssertEqual(sessionTier(tunnel: false, remoteHost: nil), .socket)
        XCTAssertEqual(sessionTier(tunnel: true, remoteHost: "192.168.29.7"), .tunnel, "whatever the tunnel's route")
        XCTAssertEqual(sessionTier(tunnel: true, remoteHost: "127.0.0.1"), .tunnel, "the loopback bridge of a tunnel")
        XCTAssertLessThan(SessionTier.tunnel, .socket)
        XCTAssertLessThan(SessionTier.socket, .lan)
    }

    // MARK: Remembered peers (lan_first_draft2)

    func testMemoryNeedsBothKeysAndForgetsADowngrade() throws {
        let suite = "bridgey.tests.lanFirstMemory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func payload(_ features: String) -> Data { Data(#"{"version":1,"features":{\#(features)}}"#.utf8) }
        XCTAssertTrue(LanFirstMemory.advertises(payload(#""lan_first_draft1":true,"lan_first_draft2":true"#)))
        XCTAssertFalse(LanFirstMemory.advertises(payload(#""lan_first_draft1":true"#)), "Beta 2 to 4")
        XCTAssertFalse(LanFirstMemory.advertises(payload(#""lan_first_draft2":true"#)), "never without the first key")
        XCTAssertFalse(LanFirstMemory.advertises(payload(#""lan_first_draft1":true,"lan_first_draft2":"true""#)))
        XCTAssertFalse(knownDraftFeatureKeys.contains(lanFirstDraft2FeatureKey), "read outside the golden vectors' list")

        let memory = LanFirstMemory(defaults: defaults)
        XCTAssertFalse(memory.remembers("Phone-A"))
        memory.record("Phone-A", advertised: true)
        XCTAssertTrue(memory.remembers("phone-a"))
        XCTAssertFalse(memory.remembers("Phone-B"))
        // Kept across launches: a new instance on the same preferences still remembers.
        XCTAssertTrue(LanFirstMemory(defaults: defaults).remembers("Phone-A"))
        memory.record("Phone-A", advertised: false)
        XCTAssertFalse(memory.remembers("Phone-A"), "a features.update without the keys forgets at once")
        memory.record("Phone-A", advertised: true)
        memory.remove("PHONE-A")
        XCTAssertFalse(memory.remembers("Phone-A"), "Forget")
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(LanFirstMemory.prefix) })
    }

    // MARK: Upgrade schedule

    private let lan = LanUpgradeAddress(host: "192.168.29.7", port: 42458, origin: "bonjour")
    private let learned = LanUpgradeAddress(host: "192.168.29.8", port: 42458, origin: "learned")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ tier: SessionTier = .tunnel, supports: Bool = true, transfer: Bool = false,
                           addresses: [LanUpgradeAddress]? = nil, id: String = "mac") -> LanUpgradeCandidate {
        LanUpgradeCandidate(deviceID: id, tier: tier, peerSupports: supports, activeTransfer: transfer, addresses: addresses ?? [lan])
    }

    func testDialsAtOnceWhenTheTierIsBelowLanAndAnAddressExists() {
        let scheduler = LanUpgradeScheduler()
        scheduler.networkChanged("home")
        let plan = scheduler.evaluate([candidate()], now: start)
        XCTAssertEqual(plan.decisions, [.dial(deviceID: "mac", address: lan)])
        XCTAssertTrue(scheduler.isDialing("mac"))
        XCTAssertEqual(scheduler.evaluate([candidate()], now: start.addingTimeInterval(1)).decisions, [], "one dial in flight per device")
        XCTAssertEqual(scheduler.evaluate([candidate(.socket)], now: start.addingTimeInterval(2)).decisions, [])
    }

    func testNoDialWithoutTheKeyAnAddressOrBelowLan() {
        let scheduler = LanUpgradeScheduler()
        XCTAssertEqual(scheduler.evaluate([candidate(supports: false)], now: start).decisions, [])
        XCTAssertEqual(scheduler.evaluate([candidate(addresses: [])], now: start).decisions, [])
        XCTAssertEqual(scheduler.evaluate([candidate(.lan)], now: start).decisions, [], "already on the LAN")
        XCTAssertEqual(scheduler.evaluate([candidate(.socket)], now: start).decisions, [.dial(deviceID: "mac", address: lan)],
                       "a VPN session moves to the LAN too")
    }

    func testNeverDuringATransferAndAtOnceWhenItEnds() {
        let scheduler = LanUpgradeScheduler()
        let held = scheduler.evaluate([candidate(transfer: true)], now: start)
        XCTAssertEqual(held.decisions, [.skippedTransfer(deviceID: "mac")])
        XCTAssertEqual(held.wakeAt, start.addingTimeInterval(LanUpgradePolicy.transferRecheck), "looks again soon")
        XCTAssertEqual(scheduler.evaluate([candidate(transfer: true)], now: start.addingTimeInterval(2)).decisions, [], "reported once")
        XCTAssertEqual(scheduler.evaluate([candidate()], now: start.addingTimeInterval(4)).decisions, [.dial(deviceID: "mac", address: lan)])
    }

    func testBacksOffEvery30SecondsThenEvery5MinutesUntilTheNetworkChanges() {
        let scheduler = LanUpgradeScheduler()
        scheduler.networkChanged("home")
        var now = start
        let both = [lan, learned]
        for failure in 1...3 {
            let plan = scheduler.evaluate([candidate(addresses: both)], now: now)
            XCTAssertEqual(plan.decisions, [.dial(deviceID: "mac", address: both[(failure - 1) % 2])], "rotates through the addresses")
            scheduler.dialEnded("mac", won: false, now: now)
            let wait = failure < 3 ? LanUpgradePolicy.retryInterval : LanUpgradePolicy.slowInterval
            let early = scheduler.evaluate([candidate(addresses: both)], now: now.addingTimeInterval(wait - 1))
            XCTAssertEqual(early.decisions, [], "failure \(failure)")
            XCTAssertEqual(early.wakeAt, now.addingTimeInterval(wait))
            now = now.addingTimeInterval(wait)
        }
        XCTAssertEqual(scheduler.evaluate([candidate()], now: now).decisions.count, 1, "every 5 minutes")
        scheduler.dialEnded("mac", won: false, now: now)
        // A transfer that starts and ends does not bring back the fast retries on a network that keeps failing.
        _ = scheduler.evaluate([candidate(transfer: true)], now: now.addingTimeInterval(10))
        XCTAssertEqual(scheduler.evaluate([candidate()], now: now.addingTimeInterval(20)).decisions, [])
        scheduler.networkChanged("office")
        XCTAssertEqual(scheduler.evaluate([candidate()], now: now.addingTimeInterval(21)).decisions, [.dial(deviceID: "mac", address: lan)],
                       "a new network starts afresh")
    }

    func testStopsOnceOnTheLanAndStartsAfreshNextTime() {
        let scheduler = LanUpgradeScheduler()
        _ = scheduler.evaluate([candidate()], now: start)
        scheduler.dialEnded("mac", won: false, now: start)
        _ = scheduler.evaluate([candidate()], now: start.addingTimeInterval(30))
        scheduler.dialEnded("mac", won: true, now: start.addingTimeInterval(31))
        let onLan = scheduler.evaluate([candidate(.lan)], now: start.addingTimeInterval(32))
        XCTAssertEqual(onLan.decisions, [])
        XCTAssertNil(onLan.wakeAt, "nothing left to do")
        // Left home and came back over the tunnel: the first dial is at once again.
        XCTAssertEqual(scheduler.evaluate([candidate()], now: start.addingTimeInterval(600)).decisions, [.dial(deviceID: "mac", address: lan)])
    }

    func testDiscoverySeeingTheDeviceTriesAtOnce() {
        let scheduler = LanUpgradeScheduler()
        XCTAssertEqual(scheduler.evaluate([candidate(addresses: [])], now: start).decisions, [])
        XCTAssertEqual(scheduler.evaluate([candidate()], now: start.addingTimeInterval(3)).decisions, [.dial(deviceID: "mac", address: lan)])
    }

    func testADialThatNeverEndsCountsAsFailed() {
        let scheduler = LanUpgradeScheduler()
        _ = scheduler.evaluate([candidate()], now: start)
        let later = start.addingTimeInterval(LanUpgradePolicy.dialGiveUp)
        XCTAssertEqual(scheduler.evaluate([candidate()], now: later).decisions, [])
        XCTAssertFalse(scheduler.isDialing("mac"))
        XCTAssertEqual(scheduler.evaluate([candidate()], now: later.addingTimeInterval(LanUpgradePolicy.retryInterval)).decisions.count, 1)
    }

    func testDevicesAreIndependent() {
        let scheduler = LanUpgradeScheduler()
        let plan = scheduler.evaluate([candidate(id: "a"), candidate(transfer: true, id: "b"), candidate(.lan, id: "c")], now: start)
        XCTAssertEqual(plan.decisions, [.dial(deviceID: "a", address: lan), .skippedTransfer(deviceID: "b")])
    }

    // MARK: connect.addresses

    func testVirtualInterfacesAreNotOfferedAsTheLan() {
        let lanAddress = ConnectAddress(a: "192.168.29.5", kind: "lan", vpn: nil)
        XCTAssertFalse(isVirtualLanAddress(lanAddress, interface: "en0"))
        XCTAssertFalse(isVirtualLanAddress(lanAddress, interface: "bridge0"), "Thunderbolt Bridge is a real link")
        XCTAssertFalse(isVirtualLanAddress(lanAddress, interface: nil))
        for name in ["bridge100", "bridge101", "vmnet8", "utun4", "docker0", "vboxnet0"] {
            XCTAssertTrue(isVirtualLanAddress(lanAddress, interface: name), name)
        }
        XCTAssertTrue(isVirtualLanAddress(ConnectAddress(a: "192.168.139.3", kind: "lan", vpn: nil), interface: "en7"), "OrbStack")
        XCTAssertTrue(isVirtualLanAddress(ConnectAddress(a: "192.168.215.0", kind: "lan", vpn: nil), interface: nil), "OrbStack")
        XCTAssertFalse(isVirtualLanAddress(ConnectAddress(a: "100.101.1.2", kind: "vpn", vpn: "tailscale"), interface: "utun4"),
                       "VPN addresses stay: they are the tunnel's VPN route")
        XCTAssertFalse(isVirtualLanAddress(ConnectAddress(a: "2405:201::1", kind: "public6", vpn: nil), interface: "en0"))
    }

    func testLocalInterfaceNamesIncludeLoopback() {
        XCTAssertEqual(localInterfaceNames()["127.0.0.1"]?.hasPrefix("lo"), true)
    }

    // MARK: Active transfers

    func testAnyTransferCounts() {
        XCTAssertFalse(DeviceTransferActivity().isActive)
        XCTAssertTrue(DeviceTransferActivity(files: true).isActive)
        XCTAssertTrue(DeviceTransferActivity(folders: true).isActive)
        XCTAssertTrue(DeviceTransferActivity(phoneFiles: true).isActive)
        XCTAssertTrue(DeviceTransferActivity(clipboard: true).isActive)
        XCTAssertTrue(DeviceTransferActivity(speedTest: true).isActive)
    }

    @MainActor func testClipboardTransfersCountForTheirDeviceOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lanfirst-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ClipboardCache(root: root)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bridgey-lanfirst-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let inbox = ClipboardInbox(cache: cache, pasteboard: pasteboard)
        inbox.transport = ClipboardInboxTransport(isConnected: { true }, sendFetch: { _ in true })
        let item = ClipboardOfferItem(index: 0, kind: .image, mime: "image/png", name: nil, size: 100, sha256: nil, inline: nil)
        let clip = ClipboardOffer(offerId: UUID().uuidString.lowercased(), createdAt: 1, sensitive: nil, items: [item])
        inbox.accept(clip, deviceID: "mac", peerName: "Work Mac")
        XCTAssertFalse(inbox.hasTransfer(from: "mac"))
        let id = UUID().uuidString.lowercased()
        XCTAssertTrue(inbox.handleTransferOffer(ClipboardTransferOffer(transferId: id, name: "image.png", mimeType: "image/png", size: 100,
                                                                       sha256: nil, offerId: clip.offerId, index: 0), outerTransferID: id))
        XCTAssertTrue(inbox.hasTransfer(from: "mac"), "an eager push")
        XCTAssertFalse(inbox.hasTransfer(from: "phone"))
        inbox.handleCancel(transferID: id)
        XCTAssertFalse(inbox.hasTransfer(from: "mac"))

        let outbox = ClipboardOutbox(cache: cache)
        outbox.available = { true }
        outbox.pasteboardChangeCount = { 1 }
        outbox.transport = ClipboardOutboxTransport(isConnected: { _ in true }, sendEncrypted: { _, _, _, _ in true })
        let image = ClipboardImageClip(data: Data(repeating: 3, count: 40_000), mime: "image/png")
        let (draft, sources) = try XCTUnwrap(ClipboardOfferBuilder.images([image], cache: cache))
        outbox.begin(offer: draft, sources: sources, changeCount: 1, deviceID: "phone")
        XCTAssertFalse(outbox.hasTransfer(for: "phone"))
        let fetch = ClipboardFetchPayload(offerId: draft.offerId, index: 0, transferId: UUID().uuidString.lowercased())
        outbox.handleFetch(fetch, from: "phone")
        XCTAssertTrue(outbox.hasTransfer(for: "phone"))
        XCTAssertFalse(outbox.hasTransfer(for: "mac"))
        outbox.handleCancel(fetch.transferId)
        XCTAssertFalse(outbox.hasTransfer(for: "phone"))
    }
}
