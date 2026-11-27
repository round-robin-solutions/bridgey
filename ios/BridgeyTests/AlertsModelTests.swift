@testable import Bridgey
import XCTest

/// Notifications, codes, the call card, ringing both ways, battery and presence, against a fake session client.
@MainActor
final class AlertsModelTests: XCTestCase {
    static let phone = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f"
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var client: FakeClient!
    private var model: AppModel!
    private var alerts: AlertsModel { model.alerts }
    private var copied: [String] = []
    private var announced: [String] = []
    private var ringer: FakeRinger!
    private var advertiser: FakeAdvertiser!

    final class FakeRinger: Ringer {
        var ringing = false
        func start() { ringing = true }
        func stop() { ringing = false }
    }

    final class FakeAdvertiser: CompanionAdvertiser {
        var answer: (Bool, String?) = (false, "unsupported")
        var started: [String] = []
        var stopped: [String] = []
        func start(service: String, seconds: TimeInterval, done: @escaping @MainActor (Bool, String?) -> Void) {
            started.append(service)
            MainActor.assumeIsolated { done(answer.0, answer.1) }
        }
        func stop(service: String) { stopped.append(service) }
    }

    override func setUp() async throws {
        let suite = "bridgey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
        let on = ["clipboard": true, "files": true, "notifications": true, "battery": true, "find_device": true]
        client = FakeClient(devices: [.init(deviceId: Self.phone, name: "Pixel 9", platform: "android", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on, remote: on)])
        var options = LaunchOptions()
        options.discovery = false
        options.ephemeral = true
        let fake = client!
        model = AppModel(settings: settings, options: options, system: FakeSystem(), activityFile: nil) { _, _ in fake }
        ringer = FakeRinger()
        advertiser = FakeAdvertiser()
        alerts.ringer = ringer
        alerts.advertiser = advertiser
        alerts.copy = { [unowned self] in copied.append($0) }
        alerts.announce = { [unowned self] in announced.append($0) }
        alerts.batteryReading = { (64, true) }
        model.start()
    }

