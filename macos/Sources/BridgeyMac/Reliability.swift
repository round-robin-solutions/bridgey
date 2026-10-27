import Foundation
import Network

let maximumProtocolFrameBytes = 65_536
let maximumTransferHistory = 20

func heartbeatExpired(
    supported: Bool,
    lastReceivedAt: Date,
    now: Date = Date(),
    timeout: TimeInterval = ReconnectPolicy.heartbeatTimeout
) -> Bool {
    supported && now.timeIntervalSince(lastReceivedAt) >= timeout
}

func localNetworkPermissionDenied(_ error: NWError) -> Bool {
    switch error {
    case .posix(.EACCES), .dns(-65570): true
    default: false
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
