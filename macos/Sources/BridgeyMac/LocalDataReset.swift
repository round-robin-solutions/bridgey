import Foundation

/*
 * Settings > Privacy > Reset Bridgey on this device. Names every place Bridgey keeps data on
 * this Mac and deletes exactly one choice's share of it. Pure apart from the file system and the
 * UserDefaults it is given, so tests run it on a temporary folder and an isolated suite. The
 * Keychain is never touched: since trust-v3.json the Mac keeps nothing there.
 */

enum ResetChoice: String, CaseIterable, Identifiable {
    case activity, caches, settings, everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: L10n.setup("reset.activity", fallback: "Activity and logs")
        case .caches: L10n.setup("reset.caches", fallback: "Downloaded models and caches")
        case .settings: L10n.setup("reset.settings", fallback: "Settings")
        case .everything: L10n.setup("reset.everything", fallback: "Everything, including pairings")
        }
    }

    var summary: String {
        switch self {
        case .activity: L10n.setup("reset.activity.summary", fallback: "Activity, notification history, diagnostics and the remote control log. Keeps settings and pairings.")
        case .caches: L10n.setup("reset.caches.summary", fallback: "The code model, clipboard cache and folder transfer journals. Keeps settings, pairings and history.")
        case .settings: L10n.setup("reset.settings.summary", fallback: "Every setting back to its default; setup runs again. Keeps pairings, history and caches.")
        case .everything: L10n.setup("reset.everything.summary", fallback: "All of the above, plus trusted devices and this Mac\u{2019}s identity. Phones need pairing again.")
        }
    }

    var symbol: String {
        switch self {
        case .activity: "list.bullet.rectangle"
        case .caches: "internaldrive"
        case .settings: "slider.horizontal.3"
        case .everything: "trash"
        }
    }

    var confirmTitle: String {
        switch self {
        case .activity: L10n.setup("reset.activity.confirm", fallback: "Delete activity and logs?")
        case .caches: L10n.setup("reset.caches.confirm", fallback: "Delete downloaded models and caches?")
        case .settings: L10n.setup("reset.settings.confirm", fallback: "Reset every setting?")
        case .everything: L10n.setup("reset.everything.confirm", fallback: "Reset Bridgey on this Mac?")
        }
    }

    /// The destructive button.
    var confirmButton: String {
        self == .everything
            ? L10n.setup("reset.action.everything", fallback: "Reset Bridgey")
            : L10n.setup("reset.action.delete", fallback: "Delete")
    }

    /// Shown afterwards.
    var doneMessage: String {
        switch self {
        case .activity: L10n.setup("reset.activity.done", fallback: "Activity and logs deleted")
        case .caches: L10n.setup("reset.caches.done", fallback: "Models and caches deleted")
        case .settings: L10n.setup("reset.settings.done", fallback: "Settings reset. Bridgey restarts and runs setup.")
        case .everything: L10n.setup("reset.everything.done", fallback: "Bridgey was reset. It restarts and runs setup.")
        }
    }

    /// Settings and Everything finish on the next launch, before anything has loaded, so nothing
    /// still in memory can write the old values back.
    var restartsApp: Bool { self == .settings || self == .everything }
}

/// One thing a choice deletes.
enum ResetItem: String, CaseIterable {
    case activityStream, notificationHistory, diagnostics, remoteAudit, transferHistory
    case codeModel, clipboardCache, folderJournals, otherCaches
    case settings
    case trustedDevices, identityKeys, reconnectAddresses, appRecords

    var title: String {
        switch self {
        case .activityStream: L10n.setup("reset.item.activity", fallback: "Activity stream")
        case .notificationHistory: L10n.setup("reset.item.history", fallback: "Notification history")
        case .diagnostics: L10n.setup("reset.item.diagnostics", fallback: "Diagnostics events and the log on this Mac")
        case .remoteAudit: L10n.setup("reset.item.remoteAudit", fallback: "Remote control audit log")
        case .transferHistory: L10n.setup("reset.item.transfers", fallback: "Transfer history")
        case .codeModel: L10n.setup("reset.item.codeModel", fallback: "Code model (Codes from messages, On this Mac)")
        case .clipboardCache: L10n.setup("reset.item.clipboardCache", fallback: "Clipboard cache")
        case .folderJournals: L10n.setup("reset.item.folderJournals", fallback: "Folder transfer journals (interrupted folders will not resume)")
        case .otherCaches: L10n.setup("reset.item.otherCaches", fallback: "Other caches (notification icons, phone thumbnails, optimised copies, downloaded updates)")
        case .settings: L10n.setup("reset.item.settings", fallback: "Every setting: feature switches, per-device settings, update channel, logging switches, folder destinations, send and drop options. Setup runs again.")
        case .trustedDevices: L10n.setup("reset.item.trusted", fallback: "Trusted devices")
        case .identityKeys: L10n.setup("reset.item.identity", fallback: "This Mac\u{2019}s identity keys")
        case .reconnectAddresses: L10n.setup("reset.item.addresses", fallback: "Reconnect addresses")
        case .appRecords: L10n.setup("reset.item.records", fallback: "Setup, What\u{2019}s new and update records, and the code model terms you accepted")
        }
    }
}

