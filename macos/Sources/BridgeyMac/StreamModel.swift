import Foundation

/*
 * Pure view-state mapping for the Stream panel and Settings, unit tested without AppKit.
 * Mirrors android/.../ui/StreamModel.kt.
 */

/// How a device is reached right now. Each has its own ring style.
enum RingState: Equatable {
    /// Connected over the local network: the aurora gradient ring.
    case connected
    /// Pairing or reconnecting.
    case connecting
    /// Seen on the network but not connected: dashed green ring.
    case nearby
    /// Paired but not seen: plain grey ring.
    case offline
    /// Reached through the relay: dashed purple ring. Defined for the design; Bridgey has no relay yet.
    case relay
    /// Reached over a private network: solid blue ring. Defined for the design; not used yet.
    case privateNetwork
}

struct DeviceRing: Identifiable, Equatable {
    /// Stable key for lists; the device id when known.
    let id: String
    let deviceID: String?
    let name: String
    let state: RingState
    let trusted: Bool
    /// Platform from discovery ("macos", "android"); nil when unknown.
    let platform: String?
    /// Where to connect to pair or reconnect; nil when not on the network.
    let peer: DiscoveredPeer?

    var canConnect: Bool { peer?.host != nil && peer?.port != nil && (state == .nearby) }
}

/// Every trusted device plus every device on the network, in reading order: connected, then
/// connecting, nearby paired, offline paired, and new devices last.
func deviceRings(trusted: [TrustedDeviceInfo], peers: [DiscoveredPeer], state: PairingState) -> [DeviceRing] {
    var connectedID: String?
    var connectedName = ""
    var connectingName: String?
    switch state {
    case let .connected(deviceID, peerName):
        connectedID = deviceID
        connectedName = peerName
    case let .connecting(name):
        connectingName = name
    case let .verification(name, _):
        connectingName = name
    default:
        break
    }
    let trustedIDs = Set(trusted.map(\.id))
    var rings: [DeviceRing] = trusted.map { device in
        let peer = peers.first { $0.deviceIDHint == device.id }
        let ringState: RingState
        if device.id == connectedID {
            ringState = .connected
        } else if let connectingName, connectingName == device.name || connectingName == peer?.deviceNameHint {
            ringState = .connecting
        } else if peer != nil {
            ringState = .nearby
        } else {
            ringState = .offline
        }
        let name = device.id == connectedID && !connectedName.isEmpty ? connectedName : device.name
        return DeviceRing(id: device.id, deviceID: device.id, name: name, state: ringState, trusted: true, platform: peer?.platformHint, peer: peer)
    }
    if let connectedID, !trustedIDs.contains(connectedID) {
        let peer = peers.first { $0.deviceIDHint == connectedID }
        rings.append(DeviceRing(id: connectedID, deviceID: connectedID, name: connectedName, state: .connected, trusted: true, platform: peer?.platformHint, peer: peer))
    }
    for peer in peers where peer.deviceIDHint == nil || (!trustedIDs.contains(peer.deviceIDHint!) && peer.deviceIDHint != connectedID) {
        let ringState: RingState = connectingName != nil && connectingName == peer.deviceNameHint ? .connecting : .nearby
        rings.append(DeviceRing(id: "peer:\(peer.id)", deviceID: peer.deviceIDHint, name: peer.deviceNameHint, state: ringState, trusted: false, platform: peer.platformHint, peer: peer))
    }
    func order(_ ring: DeviceRing) -> Int {
        switch ring.state {
        case .connected: return 0
        case .connecting: return 1
        default: return ring.trusted ? (ring.state == .nearby ? 2 : 3) : 4
        }
    }
    return rings.enumerated()
        .sorted { (order($0.element), $0.offset) < (order($1.element), $1.offset) }
        .map(\.element)
}

enum DaySection: Int, Comparable {
    case today, yesterday, earlier
    static func < (lhs: DaySection, rhs: DaySection) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum StreamRow: Identifiable, Equatable {
    case header(DaySection)
    case item(ActivityItem, DaySection)

    var id: String {
        switch self {
        case let .header(section): "header:\(section.rawValue)"
        case let .item(item, _): "item:\(item.id)"
        }
    }
}

func daySection(_ date: Date, now: Date, calendar: Calendar) -> DaySection {
    let today = calendar.startOfDay(for: now)
    if date >= today { return .today }
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return .earlier }
    return date >= yesterday ? .yesterday : .earlier
}

/// The stream as list rows: newest first, grouped under Today, Yesterday and Earlier. Items past
/// the seven day limit are dropped even before the log prunes them. `deviceID` filters by device.
func streamRows(_ items: [ActivityItem], deviceID: String? = nil, now: Date, calendar: Calendar = .current) -> [StreamRow] {
    let visible = ActivityHistory.prune(items, now: now).filter { deviceID == nil || $0.deviceID == deviceID }
    var rows: [StreamRow] = []
    var current: DaySection?
    for item in visible {
        let section = daySection(item.at, now: now, calendar: calendar)
        if section != current {
            rows.append(.header(section))
            current = section
        }
        rows.append(.item(item, section))
    }
    return rows
}

