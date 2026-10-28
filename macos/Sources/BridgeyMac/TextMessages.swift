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
 * Managing conversations (SmsManagement) is this Mac's own: pin, mute, archive, read state and
 * Delete never reach the phone, except Mark as read, which asks the phone to run the messaging
 * app's own notification action (sms.mark_read) and says what happened.
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

/// Something the Messages window says for a moment: what reached the phone, or did not.
struct SmsNotice: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Read on this Mac; how the phone's Mark as read went for those conversations.
        case markRead(SmsMarkReadSummary)
        /// Block on phone: nil when the phone did not answer.
        case blocked(SmsBlockedNumbersOutcome?, address: String?)
    }

    let id: String
    let phoneID: String
    let kind: Kind
}

struct SmsMarkReadSummary: Equatable {
    var total = 0
    var marked = 0
    var notShown = 0
    var noAction = 0
    var failed = 0
    /// The phone did not answer (not connected, or a version without sms.mark_read).
    var noAnswer = false
    /// Text messages is off for this Mac on the phone.
    var disabled = false

    var stillUnread: Int { total - marked }
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
    /// This Mac's own choices per phone (pin, mute, archive, read state, deleted).
    @Published private(set) var management: [String: SmsManagement] = [:]
    /// The newest thing to say in the Messages window.
    @Published private(set) var notice: SmsNotice?
    /// Changes each time any phone's conversations change (cheap to watch).
    @Published private(set) var revision = 0

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
    /// Phones whose older conversations are loading page after page (unread and pinned ones may be there).
    private var filling: [String: Int] = [:]
    private var lastThreadsRefresh: [String: Date] = [:]
    static let maximumFillPages = 6
    static let threadsRefreshSpacing: TimeInterval = 3

    private enum Pending: Equatable {
        case threads(phoneID: String, first: Bool)
        case messages(phoneID: String, thread: Int, before: SmsMessage?)
        case sync(phoneID: String)
        case attachment(phoneID: String, partID: String)
        case contacts(phoneID: String)
        case send(phoneID: String)
        case markRead(phoneID: String, threads: [Int], report: Bool)
        case blockedNumbers(phoneID: String, address: String?)

        var phoneID: String {
            switch self {
            case let .threads(id, _), let .messages(id, _, _), let .sync(id), let .attachment(id, _), let .contacts(id), let .send(id),
                 let .markRead(id, _, _), let .blockedNumbers(id, _): id
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
        management.removeValue(forKey: phoneID)
        filling.removeValue(forKey: phoneID)
        if notice?.phoneID == phoneID { notice = nil }
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
        management.removeAll()
        notice = nil
        store.deleteAll()
    }

    /// Keep conversations on this Mac changed: off deletes the files (memory stays for this run).
    func keepOnDiskChanged(_ keep: Bool) {
        if keep {
            for (id, phone) in phones { store.save(phone.cache, for: id) }
        } else {
            store.deleteCaches()
        }
    }

    private func ensureLoaded(_ phoneID: String) {
        guard !loaded.contains(phoneID) else { return }
        loaded.insert(phoneID)
        var phone = phones[phoneID] ?? SmsPhoneData()
        if keepOnDisk(), let cache = store.load(phoneID) { phone.cache = cache }
        phones[phoneID] = phone
        if management[phoneID] == nil, let saved = store.loadManagement(phoneID) { management[phoneID] = saved }
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
            applyManagement(phoneID)
            continueFilling(phoneID, failed: page.error != nil)
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
            applyManagement(phoneID)
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
        case SmsKinds.markReadResult:
            guard let result = decodeSmsMarkReadResult(data), case let .markRead(owner, threads, report)? = pending[result.requestID],
                  owner == phoneID else { return }
            pending.removeValue(forKey: result.requestID)
            markReadArrived(result, threads: threads, report: report, from: phoneID)
        case SmsKinds.blockedNumbersResult:
            guard let result = decodeSmsBlockedNumbersResult(data), case let .blockedNumbers(owner, address)? = pending[result.requestID],
                  owner == phoneID else { return }
            pending.removeValue(forKey: result.requestID)
            say(.blocked(result.outcome, address: address), phoneID: phoneID)
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
        if mine.isBehind(cursor) {
            startSync(phoneID)
        } else {
            // Nothing new, so something changed in place: read on the phone, or deleted there. The
            // conversation list carries the phone's unread counts.
            refreshThreadsSoon(phoneID)
        }
        refreshOpenConversation(phoneID)
    }

    /// The newest conversations again, at most once every 3 seconds.
    private func refreshThreadsSoon(_ phoneID: String) {
        let time = now()
        if let last = lastThreadsRefresh[phoneID], time.timeIntervalSince(last) < Self.threadsRefreshSpacing { return }
        lastThreadsRefresh[phoneID] = time
        requestThreads(phoneID, first: true)
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
        applyManagement(phoneID)
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
            filling.removeValue(forKey: phoneID)
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
        case let .markRead(_, threads, report):
            if report { say(.markRead(SmsMarkReadSummary(total: threads.count, noAnswer: true)), phoneID: phoneID) }
        case let .blockedNumbers(_, address):
            say(.blocked(nil, address: address), phoneID: phoneID)
        }
    }

