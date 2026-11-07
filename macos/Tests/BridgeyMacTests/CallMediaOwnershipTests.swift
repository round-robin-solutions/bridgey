import XCTest
@testable import BridgeyMac

@MainActor
private final class CallMediaMemoryOwnership: CallMediaOwnershipStore {
    var leases: [CallMediaMutedOwnership] = []
    var fails = false
    var writes = 0
    func load() throws -> [CallMediaMutedOwnership] { leases }
    func save(_ leases: [CallMediaMutedOwnership]) throws {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        writes += 1; self.leases = leases
    }
}

@MainActor
final class CallMediaOwnershipTests: XCTestCase {
    private func session() -> CallMediaSession {
        CallMediaSession(id: "com.apple.Music:123:launch", bundleID: MediaPlayer.musicBundleID,
                         contentID: "hashed-track", playing: true, position: 10, volume: 63,
                         routeID: "speakers", canMute: true)
    }

    func testSoundOwnershipIsWrittenBeforeMuteAndClearedAfterRestore() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session()]
        let store = CallMediaMemoryOwnership()
        let controller = CallMediaController(platform: platform, ownershipStore: store)
        let policy = CallMediaPolicy(mode: .muteOnly)
        controller.updateCalls(["call"], policy: policy)
        XCTAssertEqual(store.leases.first?.before.volume, 63)
        XCTAssertEqual(store.leases.first?.after.volume, 0)
        XCTAssertTrue(platform.applied.isEmpty, "the persistent intent precedes the actual volume change")
        platform.completeAll()
        controller.updateCalls([], policy: policy)
        platform.completeAll()
        XCTAssertEqual(platform.sessions[0].volume, 63)
        XCTAssertTrue(store.leases.isEmpty)
    }

    func testJournalFailurePreventsPersistentMute() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session()]
        let store = CallMediaMemoryOwnership()
        store.fails = true
        let controller = CallMediaController(platform: platform, ownershipStore: store)
        controller.updateCalls(["call"], policy: CallMediaPolicy(mode: .muteOnly))
        XCTAssertTrue(platform.requested.isEmpty)
        XCTAssertTrue(controller.result.issues.contains(.commandFailed))
        XCTAssertEqual(platform.sessions[0].volume, 63)
    }

    func testExitAfterMuteDispatchKeepsRecoveryUntilManualRepair() {
        let platform = CallMediaTestPlatform()
        platform.sessions = [session()]
        platform.postApplyFailure = .sessionGone
        let store = CallMediaMemoryOwnership()
        let controller = CallMediaController(platform: platform, ownershipStore: store)
        controller.updateCalls(["call"], policy: CallMediaPolicy(mode: .muteOnly))
        platform.complete()
        XCTAssertEqual(platform.sessions[0].volume, 0)
        XCTAssertEqual(store.leases.count, 1, "an uncertain post-dispatch result cannot erase the write-ahead intent")

        platform.postApplyFailure = nil
        platform.sessions.removeAll()
        var reset: Bool?
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, false)
        XCTAssertEqual(store.leases.count, 1)

        var repaired = session()
        repaired.id = "replacement-process"; repaired.volume = 24
        platform.sessions = [repaired]
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, true)
        XCTAssertEqual(platform.sessions[0].volume, 24)
        XCTAssertTrue(store.leases.isEmpty)
        XCTAssertFalse(platform.applied.contains(.resume))
    }

    func testRecoveredWriteAheadIntentRestoresSoundOnlyAfterConfirmedEmptyState() {
        let platform = CallMediaTestPlatform()
        let before = session()
        var after = before; after.volume = 0
        platform.sessions = [after]
        let store = CallMediaMemoryOwnership()
        store.leases = [CallMediaMutedOwnership(before: before, after: after)]
        let controller = CallMediaController(platform: platform, ownershipStore: store)
        XCTAssertTrue(platform.requested.isEmpty, "loading recovery evidence alone never changes playback")
        controller.updateCalls([], policy: CallMediaPolicy())
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.setVolume(63)])
        XCTAssertFalse(platform.applied.contains(.resume))
        XCTAssertTrue(store.leases.isEmpty)
    }

    func testRecoveryDuringAnActiveCallKeepsOwnedSoundQuietUntilLastCall() {
        let platform = CallMediaTestPlatform()
        let before = session()
        var after = before; after.volume = 0
        platform.sessions = [after]
        let store = CallMediaMemoryOwnership()
        store.leases = [CallMediaMutedOwnership(before: before, after: after)]
        let controller = CallMediaController(platform: platform, ownershipStore: store)
        controller.updateCalls(["call"], policy: CallMediaPolicy())
        XCTAssertTrue(platform.requested.isEmpty)
        controller.updateCalls([], policy: CallMediaPolicy())
        platform.completeAll()
        XCTAssertEqual(platform.applied, [.setVolume(63)])
    }

    func testFileJournalIsBoundedPrivateAndRoundTripsOnlyValidOwnedSound() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("call-media-journal-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.json")
        let store = CallMediaFileOwnershipStore(url: url)
        let before = session()
        var after = before; after.volume = 0
        let lease = CallMediaMutedOwnership(before: before, after: after)
        try store.save([lease])
        XCTAssertEqual(try store.load(), [lease])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var changed = lease; changed.after.id = "another-process"
        XCTAssertThrowsError(try store.save([changed]))
        try Data(repeating: 65, count: 65_537).write(to: url)
        XCTAssertThrowsError(try store.load())
    }

    func testClosedAndRestartedPlayerKeepRecoveryUntilManualRepairThenResetCanFinish() {
        let platform = CallMediaTestPlatform()
        let store = CallMediaMemoryOwnership()
        platform.sessions = [session()]
        let controller = CallMediaController(platform: platform, ownershipStore: store)
        controller.updateCalls(["call"], policy: CallMediaPolicy(mode: .muteOnly))
        platform.completeAll()
        platform.sessions.removeAll() // Closing the player is not proof its persistent volume was restored.
        var reset: Bool?
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, false)
        XCTAssertEqual(store.leases.count, 1)
        XCTAssertEqual(controller.recoveryItems.first?.originalVolume, 63)

        var restarted = session()
        restarted.id = "new-process"; restarted.volume = 0
        platform.sessions = [restarted]
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, false)
        XCTAssertEqual(platform.sessions[0].volume, 0, "a stale lease must never set the new process's volume")
        XCTAssertEqual(store.leases.count, 1)

        platform.sessions[0].volume = 25 // Explicit manual repair takes precedence over the old 63% setting.
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, true)
        XCTAssertEqual(platform.sessions[0].volume, 25)
        XCTAssertTrue(store.leases.isEmpty)
        XCTAssertFalse(platform.applied.contains(.resume))
    }

    func testPermissionDeniedPreservesSoundEvidenceAndBlocksResetUntilItCanBeVerified() {
        let platform = CallMediaTestPlatform()
        let store = CallMediaMemoryOwnership()
        platform.sessions = [session()]
        let controller = CallMediaController(platform: platform, ownershipStore: store)
        controller.updateCalls(["call"], policy: CallMediaPolicy(mode: .muteOnly))
        platform.completeAll()
        platform.forcedFailure = .permissionNeeded
        var reset: Bool?
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, false)
        XCTAssertEqual(store.leases.count, 1)
        platform.forcedFailure = nil
        controller.prepareForReset { reset = $0 }
        platform.completeAll()
        XCTAssertEqual(reset, true)
        XCTAssertEqual(platform.sessions[0].volume, 63)
        XCTAssertTrue(store.leases.isEmpty)
    }

    func testResetRestoresOwnedSoundWithoutResumingPlaybackAndHasABoundedTimeout() {
        let platform = CallMediaTestPlatform()
        let scheduler = CallMediaTestScheduler()
        platform.sessions = [session()]
        let controller = CallMediaController(platform: platform, scheduler: scheduler)
        controller.updateCalls(["call"], policy: CallMediaPolicy(mode: .muteOnly))
        platform.completeAll()
        var reset: Bool?
        controller.prepareForReset { reset = $0 }
        XCTAssertNil(reset)
        scheduler.advance()
        XCTAssertEqual(reset, false, "an unresponsive backend cannot hang Reset Everything indefinitely")
        platform.completeAll()
        XCTAssertEqual(platform.sessions[0].volume, 63)
        XCTAssertFalse(platform.applied.contains(.resume))
    }
}
