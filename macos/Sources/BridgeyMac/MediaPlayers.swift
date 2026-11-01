import AppKit
import Foundation

/// The Mac player the phone controls, saved in `media.player` as `off`, `auto`, `music`, `spotify` or
/// `app:<bundle ID>`. Music and Spotify are driven by AppleScript, as before; Automatic and any other app
/// go through the system's Now Playing (what the menu bar's Now Playing shows).
enum MediaPlayer: Hashable, Identifiable {
    case off, automatic, music, spotify
    /// Another app, by bundle ID. The phone controls it while it is the app playing on the Mac.
    case app(String)

    static let musicBundleID = "com.apple.Music"
    static let spotifyBundleID = "com.spotify.client"
    /// The choices every Mac has, in menu order.
    static let fixed: [MediaPlayer] = [.off, .automatic, .music, .spotify]

    init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "auto": self = .automatic
        case "music": self = .music
        case "spotify": self = .spotify
        default:
            guard rawValue.hasPrefix("app:"), let player = MediaPlayer(bundleID: String(rawValue.dropFirst(4))) else { return nil }
            self = player
        }
    }

    /// The choice for an app. Music and Spotify keep their own scripted choice.
    init?(bundleID: String) {
        guard MediaPlayer.validBundleID(bundleID) else { return nil }
        switch bundleID {
        case MediaPlayer.musicBundleID: self = .music
        case MediaPlayer.spotifyBundleID: self = .spotify
        default: self = .app(bundleID)
        }
    }

    /// Bundle IDs reach a fixed script as a quoted literal, so only ASCII letters, digits, `.`, `-` and `_`.
    static func validBundleID(_ value: String) -> Bool {
        guard (1...255).contains(value.utf8.count), value.first != ".", value.first != "-" else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 46 || byte == 45 || byte == 95
        }
    }

    var rawValue: String {
        switch self {
        case .off: "off"
        case .automatic: "auto"
        case .music: "music"
        case .spotify: "spotify"
        case .app(let id): "app:\(id)"
        }
    }
    var id: String { rawValue }

    var bundleID: String? {
        switch self {
        case .off, .automatic: nil
        case .music: MediaPlayer.musicBundleID
        case .spotify: MediaPlayer.spotifyBundleID
        case .app(let id): id
        }
    }

    /// Driven by AppleScript, so macOS asks once for Automation access to the player.
    var scripted: Bool { self == .music || self == .spotify }

    /// The name sent to the phone (`player` in `media.state`).
    var title: String {
        switch self {
        case .off: "Off"
        case .automatic: "Automatic"
        case .music: "Music"
        case .spotify: "Spotify"
        case .app(let id): MediaApps.name(for: id)
        }
    }

    /// The name in the Mac's menus.
    var menuTitle: String {
        switch self {
        case .off: L10n.text("media.player.off", fallback: "Off")
        case .automatic: L10n.text("media.player.automatic", fallback: "Automatic (whatever is playing)")
        default: title
        }
    }
}

