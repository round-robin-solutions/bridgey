import Foundation
import XCTest
@testable import BridgeyMac

final class SetupFlowTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "bridgey-setup-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: State machine

    func testQuickPathVisitsEachStepThenDone() {
        var flow = SetupFlow()
        XCTAssertEqual(flow.screen, .welcome)
        flow.send(.chooseQuick)
        XCTAssertEqual(flow.screen, .quick(.localNetwork))
        XCTAssertEqual(flow.path, .quick)
        XCTAssertEqual(flow.position?.index, 1)
        XCTAssertEqual(flow.position?.count, 3)
        flow.send(.next)
        XCTAssertEqual(flow.screen, .quick(.notifications))
        flow.send(.next)
        XCTAssertEqual(flow.screen, .quick(.pairPhone))
        XCTAssertTrue(flow.isLastPage)
        flow.send(.next)
        XCTAssertEqual(flow.screen, .done)
        XCTAssertTrue(flow.visited.isEmpty, "the quick path opens no settings groups")
        XCTAssertTrue(flow.skipped.isEmpty)
    }

    func testAdvancedPathGoesThroughEveryGroupInSettingsOrder() {
        var flow = SetupFlow()
        flow.send(.chooseAdvanced)
        XCTAssertEqual(flow.path, .advanced)
        var seen: [SetupGroup] = []
        while case let .advanced(group) = flow.screen {
            seen.append(group)
            XCTAssertEqual(flow.position?.index, seen.count)
            XCTAssertEqual(flow.position?.count, 10)
            flow.send(.next)
        }
        XCTAssertEqual(seen, [.devices, .clipboard, .notifications, .calls, .files, .media, .remoteControl, .privacy, .updates, .general])
        XCTAssertEqual(flow.screen, .done)
        XCTAssertEqual(flow.visited, SetupGroup.allCases)
        XCTAssertTrue(flow.unvisitedGroups.isEmpty)
    }

    func testGroupsMapToTheirSettingsPages() {
        XCTAssertEqual(SetupGroup.allCases.map(\.pane), [.devices, .clipboard, .notifications, .calls, .files, .media, .remoteControl, .privacy, .updates, .general])
    }

    func testFinishNowFromAnyAdvancedPageLeavesUnvisitedGroupsAlone() {
        for (index, group) in SetupGroup.allCases.enumerated() {
            var flow = SetupFlow()
            flow.send(.chooseAdvanced)
            for _ in 0..<index { flow.send(.next) }
            XCTAssertEqual(flow.screen, .advanced(group))
            flow.send(.finish)
            XCTAssertEqual(flow.screen, .done, "Finish now from \(group)")
            XCTAssertEqual(flow.visited, Array(SetupGroup.allCases.prefix(index + 1)))
            XCTAssertEqual(flow.unvisitedGroups, Array(SetupGroup.allCases.dropFirst(index + 1)))
            XCTAssertEqual(flow.choices.visitedGroups, flow.visited)
            XCTAssertTrue(flow.choices.changedFeatures.isEmpty, "setup itself changes no setting")
        }
    }

    /// The machine never writes settings: a page applies a change, finishing early applies nothing.
    func testFinishNowKeepsDefaultsInRealSettingsStorage() {
        let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("settings.") }
        var flow = SetupFlow()
        flow.send(.chooseAdvanced)
        flow.send(.jump(.files))
        flow.recordFeature(BridgeyFeature.files.rawValue, enabled: false)
        flow.send(.finish)
        XCTAssertEqual(flow.choices.changedFeatures, ["files": false])
        XCTAssertEqual(flow.visited, [.devices, .files])
        XCTAssertFalse(flow.choices.visitedGroups.contains(.clipboard))
        XCTAssertEqual(defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("settings.") }.count, before.count)
    }

    func testJumpOpensAnyGroupAndBackFollowsSettingsOrder() {
        var flow = SetupFlow()
        flow.send(.chooseAdvanced)
        flow.send(.jump(.updates))
        XCTAssertEqual(flow.screen, .advanced(.updates))
        XCTAssertEqual(flow.position?.index, 9)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .advanced(.privacy))
        XCTAssertEqual(flow.visited, [.devices, .updates, .privacy])
        flow.send(.jump(.general))
        XCTAssertTrue(flow.isLastPage)
        flow.send(.next)
        XCTAssertEqual(flow.screen, .done)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .advanced(.general), "Back from Done returns to the last page")
    }

    func testJumpIsIgnoredOutsideTheAdvancedPath() {
        var flow = SetupFlow()
        flow.send(.jump(.files))
        XCTAssertEqual(flow.screen, .welcome)
        flow.send(.chooseQuick)
        flow.send(.jump(.files))
        XCTAssertEqual(flow.screen, .quick(.localNetwork))
    }

    func testSkippingAPermissionStepRecordsItAsSkippedNotGranted() {
        var flow = SetupFlow()
        flow.send(.chooseQuick)
        flow.send(.next)                     // Local Network allowed
        flow.send(.skip)                     // Notifications skipped
        XCTAssertEqual(flow.screen, .quick(.pairPhone))
        XCTAssertEqual(flow.skipped, [.notifications])
        flow.send(.skip)                     // Pair later
        XCTAssertTrue(flow.pairingSkipped)
        XCTAssertEqual(flow.screen, .done)
        XCTAssertEqual(flow.choices.skippedPermissions, [.notifications])

        // Skipped, so macOS never asked: the Permissions page still offers to ask.
        let status = PermissionStatus(permission: .notifications, system: .notDetermined, needed: true)
        XCTAssertEqual(status.chip, .notAllowed)
        XCTAssertEqual(status.manage, .request)

        // Stored when setup finishes.
        let store = SetupStore(defaults: defaults)
        store.finish(flow.choices)
        XCTAssertEqual(store.skipped, [.notifications])
        XCTAssertEqual(store.choices, flow.choices)
    }

    func testAllowingAfterGoingBackClearsTheSkip() {
        var flow = SetupFlow()
        flow.send(.chooseQuick)
        flow.send(.skip)
        XCTAssertEqual(flow.skipped, [.localNetwork])
        flow.send(.back)
        XCTAssertEqual(flow.screen, .quick(.localNetwork))
        flow.send(.next)
        XCTAssertTrue(flow.skipped.isEmpty)
    }

    func testBackFromTheFirstStepReturnsToWelcome() {
        var quick = SetupFlow()
        quick.send(.chooseQuick)
        quick.send(.back)
        XCTAssertEqual(quick.screen, .welcome)
        XCTAssertNil(quick.path)

        var advanced = SetupFlow()
        advanced.send(.chooseAdvanced)
        advanced.send(.back)
        XCTAssertEqual(advanced.screen, .welcome)
        XCTAssertNil(advanced.path)

        var welcome = SetupFlow()
        welcome.send(.back)
        XCTAssertEqual(welcome.screen, .welcome)
    }

    func testReviewSetupStartsTheAdvancedPathAtDevices() {
        let flow = SetupFlow(start: .advanced(.devices))
        XCTAssertEqual(flow.screen, .advanced(.devices))
        XCTAssertEqual(flow.path, .advanced)
        XCTAssertEqual(flow.visited, [.devices])
    }

    // MARK: Launch

    func testFreshInstallRunsSetupAndKeepsRunningItUntilFinished() {
        let store = SetupStore(defaults: defaults)
        XCTAssertEqual(SetupLaunch.evaluate(store, trustFileExists: false), .runSetup)
        // BridgeySettings and discovery write keys on the first launch; setup still comes back.
        defaults.set("local", forKey: "settings.codes.engine")
        defaults.set(UUID().uuidString, forKey: "deviceID")
        XCTAssertEqual(SetupLaunch.evaluate(store, trustFileExists: false), .runSetup)
        store.finish(SetupChoices())
        XCTAssertEqual(SetupLaunch.evaluate(store, trustFileExists: true), .none)
        XCTAssertTrue(defaults.bool(forKey: "settings.onboarding.completed"))
    }

    func testExistingUsersGetTheReviewBannerOnceNotSetup() {
        let store = SetupStore(defaults: defaults)
        defaults.set(true, forKey: "settings.onboarding.completed")
        XCTAssertEqual(SetupLaunch.evaluate(store, trustFileExists: false), .offerReview)
        XCTAssertEqual(SetupLaunch.evaluate(store, trustFileExists: false), .offerReview, "until opened or dismissed")
        store.markSetupSeen()
        XCTAssertEqual(SetupLaunch.evaluate(store, trustFileExists: false), .none)
    }

    func testStoredSettingsOrPairingsCountAsAnExistingUser() {
        XCTAssertEqual(SetupLaunch.decide(setupVersionSeen: 0, setupPending: false, onboardingCompleted: false,
                                          hasStoredState: SetupLaunch.hasStoredState(keys: ["updates.channel"], trustFileExists: false)), .offerReview)
        XCTAssertTrue(SetupLaunch.hasStoredState(keys: [], trustFileExists: true))
        XCTAssertFalse(SetupLaunch.hasStoredState(keys: ["AppleLanguages", "NSWindow Frame X"], trustFileExists: false))
        XCTAssertEqual(SetupLaunch.decide(setupVersionSeen: 0, setupPending: false, onboardingCompleted: false, hasStoredState: false), .runSetup)
    }

    func testAResetThatRunsSetupWinsOverEverything() {
        XCTAssertEqual(SetupLaunch.decide(setupVersionSeen: 1, setupPending: true, onboardingCompleted: true, hasStoredState: true), .runSetup)
    }

    // MARK: Explained permissions

    func testExplainedPermissionsAreRemembered() {
        let store = SetupStore(defaults: defaults)
        XCTAssertFalse(store.wasExplained(.bluetooth))
        store.markExplained(.bluetooth)
        store.markExplained(.accessibility)
        store.markExplained(.bluetooth)
        XCTAssertEqual(store.explained, [.bluetooth, .accessibility])
        XCTAssertEqual(defaults.stringArray(forKey: SetupStore.explainedKey), ["bluetooth", "accessibility"])
    }
}

