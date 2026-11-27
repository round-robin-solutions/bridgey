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

    /// See and control the screens of an Android phone and a Mac. The phone or Mac decides who may.
    @Published var screens: Bool { didSet { defaults.set(screens, forKey: "screens") } }
    /// Devices whose screen this device doesn't ask for (Device settings > Screen off).
    @Published var screensOff: Set<String> { didSet { defaults.set(Array(screensOff).sorted(), forKey: "screensOff") } }
    /// The phone's conversations here. Off until chosen, as on the Mac and Windows.
    @Published var textMessages: Bool { didSet { defaults.set(textMessages, forKey: "textMessages") } }
    /// Keep conversations between launches (this device only, protected until first unlock).
    @Published var keepConversations: Bool { didSet { defaults.set(keepConversations, forKey: "keepConversations") } }
    /// The phone's notifications while Bridgey is open.
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    /// This device's battery on paired devices, and theirs here.
    @Published var battery: Bool { didSet { defaults.set(battery, forKey: "battery") } }
    /// Paired devices can ring this one while Bridgey is open, and it can ring them.
    @Published var findDevice: Bool { didSet { defaults.set(findDevice, forKey: "findDevice") } }
    /// One-time codes from the phone's text messages, with Copy code. Found here; nothing leaves this device.
    @Published var codesFromMessages: Bool { didSet { defaults.set(codesFromMessages, forKey: "codesFromMessages") } }
    /// Also look for codes in email notifications.
    @Published var codesFromEmail: Bool { didSet { defaults.set(codesFromEmail, forKey: "codesFromEmail") } }
    /// Connect away from home: reach paired devices off this Wi-Fi while Bridgey is open.
    @Published var connectAway: Bool { didSet { defaults.set(connectAway, forKey: "connectAway") } }

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
        screens = bool("screens", true)
        screensOff = Set(defaults.stringArray(forKey: "screensOff") ?? [])
        textMessages = bool("textMessages", false)
        keepConversations = bool("keepConversations", true)
        notifications = bool("notifications", true)
        battery = bool("battery", true)
        findDevice = bool("findDevice", true)
        codesFromMessages = bool("codesFromMessages", false)
        codesFromEmail = bool("codesFromEmail", false)
        connectAway = bool("connectAway", true)
    }
}
