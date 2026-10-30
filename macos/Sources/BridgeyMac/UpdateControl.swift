import Darwin
import Foundation

/*
 * `BridgeyMac --update-all`: start "check now, then Update all" from the command line, for the person
 * who publishes a release (docs/releasing.md). The running app serves the request on a Unix socket in
 * its own Application Support folder: the folder is 0700, the socket 0600, and every connection's
 * user is checked again with getpeereid, so only the user running Bridgey can use it. It is not a URL
 * scheme (a web page could open one) and not a distributed notification (any process can post one).
 * The request names no URL, version or file; each device still updates from its own channel with its
 * own signature checks, so the safety model is Update all's (SECURITY.md).
 *
 * Wire: one request line, then answer lines, newline-delimited JSON:
 *   request  {"version":1,"command":"update-all","launched":false}
 *   answers  {"event":"info","app":..,"build":..,"channel":..}
 *            {"event":"progress","step":"checking"}
 *            {"event":"plan","refresh":bool,"devices":[{"name","platform","local","from","to","channel","action","reason"}]}
 *            {"event":"result","result":"started|up_to_date|blocked|refused","reason":..,"busy":..,"device":..}
 */

struct UpdateControlRequest: Equatable {
    enum Command: String { case updateAll = "update-all" }

    var command: Command
    /// The command line started Bridgey for this request: wait a little for phones to connect.
    var launched = false

    static let maxBytes = 4096

    var line: Data {
        let object: [String: Any] = ["version": 1, "command": command.rawValue, "launched": launched]
        return ((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()) + Data([0x0A])
    }

    static func decode(_ data: Data) -> UpdateControlRequest? {
        guard data.count <= maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              jsonInteger(object["version"]) == 1,
              let command = (object["command"] as? String).flatMap(Command.init(rawValue:)) else { return nil }
        var request = UpdateControlRequest(command: command)
        if let value = object["launched"], !(value is NSNull) {
            guard let launched = jsonBool(value) else { return nil }
            request.launched = launched
        }
        return request
    }
}

enum UpdateControlResult: String {
    case started
    case upToDate = "up_to_date"
    case blocked
    case refused
}

/// The answer side of one connection: lines go out in order on their own queue; `finish` closes it.
final class UpdateControlReply: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.update-control.reply")
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let payload = data
        queue.async { [self] in
            guard !closed else { return }
            payload.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    func info(version: String, build: Int, channel: String) {
        send(["event": "info", "app": version, "build": build, "channel": channel])
    }

    func progress(_ step: String) { send(["event": "progress", "step": step]) }

    func plan(_ plan: UpdatePlan, refreshing: Bool) {
        send(["event": "plan", "refresh": refreshing, "devices": plan.entries.map(Self.device)])
    }

    static func device(_ entry: UpdatePlanEntry) -> [String: Any] {
        var device: [String: Any] = ["name": entry.name, "platform": entry.isLocal ? "macos" : "android", "local": entry.isLocal]
        if let app = entry.app { device["from"] = app }
        if let channel = entry.channel { device["channel"] = channel.rawValue }
        switch entry.kind {
        case let .update(to, _):
            device["action"] = to == nil ? "check" : "update"
            if let to { device["to"] = to }
        case .upToDate:
            device["action"] = "up_to_date"
        case let .skipped(reason):
            device["action"] = "skip"
            device["reason"] = reason.wireKey
        }
        return device
    }

    func blocked(_ blocked: AutoUpdatePolicy.Blocked) {
        switch blocked {
        case .runActive: finish(.blocked, reason: "run_active", text: nil)
        case .updatingForPeer: finish(.blocked, reason: "updating_for_peer", text: nil)
        case let .busy(kind, device):
            var object: [String: Any] = ["event": "result", "result": UpdateControlResult.blocked.rawValue, "reason": "busy", "busy": kind.rawValue]
            if let device { object["device"] = device }
            send(object)
            close()
        }
    }

    func finish(_ result: UpdateControlResult, reason: String?, text: String?) {
        var object: [String: Any] = ["event": "result", "result": result.rawValue]
        if let reason { object["reason"] = reason }
        if let text { object["text"] = text }
        send(object)
        close()
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}

enum UpdateControlError: Error, Equatable {
    case pathTooLong
    case alreadyServed
    case system(String, Int32)
}

/// Unix sockets for the hand-over, shared by the app (server) and the command line (client).
enum UpdateControlSocket {
    static let fileName = "update-control.sock"

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/\(fileName)")
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw UpdateControlError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A connected socket, or the errno of the failure (ENOENT or ECONNREFUSED: nothing serves it;
    /// EACCES: another user's folder or socket).
    static func connect(_ path: String) -> Result<Int32, UpdateControlError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.system("socket", errno)) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            Darwin.close(fd)
            return .failure(.system("setsockopt", code))
        }
        do {
            var socketAddress = try Self.address(path)
            let result = withUnsafePointer(to: &socketAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else {
                let code = errno
                Darwin.close(fd)
                return .failure(.system("connect", code))
            }
            return .success(fd)
        } catch let error as UpdateControlError {
            Darwin.close(fd)
            return .failure(error)
        } catch {
            Darwin.close(fd)
            return .failure(.system("connect", EINVAL))
        }
    }

    /// The user at the other end of a connected Unix socket.
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Reads one line (without its newline) of at most `limit` bytes; nil on a timeout, an error or too much.
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= limit {
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else { return nil }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return nil
    }
}

/// The app's side: listens on the socket and hands each request (from this user only) to `handler`.
final class UpdateControlServer: @unchecked Sendable {
    typealias Handler = (UpdateControlRequest, UpdateControlReply) -> Void

