import Darwin
import Foundation

/*
 * The Connect anywhere core (rust/core, libbridgey_connect.dylib), loaded at run time with dlopen so
 * the app and its tests build without Rust. build-app.sh puts the library in Contents/Frameworks;
 * BRIDGEY_CONNECT_DYLIB points somewhere else (tests, local builds). Five C functions, JSON in and out:
 * start, command, next event (a blocking poll with a timeout), stop and free.
 */

final class ConnectLibrary: @unchecked Sendable {
    private typealias StartFunction = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias CommandFunction = @convention(c) (UInt64, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias NextEventFunction = @convention(c) (UInt64, UInt32) -> UnsafeMutablePointer<CChar>?
    private typealias StopFunction = @convention(c) (UInt64) -> Void
    private typealias FreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private let startFunction: StartFunction
    private let commandFunction: CommandFunction
    private let nextEventFunction: NextEventFunction
    private let stopFunction: StopFunction
    private let freeFunction: FreeFunction

    /// Where the library is looked for: the environment override, then the app's Frameworks folder.
    static var candidatePaths: [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["BRIDGEY_CONNECT_DYLIB"], !override.isEmpty { paths.append(override) }
        if let frameworks = Bundle.main.privateFrameworksPath { paths.append((frameworks as NSString).appendingPathComponent("libbridgey_connect.dylib")) }
        return paths
    }

    private static let lock = NSLock()
    private static var loaded: ConnectLibrary??

    /// The library, or nil when this build has none (Connect anywhere then says "not available").
    static func shared() -> ConnectLibrary? {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        let library = candidatePaths.lazy.compactMap { ConnectLibrary(path: $0) }.first
        loaded = .some(library)
        return library
    }

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path), let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let start = symbol("bridgey_connect_start", as: StartFunction.self),
              let command = symbol("bridgey_connect_command", as: CommandFunction.self),
              let next = symbol("bridgey_connect_next_event", as: NextEventFunction.self),
              let stop = symbol("bridgey_connect_stop", as: StopFunction.self),
              let free = symbol("bridgey_connect_free", as: FreeFunction.self) else {
            dlclose(handle)
            return nil
        }
        startFunction = start
        commandFunction = command
        nextEventFunction = next
        stopFunction = stop
        freeFunction = free
    }

    private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { freeFunction(pointer) }
        return String(cString: pointer)
    }

    /// `{"ok":true,"handle":N,"udpPort":P}` or `{"ok":false,"error":...}`.
    func start(_ config: [String: Any]) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: config), let text = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "config"]
        }
        return Self.object(take(text.withCString { startFunction($0) }))
    }

    func command(_ handle: UInt64, _ command: [String: Any]) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: command), let text = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "command"]
        }
        return Self.object(take(text.withCString { commandFunction(handle, $0) }))
    }

    /// The next event, or nil after `timeoutMs` without one.
    func nextEvent(_ handle: UInt64, timeoutMs: UInt32) -> [String: Any]? {
        guard let text = take(nextEventFunction(handle, timeoutMs)) else { return nil }
        return Self.object(text)
    }

    func stop(_ handle: UInt64) { stopFunction(handle) }

    private static func object(_ text: String?) -> [String: Any] {
        guard let data = text?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ["ok": false, "error": "reply"] }
        return object
    }
}
