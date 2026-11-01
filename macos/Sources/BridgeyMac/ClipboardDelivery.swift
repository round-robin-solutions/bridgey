import Foundation

/*
 * One copy, one activity item. A copy that goes to several devices (Automatic clipboard sends to
 * every connected device) is one group: each device's message has its own id, acknowledgement and
 * timeout, and every answer updates the same item's per-device state. The item appears with the
 * first delivery; a copy no device took leaves only the status line, as before.
 *
 * Arrivals: the same clip arriving again within a minute through another device (for example a
 * phone and a Mac both passing it on) adds that device to the first item instead of a new row.
 * Clip hashes stay in memory only.
 */

/// The copy a group describes.
struct ClipboardSendGroup: Equatable {
    let id: String
    /// `.clipboardSent` (text) or `.clipOfferSent` (images, files, long text).
    let kind: ActivityKind
    let preview: String?
    let sensitive: Bool
    let automatic: Bool
    let summary: ClipboardOfferSummary?
    var peers: [ActivityPeer] = []
    /// The activity item, once the first device took the copy.
    var activityID: Int64?

    var delivered: [ActivityPeer] { peers.filter { $0.state == .delivered } }
    var isSettled: Bool { !peers.contains { $0.state == .pending } }
}

struct ClipboardDeliveryTracker {
    /// Groups older than this many sends are dropped (their late answers are ignored).
    static let keptGroups = 8

    private(set) var groups: [String: ClipboardSendGroup] = [:]
    private var order: [String] = []
    /// Message id to (group, device).
    private var messages: [String: (group: String, deviceID: String)] = [:]

    mutating func begin(_ group: ClipboardSendGroup) {
        groups[group.id] = group
        order.append(group.id)
        while order.count > Self.keptGroups {
            let dropped = order.removeFirst()
            groups[dropped] = nil
            messages = messages.filter { $0.value.group != dropped }
        }
    }

    /// One device's message in a group; the device starts as pending.
    mutating func add(messageID: String, deviceID: String, deviceName: String, to groupID: String) {
        guard var group = groups[groupID] else { return }
        messages[messageID] = (groupID, deviceID)
        if let index = group.peers.firstIndex(where: { $0.deviceID == deviceID }) {
            group.peers[index].state = .pending
        } else {
            group.peers.append(ActivityPeer(deviceID: deviceID, deviceName: deviceName, state: .pending))
        }
        groups[groupID] = group
    }

    func contains(messageID: String?) -> Bool {
        messageID.map { messages[$0] != nil } ?? false
    }

    func group(forMessage messageID: String?) -> ClipboardSendGroup? {
        messageID.flatMap { messages[$0] }.flatMap { groups[$0.group] }
    }

    /// An answer (or a timeout) for one message. Nil when the message is unknown or already
    /// answered, so a late or repeated acknowledgement changes nothing.
    mutating func resolve(messageID: String?, state: ActivityPeer.State, from deviceID: String? = nil) -> ClipboardSendGroup? {
        guard let messageID, let entry = messages[messageID], var group = groups[entry.group] else { return nil }
        if let deviceID, deviceID != entry.deviceID { return nil }
        messages[messageID] = nil
        guard let index = group.peers.firstIndex(where: { $0.deviceID == entry.deviceID }) else { return nil }
        group.peers[index].state = state
        groups[entry.group] = group
        return group
    }

    mutating func setActivityID(_ id: Int64, for groupID: String) {
        groups[groupID]?.activityID = id
    }

    /// The device's session ended: its pending messages fail. Returns the groups that changed.
    mutating func sessionEnded(deviceID: String) -> [ClipboardSendGroup] {
        let ended = messages.filter { $0.value.deviceID == deviceID }.map(\.key)
        var changed: [String: ClipboardSendGroup] = [:]
        for messageID in ended {
            if let group = resolve(messageID: messageID, state: .failed) { changed[group.id] = group }
        }
        return order.compactMap { changed[$0] }
    }

    mutating func removeAll() {
        groups = [:]
        order = []
        messages = [:]
    }

    /// The messages still waiting in a group (for their timeouts).
    func pendingMessages(in groupID: String) -> [String] {
        messages.filter { $0.value.group == groupID }.map(\.key)
    }
}

/// The same clip arriving again through another device within `window`: one item, more sources.
struct ClipboardArrivals {
    static let window: TimeInterval = 60
    static let kept = 8

    struct Arrival: Equatable {
        let hash: String
        let at: Date
        let activityID: Int64
        var peers: [ActivityPeer]
    }

    private(set) var recent: [Arrival] = []

    /// The earlier arrival of the same clip from another device, if any. A second copy of the
    /// same text from the same device is a new copy, so it gets its own item.
    func match(hash: String, deviceID: String, now: Date) -> Arrival? {
        recent.last { arrival in
            arrival.hash == hash && now >= arrival.at && now.timeIntervalSince(arrival.at) <= Self.window &&
                !arrival.peers.contains { $0.deviceID == deviceID }
        }
    }

    mutating func record(hash: String, activityID: Int64, peer: ActivityPeer, now: Date) {
        recent.removeAll { $0.activityID == activityID }
        recent.append(Arrival(hash: hash, at: now, activityID: activityID, peers: [peer]))
        if recent.count > Self.kept { recent.removeFirst(recent.count - Self.kept) }
    }

    /// Adds a device to an earlier arrival; returns its new peer list.
    mutating func add(peer: ActivityPeer, to activityID: Int64) -> [ActivityPeer]? {
        guard let index = recent.firstIndex(where: { $0.activityID == activityID }) else { return nil }
        recent[index].peers.append(peer)
        return recent[index].peers
    }

    mutating func removeAll() { recent = [] }
}

/// "OnePlus 11 5G", "OnePlus 11 5G and MacBook Pro", "A, B and C".
enum DeviceList {
    static func join(_ names: [String]) -> String {
        let and = L10n.text("stream.folder.and", fallback: " and ")
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + and + names.last!
        }
    }
}

/// The send bar's line for the newest copy. Automatic copies stay quiet unless a device missed one.
enum ClipDeliveryText {
    static func status(_ group: ClipboardSendGroup) -> String? {
        let missed = group.peers.filter { $0.state == .failed || $0.state == .off }
        if !group.isSettled {
            return group.automatic || !group.delivered.isEmpty ? nil : L10n.text("clipboard.status.sending", fallback: "Sending\u{2026}")
        }
        if missed.isEmpty {
            return group.automatic ? nil : L10n.text("clipboard.status.delivered", fallback: "Delivered")
        }
        let names = DeviceList.join(missed.map(\.deviceName))
        if group.delivered.isEmpty, missed.allSatisfy({ $0.state == .off }) {
            return group.kind == .clipOfferSent
                ? String(format: L10n.text("clipboard.status.offersOff", fallback: "Copy images and files is turned off on %@"), names)
                : String(format: L10n.text("clipboard.status.off", fallback: "Clipboard is turned off on %@"), names)
        }
        if group.delivered.isEmpty, group.peers.count == 1 {
            return L10n.text("clipboard.status.noAck", fallback: "No delivery acknowledgement")
        }
        return String(format: L10n.text("clipboard.status.missed", fallback: "Not delivered to %@"), names)
    }
}
