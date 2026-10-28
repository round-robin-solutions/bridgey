import AppKit
import XCTest
@testable import BridgeyMac

/// Text messages (sms_draft1): the sync logic against a fake phone, the cache file and every way it
/// is deleted. Temporary folders only; never the real Application Support.
@MainActor
final class TextMessagesTests: XCTestCase {
    private let phone = "11111111-1111-1111-1111-111111111111"
    private var root: URL!
    private var store: SmsStore!
    private var messages: TextMessages!
    private var sent: [(kind: String, payload: [String: Any])] = []
    private var scheduled: [() -> Void] = []
    private var available = true
    private var keep = true
    private var failedReplies: [SmsOutgoing] = []
    private var clock = Date(timeIntervalSince1970: 1_761_500_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-sms-\(UUID().uuidString)", isDirectory: true)
        store = SmsStore(directory: root.appendingPathComponent("Messages", isDirectory: true))
        messages = TextMessages(store: store)
        var counter = 0
        messages.newRequestID = {
            counter += 1
            return String(format: "00000000-0000-4000-8000-%012d", counter)
        }
        messages.send = { [unowned self] _, kind, payload in
            guard self.available else { return false }
            self.sent.append((kind, payload))
            return true
        }
        messages.isAvailable = { [unowned self] _ in self.available }
        messages.keepOnDisk = { [unowned self] in self.keep }
        messages.schedule = { [unowned self] _, work in self.scheduled.append(work) }
        messages.now = { [unowned self] in self.clock }
        messages.onReplyFailed = { [unowned self] in self.failedReplies.append($0) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func status(sms: Int = 120, mms: Int = 4, read: Bool = true, sims: [[String: Any]] = []) -> Data {
        json(["version": 1, "read": read, "send": true, "contacts": true, "sims": sims, "cursor": ["sms": sms, "mms": mms]])
    }

    private func message(_ id: String, thread: Int = 7, out: Bool = false, date: Int = 1_761_500_000_000, body: String = "Hi", read: Bool = true) -> [String: Any] {
        ["id": id, "threadId": thread, "direction": out ? "out" : "in", "status": out ? "sent" : "received", "date": date,
         "address": "+919876543210", "body": body, "read": read]
    }

    private func thread(_ id: Int, date: Int, name: String = "Anna") -> [String: Any] {
        ["threadId": id, "participants": [["address": "+91987654\(id)", "name": name]], "snippet": "Hi", "date": date, "unread": 0]
    }

    private func lastRequestID(_ kind: String) -> String? { sent.last { $0.kind == kind }?.payload["requestId"] as? String }

    private func runScheduled() {
        let work = scheduled
        scheduled = []
        work.forEach { $0() }
    }

    // MARK: Sync

    func testNoCacheStartsAtThePhonesCursorAndLoadsOnlyTheNewestConversations() {
        messages.phoneReady(phone)
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        XCTAssertEqual(sent.map(\.kind), [SmsKinds.threads], "no bulk history copy: no sync without a cache")
        XCTAssertEqual(sent[0].payload["limit"] as? Int, 30)
        XCTAssertNil(sent[0].payload["before"])
        XCTAssertEqual(messages.data(phone).cache.cursor, SmsCursor(sms: 120, mms: 4))
    }

    func testAPhoneWithoutSmsPermissionAsksNothing() {
        messages.receive(kind: SmsKinds.status, data: status(read: false), from: phone)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(messages.data(phone).status?.read, false)
    }

    func testWithACacheItSyncsFromItsCursorAndFollowsMoreForTenPagesAtMost() throws {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        let first = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": first, "threads": [thread(7, date: 5)], "more": false]), from: phone)
        sent = []
        // Reconnect: the phone's status again, now ahead.
        messages.disconnected(phone)
        messages.receive(kind: SmsKinds.status, data: status(sms: 130), from: phone)
        XCTAssertEqual(sent.map(\.kind), [SmsKinds.sync])
        XCTAssertEqual((sent[0].payload["since"] as? [String: Int]), ["sms": 120, "mms": 4])
        XCTAssertEqual(sent[0].payload["limit"] as? Int, 100)
        for page in 1...12 {
            guard let id = lastRequestID(SmsKinds.sync) else { break }
            messages.receive(kind: SmsKinds.syncPage, data: json(["version": 1, "requestId": id, "messages": [message("s\(120 + page)")],
                                                                  "cursor": ["sms": 120 + page, "mms": 4], "more": true]), from: phone)
        }
        XCTAssertEqual(sent.filter { $0.kind == SmsKinds.sync }.count, TextMessages.maximumSyncPages, "stops after 10 pages until the next change")
        XCTAssertFalse(messages.data(phone).syncing)
        XCTAssertEqual(messages.data(phone).cache.cursor?.sms, 130)
        XCTAssertEqual(messages.data(phone).cache.messages(in: 7).count, 10)
        XCTAssertEqual(messages.data(phone).cache.thread(7)?.date, 1_761_500_000_000)
    }

    func testChangedSyncsOnlyWhenThePhoneIsAhead() throws {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        let first = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": first, "threads": [thread(7, date: 5)], "more": false]), from: phone)
        sent = []
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 120, "mms": 4]]), from: phone)
        XCTAssertEqual(sent.map(\.kind), [SmsKinds.threads], "nothing new: something changed in place (read on the phone), so the list's counts refresh")
        let again = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": again, "threads": [thread(7, date: 5)], "more": false]), from: phone)
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 120, "mms": 4]]), from: phone)
        XCTAssertEqual(sent.count, 1, "at most once every 3 seconds")
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 121, "mms": 4]]), from: phone)
        XCTAssertEqual(sent.map(\.kind), [SmsKinds.threads, SmsKinds.sync])
    }

    func testChangedRefreshesTheOpenConversationAtMostEveryTwoSeconds() {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        messages.open(phone, thread: 7)
        let opened = sent.filter { $0.kind == SmsKinds.messages }.count
        XCTAssertEqual(opened, 1)
        // The first page answers, so the next refresh may go.
        let id = lastRequestID(SmsKinds.messages)!
        messages.receive(kind: SmsKinds.messagesPage, data: json(["version": 1, "requestId": id, "threadId": 7, "messages": [message("s1")], "more": false]), from: phone)
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 120, "mms": 4]]), from: phone)
        XCTAssertEqual(sent.filter { $0.kind == SmsKinds.messages }.count, 1, "too soon: waits")
        clock += 3
        runScheduled()
        XCTAssertEqual(sent.filter { $0.kind == SmsKinds.messages }.count, 2)
    }

    func testResetDropsTheCacheAndStartsAgain() throws {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        let first = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": first, "threads": [thread(7, date: 5)], "more": false]), from: phone)
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 5000, "mms": 4]]), from: phone)
        let sync = try XCTUnwrap(lastRequestID(SmsKinds.sync))
        sent = []
        messages.receive(kind: SmsKinds.syncPage, data: json(["version": 1, "requestId": sync, "messages": [], "cursor": ["sms": 5000, "mms": 4],
                                                             "more": false, "reset": true]), from: phone)
        XCTAssertTrue(messages.data(phone).cache.threads.isEmpty)
        XCTAssertEqual(messages.data(phone).cache.cursor, SmsCursor(sms: 5000, mms: 4))
        XCTAssertEqual(sent.map(\.kind), [SmsKinds.threads])
    }

    func testSyncIntoAnUnknownConversationAsksForTheThreadsAgain() throws {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        let first = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": first, "threads": [thread(7, date: 5)], "more": false]), from: phone)
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 121, "mms": 4]]), from: phone)
        let sync = try XCTUnwrap(lastRequestID(SmsKinds.sync))
        sent = []
        messages.receive(kind: SmsKinds.syncPage, data: json(["version": 1, "requestId": sync, "messages": [message("s121", thread: 9, read: false)],
                                                             "cursor": ["sms": 121, "mms": 4], "more": false]), from: phone)
        XCTAssertEqual(sent.map(\.kind), [SmsKinds.threads])
        XCTAssertEqual(messages.data(phone).cache.messages(in: 9).map(\.id), ["s121"])
    }

    func testAnswersThatWereNotAskedForAreIgnored() {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": "99999999-0000-4000-8000-000000000000",
                                                                "threads": [thread(1, date: 1)], "more": false]), from: phone)
        XCTAssertTrue(messages.data(phone).cache.threads.isEmpty)
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": lastRequestID(SmsKinds.threads)!,
                                                                "threads": [thread(1, date: 1)], "more": false]), from: "22222222-2222-2222-2222-222222222222")
        XCTAssertTrue(messages.data(phone).cache.threads.isEmpty, "another phone cannot answer this phone's request")
    }

    func testOversizedPagesAreDropped() {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        let id = lastRequestID(SmsKinds.threads)!
        let big = json(["version": 1, "requestId": id, "threads": [thread(1, date: 1)], "more": false, "pad": String(repeating: "x", count: 41_000)])
        messages.receive(kind: SmsKinds.threadsPage, data: big, from: phone)
        XCTAssertTrue(messages.data(phone).cache.threads.isEmpty)
    }

    // MARK: Pages

    func testTheNewestThreadsPageRemovesConversationsDeletedOnThePhone() {
        var cache = SmsCache()
        cache.applyThreads(try! [5, 4, 3].map { try XCTUnwrap(decodeSmsThread(thread($0, date: $0))) }, first: true, more: false)
        cache.applyThreads([decodeSmsThread(thread(5, date: 5))!, decodeSmsThread(thread(3, date: 3))!], first: true, more: false)
        XCTAssertEqual(cache.threads.map(\.threadId), [5, 3])
        cache.applyThreads([decodeSmsThread(thread(1, date: 1))!], first: false, more: false)
        XCTAssertEqual(cache.threads.map(\.threadId), [5, 3, 1])
        XCTAssertFalse(cache.threadsMore)
    }

    func testAMessagesPageReplacesItsSpanAndOlderPagesAdd() {
        var cache = SmsCache()
        let page = (1...5).map { decodeSmsMessage(message("s\($0)", date: $0 * 1000))! }
        cache.applyMessages(page, thread: 7, before: nil, more: true)
        XCTAssertEqual(cache.messages(in: 7).map(\.id), ["s5", "s4", "s3", "s2", "s1"])
        XCTAssertTrue(cache.hasOlder(in: 7))
        // s4 deleted on the phone; the newest page no longer has it.
        cache.applyMessages(page.filter { $0.id != "s4" }, thread: 7, before: nil, more: true)
        XCTAssertEqual(cache.messages(in: 7).map(\.id), ["s5", "s3", "s2", "s1"])
        cache.applyMessages([decodeSmsMessage(message("m1", date: 500))!], thread: 7, before: cache.messages(in: 7).last, more: false)
        XCTAssertEqual(cache.messages(in: 7).last?.id, "m1")
        XCTAssertFalse(cache.hasOlder(in: 7))
    }

    func testTheCacheKeepsAtMost200MessagesPerConversation() {
        var cache = SmsCache()
        cache.applySync((1...250).map { decodeSmsMessage(message("s\($0)", date: $0))! })
        XCTAssertEqual(cache.messages(in: 7).count, SmsCache.maximumMessagesPerThread)
        XCTAssertEqual(cache.messages(in: 7).first?.id, "s250")
        XCTAssertTrue(cache.hasOlder(in: 7))
    }

    func testTheCacheKeepsAtMost200Conversations() {
        var cache = SmsCache()
        cache.applyThreads((1...230).map { decodeSmsThread(thread($0, date: $0))! }, first: true, more: false)
        XCTAssertEqual(cache.threads.count, SmsCache.maximumThreads)
        XCTAssertEqual(cache.threads.first?.threadId, 230)
        XCTAssertTrue(cache.threadsMore)
    }

    func testUnreadIncomingMessagesCountOnTheirConversation() {
        var cache = SmsCache()
        cache.applyThreads([decodeSmsThread(thread(7, date: 1))!], first: true, more: false)
        cache.applySync([decodeSmsMessage(message("s9", date: 10, body: "New one", read: false))!])
        cache.applySync([decodeSmsMessage(message("s9", date: 10, body: "New one", read: false))!])
        XCTAssertEqual(cache.thread(7)?.unread, 1, "the same message twice counts once")
        XCTAssertEqual(cache.thread(7)?.snippet, "New one")
    }

    // MARK: Sending

    func testSendGoesOutAndThePendingBubbleGoesWhenThePhoneListsIt() throws {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        let id = try XCTUnwrap(messages.send("On my way", to: .thread(7), subId: 2, phoneID: phone))
        let payload = try XCTUnwrap(sent.last)
        XCTAssertEqual(payload.kind, SmsKinds.send)
        XCTAssertEqual(payload.payload["threadId"] as? Int, 7)
        XCTAssertEqual(payload.payload["subId"] as? Int, 2)
        messages.receive(kind: SmsKinds.sendStatus, data: json(["version": 1, "requestId": id, "status": "sent", "via": "sms"]), from: phone)
        XCTAssertEqual(messages.outgoing.first?.state, .sent)
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 121, "mms": 4]]), from: phone)
        let sync = try XCTUnwrap(lastRequestID(SmsKinds.sync))
        messages.receive(kind: SmsKinds.syncPage, data: json(["version": 1, "requestId": sync,
                                                             "messages": [message("s121", out: true, date: Int(clock.timeIntervalSince1970 * 1000), body: "On my way")],
                                                             "cursor": ["sms": 121, "mms": 4], "more": false]), from: phone)
        XCTAssertTrue(messages.outgoing.isEmpty)
    }

    func testAFailedSendKeepsItsBubbleWithRetry() throws {
        let id = try XCTUnwrap(messages.send("Hello", to: .address("+91 98765 43210"), phoneID: phone))
        XCTAssertEqual(sent.last?.payload["address"] as? String, "+919876543210")
        messages.receive(kind: SmsKinds.sendStatus, data: json(["version": 1, "requestId": id, "status": "failed", "reason": "no_service"]), from: phone)
        XCTAssertEqual(messages.outgoing.first?.reason, .noService)
        let retried = try XCTUnwrap(messages.retry(id))
        XCTAssertNotEqual(retried, id)
        XCTAssertEqual(messages.outgoing.map(\.id), [retried])
    }

    func testASendThatCannotGoIsNotKept() {
        available = false
        XCTAssertNil(messages.send("Hello", to: .thread(7), phoneID: phone))
        available = true
        XCTAssertNil(messages.send("   ", to: .thread(7), phoneID: phone))
        XCTAssertNil(messages.send("Hi", to: .address("HDFCBK"), phoneID: phone))
        XCTAssertTrue(messages.outgoing.isEmpty)
    }

    func testANotificationReplyThatFailsSaysSoAndOneThatWentLeaves() throws {
        let failing = try XCTUnwrap(messages.send("Thanks", to: .notification("n1"), phoneID: phone))
        XCTAssertEqual(sent.last?.payload["notificationId"] as? String, "n1")
        messages.receive(kind: SmsKinds.sendStatus, data: json(["version": 1, "requestId": failing, "status": "refused", "reason": "permission"]), from: phone)
        XCTAssertEqual(failedReplies.map(\.reason), [.permission])
        let going = try XCTUnwrap(messages.send("Thanks", to: .notification("n2"), phoneID: phone))
        messages.receive(kind: SmsKinds.sendStatus, data: json(["version": 1, "requestId": going, "status": "sent", "via": "app"]), from: phone)
        XCTAssertFalse(messages.outgoing.contains { $0.id == going })
    }

    func testANotificationReplyWithNoAnswerTimesOutAsFailed() throws {
        _ = try XCTUnwrap(messages.send("Thanks", to: .notification("n1"), phoneID: phone))
        runScheduled()
        XCTAssertEqual(failedReplies.count, 1)
    }

    // MARK: Images and contacts

    func testAtMostFourImagesLoadAtOnceAndTheyStayInMemory() throws {
        for part in 1...6 { messages.requestImage(phone, partID: "p\(part)") }
        XCTAssertEqual(sent.filter { $0.kind == SmsKinds.attachment }.count, TextMessages.maximumOpenAttachments)
        let first = try XCTUnwrap(sent.first { $0.kind == SmsKinds.attachment })
        let png = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let data = NSBitmapImageRep(data: png.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])!
        messages.receive(kind: SmsKinds.attachmentData, data: json(["version": 1, "requestId": first.payload["requestId"]!, "partId": "p1",
                                                                   "mimeType": "image/jpeg", "width": 2, "height": 2, "data": data.base64EncodedString()]), from: phone)
        XCTAssertNotNil(messages.image(phone, partID: "p1"))
        XCTAssertEqual(sent.filter { $0.kind == SmsKinds.attachment }.count, 5, "the next one goes as one finishes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "images are never written")
    }

    func testContactSearchKeepsOnlyTheNewestAnswer() throws {
        messages.searchContacts("An", phoneID: phone)
        let old = try XCTUnwrap(lastRequestID(SmsKinds.contacts))
        messages.searchContacts("Ann", phoneID: phone)
        let new = try XCTUnwrap(lastRequestID(SmsKinds.contacts))
        messages.receive(kind: SmsKinds.contactsResult, data: json(["version": 1, "requestId": old, "contacts": [["name": "Andrei", "address": "+7900"]]]), from: phone)
        XCTAssertTrue(messages.contactResults.isEmpty)
        messages.receive(kind: SmsKinds.contactsResult, data: json(["version": 1, "requestId": new, "contacts": [["name": "Anna", "address": "+9198", "label": "Mobile"]]]), from: phone)
        XCTAssertEqual(messages.contactResults, [SmsContact(name: "Anna", address: "+9198", label: "Mobile")])
    }

    // MARK: The file

    func testTheCacheFileIsOwnerOnlyInAnOwnerOnlyFolder() throws {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        runScheduled()
        let file = store.fileURL(phone)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let fresh = TextMessages(store: store)
        fresh.phoneReady(phone)
        XCTAssertEqual(fresh.data(phone).cache.cursor, SmsCursor(sms: 120, mms: 4), "loads back from the file")
    }

    func testKeepOffWritesNothingAndDeletesTheFiles() {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        runScheduled()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(phone).path))
        keep = false
        messages.keepOnDiskChanged(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": 121, "mms": 4]]), from: phone)
        runScheduled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertEqual(messages.data(phone).cache.cursor, SmsCursor(sms: 120, mms: 4), "memory stays for this run")
    }

    func testThePhoneTurningItOffDeletesWhatThisMacKeptForIt() {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        runScheduled()
        messages.phoneTurnedOff(phone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(phone).path))
        XCTAssertNil(messages.phones[phone])
    }

    func testForgetAndDeleteAllRemoveEverything() {
        let other = "22222222-2222-2222-2222-222222222222"
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        messages.receive(kind: SmsKinds.status, data: status(), from: other)
        runScheduled()
        messages.forget(phone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(phone).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(other).path))
        messages.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertTrue(messages.phones.isEmpty)
    }

    func testAPendingSaveAfterDeleteWritesNothing() {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        messages.deleteAll()
        runScheduled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    // MARK: Small rules

    func testNumbersMatchWhateverTheirFormat() {
        XCTAssertTrue(smsSameNumber("+919876543210", "09876543210"))
        XCTAssertTrue(smsSameNumber("+91 98765 43210", "9876543210"))
        XCTAssertFalse(smsSameNumber("+919876543210", "+919876543211"))
        XCTAssertTrue(smsSameNumber("56767", "56767"))
        XCTAssertFalse(smsSameNumber("56767", "156767"))
    }

    func testHistoryFilesFromBeforeTextMessagesStillLoad() throws {
        let old = #"[{"id":"a","packageName":"p","applicationName":"Messages","title":"Anna","text":"Hi","receivedAt":0}]"#
        let items = try JSONDecoder().decode([NotificationHistoryItem].self, from: Data(old.utf8))
        XCTAssertEqual(items.first?.deviceID, nil)
        XCTAssertFalse(items[0].opensConversation)
        var sms = items[0]
        sms.deviceID = phone
        sms.smsReply = true
        XCTAssertTrue(sms.opensConversation)
        let round = try JSONDecoder().decode([NotificationHistoryItem].self, from: JSONEncoder().encode([sms]))
        XCTAssertEqual(round, [sms])
    }

    func testNotificationFieldsAreReadLeniently() throws {
        struct Probe: Codable { var smsReply: LenientFlag?; var smsThreadId: LenientInteger? }
        let good = try JSONDecoder().decode(Probe.self, from: Data(#"{"smsReply":true,"smsThreadId":12}"#.utf8))
        XCTAssertEqual(good.smsReply?.value, true)
        XCTAssertEqual(good.smsThreadId?.value, 12)
        let odd = try JSONDecoder().decode(Probe.self, from: Data(#"{"smsReply":"yes","smsThreadId":"12"}"#.utf8))
        XCTAssertEqual(odd.smsReply?.value, false)
        XCTAssertNil(odd.smsThreadId?.value)
        XCTAssertEqual(smsReplyAction().identifier, smsReplyActionIdentifier)
    }

    // MARK: Managing conversations

    private func summary(_ id: Int, date: Int, unread: Int = 0, name: String = "Anna", address: String? = nil) -> [String: Any] {
        ["threadId": id, "participants": [["address": address ?? "+91987654\(id)", "name": name]], "snippet": "Line \(id)", "date": date, "unread": unread]
    }

    /// Connected with these conversations listed.
    private func listed(_ threads: [[String: Any]], more: Bool = false) throws {
        messages.receive(kind: SmsKinds.status, data: status(), from: phone)
        let id = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": id, "threads": threads, "more": more]), from: phone)
    }

    private func page(_ thread: Int, _ list: [[String: Any]]) throws {
        messages.open(phone, thread: thread)
        let id = try XCTUnwrap(lastRequestID(SmsKinds.messages))
        messages.receive(kind: SmsKinds.messagesPage, data: json(["version": 1, "requestId": id, "threadId": thread, "messages": list, "more": false]), from: phone)
    }

    private func sync(_ list: [[String: Any]], sms: Int) throws {
        messages.receive(kind: SmsKinds.changed, data: json(["version": 1, "cursor": ["sms": sms, "mms": 4]]), from: phone)
        let id = try XCTUnwrap(lastRequestID(SmsKinds.sync))
        messages.receive(kind: SmsKinds.syncPage, data: json(["version": 1, "requestId": id, "messages": list, "cursor": ["sms": sms, "mms": 4], "more": false]), from: phone)
    }

    private func order(_ filter: SmsListFilter = .all) -> [Int] { messages.rows(phone, filter: filter).map(\.id) }

    func testTheListIsPinnedThenUnreadThenTheRestEachNewestFirst() throws {
        try listed([summary(1, date: 60), summary(2, date: 50, unread: 1), summary(3, date: 40), summary(4, date: 30, unread: 2), summary(5, date: 20)])
        XCTAssertEqual(order(), [2, 4, 1, 3, 5])
        messages.setPinned([5], true, phoneID: phone)
        XCTAssertEqual(order(), [5, 2, 4, 1, 3], "pinned sit above unread")
        XCTAssertEqual(order(.unread), [2, 4])
        XCTAssertEqual(messages.rows(phone, filter: .all).first?.pinned, true)
    }

    func testReadOnThisMacStaysReadUntilANewerMessageWhateverThePhoneSays() throws {
        try listed([summary(7, date: 20, unread: 2)])
        try page(7, [message("s2", date: 20, read: false), message("s1", date: 15, read: false)])
        XCTAssertTrue(messages.isUnread(phone, thread: 7))
        messages.markRead([7], phoneID: phone)
        XCTAssertFalse(messages.isUnread(phone, thread: 7))
        XCTAssertEqual(messages.data(phone).cache.thread(7)?.unread, 2, "the phone still says unread")
        try sync([message("s3", date: 30, body: "Later", read: false)], sms: 121)
        XCTAssertEqual(messages.rows(phone, filter: .all).first?.unread, 1, "only the newer message is unread here")
    }

    func testMarkUnreadIsThisMacOnly() throws {
        try listed([summary(7, date: 20)])
        sent = []
        messages.markUnread([7], phoneID: phone)
        XCTAssertTrue(messages.isUnread(phone, thread: 7))
        XCTAssertEqual(messages.rows(phone, filter: .unread).first?.unread, 1)
        XCTAssertTrue(sent.isEmpty, "the phone cannot be told")
        messages.markRead([7], phoneID: phone)
        XCTAssertFalse(messages.isUnread(phone, thread: 7))
        XCTAssertTrue(sent.isEmpty, "read on the phone already: nothing to ask")
    }

    func testMarkReadAsksThePhoneOnlyForWhatItCountsUnreadAndSaysHowItWent() throws {
        try listed([summary(7, date: 20, unread: 2), summary(8, date: 10), summary(9, date: 5, unread: 1)])
        messages.markRead([7, 8, 9], phoneID: phone)
        let request = try XCTUnwrap(sent.last)
        XCTAssertEqual(request.kind, SmsKinds.markRead)
        XCTAssertEqual(request.payload["threadIds"] as? [Int], [7, 9])
        let id = try XCTUnwrap(request.payload["requestId"] as? String)
        messages.receive(kind: SmsKinds.markReadResult, data: json(["version": 1, "requestId": id,
                                                                    "results": [["threadId": 7, "result": "marked"], ["threadId": 9, "result": "not_shown"]]]), from: phone)
        guard case let .markRead(summary)? = messages.notice?.kind else { return XCTFail("no notice") }
        XCTAssertEqual(summary, SmsMarkReadSummary(total: 2, marked: 1, notShown: 1))
        sent = []
        runScheduled()
        XCTAssertTrue(sent.contains { $0.kind == SmsKinds.threads }, "the phone's counts come back with the list")
        let text = messagesNoticeText(try XCTUnwrap(messages.notice), phone: "Pixel").text
        XCTAssertTrue(text.contains("1 of 2"), text)
    }

    func testMarkReadThatGetsNoAnswerSaysSoAndQuietOnesSayNothing() throws {
        try listed([summary(7, date: 20, unread: 1), summary(8, date: 10, unread: 1)])
        messages.markRead([8], phoneID: phone, report: false)
        runScheduled()
        XCTAssertNil(messages.notice, "a quiet mark (a message read as it arrives) says nothing")
        messages.markRead([7], phoneID: phone)
        runScheduled()
        guard case let .markRead(summary)? = messages.notice?.kind else { return XCTFail("no notice") }
        XCTAssertTrue(summary.noAnswer)
        XCTAssertFalse(messages.isUnread(phone, thread: 7), "read here whatever the phone did")
    }

    func testMarkReadGoesFiftyConversationsAtATime() throws {
        try listed((1...60).map { summary($0, date: 1_000 - $0, unread: 1) })
        sent = []
        messages.markRead(Array(1...60), phoneID: phone)
        XCTAssertEqual(sent.filter { $0.kind == SmsKinds.markRead }.map { ($0.payload["threadIds"] as? [Int])?.count }, [50, 10])
    }

    func testArchivedComesBackWithANewMessageUnlessMuted() throws {
        try listed([summary(7, date: 20), summary(8, date: 10)])
        messages.archive([7, 8], phoneID: phone)
        messages.setMuted([8], true, phoneID: phone)
        XCTAssertEqual(order(), [])
        XCTAssertEqual(order(.archived), [7, 8])
        try sync([message("s5", thread: 7, date: 30, read: false), message("s6", thread: 8, date: 31, read: false)], sms: 121)
        XCTAssertEqual(order(), [7], "a new message brings it back")
        XCTAssertEqual(order(.archived), [8], "muted stays archived")
        XCTAssertNil(messages.manage(phone).archived["7"])
        XCTAssertEqual(messages.unreadCount(phone), 1, "muted and archived conversations are not counted")
    }

    func testADeletedConversationStaysGoneUntilANewerMessageArrives() throws {
        try listed([summary(7, date: 20), summary(8, date: 10)])
        try page(7, [message("s2", date: 20, body: "Secret")])
        messages.deleteThreads([7], phoneID: phone)
        XCTAssertEqual(order(), [8])
        XCTAssertNil(messages.data(phone).cache.thread(7))
        XCTAssertTrue(messages.data(phone).cache.messages(in: 7).isEmpty, "gone from this Mac, file included")
        // The next sync of the list brings it from the phone again: it stays hidden and out of the cache.
        messages.refreshThreads(phone)
        let id = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": id, "threads": [summary(7, date: 20), summary(8, date: 10)], "more": false]), from: phone)
        XCTAssertEqual(order(), [8])
        XCTAssertNil(messages.data(phone).cache.thread(7))
        XCTAssertTrue(messages.search("Secret", phoneID: phone).isEmpty)
        // A newer message ends the tombstone.
        try sync([message("s9", thread: 7, date: 40, body: "New", read: false)], sms: 121)
        let again = try XCTUnwrap(lastRequestID(SmsKinds.threads))
        messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": again, "threads": [summary(7, date: 40, unread: 1), summary(8, date: 10)], "more": false]), from: phone)
        XCTAssertEqual(order(), [7, 8])
        XCTAssertTrue(messages.manage(phone).deleted.isEmpty)
    }

    func testADeletedMessageStaysGoneAndStopsBeingTheConversationsLine() throws {
        try listed([summary(7, date: 20)])
        try page(7, [message("s2", date: 20, body: "Newest"), message("s1", date: 10, body: "Older")])
        messages.deleteMessage("s2", thread: 7, phoneID: phone)
        XCTAssertEqual(messages.visibleMessages(phone, thread: 7).map(\.id), ["s1"])
        XCTAssertEqual(messages.rows(phone, filter: .all).first?.thread.snippet, "Older")
        try page(7, [message("s2", date: 20, body: "Newest"), message("s1", date: 10, body: "Older")])
        XCTAssertEqual(messages.data(phone).cache.messages(in: 7).map(\.id), ["s1"], "a refreshed page does not bring it back")
    }

    func testThisMacsChoicesAreKeptOwnerOnlyAndGoWithTheCache() throws {
        try listed([summary(7, date: 20)])
        messages.setPinned([7], true, phoneID: phone)
        let file = store.managementURL(phone)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Line 7"), "IDs and dates only, never text")
        keep = false
        messages.keepOnDiskChanged(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(phone).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Keep conversations off keeps the choices")
        let fresh = TextMessages(store: store)
        XCTAssertTrue(fresh.manage(phone).isEmpty)
        fresh.phoneReady(phone)
        XCTAssertTrue(fresh.manage(phone).isPinned(7), "loads back from the file")
        messages.forget(phone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        messages.setMuted([7], true, phoneID: phone)
        messages.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertTrue(messages.manage(phone).isEmpty)
    }

    func testSearchFindsMessagesInEveryConversationWithTheMatches() throws {
        try listed([summary(7, date: 20, name: "Anna"), summary(8, date: 10, name: "Bank")])
        try page(7, [message("s2", date: 20, body: "Dinner at Olive?"), message("s1", date: 10, body: "Lunch")])
        try page(8, [message("s5", thread: 8, date: 9, body: "Your OLIVE card statement")])
        let results = messages.search("olive", phoneID: phone)
        XCTAssertEqual(results.messages.map(\.message.id), ["s2", "s5"], "newest first, case does not matter")
        let hit = results.messages[0]
        XCTAssertEqual(String(hit.excerpt[hit.matches[0]]), "Olive")
        XCTAssertEqual(messages.search("bank", phoneID: phone).threads.map(\.id), [8], "names match too")
        XCTAssertTrue(messages.search("   ", phoneID: phone).isEmpty)
    }

    func testTheUnreadDividerSitsAboveTheOldestUnreadMessageNotReadHere() {
        let list = [message("s4", date: 40, read: false), message("s3", date: 30, read: false), message("s2", out: true, date: 25),
                    message("s1", date: 20, read: true)].compactMap(decodeSmsMessage).sorted(by: SmsMessage.newerFirst)
        XCTAssertEqual(smsFirstUnread(list, readThrough: nil)?.id, "s3")
        XCTAssertEqual(smsFirstUnread(list, readThrough: 30)?.id, "s4", "read on this Mac up to s3")
        XCTAssertNil(smsFirstUnread(list, readThrough: 40))
    }

    func testBlockOnPhoneSendsTheNumberAndSaysWhatThePhoneDid() throws {
        try listed([summary(7, date: 20)])
        messages.blockOnPhone("+91 98765 43210", phoneID: phone)
        let request = try XCTUnwrap(sent.last)
        XCTAssertEqual(request.kind, SmsKinds.blockedNumbers)
        XCTAssertEqual(request.payload["address"] as? String, "+919876543210")
        let id = try XCTUnwrap(request.payload["requestId"] as? String)
        messages.receive(kind: SmsKinds.blockedNumbersResult, data: json(["version": 1, "requestId": id, "result": "notified"]), from: phone)
        XCTAssertEqual(messages.notice?.kind, .blocked(.notified, address: "+91 98765 43210"))
        XCTAssertNil(SmsRequests.blockedNumbers("x", address: "HDFCBK")["address"], "a sender name is not a number")
    }

    func testOlderConversationsFillInPageByPageUpTo200() throws {
        try listed((1...30).map { summary($0, date: 10_000 - $0) }, more: true)
        messages.fillThreads(phone)
        var pages = 0
        while let id = lastRequestID(SmsKinds.threads), messages.data(phone).loadingThreads, pages < 10 {
            pages += 1
            let start = 30 + (pages - 1) * 50 + 1
            XCTAssertEqual(sent.last?.payload["limit"] as? Int, 50)
            messages.receive(kind: SmsKinds.threadsPage, data: json(["version": 1, "requestId": id,
                                                                     "threads": (start..<(start + 50)).map { summary($0, date: 10_000 - $0) }, "more": true]), from: phone)
        }
        XCTAssertEqual(pages, 4, "30, then 50 at a time to the cache's 200")
        XCTAssertEqual(messages.data(phone).cache.threads.count, SmsCache.maximumThreads)
    }

    func testAMutedConversationIsMutedPerPhone() throws {
        messages.setMuted([7], true, phoneID: phone)
        XCTAssertTrue(messages.isMuted(phone, thread: 7))
        XCTAssertFalse(messages.isMuted("22222222-2222-2222-2222-222222222222", thread: 7))
    }
}
