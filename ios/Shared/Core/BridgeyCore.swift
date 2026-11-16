import BridgeyCoreFFI
import Foundation

/*
 * The Swift side of bridgey_core (rust/client, docs/session-client.md): one client, one thread that drains its
 * event queue, and the host storage callbacks that keep the identity and trusted devices in the Keychain.
 * The app and the Share extension both use it; view models talk to `CoreClient` so tests can use a fake.
 */

/// BridgeyEventKind in bridgey_core.h.
enum CoreEventKind: UInt32, Sendable {
    case deviceFound = 1
    case deviceLost = 2
    case pairingRequest = 3
    case pairingWaiting = 4
    case pairingCode = 5
    case pairingFinished = 6
    case connected = 7
    case disconnected = 8
    case features = 9
    case clipboard = 10
    case clipboardSent = 11
    case ping = 12
    case pingResult = 13
    case trustChanged = 14
    case eventsDropped = 15
    case error = 16
    case fileIncoming = 17
    case fileProgress = 18
    case fileDone = 19
    case fileFailed = 20
    case link = 21
    case linkSent = 22
}

/// BridgeySendStatus: how a clipboard send, ping or link ended.
enum SendStatus: Int32, Sendable {
    case delivered = 0
    case rejected = 1
    case timedOut = 2
    case failed = 3
}

/// One event. Which fields are set depends on the kind (bridgey_core.h documents each).
struct CoreEvent: Sendable, Equatable {
    var kind: CoreEventKind
    var status: Int32 = 0
    var id: UInt64 = 0
    var deviceID: String?
    var name: String?
    var text: String?
    var extra: String?
    var bytes: UInt64 = 0
    var total: UInt64 = 0
}

/// A call bridgey_core refused, with its BRIDGEY_ERR_* code.
struct CoreError: Error, Equatable, LocalizedError {
    static let invalidArgument: Int32 = -1
    static let notConnected: Int32 = -2
    static let featureOff: Int32 = -3
    static let tooLarge: Int32 = -4
    static let unknownDevice: Int32 = -5
    static let stopped: Int32 = -6
    static let storage: Int32 = -7
    static let io: Int32 = -8

    let code: Int32

    var errorDescription: String? {
        switch code {
        case Self.invalidArgument: String(localized: "That isn’t valid.")
        case Self.notConnected: String(localized: "That device isn’t connected.")
        case Self.featureOff: String(localized: "That’s turned off on one of the devices.")
        case Self.tooLarge: String(localized: "That’s too large to send.")
        case Self.unknownDevice: String(localized: "Bridgey can’t find that device.")
        case Self.stopped: String(localized: "Bridgey has stopped.")
        case Self.storage: String(localized: "Bridgey couldn’t read or save its pairing data.")
        case Self.io: String(localized: "Bridgey couldn’t use the network.")
        default: String(localized: "Something went wrong (\(code)).")
        }
    }
}

/// Where the identity and trusted devices are kept. Called from bridgey_core's threads.
protocol SecretStore: AnyObject, Sendable {
    func load(_ key: String) throws -> Data?
    func store(_ key: String, _ value: Data) throws
    func remove(_ key: String) throws
}

/// Keeps nothing past the process: tests and screenshots.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func load(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func store(_ key: String, _ value: Data) throws { lock.withLock { values[key] = value } }
    func remove(_ key: String) throws { lock.withLock { values[key] = nil } }
}

struct CoreOptions {
    var deviceName: String
    var platform = "ios"
    /// 0 is Bridgey's port, 42458.
    var port: UInt16 = 0
    var listen = true
    /// The library's own DNS-SD. iOS builds leave it out and pass devices in from Bonjour (Discovery.swift).
    var builtInDiscovery = false
    /// Where received files go; nil refuses files.
    var receiveDirectory: URL?
    /// Connect only to devices named with `connect` (the Share extension).
    var manualConnect = false
}

/// bridgey_snapshot's JSON (rust/client/src/client.rs, `snapshot`).
struct CoreSnapshot: Decodable, Equatable {
    struct Device: Decodable, Equatable {
        var deviceId: String
        var name: String
        var platform: String?
        var connected: Bool
        var pairedAtMs: Int64?
        var lastConnectedMs: Int64?
        var local: [String: Bool]
        var remote: [String: Bool]?
    }

    struct Nearby: Decodable, Equatable {
        var deviceId: String?
        var name: String
        var platform: String?
        var host: String?
        var port: Int?
        var trusted: Bool
    }

    var deviceId: String
    var name: String
    var platform: String
    var port: Int
    var allowPairingSeconds: Int
    var defaults: [String: Bool]
    var devices: [Device]
    var nearby: [Nearby]
}