    private func requestThreads(_ phoneID: String, first: Bool, limit: Int = 30) {
        let phone = data(phoneID)
        guard !phone.loadingThreads else { return }
        let id = newRequestID()
        let before = first ? nil : phone.cache.threads.last?.date
        if request(SmsKinds.threads, SmsRequests.threads(id, before: before, limit: limit), as: .threads(phoneID: phoneID, first: first), id: id) {
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

    // MARK: Managing conversations (this Mac's own, except Mark as read)

    func manage(_ phoneID: String) -> SmsManagement { management[phoneID] ?? SmsManagement() }

    /// The conversation list as the window shows it.
    func rows(_ phoneID: String, filter: SmsListFilter, holding: Int? = nil) -> [SmsThreadRow] {
        data(phoneID).cache.rows(manage(phoneID), filter: filter, holding: holding)
    }

    /// A conversation's messages without the ones deleted on this Mac.
    func visibleMessages(_ phoneID: String, thread: Int) -> [SmsMessage] {
        data(phoneID).cache.visibleMessages(in: thread, management: manage(phoneID))
    }

    func search(_ query: String, phoneID: String) -> SmsSearchResults {
        data(phoneID).cache.search(query, management: manage(phoneID))
    }

    /// The menu bar panel's count: unread on this Mac, muted and archived conversations left out.
    func unreadCount(_ phoneID: String) -> Int { data(phoneID).cache.unreadCount(manage(phoneID)) }

    func isUnread(_ phoneID: String, thread: Int) -> Bool {
        guard let summary = data(phoneID).cache.thread(thread) else { return false }
        return manage(phoneID).unread(summary, messages: visibleMessages(phoneID, thread: thread)) > 0
    }

    /// A banner for this conversation would be muted on this Mac.
    func isMuted(_ phoneID: String, thread: Int) -> Bool {
        ensureLoaded(phoneID)
        return manage(phoneID).isMuted(thread)
    }

    /// Read on this Mac; for conversations the phone still counts unread, the phone runs the
    /// messaging app's own Mark as read on their notifications. [report]: say how that went.
    func markRead(_ threads: [Int], phoneID: String, report: Bool = true) {
        ensureLoaded(phoneID)
        let cache = data(phoneID).cache
        var manage = self.manage(phoneID)
        var onPhone: [Int] = []
        for id in threads {
            guard let thread = cache.thread(id) else { continue }
            manage.markRead(id, through: cache.newestIncomingDate(thread))
            if thread.unread > 0 { onPhone.append(id) }
        }
        setManagement(phoneID, manage)
        var start = 0
        while start < onPhone.count {
            let chunk = Array(onPhone[start..<min(start + SmsLimits.markReadPerRequest, onPhone.count)])
            start += chunk.count
            let id = newRequestID()
            guard let payload = SmsRequests.markRead(id, threadIds: chunk) else { continue }
            if !request(SmsKinds.markRead, payload, as: .markRead(phoneID: phoneID, threads: chunk, report: report), id: id), report {
                say(.markRead(SmsMarkReadSummary(total: chunk.count, noAnswer: true)), phoneID: phoneID)
            }
        }
    }

    /// Unread again on this Mac only (the phone cannot be told).
    func markUnread(_ threads: [Int], phoneID: String) {
        changeManagement(phoneID) { manage in threads.forEach { manage.markUnread($0) } }
    }

    func setPinned(_ threads: [Int], _ on: Bool, phoneID: String) {
        changeManagement(phoneID) { manage in threads.forEach { manage.setPinned($0, on) } }
    }

    func setMuted(_ threads: [Int], _ on: Bool, phoneID: String) {
        changeManagement(phoneID) { manage in threads.forEach { manage.setMuted($0, on) } }
    }

    /// Hidden from the list until a newer message arrives (unless muted).
    func archive(_ threads: [Int], phoneID: String) {
        let cache = data(phoneID).cache
        changeManagement(phoneID) { manage in
            for id in threads { if let thread = cache.thread(id) { manage.archive(thread) } }
        }
    }

    func unarchive(_ threads: [Int], phoneID: String) {
        changeManagement(phoneID) { manage in threads.forEach { manage.unarchive($0) } }
    }

    /// Removed from this Mac (it stays on the phone) until a newer message arrives.
    func deleteThreads(_ threads: [Int], phoneID: String) {
        ensureLoaded(phoneID)
        var manage = self.manage(phoneID)
        update(phoneID) { phone in
            for id in threads {
                guard let thread = phone.cache.thread(id) else { continue }
                manage.delete(thread, newestMessageID: phone.cache.messages(in: id).first?.id)
                phone.cache.remove(thread: id)
            }
        }
        outgoing.removeAll { item in
            guard item.phoneID == phoneID, case let .thread(id) = item.target else { return false }
            return threads.contains(id)
        }
        if let open = openConversation, open.phoneID == phoneID, threads.contains(open.threadId) { openConversation = nil }
        setManagement(phoneID, manage)
        persist(phoneID)
    }

    /// One message removed from this Mac.
    func deleteMessage(_ id: String, thread: Int, phoneID: String) {
        ensureLoaded(phoneID)
        guard let message = data(phoneID).cache.messages(in: thread).first(where: { $0.id == id }) else { return }
        changeManagement(phoneID) { $0.deleteMessage(id, date: message.date, in: thread) }
        update(phoneID) { $0.cache.remove(message: id, in: thread) }
        persist(phoneID)
    }

    /// Block on phone: Android's Blocked numbers screen opens there (or its notification does).
    func blockOnPhone(_ address: String?, phoneID: String) {
        let id = newRequestID()
        if !request(SmsKinds.blockedNumbers, SmsRequests.blockedNumbers(id, address: address),
                    as: .blockedNumbers(phoneID: phoneID, address: address), id: id) {
            say(.blocked(nil, address: address), phoneID: phoneID)
        }
    }

    /// Loads older conversations page after page (up to the cache's 200), so unread and pinned ones
    /// further down are found without scrolling.
    func fillThreads(_ phoneID: String) {
        let phone = data(phoneID)
        guard filling[phoneID] == nil, phone.cache.threadsMore, phone.cache.threads.count < SmsCache.maximumThreads else { return }
        filling[phoneID] = 0
        if !phone.loadingThreads { continueFilling(phoneID, failed: false) }
    }

    private func continueFilling(_ phoneID: String, failed: Bool) {
        guard let pages = filling[phoneID] else { return }
        let cache = data(phoneID).cache
        guard !failed, pages < Self.maximumFillPages, cache.threadsMore, cache.threads.count < SmsCache.maximumThreads else {
            filling.removeValue(forKey: phoneID)
            return
        }
        filling[phoneID] = pages + 1
        requestThreads(phoneID, first: false, limit: SmsLimits.threadsPerPage)
    }

    func clearNotice(_ id: String) {
        if notice?.id == id { notice = nil }
    }

    private func markReadArrived(_ result: SmsMarkReadResult, threads: [Int], report: Bool, from phoneID: String) {
        var summary = SmsMarkReadSummary(total: threads.count)
        if result.error != nil {
            summary.disabled = true
        } else {
            for thread in threads {
                switch result.results.first(where: { $0.threadId == thread })?.outcome {
                case .marked?: summary.marked += 1
                case .notShown?: summary.notShown += 1
                case .noAction?: summary.noAction += 1
                case .failed?, nil: summary.failed += 1
                }
            }
        }
        // The messaging app writes the read state a moment later; the list then carries the phone's counts.
        if summary.marked > 0 {
            schedule(1.5) { [weak self] in self?.requestThreads(phoneID, first: true) }
        }
        if report { say(.markRead(summary), phoneID: phoneID) }
    }

    private func say(_ kind: SmsNotice.Kind, phoneID: String) {
        notice = SmsNotice(id: newRequestID(), phoneID: phoneID, kind: kind)
    }

    private func changeManagement(_ phoneID: String, _ change: (inout SmsManagement) -> Void) {
        ensureLoaded(phoneID)
        var manage = self.manage(phoneID)
        change(&manage)
        setManagement(phoneID, manage)
    }

    private func setManagement(_ phoneID: String, _ manage: SmsManagement) {
        guard management[phoneID] != manage else { return }
        management[phoneID] = manage
        store.saveManagement(manage, for: phoneID)
    }

    /// After the cache changed: what this Mac deleted stays out of it, and archives, tombstones and
    /// read points that newer messages or the phone ended go.
    private func applyManagement(_ phoneID: String) {
        guard var manage = management[phoneID], !manage.isEmpty else { return }
        manage.reconcile(with: data(phoneID).cache)
        update(phoneID) { phone in
            for key in manage.deleted.keys {
                guard let id = Int(key) else { continue }
                phone.cache.remove(thread: id)
            }
            for (key, ids) in manage.deletedMessages where phone.cache.messages[key]?.contains(where: { ids[$0.id] != nil }) == true {
                phone.cache.messages[key]?.removeAll { ids[$0.id] != nil }
            }
        }
        setManagement(phoneID, manage)
    }

    // MARK: Helpers

    private func update(_ phoneID: String, _ change: (inout SmsPhoneData) -> Void) {
        var phone = phones[phoneID] ?? SmsPhoneData()
        change(&phone)
        phones[phoneID] = phone
        revision &+= 1
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
