@testable import Bridgey
import XCTest

/// Real sessions through the Swift wrapper and the C ABI: the app's own AppModel and AlertsModel on one side, and a
/// second bridgey_core client on the other that sends what an Android phone sends (bridgey_send_as_phone_for_tests).
@MainActor
final class AlertsSessionTests: XCTestCase {
    typealias Log = CoreBridgeTests.Log

    private var phone: BridgeyCore!
    private var phoneLog: Log!
    private var phonePort: UInt16 = 0
    private var model: AppModel!
    private var ringer: AlertsModelTests.FakeRinger!

    override func setUp() async throws {
        let log = Log()
        var options = CoreOptions(deviceName: "Test phone")
        options.port = CoreBridgeTests.freePort()
        options.platform = "linux"
        phone = try BridgeyCore.start(options, store: MemorySecretStore()) { [log] e in log.add(e) }
        phoneLog = log
        phonePort = options.port
        for key in ["clipboard", "notifications", "notification_routing_draft1", "device_presence_draft1", "sms_codes_draft1", "battery", "find_device"] {
            try phone.setFeature(deviceID: nil, key: key, on: true)
        }

        let suite = "bridgey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.codesFromMessages = true
        var launch = LaunchOptions()
        launch.ephemeral = true
        launch.discovery = false
        launch.port = CoreBridgeTests.freePort()
        model = AppModel(settings: settings, options: launch, system: FakeSystem(), activityFile: nil) { core, onEvent in
            try BridgeyCore.start(core, store: MemorySecretStore(), onEvent: onEvent)
        }
        ringer = AlertsModelTests.FakeRinger()
        model.alerts.ringer = ringer
        model.alerts.announce = { _ in }
        model.alerts.batteryReading = { (55, false) }
        model.start()
        try await pair(appPort: launch.port)
    }

    override func tearDown() async throws {
        model?.stop()
        phone?.stop()
    }

