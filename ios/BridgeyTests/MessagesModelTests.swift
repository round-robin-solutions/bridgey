@testable import Bridgey
import XCTest

/// Text messages against a scripted session client: what the model asks bridgey_core, and what it shows.
@MainActor
final class MessagesModelTests: XCTestCase {
    static let phone = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f"
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var client: FakeClient!
    private var model: AppModel!
    private var messages: MessagesModel { model.messages }

    override func setUp() async throws {
        let suite = "bridgey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
        let on = ["clipboard": true, "files": true, "links": true, "ping": true]
        client = FakeClient(devices: [.init(deviceId: Self.phone, name: "Pixel 9", platform: "android", connected: true, pairedAtMs: nil, lastConnectedMs: nil,
                                            local: on, remote: on.merging(["sms_draft1": true]) { $1 })])
        client.phoneAnswers = [
            "status": ["ok": true, "available": true, "phone": ["read": true, "send": true, "contacts": true, "sims": [["subId": 1, "slot": 0, "label": "EE"], ["subId": 2, "slot": 1, "label": ""]]], "unread": 2],
            "threads": ["ok": true, "more": true, "threads": [
                ["threadId": 12, "title": "Asha", "participants": [["address": "+447700900123", "name": "Asha"]], "snippet": "See you at 6", "date": 1_793_091_600_000, "unread": 2, "group": false],
                ["threadId": 3, "title": "Sam, +447700900789", "participants": [["address": "+447700900789"], ["address": "+447700900790", "name": "Sam"]], "snippet": "Ok", "date": 1_793_091_400_000, "unread": 0, "group": true],
            ]],
            "open": Self.page,
            "messages": Self.page,
            "send": ["ok": true, "requestId": "r1"],
        ]
        var options = LaunchOptions()
        options.discovery = false
        options.ephemeral = true
        let fake = client!
        model = AppModel(settings: settings, options: options, system: FakeSystem(), activityFile: nil) { _, _ in fake }
        model.start()
    }

    static let page: [String: Any] = [
        "ok": true, "older": true, "canSend": true,
        "thread": ["threadId": 12, "title": "Asha", "participants": [["address": "+447700900123", "name": "Asha"]], "snippet": "See you at 6", "date": 1_793_091_600_000, "unread": 2, "group": false],
        // Newest first, as the library lists them.
        "messages": [
            ["id": "s103", "threadId": 12, "direction": "in", "status": "received", "date": 1_793_091_600_000, "address": "+447700900123", "body": "See you at 6"],
            ["id": "m40", "threadId": 12, "direction": "in", "status": "received", "date": 1_793_091_590_000, "address": "+447700900123", "body": "", "parts": [["partId": "p42", "mimeType": "image/png"]]],
            ["id": "s101", "threadId": 12, "direction": "out", "status": "delivered", "date": 1_793_091_500_000, "address": "+447700900123", "body": "Running late"],
        ],
        "outgoing": [["requestId": "r0", "body": "On my way", "state": "failed", "reason": "no_service", "date": 1_793_091_700_000, "threadId": 12]],
    ]

    private func ops(_ area: PhoneArea = .sms) -> [String] {
        client.phoneCommands.filter { $0.area == area }.compactMap { $0.command["op"] as? String }
    }

    private func sms(_ name: String, _ detail: [String: Any]) {
        let text = String(data: try! JSONSerialization.data(withJSONObject: detail), encoding: .utf8)
        model.handle(CoreEvent(kind: .sms, deviceID: Self.phone, name: name, text: text))
    }

