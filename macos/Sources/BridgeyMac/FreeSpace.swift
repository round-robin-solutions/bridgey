import Foundation

// Files 2.0 quick win: the phone's free space before big sends. The phone reports `defaultFreeBytes` in every
// places.listed (where a file or folder sent now lands by default) and `freeBytes` in folders.accept (the
// chosen destination). PairingCoordinator keeps the latest value per phone (`phoneFreeSpace`, refreshed on
// connect, when a send surface opens, and after each finished send, at most once per 20 s per phone); the
// send sheet, the Tray and the drop tiles check a send with `FreeSpaceCheck` before it starts.

struct PhoneFreeSpace: Equatable {
    let bytes: Int64
    let checkedAt: Date
}

enum FreeSpaceCheck: Equatable {
    /// Fits with room to spare, or the phone did not say.
    case ok
    /// Fits, but leaves the phone nearly full (under `warnMargin` free afterwards).
    case warn(needed: Int64, free: Int64)
    /// Does not fit: the receiver refuses anything above its free space minus `receiverMargin`.
    case block(needed: Int64, free: Int64)

    /// The receiving phone keeps 64 MiB free (protocol 4.8, insufficient_space).
    static let receiverMargin: Int64 = 64 * 1024 * 1024
    /// Below this much free space after the send, warn.
    static let warnMargin: Int64 = 1024 * 1024 * 1024
    /// Values older than this are not trusted for blocking (only for a warning).
    static let freshFor: TimeInterval = 5 * 60

    /// `needed`: bytes the send writes on the phone (after optimisation when known, else the originals).
    static func evaluate(needed: Int64, free: PhoneFreeSpace?, now: Date = Date()) -> FreeSpaceCheck {
        guard let free, needed > 0 else { return .ok }
        let fresh = now.timeIntervalSince(free.checkedAt) <= freshFor
        if needed + receiverMargin > free.bytes {
            return fresh ? .block(needed: needed, free: free.bytes) : .warn(needed: needed, free: free.bytes)
        }
        if free.bytes - needed < warnMargin { return .warn(needed: needed, free: free.bytes) }
        return .ok
    }

    /// "Needs 2.3 GB, OnePlus 11 has 1.1 GB free", or nil for `.ok`.
    func message(phoneName: String) -> String? {
        switch self {
        case .ok:
            return nil
        case let .warn(needed, free), let .block(needed, free):
            return String(format: L10n.text("freeSpace.needs", fallback: "Needs %@, %@ has %@ free"),
                          FreeSpaceCheck.bytes(needed), phoneName, FreeSpaceCheck.bytes(free))
        }
    }

    var blocks: Bool { if case .block = self { return true } else { return false } }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file) }
}