    /// Waits on the main actor for the model to reach a state.
    private func until(_ what: String, timeout: TimeInterval = 20, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            guard Date() < deadline else { throw NSError(domain: "AlertsSessionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(what): not reached"]) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The phone dials the app while its pairing screen is open; both people confirm the code.
    private func pair(appPort: UInt16) async throws {
        model.pairingScreen(open: true)
        let pairing = try phone.pair(deviceID: nil, host: "127.0.0.1", port: appPort)
        try await until("the code on the app") { if case .code = model.pairing { true } else { false } }
        model.confirmCode(true)
        let log = phoneLog!
        let code = try await Task.detached { try log.wait("the code on the phone") { $0.kind == .pairingCode && $0.id == pairing ? true : nil } }.value
        XCTAssertTrue(code)
        try phone.confirmPairing(pairing, accept: true)
        model.pairingScreen(open: false)
        try await until("the phone connected with its switches") {
            model.devices.first.map { $0.connected && $0.notificationsReady && $0.findReady } == true
        }
    }

    private var phoneID: String { phone.deviceID }
    private var appID: String { model.client!.deviceID }

    func testNotificationsWithACodeAReplyAndTheirRemovalOverARealSession() async throws {
        let post = #"{"packageName":"com.google.android.apps.messaging","applicationName":"Messages","notificationId":"0|sms|42","title":"VM-HDFCBK","text":"OTP is 482913 for txn of INR 2,499.00 at AMAZON PAY. Do not share OTP.","timestamp":1794000000000,"actions":[{"actionToken":"reply-1","title":"Reply","allowsReply":true},{"actionToken":"read-1","title":"Mark as read","allowsReply":false}],"smsDefaultApp":true,"redacted":false,"presentation":"alert"}"#
        try phone.sendAsPhoneForTests(appID, kind: "notifications.post", json: post)
        try await until("the card") { !model.alerts.notifications.isEmpty }
        let alert = try XCTUnwrap(model.alerts.notifications.first)
        XCTAssertEqual(alert.title, "VM-HDFCBK")
        XCTAssertEqual(alert.code?.code, "482913", "the shared rules reader found the code on this device")
        XCTAssertEqual(alert.buttons.map(\.title), ["Mark as read"])
        XCTAssertTrue(alert.canReply)

        model.alerts.replies[alert.id] = "Thanks"
        model.alerts.reply(to: alert)
        XCTAssertEqual(model.notice, "Reply sent", "the library took the action for the phone")
        model.alerts.run(alert.buttons[0], on: alert)

        // A quiet one, then the phone takes the first away.
        let quiet = #"{"packageName":"com.whatsapp","applicationName":"WhatsApp","notificationId":"w1","title":"Ravi","text":"On my way","timestamp":1,"presentation":"quiet"}"#
        try phone.sendAsPhoneForTests(appID, kind: "notifications.post", json: quiet)
        try await until("the quiet one") { model.alerts.notifications.contains { $0.notificationID == "w1" && $0.quiet } }
        try phone.sendAsPhoneForTests(appID, kind: "notifications.remove", json: #"{"notificationId":"0|sms|42","callEnded":false}"#)
        try await until("removed") { !model.alerts.notifications.contains { $0.notificationID == "0|sms|42" } }

        // A call: the card, then the phone says it ended.
        let call = #"{"packageName":"com.google.android.dialer","applicationName":"Phone","notificationId":"call-1","title":"Anna Kapoor","text":"Incoming call","timestamp":1,"callType":"incoming","actions":[{"actionToken":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","title":"Answer","allowsReply":false},{"actionToken":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","title":"Decline","allowsReply":false}]}"#
        try phone.sendAsPhoneForTests(appID, kind: "notifications.post", json: call)
        try await until("the call card") { model.alerts.call?.caller == "Anna Kapoor" }
        model.alerts.run(try XCTUnwrap(model.alerts.call?.buttons.first), on: try XCTUnwrap(model.alerts.call?.alert))
        try phone.sendAsPhoneForTests(appID, kind: "notifications.remove", json: #"{"notificationId":"call-1","callEnded":true}"#)
        try await until("the call ended") { model.alerts.call == nil }

        // The phone's codes status, and the link request back to it.
        try phone.sendAsPhoneForTests(appID, kind: "codes.status", json: #"{"version":1,"status":"hidden"}"#)
        try await until("codes hidden") { model.alerts.needsLink(phoneID) }
        model.alerts.link(phoneID)
        XCTAssertTrue(model.notice?.contains("Allow") == true)
    }

    func testBatteryBothWaysOverARealSession() async throws {
        let log = phoneLog!
        let level = try await Task.detached { try log.wait("this device's battery at the phone") { $0.kind == .battery ? $0.status : nil } }.value
        XCTAssertEqual(level, 55)
        try phone.setBattery(level: 80, charging: true)
        try await until("the phone's battery on its chip") { model.devices.first?.battery == BatteryLevel(level: 80, charging: true) }
    }

    func testFindDeviceBothWaysOverARealSession() async throws {
        let device = try XCTUnwrap(model.devices.first)
        model.alerts.ring(device)
        let log = phoneLog!
        let asked = try await Task.detached { try log.wait("the phone asked to ring") { $0.kind == .findRequested && $0.status == 1 ? true : nil } }.value
        XCTAssertTrue(asked)
        try await until("the phone says it rings") { model.alerts.rings.first?.confirmed == true }
        model.alerts.stop(try XCTUnwrap(model.alerts.rings.first))
        _ = try await Task.detached { try log.wait("the phone told to stop") { $0.kind == .findRequested && $0.status == 0 ? true : nil } }.value

        // And the phone rings this device until the person stops it here.
        try phone.find(appID, ring: true)
        try await until("ringing here") { self.ringer.ringing && model.alerts.rings.contains { $0.direction == .incoming } }
        model.alerts.stop(try XCTUnwrap(model.alerts.rings.first { $0.direction == .incoming }))
        XCTAssertFalse(ringer.ringing)
        _ = try await Task.detached { try log.wait("the phone hears it stopped") { $0.kind == .findState && $0.status == 0 ? true : nil } }.value
    }
}
