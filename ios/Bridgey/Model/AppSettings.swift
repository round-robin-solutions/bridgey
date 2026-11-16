import SwiftUI
import UIKit

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

/// The app's own settings. Each default is the sensible choice and has a switch in Settings. Pairing data is not
/// here: bridgey_core keeps it in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var setupDone: Bool { didSet { defaults.set(setupDone, forKey: "setupDone") } }
    /// The name other devices see.
    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    /// Clipboard text to and from paired devices (each device has its own switch too).
    @Published var clipboard: Bool { didSet { defaults.set(clipboard, forKey: "clipboard") } }
    /// Text that arrives goes straight onto this iPhone's clipboard.
    @Published var copyReceivedText: Bool { didSet { defaults.set(copyReceivedText, forKey: "copyReceivedText") } }
    @Published var files: Bool { didSet { defaults.set(files, forKey: "files") } }
    @Published var links: Bool { didSet { defaults.set(links, forKey: "links") } }
    /// Links that arrive open in the browser at once instead of waiting on a card. Off: a link opening by itself
    /// is a surprise.
    @Published var openLinksRightAway: Bool { didSet { defaults.set(openLinksRightAway, forKey: "openLinksRightAway") } }
    /// One-line previews of text in the activity list.
    @Published var showPreviews: Bool { didSet { defaults.set(showPreviews, forKey: "showPreviews") } }
    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Less motion than iOS's own Reduce Motion asks for.
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "reduceMotion") } }
    /// The device the send bar sends to.
    @Published var lastDeviceID: String? { didSet { defaults.set(lastDeviceID, forKey: "lastDeviceID") } }

    init(defaults: UserDefaults = SharedStorage.defaults) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        setupDone = bool("setupDone", false)
        let name = defaults.string(forKey: "deviceName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        deviceName = name.isEmpty ? UIDevice.current.name : name
        clipboard = bool("clipboard", true)
        copyReceivedText = bool("copyReceivedText", true)
        files = bool("files", true)
        links = bool("links", true)
        openLinksRightAway = bool("openLinksRightAway", false)
        showPreviews = bool("showPreviews", true)
        appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        reduceMotion = bool("reduceMotion", false)
        lastDeviceID = defaults.string(forKey: "lastDeviceID")
    }
}
