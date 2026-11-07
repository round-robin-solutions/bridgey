import Foundation
import Network

/*
 * Pairing over the tailnet (docs/mesh-and-codes.md, phase 2): Bridgey devices on Rahul's Tailscale tailnet find and
 * pair with each other directly, without being on the same local network. This Mac reads its tailnet peers from the
 * Tailscale app (`tailscale status --json`), knocks on Bridgey's port at each online peer, and lists the ones that
 * answer under "Pair a new device", labelled "On your tailnet". Tapping Pair dials that address and makes the normal
 * protocol 2 first pairing (Allow pairing on the other side, the code compared on both). Nothing listed here is
 * trusted, and a server paired this way gets nothing on this Mac (BridgeySettings.agentDevices).
 */

struct TailnetPeerInfo: Equatable, Sendable {
    let name: String
    let dns: String
    let ips: [String]
    let os: String
    let online: Bool

    /// The address to dial: IPv4 first.
    var address: String? { ips.first { !$0.contains(":") } ?? ips.first }
}

struct TailnetPairTarget: Equatable, Sendable {
    let host: String
    let port: Int
    let name: String
}

enum TailnetPairing {
    /// A chosen address never waits for discovery of unrelated devices. Names need only status,
    /// not a TCP scan of the entire tailnet. Literal addresses outside the tailnet remain refused.
    static func resolve(_ text: String, peers: @Sendable () async -> [TailnetPeerInfo]) async -> TailnetPairTarget? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        var host = typed
        var port = Int(BonjourDiscovery.defaultPort)
        if typed.hasPrefix("["), let close = typed.firstIndex(of: "]") {
            host = String(typed[typed.index(after: typed.startIndex)..<close])
            let suffix = typed[typed.index(after: close)...]
            if !suffix.isEmpty {
                guard suffix.first == ":", let value = Int(suffix.dropFirst()) else { return nil }
                port = value
            }
        } else if IPv6Address(typed) == nil, let colon = typed.lastIndex(of: ":") {
            guard let value = Int(typed[typed.index(after: colon)...]) else { return nil }
            host = String(typed[..<colon])
            port = value
        }
        guard (1...65_535).contains(port), !host.isEmpty else { return nil }
        if TailnetStatus.isTailnet(host) { return TailnetPairTarget(host: host, port: port, name: typed) }
        guard IPv4Address(host) == nil, IPv6Address(host) == nil,
              let peer = TailnetStatus.find(await peers(), name: host), let address = peer.address else { return nil }
        return TailnetPairTarget(host: address, port: port, name: peer.name)
    }
}

enum TailnetStatus {
    /// Tailscale's ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func isTailnet(_ address: String) -> Bool {
        if address.lowercased().hasPrefix("::ffff:") { return isTailnet(String(address.dropFirst(7))) }
        if let v4 = IPv4Address(address) {
            let bytes = [UInt8](v4.rawValue)
            return bytes[0] == 100 && (bytes[1] & 0xc0) == 64
        }
        if let v6 = IPv6Address(address) {
            let bytes = [UInt8](v6.rawValue)
            return bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0
        }
        return false
    }

    /// The peers in `tailscale status --json` (never this Mac), online first, tailnet addresses only.
    static func parse(_ data: Data) -> [TailnetPeerInfo] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["BackendState"] as? String).map({ $0 == "Running" }) ?? true,
              let peers = object["Peer"] as? [String: Any] else { return [] }
        let list: [TailnetPeerInfo] = peers.values.compactMap { value in
            guard let peer = value as? [String: Any], let host = peer["HostName"] as? String else { return nil }
            let ips = (peer["TailscaleIPs"] as? [String] ?? []).filter(isTailnet)
            guard !ips.isEmpty else { return nil }
            let name = String(host.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init)).prefix(64)
            let dns = (peer["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return TailnetPeerInfo(name: String(name), dns: dns, ips: ips, os: peer["OS"] as? String ?? "", online: peer["Online"] as? Bool ?? false)
        }
        return list.sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
    }

    /// The peer a typed name means: its host name, MagicDNS name, or that name's first label.
    /// A name more than one peer answers to means none, so a node that took another's name is not dialled by mistake.
    static func find(_ peers: [TailnetPeerInfo], name: String) -> TailnetPeerInfo? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let matches = peers.filter { peer in
            peer.name.lowercased() == wanted || peer.dns.lowercased() == wanted || peer.dns.split(separator: ".").first.map { $0.lowercased() == wanted } == true
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Tailnet peers that answered on Bridgey's port, as entries for the nearby list. Addresses already known for a
    /// trusted device are left out, so a paired device is not offered twice.
    static func discovered(_ peers: [TailnetPeerInfo], answering: Set<String>, known: Set<String>, port: Int) -> [DiscoveredPeer] {
        peers.compactMap { peer in
            guard peer.online, let address = peer.address, answering.contains(address), peer.ips.allSatisfy({ !known.contains($0) }) else { return nil }
            var entry = DiscoveredPeer(serviceName: "tailnet:\(address)", deviceIDHint: nil, deviceNameHint: peer.name, platformHint: nil,
                                       protocolVersionHint: nil, host: address, port: port, addresses: peer.ips)
            entry.tailnet = true
            return entry
        }
    }
}

/// Runs the Tailscale app's command line and knocks on Bridgey's port at each online peer. Off the main thread.
enum TailnetProbe {
    static func snapshot(installation: TailscaleInstallation) -> TailscaleSnapshot {
        guard let executable = installation.executable else {
            return TailscaleSnapshot(state: installation.application == nil ? .notInstalled : .unavailable)
        }
        switch TailscaleStatusCommand.run(executable: executable) {
        case .output(let data): return TailscaleSnapshot.decode(data)
        case .unavailable, .timedOut, .outputTooLarge: return TailscaleSnapshot(state: .unavailable)
        }
    }

    /// All peers are considered, but only eight probes may be in flight at once.
    static func scan(installation: TailscaleInstallation) async -> TailscaleSnapshot {
        var result = await Task.detached(priority: .utility) { snapshot(installation: installation) }.value
        guard result.state == .running else { return result }
        let addresses = result.peers.filter(\.online).compactMap(\.address)
        let port = Int(BonjourDiscovery.defaultPort)
        result.answering = await answering(addresses: addresses) { await answers($0, port: port) }
        return result
    }

    static func answering(addresses: [String], limit: Int = 8,
                          probe: @escaping @Sendable (String) async -> Bool) async -> Set<String> {
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = addresses.makeIterator()
            for _ in 0..<max(1, limit) {
                if let address = iterator.next() { group.addTask { (address, await probe(address)) } }
            }
            var found = Set<String>()
            while let (address, ok) = await group.next() {
                if ok { found.insert(address) }
                if let next = iterator.next() { group.addTask { (next, await probe(next)) } }
            }
            return found
        }
    }

    /// Whether something accepts a TCP connection there within `timeout` seconds (nothing is sent).
    static func answers(_ address: String, port: Int, timeout: TimeInterval = 0.8) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = TailnetOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true); connection.cancel()
                case .failed, .cancelled: once.finish(false)
                case .waiting: once.finish(false); connection.cancel()
                default: break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(false); connection.cancel() }
        }
    }
}

private final class TailnetOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func finish(_ value: Bool) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
