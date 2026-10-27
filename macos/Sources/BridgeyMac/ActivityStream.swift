import Combine
import Foundation

/*
 * The local activity stream, mirroring the Android rules (activity/ActivityLog.kt):
 * at most 200 items for 7 days, newest first, in an owner-only file under the edition's
 * Application Support folder. Clipboard items keep a one-line preview of at most 80
 * characters, alerts keep the app's name, incoming calls keep the caller. Link addresses,
 * notification titles and text, and phone numbers are never kept.
 *
 * Nothing in this file writes to the log or to diagnostics, and nothing else reads the
 * stream's file. A unit test guards both.
 */

/// The group an item belongs to.
enum ActivityCategory: String {
    case clipboard, files, alerts, calls, other
}

/// What happened. Raw values are the stored keys, shared with Android.
enum ActivityKind: String, CaseIterable, Codable {
    case clipboardSent = "clipboard_sent"
    case clipboardReceived = "clipboard_received"
    case fileSent = "file_sent"
    case fileReceived = "file_received"
    case fileFailed = "file_failed"
    case linkSent = "link_sent"
    case linkReceived = "link_received"
    case notificationsShown = "notifications_shown"
    case callShown = "call_shown"
    case callStarted = "call_started"
    case pingSent = "ping_sent"
    case pingReceived = "ping_received"
    /// The phone rang this Mac.
    case findMac = "find_mac"
    /// This Mac rang the phone.
    case findPhone = "find_phone"
    case paired
    /// Clipboard offers (docs/protocol.md): a copy here is ready on the phone.
    case clipOfferSent = "clip_offer_sent"
    /// A copy on the phone is ready to paste here.
    case clipOfferReceived = "clip_offer_received"
    /// A paste here moved the data from the phone.
    case clipPasted = "clip_pasted"
    case clipPasteFailed = "clip_paste_failed"
    /// A folder from this Mac was saved on the phone (Files 2.0).
    case folderSent = "folder_sent"
    /// A folder from the phone was saved here (phone to Mac comes later; the kind is stored already).
    case folderReceived = "folder_received"
    /// A folder transfer ended before every file arrived.
    case folderIncomplete = "folder_incomplete"

    var category: ActivityCategory {
        switch self {
        case .clipboardSent, .clipboardReceived, .clipOfferSent, .clipOfferReceived, .clipPasted, .clipPasteFailed: .clipboard
        case .fileSent, .fileReceived, .fileFailed, .folderSent, .folderReceived, .folderIncomplete: .files
        case .notificationsShown: .alerts
        case .callShown, .callStarted: .calls
        default: .other
        }
    }

    /// A burst of the same event (same device, app and caller) folds into one item with a count.
    var mergeWindow: TimeInterval {
        switch self {
        case .notificationsShown: 15 * 60
        case .callShown: 60
        default: 0
        }
    }

    var isClipOffer: Bool { [.clipOfferSent, .clipOfferReceived, .clipPasted, .clipPasteFailed].contains(self) }
    /// File events and clipboard offers keep a file name (offers: one file, previews on).
    var carriesFileName: Bool { category == .files || isClipOffer }
    /// Clipboard items carry a text preview; incoming calls the caller.
    var carriesPreview: Bool { self == .clipboardSent || self == .clipboardReceived || self == .callShown }
    var carriesAppName: Bool { self == .notificationsShown }
    var isFolder: Bool { self == .folderSent || self == .folderReceived || self == .folderIncomplete }
}

/// One stream item. These fields are the whole record, in memory and on disk.
struct ActivityItem: Codable, Equatable, Identifiable {
    let id: Int64
    let kind: ActivityKind
    let deviceID: String?
    let deviceName: String
    let fileName: String?
    /// Clipboard preview (one line, at most 80 characters) or the caller.
    let preview: String?
    /// Forwarded notifications: the app's name.
    let appName: String?
    /// Concealed clipboard content: shown as "Hidden", no text kept.
    let sensitive: Bool
    /// Sent or received by Automatic clipboard.
    let automatic: Bool
    /// Clipboard offers: the number of items. Merged events: how many.
    let count: Int
    let at: Date
    /// Clipboard offers and folders: total size in bytes.
    var bytes: Int64? = nil
    /// Clipboard offers: "text", "image" or "file". Folders: the detail facts (`FolderActivityDetail`).
    var content: String? = nil
    /// Folders: how many files the folder has.
    var fileCount: Int? = nil
    /// Folders: where it landed, as a display path ("Pictures/Trip"), at most 128 characters.
    var destination: String? = nil
}

