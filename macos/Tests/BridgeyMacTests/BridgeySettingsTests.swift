import XCTest
@testable import BridgeyMac

final class BridgeySettingsTests: XCTestCase {
    private let otherAppsKey = "settings.calls.otherApps"
    /// `BridgeySettings()` reads and settles keys in the test runner's own defaults; put them back afterwards.
    private lazy var touchedKeys = [otherAppsKey, "settings.codes.engine"]
    private var savedValues: [String: Any] = [:]

    override func setUp() {
        savedValues = touchedKeys.reduce(into: [:]) { $0[$1] = UserDefaults.standard.object(forKey: $1) }
        UserDefaults.standard.removeObject(forKey: otherAppsKey)
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
