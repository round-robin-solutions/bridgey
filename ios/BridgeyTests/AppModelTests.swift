@testable import Bridgey
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    static let mac = "0b9e3f5c-1d2a-4b6c-8e7f-9a0b1c2d3e4f"
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var client: FakeClient!
    private var system: FakeSystem!
    private var model: AppModel!

    override func setUp() async throws {
        let suite = "bridgey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
        let on = ["clipboard": true, "files": true, "links": true, "ping": true]
        client = FakeClient(devices: [.init(deviceId: Self.mac, name: "MacBook Pro", platform: "macos", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on, remote: on)])
        system = FakeSystem()
        var options = LaunchOptions()
        options.discovery = false
        options.ephemeral = true
        let fake = client!
        model = AppModel(settings: settings, options: options, system: system, activityFile: nil) { _, _ in fake }
        model.start()
    }

    private var mac: DeviceItem { model.devices.first { $0.id == Self.mac }! }

    func testStartReadsDevicesAndAppliesSettings() {
        XCTAssertEqual(model.devices.map(\.name), ["MacBook Pro"])
        XCTAssertTrue(mac.clipboardReady && mac.filesReady && mac.linksReady)
        XCTAssertEqual(model.target?.id, Self.mac)
        XCTAssertTrue(client.calls.contains("feature * clipboard true"))
        XCTAssertTrue(client.calls.contains("feature * files true"))
        XCTAssertTrue(client.calls.contains("receive on"))
    }

    func testReceivedTextIsCopiedAndListed() {
        model.handle(CoreEvent(kind: .clipboard, deviceID: Self.mac, text: "hello from the Mac"))
        XCTAssertEqual(system.copied, ["hello from the Mac"])
        XCTAssertEqual(model.activity.first?.value, "hello from the Mac")
        XCTAssertEqual(model.activity.first?.direction, .received)
        XCTAssertEqual(model.activity.first?.deviceName, "MacBook Pro")
    }

    func testReceivedTextIsNotCopiedWhenTurnedOff() {
        settings.copyReceivedText = false
        model.handle(CoreEvent(kind: .clipboard, deviceID: Self.mac, text: "secret"))
        XCTAssertTrue(system.copied.isEmpty)
        XCTAssertEqual(model.activity.count, 1)
    }

    func testDraftSendsTextAndShowsDelivery() throws {
        model.draft = "Meeting at 4"
        model.sendDraft()
        XCTAssertEqual(client.calls.last, "text \(Self.mac) Meeting at 4")
        XCTAssertEqual(model.draft, "")
        let row = try XCTUnwrap(model.activity.first)
        XCTAssertEqual(row.outcome, .sending)
        model.handle(CoreEvent(kind: .clipboardSent, status: SendStatus.delivered.rawValue, id: try XCTUnwrap(row.request), deviceID: Self.mac))
        XCTAssertEqual(model.activity.first?.outcome, .delivered)
    }

    func testDraftLinkGoesAsALink() {
        model.draft = "https://roundrobin.in/bridgey"
        model.sendDraft()
        XCTAssertEqual(client.calls.last, "link \(Self.mac) https://roundrobin.in/bridgey")
        XCTAssertEqual(model.activity.first?.kind, .link)
    }

    func testLinkGoesAsTextWhenTheDeviceHasLinksOff() {
        model.handle(CoreEvent(kind: .features, deviceID: Self.mac, text: #"{"clipboard":true,"links":true}"#, extra: #"{"clipboard":true,"links":false}"#))
        XCTAssertFalse(mac.linksReady)
        model.draft = "https://example.com"
        model.sendDraft()
        XCTAssertEqual(client.calls.last, "text \(Self.mac) https://example.com")
    }

    func testRejectedTextSaysWhy() throws {
        model.draft = "x"
        model.sendDraft()
        let request = try XCTUnwrap(model.activity.first?.request)
        model.handle(CoreEvent(kind: .clipboardSent, status: SendStatus.rejected.rawValue, id: request, deviceID: Self.mac))
        XCTAssertEqual(model.activity.first?.outcome, .failed)
        XCTAssertEqual(model.activity.first?.detail, "Clipboard is off on that device.")
    }

    func testFeatureOffBecomesANotice() {
        client.failNext = CoreError(code: CoreError.featureOff)
        model.sendText("x", to: mac)
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(model.activity.isEmpty)
    }

    func testDisconnectAndFeaturesUpdateReadiness() {
        model.handle(CoreEvent(kind: .disconnected, deviceID: Self.mac, text: "closed_by_peer"))
        XCTAssertFalse(mac.connected)
        XCTAssertFalse(mac.clipboardReady)
        model.handle(CoreEvent(kind: .connected, deviceID: Self.mac, name: "MacBook Pro"))
        XCTAssertTrue(mac.connected)
        XCTAssertFalse(mac.clipboardReady, "not until the device sends its switches")
        model.handle(CoreEvent(kind: .features, deviceID: Self.mac, text: #"{"clipboard":true}"#, extra: #"{"clipboard":true}"#))
        XCTAssertTrue(mac.clipboardReady)
    }

    func testPairingByAddressThroughToPaired() {
        model.pair(address: "192.168.1.20:42470")
        XCTAssertEqual(client.calls.last, "pair - 192.168.1.20 42470")
        guard case let .dialling(pairing, _) = model.pairing else { return XCTFail("dialling") }
        model.handle(CoreEvent(kind: .pairingWaiting, id: pairing, name: "MacBook Pro"))
        XCTAssertEqual(model.pairing, .waiting(pairing: pairing, name: "MacBook Pro"))
        model.handle(CoreEvent(kind: .pairingCode, id: pairing, deviceID: Self.mac, name: "MacBook Pro", text: "744419"))
        XCTAssertEqual(model.pairing, .code(pairing: pairing, name: "MacBook Pro", code: "744419"))
        model.confirmCode(true)
        XCTAssertEqual(client.calls.last, "confirm \(pairing) true")
        XCTAssertEqual(model.pairing, .confirming(pairing: pairing, name: "MacBook Pro", code: "744419"))
        model.handle(CoreEvent(kind: .pairingFinished, status: 0, id: pairing, deviceID: Self.mac, name: "MacBook Pro", text: "paired"))
        XCTAssertEqual(model.pairing, .paired(name: "MacBook Pro"))
        XCTAssertEqual(model.targetID, Self.mac)
    }

    func testAMismatchedCodePairsNothing() {
        model.pair(address: "10.0.0.2")
        XCTAssertEqual(client.calls.last, "pair - 10.0.0.2 0")
        let pairing = model.pairing.pairing!
        model.handle(CoreEvent(kind: .pairingCode, id: pairing, deviceID: Self.mac, name: "Mac", text: "123456"))
        model.confirmCode(false)
        XCTAssertEqual(client.calls.last, "confirm \(pairing) false")
        XCTAssertEqual(model.pairing, .failed(name: "Mac", reason: "code_rejected"))
        XCTAssertEqual(PairingState.failureText("code_rejected", name: "Mac"), "The codes didn’t match, so nothing was paired.")
    }

    func testPairingScreenAllowsPairingWhileOpen() {
        model.pairingScreen(open: true)
        XCTAssertEqual(client.calls.last, "allow 120")
        model.pairingScreen(open: false)
        XCTAssertEqual(client.calls.last, "allow 0")
    }

    func testFilesComingInShowProgressThenARow() {
        model.handle(CoreEvent(kind: .fileIncoming, status: 1, id: 7, deviceID: Self.mac, name: "photo.jpg", extra: "image/jpeg", total: 1000))
        XCTAssertEqual(model.transfers.first?.name, "photo.jpg")
        model.handle(CoreEvent(kind: .fileProgress, status: 1, id: 7, deviceID: Self.mac, bytes: 500, total: 1000))
        XCTAssertEqual(model.transfers.first?.fraction, 0.5)
        model.handle(CoreEvent(kind: .fileDone, status: 1, id: 7, deviceID: Self.mac, name: "photo 2.jpg", text: "/tmp/photo 2.jpg", bytes: 1000, total: 1000))
        XCTAssertTrue(model.transfers.isEmpty)
        XCTAssertEqual(model.activity.first?.kind, .file)
        XCTAssertEqual(model.activity.first?.savedName, "photo 2.jpg")
    }

    func testSendingAFileCopiesItAndTracksTheTransfer() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: source)
        model.sendFiles([source], to: mac)
        let call = try XCTUnwrap(client.calls.last)
        XCTAssertEqual(call, "file \(Self.mac) \(source.lastPathComponent)")
        let transfer = try XCTUnwrap(model.transfers.first)
        XCTAssertEqual(transfer.total, 5)
        XCTAssertFalse(transfer.incoming)
        model.handle(CoreEvent(kind: .fileDone, status: 0, id: transfer.id, deviceID: Self.mac, name: source.lastPathComponent, bytes: 5, total: 5))
        XCTAssertEqual(model.activity.first?.outcome, .delivered)
        model.handle(CoreEvent(kind: .fileFailed, status: 0, id: 999, deviceID: Self.mac, name: "x", text: "rejected"))
        try? FileManager.default.removeItem(at: source)
    }

    func testFailedSendSaysWhy() {
        XCTAssertEqual(AppModel.fileFailure("rejected"), "Files is off on that device.")
        XCTAssertEqual(AppModel.fileFailure("verification_failed"), "The file didn’t arrive intact.")
        XCTAssertEqual(AppModel.fileFailure("something new"), "It didn’t finish.")
    }

    func testLinksWaitOnACardUnlessOpenRightAwayIsOn() throws {
        model.handle(CoreEvent(kind: .link, deviceID: Self.mac, text: "https://roundrobin.in"))
        XCTAssertEqual(model.links.count, 1)
        XCTAssertTrue(system.opened.isEmpty)
        model.open(try XCTUnwrap(model.links.first))
        XCTAssertEqual(system.opened, [URL(string: "https://roundrobin.in")!])
        XCTAssertTrue(model.links.isEmpty)
        settings.openLinksRightAway = true
        model.handle(CoreEvent(kind: .link, deviceID: Self.mac, text: "https://example.com"))
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertEqual(system.opened.last, URL(string: "https://example.com")!)
    }

    func testPairingRequestCardAllows() {
        model.handle(CoreEvent(kind: .pairingRequest, deviceID: Self.mac, name: "Pixel 9"))
        XCTAssertEqual(model.pairingRequest, PairingRequest(deviceID: Self.mac, name: "Pixel 9"))
        model.allowPairingRequest()
        XCTAssertNil(model.pairingRequest)
        XCTAssertEqual(client.calls.last, "allow 120")
    }

    func testForgettingRemovesTheDevice() {
        model.forget(mac)
        XCTAssertEqual(client.calls.last, "forget \(Self.mac)")
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(model.target)
    }

    func testIsLink() {
        XCTAssertTrue(AppModel.isLink("https://example.com/a?b"))
        XCTAssertTrue(AppModel.isLink("http://192.168.1.1:8080"))
        XCTAssertFalse(AppModel.isLink("example.com"))
        XCTAssertFalse(AppModel.isLink("https://example.com and more"))
        XCTAssertFalse(AppModel.isLink("ftp://example.com"))
    }

    func testBackgroundWithNothingRunningStops() {
        model.enterBackground()
        XCTAssertEqual(client.calls.last, "stop")
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.devices.contains { $0.connected })
    }

    func testSettingsPersist() {
        settings.files = false
        settings.appearance = .dark
        let again = AppSettings(defaults: defaults)
        XCTAssertFalse(again.files)
        XCTAssertEqual(again.appearance, .dark)
        XCTAssertTrue(again.clipboard)
        XCTAssertFalse(again.openLinksRightAway, "off by default")
    }
}
