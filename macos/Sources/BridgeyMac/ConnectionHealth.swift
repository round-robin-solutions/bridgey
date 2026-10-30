import Foundation

/*
 * Connection health (docs/protocol.md, "Connection health"): per paired phone, how the link is
 * doing. Privacy: what this holds and exports is a route class, tokens, counts and times. Never
 * an address, a name or any content. The round trip comes from the existing heartbeat.ping and
 * its pong, which echoes the ping's messageId.
 */

enum ConnectionRoute: String, Equatable {
    /// A private LAN range (RFC 1918, link-local, IPv6 unique local) or a `.local` name.
    case sameNetwork = "same_network"
    /// A private overlay network: 100.64.0.0/10 (carrier-grade NAT, Tailscale) or Tailscale's IPv6 range.
    case privateNetwork = "private_network"
    case otherNetwork = "other_network"
    case unknown
}

/// The route class of a peer address. The address itself never leaves this function.
func connectionRoute(forHost raw: String?) -> ConnectionRoute {
    guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return .unknown }
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
    if host.lowercased().hasPrefix("::ffff:"), parseIPv4(String(host.dropFirst(7))) != nil { host = String(host.dropFirst(7)) }
    if let value = parseIPv4(host) {
        let a = value >> 24, b = (value >> 16) & 0xFF
        if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) || a == 127 {
            return .sameNetwork
        }
        if a == 100 && (64...127).contains(b) { return .privateNetwork }
        return .otherNetwork
    }
    var address = in6_addr()
    if inet_pton(AF_INET6, host, &address) == 1 {
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        // Tailscale's unique local range fd7a:115c:a1e0::/48.
        if bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) { return .privateNetwork }
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return .sameNetwork }
        if (bytes[0] & 0xFE) == 0xFC { return .sameNetwork }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .sameNetwork }
        return .otherNetwork
    }
    return host.lowercased().hasSuffix(".local") || host.lowercased().hasSuffix(".local.") ? .sameNetwork : .unknown
}

/// The route class of a Connect anywhere tunnel (lan, vpn, direct, relay).
func connectionRoute(forTunnel route: String) -> ConnectionRoute {
    switch ConnectRouteKind(rawValue: route) {
    case .lan: .sameNetwork
    case .vpn: .privateNetwork
    case .direct, .relay: .otherNetwork
    case nil: .unknown
    }
}

/// Heartbeat round trips: the send time of the last few pings, and the last ten samples.
struct HeartbeatRoundTrips: Equatable {
    static let maximumPending = 8
    static let maximumSamples = 10

    private var pending: [(id: String, at: Date)] = []
    private(set) var samples: [TimeInterval] = []

    static func == (lhs: HeartbeatRoundTrips, rhs: HeartbeatRoundTrips) -> Bool { lhs.samples == rhs.samples }

    mutating func sent(_ id: String, at date: Date) {
        pending.append((id, date))
        if pending.count > Self.maximumPending { pending.removeFirst(pending.count - Self.maximumPending) }
    }

    /// The pong for `id`: its round trip, or nil when it answers no ping of ours.
    @discardableResult
    mutating func received(_ id: String?, at date: Date) -> TimeInterval? {
        guard let id, let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
        let rtt = max(0, date.timeIntervalSince(pending[index].at))
        pending.removeSubrange(...index)
        guard rtt < 60 else { return nil }
        samples.append(rtt)
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
        return rtt
    }

    var last: TimeInterval? { samples.last }

    var median: TimeInterval? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// A count that starts again at local midnight.
struct DailyCounter: Equatable {
    private(set) var day: String = ""
    private(set) var count = 0

    mutating func increment(now: Date, calendar: Calendar = .current) {
        let today = Self.dayKey(now, calendar)
        if today != day { day = today; count = 0 }
        count += 1
    }

    func value(now: Date, calendar: Calendar = .current) -> Int {
        Self.dayKey(now, calendar) == day ? count : 0
    }

    private static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

/// What the coordinator keeps per phone between sessions.
struct DeviceHealthRecord: Equatable {
    var connectedSince: Date?
    var route: ConnectionRoute = .unknown
    /// Connect anywhere: the tunnel's route and relay (nil on today's TCP).
    var tunnelRoute: String?
    var tunnelRelay: String?
    /// This Mac dialled the phone (true), or the phone connected to this Mac (false).
    var outbound: Bool?
    var roundTrips = HeartbeatRoundTrips()
    var lastDropReason: String?
    var lastDropAt: Date?
    var reconnects = DailyCounter()
}

/// Bonjour on this Mac, for the health view.
enum DiscoveryHealth: String, Equatable {
    case browsing, denied, stopped
}

/// One phone's health as Settings shows it and diagnostics exports it.
struct ConnectionHealthSnapshot: Equatable, Identifiable {
    let deviceID: String
    var connected = false
    var route: ConnectionRoute = .unknown
    var tunnelRoute: String?
    var tunnelRelay: String?
    var outbound: Bool?
    var connectedSince: Date?
    var roundTripLast: TimeInterval?
    var roundTripMedian: TimeInterval?
    var lastDropReason: String?
    var lastDropAt: Date?
    var reconnectsToday = 0
    /// Bonjour sees the phone right now.
    var discoveryVisible = false
    var discovery: DiscoveryHealth = .browsing

