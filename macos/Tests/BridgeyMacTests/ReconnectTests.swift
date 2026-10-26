import Foundation
import Network
import XCTest
@testable import BridgeyMac

/// A clock the test moves by hand.
final class ManualClock: ReconnectClock {
    private final class Task: ScheduledTask {
        let at: Date
        let action: () -> Void
        var cancelled = false
        init(at: Date, action: @escaping () -> Void) {
            self.at = at
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    var now: Date
    private var tasks: [Task] = []

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = now }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask {
        let task = Task(at: now.addingTimeInterval(max(delay, 0)), action: action)
        tasks.append(task)
        return task
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = tasks.filter({ !$0.cancelled && $0.at <= target }).min(by: { $0.at < $1.at }) {
            now = next.at
            tasks.removeAll { $0 === next }
            next.action()
        }
        now = target
        tasks.removeAll { $0.cancelled }
    }
}

final class MemoryAddressBookStore: AddressBookStore {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

final class ReconnectTests: XCTestCase {
    private let phone = "a1b2c3d4-0000-4000-8000-000000000001"
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let homeLAN = [LocalIPv4Network(address: parseIPv4("192.168.29.148")!, netmask: 0xFFFF_FF00)]

    // MARK: Address book

    func testLearnsInboundAddressPersistsAndPrefersTheMostRecent() {
        let store = MemoryAddressBookStore()
        let book = KnownAddressBook(store: store)
        // The phone dialled in from 192.168.29.40:51234; it listens on 42458.
        XCTAssertTrue(book.learn(phone, host: "192.168.29.40", port: ReconnectPolicy.listeningPort, source: .inbound, at: start))
        book.learn(phone, host: "192.168.29.77", port: 42_458, source: .discovery, at: start.addingTimeInterval(60))
        XCTAssertEqual(book.addresses(for: phone).map(\.host), ["192.168.29.77", "192.168.29.40"])

        // Seen again: it moves to the front.
        book.learn(phone, host: "192.168.29.40", port: 42_458, source: .inbound, at: start.addingTimeInterval(120))
        XCTAssertEqual(book.addresses(for: phone).map(\.host), ["192.168.29.40", "192.168.29.77"])

        // A new instance (an app restart) reads the same book.
        let reloaded = KnownAddressBook(store: store)
        XCTAssertEqual(reloaded.addresses(for: phone), book.addresses(for: phone))
        XCTAssertEqual(reloaded.addresses(for: phone).first?.port, 42_458)
        XCTAssertEqual(reloaded.addresses(for: phone).first?.source, .inbound)
    }

    func testDiscoveryNeverDowngradesAnAuthenticatedAddress() {
        let book = KnownAddressBook(store: MemoryAddressBookStore())
        book.learn(phone, host: "192.168.29.40", port: 42_458, source: .inbound, at: start)
        book.learn(phone, host: "192.168.29.40", port: 42_458, source: .discovery, at: start.addingTimeInterval(5))
        XCTAssertEqual(book.addresses(for: phone).first?.source, .inbound)
        XCTAssertEqual(book.addresses(for: phone).first?.lastSeen, start.addingTimeInterval(5))
    }

    func testSpoofedDiscoveryCannotPushOutTheRealAddress() {
        let book = KnownAddressBook(store: MemoryAddressBookStore(), limit: 3)
        book.learn(phone, host: "192.168.29.40", port: 42_458, source: .inbound, at: start)
        for index in 1...6 {
            book.learn(phone, host: "192.168.29.\(100 + index)", port: 42_458, source: .discovery, at: start.addingTimeInterval(Double(index)))
        }
        let hosts = book.addresses(for: phone).map(\.host)
        XCTAssertEqual(hosts.count, 3)
        XCTAssertTrue(hosts.contains("192.168.29.40"))
    }

