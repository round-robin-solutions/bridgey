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
    /// Draft, edition only: a phone you allow may lock, sleep, change the volume, open listed apps
    /// and run listed Shortcuts (docs/protocol.md, "Mac actions"). Off by default, granted per device.
    case macActions = "mac_actions_draft1"

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
        case .macActions: L10n.text("settings.macActions", fallback: "Mac actions")
        }
    }

    /// Off by default and granted per device: the global switch alone allows nothing.
    var needsDeviceGrant: Bool { self == .remoteInput || self == .macActions }
}

func featureEnabledByLegacyPeer(_ feature: BridgeyFeature) -> Bool {
    ![.calls, .ping, .links, .media, .remoteInput, .macActions].contains(feature)
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
    /// Settings > Privacy > Logging: what reaches the unified log and exported diagnostics. Per Mac.
    @Published private(set) var logging: LoggingPolicy
    /// Settings > Calls > Ring for incoming calls: a soft ring repeats until the call is answered,
    /// declined, hidden or ends. On by default.
    @Published private(set) var ringForIncomingCalls: Bool
    /// Settings > Calls > When another app asks to call (tel: links, the Call with Bridgey Service).
    /// Ask every time by default; calls started inside Bridgey are not affected.
    @Published private(set) var otherAppCallPolicy: MacOtherAppCallPolicy
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
    /// Files > Include hidden files when sending folders (dotfiles that are not system files). Off by default.
    @Published private(set) var folderIncludeHidden: Bool
    /// Files > Include system files when sending folders (.DS_Store, ._*, Thumbs.db, ...). Off by default.
    @Published private(set) var folderIncludeSystem: Bool
    /// Files > Folders sent to this Mac (phone to Mac): Received files (default) or ask each time.
    @Published private(set) var folderReceiveMode: MacFolderReceiveMode
    /// Files > When a folder already exists (folders sent to this Mac). Ask by default.
    @Published private(set) var folderConflictPolicy: MacFolderConflictPolicy
    /// Files > Tag received files in Finder with "Bridgey". Off by default; "Where from" is always set.
    @Published private(set) var tagReceivedFiles: Bool
    /// Notifications > Codes from messages: read SMS text that looks like it has a code and show the
    /// code with a Copy button. Off by default.
    @Published private(set) var codesEnabled: Bool
    /// Notifications > Codes from messages > Read codes: on this Mac (default) or the cloud relay.
    @Published private(set) var codesEngine: CodeEngine
    /// Every acceptance of the on-device model's terms, oldest first, with its date and model version.
    @Published private(set) var codeModelAcceptances: [CodeModelAcceptance]
    /// Notifications > Codes from messages > Copy automatically. Off by default.
    @Published private(set) var codesAutoCopy: Bool
    /// Media and actions > Open links from phones right away (links_open_draft1). Off by default:
    /// a link waits for Open on this Mac.
    @Published private(set) var openLinksRightAway: Bool
    /// Settings > Text messages (draft sms_draft1): the phone's conversations in the Messages window,
    /// and Reply on its text message notifications. Off by default.
    @Published private(set) var smsEnabled: Bool
    /// Settings > Text messages > Keep conversations on this Mac: the cache is written (0600) so
    /// conversations open instantly. On by default; off keeps them in memory only.
    @Published private(set) var smsKeepOnMac: Bool

    private let defaults = UserDefaults.standard

    init() {
        let storedDefaults = UserDefaults.standard
        let systemName = Host.current().localizedName ?? "Mac"
        deviceName = storedDefaults.string(forKey: "settings.deviceName") ?? systemName
        hasCompletedOnboarding = storedDefaults.bool(forKey: "settings.onboarding.completed")
        notificationHistoryEnabled = storedDefaults.bool(forKey: "settings.notificationHistory.enabled")
        showActivityPreviews = storedDefaults.object(forKey: "settings.activity.previews") as? Bool ?? true
        reduceMotion = storedDefaults.bool(forKey: "settings.reduceMotion")
        ringForIncomingCalls = storedDefaults.object(forKey: "settings.calls.ring") as? Bool ?? true
        otherAppCallPolicy = MacOtherAppCallPolicy(rawValue: storedDefaults.string(forKey: "settings.calls.otherApps") ?? "") ?? .ask
        let logging = loggingPolicy { key, fallback in storedDefaults.object(forKey: key) as? Bool ?? fallback }
        self.logging = logging
        BridgeyLog.policy = logging
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
        folderIncludeHidden = storedDefaults.bool(forKey: "settings.folders.includeHidden")
        folderIncludeSystem = storedDefaults.bool(forKey: "settings.folders.includeSystem")
        folderReceiveMode = MacFolderReceiveMode(rawValue: storedDefaults.string(forKey: "settings.folders.receiveMode") ?? "") ?? .fixed
        folderConflictPolicy = MacFolderConflictPolicy(rawValue: storedDefaults.string(forKey: "settings.folders.conflict") ?? "") ?? .ask
        tagReceivedFiles = storedDefaults.bool(forKey: "settings.files.tagReceived")
        let codesOn = storedDefaults.bool(forKey: "settings.codes.enabled")
        codesEnabled = codesOn
        codesAutoCopy = storedDefaults.bool(forKey: "settings.codes.autoCopy")
        openLinksRightAway = storedDefaults.bool(forKey: "settings.links.openRightAway")
        smsEnabled = storedDefaults.bool(forKey: "settings.sms.enabled")
        smsKeepOnMac = storedDefaults.object(forKey: "settings.sms.keepOnMac") as? Bool ?? true
        let engine = CodeEngine.stored(storedDefaults.string(forKey: "settings.codes.engine"), codesWereEnabled: codesOn)
        // Settle the choice once, so turning codes on later never reads as an old cloud opt-in.
        storedDefaults.set(engine.rawValue, forKey: "settings.codes.engine")
        codesEngine = engine
        codeModelAcceptances = CodeModelAcceptance.decode(storedDefaults.data(forKey: "settings.codes.model.acceptance"))
        // A switch never set takes this install's defaults (off until chosen on fresh installs).
        globalFeatures = DefaultsGeneration.globalFeatures(storedDefaults)
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

    func setCodesEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.codes.enabled")
        codesEnabled = enabled
    }

    func setSmsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.sms.enabled")
        smsEnabled = enabled
    }

    func setSmsKeepOnMac(_ keep: Bool) {
        defaults.set(keep, forKey: "settings.sms.keepOnMac")
        smsKeepOnMac = keep
    }

    func setCodesAutoCopy(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.codes.autoCopy")
        codesAutoCopy = enabled
    }

    func setOpenLinksRightAway(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.links.openRightAway")
        openLinksRightAway = enabled
    }

    func setCodesEngine(_ engine: CodeEngine) {
        defaults.set(engine.rawValue, forKey: "settings.codes.engine")
        codesEngine = engine
    }

    /// The newest acceptance, if it covers `manifest`'s terms.
    func codeModelAcceptance(for manifest: CodeModelManifest) -> CodeModelAcceptance? {
        codeModelAcceptances.last.flatMap { $0.covers(manifest) ? $0 : nil }
    }

    /// Records that the user accepted the Gemma Terms of Use, the Prohibited Use Policy and Bridgey's
    /// model terms for `manifest`, on `date`.
    func recordCodeModelAcceptance(_ manifest: CodeModelManifest, at date: Date = Date()) {
        // Whole seconds, as the ISO 8601 record keeps them.
        let record = CodeModelAcceptance(acceptedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)), modelVersion: manifest.version, termsVersion: manifest.termsVersion)
        codeModelAcceptances.append(record)
        if let data = CodeModelAcceptance.encode(codeModelAcceptances) { defaults.set(data, forKey: "settings.codes.model.acceptance") }
    }

    /// The relay's rate-limit key for this Mac: random, made on first use, never tied to the user.
    var codesInstallID: String {
        if let stored = defaults.string(forKey: "settings.codes.installId"), CodeRelay.isInstallID(stored) { return stored }
        let created = CodeRelay.newInstallID()
        defaults.set(created, forKey: "settings.codes.installId")
        return created
    }

    func setShowActivityPreviews(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.activity.previews")
        showActivityPreviews = enabled
    }

    func setLogging(_ policy: LoggingPolicy) {
        for (key, value) in loggingPreferenceValues(policy) { defaults.set(value, forKey: key) }
        BridgeyLog.policy = policy
        logging = policy
    }

    func setRingForIncomingCalls(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.calls.ring")
        ringForIncomingCalls = enabled
    }

    func setOtherAppCallPolicy(_ policy: MacOtherAppCallPolicy) {
        defaults.set(policy.rawValue, forKey: "settings.calls.otherApps")
        otherAppCallPolicy = policy
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

    func setFolderIncludeHidden(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.folders.includeHidden")
        folderIncludeHidden = enabled
    }

    func setFolderIncludeSystem(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.folders.includeSystem")
        folderIncludeSystem = enabled
    }

    func setFolderReceiveMode(_ mode: MacFolderReceiveMode) {
        defaults.set(mode.rawValue, forKey: "settings.folders.receiveMode")
        folderReceiveMode = mode
    }

    func setFolderConflictPolicy(_ policy: MacFolderConflictPolicy) {
        defaults.set(policy.rawValue, forKey: "settings.folders.conflict")
        folderConflictPolicy = policy
    }

    func setTagReceivedFiles(_ enabled: Bool) {
        defaults.set(enabled, forKey: "settings.files.tagReceived")
        tagReceivedFiles = enabled
    }

    /// The defaults for the next folder send.
    var folderScanOptions: FolderScanOptions {
        FolderScanOptions(includeHidden: folderIncludeHidden, includeSystem: folderIncludeSystem)
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

/// UserDefaults keys of `LoggingPolicy`, with their values.
func loggingPreferenceValues(_ policy: LoggingPolicy) -> [String: Bool] {
    [
        "settings.logging.connection": policy.connection,
        "settings.logging.calls": policy.calls,
        "settings.logging.calls.numbers": policy.callNumbers,
        "settings.logging.notifications": policy.notifications,
        "settings.logging.notifications.content": policy.notificationContent,
        "settings.logging.clipboard": policy.clipboard,
        "settings.logging.clipboard.previews": policy.clipboardPreviews,
        "settings.logging.files.names": policy.fileNames,
        "settings.logging.remoteControl": policy.remoteControl,
    ]
}

func loggingPolicy(read: (String, Bool) -> Bool) -> LoggingPolicy {
    let defaults = loggingPreferenceValues(LoggingPolicy())
    func value(_ key: String) -> Bool { read(key, defaults[key]!) }
    return LoggingPolicy(
        connection: value("settings.logging.connection"),
        calls: value("settings.logging.calls"),
        callNumbers: value("settings.logging.calls.numbers"),
        notifications: value("settings.logging.notifications"),
        notificationContent: value("settings.logging.notifications.content"),
        clipboard: value("settings.logging.clipboard"),
        clipboardPreviews: value("settings.logging.clipboard.previews"),
        fileNames: value("settings.logging.files.names"),
        remoteControl: value("settings.logging.remoteControl")
    )
}


/// Files > Folders sent to this Mac. A Mac serves no places, so "Choose on the phone" is not offered.
enum MacFolderReceiveMode: String, CaseIterable {
    /// Always save to the Received files folder (protocol `fixed`).
    case fixed
    /// Ask on this Mac each time, with a Save panel (protocol `receiver_asks`).
    case ask
}

/// Files > When a folder already exists, for folders sent to this Mac (protocol 3.3).
enum MacFolderConflictPolicy: String, CaseIterable {
    case ask, merge, replace
    case newFolder = "new_folder"
}
