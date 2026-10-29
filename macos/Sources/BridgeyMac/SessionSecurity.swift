import CryptoKit
import Foundation
import Network

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

    /// Base64 HMAC-SHA-256 over the sender's device ID and every envelope field of `message` except `tag`. An empty
    /// field counts as absent, as the decoders read it.
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
            message.targetDeviceId, message.commitment, message.protocolVersion.map { String($0) }, message.reason,
        ].map { $0?.isEmpty == true ? nil : $0 })
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

/// Where one end of a pairing stands, for `PairingRules`: who dialled, whether this end committed to its key,
/// whether it holds the other end's commitment, and whether the session key exists yet.
struct PairingPosition: Equatable {
    var initiatedLocally: Bool
    var committed: Bool
    var holdsRemoteCommitment: Bool
    var hasSessionKey: Bool
}

/// Which pairing frames each end may act on. The order is what keeps the code honest: the end that answers fixes
/// its key before the dialler's key is revealed, and the dialler committed to its key before it saw the answer.
enum PairingRules {
    /// Only the end that was dialled takes an offer, once.
    static func acceptsOffer(_ p: PairingPosition) -> Bool { !p.initiatedLocally && !p.hasSessionKey && !p.holdsRemoteCommitment }

    /// Only the dialler takes an answer. An answer sent to the dialled end would replace the reveal.
    static func acceptsAnswer(_ p: PairingPosition) -> Bool { p.initiatedLocally && !p.holdsRemoteCommitment && !p.hasSessionKey }

    /// Only the dialled end takes a reveal, and only after a committed offer.
    static func acceptsReveal(_ p: PairingPosition) -> Bool { !p.initiatedLocally && p.holdsRemoteCommitment && !p.hasSessionKey }

    /// Whether an untrusted device may get the code prompt: only when the dialler committed to its key. A dialler that
    /// did not commit (a reconnect to what it thought was a trusted device) never prompts, and neither does the dialled
    /// end after a plain protocol 1 offer: a man in the middle could answer that offer's sender with a key ground to
    /// match the code it already saw from this end.
    static func mayPromptUntrusted(_ p: PairingPosition) -> Bool { p.initiatedLocally ? p.committed : p.holdsRemoteCommitment }

    /// Whether this end's dial commits to its key (a first pairing). Only a pairing the user started can: a background
    /// reconnect never commits, so it can never turn into a code prompt (for example after the phone was forgotten).
    static func diallerCommits(userStarted: Bool, targetTrusted: Bool) -> Bool { userStarted && !targetTrusted }

    /// A background reconnect goes out only to a phone that is still trusted; otherwise it closes before any offer.
    static func backgroundDialAllowed(targetTrusted: Bool) -> Bool { targetTrusted }

    /// An answered offer from a device that is not trusted costs one `InboundPairingLimiter` slot, whether or not it ever
    /// reaches the code, so an attacker cannot try codes faster by giving up before the reveal. A committed offer from a
    /// trusted ID (a one-sided Forget re-pair) shows a code too, so it costs a slot as well.
    static func chargesInboundAttempt(initiatedLocally: Bool, trusted: Bool, committedOffer: Bool) -> Bool {
        !initiatedLocally && (!trusted || committedOffer)
    }

    /// Only a plain reconnect confirms without a prompt: a trusted device and no commitment either way. A committed
    /// pairing from a trusted ID prompts on both ends; pairing.confirm still checks the pinned identity key.
    static func autoConfirms(trusted: Bool, _ p: PairingPosition) -> Bool { trusted && !p.committed && !p.holdsRemoteCommitment }

    /// What the dialled end does with an offer, before it answers. Refusals cost no limiter slot.
    /// - No commitment: a trusted device reconnects; an untrusted one is refused (an older Bridgey, or a device that
    ///   forgot this one), because a code from an uncommitted offer can be ground by a man in the middle.
    /// - A commitment: answered only while pairing is armed here.
    static func inboundOffer(trusted: Bool, committed: Bool, remoteProtocol: Int64, armed: Bool) -> InboundOfferDecision {
        if !committed {
            if trusted { return .answer(chargesLimiter: false) }
            return .refuse(remoteProtocol < SessionSecurity.protocolVersion ? .needsProtocol2 : .notTrusted)
        }
        guard armed else { return .refuse(.notArmed) }
        return .answer(chargesLimiter: chargesInboundAttempt(initiatedLocally: false, trusted: trusted, committedOffer: true))
    }

    /// Pairing frames on a session. After authentication only pairing.cancel is taken, and with an envelope key only
    /// with a valid tag. Before it, a tagged cancel must verify when this end has an envelope key; untagged ones are taken.
    static func admitsPairingFrame(kind: String, authenticated: Bool, hasEnvelopeKey: Bool, tagged: Bool, tagValid: Bool) -> Bool {
        let cancel = kind == "pairing.cancel"
        if authenticated { return cancel && (!hasEnvelopeKey || tagValid) }
        if cancel && tagged && hasEnvelopeKey { return tagValid }
        return true
    }

