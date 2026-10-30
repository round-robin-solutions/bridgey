import CryptoKit
import Darwin
import Foundation

/*
 * Connect anywhere (draft connect_draft1, docs/protocol.md "Draft: Connect anywhere"): the payloads
 * of connect.setup and connect.addresses, the pair secret, the pair check and the tunnel transcript.
 * Pure functions, so protocol/test-vectors/connect-v1.json and protocol-v1.json pin them. Android has
 * the same rules (android/.../connect/ConnectProtocol.kt).
 */

let connectFeatureKey = "connect_draft1"

/// connect.setup: one side's 32-byte contribution to the pair secret.
struct ConnectSetup: Equatable {
    let contribution: Data
    let rotate: Bool

    static let maximumBytes = 256

    static func decode(_ data: Data) -> ConnectSetup? {
        guard data.count <= maximumBytes, isStrictJSONObject(data),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              jsonInteger(object["version"]) == 1,
              let text = object["contribution"] as? String,
              let contribution = Data(base64Encoded: text), contribution.count == 32 else { return nil }
        var rotate = false
        if let value = object["rotate"] {
            guard let flag = jsonBool(value) else { return nil }
            rotate = flag
        }
        return ConnectSetup(contribution: contribution, rotate: rotate)
    }

    var payload: [String: Any] { ["version": 1, "contribution": contribution.base64EncodedString(), "rotate": rotate] }
}

/// One address in connect.addresses.
struct ConnectAddress: Equatable, Codable {
    let a: String
    let kind: String
    var vpn: String?

    static let kinds: Set<String> = ["lan", "vpn", "public6"]
    static let vpns: Set<String> = ["tailscale", "other"]
}

/// connect.addresses: where the sender can be dialled, and its pair check.
struct ConnectAddresses: Equatable {
    let port: Int
    let addrs: [ConnectAddress]
    let pairCheck: String?

    static let maximumBytes = 2_048
    static let maximumEntries = 16

    static func decode(_ data: Data) -> ConnectAddresses? {
        guard data.count <= maximumBytes, isStrictJSONObject(data),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              jsonInteger(object["version"]) == 1,
              let port = jsonInteger(object["port"]), (1...65_535).contains(port),
              let list = object["addrs"] as? [Any], list.count <= maximumEntries else { return nil }
        var check: String?
        if let value = object["pairCheck"] {
            guard let text = value as? String, isPairCheck(text) else { return nil }
            check = text
        }
        // Entries with an unknown kind or an address that is not a usable IP literal are skipped.
        let addrs: [ConnectAddress] = list.compactMap { entry in
            guard let entry = entry as? [String: Any], let a = entry["a"] as? String, let kind = entry["kind"] as? String,
                  ConnectAddress.kinds.contains(kind), isUsableIPLiteral(a) else { return nil }
            let vpn = (entry["vpn"] as? String).flatMap { ConnectAddress.vpns.contains($0) ? $0 : nil }
            return ConnectAddress(a: a, kind: kind, vpn: vpn)
        }
        return ConnectAddresses(port: port, addrs: addrs, pairCheck: check)
    }

    var payload: [String: Any] {
        var value: [String: Any] = [
            "version": 1, "port": port,
            "addrs": addrs.map { address -> [String: Any] in
                var entry: [String: Any] = ["a": address.a, "kind": address.kind]
                if let vpn = address.vpn { entry["vpn"] = vpn }
                return entry
            },
        ]
        if let pairCheck { value["pairCheck"] = pairCheck }
        return value
    }

    /// 11 base64url characters (8 bytes, no padding).
    static func isPairCheck(_ text: String) -> Bool {
        text.utf8.count == 11 && text.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
        }
    }
}

/// An IPv4 or IPv6 literal (never a name, never resolved) that is not loopback, unspecified or multicast.
func isUsableIPLiteral(_ text: String) -> Bool {
    guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%") else { return false }
    var v4 = in_addr()
    if inet_pton(AF_INET, text, &v4) == 1 {
        let first = UInt32(bigEndian: v4.s_addr) >> 24
        return first != 127 && !(224...239).contains(first) && v4.s_addr != 0
    }
    var v6 = in6_addr()
    guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
    let bytes = withUnsafeBytes(of: &v6) { Array($0) }
    if bytes.allSatisfy({ $0 == 0 }) { return false }
    if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }
    if bytes[0] == 0xFF { return false }
    return true
}

/// Pair secret, pair check and the tunnel transcript (docs/protocol.md).
enum ConnectCrypto {
    /// 0 when `local` is the lower device ID (plain string order, as the dialler rule).
    static func side(local: String, remote: String) -> Int { local < remote ? 0 : 1 }