/// Apps that report to Now Playing, for the player menu: these show when installed or running.
enum MediaApps {
    static let known: [(id: String, name: String)] = [
        ("com.apple.podcasts", "Podcasts"), ("com.apple.TV", "TV"), ("com.apple.QuickTimePlayerX", "QuickTime Player"),
        ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Google Chrome"), ("org.mozilla.firefox", "Firefox"),
        ("company.thebrowser.Browser", "Arc"), ("app.zen-browser.zen", "Zen"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave"), ("org.videolan.vlc", "VLC"), ("com.colliderli.iina", "IINA"),
        ("com.tidal.desktop", "TIDAL"), ("com.deezer.deezer-desktop", "Deezer"), ("com.amazon.music", "Amazon Music"),
        ("com.github.th-ch.youtube-music", "YouTube Music"),
    ]
    /// How many apps the picker remembers from Now Playing.
    static let seenLimit = 10

    static func name(for bundleID: String) -> String {
        if let known = known.first(where: { $0.id == bundleID }) { return known.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return String((name.hasSuffix(".app") ? String(name.dropLast(4)) : name).prefix(64))
        }
        return String((bundleID.split(separator: ".").last.map(String.init) ?? bundleID).prefix(64))
    }

    /// The menu: the fixed choices, then other apps (seen in Now Playing, or known and on this Mac) by name.
    /// The current choice always shows, even when its app is gone.
    static func choices(current: MediaPlayer, seen: [String], onMac: (String) -> Bool,
                        name: (String) -> String = MediaApps.name(for:)) -> [MediaPlayer] {
        var others: [String] = []
        for id in seen + known.map(\.id) where !others.contains(id) {
            guard case .app = MediaPlayer(bundleID: id) else { continue }
            if seen.contains(id) || onMac(id) { others.append(id) }
        }
        if case .app(let id) = current, !others.contains(id) { others.append(id) }
        let sorted = others.map { (id: $0, name: name($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return MediaPlayer.fixed + sorted.map { .app($0.id) }
    }

    /// The seen list after Now Playing reported `bundleID`: newest first, at most `seenLimit`.
    static func remember(_ bundleID: String, in seen: [String]) -> [String] {
        guard case .app = MediaPlayer(bundleID: bundleID) else { return seen }
        return Array(([bundleID] + seen.filter { $0 != bundleID }).prefix(seenLimit))
    }

    /// Installed or running, for `choices`.
    static func onMac(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

// MARK: - Now Playing

/// What the system's Now Playing reports. Read with a fixed JavaScript for Automation script through
/// /usr/bin/osascript: macOS 15.4 and later only serve MediaRemote to Apple's own binaries, and osascript
/// is one (the same idea as github.com/ungive/mediaremote-adapter, which uses /usr/bin/perl; nothing is copied).
struct NowPlayingItem: Equatable {
    /// The app that reports it (a browser's parent app when the content runs in a helper).
    var bundleID: String
    var name: String
    var title = ""
    var artist = ""
    var playing = false
    var position = 0
    var duration = 0
    var artwork: Data? = nil
}

enum NowPlayingRead: Equatable {
    /// MediaRemote did not answer (a future macOS may close it): fall back to the AppleScript players.
    case unavailable
    /// Nothing reports to Now Playing.
    case nothing
    case item(NowPlayingItem)
}

enum NowPlaying {
    /// The read script. `artwork`: also return the artwork (skipped while the track stays the same).
    static func readScript(artwork: Bool) -> String {
        """
        ObjC.import('Foundation');
        function run() {
          const out = { v: 1, state: 'unavailable' };
          try {
            if (!$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load) return JSON.stringify(out);
            const R = $.NSClassFromString('MRNowPlayingRequest');
            if (R.isNil() || !R.respondsToSelector('localNowPlayingItem')) return JSON.stringify(out);
            const s = (v) => { const u = ObjC.unwrap(v); return typeof u === 'string' ? u.slice(0, 512) : ''; };
            const n = (v) => { const u = ObjC.unwrap(v); return typeof u === 'number' && isFinite(u) ? u : 0; };
            out.state = 'none';
            const path = R.localNowPlayingPlayerPath;
            const client = path.isNil() ? path : path.client;
            if (client.isNil()) return JSON.stringify(out);
            out.state = 'app';
            out.bundle = s(client.bundleIdentifier);
            out.parent = s(client.parentApplicationBundleIdentifier);
            out.name = s(client.displayName);
            out.playing = ObjC.unwrap(R.localIsPlaying) === true;
            const item = R.localNowPlayingItem;
            if (item.isNil() || item.metadata.isNil()) return JSON.stringify(out);
            const m = item.metadata;
            out.title = s(m.title);
            out.artist = s(m.trackArtistName);
            out.duration = n(m.duration);
            out.position = n(m.calculatedPlaybackPosition);
            if (\(artwork ? "true" : "false")) {
              try {
                const d = m.artworkData;
                if (!d.isNil() && d.length > 0 && d.length <= 1500000) out.art = ObjC.unwrap(d.base64EncodedStringWithOptions(0));
              } catch (e) {}
            }
          } catch (e) { return JSON.stringify({ v: 1, state: 'unavailable' }); }
          return JSON.stringify(out);
        }
        """
    }

    static func parse(_ output: String?) -> NowPlayingRead {
        guard let data = output?.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["v"] as? Int == 1, let state = json["state"] as? String else { return .unavailable }
        switch state {
        case "none": return .nothing
        case "app":
            let parent = json["parent"] as? String ?? ""
            let own = json["bundle"] as? String ?? ""
            let bundleID = MediaPlayer.validBundleID(parent) ? parent : own
            guard MediaPlayer.validBundleID(bundleID) else { return .nothing }
            func text(_ key: String) -> String {
                String((json[key] as? String ?? "").filter { !$0.isNewline && $0 != "\u{0}" }.prefix(256))
            }
            func seconds(_ key: String) -> Int {
                guard let value = (json[key] as? NSNumber)?.doubleValue, value.isFinite else { return 0 }
                return Int(min(max(value, 0), 604800))
            }
            var name = String(text("name").prefix(64))
            // A helper process (WebKit, a browser's media helper) names itself; the parent app's name reads better.
            if name.isEmpty || bundleID == parent { name = MediaApps.name(for: bundleID) }
            let artwork = (json["art"] as? String).flatMap { $0.utf8.count <= 2_000_000 ? Data(base64Encoded: $0) : nil }
            return .item(NowPlayingItem(bundleID: bundleID, name: name, title: text("title"), artist: text("artist"),
                                        playing: json["playing"] as? Bool == true, position: seconds("position"),
                                        duration: seconds("duration"), artwork: artwork))
        default: return .unavailable
        }
    }

    /// A phone command as a MediaRemote command number and optional position. Volume is not offered:
    /// Now Playing has no player volume, and the Mac's own volume belongs to Mac actions.
    static func command(_ action: String, value: String) -> (command: Int, position: Int?)? {
        switch action {
        case "toggle": return (2, nil)
        case "pause": return (1, nil)
        case "next": return (4, nil)
        case "previous": return (5, nil)
        case "seek":
            guard let seconds = Int(value), (0...604800).contains(seconds) else { return nil }
            return (24, seconds)
        default: return nil
        }
    }

    /// The command script. `expected`: only send while that app is the one playing (a chosen app).
    /// Only validated integers and a validated bundle ID are put in it.
    static func commandScript(command: Int, position: Int?, expected: String?) -> String? {
        guard [1, 2, 4, 5, 24].contains(command), (command == 24) == (position != nil),
              position.map({ (0...604800).contains($0) }) ?? true,
              expected.map(MediaPlayer.validBundleID) ?? true else { return nil }
        let options = position.map {
            "const o = $.NSMutableDictionary.dictionary; o.setObjectForKey($.NSNumber.numberWithDouble(\($0)), $('kMRMediaRemoteOptionPlaybackPosition'));"
        } ?? "const o = $.NSDictionary.dictionary;"
        return """
        ObjC.import('Foundation');
        function run() {
          try {
            if (!$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load) return 'unavailable';
            const R = $.NSClassFromString('MRNowPlayingRequest');
            if (R.isNil()) return 'unavailable';
            const want = '\(expected ?? "")';
            if (want !== '') {
              const path = R.localNowPlayingPlayerPath;
              const client = path.isNil() ? path : path.client;
              const id = client.isNil() ? '' : (ObjC.unwrap(client.parentApplicationBundleIdentifier) || ObjC.unwrap(client.bundleIdentifier) || '');
              if (id !== want) return 'other';
            }
            ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['unsigned int', 'id']]);
            \(options)
            const sent = $.MRMediaRemoteSendCommand(\(command), o) === true;
            delay(0.3);
            return sent ? 'ok' : 'failed';
          } catch (e) { return 'unavailable'; }
        }
        """
    }
}
