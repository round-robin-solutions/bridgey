import Foundation
import XCTest
@testable import BridgeyMac

/// Every choice on a temporary support and caches folder and an isolated UserDefaults suite.
/// Never the real user's folders, never UserDefaults.standard, never the Keychain.
final class LocalDataResetTests: XCTestCase {
    private var root: URL!
    private var locations: LocalDataLocations!
    private var outside: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let activityFiles = ["activity-stream.json", "notification-history.json", "diagnostics.json", "remote-control-audit.json",
                                 "transfer-history.json", "mac-actions-audit.json"]
    private let cacheFolders = ["Models", "ClipboardCache", "FolderTransfers", "FolderReceives"]
    /// Files 2.0 user content: only Everything removes the Tray (bookmarks and dropped images).
    private let trayFolder = "Tray"
    /// Text messages kept on this Mac: Activity and logs removes it with the other history.
    private let messagesFolder = "Messages"

    private let settingsKeys = [
        "settings.global.clipboard", "settings.device.11111111-1111-1111-1111-111111111111.files",
        "settings.autoClipboard.device.11111111-1111-1111-1111-111111111111", "settings.logging.calls",
        "settings.receiveFolderPath", "settings.receiveFolderBookmark", "settings.onboarding.completed", "settings.codes.enabled",
        "updates.channel", "SUEnableAutomaticChecks", "media.player", "media.pauseForCalls", "shortcuts.shift", "shortcuts.clipboard",
        "folders.lastDestination.11111111-1111-1111-1111-111111111111", "setup.completedVersion", "setup.permissions.explained",
        // Files 2.0
        "settings.folders.receiveMode", "settings.folders.conflict", "settings.files.tagReceived",
        "send.menuBarDrop", "send.optimization.v1", "send.lastDevice",
        "phoneFiles.last.phone", "phoneFiles.sort", "phoneFiles.last.path.11111111-1111-1111-1111-111111111111",
        // v0.9 automation
        "settings.global.mac_actions_draft1", "settings.device.11111111-1111-1111-1111-111111111111.mac_actions_draft1",
        "settings.macActions.config", "settings.links.openRightAway", "settings.batteryAlerts.11111111-1111-1111-1111-111111111111.low",
        "settings.batteryAlerts.11111111-1111-1111-1111-111111111111.full", "settings.focusSync", "settings.camera.copyToClipboard",
        // Text messages
        "settings.sms.enabled", "settings.sms.keepOnMac",
    ]
    private let identityKeys = ["deviceID", "settings.codes.installId"]
    private let trustKeys = ["trustedDeviceIDs", "trusted.11111111-1111-1111-1111-111111111111.name"]
    private let addressKeys = ["reconnect.addressBook.v1"]
    private let recordKeys = ["settings.codes.model.acceptance", "whatsNew.lastBuild", "whatsNew.offeredNotes", "SULastCheckTime", "legacyPreferencesMigrated"]
    /// Not Bridgey's to delete in any choice.
    private let foreignKeys = ["NSWindow Frame BridgeySettingsWindowB", "com.example.other"]

