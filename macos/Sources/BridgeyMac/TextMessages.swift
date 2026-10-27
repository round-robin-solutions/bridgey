import AppKit
import Foundation

/*
 * Text messages (draft sms_draft1): keeps each phone's conversations in step with the phone, with as
 * little traffic as it can (docs/protocol.md, "Incremental sync"):
 *  - no cache yet: the phone's cursor from sms.status is the starting point (the history is never
 *    copied in bulk) and the newest 30 conversations load;
 *  - with a cache: sms.sync from the cursor on connect and after each sms.changed, following `more`
 *    for at most 10 pages, then waiting for the next change;
 *  - older conversations and older messages load only when scrolled to; an open conversation's newest
 *    page is refreshed after a change, at most once every 2 seconds;
 *  - MMS images load when shown, at most 4 at a time, and stay in memory only.
 * The transport is a closure, so the logic is tested without a phone.
 */

/// A send from this Mac, until the phone's provider has the message (or it failed).
struct SmsOutgoing: Identifiable, Equatable {
    let id: String
    let phoneID: String
    let target: SmsRequests.Target
    let body: String
    let subId: Int?
    let createdAt: Date
    var state: SmsSendState = .sending
    var reason: SmsSendReason?
    var via: String?

    var isNotificationReply: Bool { if case .notification = target { true } else { false } }
    var isFinal: Bool { state == .failed || state == .refused || state == .delivered }
    var failed: Bool { state == .failed || state == .refused }
}

/// One phone's conversations as this Mac knows them.
struct SmsPhoneData: Equatable {
    var status: SmsPhoneStatus?
    var cache = SmsCache()
    var loadingThreads = false
    var loadingMessages: Set<Int> = []
    var syncing = false
    /// The last threads or messages request failed (the phone answered an error, or nothing came).
    var problem: String?
}

@MainActor
final class TextMessages: ObservableObject {
    static let requestTimeout: TimeInterval = 15
    static let maximumSyncPages = 10
    static let maximumOpenAttachments = 4
    static let refreshSpacing: TimeInterval = 2
    static let maximumImages = 80

    @Published private(set) var phones: [String: SmsPhoneData] = [:]
    @Published private(set) var outgoing: [SmsOutgoing] = []
    /// Decoded MMS images by `phoneID|partID`, in memory only.
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var contactResults: [SmsContact] = []
    @Published private(set) var contactsSearching = false
    /// The conversation shown in the Messages window, refreshed after each change.
    @Published private(set) var openConversation: (phoneID: String, threadId: Int)?

    /// Sends one encrypted message to the phone; false when it could not go.
    var send: (_ phoneID: String, _ kind: String, _ payload: [String: Any]) -> Bool = { _, _, _ in false }
    /// Text messages is on here and on the phone, and the phone is connected.
    var isAvailable: (_ phoneID: String) -> Bool = { _ in false }
    /// Settings > Text messages > Keep conversations on this Mac.
    var keepOnDisk: () -> Bool = { true }
    /// A reply from a notification did not go (the Mac says so in a notification).
    var onReplyFailed: (SmsOutgoing) -> Void = { _ in }
    var now: () -> Date = Date.init
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    var newRequestID: () -> String = { UUID().uuidString.lowercased() }

    private let store: SmsStore
    private var loaded: Set<String> = []
    private var pending: [String: Pending] = [:]
    private var syncPages: [String: Int] = [:]
    private var lastRefresh: [String: Date] = [:]
    private var imageQueue: [(phoneID: String, partID: String)] = []
    private var imageOrder: [String] = []
    private var failedImages: Set<String> = []
    private var saveScheduled: Set<String> = []
    private var contactsRequest: String?

    private enum Pending: Equatable {
        case threads(phoneID: String, first: Bool)
        case messages(phoneID: String, thread: Int, before: SmsMessage?)
        case sync(phoneID: String)
        case attachment(phoneID: String, partID: String)
        case contacts(phoneID: String)
        case send(phoneID: String)

