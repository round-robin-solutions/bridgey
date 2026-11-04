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

struct TailnetPeerInfo: Equatable {
    let name: String
    let dns: String
    let ips: [String]
    let os: String
    let online: Bool

    /// The address to dial: IPv4 first.
    var address: String? { ips.first { !$0.contains(":") } ?? ips.first }
}

enum TailnetStatus {
    /// Tailscale's ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func isTailnet(_ address: String) -> Bool {
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
    static func find(_ peers: [TailnetPeerInfo], name: String) -> TailnetPeerInfo? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return peers.first { peer in
            peer.name.lowercased() == wanted || peer.dns.lowercased() == wanted || peer.dns.split(separator: ".").first.map { $0.lowercased() == wanted } == true
        }
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
    private static let binaries = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]

    static func status() -> [TailnetPeerInfo] {
        guard let binary = binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = DispatchTime.now() + 5
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if DispatchTime.now() > deadline { process.terminate() }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? TailnetStatus.parse(data) : []
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
