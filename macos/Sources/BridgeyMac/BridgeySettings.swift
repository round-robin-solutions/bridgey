import AppKit
import Foundation
import ServiceManagement

enum BridgeyFeature: String, CaseIterable, Identifiable {
    case clipboard
    case files
    case notifications
    case battery
    case findDevice = "find_device"
    case ping
    case links
    case media
    case calls
    /// Draft, edition only until accepted upstream: this Mac accepts remote input from the phone.
    case remoteInput = "remote_input_draft1"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .files: "File transfer"
        case .notifications: "Android notifications"
        case .battery: "Battery status"
        case .findDevice: "Find Device"
        case .ping: "Ping"
        case .links: "Web links"
        case .media: "Media controls"
        case .calls: "Calls from Mac"
        case .remoteInput: L10n.text("settings.remoteControl", fallback: "Remote control")
        }
    }

    /// Off by default and granted per device: the global switch alone allows nothing.
    var needsDeviceGrant: Bool { self == .remoteInput }
}

func featureEnabledByLegacyPeer(_ feature: BridgeyFeature) -> Bool {
    ![.calls, .ping, .links, .media, .remoteInput].contains(feature)
}

/// Remote control: on for this Mac and explicitly granted to the device; a missing grant is off.
func effectiveGrantEnabled(globalEnabled: Bool, deviceGranted: Bool?) -> Bool {
    globalEnabled && deviceGranted == true
}

func effectiveFeatureEnabled(globalEnabled: Bool, deviceEnabled: Bool?) -> Bool {
    globalEnabled && deviceEnabled != false
}

func effectiveFeatureAvailable(localEnabled: Bool, remoteEnabled: Bool) -> Bool {
    localEnabled && remoteEnabled
}

final class ReceiveDirectoryAccess {
    let url: URL
    private let scoped: Bool

    init(url: URL, scoped: Bool) {
        self.url = url
        self.scoped = scoped
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

@MainActor
final class BridgeySettings: ObservableObject {
    @Published private(set) var deviceName: String
    @Published private(set) var globalFeatures: [BridgeyFeature: Bool]
    @Published private(set) var deviceFeatures: [String: [BridgeyFeature: Bool]]
    @Published private(set) var receiveFolderPath: String
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var notificationHistoryEnabled: Bool
    /// Settings > Privacy > Show previews in activity. On by default.
    @Published private(set) var showActivityPreviews: Bool
    /// Settings > General > Reduce motion: cross-fades only, like the system setting.
    @Published private(set) var reduceMotion: Bool
    /// Automatic clipboard for every device. On by default, like Universal Clipboard.
    @Published private(set) var autoClipboardEnabled: Bool
    /// Per-device Automatic clipboard; a missing entry follows the global switch.
    @Published private(set) var autoClipboardDevices: [String: Bool]
    /// Clipboard > Copy images and files (clipboard offers). On by default.
    @Published private(set) var clipboardFilesEnabled: Bool
    /// Clipboard > Send right away up to: bytes pushed right after a copy; 0 = always ask when pasting.
    @Published private(set) var clipboardEagerLimit: Int64

    private let defaults = UserDefaults.standard

    init() {
        let storedDefaults = UserDefaults.standard
        let systemName = Host.current().localizedName ?? "Mac"
        deviceName = storedDefaults.string(forKey: "settings.deviceName") ?? systemName
        hasCompletedOnboarding = storedDefaults.bool(forKey: "settings.onboarding.completed")
        notificationHistoryEnabled = storedDefaults.bool(forKey: "settings.notificationHistory.enabled")
        showActivityPreviews = storedDefaults.object(forKey: "settings.activity.previews") as? Bool ?? true
        reduceMotion = storedDefaults.bool(forKey: "settings.reduceMotion")
        autoClipboardEnabled = storedDefaults.object(forKey: "settings.autoClipboard.enabled") as? Bool ?? true
        var autoDevices: [String: Bool] = [:]
        for (key, value) in storedDefaults.dictionaryRepresentation() where key.hasPrefix(Self.autoClipboardDevicePrefix) {
            let id = String(key.dropFirst(Self.autoClipboardDevicePrefix.count))
            if !id.isEmpty, let enabled = value as? Bool { autoDevices[id] = enabled }
        }
        autoClipboardDevices = autoDevices
        clipboardFilesEnabled = storedDefaults.object(forKey: "settings.clipboardFiles.enabled") as? Bool ?? true
        clipboardEagerLimit = ClipboardEagerLimit(
            bytes: (storedDefaults.object(forKey: "settings.clipboardFiles.eagerLimit") as? NSNumber)?.int64Value ?? ClipboardEagerLimit.default.bytes
        ).bytes
        globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map {
            ($0, storedDefaults.object(forKey: "settings.global.\($0.rawValue)") as? Bool ?? ($0 != .media && $0 != .remoteInput))
        })
        var perDevice: [String: [BridgeyFeature: Bool]] = [:]
        for (key, value) in storedDefaults.dictionaryRepresentation() where key.hasPrefix("settings.device.") {
            guard let enabled = value as? Bool else { continue }
            for feature in BridgeyFeature.allCases where key.hasSuffix(".\(feature.rawValue)") {
                let id = key
                    .replacingOccurrences(of: "settings.device.", with: "")
                    .replacingOccurrences(of: ".\(feature.rawValue)", with: "")
                if !id.isEmpty { perDevice[id, default: [:]][feature] = enabled }
            }
        }
        deviceFeatures = perDevice
        receiveFolderPath = storedDefaults.string(forKey: "settings.receiveFolderPath")
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Bridgey", isDirectory: true).path
        refreshLoginItemStatus()
    }

    func setDeviceName(_ value: String) {
        let name = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return }
        defaults.set(name, forKey: "settings.deviceName")
        deviceName = name
    }

