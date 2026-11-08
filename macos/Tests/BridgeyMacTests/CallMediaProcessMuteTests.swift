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
    func create(_ target: CallMediaProcessTarget) -> Result<UInt32, CallMediaIssue> {
        if let issue = createFailure { return .failure(issue) }
        let id = UInt32(created.count + 100)
        created.append(id); live.insert(id)
        onCreate?()
        return .success(id)
    }
    func destroy(_ tap: UInt32) -> Bool {
        destroyed.append(tap)
        if destroyWorks { live.remove(tap) }
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
}