    func testOnlyAddressesAreLearned() {
        let book = KnownAddressBook(store: MemoryAddressBookStore())
        XCTAssertTrue(book.learn(phone, host: "::ffff:192.168.29.40", port: 42_458, source: .inbound, at: start))
        XCTAssertEqual(book.addresses(for: phone).first?.host, "192.168.29.40")
        XCTAssertFalse(book.learn(phone, host: "fe80::1%en0", port: 42_458, source: .discovery, at: start))
        XCTAssertFalse(book.learn(phone, host: "evil.example.com", port: 42_458, source: .discovery, at: start))
        XCTAssertFalse(book.learn(phone, host: "192.168.29.40", port: 0, source: .discovery, at: start))
        XCTAssertTrue(book.learn(phone, host: "OnePlus-11.local.", port: 42_458, source: .discovery, at: start))
        XCTAssertEqual(normalizedHost("OnePlus-11.local."), "OnePlus-11.local")
        book.forget(phone)
        XCTAssertTrue(book.addresses(for: phone).isEmpty)
    }

    func testAddressTagsNeverHoldTheFullAddress() {
        XCTAssertEqual(addressTag("192.168.29.40"), "v4.40")
        XCTAssertEqual(addressTag("fd00::1"), "v6")
        XCTAssertEqual(addressTag("OnePlus-11.local"), "name")
    }

    func testOnlyAddressesOnThisNetworkAreDialled() {
        XCTAssertTrue(isDialable("192.168.29.40", on: homeLAN))
        XCTAssertFalse(isDialable("192.168.1.40", on: homeLAN))
        XCTAssertFalse(isDialable("192.168.29.40", on: []))
        XCTAssertTrue(isDialable("OnePlus-11.local", on: homeLAN))
    }

    // MARK: Schedule

    func testScheduleBacksOffThenStretchesAfterTheFirstHour() {
        let schedule = ReconnectSchedule()
        schedule.disconnected(phone, at: start)
        XCTAssertEqual(schedule.entry(phone)?.nextAt, start.addingTimeInterval(2))
        XCTAssertTrue(schedule.due(at: start.addingTimeInterval(1)).isEmpty)
        var now = start.addingTimeInterval(2)
        var gaps: [TimeInterval] = []
        for _ in 0..<6 {
            schedule.attemptStarted(phone, at: now)
            let next = schedule.entry(phone)!.nextAt
            gaps.append(next.timeIntervalSince(now))
            now = next
        }
        XCTAssertEqual(gaps, [5, 15, 30, 60, 60, 60])
        // An hour in, the device has been away for a while: every ten minutes.
        schedule.attemptStarted(phone, at: start.addingTimeInterval(3_700))
        XCTAssertEqual(schedule.entry(phone)!.nextAt, start.addingTimeInterval(3_700 + 600))
        schedule.connected(phone)
        XCTAssertNil(schedule.entry(phone))
    }

    func testWakeOrNetworkChangeResetsTheBackoff() {
        let schedule = ReconnectSchedule()
        schedule.disconnected(phone, at: start)
        for second in [2.0, 7, 22, 52, 112] { schedule.attemptStarted(phone, at: start.addingTimeInterval(second)) }
        let wake = start.addingTimeInterval(5_000)
        schedule.resetAll(at: wake)
        XCTAssertEqual(schedule.due(at: wake), [phone])
        XCTAssertEqual(schedule.entry(phone)?.attempts, 0)
        schedule.attemptStarted(phone, at: wake)
        // The fast phase starts again.
        XCTAssertEqual(schedule.entry(phone)?.nextAt, wake.addingTimeInterval(5))
    }

    // MARK: Debounce

    func testBurstOfEventsBecomesOneRecovery() {
        let clock = ManualClock(now: start)
        var fired: [[String]] = []
        let debouncer = EventDebouncer(clock: clock, quiet: 2, maxWait: 10) { fired.append($0) }
        debouncer.note("wake")
        clock.advance(by: 0.5)
        debouncer.note("screen_wake")
        clock.advance(by: 1)
        debouncer.note("network_change")
        debouncer.note("network_change")
        clock.advance(by: 1.9)
        XCTAssertTrue(fired.isEmpty)
        clock.advance(by: 0.2)
        XCTAssertEqual(fired, [["wake", "screen_wake", "network_change"]])
        clock.advance(by: 30)
        XCTAssertEqual(fired.count, 1)
    }

    func testEndlessEventsStillRecoverAtMaxWait() {
        let clock = ManualClock(now: start)
        var fired: [Date] = []
        let debouncer = EventDebouncer(clock: clock, quiet: 2, maxWait: 10) { _ in fired.append(clock.now) }
        for _ in 0..<15 {
            debouncer.note("network_change")
            clock.advance(by: 1)
        }
        XCTAssertEqual(fired.first, start.addingTimeInterval(10))
    }