/// Transfers that need a card with an action: running ones (Cancel) and failed ones that can be retried.
func liveTransfers(_ transfers: [String: FileTransferRow]) -> [FileTransferRow] {
    transfers.values.filter { $0.active || $0.retryable }.sorted { $0.startedAt > $1.startedAt }
}

/// A transfer card's detail without repeating the file name the card already shows as its title.
func transferDetail(_ transfer: FileTransferRow) -> String {
    for verb in ["Sending", "Receiving"] {
        let prefix = "\(verb) \(transfer.name): "
        if transfer.status.hasPrefix(prefix) { return "\(verb), \(transfer.status.dropFirst(prefix.count))" }
        if transfer.status == "\(verb) \(transfer.name)\u{2026}" { return "\(verb)\u{2026}" }
    }
    return transfer.status
}

/// Words shown for stream items. Previews (clipboard text, app names, callers) appear only
/// when `showPreviews` is on, so turning the switch off hides what was stored before.
enum ActivityText {
    static func title(_ item: ActivityItem, showPreviews: Bool) -> String {
        let device = item.deviceName.isEmpty ? L10n.text("stream.device.unknown", fallback: "your phone") : item.deviceName
        if showPreviews, item.kind == .notificationsShown, let app = item.appName {
            return item.count == 1
                ? format("stream.alert.app", "1 %@ alert", app)
                : String.localizedStringWithFormat(L10n.text("stream.alerts.app", fallback: "%1$d %2$@ alerts"), item.count, app)
        }
        if showPreviews, item.kind == .callShown, let caller = item.preview {
            return format("stream.call.from", "Call from %@", caller)
        }
        switch item.kind {
        case .clipboardSent: return format("stream.clipboard.sent", "Clipboard sent to %@", device)
        case .clipboardReceived: return format("stream.clipboard.received", "Copied text from %@", device)
        case .fileSent:
            return format("stream.file.sent", "%@ sent", item.fileName ?? L10n.text("stream.file", fallback: "File"))
        case .fileReceived:
            return format("stream.file.received", "%@ received", item.fileName ?? L10n.text("stream.file", fallback: "File"))
        case .fileFailed:
            return format("stream.file.failed", "%@ not delivered", item.fileName ?? L10n.text("stream.file", fallback: "File"))
        case .linkSent: return format("stream.link.sent", "Link sent to %@", device)
        case .linkReceived: return format("stream.link.received", "Link from %@", device)
        case .notificationsShown:
            return item.count == 1
                ? L10n.text("stream.alert", fallback: "1 alert")
                : String.localizedStringWithFormat(L10n.text("stream.alerts", fallback: "%d alerts"), item.count)
        case .callShown:
            return item.count == 1
                ? L10n.text("stream.call", fallback: "Incoming call")
                : String.localizedStringWithFormat(L10n.text("stream.calls", fallback: "%d calls"), item.count)
        case .callStarted: return format("stream.call.started", "Call placed on %@", device)
        case .pingSent: return format("stream.ping.sent", "Pinged %@", device)
        case .pingReceived: return format("stream.ping.received", "Ping from %@", device)
        case .findMac: return format("stream.find.mac", "%@ rang this Mac", device)
        case .findPhone: return format("stream.find.phone", "Rang %@", device)
        case .paired: return format("stream.paired", "Paired with %@", device)
        }
    }

    /// The second line, or nil for a one-line row: the quoted clipboard preview, "Hidden" for
    /// concealed clips, and "Automatic" for Automatic clipboard.
    static func detail(_ item: ActivityItem, showPreviews: Bool) -> String? {
        guard item.kind.category == .clipboard else { return nil }
        var parts: [String] = []
        if item.automatic { parts.append(L10n.text("stream.automatic", fallback: "Automatic")) }
        if item.sensitive {
            parts.append(L10n.text("stream.hidden", fallback: "Hidden"))
        } else if showPreviews, let preview = item.preview {
            parts.append("\u{201C}\(preview)\u{201D}")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func time(_ date: Date, now: Date, section: DaySection, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= 0 && elapsed < 60 { return L10n.text("stream.now", fallback: "Now") }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if section == .earlier {
            formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    static func section(_ section: DaySection) -> String {
        switch section {
        case .today: L10n.text("stream.today", fallback: "Today")
        case .yesterday: L10n.text("stream.yesterday", fallback: "Yesterday")
        case .earlier: L10n.text("stream.earlier", fallback: "Earlier this week")
        }
    }

    private static func format(_ key: String, _ fallback: String, _ value: String) -> String {
        String(format: L10n.text(key, fallback: fallback), value)
    }
}

/// A ring's one-line status under the device name.
func ringStatusText(_ ring: DeviceRing) -> String {
    switch ring.state {
    case .connected: L10n.text("ring.connected", fallback: "Same Wi-Fi")
    case .connecting: L10n.text("ring.connecting", fallback: "Connecting")
    case .nearby: ring.trusted ? L10n.text("ring.nearby", fallback: "Nearby") : L10n.text("ring.new", fallback: "New device")
    case .offline: L10n.text("ring.offline", fallback: "Offline")
    case .relay: L10n.text("ring.relay", fallback: "Relay")
    case .privateNetwork: L10n.text("ring.private", fallback: "Private")
    }
}
