import XCTest
@testable import BridgeyMac

private final class FakeProcessTapDriver: CallMediaProcessTapDriver {
    var current: Result<CallMediaProcessTarget, CallMediaIssue> = .success(
        CallMediaProcessTarget(sessionID: "music:launch", processObject: 15, routeID: "speakers"))
    var observeFailure: CallMediaIssue?
    var createFailure: CallMediaIssue?
    var destroyWorks = true
    var onCreate: (() -> Void)?
    var onObserve: (() -> Void)?
    var observers: [(CallMediaIssue) -> Void] = []
    var created: [UInt32] = []
    var destroyed: [UInt32] = []
    var cancellations = 0
    var live = Set<UInt32>()
    func target(for session: CallMediaSession) -> Result<CallMediaProcessTarget, CallMediaIssue> { current }
    func observe(_ target: CallMediaProcessTarget, changed: @escaping (CallMediaIssue) -> Void)
        -> Result<() -> Void, CallMediaIssue> {
        if let issue = observeFailure { return .failure(issue) }
        observers.append(changed)
        onObserve?()
        return .success { self.cancellations += 1 }
    }
    func create(_ target: CallMediaProcessTarget) -> Result<CallMediaProcessTap, CallMediaIssue> {
        if let issue = createFailure { return .failure(issue) }
        let id = UInt32(created.count + 100)
        created.append(id); live.insert(id)
        onCreate?()
        return .success(CallMediaProcessTap(objectID: id, uid: UUID()))
    }
    func destroy(_ tap: CallMediaProcessTap) -> Bool {
        destroyed.append(tap.objectID)
        if destroyWorks { live.remove(tap.objectID) }
        return destroyWorks
    }
}

final class CallMediaProcessMuteTests: XCTestCase {
    private func session() -> CallMediaSession {
        CallMediaSession(id: "music:launch", bundleID: MediaPlayer.musicBundleID, contentID: "track",
            playing: true, volume: 50, routeID: "default", canMute: true, processMuteRouteID: "speakers")
    }

    func testReleaseOwnsOnlyTheTapAndNeverRestoresThePlayersVolume() throws {
        let driver = FakeProcessTapDriver(), token = UUID()
        let backend = CallMediaProcessMute(driver: driver)
        let after = try backend.mute(session(), token: token, permit: CallMediaPermit()).get()
        XCTAssertEqual(after.volume, 50)
        XCTAssertEqual(after.processMuteToken, token)
        XCTAssertTrue(backend.release(token, sessionID: after.id))
        XCTAssertTrue(driver.live.isEmpty)
        XCTAssertEqual(driver.destroyed, [100])
        XCTAssertTrue(backend.release(token, sessionID: after.id), "release is idempotent")
        XCTAssertEqual(driver.destroyed, [100])
    }

    func testAlreadyCancelledPermissionDeniedAndUnsupportedTargetsNeverCreateAMute() {
        let driver = FakeProcessTapDriver()
        let backend = CallMediaProcessMute(driver: driver)
        let permit = CallMediaPermit(); permit.invalidate()
        XCTAssertThrowsError(try backend.mute(session(), token: UUID(), permit: permit).get())
        for issue in [CallMediaIssue.permissionNeeded, .callAudioProtected, .selectiveMuteUnavailable, .sessionGone] {
            driver.current = .failure(issue)
            XCTAssertThrowsError(try backend.mute(session(), token: UUID(), permit: CallMediaPermit()).get())
        }
        XCTAssertTrue(driver.created.isEmpty)
    }

    func testObserverAndCreateFailuresLeaveNoResourceOrLiveObservation() {
        let driver = FakeProcessTapDriver()
        let backend = CallMediaProcessMute(driver: driver)
        driver.observeFailure = .unsupported
        XCTAssertThrowsError(try backend.mute(session(), token: UUID(), permit: CallMediaPermit()).get())
        XCTAssertEqual(driver.cancellations, 0)
        driver.observeFailure = nil; driver.createFailure = .permissionNeeded
        XCTAssertThrowsError(try backend.mute(session(), token: UUID(), permit: CallMediaPermit()).get())
        XCTAssertEqual(driver.cancellations, 1)
        XCTAssertTrue(driver.live.isEmpty)
    }