        var phoneID: String {
            switch self {
            case let .threads(id, _), let .messages(id, _, _), let .sync(id), let .attachment(id, _), let .contacts(id), let .send(id): id
            }
        }
    }

    init(store: SmsStore = SmsStore()) {
        self.store = store
    }

    func data(_ phoneID: String) -> SmsPhoneData { phones[phoneID] ?? SmsPhoneData() }

    // MARK: Lifecycle

    /// The key is on both sides for `phoneID` (after its features.update): the cache loads from disk
    /// and the phone's sms.status starts the sync.
    func phoneReady(_ phoneID: String) {
        ensureLoaded(phoneID)
    }

    /// The phone turned Text messages off: what this Mac kept for it goes.
    func phoneTurnedOff(_ phoneID: String) {
        forget(phoneID)
    }

    /// The session ended: requests in flight are dropped; the cache stays.
    func disconnected(_ phoneID: String) {
        for (id, request) in pending where request.phoneID == phoneID { pending.removeValue(forKey: id) }
        imageQueue.removeAll { $0.phoneID == phoneID }
        syncPages.removeValue(forKey: phoneID)
        guard var phone = phones[phoneID] else { return }
        phone.status = nil
        phone.loadingThreads = false
        phone.loadingMessages = []
        phone.syncing = false
        phones[phoneID] = phone
        for index in outgoing.indices where outgoing[index].phoneID == phoneID && outgoing[index].state == .sending {
            outgoing[index].state = .failed
            outgoing[index].reason = .failed
        }
    }

    /// Forgotten, unpaired or turned off by the phone: memory and file.
    func forget(_ phoneID: String) {
        disconnected(phoneID)
        phones.removeValue(forKey: phoneID)
        loaded.remove(phoneID)
        outgoing.removeAll { $0.phoneID == phoneID }
        for key in images.keys where key.hasPrefix(phoneID + "|") { images.removeValue(forKey: key) }
        imageOrder.removeAll { $0.hasPrefix(phoneID + "|") }
        if openConversation?.phoneID == phoneID { openConversation = nil }
        store.delete(phoneID)
    }

    /// Text messages turned off on this Mac, or Reset: everything goes.
    func deleteAll() {
        for id in Array(phones.keys) { forget(id) }
        pending.removeAll()
        imageQueue.removeAll()
        images.removeAll()
        imageOrder.removeAll()
        failedImages.removeAll()
        outgoing.removeAll()
        contactResults = []
        openConversation = nil
        store.deleteAll()
    }

    /// Keep conversations on this Mac changed: off deletes the files (memory stays for this run).
    func keepOnDiskChanged(_ keep: Bool) {
        if keep {
            for (id, phone) in phones { store.save(phone.cache, for: id) }
        } else {
            store.deleteAll()
        }
    }

    private func ensureLoaded(_ phoneID: String) {
        guard !loaded.contains(phoneID) else { return }
        loaded.insert(phoneID)
        var phone = phones[phoneID] ?? SmsPhoneData()
        if keepOnDisk(), let cache = store.load(phoneID) { phone.cache = cache }
        phones[phoneID] = phone
    }

    // MARK: Receiving

