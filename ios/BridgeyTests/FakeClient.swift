@testable import Bridgey
import Foundation

/// Records what the model asks of the session client and answers from a script.
final class FakeClient: CoreClient {
    let deviceID = "11111111-2222-4333-8444-555555555555"
    var snapshotValue: CoreSnapshot
    var calls: [String] = []
    var nextID: UInt64 = 10
    var failNext: CoreError?

    init(devices: [CoreSnapshot.Device] = []) {
        snapshotValue = CoreSnapshot(deviceId: deviceID, name: "Test iPhone", platform: "ios", port: 42_458, allowPairingSeconds: 0,
                                     defaults: [:], devices: devices, nearby: [])
    }

    private func record(_ call: String) throws -> UInt64 {
        calls.append(call)
        if let failNext {
            self.failNext = nil
            throw failNext
        }
        nextID += 1
        return nextID
    }

    func snapshot() throws -> CoreSnapshot { snapshotValue }
    func setDeviceName(_ name: String) throws { _ = try record("name \(name)") }
    func allowPairing(seconds: UInt32) throws { _ = try record("allow \(seconds)") }
    func pair(deviceID: String?, host: String?, port: UInt16) throws -> UInt64 { try record("pair \(deviceID ?? "-") \(host ?? "-") \(port)") }
    func confirmPairing(_ pairing: UInt64, accept: Bool) throws { _ = try record("confirm \(pairing) \(accept)") }
    func cancelPairing(_ pairing: UInt64) throws { _ = try record("cancel \(pairing)") }
    func forget(_ deviceID: String) throws { _ = try record("forget \(deviceID)") }
    func sendClipboard(_ deviceID: String, text: String) throws -> UInt64 { try record("text \(deviceID) \(text)") }
    func ping(_ deviceID: String) throws -> UInt64 { try record("ping \(deviceID)") }
    func setFeature(deviceID: String?, key: String, on: Bool) throws { _ = try record("feature \(deviceID ?? "*") \(key) \(on)") }
    func addDiscovered(deviceID: String?, name: String, platform: String?, host: String, port: UInt16) throws { _ = try record("found \(host)") }
    func removeDiscovered(host: String, port: UInt16) throws { _ = try record("lost \(host)") }
    func networkChanged() throws { _ = try record("network") }
    func sendFile(_ deviceID: String, url: URL, name: String?, mime: String?) throws -> UInt64 { try record("file \(deviceID) \(name ?? url.lastPathComponent)") }
    func cancelFile(_ transfer: UInt64) throws { _ = try record("cancelFile \(transfer)") }
    func sendLink(_ deviceID: String, url: String) throws -> UInt64 { try record("link \(deviceID) \(url)") }
    func connect(_ deviceID: String) throws { _ = try record("connect \(deviceID)") }
    func setReceiveDirectory(_ url: URL?) throws { _ = try record("receive \(url == nil ? "off" : "on")") }
    func stop() { calls.append("stop") }

    /// Commands sent with `phone`, and the answer for each op (default `{"ok": true}`).
    var phoneCommands: [(area: PhoneArea, deviceID: String, command: [String: Any])] = []
    var phoneAnswers: [String: [String: Any]] = [:]
    /// Frames `screenFrame` hands out, in order, then `.timeout`.
    var frames: [Data] = []

    func phone(_ area: PhoneArea, deviceID: String, command: [String: Any]) -> [String: Any] {
        phoneCommands.append((area, deviceID, command))
        let op = command["op"] as? String ?? ""
        calls.append("phone \(area.rawValue) \(op)")
        return phoneAnswers[op] ?? ["ok": true]
    }

    func screenFrame(_ stream: UInt64, timeoutMs: UInt32, buffer: UnsafeMutableRawBufferPointer) -> ScreenFramePull {
        guard !frames.isEmpty else { return .timeout }
        let frame = frames.removeFirst()
        guard frame.count <= buffer.count else { return .tooLarge(needed: frame.count) }
        frame.copyBytes(to: buffer)
        return .frame(length: frame.count, captureMicros: 0, key: true, parameterSets: true)
    }

    func setBattery(level: Int?, charging: Bool) throws { _ = try record("battery \(level.map(String.init) ?? "none") \(charging)") }
    func find(_ deviceID: String, ring: Bool) throws { _ = try record("find \(deviceID) \(ring)") }
    func findStopped(_ deviceID: String) throws { _ = try record("findStopped \(deviceID)") }
    func dismissNotification(_ deviceID: String, notificationID: String) throws { _ = try record("dismiss \(notificationID)") }
    func notificationAction(_ deviceID: String, notificationID: String, token: String, reply: String?) throws {
        _ = try record("action \(notificationID) \(token) \(reply ?? "-")")
    }
    func setCodes(sms: Bool, email: Bool) throws { _ = try record("codes \(sms) \(email)") }
    func codesLinkRequest(_ deviceID: String) throws { _ = try record("codesLink \(deviceID)") }
    func codesAdvertiseResult(_ deviceID: String, serviceUUID: String, ok: Bool, reason: String?) throws {
        _ = try record("advertise \(ok) \(reason ?? "-")")
    }
    func setPresence(state: Int32, idleSeconds: UInt32) throws { _ = try record("presence \(state)") }
    func setConnect(_ on: Bool, controlURL: String?) throws { _ = try record("connect \(on) \(controlURL ?? "-")") }
    func setLinksOpen(_ on: Bool) throws { _ = try record("linksOpen \(on)") }
}

final class FakeSystem: SystemServices {
    var copied: [String] = []
    var opened: [URL] = []
    func copy(_ text: String) { copied.append(text) }
    func open(_ url: URL) { opened.append(url) }
}
