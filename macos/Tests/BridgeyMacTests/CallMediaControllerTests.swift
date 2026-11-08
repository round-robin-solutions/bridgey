import XCTest
@testable import BridgeyMac

@MainActor
final class CallMediaTestScheduler: CallMediaScheduler {
    private final class Task {
        let work: @MainActor () -> Void
        var cancelled = false
        init(_ work: @escaping @MainActor () -> Void) { self.work = work }
    }
    private var tasks: [Task] = []
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        XCTAssertTrue(delay == 0.35 || delay == 30)
        let task = Task(work)
        tasks.append(task)
        return { task.cancelled = true }
    }
    func advance() {
        let ready = tasks
        tasks.removeAll()
        for task in ready where !task.cancelled { task.work() }
    }
}

@MainActor
final class CallMediaTestPlatform: CallMediaPlatform {
    struct Command {
        let action: CallMediaAction
        let session: CallMediaSession
        let permit: CallMediaPermit
        let completion: @MainActor (Result<CallMediaSession, CallMediaIssue>) -> Void
    }
    var sessions: [CallMediaSession] = []
    var issues = Set<CallMediaIssue>()
    var pauseWorks = true
    var pauseConfirms = true
    var deferScan = false
    var deferSoundRecovery = false
    var forcedFailure: CallMediaIssue?
    var postApplyFailure: CallMediaIssue?
    private var scans: [@MainActor (CallMediaScan) -> Void] = []
    private var commands: [Command] = []
    private var heldReplies: [@MainActor () -> Void] = []
    private var soundChecks: [(CallMediaMutedOwnership, @MainActor (Bool) -> Void)] = []
    private(set) var requested: [CallMediaAction] = []
    private(set) var applied: [CallMediaAction] = []
    private(set) var localCallActive = false
    private(set) var scanCount = 0
    var processMuteChanged: (@MainActor (UUID, CallMediaIssue, Bool) -> Void)?
    var commandCount: Int { commands.count }
    var soundCheckCount: Int { soundChecks.count }

    func observeProcessMuteRelease(_ changed: @escaping @MainActor (UUID, CallMediaIssue, Bool) -> Void) {
        processMuteChanged = changed
    }
    func soundWasReleased(_ ownership: CallMediaMutedOwnership, completion: @escaping @MainActor (Bool) -> Void) {
        if deferSoundRecovery { soundChecks.append((ownership, completion)); return }
        completion(soundReleased(ownership))
    }
    private func soundReleased(_ ownership: CallMediaMutedOwnership) -> Bool {
        if let token = ownership.after.processMuteToken {
            return !sessions.contains { $0.processMuteToken == token }
        } else { return sessions.contains { $0.bundleID == ownership.before.bundleID && ($0.volume ?? 0) > 0 } }
    }
    func completeSoundRecovery(released: Bool? = nil) {
        XCTAssertFalse(soundChecks.isEmpty)
        guard !soundChecks.isEmpty else { return }
        let (ownership, completion) = soundChecks.removeFirst()
        completion(released ?? soundReleased(ownership))
    }
    func setLocalCallActive(_ active: Bool) { localCallActive = active }
    func scan(_ completion: @escaping @MainActor (CallMediaScan) -> Void) {
        scanCount += 1
        if deferScan { scans.append(completion) }
        else { completion(CallMediaScan(sessions: sessions, issues: issues)) }
    }
    func finishScan() {
        XCTAssertFalse(scans.isEmpty)
        guard !scans.isEmpty else { return }
        scans.removeFirst()(CallMediaScan(sessions: sessions, issues: issues))
    }
    func command(_ action: CallMediaAction, session: CallMediaSession, permit: CallMediaPermit,
                 completion: @escaping @MainActor (Result<CallMediaSession, CallMediaIssue>) -> Void) {
        requested.append(action)
        commands.append(Command(action: action, session: session, permit: permit, completion: completion))
    }
    func complete(holdReply: Bool = false) {
        XCTAssertFalse(commands.isEmpty)
        guard !commands.isEmpty else { return }
        let command = commands.removeFirst()
        var reply: Result<CallMediaSession, CallMediaIssue>
        let appliedBefore = applied.count
        if !command.permit.isValid { reply = .failure(.cancelled) }
        else if let failure = forcedFailure { reply = .failure(failure) }
        else if let index = sessions.firstIndex(where: { $0.id == command.session.id }) {
            let current = sessions[index]
            switch command.action {
            case .pause:
                if !pauseWorks { reply = .failure(.unsupported) }
                else {
                    if pauseConfirms { sessions[index].playing = false }
                    applied.append(.pause)
                    reply = .success(sessions[index])
                }
            case .resume:
                if !current.isStillPaused(from: command.session) { reply = .failure(.changedByUser) }
                else {
                    sessions[index].playing = true
                    applied.append(.resume)
                    reply = .success(sessions[index])
                }
            case .setVolume(let value):
                if current.volume != command.session.volume || !current.hasSameSoundRoute(as: command.session) {
                    reply = .failure(.changedByUser)
                } else {
                    sessions[index].volume = value
                    applied.append(.setVolume(value))
                    reply = .success(sessions[index])
                }
            case .muteProcess(let token):
                sessions[index].processMuteToken = token
                applied.append(command.action)
                reply = .success(sessions[index])
            case .releaseProcessMute(let token):
                if current.processMuteToken == token { sessions[index].processMuteToken = nil }
                applied.append(command.action)
                reply = .success(sessions[index])
            }
        } else { reply = .failure(.sessionGone) }
        if let failure = postApplyFailure, applied.count > appliedBefore { reply = .failure(failure) }
        let deliveredReply = reply
        if holdReply { heldReplies.append { command.completion(deliveredReply) } }
        else { command.completion(deliveredReply) }
    }
    func completeAll() {
        var remaining = 100
        while !commands.isEmpty && remaining > 0 { remaining -= 1; complete() }
        XCTAssertGreaterThan(remaining, 0, "commands must settle rather than retry forever")
    }
    func deliverHeldReply() {
        XCTAssertFalse(heldReplies.isEmpty)
        guard !heldReplies.isEmpty else { return }
        heldReplies.removeFirst()()
    }
}