/// What the app needs from the session client; view models are tested against a fake.
protocol CoreClient: AnyObject {
    var deviceID: String { get }
    func snapshot() throws -> CoreSnapshot
    func setDeviceName(_ name: String) throws
    func allowPairing(seconds: UInt32) throws
    func pair(deviceID: String?, host: String?, port: UInt16) throws -> UInt64
    func confirmPairing(_ pairing: UInt64, accept: Bool) throws
    func cancelPairing(_ pairing: UInt64) throws
    func forget(_ deviceID: String) throws
    func sendClipboard(_ deviceID: String, text: String) throws -> UInt64
    func ping(_ deviceID: String) throws -> UInt64
    func setFeature(deviceID: String?, key: String, on: Bool) throws
    func addDiscovered(deviceID: String?, name: String, platform: String?, host: String, port: UInt16) throws
    func removeDiscovered(host: String, port: UInt16) throws
    func networkChanged() throws
    func sendFile(_ deviceID: String, url: URL, name: String?, mime: String?) throws -> UInt64
    func cancelFile(_ transfer: UInt64) throws
    func sendLink(_ deviceID: String, url: String) throws -> UInt64
    func connect(_ deviceID: String) throws
    func setReceiveDirectory(_ url: URL?) throws
    func stop()
}

/// The library's own version and ABI, for About and a start-up check.
enum CoreLibrary {
    static var version: String { String(cString: bridgey_version()) }
    static var abiVersion: UInt32 { bridgey_abi_version() }
    /// The ABI this app was built against (BRIDGEY_ABI_VERSION in bridgey_core.h).
    static let expectedABI: UInt32 = 1
}

/// Holds the store for the C callbacks; the client keeps it alive.
private final class StoreBox {
    let store: SecretStore
    init(_ store: SecretStore) { self.store = store }
}

private func box(_ context: UnsafeMutableRawPointer?) -> StoreBox? {
    context.map { Unmanaged<StoreBox>.fromOpaque($0).takeUnretainedValue() }
}

// Storage callbacks run on bridgey_core's threads; errors become negative results, never exceptions.
private let loadValue: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, OpaquePointer?) -> Int32 = { context, key, buffer in
    guard let store = box(context)?.store, let key else { return -1 }
    do {
        guard let data = try store.load(String(cString: key)) else { return 0 }
        return data.withUnsafeBytes { raw in
            bridgey_buffer_set(buffer, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) == 0 ? 1 : -1
        }
    } catch {
        return -1
    }
}

private let storeValue: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int) -> Int32 = { context, key, data, length in
    guard let store = box(context)?.store, let key else { return -1 }
    let value = data.map { Data(bytes: $0, count: length) } ?? Data()
    do {
        try store.store(String(cString: key), value)
        return 0
    } catch {
        return -1
    }
}

private let removeValue: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32 = { context, key in
    guard let store = box(context)?.store, let key else { return -1 }
    do {
        try store.remove(String(cString: key))
        return 0
    } catch {
        return -1
    }
}

private extension BridgeyStr {
    var string: String? {
        guard let ptr else { return nil }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}

private func check(_ code: Int32) throws {
    if code < 0 { throw CoreError(code: code) }
}

/// The real client: one bridgey_core handle and the thread that drains its events.
final class BridgeyCore: CoreClient, @unchecked Sendable {
    private let handle: UInt64
    private let storeBox: Unmanaged<StoreBox>
    private let pump: Thread
    private let stopped = NSLock()
    private var isStopped = false
    let deviceID: String

    /// Starts a client. `onEvent` is called on the event thread, in order.
    static func start(_ options: CoreOptions, store: SecretStore, onEvent: @escaping @Sendable (CoreEvent) -> Void) throws -> BridgeyCore {
        guard CoreLibrary.abiVersion == CoreLibrary.expectedABI else { throw CoreError(code: CoreError.invalidArgument) }
        let storeBox = Unmanaged.passRetained(StoreBox(store))
        var handle: UInt64 = 0
        let rc = options.deviceName.withCString { name in
            options.platform.withCString { platform in
                withOptionalCString(options.receiveDirectory?.path) { receive in
                    var config = BridgeyConfig(
                        struct_size: UInt32(MemoryLayout<BridgeyConfig>.size),
                        port: options.port,
                        listen: options.listen ? 1 : 0,
                        discovery: options.builtInDiscovery ? 1 : 0,
                        event_capacity: 0,
                        device_name: name,
                        platform: platform,
                        data_dir: nil,
                        receive_dir: receive,
                        manual_connect: options.manualConnect ? 1 : 0
                    )
                    var storage = BridgeyStorage(context: storeBox.toOpaque(), load: loadValue, store: storeValue, remove: removeValue)
                    return bridgey_client_new(&config, &storage, &handle)
                }
            }
        }
        guard rc == 0 else {
            storeBox.release()
            throw CoreError(code: rc)
        }
        return BridgeyCore(handle: handle, storeBox: storeBox, onEvent: onEvent)
    }

