import Foundation
import os

struct NotificationHistoryItem: Codable, Identifiable, Equatable {
    let id: String
    let packageName: String
    let applicationName: String
    let title: String
    let text: String
    let receivedAt: Date
    /// Text messages (sms_draft1): the phone and notification it came from, its conversation and whether
    /// the phone can answer it. Optional, so history files from before still load.
    var deviceID: String? = nil
    var notificationID: String? = nil
    var smsThreadID: Int? = nil
    var smsReply: Bool? = nil

    /// Reply opens the conversation in the Messages window.
    var opensConversation: Bool { deviceID != nil && (smsThreadID != nil || smsReply == true) }
}

final class NotificationHistoryStore {
    static let maximumItems = 200
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL

    init(fileURL: URL = NotificationHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load(now: Date = Date()) -> [NotificationHistoryItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([NotificationHistoryItem].self, from: data) else { return [] }
        let items = pruned(decoded, now: now)
        if items != decoded { save(items) }
        return items
    }

    @discardableResult
    func record(_ item: NotificationHistoryItem, in current: [NotificationHistoryItem], now: Date = Date()) -> [NotificationHistoryItem] {
        let items = pruned([item] + current.filter { $0.id != item.id }, now: now)
        save(items)
        return items
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func pruned(_ items: [NotificationHistoryItem], now: Date) -> [NotificationHistoryItem] {
        let oldest = now.addingTimeInterval(-Self.maximumAge)
        return Array(items.filter { $0.receivedAt >= oldest }.sorted { $0.receivedAt > $1.receivedAt }.prefix(Self.maximumItems))
    }

    private func save(_ items: [NotificationHistoryItem]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            BridgeyLog.notifications.error("notification history persistence failed error=\(String(describing: error), privacy: .private)")
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/notification-history.json")
    }
}
