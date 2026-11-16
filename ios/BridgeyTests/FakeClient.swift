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
}

final class FakeSystem: SystemServices {
    var copied: [String] = []
    var opened: [URL] = []
    func copy(_ text: String) { copied.append(text) }
    func open(_ url: URL) { opened.append(url) }
}
