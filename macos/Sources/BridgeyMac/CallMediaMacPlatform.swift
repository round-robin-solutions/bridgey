import AppKit
import CoreAudio
import CryptoKit
import Foundation

/// Public playback automation and temporary Core Audio process mutes for Music/Spotify;
/// the existing Now Playing compatibility backend for a bounded set of media-only apps.
@MainActor
final class CallMediaMacPlatform: CallMediaPlatform {
    private let queue: DispatchQueue
    private let processMute: CallMediaProcessMute
    private var localCallActive = false

    init() {
        let queue = DispatchQueue(label: "\(Edition.identifier).call-media")
        self.queue = queue
        processMute = CallMediaProcessMute(driver: CallMediaCoreAudioTap(queue: queue))
    }

    func observeProcessMuteRelease(_ changed: @escaping @MainActor (UUID, CallMediaIssue, Bool) -> Void) {
        let backend = processMute
        queue.async {
            backend.onInvalidated = { token, issue, released in
                DispatchQueue.main.async { changed(token, issue, released) }
            }
        }
    }

    func setLocalCallActive(_ active: Bool) { localCallActive = active }

    func scan(_ completion: @escaping @MainActor (CallMediaScan) -> Void) {
        enqueueScan(permit: nil, completion)
    }

    func scan(permit: CallMediaPermit, _ completion: @escaping @MainActor (CallMediaScan) -> Void) {
        enqueueScan(permit: permit, completion)
    }

