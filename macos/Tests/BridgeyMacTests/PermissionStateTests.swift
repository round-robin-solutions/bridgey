import CoreBluetooth
import Foundation
import UserNotifications
import XCTest
@testable import BridgeyMac

final class PermissionStateTests: XCTestCase {
    func testChipForEverySystemState() {
        XCTAssertEqual(PermissionStatus.chip(system: .allowed, needed: true), .allowed)
        XCTAssertEqual(PermissionStatus.chip(system: .allowed, needed: false), .allowed)
        XCTAssertEqual(PermissionStatus.chip(system: .denied, needed: true), .notAllowed)
        XCTAssertEqual(PermissionStatus.chip(system: .notDetermined, needed: true), .notAllowed)
        XCTAssertEqual(PermissionStatus.chip(system: .denied, needed: false), .notNeededYet)
        XCTAssertEqual(PermissionStatus.chip(system: .notDetermined, needed: false), .notNeededYet)
        XCTAssertEqual(PermissionStatus.chip(system: .unavailable, needed: true), .notOnThisDevice)
    }

    func testManageAsksFirstThenOpensSystemSettings() {
        XCTAssertEqual(PermissionStatus.manage(system: .notDetermined), .request)
        XCTAssertEqual(PermissionStatus.manage(system: .denied), .openSettings)
        XCTAssertEqual(PermissionStatus.manage(system: .allowed), .openSettings)
        XCTAssertEqual(PermissionStatus.manage(system: .unavailable), .none)
    }

    func testNotificationsMapping() {
        XCTAssertEqual(PermissionMapping.notifications(.authorized), .allowed)
        XCTAssertEqual(PermissionMapping.notifications(.provisional), .allowed)
        XCTAssertEqual(PermissionMapping.notifications(.denied), .denied)
        XCTAssertEqual(PermissionMapping.notifications(.notDetermined), .notDetermined)
    }

    func testBluetoothMapping() {
        XCTAssertEqual(PermissionMapping.bluetooth(.allowedAlways), .allowed)
        XCTAssertEqual(PermissionMapping.bluetooth(.denied), .denied)
        XCTAssertEqual(PermissionMapping.bluetooth(.restricted), .denied)
        XCTAssertEqual(PermissionMapping.bluetooth(.notDetermined), .notDetermined)
    }

    func testAutomationMappingFallsBackToTheLastAnswerWhenThePlayerIsClosed() {
        XCTAssertEqual(PermissionMapping.automation(noErr, lastKnown: nil), .allowed)
        XCTAssertEqual(PermissionMapping.automation(-1743, lastKnown: .allowed), .denied)
        XCTAssertEqual(PermissionMapping.automation(-1744, lastKnown: nil), .notDetermined)
        XCTAssertEqual(PermissionMapping.automation(-600, lastKnown: .allowed), .allowed)
        XCTAssertEqual(PermissionMapping.automation(-600, lastKnown: nil), .notDetermined)
    }

    func testLocalNetworkAndAccessibilityMapping() {
        XCTAssertEqual(PermissionMapping.localNetwork(browseDenied: false, reachedADevice: true), .allowed)
        XCTAssertEqual(PermissionMapping.localNetwork(browseDenied: true, reachedADevice: false), .denied)
        XCTAssertEqual(PermissionMapping.localNetwork(browseDenied: false, reachedADevice: false), .notDetermined)
        XCTAssertEqual(PermissionMapping.accessibility(trusted: true), .allowed)
        XCTAssertEqual(PermissionMapping.accessibility(trusted: false), .notDetermined)
    }

    func testNeededFollowsTheFeatures() {
        var needs = PermissionNeeds(notifications: false, calls: false, codes: false, remoteControl: false, media: true, mediaPlayer: .off)
        XCTAssertTrue(needs.needed(.localNetwork))
        XCTAssertFalse(needs.needed(.notifications))
        XCTAssertFalse(needs.needed(.bluetooth))
        XCTAssertFalse(needs.needed(.accessibility))
        XCTAssertFalse(needs.needed(.automation), "media on but no player chosen")
        needs.codes = true
        needs.remoteControl = true
        needs.mediaPlayer = .spotify
        XCTAssertTrue(needs.needed(.notifications), "codes arrive as notifications")
        XCTAssertTrue(needs.needed(.bluetooth))
        XCTAssertTrue(needs.needed(.accessibility))
        XCTAssertTrue(needs.needed(.automation))
    }

