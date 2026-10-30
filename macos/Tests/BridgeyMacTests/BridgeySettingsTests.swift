import XCTest
@testable import BridgeyMac

final class BridgeySettingsTests: XCTestCase {
    private let otherAppsKey = "settings.calls.otherApps"
    /// `BridgeySettings()` reads and settles keys in the test runner's own defaults; put them back afterwards.
    private let connectAwayKey = "settings.connect.away"
    private lazy var touchedKeys = [otherAppsKey, "settings.codes.engine", connectAwayKey]
    private var savedValues: [String: Any] = [:]

    override func setUp() {
        savedValues = touchedKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
        UserDefaults.standard.removeObject(forKey: otherAppsKey)
        UserDefaults.standard.removeObject(forKey: connectAwayKey)
    }

    override func tearDown() {
        for key in touchedKeys {
            if let value = savedValues[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        BridgeyLog.policy = LoggingPolicy()
    }

    func testGlobalSwitchOverridesDeviceSetting() {
        XCTAssertFalse(effectiveFeatureEnabled(globalEnabled: false, deviceEnabled: true))
        XCTAssertFalse(effectiveFeatureEnabled(globalEnabled: false, deviceEnabled: nil))
    }

    func testDeviceSwitchOverridesEnabledGlobalDefault() {
        XCTAssertFalse(effectiveFeatureEnabled(globalEnabled: true, deviceEnabled: false))
        XCTAssertTrue(effectiveFeatureEnabled(globalEnabled: true, deviceEnabled: true))
        XCTAssertTrue(effectiveFeatureEnabled(globalEnabled: true, deviceEnabled: nil))
    }

    func testFeatureRequiresBothDevicesToOfferIt() {
        XCTAssertTrue(effectiveFeatureAvailable(localEnabled: true, remoteEnabled: true))
        XCTAssertFalse(effectiveFeatureAvailable(localEnabled: true, remoteEnabled: false))
        XCTAssertFalse(effectiveFeatureAvailable(localEnabled: false, remoteEnabled: true))
    }


    func testNewerFeaturesAreOffForLegacyPeers() {
        XCTAssertFalse(featureEnabledByLegacyPeer(.calls))
        XCTAssertFalse(featureEnabledByLegacyPeer(.ping))
        XCTAssertTrue(featureEnabledByLegacyPeer(.battery))
    }

    /// Connect away from home is on until chosen (Rahul, 2026-10-30); nobody chose, so it is not a choice to sync.
    @MainActor
    func testConnectAwayIsOnForAFreshInstall() {
        let settings = BridgeySettings()
        XCTAssertTrue(settings.connectAway)
        XCTAssertNil(settings.connectAwayChoice)
        let synced = SettingsSyncController.connectAwaySetting(settings)
        XCTAssertEqual(synced.read(), .bool(true))
        XCTAssertEqual(synced.followsDefault(), true)
        XCTAssertNil(settingsSyncStoredValues(UserDefaults.standard.dictionaryRepresentation())[.connectAway])
        XCTAssertEqual(SyncKey.connectAway.defaultValue, .bool(true))
    }

    /// An explicit off is stored, survives a restart or an upgrade, and is a choice the upgrade stamp keeps.
    @MainActor
    func testAnExplicitConnectAwayOffStaysOff() {
        BridgeySettings().setConnectAway(false)
        let reloaded = BridgeySettings()
        XCTAssertFalse(reloaded.connectAway)
        XCTAssertEqual(reloaded.connectAwayChoice, false)
        XCTAssertEqual(SettingsSyncController.connectAwaySetting(reloaded).followsDefault(), false)
        XCTAssertEqual(settingsSyncStoredValues(UserDefaults.standard.dictionaryRepresentation())[.connectAway], .bool(false))
        // A synced value counts as a choice too.
        SettingsSyncController.connectAwaySetting(reloaded).write(.bool(true))
        XCTAssertEqual(BridgeySettings().connectAwayChoice, true)
    }

    @MainActor
    func testCallsFromOtherAppsAskByDefault() {
        XCTAssertEqual(BridgeySettings().otherAppCallPolicy, .ask)
    }

    @MainActor
    func testCallsFromOtherAppsPolicyIsRemembered() {
        let settings = BridgeySettings()
        for policy in MacOtherAppCallPolicy.allCases {
            settings.setOtherAppCallPolicy(policy)
            XCTAssertEqual(settings.otherAppCallPolicy, policy)
            XCTAssertEqual(UserDefaults.standard.string(forKey: otherAppsKey), policy.rawValue)
            XCTAssertEqual(BridgeySettings().otherAppCallPolicy, policy, "read back on the next launch")
        }
        XCTAssertEqual(Set(MacOtherAppCallPolicy.allCases.map(\.rawValue)), ["ask", "call_now", "refuse"], "stored values are pinned")
    }

    @MainActor
    func testUnknownCallsFromOtherAppsValueReadsAsAsk() {
        for stored: Any in ["always", "", "CALL_NOW", 1, true] {
            UserDefaults.standard.set(stored, forKey: otherAppsKey)
            XCTAssertEqual(BridgeySettings().otherAppCallPolicy, .ask, "\(stored)")
        }
    }
}
