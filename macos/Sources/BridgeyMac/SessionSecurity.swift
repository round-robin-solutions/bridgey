import CryptoKit
import Foundation

/// Protocol 2 session security (v0.10 security review, docs/security-review-0.10.md):
///
/// - A first pairing commits to the initiator's ephemeral key before the responder answers, and the six-digit
///   code comes from its own HKDF label over both keys. The party that answers can no longer pick its key to
///   make two codes match (the man-in-the-middle grind on the old code).
/// - When both ends speak protocol 2, every frame after pairing carries `tag`: an HMAC over the sender's device
///   ID and every envelope field, under a key derived from the session key. Replaying a ciphertext under a new
///   messageId, relabelling its kind or reflecting it back to its sender fails the tag.
/// - A device that once connected with protocol 2 is pinned to it, so a stripped `protocolVersion` cannot
///   downgrade a later session.
///
/// Android has the same code in SessionSecurity.kt; protocol/test-vectors/crypto-v1.properties pins both.
enum SessionSecurity {
    static let protocolVersion: Int64 = 2
    private static let commitLabel = "bridgey-commit-v2"
    private static let sasLabel = "bridgey-sas-v2"
    private static let envelopeLabel = "bridgey-envelope-v2"

    /// Base64 SHA-256 over the label, the session ID and the initiator's ephemeral public key (base64 text).
    static func commitment(sessionID: String, publicKey: String) -> String {
        Data(SHA256.hash(data: lengthPrefixed([commitLabel, sessionID, publicKey]))).base64EncodedString()
    }

    static func commitmentMatches(_ commitment: String, sessionID: String, publicKey: String) -> Bool {
        guard let received = Data(base64Encoded: commitment) else { return false }
        let expected = Data(SHA256.hash(data: lengthPrefixed([commitLabel, sessionID, publicKey])))
        return constantTimeEqual(received, expected)
    }

    /// The protocol 2 code: HKDF-Expand(prk, label + both ephemeral keys), never bytes of the session key.
    static func sasCode(prk: Data, initiatorKey: String, responderKey: String) -> String {
        var info = lengthPrefixed([sasLabel, initiatorKey, responderKey])
        info.append(1)
        let output = Array(HMAC<SHA256>.authenticationCode(for: info, using: SymmetricKey(data: prk)))
        let value = (UInt32(output[0]) << 24) | (UInt32(output[1]) << 16) | (UInt32(output[2]) << 8) | UInt32(output[3])
        return String(format: "%06d", value % 1_000_000)
    }

    static func envelopeKey(sessionKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(envelopeLabel.utf8), using: SymmetricKey(data: sessionKey)))
    }

    /// Base64 HMAC-SHA-256 over the sender's device ID and every envelope field of `message` except `tag`.
    static func tag(envelopeKey: Data, senderDeviceID: String, message: PairingMessage) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: tagInput(senderDeviceID, message), using: SymmetricKey(data: envelopeKey)))
            .base64EncodedString()
    }

    static func tagMatches(envelopeKey: Data, senderDeviceID: String, message: PairingMessage) -> Bool {
        guard let received = message.tag.flatMap({ Data(base64Encoded: $0) }) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            received,
            authenticating: tagInput(senderDeviceID, message),
            using: SymmetricKey(data: envelopeKey)
        )
    }

    /// Pairing frames run before there is a session key; everything else needs an authenticated session.
    static func allowedBeforeAuthentication(_ kind: String) -> Bool { kind.hasPrefix("pairing.") }

    private static func tagInput(_ senderDeviceID: String, _ message: PairingMessage) -> Data {
        lengthPrefixed([
            envelopeLabel, senderDeviceID, message.kind, message.sessionId, message.deviceId, message.deviceName,
            message.publicKey, message.identityKey, message.proof, message.signature, message.messageId,
            message.nonce, message.ciphertext, message.transferId, message.sequence.map { String($0) },
            message.targetDeviceId, message.commitment, message.protocolVersion.map { String($0) },
        ])
    }

    /// Each field as a 4-byte big-endian length and its UTF-8 bytes; an absent field is length 0xFFFFFFFF.
    static func lengthPrefixed(_ fields: [String?]) -> Data {
        var out = Data()
        for field in fields {
            let bytes = field.map { Data($0.utf8) }
            let length = bytes.map { UInt32($0.count) } ?? UInt32.max
            out.append(contentsOf: [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
            if let bytes { out.append(bytes) }
        }
        return out
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The protocol version each trusted phone last authenticated with; later sessions may not go below it.
/// Kept apart from the trust file so the trust format does not change; Forget removes the entry.
struct ProtocolPins {
    var defaults: UserDefaults = .standard

    private func key(_ deviceID: String) -> String { "protocolPin.\(deviceID.lowercased())" }

    func pinned(_ deviceID: String) -> Int64 {
        let value = defaults.integer(forKey: key(deviceID))
        return value > 0 ? Int64(value) : 1
    }

    func pin(_ deviceID: String, version: Int64) {
        if version > pinned(deviceID) { defaults.set(Int(version), forKey: key(deviceID)) }
    }

    func remove(_ deviceID: String) { defaults.removeObject(forKey: key(deviceID)) }
}

/// A peer-supplied device name made safe to show: no control or bidi characters, at most 64 characters.
func sanitizedPeerName(_ name: String?, fallback: String) -> String {
    let bidi: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", "\u{061C}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]
    var scalars = String.UnicodeScalarView()
    for scalar in (name ?? "").unicodeScalars where !(scalar.properties.generalCategory == .control || bidi.contains(scalar)) {
        scalars.append(scalar)
    }
    var cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count > maximumPeerNameCharacters {
        cleaned = String(cleaned.prefix(maximumPeerNameCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return cleaned.isEmpty ? fallback : cleaned
}

let maximumPeerNameCharacters = 64

/// Connections that have not authenticated yet: at most `maxTotal` in all and `maxPerHost` from one address, so a
/// host on the network cannot hold every connection slot open.
func admitsPendingConnection(pendingHosts: [String?], host: String?, maxTotal: Int = 8, maxPerHost: Int = 3) -> Bool {
    pendingHosts.count < maxTotal && (host == nil || pendingHosts.filter { $0 == host }.count < maxPerHost)
}

/// Pairing prompts started by another device: at most `limit` per `window`. Each prompt is a fresh random
/// code, so this keeps a device on the network from cycling through codes until one matches.
struct InboundPairingLimiter {
    let limit: Int
    let window: TimeInterval
    private var starts: [Date] = []

    init(limit: Int = 3, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    mutating func tryAcquire(now: Date = Date()) -> Bool {
        starts.removeAll { now.timeIntervalSince($0) >= window }
        guard starts.count < limit else { return false }
        starts.append(now)
        return true
    }
}