    private func enqueueScan(permit: CallMediaPermit?, _ completion: @escaping @MainActor (CallMediaScan) -> Void) {
        let protectingLocalCall = localCallActive
        let backend = processMute
        queue.async {
            var result = Self.readAll(localCallActive: protectingLocalCall, permit: permit)
            result.sessions = result.sessions.map { backend.decorate($0) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func command(_ action: CallMediaAction, session: CallMediaSession, permit: CallMediaPermit,
                 completion: @escaping @MainActor (Result<CallMediaSession, CallMediaIssue>) -> Void) {
        let protectingLocalCall = localCallActive
        let backend = processMute
        queue.async {
            let result: Result<CallMediaSession, CallMediaIssue>
            switch action {
            case .releaseProcessMute(let token):
                if !permit.isValid { result = .failure(.cancelled) }
                else if backend.release(token, sessionID: session.id) {
                    var released = session; released.processMuteToken = nil; released.processMuteActive = false
                    result = .success(released)
                } else { result = .failure(.commandFailed) }
            case .muteProcess(let token):
                if !permit.isValid { result = .failure(.cancelled) }
                else if Self.identity(session.bundleID) != session.id { result = .failure(.sessionGone) }
                else {
                    switch Self.readScripted(session.bundleID, identity: session.id) {
                    case .failure(let issue): result = .failure(issue)
                    case .success(let current):
                        if !current.playing || current.contentID != session.contentID || current.volume != session.volume {
                            result = .failure(.changedByUser)
                        } else { result = backend.mute(session, token: token, permit: permit) }
                    }
                }
            case .setVolume:
                // Snapshot comparison cannot prove volume ownership after a later manual mute.
                // This live platform never writes a player's persistent volume, even on failure.
                result = .failure(.selectiveMuteUnavailable)
            case .pause, .resume:
                result = Self.apply(action, expected: session, permit: permit, localCallActive: protectingLocalCall)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func soundWasReleased(_ ownership: CallMediaMutedOwnership, completion: @escaping @MainActor (Bool) -> Void) {
        let backend = processMute
        queue.async {
            let released: Bool
            if let token = ownership.after.processMuteToken { released = !backend.contains(token) }
            else { released = false }
            DispatchQueue.main.async { completion(released) }
        }
    }

    nonisolated private static func readAll(localCallActive: Bool, permit: CallMediaPermit?) -> CallMediaScan {
        // Neither the public Now Playing API nor the compatibility backend enumerates every app.
        // Keep this limitation visible even when all the supported players were successfully quieted.
        var result = CallMediaScan(sessions: [], issues: [.otherPlayersLimited])
        for bundle in [MediaPlayer.musicBundleID, MediaPlayer.spotifyBundleID] {
            guard permit?.isValid != false else { return CallMediaScan(sessions: [], issues: [.cancelled]) }
            guard let identity = identity(bundle) else { continue }
            switch readScripted(bundle, identity: identity) {
            case .success(let session): result.sessions.append(session)
            case .failure(let issue): result.issues.insert(issue)
            }
        }
        guard permit?.isValid != false else { return CallMediaScan(sessions: [], issues: [.cancelled]) }
        switch readNowPlaying(localCallActive: localCallActive) {
        case .success(let session):
            if let session, !result.sessions.contains(where: { $0.bundleID == session.bundleID }) {
                result.sessions.append(session)
            }
        case .failure(let issue): result.issues.insert(issue)
        }
        return result
    }

    nonisolated private static func apply(_ action: CallMediaAction, expected: CallMediaSession,
                                         permit: CallMediaPermit, localCallActive: Bool)
        -> Result<CallMediaSession, CallMediaIssue> {
        guard permit.isValid else { return .failure(.cancelled) }
        guard identity(expected.bundleID) == expected.id else { return .failure(.sessionGone) }
        let current: CallMediaSession
        if CallMediaMacScripts.isScripted(expected.bundleID) {
            switch readScripted(expected.bundleID, identity: expected.id) {
            case .success(let session): current = session
            case .failure(let issue): return .failure(issue)
            }
        } else {
            switch readNowPlaying(localCallActive: localCallActive) {
            case .success(let session):
                guard let session, session.id == expected.id else { return .failure(.sessionGone) }
                current = session
            case .failure(let issue): return .failure(issue)
            }
        }
        guard !current.protectedCallAudio else { return .failure(.callAudioProtected) }
        switch action {
        case .pause:
            guard current.playing, current.contentID == expected.contentID else { return .failure(.changedByUser) }
        case .resume:
            guard expected.canResume, current.isStillPaused(from: expected) else { return .failure(.changedByUser) }
        case .setVolume, .muteProcess, .releaseProcessMute: return .failure(.selectiveMuteUnavailable)
        }
        guard permit.isValid, identity(expected.bundleID) == expected.id else { return .failure(.cancelled) }
        let script: String?
        let javaScript: Bool
        if CallMediaMacScripts.isScripted(expected.bundleID) {
            script = CallMediaMacScripts.command(action, bundleID: expected.bundleID)
            javaScript = false
        } else {
            switch action {
            case .pause:
                script = NowPlaying.commandScript(command: 1, position: nil, expected: expected.bundleID)
            case .resume:
                script = CallMediaMacScripts.nowPlayingResume(bundleID: expected.bundleID)
            case .setVolume, .muteProcess, .releaseProcessMute: return .failure(.selectiveMuteUnavailable)
            }
            javaScript = true
        }
        guard let script else { return .failure(.unsupported) }
        switch CallMediaMacScripts.run(script, javaScript: javaScript) {
        case .failure(let issue): return .failure(issue)
        case .success(let output):
            guard output == "ok" else { return .failure(.commandFailed) }
        }
        // The command returning does not prove playback stopped; return actual state for the
        // controller's bounded confirmation. An app switch/process restart never becomes success.
        guard identity(expected.bundleID) == expected.id else { return .failure(.sessionGone) }
        if CallMediaMacScripts.isScripted(expected.bundleID) {
            return readScripted(expected.bundleID, identity: expected.id)
        }
        switch readNowPlaying(localCallActive: localCallActive) {
        case .success(let current):
            guard let current, current.id == expected.id else { return .failure(.sessionGone) }
            return .success(current)
        case .failure(let issue): return .failure(issue)
        }
    }

    nonisolated private static func readScripted(_ bundleID: String, identity: String)
        -> Result<CallMediaSession, CallMediaIssue> {
        guard let source = CallMediaMacScripts.read(bundleID: bundleID) else { return .failure(.unsupported) }
        switch CallMediaMacScripts.run(source) {
        case .failure(let issue): return .failure(issue)
        case .success(let output):
            guard let session = CallMediaMacScripts.parse(output, bundleID: bundleID, identity: identity,
                                                         routeID: outputRoute()) else { return .failure(.commandFailed) }
            return .success(session)
        }
    }

    nonisolated private static func readNowPlaying(localCallActive: Bool)
        -> Result<CallMediaSession?, CallMediaIssue> {
        switch CallMediaMacScripts.run(NowPlaying.readScript(artwork: false), javaScript: true) {
        case .failure(let issue): return .failure(issue)
        case .success(let output):
            switch NowPlaying.parse(output) {
            case .unavailable: return .failure(.unsupported)
            case .nothing: return .success(nil)
            case .item(let item):
                guard let process = identity(item.bundleID) else { return .failure(.sessionGone) }
                // A browser can carry both YouTube and a call. The existing global Now Playing
                // surface cannot establish the audio's role, so it must not mute/pause that process.
                let protected = localCallActive || !CallMediaMacScripts.mediaOnlyApps.contains(item.bundleID)
                let content = CallMediaMacScripts.contentID([item.title, item.artist, String(item.duration)])
                return .success(CallMediaSession(id: process, bundleID: item.bundleID, contentID: content,
                                                playing: item.playing, position: item.position, routeID: outputRoute(),
                                                // This compatibility surface has only playing/not-playing;
                                                // it cannot prove a later Stop is still our owned pause.
                                                canResume: false, protectedCallAudio: protected))
            }
        }
    }

    nonisolated private static func identity(_ bundleID: String) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated, let launched = app.launchDate else { return nil }
        return "\(bundleID):\(app.processIdentifier):\(launched.timeIntervalSince1970)"
    }

    nonisolated private static func outputRoute() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? String(device) : "unavailable"
    }
}

enum CallMediaMacScripts {
    /// Narrow media-only compatibility adapters; unknown/call/browser apps remain protected.
    static let mediaOnlyApps: Set<String> = [
        MediaPlayer.musicBundleID, MediaPlayer.spotifyBundleID, "com.apple.podcasts", "com.apple.TV",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina", "com.tidal.desktop",
        "com.deezer.deezer-desktop", "com.amazon.music", "com.github.th-ch.youtube-music",
    ]

    static func isScripted(_ bundleID: String) -> Bool {
        bundleID == MediaPlayer.musicBundleID || bundleID == MediaPlayer.spotifyBundleID
    }

    static func read(bundleID: String) -> String? {
        guard isScripted(bundleID) else { return nil }
        let itemID = bundleID == MediaPlayer.musicBundleID ? "persistent ID of current track" : "id of current track"
        return wrap("""
        set sep to ASCII character 31
        set itemID to ""
        set p to 0
        try
            set itemID to (\(itemID)) as text
            set p to player position as integer
        end try
        return (player state as text) & sep & p & sep & sound volume & sep & itemID
        """, bundleID: bundleID)
    }

    static func command(_ action: CallMediaAction, bundleID: String) -> String? {
        guard isScripted(bundleID) else { return nil }
        let command: String
        switch action {
        case .pause: command = "pause"
        case .resume: command = "play"
        case .setVolume, .muteProcess, .releaseProcessMute: return nil
        }
        return wrap(command + "\nreturn \"ok\"", bundleID: bundleID)
    }

    private static func wrap(_ body: String, bundleID: String) -> String {
        """
        try
            if application id "\(bundleID)" is not running then return "__bridgey_error__:-600"
            with timeout of 3 seconds
                tell application id "\(bundleID)"
                    \(body)
                end tell
            end timeout
        on error number code
            return "__bridgey_error__:" & code
        end try
        """
    }

    static func parse(_ output: String, bundleID: String, identity: String, routeID: String) -> CallMediaSession? {
        guard isScripted(bundleID), output.utf8.count <= 8192 else { return nil }
        let parts = output.components(separatedBy: "\u{1f}")
        guard parts.count == 4, ["playing", "paused", "stopped"].contains(parts[0]),
              let position = Int(parts[1]), (0...604800).contains(position),
              let volume = Int(parts[2]), (0...100).contains(volume), parts[3].utf8.count <= 512 else { return nil }
        return CallMediaSession(id: identity, bundleID: bundleID, contentID: contentID([parts[3]]),
                                playing: parts[0] == "playing", position: position, volume: volume,
                                routeID: routeID, canResume: !parts[3].isEmpty && parts[0] != "stopped",
                                canMute: false, stopped: parts[0] == "stopped")
    }

    static func contentID(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The existing compatibility surface has no explicit Play command helper. Command zero is
    /// Play, not a toggle. Bundle identity is checked inside the same fixed script as dispatch.
    static func nowPlayingResume(bundleID: String) -> String? {
        guard MediaPlayer.validBundleID(bundleID), mediaOnlyApps.contains(bundleID) else { return nil }
        return """
        ObjC.import('Foundation');
        function run() {
          try {
            if (!$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load) return 'unavailable';
            const R = $.NSClassFromString('MRNowPlayingRequest');
            if (R.isNil()) return 'unavailable';
            const path = R.localNowPlayingPlayerPath;
            const client = path.isNil() ? path : path.client;
            const id = client.isNil() ? '' : (ObjC.unwrap(client.parentApplicationBundleIdentifier) || ObjC.unwrap(client.bundleIdentifier) || '');
            if (id !== '\(bundleID)' || ObjC.unwrap(R.localIsPlaying) === true) return 'other';
            ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['unsigned int', 'id']]);
            return $.MRMediaRemoteSendCommand(0, $.NSDictionary.dictionary) === true ? 'ok' : 'failed';
          } catch (e) { return 'unavailable'; }
        }
        """
    }

    static func run(_ source: String, javaScript: Bool = false) -> Result<String, CallMediaIssue> {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = (javaScript ? ["-l", "JavaScript"] : []) + ["-e", source]
        process.standardOutput = pipe
        process.standardError = pipe
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do { try process.run() } catch { return .failure(.commandFailed) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: deadline)
        var data = Data()
        while let part = try? pipe.fileHandleForReading.read(upToCount: 8192), !part.isEmpty {
            guard data.count + part.count <= 8192 else {
                process.terminate(); pipe.fileHandleForReading.closeFile()
                process.waitUntilExit(); deadline.cancel()
                return .failure(.commandFailed)
            }
            data.append(part)
        }
        process.waitUntilExit()
        deadline.cancel()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if output.hasPrefix("__bridgey_error__:") {
            let code = Int(output.dropFirst("__bridgey_error__:".count))
            return .failure(code == -1743 ? .permissionNeeded : code == -600 ? .sessionGone : .commandFailed)
        }
        guard process.terminationStatus == 0 else {
            return .failure(output.contains("(-1743)") ? .permissionNeeded : .commandFailed)
        }
        return .success(output)
    }
}
