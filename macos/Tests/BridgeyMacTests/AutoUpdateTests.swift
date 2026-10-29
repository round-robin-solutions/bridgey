import Foundation
import XCTest
@testable import BridgeyMac

/// Update all devices automatically: the defaults, the check schedule, the defer rules, coalescing,
/// the run's hold and countdown, the notice, the activity words, setup, and the command line.
final class AutoUpdateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_091_600)
    private let mac = "55555555-5555-4555-8555-555555555555"
    private let lowPhone = "11111111-1111-4111-8111-111111111111"
    private let highPhone = "99999999-9999-4999-8999-999999999999"

    private func status(_ state: PeerUpdateState = .current, app: String = "0.10.0-rr.1-beta.10", build: Int = 263_011_402,
                        channel: UpdateChannel = .beta, target: String? = nil, targetBuild: Int? = nil,
                        reason: PeerUpdateReason? = nil, remoteStart: Bool = true, checkedAt: Date? = nil,
                        platform: UpdatePlatform = .android, auto: Bool = false, busy: UpdateBusy? = nil) -> PeerUpdateStatus {
        PeerUpdateStatus(platform: platform, edition: "rr", app: app, build: build, channel: channel, state: state, target: target,
                         targetBuild: targetBuild, reason: reason, remoteStart: remoteStart,
                         checkedAt: Int(((checkedAt ?? t0).timeIntervalSince1970 * 1000).rounded()), auto: auto, busy: busy)
    }

    private var localNew: PeerUpdateStatus {
        status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, platform: .macos, auto: true)
    }

    private var localCurrent: PeerUpdateStatus { status(platform: .macos, auto: true) }

    private func facts(at seconds: TimeInterval = 0, enabled: Bool = true, local: PeerUpdateStatus? = nil, localBusy: UpdateBusy? = nil,
                       peers: [AutoPeer] = [], runActive: Bool = false, updatingForPeer: Bool = false, idle: Bool = false,
                       localID: String? = nil) -> AutoFacts {
        AutoFacts(now: t0.addingTimeInterval(seconds), enabled: enabled, localID: localID ?? mac, localName: "This Mac",
                  local: local ?? localNew, localBusy: localBusy, peers: peers, runActive: runActive,
                  updatingForPeer: updatingForPeer, idle: idle)
    }

    private func peer(_ id: String, _ name: String = "OnePlus 11", _ status: PeerUpdateStatus) -> AutoPeer {
        AutoPeer(id: id, name: name, status: status)
    }

    // MARK: Defaults and the explicit choice

    func testDefaultFollowsTheChannelUntilThePersonChooses() {
        XCTAssertFalse(AutoUpdateRules.enabled(stored: nil, channel: .stable))
        XCTAssertTrue(AutoUpdateRules.enabled(stored: nil, channel: .beta))
        XCTAssertTrue(AutoUpdateRules.enabled(stored: nil, channel: .nightly))
        XCTAssertFalse(AutoUpdateRules.enabled(stored: false, channel: .beta), "an explicit Off survives a Beta channel")
        XCTAssertTrue(AutoUpdateRules.enabled(stored: true, channel: .stable), "an explicit On survives a Stable channel")
    }

    @MainActor
    func testTheChoiceIsStoredOnlyWhenThePersonMakesIt() throws {
        let suite = "AutoUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // An install from before this feature: the channel is set, the switch was never touched.
        defaults.set("beta", forKey: UpdateChannel.defaultsKey)
        let before = AutoUpdateCoordinator(defaults: defaults)
        XCTAssertNil(before.storedChoice)
        XCTAssertEqual(UpdateChannel.stored(in: defaults), .beta, "the channel the person picked stays")
        before.setEnabled(false)
        XCTAssertEqual(AutoUpdateCoordinator(defaults: defaults).storedChoice, false)
        XCTAssertEqual(defaults.object(forKey: AutoUpdateCoordinator.choiceKey) as? Bool, false)
    }

    // MARK: Checks

    func testCheckIntervalByChannelAndSetting() {
        XCTAssertNil(AutoUpdateRules.checkInterval(enabled: false, channel: .beta), "off: Sparkle's own daily schedule")
        XCTAssertEqual(AutoUpdateRules.checkInterval(enabled: true, channel: .stable), 6 * 3600)
        XCTAssertEqual(AutoUpdateRules.checkInterval(enabled: true, channel: .beta), 30 * 60)
        XCTAssertEqual(AutoUpdateRules.checkInterval(enabled: true, channel: .nightly), 30 * 60)
        XCTAssertTrue(AutoUpdateRules.checkDue(lastCheck: nil, now: t0, interval: 1800))
        XCTAssertFalse(AutoUpdateRules.checkDue(lastCheck: t0, now: t0.addingTimeInterval(1799), interval: 1800))
        XCTAssertTrue(AutoUpdateRules.checkDue(lastCheck: t0, now: t0.addingTimeInterval(1800), interval: 1800))
        XCTAssertTrue(AutoUpdateRules.checkDue(lastCheck: t0, now: t0.addingTimeInterval(-60), interval: 1800), "a clock that went back")
    }

    func testAtLaunchItWaitsAMinuteForPairedPhonesToReconnect() {
        XCTAssertTrue(AutoUpdateRules.settling(launchedAt: t0, now: t0.addingTimeInterval(5), paired: [highPhone], ready: []))
        XCTAssertFalse(AutoUpdateRules.settling(launchedAt: t0, now: t0.addingTimeInterval(5), paired: [highPhone], ready: [highPhone]))
        XCTAssertFalse(AutoUpdateRules.settling(launchedAt: t0, now: t0.addingTimeInterval(60), paired: [highPhone], ready: []),
                       "a phone that stays away is left out after a minute")
        XCTAssertFalse(AutoUpdateRules.settling(launchedAt: t0, now: t0.addingTimeInterval(5), paired: [], ready: []))
    }

    func testWakeAndNetworkChecksAreRateLimited() {
        XCTAssertTrue(AutoUpdateRules.eventCheckAllowed(lastCheck: nil, lastEventCheck: nil, now: t0))
        XCTAssertFalse(AutoUpdateRules.eventCheckAllowed(lastCheck: t0, lastEventCheck: nil, now: t0.addingTimeInterval(599)))
        XCTAssertFalse(AutoUpdateRules.eventCheckAllowed(lastCheck: t0.addingTimeInterval(-3600), lastEventCheck: t0, now: t0.addingTimeInterval(300)))
        XCTAssertTrue(AutoUpdateRules.eventCheckAllowed(lastCheck: t0.addingTimeInterval(-3600), lastEventCheck: t0, now: t0.addingTimeInterval(600)))
    }

    // MARK: Defer rules

    func testNothingHappensWithTheSettingOffOrNothingNew() {
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(enabled: false), memory: AutoMemory()).decision, .off)
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(local: localCurrent), memory: AutoMemory()).decision, .nothingToDo)
        let didNotApply = status(.failed, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, reason: .notApplied, platform: .macos)
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(local: didNotApply), memory: AutoMemory()).decision, .notApplied,
                       "a version that did not apply is never tried again on its own")
    }

    func testANewBuildStartsAndRemembersWhenItWasFound() {
        let step = AutoUpdatePolicy.decide(facts(), memory: AutoMemory())
        XCTAssertEqual(step.decision, .start(targetBuild: 263_020_900, refreshBefore: t0))
        XCTAssertEqual(step.memory.targetBuild, 263_020_900)
        XCTAssertEqual(step.memory.foundAt, t0)
        // Found earlier: phones that said "up to date" since then are not asked again.
        let later = AutoUpdatePolicy.decide(facts(at: 600), memory: step.memory)
        XCTAssertEqual(later.decision, .start(targetBuild: 263_020_900, refreshBefore: t0))
    }

    func testARunOrAnotherDevicesUpdateBlocksANewRun() {
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(runActive: true), memory: AutoMemory()).decision, .running)
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(updatingForPeer: true), memory: AutoMemory()).decision, .running)
    }

    func testBusyHereOrOnAPeerWaitsAndLooksAgainEveryFiveMinutes() {
        var step = AutoUpdatePolicy.decide(facts(localBusy: .transfer), memory: AutoMemory())
        XCTAssertEqual(step.decision, .wait(.transfer, device: nil, until: t0.addingTimeInterval(300)))
        XCTAssertEqual(step.log, .waiting(.transfer, device: nil))
        // A call on the phone outranks a transfer here.
        let calling = peer(highPhone, "OnePlus 11", status(busy: .call))
        step = AutoUpdatePolicy.decide(facts(localBusy: .transfer, peers: [calling]), memory: AutoMemory())
        XCTAssertEqual(step.decision, .wait(.call, device: "OnePlus 11", until: t0.addingTimeInterval(300)))
        XCTAssertEqual(step.log, .waiting(.call, device: "OnePlus 11"))
        // The call ends a minute later: it still waits for the next look, and logs nothing new.
        let waiting = step.memory
        step = AutoUpdatePolicy.decide(facts(at: 60), memory: waiting)
        XCTAssertEqual(step.decision, .wait(.call, device: "OnePlus 11", until: t0.addingTimeInterval(300)))
        XCTAssertNil(step.log)
        // Still on the call at the next look: waits again, same reason, no second entry.
        step = AutoUpdatePolicy.decide(facts(at: 300, peers: [calling]), memory: waiting)
        XCTAssertEqual(step.decision, .wait(.call, device: "OnePlus 11", until: t0.addingTimeInterval(600)))
        XCTAssertNil(step.log)
        // A different activity is logged.
        let sharing = peer(highPhone, "OnePlus 11", status(busy: .screenShare))
        let next = AutoUpdatePolicy.decide(facts(at: 600, peers: [sharing]), memory: step.memory)
        XCTAssertEqual(next.log, .waiting(.screenShare, device: "OnePlus 11"))
        // Nobody busy at the look after: it starts.
        let done = AutoUpdatePolicy.decide(facts(at: 900), memory: next.memory)
        XCTAssertEqual(done.decision, .start(targetBuild: 263_020_900, refreshBefore: t0))
        XCTAssertNil(done.memory.waitUntil)
    }

    func testLaterWaitsAnHourThenOnlyWhenIdleAfterThree() {
        var memory = AutoUpdatePolicy.decide(facts(), memory: AutoMemory()).memory
        for round in 0..<3 {
            let at = TimeInterval(round) * 3600
            memory.later(now: t0.addingTimeInterval(at))
            XCTAssertEqual(AutoUpdatePolicy.decide(facts(at: at + 60), memory: memory).decision,
                           .later(until: t0.addingTimeInterval(at + 3600)))
        }
        XCTAssertEqual(memory.laterCount, 3)
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(at: 3 * 3600), memory: memory).decision, .waitForIdle)
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(at: 3 * 3600, idle: true), memory: memory).decision,
                       .start(targetBuild: 263_020_900, refreshBefore: t0))
        // A newer build starts afresh.
        let newer = status(.available, target: "0.10.0-rr.1-beta.12", targetBuild: 263_030_900, platform: .macos)
        let fresh = AutoUpdatePolicy.decide(facts(at: 3 * 3600, local: newer), memory: memory)
        XCTAssertEqual(fresh.decision, .start(targetBuild: 263_030_900, refreshBefore: t0.addingTimeInterval(3 * 3600)))
        XCTAssertEqual(fresh.memory.laterCount, 0)
    }

    func testARunThatEndedWaitsAnHourBeforeTheSameBuildRunsAgain() {
        // The phone never answered: it still reports the build, but the next run waits an hour.
        let waiting = peer(highPhone, "OnePlus 11", status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, auto: true))
        var memory = AutoUpdatePolicy.decide(facts(local: localCurrent, peers: [waiting]), memory: AutoMemory()).memory
        memory.ran(now: t0.addingTimeInterval(30))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(at: 40, local: localCurrent, peers: [waiting]), memory: memory).decision,
                       .retry(until: t0.addingTimeInterval(3630)))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(at: 3630, local: localCurrent, peers: [waiting]), memory: memory).decision,
                       .start(targetBuild: 263_020_900, refreshBefore: t0))
        // A newer build does not wait.
        let newer = peer(highPhone, "OnePlus 11", status(.available, target: "0.10.0-rr.1-beta.12", targetBuild: 263_030_900, auto: true))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(at: 40, local: localCurrent, peers: [newer]), memory: memory).decision,
                       .start(targetBuild: 263_030_900, refreshBefore: t0.addingTimeInterval(40)))
        var empty = AutoMemory()
        empty.ran(now: t0)
        XCTAssertNil(empty.ranAt, "nothing ran for no build")
    }

    func testLaterOrAnEndInAClickedRunCountsForTheAutomaticRules() {
        // The person clicked Update all and chose Later; the automatic rules see that Later for the same build.
        var memory = AutoMemory().forTarget(263_020_900, now: t0)
        memory.later(now: t0)
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(at: 5), memory: memory).decision, .later(until: t0.addingTimeInterval(3600)))
        // A clicked run that ended with a phone still on offer: no automatic run for an hour.
        let waiting = peer(highPhone, "OnePlus 11", status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, auto: true))
        let peerFacts = facts(local: localCurrent, peers: [waiting])
        XCTAssertEqual(AutoUpdatePolicy.target(peerFacts), 263_020_900)
        var ended = AutoMemory().forTarget(263_020_900, now: t0)
        ended.ran(now: t0)
        XCTAssertEqual(AutoUpdatePolicy.decide(peerFacts, memory: ended).decision, .retry(until: t0.addingTimeInterval(3600)))
        // Memory for another build starts afresh.
        XCTAssertEqual(ended.forTarget(263_030_900, now: t0), AutoMemory(targetBuild: 263_030_900, foundAt: t0))
        XCTAssertEqual(ended.forTarget(263_020_900, now: t0.addingTimeInterval(9)), ended)
    }

    func testMemoryRoundTrips() throws {
        var memory = AutoMemory(targetBuild: 5, foundAt: t0, laterCount: 2, laterUntil: t0, yieldingSince: t0, ranAt: t0,
                                waitUntil: t0, waiting: .phoneFiles, waitingDevice: "Pixel")
        memory.later(now: t0)
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(AutoMemory.self, from: data), memory)
    }

    // MARK: Coalescing

    func testTheLowestDeviceIDWithTheSettingOnStarts() {
        // A phone with a lower ID and the setting on runs it; this Mac waits for it.
        let leader = peer(lowPhone, "OnePlus 11", status(auto: true))
        var step = AutoUpdatePolicy.decide(facts(peers: [leader]), memory: AutoMemory())
        XCTAssertEqual(step.decision, .yield(to: "OnePlus 11", until: t0.addingTimeInterval(900)))
        // The same phone with the setting off does not count.
        let off = peer(lowPhone, "OnePlus 11", status(auto: false))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(peers: [off]), memory: AutoMemory()).decision,
                       .start(targetBuild: 263_020_900, refreshBefore: t0))
        // A higher ID never leads, and IDs compare without case.
        let follower = peer(highPhone, "Pixel", status(auto: true))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(peers: [follower]), memory: AutoMemory()).decision,
                       .start(targetBuild: 263_020_900, refreshBefore: t0))
        XCTAssertNotNil(AutoUpdatePolicy.leader(localID: mac.uppercased(), peers: [leader]))
        // The leader never came: after 15 minutes this Mac updates itself.
        step = AutoUpdatePolicy.decide(facts(at: 899, peers: [leader]), memory: step.memory)
        XCTAssertEqual(step.decision, .yield(to: "OnePlus 11", until: t0.addingTimeInterval(900)))
        step = AutoUpdatePolicy.decide(facts(at: 900, peers: [leader]), memory: step.memory)
        XCTAssertEqual(step.decision, .start(targetBuild: 263_020_900, refreshBefore: t0))
    }

    func testTheLeaderRunsForPeersThatWaitForIt() {
        // This Mac is up to date and has the lowest ID; a phone with the setting on found a build.
        let waiting = peer(highPhone, "OnePlus 11", status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, auto: true))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(local: localCurrent, peers: [waiting]), memory: AutoMemory()).decision,
                       .start(targetBuild: 263_020_900, refreshBefore: t0))
        // A phone without the setting is only updated when this Mac runs for its own build.
        let manual = peer(highPhone, "OnePlus 11", status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(local: localCurrent, peers: [manual]), memory: AutoMemory()).decision, .nothingToDo)
        // Nor one whose updates from other devices are off.
        let refusing = peer(highPhone, "OnePlus 11", status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900,
                                                             remoteStart: false, auto: true))
        XCTAssertEqual(AutoUpdatePolicy.decide(facts(local: localCurrent, peers: [refusing]), memory: AutoMemory()).decision, .nothingToDo)
        // Not the leader and nothing of its own: it leaves the phone to the leader, however long that takes.
        let leader = peer(lowPhone, "Pixel", status(auto: true))
        var memory = AutoMemory()
        for minutes in [0, 20, 60] {
            let step = AutoUpdatePolicy.decide(facts(at: TimeInterval(minutes) * 60, local: localCurrent, peers: [leader, waiting]), memory: memory)
            guard case .yield = step.decision else { return XCTFail("\(minutes) min: \(step.decision)") }
            memory = step.memory
        }
    }

    func testTheCommandLineSkipsTheSettingButNotABusyPerson() {
        XCTAssertNil(AutoUpdatePolicy.commandLineBlocked(facts(enabled: false)))
        XCTAssertEqual(AutoUpdatePolicy.commandLineBlocked(facts(runActive: true)), .runActive)
        XCTAssertEqual(AutoUpdatePolicy.commandLineBlocked(facts(updatingForPeer: true)), .updatingForPeer)
        let calling = peer(highPhone, "OnePlus 11", status(busy: .call))
        XCTAssertEqual(AutoUpdatePolicy.commandLineBlocked(facts(peers: [calling])), .busy(.call, device: "OnePlus 11"))
        XCTAssertEqual(AutoUpdatePolicy.commandLineBlocked(facts(localBusy: .setup)), .busy(.setup, device: nil))
    }

    // MARK: A device asked to update

    func testAnAutomaticStartWaitsForABusyPerson() {
        var gate = UpdateStartGate()
        XCTAssertEqual(gate.decide(deviceID: "p", retry: false, now: t0, allowed: true, updaterAvailable: true, notApplied: false,
                                   canStart: true, auto: true, personBusy: .call), .refuse(.busy))
        XCTAssertEqual(gate.decide(deviceID: "q", retry: false, now: t0, allowed: true, updaterAvailable: true, notApplied: false,
                                   canStart: true, auto: false, personBusy: .call), .accept, "a start someone clicked goes ahead")
        XCTAssertEqual(gate.decide(deviceID: "r", retry: false, now: t0, allowed: true, updaterAvailable: true, notApplied: false,
                                   canStart: true, auto: true, personBusy: nil), .accept)
        XCTAssertTrue(AutoStartRule.refusesBusy(UpdateStartRequest(requestID: "x", auto: true), localBusy: .transfer))
        XCTAssertFalse(AutoStartRule.refusesBusy(UpdateStartRequest(requestID: "x"), localBusy: .transfer))
    }

    func testStatusCarriesTheSettingAndBusy() {
        var inputs = LocalUpdateInputs(available: true, app: "0.10.0-rr.1-beta.10", build: 263_011_402, channel: .beta, flow: .idle,
                                       deferral: nil, offeredBuild: nil, failureReason: nil, lastCheck: t0, remoteStartAllowed: true,
                                       notApplied: nil, auto: true, busy: .call)
        XCTAssertTrue(inputs.status.auto)
        XCTAssertEqual(inputs.status.busy, .call)
        XCTAssertEqual(inputs.status.payload["auto"] as? Bool, true)
        XCTAssertEqual(inputs.status.payload["busy"] as? String, "call")
        inputs.available = false
        XCTAssertFalse(inputs.status.auto, "a build that cannot update itself never says it updates automatically")
        inputs.auto = false
        inputs.busy = nil
        XCTAssertNil(inputs.status.payload["auto"])
        XCTAssertNil(inputs.status.payload["busy"])
    }

    // MARK: Plan and run

    private func ids() -> () -> String {
        var counter = 0
        return {
            counter += 1
            return String(format: "00000000-0000-4000-8000-%012d", counter)
        }
    }

    func testAutomaticRunsAskPhonesThatCheckedBeforeTheBuildWasFound() {
        let checkedBefore = UpdateAllPhone(id: highPhone, name: "OnePlus 11", connected: true, supportsUpdates: true,
                                           status: status(checkedAt: t0.addingTimeInterval(-600)))
        let plain = UpdatePlan.make(local: localNew, localName: "This Mac", phones: [checkedBefore], now: t0)
        XCTAssertEqual(plain.entries.first?.kind, .upToDate)
        let refreshed = UpdatePlan.make(local: localNew, localName: "This Mac", phones: [checkedBefore], now: t0, refreshBefore: t0.addingTimeInterval(-60))
        XCTAssertEqual(refreshed.entries.first?.kind, .update(to: nil, toBuild: nil))
        let checkedAfter = UpdatePlan.make(local: localNew, localName: "This Mac", phones: [checkedBefore], now: t0, refreshBefore: t0.addingTimeInterval(-900))
        XCTAssertEqual(checkedAfter.entries.first?.kind, .upToDate)
    }

    private func autoRun(local: Bool = true) -> UpdateRun {
        let phone = UpdateAllPhone(id: highPhone, name: "OnePlus 11", connected: true, supportsUpdates: true,
                                   status: status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900))
        let plan = UpdatePlan.make(local: local ? localNew : localCurrent, localName: "This Mac", phones: [phone], now: t0)
        return UpdateRun.start(plan: plan, now: t0, auto: true, newID: ids())!.run
    }

    func testAutomaticStartsSayAutoAndRetriesDoNot() {
        let phone = UpdateAllPhone(id: highPhone, name: "OnePlus 11", connected: true, supportsUpdates: true,
                                   status: status(.available, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900))
        let plan = UpdatePlan.make(local: localNew, localName: "This Mac", phones: [phone], now: t0)
        let automatic = UpdateRun.start(plan: plan, now: t0, auto: true, newID: ids())!
        XCTAssertEqual(automatic.starts.map(\.request.auto), [true])
        XCTAssertTrue(automatic.run.isAuto)
        let clicked = UpdateRun.start(plan: plan, now: t0, newID: ids())!
        XCTAssertEqual(clicked.starts.map(\.request.auto), [false])
        var run = automatic.run
        run.result(from: highPhone, UpdateStartResult(requestID: run.phones[0].requestID!, refusal: .busy), now: t0)
        let retry = run.retry(highPhone, now: t0, newID: ids())
        XCTAssertEqual(retry?.retry, true)
        XCTAssertEqual(retry?.auto, false, "Retry is a click")
    }

    func testTheCountdownIsSixtySecondsAndABusyPersonHoldsIt() {
        var run = autoRun()
        run.result(from: highPhone, UpdateStartResult(requestID: run.phones[0].requestID!), now: t0)
        run.status(from: highPhone, status(.installing, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900), now: t0)
        run.local(status(.ready, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, platform: .macos), now: t0)
        _ = run.tick(now: t0)
        XCTAssertEqual(run.countdownUntil, t0.addingTimeInterval(60))
        // A call starts during the countdown: it stops at once.
        run.busy(.call, now: t0.addingTimeInterval(10))
        XCTAssertNil(run.countdownUntil)
        XCTAssertEqual(run.hold, .call)
        XCTAssertTrue(run.tick(now: t0.addingTimeInterval(11)).isEmpty)
        XCTAssertNil(run.countdownUntil)
        // The call ends; the run looks again five minutes after the last busy sign, then counts down afresh.
        run.busy(nil, now: t0.addingTimeInterval(100))
        XCTAssertEqual(run.hold, .call)
        run.busy(nil, now: t0.addingTimeInterval(310))
        XCTAssertNil(run.hold)
        _ = run.tick(now: t0.addingTimeInterval(310))
        XCTAssertEqual(run.countdownUntil, t0.addingTimeInterval(370))
        XCTAssertEqual(run.tick(now: t0.addingTimeInterval(370)), [.installLocal])
    }

    func testAClickedRunKeepsTenSecondsAndGoesOnWhenTheCallEnds() {
        let phone = UpdateAllPhone(id: highPhone, name: "OnePlus 11", connected: true, supportsUpdates: true, status: status())
        var run = UpdateRun.start(plan: UpdatePlan.make(local: localNew, localName: "This Mac", phones: [phone], now: t0.addingTimeInterval(7200)),
                                  now: t0, newID: ids())!.run
        run.result(from: highPhone, UpdateStartResult(requestID: run.phones[0].requestID!, refusal: .disabled), now: t0)
        run.local(status(.ready, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, platform: .macos), now: t0)
        run.busy(.call, now: t0)
        _ = run.tick(now: t0)
        XCTAssertNil(run.countdownUntil)
        run.busy(nil, now: t0.addingTimeInterval(1))
        _ = run.tick(now: t0.addingTimeInterval(1))
        XCTAssertEqual(run.countdownUntil, t0.addingTimeInterval(11))
    }

    func testSavedRunsKeepAutoAndDropTheHold() throws {
        var run = autoRun()
        run.busy(.call, now: t0)
        let data = try JSONEncoder().encode(run)
        let restored = try JSONDecoder().decode(UpdateRun.self, from: data)
        XCTAssertTrue(restored.isAuto)
        XCTAssertNil(restored.hold)
        // A run saved by beta 10 (no auto key) still loads, as a clicked run.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "auto")
        let old = try JSONDecoder().decode(UpdateRun.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(old.isAuto)
        XCTAssertEqual(old.countdownLength, 10)
    }

    func testRunRecordCountsTheResult() {
        var run = autoRun()
        run.result(from: highPhone, UpdateStartResult(requestID: run.phones[0].requestID!, refusal: .rateLimited), now: t0)
        var record = AutoRunRecord(run: run)
        XCTAssertFalse(record.finished)
        run.local(status(.ready, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, platform: .macos), now: t0)
        run.later(now: t0)
        record.update(from: run)
        XCTAssertTrue(record.finished)
        XCTAssertTrue(record.later)
        XCTAssertEqual(record.failed, 1)
        XCTAssertEqual(record.version, "0.10.0-rr.1-beta.11")
    }

    // MARK: What the person is doing

    func testBusyMapping() {
        let transfer = FileTransferRow(id: "t", name: "a.jpg", status: "", active: true)
        var download = FolderRowSummary(phoneName: "OnePlus 11", displayName: "Photos")
        download.incoming = true
        let phoneFiles = FileTransferRow(id: "f", name: "Photos", status: "", active: true, folder: download)
        let finished = FileTransferRow(id: "d", name: "b.jpg", status: "", active: false)
        XCTAssertEqual(MacBusyMonitor.busy(call: false, screen: false, remote: false, transfers: [finished], pairing: .idle, setupOpen: false), [])
        XCTAssertEqual(MacBusyMonitor.busy(call: true, screen: true, remote: true, transfers: [transfer, phoneFiles],
                                           pairing: .verification(PairingPrompt(peerName: "x", code: "1")), setupOpen: false),
                       [.call, .screenShare, .remoteControl, .transfer, .phoneFiles, .setup])
        XCTAssertEqual(MacBusyMonitor.busy(call: false, screen: false, remote: false, transfers: [], pairing: .waitingForAllow("x"), setupOpen: false), [.setup])
        XCTAssertEqual(MacBusyMonitor.busy(call: false, screen: false, remote: false, transfers: [], pairing: .idle, pairingArmed: true, setupOpen: false),
                       [.setup], "Allow pairing is on")
        XCTAssertEqual(MacBusyMonitor.busy(call: false, screen: false, remote: false, transfers: [], pairing: .paired(deviceID: "d", peerName: "x"),
                                           setupOpen: true), [.setup])
        XCTAssertEqual(MacBusyMonitor.busy(call: false, screen: false, remote: false, transfers: [], pairing: .paired(deviceID: "d", peerName: "x"),
                                           setupOpen: false), [])
        XCTAssertEqual(UpdateBusy.mostImportant([.transfer, .call, .setup]), .call)
    }

    // MARK: Notice and words

    func testNoticeShowsAtTheStartAndDuringTheCountdownOnly() {
        var run = autoRun()
        XCTAssertEqual(AutoNoticeState.make(run: run, now: t0.addingTimeInterval(1), currentVersion: "0.10.0-rr.1-beta.10", closedRunID: nil),
                       .starting(title: "Updating your devices to beta.11", detail: "OnePlus 11 updates first. This Mac restarts last.", canLater: false))
        XCTAssertEqual(AutoNoticeState.make(run: run, now: t0.addingTimeInterval(13), currentVersion: "0.10.0-rr.1-beta.10", closedRunID: nil), .hidden)
        XCTAssertEqual(AutoNoticeState.make(run: run, now: t0.addingTimeInterval(1), currentVersion: "0.10.0-rr.1-beta.10", closedRunID: run.id), .hidden)
        run.countdownUntil = t0.addingTimeInterval(60)
        XCTAssertEqual(AutoNoticeState.make(run: run, now: t0.addingTimeInterval(20), currentVersion: "0.10.0-rr.1-beta.10", closedRunID: run.id),
                       .countdown(title: "Updating your devices to beta.11", until: t0.addingTimeInterval(60)))
        run.busy(.call, now: t0.addingTimeInterval(21))
        XCTAssertEqual(AutoNoticeState.make(run: run, now: t0.addingTimeInterval(21), currentVersion: "0.10.0-rr.1-beta.10", closedRunID: nil), .hidden,
                       "never over a call")
        let clicked = UpdateRun.start(plan: UpdatePlan.make(local: localNew, localName: "This Mac", phones: [], now: t0), now: t0, newID: ids())!.run
        XCTAssertEqual(AutoNoticeState.make(run: clicked, now: t0, currentVersion: "0.10.0-rr.1-beta.10", closedRunID: nil), .hidden)
    }

    func testActivityWords() {
        func item(_ kind: ActivityKind, device: String = "", content: String?) -> ActivityItem {
            ActivityItem(id: 1, kind: kind, deviceID: nil, deviceName: device, fileName: nil, preview: nil, appName: nil, sensitive: false,
                         automatic: false, count: 1, at: t0, content: content)
        }
        XCTAssertEqual(AutoUpdateText.activityTitle(item(.updateAutoDone, content: "0.10.0-rr.1-beta.11")), "Updated automatically to 0.10.0-rr.1-beta.11")
        XCTAssertEqual(AutoUpdateText.activityTitle(item(.updateAutoWaiting, content: "call")), "Waiting: call in progress")
        XCTAssertEqual(AutoUpdateText.activityTitle(item(.updateAutoWaiting, device: "OnePlus 11", content: "call")), "Waiting: call in progress on OnePlus 11")
        XCTAssertEqual(AutoUpdateText.activityTitle(item(.updateAutoSkipped, device: "Work phone", content: "remote_off")),
                       "Skipped Work phone: updates from other devices are off")
        XCTAssertEqual(AutoUpdateText.activityTitle(item(.updateAutoStartedBy, device: "OnePlus 11", content: nil)), "Update started automatically by OnePlus 11")
        XCTAssertEqual(AutoUpdateText.activityTitle(item(.updateAutoFailed, device: "OnePlus 11", content: "no_answer")),
                       "Automatic update didn\u{2019}t finish on OnePlus 11: no answer")
        XCTAssertEqual(AutoUpdateText.activityTitle(item(.updateAutoFailed, device: "OnePlus 11", content: "not_applied")),
                       "Automatic update didn\u{2019}t apply on OnePlus 11")
        // Stored and read back like every other item, with the short content kept.
        var items: [ActivityItem] = []
        items = ActivityHistory.add(items, kind: .updateAutoWaiting, deviceID: nil, deviceName: "OnePlus 11", fileName: nil, preview: nil,
                                    appName: nil, sensitive: false, automatic: false, count: 1, bytes: nil, content: "phone_files",
                                    fileCount: nil, destination: nil, now: t0, nextID: 1)
        let decoded = ActivityHistory.decode(try! ActivityHistory.encode(items), now: t0)
        XCTAssertEqual(decoded.first?.kind, .updateAutoWaiting)
        XCTAssertEqual(decoded.first?.content, "phone_files")
        for kind in ActivityKind.allCases where kind.isAutoUpdate { XCTAssertTrue(kind.rawValue.hasPrefix("update_auto_")) }
    }

    func testSettingsLines() {
        var display = AutoUpdateDisplay(enabled: true, choice: nil, available: true, checksOff: false, channel: .beta, decision: .nothingToDo, now: t0)
        XCTAssertEqual(AutoUpdateText.statusLines(display), ["Checks every 30 minutes"])
        display.channel = .stable
        XCTAssertEqual(AutoUpdateText.statusLines(display), ["Checks every 6 hours"])
        display.decision = .wait(.call, device: "OnePlus 11", until: t0)
        var run = autoRun()
        run.result(from: highPhone, UpdateStartResult(requestID: run.phones[0].requestID!), now: t0)
        run.status(from: highPhone, status(app: "0.10.0-rr.1-beta.11", build: 263_020_900), now: t0)
        run.local(status(.ready, target: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, platform: .macos), now: t0)
        run.later(now: t0)
        display.lastRun = AutoRunRecord(run: run)
        let lines = AutoUpdateText.statusLines(display)
        XCTAssertEqual(lines.first, "Waiting: call in progress on OnePlus 11")
        XCTAssertTrue(lines.last?.hasPrefix("Last automatic update: ") == true)
        XCTAssertTrue(lines.last?.hasSuffix("this Mac put off with Later") == true)
        display.enabled = false
        display.checksOff = true
        display.choice = true
        XCTAssertEqual(AutoUpdateText.statusLines(display), ["Turn on Check automatically to use it."])
        for line in lines { XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}")) }
    }

    // MARK: Setup

    func testSetupUpdatesAnswersCoverTheSetting() {
        XCTAssertEqual(SetupQuestions.typedOnly["updates"]?[SetupAnswerKey.steady], [.set(.updateChannel, "stable"), .off(.updatesAutoAll)])
        XCTAssertEqual(SetupQuestions.typedOnly["updates"]?[SetupAnswerKey.early], [.set(.updateChannel, "beta"), .on(.updatesAutoAll)])
        XCTAssertEqual(SetupQuestions.typedOnly["updates_auto"]?[SetupAnswerKey.no], [.off(.updatesAutoAll)])
        XCTAssertNotNil(SetupQuestions.coverage[.updatesAutoAll])
        func match(_ text: String) -> [String] { SetupTyped.match(text).map { "\($0.id)=\($0.key)" } }
        // The same sentences as Android's SetupTypedTest.
        XCTAssertEqual(match("update all my devices automatically"), ["updates_auto=yes"])
        XCTAssertEqual(match("Auto-update everything"), ["updates_auto=yes"])
        XCTAssertEqual(match("beta, but no automatic updates"), ["updates=early", "updates_auto=no"])
        XCTAssertEqual(match("don't update automatically"), ["updates_auto=no"])
        XCTAssertEqual(match("nightly builds that install automatically"), ["updates=newest", "updates_auto=yes"])
        XCTAssertEqual(match("Хочу автообновление"), ["updates_auto=yes"])
        XCTAssertEqual(match("без автообновлений"), ["updates_auto=no"])
        XCTAssertEqual(match("стабильные, обновлять автоматически"), ["updates=steady", "updates_auto=yes"])
        XCTAssertEqual(match("I want to update my Mac"), [])
        // The explicit answer is applied after the channel's own choice.
        let ids = SetupQuestions.typedOnly.keys.sorted()
        XCTAssertLessThan(ids.firstIndex(of: "updates")!, ids.firstIndex(of: "updates_auto")!)
    }
}

