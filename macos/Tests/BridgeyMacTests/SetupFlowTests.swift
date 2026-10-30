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

    /// A fresh install: every feature off, a phone paired, every permission allowed.
    private var paired: SetupFacts {
        var facts = SetupFacts(paired: true, granted: Set(SetupPermission.allCases), allowed: Set(SetupPermission.allCases))
        for feature in SetupFeatures.all { for change in feature.off { facts.current[change.setting] = change.value } }
        return facts
    }

    /// The same, with no permission allowed yet (Local Network and Automation still count as not refused).
    private var askingFacts: SetupFacts {
        var facts = paired
        facts.allowed = []
        facts.granted = [.localNetwork, .automation]
        return facts
    }

    private func run(_ events: [SetupEvent], facts: SetupFacts, from start: SetupFlow = SetupFlow()) -> SetupFlow {
        var flow = start
        for event in events { flow.send(event, facts: facts) }
        return flow
    }

    /// From the Intro with `chosen`, Not now on every follow-up and Continue on the pages; the screens shown.
    private func walk(_ facts: SetupFacts, chosen: [String: String] = [:]) -> (screens: [SetupScreen], flow: SetupFlow) {
        var flow = run([.chooseAdvanced, .startQuestions(chosen)], facts: facts)
        var shown: [SetupScreen] = []
        while flow.screen != .summary {
            shown.append(flow.screen)
            switch flow.screen {
            case .question: flow.send(.notNow, facts: facts)
            default: flow.send(.proceed, facts: facts)
            }
            XCTAssertLessThan(shown.count, 20)
        }
        return (shown, flow)
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
        flow.send(.next)
        XCTAssertTrue(flow.isLastPage)
        flow.send(.next)
        XCTAssertEqual(flow.screen, .done)
        XCTAssertTrue(flow.skipped.isEmpty)
    }

    func testQuickSetupTurnsOnTheEssentialsOnlyWhereTheyAreOff() {
        let fresh = SetupFlow().changes(for: .chooseQuick, facts: paired)
        XCTAssertEqual(Set(fresh), [.on(.featureClipboard), .off(.autoClipboard), .on(.featureNotifications)])
        // A rerun with an automatic clipboard keeps it.
        var rerun = paired
        rerun.current[.featureClipboard] = "true"
        rerun.current[.autoClipboard] = "true"
        XCTAssertEqual(SetupFlow().changes(for: .chooseQuick, facts: rerun), [.on(.featureNotifications)])
    }

    func testThePathAsksOnlyForWhatWasPicked() {
        let (screens, flow) = walk(paired, chosen: ["notifications": SetupAnswerKey.pick, "files": SetupAnswerKey.pick])
        XCTAssertEqual(screens, [.question("codes"), .question("files_photos"), .switches])
        XCTAssertEqual(flow.picked, ["notifications", "files"])
        XCTAssertEqual(flow.pathLength(paired), 1 + 2 + 1 + 1, "everything allowed: no permissions page")
        // Nothing picked: straight to the switches.
        XCTAssertEqual(walk(paired).screens, [.switches])
    }

    func testTypicalPathsAreFiveToEightSteps() {
        var fresh = askingFacts
        fresh.paired = false
        let cases: [[String: String]] = [
            ["clipboard": SetupAnswerKey.pick],
            ["notifications": SetupAnswerKey.pick, "files": SetupAnswerKey.pick],
            ["calls": SetupAnswerKey.pick, "notifications": SetupAnswerKey.pick, "remote": SetupAnswerKey.pick, "mac_actions": SetupAnswerKey.pick],
        ]
        for chosen in cases {
            let (screens, flow) = walk(fresh, chosen: chosen)
            let length = flow.pathLength(fresh)
            XCTAssertEqual(screens.count + 2, run([.chooseAdvanced, .startQuestions(chosen)], facts: fresh).pathLength(fresh), "\(chosen)")
            XCTAssertTrue((5...8).contains(length), "\(chosen): \(length) steps")
            XCTAssertEqual(screens.first, .question("pair"), "no phone yet: pairing first")
            XCTAssertTrue(screens.contains(.permissions))
        }
    }

    func testStepsLeftFollowsTheActualPath() {
        let intro = run([.chooseAdvanced], facts: askingFacts)
        // Nothing picked: the switches and nothing else.
        XCTAssertEqual(intro.stepsLeft(askingFacts), 1)
        XCTAssertEqual(intro.stepsLeft(ifStarted: ["clipboard": SetupAnswerKey.pick], facts: askingFacts), 3, "follow-up, switches, permissions")
        var flow = run([.startQuestions(["clipboard": SetupAnswerKey.pick, "calls": SetupAnswerKey.pick])], facts: askingFacts, from: intro)
        XCTAssertEqual(flow.screen, .question("clipboard"))
        XCTAssertEqual(flow.stepsLeft(askingFacts), 3)
        flow.send(.answer("clipboard", SetupAnswerKey.auto), facts: askingFacts)
        XCTAssertEqual(flow.screen, .question("calls_ring"))
        XCTAssertEqual(flow.stepsLeft(askingFacts), 2)
        flow.send(.notNow, facts: askingFacts)
        XCTAssertEqual(flow.screen, .switches)
        XCTAssertEqual(flow.stepsLeft(askingFacts), 1)
        XCTAssertLessThan(SetupQuestions.all.count + 2, 26)
    }

    func testTheSwitchesPageListsEveryOtherFeatureAndTurnsThemOn() {
        var flow = run([.chooseAdvanced, .startQuestions(["clipboard": SetupAnswerKey.auto])], facts: paired)
        XCTAssertEqual(flow.screen, .switches, "typed answer: no follow-up")
        XCTAssertEqual(flow.changes(for: .setSwitch("battery", true), facts: paired), [.on(.featureBattery)])
        flow.send(.setSwitch("battery", true), facts: paired)
        flow.send(.setSwitch("remote", true), facts: paired)
        XCTAssertEqual(flow.switches, ["battery": true, "remote": true])
        let effective = flow.effective(paired)
        XCTAssertTrue(effective.on(.featureBattery))
        XCTAssertTrue(effective.on(.remoteGrant))
        XCTAssertFalse(effective.on(.featureFiles))
    }

    func testThePermissionsPageListsOnlyWhatIsNeededAndContinueAlwaysWorks() {
        var flow = run([.chooseAdvanced, .startQuestions(["notifications": SetupAnswerKey.pick, "codes": SetupAnswerKey.no])], facts: askingFacts)
        XCTAssertEqual(flow.screen, .switches)
        flow.send(.setSwitch("remote", true), facts: askingFacts)
        flow.send(.proceed, facts: askingFacts)
        XCTAssertEqual(flow.screen, .permissions)
        XCTAssertEqual(flow.neededPermissions(askingFacts).map(\.permission), [.localNetwork, .notifications, .accessibility])
        flow.send(.asked([.notifications]), facts: askingFacts)
        // Notifications allowed, Accessibility refused: remote control stays off, setup goes on.
        var after = askingFacts
        after.allowed = [.notifications]
        after.granted = [.notifications, .localNetwork, .automation]
        let undo = flow.changes(for: .proceed, facts: after)
        XCTAssertTrue(undo.contains(.off(.featureRemoteInput)))
        XCTAssertFalse(undo.contains(.off(.featureNotifications)))
        flow.send(.proceed, facts: after)
        XCTAssertEqual(flow.screen, .summary)
        XCTAssertEqual(flow.refused, [.accessibility])
        XCTAssertFalse(flow.effective(after).on(.featureRemoteInput))
        XCTAssertTrue(flow.asked.contains(.notifications))
        // Back from the summary returns to the permissions page, and from there to the switches.
        flow.send(.back)
        XCTAssertEqual(flow.screen, .permissions)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .switches)
    }

    func testThePermissionsPageIsSkippedWhenEverythingIsAllowed() {
        let flow = run([.chooseAdvanced, .startQuestions(["notifications": SetupAnswerKey.pick, "codes": SetupAnswerKey.no]), .proceed], facts: paired)
        XCTAssertEqual(flow.screen, .summary)
    }

    func testBackWalksTheScreensShownAndKeepsAnswers() {
        var flow = run([.chooseAdvanced, .startQuestions(["clipboard": SetupAnswerKey.pick, "media": SetupAnswerKey.pick])], facts: paired)
        flow.send(.answer("clipboard", SetupAnswerKey.tap), facts: paired)
        XCTAssertEqual(flow.screen, .question("media"))
        flow.send(.back)
        XCTAssertEqual(flow.screen, .question("clipboard"))
        XCTAssertEqual(flow.answers["clipboard"], SetupAnswerKey.tap)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .intro)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .welcome)
        XCTAssertEqual(SetupBack.decide(flow), .askLeave, "something was chosen")
    }

    func testFollowUpsAnswerTheirFeature() {
        let flow = run([.chooseAdvanced, .startQuestions(["media": SetupAnswerKey.pick]), .answer("media", SetupAnswerKey.spotify)], facts: paired)
        XCTAssertEqual(flow.effective(paired)[.mediaPlayer], "spotify")
        XCTAssertTrue(flow.effective(paired).on(.featureMedia))
        let items = SetupSummary.items(run([.proceed, .proceed], facts: paired, from: flow), facts: paired)
        guard case let .featureOn(feature, on, detail) = items.first else { return XCTFail("\(items)") }
        XCTAssertEqual(feature.id, "media")
        XCTAssertTrue(on)
        XCTAssertEqual(detail, SetupQuestions.question("media")?.answer(SetupAnswerKey.spotify)?.label)
    }

    /// A fresh install never set Connect away from home, so it is on: the summary lists it with its switch, and
    /// Get started quickly leaves it on. An explicit off from before stays off.
    func testConnectAwayIsOnInTheSummaryAndAfterTheEssentials() {
        var facts = paired
        facts.current[.connectAway] = nil
        XCTAssertEqual(facts.value(.connectAway), "true")
        let flow = walk(facts).flow
        let on = SetupSummary.items(flow, facts: facts).compactMap { item -> (String, Bool)? in
            if case let .featureOn(feature, on, _) = item { (feature.id, on) } else { nil }
        }
        XCTAssertEqual(on.map { $0.0 }, ["away"])
        XCTAssertEqual(on.map { $0.1 }, [true])
        XCTAssertNil(flow.effective(facts).overlay[.connectAway], "nothing in the run sets it, so it keeps following the default")
        XCTAssertTrue(flow.changes(for: .summarySwitch("away", false), facts: facts).contains(.off(.connectAway)))
        XCTAssertFalse(SetupBundles.essentialChanges(SetupEffective(facts: facts)).contains { $0.setting == .connectAway })
        XCTAssertFalse(SetupFlow().changes(for: .chooseQuick, facts: facts).contains { $0.setting == .connectAway })
        let off = walk(paired).flow
        XCTAssertFalse(SetupSummary.items(off, facts: paired).contains { if case .featureOn = $0 { true } else { false } })
    }

    func testSummaryListsWhatIsOnChoicesAndRefusals() {
        var flow = run([.chooseAdvanced, .startQuestions(["remote": SetupAnswerKey.pick, "updates": SetupAnswerKey.early, "focus": SetupAnswerKey.both])], facts: askingFacts)
        while flow.screen != .summary { flow.send(.proceed, facts: askingFacts) }
        let items = SetupSummary.items(flow, facts: askingFacts)
        XCTAssertEqual(items.compactMap { if case let .chosen(title, _, _) = $0 { title } else { nil } }.count, 2)
        XCTAssertTrue(items.contains { if case let .notAllowed(need) = $0 { need.permission == .accessibility } else { false } })
        XCTAssertFalse(items.contains { if case let .featureOn(feature, _, _) = $0 { feature.id == "remote" } else { false } }, "refused: stays off")
        flow.send(.summarySwitch("remote", false))
        XCTAssertTrue(flow.changes(for: .summarySwitch("remote", true), facts: askingFacts).contains(.on(.featureRemoteInput)))
        XCTAssertEqual(flow.choices.settings["updateChannel"], "beta")
    }

    func testTheFlowSurvivesQuittingOnThePermissionsPage() {
        var flow = run([.chooseAdvanced, .startQuestions(["notifications": SetupAnswerKey.pick, "codes": SetupAnswerKey.onMac])], facts: askingFacts)
        flow.send(.setSwitch("battery", true), facts: askingFacts)
        flow.send(.proceed, facts: askingFacts)
        flow.send(.asked([.notifications]))
        XCTAssertEqual(flow.screen, .permissions)
        let store = SetupStore(defaults: defaults)
        store.savedFlow = flow
        var restored = store.savedFlow
        XCTAssertEqual(restored, flow)
        restored?.send(.back)
        XCTAssertEqual(restored?.screen, .switches)
        XCTAssertNil(SetupFlow.decode(Data("nonsense".utf8)))
        store.finish(SetupChoices())
        XCTAssertNil(store.savedFlow, "finishing forgets the saved step")
    }

    // MARK: Coverage and mapping

    func testEverySettingIsCovered() {
        let coverage = SetupQuestions.coverage
        let missing = SetupSetting.allCases.filter { coverage[$0] == nil }
        XCTAssertEqual(missing, [], "settings no question, switch, permission or Settings page covers")
        for (setting, place) in coverage {
            switch place.how {
            case .answer:
                let question = SetupQuestions.question(place.place)
                XCTAssertTrue(setting == .pairing || question?.answers.contains { $0.changes.contains { $0.setting == setting } } == true,
                              "\(setting) is not set by \(place.place)")
            case .featureSwitch:
                XCTAssertTrue(SetupFeatures.all.contains { $0.on.contains { $0.setting == setting } }, "\(setting)")
            case .permission:
                XCTAssertNotNil(SetupQuestions.byPermission[setting])
            case .moreOptions:
                XCTAssertNotNil(SettingsPane(rawValue: place.place), "\(setting)")
            case .summary:
                XCTAssertTrue(SetupQuestions.bySummary.contains(setting), "\(setting)")
            }
        }
    }

    func testEveryFollowUpBelongsToAFeatureAndSetsOnlyWhatItCovers() {
        var owners: Set<String> = []
        for question in SetupQuestions.all where question.id != "pair" {
            let feature = try? XCTUnwrap(question.feature)
            XCTAssertNotNil(feature.flatMap(SetupFeatures.feature), question.id)
            XCTAssertTrue(owners.insert(feature ?? "").inserted, "one follow-up per feature: \(question.id)")
            for change in question.answers.flatMap(\.changes) {
                XCTAssertTrue(question.covers.contains(change.setting), "\(question.id) sets \(change.setting)")
            }
        }
    }

    func testAnswersMapToSettings() {
        func changes(_ id: String, _ key: String) -> [SettingChange] { SetupQuestions.changes(SetupQuestions.question(id)!, key) }
        XCTAssertEqual(changes("clipboard", SetupAnswerKey.auto), [.on(.featureClipboard), .on(.autoClipboard)])
        XCTAssertEqual(changes("clipboard", SetupAnswerKey.tap), [.on(.featureClipboard), .off(.autoClipboard)])
        XCTAssertEqual(changes("codes", SetupAnswerKey.cloud), [.on(.codesEnabled), .set(.codesEngine, "cloud")])
        XCTAssertEqual(changes("calls_ring", SetupAnswerKey.no), [.off(.ringForCalls)])
        XCTAssertEqual(changes("files_photos", SetupAnswerKey.yes), [.set(.sendImageMode, "optimize")])
        XCTAssertEqual(changes("media", SetupAnswerKey.music), [.on(.featureMedia), .set(.mediaPlayer, "music")])
        XCTAssertEqual(changes("links", SetupAnswerKey.wait), [.on(.featureLinks), .off(.openLinksRightAway)])
        XCTAssertEqual(changes("messages", SetupAnswerKey.yes), [.on(.featureMessages), .on(.smsKeepOnMac)])
        XCTAssertEqual(changes("messages", SetupAnswerKey.no), [.on(.featureMessages), .off(.smsKeepOnMac)])
        XCTAssertEqual(SetupBundles.all.first { $0.id == "messages" }?.answers.map(\.id), ["messages"])
        XCTAssertTrue(SetupQuestions.need(.notifications)?.features.contains("messages") == true)
        // The phone-to-Mac link (Android 15+) is one link for codes and Text messages; the Mac advertises it over Bluetooth.
        let bluetooth = SetupQuestions.need(.bluetooth)!
        XCTAssertTrue(bluetooth.features.contains("messages"))
        XCTAssertTrue(bluetooth.needed(SetupEffective(facts: SetupFacts(), overlay: [.featureNotifications: "true", .featureMessages: "true", .codesEnabled: "false"])))
        XCTAssertFalse(bluetooth.needed(SetupEffective(facts: SetupFacts(), overlay: [.featureNotifications: "false", .featureMessages: "true"])))
        XCTAssertEqual(SetupFeatures.feature("mac_actions")?.on, [.on(.featureMacActions), .on(.macActionsGrant), .set(.macActionSwitches, "lock,sleep,volume")])
        XCTAssertEqual(SetupQuestions.typedOnly["updates"]?[SetupAnswerKey.newest], [.set(.updateChannel, "nightly"), .on(.updatesAutoAll)])
        XCTAssertEqual(SetupQuestions.need(.accessibility)?.offWhenRefused.first, .off(.featureRemoteInput))
    }

    func testCloudCodesAreOfferedOnlyWithARelay() {
        let codes = SetupQuestions.question("codes")!
        XCTAssertEqual(codes.visibleAnswers(SetupFacts(codesAvailable: false)).map(\.key), [SetupAnswerKey.onMac, SetupAnswerKey.no])
        XCTAssertEqual(codes.visibleAnswers(SetupFacts()).count, 3)
    }

    func testBundlesAndSwitchesUseTheSettingsNames() {
        // Text messages has its own page, as on the phone: its bundle, switch and page share one name.
        // Show phone screens is a switch on the Remote control page, not a feature of its own.
        let names = Set(SettingsPane.allCases.map(\.title) + BridgeyFeature.allCases.map(\.title) + [PhoneScreenSettings.switchTitle])
        XCTAssertEqual(SetupFeatures.textMessagesTitle, SettingsPane.messages.title)
        XCTAssertEqual(SetupFeatures.feature("messages")?.pane, .messages)
        XCTAssertEqual(SetupQuestions.question("messages")?.pane, .messages)
        XCTAssertTrue(SettingsPane.sidebarItems.contains(.messages))
        for bundle in SetupBundles.all {
            XCTAssertEqual(bundle.title, bundle.pane.title)
            XCTAssertTrue(names.contains(bundle.title), bundle.title)
            for (id, key) in bundle.answers { XCTAssertNotNil(SetupFeatures.feature(id), "\(bundle.id): \(id)=\(key)") }
        }
        for feature in SetupFeatures.all { XCTAssertTrue(names.contains(feature.title), feature.title) }
    }

    /// Connect away from home: on until chosen (Rahul, 2026-10-30), its own switch, follow-up and bundle (same ids as
    /// Android).
    func testConnectAwayIsAFeatureAQuestionAndABundle() {
        XCTAssertEqual(SetupSetting.connectAway.defaultValue, "true")
        XCTAssertEqual(SetupFeatures.feature("away")?.on, [.on(.connectAway)])
        let question = SetupQuestions.question("away")!
        XCTAssertEqual(question.section, .devices)
        XCTAssertEqual(question.feature, "away")
        XCTAssertEqual(SetupQuestions.changes(question, SetupAnswerKey.yes), [.on(.connectAway)])
        XCTAssertEqual(SetupQuestions.changes(question, SetupAnswerKey.no), [.off(.connectAway)])
        XCTAssertEqual(SetupQuestions.coverage[.connectAway]?.place, "away")
        let bundle = SetupBundles.all.first { $0.id == "away" }
        XCTAssertEqual(bundle?.title, SettingsPane.away.title)
        XCTAssertEqual(SetupBundles.answers(picked: ["away"], typed: []).map(\.id), ["away"])
        XCTAssertEqual(SettingsPane.away.parentPane, .devices)
        XCTAssertFalse(SettingsPane.sidebarItems.contains(.away))
    }

    // MARK: Back, Escape and the close button

    func testEscapeStepsBackAndLeavesOnlyFromTheFirstScreen() {
        var flow = SetupFlow()
        XCTAssertEqual(SetupBack.decide(flow), .leave)
        XCTAssertFalse(SetupBack.closeAsks(flow))
        flow.send(.chooseAdvanced)
        XCTAssertEqual(SetupBack.decide(flow), .step)
        XCTAssertTrue(SetupBack.closeAsks(flow))
        flow.send(.startQuestions(["clipboard": SetupAnswerKey.pick]), facts: paired)
        XCTAssertEqual(SetupBack.decide(flow), .step)
        flow.send(.back)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .welcome)
        XCTAssertEqual(SetupBack.decide(flow), .askLeave)
        XCTAssertTrue(SetupBack.closeAsks(flow))
        flow.send(.askLeave)
        XCTAssertTrue(flow.confirmLeave)
        flow.send(.keepGoing)
        XCTAssertFalse(flow.confirmLeave)
        var done = SetupFlow()
        done.send(.chooseQuick)
        done.send(.finish)
        XCTAssertFalse(SetupBack.closeAsks(done))
    }

    func testReviewSetupStartsAtTheIntroAndLeavesFromThere() {
        var flow = SetupFlow.review()
        XCTAssertEqual(flow.screen, .intro)
        XCTAssertEqual(SetupBack.decide(flow), .leave)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .intro)
        flow.send(.startQuestions(["battery": SetupAnswerKey.pick]), facts: paired)
        XCTAssertEqual(flow.screen, .switches)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .intro)
        XCTAssertEqual(SetupBack.decide(flow), .askLeave)
    }

    func testSkippingAPermissionStepRecordsItAsSkippedNotGranted() {
        var flow = SetupFlow()
        flow.send(.chooseQuick)
        flow.send(.next)
        flow.send(.skip)
        XCTAssertEqual(flow.screen, .quick(.pairPhone))
        XCTAssertEqual(flow.skipped, [.notifications])
        flow.send(.skip)
        XCTAssertTrue(flow.pairingSkipped)
        XCTAssertEqual(flow.screen, .done)
        XCTAssertEqual(flow.choices.skippedPermissions, [.notifications])
        let store = SetupStore(defaults: defaults)
        store.finish(flow.choices)
        XCTAssertEqual(store.skipped, [.notifications])
        XCTAssertEqual(store.choices, flow.choices)
    }

    func testBackFromTheFirstQuickStepReturnsToWelcome() {
        var flow = SetupFlow()
        flow.send(.chooseQuick)
        flow.send(.back)
        XCTAssertEqual(flow.screen, .welcome)
        XCTAssertNil(flow.path)
    }

    // MARK: Type what you want

    private func match(_ text: String) -> [String] { SetupTyped.match(text).map { "\($0.id)=\($0.key)" } }

    func testTypedSentencesMatchTheSameFeaturesAsAndroid() {
        XCTAssertEqual(match("I mainly want my WhatsApp notifications and to send photos to my Mac"), ["notifications=pick", "files=pick"])
        XCTAssertEqual(match("copy paste and calls but no music"), ["clipboard=pick", "calls=pick", "media=no"])
        XCTAssertEqual(match("Хочу уведомления и фото на Mac, без звонков"), ["notifications=pick", "calls=no", "files=pick"])
        XCTAssertEqual(match("Do not disturb in sync, and beta updates"), ["focus=both", "updates=early"])
        XCTAssertEqual(match("control my mac with a touchpad for slides"), ["remote=pick"])
        XCTAssertEqual(match(""), [])
        // Mac only: codes read on this Mac; there is no camera switch here.
        XCTAssertEqual(match("codes from messages"), ["codes=on_mac"])
        XCTAssertEqual(match("I want to answer SMS from my Mac"), ["messages=pick"])
        XCTAssertEqual(match("Хочу отвечать на смс с Mac"), ["messages=pick"])
        XCTAssertEqual(match("no camera"), [])
        // Phone screen (v0.9): sharing words, not "screen" alone (screen saver, lock screen).
        XCTAssertEqual(match("I want to see my phone screen on the Mac"), ["screen=pick"])
        XCTAssertEqual(match("screen sharing but no music"), ["media=no", "screen=pick"])
        XCTAssertEqual(match("показывать экран телефона"), ["screen=pick"])
        XCTAssertEqual(match("lock the screen"), ["mac_actions=pick"])
    }

    func testTheRemoteControlBundleAsksAboutThePhoneScreen() {
        let bundle = SetupBundles.all.first { $0.id == "remote" }
        XCTAssertTrue(bundle?.answers.contains { $0.id == "screen" && $0.key == SetupAnswerKey.pick } == true)
        let (screens, flow) = walk(paired, chosen: ["screen": SetupAnswerKey.pick])
        XCTAssertEqual(screens, [.question("screen"), .switches])
        XCTAssertTrue(flow.effective(paired).on(.featureScreen), "picked: on")
        XCTAssertEqual(SetupQuestions.changes(SetupQuestions.question("screen")!, SetupAnswerKey.no), [.off(.featureScreen)])
        XCTAssertEqual(SetupSetting.featureScreen.defaultValue, "false", "off even on installs from before")
        XCTAssertEqual(SetupQuestions.coverage[.featureScreen]?.how, .answer)
    }

    func testTypedAnswersPickTheirFeatureAndSkipTheirFollowUp() {
        let flow = run([.chooseAdvanced, .startQuestions(["codes": SetupAnswerKey.onMac, "clipboard": SetupAnswerKey.pick])], facts: paired)
        XCTAssertEqual(flow.picked, ["clipboard", "notifications"])
        XCTAssertEqual(flow.screen, .question("clipboard"), "codes was typed, so only the clipboard follow-up is left")
        let noMusic = run([.chooseAdvanced, .startQuestions(["media": SetupAnswerKey.no])], facts: paired)
        XCTAssertEqual(noMusic.switches, ["media": false])
    }

    // MARK: Defaults generation

    func testAFreshInstallStartsWithEveryFeatureOff() {
        let generation = DefaultsGeneration.settle(defaults, priorInstall: SetupLaunch.hasStoredState(keys: defaults.dictionaryRepresentation().keys,
                                                                                                         trustFileExists: false))
        XCTAssertEqual(generation, DefaultsGeneration.offUntilChosen)
        XCTAssertTrue(DefaultsGeneration.globalFeatures(defaults).values.allSatisfy { !$0 })
        // Settled once: later launches, with settings written, keep it.
        defaults.set(UUID().uuidString, forKey: "deviceID")
        XCTAssertEqual(DefaultsGeneration.settle(defaults, priorInstall: true), DefaultsGeneration.offUntilChosen)
        // Turned on in setup or Settings: the stored switch wins.
        defaults.set(true, forKey: "settings.global.clipboard")
        XCTAssertEqual(DefaultsGeneration.globalFeatures(defaults)[.clipboard], true)
    }

    func testAnUpgradeFromBeta1KeepsEveryFeatureExactlyAsItWas() {
        // 0.10 beta 1: a device ID, some switches stored, most never touched (their defaults).
        defaults.set(UUID().uuidString, forKey: "deviceID")
        defaults.set("local", forKey: "settings.codes.engine")
        defaults.set(false, forKey: "settings.global.files")
        defaults.set(true, forKey: "settings.global.media")
        let before: [BridgeyFeature: Bool] = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map {
            ($0, defaults.object(forKey: "settings.global.\($0.rawValue)") as? Bool ?? ($0 != .media && $0 != .remoteInput && $0 != .macActions))
        })
        let generation = DefaultsGeneration.settle(defaults, priorInstall: SetupLaunch.hasStoredState(keys: defaults.dictionaryRepresentation().keys,
                                                                                                         trustFileExists: false))
        XCTAssertEqual(generation, DefaultsGeneration.featuresOn)
        XCTAssertEqual(DefaultsGeneration.globalFeatures(defaults), before)
        XCTAssertEqual(DefaultsGeneration.globalFeatures(defaults)[.clipboard], true)
        XCTAssertEqual(DefaultsGeneration.globalFeatures(defaults)[.files], false)
        XCTAssertEqual(DefaultsGeneration.globalFeatures(defaults)[.remoteInput], false)
    }

    func testTheStoredGenerationWinsAndSurvivesASettingsReset() {
        defaults.set(DefaultsGeneration.offUntilChosen, forKey: DefaultsGeneration.key)
        XCTAssertEqual(DefaultsGeneration.settle(defaults, priorInstall: true), DefaultsGeneration.offUntilChosen)
        XCTAssertEqual(DefaultsGeneration.resolve(stored: 1, priorInstall: false), 1)
        XCTAssertEqual(DefaultsGeneration.resolve(stored: nil, priorInstall: false), DefaultsGeneration.offUntilChosen)
        XCTAssertEqual(DefaultsGeneration.resolve(stored: nil, priorInstall: true), DefaultsGeneration.featuresOn)
        // Reset > Settings removes settings.* and setup.* keys, not this one.
        XCTAssertFalse(LocalDataReset.settingsPrefixes.contains { DefaultsGeneration.key.hasPrefix($0) })
        XCTAssertFalse(LocalDataReset.settingsKeys.contains(DefaultsGeneration.key))
        // An install that never settled one (the old build, tests) keeps the old defaults.
        let unset = UserDefaults(suiteName: suiteName + ".unset")!
        XCTAssertEqual(DefaultsGeneration.current(unset), DefaultsGeneration.featuresOn)
        unset.removePersistentDomain(forName: suiteName + ".unset")
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
