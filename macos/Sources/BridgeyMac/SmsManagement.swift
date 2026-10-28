import Foundation

/*
 * Text messages: what this Mac decided about one phone's conversations. Pin, mute, archive, read
 * state, Mark as unread and Delete belong to this Mac only: Android lets only the default SMS app
 * write to the SMS provider, so none of it changes the phone (docs/sms-call-policy.md). The only
 * thing that reaches the phone is Mark as read, through the messaging app's own notification action
 * (sms.mark_read, TextMessages).
 *
 * Kept per phone in SmsStore next to the cache (0600, thread and message IDs and dates, never text),
 * cleared with it on Forget, Text messages off and Reset, synced nowhere. Everything here is pure, so
 * the ordering, read and tombstone rules are tested without a window or a phone.
 */

struct SmsTombstone: Codable, Equatable {
    /// The conversation's newest date when it was deleted here.
    var date: Int
    /// Its newest message then, when this Mac had it.
    var messageId: String?
}

struct SmsManagement: Codable, Equatable {
    static let maximumDeletedMessagesPerThread = 500
    static let maximumEntries = 1_000

    var version = 1
    var pinned: Set<Int> = []
    var muted: Set<Int> = []
    /// Marked unread on this Mac (the phone's state is untouched).
    var markedUnread: Set<Int> = []
    /// Thread ID (as text) to the conversation's date when archived: newer messages bring it back.
    var archived: [String: Int] = [:]
    /// Thread ID to the newest incoming message date read on this Mac.
    var readThrough: [String: Int] = [:]
    /// Deleted from this Mac: hidden until a newer message arrives.
    var deleted: [String: SmsTombstone] = [:]
    /// Single messages deleted from this Mac, by thread: message ID to its date.
    var deletedMessages: [String: [String: Int]] = [:]

    var isEmpty: Bool { self == SmsManagement() }

    func isPinned(_ thread: Int) -> Bool { pinned.contains(thread) }
    func isMuted(_ thread: Int) -> Bool { muted.contains(thread) }

    // MARK: Rules

    /// Hidden by a Delete on this Mac: nothing newer than the tombstone has arrived.
    func isDeleted(_ thread: SmsThread, newestMessageID: String?) -> Bool {
        guard let tomb = deleted[String(thread.threadId)] else { return false }
        if thread.date < tomb.date { return true }
        guard thread.date == tomb.date else { return false }
        guard let id = tomb.messageId, let newest = newestMessageID else { return true }
        return id == newest
    }

    /// Archived, until a newer message arrives (a muted conversation stays archived).
    func isArchived(_ thread: SmsThread) -> Bool {
        guard let date = archived[String(thread.threadId)] else { return false }
        return thread.date <= date || muted.contains(thread.threadId)
    }

    /// Unread as this Mac shows it: the phone's count, unless this Mac read up to the newest incoming
    /// message since; at least 1 when marked unread here.
    func unread(_ thread: SmsThread, messages: [SmsMessage]) -> Int {
        let key = String(thread.threadId)
        if markedUnread.contains(thread.threadId) { return max(thread.unread, 1) }
        guard thread.unread > 0 else { return 0 }
        guard let read = readThrough[key] else { return thread.unread }
        let incoming = messages.filter { $0.direction == .incoming }
        if incoming.isEmpty { return thread.date > read ? thread.unread : 0 }
        let newer = incoming.filter { $0.date > read }.count
        return newer == 0 ? 0 : min(thread.unread, newer)
    }

    // MARK: Changes

    /// Read on this Mac up to `newestIncoming` (the newest incoming message date, or the
    /// conversation's date when no message is here yet).
    mutating func markRead(_ thread: Int, through newestIncoming: Int) {
        markedUnread.remove(thread)
        let key = String(thread)
        readThrough[key] = max(readThrough[key] ?? 0, newestIncoming)
    }

    mutating func markUnread(_ thread: Int) {
        markedUnread.insert(thread)
        readThrough.removeValue(forKey: String(thread))
    }

    mutating func setPinned(_ thread: Int, _ on: Bool) {
        if on { pinned.insert(thread) } else { pinned.remove(thread) }
    }

    mutating func setMuted(_ thread: Int, _ on: Bool) {
        if on { muted.insert(thread) } else { muted.remove(thread) }
    }

    /// Archiving unpins, as in Google Messages.
    mutating func archive(_ thread: SmsThread) {
        archived[String(thread.threadId)] = thread.date
        pinned.remove(thread.threadId)
    }

    mutating func unarchive(_ thread: Int) {
        archived.removeValue(forKey: String(thread))
    }