/// What a choice keeps, for the confirm dialog.
enum ResetKept: String, CaseIterable {
    case settings, pairings, history, caches

    var title: String {
        switch self {
        case .settings: L10n.setup("reset.kept.settings", fallback: "Settings")
        case .pairings: L10n.setup("reset.kept.pairings", fallback: "Paired devices")
        case .history: L10n.setup("reset.kept.history", fallback: "Activity and history")
        case .caches: L10n.setup("reset.kept.caches", fallback: "Downloaded models and caches")
        }
    }
}

/// Where Bridgey keeps things on this Mac.
struct LocalDataLocations {
    /// `~/Library/Application Support/in.roundrobin.bridgey/`
    let support: URL
    /// `~/Library/Caches/in.roundrobin.bridgey/` (notification icons, Sparkle downloads, URL cache, phone
    /// thumbnails and listings in `PhoneFiles`, optimised send copies in `SendOptimized`)
    let caches: URL

    static var standard: LocalDataLocations {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches", isDirectory: true)
        return LocalDataLocations(
            support: support.appendingPathComponent(Edition.supportFolderName, isDirectory: true),
            caches: caches.appendingPathComponent(Edition.supportFolderName, isDirectory: true)
        )
    }

    func files(_ item: ResetItem) -> [URL] {
        switch item {
        case .activityStream: [support.appendingPathComponent(ActivityStore.fileName)]
        case .notificationHistory: [support.appendingPathComponent("notification-history.json")]
        case .diagnostics: [support.appendingPathComponent("diagnostics.json")]
        case .remoteAudit: [support.appendingPathComponent(RemoteControlAuditStore.fileName)]
        // The History window's file (Files 2.0); the live reset also clears the rows in memory.
        case .transferHistory: [support.appendingPathComponent(TransferHistoryStore.fileName)]
        case .codeModel: [support.appendingPathComponent("Models", isDirectory: true)]
        case .clipboardCache: [support.appendingPathComponent("ClipboardCache", isDirectory: true)]
        // Folders this Mac sends (FolderTransfers) and receives from phones (FolderReceives, Files 2.0).
        case .folderJournals: [support.appendingPathComponent("FolderTransfers", isDirectory: true),
                               support.appendingPathComponent("FolderReceives", isDirectory: true)]
        case .otherCaches: [caches]
        case .settings: []
        // The identity key and the trusted phones share trust-v3.json.
        case .trustedDevices, .identityKeys: [support.appendingPathComponent(MacPairingStore.fileName)]
        case .reconnectAddresses, .appRecords: []
        }
    }
}

struct ResetReport: Equatable {
    var removedFiles: [URL] = []
    var removedKeys: [String] = []
}

struct LocalDataReset {
    let locations: LocalDataLocations
    let defaults: UserDefaults

    init(locations: LocalDataLocations = .standard, defaults: UserDefaults = .standard) {
        self.locations = locations
        self.defaults = defaults
    }

    static func items(_ choice: ResetChoice) -> [ResetItem] {
        let activity: [ResetItem] = [.activityStream, .notificationHistory, .diagnostics, .remoteAudit, .transferHistory]
        let caches: [ResetItem] = [.codeModel, .clipboardCache, .folderJournals, .otherCaches]
        switch choice {
        case .activity: return activity
        case .caches: return caches
        case .settings: return [.settings]
        case .everything: return activity + caches + [.settings, .trustedDevices, .identityKeys, .reconnectAddresses, .appRecords]
        }
    }

