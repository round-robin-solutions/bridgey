import Foundation

/// What this Mac knows about one connected phone. Every phone has its own copy, so one phone's
/// features, battery or Find state never leak into another's.
struct PhoneLinkState: Equatable {
    var remoteFeatures: [BridgeyFeature: Bool] = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map {
        ($0, featureEnabledByLegacyPeer($0))
    })
    var featureStateReceived = false
    /// The phone advertised `clipboard_files_draft1`.
    var remoteClipboardFiles = false
    /// The phone advertised `folders_draft1` (it receives folders) and `places_draft1` (it serves places).
    var remoteFolders = false
    var remotePlaces = false
    /// The phone advertised `sms_codes_draft1`: it marks SMS notifications and can make a companion link.
    var remoteSmsCodes = false
    /// The phone advertised `focus_sync_draft1`: it understands focus.state.
    var remoteFocusSync = false
    /// The phone advertised `camera_draft1`: it takes photos for this Mac.
    var remoteCamera = false
    /// The phone's last `codes.status`: whether Android shows Bridgey the text of code messages.
    var codeAccess: CodeAccessStatus?
    var battery: RemoteBatteryStatus?
    /// The phone reported that it is ringing (Find device).
    var ringing = false
}

/// A connected, authenticated phone as the UI sees it.
struct PhoneConnection: Identifiable, Equatable {
    let id: String
    let name: String
    let state: PhoneLinkState
}

/// Why a pairing attempt ended; the panel shows `message`.
enum PairingFailure: String, Equatable {
    case couldNotConnect, timeout, cancelledRemote, codeRejected, identityChanged, connectionLost, busy, invalid, localNetworkDenied

    var message: String {
        switch self {
        case .couldNotConnect:
            L10n.text("pairing.failure.connect", fallback: "Could not reach the device. Check that both are on the same Wi-Fi and Bridgey is open.")
        case .timeout:
            L10n.text("pairing.failure.timeout", fallback: "Pairing timed out. Start again and confirm the code on both devices within two minutes.")
        case .cancelledRemote:
            L10n.text("pairing.failure.cancelled", fallback: "Pairing was cancelled on the other device, or its code was rejected there.")
        case .codeRejected:
            L10n.text("pairing.failure.rejected", fallback: "The devices could not verify each other. Check that the codes match and try again.")
        case .identityChanged:
            L10n.text("pairing.failure.identity", fallback: "This device\u{2019}s identity changed. Forget it on both devices, then pair again.")
        case .connectionLost:
            L10n.text("pairing.failure.lost", fallback: "The connection was lost before pairing finished. Try again.")
        case .busy:
            L10n.text("pairing.failure.busy", fallback: "Another pairing is waiting for confirmation. Finish or cancel it first.")
        case .invalid:
            L10n.text("pairing.failure.invalid", fallback: "The other device sent something unexpected. Update Bridgey on both devices and try again.")
        case .localNetworkDenied:
            "Local Network access is off. Enable Bridgey in System Settings \u{2192} Privacy & Security \u{2192} Local Network."
        }
    }
}

/// Sessions keyed the way multi-device needs them: unauthenticated or pairing sessions on their
/// own, and one authenticated session per phone. Mirrors android/.../SessionRegistry.kt, with the
/// same duplicate rule so both ends keep the same socket: keep the one dialled by the side with
/// the lower device id; if both were dialled by the same side, keep the newer one.
final class SessionRegistry<S: AnyObject> {
    enum Admission: Equatable {
        /// The session is now the device's session; `replaced` (if any) must be closed.
        case accepted(replaced: S?)
        /// Another live session for the device wins; this one must be closed.
        case rejected

        static func == (lhs: Admission, rhs: Admission) -> Bool {
            switch (lhs, rhs) {
            case let (.accepted(a), .accepted(b)): a === b
            case (.rejected, .rejected): true
            default: false
            }
        }
    }

    private final class Entry {
        let session: S
        let initiatedLocally: Bool
        var deviceID: String?
        var peerName = ""
        var state = PhoneLinkState()

        init(session: S, initiatedLocally: Bool) {
            self.session = session
            self.initiatedLocally = initiatedLocally
        }
    }

    private let localDeviceID: String
    private var pending: [Entry] = []
    /// Connection order.
    private var active: [Entry] = []

    init(localDeviceID: String) {
        self.localDeviceID = localDeviceID
    }