    func completeOnboarding() {
        defaults.set(true, forKey: "settings.onboarding.completed")
        hasCompletedOnboarding = true
    }

    func setGlobal(_ feature: BridgeyFeature, enabled: Bool) {
        defaults.set(enabled, forKey: "settings.global.\(feature.rawValue)")
        globalFeatures[feature] = enabled
    }

    func setNotificationHistoryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.notificationHistory.enabled")
        notificationHistoryEnabled = enabled
    }

    func setShowActivityPreviews(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.activity.previews")
        showActivityPreviews = enabled
    }

    func setReduceMotion(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.reduceMotion")
        reduceMotion = enabled
    }

    func setAutoClipboard(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.autoClipboard.enabled")
        autoClipboardEnabled = enabled
    }

    func setAutoClipboard(_ enabled: Bool, for deviceID: String) {
        defaults.set(enabled, forKey: Self.autoClipboardDevicePrefix + deviceID)
        autoClipboardDevices[deviceID] = enabled
    }

    /// The global switch and the device's own switch; the device follows the global one until changed.
    func isAutoClipboardEnabled(for deviceID: String?) -> Bool {
        effectiveFeatureEnabled(
            globalEnabled: autoClipboardEnabled,
            deviceEnabled: deviceID.flatMap { autoClipboardDevices[$0] }
        )
    }

    private static let autoClipboardDevicePrefix = "settings.autoClipboard.device."

    func setClipboardFilesEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.clipboardFiles.enabled")
        clipboardFilesEnabled = enabled
    }

    func setClipboardEagerLimit(_ limit: ClipboardEagerLimit) {
        defaults.set(NSNumber(value: limit.bytes), forKey: "settings.clipboardFiles.eagerLimit")
        clipboardEagerLimit = limit.bytes
    }

    func setForDevice(_ deviceID: String, feature: BridgeyFeature, enabled: Bool) {
        defaults.set(enabled, forKey: "settings.device.\(deviceID).\(feature.rawValue)")
        deviceFeatures[deviceID, default: [:]][feature] = enabled
    }

    func isEnabled(_ feature: BridgeyFeature, for deviceID: String?) -> Bool {
        if feature.needsDeviceGrant {
            return effectiveGrantEnabled(
                globalEnabled: globalFeatures[feature] == true,
                deviceGranted: deviceID.flatMap { deviceFeatures[$0]?[feature] }
            )
        }
        return effectiveFeatureEnabled(
            globalEnabled: globalFeatures[feature] != false,
            deviceEnabled: deviceID.flatMap { deviceFeatures[$0]?[feature] }
        )
    }

    func removeDevice(_ deviceID: String) {
        for feature in BridgeyFeature.allCases {
            defaults.removeObject(forKey: "settings.device.\(deviceID).\(feature.rawValue)")
        }
        deviceFeatures.removeValue(forKey: deviceID)
        defaults.removeObject(forKey: Self.autoClipboardDevicePrefix + deviceID)
        autoClipboardDevices.removeValue(forKey: deviceID)
    }

    func chooseReceiveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where Bridgey saves received files"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: receiveFolderPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: "settings.receiveFolderPath")
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            defaults.set(bookmark, forKey: "settings.receiveFolderBookmark")
        }
        receiveFolderPath = url.path
    }

    func receiveDirectoryAccess() -> ReceiveDirectoryAccess {
        if let data = defaults.data(forKey: "settings.receiveFolderBookmark") {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let scoped = url.startAccessingSecurityScopedResource()
                if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope) {
                    defaults.set(refreshed, forKey: "settings.receiveFolderBookmark")
                }
                return ReceiveDirectoryAccess(url: url, scoped: scoped)
            }
        }
        return ReceiveDirectoryAccess(url: URL(fileURLWithPath: receiveFolderPath, isDirectory: true), scoped: false)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemMessage = nil
        } catch {
            loginItemMessage = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    func refreshLoginItemStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