@MainActor
final class CallMediaControllerTests: XCTestCase {
    private var platform: CallMediaTestPlatform!
    private var scheduler: CallMediaTestScheduler!
    private var controller: CallMediaController!
    private var policy = CallMediaPolicy()

    override func setUp() async throws {
        platform = CallMediaTestPlatform()
        scheduler = CallMediaTestScheduler()
        controller = CallMediaController(platform: platform, scheduler: scheduler)
        policy = CallMediaPolicy()
    }

    private func player(_ id: String = "music", playing: Bool = true, volume: Int = 50) -> CallMediaSession {
        CallMediaSession(id: id, bundleID: "test.\(id)", contentID: "track", playing: playing,
                         position: 100, volume: volume, routeID: "speakers", canMute: true)
    }

    private func start(_ keys: Set<String> = ["phone/call"]) { controller.updateCalls(keys, policy: policy) }
    private func end() { controller.updateCalls([], policy: policy) }

    func testDefaultPausesEveryPlayingPlayerAndResumesOnlyOwnedPlayback() {
        platform.sessions = [player(), player("spotify"), player("already-paused", playing: false)]
        start()
        XCTAssertEqual(platform.requested, [.pause, .pause])
        platform.completeAll()
        XCTAssertEqual(controller.result.paused, 2)

        end()
        platform.completeAll()

        XCTAssertEqual(platform.applied.filter { $0 == .resume }.count, 2)
        XCTAssertEqual(platform.sessions.map(\.playing), [true, true, false])
        XCTAssertEqual(controller.result.paused, 0)
    }

