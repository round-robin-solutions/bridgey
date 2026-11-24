import Darwin
import Foundation
import Network

/*
 * LAN first (draft lan_first_draft1, docs/protocol.md "Draft: LAN first"). On the same network a device should talk
 * over a direct LAN socket, never the Connect anywhere tunnel (100+ MB/s against 3 to 8 MB/s). Pure parts, unit tested:
 * the session tier both ends compute alike, the upgrade schedule, and which addresses connect.addresses may offer.
 * Android has the same rules (LanFirst.kt); both ends run the duplicate rule on their own, so they must agree.
 */

/// The `features.update` key of builds with this change. A capability: always advertised. Read outside
/// knownDraftFeatureKeys (decodeFeatureFlag), so the golden vectors stay as they are.
let lanFirstFeatureKey = "lan_first_draft1"

/// What a session runs on, best last. Both ends see the same tier for one session.
enum SessionTier: Int, Comparable {
    /// A Connect anywhere tunnel, whatever its route: the two ends can label one tunnel differently.
    case tunnel = 0
    /// A socket to a VPN (Tailscale), public or unknown address.
    case socket = 1
    /// A socket to a private address on the local network, or loopback.
    case lan = 2

    static func < (lhs: SessionTier, rhs: SessionTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var token: String {
        switch self {
        case .tunnel: "tunnel"
        case .socket: "socket"
        case .lan: "lan"
        }
    }
}

/// The tier of a session: a tunnel is `.tunnel`; a socket is `.lan` when its remote address is private, else `.socket`.
func sessionTier(tunnel: Bool, remoteHost: String?) -> SessionTier {
    if tunnel { return .tunnel }
    guard let remoteHost, isLanAddress(remoteHost) else { return .socket }
    return .lan
}

/// Private addresses: IPv4 10/8, 172.16/12, 192.168/16, 169.254/16 and loopback; IPv6 fe80::/10, fc00::/7 except
/// Tailscale's fd7a:115c:a1e0::/48, and loopback. IPv4-mapped IPv6 counts as its IPv4. Host names are not private.
func isLanAddress(_ raw: String) -> Bool {
    var host = raw.trimmingCharacters(in: .whitespaces)
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
    if let value = parseIPv4(host) { return isLanIPv4(value) }
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
    let bytes = withUnsafeBytes(of: address) { Array($0) }
    if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
        return isLanIPv4(UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]))
    }
    if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
    if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
    if bytes[0] & 0xFE == 0xFC {
        return !(bytes[0] == 0xFD && bytes[1] == 0x7A && bytes[2] == 0x11 && bytes[3] == 0x5C && bytes[4] == 0xA1 && bytes[5] == 0xE0)
    }
    return false
}

private func isLanIPv4(_ value: UInt32) -> Bool {
    value >> 24 == 10 || value >> 20 == 0xAC1 || value >> 16 == 0xC0A8 || value >> 16 == 0xA9FE || value >> 24 == 127
}

/// The remote address of a connection as it is on the wire (a link-local IPv6 keeps its zone), for the tier. Outbound
/// connections report the address the name resolved to once they are up.
func tierHost(_ connection: NWConnection) -> String? {
    func host(_ endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address): return "\(address)"
        case let .name(name, _): return name
        @unknown default: return nil
        }
    }
    return host(connection.currentPath?.remoteEndpoint) ?? host(connection.endpoint)
}

// MARK: - Upgrade dial

enum LanUpgradePolicy {
    /// After a failed upgrade dial, the next one waits this long...
    static let retryInterval: TimeInterval = 30
    /// ...and after this many failures on the same network, this long, until the network changes.
    static let failuresBeforeSlow = 3
    static let slowInterval: TimeInterval = 300
    /// While only a transfer holds an upgrade back, how often to look again, so the dial follows the transfer's end.
    static let transferRecheck: TimeInterval = 2
    /// An upgrade dial that has not ended by then counts as failed (connect and pairing timeouts end it well before).
    static let dialGiveUp: TimeInterval = 60
}

/// A LAN address to dial for an upgrade: seen by Bonjour now, or learned from connect.addresses.
struct LanUpgradeAddress: Equatable {
    let host: String
    let port: Int
    /// "bonjour" or "learned", for diagnostics.
    let origin: String
}

/// One connected device as the upgrade loop sees it.
struct LanUpgradeCandidate: Equatable {
    let deviceID: String
    let tier: SessionTier
    let peerSupports: Bool
    let activeTransfer: Bool
    let addresses: [LanUpgradeAddress]
}

enum LanUpgradeDecision: Equatable {
    case dial(deviceID: String, address: LanUpgradeAddress)
    case skippedTransfer(deviceID: String)
}

/// When to dial a connected device's LAN address so its session moves off the tunnel or VPN. At most one dial per
/// device; at once when it becomes possible, then every 30 s, then every 5 min after 3 failures on one network.
final class LanUpgradeScheduler {
    private struct State {
        var failures = 0
        var nextAt: Date?
        var dialStartedAt: Date?
        var eligible = false
        var skipReported = false
    }

    private var states: [String: State] = [:]
    private var network: String?