    /// The code prompt's buttons act only on the pairing whose prompt the user saw.
    static func promptMatches(sessionToken: String?, requested: String) -> Bool {
        guard let sessionToken, !requested.isEmpty else { return false }
        return sessionToken == requested
    }

    /// The two-minute code timer ran out: say who did not confirm.
    static func timeoutFailure(localConfirmed: Bool, remoteConfirmed: Bool) -> PairingFailure {
        switch (localConfirmed, remoteConfirmed) {
        case (true, false): .timeoutRemote
        case (false, true): .timeoutLocal
        default: .timeoutNeither
        }
    }

    /// What a received pairing.cancel means for this end's pairing. Nil: not a failure (`not_armed`: wait for Allow
    /// pairing on the other device and try again).
    static func failure(forCancel reason: PairingCancelReason, localConfirmed: Bool, remoteConfirmed: Bool) -> PairingFailure? {
        switch reason {
        case .mismatch: .mismatchRemote
        case .cancelled: .cancelledRemote
        case .timeout: timeoutFailure(localConfirmed: localConfirmed, remoteConfirmed: remoteConfirmed)
        case .busy: .busy
        case .rateLimited: .rateLimited
        case .notArmed: nil
        // This end only sends uncommitted offers to devices it trusts, so these two mean something else went wrong.
        case .needsProtocol2, .notTrusted: .invalid
        }
    }
}

enum InboundOfferDecision: Equatable {
    case answer(chargesLimiter: Bool)
    case refuse(PairingCancelReason)
}

/// Why a pairing.cancel was sent (`reason`, protocol 2). An unknown or absent reason reads as `cancelled`.
enum PairingCancelReason: String, CaseIterable {
    case mismatch, cancelled, timeout, busy
    case rateLimited = "rate_limited"
    case notArmed = "not_armed"
    case needsProtocol2 = "needs_protocol_2"
    case notTrusted = "not_trusted"

    init(wire: String?) { self = wire.flatMap(Self.init(rawValue:)) ?? .cancelled }
}

/// Monotonic seconds (they do not jump when the wall clock is changed), injectable in tests.
typealias MonotonicClock = () -> TimeInterval
let systemUptimeClock: MonotonicClock = { ProcessInfo.processInfo.systemUptime }

/// Monotonic seconds that keep counting while the Mac sleeps (CLOCK_MONOTONIC on macOS, unlike `systemUptime`), so
/// two minutes of Allow pairing cannot outlast a night of sleep.
let continuousClock: MonotonicClock = { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }

/// Whether this end answers committed offers now. Allow pairing arms it for two minutes (again from the start on each
/// tap); a pairing screen that is open holds it on until it closes.
struct PairingArming {
    static let duration: TimeInterval = 120
    private let now: MonotonicClock
    private var armedUntil: TimeInterval?
    private(set) var held = false

    init(now: @escaping MonotonicClock = continuousClock) { self.now = now }

    mutating func arm() { armedUntil = now() + Self.duration }

    /// The Mac is going to sleep: Allow pairing ends (an open pairing screen still holds it on when it wakes).
    mutating func systemWillSleep() { armedUntil = nil }
    mutating func disarm() { armedUntil = nil }
    mutating func hold(_ on: Bool) { held = on }

    var isArmed: Bool { held || remainingSeconds > 0 }

    /// Whole seconds left on Allow pairing (0 when not armed by it), for the countdown.
    var remainingSeconds: Int {
        guard let armedUntil else { return 0 }
        return max(0, Int((armedUntil - now()).rounded(.up)))
    }
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

/// Pairing prompts started by another device: at most `limit` per `window` and `hourlyLimit` per hour, on monotonic
/// time. Each prompt is a fresh random code, so this keeps a device on the network from cycling through codes until one
/// matches.
struct InboundPairingLimiter {
    let limit: Int
    let window: TimeInterval
    let hourlyLimit: Int
    static let hour: TimeInterval = 3_600
    private let now: MonotonicClock
    private var starts: [TimeInterval] = []

    init(limit: Int = 3, window: TimeInterval = 60, hourlyLimit: Int = 10, now: @escaping MonotonicClock = systemUptimeClock) {
        self.limit = limit
        self.window = window
        self.hourlyLimit = hourlyLimit
        self.now = now
    }

    mutating func tryAcquire() -> Bool {
        let time = now()
        starts.removeAll { time - $0 >= Self.hour }
        guard starts.count < hourlyLimit, starts.filter({ time - $0 < window }).count < limit else { return false }
        starts.append(time)
        return true
    }
}

/// Sends `data` as the connection's last message and cancels the connection once it has gone out: cancelling right
/// after a send can drop the send, so a refusal's reason never reached the phone. Cancels anyway after `timeout`.
func sendFinalAndCancel(_ connection: NWConnection, _ data: Data, timeout: TimeInterval = 2) {
    connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
        connection.cancel()
    })
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { connection.cancel() }
}
