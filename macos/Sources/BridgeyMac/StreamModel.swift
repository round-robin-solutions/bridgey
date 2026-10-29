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

/// A trusted device that is not connected while both apps keep trying to reach it.
struct ReconnectDisplay: Equatable {
    /// When it was last connected.
    let lastSeen: Date?
    /// Several attempts failed: the chip says "Can't reach" rather than "Reconnecting".
    let struggling: Bool
    /// Not connected for over an hour and not in discovery: "Not on this network".
    var away: Bool = false
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
    /// Set while a trusted, disconnected device is being retried.
    var reconnect: ReconnectDisplay? = nil
    /// A trusted device that is not connected while a new, unpaired device with the same name is
    /// nearby: most likely the same device after a reset or reinstall, which needs pairing again.
    var namesakeNearby = false

    var canConnect: Bool { peer?.host != nil && peer?.port != nil && (state == .nearby) }
    /// Offers "Retry now".
    var canRetry: Bool { trusted && reconnect != nil && state != .connected }
}

/// Every trusted device plus every device on the network, in reading order: connected, then
/// connecting, nearby paired, offline paired, and new devices last.
func deviceRings(trusted: [TrustedDeviceInfo], peers: [DiscoveredPeer], state: PairingState) -> [DeviceRing] {
    if case let .connected(deviceID, peerName) = state {
        return deviceRings(trusted: trusted, peers: peers, connected: [PhoneConnection(id: deviceID, name: peerName, state: PhoneLinkState())], pairing: .idle)
    }
    return deviceRings(trusted: trusted, peers: peers, connected: [], pairing: state)
}

