import Foundation
import XCTest
@testable import BridgeyMac

/// Settings from every edition release load unchanged. The fixtures are the app's defaults domain
/// (`~/Library/Preferences/in.roundrobin.bridgey.plist`) as each release left it.
///
/// `BridgeySettings` reads `UserDefaults.standard`. Under `swift test` that is the test runner's own
/// domain, never the app's; every `settings.*` key there is saved first and put back afterwards.
/// Keys read through an injected `UserDefaults` go to a throwaway suite instead.
final class MigrationSettingsTests: XCTestCase {
    private typealias F = MigrationFixtures
    private static let releases = [1, 4, 5, 9, 10, 11, 13]
    private static var runnerDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    private var savedSettings: [String: Any] = [:]
    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUpWithError() throws {
        savedSettings = (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).filter { $0.key.hasPrefix("settings.") }
        clearStandardSettings()
        suiteName = "in.roundrobin.bridgey.migration-tests.\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        clearStandardSettings()
        for (key, value) in savedSettings { UserDefaults.standard.set(value, forKey: key) }
        suite.removePersistentDomain(forName: suiteName)
        BridgeyLog.policy = LoggingPolicy()
    }

    private func clearStandardSettings() {
        for key in (UserDefaults.standard.persistentDomain(forName: Self.runnerDomain) ?? [:]).keys where key.hasPrefix("settings.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// `settings.*` into the standard domain (BridgeySettings), everything else into the suite.
    private func install(_ fixture: String) throws {
        clearStandardSettings()
        for (key, value) in try F.defaults(fixture) {
            if key.hasPrefix("settings.") { UserDefaults.standard.set(value, forKey: key) } else { suite.set(value, forKey: key) }
        }
    }

    @MainActor
    func testEverySettingsSnapshotLoads() throws {
        for release in Self.releases {
            try install("settings/defaults.beta.\(release).plist")
            assertSettings(BridgeySettings(), release: release)
        }
    }

    @MainActor
    func testSettingsWrittenByThisBuildKeepTheOlderValues() throws {
        for release in Self.releases {
            try install("settings/defaults.beta.\(release).plist")
            BridgeySettings().setDeviceName("Test Mac")
            assertSettings(BridgeySettings(), release: release)
        }
    }

    @MainActor
    private func assertSettings(_ settings: BridgeySettings, release: Int, file: StaticString = #filePath, line: UInt = #line) {
        let label = "beta.\(release)"
        XCTAssertEqual(settings.deviceName, "Test Mac", label, file: file, line: line)
        XCTAssertTrue(settings.hasCompletedOnboarding, label, file: file, line: line)
        XCTAssertTrue(settings.notificationHistoryEnabled, label, file: file, line: line)
        XCTAssertEqual(settings.receiveFolderPath, "/Users/test/Downloads/Bridgey Inbox", label, file: file, line: line)

        var globals = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        globals[.clipboard] = false
        globals[.remoteInput] = release >= 9
        XCTAssertEqual(settings.globalFeatures, globals, label, file: file, line: line)
        var phoneA: [BridgeyFeature: Bool] = [.notifications: false, .calls: true]
        if release >= 9 { phoneA[.remoteInput] = true }
        XCTAssertEqual(settings.deviceFeatures, [F.phoneA: phoneA, F.phoneB: [.files: false]], label, file: file, line: line)

        // Beta 4: the Stream design and Automatic clipboard.
        XCTAssertEqual(settings.showActivityPreviews, release < 4, label, file: file, line: line)
        XCTAssertEqual(settings.reduceMotion, release >= 4, label, file: file, line: line)
        XCTAssertEqual(settings.autoClipboardEnabled, release < 4, label, file: file, line: line)
        XCTAssertEqual(settings.autoClipboardDevices, release >= 4 ? [F.phoneA: true] : [:], label, file: file, line: line)
        // Beta 5: Copy images and files.
        XCTAssertEqual(settings.clipboardFilesEnabled, release < 5, label, file: file, line: line)
        XCTAssertEqual(settings.clipboardEagerLimit, release >= 5 ? 100_000_000 : 25_000_000, label, file: file, line: line)
        // Beta 10: folders.
        XCTAssertEqual(settings.folderIncludeHidden, release >= 10, label, file: file, line: line)
        XCTAssertEqual(settings.folderIncludeSystem, release >= 10, label, file: file, line: line)
        // Beta 11: ringing and Privacy > Logging.
        XCTAssertEqual(settings.ringForIncomingCalls, release < 11, label, file: file, line: line)
        var logging = LoggingPolicy()
        if release >= 11 {
            logging.connection = false
            logging.callNumbers = true
            logging.remoteControl = false
        }
        XCTAssertEqual(settings.logging, logging, label, file: file, line: line)
        // Beta 13: codes from messages.
        XCTAssertEqual(settings.codesEnabled, release >= 13, label, file: file, line: line)
        XCTAssertEqual(settings.codesAutoCopy, release >= 13, label, file: file, line: line)
        XCTAssertEqual(settings.codesEngine, .local, label, file: file, line: line)
        XCTAssertEqual(settings.codeModelAcceptances.map(\.modelVersion), release >= 13 ? [1] : [], label, file: file, line: line)

        // Read through injected defaults elsewhere in the app.
        XCTAssertEqual(UpdateChannel.stored(in: suite), .beta, label, file: file, line: line)
        XCTAssertEqual(suite.string(forKey: "deviceID"), F.macID, label, file: file, line: line)
        XCTAssertEqual(FolderDestinationMemory(defaults: suite).last(for: F.phoneA),
                       release >= 10 ? FolderDestination(placeId: "q3Jx0bVv1eG7tq8Wm2l5wA", path: "Photos/2026") : nil,
                       label, file: file, line: line)
    }

    @MainActor
    func testCodesTurnedOnBeforeTheEngineChoiceKeepTheCloudTheyAgreedTo() throws {
        try install("settings/defaults.codes-before-engine.plist")
        let settings = BridgeySettings()
        XCTAssertTrue(settings.codesEnabled)
        XCTAssertEqual(settings.codesEngine, .cloud)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "settings.codes.engine"), "cloud", "settled once")
    }

    @MainActor
    func testWrongValuesFallBackToSafeDefaultsWithoutCrashing() throws {
        try install("settings/defaults.wrong-values.plist")
        let settings = BridgeySettings()
        XCTAssertEqual(settings.globalFeatures[.clipboard], true, "a string where a Bool belongs reads as the default")
        XCTAssertEqual(settings.deviceFeatures[F.phoneA]?[.files], true, "NSNumber 1 is a Bool")
        XCTAssertNil(settings.autoClipboardDevices[""], "a key with no device id is ignored")
        XCTAssertEqual(settings.clipboardEagerLimit, ClipboardEagerLimit.default.bytes, "a limit that is not offered")
        XCTAssertEqual(settings.codesEngine, .local, "an engine this build does not know never means the cloud")
        XCTAssertEqual(settings.codeModelAcceptances, [], "damaged acceptances ask again")
        XCTAssertEqual(UpdateChannel.stored(in: suite), .stable)
        XCTAssertNil(FolderDestinationMemory(defaults: suite).last(for: F.phoneB))
    }

    func testTheDeviceIDKeyIsPinned() throws {
        // Discovery reads it straight from UserDefaults.standard; a new name would give the Mac a new id.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/BridgeyMac/Discovery.swift").standardizedFileURL
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("defaults.string(forKey: \"deviceID\")"))
        XCTAssertTrue(text.contains("defaults.set(deviceID, forKey: \"deviceID\")"))
    }
}
