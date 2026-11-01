import XCTest
@testable import BridgeyMac

final class MediaPlayerTests: XCTestCase {
    func testSavedChoicesReadTheSameAndNewOnesRoundTrip() {
        // Saved before the picker: off, music and spotify keep meaning the same player.
        XCTAssertEqual(MediaPlayer(rawValue: "off"), .off)
        XCTAssertEqual(MediaPlayer(rawValue: "music"), .music)
        XCTAssertEqual(MediaPlayer(rawValue: "spotify"), .spotify)
        XCTAssertEqual(MediaPlayer(rawValue: "auto"), .automatic)
        XCTAssertEqual(MediaPlayer(rawValue: "app:org.videolan.vlc"), .app("org.videolan.vlc"))
        for player in [MediaPlayer.off, .automatic, .music, .spotify, .app("com.colliderli.iina")] {
            XCTAssertEqual(MediaPlayer(rawValue: player.rawValue), player)
        }
        // Music and Spotify by bundle ID stay the scripted players.
        XCTAssertEqual(MediaPlayer(rawValue: "app:com.apple.Music"), .music)
        XCTAssertEqual(MediaPlayer(rawValue: "app:com.spotify.client"), .spotify)
        for bad in ["", "Spotify", "app:", "app:with space", "app:x';$.doShellScript('id", "app:.hidden", "app:" + String(repeating: "a", count: 256)] {
            XCTAssertNil(MediaPlayer(rawValue: bad), bad)
        }
    }

    func testOnlyMusicAndSpotifyAreScripted() {
        XCTAssertTrue(MediaPlayer.music.scripted)
        XCTAssertTrue(MediaPlayer.spotify.scripted)
        XCTAssertFalse(MediaPlayer.automatic.scripted)
        XCTAssertFalse(MediaPlayer.off.scripted)
        XCTAssertFalse(MediaPlayer.app("org.videolan.vlc").scripted)
        XCTAssertEqual(MediaPlayer.music.bundleID, "com.apple.Music")
        XCTAssertEqual(MediaPlayer.spotify.bundleID, "com.spotify.client")
        XCTAssertNil(MediaPlayer.automatic.bundleID)
        XCTAssertEqual(MediaPlayer.app("org.videolan.vlc").title, "VLC")
        XCTAssertEqual(MediaPlayer.spotify.title, "Spotify")
        XCTAssertEqual(MediaPlayer.automatic.title, "Automatic")
        XCTAssertEqual(MediaPlayer.automatic.menuTitle, "Automatic (whatever is playing)")
    }

    func testValidBundleIDs() {
        for good in ["com.apple.Music", "org.videolan.vlc", "app.zen-browser.zen", "com.github.th-ch.youtube-music", "a_b.c"] {
            XCTAssertTrue(MediaPlayer.validBundleID(good), good)
        }
        for bad in ["", ".a", "-a", "a b", "a'b", "a\"b", "a\\b", "a\nb", "é.app", String(repeating: "a", count: 256)] {
            XCTAssertFalse(MediaPlayer.validBundleID(bad), bad)
        }
    }

    func testChoicesListFixedPlayersThenAppsByName() {
        let names = ["org.videolan.vlc": "VLC", "com.apple.podcasts": "Podcasts", "dev.example.tunes": "Tunes", "com.colliderli.iina": "IINA"]
        let onMac: Set = ["org.videolan.vlc", "com.apple.podcasts"]
        let choices = MediaApps.choices(current: .spotify, seen: ["dev.example.tunes", "com.spotify.client", "com.apple.Music"],
                                        onMac: { onMac.contains($0) }, name: { names[$0] ?? $0 })
        XCTAssertEqual(choices, [.off, .automatic, .music, .spotify, .app("com.apple.podcasts"), .app("dev.example.tunes"), .app("org.videolan.vlc")])
        // A chosen app that is gone still shows, so the menu has a check mark.
        let gone = MediaApps.choices(current: .app("com.colliderli.iina"), seen: [], onMac: { _ in false }, name: { names[$0] ?? $0 })
        XCTAssertEqual(gone, MediaPlayer.fixed + [.app("com.colliderli.iina")])
        XCTAssertEqual(MediaApps.choices(current: .off, seen: [], onMac: { _ in false }), MediaPlayer.fixed)
    }

    func testSeenAppsAreNewestFirstAndBounded() {
        var seen: [String] = []
        for index in 0..<15 { seen = MediaApps.remember("dev.example.app\(index)", in: seen) }
        XCTAssertEqual(seen.count, MediaApps.seenLimit)
        XCTAssertEqual(seen.first, "dev.example.app14")
        seen = MediaApps.remember("dev.example.app10", in: seen)
        XCTAssertEqual(seen.first, "dev.example.app10")
        XCTAssertEqual(seen.filter { $0 == "dev.example.app10" }.count, 1)
        XCTAssertEqual(MediaApps.remember("com.apple.Music", in: seen), seen, "Music has its own choice")
        XCTAssertEqual(MediaApps.remember("bad id", in: seen), seen)
    }