    func testShowingAPhoneReadsWhatIsKeptThenAsksForTheNewest() {
        messages.show(Self.phone)
        XCTAssertEqual(Array(ops().suffix(3)), ["status", "threads", "refresh"])
        XCTAssertEqual(messages.conversations.map(\.threadID), [12, 3])
        XCTAssertEqual(messages.conversations[0].unread, 2)
        XCTAssertEqual(messages.conversations[0].address, "+447700900123")
        XCTAssertTrue(messages.conversations[1].group)
        XCTAssertTrue(messages.moreConversations)
        XCTAssertTrue(messages.status.canSend)
        XCTAssertEqual(messages.sims.map(\.label), ["EE", "SIM 2"], "a SIM without a label is named by its slot")
        XCTAssertNil(messages.statusText)
        // Changes from the library ask again.
        client.phoneCommands = []
        sms("changed", ["threads": true])
        XCTAssertEqual(ops(), ["threads"])
    }

    func testOpeningAConversationShowsItOldestFirstAsksForPicturesAndMarksItRead() throws {
        messages.show(Self.phone)
        messages.open(12)
        XCTAssertEqual(messages.messages.map(\.id), ["s101", "m40", "s103", "out:r0"])
        XCTAssertEqual(messages.messages[0].state, .delivered)
        XCTAssertTrue(messages.messages[3].canRetry, "a failed send can be tried again")
        XCTAssertTrue(messages.olderMessages)
        let image = try XCTUnwrap(client.phoneCommands.last { $0.command["op"] as? String == "image" })
        XCTAssertEqual(image.command["partId"] as? String, "p42")
        let read = try XCTUnwrap(client.phoneCommands.last { $0.command["op"] as? String == "mark_read" })
        XCTAssertEqual(read.command["threadIds"] as? [Int64], [12])

        // The picture arrives and stays in memory; one that fails says so.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        sms("image", ["partId": "p42", "data": png, "width": 1, "height": 1])
        XCTAssertNotNil(messages.images["p42"])
        sms("image", ["partId": "p43", "failed": true])
        XCTAssertTrue(messages.failedImages.contains("p43"))

        // A change to this conversation shows it again; closing tells the library.
        client.phoneCommands = []
        sms("changed", ["threadId": 12])
        XCTAssertEqual(ops(), ["threads", "messages"])
        messages.close(12)
        XCTAssertEqual(ops().last, "close")
        XCTAssertNil(messages.openThread)
    }

    func testSendingAReplyAndARefusal() throws {
        messages.show(Self.phone)
        messages.open(12)
        XCTAssertTrue(messages.send("On my way", thread: 12, sim: 2))
        let send = try XCTUnwrap(client.phoneCommands.last { $0.command["op"] as? String == "send" })
        XCTAssertEqual(send.command["threadId"] as? Int64, 12)
        XCTAssertEqual(send.command["subId"] as? Int64, 2, "the chosen SIM, as the phone has two")
        XCTAssertEqual(send.command["body"] as? String, "On my way")
        XCTAssertFalse(messages.send("   ", thread: 12), "blank text never goes")

        sms("send", ["requestId": "r1", "state": "refused", "reason": "group"])
        XCTAssertEqual(messages.notice, "Group conversations are answered on the phone.")
        client.phoneAnswers["send"] = ["ok": false, "error": "invalid"]
        XCTAssertFalse(messages.send("Hi", address: "*123#"))
        XCTAssertEqual(messages.notice, "That number can’t take texts.")
    }

    func testRetryDiscardAndMarkUnread() throws {
        messages.show(Self.phone)
        messages.open(12)
        let failed = try XCTUnwrap(messages.messages.last)
        messages.retry(failed)
        XCTAssertEqual(client.phoneCommands.last { $0.command["op"] as? String == "retry" }?.command["requestId"] as? String, "r0")
        messages.discard(failed)
        XCTAssertFalse(messages.messages.contains { $0.id == failed.id })
        messages.markUnread(messages.conversations[1])
        XCTAssertEqual(client.phoneCommands.last { $0.command["op"] as? String == "mark_unread" }?.command["threadIds"] as? [Int64], [3])
    }

