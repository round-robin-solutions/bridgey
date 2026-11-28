import Combine
import Foundation
import UIKit

/// The phone's text messages (`sms_draft1`, area 1): its conversations, one conversation, replies and new messages.
/// bridgey_core keeps the conversations and talks to the phone (rust/client/src/sms.rs); this model asks it for what
/// to show after each change, as the Windows app does (MessagesViewModel.cs). Pictures stay in memory.
@MainActor
final class MessagesModel: ObservableObject, SessionFeature {
    private(set) weak var app: AppModel?
    private var client: CoreClient?
    private var watching: AnyCancellable?

    /// The phone the views show.
    @Published private(set) var phoneID: String?
    @Published private(set) var status = Status()
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var moreConversations = false
    @Published private(set) var loadingConversations = false
    @Published var unreadOnly = false { didSet { if unreadOnly != oldValue { reload() } } }

    /// The open conversation and its messages, oldest first.
    @Published private(set) var openThread: Int64?
    @Published private(set) var messages: [MessageRow] = []
    @Published private(set) var olderMessages = false
    @Published private(set) var canSend = false
    @Published private(set) var sims: [Sim] = []
    /// Pictures from the phone, kept while Bridgey runs.
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var failedImages: Set<String> = []

    /// What the phone found for a new message.
    @Published private(set) var contacts: [ContactRow] = []
    /// What Mark as read did, or why a text didn't go.
    @Published var notice: String?

    struct Status: Equatable {
        var available = false
        /// The phone answered with its status (permissions and SIMs).
        var phoneKnown = false
        var canRead = false
        var canSend = false
        var syncing = false
        var problem: String?
        var unread = 0
    }

    struct Conversation: Identifiable, Equatable {
        let threadID: Int64
        var title: String
        var snippet: String
        var date: Int64
        var unread: Int
        var group: Bool
        /// The first participant's number, for Block on phone.
        var address: String

        var id: Int64 { threadID }
    }

    struct Sim: Identifiable, Equatable {
        let subID: Int64
        var label: String
        var id: Int64 { subID }
    }

    struct ContactRow: Identifiable, Equatable {
        var name: String
        var address: String
        var label: String?
        var id: String { "\(name)|\(address)" }
    }

    struct MessageRow: Identifiable, Equatable {
        enum State: Equatable { case none, sending, sent, delivered, failed }

        /// The phone's message ID, or "out:<request>" for a text this device is sending.
        let id: String
        var incoming: Bool
        var body: String
        var date: Int64
        var state: State = .none
        /// The first picture of an MMS.
        var partID: String?
        /// This device's send, until the phone's own list has it.
        var requestID: String?

        var canRetry: Bool { state == .failed && requestID != nil }
    }

    // MARK: Session