    private init(handle: UInt64, storeBox: Unmanaged<StoreBox>, onEvent: @escaping @Sendable (CoreEvent) -> Void) {
        self.handle = handle
        self.storeBox = storeBox
        if let id = bridgey_device_id(handle) {
            deviceID = String(cString: id)
            bridgey_string_free(id)
        } else {
            deviceID = ""
        }
        pump = Thread {
            while true {
                var event: UnsafeMutablePointer<BridgeyEvent>?
                let rc = bridgey_next_event(handle, 500, &event)
                if rc < 0 { return }
                guard rc > 0, let event else { continue }
                let e = event.pointee
                let converted = CoreEventKind(rawValue: e.kind).map {
                    CoreEvent(kind: $0, status: e.status, id: e.id, deviceID: e.device_id.string, name: e.name.string,
                              text: e.text.string, extra: e.extra.string, bytes: e.bytes, total: e.total)
                }
                bridgey_event_free(event)
                // Kinds from a newer library are skipped.
                if let converted { onEvent(converted) }
            }
        }
        pump.name = "Bridgey events"
        pump.qualityOfService = .userInitiated
        pump.start()
    }

    deinit {
        stop()
        bridgey_client_free(handle)
        storeBox.release()
    }

    func stop() {
        let first = stopped.withLock {
            defer { isStopped = true }
            return !isStopped
        }
        if first { bridgey_client_stop(handle) }
    }

    func snapshot() throws -> CoreSnapshot {
        guard let json = bridgey_snapshot(handle) else { throw CoreError(code: CoreError.stopped) }
        defer { bridgey_string_free(json) }
        return try JSONDecoder().decode(CoreSnapshot.self, from: Data(bytes: json, count: strlen(json)))
    }

    func setDeviceName(_ name: String) throws { try check(bridgey_set_device_name(handle, name)) }

    func allowPairing(seconds: UInt32) throws { try check(bridgey_allow_pairing(handle, min(seconds, 600))) }

    func pair(deviceID: String?, host: String?, port: UInt16) throws -> UInt64 {
        var pairing: UInt64 = 0
        try withOptionalCString(deviceID) { id in
            try withOptionalCString(host) { host in try check(bridgey_pair(handle, id, host, port, &pairing)) }
        }
        return pairing
    }

    func confirmPairing(_ pairing: UInt64, accept: Bool) throws { try check(bridgey_pair_confirm(handle, pairing, accept ? 1 : 0)) }

    func cancelPairing(_ pairing: UInt64) throws { try check(bridgey_pair_cancel(handle, pairing)) }

    func forget(_ deviceID: String) throws { try check(bridgey_forget(handle, deviceID)) }

    func sendClipboard(_ deviceID: String, text: String) throws -> UInt64 {
        var request: UInt64 = 0
        // A trailing NUL keeps the pointer valid for empty text, which the library refuses itself.
        let bytes = Array(text.utf8) + [0]
        try check(bridgey_send_clipboard(handle, deviceID, bytes, bytes.count - 1, &request))
        return request
    }

    func ping(_ deviceID: String) throws -> UInt64 {
        var request: UInt64 = 0
        try check(bridgey_ping(handle, deviceID, &request))
        return request
    }

    func setFeature(deviceID: String?, key: String, on: Bool) throws {
        try withOptionalCString(deviceID) { id in try check(bridgey_set_feature(handle, id, key, on ? 1 : 0)) }
    }

    func addDiscovered(deviceID: String?, name: String, platform: String?, host: String, port: UInt16) throws {
        try withOptionalCString(deviceID) { id in
            try withOptionalCString(platform) { platform in try check(bridgey_add_discovered(handle, id, name, platform, host, port)) }
        }
    }

    func removeDiscovered(host: String, port: UInt16) throws { try check(bridgey_remove_discovered(handle, host, port)) }

    func networkChanged() throws { try check(bridgey_network_changed(handle)) }

    func sendFile(_ deviceID: String, url: URL, name: String?, mime: String?) throws -> UInt64 {
        var transfer: UInt64 = 0
        try withOptionalCString(name) { name in
            try withOptionalCString(mime) { mime in try check(bridgey_send_file(handle, deviceID, url.path, name, mime, &transfer)) }
        }
        return transfer
    }

    func cancelFile(_ transfer: UInt64) throws { try check(bridgey_cancel_file(handle, transfer)) }

    func sendLink(_ deviceID: String, url: String) throws -> UInt64 {
        var request: UInt64 = 0
        try check(bridgey_send_link(handle, deviceID, url, &request))
        return request
    }

    func connect(_ deviceID: String) throws { try check(bridgey_connect(handle, deviceID)) }

    func setReceiveDirectory(_ url: URL?) throws {
        try withOptionalCString(url?.path) { dir in try check(bridgey_set_receive_dir(handle, dir)) }
    }
}

/// Calls `body` with a C string for `text`, or NULL.
func withOptionalCString<R>(_ text: String?, _ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
    guard let text else { return try body(nil) }
    return try text.withCString { try body($0) }
}
