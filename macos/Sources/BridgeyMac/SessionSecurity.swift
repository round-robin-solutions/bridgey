import CryptoKit
import Foundation
import Network

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

    /// Crossed pairing (docs/protocol.md): the user is pairing this end with a device (`target`), that committed pairing
    /// has not been answered yet (`ownPending`: its dial is in flight, or it waits for Allow pairing there), and a
    /// committed offer arrives from that same device, because someone started pairing there too. Both people acted, so
    /// that one device's offer counts as armed here, but only one of the two dials may go on: the one from the lower
    /// device ID, as for simultaneous reconnects. Commit-reveal and the code confirmation run as for any first pairing.
    ///
    /// A device ID is only a claim, so the offer must also come from an address this end dialled or discovery showed
    /// for the device the user tapped; after the own dial met `not_armed` from a device whose offer this end refused
    /// (it does not know this end's ID), the usual rules apply to it again.
    static func crossedPairing(localDeviceID: String, remoteDeviceID: String, sourceAddress: String?,
                               target: CrossedPairingTarget?, ownPending: Bool, committedOffer: Bool) -> CrossedPairing {
        let local = localDeviceID.lowercased()
        let remote = remoteDeviceID.lowercased()
        guard committedOffer, ownPending, let target, !target.fellBack, remote != local,
              target.admits(remoteDeviceID: remote, sourceAddress: sourceAddress) else { return .none }
        return remote < local ? .answer : .keepOwn
    }

    /// Answering this offer sets the user's own pairing aside (parks it) instead of refusing the offer as busy at the
    /// code: only for the tapped device's committed offer from one of its addresses, while that pairing is pending.
    /// Allow pairing here does not widen this. Setup's pair step holds it while the user's own dial runs, so an offer
    /// that only copies the tapped ID is answered like any other offer and then refused as busy; the own pairing stays.
    static func yieldsOwnPairing(ownPending: Bool, committedOffer: Bool, target: CrossedPairingTarget?,
                                 remoteDeviceID: String, sourceAddress: String?) -> Bool {
        guard ownPending, committedOffer, let target else { return false }
        return target.admits(remoteDeviceID: remoteDeviceID, sourceAddress: sourceAddress)
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

/// The user's own committed pairing, as crossed pairing sees it (`PairingRules.crossedPairing`).
struct CrossedPairingTarget: Equatable {
    /// The ID discovery showed for the device the user tapped (lowercase).
    let deviceID: String
    /// Where this end dialled that device and where discovery saw it (normalised): a crossed offer comes from one of these.
    private(set) var addresses: Set<String>
    /// This end has the lower ID and refused that device's offer, so that its own dial goes on.
    private(set) var keptOwn = false
    /// The own dial then met `not_armed` from that device: it does not know this end's ID, so the usual rules apply
    /// (its offer shows the "wants to pair" card, and Allow pairing answers it).
    private(set) var fellBack = false

    init(deviceID: String, addresses: [String]) {
        self.deviceID = deviceID.lowercased()
        self.addresses = Set(addresses.compactMap(normalizedHost))
    }

    /// The offer claims the tapped device's ID and comes from one of its addresses.
    func admits(remoteDeviceID: String, sourceAddress: String?) -> Bool {
        guard remoteDeviceID.lowercased() == deviceID, let source = sourceAddress.flatMap(normalizedHost) else { return false }
        return addresses.contains(source)
    }

    /// An offer claims the tapped device's ID from an address this end never saw for it: the detail for the
    /// `crossed unverified_source` diagnostic, the source's address tag and the known ones (`src_v6_known_name.v4.194.v6`;
    /// tags only, never addresses). Nil for any other ID or an admitted address.
    func unverifiedSourceDetail(remoteDeviceID: String, sourceAddress: String?) -> String? {
        guard remoteDeviceID.lowercased() == deviceID, !admits(remoteDeviceID: remoteDeviceID, sourceAddress: sourceAddress) else {
            return nil
        }
        let source = sourceAddress.flatMap(normalizedHost).map(addressTag) ?? "none"
        let known = addresses.map(addressTag).sorted().joined(separator: ".")
        return "src_\(source)_known_\(known.isEmpty ? "none" : known)"
    }

    /// The address the own dial reached (the resolved endpoint of a `.local` name).
    mutating func note(address: String) {
        if let host = normalizedHost(address) { addresses.insert(host) }
    }

    mutating func keepOwnDial() { keptOwn = true }

    /// The own dial met `not_armed`. True when this falls back to the usual rules now.
    mutating func ownDialNotArmed() -> Bool {
        guard keptOwn, !fellBack else { return false }
        fellBack = true
        return true
    }
}

/// What a crossed pairing means for an offer (`PairingRules.crossedPairing`).
enum CrossedPairing: Equatable {
    /// Not a crossed pairing: the usual rules.
    case none
    /// The other device's ID is the lower one, so its dial goes on: its offer is answered even when pairing is not armed
    /// here, and this end's own dial (or wait for Allow pairing) is parked: it resumes if that offer fails before its code.
    case answer
    /// This end's ID is the lower one, so its own dial goes on: the other device's offer is refused with `not_armed`,
    /// without a "wants to pair" card. That device waits and answers this end's next dial.
    case keepOwn
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