    /// HKDF-SHA256(cLow || cHigh, salt "bridgey-pair-secret-v1", info idLow 0x00 idHigh, 32).
    static func pairSecret(local: Data, remote: Data, localID: String, remoteID: String) -> Data {
        let lowFirst = localID < remoteID
        let ikm = lowFirst ? local + remote : remote + local
        let info = Data((lowFirst ? localID : remoteID).utf8) + Data([0]) + Data((lowFirst ? remoteID : localID).utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data("bridgey-pair-secret-v1".utf8),
                                         info: info, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// base64url(HMAC-SHA256(pairSecret, "bridgey-pair-check-v1")[0..8]), no padding.
    static func pairCheck(_ secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("bridgey-pair-check-v1".utf8), using: SymmetricKey(data: secret))
        return base64URL(Data(mac).prefix(8))
    }

    /// "bridgey-auth-v2" \0 sessionId \0 initiator \0 responder \0 initiatorKey \0 responderKey \0 exporter.
    static func transcriptV2(sessionID: String, initiator: String, responder: String, initiatorKey: String, responderKey: String, exporter: String) -> Data {
        Data(["bridgey-auth-v2", sessionID, initiator, responder, initiatorKey, responderKey, exporter].joined(separator: "\0").utf8)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The route a tunnel takes, as the core reports it.
enum ConnectRouteKind: String {
    case lan, vpn, direct, relay
}

/// Where each relay is, for "Relay (Mumbai)".
func relayPlaceName(_ relay: String?) -> String? {
    switch relay {
    case "bom": L10n.text("connect.relay.bom", fallback: "Mumbai")
    case "sin": L10n.text("connect.relay.sin", fallback: "Singapore")
    case "sxb": L10n.text("connect.relay.sxb", fallback: "France")
    case "cf": L10n.text("connect.relay.cf", fallback: "Cloudflare")
    default: nil
    }
}

/// The route chip: "Same Wi-Fi", "Private network", "Direct" or "Relay (Mumbai)". A session without a
/// tunnel (today's LAN TCP) reads from its address class. Nil when there is nothing to say.
func connectRouteChipText(tunnelRoute: String?, relay: String?, legacy: ConnectionRoute) -> String? {
    switch tunnelRoute.flatMap(ConnectRouteKind.init(rawValue:)) {
    case .lan: return L10n.text("connect.route.lan", fallback: "Same Wi-Fi")
    case .vpn:
        // The relay slot carries the private network's name for VPN routes (`tailscale`).
        if relay == "tailscale" { return L10n.text("connect.route.tailscale", fallback: "Tailscale") }
        return L10n.text("connect.route.vpn", fallback: "Private network")
    case .direct: return L10n.text("connect.route.direct", fallback: "Direct")
    case .relay:
        guard let place = relayPlaceName(relay) else { return L10n.text("connect.route.relay", fallback: "Relay") }
        return String(format: L10n.text("connect.route.relayAt", fallback: "Relay (%@)"), place)
    case nil:
        switch legacy {
        case .sameNetwork: return L10n.text("connect.route.lan", fallback: "Same Wi-Fi")
        case .privateNetwork: return L10n.text("connect.route.vpn", fallback: "Private network")
        case .otherNetwork: return L10n.text("connect.route.direct", fallback: "Direct")
        case .unknown: return nil
        }
    }
}

/// Settings > Devices > Connect away from home.
struct ConnectDisplay: Equatable {
    /// This build has the core.
    var available = false
    /// The build (or the debug override) names a control service.
    var controlConfigured = false
    var running = false
    /// off, disabled (no control service), connecting or online.
    var presence = "off"
    var relayOnly = false
    var debug = false
    var controlURL = ""
}

/// What a Connect anywhere tunnel may carry (protocol 2 era), the same rules as Android's TunnelRules. A tunnel is
/// never a way to pair: pairing stays on the local network, where the code is compared. Over a tunnel only a plain
/// reconnect of an already paired phone runs, with protocol 2 envelope tags on every frame.
enum TunnelRules {
    static let minProtocol: Int64 = 2

    /// The dialled end's check of pairing.offer: trusted sender, no commitment (no new pairing), protocol 2.
    static func offerAllowed(trusted: Bool, committed: Bool, protocolVersion: Int64) -> Bool {
        trusted && !committed && protocolVersion >= minProtocol
    }

    /// Both ends, before confirming: a trusted phone, confirmed without a prompt, with envelope tags.
    static func sessionAllowed(trusted: Bool, autoConfirms: Bool, tagged: Bool) -> Bool { trusted && autoConfirms && tagged }
}