    /// One decrypted sms.* message from `phoneID`. Malformed ones are dropped; the session stays.
    func receive(kind: String, data: Data, from phoneID: String) {
        guard let limit = SmsLimits.incoming(kind), data.count <= limit else { return }
        ensureLoaded(phoneID)
        switch kind {
        case SmsKinds.status:
            guard let status = decodeSmsStatus(data) else { return }
            statusArrived(status, from: phoneID)
        case SmsKinds.changed:
            guard let cursor = decodeSmsChanged(data) else { return }
            changed(cursor, from: phoneID)
        case SmsKinds.threadsPage:
            guard let page = decodeSmsThreadsPage(data), case let .threads(owner, first)? = pending[page.requestID], owner == phoneID else { return }
            pending.removeValue(forKey: page.requestID)
            update(phoneID) { phone in
                phone.loadingThreads = false
                phone.problem = page.error
                if page.error == nil { phone.cache.applyThreads(page.threads, first: first, more: page.more) }
            }
            persist(phoneID)
        case SmsKinds.messagesPage:
            guard let page = decodeSmsMessagesPage(data),
                  case let .messages(owner, thread, before)? = pending[page.requestID], owner == phoneID, thread == page.threadId else { return }
            pending.removeValue(forKey: page.requestID)
            update(phoneID) { phone in
                phone.loadingMessages.remove(thread)
                phone.problem = page.error
                if page.error == nil { phone.cache.applyMessages(page.messages, thread: thread, before: before, more: page.more) }
            }
            reconcile(page.messages, phoneID: phoneID)
            persist(phoneID)
        case SmsKinds.syncPage:
            guard let page = decodeSmsSyncPage(data), case let .sync(owner)? = pending[page.requestID], owner == phoneID else { return }
            pending.removeValue(forKey: page.requestID)
            syncArrived(page, from: phoneID)
        case SmsKinds.sendStatus:
            guard let status = decodeSmsSendStatus(data) else { return }
            sendStatusArrived(status, from: phoneID)
        case SmsKinds.attachmentData:
            guard let attachment = decodeSmsAttachment(data), case let .attachment(owner, part)? = pending[attachment.requestID],
                  owner == phoneID, part == attachment.partID else { return }
            pending.removeValue(forKey: attachment.requestID)
            let key = imageKey(phoneID, part)
            if let bytes = attachment.data, let image = NSImage(data: bytes) {
                remember(image, key: key)
            } else {
                failedImages.insert(key)
            }
            pumpImages()
        case SmsKinds.contactsResult:
            guard let result = decodeSmsContactsResult(data), result.requestID == contactsRequest else { return }
            pending.removeValue(forKey: result.requestID)
            contactsRequest = nil
            contactsSearching = false
            contactResults = result.contacts
        default:
            break
        }
    }

    private func statusArrived(_ status: SmsPhoneStatus, from phoneID: String) {
        update(phoneID) { $0.status = status }
        guard status.read else { return }
        let phone = data(phoneID)
        if phone.cache.cursor == nil {
            // No cache: start from the phone's cursor; only the newest conversations load.
            update(phoneID) { $0.cache.cursor = status.cursor }
            requestThreads(phoneID, first: true)
            persist(phoneID)
        } else {
            // With a cache only the sync goes; summaries refresh when the Messages window shows them.
            if phone.cache.threads.isEmpty { requestThreads(phoneID, first: true) }
            startSync(phoneID)
        }
    }

    private func changed(_ cursor: SmsCursor, from phoneID: String) {
        update(phoneID) { $0.status?.cursor = cursor }
        guard let mine = data(phoneID).cache.cursor else { return }
        if mine.isBehind(cursor) { startSync(phoneID) }
        refreshOpenConversation(phoneID)
    }

    private func syncArrived(_ page: SmsSyncPage, from phoneID: String) {
        guard page.error == nil else {
            update(phoneID) {
                $0.syncing = false
                $0.problem = page.error
            }
            return
        }
        if page.reset {
            // The phone was restored or this Mac fell too far behind: start again from its cursor.
            update(phoneID) { phone in
                phone.cache = SmsCache()
                phone.cache.cursor = page.cursor
                phone.syncing = false
            }
            syncPages.removeValue(forKey: phoneID)
            requestThreads(phoneID, first: true)
            persist(phoneID)
            return
        }
        var unknown = Set<Int>()
        update(phoneID) { phone in
            unknown = phone.cache.applySync(page.messages)
            phone.cache.cursor = page.cursor
        }
        reconcile(page.messages, phoneID: phoneID)
        if !unknown.isEmpty, !data(phoneID).loadingThreads { requestThreads(phoneID, first: true) }
        let pages = (syncPages[phoneID] ?? 0) + 1
        syncPages[phoneID] = pages
        if page.more && pages < Self.maximumSyncPages {
            sendSync(phoneID)
        } else {
            syncPages.removeValue(forKey: phoneID)
            update(phoneID) { $0.syncing = false }
        }
        persist(phoneID)
    }