    let path: String
    private let ownUID: uid_t
    private let peerUID: (Int32) -> uid_t?
    private let handler: Handler
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.update-control")
    private var source: DispatchSourceRead?

    static func defaultSocketURL() -> URL { UpdateControlSocket.defaultURL() }

    init(path: String, ownUID: uid_t = getuid(), peerUID: @escaping (Int32) -> uid_t? = UpdateControlSocket.peerUID, handler: @escaping Handler) {
        self.path = path
        self.ownUID = ownUID
        self.peerUID = peerUID
        self.handler = handler
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Owner only, even if the folder was made earlier with wider permissions.
        chmod(directory, 0o700)
        if FileManager.default.fileExists(atPath: path) {
            if case let .success(fd) = UpdateControlSocket.connect(path) {
                Darwin.close(fd)
                throw UpdateControlError.alreadyServed
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UpdateControlError.system("socket", errno) }
        var address = try UpdateControlSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UpdateControlError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw UpdateControlError.system("listen", code)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(fd) }
        let socketPath = path
        source.setCancelHandler {
            Darwin.close(fd)
            unlink(socketPath)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func acceptOne(_ listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        // A client that already hung up (a second app probing the socket, a killed command line) cannot
        // take SO_NOSIGPIPE (EINVAL), and writing to it would then raise SIGPIPE and end the app: drop it.
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(client)
            return
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let reply = UpdateControlReply(fd: client)
        guard let uid = peerUID(client), uid == ownUID else {
            BridgeyLog.updates.notice("UPDATE_CONTROL refused another_user")
            return reply.finish(.refused, reason: "another_user", text: nil)
        }
        guard let line = UpdateControlSocket.readLine(client, limit: UpdateControlRequest.maxBytes),
              let request = UpdateControlRequest.decode(line) else {
            return reply.finish(.refused, reason: "bad_request", text: nil)
        }
        BridgeyLog.updates.notice("UPDATE_CONTROL request=\(request.command.rawValue, privacy: .public) launched=\(request.launched, privacy: .public)")
        handler(request, reply)
    }
}

// MARK: - The command line

/// `BridgeyMac --update-all [--json]`: hands the request to the running app (starting it if needed),
/// prints the plan and the result, and exits: 0 started, 3 up to date, 2 blocked, 1 anything else.
enum UpdateControlCLI {
    static let usage = "Usage: BridgeyMac --update-all [--json]"

    struct Environment {
        var socketPath = UpdateControlSocket.defaultURL().path
        /// Opens Bridgey without bringing it to the front; false when it cannot.
        var launch: () -> Bool = UpdateControlCLI.launchApp
        var output: (String) -> Void = { print($0); fflush(stdout) }
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        /// How long to wait for a started app to answer.
        var launchWait: TimeInterval = 30
    }

    static func run(arguments: [String], environment: Environment = Environment()) -> Int32 {
        let json = arguments.contains("--json")
        let out = environment.output
        let fd: Int32
        var launched = false
        switch UpdateControlSocket.connect(environment.socketPath) {
        case let .success(connected):
            fd = connected
        case let .failure(error):
            if case let .system(_, code) = error, code == EACCES || code == EPERM {
                out("Error: permission denied. Only the user running Bridgey by Round Robin can start its updates.")
                return 1
            }
            if !json { out("Bridgey by Round Robin is not running. Starting it...") }
            guard environment.launch() else {
                out("Error: Bridgey by Round Robin is not running and could not be started.")
                return 1
            }
            launched = true
            var connected: Int32?
            let deadline = Date().addingTimeInterval(environment.launchWait)
            while Date() < deadline {
                if case let .success(value) = UpdateControlSocket.connect(environment.socketPath) {
                    connected = value
                    break
                }
                environment.sleep(0.5)
            }
            guard let connected else {
                out("Error: Bridgey by Round Robin did not answer. If it is running, quit it and open it again.")
                return 1
            }
            fd = connected
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 150, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = UpdateControlRequest(command: .updateAll, launched: launched).line
        let sent = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        // A refusal (another user) may close the connection before the request is read: its answer
        // is still waiting to be read, so read before giving up.
        var result: String?
        while let line = UpdateControlSocket.readLine(fd, limit: 64 * 1024) {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if json {
                out(String(decoding: line, as: UTF8.self))
            } else {
                for text in UpdateControlText.lines(object) { out(text) }
            }
            if object["event"] as? String == "result" { result = object["result"] as? String }
        }
        switch result.flatMap(UpdateControlResult.init(rawValue:)) {
        case .started: return 0
        case .upToDate: return 3
        case .blocked: return 2
        case .refused: return 1
        case nil:
            out(sent == request.count
                ? "Error: Bridgey by Round Robin closed the connection without a result."
                : "Error: could not send the request to Bridgey by Round Robin.")
            return 1
        }
    }

    /// `open -g` on this app's bundle (LaunchServices starts it in the person's session, in the background).
    static func launchApp() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", bundle.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// The command line's words. English only: scripts read them, and the JSON form (`--json`) is the stable interface.
enum UpdateControlText {
    static func lines(_ object: [String: Any]) -> [String] {
        switch object["event"] as? String {
        case "info":
            let app = object["app"] as? String ?? "?"
            let build = jsonInteger(object["build"]).map { " (\($0))" } ?? ""
            let channel = (object["channel"] as? String).flatMap(UpdateChannel.init(rawValue:))?.title ?? "?"
            return ["Bridgey by Round Robin \(app)\(build) on this Mac, \(channel) channel"]
        case "progress":
            return object["step"] as? String == "checking" ? ["Checking for updates..."] : []
        case "plan":
            let devices = object["devices"] as? [[String: Any]] ?? []
            return ["Plan:"] + devices.map { "  " + device($0) }
        case "result":
            return [result(object)]
        default:
            return []
        }
    }

    static func device(_ device: [String: Any]) -> String {
        let local = device["local"] as? Bool == true
        let name = local ? "This Mac" : (device["name"] as? String ?? "?")
        let platform = device["platform"] as? String == "macos" ? "Mac" : "Android"
        let channel = (device["channel"] as? String).flatMap(UpdateChannel.init(rawValue:))?.title
        let label = channel.map { "\(name) (\(platform), \($0))" } ?? "\(name) (\(platform))"
        let from = device["from"] as? String ?? "?"
        switch device["action"] as? String {
        case "update":
            let to = device["to"] as? String ?? "?"
            return "update   \(label): \(from) > \(to)" + (local ? ", restarts last after a 60 s countdown" : "")
        case "check":
            return "check    \(label): \(from), updates if its channel has a newer build"
        case "up_to_date":
            return "current  \(label): \(from), up to date"
        default:
            let reason = (device["reason"] as? String).flatMap(UpdateSkipReason.init(wireKey:)).map(skipReason) ?? "skipped"
            return "skip     \(label): \(reason)"
        }
    }

    static func skipReason(_ reason: UpdateSkipReason) -> String {
        switch reason {
        case .offline: "not connected"
        case .byHand: "update it by hand"
        case .noStatus: "has not sent its version yet"
        case .notApplied: "its last update did not apply"
        case .remoteOff: "updates from other devices are off there"
        }
    }

    static func busy(_ busy: UpdateBusy) -> String {
        switch busy {
        case .call: "a call is in progress"
        case .screenShare: "a screen is being shared"
        case .remoteControl: "remote control is in use"
        case .transfer: "files are transferring"
        case .phoneFiles: "a Phone files download is running"
        case .setup: "setup or pairing is open"
        case .other: "someone is busy"
        }
    }

    static func result(_ object: [String: Any]) -> String {
        switch object["result"] as? String {
        case "started":
            return "Result: started"
        case "up_to_date":
            return "Result: up to date (this Mac and its connected phones report nothing newer)"
        case "blocked":
            switch object["reason"] as? String {
            case "run_active": return "Result: blocked because an Update all run is already going on this Mac"
            case "updating_for_peer": return "Result: blocked because this Mac is updating at another device's request"
            case "busy":
                let what = (object["busy"] as? String).map { UpdateBusy(rawValue: $0) ?? .other }.map(busy) ?? "someone is busy"
                let place = (object["device"] as? String).map { " on \($0)" } ?? " on this Mac"
                return "Result: blocked because \(what)\(place)"
            default: return "Result: blocked because Bridgey is not ready yet"
            }
        default:
            switch object["reason"] as? String {
            case "another_user": return "Result: refused, the request came from another user"
            default: return "Result: refused, the request was not understood"
            }
        }
    }
}
