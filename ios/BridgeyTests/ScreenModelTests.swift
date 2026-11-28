@testable import Bridgey
import XCTest

/// The screen model against a fake client: which area it asks, what each event shows, control and input, and Stop.
@MainActor
final class ScreenModelTests: XCTestCase {
    static let mac = "0b9e3f5c-1d2a-4b6c-8e7f-9a0b1c2d3e4f"
    static let phone = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f"
    private var client: FakeClient!
    private var model: AppModel!
    private var screen: ScreenModel { model.screen }

    override func setUp() async throws {
        let suite = "bridgey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let on = ["clipboard": true, "files": true]
        client = FakeClient(devices: [
            .init(deviceId: Self.mac, name: "MacBook Pro", platform: "macos", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on,
                  remote: on.merging(["screen_control_draft1": true]) { $1 }),
            .init(deviceId: Self.phone, name: "Pixel 9", platform: "android", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on,
                  remote: on.merging(["screen_draft1": true, "phone_control_draft1": true]) { $1 }),
        ])
        var options = LaunchOptions()
        options.discovery = false
        options.ephemeral = true
        let fake = client!
        model = AppModel(settings: AppSettings(defaults: defaults), options: options, system: FakeSystem(), activityFile: nil) { _, _ in fake }
        model.start()
    }

    override func tearDown() async throws {
        screen.close()
    }

    private func device(_ id: String) -> DeviceItem { model.devices.first { $0.id == id }! }

