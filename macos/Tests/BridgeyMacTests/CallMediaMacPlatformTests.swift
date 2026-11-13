import XCTest
@testable import BridgeyMac

final class CallMediaMacPlatformTests: XCTestCase {
    func testScriptsCannotTargetArbitraryAppsOrUsePlaybackToggle() throws {
        for bundle in [MediaPlayer.musicBundleID, MediaPlayer.spotifyBundleID] {
            let pause = try XCTUnwrap(CallMediaMacScripts.command(.pause, bundleID: bundle))
            let resume = try XCTUnwrap(CallMediaMacScripts.command(.resume, bundleID: bundle))
            XCTAssertTrue(pause.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.contains("pause"))
            XCTAssertFalse(pause.contains("playpause"))
            XCTAssertFalse(resume.contains("playpause"))
            XCTAssertTrue(pause.contains("is not running"))
        }
        XCTAssertNil(CallMediaMacScripts.command(.pause, bundleID: "com.apple.FaceTime"))
        XCTAssertNil(CallMediaMacScripts.command(.setVolume(-1), bundleID: MediaPlayer.musicBundleID))
        XCTAssertNil(CallMediaMacScripts.command(.setVolume(101), bundleID: MediaPlayer.spotifyBundleID))
        XCTAssertNil(CallMediaMacScripts.command(.setVolume(0), bundleID: MediaPlayer.spotifyBundleID))
        XCTAssertNil(CallMediaMacScripts.command(.setVolume(50), bundleID: MediaPlayer.musicBundleID))
        XCTAssertNil(CallMediaMacScripts.command(.pause, bundleID: "evil\"\n do shell script \"anything"))
    }

    func testBrowserAndCallAppsCannotUseGenericResumeAdapter() {
        for bundle in ["com.apple.Safari", "com.google.Chrome", "us.zoom.xos", "com.apple.FaceTime", "com.unknown.app"] {
            XCTAssertNil(CallMediaMacScripts.nowPlayingResume(bundleID: bundle))
        }
        XCTAssertNotNil(CallMediaMacScripts.nowPlayingResume(bundleID: "org.videolan.vlc"))
    }

    func testMetadataReadRecordsAnActualItemAndHonestCapabilities() throws {
        let session = try XCTUnwrap(CallMediaMacScripts.parse("playing\u{1f}123\u{1f}45\u{1f}track-id",
            bundleID: MediaPlayer.musicBundleID, identity: "music:321:launch", routeID: "speakers"))
        XCTAssertTrue(session.playing)
        XCTAssertEqual(session.position, 123)
        XCTAssertEqual(session.volume, 45)
        XCTAssertTrue(session.canResume)
        XCTAssertFalse(session.canMute, "metadata/volume snapshots cannot establish a reliable mute capability")
        XCTAssertNotEqual(session.contentID, "track-id", "raw media identity is not copied into state results")

        let unknownItem = try XCTUnwrap(CallMediaMacScripts.parse("playing\u{1f}0\u{1f}45\u{1f}",
            bundleID: MediaPlayer.musicBundleID, identity: "music:321:launch", routeID: "unavailable"))
        XCTAssertFalse(unknownItem.canResume, "an unidentified item cannot safely autoplay later")
        XCTAssertFalse(unknownItem.canMute, "an unreadable route cannot support owned volume restoration")
    }

    func testMalformedOrOutOfRangePlayerStateIsNeverAccepted() {
        for output in ["playing", "unknown\u{1f}1\u{1f}50\u{1f}id", "playing\u{1f}-1\u{1f}50\u{1f}id",
                       "playing\u{1f}1\u{1f}101\u{1f}id", "playing\u{1f}1\u{1f}50\u{1f}" + String(repeating: "x", count: 513)] {
            XCTAssertNil(CallMediaMacScripts.parse(output, bundleID: MediaPlayer.musicBundleID, identity: "app", routeID: "r"))
        }
    }

    func testStoppedPlaybackCannotBeRestoredAsAnOwnedPause() throws {
        let paused = try XCTUnwrap(CallMediaMacScripts.parse("paused\u{1f}0\u{1f}50\u{1f}track",
            bundleID: MediaPlayer.musicBundleID, identity: "same-process", routeID: "speakers"))
        let stopped = try XCTUnwrap(CallMediaMacScripts.parse("stopped\u{1f}0\u{1f}50\u{1f}track",
            bundleID: MediaPlayer.musicBundleID, identity: "same-process", routeID: "speakers"))
        XCTAssertFalse(paused.stopped)
        XCTAssertTrue(stopped.stopped)
        XCTAssertFalse(stopped.canResume)
        XCTAssertTrue(paused.isStillPaused(from: paused))
        XCTAssertFalse(stopped.isStillPaused(from: paused))
        XCTAssertNotEqual(paused, stopped)
    }

    func testRestorationEvidenceRejectsASeekTrackRestartOrRouteChange() {
        let original = CallMediaSession(id: "process", bundleID: "media", contentID: "track", playing: false,
                                        position: 123, volume: 0, routeID: "speakers")
        var changed = original
        changed.position = 150
        XCTAssertFalse(changed.isStillPaused(from: original))
        changed = original; changed.contentID = "another-track"
        XCTAssertFalse(changed.isStillPaused(from: original))
        changed = original; changed.id = "restarted-process"
        XCTAssertFalse(changed.isStillPaused(from: original))
        changed = original; changed.routeID = "headphones"
        XCTAssertFalse(changed.hasSameSoundRoute(as: original))
    }

    @MainActor func testCallQuietStartsOffForEveryInstallAndUsesItsOwnExplicitDeviceGrant() {
        XCTAssertFalse(DefaultsGeneration.featureDefault(.callQuiet, generation: DefaultsGeneration.featuresOn))
        XCTAssertFalse(DefaultsGeneration.featureDefault(.callQuiet, generation: DefaultsGeneration.offUntilChosen))
        XCTAssertFalse(featureEnabledByLegacyPeer(.callQuiet))
        var model = SettingsModel()
        model.globalFeatures[.callQuiet] = true
        model.deviceFeatures["phone"] = [.remoteInput: true]
        XCTAssertFalse(model.isEnabled(.callQuiet, for: "phone"))
        model.deviceFeatures["phone"]?[.callQuiet] = true
        XCTAssertTrue(model.isEnabled(.callQuiet, for: "phone"))
        XCTAssertNil(SyncKey.key(for: .callQuiet), "sensitive enablement/grants never propagate through shared settings")
    }
}