    func attach(_ app: AppModel) {
        self.app = app
        // Keep conversations (Settings): the library keeps or deletes what it stored.
        watching = app.settings.$keepConversations.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyKeep() }
        }
    }

    func clientChanged(_ client: CoreClient?) {
        self.client = client
        if client == nil {
            conversations = []
            messages = []
            openThread = nil
            contacts = []
            images = [:]
            failedImages = []
            status = Status()
            loadingConversations = false
        } else {
            applyKeep()
        }
    }

    func handle(_ e: CoreEvent) {
        switch e.kind {
        case .trustChanged, .connected:
            applyKeep()
            if e.kind == .connected, e.deviceID == phoneID { loadStatus() }
        case .features where e.deviceID == phoneID:
            loadStatus()
        case .disconnected where e.deviceID == phoneID:
            loadStatus()
        case .sms where e.deviceID == phoneID:
            apply(e.name ?? "", e.json)
        default:
            break
        }
    }

    private func apply(_ what: String, _ detail: [String: Any]) {
        switch what {
        case "status":
            loadStatus()
        case "changed":
            reload()
            if let open = openThread, detail["threadId"] == nil || Self.int(detail["threadId"]) == open {
                showMessages(command(["op": "messages", "threadId": open]))
            }
        case "send":
            if let open = openThread { showMessages(command(["op": "messages", "threadId": open])) }
            if let state = detail["state"] as? String, state == "failed" || state == "refused" {
                notice = Self.sendProblem(detail["reason"] as? String)
            }
        case "image":
            guard let part = detail["partId"] as? String else { break }
            if let data = (detail["data"] as? String).flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) {
                images[part] = image
            } else {
                failedImages.insert(part)
            }
        case "contacts":
            contacts = (detail["contacts"] as? [[String: Any]] ?? []).compactMap { c in
                guard let name = c["name"] as? String, let address = c["address"] as? String else { return nil }
                return ContactRow(name: name, address: address, label: c["label"] as? String)
            }
        case "notice":
            if let text = Self.noticeText(detail) { notice = text }
        default:
            break
        }
    }

    // MARK: Showing a phone

    /// The Messages screen opened for a phone: its status, what is kept, then the newest from the phone.
    func show(_ deviceID: String) {
        if phoneID != deviceID {
            phoneID = deviceID
            conversations = []
            messages = []
            openThread = nil
            contacts = []
            notice = nil
        }
        loadStatus()
        reload()
        if status.available { refresh() }
    }

    /// This device's Text messages for the phone: on for this phone only, so other phones don't start sharing theirs.
    func turnOn() {
        guard let app, let id = phoneID, let device = app.device(id) else { return }
        app.setFeature(device, key: "sms_draft1", on: true)
    }

    func refresh() {
        loadingConversations = true
        let answer = command(["op": "refresh"])
        if !Self.ok(answer) {
            loadingConversations = false
            if answer["error"] as? String == "not_connected" { notice = notConnected }
        }
    }

    func loadOlder() {
        _ = command(["op": "older_threads"])
    }

    /// The list again from what the library keeps.
    func reload() {
        guard phoneID != nil else { return }
        var cmd: [String: Any] = ["op": "threads", "filter": unreadOnly ? "unread" : "all"]
        if let open = openThread { cmd["holding"] = open }
        let answer = command(cmd)
        guard Self.ok(answer) else { return }
        moreConversations = answer["more"] as? Bool ?? false
        loadingConversations = answer["loading"] as? Bool ?? false
        conversations = (answer["threads"] as? [[String: Any]] ?? []).compactMap(Self.conversation)
    }

    private func loadStatus() {
        let s = command(["op": "status"])
        var next = Status()
        next.available = s["available"] as? Bool ?? false
        if let phone = s["phone"] as? [String: Any] {
            next.phoneKnown = true
            next.canRead = phone["read"] as? Bool ?? false
            next.canSend = phone["send"] as? Bool ?? false
            sims = (phone["sims"] as? [[String: Any]] ?? []).compactMap { sim in
                guard let sub = Self.int(sim["subId"]) else { return nil }
                let slot = Self.int(sim["slot"]) ?? 0
                let label = (sim["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "SIM \(Int(slot) + 1)")
                return Sim(subID: sub, label: label)
            }
        }
        next.syncing = s["syncing"] as? Bool ?? false
        next.problem = s["problem"] as? String
        next.unread = Int(Self.int(s["unread"]) ?? 0)
        status = next
    }

    /// One short line about why the list can't show, or nil.
    var statusText: String? {
        guard let id = phoneID else { return nil }
        let name = app?.deviceName(id) ?? String(localized: "the phone")
        if !(app?.device(id)?.connected ?? false) { return String(localized: "\(name) isn’t connected.") }
        if !status.available { return nil }
        if !status.phoneKnown { return String(localized: "Waiting for \(name)…") }
        if !status.canRead { return String(localized: "\(name) needs permission to read texts. Open Bridgey on the phone.") }
        return nil
    }

    // MARK: A conversation

    /// Opens a conversation: its newest messages from the phone, and read here and on the phone, as on Windows.
    func open(_ thread: Int64) {
        openThread = thread
        messages = []
        olderMessages = false
        showMessages(command(["op": "open", "threadId": thread]))
        if let c = conversations.first(where: { $0.threadID == thread }), c.unread > 0 { markRead(c) }
    }

    func close(_ thread: Int64) {
        guard openThread == thread else { return }
        _ = command(["op": "close"])
        openThread = nil
        messages = []
    }

    func loadOlderMessages() {
        guard let open = openThread else { return }
        _ = command(["op": "older_messages", "threadId": open])
    }

    private func showMessages(_ answer: [String: Any]) {
        guard Self.ok(answer) else { return }
        olderMessages = answer["older"] as? Bool ?? false
        canSend = answer["canSend"] as? Bool ?? false
        if let thread = answer["thread"] as? [String: Any], let c = Self.conversation(thread),
           let i = conversations.firstIndex(where: { $0.threadID == c.threadID }) {
            conversations[i] = c
        }
        // The library lists newest first; a conversation reads oldest at the top.
        var rows: [MessageRow] = (answer["messages"] as? [[String: Any]] ?? []).reversed().compactMap(Self.message)
        rows += (answer["outgoing"] as? [[String: Any]] ?? []).compactMap(Self.outgoing)
        messages = rows
        for part in rows.compactMap(\.partID) where images[part] == nil && !failedImages.contains(part) {
            _ = command(["op": "image", "partId": part])
        }
    }

    /// Sends a text to the open conversation or to a number; false (with a notice) when it couldn't go.
    @discardableResult
    func send(_ body: String, thread: Int64? = nil, address: String? = nil, sim: Int64? = nil) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var cmd: [String: Any] = ["op": "send", "body": body]
        if let thread { cmd["threadId"] = thread } else if let address { cmd["address"] = address.trimmingCharacters(in: .whitespaces) } else { return false }
        if let sim, sims.count > 1 { cmd["subId"] = sim }
        let answer = command(cmd)
        guard Self.ok(answer) else {
            notice = answer["error"] as? String == "invalid" ? String(localized: "That number can’t take texts.") : notConnected
            return false
        }
        if let open = openThread, thread == open {
            showMessages(command(["op": "messages", "threadId": open]))
        } else {
            refresh()
        }
        return true
    }

    func retry(_ row: MessageRow) {
        guard let id = row.requestID else { return }
        _ = command(["op": "retry", "requestId": id])
        if let open = openThread { showMessages(command(["op": "messages", "threadId": open])) }
    }

    func discard(_ row: MessageRow) {
        guard let id = row.requestID else { return }
        _ = command(["op": "discard", "requestId": id])
        messages.removeAll { $0.id == row.id }
    }

    func markRead(_ c: Conversation) {
        _ = command(["op": "mark_read", "threadIds": [c.threadID]])
        reload()
    }

    func markUnread(_ c: Conversation) {
        _ = command(["op": "mark_unread", "threadIds": [c.threadID]])
        reload()
    }

    /// Opens Android's Blocked numbers on the phone, with the conversation's number.
    func blockOnPhone(_ c: Conversation) {
        let answer = command(["op": "block", "address": c.address])
        if !Self.ok(answer) { notice = notConnected }
    }

    /// Contacts for the To field: names only (a number needs no search), two letters or more.
    func searchContacts(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !q.contains(where: \.isNumber) else {
            contacts = []
            return
        }
        _ = command(["op": "contacts", "query": q])
    }

    func clearContacts() { contacts = [] }

    // MARK: Helpers

    private var notConnected: String {
        String(localized: "\(phoneID.flatMap { app?.deviceName($0) } ?? String(localized: "Your phone")) isn’t connected.")
    }

    /// Keep conversations on this device: a setting of the library's, carried by any trusted device.
    private func applyKeep() {
        guard let client, let app, let any = (try? client.snapshot())?.devices.first?.deviceId else { return }
        _ = client.phone(.sms, deviceID: any, command: ["op": "keep", "on": app.settings.keepConversations])
    }

    private func command(_ cmd: [String: Any]) -> [String: Any] {
        guard let client, let id = phoneID else { return ["ok": false, "error": "not_connected"] }
        return client.phone(.sms, deviceID: id, command: cmd)
    }

    nonisolated static func ok(_ answer: [String: Any]) -> Bool { answer["ok"] as? Bool == true }

    nonisolated static func int(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: n.int64Value
        case let i as Int: Int64(i)
        case let i as Int64: i
        default: nil
        }
    }

    nonisolated static func conversation(_ t: [String: Any]) -> Conversation? {
        guard let id = int(t["threadId"]) else { return nil }
        let participants = t["participants"] as? [[String: Any]] ?? []
        return Conversation(threadID: id, title: t["title"] as? String ?? "", snippet: t["snippet"] as? String ?? "",
                            date: int(t["date"]) ?? 0, unread: Int(int(t["unread"]) ?? 0), group: t["group"] as? Bool ?? false,
                            address: participants.first?["address"] as? String ?? "")
    }

    nonisolated static func message(_ m: [String: Any]) -> MessageRow? {
        guard let id = m["id"] as? String else { return nil }
        let incoming = m["direction"] as? String == "in"
        let state: MessageRow.State = incoming ? .none : {
            switch m["status"] as? String {
            case "pending": .sending
            case "failed": .failed
            case "delivered": .delivered
            default: .none
            }
        }()
        let part = (m["parts"] as? [[String: Any]] ?? []).lazy.compactMap { $0["partId"] as? String }.first
        return MessageRow(id: id, incoming: incoming, body: m["body"] as? String ?? "", date: int(m["date"]) ?? 0, state: state, partID: part)
    }

    nonisolated static func outgoing(_ o: [String: Any]) -> MessageRow? {
        guard let request = o["requestId"] as? String else { return nil }
        let state: MessageRow.State = switch o["state"] as? String {
        case "sending": .sending
        case "sent": .sent
        case "delivered": .delivered
        default: .failed
        }
        return MessageRow(id: "out:\(request)", incoming: false, body: o["body"] as? String ?? "", date: int(o["date"]) ?? 0, state: state, requestID: request)
    }

    /// Why the phone didn't send a text.
    nonisolated static func sendProblem(_ reason: String?) -> String {
        switch reason {
        case "disabled": String(localized: "Text messages is off for this device on your phone.")
        case "permission": String(localized: "Your phone needs permission to send texts. Open Bridgey on the phone.")
        case "group": String(localized: "Group conversations are answered on the phone.")
        case "no_sim": String(localized: "That SIM isn’t active on your phone.")
        case "rate_limited": String(localized: "Too many texts at once. Try again in a moment.")
        case "radio_off", "no_service": String(localized: "Your phone has no mobile signal right now.")
        case "invalid": String(localized: "Your phone can’t send to that number.")
        default: String(localized: "The text wasn’t sent.")
        }
    }

    /// What Mark as read or Block on phone did, when it needs saying.
    nonisolated static func noticeText(_ d: [String: Any]) -> String? {
        switch d["kind"] as? String {
        case "mark_read":
            if d["noAnswer"] as? Bool == true { return String(localized: "Your phone didn’t answer, so it still counts them unread.") }
            if d["disabled"] as? Bool == true { return String(localized: "Text messages is off for this device on your phone.") }
            let left = Int(int(d["total"]) ?? 0) - Int(int(d["marked"]) ?? 0)
            guard left > 0 else { return nil }
            if left == 1 { return String(localized: "1 conversation stays unread on your phone. Open it there to clear it.") }
            return String(localized: "\(left) conversations stay unread on your phone. Open them there to clear them.")
        case "blocked":
            switch d["result"] as? String {
            case "opened": return String(localized: "Blocked numbers is open on your phone.")
            case "notified": return String(localized: "Tap the notification on your phone to open Blocked numbers.")
            case "unavailable": return String(localized: "Your phone has no Blocked numbers screen.")
            default: return String(localized: "Your phone didn’t answer.")
            }
        default:
            return nil
        }
    }

    /// "15:20", "Yesterday", "Monday", "3 Nov", "3 Nov 2025".
    nonisolated static func when(_ ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard ms > 0 else { return "" }
        let at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        if calendar.isDate(at, inSameDayAs: now) { return at.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), at >= week {
            return at.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: at) == calendar.component(.year, from: now) {
            return at.formatted(.dateTime.day().month(.abbreviated))
        }
        return at.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
