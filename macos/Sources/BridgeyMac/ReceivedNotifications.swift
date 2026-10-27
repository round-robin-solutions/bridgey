import AppKit
import Foundation
import UserNotifications

// Files 2.0 quick win: a notification for what arrives from a phone (single files, folders the phone pushed,
// downloads saved from the Phone files window), with Open and Show in Finder. A burst from one phone (items
// less than 3 s apart) is one notification, updated in place ("12 files from OnePlus 11"). Posted only while
// macOS allows Bridgey's notifications; otherwise the received item is revealed in Finder as before. Bridgey
// has no setting of its own for local notifications: the macOS switch decides.

let receivedNotificationCategory = "bridgey.received"
let receivedOpenActionIdentifier = "bridgey.received.open"
let receivedRevealActionIdentifier = "bridgey.received.reveal"
let receivedPathsUserInfoKey = "bridgeyReceivedPaths"
let receivedOpenPathUserInfoKey = "bridgeyReceivedOpen"

/// One received item: a file or a folder on this Mac.
struct ReceivedItem: Equatable {
    let url: URL
    let isFolder: Bool
}

/// A notification's content, built from its group. Pure, so tests check the words and the routing.
struct ReceivedNotificationContent: Equatable {
    let identifier: String
    let title: String
    let body: String
    /// What Show in Finder selects.
    let reveal: [URL]
    /// What a click on the body and Open open: the item itself, or the folder a burst landed in.
    let open: URL
}

/// Groups items per phone: a new item within `window` of the group's last item joins it (same identifier, so
/// the notification is replaced in place); later ones start a new group.
struct ReceivedNotificationGrouper {
    static let window: TimeInterval = 3
    /// Show in Finder selects at most this many; the notification still counts all of them.
    static let maxPaths = 200

    private struct Group {
        let identifier: String
        let phoneName: String
        var items: [ReceivedItem]
        var count: Int
        var last: Date
    }

    private var groups: [String: Group] = [:]
    private let makeID: () -> String

    init(makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) { self.makeID = makeID }

    mutating func add(_ items: [ReceivedItem], phoneID: String, phoneName: String, at now: Date) -> ReceivedNotificationContent? {
        guard !items.isEmpty else { return nil }
        var group: Group
        if let current = groups[phoneID], now.timeIntervalSince(current.last) <= Self.window, now >= current.last {
            group = current
            group.items.append(contentsOf: items)
            group.count += items.count
            if group.items.count > Self.maxPaths { group.items = Array(group.items.prefix(Self.maxPaths)) }
        } else {
            group = Group(identifier: "bridgey.received.\(makeID())", phoneName: phoneName, items: Array(items.prefix(Self.maxPaths)),
                          count: items.count, last: now)
        }
        group.last = now
        groups[phoneID] = group
        return Self.content(identifier: group.identifier, items: group.items, count: group.count, phoneName: phoneName)
    }

    mutating func forget(_ phoneID: String) { groups.removeValue(forKey: phoneID) }

    static func content(identifier: String, items: [ReceivedItem], count: Int, phoneName: String) -> ReceivedNotificationContent {
        let urls = items.map(\.url)
        if count == 1, let item = items.first {
            let title = item.isFolder
                ? String(format: L10n.text("received.folder.title", fallback: "Folder from %@"), phoneName)
                : String(format: L10n.text("received.file.title", fallback: "File from %@"), phoneName)
            return ReceivedNotificationContent(identifier: identifier, title: title, body: item.url.lastPathComponent, reveal: urls, open: item.url)
        }
        let folders = items.filter(\.isFolder).count
        let title: String
        if folders == 0 {
            title = String(format: L10n.text("received.files.title", fallback: "%1$@ files from %2$@"), FolderText.number(count), phoneName)
        } else if folders == items.count, count == items.count {
            title = String(format: L10n.text("received.folders.title", fallback: "%1$@ folders from %2$@"), FolderText.number(count), phoneName)
        } else {
            title = String(format: L10n.text("received.items.title", fallback: "%1$@ items from %2$@"), FolderText.number(count), phoneName)
        }
        let names = items.prefix(3).map { $0.url.lastPathComponent }.joined(separator: ", ")
        let body = count > 3 ? String(format: L10n.text("received.items.more", fallback: "%1$@ and %2$@ more"), names, FolderText.number(count - 3)) : names
        return ReceivedNotificationContent(identifier: identifier, title: title, body: body, reveal: urls, open: commonFolder(urls))
    }

