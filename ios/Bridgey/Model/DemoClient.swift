import Foundation

#if DEBUG
/// Sample devices and activity for screenshots (BRIDGEY_DEMO, debug builds only). No network, nothing saved.
final class DemoClient: CoreClient {
    static let factory: ClientFactory = { _, onEvent in DemoClient(onEvent: onEvent) }

    let deviceID = "7f3c2a9e-1b4d-4c6e-9a8f-2d1e0c3b4a59"
    let onEvent: @Sendable (CoreEvent) -> Void
    private var next: UInt64 = 100

    static let mac = "0b9e3f5c-1d2a-4b6c-8e7f-9a0b1c2d3e4f"
    static let pixel = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f"
    static let pc = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"

    init(onEvent: @escaping @Sendable (CoreEvent) -> Void) {
        self.onEvent = onEvent
    }

    func snapshot() throws -> CoreSnapshot {
        let on = ["clipboard": true, "files": true, "links": true, "ping": true, "battery": true, "find_device": true, "notifications": true]
        let mac = on.merging(["screen_control_draft1": true]) { $1 }
        let pixel = on.merging(["screen_draft1": true, "phone_control_draft1": true, "sms_draft1": true, "files_browse_draft1": true]) { $1 }
        return CoreSnapshot(
            deviceId: deviceID, name: "Rahul’s iPhone", platform: "ios", port: 42_458, allowPairingSeconds: 0, defaults: on,
            devices: [
                .init(deviceId: Self.mac, name: "MacBook Pro", platform: "macos", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on, remote: mac),
                .init(deviceId: Self.pixel, name: "Pixel 9", platform: "android", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on, remote: pixel),
                .init(deviceId: Self.pc, name: "Studio PC", platform: "windows", connected: false, pairedAtMs: nil, lastConnectedMs: nil, local: on, remote: nil),
            ],
            nearby: [
                .init(deviceId: "c0ffee00-1234-4abc-8def-0123456789ab", name: "Living room iPad", platform: "ios", host: "192.168.1.31", port: 42_458, trusted: false),
                .init(deviceId: "beefcafe-4321-4cba-8fed-ba9876543210", name: "Office Mac mini", platform: "macos", host: "192.168.1.40", port: 42_458, trusted: false),
            ]
        )
    }

    private func id() -> UInt64 {
        next += 1
        return next
    }

    func setDeviceName(_ name: String) throws {}
    func allowPairing(seconds: UInt32) throws {}
    func pair(deviceID: String?, host: String?, port: UInt16) throws -> UInt64 { id() }
    func confirmPairing(_ pairing: UInt64, accept: Bool) throws {}
    func cancelPairing(_ pairing: UInt64) throws {}
    func forget(_ deviceID: String) throws {}
    func sendClipboard(_ deviceID: String, text: String) throws -> UInt64 { id() }
    func ping(_ deviceID: String) throws -> UInt64 { id() }
    func setFeature(deviceID: String?, key: String, on: Bool) throws {}
    func addDiscovered(deviceID: String?, name: String, platform: String?, host: String, port: UInt16) throws {}
    func removeDiscovered(host: String, port: UInt16) throws {}
    func networkChanged() throws {}
    func sendFile(_ deviceID: String, url: URL, name: String?, mime: String?) throws -> UInt64 { id() }
    func cancelFile(_ transfer: UInt64) throws {}
    func sendLink(_ deviceID: String, url: String) throws -> UInt64 { id() }
    func connect(_ deviceID: String) throws {}
    func setReceiveDirectory(_ url: URL?) throws {}
    func stop() {}
    /// Each area's sample answers live with its feature (DemoClient+<Feature>.swift).
    func phone(_ area: PhoneArea, deviceID: String, command: [String: Any]) -> [String: Any] {
        switch area {
        case .screen, .display: demoScreen(area, deviceID: deviceID, command: command)
        case .sms: demoMessages(deviceID: deviceID, command: command)
        case .phoneFiles: demoPhoneFiles(deviceID: deviceID, command: command)
        case .calls: ["ok": false, "error": "unsupported"]
        }
    }

