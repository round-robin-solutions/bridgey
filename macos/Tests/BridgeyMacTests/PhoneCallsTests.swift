import AppKit
import XCTest
@testable import BridgeyMac

/// Calls window (dialer_draft1): the client against a fake phone. Nothing goes to a phone that is not
/// allowed, an older search's answer is dropped, calls are spaced and time out, and what was kept for a
/// phone goes when it stops allowing this Mac.
@MainActor
final class PhoneCallsTests: XCTestCase {
    private let phone = "11111111-1111-1111-1111-111111111111"
    private var calls: PhoneCalls!
    private var sent: [(phone: String, kind: String, payload: [String: Any])] = []
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var available = true
    private var clock = Date(timeIntervalSince1970: 1_763_200_000)

    override func setUp() async throws {
        calls = PhoneCalls()
        var counter = 0
        calls.newRequestID = {
            counter += 1
            return String(format: "00000000-0000-4000-8000-%012d", counter)
        }
        calls.send = { [unowned self] id, kind, payload in
            guard self.available else { return false }
            self.sent.append((id, kind, payload))
            return true
        }
        calls.isAvailable = { [unowned self] _ in self.available }
        calls.schedule = { [unowned self] delay, work in self.scheduled.append((delay, work)) }
        calls.now = { [unowned self] in self.clock }
        calls.recentCount = { 20 }
    }

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func status(contacts: String = "on", recents: String = "on") {
        calls.receive(kind: DialerKinds.status, data: json(["version": 1, "place": true, "confirm": false, "contacts": contacts, "recents": recents,
                                                             "whatsapp": true, "sims": [["subId": 1, "slot": 0, "label": "Jio"]]]), from: phone)
    }

    private func runScheduled(upTo delay: TimeInterval) {
        let due = scheduled.filter { $0.delay <= delay }
        scheduled.removeAll { $0.delay <= delay }
        due.forEach { $0.work() }
    }

    func testNothingGoesToAPhoneThatIsNotAvailable() {
        available = false
        status()
        calls.search("Anna", phoneID: phone)
        runScheduled(upTo: 1)
        XCTAssertFalse(calls.call(.number("100200", subId: nil), phoneID: phone))
        calls.loadRecents(phone)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(calls.calling)
    }

    func testTheFirstStatusLoadsRecentCallsAndTheAnswerFillsThem() throws {
        status()
        XCTAssertEqual(sent.map(\.kind), [DialerKinds.recents])
        XCTAssertEqual(sent[0].payload["limit"] as? Int, 20)
        let id = try XCTUnwrap(sent[0].payload["requestId"] as? String)
        calls.receive(kind: DialerKinds.recentsResult, data: json(["version": 1, "requestId": id, "calls": [
            ["id": 1, "address": "100200", "type": "missed", "date": 1_000, "duration": 0],
            ["id": 2, "address": "100300", "type": "outgoing", "date": 2_000, "duration": 30],
        ]]), from: phone)
        XCTAssertEqual(calls.data(phone).recents.map(\.id), [2, 1], "newest first")
        XCTAssertTrue(calls.data(phone).recentsLoaded)
        status()
        XCTAssertEqual(sent.count, 1, "a later status does not load again")
        // Call history turned off on the phone: what was listed goes.
        status(recents: "off")
        XCTAssertTrue(calls.data(phone).recents.isEmpty)
    }

    func testAnOlderSearchsAnswerIsDropped() throws {
        status()
        sent.removeAll()
        calls.search("An", phoneID: phone)
        calls.search("Ann", phoneID: phone)
        runScheduled(upTo: PhoneCalls.searchDelay)
        XCTAssertEqual(sent.map { $0.payload["query"] as? String }, ["Ann"], "only the last typing reaches the phone")
        let id = try XCTUnwrap(sent[0].payload["requestId"] as? String)
        calls.receive(kind: DialerKinds.contactsResult, data: json(["version": 1, "requestId": "00000000-0000-4000-8000-000000000099", "contacts": [
            ["id": 9, "name": "Stale", "numbers": [["address": "1"]]],
        ]]), from: phone)
        XCTAssertTrue(calls.contacts.isEmpty, "an answer nobody asked for is ignored")
        calls.receive(kind: DialerKinds.contactsResult, data: json(["version": 1, "requestId": id, "contacts": [
            ["id": 7, "name": "Anna Kapoor", "numbers": [["address": "+91 98765 43210"]]],
        ]]), from: phone)
        XCTAssertEqual(calls.contacts.map(\.name), ["Anna Kapoor"])
        XCTAssertEqual(calls.contactsQuery, "Ann")
        XCTAssertFalse(calls.searching)
        calls.search("", phoneID: phone)
        XCTAssertTrue(calls.contacts.isEmpty)
    }