/// Multi-device: every connected phone shows as connected at once; `pairing` (the pairing
/// flow) marks the device being paired as connecting.
func deviceRings(
    trusted: [TrustedDeviceInfo],
    peers: [DiscoveredPeer],
    connected: [PhoneConnection],
    pairing: PairingState,
    reconnecting: [String: ReconnectDisplay] = [:]
) -> [DeviceRing] {
    let connectedNames = Dictionary(connected.map { ($0.id, $0.name) }, uniquingKeysWith: { $1 })
    var connectingName: String?
    switch pairing {
    case let .connecting(name), let .waitingForAllow(name):
        connectingName = name
    case let .verification(prompt):
        connectingName = prompt.peerName
    default:
        break
    }
    let trustedIDs = Set(trusted.map(\.id))
    var rings: [DeviceRing] = trusted.map { device in
        let peer = peers.first { $0.deviceIDHint == device.id }
        let ringState: RingState
        var reconnect: ReconnectDisplay?
        if connectedNames[device.id] != nil {
            ringState = .connected
        } else if let connectingName, connectingName == device.name || connectingName == peer?.deviceNameHint {
            ringState = .connecting
        } else if let retry = reconnecting[device.id] {
            // Retrying: the connecting ring while it is fresh; after several misses the ring shows
            // how it is reached (nearby or offline) and the text says it is still retrying.
            reconnect = retry
            ringState = retry.struggling ? (peer != nil ? .nearby : .offline) : .connecting
        } else if peer != nil {
            ringState = .nearby
        } else {
            ringState = .offline
        }
        let connectedName = connectedNames[device.id] ?? ""
        let name = !connectedName.isEmpty ? connectedName : device.name
        let namesake = ringState != .connected && peer == nil && peers.contains { other in
            guard let otherID = other.deviceIDHint else { return false }
            return otherID != device.id && !trustedIDs.contains(otherID) && connectedNames[otherID] == nil && other.deviceNameHint == device.name
        }
        return DeviceRing(id: device.id, deviceID: device.id, name: name, state: ringState, trusted: true, platform: peer?.platformHint, peer: peer,
                          reconnect: reconnect, namesakeNearby: namesake)
    }
    for phone in connected where !trustedIDs.contains(phone.id) {
        let peer = peers.first { $0.deviceIDHint == phone.id }
        rings.append(DeviceRing(id: phone.id, deviceID: phone.id, name: phone.name, state: .connected, trusted: true, platform: peer?.platformHint, peer: peer))
    }
    for peer in peers where peer.deviceIDHint == nil || (!trustedIDs.contains(peer.deviceIDHint!) && connectedNames[peer.deviceIDHint!] == nil) {
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

/// The pairing code as it is read: six digits grouped 3 + 3 ("482 913").
func formattedPairingCode(_ code: String) -> String {
    let digits = code.filter(\.isNumber)
    guard digits.count == 6 else { return code }
    return "\(digits.prefix(3)) \(digits.suffix(3))"
}

/// What VoiceOver says for the code: digit by digit ("4 8 2 9 1 3").
func pairingCodeSpokenLabel(_ code: String) -> String {
    code.filter(\.isNumber).map(String.init).joined(separator: " ")
}

/// Allow pairing's countdown: "1:58".
func pairingCountdownText(_ seconds: Int) -> String {
    let value = max(0, seconds)
    return String(format: "%d:%02d", value / 60, value % 60)
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

/// Transfers that need a card with an action: running ones (Cancel) and failed ones that can be retried,
/// newest first, then the queued files in the order they will be sent.
func liveTransfers(_ transfers: [String: FileTransferRow]) -> [FileTransferRow] {
    let candidates = transfers.values.filter { $0.active || $0.retryable }
    let others = candidates.filter { !$0.queued }.sorted { $0.startedAt > $1.startedAt }
    let queued = candidates.filter(\.queued).sorted { $0.startedAt < $1.startedAt }
    return others + queued
}

/// Cancel All appears on the first transfer card once more than one transfer is running or queued.
func showsCancelAll(_ transfers: [FileTransferRow]) -> Bool {
    transfers.filter(\.active).count > 1
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
        case .clipOfferSent, .clipOfferReceived, .clipPasted, .clipPasteFailed:
            return clipTitle(item, device: device, showPreviews: showPreviews)
        case .folderSent, .folderReceived, .folderIncomplete:
            return folderTitle(item, device: device)
        case .updateAutoDone, .updateAutoWaiting, .updateAutoSkipped, .updateAutoStartedBy, .updateAutoFailed:
            return AutoUpdateText.activityTitle(item)
        }
    }

    /// "Sent folder Photos (124 files, 2.3 GB) to OnePlus 11 › Pictures/Trip".
    static func folderTitle(_ item: ActivityItem, device: String) -> String {
        let name = item.fileName ?? L10n.text("stream.folder", fallback: "Folder")
        let files = item.fileCount ?? 0
        let size = ByteCountFormatter.string(fromByteCount: item.bytes ?? 0, countStyle: .file)
        let place = item.destination.map { "\(device) \u{203A} \($0)" } ?? device
        let fileText = files == 1
            ? L10n.text("folders.count.file", fallback: "1 file")
            : String(format: L10n.text("folders.count.files", fallback: "%@ files"), FolderText.number(files))
        switch item.kind {
        case .folderReceived:
            return String(format: L10n.text("stream.folder.received", fallback: "Received folder %1$@ (%2$@, %3$@) from %4$@"), name, fileText, size, place)
        case .folderIncomplete:
            let detail = FolderActivityDetail(item.content)
            let done = ByteCountFormatter.string(fromByteCount: detail.doneBytes ?? 0, countStyle: .file)
            return String(format: L10n.text("stream.folder.incomplete", fallback: "Folder %1$@ incomplete: %2$@ of %3$@ files (%4$@) to %5$@"),
                          name, FolderText.number(detail.doneFiles ?? 0), FolderText.number(files), done, place)
        default:
            return String(format: L10n.text("stream.folder.sent", fallback: "Sent folder %1$@ (%2$@, %3$@) to %4$@"), name, fileText, size, place)
        }
    }

    /// "Merged, 12 kept as copies · 3 links and 12 hidden items skipped · 3 files failed".
    static func folderDetail(_ item: ActivityItem) -> String? {
        let detail = FolderActivityDetail(item.content)
        let device = item.deviceName.isEmpty ? L10n.text("stream.device.unknown", fallback: "your phone") : item.deviceName
        var parts: [String] = []
        switch detail.end {
        case nil: break
        case "cancelled": parts.append(L10n.text("folders.end.cancelled", fallback: "Cancelled"))
        case "lost": parts.append(L10n.text("stream.folder.lost", fallback: "Connection lost"))
        case "phone_cancelled": parts.append(String(format: L10n.text("folders.end.phoneCancelled", fallback: "Cancelled on %@"), device))
        case "timeout": parts.append(L10n.text("stream.folder.timeout", fallback: "Nobody answered in time"))
        case "unconfirmed": parts.append(String(format: L10n.text("folders.end.unconfirmed", fallback: "Not confirmed by %@"), device))
        case let code?: parts.append(FolderText.rejection(code: code, phone: device, needed: nil, free: nil))
        }
        if let savedAs = detail.savedAs {
            parts.append(String(format: L10n.text("stream.folder.savedAs", fallback: "Saved as %@"), savedAs))
        } else if detail.choice == ConflictChoice.merge.rawValue {
            parts.append(detail.kept > 0
                ? String(format: L10n.text("stream.folder.mergedKept", fallback: "Merged, %@ kept as copies"), FolderText.number(detail.kept))
                : L10n.text("stream.folder.merged", fallback: "Merged"))
        }
        if detail.replaced > 0 {
            parts.append(detail.replaced == 1
                ? L10n.text("stream.folder.replacedOne", fallback: "1 file replaced")
                : String(format: L10n.text("stream.folder.replaced", fallback: "%@ files replaced"), FolderText.number(detail.replaced)))
        }
        var skipped: [String] = []
        if detail.links > 0 {
            skipped.append(detail.links == 1 ? L10n.text("stream.folder.link", fallback: "1 link")
                : String(format: L10n.text("stream.folder.links", fallback: "%@ links"), FolderText.number(detail.links)))
        }
        if detail.hidden > 0 {
            skipped.append(detail.hidden == 1 ? L10n.text("stream.folder.hiddenOne", fallback: "1 hidden item")
                : String(format: L10n.text("stream.folder.hidden", fallback: "%@ hidden items"), FolderText.number(detail.hidden)))
        }
        if detail.system > 0 {
            skipped.append(detail.system == 1 ? L10n.text("stream.folder.systemOne", fallback: "1 system file")
                : String(format: L10n.text("stream.folder.system", fallback: "%@ system files"), FolderText.number(detail.system)))
        }
        if !skipped.isEmpty {
            let list = skipped.count == 1 ? skipped[0]
                : skipped.dropLast().joined(separator: ", ") + L10n.text("stream.folder.and", fallback: " and ") + skipped.last!
            parts.append(String(format: L10n.text("stream.folder.skipped", fallback: "%@ skipped"), list))
        }
        if detail.failed > 0 { parts.append(FolderText.failedFiles(detail.failed)) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// "Copied image (2.1 MB)", "Copied video.mp4 from OnePlus 11 (340 MB)", "Copied 3 files".
    /// Names show only with previews on.
    static func clipTitle(_ item: ActivityItem, device: String, showPreviews: Bool) -> String {
        if item.kind == .clipPasteFailed {
            return format("stream.clip.failed", "Couldn\u{2019}t paste from %@", device)
        }
        let size = ByteCountFormatter.string(fromByteCount: item.bytes ?? 0, countStyle: .file)
        let name = showPreviews ? item.fileName : nil
        let content = item.content ?? "file"
        let prefix: String
        switch item.kind {
        case .clipOfferSent: prefix = "stream.clip.sent"
        case .clipPasted: prefix = "stream.clip.pasted"
        default: prefix = "stream.clip.received"
        }
        let fallbacks = clipFallbacks(item.kind)
        if item.count > 1 {
            let key = content == "image" ? "images" : "files"
            let template = L10n.text("\(prefix).\(key)", fallback: fallbacks[key]!)
            return item.kind == .clipOfferSent
                ? String.localizedStringWithFormat(template, item.count)
                : String.localizedStringWithFormat(template, item.count, device)
        }
        let key: String
        var values: [CVarArg]
        switch (content, name) {
        case ("image", _): key = "image"; values = [size]
        case ("text", _): key = "text"; values = [size]
        case let (_, name?): key = "named"; values = [name, size]
        default: key = "file"; values = [size]
        }
        if item.kind != .clipOfferSent { values.insert(device, at: key == "named" ? 1 : 0) }
        return String(format: L10n.text("\(prefix).\(key)", fallback: fallbacks[key]!), arguments: values)
    }

    private static func clipFallbacks(_ kind: ActivityKind) -> [String: String] {
        switch kind {
        case .clipOfferSent:
            return ["image": "Copied image (%@)", "named": "Copied %1$@ (%2$@)", "file": "Copied a file (%@)",
                    "text": "Copied text (%@)", "images": "Copied %d images", "files": "Copied %d files"]
        case .clipPasted:
            return ["image": "Pasted image from %1$@ (%2$@)", "named": "Pasted %1$@ from %2$@ (%3$@)",
                    "file": "Pasted a file from %1$@ (%2$@)", "text": "Pasted text from %1$@ (%2$@)",
                    "images": "Pasted %1$d images from %2$@", "files": "Pasted %1$d files from %2$@"]
        default:
            return ["image": "Copied image from %1$@ (%2$@)", "named": "Copied %1$@ from %2$@ (%3$@)",
                    "file": "Copied a file from %1$@ (%2$@)", "text": "Copied text from %1$@ (%2$@)",
                    "images": "Copied %1$d images from %2$@", "files": "Copied %1$d files from %2$@"]
        }
    }

    /// The second line, or nil for a one-line row: the quoted clipboard preview, "Hidden" for
    /// concealed clips, and "Automatic" for Automatic clipboard.
    static func detail(_ item: ActivityItem, showPreviews: Bool) -> String? {
        let device = item.deviceName.isEmpty ? L10n.text("stream.device.unknown", fallback: "your phone") : item.deviceName
        switch item.kind {
        case .clipOfferSent:
            return item.automatic
                ? format("stream.clip.sent.detail.auto", "Automatic, ready to paste on %@", device)
                : format("stream.clip.sent.detail", "Ready to paste on %@", device)
        case .clipOfferReceived: return L10n.text("stream.clip.received.detail", fallback: "Ready to paste here")
        case .clipPasted: return L10n.text("stream.clip.pasted.detail", fallback: "Moved when you pasted")
        case .clipPasteFailed: return L10n.text("stream.clip.failed.detail", fallback: "Copy it again and paste")
        case .folderSent, .folderReceived, .folderIncomplete: return folderDetail(item)
        case .updateAutoWaiting, .updateAutoSkipped, .updateAutoFailed: return AutoUpdateText.activityDetail
        default: break
        }
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

/// A ring's one-line status under the device name (short form, for narrow chips).
func ringStatusText(_ ring: DeviceRing) -> String {
    if let retry = ring.reconnect, ring.state != .connected {
        if retry.away { return L10n.text("ring.away", fallback: "Not nearby") }
        return retry.struggling
            ? L10n.text("ring.retrying", fallback: "Retrying\u{2026}")
            : L10n.text("ring.reconnecting", fallback: "Reconnecting\u{2026}")
    }
    return switch ring.state {
    case .connected: L10n.text("ring.connected", fallback: "Same Wi-Fi")
    case .connecting: L10n.text("ring.connecting", fallback: "Connecting")
    case .nearby: ring.trusted ? L10n.text("ring.nearby", fallback: "Nearby") : L10n.text("ring.new", fallback: "New device")
    case .offline: L10n.text("ring.offline", fallback: "Offline")
    case .relay: L10n.text("ring.relay", fallback: "Relay")
    case .privateNetwork: L10n.text("ring.private", fallback: "Private")
    }
}

/// The long status, where there is room (a wide chip, Settings): "Reconnecting… (last seen 02:56)",
/// "Can't reach. Retrying (last seen 02:56)" or, away for over an hour, "Not on this network (last
/// seen 10:20)". Other states use the short text.
func ringStatusDetail(_ ring: DeviceRing, now: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
    guard let retry = ring.reconnect, ring.state != .connected else { return ringStatusText(ring) }
    let base = retry.away
        ? L10n.text("ring.away.detail", fallback: "Not on this network")
        : retry.struggling
        ? L10n.text("ring.cantReach", fallback: "Can\u{2019}t reach. Retrying")
        : L10n.text("ring.reconnecting", fallback: "Reconnecting\u{2026}")
    guard let seen = retry.lastSeen else { return base }
    let when = lastSeenText(seen, now: now, locale: locale, calendar: calendar)
    return String(format: L10n.text("ring.lastSeen", fallback: "%1$@ (last seen %2$@)"), base, when)
}

/// The chip's tooltip: what is happening, with the device's name, and what a click does.
func ringRetryHelp(_ ring: DeviceRing) -> String {
    let struggling = ring.reconnect?.struggling == true
    let help: String
    if ring.reconnect?.away == true {
        help = String(format: L10n.text("ring.away.help", fallback: "%@ has not been on this network for over an hour. Bridgey checks every 10 minutes. Click to retry now."), ring.name)
    } else {
        help = String(format: struggling
            ? L10n.text("ring.cantReach.help", fallback: "Can\u{2019}t reach %@. Bridgey keeps retrying. Click to retry now.")
            : L10n.text("ring.reconnecting.help", fallback: "Reconnecting to %@. Click to retry now."), ring.name)
    }
    guard ring.namesakeNearby else { return help }
    // The usual reason: the device was reset or reinstalled and now has a new identity.
    let namesake = String(format: L10n.text("ring.namesake.help", fallback: "A new device named %@ is nearby. If this device was reset, pair the new one and remove this one."), ring.name)
    return "\(help) \(namesake)"
}

/// "02:56" today, "Mon 02:56" this week, else "26 Oct".
func lastSeenText(_ date: Date, now: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    if calendar.isDate(date, inSameDayAs: now) {
        formatter.setLocalizedDateFormatFromTemplate("jmm")
    } else if now.timeIntervalSince(date) < 6 * 86_400 {
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
    } else {
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
    }
    return formatter.string(from: date)
}
