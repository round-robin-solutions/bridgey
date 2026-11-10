import Darwin
import Foundation

/// Private, per-user temporary directory. Never Application Support, a synced folder or TCP.
enum LocalAgentCodesSocket {
    static var path: String {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bridgey-local-codes-\(getuid())/codes.sock").path
    }
    static let request = Data("{\"version\":1,\"command\":\"read\"}\n".utf8)

    static func isPrivate(_ path: String, kind: mode_t, mode: mode_t, uid: uid_t = getuid()) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_uid == uid && info.st_mode & S_IFMT == kind && info.st_mode & 0o777 == mode
    }

    static func connect(_ path: String) -> Result<Int32, UpdateControlError> {
        guard isPrivate((path as NSString).deletingLastPathComponent, kind: S_IFDIR, mode: 0o700),
              isPrivate(path, kind: S_IFSOCK, mode: 0o600) else { return .failure(.system("permissions", EACCES)) }
        let result = UpdateControlSocket.connect(path)
        if case let .success(fd) = result {
            guard UpdateControlSocket.peerUID(fd) == getuid() else {
                close(fd)
                return .failure(.system("peer", EACCES))
            }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return result
    }

    /// One absolute deadline for the whole request, so trickling bytes cannot stall shutdown.
    static func readLine(_ fd: Int32, limit: Int, seconds: TimeInterval) -> Data? {
        let deadline = LocalAgentCodeStore.continuousSeconds() + seconds
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= limit {
            let left = deadline - LocalAgentCodeStore.continuousSeconds()
            guard left > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(max(1, (left * 1000).rounded(.up)))) > 0,
                  Darwin.read(fd, &byte, 1) == 1 else { return nil }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return nil
    }

    @discardableResult
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

/// One read-only request type. Same-user authentication is checked for every connection.
final class LocalAgentCodesServer: @unchecked Sendable {
    typealias Audit = (uid_t?, String, Int) -> Void
    private let path: String
    private let store: LocalAgentCodeStore
    private let peerUID: (Int32) -> uid_t?
    private let audit: Audit
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.local-codes.socket")
    private var source: DispatchSourceRead?
    private var stopped: DispatchSemaphore?

    init(path: String = LocalAgentCodesSocket.path, store: LocalAgentCodeStore,
         peerUID: @escaping (Int32) -> uid_t? = UpdateControlSocket.peerUID,
         audit: @escaping Audit = { uid, outcome, count in
             BridgeyLog.notifications.notice("LOCAL_CODES read uid=\(uid.map(String.init) ?? "unknown", privacy: .public) result=\(outcome, privacy: .public) count=\(count, privacy: .public)")
         }) {
        self.path = path; self.store = store; self.peerUID = peerUID; self.audit = audit
    }

    func start() throws {
        guard source == nil else { return }
        let directory = (path as NSString).deletingLastPathComponent
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST,
              LocalAgentCodesSocket.isPrivate(directory, kind: S_IFDIR, mode: 0o700) else {
            throw UpdateControlError.system("directory", EACCES)
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard LocalAgentCodesSocket.isPrivate(path, kind: S_IFSOCK, mode: 0o600) else {
                throw UpdateControlError.system("permissions", EACCES)
            }
            if case let .success(fd) = LocalAgentCodesSocket.connect(path) {
                close(fd); throw UpdateControlError.alreadyServed
            }
            guard unlink(path) == 0 else { throw UpdateControlError.system("unlink", errno) }
        }
        var address = try UpdateControlSocket.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UpdateControlError.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let code = errno; close(fd); throw UpdateControlError.system("bind", code) }
        guard chmod(path, 0o600) == 0, listen(fd, 4) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno; close(fd); unlink(path); throw UpdateControlError.system("listen", code)
        }
        let done = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(fd) }
        let path = self.path
        source.setCancelHandler { close(fd); unlink(path); done.signal() }
        self.source = source
        self.stopped = done
        source.resume()
    }

    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        stopped?.wait() // Reads and writes have a one-second deadline; no queued code responses.
        stopped = nil
    }

    private func acceptOne(_ listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var on: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let uid = peerUID(client)
        guard uid == getuid() else { audit(uid, "denied", 0); return }
        guard let line = LocalAgentCodesSocket.readLine(client, limit: 256, seconds: 1),
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              Set(object.keys) == ["version", "command"], jsonInteger(object["version"]) == 1,
              object["command"] as? String == "read" else { audit(uid, "bad_request", 0); return }
        let codes = store.read()
        // Every read, including an empty result, is logged before any code is returned. No code,
        // notification text, sender string or response body can reach the audit callback.
        audit(uid, "read", codes.count)
        guard var data = try? JSONEncoder().encode(codes) else { return }
        data.append(0x0A)
        LocalAgentCodesSocket.write(data, to: client)
    }
}

enum LocalAgentCodesCLI {
    static func run(arguments: [String], path: String = LocalAgentCodesSocket.path,
                    output: (String) -> Void = { print($0) }) -> Int32 {
        guard arguments.dropFirst().allSatisfy({ $0 == "--local-codes" }), arguments.count == 2 else {
            output("Usage: BridgeyMac --local-codes")
            return 2
        }
        guard case let .success(fd) = LocalAgentCodesSocket.connect(path) else {
            output("Local codes unavailable. Open Bridgey and check Settings > Notifications > Local agent codes.")
            return 1
        }
        defer { close(fd) }
        guard LocalAgentCodesSocket.write(LocalAgentCodesSocket.request, to: fd),
              let data = LocalAgentCodesSocket.readLine(fd, limit: 128 * 4096, seconds: 2),
              (try? JSONDecoder().decode([LocalAgentCode].self, from: data)) != nil else {
            output("Could not read local codes. Check Bridgey and try again.")
            return 1
        }
        output(String(decoding: data, as: UTF8.self))
        return 0
    }
}
