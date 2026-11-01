import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaSnapshot {
    var title = ""
    var artist = ""
    var playing = false
    var position = 0
    var duration = 0
    var volume = 0
    var detail = ""
    var artwork: String? = nil
    /// The commands the phone may send for this player (`controls` in `media.state`). Phones from before it
    /// enable every control for Music and Spotify only.
    var controls: [String] = []

    static let allControls = ["toggle", "pause", "next", "previous", "seek", "volume"]

    /// `player`: the name the phone shows (the app playing, in Automatic).
    func payload(player: String) -> [String: Any] {
        var value: [String: Any] = ["version": 1, "player": String(player.prefix(64)), "title": title, "artist": artist,
         "playing": playing, "position": position, "duration": duration, "volume": volume, "detail": detail,
         "controls": controls]
        if let artwork { value["artwork"] = artwork }
        return value
    }

    /// A Now Playing item as the phone's state: no player volume through Now Playing, so no volume control.
    static func nowPlaying(_ item: NowPlayingItem, artwork: String?) -> MediaSnapshot {
        MediaSnapshot(title: item.title, artist: item.artist, playing: item.playing, position: item.position,
                      duration: item.duration, volume: 0, detail: "", artwork: artwork,
                      controls: ["toggle", "pause", "next", "previous"] + (item.duration > 0 ? ["seek"] : []))
    }
}

func mediaCommand(_ action: String, value: String) -> String? {
    switch action {
    case "toggle": return "playpause"
    case "pause": return "pause"
    case "next": return "next track"
    case "previous": return "previous track"
    case "seek":
        guard let seconds = Int(value), (0...604800).contains(seconds) else { return nil }
        return "set player position to \(seconds)"
    case "volume":
        guard let volume = Int(value), (0...100).contains(volume) else { return nil }
        return "set sound volume to \(volume)"
    default: return nil
    }
}

// Only fixed scripts and validated integer operands reach osascript. No remote source code.
// `javaScript`: a JavaScript for Automation script (Now Playing), else AppleScript.
private func runMediaScript(_ source: String, limit: Int = 8192, javaScript: Bool = false) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = (javaScript ? ["-l", "JavaScript"] : []) + ["-e", source]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    do { try process.run() } catch { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: deadline)
    var data = Data()
    while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
        guard data.count + chunk.count <= limit else {
            pipe.fileHandleForReading.closeFile()
            process.terminate()
            process.waitUntilExit()
            deadline.cancel()
            return nil
        }
        data.append(chunk)
    }
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
}

// osascript prints raw Apple-event data as «data TYPE<hex>». Never read player files directly.
func mediaArtworkData(_ descriptor: String) -> Data? {
    guard descriptor.utf8.count <= 2_100_000, descriptor.hasPrefix("«data "), descriptor.hasSuffix("»") else { return nil }
    let hex = descriptor.dropFirst(10).dropLast()
    guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
    var bytes = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let end = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
        bytes.append(byte); index = end
    }
    return bytes
}

private func smallMediaArtwork(_ descriptor: String) -> String? {
    mediaArtworkData(descriptor).flatMap(smallMediaArtwork(data:))
}

/// At most 128x128 pixels and 16 KiB of JPEG, as `media.state` allows.
func smallMediaArtwork(data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    guard CGImageDestinationFinalize(destination), output.length <= 16384 else { return nil }
    return (output as Data).base64EncodedString()
}


/// What a Now Playing read means for the chosen player (pure, for tests).
enum MediaResolution: Equatable {
    /// Show this Now Playing item under `name`.
    case show(name: String, item: NowPlayingItem)
    /// Read this AppleScript player instead (Automatic, when Now Playing has nothing or is unavailable).
    case scripted(MediaPlayer)
    /// Nothing to control: `detail` says why.
    case message(name: String, detail: String)

    static let unavailableDetail = "Bridgey can't see what's playing on this Mac. Choose Music or Spotify in Bridgey Settings, Media."

    /// `running`: whether an AppleScript player (Music, Spotify) is open.
    static func resolve(_ player: MediaPlayer, read: NowPlayingRead, running: (MediaPlayer) -> Bool) -> MediaResolution {
        switch player {
        case .automatic:
            if case .item(let item) = read { return .show(name: item.name, item: item) }
            if running(.spotify) { return .scripted(.spotify) }
            if running(.music) { return .scripted(.music) }
            return .message(name: player.title, detail: read == .unavailable ? unavailableDetail : "Nothing is playing on your Mac")
        case .app(let id):
            let name = player.title
            switch read {
            // Now Playing names the app as the system shows it, which beats a guess from the bundle ID.
            case .item(let item) where item.bundleID == id: return .show(name: item.name.isEmpty ? name : item.name, item: item)
            case .unavailable: return .message(name: name, detail: unavailableDetail)
            default: return .message(name: name, detail: "Play something in \(name) on your Mac")
            }
        case .off, .music, .spotify:
            return .scripted(player)
        }
    }
}

