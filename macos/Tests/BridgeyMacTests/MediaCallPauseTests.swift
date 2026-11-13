import XCTest
@testable import BridgeyMac

/// Completes the controller's actual asynchronous path explicitly, without running its
/// AppleScript/Now Playing work closure or sending a command to a real player.
@MainActor
private final class ControlledMediaOperations {
    struct Request {
        let player: MediaPlayer
        let action: String?
        let completion: @MainActor (MediaOperationResult) -> Void
    }

    private(set) var requests: [Request] = []
    private var pending: [Request] = []

    func run(_ player: MediaPlayer, _ command: (action: String, value: String)?, _ previous: MediaSnapshot,
             _ work: @escaping @Sendable (MediaSnapshot) -> MediaOperationResult,
             _ completion: @escaping @MainActor (MediaOperationResult) -> Void) {
        let request = Request(player: player, action: command?.action, completion: completion)
        requests.append(request)
        pending.append(request)
    }

    var pauses: [MediaPlayer] { requests.filter { $0.action == "pause" }.map(\.player) }
    var pendingCount: Int { pending.count }

    func finish(title: String = "Track", shown: String? = nil) {
        guard !pending.isEmpty else { XCTFail("No media operation is pending"); return }
        let request = pending.removeFirst()
        let target = request.player.scripted ? nil : shown ?? request.player.bundleID
        let state = MediaSnapshot(title: title, playing: request.action != "pause")
        request.completion(((state, true, true), request.player.title, target,
                            request.player.scripted ? request.player : nil))
    }
}