    private var allKeys: [String] { settingsKeys + identityKeys + trustKeys + addressKeys + recordKeys + foreignKeys }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-reset-\(UUID().uuidString)", isDirectory: true)
        locations = LocalDataLocations(support: root.appendingPathComponent("Support/in.roundrobin.bridgey", isDirectory: true),
                                       caches: root.appendingPathComponent("Caches/in.roundrobin.bridgey", isDirectory: true))
        outside = root.appendingPathComponent("Support/someone-else/keep.json")
        let manager = FileManager.default
        try manager.createDirectory(at: locations.support, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        for name in activityFiles + [MacPairingStore.fileName, "unknown-future-store.json"] {
            try Data("{}".utf8).write(to: locations.support.appendingPathComponent(name))
        }
        for folder in cacheFolders + [trayFolder, messagesFolder] {
            let url = locations.support.appendingPathComponent(folder, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("item"))
        }
        for folder in ["NotificationIcons", "org.sparkle-project.Sparkle", "perf-test", "PhoneFiles", "SendOptimized"] {
            let url = locations.caches.appendingPathComponent(folder, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("item"))
        }
        try Data("{}".utf8).write(to: outside)

        suiteName = "bridgey-reset-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        for key in allKeys { defaults.set("value", forKey: key) }
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private var reset: LocalDataReset { LocalDataReset(locations: locations, defaults: defaults) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func support(_ name: String) -> URL { locations.support.appendingPathComponent(name) }
    private func present(_ keys: [String]) -> [String] { keys.filter { defaults.object(forKey: $0) != nil } }

    private func assertFiles(gone: [URL], kept: [URL], file: StaticString = #filePath, line: UInt = #line) {
        for url in gone { XCTAssertFalse(exists(url), "\(url.lastPathComponent) should be deleted", file: file, line: line) }
        for url in kept { XCTAssertTrue(exists(url), "\(url.lastPathComponent) should be kept", file: file, line: line) }
    }

    private func assertKeys(gone: [String], kept: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(present(gone), [], "deleted keys", file: file, line: line)
        XCTAssertEqual(present(kept), kept, "kept keys", file: file, line: line)
    }

    func testActivityAndLogsDeletesOnlyItsFiles() {
        let report = reset.perform(.activity)
        assertFiles(gone: activityFiles.map(support) + [support(messagesFolder)],
                    kept: cacheFolders.map(support) + [support(MacPairingStore.fileName), support("unknown-future-store.json"), support(trayFolder),
                           locations.caches, outside])
        assertKeys(gone: [], kept: allKeys)
        XCTAssertEqual(Set(report.removedFiles.map(\.lastPathComponent)), Set(activityFiles + [messagesFolder]))
        XCTAssertTrue(report.removedKeys.isEmpty)
    }

    func testModelsAndCachesDeletesOnlyCaches() {
        reset.perform(.caches)
        assertFiles(gone: cacheFolders.map(support) + [locations.caches],
                    kept: activityFiles.map(support) + [support(MacPairingStore.fileName), support("unknown-future-store.json"), support(trayFolder),
                           support(messagesFolder), outside])
        assertKeys(gone: [], kept: allKeys)
    }

    func testSettingsResetsEverySettingAndKeepsPairingsHistoryAndCaches() {
        reset.perform(.settings)
        assertFiles(gone: [], kept: activityFiles.map(support) + cacheFolders.map(support) + [support(MacPairingStore.fileName), support(trayFolder), support(messagesFolder),
                                    locations.caches, outside])
        assertKeys(gone: settingsKeys, kept: identityKeys + trustKeys + addressKeys + recordKeys + foreignKeys)
        XCTAssertTrue(SetupStore(defaults: defaults).pending, "setup runs again next launch")
        XCTAssertEqual(SetupLaunch.evaluate(SetupStore(defaults: defaults), trustFileExists: true), .runSetup)
    }

    func testEverythingDeletesAllOfBridgeysDataButNothingElse() {
        reset.perform(.everything)
        assertFiles(gone: [locations.support, locations.caches], kept: [outside])
        assertKeys(gone: settingsKeys + identityKeys + trustKeys + addressKeys + recordKeys, kept: foreignKeys)
        XCTAssertTrue(SetupStore(defaults: defaults).pending, "back to first-run setup")
    }

    func testItemsAndKeptListsMatchTheChoices() {
        XCTAssertEqual(LocalDataReset.items(.activity), [.activityStream, .notificationHistory, .diagnostics, .remoteAudit, .transferHistory, .macActionsAudit, .textMessages])
        XCTAssertEqual(LocalDataReset.items(.caches), [.codeModel, .clipboardCache, .folderJournals, .otherCaches])
        XCTAssertEqual(LocalDataReset.items(.settings), [.settings])
        let everything = Set(LocalDataReset.items(.everything))
        for choice in [ResetChoice.activity, .caches, .settings] { XCTAssertTrue(everything.isSuperset(of: LocalDataReset.items(choice))) }
        XCTAssertTrue(everything.isSuperset(of: [.trustedDevices, .identityKeys, .reconnectAddresses]))
        XCTAssertEqual(LocalDataReset.kept(.activity), [.settings, .pairings])
        XCTAssertEqual(LocalDataReset.kept(.caches), [.settings, .pairings, .history])
        XCTAssertEqual(LocalDataReset.kept(.settings), [.pairings, .history, .caches])
        XCTAssertEqual(LocalDataReset.kept(.everything), [])
        XCTAssertEqual(LocalDataReset.confirmLines(.activity), LocalDataReset.items(.activity).map(\.title))
        XCTAssertEqual(LocalDataReset.confirmLines(.everything).count, 7, "short enough for the dialog")
        XCTAssertEqual(LocalDataReset.confirmLines(.everything).first, ResetChoice.activity.title)
        XCTAssertEqual(ResetChoice.everything.confirmButton, "Reset Bridgey")
        XCTAssertEqual(ResetChoice.activity.confirmButton, "Delete")
        XCTAssertEqual(ResetChoice.activity.doneMessage, "Activity and logs deleted")
    }

    func testStandardLocationsAreBridgeysOwnFolders() {
        let standard = LocalDataLocations.standard
        XCTAssertEqual(standard.support.lastPathComponent, "in.roundrobin.bridgey")
        XCTAssertEqual(standard.support.deletingLastPathComponent().lastPathComponent, "Application Support")
        XCTAssertEqual(standard.caches.lastPathComponent, "in.roundrobin.bridgey")
        XCTAssertEqual(standard.caches.deletingLastPathComponent().lastPathComponent, "Caches")
        XCTAssertEqual(standard.files(.trustedDevices), [standard.support.appendingPathComponent("trust-v3.json")])
    }

    func testScheduledResetFinishesOnTheNextLaunchOnce() {
        reset.schedule(.settings)
        XCTAssertEqual(defaults.string(forKey: LocalDataReset.pendingKey), "settings")
        // Something wrote a setting back before the app quit.
        defaults.set(false, forKey: "settings.global.clipboard")
        XCTAssertEqual(reset.performPending(), .settings)
        XCTAssertNil(defaults.object(forKey: "settings.global.clipboard"))
        XCTAssertNil(defaults.object(forKey: LocalDataReset.pendingKey))
        XCTAssertNil(reset.performPending())
    }
}