    /// v0.9: Lock (Mac actions) needs Accessibility too; Send the Current Browser Tab needs Automation for the browser.
    func testAutomationFeaturesNeedTheirPermissions() {
        var needs = PermissionNeeds(notifications: false, calls: false)
        XCTAssertFalse(needs.needed(.accessibility))
        XCTAssertFalse(needs.needed(.browserAutomation))
        needs.macActionsLock = true
        XCTAssertTrue(needs.needed(.accessibility), "Lock presses the Lock Screen shortcut")
        XCTAssertFalse(needs.needed(.automation), "the player's Automation is separate from the browser's")
        needs.browserTab = true
        XCTAssertTrue(needs.needed(.browserAutomation))
        XCTAssertEqual(PermissionStatus(permission: .browserAutomation, system: .notDetermined, needed: false).chip, .notNeededYet)
        XCTAssertEqual(PermissionStatus(permission: .browserAutomation, system: .denied, needed: true).chip, .notAllowed)
    }

    func testEveryPermissionHasItsCopyAndExactSettingsPage() {
        XCTAssertEqual(SetupPermission.allCases, [.localNetwork, .notifications, .bluetooth, .accessibility, .automation, .browserAutomation])
        XCTAssertEqual(SetupPermission.localNetwork.why, "Finds your phone and talks to it on this network.")
        XCTAssertEqual(SetupPermission.automation.without, "Media controls from the phone do nothing.")
        XCTAssertEqual(SetupPermission.bluetooth.explainerTitle, "Allow Bluetooth?")
        XCTAssertTrue(SetupPermission.localNetwork.settingsURL.absoluteString.hasSuffix("Privacy_LocalNetwork"))
        XCTAssertTrue(SetupPermission.bluetooth.settingsURL.absoluteString.hasSuffix("Privacy_Bluetooth"))
        XCTAssertTrue(SetupPermission.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
        XCTAssertTrue(SetupPermission.automation.settingsURL.absoluteString.hasSuffix("Privacy_Automation"))
        XCTAssertTrue(SetupPermission.browserAutomation.settingsURL.absoluteString.hasSuffix("Privacy_Automation"))
        XCTAssertEqual(SetupPermission.browserAutomation.name, "Automation (Safari, Chrome)")
        XCTAssertTrue(SetupPermission.notifications.settingsURL.absoluteString.contains("Notifications-Settings"))
    }

    func testPermissionsAndResetAreCardsInPrivacy() {
        XCTAssertEqual(SettingsPane.permissions.group, .privacy)
        XCTAssertEqual(SettingsPane.reset.group, .privacy)
        XCTAssertEqual(SettingsPane.permissions.card, .permissions)
        XCTAssertEqual(SettingsPane.reset.card, .reset)
        XCTAssertEqual(SettingsGroup.privacy.cards(developer: false), [.activity, .permissions, .logging, .reset])
        XCTAssertEqual(SettingsPane.permissions.title, "Permissions")
    }

    /// A probe that never returns (seen live: 64 of them filled GCD's worker pool on the work Mac, so clipboard and
    /// file sends never started) holds one thread, and refreshes meanwhile start no more.
    func testAHungAutomationProbeIsNeverStackedUp() {
        let release = DispatchSemaphore(value: 0)
        let calls = NSLock()
        var started: [String] = []
        let gate = AutomationProbeGate { bundleID, ask in
            calls.withLock { started.append("\(ask ? "ask" : "check"):\(bundleID)") }
            release.wait()
            return noErr
        }
        let finished = expectation(description: "probes finished")
        finished.expectedFulfillmentCount = 2
        XCTAssertTrue(gate.run(bundleID: "com.apple.Music", ask: false) { _ in finished.fulfill() })
        for _ in 0..<100 { XCTAssertFalse(gate.run(bundleID: "com.apple.Music", ask: false) { _ in XCTFail("skipped probes never run") }) }
        XCTAssertTrue(gate.run(bundleID: "com.apple.Safari", ask: false) { _ in finished.fulfill() }, "another app has its own probe")
        XCTAssertEqual(gate.runningCount, 2)
        // Every refresh queued 64 such blocks on a global queue before; this one must still run at once.
        let globalQueue = expectation(description: "the global queue still runs work")
        DispatchQueue.global(qos: .userInitiated).async { globalQueue.fulfill() }
        wait(for: [globalQueue], timeout: 5)
        release.signal()
        release.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(gate.runningCount, 0)
        XCTAssertEqual(calls.withLock { started.sorted() }, ["check:com.apple.Music", "check:com.apple.Safari"])
        let again = expectation(description: "a finished probe can run again")
        XCTAssertTrue(gate.run(bundleID: "com.apple.Music", ask: false) { _ in again.fulfill() })
        release.signal()
        wait(for: [again], timeout: 5)
    }
}
