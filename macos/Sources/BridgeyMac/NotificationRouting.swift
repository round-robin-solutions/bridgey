import Foundation

/// Feature-map key for routing phone alerts to the Mac in use (PR #7). Presence itself is #19's.
let notificationRoutingFeatureKey = "notification_routing_draft1"

struct CodeReadPermissionTicket {
    let channel: CodeChannel
    let codesRevision: UInt64
    let emailRevision: UInt64
}

/// Permission changes invalidate in-flight work, including an off/on cycle before it completes.
/// Email-only changes leave an unrelated SMS read alone. The coordinator updates this synchronously
/// from the published permission values, before scheduling feature-map refreshes.
struct CodeReadPermissionFence {
    private var enabled = false
    private var emailEnabled = false
    private var codesRevision: UInt64 = 0
    private var emailRevision: UInt64 = 0

    mutating func update(enabled: Bool, emailEnabled: Bool) {
        if self.enabled != enabled { codesRevision &+= 1 }
        if self.emailEnabled != emailEnabled { emailRevision &+= 1 }
        self.enabled = enabled
        self.emailEnabled = emailEnabled
    }

    func ticket(for channel: CodeChannel) -> CodeReadPermissionTicket? {
        guard enabled, channel != .email || emailEnabled else { return nil }
        return CodeReadPermissionTicket(channel: channel, codesRevision: codesRevision, emailRevision: emailRevision)
    }

    func permits(_ ticket: CodeReadPermissionTicket) -> Bool {
        enabled && ticket.codesRevision == codesRevision &&
            (ticket.channel != .email || emailEnabled && ticket.emailRevision == emailRevision)
    }
}

enum NotificationPresentation: String, Codable, Equatable {
    case alert, quiet

    /// Missing means the legacy alert behavior. A present value is strict and negotiated:
    /// null, numbers, unknown enum values and duplicate top-level keys are never alerts.
    static func decode(_ data: Data, negotiated: Bool) -> NotificationPresentation? {
        // Strict JSON with unique top-level keys (shared with presence.state); Foundation would otherwise
        // keep one of duplicate keys, which could disagree with Android about whether a notification is quiet.
        guard let object = presenceJSONObject(data) else { return nil }
        if let event = object["eventId"] {
            guard negotiated, object["callType"] == nil, let id = event as? String,
                  id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        }
        guard let value = object["presentation"] else { return .alert }
        guard negotiated, let text = value as? String else { return nil }
        return NotificationPresentation(rawValue: text)
    }
}

struct NotificationPresentationTicket: Equatable {
    let identifier: String
    let sessionID: String
    let generation: UInt64
}

/// One bounded policy record per notification. Updating to quiet, removing, replacing the
/// session or evicting a record fences every outstanding asynchronous code-reading callback.
struct NotificationPresentationLedger {
    private struct Record {
        let ticket: NotificationPresentationTicket
        let deviceID: String
        let presentation: NotificationPresentation
    }
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var generation: UInt64 = 0
    let limit: Int
    init(limit: Int = 1_024) { self.limit = max(1, limit) }

    mutating func receive(deviceID: String, notificationID: String, sessionID: String,
                          presentation: NotificationPresentation) -> NotificationPresentationTicket {
        let identifier = remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: notificationID)
        generation &+= 1
        let ticket = NotificationPresentationTicket(identifier: identifier, sessionID: sessionID, generation: generation)
        if records[identifier] == nil { order.append(identifier) }
        records[identifier] = Record(ticket: ticket, deviceID: deviceID, presentation: presentation)
        while order.count > limit { records.removeValue(forKey: order.removeFirst()) }
        return ticket
    }

    func isCurrent(_ ticket: NotificationPresentationTicket) -> Bool { records[ticket.identifier]?.ticket == ticket }

    func allowsAlert(_ ticket: NotificationPresentationTicket) -> Bool {
        records[ticket.identifier].map { $0.ticket == ticket && $0.presentation == .alert } == true
    }

    mutating func remove(deviceID: String, notificationID: String) {
        let id = remoteNotificationRequestIdentifier(deviceID: deviceID, notificationID: notificationID)
        records.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    mutating func remove(deviceID: String) {
        let ids = Set(records.filter { $0.value.deviceID == deviceID }.keys)
        for id in ids { records.removeValue(forKey: id) }
        order.removeAll { ids.contains($0) }
    }
}