    private func event(_ area: PhoneArea, _ name: String, id: UInt64 = 0, device: String, _ json: [String: Any]) -> CoreEvent {
        let text = String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)
        return CoreEvent(kind: area.eventKind, id: id, deviceID: device, name: name, text: text)
    }

    private var last: (area: PhoneArea, op: String?, command: [String: Any])? {
        client.phoneCommands.last.map { ($0.area, $0.command["op"] as? String, $0.command) }
    }

    private func started(_ area: PhoneArea, device: String, screenshots: Bool = false, capable: Bool = true) -> CoreEvent {
        event(area, "started", id: 7, device: device, [
            "stream": 7, "width": 96, "height": 160, "fps": 10, "bitrate": 300_000, "screenshots": screenshots,
            "control": ["stream": 7, "capable": capable, "allowed": capable, "phase": "off",
                        "input": ["pointer": area == .display, "touch": area == .screen, "keys": true, "text": true, "navigation": area == .screen]],
        ])
    }

    func testAPhoneIsAskedOnItsAreaAndExplainsWhatItNeeds() {
        screen.open(device(Self.phone))
        XCTAssertEqual(screen.viewing, Self.phone)
        XCTAssertEqual(last?.area, .screen)
        XCTAssertEqual(last?.op, "request")
        XCTAssertEqual(screen.phase, .waiting(needs: nil))
        model.handle(event(.screen, "status", device: Self.phone, ["status": "waiting", "needs": "unlock"]))
        XCTAssertEqual(screen.phase, .waiting(needs: "unlock"))
        XCTAssertEqual(screen.waitingText("unlock"), "Unlock Pixel 9 to share its screen.")
        // Another device's events are not this screen's.
        model.handle(event(.screen, "status", device: Self.mac, ["status": "declined"]))
        XCTAssertEqual(screen.phase, .waiting(needs: "unlock"))
        model.handle(event(.screen, "status", device: Self.phone, ["status": "declined"]))
        XCTAssertEqual(screen.phase, .ended("Pixel 9 didn’t allow it."))
    }

    func testAMacIsAskedOnTheDisplayArea() {
        screen.open(device(Self.mac))
        XCTAssertEqual(last?.area, .display)
        XCTAssertEqual(last?.op, "request")
        model.handle(event(.display, "status", device: Self.mac, ["status": "permission"]))
        XCTAssertEqual(screen.phase, .ended("MacBook Pro needs Screen Recording for Bridgey."))
    }

    func testRefusalsBecomeWords() {
        client.phoneAnswers["request"] = ["ok": false, "error": "feature_off"]
        screen.open(device(Self.phone))
        guard case let .ended(text) = screen.phase else { return XCTFail("ended") }
        XCTAssertTrue(text.hasPrefix("Pixel 9 doesn’t share its screen"))
        client.phoneAnswers["request"] = ["ok": false, "error": "too_soon"]
        screen.request()
        XCTAssertEqual(screen.phase, .ended("Wait a few seconds, then try again."))
    }

    func testAStreamShowsSlowerModeAndControlTurnsTouchesIntoCommands() {
        screen.open(device(Self.phone))
        model.handle(started(.screen, device: Self.phone, screenshots: true))
        XCTAssertEqual(screen.phase, .showing)
        XCTAssertEqual(screen.stream, .init(handle: 7, width: 96, height: 160, screenshots: true, displayName: nil))
        XCTAssertTrue(screen.control.available)
        XCTAssertFalse(screen.control.active)
        // Input before control is on goes nowhere.
        screen.send(ScreenCommands.touch(contact: 0, phase: "down", at: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(last?.op, "request")
        screen.setControl(true)
        XCTAssertEqual(last?.op, "control_begin")
        model.handle(event(.screen, "control", id: 7, device: Self.phone, ["stream": 7, "capable": true, "allowed": true, "phase": "active",
                                                                             "input": ["touch": true, "navigation": true, "keys": true, "text": true]]))
        XCTAssertTrue(screen.control.active)
        XCTAssertTrue(screen.control.touch && screen.control.navigation)
        screen.send(ScreenCommands.touch(contact: 0, phase: "down", at: CGPoint(x: 0.5, y: 0.25)))
        XCTAssertEqual(last?.op, "touch")
        XCTAssertEqual(last?.command["y"] as? Double, 0.25)
        screen.send(ScreenCommands.navigate("home"))
        XCTAssertEqual(last?.command["action"] as? String, "home")
        // The phone ends control with a reason: a word, and touches stop.
        model.handle(event(.screen, "control", id: 7, device: Self.phone, ["stream": 7, "capable": true, "allowed": true, "phase": "off", "note": "locked"]))
        XCTAssertFalse(screen.control.active)
        XCTAssertEqual(screen.notice, "Pixel 9 is locked.")
    }

    func testStopTellsTheDeviceAndAMacHearsWhy() {
        screen.open(device(Self.mac))
        model.handle(started(.display, device: Self.mac))
        screen.close(reason: "left_screen")
        XCTAssertEqual(last?.area, .display)
        XCTAssertEqual(last?.op, "stop")
        XCTAssertEqual(last?.command["reason"] as? String, "left_screen")
        XCTAssertNil(screen.viewing)
        XCTAssertNil(screen.stream)

        screen.open(device(Self.phone))
        model.handle(started(.screen, device: Self.phone))
        screen.close()
        XCTAssertEqual(last?.area, .screen)
        XCTAssertEqual(last?.op, "stop")
        XCTAssertNil(last?.command["reason"], "a phone's stop takes no reason")
    }

    func testAStreamEndedThereSaysWhy() {
        screen.open(device(Self.phone))
        model.handle(started(.screen, device: Self.phone))
        model.handle(event(.screen, "stopped", id: 7, device: Self.phone, ["stream": 7, "reason": "screen_off", "by": "phone"]))
        XCTAssertEqual(screen.phase, .ended("The screen of Pixel 9 turned off."))
        XCTAssertNil(screen.stream)
        screen.request()
        model.handle(started(.screen, device: Self.phone))
        model.handle(event(.screen, "stopped", id: 7, device: Self.phone, ["stream": 7, "reason": "closed", "by": "here"]))
        XCTAssertEqual(screen.phase, .ended("Stopped."))
    }

    func testTheSessionStoppingClosesTheScreen() {
        screen.open(device(Self.mac))
        model.handle(started(.display, device: Self.mac))
        model.stop()
        XCTAssertNil(screen.viewing)
        XCTAssertNil(screen.stream)
        XCTAssertEqual(screen.phase, .idle)
    }
}
