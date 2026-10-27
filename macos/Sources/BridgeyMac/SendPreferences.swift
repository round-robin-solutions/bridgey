import Combine
import Foundation

// Send preferences on this Mac (Files 2.0): the last device a send went to, what a drop on the menu-bar icon
// does, and the "Before sending" optimisation defaults. Never synced; UserDefaults under `send.`.

/// Settings > Files > When I drop on the menu-bar icon.
enum MenuBarDropMode: String, CaseIterable, Codable {
    /// Hover opens the panel with a tile per device plus Tray; a quick drop on the icon sends to the last device.
    case springOpen = "spring_open"
    /// Every drop goes to the Tray.
    case tray
    /// Every drop is sent at once to the default device.
    case instant
}

@MainActor
final class SendPreferences: ObservableObject {
    static let shared = SendPreferences(defaults: .standard)

    @Published private(set) var lastDeviceID: String?
    @Published private(set) var menuBarDropMode: MenuBarDropMode
    @Published private(set) var optimization: SendOptimization

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        lastDeviceID = defaults.string(forKey: Keys.lastDevice)
        menuBarDropMode = MenuBarDropMode(rawValue: defaults.string(forKey: Keys.dropMode) ?? "") ?? .springOpen
        optimization = defaults.data(forKey: Keys.optimization)
            .flatMap { try? JSONDecoder().decode(SendOptimization.self, from: $0) } ?? .default
    }

    func rememberDevice(_ id: String) {
        guard lastDeviceID != id else { return }
        defaults.set(id, forKey: Keys.lastDevice)
        lastDeviceID = id
    }

    func setMenuBarDropMode(_ mode: MenuBarDropMode) {
        defaults.set(mode.rawValue, forKey: Keys.dropMode)
        menuBarDropMode = mode
    }

    func setOptimization(_ value: SendOptimization) {
        guard value != optimization else { return }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Keys.optimization) }
        optimization = value
    }

    func updateOptimization(_ change: (inout SendOptimization) -> Void) {
        var value = optimization
        change(&value)
        setOptimization(value)
    }

    /// The device a send goes to when nobody picked one: the last used if it is connected, else the selected
    /// phone, else the first connected one.
    func defaultDevice(connected: [String], selected: String?) -> String? {
        if let last = lastDeviceID, connected.contains(last) { return last }
        if let selected, connected.contains(selected) { return selected }
        return connected.first
    }

    private enum Keys {
        static let lastDevice = "send.lastDevice"
        static let dropMode = "send.menuBarDrop"
        static let optimization = "send.optimization.v1"
    }
}