    var id: String { deviceID }

    init(deviceID: String, record: DeviceHealthRecord?, connected: Bool, discoveryVisible: Bool, discovery: DiscoveryHealth, now: Date) {
        self.deviceID = deviceID
        self.connected = connected
        self.discoveryVisible = discoveryVisible
        self.discovery = discovery
        guard let record else { return }
        if connected {
            route = record.route
            tunnelRoute = record.tunnelRoute
            tunnelRelay = record.tunnelRelay
            outbound = record.outbound
            connectedSince = record.connectedSince
            roundTripLast = record.roundTrips.last
            roundTripMedian = record.roundTrips.median
        }
        lastDropReason = record.lastDropReason
        lastDropAt = record.lastDropAt
        reconnectsToday = record.reconnects.value(now: now)
    }

    /// For the diagnostics report: the eight-character device prefix, tokens, numbers and times.
    func diagnostics() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var value: [String: Any] = [
            "connected": connected,
            "route": route.rawValue,
            "reconnectsToday": reconnectsToday,
            "discoveryVisible": discoveryVisible,
            "discovery": discovery.rawValue,
        ]
        if let tunnelRoute { value["tunnel"] = tunnelRoute }
        if let tunnelRelay { value["relay"] = tunnelRelay }
        if let outbound { value["dialledBy"] = outbound ? "this_device" : "other_device" }
        if let connectedSince { value["connectedSince"] = formatter.string(from: connectedSince) }
        if let roundTripLast { value["roundTripMs"] = Int((roundTripLast * 1000).rounded()) }
        if let roundTripMedian { value["roundTripMedianMs"] = Int((roundTripMedian * 1000).rounded()) }
        if let lastDropReason { value["lastDisconnectReason"] = healthToken(lastDropReason) }
        if let lastDropAt { value["lastDisconnectAt"] = formatter.string(from: lastDropAt) }
        return value
    }
}

/// A reason as a short token: lowercase letters, digits and underscores, at most 40.
func healthToken(_ value: String) -> String {
    String(value.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" }.prefix(40))
}

/// A disconnect reason in plain words.
func dropReasonText(_ reason: String) -> String {
    switch reason {
    case "heartbeat_timeout": L10n.text("health.drop.heartbeat", fallback: "Stopped answering")
    case "reset_by_peer", "closed_by_peer", "broken_pipe", "aborted": L10n.text("health.drop.peer", fallback: "Closed by the phone")
    case "network_unreachable", "host_unreachable", "timed_out", "not_connected": L10n.text("health.drop.network", fallback: "Network changed or unreachable")
    case "local_network_denied": L10n.text("health.drop.localNetwork", fallback: "Local Network access is off")
    case "replaced", "duplicate": L10n.text("health.drop.replaced", fallback: "Replaced by a newer connection")
    case "user", "closed", "cancelled": L10n.text("health.drop.user", fallback: "Disconnected here")
    case "protocol_error", "frame_too_large", "wrong_device", "not_for_this_device": L10n.text("health.drop.protocol", fallback: "Unexpected message")
    default: L10n.text("health.drop.other", fallback: "Connection ended")
    }
}

/// The chip for a connected phone: "Same Wi-Fi", "Private network", "Direct" or "Relay (Mumbai)".
func routeChipText(_ health: ConnectionHealthSnapshot?) -> String? {
    guard let health, health.connected else { return nil }
    return connectRouteChipText(tunnelRoute: health.tunnelRoute, relay: health.tunnelRelay, legacy: health.route)
}

func routeText(_ route: ConnectionRoute) -> String {
    switch route {
    case .sameNetwork: L10n.text("health.route.same", fallback: "Same network")
    case .privateNetwork: L10n.text("health.route.private", fallback: "Private network")
    case .otherNetwork: L10n.text("health.route.other", fallback: "Another network")
    case .unknown: L10n.text("health.route.unknown", fallback: "Unknown route")
    }
}

/// "12 ms" or "1.2 s".
func roundTripText(_ seconds: TimeInterval) -> String {
    seconds < 1 ? String(format: L10n.text("health.ms", fallback: "%d ms"), Int((seconds * 1000).rounded()))
        : String(format: L10n.text("health.seconds", fallback: "%.1f s"), seconds)
}