    // MARK: Engine

    private final class Harness {
        let clock: ManualClock
        let engine: ReconnectEngine
        var connected = Set<String>()
        var dials: [(String, String)] = []

        init(clock: ManualClock, trusted: Set<String>, networks: [LocalIPv4Network]) {
            self.clock = clock
            engine = ReconnectEngine(addressBook: KnownAddressBook(store: MemoryAddressBookStore()), clock: clock)
            engine.isTrusted = { trusted.contains($0) }
            engine.isConnected = { [unowned self] in self.connected.contains($0) }
            engine.networks = { networks }
            engine.dial = { [unowned self] id, address in self.dials.append((id, address.host)) }
        }

        /// The dial failed (refused, timed out, never authenticated).
        func failDials() {
            let ids = dials.map(\.0)
            dials.removeAll()
            ids.forEach(engine.dialEnded)
        }
    }

    /// The reported bug: the phone dialled the Mac, the link reset at 02:56, and the phone was
    /// gone from Bonjour. The Mac must still redial the phone where it last connected from.
    func testRedialsTheInboundAddressAfterAResetWithNothingInDiscovery() {
        let harness = Harness(clock: ManualClock(now: start), trusted: [phone], networks: homeLAN)
        harness.connected.insert(phone)
        harness.engine.connected(phone, host: "192.168.29.40", port: ReconnectPolicy.listeningPort, source: .inbound)
        harness.engine.discoveryChanged([])

        harness.connected.remove(phone)
        harness.engine.disconnected(phone)
        harness.clock.advance(by: 1.9)
        XCTAssertTrue(harness.dials.isEmpty)
        harness.clock.advance(by: 0.2)
        XCTAssertEqual(harness.dials.map(\.1), ["192.168.29.40"])

        // No answer: it keeps trying on the schedule, not once.
        harness.failDials()
        harness.clock.advance(by: 5)
        XCTAssertEqual(harness.dials.count, 1)
        harness.failDials()
        harness.clock.advance(by: 15)
        XCTAssertEqual(harness.dials.count, 1)

        // The phone answers: connected, the schedule ends.
        harness.dials.removeAll()
        harness.connected.insert(phone)
        harness.engine.dialEnded(phone)
        harness.engine.connected(phone, host: "192.168.29.40", port: 42_458, source: .outbound)
        harness.clock.advance(by: 3_600)
        XCTAssertTrue(harness.dials.isEmpty)
        XCTAssertNil(harness.engine.display(for: phone))
    }

    func testWakeDialsAtOnceAndAttemptsRotateThroughAddresses() {
        let harness = Harness(clock: ManualClock(now: start), trusted: [phone], networks: homeLAN)
        harness.engine.addressBook.learn(phone, host: "192.168.29.40", port: 42_458, source: .inbound, at: start)
        harness.engine.addressBook.learn(phone, host: "192.168.29.41", port: 42_458, source: .discovery, at: start.addingTimeInterval(-60))
        harness.engine.disconnected(phone)
        harness.clock.advance(by: 2)
        harness.failDials()
        harness.clock.advance(by: 5)
        XCTAssertEqual(harness.dials.map(\.1), ["192.168.29.41"])
        harness.failDials()

        // Mac woke: try now rather than in 15 s.
        harness.engine.resetAll([phone])
        harness.clock.advance(by: 0)
        XCTAssertEqual(harness.dials.map(\.1), ["192.168.29.40"])
    }

    func testNothingIsDialledOffTheHomeNetwork() {
        let office = [LocalIPv4Network(address: parseIPv4("10.20.0.5")!, netmask: 0xFFFF_0000)]
        var events: [ReconnectEvent] = []
        let harness = Harness(clock: ManualClock(now: start), trusted: [phone], networks: office)
        harness.engine.onEvent = { events.append($0) }
        harness.engine.addressBook.learn(phone, host: "192.168.29.40", port: 42_458, source: .inbound, at: start)
        harness.engine.disconnected(phone)
        harness.clock.advance(by: 600)
        XCTAssertTrue(harness.dials.isEmpty)
        XCTAssertEqual(events.first, .noAddress(deviceID: phone, attempt: 1, reason: "backoff"))
    }