    func testContactsOffMeansNoSearchIsSent() {
        status(contacts: "unavailable")
        sent.removeAll()
        calls.search("Anna", phoneID: phone)
        runScheduled(upTo: 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func testACallIsSentOnceAndTheAnswerSaysWhatHappened() throws {
        status()
        sent.removeAll()
        XCTAssertTrue(calls.call(.number("+91 98765 43210", subId: 1), phoneID: phone))
        XCTAssertFalse(calls.call(.number("100200", subId: nil), phoneID: phone), "one at a time")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].payload["via"] as? String, "phone")
        XCTAssertEqual(sent[0].payload["subId"] as? Int, 1)
        XCTAssertEqual(calls.notice?.kind, .sent)
        let id = try XCTUnwrap(sent[0].payload["requestId"] as? String)
        calls.receive(kind: DialerKinds.callResult, data: json(["version": 1, "requestId": id, "result": "confirm"]), from: phone)
        XCTAssertNil(calls.calling)
        XCTAssertEqual(calls.notice?.kind, .confirm(.phone))
        XCTAssertEqual(callsNoticeText(try XCTUnwrap(calls.notice), phone: "OnePlus 11"), "Tap the notification on OnePlus 11 to start the call.")
        XCTAssertFalse(calls.call(.number("100200", subId: nil), phoneID: phone), "the phone allows one call every 3 seconds")
        clock.addTimeInterval(PhoneCalls.callSpacing)
        XCTAssertTrue(calls.call(.whatsApp(dataID: 4212, video: true), phoneID: phone))
        XCTAssertEqual(sent.last?.payload["via"] as? String, "whatsapp_video")
        XCTAssertEqual(sent.last?.payload["dataId"] as? Int, 4212)
        let second = try XCTUnwrap(sent.last?.payload["requestId"] as? String)
        calls.receive(kind: DialerKinds.callResult, data: json(["version": 1, "requestId": second, "result": "refused", "reason": "emergency"]), from: phone)
        XCTAssertEqual(calls.notice?.kind, .refused(.emergency))
        XCTAssertFalse(try XCTUnwrap(calls.notice).good)
    }

    func testACallThatGetsNoAnswerTimesOut() {
        status()
        XCTAssertTrue(calls.call(.number("100200", subId: nil), phoneID: phone))
        runScheduled(upTo: PhoneCalls.requestTimeout)
        XCTAssertNil(calls.calling)
        XCTAssertEqual(calls.notice?.kind, .noAnswer)
    }

    func testAPhoneThatStopsAllowingThisMacTakesEverythingWithIt() throws {
        status()
        let id = try XCTUnwrap(sent[0].payload["requestId"] as? String)
        calls.receive(kind: DialerKinds.recentsResult, data: json(["version": 1, "requestId": id, "calls": [
            ["id": 1, "address": "100200", "type": "missed", "date": 1_000, "duration": 0],
        ]]), from: phone)
        XCTAssertTrue(calls.call(.number("100200", subId: nil), phoneID: phone))
        calls.forget(phone)
        XCTAssertNil(calls.phones[phone])
        XCTAssertNil(calls.calling)
        XCTAssertNil(calls.notice)
        calls.disconnected(phone)
        XCTAssertNil(calls.data(phone).status)
    }

    func testMalformedOrOversizedAnswersAreDropped() {
        calls.receive(kind: DialerKinds.status, data: Data("{\"version\":1}".utf8), from: phone)
        XCTAssertNil(calls.data(phone).status)
        calls.receive(kind: DialerKinds.status, data: Data(repeating: 0x20, count: DialerLimits.status + 1), from: phone)
        XCTAssertNil(calls.data(phone).status)
        calls.receive(kind: DialerKinds.call, data: json(["version": 1]), from: phone)
        XCTAssertTrue(sent.isEmpty, "a request kind from a phone does nothing")
    }
}
