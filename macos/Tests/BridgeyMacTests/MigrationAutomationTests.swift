import Foundation
import XCTest
@testable import BridgeyMac

/// v0.9 automation stores on the Mac: the Mac actions switch, grants and list, Open links right away, battery
/// alert thresholds, Focus sync, the camera clipboard option and the Mac actions log. The fixtures in
/// `protocol/test-vectors/migrations/macos` are this build's formats, pinned so a later build keeps reading
/// them (docs/upgrade-policy.md). Settings go through `UserDefaults.standard` as in MigrationSettingsTests.
final class MigrationAutomationTests: XCTestCase {
    private typealias F = MigrationFixtures
    private static var runnerDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }
    private let shortcutHandle = "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b"

    private var directory: URL!
    private var savedSettings: [String: Any] = [:]

    override func setUpWithError() throws {
        directory = try F.temporaryDirectory("automation")
        savedSettings = (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).filter { $0.key.hasPrefix("settings.") }
        clearStandardSettings()
    }

    override func tearDownWithError() throws {
        clearStandardSettings()
        for (key, value) in savedSettings { UserDefaults.standard.set(value, forKey: key) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func clearStandardSettings() {
        for key in (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).keys where key.hasPrefix("settings.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Only the `settings.*` keys: the automation stores all live there.
    private func install(_ fixture: String) throws {
        clearStandardSettings()
        for (key, value) in try F.defaults(fixture) where key.hasPrefix("settings.") { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: Settings (UserDefaults)

    @MainActor
    func testAutomationSettingsLoad() throws {
        try install("settings/defaults.automation.plist")
        let settings = BridgeySettings()
        XCTAssertEqual(settings.deviceName, "Test Mac")
        XCTAssertEqual(settings.globalFeatures[.macActions], true)
        XCTAssertEqual(settings.deviceFeatures[F.phoneA]?[.macActions], true, "the grant for phone A")
        XCTAssertNil(settings.deviceFeatures[F.phoneB]?[.macActions], "no grant for phone B")
        XCTAssertTrue(settings.openLinksRightAway)

        // A switch a newer build added (brightness), an app without a name, a bad bundle id and a bad Shortcut
        // handle are each dropped on their own; the rest of the list stays.
        let config = MacActionsConfigStore(defaults: .standard).load()
        XCTAssertEqual(config.switches, [.lock: true, .sleep: false, .volume: true])
        XCTAssertEqual(config.apps, [AllowedApp(bundleID: "com.apple.Safari", name: "Safari")])
        XCTAssertEqual(config.shortcuts, [AllowedShortcut(id: shortcutHandle, name: "Morning routine")])

        let alerts = BatteryAlertSettings(defaults: .standard)
        XCTAssertEqual(alerts.thresholds(for: F.phoneA), BatteryAlertThresholds(low: 15, full: 80))
        // 7% is not a choice: the default low; 0 is "off" and stays.
        XCTAssertEqual(alerts.thresholds(for: F.phoneB), BatteryAlertThresholds(low: 20, full: 0))

        XCTAssertEqual(FocusSync(defaults: .standard).settings,
                       FocusSyncSettings(share: true, follow: true, onShortcut: "Focus On", offShortcut: "Focus Off"))
        XCTAssertTrue(PhoneCamera(defaults: .standard).copyToClipboard)

        // Written back by this build, the config keeps its format.
        MacActionsConfigStore(defaults: .standard).save(config)
        XCTAssertEqual(MacActionsConfigStore(defaults: .standard).load(), config)
    }

    @MainActor
    func testSnapshotsFromBeforeAutomationGetItsDefaults() throws {
        for fixture in ["settings/defaults.beta.13.plist", "settings/defaults.0.8.0-rr.1.plist"] {
            try install(fixture)
            let settings = BridgeySettings()
            XCTAssertEqual(settings.globalFeatures[.macActions], false, "\(fixture): Mac actions is off until turned on")
            XCTAssertFalse(settings.openLinksRightAway, fixture)
            XCTAssertEqual(MacActionsConfigStore(defaults: .standard).load(), MacActionsConfig(), fixture)
            XCTAssertEqual(BatteryAlertSettings(defaults: .standard).thresholds(for: F.phoneA), .default, fixture)
            XCTAssertEqual(FocusSync(defaults: .standard).settings, FocusSyncSettings(), fixture)
            XCTAssertFalse(PhoneCamera(defaults: .standard).copyToClipboard, fixture)
        }
    }

    @MainActor
    func testAMacActionsConfigThatIsNotJSONStartsEmpty() throws {
        clearStandardSettings()
        UserDefaults.standard.set(Data("not json".utf8), forKey: "settings.macActions.config")
        XCTAssertEqual(MacActionsConfigStore(defaults: .standard).load(), MacActionsConfig())
        UserDefaults.standard.set("a string", forKey: "settings.focusSync")
        XCTAssertEqual(FocusSync(defaults: .standard).settings, FocusSyncSettings())
    }

    // MARK: Mac actions log (mac-actions-audit.json)

    private func installAudit(_ fixture: String) throws -> MacActionsAuditStore {
        let url = directory.appendingPathComponent("mac-actions-audit.json")
        try FileManager.default.copyItem(at: F.url("mac-actions/\(fixture)"), to: url)
        return MacActionsAuditStore(fileURL: url)
    }

    func testMacActionsLogLoads() throws {
        let store = try installAudit("mac-actions-audit.automation.json")
        let entries = store.load(now: F.base.addingTimeInterval(3_600))
        XCTAssertEqual(entries.map(\.action), ["lock", "app:com.apple.Safari", "shortcut:\(shortcutHandle)"])
        XCTAssertEqual(entries.map(\.outcome), ["done", "not_allowed", "rate_limited"])
        XCTAssertEqual(entries.first?.deviceID, F.phoneA)
        XCTAssertEqual(entries.first?.at, F.base)
        XCTAssertTrue(entries.first?.accepted == true)
    }

    func testMacActionsLogEntriesThisBuildCannotReadAreDroppedOneByOne() throws {
        let store = try installAudit("mac-actions-audit.unknown-entries.json")
        let entries = store.load(now: F.base.addingTimeInterval(3_600))
        XCTAssertEqual(entries.count, 3)
        // The file is rewritten without them, and reads the same again.
        XCTAssertEqual(store.load(now: F.base.addingTimeInterval(3_600)), entries)
    }

    func testMacActionsLogPastThirtyDaysIsPruned() throws {
        let store = try installAudit("mac-actions-audit.automation.json")
        XCTAssertEqual(store.load(now: F.base.addingTimeInterval(31 * 24 * 3_600)), [])
    }

    // MARK: Names

    func testAutomationStorageNamesArePinned() {
        XCTAssertEqual(MacActionsAuditStore.fileName, "mac-actions-audit.json")
        XCTAssertEqual(MacActionsAuditStore.defaultFileURL().deletingLastPathComponent().lastPathComponent, "in.roundrobin.bridgey")
        XCTAssertEqual(BridgeyFeature.macActions.rawValue, "mac_actions_draft1")
        XCTAssertEqual(LocalDataLocations.standard.files(.macActionsAudit).map(\.lastPathComponent), ["mac-actions-audit.json"])
    }
}
