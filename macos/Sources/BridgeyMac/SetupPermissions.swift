import AppKit
import CoreBluetooth
import Foundation
import Network
import UserNotifications

/*
 * The optional macOS permissions Bridgey uses: what each one is for, what breaks without it,
 * and the state chip Settings > Privacy > Permissions shows. The mapping is pure; the probes
 * below read the live state from the system.
 */

enum SetupPermission: String, CaseIterable, Identifiable, Codable {
    case localNetwork, notifications, bluetooth, accessibility, automation
    /// v0.9: Send current browser tab asks Safari or Chrome for the front tab's address.
    case browserAutomation

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .localNetwork: "network"
        case .notifications: "bell.badge"
        case .bluetooth: "wave.3.right"
        case .accessibility: "accessibility"
        case .automation: "music.note"
        case .browserAutomation: "safari"
        }
    }

    var tint: TileTint {
        switch self {
        case .localNetwork, .notifications, .browserAutomation: .blue
        case .bluetooth, .automation: .purple
        case .accessibility: .green
        }
    }

    var name: String {
        switch self {
        case .localNetwork: L10n.setup("permission.localNetwork", fallback: "Local Network")
        case .notifications: L10n.setup("permission.notifications", fallback: "Notifications")
        case .bluetooth: L10n.setup("permission.bluetooth", fallback: "Bluetooth")
        case .accessibility: L10n.setup("permission.accessibility", fallback: "Accessibility")
        case .automation: L10n.setup("permission.automation", fallback: "Automation (Music, Spotify)")
        case .browserAutomation: L10n.setup("permission.browserAutomation", fallback: "Automation (Safari, Chrome)")
        }
    }

    var why: String {
        switch self {
        case .localNetwork: L10n.setup("permission.localNetwork.why", fallback: "Finds your phone and talks to it on this network.")
        case .notifications: L10n.setup("permission.notifications.why", fallback: "Shows your phone\u{2019}s notifications, calls, codes and text replies on this Mac. Used by Notifications, Text messages and Calls.")
        case .bluetooth: L10n.setup("permission.bluetooth.why", fallback: "Lets your phone link to this Mac so Android shows Bridgey your codes.")
        case .accessibility: L10n.setup("permission.accessibility.why", fallback: "Lets your phone move the pointer and type when you turn on remote control, and lock this Mac with Mac actions.")
        case .automation: L10n.setup("permission.automation.why", fallback: "Lets your phone play, pause and skip in Music or Spotify.")
        case .browserAutomation: L10n.setup("permission.browserAutomation.why", fallback: "Lets you send the front Safari or Chrome tab to your phone.")
        }
    }

    var without: String {
        switch self {
        case .localNetwork: L10n.setup("permission.localNetwork.without", fallback: "The Mac cannot find or reach your phone.")
        case .notifications: L10n.setup("permission.notifications.without", fallback: "Phone alerts, call cards and codes stay silent.")
        case .bluetooth: L10n.setup("permission.bluetooth.without", fallback: "Codes from messages may show \u{201C}hidden\u{201D} on Android 15 and later.")
        case .accessibility: L10n.setup("permission.accessibility.without", fallback: "Remote control cannot move the pointer or type, and Lock from the phone is refused.")
        case .automation: L10n.setup("permission.automation.without", fallback: "Media controls from the phone do nothing.")
        case .browserAutomation: L10n.setup("permission.browserAutomation.without", fallback: "Send the Current Browser Tab cannot read the tab\u{2019}s address.")
        }
    }

    /// "Allow Local Network?"
    var explainerTitle: String {
        String(format: L10n.setup("permission.explainer.title", fallback: "Allow %@?"), name)
    }

    /// The exact System Settings page.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .localNetwork: anchor = "Privacy_LocalNetwork"
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? Edition.identifier)")!
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .accessibility: return AccessibilityAccess.settingsURL
        case .automation, .browserAutomation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// What macOS says about one permission.
enum PermissionSystemState: Equatable {
    case allowed, denied, notDetermined
    /// This macOS or this Mac does not have it.
    case unavailable
}

/// The chip on the Permissions page.
enum PermissionChip: Equatable {
    case allowed, notAllowed, notNeededYet, notOnThisDevice

    var title: String {
        switch self {
        case .allowed: L10n.setup("permission.state.allowed", fallback: "Allowed")
        case .notAllowed: L10n.setup("permission.state.notAllowed", fallback: "Not allowed")
        case .notNeededYet: L10n.setup("permission.state.notNeeded", fallback: "Not needed yet")
        case .notOnThisDevice: L10n.setup("permission.state.notOnDevice", fallback: "Not on this device")
        }
    }
}