    func addPending(_ session: S, initiatedLocally: Bool) {
        pending.append(Entry(session: session, initiatedLocally: initiatedLocally))
    }

    var pendingSessions: [S] { pending.map(\.session) }

    func isPending(_ session: S) -> Bool { pending.contains { $0.session === session } }

    func isActive(_ session: S) -> Bool { active.contains { $0.session === session } }

    func authenticate(_ session: S, deviceID: String, peerName: String) -> Admission {
        let entry: Entry
        if let index = pending.firstIndex(where: { $0.session === session }) {
            entry = pending.remove(at: index)
        } else if let existing = active.first(where: { $0.session === session }) {
            entry = existing
        } else {
            return .rejected
        }
        entry.deviceID = deviceID
        entry.peerName = peerName
        guard let index = active.firstIndex(where: { $0.deviceID == deviceID && $0.session !== session }) else {
            if !active.contains(where: { $0 === entry }) { active.append(entry) }
            return .accepted(replaced: nil)
        }
        let existing = active[index]
        guard prefers(entry, over: existing) else { return .rejected }
        entry.state = existing.state
        active.remove(at: index)
        active.append(entry)
        return .accepted(replaced: existing.session)
    }

    private func prefers(_ candidate: Entry, over existing: Entry) -> Bool {
        let candidateLower = dialledByLowerID(candidate)
        let existingLower = dialledByLowerID(existing)
        return candidateLower != existingLower ? candidateLower : true
    }

    private func dialledByLowerID(_ entry: Entry) -> Bool {
        guard let remote = entry.deviceID else { return false }
        return entry.initiatedLocally ? localDeviceID < remote : remote < localDeviceID
    }

    /// Forgets the session. Returns the device id when it was that device's live session.
    @discardableResult
    func remove(_ session: S) -> String? {
        if let index = pending.firstIndex(where: { $0.session === session }) {
            pending.remove(at: index)
            return nil
        }
        guard let index = active.firstIndex(where: { $0.session === session }) else { return nil }
        return active.remove(at: index).deviceID
    }

    func session(for deviceID: String) -> S? { active.first { $0.deviceID == deviceID }?.session }

    func deviceID(of session: S) -> String? { active.first { $0.session === session }?.deviceID }

    var connectedIDs: [String] { active.compactMap(\.deviceID) }

    var connections: [PhoneConnection] {
        active.map { PhoneConnection(id: $0.deviceID ?? "", name: $0.peerName, state: $0.state) }
    }

    func state(for deviceID: String) -> PhoneLinkState? { active.first { $0.deviceID == deviceID }?.state }

    @discardableResult
    func update(_ deviceID: String, _ transform: (inout PhoneLinkState) -> Void) -> Bool {
        guard let entry = active.first(where: { $0.deviceID == deviceID }) else { return false }
        transform(&entry.state)
        return true
    }

    /// The phone outgoing actions aim at: `selected` while connected, else the latest connection.
    func target(selected: String?) -> String? {
        if let selected, active.contains(where: { $0.deviceID == selected }) { return selected }
        return active.last?.deviceID
    }

    /// Connected phones for a broadcast, in connection order.
    func broadcastTargets(_ include: (String, PhoneLinkState) -> Bool) -> [(String, S)] {
        active.compactMap { entry in
            guard let id = entry.deviceID, include(id, entry.state) else { return nil }
            return (id, entry.session)
        }
    }

    @discardableResult
    func removeAll() -> [S] {
        let all = pending.map(\.session) + active.map(\.session)
        pending.removeAll()
        active.removeAll()
        return all
    }
}

/// The menu bar's status line: how many phones are connected, or the pairing step.
func connectionSummary(_ connections: [PhoneConnection], pairing: PairingState) -> String {
    switch connections.count {
    case 0:
        switch pairing {
        case let .connecting(name), let .verification(name, _):
            return String(format: L10n.text("panel.connecting", fallback: "Connecting to %@"), name)
        case .failed: return L10n.text("thisMac.failed", fallback: "Couldn\u{2019}t connect")
        default: return L10n.text("thisMac.idle", fallback: "Not connected")
        }
    case 1:
        return String(format: L10n.text("thisMac.connected", fallback: "Connected to %@"), connections[0].name)
    default:
        return String(format: L10n.text("thisMac.connectedMany", fallback: "Connected to %d devices"), connections.count)
    }
}