    func screenFrame(_ stream: UInt64, timeoutMs: UInt32, buffer: UnsafeMutableRawBufferPointer) -> ScreenFramePull {
        demoScreenFrame(stream, timeoutMs: timeoutMs, buffer: buffer)
    }
    func setBattery(level: Int?, charging: Bool) throws {}
    func find(_ deviceID: String, ring: Bool) throws {}
    func findStopped(_ deviceID: String) throws {}
    func dismissNotification(_ deviceID: String, notificationID: String) throws {}
    func notificationAction(_ deviceID: String, notificationID: String, token: String, reply: String?) throws {}
    func setCodes(sms: Bool, email: Bool) throws {}
    func codesLinkRequest(_ deviceID: String) throws {}
    func codesAdvertiseResult(_ deviceID: String, serviceUUID: String, ok: Bool, reason: String?) throws {}
    func setPresence(state: Int32, idleSeconds: UInt32) throws {}
    func setConnect(_ on: Bool, controlURL: String?) throws {}
    func setLinksOpen(_ on: Bool) throws {}

    /// Fills the model for one screenshot: `home`, `pair`, `empty`, `setup`, `settings`.
    @MainActor
    static func seed(_ model: AppModel, screen: String) {
        guard screen != "setup" else { return }
        model.start()
        if screen == "empty" {
            model.loadDemo(devices: [], activity: [])
            return
        }
        let minute: TimeInterval = 60
        let now = Date()
        model.loadDemo(
            activity: [
                ActivityItem(date: now.addingTimeInterval(-1 * minute), direction: .received, kind: .text, deviceName: "MacBook Pro",
                             value: "Meeting moved to 4:30 in the Hudle room. Bring the Q3 numbers."),
                ActivityItem(date: now.addingTimeInterval(-6 * minute), direction: .sent, kind: .file, deviceName: "MacBook Pro",
                             value: "IMG_4021.HEIC"),
                ActivityItem(date: now.addingTimeInterval(-14 * minute), direction: .sent, kind: .link, deviceName: "Pixel 9",
                             value: "https://roundrobin.in/bridgey"),
                ActivityItem(date: now.addingTimeInterval(-32 * minute), direction: .received, kind: .file, deviceName: "Pixel 9",
                             value: "Boarding pass.pdf", savedName: "Boarding pass.pdf"),
                ActivityItem(date: now.addingTimeInterval(-58 * minute), direction: .sent, kind: .text, deviceName: "Studio PC",
                             value: "ssh rb@studio.local", outcome: .failed, detail: "The connection ended first."),
            ],
            transfers: [TransferItem(id: 1, deviceID: mac, deviceName: "MacBook Pro", name: "Site walkthrough.mov", incoming: true, bytes: 41_000_000, total: 96_000_000)],
            links: [LinkCard(deviceName: "MacBook Pro", url: URL(string: "https://github.com/round-robin-solutions/bridgey/pull/29")!)]
        )
        if screen == "pair" {
            model.showDemoCode()
        }
        model.handle(CoreEvent(kind: .battery, status: 76, id: 0, deviceID: pixel))
        model.handle(CoreEvent(kind: .battery, status: 54, id: 1, deviceID: mac))
        seedScreen(model, screen: screen)
        seedMessages(model, screen: screen)
        seedPhoneFiles(model, screen: screen)
        seedAlerts(model, screen: screen)
    }
}

extension AppModel {
    /// Screenshot data.
    func loadDemo(devices: [DeviceItem]? = nil, activity: [ActivityItem] = [], transfers: [TransferItem] = [], links: [LinkCard] = []) {
        replaceForDemo(devices: devices, activity: activity, transfers: transfers, links: links)
    }
}
#endif