    private func post(_ json: [String: Any], quiet: Bool = false) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        model.handle(CoreEvent(kind: .notification, status: quiet ? 1 : 0, deviceID: Self.phone, text: String(data: data, encoding: .utf8)))
    }

    private let message: [String: Any] = [
        "packageName": "com.whatsapp", "applicationName": "WhatsApp", "notificationId": "wa-1", "title": "Ravi", "text": "On my way",
        "timestamp": 1_794_000_000_000, "actions": [["token": "r1", "title": "Reply", "allowsReply": true], ["token": "m1", "title": "Mark as read", "allowsReply": false]],
    ]

    func testANotificationBecomesACardWithItsButtonsAndIsAnnounced() throws {
        post(message)
        let alert = try XCTUnwrap(alerts.notifications.first)
        XCTAssertEqual(alert.title, "Ravi")
        XCTAssertEqual(alert.source, "WhatsApp")
        XCTAssertEqual(alert.deviceName, "Pixel 9")
        XCTAssertEqual(alert.buttons.map(\.title), ["Mark as read"])
        XCTAssertEqual(alert.replyAction?.token, "r1")
        XCTAssertTrue(alert.canReply)
        XCTAssertEqual(announced, ["WhatsApp: Ravi"])

        alerts.run(alert.buttons[0], on: alert)
        XCTAssertEqual(client.calls.last, "action wa-1 m1 -")

        alerts.replies[alert.id] = "  Thanks  "
        alerts.reply(to: alert)
        XCTAssertEqual(client.calls.last, "action wa-1 r1 Thanks")
        XCTAssertNil(alerts.replies[alert.id], "the field clears once sent")
        XCTAssertEqual(model.notice, "Reply sent")
    }

    func testAQuietNotificationIsListedButNeverAnnounced() {
        post(message, quiet: true)
        XCTAssertEqual(alerts.notifications.count, 1)
        XCTAssertTrue(alerts.notifications[0].quiet)
        XCTAssertTrue(announced.isEmpty)
    }

    func testTheSameNotificationAgainReplacesItAndTheListIsBounded() {
        post(message)
        var changed = message
        changed["text"] = "Here now"
        post(changed)
        XCTAssertEqual(alerts.notifications.map(\.text), ["Here now"])
        for n in 0..<(AlertsModel.limit + 5) {
            var m = message
            m["notificationId"] = "n\(n)"
            post(m, quiet: true)
        }
        XCTAssertEqual(alerts.notifications.count, AlertsModel.limit)
        XCTAssertEqual(alerts.notifications.first?.notificationID, "n\(AlertsModel.limit + 4)", "newest first")
    }

    func testDismissAndThePhoneRemovingOne() {
        post(message)
        var other = message
        other["notificationId"] = "wa-2"
        post(other)
        alerts.dismiss(alerts.notifications.first { $0.notificationID == "wa-1" }!)
        XCTAssertEqual(client.calls.last, "dismiss wa-1")
        model.handle(CoreEvent(kind: .notificationRemoved, deviceID: Self.phone, text: "wa-2"))
        XCTAssertTrue(alerts.notifications.isEmpty)
    }

    func testAnSMSWithoutItsOwnReplyAnswersThroughThePhone() throws {
        post(["packageName": "com.google.android.apps.messaging", "applicationName": "Messages", "notificationId": "sms-1", "title": "Mum",
              "text": "Call me", "timestamp": 1, "smsReply": true, "smsThreadId": 12])
        let alert = try XCTUnwrap(alerts.notifications.first)
        XCTAssertTrue(alert.canReply)
        XCTAssertEqual(alert.smsThreadID, 12)
        alerts.replies[alert.id] = "On it"
        alerts.reply(to: alert)
        let sent = try XCTUnwrap(client.phoneCommands.last)
        XCTAssertEqual(sent.area, .sms)
        XCTAssertEqual(sent.command["op"] as? String, "send")
        XCTAssertEqual(sent.command["notificationId"] as? String, "sms-1")
        XCTAssertEqual(sent.command["body"] as? String, "On it")
    }

    func testACodeCopiesAndIsAnnouncedWithItsSender() throws {
        post(["packageName": "com.google.android.apps.messaging", "applicationName": "Messages", "notificationId": "sms-2", "title": "VM-HDFCBK",
              "text": "OTP is 482913", "timestamp": 1, "code": ["code": "482913", "service": "VM-HDFCBK", "channel": "sms"]])
        let alert = try XCTUnwrap(alerts.notifications.first)
        XCTAssertEqual(alert.code, FoundCode(code: "482913", service: "VM-HDFCBK"))
        XCTAssertEqual(announced.last, "Code 482913 from VM-HDFCBK")
        alerts.copyCode(alert)
        XCTAssertEqual(copied, ["482913"])
        XCTAssertEqual(model.notice, "Code copied")
    }

    func testFailuresSayWhy() {
        post(message)
        client.failNext = CoreError(code: CoreError.notConnected)
        alerts.run(alerts.notifications[0].buttons[0], on: alerts.notifications[0])
        XCTAssertEqual(model.notice, "Pixel 9 isn’t connected.")
    }

    func testTheCallCardUsesThePhonesButtonsAndGoesWhenTheCallEnds() throws {
        let decline = AlertAction(token: String(repeating: "d", count: 64), title: "Decline", allowsReply: false)
        post(["packageName": "com.google.android.dialer", "applicationName": "Phone", "notificationId": "call-1", "title": "Anna Kapoor",
              "text": "Incoming call", "timestamp": 1, "callType": "incoming",
              "actions": [["token": String(repeating: "c", count: 64), "title": "Answer", "allowsReply": false], ["token": decline.token, "title": "Decline", "allowsReply": false]]])
        XCTAssertTrue(alerts.notifications.isEmpty, "a call has its own card")
        let card = try XCTUnwrap(alerts.call)
        XCTAssertEqual(card.caller, "Anna Kapoor")
        XCTAssertTrue(card.incoming)
        XCTAssertEqual(card.buttons.map(\.title), ["Answer", "Decline"])
        XCTAssertEqual(card.buttons.map(\.role), [.answer, .end])
        XCTAssertEqual(announced.last, "Incoming call on Pixel 9: Anna Kapoor")
        alerts.run(card.buttons[1], on: card.alert)
        XCTAssertEqual(client.calls.last, "action call-1 \(decline.token) -")

        // Answered on the phone: the same notification, now ongoing with Hang up; the timer starts.
        post(["packageName": "com.google.android.dialer", "applicationName": "Phone", "notificationId": "call-1", "title": "Anna Kapoor",
              "text": "Ongoing call", "timestamp": 1, "callType": "ongoing", "actions": [["token": "h", "title": "Hang up", "allowsReply": false]]])
        XCTAssertEqual(alerts.calls.count, 1)
        XCTAssertEqual(alerts.call?.alert.callType, "ongoing")
        XCTAssertNotNil(alerts.call?.since)
        XCTAssertEqual(alerts.call?.buttons.map(\.role), [.end])

        model.handle(CoreEvent(kind: .notificationRemoved, status: 1, deviceID: Self.phone, text: "call-1"))
        XCTAssertNil(alerts.call)
    }

    func testACallTakenAwayWithoutEndingStaysAMoment() async throws {
        post(["notificationId": "call-2", "title": "Unknown", "timestamp": 1, "callType": "incoming"])
        model.handle(CoreEvent(kind: .notificationRemoved, status: 0, deviceID: Self.phone, text: "call-2"))
        XCTAssertNotNil(alerts.call, "kept in case the dialer posts it again")
        try await Task.sleep(for: .seconds(AlertsModel.removalGrace + 0.5))
        XCTAssertNil(alerts.call)
    }

    func testACallsEndButtonIsKeptWhenItComesLater() {
        let card = CallCard(alert: {
            var a = PhoneAlert(deviceID: Self.phone, notificationID: "c", deviceName: "Pixel 9")
            a.actions = [AlertAction(token: "1", title: "Answer", allowsReply: false), AlertAction(token: "2", title: "Speaker", allowsReply: false),
                         AlertAction(token: "3", title: "Hang up", allowsReply: false)]
            return a
        }())
        XCTAssertEqual(card.buttons.map(\.title), ["Answer", "Hang up"])
    }

    func testRingingThePhoneAndStoppingIt() throws {
        let phone = try XCTUnwrap(model.devices.first)
        alerts.ring(phone)
        XCTAssertEqual(client.calls.last, "find \(Self.phone) true")
        XCTAssertEqual(alerts.rings.first?.direction, .outgoing)
        XCTAssertEqual(alerts.rings.first?.confirmed, false)
        model.handle(CoreEvent(kind: .findState, status: 1, deviceID: Self.phone))
        XCTAssertEqual(alerts.rings.first?.confirmed, true)
        alerts.stop(alerts.rings[0])
        XCTAssertEqual(client.calls.last, "find \(Self.phone) false")
        XCTAssertTrue(alerts.rings.isEmpty)
        // The phone stopping it there takes the card away too.
        alerts.ring(phone)
        model.handle(CoreEvent(kind: .findState, status: 0, deviceID: Self.phone))
        XCTAssertTrue(alerts.rings.isEmpty)
    }

    func testThePhoneRingingThisDevicePlaysUntilStopped() throws {
        model.handle(CoreEvent(kind: .findRequested, status: 1, deviceID: Self.phone))
        XCTAssertTrue(ringer.ringing)
        XCTAssertEqual(alerts.rings.first?.direction, .incoming)
        alerts.stop(try XCTUnwrap(alerts.rings.first))
        XCTAssertFalse(ringer.ringing)
        XCTAssertEqual(client.calls.last, "findStopped \(Self.phone)")
        // Stopped from the phone.
        model.handle(CoreEvent(kind: .findRequested, status: 1, deviceID: Self.phone))
        model.handle(CoreEvent(kind: .findRequested, status: 0, deviceID: Self.phone))
        XCTAssertFalse(ringer.ringing)
        XCTAssertTrue(alerts.rings.isEmpty)
    }

    func testFindDeviceOffSaysWhere() throws {
        client.failNext = CoreError(code: CoreError.featureOff)
        alerts.ring(try XCTUnwrap(model.devices.first))
        XCTAssertTrue(model.notice?.hasPrefix("Find device is off on Pixel 9") == true)
        XCTAssertTrue(alerts.rings.isEmpty)
    }

    func testBatteryAndPresenceAreReportedAndBatteryOffSendsNone() {
        XCTAssertTrue(client.calls.contains("battery 64 true"))
        XCTAssertTrue(client.calls.contains("presence 0"))
        settings.battery = false
        alerts.reportBattery(on: false)
        XCTAssertEqual(client.calls.last, "battery none false")
    }

    func testCodesLinkAndAdvertising() {
        model.handle(CoreEvent(kind: .codesStatus, deviceID: Self.phone, text: "hidden"))
        XCTAssertTrue(alerts.needsLink(Self.phone))
        alerts.link(Self.phone)
        XCTAssertEqual(client.calls.last, "codesLink \(Self.phone)")
        let uuid = "7e57d00d-0000-4000-8000-0000000000cc"
        model.handle(CoreEvent(kind: .codesAdvertise, status: 1, deviceID: Self.phone, text: uuid))
        XCTAssertEqual(advertiser.started, [uuid])
        XCTAssertEqual(client.calls.last, "advertise false unsupported")
        advertiser.answer = (true, nil)
        model.handle(CoreEvent(kind: .codesAdvertise, status: 1, deviceID: Self.phone, text: uuid))
        XCTAssertEqual(client.calls.last, "advertise true -")
        model.handle(CoreEvent(kind: .codesAdvertise, status: 0, deviceID: Self.phone, text: uuid))
        XCTAssertEqual(advertiser.stopped, [uuid])
        model.handle(CoreEvent(kind: .codesStatus, deviceID: Self.phone, text: "allowed"))
        XCTAssertFalse(alerts.needsLink(Self.phone))
    }

    func testConnectStateIsShown() {
        model.handle(CoreEvent(kind: .connectState, text: "online", extra: #"["\#(Self.phone)"]"#))
        XCTAssertEqual(alerts.connectState, "online")
        XCTAssertEqual(alerts.connectOnline, [Self.phone])
        XCTAssertTrue(alerts.connectText.hasPrefix("On."))
        model.handle(CoreEvent(kind: .connectState, text: "unreachable"))
        XCTAssertTrue(alerts.connectText.contains("Can’t reach"))
    }

    func testADisconnectOrStoppingClearsWhatCanNoLongerBeActedOn() {
        post(message)
        post(["notificationId": "call-3", "title": "Anna", "timestamp": 1, "callType": "incoming"])
        model.handle(CoreEvent(kind: .findRequested, status: 1, deviceID: Self.phone))
        model.handle(CoreEvent(kind: .disconnected, deviceID: Self.phone))
        XCTAssertTrue(alerts.notifications.isEmpty)
        XCTAssertNil(alerts.call)
        XCTAssertTrue(alerts.rings.isEmpty)
        XCTAssertFalse(ringer.ringing)
        post(message)
        model.stop()
        XCTAssertTrue(alerts.notifications.isEmpty)
        XCTAssertEqual(alerts.connectState, "off")
    }

    func testTheRingtoneIsAValidWave() {
        let tone = ToneRinger.tone
        XCTAssertEqual(String(decoding: tone.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertGreaterThan(tone.count, 40_000)
    }
}