@MainActor
final class MediaCallPauseTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    private var operations: ControlledMediaOperations!
    private var controller: MediaController!

    override func setUp() async throws {
        domain = "MediaCallPauseTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        operations = ControlledMediaOperations()
    }

    override func tearDown() async throws {
        controller = nil
        operations = nil
        defaults.removePersistentDomain(forName: domain)
        defaults = nil
    }

    private func makeController(player: MediaPlayer = .music, pause: Bool = true) {
        defaults.set(player.rawValue, forKey: "media.player")
        defaults.set(pause, forKey: "media.pauseForCalls")
        controller = MediaController(defaults: defaults, isRunning: { _ in true }, runOperation: operations.run)
        controller.allowed = { true }
    }

    func testEnablingPauseDuringAnExistingCallPausesWithoutWaitingForAnotherCall() {
        makeController(pause: false)
        controller.callChanged(active: true)
        XCTAssertTrue(operations.requests.isEmpty)

        controller.pauseForCalls = true

        XCTAssertEqual(operations.pauses, [.music])
        XCTAssertTrue(defaults.bool(forKey: "media.pauseForCalls"))
        operations.finish()
        controller.callChanged(active: false)
        XCTAssertEqual(operations.requests.map(\.action), ["pause"], "ending the call never resumes playback")
    }

    func testChangingPlayersDuringACallReadsThenPausesTheNewPlayerOnly() {
        makeController()
        controller.callChanged(active: true)
        operations.finish()

        controller.player = .spotify
        XCTAssertEqual(operations.requests.last?.player, .spotify)
        XCTAssertNil(operations.requests.last?.action, "the new player is refreshed first")
        XCTAssertEqual(operations.pauses, [.music])
        operations.finish()

        XCTAssertEqual(operations.pauses, [.music, .spotify])
        operations.finish()
        XCTAssertEqual(defaults.string(forKey: "media.player"), "spotify")
    }

    func testTurningThePolicyOffCancelsAPauseWaitingForAMetadataRead() {
        makeController()
        controller.refresh()
        controller.callChanged(active: true)
        controller.pauseForCalls = false

        operations.finish()

        XCTAssertTrue(operations.pauses.isEmpty)
        XCTAssertEqual(operations.requests.count, 1)
        XCTAssertEqual(operations.pendingCount, 0)
    }

    func testEndingTheCallCancelsAPauseWaitingForAMetadataRead() {
        makeController()
        controller.refresh()
        controller.callChanged(active: true)
        controller.callChanged(active: false)

        operations.finish()

        XCTAssertTrue(operations.pauses.isEmpty)
        XCTAssertEqual(operations.requests.count, 1)
        XCTAssertEqual(operations.pendingCount, 0)
    }

    func testStaleCompletionResolvesAutomaticBeforePausingItsCurrentTarget() {
        makeController()
        controller.refresh()
        controller.callChanged(active: true)
        controller.player = .automatic

        operations.finish(title: "Old song")

        XCTAssertEqual(controller.snapshot.title, "", "a result from the old generation is never published")
        XCTAssertEqual(operations.requests.map(\.player), [.music, .automatic])
        XCTAssertTrue(operations.pauses.isEmpty)
        operations.finish(title: "Video", shown: "org.videolan.vlc")

        XCTAssertEqual(controller.snapshot.title, "Video")
        XCTAssertEqual(operations.pauses, [.automatic], "the pause is issued after Automatic knows its app")
        operations.finish(title: "Video", shown: "org.videolan.vlc")
        XCTAssertEqual(operations.pendingCount, 0)
    }

    func testSeveralPlayerChangesDuringAReadOnlyRefreshAndPauseTheLatestChoice() {
        makeController()
        controller.refresh()
        controller.callChanged(active: true)
        controller.player = .spotify
        controller.player = .app("org.videolan.vlc")

        operations.finish()
        XCTAssertEqual(operations.requests.map(\.player), [.music, .app("org.videolan.vlc")])
        operations.finish()

        XCTAssertEqual(operations.pauses, [.app("org.videolan.vlc")])
        operations.finish()
        XCTAssertEqual(operations.pendingCount, 0)
    }

    func testRepeatedActiveUpdatesDoNotSpamPauseCommands() {
        makeController()
        controller.callChanged(active: true)
        controller.callChanged(active: true)
        operations.finish()
        controller.callChanged(active: true)

        XCTAssertEqual(operations.pauses, [.music])
        XCTAssertEqual(operations.requests.count, 1)

        controller.callChanged(active: false)
        controller.callChanged(active: true)
        XCTAssertEqual(operations.pauses, [.music, .music], "a later call gets its own pause")
        operations.finish()
    }

    func testPeriodicRefreshesCannotStarveAPauseWaitingForTheCurrentRead() {
        makeController()
        controller.refresh()
        for _ in 0..<5 { controller.refresh() }
        controller.callChanged(active: true)
        for _ in 0..<5 { controller.refresh() }
        XCTAssertEqual(operations.requests.count, 1)

        operations.finish()

        XCTAssertEqual(operations.requests.count, 2)
        XCTAssertEqual(operations.requests.last?.action, "pause", "a redundant refresh never takes priority over the call")
        XCTAssertEqual(operations.pauses, [.music])
        operations.finish()
        XCTAssertEqual(operations.pendingCount, 0)
    }

    func testOffStaysOffUntilAPlayerIsChosen() {
        makeController(player: .off)
        controller.callChanged(active: true)
        controller.pauseForCalls = false
        controller.pauseForCalls = true
        XCTAssertTrue(operations.requests.isEmpty)

        controller.player = .music
        operations.finish()

        XCTAssertEqual(operations.pauses, [.music])
        operations.finish()
    }

    func testAutomaticResolvesAnUnknownTargetWhenPolicyIsEnabledMidCall() {
        makeController(player: .automatic, pause: false)
        controller.callChanged(active: true)

        controller.pauseForCalls = true

        XCTAssertEqual(operations.requests.count, 1)
        XCTAssertNil(operations.requests[0].action)
        operations.finish(shown: "com.apple.Safari")
        XCTAssertEqual(operations.pauses, [.automatic])
        operations.finish(shown: "com.apple.Safari")
    }

    func testPermissionRevokedWhileWaitingPreventsThePauseOperation() {
        makeController()
        controller.refresh()
        controller.callChanged(active: true)
        controller.allowed = { false }

        operations.finish()

        XCTAssertTrue(operations.pauses.isEmpty)
        XCTAssertEqual(operations.requests.count, 1)
        XCTAssertEqual(operations.pendingCount, 0)
    }
}