/// What Manage does.
enum PermissionManageAction: Equatable {
    /// macOS has not asked yet: the explainer, then the system prompt.
    case request
    /// Already answered: the exact System Settings page.
    case openSettings
    case none
}

struct PermissionStatus: Equatable, Identifiable {
    let permission: SetupPermission
    let system: PermissionSystemState
    /// The feature that needs it is on.
    let needed: Bool

    var id: String { permission.rawValue }

    var chip: PermissionChip { Self.chip(system: system, needed: needed) }
    var manage: PermissionManageAction { Self.manage(system: system) }

    static func chip(system: PermissionSystemState, needed: Bool) -> PermissionChip {
        switch system {
        case .unavailable: .notOnThisDevice
        case .allowed: .allowed
        case .denied, .notDetermined: needed ? .notAllowed : .notNeededYet
        }
    }

    static func manage(system: PermissionSystemState) -> PermissionManageAction {
        switch system {
        case .notDetermined: .request
        case .allowed, .denied: .openSettings
        case .unavailable: .none
        }
    }
}

/// Which features are on, for "Not needed yet".
struct PermissionNeeds: Equatable {
    var notifications = true
    var calls = true
    var codes = false
    /// Text messages: Reply on text notifications and send failures appear as notifications.
    var messages = false
    var remoteControl = false
    var media = false
    var mediaPlayer: MediaPlayer = .off
    /// v0.9: Mac actions is on and its Lock switch is on (Lock presses the shortcut through Accessibility).
    var macActionsLock = false
    /// v0.9: Web links is on, so the panel offers Send current browser tab.
    var browserTab = false

    func needed(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .localNetwork: true
        case .notifications: notifications || calls || codes || messages
        case .bluetooth: codes
        case .accessibility: remoteControl || macActionsLock
        case .automation: media && mediaPlayer != .off
        case .browserAutomation: browserTab
        }
    }
}

// MARK: - Mapping system answers (pure)

enum PermissionMapping {
    static func notifications(_ status: UNAuthorizationStatus) -> PermissionSystemState {
        switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    static func bluetooth(_ authorization: CBManagerAuthorization) -> PermissionSystemState {
        switch authorization {
        case .allowedAlways: .allowed
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    static func accessibility(trusted: Bool) -> PermissionSystemState { trusted ? .allowed : .notDetermined }

    /// `AEDeterminePermissionToAutomateTarget`: noErr, errAEEventNotPermitted (-1743),
    /// errAEEventWouldRequireUserConsent (-1744), procNotFound (-600, the player is not running).
    static func automation(_ status: OSStatus, lastKnown: PermissionSystemState?) -> PermissionSystemState {
        switch status {
        case noErr: .allowed
        case -1743: .denied
        case -1744: .notDetermined
        default: lastKnown ?? .notDetermined
        }
    }

    /// There is no API for Local Network: a browse that macOS refuses (kDNSServiceErr_PolicyDenied)
    /// means denied, finding any device means allowed, anything else is not known yet.
    static func localNetwork(browseDenied: Bool, reachedADevice: Bool) -> PermissionSystemState {
        if reachedADevice { return .allowed }
        if browseDenied { return .denied }
        return .notDetermined
    }
}

// MARK: - Live probes

/// Watches whether macOS refuses Bonjour browsing, the only Local Network signal there is.
@MainActor
final class LocalNetworkProbe {
    private var browser: NWBrowser?
    private(set) var denied = false
    var onChange: () -> Void = {}

    func start() {
        guard browser == nil else { return }
        let created = NWBrowser(for: .bonjour(type: BonjourDiscovery.serviceType, domain: "local."), using: NWParameters())
        created.stateUpdateHandler = { [weak self] state in
            let refused: Bool
            switch state {
            case let .waiting(error), let .failed(error): refused = localNetworkPermissionDenied(error)
            case .ready: refused = false
            default: return
            }
            Task { @MainActor in
                guard let self, self.denied != refused else { return }
                self.denied = refused
                self.onChange()
            }
        }
        created.start(queue: .main)
        browser = created
    }

    /// Asks again (the system prompt appears on the first browse after an install).
    func restart() {
        browser?.cancel()
        browser = nil
        start()
    }
}

/// Keeps a Core Bluetooth manager alive until macOS has answered the prompt.
@MainActor
final class BluetoothPermissionRequest: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private var done: (() -> Void)?

    func request(_ completion: @escaping () -> Void) {
        done = completion
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            guard CBManager.authorization != .notDetermined else { return }
            self.done?()
            self.done = nil
            self.manager = nil
        }
    }
}

enum AutomationProbe {
    /// Off the main thread: the call can wait on the target app.
    static func state(bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let status = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, strlen(pointer), &target)
        }
        guard status == noErr else { return OSStatus(status) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }
}
