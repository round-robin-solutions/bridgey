@testable import Bridgey
import XCTest

/// The parts of I2 every feature shares: per-platform screen keys, the feature switches, battery on a device, and
/// where the library's data is kept.
@MainActor
final class FoundationI2Tests: XCTestCase {
    static let mac = "0b9e3f5c-1d2a-4b6c-8e7f-9a0b1c2d3e4f"
    static let phone = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f"
    static let pc = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var client: FakeClient!
    private var model: AppModel!

    override func setUp() async throws {
        let suite = "bridgey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
        let on = ["clipboard": true, "files": true, "links": true, "ping": true, "battery": true, "find_device": true]
        client = FakeClient(devices: [
            .init(deviceId: Self.mac, name: "MacBook Pro", platform: "macos", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on, remote: on.merging(["screen_control_draft1": true]) { $1 }),
            .init(deviceId: Self.phone, name: "Pixel 9", platform: "android", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on,
                  remote: on.merging(["screen_draft1": true, "phone_control_draft1": true, "sms_draft1": true, "files_browse_draft1": true]) { $1 }),
            .init(deviceId: Self.pc, name: "Studio PC", platform: "windows", connected: true, pairedAtMs: nil, lastConnectedMs: nil, local: on, remote: on),
        ])
        var options = LaunchOptions()
        options.discovery = false
        options.ephemeral = true
        let fake = client!
        model = AppModel(settings: settings, options: options, system: FakeSystem(), activityFile: nil) { _, _ in fake }
        model.start()
    }

    private func device(_ id: String) -> DeviceItem { model.devices.first { $0.id == id }! }

    func testEachDeviceGetsOnlyTheViewerKeyItsPlatformReadsThatWay() {
        XCTAssertTrue(client.calls.contains("feature \(Self.phone) screen_draft1 true"))
        XCTAssertTrue(client.calls.contains("feature \(Self.phone) phone_control_draft1 true"))
        XCTAssertTrue(client.calls.contains("feature \(Self.mac) screen_control_draft1 true"))
        // A Mac would read screen_draft1 as "this phone shares its screen", and a PC gets no screen key at all.
        XCTAssertFalse(client.calls.contains("feature \(Self.mac) screen_draft1 true"))
        XCTAssertFalse(client.calls.contains("feature \(Self.phone) screen_control_draft1 true"))
        XCTAssertFalse(client.calls.contains { $0.hasPrefix("feature \(Self.pc) screen") && $0.hasSuffix("true") })
        XCTAssertEqual(device(Self.phone).screenArea, .screen)
        XCTAssertEqual(device(Self.mac).screenArea, .display)
        XCTAssertNil(device(Self.pc).screenArea)
        XCTAssertTrue(device(Self.phone).screenReady)
        XCTAssertTrue(device(Self.mac).screenReady)
    }

    func testScreensOffHereOrForOneDeviceTurnsItsKeyOff() {
        model.setScreen(device(Self.mac), on: false)
        XCTAssertTrue(client.calls.contains("feature \(Self.mac) screen_control_draft1 false"))
        XCTAssertFalse(device(Self.mac).screenReady)
        XCTAssertTrue(device(Self.phone).screenReady, "the other device keeps its key")
        settings.screens = false
        model.applyDefaults()
        XCTAssertTrue(client.calls.contains("feature \(Self.phone) screen_draft1 false"))
        XCTAssertTrue(client.calls.contains("feature \(Self.phone) phone_control_draft1 false"))
    }

    func testNoKeyEverOffersThisDeviceAsAScreenSourceOrInputHost() {
        for platform in ["android", "macos", "windows", "linux", "ios", nil] as [String?] {
            let keys = ScreenRoles.keys(platform: platform, wanted: true)
            XCTAssertEqual(Set(keys.keys), Set(ScreenRoles.keys))
            XCTAssertFalse(keys.contains { $0.value } && platform != "android" && platform != "macos")
        }
        XCTAssertFalse(model.featureDefaults.contains { $0.0 == "remote_input_draft1" })
        XCTAssertFalse(model.featureDefaults.contains { $0.0.hasPrefix("screen") })
    }

    func testFeatureDefaultsFollowSettings() {
        XCTAssertTrue(client.calls.contains("feature * battery true"))
        XCTAssertTrue(client.calls.contains("feature * find_device true"))
        XCTAssertTrue(client.calls.contains("feature * notifications true"))
        XCTAssertTrue(client.calls.contains("feature * sms_draft1 false"), "Text messages is off until chosen")
        XCTAssertTrue(client.calls.contains("feature * media false"), "iOS can't control other apps' players")
        XCTAssertTrue(client.calls.contains("codes false false"))
        XCTAssertTrue(client.calls.contains("connect false -"), "tests never reach the control service")
        settings.textMessages = true
        settings.codesFromMessages = true
        model.applyDefaults()
        XCTAssertTrue(client.calls.contains("feature * sms_draft1 true"))
        XCTAssertTrue(client.calls.contains("codes true false"))
    }

    func testBatteryShowsOnTheDeviceUntilItDisconnects() {
        model.handle(CoreEvent(kind: .battery, status: 82, id: 1, deviceID: Self.phone))
        XCTAssertEqual(device(Self.phone).battery, BatteryLevel(level: 82, charging: true))
        XCTAssertEqual(device(Self.phone).statusLabel(selected: false), "Connected, battery 82%, charging")
        model.refresh()
        XCTAssertEqual(device(Self.phone).battery?.level, 82, "a refresh keeps it")
        model.handle(CoreEvent(kind: .disconnected, deviceID: Self.phone))
        XCTAssertNil(device(Self.phone).battery)
    }

    func testPhoneActionsNeedThePhonesAllowance() {
        let phone = device(Self.phone)
        XCTAssertTrue(phone.messagesOffered)
        XCTAssertFalse(phone.messagesOn)
        XCTAssertTrue(phone.phoneFilesReady)
        XCTAssertTrue(phone.findReady)
        XCTAssertFalse(device(Self.mac).messagesOffered)
        XCTAssertFalse(device(Self.mac).phoneFilesReady)
    }

    func testFeaturesAreToldWhenTheSessionStops() {
        model.screen.viewing = Self.mac
        model.path = [.messages(deviceID: Self.phone)]
        model.stop()
        XCTAssertNil(model.screen.viewing)
        XCTAssertTrue(model.path.isEmpty)
    }

    func testHybridStoreKeepsPairingInTheKeychainAndFeatureDataInFiles() throws {
        let keychain = MemorySecretStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HybridStore(keychain: keychain, folder: folder)
        try store.store("identity", Data("id".utf8))
        try store.store("sms-0b9e3f5c", Data("conversations".utf8))
        XCTAssertEqual(try keychain.load("identity"), Data("id".utf8))
        XCTAssertNil(try keychain.load("sms-0b9e3f5c"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sms-0b9e3f5c")), Data("conversations".utf8))
        XCTAssertEqual(try store.load("sms-0b9e3f5c"), Data("conversations".utf8))
        XCTAssertThrowsError(try store.store("../escape", Data()))
        XCTAssertThrowsError(try store.store(".hidden", Data()))
        try store.remove("sms-0b9e3f5c")
        XCTAssertNil(try store.load("sms-0b9e3f5c"))
        HybridStore.removeFeatureData(folder: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