    func testDiscoveryFindingTheDeviceTriesItNow() {
        let harness = Harness(clock: ManualClock(now: start), trusted: [phone], networks: homeLAN)
        harness.engine.disconnected(phone)
        for _ in 0..<5 {
            harness.clock.advance(by: 60)
            harness.failDials()
        }
        let peer = DiscoveredPeer(serviceName: "Bridgey-a1b2c3d4", deviceIDHint: phone, deviceNameHint: "OnePlus 11", platformHint: "android",
                                  protocolVersionHint: 1, host: "OnePlus-11.local.", port: 42_458, addresses: ["192.168.29.52"])
        harness.engine.discoveryChanged([peer])
        harness.clock.advance(by: 0)
        XCTAssertEqual(harness.dials.map(\.1), ["192.168.29.52"])
        XCTAssertEqual(harness.engine.addressBook.addresses(for: phone).first?.source, .discovery)
    }

    func testRetryNowDialsEveryKnownAddressAndUntrustedDevicesAreLeftAlone() {
        let stranger = "ffffffff-0000-4000-8000-000000000009"
        let harness = Harness(clock: ManualClock(now: start), trusted: [phone], networks: homeLAN)
        harness.engine.addressBook.learn(phone, host: "192.168.29.40", port: 42_458, source: .inbound, at: start)
        harness.engine.addressBook.learn(phone, host: "192.168.29.41", port: 42_458, source: .outbound, at: start.addingTimeInterval(-5))
        harness.engine.dialEverywhere(phone, reason: "retry_now")
        XCTAssertEqual(Set(harness.dials.map(\.1)), ["192.168.29.40", "192.168.29.41"])
        harness.engine.dialEverywhere(stranger, reason: "retry_now")
        XCTAssertEqual(harness.dials.count, 2)
        harness.engine.disconnected(stranger)
        XCTAssertNil(harness.engine.schedule.entry(stranger))
    }

    func testDisplayTurnsToCantReachAfterSeveralMisses() {
        let harness = Harness(clock: ManualClock(now: start), trusted: [phone], networks: homeLAN)
        harness.engine.addressBook.learn(phone, host: "192.168.29.40", port: 42_458, source: .inbound, at: start)
        harness.engine.disconnected(phone)
        XCTAssertEqual(harness.engine.display(for: phone), ReconnectDisplay(lastSeen: start, struggling: false))
        for _ in 0..<4 {
            harness.clock.advance(by: 60)
            harness.failDials()
        }
        XCTAssertEqual(harness.engine.display(for: phone)?.struggling, true)
        harness.engine.resetAll([phone])
        XCTAssertEqual(harness.engine.display(for: phone)?.struggling, false)
    }

    // MARK: Both sides dial at once

    /// Both apps now redial, so after a drop the phone's socket (A) and the Mac's (B) often
    /// authenticate together. In every order, both ends keep A and closing B never reports the
    /// phone as disconnected (no flapping).
    func testBothSidesDialingAtOnceSettleOnTheSameSocket() {
        final class Tag { let value: String; init(_ value: String) { self.value = value } }
        let macID = "z-mac", phoneID = "m-phone"
        for macFirst in [true, false] {
            for phoneFirst in [true, false] {
                let a = Tag("A: phone dialled"), b = Tag("B: Mac dialled")
                let mac = SessionRegistry<Tag>(localDeviceID: macID)
                let phoneSide = SessionRegistry<Tag>(localDeviceID: phoneID)
                mac.addPending(a, initiatedLocally: false)
                mac.addPending(b, initiatedLocally: true)
                phoneSide.addPending(a, initiatedLocally: true)
                phoneSide.addPending(b, initiatedLocally: false)
                let macOrder = macFirst ? [a, b] : [b, a]
                let phoneOrder = phoneFirst ? [a, b] : [b, a]
                var macClosed: [Tag] = []
                var phoneClosed: [Tag] = []
                for tag in macOrder {
                    switch mac.authenticate(tag, deviceID: phoneID, peerName: "Phone") {
                    case .rejected: macClosed.append(tag)
                    case let .accepted(replaced): if let replaced { macClosed.append(replaced) }
                    }
                }
                for tag in phoneOrder {
                    switch phoneSide.authenticate(tag, deviceID: macID, peerName: "Mac") {
                    case .rejected: phoneClosed.append(tag)
                    case let .accepted(replaced): if let replaced { phoneClosed.append(replaced) }
                    }
                }
                XCTAssertTrue(mac.session(for: phoneID) === a)
                XCTAssertTrue(phoneSide.session(for: macID) === a)
                XCTAssertEqual(macClosed.map(\.value), [b.value])
                XCTAssertEqual(phoneClosed.map(\.value), [b.value])
                // The loser's reader ends on both sides: neither reports a disconnect.
                XCTAssertNil(mac.remove(b))
                XCTAssertNil(phoneSide.remove(b))
                XCTAssertEqual(mac.connectedIDs, [phoneID])
                XCTAssertEqual(phoneSide.connectedIDs, [macID])
            }
        }
    }

