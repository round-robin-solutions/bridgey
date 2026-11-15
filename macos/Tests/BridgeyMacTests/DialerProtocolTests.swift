import Foundation
import XCTest
@testable import BridgeyMac

/// Calls window (dialer_draft1): protocol/test-vectors/dialer-v1.json, decoded as the Mac decodes the
/// phone's answers and written as the Mac writes its requests; Android (DialerProtocolTest.kt) decodes
/// the same file. Then the window's pure parts: the SIM choice, the search rows and the words.
final class DialerProtocolTests: XCTestCase {
    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/dialer-v1.json")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func each(_ group: String, file: StaticString = #filePath, line: UInt = #line, _ check: ([String: Any]) throws -> Bool) throws {
        let list = try XCTUnwrap(vectors[group] as? [[String: Any]])
        XCTAssertGreaterThan(list.count, 5)
        let failed = list.filter { ((try? check($0)) ?? false) == false }.map { $0["name"] as! String }
        XCTAssertEqual(failed, [], "\(group) vectors that decode differently from the contract", file: file, line: line)
    }

    private func plaintext(_ vector: [String: Any]) -> Data {
        if let raw = vector["plaintextString"] as? String { return Data(raw.utf8) }
        return (try? JSONSerialization.data(withJSONObject: vector["plaintext"] as Any, options: [.fragmentsAllowed])) ?? Data()
    }

    private func same(_ result: Any, _ expected: Any?) -> Bool {
        guard let expected else { return false }
        return NSArray(object: result).isEqual(to: [expected])
    }

    private func null(_ value: Any?) -> Any { value ?? NSNull() }

    func testStatus() throws {
        try each("status") { vector in
            guard let status = decodeDialerStatus(plaintext(vector)) else { return (vector["expect"] as? String) == "reject" }
            let result: [String: Any] = [
                "place": status.place, "confirm": status.confirm, "contacts": status.contacts.rawValue, "recents": status.recents.rawValue,
                "whatsapp": status.whatsApp, "sims": status.sims.map { ["subId": $0.subId, "slot": $0.slot, "label": $0.label] },
            ]
            return same(result, vector["expect"])
        }
    }

    func testContactsResult() throws {
        try each("contacts") { vector in
            guard let result = decodeDialerContactsResult(plaintext(vector)) else { return (vector["expect"] as? String) == "reject" }
            let contacts: [[String: Any]] = result.contacts.map { contact in
                [
                    "id": contact.id, "name": contact.name, "starred": contact.starred,
                    "numbers": contact.numbers.map { ["address": $0.address, "label": null($0.label)] },
                    "whatsapp": contact.whatsApp.map { ["address": $0.address, "voice": null($0.voice), "video": null($0.video)] },
                ]
            }
            return same(["requestId": result.requestID, "contacts": contacts, "error": null(result.error)], vector["expect"])
        }
    }

    func testRecentsResult() throws {
        try each("recents") { vector in
            guard let result = decodeDialerRecentsResult(plaintext(vector)) else { return (vector["expect"] as? String) == "reject" }
            let calls: [[String: Any]] = result.calls.map {
                ["id": $0.id, "address": $0.address, "name": null($0.name), "type": $0.type.rawValue, "date": $0.date,
                 "duration": $0.duration, "subId": null($0.subId)]
            }
            return same(["requestId": result.requestID, "calls": calls, "error": null(result.error)], vector["expect"])
        }
    }

    func testCallResult() throws {
        try each("callResult") { vector in
            guard let result = decodeDialerCallResult(plaintext(vector)) else { return (vector["expect"] as? String) == "reject" }
            return same(["requestId": result.requestID, "result": result.outcome.rawValue, "reason": null(result.reason?.rawValue)], vector["expect"])
        }
    }

    /// What this Mac writes, the phone decodes as the request vectors say.
    func testRequestsMatchTheVectorsThePhoneDecodes() throws {
        let list = try XCTUnwrap(vectors["request"] as? [[String: Any]])
        func vector(_ name: String) throws -> [String: Any] { try XCTUnwrap(list.first { $0["name"] as? String == name }?["plaintext"] as? [String: Any]) }
        let id = "5b6c7d8e-9f01-4a2b-8c3d-4e5f60718293"
        XCTAssertEqual(NSDictionary(dictionary: DialerRequests.contacts(requestID: id, query: "Anna")), NSDictionary(dictionary: try vector("contacts, a name")))
        XCTAssertEqual(NSDictionary(dictionary: DialerRequests.recents(requestID: id, limit: 20)), NSDictionary(dictionary: try vector("recents, 20")))
        XCTAssertEqual(NSDictionary(dictionary: DialerRequests.call(requestID: id, number: "+91 98765 43210", subId: nil)), NSDictionary(dictionary: try vector("call, a number")))
        XCTAssertEqual(NSDictionary(dictionary: DialerRequests.call(requestID: id, number: "(022) 4000-1234", subId: 2)), NSDictionary(dictionary: try vector("call, a number on SIM 2")))
        XCTAssertEqual(NSDictionary(dictionary: DialerRequests.whatsApp(requestID: id, dataID: 4211, video: false)), NSDictionary(dictionary: try vector("call, WhatsApp voice")))
        XCTAssertEqual(NSDictionary(dictionary: DialerRequests.whatsApp(requestID: id, dataID: 4212, video: true)), NSDictionary(dictionary: try vector("call, WhatsApp video")))
        // A long query is cut to 64 UTF-16 units and trimmed, never sent as a request the phone rejects.
        let long = DialerRequests.contacts(requestID: id, query: "  " + String(repeating: "\u{1F600}", count: 40))["query"] as? String
        XCTAssertEqual(long?.utf16.count, 64)
        XCTAssertEqual(DialerRequests.recents(requestID: id, limit: 500)["limit"] as? Int, 50)
    }

    // MARK: SIM choice

    private let sims = [SmsSim(subId: 3, slot: 0, label: "Jio"), SmsSim(subId: 7, slot: 1, label: "Airtel")]

    func testSimChoice() {
        XCTAssertEqual(callsSimDecision(preference: .ask, sims: sims, picked: nil), .ask)
        XCTAssertEqual(callsSimDecision(preference: .ask, sims: sims, picked: 7), .use(subId: 7))
        XCTAssertEqual(callsSimDecision(preference: .sim1, sims: sims, picked: nil), .use(subId: 3))
        XCTAssertEqual(callsSimDecision(preference: .sim2, sims: sims, picked: nil), .use(subId: 7))
        XCTAssertEqual(callsSimDecision(preference: .sim2, sims: sims, picked: 3), .use(subId: 3), "a pick in the window wins")
        XCTAssertEqual(callsSimDecision(preference: .sim1, sims: sims, picked: 99), .use(subId: 3), "a SIM that is gone is ignored")
        XCTAssertEqual(callsSimDecision(preference: .sim2, sims: [sims[0], SmsSim(subId: 9, slot: 2, label: "")], picked: nil), .ask,
                       "an empty preferred slot asks")
        XCTAssertEqual(callsSimDecision(preference: .ask, sims: [sims[0]], picked: nil), .phoneDefault, "one SIM never asks")
        XCTAssertEqual(callsSimDecision(preference: .sim2, sims: [], picked: 7), .phoneDefault, "no SIM list: the phone's default")
        XCTAssertNil(callsInitialSim(preference: .ask, sims: sims))
        XCTAssertEqual(callsInitialSim(preference: .sim2, sims: sims), 7)
        XCTAssertNil(callsInitialSim(preference: .sim2, sims: [sims[1]]))
    }

    // MARK: Search

    private let anna = DialerContact(id: 7, name: "Anna Kapoor", starred: true,
                                     numbers: [DialerNumber(address: "+91 98765 43210", label: "Mobile")],
                                     whatsApp: [DialerWhatsApp(address: "+919876543210", voice: 4211, video: 4212)])
    private var recents: [RecentCall] {
        [
            RecentCall(id: 5, address: "+919876543210", name: "Anna Kapoor", type: .outgoing, date: 5_000, duration: 60),
            RecentCall(id: 4, address: "+91 98765 43210", name: "Anna Kapoor", type: .missed, date: 4_000, duration: 0),
            RecentCall(id: 3, address: "100200", name: "Rohan Mehta", type: .incoming, date: 3_000, duration: 12),
            RecentCall(id: 2, address: "", type: .missed, date: 2_000, duration: 0),
            RecentCall(id: 1, address: "+44 20 7946 0000", type: .outgoing, date: 1_000, duration: 300),
        ]
    }

    func testNothingTypedListsRecentCallsOncePerNumber() {
        let rows = callsRows(query: " ", contacts: [], recents: recents, limit: 20)
        XCTAssertEqual(rows.map(\.id), ["r:5", "r:3", "r:2", "r:1"], "Anna's older call is folded into her newest")
        XCTAssertEqual(callsRows(query: "", contacts: [], recents: recents, limit: 2).count, 2)
        XCTAssertNil(CallsRow.recent(recents[3]).number, "a private number cannot be called back")
    }

    func testTypingANumberOffersItFirstThenContactsThenOtherMatches() {
        let rows = callsRows(query: "98765", contacts: [anna], recents: recents, limit: 20)
        XCTAssertEqual(rows.map(\.id), ["n:98765", "c:7"], "Anna's recent calls are her contact row")
        XCTAssertEqual(rows.first?.number, "98765")
        let other = callsRows(query: "7946 0000", contacts: [], recents: recents, limit: 20)
        XCTAssertEqual(other.map(\.id), ["n:7946 0000", "r:1"], "a recent call matches the digits whatever their spacing")
        XCTAssertEqual(callsRows(query: "100200", contacts: [], recents: recents, limit: 20).map(\.id), ["n:100200"],
                       "a recent call to exactly the typed number is not listed twice")
    }

    func testTypingANameMatchesWordStarts() {
        XCTAssertEqual(callsRows(query: "meh", contacts: [], recents: recents, limit: 20).map(\.id), ["r:3"])
        XCTAssertEqual(callsRows(query: "ro", contacts: [], recents: recents, limit: 20).map(\.id), ["r:3"])
        XCTAssertEqual(callsRows(query: "ohan", contacts: [], recents: recents, limit: 20).map(\.id), [])
        XCTAssertEqual(callsRows(query: "Anna", contacts: [anna], recents: recents, limit: 20).map(\.id), ["c:7"])
        XCTAssertTrue(recentMatches(recents[2], query: "100"))
        XCTAssertFalse(recentMatches(recents[2], query: "1"), "one digit matches too much")
        XCTAssertFalse(callsQueryIsNumber("Anna"))
        XCTAssertTrue(callsQueryIsNumber("+91 (22) 4000-1234"))
        XCTAssertFalse(callsQueryIsNumber("*#06#"))
    }

    // MARK: Words

    func testRelativeTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12, minute: 0))!
        func ago(_ seconds: TimeInterval) -> String { callsRelativeTime(now.addingTimeInterval(-seconds), now: now, locale: locale, calendar: calendar) }
        XCTAssertEqual(ago(20), "Just now")
        XCTAssertTrue(ago(5 * 60).contains("5"), ago(5 * 60))
        XCTAssertFalse(ago(3 * 3_600).isEmpty)
        XCTAssertEqual(ago(15 * 3_600), "Yesterday")
        XCTAssertEqual(ago(3 * 86_400), now.addingTimeInterval(-3 * 86_400).formatted(Date.FormatStyle().weekday(.abbreviated).locale(locale)))
        XCTAssertTrue(ago(30 * 86_400).contains("Oct"), ago(30 * 86_400))
    }

    func testDurationsAndInitials() {
        XCTAssertNil(callsDuration(0))
        XCTAssertNotNil(callsDuration(45))
        XCTAssertNotNil(callsDuration(184))
        XCTAssertEqual(callsInitials("Anna Kapoor"), "AK")
        XCTAssertEqual(callsInitials("rohan"), "R")
        XCTAssertEqual(callsInitials("Mary Jane Watson"), "MW")
        XCTAssertEqual(callsInitials("+91 98765"), "#")
    }

    func testWhatsAppOnThisMacOpensTheChatForTheNumber() {
        XCTAssertEqual(WhatsAppOnMac.chatURL(for: "+91 98765 43210")?.absoluteString, "whatsapp://send?phone=919876543210")
        XCTAssertNil(WhatsAppOnMac.chatURL(for: "12"))
        let saved = WhatsAppOnMac.handler
        defer { WhatsAppOnMac.handler = saved }
        WhatsAppOnMac.handler = { nil }
        XCTAssertFalse(WhatsAppOnMac.isInstalled)
        XCTAssertFalse(WhatsAppOnMac.open("+919876543210"), "nothing opens without WhatsApp Desktop")
    }
}