/// The command-line hand-over: the request, the words, and the socket (only this user, the running app).
final class UpdateControlTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Short: a Unix socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/buc-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var socketPath: String { directory.appendingPathComponent("s.sock").path }

    func testRequestsRoundTripAndBadOnesAreRefused() {
        let request = UpdateControlRequest(command: .updateAll, launched: true)
        XCTAssertEqual(UpdateControlRequest.decode(request.line.dropLast()), request)
        XCTAssertNil(UpdateControlRequest.decode(Data(#"{"version":2,"command":"update-all"}"#.utf8)))
        XCTAssertNil(UpdateControlRequest.decode(Data(#"{"version":1,"command":"install","url":"https://example.com/x.zip"}"#.utf8)))
        XCTAssertNil(UpdateControlRequest.decode(Data(#"{"version":1,"command":"update-all","launched":"yes"}"#.utf8)))
        XCTAssertEqual(UpdateControlRequest.decode(Data(#"{"version":1,"command":"update-all","url":"https://example.com/x.zip"}"#.utf8))?.launched, false,
                       "nothing else is read from a request")
    }

    func testTheWords() {
        XCTAssertEqual(UpdateControlText.lines(["event": "info", "app": "0.10.0-rr.1-beta.10", "build": 263_011_402, "channel": "beta"]),
                       ["Bridgey by Round Robin 0.10.0-rr.1-beta.10 (263011402) on this Mac, Beta channel"])
        let plan: [String: Any] = ["event": "plan", "devices": [
            ["name": "OnePlus 11", "platform": "android", "local": false, "from": "0.10.0-rr.1-beta.10", "to": "0.10.0-rr.1-beta.11",
             "channel": "beta", "action": "update"],
            ["name": "Work phone", "platform": "android", "local": false, "from": "0.9.0-rr.2", "action": "skip", "reason": "remote_off"],
            ["name": "This Mac", "platform": "macos", "local": true, "from": "0.10.0-rr.1-beta.10", "to": "0.10.0-rr.1-beta.11",
             "channel": "beta", "action": "update"],
        ]]
        XCTAssertEqual(UpdateControlText.lines(plan), [
            "Plan:",
            "  update   OnePlus 11 (Android, Beta): 0.10.0-rr.1-beta.10 > 0.10.0-rr.1-beta.11",
            "  skip     Work phone (Android): updates from other devices are off there",
            "  update   This Mac (Mac, Beta): 0.10.0-rr.1-beta.10 > 0.10.0-rr.1-beta.11, restarts last after a 60 s countdown",
        ])
        XCTAssertEqual(UpdateControlText.lines(["event": "result", "result": "started"]), ["Result: started"])
        XCTAssertEqual(UpdateControlText.lines(["event": "result", "result": "blocked", "reason": "busy", "busy": "call", "device": "OnePlus 11"]),
                       ["Result: blocked because a call is in progress on OnePlus 11"])
        XCTAssertEqual(UpdateControlText.lines(["event": "result", "result": "blocked", "reason": "run_active"]),
                       ["Result: blocked because an Update all run is already going on this Mac"])
        XCTAssertEqual(UpdateControlText.lines(["event": "result", "result": "refused", "reason": "another_user"]),
                       ["Result: refused, the request came from another user"])
    }

    func testTheSocketIsOwnerOnlyAndHandsTheRequestOver() throws {
        let received = expectation(description: "request")
        let server = UpdateControlServer(path: socketPath) { request, reply in
            XCTAssertEqual(request.command, .updateAll)
            reply.progress("checking")
            reply.finish(.started, reason: nil, text: nil)
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }
        let socketMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? Int)
        let folderMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int)
        XCTAssertEqual(socketMode & 0o777, 0o600)
        XCTAssertEqual(folderMode & 0o777, 0o700)
        // A second app on the same socket is refused while the first one serves it.
        XCTAssertThrowsError(try UpdateControlServer(path: socketPath) { _, _ in }.start()) { error in
            XCTAssertEqual(error as? UpdateControlError, .alreadyServed)
        }
        var lines: [String] = []
        var environment = UpdateControlCLI.Environment()
        environment.socketPath = socketPath
        environment.output = { lines.append($0) }
        environment.launch = { XCTFail("the app is running: no launch"); return false }
        XCTAssertEqual(UpdateControlCLI.run(arguments: ["BridgeyMac", "--update-all"], environment: environment), 0)
        wait(for: [received], timeout: 5)
        XCTAssertEqual(lines, ["Checking for updates...", "Result: started"])
    }

    /// A client that connects and hangs up before it is accepted used to make the answer raise SIGPIPE,
    /// which ends the app. Many of them, then a real request.
    func testClientsThatHangUpAtOnceNeverEndTheApp() throws {
        let served = expectation(description: "request after the hang-ups")
        let server = UpdateControlServer(path: socketPath) { _, reply in
            reply.finish(.upToDate, reason: nil, text: nil)
            served.fulfill()
        }
        try server.start()
        defer { server.stop() }
        for _ in 0..<50 {
            if case let .success(fd) = UpdateControlSocket.connect(socketPath) { close(fd) }
        }
        Thread.sleep(forTimeInterval: 0.3)
        var environment = UpdateControlCLI.Environment()
        environment.socketPath = socketPath
        environment.output = { _ in }
        XCTAssertEqual(UpdateControlCLI.run(arguments: ["BridgeyMac", "--update-all"], environment: environment), 3)
        wait(for: [served], timeout: 5)
    }

    func testAnotherUserIsRefused() throws {
        let server = UpdateControlServer(path: socketPath, ownUID: getuid(), peerUID: { _ in getuid() + 1 }) { _, reply in
            XCTFail("another user's request reached the app")
            reply.close()
        }
        try server.start()
        defer { server.stop() }
        var lines: [String] = []
        var environment = UpdateControlCLI.Environment()
        environment.socketPath = socketPath
        environment.output = { lines.append($0) }
        XCTAssertEqual(UpdateControlCLI.run(arguments: ["BridgeyMac", "--update-all"], environment: environment), 1)
        XCTAssertEqual(lines, ["Result: refused, the request came from another user"])
        // And the socket's folder keeps other users out before any of that.
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int).map { $0 & 0o077 }, 0)
    }

    func testNotRunningStartsTheAppThenHandsOver() throws {
        var server: UpdateControlServer?
        let received = expectation(description: "request")
        var lines: [String] = []
        var environment = UpdateControlCLI.Environment()
        environment.socketPath = socketPath
        environment.output = { lines.append($0) }
        environment.launchWait = 5
        environment.launch = { [socketPath] in
            let started = UpdateControlServer(path: socketPath) { request, reply in
                XCTAssertTrue(request.launched, "the app is told it was just started, so it waits for phones")
                reply.finish(.upToDate, reason: nil, text: nil)
                received.fulfill()
            }
            try? started.start()
            server = started
            return true
        }
        // A stale socket file from a crash does not count as a running app.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: socketPath, contents: nil)
        XCTAssertEqual(UpdateControlCLI.run(arguments: ["BridgeyMac", "--update-all"], environment: environment), 3)
        wait(for: [received], timeout: 5)
        server?.stop()
        XCTAssertEqual(lines.first, "Bridgey by Round Robin is not running. Starting it...")
        XCTAssertEqual(lines.last, "Result: up to date (this Mac and its connected phones report nothing newer)")
    }

    func testNothingRunningAndNoAppToStart() {
        var lines: [String] = []
        var environment = UpdateControlCLI.Environment()
        environment.socketPath = socketPath
        environment.output = { lines.append($0) }
        environment.launch = { false }
        XCTAssertEqual(UpdateControlCLI.run(arguments: ["BridgeyMac", "--update-all", "--json"], environment: environment), 1)
        XCTAssertEqual(lines, ["Error: Bridgey by Round Robin is not running and could not be started."])
    }
}
