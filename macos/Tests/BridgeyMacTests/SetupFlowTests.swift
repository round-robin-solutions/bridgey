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

    /// A paired Mac with every permission allowed: no question is skipped for a missing phone or permission.
    private let paired = SetupFacts(paired: true, granted: Set(SetupPermission.allCases))

    private func run(_ events: [SetupEvent], facts: SetupFacts, from start: SetupFlow = SetupFlow()) -> SetupFlow {
        var flow = start
        for event in events { flow.send(event, facts: facts) }
        return flow
    }

    /// Walks the question path with Not now on every card; returns the question ids shown.
    private func walk(_ facts: SetupFacts, typed: [String: String] = [:]) -> [String] {
        var flow = run([.chooseAdvanced, .startQuestions(typed)], facts: facts)
        var shown: [String] = []
        while case let .question(id) = flow.screen {
            shown.append(id)
            flow.send(.notNow, facts: facts)
        }
        XCTAssertEqual(flow.screen, .summary)
        return shown
    }

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
        XCTAssertTrue(flow.answers.isEmpty, "the quick path asks no questions")
        XCTAssertTrue(flow.skipped.isEmpty)
    }

    func testAdvancedStartsAtTheIntroAndGoesThroughEveryQuestionInOrder() {
        XCTAssertEqual(run([.chooseAdvanced], facts: paired).screen, .intro)
        XCTAssertEqual(walk(paired), ["clipboard", "clipboard_files", "notifications", "codes", "notification_history",
                                      "calls", "calls_ring", "calls_pause", "calls_links", "files", "files_folder", "files_photos",
                                      "remote", "mac_actions", "media", "camera", "focus", "links", "find", "battery",
                                      "stats", "previews", "updates", "updates_auto", "login", "motion"])
        let order = SetupQuestions.all.map { SetupSection.allCases.firstIndex(of: $0.section)! }
        XCTAssertEqual(order, order.sorted(), "questions follow the section order")
    }

    func testNoMacControlQuestionsWithoutAPairedPhone() {
        let shown = walk(SetupFacts(paired: false, granted: Set(SetupPermission.allCases)))
        XCTAssertEqual(shown.first, "pair")
        for id in ["remote", "mac_actions", "media"] { XCTAssertFalse(shown.contains(id), id) }
        XCTAssertFalse(walk(paired).contains("pair"), "already paired: the pairing card is implied")
    }

    func testDeclinedAnswersSkipTheirFollowUps() {
        var flow = run([.chooseAdvanced, .startQuestions([:])], facts: paired)
        flow.send(.answer("clipboard", SetupAnswerKey.no), facts: paired)
        XCTAssertEqual(flow.screen, .question("notifications"), "no clipboard: no images question")
        flow.send(.answer("notifications", SetupAnswerKey.no), facts: paired)
        XCTAssertEqual(flow.screen, .question("calls"), "notifications declined: no codes or history questions")
        flow.send(.answer("calls", SetupAnswerKey.no), facts: paired)
        XCTAssertEqual(flow.screen, .question("files"), "no calls: no ring, pause or phone links questions")
        flow.send(.answer("files", SetupAnswerKey.no), facts: paired)
        XCTAssertEqual(flow.screen, .question("remote"))
    }

    func testStepsLeftFollowsTheAnswers() {
        var flow = run([.chooseAdvanced, .startQuestions([:])], facts: paired)
        flow.send(.notNow, facts: paired)          // clipboard
        flow.send(.notNow, facts: paired)          // clipboard_files
        XCTAssertEqual(flow.screen, .question("notifications"))
        let before = flow.stepsLeft(paired)
        var declined = flow
        declined.send(.answer("notifications", SetupAnswerKey.no), facts: paired)
        XCTAssertEqual(declined.stepsLeft(paired), before - 1 - 2, "codes and history drop out")
        XCTAssertEqual(walk(paired).count, run([.chooseAdvanced], facts: paired).stepsLeft(paired))
    }

    func testBackWalksTheQuestionsShownAndKeepsAnswers() {
        var flow = run([.chooseAdvanced, .startQuestions([:])], facts: paired)
        flow.send(.answer("clipboard", SetupAnswerKey.tap), facts: paired)
        flow.send(.answer("clipboard_files", SetupAnswerKey.text), facts: paired)
        flow.send(.answer("notifications", SetupAnswerKey.no), facts: paired)
        XCTAssertEqual(flow.screen, .question("calls"))
        flow.send(.back)
        XCTAssertEqual(flow.screen, .question("notifications"))
        XCTAssertEqual(flow.answers["notifications"], SetupAnswerKey.no, "the answer stays chosen")
        flow.send(.back)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .question("clipboard"))
        flow.send(.back)
        XCTAssertEqual(flow.screen, .intro)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .welcome)
        XCTAssertEqual(flow.answers.count, 3, "going back undoes nothing")
        // Forward again: the questions come back in order, answers marked.
        flow.send(.chooseAdvanced)
        flow.send(.startQuestions([:]), facts: paired)
        XCTAssertEqual(flow.screen, .question("clipboard"))
        XCTAssertEqual(flow.trail, ["clipboard"])
    }

    func testAPermissionIsAskedRightAfterItsAnswer() {
        let none = SetupFacts(paired: true)
        var flow = run([.chooseAdvanced, .startQuestions([:]), .notNow, .notNow], facts: none)
        XCTAssertEqual(flow.screen, .question("notifications"))
        flow.send(.answer("notifications", SetupAnswerKey.yes), facts: none)
        XCTAssertEqual(flow.screen, .permission("notifications", .notifications))
        flow.send(.back)
        XCTAssertEqual(flow.screen, .question("notifications"), "Back from a permission returns to its question")
        flow.send(.answer("notifications", SetupAnswerKey.yes), facts: none)

        var allowed = flow
        allowed.send(.permissionResult(true), facts: none)
        XCTAssertEqual(allowed.screen, .question("codes"))
        XCTAssertTrue(allowed.denied.isEmpty)

        var refused = flow
        XCTAssertEqual(refused.changes(for: .permissionResult(false), facts: none), [.off(.featureNotifications), .off(.macNotifications)])
        refused.send(.permissionResult(false), facts: none)
        XCTAssertEqual(refused.denied["notifications"], .notifications)
        XCTAssertEqual(refused.notice, "notifications", "the next card says so in one line")
        XCTAssertEqual(refused.screen, .question("calls"), "notifications stayed off: no codes or history questions")
        refused.send(.notNow, facts: none)
        XCTAssertNil(refused.notice, "only the next card")

        var notNow = flow
        notNow.send(.notNow, facts: none)
        XCTAssertEqual(notNow.denied["notifications"], .notifications, "Not now on a permission is not allowed")

        // Already allowed: no permission step.
        var granted = run([.chooseAdvanced, .startQuestions([:]), .notNow, .notNow], facts: paired)
        granted.send(.answer("notifications", SetupAnswerKey.yes), facts: paired)
        XCTAssertEqual(granted.screen, .question("codes"))
    }

    func testTypedAnswersSkipTheirQuestionsUnlessTheyNeedAPermission() {
        let typed = ["notifications": SetupAnswerKey.yes, "files": SetupAnswerKey.yes]
        XCTAssertFalse(walk(paired, typed: typed).contains("notifications"))
        XCTAssertFalse(walk(paired, typed: typed).contains("files"))
        let intro = run([.chooseAdvanced], facts: paired)
        XCTAssertEqual(Set(intro.changes(for: .startQuestions(typed), facts: paired)),
                       [.on(.featureNotifications), .on(.macNotifications), .on(.featureFiles)])

        // Notifications needs a permission that is not allowed yet: its card comes up, already chosen.
        let none = SetupFacts(paired: true)
        let pending = run([.chooseAdvanced], facts: none)
        XCTAssertEqual(pending.changes(for: .startQuestions(typed), facts: none), [.on(.featureFiles)])
        XCTAssertTrue(walk(none, typed: typed).contains("notifications"))
        XCTAssertFalse(walk(none, typed: typed).contains("files"))
        var flow = run([.chooseAdvanced, .startQuestions(typed), .notNow, .notNow], facts: none)
        XCTAssertEqual(flow.screen, .question("notifications"))
        XCTAssertEqual(flow.typed["notifications"], SetupAnswerKey.yes)
        flow.send(.answer("notifications", SetupAnswerKey.yes), facts: none)
        XCTAssertEqual(flow.screen, .permission("notifications", .notifications))
    }

    func testSummaryListsWhatWasTurnedOnChoicesAndRefusals() {
        let none = SetupFacts(paired: true)
        var flow = run([.chooseAdvanced, .startQuestions([:])], facts: none)
        flow.send(.answer("clipboard", SetupAnswerKey.auto), facts: none)
        flow.send(.answer("clipboard_files", SetupAnswerKey.text), facts: none)
        flow.send(.answer("notifications", SetupAnswerKey.yes), facts: none)
        flow.send(.permissionResult(false), facts: none)
        while case let .question(id) = flow.screen {
            flow.send(id == "updates" ? .answer(id, SetupAnswerKey.early) : .notNow, facts: none)
        }
        XCTAssertEqual(flow.screen, .summary)
        let items = SetupSummary.items(flow)
        XCTAssertEqual(items.map(\.question.id), ["clipboard", "notifications", "updates"])
        guard case .turnedOn(_, _, on: true) = items[0] else { return XCTFail("clipboard is on") }
        guard case .notAllowed(_, .notifications, _) = items[1] else { return XCTFail("notifications not allowed") }
        guard case .chosen = items[2] else { return XCTFail("updates is a choice") }

        XCTAssertEqual(flow.changes(for: .summarySwitch("clipboard", false), facts: none), [.off(.featureClipboard)])
        flow.send(.summarySwitch("clipboard", false), facts: none)
        guard case .turnedOn(_, _, on: false) = SetupSummary.items(flow)[0] else { return XCTFail("switched off") }
        XCTAssertEqual(flow.choices.settings["featureClipboard"], "false")
        XCTAssertEqual(flow.changes(for: .summarySwitch("clipboard", true), facts: none), [.on(.featureClipboard), .on(.autoClipboard)])
        flow.send(.back)
        XCTAssertEqual(flow.screen, .question("motion"), "Back from the summary returns to the last question")

        let store = SetupStore(defaults: defaults)
        store.finish(flow.choices)
        XCTAssertEqual(store.choices, flow.choices)
        XCTAssertEqual(store.choices?.settings["updateChannel"], "beta")
    }

    // MARK: Coverage and mapping

    /// Every setting the old Advanced setup showed is reachable through a question, a follow-up or
    /// a question's More options.
    func testEverySettingIsCoveredByAQuestion() {
        let coverage = SetupQuestions.coverage
        for setting in SetupSetting.allCases {
            guard let entry = coverage[setting] else {
                XCTFail("\(setting) is not covered by any question")
                continue
            }
            let (id, how) = (entry.question, entry.how)
            let question = SetupQuestions.question(id)!
            switch how {
            case .answer where id != "pair":
                let set = question.answers.flatMap { $0.changes + $0.onDenied }.map(\.setting)
                XCTAssertTrue(set.contains(setting), "\(id) claims to answer \(setting) but no answer sets it")
            case .moreOptions:
                XCTAssertNotNil(question.pane, "\(id) covers \(setting) through More options, so it needs a Settings page")
            default:
                break
            }
        }
    }

    func testEveryAnswerSetsOnlyWhatItsQuestionCovers() {
        for question in SetupQuestions.all {
            XCTAssertEqual(Set(question.answers.map(\.key)).count, question.answers.count, "\(question.id) answer keys")
            if let off = question.offKey { XCTAssertNotNil(question.answer(off), "\(question.id) off answer") }
            for answer in question.answers {
                for change in answer.changes + answer.onDenied {
                    XCTAssertEqual(question.covers[change.setting], .answer, "\(question.id).\(answer.key) sets \(change.setting)")
                }
            }
        }
        XCTAssertEqual(Set(SetupQuestions.all.map(\.id)).count, SetupQuestions.all.count, "question ids are unique")
    }

    func testAnswersMapToSettings() {
        func changes(_ id: String, _ key: String) -> [SettingChange] { SetupQuestions.changes(SetupQuestions.question(id)!, key) }
        XCTAssertEqual(changes("clipboard", "auto"), [.on(.featureClipboard), .on(.autoClipboard)])
        XCTAssertEqual(changes("clipboard", "tap"), [.on(.featureClipboard), .off(.autoClipboard)])
        XCTAssertEqual(changes("clipboard", "no"), [.off(.featureClipboard)])
        XCTAssertEqual(changes("codes", "on_mac"), [.on(.codesEnabled), .set(.codesEngine, "local")])
        XCTAssertEqual(changes("codes", "cloud"), [.on(.codesEnabled), .set(.codesEngine, "cloud")])
        XCTAssertEqual(changes("files_folder", "ask"), [.set(.folderReceiveMode, "ask")])
        XCTAssertEqual(changes("files_photos", "yes"), [.set(.sendImageMode, "optimize")])
        XCTAssertEqual(changes("remote", "yes"), [.on(.featureRemoteInput), .on(.remoteGrant), .on(.accessibility)])
        XCTAssertEqual(changes("mac_actions", "yes"), [.on(.featureMacActions), .set(.macActionSwitches, "lock,sleep,volume"), .on(.macActionsGrant)])
        XCTAssertEqual(SetupQuestions.question("mac_actions")!.answer("yes")!.onDenied, [.set(.macActionSwitches, "sleep,volume")],
                       "no Accessibility: Lock stays off, sleep and volume still work")
        XCTAssertEqual(changes("media", "spotify"), [.on(.featureMedia), .set(.mediaPlayer, "spotify")])
        XCTAssertEqual(changes("focus", "follow"), [.off(.focusShare), .on(.focusFollow)])
        XCTAssertEqual(changes("focus", "share"), [.on(.focusShare), .off(.focusFollow)])
        XCTAssertEqual(changes("links", "right_away"), [.on(.featureLinks), .on(.openLinksRightAway)])
        XCTAssertEqual(changes("find", "no"), [.off(.featureFindDevice), .off(.featurePing)])
        XCTAssertEqual(changes("stats", "no"), [.off(.loggingConnection)])
        XCTAssertEqual(changes("updates", "steady"), [.set(.updateChannel, "stable")])
        XCTAssertEqual(changes("updates", "early"), [.set(.updateChannel, "beta")])
        XCTAssertEqual(changes("updates", "newest"), [.set(.updateChannel, "nightly")])
        XCTAssertEqual(UpdateChannel(rawValue: "nightly"), .nightly)
        XCTAssertEqual(MacFolderReceiveMode(rawValue: "ask"), .ask)
        XCTAssertEqual(SendOptimization.ImageMode(rawValue: "optimize"), .optimize)
        XCTAssertEqual(CodeEngine(rawValue: "cloud"), .cloud)
        XCTAssertEqual(MediaPlayer(rawValue: "spotify"), .spotify)
    }

    func testCloudCodesAreOfferedOnlyWithARelay() {
        let codes = SetupQuestions.question("codes")!
        XCTAssertEqual(codes.visibleAnswers(SetupFacts(codesAvailable: true)).map(\.key), ["on_mac", "cloud", "no"])
        XCTAssertEqual(codes.visibleAnswers(SetupFacts(codesAvailable: false)).map(\.key), ["on_mac", "no"])
    }

    func testBundlesAreNamedAfterTheirSettingsPagesAndAnswerRealQuestions() {
        for bundle in SetupBundles.all {
            XCTAssertEqual(bundle.title, bundle.pane.title)
            for (id, key) in bundle.answers { XCTAssertNotNil(SetupQuestions.question(id)?.answer(key), "\(bundle.id): \(id).\(key)") }
        }
        let merged = SetupBundles.answers(picked: ["clipboard"], typed: ["clipboard": "tap"])
        XCTAssertEqual(merged, ["clipboard": "tap", "clipboard_files": "yes"], "typing wins over a bundle")
    }

    // MARK: Back, Escape and the close button

    func testEscapeStepsBackAndLeavesOnlyFromTheFirstScreen() {
        var flow = SetupFlow()
        XCTAssertEqual(SetupBack.decide(flow), .leave, "Welcome, nothing chosen: leave")
        XCTAssertFalse(SetupBack.closeAsks(flow))
        flow.send(.chooseAdvanced)
        XCTAssertEqual(SetupBack.decide(flow), .step)
        XCTAssertTrue(SetupBack.closeAsks(flow), "closing mid-way asks")
        flow.send(.startQuestions([:]), facts: paired)
        flow.send(.answer("clipboard", SetupAnswerKey.auto), facts: paired)
        XCTAssertEqual(SetupBack.decide(flow), .step)
        flow.send(.back)
        flow.send(.back)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .welcome)
        XCTAssertEqual(SetupBack.decide(flow), .askLeave, "choices made: ask before leaving")
        XCTAssertTrue(SetupBack.closeAsks(flow))
        flow.send(.askLeave)
        XCTAssertTrue(flow.confirmLeave)
        flow.send(.keepGoing)
        XCTAssertFalse(flow.confirmLeave)

        var quick = SetupFlow()
        quick.send(.chooseQuick)
        quick.send(.skip)
        quick.send(.skip)
        quick.send(.skip)
        XCTAssertEqual(quick.screen, .done)
        XCTAssertFalse(SetupBack.closeAsks(quick), "the end closes without asking")
        XCTAssertEqual(SetupBack.decide(quick), .step)
        quick.send(.back)
        XCTAssertEqual(quick.screen, .quick(.pairPhone))
    }

    func testReviewSetupStartsAtTheQuestionsAndLeavesFromThere() {
        var flow = SetupFlow.review()
        XCTAssertEqual(flow.screen, .intro)
        XCTAssertEqual(flow.entry, .intro)
        XCTAssertEqual(flow.path, .advanced)
        XCTAssertEqual(SetupBack.decide(flow), .leave)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .intro, "the review never shows Welcome")
        flow.send(.startQuestions([:]), facts: paired)
        flow.send(.answer("clipboard", SetupAnswerKey.auto), facts: paired)
        flow.send(.back)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .intro)
        XCTAssertEqual(SetupBack.decide(flow), .askLeave)
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

        let status = PermissionStatus(permission: .notifications, system: .notDetermined, needed: true)
        XCTAssertEqual(status.chip, .notAllowed)
        XCTAssertEqual(status.manage, .request)

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

    func testBackFromTheFirstQuickStepReturnsToWelcome() {
        var quick = SetupFlow()
        quick.send(.chooseQuick)
        quick.send(.back)
        XCTAssertEqual(quick.screen, .welcome)
        XCTAssertNil(quick.path)
    }

    // MARK: Type what you want

    func testTypedSentencesMatchTheSameFeaturesAsAndroid() {
        XCTAssertEqual(SetupTyped.match("I mainly want my WhatsApp notifications and to send photos to my Mac"),
                       ["notifications": "yes", "files": "yes"])
        XCTAssertEqual(SetupTyped.match("copy paste and calls but no music"),
                       ["clipboard": "auto", "calls": "yes", "media": "no"])
        XCTAssertEqual(SetupTyped.match("Хочу уведомления и фото на Mac, без звонков"),
                       ["notifications": "yes", "files": "yes", "calls": "no"])
        XCTAssertEqual(SetupTyped.match("Do not disturb in sync, and beta updates"),
                       ["focus": "both", "updates": "early"])
        XCTAssertEqual(SetupTyped.match("control my mac with a touchpad for slides"), ["remote": "yes"])
        XCTAssertEqual(SetupTyped.match(""), [:])
        XCTAssertEqual(SetupTyped.match("codes from messages"), ["codes": "on_mac"], "typing never picks the cloud")
        XCTAssertEqual(SetupTyped.match("no camera"), [:], "camera has no No on the Mac")
        for (id, key) in SetupTyped.rules.map({ ($0.question, $0.answer) }) {
            XCTAssertNotNil(SetupQuestions.question(id)?.answer(key), "rule \(id).\(key)")
        }
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