    private func sendStatusArrived(_ status: SmsSendStatus, from phoneID: String) {
        guard let index = outgoing.firstIndex(where: { $0.id == status.requestID && $0.phoneID == phoneID }) else { return }
        pending.removeValue(forKey: status.requestID)
        // A late "sent" never undoes "delivered".
        if outgoing[index].state == .delivered, status.status == .sent { return }
        outgoing[index].state = status.status
        outgoing[index].reason = status.reason
        if let via = status.via { outgoing[index].via = via }
        let item = outgoing[index]
        if item.failed, item.isNotificationReply { onReplyFailed(item) }
        if item.isNotificationReply, item.state == .sent || item.state == .delivered {
            outgoing.remove(at: index)
        }
    }

    /// Messages the phone now has replace this Mac's pending bubbles for them.
    private func reconcile(_ messages: [SmsMessage], phoneID: String) {
        let sent = messages.filter { $0.direction == .outgoing }
        guard !sent.isEmpty, !outgoing.isEmpty else { return }
        outgoing.removeAll { item in
            guard item.phoneID == phoneID, !item.failed else { return false }
            return sent.contains { message in
                guard message.body == item.body, message.sentAt >= item.createdAt.addingTimeInterval(-120) else { return false }
                switch item.target {
                case let .thread(id): return message.threadId == id
                case let .address(address): return smsSameNumber(message.address, address)
                case .notification: return false
                }
            }
        }
    }

    // MARK: Asking the phone

    @discardableResult
    private func request(_ kind: String, _ payload: [String: Any], as entry: Pending, id: String) -> Bool {
        guard isAvailable(entry.phoneID), send(entry.phoneID, kind, payload) else { return false }
        pending[id] = entry
        schedule(Self.requestTimeout) { [weak self] in self?.timedOut(id) }
        return true
    }