    /// The Deletes list in the confirm dialog. Everything names the three smaller choices
    /// instead of repeating their items, so the dialog fits a small window.
    static func confirmLines(_ choice: ResetChoice) -> [String] {
        guard choice == .everything else { return items(choice).map(\.title) }
        return [ResetChoice.activity.title, ResetChoice.caches.title, ResetChoice.settings.title]
            + [ResetItem.trustedDevices, .identityKeys, .reconnectAddresses, .appRecords].map(\.title)
    }

    static func kept(_ choice: ResetChoice) -> [ResetKept] {
        switch choice {
        case .activity: [.settings, .pairings]
        case .caches: [.settings, .pairings, .history]
        case .settings: [.pairings, .history, .caches]
        case .everything: []
        }
    }

    // MARK: UserDefaults

    /// Settings: every `settings.` key but the two records below, the update channel and
    /// Sparkle's own choices, Media, shortcuts, folder destinations, setup progress, and (Files 2.0) the
    /// send and menu-bar drop options and what the Phone files window remembers.
    static let settingsPrefixes = ["settings.", "media.", "shortcuts.", "folders.lastDestination.", "setup.", "send.", "phoneFiles."]
    static let settingsKeys = [UpdateChannel.defaultsKey, "SUEnableAutomaticChecks", "SUAutomaticallyUpdate",
                               "SUScheduledCheckInterval", "SUSkippedVersion", "SUSkippedMajorVersion"]
    /// Not settings: the relay's random install ID (identity) and the record of accepted model terms.
    static let notSettingsKeys = ["settings.codes.installId", "settings.codes.model.acceptance"]
    static let identityKeys = ["deviceID", "settings.codes.installId"]
    /// Upstream's pre-file trust records, imported once by MacTrustRegistry.
    static let trustKeys = ["trustedDeviceIDs"]
    static let trustPrefixes = ["trusted."]
    static let addressPrefixes = ["reconnect."]
    static let recordKeys = ["settings.codes.model.acceptance", "legacyPreferencesMigrated", pendingKey]
    static let recordPrefixes = ["whatsNew.", "SU"]

    func keys(_ item: ResetItem) -> [String] {
        let stored = Array(defaults.dictionaryRepresentation().keys)
        func matching(_ exact: [String], _ prefixes: [String], except: [String] = []) -> [String] {
            stored.filter { key in
                !except.contains(key) && (exact.contains(key) || prefixes.contains { key.hasPrefix($0) })
            }.sorted()
        }
        switch item {
        case .settings: return matching(Self.settingsKeys, Self.settingsPrefixes, except: Self.notSettingsKeys)
        case .trustedDevices: return matching(Self.trustKeys, Self.trustPrefixes)
        case .identityKeys: return matching(Self.identityKeys, [])
        case .reconnectAddresses: return matching([], Self.addressPrefixes)
        case .appRecords: return matching(Self.recordKeys, Self.recordPrefixes)
        default: return []
        }
    }

    // MARK: Deleting

    /// Deletes exactly `choice`'s items. Disconnect sessions first for Everything (the caller does).
    @discardableResult
    func perform(_ choice: ResetChoice) -> ResetReport {
        var report = ResetReport()
        let manager = FileManager.default
        for item in Self.items(choice) {
            for url in locations.files(item) where manager.fileExists(atPath: url.path) {
                if (try? manager.removeItem(at: url)) != nil { report.removedFiles.append(url) }
            }
            for key in keys(item) {
                defaults.removeObject(forKey: key)
                report.removedKeys.append(key)
            }
        }
        if choice == .everything {
            // Anything else under the support folder (a newer feature's store) goes too.
            if manager.fileExists(atPath: locations.support.path), (try? manager.removeItem(at: locations.support)) != nil {
                report.removedFiles.append(locations.support)
            }
        }
        if choice == .settings || choice == .everything {
            SetupStore(defaults: defaults).pending = true
        }
        return report
    }

    // MARK: Finishing on the next launch

    static let pendingKey = "reset.pending"

    /// Settings and Everything: remembered, then done again first thing on the next launch.
    func schedule(_ choice: ResetChoice) {
        defaults.set(choice.rawValue, forKey: Self.pendingKey)
    }

    /// Call at launch before any store loads. Returns the choice it finished, if any.
    @discardableResult
    func performPending() -> ResetChoice? {
        guard let raw = defaults.string(forKey: Self.pendingKey), let choice = ResetChoice(rawValue: raw) else { return nil }
        defaults.removeObject(forKey: Self.pendingKey)
        perform(choice)
        return choice
    }
}