@MainActor
final class MediaController: ObservableObject {
    @Published var player: MediaPlayer {
        didSet {
            UserDefaults.standard.set(player.rawValue, forKey: "media.player")
            generation += 1; shown = nil; scriptedFallback = nil; updateChoices(); refresh()
        }
    }
    @Published var pauseForCalls: Bool {
        didSet { UserDefaults.standard.set(pauseForCalls, forKey: "media.pauseForCalls") }
    }
    @Published private(set) var snapshot = MediaSnapshot()
    /// The player menu: Off, Automatic, Music, Spotify, then other apps on this Mac or seen in Now Playing.
    @Published private(set) var choices: [MediaPlayer] = MediaPlayer.fixed
    /// In Automatic, the app the phone sees now (empty while nothing plays).
    @Published private(set) var playingName = ""
    var onState: ([String: Any]) -> Void = { _ in }
    var allowed: () -> Bool = { false }
    private var busy = false
    private var generation = 0
    private var callActive = false
    private var pendingPause = false
    /// The Now Playing app last shown, so a command only reaches the app the phone was showing.
    private var shown: String?
    /// Automatic fell back to this AppleScript player on the last read.
    private var scriptedFallback: MediaPlayer?
    private var choicesUpdated = Date.distantPast
    private let queue = DispatchQueue(label: "\(Edition.identifier).media")
    private static let seenKey = "media.seenPlayers"

    init() {
        // Saved choices from before the picker (`off`, `music`, `spotify`) read the same; anything unreadable is Off.
        player = MediaPlayer(rawValue: UserDefaults.standard.string(forKey: "media.player") ?? "") ?? .off
        pauseForCalls = UserDefaults.standard.bool(forKey: "media.pauseForCalls")
        updateChoices()
    }

    func refresh() {
        if Date().timeIntervalSince(choicesUpdated) > 60 { updateChoices() }
        perform(nil, completion: { _ in })
    }
    func command(action: String, value: String, completion: @escaping (Bool) -> Void) {
        guard mediaCommand(action, value: value) != nil else { completion(false); return }
        perform((action, value), completion: completion)
    }
    func callChanged(active: Bool) {
        let shouldPause = active && !callActive && pauseForCalls
        callActive = active
        if !active { pendingPause = false }
        if shouldPause {
            if busy { pendingPause = true }
            else { command(action: "pause", value: "", completion: { _ in }) }
        }
    }
    func reset() { generation += 1; pendingPause = false; shown = nil; scriptedFallback = nil; snapshot = MediaSnapshot(); playingName = "" }

    func updateChoices() {
        choicesUpdated = Date()
        let seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        let updated = MediaApps.choices(current: player, seen: seen, onMac: MediaApps.onMac)
        if updated != choices { choices = updated }
    }

    private func remember(_ bundleID: String) {
        let seen = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        let updated = MediaApps.remember(bundleID, in: seen)
        guard updated != seen else { return }
        UserDefaults.standard.set(updated, forKey: Self.seenKey)
        updateChoices()
    }

