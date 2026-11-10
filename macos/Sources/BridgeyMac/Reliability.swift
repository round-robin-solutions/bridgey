import Foundation
import Network

let maximumTransferHistory = 20

func heartbeatExpired(
    supported: Bool,
    lastReceivedAt: Date,
    now: Date = Date(),
    timeout: TimeInterval = ReconnectPolicy.heartbeatTimeout
) -> Bool {
    supported && now.timeIntervalSince(lastReceivedAt) >= timeout
}

/// A live session that has heard nothing for longer than a healthy heartbeat allows. When the same device
/// authenticates a new session meanwhile, the new one wins the duplicate rule (the device has dropped the old one; a
/// Work Mac refused 20 redials in 56 s for a tunnel it had not yet noticed was dead).
func sessionLooksStale(
    supported: Bool,
    lastReceivedAt: Date,
    tunnel: Bool,
    now: Date = Date()
) -> Bool {
    heartbeatExpired(supported: supported, lastReceivedAt: lastReceivedAt, now: now,
                     timeout: tunnel ? ReconnectPolicy.staleTunnelSessionAfter : ReconnectPolicy.staleSessionAfter)
}

/// The `detail` of a `disconnected` diagnostics event: the route (tcp or tunnel), who dialled (out: this Mac, in: the
/// peer), how long the session lived and how long it had been silent, in whole seconds. "tcp_in_age94_silent31".
func disconnectDetail(tunnel: Bool, initiatedLocally: Bool, createdAt: Date, lastReceivedAt: Date, now: Date = Date()) -> String {
    let age = max(0, Int(now.timeIntervalSince(createdAt)))
    let silent = max(0, Int(now.timeIntervalSince(lastReceivedAt)))
    return "\(tunnel ? "tunnel" : "tcp")_\(initiatedLocally ? "out" : "in")_age\(age)_silent\(silent)"
}

func localNetworkPermissionDenied(_ error: NWError) -> Bool {
    switch error {
    case .posix(.EACCES), .dns(-65570): true
    default: false
    }
}

/// An accepted transfer always ends: received, failed, cancelled, or (here) timed out. One with no progress for
/// `timeout` is failed with `message`, and until then it stops counting as busy for an automatic update.
enum TransferStall {
    static let timeout: TimeInterval = 120
    static let sweepInterval: TimeInterval = 15
    static let message = "Transfer stalled: no data for 2 minutes. Try again."

    static func isStalled(lastProgressAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastProgressAt) >= timeout
    }

    /// The rows to fail now: active, not waiting in a queue, not preparing, not a folder (folders have their own
    /// session), and silent for the timeout.
    static func stalledIDs(_ rows: [FileTransferRow], excluding: Set<String> = [], now: Date) -> [String] {
        rows.filter { $0.active && !$0.queued && $0.folder == nil && !excluding.contains($0.id) && isStalled(lastProgressAt: $0.lastProgressAt, now: now) }
            .map(\.id)
            .sorted()
    }
}

func recoverInterruptedTransfers(_ transfers: [String: FileTransferRow]) -> [String: FileTransferRow] {
    Dictionary(uniqueKeysWithValues: transfers.values
        .map { transfer in
            guard transfer.active else { return transfer }
            return FileTransferRow(
                id: transfer.id,
                name: transfer.name,
                status: "Transfer interrupted; reconnect to retry",
                active: false,
                startedAt: transfer.startedAt,
                retryable: transfer.retryable,
                folder: transfer.folder
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
        .prefix(maximumTransferHistory)
        .map { ($0.id, $0) })
}

/// A short reason token for a socket error, for logs and diagnostics.
func connectionDropReason(_ error: NWError) -> String {
    switch error {
    case let .posix(code):
        switch code {
        case .ECONNRESET: return "reset_by_peer"
        case .ETIMEDOUT: return "timed_out"
        case .ECONNREFUSED: return "refused"
        case .EHOSTUNREACH, .EHOSTDOWN: return "host_unreachable"
        case .ENETUNREACH, .ENETDOWN: return "network_unreachable"
        case .ECONNABORTED: return "aborted"
        case .EPIPE: return "broken_pipe"
        case .ENOTCONN: return "not_connected"
        default: return "posix_\(code.rawValue)"
        }
    case let .dns(code): return "dns_\(code)"
    case let .tls(code): return "tls_\(code)"
    default: return "error"
    }
}

/// The IP (or host name) of an endpoint, without the port.
func endpointHost(_ endpoint: NWEndpoint) -> String? {
    guard case let .hostPort(host, _) = endpoint else { return nil }
    switch host {
    case let .ipv4(address): return normalizedHost("\(address)")
    case let .ipv6(address): return normalizedHost("\(address)")
    case let .name(name, _): return normalizedHost(name)
    @unknown default: return nil
    }
}