    private func timedOut(_ id: String) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        let phoneID = entry.phoneID
        switch entry {
        case .threads:
            update(phoneID) { $0.loadingThreads = false }
        case let .messages(_, thread, _):
            update(phoneID) { $0.loadingMessages.remove(thread) }
        case .sync:
            syncPages.removeValue(forKey: phoneID)
            update(phoneID) { $0.syncing = false }
        case let .attachment(_, part):
            failedImages.insert(imageKey(phoneID, part))
            pumpImages()
        case .contacts:
            contactsRequest = nil
            contactsSearching = false
        case .send:
            if let index = outgoing.firstIndex(where: { $0.id == id }), outgoing[index].state == .sending {
                outgoing[index].state = .failed
                outgoing[index].reason = .failed
                if outgoing[index].isNotificationReply { onReplyFailed(outgoing[index]) }
            }
        }
    }

    private func requestThreads(_ phoneID: String, first: Bool) {
        let phone = data(phoneID)
        guard !phone.loadingThreads else { return }
        let id = newRequestID()
        let before = first ? nil : phone.cache.threads.last?.date
        if request(SmsKinds.threads, SmsRequests.threads(id, before: before, limit: 30), as: .threads(phoneID: phoneID, first: first), id: id) {
            update(phoneID) { $0.loadingThreads = true }
        }
    }

    private func startSync(_ phoneID: String) {
        guard !data(phoneID).syncing else { return }
        syncPages[phoneID] = 0
        sendSync(phoneID)
    }

    private func sendSync(_ phoneID: String) {
        guard let cursor = data(phoneID).cache.cursor else { return }
        let id = newRequestID()
        if request(SmsKinds.sync, SmsRequests.sync(id, since: cursor, limit: 100), as: .sync(phoneID: phoneID), id: id) {
            update(phoneID) { $0.syncing = true }
        } else {
            update(phoneID) { $0.syncing = false }
        }
    }

    private func requestMessages(_ phoneID: String, thread: Int, older: Bool) {
        let phone = data(phoneID)
        guard !phone.loadingMessages.contains(thread) else { return }
        let before = older ? phone.cache.messages(in: thread).last : nil
        let id = newRequestID()
        if request(SmsKinds.messages, SmsRequests.messages(id, threadId: thread, before: before, limit: 50),
                   as: .messages(phoneID: phoneID, thread: thread, before: before), id: id) {
            update(phoneID) { $0.loadingMessages.insert(thread) }
        }
    }

    // MARK: What the window asks for

    /// The Messages window shows the newest conversations (on open, or when the phone is picked).
    func refreshThreads(_ phoneID: String) {
        ensureLoaded(phoneID)
        requestThreads(phoneID, first: true)
    }

    /// Scrolled to the end of the conversation list.
    func loadOlderThreads(_ phoneID: String) {
        guard data(phoneID).cache.threadsMore else { return }
        requestThreads(phoneID, first: false)
    }

    /// A conversation is shown: its newest page refreshes (delivery reports, deletions on the phone).
    func open(_ phoneID: String, thread: Int) {
        openConversation = (phoneID, thread)
        lastRefresh[phoneID] = now()
        requestMessages(phoneID, thread: thread, older: false)
    }

    func close() { openConversation = nil }

    /// Scrolled to the top of the open conversation.
    func loadOlderMessages(_ phoneID: String, thread: Int) {
        guard data(phoneID).cache.hasOlder(in: thread), !data(phoneID).cache.messages(in: thread).isEmpty else { return }
        requestMessages(phoneID, thread: thread, older: true)
    }

    private func refreshOpenConversation(_ phoneID: String) {
        guard let open = openConversation, open.phoneID == phoneID else { return }
        let time = now()
        if let last = lastRefresh[phoneID], time.timeIntervalSince(last) < Self.refreshSpacing {
            // Too soon: once more when the spacing is up.
            schedule(Self.refreshSpacing) { [weak self] in
                guard let self, self.openConversation?.phoneID == phoneID, let thread = self.openConversation?.threadId else { return }
                if let last = self.lastRefresh[phoneID], self.now().timeIntervalSince(last) < Self.refreshSpacing { return }
                self.lastRefresh[phoneID] = self.now()
                self.requestMessages(phoneID, thread: thread, older: false)
            }
            return
        }
        lastRefresh[phoneID] = time
        requestMessages(phoneID, thread: open.threadId, older: false)
    }

    /// Sends `body`; the request ID, or nil when it cannot go (not connected, empty, bad number).
    @discardableResult
    func send(_ body: String, to target: SmsRequests.Target, subId: Int? = nil, phoneID: String) -> String? {
        let id = newRequestID()
        guard let payload = SmsRequests.send(id, body: body, to: target, subId: subId) else { return nil }
        let item = SmsOutgoing(id: id, phoneID: phoneID, target: target, body: body, subId: subId, createdAt: now())
        guard request(SmsKinds.send, payload, as: .send(phoneID: phoneID), id: id) else { return nil }
        outgoing.append(item)
        // Finished sends stay only while the phone's provider catches up.
        outgoing.removeAll { $0.isFinal && !$0.failed && now().timeIntervalSince($0.createdAt) > 600 }
        return id
    }

    /// Retry on a failed bubble: the same text again, as a new request.
    @discardableResult
    func retry(_ outgoingID: String) -> String? {
        guard let index = outgoing.firstIndex(where: { $0.id == outgoingID && $0.failed }) else { return nil }
        let item = outgoing[index]
        guard let id = send(item.body, to: item.target, subId: item.subId, phoneID: item.phoneID) else { return nil }
        outgoing.removeAll { $0.id == outgoingID }
        return id
    }

    func discard(_ outgoingID: String) {
        outgoing.removeAll { $0.id == outgoingID }
    }

    /// An MMS image scrolled into view.
    func requestImage(_ phoneID: String, partID: String) {
        let key = imageKey(phoneID, partID)
        guard images[key] == nil, !failedImages.contains(key), isSmsPartID(partID),
              !imageQueue.contains(where: { $0.phoneID == phoneID && $0.partID == partID }),
              !pending.values.contains(.attachment(phoneID: phoneID, partID: partID)) else { return }
        imageQueue.append((phoneID, partID))
        pumpImages()
    }

    func image(_ phoneID: String, partID: String) -> NSImage? { images[imageKey(phoneID, partID)] }
    func imageFailed(_ phoneID: String, partID: String) -> Bool { failedImages.contains(imageKey(phoneID, partID)) }

    private func pumpImages() {
        while !imageQueue.isEmpty {
            let open = pending.values.filter { if case .attachment = $0 { true } else { false } }.count
            guard open < Self.maximumOpenAttachments else { return }
            let next = imageQueue.removeFirst()
            let id = newRequestID()
            if !request(SmsKinds.attachment, SmsRequests.attachment(id, partID: next.partID),
                        as: .attachment(phoneID: next.phoneID, partID: next.partID), id: id) {
                failedImages.insert(imageKey(next.phoneID, next.partID))
            }
        }
    }

    private func remember(_ image: NSImage, key: String) {
        images[key] = image
        imageOrder.removeAll { $0 == key }
        imageOrder.append(key)
        while imageOrder.count > Self.maximumImages { images.removeValue(forKey: imageOrder.removeFirst()) }
    }

    private func imageKey(_ phoneID: String, _ partID: String) -> String { phoneID + "|" + partID }

    /// New message: names and numbers on the phone matching `query`.
    func searchContacts(_ query: String, phoneID: String) {
        if let previous = contactsRequest { pending.removeValue(forKey: previous) }
        contactsRequest = nil
        let id = newRequestID()
        guard let payload = SmsRequests.contacts(id, query: query) else {
            contactResults = []
            contactsSearching = false
            return
        }
        if request(SmsKinds.contacts, payload, as: .contacts(phoneID: phoneID), id: id) {
            contactsRequest = id
            contactsSearching = true
        }
    }

    func clearContacts() {
        if let previous = contactsRequest { pending.removeValue(forKey: previous) }
        contactsRequest = nil
        contactsSearching = false
        contactResults = []
    }

    // MARK: Helpers

    private func update(_ phoneID: String, _ change: (inout SmsPhoneData) -> Void) {
        var phone = phones[phoneID] ?? SmsPhoneData()
        change(&phone)
        phones[phoneID] = phone
    }

    /// Writes the phone's cache once per second at most, while Keep conversations on this Mac is on.
    private func persist(_ phoneID: String) {
        guard keepOnDisk(), !saveScheduled.contains(phoneID) else { return }
        saveScheduled.insert(phoneID)
        schedule(1) { [weak self] in
            guard let self else { return }
            self.saveScheduled.remove(phoneID)
            guard self.keepOnDisk(), let phone = self.phones[phoneID] else { return }
            self.store.save(phone.cache, for: phoneID)
        }
    }

    /// Saves now (tests, and before the app quits).
    func flush() {
        guard keepOnDisk() else { return }
        for id in saveScheduled { if let phone = phones[id] { store.save(phone.cache, for: id) } }
        saveScheduled.removeAll()
    }
}

/// The same phone number, written differently: the last 10 digits match (or all of them when shorter).
func smsSameNumber(_ a: String, _ b: String) -> Bool {
    let left = a.filter(\.isNumber), right = b.filter(\.isNumber)
    guard !left.isEmpty, !right.isEmpty else { return a == b }
    let length = min(10, left.count, right.count)
    return left.suffix(length) == right.suffix(length) && (length == 10 || left == right)
}