    func testCancellationDuringCreationDestroysItsOwnTap() {
        let driver = FakeProcessTapDriver(), permit = CallMediaPermit(), token = UUID()
        let backend = CallMediaProcessMute(driver: driver)
        driver.onCreate = { permit.invalidate() }
        XCTAssertThrowsError(try backend.mute(session(), token: token, permit: permit).get())
        XCTAssertFalse(backend.contains(token))
        XCTAssertTrue(driver.live.isEmpty)
        XCTAssertEqual(driver.cancellations, 1)
    }

    func testFailureToCleanUpCancelledCreationReturnsItsTokenForRecovery() throws {
        let driver = FakeProcessTapDriver(), permit = CallMediaPermit(), token = UUID()
        let backend = CallMediaProcessMute(driver: driver)
        driver.destroyWorks = false
        driver.onCreate = { permit.invalidate() }
        let after = try backend.mute(session(), token: token, permit: permit).get()
        XCTAssertEqual(after.processMuteToken, token)
        XCTAssertTrue(backend.contains(token))
        XCTAssertEqual(driver.cancellations, 0, "failed destruction must not lose listeners or ownership")
        driver.destroyWorks = true
        XCTAssertTrue(backend.release(token, sessionID: after.id))
        XCTAssertTrue(driver.live.isEmpty)
    }

    func testRouteABAEventPermanentlyReleasesThisIntervalEvenWhenSnapshotMatches() throws {
        let driver = FakeProcessTapDriver(), token = UUID()
        let backend = CallMediaProcessMute(driver: driver)
        var changes: [(UUID, CallMediaIssue, Bool)] = []
        backend.onInvalidated = { changes.append(($0, $1, $2)) }
        _ = try backend.mute(session(), token: token, permit: CallMediaPermit()).get()
        // The notification is the evidence. The current route still reads "speakers".
        driver.observers[0](.changedByUser)
        driver.observers[0](.changedByUser)
        XCTAssertFalse(backend.contains(token))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.1, .changedByUser)
        XCTAssertEqual(changes.first?.2, true)
        XCTAssertEqual(driver.destroyed, [100])
    }

    func testChangeDuringObserverSetupOrCreateCannotBecomeSuccessfulOwnedMute() {
        for duringCreate in [false, true] {
            let driver = FakeProcessTapDriver(), token = UUID()
            let backend = CallMediaProcessMute(driver: driver)
            let event = { driver.observers[0](.callAudioProtected) }
            if duringCreate { driver.onCreate = event } else { driver.onObserve = event }
            XCTAssertThrowsError(try backend.mute(session(), token: token, permit: CallMediaPermit()).get())
            XCTAssertFalse(backend.contains(token))
            XCTAssertTrue(driver.live.isEmpty)
        }
    }

    func testProcessReplacementAfterCreateReleasesWithoutTouchingTheReplacement() {
        let driver = FakeProcessTapDriver(), token = UUID()
        let backend = CallMediaProcessMute(driver: driver)
        driver.onCreate = { driver.current = .failure(.sessionGone) }
        XCTAssertThrowsError(try backend.mute(session(), token: token, permit: CallMediaPermit()).get())
        XCTAssertEqual(driver.destroyed, [100])
        XCTAssertTrue(driver.live.isEmpty)
    }

    func testDestructionFailureKeepsTokenAndReportsRecoveryThenAllowsBackupRetry() throws {
        let driver = FakeProcessTapDriver(), token = UUID()
        let backend = CallMediaProcessMute(driver: driver)
        var changed: (CallMediaIssue, Bool)?
        backend.onInvalidated = { _, issue, released in changed = (issue, released) }
        _ = try backend.mute(session(), token: token, permit: CallMediaPermit()).get()
        driver.destroyWorks = false
        driver.observers[0](.sessionGone)
        XCTAssertTrue(backend.contains(token))
        XCTAssertEqual(changed?.0, .commandFailed)
        XCTAssertEqual(changed?.1, false)
        driver.destroyWorks = true
        XCTAssertTrue(backend.release(token, sessionID: session().id))
        XCTAssertTrue(driver.live.isEmpty)
    }

    func testAStaleOrWrongSessionCannotDestroyANewerMute() throws {
        let driver = FakeProcessTapDriver(), token = UUID()
        let backend = CallMediaProcessMute(driver: driver)
        _ = try backend.mute(session(), token: token, permit: CallMediaPermit()).get()
        XCTAssertFalse(backend.release(token, sessionID: "restarted-player"))
        XCTAssertTrue(backend.release(UUID(), sessionID: session().id))
        XCTAssertTrue(backend.contains(token))
        XCTAssertTrue(driver.destroyed.isEmpty)
        XCTAssertThrowsError(try backend.mute(session(), token: UUID(), permit: CallMediaPermit()).get())
        XCTAssertEqual(driver.created, [100])
    }

    func testBackendShutdownDestroysItsResourcesAndListeners() throws {
        let driver = FakeProcessTapDriver()
        var backend: CallMediaProcessMute? = CallMediaProcessMute(driver: driver)
        _ = try backend?.mute(session(), token: UUID(), permit: CallMediaPermit()).get()
        backend = nil
        XCTAssertTrue(driver.live.isEmpty)
        XCTAssertEqual(driver.cancellations, 1)
    }
}