/// The facts behind a folder item's detail line, stored in `content` as "key=value;..." (values
/// percent-encoded). Counts and codes only, plus the final folder name after "Save as new folder".
struct FolderActivityDetail: Equatable {
    var doneFiles: Int?
    var doneBytes: Int64?
    var links = 0
    var hidden = 0
    var system = 0
    var failed = 0
    /// "cancelled", "phone_cancelled", "lost", "timeout", "unconfirmed" or a rejection code.
    var end: String?
    var choice: String?
    var kept = 0
    var replaced = 0
    var savedAs: String?

    static let maximumLength = 512

    var encoded: String {
        var parts: [String] = []
        func addText(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
            parts.append("\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")")
        }
        func addCount(_ key: String, _ value: Int) { if value > 0 { parts.append("\(key)=\(value)") } }
        if let doneFiles { parts.append("done=\(doneFiles)") }
        if let doneBytes { parts.append("doneBytes=\(doneBytes)") }
        addCount("links", links)
        addCount("hidden", hidden)
        addCount("system", system)
        addCount("failed", failed)
        addText("end", end)
        addText("choice", choice)
        addCount("kept", kept)
        addCount("replaced", replaced)
        addText("savedAs", savedAs.map { String($0.prefix(ActivityHistory.maximumNameLength)) })
        return String(parts.joined(separator: ";").prefix(Self.maximumLength))
    }

    init(doneFiles: Int? = nil, doneBytes: Int64? = nil, links: Int = 0, hidden: Int = 0, system: Int = 0, failed: Int = 0,
         end: String? = nil, choice: String? = nil, kept: Int = 0, replaced: Int = 0, savedAs: String? = nil) {
        self.doneFiles = doneFiles
        self.doneBytes = doneBytes
        self.links = links
        self.hidden = hidden
        self.system = system
        self.failed = failed
        self.end = end
        self.choice = choice
        self.kept = kept
        self.replaced = replaced
        self.savedAs = savedAs
    }

    init(_ encoded: String?) {
        self.init()
        for part in (encoded ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1].removingPercentEncoding ?? pair[1]
            let number = max(0, min(Int(value) ?? 0, 1_000_000))
            switch pair[0] {
            case "done": doneFiles = number
            case "doneBytes": doneBytes = max(0, Int64(value) ?? 0)
            case "links": links = number
            case "hidden": hidden = number
            case "system": system = number
            case "failed": failed = number
            case "end": end = String(value.prefix(32))
            case "choice": choice = String(value.prefix(16))
            case "kept": kept = number
            case "replaced": replaced = number
            case "savedAs": savedAs = String(value.prefix(ActivityHistory.maximumNameLength))
            default: break
            }
        }
    }
}

enum ActivityHistory {
    static let maximumItems = 200
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumPreviewLength = 80
    /// A clock set back should not leave items stuck on top for days.
    static let futureTolerance: TimeInterval = 5 * 60
    static let maximumNameLength = 128
    static let maximumFileNameLength = 255
    static let maximumFileBytes = 512 * 1024

    /// One line, whitespace collapsed, at most 80 characters ending with an ellipsis when cut.
    static func preview(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > maximumPreviewLength else { return line }
        let cut = String(line.prefix(maximumPreviewLength - 1))
        let trimmed = cut.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trimmed + "\u{2026}"
    }

    static func prune(_ items: [ActivityItem], now: Date) -> [ActivityItem] {
        let oldest = now.addingTimeInterval(-maximumAge)
        let newest = now.addingTimeInterval(futureTolerance)
        return Array(items
            .filter { $0.at >= oldest && $0.at <= newest }
            .sorted { $0.at > $1.at }
            .prefix(maximumItems))
    }