    /// Deleted from this Mac: everything else this Mac kept about it goes too.
    mutating func delete(_ thread: SmsThread, newestMessageID: String?) {
        let key = String(thread.threadId)
        deleted[key] = SmsTombstone(date: thread.date, messageId: newestMessageID)
        pinned.remove(thread.threadId)
        muted.remove(thread.threadId)
        markedUnread.remove(thread.threadId)
        archived.removeValue(forKey: key)
        readThrough.removeValue(forKey: key)
        deletedMessages.removeValue(forKey: key)
    }

    mutating func deleteMessage(_ id: String, date: Int, in thread: Int) {
        let key = String(thread)
        var list = deletedMessages[key] ?? [:]
        list[id] = date
        if list.count > Self.maximumDeletedMessagesPerThread {
            // The oldest go first: they are long gone from the cache's newest 200.
            for old in list.sorted(by: { $0.value < $1.value }).prefix(list.count - Self.maximumDeletedMessagesPerThread).map(\.key) {
                list.removeValue(forKey: old)
            }
        }
        deletedMessages[key] = list
    }

    func isMessageDeleted(_ id: String, in thread: Int) -> Bool {
        deletedMessages[String(thread)]?[id] != nil
    }

    /// The conversation's newest message was deleted on this Mac, so its line on the list is not shown.
    func newestDeleted(_ thread: SmsThread) -> Bool {
        guard let dates = deletedMessages[String(thread.threadId)]?.values, let newest = dates.max() else { return false }
        return thread.date <= newest
    }

    /// After the cache changed: archives and tombstones that a newer message ended go, and read
    /// points the phone caught up with go. Conversations the cache does not hold are left alone.
    mutating func reconcile(with cache: SmsCache) {
        for thread in cache.threads {
            let key = String(thread.threadId)
            if let date = archived[key], thread.date > date, !muted.contains(thread.threadId) { archived.removeValue(forKey: key) }
            if deleted[key] != nil, !isDeleted(thread, newestMessageID: cache.messages(in: thread.threadId).first?.id) {
                deleted.removeValue(forKey: key)
            }
            if thread.unread == 0 { readThrough.removeValue(forKey: key) }
        }
        // Messages from a sync can arrive before the conversation's summary: newer ones end a tombstone too.
        for (key, tomb) in deleted where cache.thread(Int(key) ?? 0) == nil {
            if let newest = cache.messages[key]?.first, newest.date > tomb.date || (newest.date == tomb.date && tomb.messageId != nil && newest.id != tomb.messageId) {
                deleted.removeValue(forKey: key)
            }
        }
        trim()
    }

    /// Bounded: the oldest archive and tombstone entries go first.
    private mutating func trim() {
        if deleted.count > Self.maximumEntries {
            for key in deleted.sorted(by: { $0.value.date < $1.value.date }).prefix(deleted.count - Self.maximumEntries).map(\.key) {
                deleted.removeValue(forKey: key)
            }
        }
        if archived.count > Self.maximumEntries {
            for key in archived.sorted(by: { $0.value < $1.value }).prefix(archived.count - Self.maximumEntries).map(\.key) {
                archived.removeValue(forKey: key)
            }
        }
    }
}

// MARK: - The list the window shows

enum SmsListFilter: String, Equatable, CaseIterable {
    case all, unread, archived
}

/// One conversation as the list shows it.
struct SmsThreadRow: Equatable, Identifiable {
    var thread: SmsThread
    var unread: Int
    var pinned: Bool
    var muted: Bool
    var archived: Bool
    var id: Int { thread.threadId }
}

extension SmsCache {
    /// A conversation's messages without the ones deleted on this Mac (newest first).
    func visibleMessages(in thread: Int, management: SmsManagement) -> [SmsMessage] {
        let all = messages(in: thread)
        guard let deleted = management.deletedMessages[String(thread)], !deleted.isEmpty else { return all }
        return all.filter { deleted[$0.id] == nil }
    }

