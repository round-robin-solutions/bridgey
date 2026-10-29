import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Text messages: the Messages window and its Settings card, rendered from sample state, light and
/// dark. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter MessagesScreenshots
final class MessagesScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    private func thread(_ id: Int, _ name: String?, _ address: String, _ snippet: String, _ date: Date, unread: Int = 0, sim: Int = 1) -> SmsThread {
        SmsThread(threadId: id, participants: [SmsParticipant(address: address, name: name)], snippet: snippet, date: ms(date), unread: unread, subId: sim)
    }

    private func message(_ id: String, out: Bool, _ body: String, _ date: Date, status: SmsMessage.Status? = nil, parts: [SmsPart] = [], sim: Int = 1) -> SmsMessage {
        SmsMessage(id: id, threadId: 7, direction: out ? .outgoing : .incoming, status: status ?? (out ? .sent : .received),
                   date: ms(date), address: "+919876543210", body: body, subId: sim, parts: parts)
    }

    private var photo: NSImage {
        NSImage(size: NSSize(width: 480, height: 360), flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.35, alpha: 1), NSColor(red: 0.55, green: 0.36, blue: 0.85, alpha: 1)])
            gradient?.draw(in: rect, angle: -35)
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 300, y: 210, width: 90, height: 90)).fill()
            NSColor(red: 0.15, green: 0.2, blue: 0.35, alpha: 0.9).setFill()
            let hills = NSBezierPath()
            hills.move(to: NSPoint(x: 0, y: 0))
            hills.line(to: NSPoint(x: 0, y: 120))
            hills.curve(to: NSPoint(x: 480, y: 90), controlPoint1: NSPoint(x: 160, y: 220), controlPoint2: NSPoint(x: 300, y: 40))
            hills.line(to: NSPoint(x: 480, y: 0))
            hills.close()
            hills.fill()
            return true
        }
    }

    private var model: MessagesModel {
        var model = MessagesModel()
        model.now = at(27, 9, 41)
        model.phones = [MessagesPhone(id: phoneID, name: "OnePlus 11")]
        model.phoneID = phoneID
        model.phoneName = "OnePlus 11"
        model.availability = .ready
        model.sims = [SmsSim(subId: 1, slot: 0, label: "Jio"), SmsSim(subId: 2, slot: 1, label: "Airtel")]
        model.codesEnabled = true
        model.threads = [
            thread(7, "Anna Kapoor", "+919876543210", "Perfect, see you at 6", at(27, 9, 38)),
            thread(8, "HDFC Bank", "HDFCBK", "482913 is your OTP for the transaction of Rs 2,499", at(27, 9, 12), unread: 1, sim: 2),
            thread(9, "Mahima", "+919812345678", "Sent the slides, take a look", at(26, 21, 4), unread: 2),
            thread(10, nil, "+919900112233", "Your parcel is out for delivery", at(25, 14, 30), sim: 2),
            SmsThread(threadId: 11, participants: [SmsParticipant(address: "+911", name: "Rohan"), SmsParticipant(address: "+912", name: "Shreya")],
                      snippet: "Dinner on Friday?", date: ms(at(23, 19, 10)), unread: 0, subId: 1),
            thread(12, "Airtel", "AIRTEL", "Your data pack renews tomorrow", at(20, 8, 0), sim: 2),
        ]
        model.target = .thread(7)
        model.messages = [
            message("s105", out: true, "Perfect, see you at 6", at(27, 9, 38), status: .delivered),
            message("s104", out: false, "Booked a table at Olive for 6. Here is the place", at(27, 9, 30)),
            message("m40", out: false, "", at(27, 9, 29), parts: [SmsPart(partId: "p77", mimeType: "image/jpeg", size: 120_034)]),
            message("s103", out: true, "Sounds good. Lunch or dinner?", at(26, 20, 12)),
            message("s102", out: false, "Free on Saturday?", at(26, 20, 5)),
        ].sorted(by: SmsMessage.newerFirst)
        model.images = ["p77": photo]
        return model.listed(SmsManagement())
    }

    /// Managing conversations: unread ones and a pin, the unread divider in an opened conversation.
    private var managed: SmsManagement {
        var manage = SmsManagement()
        manage.setPinned(12, true)
        manage.setMuted(10, true)
        return manage
    }

    @MainActor func testConversation() throws {
        var model = self.model
        model.draft = "Running 10 minutes late"
        try render(model, name: "mac-messages-conversation")
    }

    @MainActor func testCodeAndSendingStates() throws {
        var model = self.model
        model.target = .thread(8)
        model.messages = [
            SmsMessage(id: "s210", threadId: 8, direction: .incoming, status: .received, date: ms(at(27, 9, 12)), address: "HDFCBK",
                       body: "482913 is your OTP for the transaction of Rs 2,499 at Amazon. Valid for 5 minutes. Do not share it with anyone.", subId: 2),
        ]
        model.threads[1].unread = 0
        model = model.listed(SmsManagement())
        model.canSend = false
        try render(model, name: "mac-messages-code", copied: nil)
        var anna = self.model
        anna.outgoing = [
            SmsOutgoing(id: "a", phoneID: phoneID, target: .thread(7), body: "Can you bring the charger?", subId: 1, createdAt: at(27, 9, 40), state: .failed, reason: .noService),
            SmsOutgoing(id: "b", phoneID: phoneID, target: .thread(7), body: "On my way", subId: 1, createdAt: at(27, 9, 41), state: .sending),
        ]
        try render(anna, name: "mac-messages-sending")
    }

    @MainActor func testNewMessage() throws {
        var model = self.model
        model.target = .compose
        model.typedRecipient = "Ann"
        model.contacts = [SmsContact(name: "Anna Kapoor", address: "+91 98765 43210", label: "Mobile"),
                          SmsContact(name: "Anna Kapoor", address: "+91 22 4000 1234", label: "Work"),
                          SmsContact(name: "Annapurna Stores", address: "+91 98111 22334", label: nil)]
        try render(model, name: "mac-messages-new")
    }

    @MainActor func testGroupConversation() throws {
        var model = self.model
        model.target = .thread(11)
        model.messages = [
            SmsMessage(id: "s300", threadId: 11, direction: .incoming, status: .received, date: ms(at(23, 19, 10)), address: "+912", body: "Dinner on Friday?", subId: 1),
            SmsMessage(id: "s299", threadId: 11, direction: .incoming, status: .received, date: ms(at(23, 19, 2)), address: "+911", body: "Who is in town this week?", subId: 1),
        ]
        try render(model, name: "mac-messages-group")
    }

    @MainActor func testUnreadFirstAndTheDivider() throws {
        var model = self.model
        model.threads[0].unread = 2
        model = model.listed(managed)
        model.target = .thread(7)
        model.messages = [
            message("s107", out: false, "Also, can you bring the charger?", at(27, 9, 40)),
            message("s106", out: false, "Running a bit late, table is under Kapoor", at(27, 9, 39)),
            message("s105", out: true, "Perfect, see you at 6", at(27, 9, 38), status: .delivered),
            message("s104", out: false, "Booked a table at Olive for 6. Here is the place", at(27, 9, 30)),
            message("s103", out: true, "Sounds good. Lunch or dinner?", at(26, 20, 12)),
            message("s102", out: false, "Free on Saturday?", at(26, 20, 5)),
        ].sorted(by: SmsMessage.newerFirst)
        model.unreadFrom = "s106"
        model.notice = MessagesNoticeText(id: "n", text: "Also marked read on OnePlus 11.", symbol: "checkmark.circle", good: true)
        try render(model, name: "mac-messages-unread-first")
    }

    @MainActor func testUnreadFilterArchivedAndSearch() throws {
        var unread = self.model.listed(managed, filter: .unread)
        unread.target = nil
        try render(unread, name: "mac-messages-filter-unread")
        var manage = managed
        manage.archive(SmsThread(threadId: 12, participants: [], snippet: "", date: ms(at(20, 8, 0)), unread: 0))
        manage.archive(SmsThread(threadId: 11, participants: [], snippet: "", date: ms(at(23, 19, 10)), unread: 0))
        var archived = self.model.listed(manage, filter: .archived)
        archived.target = .thread(11)
        archived.messages = [
            SmsMessage(id: "s300", threadId: 11, direction: .incoming, status: .received, date: ms(at(23, 19, 10)), address: "+912", body: "Dinner on Friday?", subId: 1),
        ]
        try render(archived, name: "mac-messages-archived")
        var search = self.model
        search.query = "olive"
        search.search = search.cache.search("olive", management: SmsManagement())
        search.focusMessage = "s104"
        try render(search, name: "mac-messages-search")
    }

    @MainActor func testSeveralSelected() throws {
        var model = self.model
        model.selected = [8, 9, 10]
        model.selecting = true
        try render(model, name: "mac-messages-bulk")
    }

    @MainActor func testStates() throws {
        var permission = MessagesModel()
        permission.availability = .needsPermission("OnePlus 11")
        try render(permission, name: "mac-messages-permission")
        var off = MessagesModel()
        off.availability = .macOff
        try render(off, name: "mac-messages-off")
    }

    @MainActor func testSettingsCard() throws {
        var settings = SettingsModel()
        settings.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        settings.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, $0 != .remoteInput) })
        settings.remoteFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        settings.notificationsAuthorized = true
        settings.smsEnabled = true
        settings.smsKeepOnMac = true
        settings.smsPhone = .ready("OnePlus 11", SmsPhoneStatus(read: true, send: true, contacts: true,
                                                                sims: [SmsSim(subId: 1, slot: 0, label: "Jio"), SmsSim(subId: 2, slot: 1, label: "Airtel")],
                                                                cursor: .zero))
        settings.historyEnabled = true
        settings.history = [NotificationHistoryItem(id: "1", packageName: "com.google.android.apps.messaging", applicationName: "Messages",
                                                    title: "Anna Kapoor", text: "Booked a table at Olive for 6", receivedAt: at(27, 9, 30),
                                                    deviceID: phoneID, notificationID: "n1", smsThreadID: 7, smsReply: true)]
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(SettingsPane.messages.title).font(BrandFont.heading(24)).frame(height: 30)
                    TextMessagesPane(model: settings, actions: SettingsActions())
                }
                .padding(32)
                .frame(width: 670, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            }
            try write(view, scheme: scheme, name: "mac-messages-settings-\(scheme == .dark ? "dark" : "light")")
        }
    }

    // MARK: Rendering

    @MainActor private func render(_ model: MessagesModel, name: String, copied: String? = nil) throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                MessagesView(model: model, actions: MessagesActions(), copiedMessage: copied)
                    .frame(width: MessagesView.size.width, height: MessagesView.size.height)
            }
            try write(view, scheme: scheme, name: "\(name)-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true)
            .environment(\.locale, Locale(identifier: "en_GB")))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

