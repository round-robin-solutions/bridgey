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

    func testPrivacySubpagesStayOutOfTheSidebar() {
        XCTAssertFalse(SettingsPane.sidebarItems.contains(.permissions))
        XCTAssertFalse(SettingsPane.sidebarItems.contains(.reset))
        XCTAssertEqual(SettingsPane.permissions.sidebarPane, .privacy)
        XCTAssertEqual(SettingsPane.reset.parentPane, .privacy)
        XCTAssertNil(SettingsPane.general.parentPane)
        XCTAssertEqual(SettingsPane.permissions.title, "Permissions")
    }
}
