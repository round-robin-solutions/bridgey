import Foundation

/*
 * Text messages: what this Mac keeps of one phone's conversations (docs/protocol.md, "The Mac's
 * cache"). At most 200 conversations and the newest 200 messages of each, plus the sync cursor, in one
 * file per phone under Application Support/<edition>/Messages, the file 0600 and the folder 0700.
 * Deleted when Text messages is turned off here or on the phone, when the phone is forgotten, and from
 * Reset. With "Keep conversations on this Mac" off nothing is written and the files go.
 * MMS images are never written (TextMessages keeps them in memory).
 */

struct SmsCache: Codable, Equatable {
    static let maximumThreads = 200
    static let maximumMessagesPerThread = 200

    var version = 1
    /// Where the next sms.sync starts; nil until the phone's first sms.status (the baseline).
    var cursor: SmsCursor?
    /// Newest first.
    var threads: [SmsThread] = []
    /// The phone has older conversations than the last one here.
    var threadsMore = false
    /// Newest first, per conversation (JSON keys are the thread IDs as text).
    var messages: [String: [SmsMessage]] = [:]
    /// The phone has older messages in that conversation than the oldest one here.
    var olderMore: [String: Bool] = [:]

    func thread(_ id: Int) -> SmsThread? { threads.first { $0.threadId == id } }
    func messages(in thread: Int) -> [SmsMessage] { messages[String(thread)] ?? [] }
    func hasOlder(in thread: Int) -> Bool { olderMore[String(thread)] ?? true }

    // MARK: Merging pages

    /// The newest page (`first`) replaces every cached conversation at least as new as its oldest
    /// entry, so a conversation deleted on the phone goes; an older page only adds.
    mutating func applyThreads(_ page: [SmsThread], first: Bool, more: Bool) {
        if first {
            let ids = Set(page.map(\.threadId))
            if let oldest = page.map(\.date).min() {
                let gone = threads.filter { $0.date >= oldest && !ids.contains($0.threadId) }.map(\.threadId)
                drop(gone)
            } else if !more {
                drop(threads.map(\.threadId))
            }
        }
        for thread in page {
            if let index = threads.firstIndex(where: { $0.threadId == thread.threadId }) {
                threads[index] = thread
            } else {
                threads.append(thread)
            }
        }
        threads.sort { $0.date != $1.date ? $0.date > $1.date : $0.threadId > $1.threadId }
        if threads.count > Self.maximumThreads {
            drop(threads[Self.maximumThreads...].map(\.threadId))
            threadsMore = true
        } else if first ? threads.count <= page.count : true {
            threadsMore = more
        }
    }

    /// One conversation's page. The span it covers (from its oldest message up to `before`, or to the
    /// newest when `before` is nil) is replaced, so messages deleted on the phone go.
    mutating func applyMessages(_ page: [SmsMessage], thread: Int, before: SmsMessage?, more: Bool) {
        let key = String(thread)
        var list = messages[key] ?? []
        let ids = Set(page.map(\.id))
        if let oldest = page.min(by: { SmsMessage.newerFirst($1, $0) }) {
            list.removeAll { message in
                guard !ids.contains(message.id) else { return false }
                let atLeastOldest = !SmsMessage.newerFirst(oldest, message)
                let belowUpper = before.map { SmsMessage.newerFirst($0, message) } ?? true
                return atLeastOldest && belowUpper
            }
        } else if before == nil {
            list.removeAll()
        }
        for message in page {
            if let index = list.firstIndex(where: { $0.id == message.id }) { list[index] = message } else { list.append(message) }
        }
        list.sort(by: SmsMessage.newerFirst)
        if list.count > Self.maximumMessagesPerThread {
            list = Array(list.prefix(Self.maximumMessagesPerThread))
            olderMore[key] = true
        } else if before != nil || list.count <= page.count {
            // This page reached the oldest message kept here: the phone says whether there are more.
            olderMore[key] = more
        }
        messages[key] = list
    }

    /// Messages from sms.sync, newer than the cursor. Updates each conversation's summary and returns
    /// the conversations this cache does not know yet (their summaries come with the next threads page).
    @discardableResult
    mutating func applySync(_ page: [SmsMessage]) -> Set<Int> {
        var unknown = Set<Int>()
        for message in page.sorted(by: { SmsMessage.newerFirst($1, $0) }) {
            let key = String(message.threadId)
            var list = messages[key] ?? []
            let isNew = !list.contains { $0.id == message.id }
            if let index = list.firstIndex(where: { $0.id == message.id }) { list[index] = message } else { list.append(message) }
            list.sort(by: SmsMessage.newerFirst)
            if list.count > Self.maximumMessagesPerThread {
                list = Array(list.prefix(Self.maximumMessagesPerThread))
                olderMore[key] = true
            }
            messages[key] = list
            guard let index = threads.firstIndex(where: { $0.threadId == message.threadId }) else {
                unknown.insert(message.threadId)
                continue
            }
            if message.date >= threads[index].date {
                threads[index].date = message.date
                threads[index].snippet = smsSnippet(message)
                if message.subId != nil { threads[index].subId = message.subId }
            }
            if isNew, message.direction == .incoming, !message.read { threads[index].unread += 1 }
        }
        threads.sort { $0.date != $1.date ? $0.date > $1.date : $0.threadId > $1.threadId }
        return unknown
    }

    private mutating func drop(_ ids: [Int]) {
        let set = Set(ids)
        threads.removeAll { set.contains($0.threadId) }
        for id in set {
            messages.removeValue(forKey: String(id))
            olderMore.removeValue(forKey: String(id))
        }
    }
}

/// The one line a conversation shows for its newest message.
func smsSnippet(_ message: SmsMessage) -> String {
    let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty, !message.parts.isEmpty { return L10n.text("sms.snippet.image", fallback: "Image") }
    return String(text.prefix(160))
}

/// Files under Application Support/<edition>/Messages, one per phone.
struct SmsStore {
    static let folderName = "Messages"

    let directory: URL

    init(directory: URL = SmsStore.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        LocalDataLocations.standard.support.appendingPathComponent(folderName, isDirectory: true)
    }

    func fileURL(_ phoneID: String) -> URL {
        let safe = String(phoneID.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
        return directory.appendingPathComponent("\(safe.isEmpty ? "phone" : safe).json")
    }

    func load(_ phoneID: String) -> SmsCache? {
        guard let data = try? Data(contentsOf: fileURL(phoneID)),
              let cache = try? JSONDecoder().decode(SmsCache.self, from: data), cache.version == 1 else { return nil }
        return cache
    }

    @discardableResult
    func save(_ cache: SmsCache, for phoneID: String) -> Bool {
        guard let data = try? JSONEncoder().encode(cache) else { return false }
        let ok = TrayStore.writeOwnerOnly(data, to: fileURL(phoneID))
        if !ok { BridgeyLog.notifications.error("text messages cache write failed") }
        return ok
    }

    func delete(_ phoneID: String) {
        try? FileManager.default.removeItem(at: fileURL(phoneID))
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