    func testOverlappingCallsAndManualPlaybackNeverQuietAgainOrRestoreEarly() {
        platform.sessions = [player()]
        start()
        platform.completeAll()
        platform.sessions[0].playing = true // The person deliberately resumes during the call.

        start(["phone/call", "other-phone/call"])
        start(["other-phone/call"])
        XCTAssertEqual(platform.requested, [.pause])
        XCTAssertTrue(platform.sessions[0].playing)

        end()
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause], "restoration must not issue Play over an override")
        XCTAssertTrue(controller.result.issues.contains(.changedByUser))
    }

    func testRestoreSoundOptionLeavesPlaybackPaused() {
        policy.restoration = .restoreSound
        platform.sessions = [player()]
        start()
        platform.completeAll()
        end()
        XCTAssertEqual(platform.requested, [.pause])
        XCTAssertFalse(platform.sessions[0].playing)
    }

    func testMuteOnlyRestoresOnlyItsOwnVolumeAndNeverUnmutesAnAlreadyMutedPlayer() {
        policy.mode = .muteOnly
        platform.sessions = [player(), player("already-muted", volume: 0)]
        start()
        platform.completeAll()
        XCTAssertEqual(controller.result.muted, 1)
        XCTAssertEqual(platform.sessions.map(\.volume), [0, 0])
        end()
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.setVolume(0), .setVolume(50)])
        XCTAssertEqual(platform.sessions.map(\.volume), [50, 0])
    }

    func testLeaveAsIsDoesNotRestoreSoundOrPlayback() {
        policy.mode = .muteOnly
        policy.restoration = .leaveAsIs
        platform.sessions = [player()]
        start()
        platform.completeAll()
        end()
        XCTAssertEqual(platform.requested, [.setVolume(0)])
        XCTAssertEqual(platform.sessions[0].volume, 0)
        XCTAssertEqual(controller.result.muted, 0, "ownership is relinquished, not retained forever")
    }

    func testPauseFailureUsesOneSelectiveMuteFallback() {
        platform.pauseWorks = false
        platform.sessions = [player()]
        start()
        platform.completeAll()
        XCTAssertEqual(platform.requested, [.pause, .setVolume(0)])
        XCTAssertEqual(controller.result.muted, 1)
        end()
        platform.completeAll()
        XCTAssertEqual(platform.sessions[0].volume, 50)
        XCTAssertFalse(platform.applied.contains(.resume))
    }

    func testUnconfirmedPauseGetsOneBoundedCheckBeforeMute() {
        platform.pauseConfirms = false
        platform.sessions = [player()]
        start()
        platform.completeAll()
        XCTAssertEqual(controller.result.pending, 1)
        XCTAssertEqual(platform.requested, [.pause])
        scheduler.advance()
        platform.completeAll()
        XCTAssertEqual(platform.requested, [.pause, .setVolume(0)])
        scheduler.advance()
        XCTAssertEqual(platform.requested.count, 2)
    }

    func testPauseOnlyCannotFallBackToMute() {
        policy.mode = .pauseOnly
        platform.pauseWorks = false
        platform.sessions = [player()]
        start()
        platform.completeAll()
        XCTAssertEqual(platform.requested, [.pause])
        XCTAssertEqual(controller.result.muted, 0)
    }

    func testUnsafeOrUnsupportedPlayersAreReportedWithoutMutingTheCall() {
        var call = player("browser")
        call.protectedCallAudio = true
        var unknown = player("unknown")
        unknown.canPause = false
        unknown.canMute = false
        platform.sessions = [call, unknown]
        start()
        XCTAssertTrue(platform.requested.isEmpty)
        XCTAssertTrue(controller.result.issues.contains(.callAudioProtected))
        XCTAssertTrue(controller.result.issues.contains(.selectiveMuteUnavailable))
    }

    func testCallEndingBeforePauseStartsRevokesItsPermit() {
        platform.sessions = [player()]
        start()
        end()
        platform.completeAll()
        XCTAssertTrue(platform.applied.isEmpty)
        XCTAssertTrue(platform.sessions[0].playing)
        XCTAssertEqual(controller.result.pending, 0)
    }

    func testPauseAppliedBeforeCallEndButAcknowledgedLaterStillRestores() {
        platform.sessions = [player()]
        start()
        platform.complete(holdReply: true)
        XCTAssertFalse(platform.sessions[0].playing)
        end()
        platform.deliverHeldReply()
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
        XCTAssertTrue(platform.sessions[0].playing)
    }

    func testLatePauseFromALostIntervalCannotBecomeAutoplayOwnershipForANewCall() {
        platform.sessions = [player()]
        start()
        platform.complete(holdReply: true)
        controller.release(reason: .disconnected)
        start(["new-call"])
        platform.deliverHeldReply()
        end()
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        XCTAssertFalse(platform.sessions[0].playing)
    }

    func testDisableDisconnectAndPermissionLossRestoreSoundButNeverAutoplay() {
        for reason in [CallMediaReleaseReason.disabled, .disconnected, .permissionLost] {
            let isolated = CallMediaTestPlatform()
            isolated.sessions = [player()]
            let state = CallMediaController(platform: isolated, scheduler: scheduler)
            state.updateCalls(["call"], policy: policy)
            isolated.completeAll()
            state.release(reason: reason)
            isolated.completeAll()
            XCTAssertEqual(isolated.applied, [.pause])
            XCTAssertFalse(isolated.sessions[0].playing)

            isolated.sessions[0].playing = true
            var mutedPolicy = policy
            mutedPolicy.mode = .muteOnly
            state.updateCalls(["call"], policy: mutedPolicy)
            isolated.completeAll()
            state.release(reason: reason)
            isolated.completeAll()
            XCTAssertEqual(isolated.sessions[0].volume, 50)
            XCTAssertFalse(isolated.applied.contains(.resume))
        }
    }

    func testLaterUserVolumeOrOutputRouteChoiceIsNeverOverwritten() {
        for changedRoute in [false, true] {
            let isolated = CallMediaTestPlatform()
            isolated.sessions = [player()]
            var mutedPolicy = policy
            mutedPolicy.mode = .muteOnly
            let state = CallMediaController(platform: isolated, scheduler: scheduler)
            state.updateCalls(["call"], policy: mutedPolicy)
            isolated.completeAll()
            if changedRoute { isolated.sessions[0].routeID = "headphones" }
            else { isolated.sessions[0].volume = 25 }
            state.updateCalls([], policy: mutedPolicy)
            isolated.completeAll()
            XCTAssertEqual(isolated.applied, [.setVolume(0)])
            XCTAssertTrue(state.result.issues.contains(.changedByUser))
        }
    }

    func testChangedTrackSeekOrProcessDoesNotAutoplay() {
        for change in ["content", "position", "process"] {
            let isolated = CallMediaTestPlatform()
            isolated.sessions = [player()]
            let state = CallMediaController(platform: isolated, scheduler: scheduler)
            state.updateCalls(["call"], policy: policy)
            isolated.completeAll()
            switch change {
            case "content": isolated.sessions[0].contentID = "new-track"
            case "position": isolated.sessions[0].position = 150
            default: isolated.sessions[0].id = "new-process"
            }
            state.updateCalls([], policy: policy)
            isolated.completeAll()
            XCTAssertEqual(isolated.applied, [.pause])
        }
    }

    func testNewMediaDuringAnExistingCallIsAnAllowedOverride() {
        platform.sessions = [player()]
        start()
        platform.completeAll()
        platform.sessions.append(player("new-player"))
        start()
        XCTAssertEqual(platform.requested, [.pause])
        XCTAssertTrue(platform.sessions[1].playing)
    }

    func testNewCallCancelsAnUnsentRestoreAndKeepsOwnershipUntilItsEnd() {
        platform.sessions = [player()]
        start()
        platform.completeAll()
        end() // Resume is queued but has not run on the platform queue yet.
        start(["next-call"])
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        XCTAssertFalse(platform.sessions[0].playing)
        XCTAssertEqual(controller.result.paused, 1)
        end()
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
    }

    func testPolicyChangeDoesNotRequietButControlsAfterCallRestoration() {
        platform.sessions = [player()]
        start()
        platform.completeAll()
        policy.mode = .muteOnly
        policy.restoration = .restoreSound
        controller.updatePolicy(policy)
        XCTAssertEqual(platform.requested, [.pause])
        end()
        XCTAssertEqual(platform.requested, [.pause])
    }

    func testCallEndingBeforeEnumerationReturnsDoesNothing() {
        platform.deferScan = true
        platform.sessions = [player()]
        start()
        end()
        platform.finishScan()
        XCTAssertTrue(platform.requested.isEmpty)
        XCTAssertEqual(controller.result.pending, 0)
    }

    func testLatePauseConfirmationAfterCallEndStillRestoresOnlyTheOwnedItem() {
        platform.pauseConfirms = false
        platform.sessions = [player()]
        start()
        platform.completeAll()
        end()
        platform.sessions[0].playing = false // Player finally applies the earlier explicit Pause.
        scheduler.advance()
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
    }

    func testLocalCallSafetyContextReachesTheBackend() {
        controller.updateCalls(["local/manual"], policy: policy, localCallActive: true)
        XCTAssertTrue(platform.localCallActive)
    }

    func testLegacyCallBarrierRetainsOwnedPauseWithoutStartingOrResumingPlayback() {
        platform.sessions = [player()]
        controller.setPlaybackRestorationBlocked(true)
        XCTAssertTrue(platform.requested.isEmpty)
        start()
        platform.completeAll()
        end()
        XCTAssertEqual(platform.applied, [.pause])
        XCTAssertEqual(controller.result.paused, 1)
        controller.setPlaybackRestorationBlocked(false)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
    }

    func testPlatformCannotDispatchUnboundedQuietCommands() {
        platform.sessions = (0..<40).map { player("player\($0)") }
        start()
        XCTAssertEqual(platform.commandCount, 32)
        XCTAssertTrue(controller.result.issues.contains(.unsupported))
    }

    func testLegacyCallHoldsOwnedSoundUntilItsConfirmedEnd() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [CallMediaSession(id: "player", bundleID: "test.media", contentID: "track",
            playing: true, volume: 60, routeID: "speakers", canMute: true)]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .muteOnly)
        controller.updateCalls(["draft"], policy: policy)
        platform.completeAll()
        controller.setPlaybackRestorationBlocked(true)
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.setVolume(0)])
        XCTAssertEqual(platform.sessions[0].volume, 0)
        controller.setPlaybackRestorationBlocked(false)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.setVolume(0), .setVolume(60)])
    }

    func testLegacyCallRevokesAlreadyQueuedPlaybackRestoration() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [CallMediaSession(id: "player", bundleID: "test.media", contentID: "track", playing: true)]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .pauseOnly)
        controller.updateCalls(["draft"], policy: policy)
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        XCTAssertEqual(platform.commandCount, 1)
        controller.setPlaybackRestorationBlocked(true)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        XCTAssertFalse(platform.sessions[0].playing)
        controller.setPlaybackRestorationBlocked(false)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
    }

    func testExplicitResetCanReleaseOwnedSoundWhileLegacyCallContinues() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [CallMediaSession(id: "player", bundleID: "test.media", contentID: "track",
            playing: true, volume: 60, routeID: "speakers", canMute: true)]
        let controller = CallMediaController(platform: platform)
        controller.updateCalls(["draft"], policy: CallMediaPolicy(mode: .muteOnly))
        platform.completeAll()
        controller.setPlaybackRestorationBlocked(true)
        var reset: Bool?
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, true)
        XCTAssertEqual(platform.sessions[0].volume, 60)
        XCTAssertFalse(platform.applied.contains(.resume))
    }


    func testRapidTransitionsKeepOnlyOneScanAndTheLatestWantedGeneration() {
        let platform = CallMediaTestPlatform()
        platform.deferScan = true
        platform.sessions = [CallMediaSession(id: "player", bundleID: "test.media", contentID: "track", playing: true)]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .pauseOnly)
        for i in 0..<100 {
            controller.updateCalls(["call-\(i)"], policy: policy)
            controller.updateCalls([], policy: policy)
        }
        XCTAssertEqual(platform.scanCount, 1)
        XCTAssertEqual(controller.result.pending, 1)
        controller.updateCalls(["latest"], policy: policy)
        platform.finishScan()
        XCTAssertEqual(platform.scanCount, 2)
        XCTAssertTrue(platform.requested.isEmpty, "the obsolete scan cannot dispatch media work")
        platform.finishScan()
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause])
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause, .resume])
    }

    func testRapidTransitionsDoNotRetainUnboundedCommandsAndDisableSettles() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [CallMediaSession(id: "player", bundleID: "test.media", contentID: "track", playing: true)]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .pauseOnly)
        for i in 0..<200 {
            controller.updateCalls(["call-\(i)"], policy: policy)
            controller.updateCalls([], policy: policy)
            XCTAssertLessThanOrEqual(controller.result.pending, 64)
        }
        XCTAssertLessThanOrEqual(platform.requested.count, 32)
        controller.release(reason: .disabled)
        platform.completeAll()
        XCTAssertEqual(controller.result.pending, 0)
        XCTAssertTrue(platform.applied.isEmpty)
    }

    func testResetAfterRapidTransitionsWaitsForOnlyOneObsoleteScan() {
        let platform = CallMediaTestPlatform()
        platform.deferScan = true
        let controller = CallMediaController(platform: platform)
        for i in 0..<100 {
            controller.updateCalls(["call-\(i)"], policy: CallMediaPolicy())
            controller.updateCalls([], policy: CallMediaPolicy())
        }
        var reset: Bool?
        controller.prepareForReset { reset = $0 }
        XCTAssertNil(reset)
        XCTAssertEqual(platform.scanCount, 1)
        platform.finishScan()
        XCTAssertEqual(reset, true)
        XCTAssertEqual(controller.result.pending, 0)
        XCTAssertTrue(platform.requested.isEmpty)
    }


    func testLegacyLossRevokesAnOlderNormalEndAcknowledgementBeforeANewInterval() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [CallMediaSession(id: "player", bundleID: "test.media", contentID: "track", playing: true)]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .pauseOnly)
        controller.updateCalls(["old"], policy: policy)
        platform.complete(holdReply: true)
        controller.setPlaybackRestorationBlocked(true)
        controller.updateCalls([], policy: policy)
        controller.release(reason: .disconnected)
        controller.setPlaybackRestorationBlocked(false)
        controller.updateCalls(["next"], policy: policy)
        platform.deliverHeldReply()
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.pause], "a lossy old interval cannot donate autoplay ownership to a later call")
    }

}