    func testContactsSearchOnlyForNames() {
        messages.show(Self.phone)
        client.phoneCommands = []
        messages.searchContacts("07700")
        messages.searchContacts("A")
        XCTAssertTrue(ops().isEmpty, "numbers and single letters need no search")
        messages.searchContacts("As")
        XCTAssertEqual(client.phoneCommands.last?.command["query"] as? String, "As")
        sms("contacts", ["contacts": [["name": "Asha", "address": "+447700900123", "label": "Mobile"]]])
        XCTAssertEqual(messages.contacts.first?.name, "Asha")
        XCTAssertEqual(messages.contacts.first?.label, "Mobile")
    }

    func testNotices() {
        XCTAssertNil(MessagesModel.noticeText(["kind": "mark_read", "total": 2, "marked": 2]))
        XCTAssertEqual(MessagesModel.noticeText(["kind": "mark_read", "total": 2, "marked": 1]), "1 conversation stays unread on your phone. Open it there to clear it.")
        XCTAssertEqual(MessagesModel.noticeText(["kind": "mark_read", "total": 3, "marked": 0]), "3 conversations stay unread on your phone. Open them there to clear them.")
        XCTAssertEqual(MessagesModel.noticeText(["kind": "mark_read", "noAnswer": true, "total": 1]), "Your phone didn’t answer, so it still counts them unread.")
        XCTAssertEqual(MessagesModel.noticeText(["kind": "blocked", "result": "notified"]), "Tap the notification on your phone to open Blocked numbers.")
        XCTAssertEqual(MessagesModel.sendProblem("radio_off"), "Your phone has no mobile signal right now.")
        XCTAssertEqual(MessagesModel.sendProblem("something new"), "The text wasn’t sent.")
    }

    func testTurnOnIsForThisPhoneOnly() {
        messages.show(Self.phone)
        XCTAssertFalse(model.device(Self.phone)!.messagesOn)
        messages.turnOn()
        XCTAssertTrue(client.calls.contains("feature \(Self.phone) sms_draft1 true"))
        XCTAssertTrue(model.device(Self.phone)!.messagesOn)
        XCTAssertFalse(settings.textMessages, "the default for other phones stays off")
    }

    func testKeepConversationsGoesToTheLibrary() async throws {
        XCTAssertEqual(client.phoneCommands.last { $0.command["op"] as? String == "keep" }?.command["on"] as? Bool, true)
        settings.keepConversations = false
        // The setting reaches the library on the next turn of the main queue.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.phoneCommands.last { $0.command["op"] as? String == "keep" }?.command["on"] as? Bool, false)
    }

    func testStatusLines() {
        client.phoneAnswers["status"] = ["ok": true, "available": true]
        messages.show(Self.phone)
        XCTAssertEqual(messages.statusText, "Waiting for Pixel 9…")
        client.phoneAnswers["status"] = ["ok": true, "available": true, "phone": ["read": false, "send": false, "contacts": false, "sims": []]]
        sms("status", [:])
        XCTAssertEqual(messages.statusText, "Pixel 9 needs permission to read texts. Open Bridgey on the phone.")
        model.handle(CoreEvent(kind: .disconnected, deviceID: Self.phone))
        XCTAssertEqual(messages.statusText, "Pixel 9 isn’t connected.")
    }

    func testTheSessionStoppingClearsWhatIsShown() {
        messages.show(Self.phone)
        messages.open(12)
        model.stop()
        XCTAssertTrue(messages.conversations.isEmpty)
        XCTAssertTrue(messages.messages.isEmpty)
        XCTAssertNil(messages.openThread)
    }

    func testWhen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 15))!
        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
        XCTAssertEqual(MessagesModel.when(0, now: now, calendar: calendar), "")
        XCTAssertEqual(MessagesModel.when(ms(now.addingTimeInterval(-86_400)), now: now, calendar: calendar), "Yesterday")
        XCTAssertFalse(MessagesModel.when(ms(now.addingTimeInterval(-600)), now: now, calendar: calendar).isEmpty)
        let old = MessagesModel.when(ms(calendar.date(from: DateComponents(year: 2025, month: 3, day: 2))!), now: now, calendar: calendar)
        XCTAssertTrue(old.contains("2025"), old)
    }
}
