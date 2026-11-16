import Foundation

/// A paired device and what works with it right now.
struct DeviceItem: Identifiable, Equatable {
    let id: String
    var name: String
    var platform: String?
    var connected = false
    /// This device's switches for it, and its own (nil until it has sent them).
    var local: [String: Bool] = [:]
    var remote: [String: Bool]?

    private func both(_ key: String) -> Bool { connected && local[key] == true && remote?[key] == true }

    var clipboardReady: Bool { both("clipboard") }
    var filesReady: Bool { both("files") }
    var linksReady: Bool { both("links") }
    var pingReady: Bool { both("ping") }

    var ring: RingState { connected ? .connected : .offline }
}

/// A device on this network that is not paired.
struct NearbyItem: Identifiable, Equatable {
    var deviceID: String?
    var name: String
    var platform: String?
    var host: String
    var port: UInt16

    var id: String { deviceID ?? "\(host):\(port)" }
}

/// Where a pairing is. The code is compared by the person on both devices.
enum PairingState: Equatable {
    case idle
    /// Dialling the other device.
    case dialling(pairing: UInt64, name: String)
    /// The other device hasn't allowed pairing yet; Bridgey keeps trying for two minutes.
    case waiting(pairing: UInt64, name: String)
    case code(pairing: UInt64, name: String, code: String)
    /// This person said the codes match; waiting for the other.
    case confirming(pairing: UInt64, name: String, code: String)
    case paired(name: String)
    case failed(name: String, reason: String)

    var pairing: UInt64? {
        switch self {
        case let .dialling(p, _), let .waiting(p, _), let .code(p, _, _), let .confirming(p, _, _): p
        default: nil
        }
    }

    var isActive: Bool { pairing != nil }

    /// What failed pairings say, from the library's reasons.
    static func failureText(_ reason: String, name: String) -> String {
        switch reason {
        case "not_allowed": String(localized: "\(name) didn’t allow pairing in time.")
        case "unreachable": String(localized: "Bridgey couldn’t reach \(name). Check you’re on the same Wi-Fi.")
        case "cancelled": String(localized: "Pairing cancelled.")
        case let r where r.contains("mismatch") || r == "code_rejected": String(localized: "The codes didn’t match, so nothing was paired.")
        case let r where r.contains("timeout"): String(localized: "Pairing timed out.")
        case let r where r.contains("needs_protocol_2"): String(localized: "Update Bridgey on \(name) to pair.")
        default: String(localized: "Pairing with \(name) didn’t finish.")
        }
    }
}

struct PairingRequest: Equatable {
    var deviceID: String
    var name: String
}

/// A link waiting for the person to open it.
struct LinkCard: Identifiable, Equatable {
    let id = UUID()
    var deviceName: String
    var url: URL
}

/// A file on its way in or out.
struct TransferItem: Identifiable, Equatable {
    var id: UInt64
    var deviceID: String
    var deviceName: String
    var name: String
    var incoming: Bool
    var bytes: UInt64 = 0
    var total: UInt64 = 0

    var fraction: Double { total == 0 ? 0 : min(1, Double(bytes) / Double(total)) }
}

/// One row of the activity stream, newest first.
struct ActivityItem: Identifiable, Equatable, Codable {
    enum Direction: String, Codable { case received, sent }
    enum Kind: String, Codable { case text, link, file }
    enum Outcome: String, Codable { case sending, delivered, failed }

    var id = UUID()
    var date = Date()
    var direction: Direction
    var kind: Kind
    var deviceName: String
    /// The text, the link, or the file's name.
    var value: String
    /// A received file's name in the Files folder.
    var savedName: String?
    var outcome: Outcome = .delivered
    /// Why it failed, shown under the row.
    var detail: String?
    /// The library's request or transfer ID while it is under way.
    var request: UInt64?

    enum CodingKeys: String, CodingKey { case id, date, direction, kind, deviceName, value, savedName, outcome, detail }
}

extension ByteCountFormatter {
    static func file(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