    // MARK: UI

    func testRingsSayReconnectingRatherThanLookingIdle() {
        let trusted = [TrustedDeviceInfo(id: phone, name: "OnePlus 11")]
        let fresh = deviceRings(trusted: trusted, peers: [], connected: [], pairing: .idle,
                                reconnecting: [phone: ReconnectDisplay(lastSeen: start, struggling: false)])
        XCTAssertEqual(fresh.first?.state, .connecting)
        XCTAssertTrue(fresh.first?.canRetry == true)
        XCTAssertEqual(ringStatusText(fresh[0]), "Reconnecting\u{2026}")

        let struggling = deviceRings(trusted: trusted, peers: [], connected: [], pairing: .idle,
                                     reconnecting: [phone: ReconnectDisplay(lastSeen: start, struggling: true)])
        XCTAssertEqual(struggling.first?.state, .offline)
        XCTAssertEqual(ringStatusText(struggling[0]), "Retrying\u{2026}")
        XCTAssertTrue(ringRetryHelp(struggling[0]).contains("OnePlus 11"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let seen = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 2, minute: 56))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 30))!
        let ring = deviceRings(trusted: trusted, peers: [], connected: [], pairing: .idle,
                               reconnecting: [phone: ReconnectDisplay(lastSeen: seen, struggling: false)])[0]
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(ringStatusDetail(ring, now: morning, locale: locale, calendar: calendar), "Reconnecting\u{2026} (last seen 02:56)")
        let cantReach = deviceRings(trusted: trusted, peers: [], connected: [], pairing: .idle,
                                    reconnecting: [phone: ReconnectDisplay(lastSeen: seen, struggling: true)])[0]
        XCTAssertEqual(ringStatusDetail(cantReach, now: morning, locale: locale, calendar: calendar), "Can\u{2019}t reach. Retrying (last seen 02:56)")

        // Connected devices and devices without a reconnect show as before.
        let connected = deviceRings(trusted: trusted, peers: [], connected: [PhoneConnection(id: phone, name: "OnePlus 11", state: PhoneLinkState())],
                                    pairing: .idle, reconnecting: [phone: ReconnectDisplay(lastSeen: start, struggling: true)])
        XCTAssertEqual(connected.first?.state, .connected)
        XCTAssertFalse(connected.first?.canRetry == true)
        XCTAssertEqual(deviceRings(trusted: trusted, peers: [], connected: [], pairing: .idle).first?.state, .offline)
    }

    func testRediscoverSummaries() {
        XCTAssertEqual(rediscoverSummary(found: ["OnePlus 11"], stillMissing: []), "Found OnePlus 11")
        XCTAssertEqual(rediscoverSummary(found: [], stillMissing: ["OnePlus 11"]), "Still can\u{2019}t reach OnePlus 11")
        XCTAssertEqual(rediscoverSummary(found: ["Pixel 9"], stillMissing: ["OnePlus 11"]), "Found Pixel 9. Still can\u{2019}t reach OnePlus 11")
        XCTAssertEqual(rediscoverSummary(found: [], stillMissing: []), "No new devices found")
        XCTAssertEqual(rediscoverSummary(found: ["A", "B", "C"], stillMissing: []), "Found 3 devices")
    }
}
