import Foundation

// Files 2.0 quick win, Mac half of the phone's free space: when to ask (places.list, at most once per 20 s per
// phone; a request inside the window becomes one trailing request at its end) and what an answer means.

struct FreeSpaceThrottle {
    static let interval: TimeInterval = 20

    private var lastAsked: [String: Date] = [:]
    private var trailing: Set<String> = []

    enum Decision: Equatable {
        /// Ask now.
        case ask
        /// Ask once the window ends, after this many seconds (one trailing request per phone).
        case later(TimeInterval)
        /// A trailing request is already waiting.
        case alreadyWaiting
    }

    mutating func request(_ phoneID: String, now: Date) -> Decision {
        if let last = lastAsked[phoneID], now >= last, now.timeIntervalSince(last) < Self.interval {
            if trailing.contains(phoneID) { return .alreadyWaiting }
            trailing.insert(phoneID)
            return .later(Self.interval - now.timeIntervalSince(last))
        }
        lastAsked[phoneID] = now
        trailing.remove(phoneID)
        return .ask
    }

    /// The trailing request ran (or was dropped).
    mutating func trailingDone(_ phoneID: String) { trailing.remove(phoneID) }

    mutating func forget(_ phoneID: String) {
        lastAsked.removeValue(forKey: phoneID)
        trailing.remove(phoneID)
    }
}

enum FreeSpaceReading {
    /// From places.listed: `defaultFreeBytes`, else the `default` place's `freeBytes` when the phone listed it.
    static func bytes(from listed: PlacesListedPayload) -> Int64? {
        if let value = listed.defaultFreeBytes, value >= 0 { return value }
        return listed.places.first { $0.placeId == defaultPlaceID }?.freeBytes.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// From folders.accept: the chosen destination's free bytes before the folder.
    static func bytes(from accept: FolderAcceptPayload) -> Int64? {
        accept.freeBytes.flatMap { $0 >= 0 ? $0 : nil }
    }
}