    /// The networks this device is on, as a key. A new network forgets the failures of the old one.
    func networkChanged(_ key: String) {
        guard key != network else { return }
        network = key
        for id in states.keys {
            states[id]?.failures = 0
            states[id]?.nextAt = nil
        }
    }

    func isDialing(_ id: String) -> Bool { states[id]?.dialStartedAt != nil }

    /// Which dials to start now (and transfers to report), and when to look again (nil: on the next event).
    func evaluate(_ candidates: [LanUpgradeCandidate], now: Date) -> (decisions: [LanUpgradeDecision], wakeAt: Date?) {
        var decisions: [LanUpgradeDecision] = []
        var wake: Date?
        func wakeAt(_ date: Date) { wake = min(wake ?? date, date) }
        let ids = Set(candidates.map(\.deviceID))
        states = states.filter { ids.contains($0.key) || $0.value.dialStartedAt != nil }
        for candidate in candidates {
            let id = candidate.deviceID
            var state = states[id] ?? State()
            if let started = state.dialStartedAt {
                if now.timeIntervalSince(started) < LanUpgradePolicy.dialGiveUp {
                    wakeAt(started.addingTimeInterval(LanUpgradePolicy.dialGiveUp))
                    continue
                }
                state.dialStartedAt = nil
                fail(&state, now: now)
            }
            guard candidate.tier < .lan, candidate.peerSupports else {
                states[id] = nil
                continue
            }
            let eligible = !candidate.activeTransfer && !candidate.addresses.isEmpty
            // It just became possible (a session came up, discovery saw the device, a transfer ended): try now,
            // unless this network already failed often enough for the slow interval.
            if eligible && !state.eligible && state.failures < LanUpgradePolicy.failuresBeforeSlow { state.nextAt = nil }
            state.eligible = eligible
            if candidate.activeTransfer && !candidate.addresses.isEmpty {
                // Reported once per transfer.
                if !state.skipReported { decisions.append(.skippedTransfer(deviceID: id)) }
                state.skipReported = true
                wakeAt(now.addingTimeInterval(LanUpgradePolicy.transferRecheck))
            } else {
                state.skipReported = false
            }
            guard eligible else {
                states[id] = state
                continue
            }
            if let next = state.nextAt, next > now {
                wakeAt(next)
                states[id] = state
                continue
            }
            state.dialStartedAt = now
            decisions.append(.dial(deviceID: id, address: candidate.addresses[state.failures % candidate.addresses.count]))
            wakeAt(now.addingTimeInterval(LanUpgradePolicy.dialGiveUp))
            states[id] = state
        }
        return (decisions, wake)
    }

    /// The upgrade dial ended: `won` when its session became the device's session.
    func dialEnded(_ id: String, won: Bool, now: Date) {
        guard var state = states[id], state.dialStartedAt != nil else { return }
        state.dialStartedAt = nil
        if won {
            states[id] = nil
            return
        }
        fail(&state, now: now)
        states[id] = state
    }

    private func fail(_ state: inout State, now: Date) {
        state.failures += 1
        state.nextAt = now.addingTimeInterval(state.failures >= LanUpgradePolicy.failuresBeforeSlow
            ? LanUpgradePolicy.slowInterval : LanUpgradePolicy.retryInterval)
    }
}

// MARK: - connect.addresses

/// A LAN address on a virtual interface of this device (a VM or container bridge, a VPN tunnel, OrbStack's ranges seen
/// live: 192.168.139.0/24 and 192.168.215.0/24): never offered in connect.addresses, where the other device would dial
/// it as this device's LAN. VPN and public addresses stay as the core reports them.
func isVirtualLanAddress(_ address: ConnectAddress, interface: String?) -> Bool {
    guard address.kind == "lan" else { return false }
    if let value = parseIPv4(address.a), value >> 8 == 0xC0A88B || value >> 8 == 0xC0A8D7 { return true }
    guard let name = interface else { return false }
    if name.hasPrefix("vmnet") || name.hasPrefix("utun") || name.hasPrefix("docker") || name.hasPrefix("vboxnet") { return true }
    // bridge0 is Thunderbolt Bridge, a real link; bridge100 and up are Internet Sharing and virtual machines.
    if name.hasPrefix("bridge"), let number = Int(name.dropFirst("bridge".count)), number >= 100 { return true }
    return false
}

/// This device's addresses and the interface each is on (getifaddrs).
func localInterfaceNames() -> [String: String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [:] }
    defer { freeifaddrs(list) }
    var names: [String: String] = [:]
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        defer { cursor = current.pointee.ifa_next }
        guard let address = current.pointee.ifa_addr else { continue }
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        var text = String(cString: buffer)
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        names[text.lowercased()] = String(cString: current.pointee.ifa_name)
    }
    return names
}

// MARK: - Active transfers

/// LAN first rule 2: a session with any of these running for its device is never replaced, so no switch cancels one.
struct DeviceTransferActivity: Equatable {
    var files = false
    var folders = false
    var phoneFiles = false
    var clipboard = false
    var speedTest = false

    var isActive: Bool { files || folders || phoneFiles || clipboard || speedTest }
}
