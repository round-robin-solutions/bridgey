import Foundation
import XCTest
@testable import BridgeyMac

/// The first build with settings sync, on a Mac from every edition release: what the person chose before is
/// stamped `changedAt 1, version 1` (so it wins over a never-edited default, and any later edit wins over
/// it), defaults stay at 0, and nothing counts as a fresh local edit. Same handling of the standard domain as
/// MigrationSettingsTests: every `settings.*` key is saved first and put back afterwards.
@MainActor
final class MigrationSettingsSyncTests: XCTestCase {
    private typealias F = MigrationFixtures
    private static var runnerDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }
    private var savedSettings: [String: Any] = [:]

    override func setUp() {
        savedSettings = (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).filter { $0.key.hasPrefix("settings.") }
        clearStandardSettings()
    }

    override func tearDown() {
        clearStandardSettings()
        for (key, value) in savedSettings { UserDefaults.standard.set(value, forKey: key) }
        BridgeyLog.policy = LoggingPolicy()
    }

    private func clearStandardSettings() {
        for key in (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).keys where key.hasPrefix("settings.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func install(_ fixture: String) throws {
        clearStandardSettings()
        for (key, value) in try F.defaults(fixture) where key.hasPrefix("settings.") { UserDefaults.standard.set(value, forKey: key) }
    }

    private func upgrade(_ fixture: String) throws -> SettingsSyncController {
        try install(fixture)
        let settings = BridgeySettings()
        return SettingsSyncController(localDeviceID: F.macID, defaults: .standard,
                                      settings: SettingsSyncController.liveSettings(settings, focus: FocusSync(defaults: .standard)),
                                      clock: { 1_793_005_200_000 })
    }

    private func chosen(_ value: SyncValue) -> SyncRecord { SyncRecord(value: value, changedAt: 1, version: 1, changedBy: F.macID) }

    func testBetaReleasesStampWhatWasStored() throws {
        for fixture in ["beta.4", "beta.5", "beta.9", "beta.10", "beta.11", "beta.13", "codes-before-engine", "wrong-values"] {
            let sync = try upgrade("settings/defaults.\(fixture).plist")
            XCTAssertEqual(sync.engine.record(.reduceMotion), chosen(.bool(true)), fixture)
            XCTAssertEqual(sync.engine.record(.activityPreviews), chosen(.bool(false)), fixture)
            // wrong-values stores "yes" for Clipboard: a wrong type counts as never chosen.
            XCTAssertEqual(sync.engine.record(.featureClipboard).chosen, fixture != "wrong-values", fixture)
            if fixture != "wrong-values" { XCTAssertEqual(sync.engine.record(.featureClipboard), chosen(.bool(false)), fixture) }
            XCTAssertEqual(sync.engine.record(.featureMedia), chosen(.bool(true)), fixture)
            // Never stored: what this Mac does now, never chosen ("Received files" for folders).
            XCTAssertEqual(sync.engine.record(.folderDestination), .neverChosen(.string("fixed")), fixture)
            XCTAssertEqual(sync.engine.record(.folderConflict), .neverChosen(.string("ask")), fixture)
            XCTAssertFalse(sync.engine.record(.featureFiles).chosen, fixture)
            XCTAssertEqual(sync.engine.record(.featureCamera), .defaultRecord(.featureCamera), fixture)
            XCTAssertTrue(sync.enabled, fixture)
            XCTAssertTrue(sync.excluded.isEmpty, fixture)
        }
        let beta13 = try upgrade("settings/defaults.beta.13.plist")
        XCTAssertEqual(beta13.engine.record(.featureRemoteInput), chosen(.bool(true)))
        XCTAssertEqual(beta13.engine.record(.autoClipboard), chosen(.bool(false)))
        XCTAssertEqual(beta13.engine.record(.clipboardFiles), chosen(.bool(false)))
        XCTAssertEqual(beta13.engine.record(.codesEnabled), chosen(.bool(true)))
    }

    func testBeta1StampsOnlyItsTwoSwitches() throws {
        let sync = try upgrade("settings/defaults.beta.1.plist")
        XCTAssertEqual(sync.engine.record(.featureClipboard), chosen(.bool(false)))
        XCTAssertEqual(sync.engine.record(.featureMedia), chosen(.bool(true)))
        XCTAssertEqual(sync.engine.record(.reduceMotion), .neverChosen(.bool(false)))
        XCTAssertEqual(sync.engine.record(.activityPreviews), .neverChosen(.bool(true)))
    }

    func testFiles2FolderChoicesAreStamped() throws {
        let sync = try upgrade("settings/defaults.0.8.0-rr.1.plist")
        XCTAssertEqual(sync.engine.record(.folderDestination), chosen(.string("receiver_asks")))
        XCTAssertEqual(sync.engine.record(.folderConflict), chosen(.string("new_folder")))
    }

    func testWrongFolderValuesCountAsNeverChosen() throws {
        let sync = try upgrade("settings/defaults.files2-wrong-values.plist")
        XCTAssertEqual(sync.engine.record(.folderDestination), .neverChosen(.string("fixed")))
        XCTAssertEqual(sync.engine.record(.folderConflict), .neverChosen(.string("ask")))
    }

    func testAutomationFocusAndMacActionsAreStamped() throws {
        let sync = try upgrade("settings/defaults.automation.plist")
        XCTAssertEqual(sync.engine.record(.focusShare), chosen(.bool(true)))
        XCTAssertEqual(sync.engine.record(.focusFollow), chosen(.bool(true)))
        XCTAssertEqual(sync.engine.record(.featureMacActions), chosen(.bool(true)))
    }

    func testTheUpgradeRunsOnceAndLaterLaunchesKeepTheRecords() throws {
        let first = try upgrade("settings/defaults.beta.13.plist")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SettingsSyncController.stampedKey))
        let settings = BridgeySettings()
        settings.setReduceMotion(false)
        let second = SettingsSyncController(localDeviceID: F.macID, defaults: .standard,
                                            settings: SettingsSyncController.liveSettings(settings, focus: FocusSync(defaults: .standard)),
                                            clock: { 1_793_005_300_000 })
        // Turned off while sync was not watching: a local edit, stamped above the upgrade stamp.
        XCTAssertEqual(second.engine.record(.reduceMotion), SyncRecord(value: .bool(false), changedAt: 1_793_005_300_000, version: 2, changedBy: F.macID))
        XCTAssertEqual(second.engine.record(.activityPreviews), first.engine.record(.activityPreviews))
    }
}