    func testNowPlayingParse() {
        XCTAssertEqual(NowPlaying.parse(nil), .unavailable)
        XCTAssertEqual(NowPlaying.parse("garbage"), .unavailable)
        XCTAssertEqual(NowPlaying.parse(#"{"v":2,"state":"none"}"#), .unavailable)
        XCTAssertEqual(NowPlaying.parse(#"{"v":1,"state":"unavailable"}"#), .unavailable)
        XCTAssertEqual(NowPlaying.parse(#"{"v":1,"state":"none"}"#), .nothing)
        XCTAssertEqual(NowPlaying.parse(#"{"v":1,"state":"app","bundle":"bad id","parent":""}"#), .nothing)
        let read = NowPlaying.parse(#"""
            {"v":1,"state":"app","bundle":"dev.example.player","parent":"","name":"Example Player","playing":true,
             "title":"Song\nOne","artist":"Band","duration":700000.5,"position":-3,"art":"AQID"}
            """#)
        XCTAssertEqual(read, .item(NowPlayingItem(bundleID: "dev.example.player", name: "Example Player", title: "SongOne", artist: "Band",
                                                  playing: true, position: 0, duration: 604800, artwork: Data([1, 2, 3]))))
        // A browser's media helper: the parent app is the player.
        let helper = NowPlaying.parse(#"{"v":1,"state":"app","bundle":"com.apple.WebKit.GPU","parent":"com.apple.Safari","name":"Safari Web Content","playing":false,"title":"Video"}"#)
        guard case .item(let item) = helper else { return XCTFail("\(helper)") }
        XCTAssertEqual(item.bundleID, "com.apple.Safari")
        XCTAssertEqual(item.name, "Safari")
        XCTAssertFalse(item.playing)
        let long = NowPlaying.parse(#"{"v":1,"state":"app","bundle":"dev.example.player","title":""# + String(repeating: "x", count: 600) + #""}"#)
        guard case .item(let longItem) = long else { return XCTFail("\(long)") }
        XCTAssertEqual(longItem.title.count, 256)
    }

    func testNowPlayingCommandsAreFixedNumbers() {
        XCTAssertEqual(NowPlaying.command("toggle", value: "")?.command, 2)
        XCTAssertEqual(NowPlaying.command("pause", value: "")?.command, 1)
        XCTAssertEqual(NowPlaying.command("next", value: "")?.command, 4)
        XCTAssertEqual(NowPlaying.command("previous", value: "")?.command, 5)
        XCTAssertEqual(NowPlaying.command("seek", value: "90")?.command, 24)
        XCTAssertEqual(NowPlaying.command("seek", value: "90")?.position, 90)
        XCTAssertNil(NowPlaying.command("volume", value: "50"), "Now Playing has no player volume")
        XCTAssertNil(NowPlaying.command("seek", value: "604801"))
        XCTAssertNil(NowPlaying.command("seek", value: "1); $.doShellScript('id"))
        XCTAssertNil(NowPlaying.command("do shell script", value: ""))
    }

    func testCommandScriptTakesOnlyValidatedValues() throws {
        let toggle = try XCTUnwrap(NowPlaying.commandScript(command: 2, position: nil, expected: "org.videolan.vlc"))
        XCTAssertTrue(toggle.contains("const want = 'org.videolan.vlc';"))
        XCTAssertTrue(toggle.contains("MRMediaRemoteSendCommand(2, o)"))
        let seek = try XCTUnwrap(NowPlaying.commandScript(command: 24, position: 75, expected: nil))
        XCTAssertTrue(seek.contains("numberWithDouble(75)"))
        XCTAssertTrue(seek.contains("const want = '';"))
        XCTAssertNil(NowPlaying.commandScript(command: 3, position: nil, expected: nil), "not a phone command")
        XCTAssertNil(NowPlaying.commandScript(command: 24, position: nil, expected: nil))
        XCTAssertNil(NowPlaying.commandScript(command: 2, position: 5, expected: nil))
        XCTAssertNil(NowPlaying.commandScript(command: 24, position: 604801, expected: nil))
        XCTAssertNil(NowPlaying.commandScript(command: 2, position: nil, expected: "x'; $.doShellScript('id"))
        XCTAssertTrue(NowPlaying.readScript(artwork: true).contains("if (true)"))
        XCTAssertTrue(NowPlaying.readScript(artwork: false).contains("if (false)"))
    }

    func testResolveAutomaticChosenAppAndFallback() {
        let vlc = NowPlayingItem(bundleID: "org.videolan.vlc", name: "VLC", title: "Film", playing: true)
        let none: (MediaPlayer) -> Bool = { _ in false }
        XCTAssertEqual(MediaResolution.resolve(.automatic, read: .item(vlc), running: none), .show(name: "VLC", item: vlc))
        XCTAssertEqual(MediaResolution.resolve(.automatic, read: .nothing, running: none), .message(name: "Automatic", detail: "Nothing is playing on your Mac"))
        XCTAssertEqual(MediaResolution.resolve(.automatic, read: .unavailable, running: none), .message(name: "Automatic", detail: MediaResolution.unavailableDetail))
        // Now Playing has nothing or is closed: the AppleScript players, Spotify first.
        XCTAssertEqual(MediaResolution.resolve(.automatic, read: .unavailable, running: { $0 == .music }), .scripted(.music))
        XCTAssertEqual(MediaResolution.resolve(.automatic, read: .nothing, running: { _ in true }), .scripted(.spotify))
        // A chosen app shows only while it is the app playing.
        XCTAssertEqual(MediaResolution.resolve(.app("org.videolan.vlc"), read: .item(vlc), running: none), .show(name: "VLC", item: vlc))
        let other = NowPlayingItem(bundleID: "com.apple.Safari", name: "Safari")
        XCTAssertEqual(MediaResolution.resolve(.app("org.videolan.vlc"), read: .item(other), running: none),
                       .message(name: "VLC", detail: "Play something in VLC on your Mac"))
        XCTAssertEqual(MediaResolution.resolve(.app("org.videolan.vlc"), read: .unavailable, running: none),
                       .message(name: "VLC", detail: MediaResolution.unavailableDetail))
        XCTAssertEqual(MediaResolution.resolve(.spotify, read: .item(vlc), running: none), .scripted(.spotify))
        // An app the known list does not name takes the name Now Playing gives it.
        let test = NowPlayingItem(bundleID: "in.roundrobin.bridgey.mediatest.player", name: "Bridgey Media Test Player")
        XCTAssertEqual(MediaResolution.resolve(.app("in.roundrobin.bridgey.mediatest.player"), read: .item(test), running: none),
                       .show(name: "Bridgey Media Test Player", item: test))
    }

    func testStatePayloadNamesThePlayerAndItsControls() {
        let item = NowPlayingItem(bundleID: "org.videolan.vlc", name: "VLC", title: "Film", artist: "", playing: true, position: 5, duration: 0)
        let live = MediaSnapshot.nowPlaying(item, artwork: nil)
        XCTAssertEqual(live.controls, ["toggle", "pause", "next", "previous"], "no seek without a duration, never volume")
        var long = item
        long.duration = 100
        XCTAssertEqual(MediaSnapshot.nowPlaying(long, artwork: nil).controls, ["toggle", "pause", "next", "previous", "seek"])
        let payload = live.payload(player: "VLC")
        XCTAssertEqual(payload["player"] as? String, "VLC")
        XCTAssertEqual(payload["controls"] as? [String], ["toggle", "pause", "next", "previous"])
        XCTAssertEqual(payload["detail"] as? String, "")
        XCTAssertEqual((MediaSnapshot().payload(player: String(repeating: "n", count: 100))["player"] as? String)?.count, 64)
        let data = try? JSONSerialization.data(withJSONObject: payload)
        XCTAssertNotNil(data)
        XCTAssertLessThan(data?.count ?? .max, 32768)
        XCTAssertEqual(MediaSnapshot.allControls, ["toggle", "pause", "next", "previous", "seek", "volume"])
    }

    func testAutomationIsNeededOnlyForScriptedPlayers() {
        var needs = PermissionNeeds(notifications: false, calls: false, codes: false, remoteControl: false, media: true, mediaPlayer: .automatic)
        XCTAssertFalse(needs.needed(.automation))
        needs.mediaPlayer = .app("org.videolan.vlc")
        XCTAssertFalse(needs.needed(.automation))
        needs.mediaPlayer = .music
        XCTAssertTrue(needs.needed(.automation))
    }

    @MainActor
    func testSavedSpotifyStaysSpotify() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "media.player")
        defer { if let saved { defaults.set(saved, forKey: "media.player") } else { defaults.removeObject(forKey: "media.player") } }
        defaults.set("spotify", forKey: "media.player")
        XCTAssertEqual(MediaController().player, .spotify)
        defaults.removeObject(forKey: "media.player")
        XCTAssertEqual(MediaController().player, .off, "off until chosen")
        defaults.set("something-else", forKey: "media.player")
        XCTAssertEqual(MediaController().player, .off)
    }
}