    /// Pinned first, then unread, then the rest, each newest first. Deleted conversations never show;
    /// archived ones only in the Archived list.
    func rows(_ management: SmsManagement, filter: SmsListFilter) -> [SmsThreadRow] {
        var rows: [SmsThreadRow] = []
        for thread in threads {
            let messages = visibleMessages(in: thread.threadId, management: management)
            guard !management.isDeleted(thread, newestMessageID: self.messages(in: thread.threadId).first?.id) else { continue }
            var shown = thread
            // A newest message deleted here is not the conversation's line any more.
            if management.newestDeleted(thread) {
                shown.snippet = messages.first.map(smsSnippet) ?? ""
            }
            let row = SmsThreadRow(thread: shown, unread: management.unread(thread, messages: messages),
                                   pinned: management.isPinned(thread.threadId), muted: management.isMuted(thread.threadId),
                                   archived: management.isArchived(thread))
            switch filter {
            case .all: if !row.archived { rows.append(row) }
            case .unread: if !row.archived && row.unread > 0 { rows.append(row) }
            case .archived: if row.archived { rows.append(row) }
            }
        }
        guard filter != .archived else { return rows }
        func rank(_ row: SmsThreadRow) -> Int { row.pinned ? 0 : row.unread > 0 ? 1 : 2 }
        // The cache is newest first already; a stable sort keeps that order inside each group.
        return rows.enumerated().sorted { a, b in
            let left = rank(a.element), right = rank(b.element)
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
    }

    /// Unread conversations for the menu bar panel: muted and archived ones do not call for attention.
    func unreadCount(_ management: SmsManagement) -> Int {
        rows(management, filter: .all).filter { !$0.muted }.reduce(0) { $0 + $1.unread }
    }

    /// The newest incoming message's date in a conversation, else its own date.
    func newestIncomingDate(_ thread: SmsThread) -> Int {
        messages(in: thread.threadId).first { $0.direction == .incoming }?.date ?? thread.date
    }
}

// MARK: - Search

/// One message found by a search, with where the text matched.
struct SmsSearchHit: Equatable, Identifiable {
    let threadId: Int
    let message: SmsMessage
    /// The text shown for it (a window around the first match) and the matches inside it.
    let excerpt: String
    let matches: [Range<String.Index>]
    var id: String { "\(threadId)|\(message.id)" }
}

struct SmsSearchResults: Equatable {
    var threads: [SmsThreadRow] = []
    var messages: [SmsSearchHit] = []
    var isEmpty: Bool { threads.isEmpty && messages.isEmpty }
}

/// Every range of `query` in `text`, ignoring case and accents.
func smsMatches(of query: String, in text: String) -> [Range<String.Index>] {
    guard !query.isEmpty else { return [] }
    var found: [Range<String.Index>] = []
    var start = text.startIndex
    while start < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
        found.append(range)
        start = range.upperBound
        if found.count >= 20 { break }
    }
    return found
}

extension SmsCache {
    static let maximumSearchHits = 200

    /// Conversations whose name or number matches, and cached messages whose text does, newest first.
    /// Archived conversations are searched too; deleted ones and deleted messages are not.
    func search(_ raw: String, management: SmsManagement) -> SmsSearchResults {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SmsSearchResults() }
        var results = SmsSearchResults()
        let digits = query.filter(\.isNumber)
        let visible = rows(management, filter: .all) + rows(management, filter: .archived)
        for row in visible {
            let thread = row.thread
            let titled = !smsMatches(of: query, in: thread.title).isEmpty
            let numbered = digits.count >= 3 && thread.participants.contains { $0.address.filter(\.isNumber).contains(digits) }
            if titled || numbered { results.threads.append(row) }
        }
        var hits: [SmsSearchHit] = []
        for row in visible {
            for message in visibleMessages(in: row.thread.threadId, management: management) {
                let matches = smsMatches(of: query, in: message.body)
                guard let first = matches.first else { continue }
                hits.append(smsSearchHit(row.thread.threadId, message, first: first, query: query))
            }
        }
        hits.sort { SmsMessage.newerFirst($0.message, $1.message) }
        results.messages = Array(hits.prefix(Self.maximumSearchHits))
        results.threads.sort { $0.thread.date > $1.thread.date }
        return results
    }
}

/// The excerpt for a hit: one line, up to about 40 characters before the first match.
private func smsSearchHit(_ thread: Int, _ message: SmsMessage, first: Range<String.Index>, query: String) -> SmsSearchHit {
    let body = message.body
    let lead = body.distance(from: body.startIndex, to: first.lowerBound)
    var start = body.startIndex
    var prefix = ""
    if lead > 40 {
        start = body.index(first.lowerBound, offsetBy: -32)
        if let space = body[start..<first.lowerBound].firstIndex(of: " ") { start = body.index(after: space) }
        prefix = "\u{2026}"
    }
    let tail = body[start...].prefix(220)
    let excerpt = prefix + tail.replacingOccurrences(of: "\n", with: " ")
    return SmsSearchHit(threadId: thread, message: message, excerpt: excerpt, matches: smsMatches(of: query, in: excerpt))
}

/// The first unread message of a conversation as it was when opened: the oldest incoming message the
/// phone has unread and this Mac had not read. Nil when there is none (marked unread on this Mac only).
func smsFirstUnread(_ messages: [SmsMessage], readThrough: Int?) -> SmsMessage? {
    messages.last { $0.direction == .incoming && !$0.read && $0.date > (readThrough ?? -1) }
}