@MainActor
final class CallMediaProcessMuteControllerTests: XCTestCase {
    private func session(volume: Int = 50) -> CallMediaSession {
        CallMediaSession(id: "music:launch", bundleID: MediaPlayer.musicBundleID, contentID: "track",
            playing: true, volume: volume, routeID: "speakers", canMute: true, processMuteRouteID: "speakers")
    }

    func testManualVolumeABAAndFinalMuteSurviveTheCallWithoutAnyVolumeWrite() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session()]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .muteOnly)
        controller.updateCalls(["call"], policy: policy)
        platform.completeAll()
        XCTAssertEqual(controller.result.muted, 1)
        XCTAssertEqual(platform.sessions[0].volume, 50)
        platform.sessions[0].volume = 0
        platform.sessions[0].volume = 25
        platform.sessions[0].volume = 0
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertNil(platform.sessions[0].processMuteToken)
        XCTAssertEqual(platform.sessions[0].volume, 0)
        XCTAssertTrue(controller.recoveryItems.isEmpty, "a user's own mute is not failed sound recovery")
        XCTAssertFalse(controller.canRestoreSound)
        XCTAssertFalse(platform.applied.contains { if case .setVolume = $0 { return true }; return false })
    }

    func testAllEndPoliciesReleaseTemporaryMuteAndManualPolicyNeverStartsPlayback() {
        for restoration in CallMediaRestoration.allCases {
            let platform = CallMediaTestPlatform()
            platform.sessions = [session()]
            let controller = CallMediaController(platform: platform)
            let policy = CallMediaPolicy(mode: .muteOnly, restoration: restoration)
            controller.updateCalls(["first", "second"], policy: policy)
            platform.completeAll()
            controller.updateCalls(["second"], policy: policy)
            XCTAssertNotNil(platform.sessions[0].processMuteToken)
            controller.updateCalls([], policy: policy)
            platform.completeAll()
            XCTAssertNil(platform.sessions[0].processMuteToken)
            XCTAssertFalse(platform.applied.contains(.resume))
        }
    }

    func testBackupReleaseWorksMidCallAndTheSameIntervalDoesNotReapplyMute() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session()]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .muteOnly)
        controller.updateCalls(["call"], policy: policy)
        platform.completeAll()
        controller.restoreSoundNow()
        platform.completeAll()
        controller.updateCalls(["call", "another"], policy: policy)
        XCTAssertNil(platform.sessions[0].processMuteToken)
        XCTAssertEqual(platform.applied.count, 2)
        XCTAssertEqual(controller.result.activeCalls, 2)
        XCTAssertFalse(platform.applied.contains(.resume))
    }

    func testCallEndBeforeTheCreateAcknowledgementStillReleasesItsToken() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session()]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .muteOnly, restoration: .leaveAsIs)
        controller.updateCalls(["call"], policy: policy)
        platform.complete(holdReply: true)
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        platform.deliverHeldReply()
        platform.completeAll()
        XCTAssertNil(platform.sessions[0].processMuteToken)
        XCTAssertFalse(controller.canRestoreSound)
    }

    func testFailedEndReleaseKeepsRecoveryAndBackupButtonRetriesWithoutAutoplay() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session()]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .muteOnly)
        controller.updateCalls(["call"], policy: policy)
        platform.completeAll()
        platform.forcedFailure = .commandFailed
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertTrue(controller.canRestoreSound)
        XCTAssertEqual(controller.recoveryItems.count, 1)
        platform.forcedFailure = nil
        controller.restoreSoundNow()
        platform.completeAll()
        XCTAssertFalse(controller.canRestoreSound)
        XCTAssertTrue(controller.recoveryItems.isEmpty)
        XCTAssertFalse(platform.applied.contains(.resume))
    }

    func testPreexistingMuteIsNeverAcquired() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session(volume: 0)]
        let controller = CallMediaController(platform: platform)
        controller.updateCalls(["call"], policy: CallMediaPolicy(mode: .muteOnly))
        XCTAssertTrue(platform.requested.isEmpty)
    }

    func testBackupAlsoRevokesQueuedAutoplayAfterTheCallEnds() {
        let platform = CallMediaTestPlatform()
        var other = session(); other.id = "second-player"; other.canPause = false
        platform.sessions = [session(), other]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .pauseThenMute)
        controller.updateCalls(["call"], policy: policy)
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        controller.restoreSoundNow()
        platform.completeAll()
        XCTAssertFalse(platform.applied.contains(.resume))
        XCTAssertFalse(platform.sessions[0].playing)
        XCTAssertNil(platform.sessions[1].processMuteToken)
    }

    func testStaleVerificationCannotClearANewerMuteForTheSamePlayer() throws {
        for explicitRecoveryCheck in [false, true] {
            let platform = CallMediaTestPlatform()
            platform.sessions = [session()]
            let controller = CallMediaController(platform: platform)
            let policy = CallMediaPolicy(mode: .muteOnly)
            controller.updateCalls(["A"], policy: policy)
            platform.completeAll()
            let oldToken = try XCTUnwrap(platform.sessions[0].processMuteToken)
            platform.deferSoundRecovery = true
            if explicitRecoveryCheck { controller.checkSoundRecovery() }
            else {
                platform.forcedFailure = .commandFailed
                controller.updateCalls([], policy: policy)
                platform.completeAll()
                platform.forcedFailure = nil
            }
            XCTAssertEqual(platform.soundCheckCount, 1)
            if explicitRecoveryCheck { controller.updateCalls([], policy: policy) }
            platform.deferScan = true
            controller.updateCalls(["B"], policy: policy)
            // The HAL releases T1 by notification while B's scan and T1's verification are
            // queued. B can then own T2 before the old verification reply reaches main.
            platform.sessions[0].processMuteToken = nil
            platform.processMuteChanged?(oldToken, .changedByUser, true)
            platform.finishScan()
            platform.completeAll()
            let newToken = try XCTUnwrap(platform.sessions[0].processMuteToken)
            XCTAssertNotEqual(newToken, oldToken)
            platform.completeSoundRecovery(released: true)
            XCTAssertTrue(controller.canRestoreSound, "T1's verification must not erase T2")
            XCTAssertEqual(controller.result.muted, 1)
            controller.updateCalls([], policy: policy)
            platform.completeAll()
            XCTAssertNil(platform.sessions[0].processMuteToken)
            XCTAssertFalse(controller.canRestoreSound)
        }
    }

    func testNewCallCannotUndoBackupVetoWhileCancelledResumeStillAwaitsAReply() {
        let platform = CallMediaTestPlatform()
        var other = session(); other.id = "second-player"; other.canPause = false
        platform.sessions = [session(), other]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .pauseThenMute)
        controller.updateCalls(["A"], policy: policy)
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        controller.restoreSoundNow()
        controller.updateCalls(["B"], policy: policy)
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertFalse(platform.applied.contains(.resume))
        XCTAssertFalse(platform.sessions[0].playing)
        XCTAssertNil(platform.sessions[1].processMuteToken)
    }

    func testBackupVetoSurvivesAPauseAcknowledgementDeliveredDuringANewerCall() {
        let platform = CallMediaTestPlatform()
        var other = session(); other.id = "second-player"; other.canPause = false
        platform.sessions = [session(), other]
        let controller = CallMediaController(platform: platform)
        let policy = CallMediaPolicy(mode: .pauseThenMute)
        controller.updateCalls(["A"], policy: policy)
        platform.complete(holdReply: true) // The actual pause has happened; its ack is delayed.
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        controller.restoreSoundNow()
        controller.updateCalls(["B"], policy: policy)
        platform.deliverHeldReply()
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertFalse(platform.applied.contains(.resume))
        XCTAssertFalse(platform.sessions[0].playing)
        XCTAssertNil(platform.sessions[1].processMuteToken)
    }

    func testSourceLossCannotReviveAnOldPauseAfterANewerCall() {
        for reason in [CallMediaReleaseReason.disconnected, .permissionLost, .disabled] {
            for latePauseAcknowledgement in [false, true] {
            let platform = CallMediaTestPlatform()
            platform.sessions = [session()]
            let controller = CallMediaController(platform: platform)
            let policy = CallMediaPolicy(mode: .pauseOnly)
            controller.updateCalls(["A"], policy: policy)
            platform.complete(holdReply: latePauseAcknowledgement)
            if !latePauseAcknowledgement { controller.updateCalls([], policy: policy) }
            controller.release(reason: reason)
            controller.updateCalls(["B"], policy: policy)
            if latePauseAcknowledgement { platform.deliverHeldReply() }
            platform.completeAll()
            controller.updateCalls([], policy: policy)
            platform.completeAll()
            XCTAssertFalse(platform.applied.contains(.resume))
            }
        }
    }

    func testBackupRevokesAnAlreadyRunningPauseConfirmationAcrossTheNextCall() {
        let platform = CallMediaTestPlatform()
        let scheduler = CallMediaTestScheduler()
        var other = session(); other.id = "second-player"; other.canPause = false
        platform.sessions = [session(), other]
        platform.pauseConfirms = false
        let controller = CallMediaController(platform: platform, scheduler: scheduler)
        let policy = CallMediaPolicy(mode: .pauseThenMute)
        controller.updateCalls(["A"], policy: policy)
        platform.completeAll()
        platform.deferScan = true
        scheduler.advance() // A's confirmation scan is already in flight.
        platform.sessions[0].playing = false
        controller.updateCalls([], policy: policy)
        controller.restoreSoundNow()
        controller.updateCalls(["B"], policy: policy)
        platform.finishScan()
        platform.finishScan()
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertFalse(platform.applied.contains(.resume))
        XCTAssertNil(platform.sessions[1].processMuteToken)
        XCTAssertEqual(controller.result.pending, 0)
    }

    func testRecoveryVerificationHandsOffToBackupReleaseAfterItFindsTheTapStillMuted() throws {
        for callStillActive in [false, true] {
            let platform = CallMediaTestPlatform()
            platform.sessions = [session()]
            let controller = CallMediaController(platform: platform)
            let policy = CallMediaPolicy(mode: .muteOnly)
            controller.updateCalls(["call"], policy: policy)
            platform.completeAll()
            let token = try XCTUnwrap(platform.sessions[0].processMuteToken)
            if callStillActive {
                // The driver's invalidation tried to destroy its tap and failed.
                platform.processMuteChanged?(token, .commandFailed, false)
            } else {
                platform.forcedFailure = .commandFailed
                controller.updateCalls([], policy: policy)
                platform.completeAll()
                platform.forcedFailure = nil
            }
            XCTAssertEqual(controller.recoveryItems.count, 1)
            platform.deferSoundRecovery = true
            controller.checkSoundRecovery()
            XCTAssertEqual(platform.soundCheckCount, 1)
            controller.restoreSoundNow()
            XCTAssertEqual(platform.commandCount, 0, "the matching verification still owns the operation slot")
            platform.completeSoundRecovery(released: false)
            platform.completeAll()
            XCTAssertNil(platform.sessions[0].processMuteToken)
            XCTAssertFalse(controller.canRestoreSound)
            XCTAssertTrue(controller.recoveryItems.isEmpty)
            XCTAssertFalse(platform.applied.contains(.resume))
            XCTAssertFalse(platform.applied.contains { if case .setVolume = $0 { return true }; return false })
        }
    }
}
