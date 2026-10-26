import Foundation

private let supportedRemoteCallTypes: Set<String> = ["incoming", "ongoing", "screening", "unknown"]

func normalizedRemoteCallType(_ value: String?) -> String? {
    guard let value, supportedRemoteCallTypes.contains(value) else { return nil }
    return value
}

func remoteCallStatusTitle(_ type: String?) -> String {
    switch type {
    case "incoming": return "Incoming call"
    case "ongoing": return "Call in progress"
    case "screening": return "Call screening"
    default: return "Phone call"
    }
}

func remoteCallDetail(_ detail: String, type: String?) -> String {
    let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    let genericCallDescriptions: Set<String> = [
        "incoming call", "ongoing call", "call in progress", "call screening", "screening call", "phone call",
    ]
    return genericCallDescriptions.contains(trimmed.lowercased()) ? "" : trimmed
}

func shouldUseSystemNotification(callType: String?) -> Bool {
    callType == nil
}

func remoteCallPausesMedia(_ type: String) -> Bool {
    type == "incoming" || type == "ongoing"
}

/// How long a call card stays after the phone retracts its notification without saying the call
/// ended: long enough for a dialer to re-post the same call (an older phone app sends no end flag).
let remoteCallRemovalGrace: TimeInterval = 2

struct ActiveRemoteCalls {
    private static let maximumCount = 8
    private var calls: [RemoteCallStatus] = []
    /// Calls the phone retracted without confirming the end, with the time they may go.
    private var pendingRemovals: [String: Date] = [:]

    var isEmpty: Bool { calls.isEmpty }
    var pausesMedia: Bool { calls.contains { remoteCallPausesMedia($0.type) } }
    var all: [RemoteCallStatus] { calls }

    var mostRelevant: RemoteCallStatus? {
        calls.last { $0.type == "incoming" } ?? calls.last
    }

    func contains(notificationID: String, deviceID: String) -> Bool {
        calls.contains { $0.deviceID == deviceID && $0.notificationID == notificationID }
    }

    func isPendingRemoval(notificationID: String, deviceID: String) -> Bool {
        pendingRemovals[Self.key(notificationID, deviceID)] != nil
    }

    /// A post for the call (a re-post after a retraction included) keeps it.
    /// Returns true when the post cancelled a pending removal.
    @discardableResult
    mutating func update(_ call: RemoteCallStatus) -> Bool {
        let resumed = pendingRemovals.removeValue(forKey: Self.key(call.notificationID, call.deviceID)) != nil
        if let index = calls.firstIndex(where: { $0.deviceID == call.deviceID && $0.notificationID == call.notificationID }) {
            calls[index] = call
        } else {
            calls.append(call)
            if calls.count > Self.maximumCount {
                let dropped = calls.removeFirst()
                pendingRemovals.removeValue(forKey: Self.key(dropped.notificationID, dropped.deviceID))
            }
        }
        return resumed
    }

    /// The phone retracted the call's notification but did not confirm the call ended: the card
    /// stays until `deadline` unless the call is posted again. Returns false for an unknown call.
    @discardableResult
    mutating func scheduleRemoval(notificationID: String, deviceID: String, deadline: Date) -> Bool {
        guard contains(notificationID: notificationID, deviceID: deviceID) else { return false }
        let key = Self.key(notificationID, deviceID)
        if pendingRemovals[key] == nil { pendingRemovals[key] = deadline }
        return true
    }

    /// Removes and returns the calls whose removal grace has run out.
    mutating func removeExpired(now: Date) -> [RemoteCallStatus] {
        let expired = pendingRemovals.filter { $0.value <= now }.map(\.key)
        var removed: [RemoteCallStatus] = []
        for key in expired {
            pendingRemovals.removeValue(forKey: key)
            if let index = calls.firstIndex(where: { Self.key($0.notificationID, $0.deviceID) == key }) {
                removed.append(calls.remove(at: index))
            }
        }
        return removed
    }

    @discardableResult
    mutating func remove(notificationID: String, deviceID: String) -> RemoteCallStatus? {
        pendingRemovals.removeValue(forKey: Self.key(notificationID, deviceID))
        guard let index = calls.firstIndex(where: { $0.deviceID == deviceID && $0.notificationID == notificationID }) else {
            return nil
        }
        return calls.remove(at: index)
    }

    /// One phone disconnected or turned notifications off: only its calls go.
    mutating func removeAll(deviceID: String) -> [RemoteCallStatus] {
        let removed = calls.filter { $0.deviceID == deviceID }
        calls.removeAll { $0.deviceID == deviceID }
        for call in removed { pendingRemovals.removeValue(forKey: Self.key(call.notificationID, call.deviceID)) }
        return removed
    }

    mutating func removeAll() -> [RemoteCallStatus] {
        defer {
            calls = []
            pendingRemovals = [:]
        }
        return calls
    }

    private static func key(_ notificationID: String, _ deviceID: String) -> String {
        "\(deviceID)\u{0}\(notificationID)"
    }
}

/// The incoming calls that should ring on the Mac: ringing is on, and the call card is neither
/// hidden nor already acted on (answered or declined from the Mac).
func ringingRemoteCallIdentities(
    _ calls: [RemoteCallStatus],
    enabled: Bool,
    silenced: Set<String>,
    identity: (RemoteCallStatus) -> String
) -> [String] {
    guard enabled else { return [] }
    return calls.filter { $0.type == "incoming" }.map(identity).filter { !silenced.contains($0) }
}

/// The first eight characters of an Android notification id, for logs and diagnostics.
func shortCallID(_ notificationID: String) -> String { String(notificationID.prefix(8)) }
