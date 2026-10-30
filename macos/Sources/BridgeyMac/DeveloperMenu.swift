import Foundation

/// Settings > About: clicking the version `taps` times in a row (each within `window` of the last) turns on the hidden
/// Developer and experimental pane, like Android's build number. Once on, the pane is in the sidebar and a click on
/// the version opens it, until it is hidden inside the pane. Kept in this Mac's preferences under a key settings sync
/// does not list (SettingsSync.swift), so it never syncs. Android has the same rules in DeveloperMenu.kt.
final class DeveloperMenu {
    enum Tap: Equatable {
        /// Counting, nothing to show yet.
        case counting
        /// Counting: this many more clicks turn the pane on.
        case remaining(Int)
        /// This click turned the pane on.
        case unlocked
        /// The pane was already on: open it.
        case open
    }

    static let taps = 5
    static let window: TimeInterval = 3
    /// The countdown shows once this many clicks are left.
    static let showFrom = 3
    static let key = "developer.menu"
    static let shared = DeveloperMenu()

    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private var count = 0
    private var lastTap: TimeInterval?

    init(defaults: UserDefaults = .standard, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.now = now
    }

    var enabled: Bool { defaults.bool(forKey: Self.key) }

    func tap() -> Tap {
        if enabled { return .open }
        let at = now()
        if let lastTap, at - lastTap <= Self.window {} else { count = 0 }
        lastTap = at
        count += 1
        if count >= Self.taps {
            count = 0
            defaults.set(true, forKey: Self.key)
            return .unlocked
        }
        let left = Self.taps - count
        return left <= Self.showFrom ? .remaining(left) : .counting
    }

    /// "Hide this pane": it goes away until the version is clicked again.
    func turnOff() {
        defaults.set(false, forKey: Self.key)
        count = 0
        lastTap = nil
    }
}

/// Developer pane > How files travel now: one connected phone.
struct TransferPathRow: Equatable, Identifiable {
    let id: String
    let name: String
    /// Both ends speak files_fast_draft1 on this session: binary frames and the byte window.
    let fast: Bool
    /// A Connect anywhere tunnel's route ("vpn", "direct", "relay"), or nil on the local network.
    let tunnelRoute: String?
}