    /// Newest first. `nextID` is used only when a new item is created.
    static func add(
        _ items: [ActivityItem],
        kind: ActivityKind,
        deviceID: String?,
        deviceName: String,
        fileName: String? = nil,
        preview: String? = nil,
        appName: String? = nil,
        sensitive: Bool = false,
        automatic: Bool = false,
        count: Int = 1,
        bytes: Int64? = nil,
        content: String? = nil,
        fileCount: Int? = nil,
        destination: String? = nil,
        now: Date,
        nextID: Int64
    ) -> [ActivityItem] {
        let cleanContent = cleanContentValue(content, kind: kind)
        let cleanBytes = kind.isClipOffer || kind.isFolder ? bytes.map { max(0, $0) } : nil
        if kind == .clipPasted, let match = items.first, match.kind == .clipPasted,
           match.deviceID == deviceID.map({ String($0.prefix(64)) }), now >= match.at, now.timeIntervalSince(match.at) <= 60 {
            // Several files pasted at once read as one event.
            let merged = ActivityItem(
                id: match.id, kind: kind, deviceID: match.deviceID, deviceName: cleanName(deviceName), fileName: nil,
                preview: nil, appName: nil, sensitive: false, automatic: false,
                count: min(match.count + max(count, 1), 9_999), at: now,
                bytes: (match.bytes ?? 0) + (cleanBytes ?? 0),
                content: match.content == "image" && cleanContent == "image" ? "image" : "file"
            )
            return prune([merged] + items.dropFirst(), now: now)
        }
        let isSensitive = sensitive && kind.carriesPreview
        let cleanPreview = kind.carriesPreview && !isSensitive ? Self.preview(preview) : nil
        let cleanApp = kind.carriesAppName ? clean(appName, limit: maximumNameLength) : nil
        let cleanDeviceID = deviceID.map { String($0.prefix(64)) }
        if kind.mergeWindow > 0, let match = items.first(where: {
            $0.kind == kind && $0.deviceID == cleanDeviceID && $0.appName == cleanApp && $0.preview == cleanPreview &&
                now >= $0.at && now.timeIntervalSince($0.at) <= kind.mergeWindow
        }) {
            let merged = ActivityItem(
                id: match.id, kind: kind, deviceID: match.deviceID, deviceName: cleanName(deviceName),
                fileName: nil, preview: match.preview, appName: match.appName, sensitive: match.sensitive,
                automatic: match.automatic, count: min(match.count + 1, 9_999), at: now
            )
            return prune([merged] + items.filter { $0.id != match.id }, now: now)
        }
        let item = ActivityItem(
            id: nextID,
            kind: kind,
            deviceID: cleanDeviceID,
            deviceName: cleanName(deviceName),
            fileName: kind.carriesFileName ? clean(fileName, limit: maximumFileNameLength) : nil,
            preview: cleanPreview,
            appName: cleanApp,
            sensitive: isSensitive,
            automatic: automatic && kind.category == .clipboard,
            count: kind.isClipOffer ? min(max(count, 1), 9_999) : 1,
            at: now,
            bytes: cleanBytes,
            content: cleanContent,
            fileCount: kind.isFolder ? fileCount.map { min(max($0, 0), 1_000_000) } : nil,
            destination: kind.isFolder ? clean(destination, limit: maximumNameLength) : nil
        )
        return prune([item] + items, now: now)
    }

    private static func cleanContentValue(_ value: String?, kind: ActivityKind) -> String? {
        if kind.isClipOffer { return ["text", "image", "file"].contains(value ?? "") ? value : nil }
        if kind.isFolder { return clean(value, limit: FolderActivityDetail.maximumLength) }
        return nil
    }