    nonisolated private static func running(_ player: MediaPlayer) -> Bool {
        guard let id = player.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func perform(_ command: (action: String, value: String)?, completion: @escaping (Bool) -> Void) {
        guard allowed() else { snapshot = MediaSnapshot(); completion(false); return }
        guard player != .off else {
            snapshot = MediaSnapshot(detail: "Choose a player in Bridgey Settings on your Mac, under Media")
            onState(snapshot.payload(player: MediaPlayer.off.title)); completion(false); return
        }
        guard !busy else { completion(false); return }
        let selected = player
        if selected.scripted || (selected == .automatic && scriptedFallback != nil && command != nil) {
            let target = selected.scripted ? selected : scriptedFallback ?? selected
            guard Self.running(target) else {
                snapshot = MediaSnapshot(detail: "Open \(target.title) on your Mac")
                onState(snapshot.payload(player: target.title)); completion(false); return
            }
            run(selected, command: command, completion: completion) { previous in
                (Self.scriptedState(target, command: command, previous: previous), target.title, nil, target)
            }
            return
        }
        if case .app = selected, !Self.running(selected) {
            snapshot = MediaSnapshot(detail: "Open \(selected.title) on your Mac")
            onState(snapshot.payload(player: selected.title)); completion(false); return
        }
        // Now Playing: Automatic sends to the app the phone was showing; a chosen app only to itself.
        let expected = selected.bundleID ?? shown
        if command != nil, expected == nil { completion(false); return }
        run(selected, command: command, completion: completion) { previous in
            Self.nowPlayingState(selected, command: command, expected: expected, previous: previous)
        }
    }

    /// One read (and command) on the media queue. `work` returns the state, the name the phone shows,
    /// the Now Playing app shown and the AppleScript player Automatic fell back to.
    private func run(_ selected: MediaPlayer, command: (action: String, value: String)?, completion: @escaping (Bool) -> Void,
                     work: @escaping @Sendable (MediaSnapshot) -> (state: (snapshot: MediaSnapshot, commandOK: Bool, readOK: Bool),
                                                                 name: String, shown: String?, fallback: MediaPlayer?)) {
        busy = true
        let epoch = generation
        let previous = snapshot
        queue.async {
            let result = work(previous)
            DispatchQueue.main.async {
                self.busy = false
                defer {
                    if self.pendingPause && self.callActive && self.pauseForCalls {
                        self.pendingPause = false
                        self.command(action: "pause", value: "", completion: { _ in })
                    }
                }
                guard epoch == self.generation, self.allowed(), self.player == selected else {
                    completion(false)
                    return
                }
                if command != nil { completion(result.state.commandOK) }
                self.shown = result.shown
                if selected == .automatic {
                    self.scriptedFallback = result.fallback
                    self.playingName = result.state.snapshot.detail.isEmpty ? result.name : ""
                }
                if let shown = result.shown { self.remember(shown) }
                self.snapshot = result.state.snapshot
                self.onState(result.state.snapshot.payload(player: result.name))
                if command == nil { completion(result.state.readOK) }
            }
        }
    }

    /// Now Playing read, after the command if any; Automatic may fall back to an AppleScript player.
    nonisolated private static func nowPlayingState(_ selected: MediaPlayer, command: (action: String, value: String)?,
                                                    expected: String?, previous: MediaSnapshot)
        -> (state: (snapshot: MediaSnapshot, commandOK: Bool, readOK: Bool), name: String, shown: String?, fallback: MediaPlayer?) {
        var commandOK = false
        if let command {
            if let mapped = NowPlaying.command(command.action, value: command.value),
               let script = NowPlaying.commandScript(command: mapped.command, position: mapped.position, expected: expected) {
                commandOK = runMediaScript(script, javaScript: true) == "ok"
            }
        }
        var read = NowPlaying.parse(runMediaScript(NowPlaying.readScript(artwork: false), javaScript: true))
        // Artwork only when the track changed: it is the slow, large part.
        if case .item(var item) = read, !item.title.isEmpty, item.title != previous.title || item.artist != previous.artist {
            if case .item(let full) = NowPlaying.parse(runMediaScript(NowPlaying.readScript(artwork: true), limit: 2_100_000, javaScript: true)),
               full.bundleID == item.bundleID, full.title == item.title {
                item.artwork = full.artwork
                read = .item(item)
            }
        }
        switch MediaResolution.resolve(selected, read: read, running: running) {
        case .show(let name, let item):
            let sameTrack = previous.title == item.title && previous.artist == item.artist
            let artwork = item.artwork.flatMap(smallMediaArtwork(data:)) ?? (sameTrack ? previous.artwork : nil)
            return ((MediaSnapshot.nowPlaying(item, artwork: artwork), commandOK, true), name, item.bundleID, nil)
        case .scripted(let player):
            return (scriptedState(player, command: nil, previous: previous), player.title, nil, player)
        case .message(let name, let detail):
            return ((MediaSnapshot(detail: detail), commandOK, read != .unavailable), name, nil, nil)
        }
    }

    /// Music or Spotify through fixed AppleScript, as before the picker.
    nonisolated private static func scriptedState(_ selected: MediaPlayer, command: (action: String, value: String)?,
                                                  previous: MediaSnapshot) -> (snapshot: MediaSnapshot, commandOK: Bool, readOK: Bool) {
        guard let bundleID = selected.bundleID else { return (MediaSnapshot(), false, false) }
        let prefix = "with timeout of 3 seconds\n tell application id \"\(bundleID)\"\n"
        let suffix = "\n end tell\nend timeout"
        let commandOK = command.flatMap { mediaCommand($0.action, value: $0.value) }.map { runMediaScript(prefix + $0 + suffix) != nil } ?? false
        let duration = selected == .spotify ? "(duration of current track) / 1000" : "duration of current track"
        let source = prefix + """
            set sep to ASCII character 31
            set t to ""
            set a to ""
            set d to 0
            set p to 0
            try
                set t to name of current track
                set a to artist of current track
                set d to \(duration)
                set p to player position
            end try
            if (count t) > 256 then set t to text 1 thru 256 of t
            if (count a) > 256 then set a to text 1 thru 256 of a
            return t & sep & a & sep & (player state as text) & sep & (p as integer) & sep & (d as integer) & sep & sound volume
            """ + suffix
        let output = runMediaScript(source)
        let fields = output?.components(separatedBy: "\u{1f}") ?? []
        var result = MediaSnapshot(detail: "Allow Bridgey in System Settings, Privacy & Security, Automation")
        if fields.count == 6 {
            result = MediaSnapshot(title: String(fields[0].prefix(256)), artist: String(fields[1].prefix(256)),
                playing: fields[2] == "playing", position: min(max(Int(fields[3]) ?? 0, 0), 604800),
                duration: min(max(Int(fields[4]) ?? 0, 0), 604800), volume: min(max(Int(fields[5]) ?? 0, 0), 100),
                controls: MediaSnapshot.allControls)
            if selected == .music && !result.title.isEmpty {
                if previous.title == result.title && previous.artist == result.artist {
                    result.artwork = previous.artwork
                } else if let art = runMediaScript(prefix + "return raw data of artwork 1 of current track" + suffix, limit: 2_100_000) {
                    result.artwork = smallMediaArtwork(art)
                }
            }
        }
        return (result, commandOK, output != nil)
    }
}