/// Setup's strings: every key in both tables, no em or en dashes, the milestone never called 1.0.
final class SetupStringsTests: XCTestCase {
    private let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ language: String) throws -> [String: String] {
        let url = macos.appendingPathComponent("Resources/\(language).lproj/Setup.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func usedKeys() throws -> Set<String> {
        let sources = macos.appendingPathComponent("Sources/BridgeyMac")
        var keys = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"L10n\.setup\(\s*"([^"]+)""#)
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return keys
    }

    func testEveryKeyIsInEnglishAndRussian() throws {
        let used = try usedKeys()
        XCTAssertGreaterThan(used.count, 100)
        let english = try table("en")
        let russian = try table("ru")
        XCTAssertEqual(Set(english.keys), used, "en.lproj/Setup.strings")
        XCTAssertEqual(Set(russian.keys), used, "ru.lproj/Setup.strings")
        for (key, value) in russian {
            XCTAssertEqual(value.components(separatedBy: "%").count, english[key]?.components(separatedBy: "%").count, "placeholders in \(key)")
        }
    }

    func testNoDashesAndNoOnePointZero() throws {
        for language in ["en", "ru"] {
            for (key, value) in try table(language) {
                XCTAssertFalse(value.contains("\u{2014}") || value.contains("\u{2013}"), "\(language) \(key) has a dash")
                XCTAssertFalse(value.contains("1.0"), "\(language) \(key) mentions 1.0")
            }
        }
    }
}