    static func encode(_ items: [ActivityItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(items)
    }

    /// Lenient: unknown kinds and malformed items are dropped, fields are re-cleaned.
    static func decode(_ data: Data, now: Date) -> [ActivityItem] {
        guard data.count <= maximumFileBytes else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let raw = try? decoder.decode([LenientItem].self, from: data) else { return [] }
        let items: [ActivityItem] = raw.prefix(maximumItems * 2).compactMap(\.value).compactMap { value in
            guard let id = value.id, id >= 0,
                  let kind = value.kind.flatMap(ActivityKind.init(rawValue:)),
                  let at = value.at else { return nil }
            let sensitive = kind.carriesPreview && value.sensitive == true
            return ActivityItem(
                id: id,
                kind: kind,
                deviceID: value.deviceID.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) },
                deviceName: cleanName(value.deviceName ?? ""),
                fileName: kind.carriesFileName ? clean(value.fileName, limit: maximumFileNameLength) : nil,
                preview: kind.carriesPreview && !sensitive ? preview(value.preview) : nil,
                appName: kind.carriesAppName ? clean(value.appName, limit: maximumNameLength) : nil,
                sensitive: sensitive,
                automatic: kind.category == .clipboard && value.automatic == true,
                count: min(max(value.count ?? 1, 1), 9_999),
                at: at,
                bytes: kind.isClipOffer || kind.isFolder ? value.bytes.map { max(0, $0) } : nil,
                content: cleanContentValue(value.content, kind: kind),
                fileCount: kind.isFolder ? value.fileCount.map { min(max($0, 0), 1_000_000) } : nil,
                destination: kind.isFolder ? clean(value.destination, limit: maximumNameLength) : nil
            )
        }
        return prune(items, now: now)
    }

    /// The same item with its preview text, app name and caller removed.
    static func withoutPreview(_ item: ActivityItem) -> ActivityItem {
        ActivityItem(
            id: item.id, kind: item.kind, deviceID: item.deviceID, deviceName: item.deviceName,
            fileName: item.kind.isClipOffer ? nil : item.fileName, preview: nil, appName: nil, sensitive: item.sensitive,
            automatic: item.automatic, count: item.count, at: item.at, bytes: item.bytes, content: item.content,
            fileCount: item.fileCount, destination: item.destination
        )
    }

    private static func cleanName(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }

    /// One element of the file. An element that does not decode (a field of another type, not an
    /// object) is dropped on its own instead of failing the whole stream.
    private struct LenientItem: Decodable {
        let value: StoredItem?
        init(from decoder: Decoder) throws { value = try? StoredItem(from: decoder) }
    }

    private struct StoredItem: Decodable {
        let id: Int64?
        let kind: String?
        let deviceID: String?
        let deviceName: String?
        let fileName: String?
        let preview: String?
        let appName: String?
        let sensitive: Bool?
        let automatic: Bool?
        let count: Int?
        let at: Date?
        let bytes: Int64?
        let content: String?
        let fileCount: Int?
        let destination: String?
    }
}

/// Reads and writes the stream's file: owner-only (0600), replaced atomically.
final class ActivityStore {
    static let fileName = "activity-stream.json"

    let fileURL: URL
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.activity-store")

    init(fileURL: URL = ActivityStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load(now: Date) -> [ActivityItem] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return ActivityHistory.decode(data, now: now)
        }
    }

    func save(_ items: [ActivityItem]) {
        guard let data = try? ActivityHistory.encode(items) else { return }
        let target = fileURL
        queue.async { Self.write(data, to: target) }
    }

    func clear() {
        let target = fileURL
        queue.async { try? FileManager.default.removeItem(at: target) }
    }

    /// Waits for pending writes; used by tests.
    func flush() {
        queue.sync {}
    }

    private static func write(_ data: Data, to target: URL) {
        let manager = FileManager.default
        let directory = target.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, target.path) != 0 {
            try? manager.removeItem(at: temporary)
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/\(fileName)")
    }
}

/// The stream in memory, persisted through an `ActivityStore`. Cleared from Settings > Privacy.
@MainActor
final class ActivityLog: ObservableObject {
    @Published private(set) var items: [ActivityItem]

    private let store: ActivityStore?
    private let clock: () -> Date
    private var nextID: Int64

    init(store: ActivityStore?, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.clock = clock
        let loaded = store?.load(now: clock()) ?? []
        items = loaded
        nextID = (loaded.map(\.id).max() ?? 0) + 1
    }

    /// `previews` is Settings > Privacy > Show previews in activity. Off: no preview text,
    /// app name or caller is kept for this event.
    func record(
        _ kind: ActivityKind,
        deviceID: String?,
        deviceName: String,
        fileName: String? = nil,
        preview: String? = nil,
        appName: String? = nil,
        sensitive: Bool = false,
        automatic: Bool = false,
        count: Int = 1,
        bytes: Int64? = nil,
        content: String? = nil,
        fileCount: Int? = nil,
        destination: String? = nil,
        previews: Bool
    ) {
        let updated = ActivityHistory.add(
            items,
            kind: kind,
            deviceID: deviceID,
            deviceName: deviceName,
            // Clipboard offers keep a file name only with previews on.
            fileName: kind.isClipOffer && !previews ? nil : fileName,
            preview: previews ? preview : nil,
            appName: previews ? appName : nil,
            sensitive: sensitive,
            automatic: automatic,
            count: count,
            bytes: bytes,
            content: content,
            fileCount: fileCount,
            destination: destination,
            now: clock(),
            nextID: nextID
        )
        if updated.contains(where: { $0.id == nextID }) { nextID += 1 }
        items = updated
        store?.save(updated)
    }

    /// Drops expired items; called when the stream is shown.
    func prune() {
        let pruned = ActivityHistory.prune(items, now: clock())
        guard pruned != items else { return }
        items = pruned
        store?.save(pruned)
    }

    func clear() {
        items = []
        store?.clear()
    }
}