    /// The folder every item is in, or the first item's folder when they landed in different places.
    static func commonFolder(_ urls: [URL]) -> URL {
        let parents = urls.map { $0.deletingLastPathComponent().standardizedFileURL }
        guard let first = parents.first else { return URL(fileURLWithPath: NSHomeDirectory()) }
        if parents.allSatisfy({ $0.path == first.path }) { return first }
        var common = first.pathComponents
        for parent in parents.dropFirst() {
            let parts = parent.pathComponents
            var shared = 0
            while shared < min(common.count, parts.count), common[shared] == parts[shared] { shared += 1 }
            common = Array(common.prefix(shared))
        }
        // Different volumes or nothing in common: the first item's folder is the useful one.
        return common.count > 1 ? URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true) : first
    }
}

/// What a click on a received notification does.
enum ReceivedNotificationAction: Equatable {
    /// NSWorkspace.open: a file opens in its app, a folder in Finder.
    case open(URL)
    /// Finder selects these.
    case reveal([URL])
    case none

    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> ReceivedNotificationAction {
        let paths = (userInfo[receivedPathsUserInfoKey] as? [String]) ?? []
        let open = (userInfo[receivedOpenPathUserInfoKey] as? String).map { URL(fileURLWithPath: $0) }
        switch actionIdentifier {
        case receivedRevealActionIdentifier:
            return paths.isEmpty ? .none : .reveal(paths.map { URL(fileURLWithPath: $0) })
        case receivedOpenActionIdentifier, UNNotificationDefaultActionIdentifier:
            return open.map(ReceivedNotificationAction.open) ?? .none
        default:
            return .none
        }
    }

    /// The user's click, carried out. Items moved or deleted since are skipped; nothing left means nothing.
    @MainActor
    func perform(fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) {
        switch self {
        case let .open(url):
            guard fileExists(url) else { return }
            NSWorkspace.shared.open(url)
        case let .reveal(urls):
            let present = urls.filter(fileExists)
            guard !present.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(present)
        case .none:
            break
        }
    }
}

/// Posts and updates the notifications; owned by the coordinator, main thread.
@MainActor
final class ReceivedNotifier {
    private var grouper = ReceivedNotificationGrouper()
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: receivedNotificationCategory,
            actions: [
                UNNotificationAction(identifier: receivedOpenActionIdentifier, title: L10n.text("received.open", fallback: "Open"), options: [.foreground]),
                UNNotificationAction(identifier: receivedRevealActionIdentifier, title: L10n.text("received.reveal", fallback: "Show in Finder"), options: [.foreground]),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Posts (or updates) the phone's notification. Returns the content (tests, logs use only its identifier).
    @discardableResult
    func post(_ items: [ReceivedItem], phoneID: String, phoneName: String) -> ReceivedNotificationContent? {
        guard let content = grouper.add(items, phoneID: phoneID, phoneName: phoneName, at: clock()) else { return nil }
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.categoryIdentifier = receivedNotificationCategory
        notification.threadIdentifier = "bridgey.received.\(phoneID)"
        notification.userInfo = [
            receivedPathsUserInfoKey: content.reveal.map(\.path),
            receivedOpenPathUserInfoKey: content.open.path,
        ]
        // Same identifier: the burst's notification is replaced in place, not stacked.
        let request = UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { BridgeyLog.files.error("received notification failed error=\(String(describing: error), privacy: .public)") }
        }
        return content
    }

    func forget(_ phoneID: String) { grouper.forget(phoneID) }
}