private extension MessagesModel {
    /// The cache these sample threads and messages make (for the list's order and search).
    var cache: SmsCache {
        var cache = SmsCache()
        cache.applyThreads(threads, first: true, more: false)
        if case let .thread(id)? = target { cache.applyMessages(messages.filter { $0.threadId == id }, thread: id, before: nil, more: false) }
        // Search finds Anna's messages wherever the sample opens.
        cache.applyMessages([
            SmsMessage(id: "s104", threadId: 7, direction: .incoming, status: .received, date: threads.first { $0.threadId == 7 }!.date - 480_000,
                       address: "+919876543210", body: "Booked a table at Olive for 6. Here is the place"),
        ], thread: 7, before: nil, more: true)
        cache.applyMessages([
            SmsMessage(id: "s801", threadId: 8, direction: .incoming, status: .received, date: threads.first { $0.threadId == 8 }!.date - 86_400_000 * 3,
                       address: "HDFCBK", body: "Thank you for using your card at OLIVE BAR AND KITCHEN for Rs 3,240"),
        ], thread: 8, before: nil, more: true)
        return cache
    }

    /// The list as the window builds it from the cache.
    func listed(_ manage: SmsManagement, filter: SmsListFilter = .all) -> MessagesModel {
        var model = self
        let cache = SmsCache().with(threads)
        model.filter = filter
        model.rows = cache.rows(manage, filter: filter)
        let all = cache.rows(manage, filter: .all), archived = cache.rows(manage, filter: .archived)
        model.states = Dictionary((all + archived).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.unreadConversations = all.filter { $0.unread > 0 }.count
        model.archivedCount = archived.count
        return model
    }
}

private extension SmsCache {
    func with(_ threads: [SmsThread]) -> SmsCache {
        var cache = self
        cache.applyThreads(threads, first: true, more: false)
        return cache
    }
}
