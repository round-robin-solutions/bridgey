import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Mac actions, Open links right away and Connection health in Settings, rendered from sample
/// state at the panes' natural height. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter AutomationScreenshots
final class AutomationScreenshots: XCTestCase {
    private var directory: URL!
    private let calendar = Calendar.current
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: hour, minute: minute))!
    }

    private var model: SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"), TrustedDeviceInfo(id: tabletID, name: "Pixel Tablet")]
        model.trustedDevices = trusted
        model.rings = deviceRings(trusted: trusted, peers: [], state: model.state)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, $0 != .remoteInput) })
        model.remoteFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.phoneFeatures = [phoneID: model.remoteFeatures]
        model.deviceFeatures = [phoneID: [.macActions: true]]
        model.mediaPlayer = .music
        model.openLinksRightAway = true
        model.accessibilityTrusted = false
        model.now = at(9, 41)
        var config = MacActionsConfig()
        config.switches = [.lock: true, .sleep: true, .volume: true]
        _ = config.addApp(AllowedApp(bundleID: "com.apple.Safari", name: "Safari"))
        _ = config.addApp(AllowedApp(bundleID: "com.apple.Music", name: "Music"))
        _ = config.addShortcut(named: "Focus on", handle: "0f0e0d0c-0b0a-4908-8706-050403020100")
        _ = config.addShortcut(named: "Start meeting", handle: "1f0e0d0c-0b0a-4908-8706-050403020100")
        model.macActions = config
        model.availableShortcuts = ["Focus on", "Start meeting", "Night mode"]
        model.macActionsAudit = [
            MacActionAuditEntry(id: "1", deviceID: phoneID, deviceName: "OnePlus 11", action: "lock", title: "Lock screen", outcome: "done", at: at(9, 12)),
            MacActionAuditEntry(id: "2", deviceID: phoneID, deviceName: "OnePlus 11", action: "app:com.apple.Music", title: "Music", outcome: "done", at: at(8, 40)),
            MacActionAuditEntry(id: "3", deviceID: tabletID, deviceName: "Pixel Tablet", action: "sleep", title: "Sleep", outcome: "not_allowed", at: at(8, 2)),
        ]
        var record = DeviceHealthRecord()
        record.connectedSince = at(8, 55)
        record.route = .sameNetwork
        record.outbound = false
        record.roundTrips.sent("a", at: at(9, 40))
        record.roundTrips.received("a", at: at(9, 40).addingTimeInterval(0.014))
        record.lastDropReason = "heartbeat_timeout"
        record.lastDropAt = at(8, 50)
        record.reconnects.increment(now: model.now)
        record.reconnects.increment(now: model.now)
        var offline = DeviceHealthRecord()
        offline.lastDropReason = "network_unreachable"
        offline.lastDropAt = calendar.date(byAdding: .day, value: -1, to: at(18, 20))
        model.health = [
            phoneID: ConnectionHealthSnapshot(deviceID: phoneID, record: record, connected: true, discoveryVisible: true, discovery: .browsing, now: model.now),
            tabletID: ConnectionHealthSnapshot(deviceID: tabletID, record: offline, connected: false, discoveryVisible: false, discovery: .browsing, now: model.now),
        ]
        return model
    }

    @MainActor func testMediaAndActionsPane() throws {
        for scheme in [ColorScheme.light, .dark] {
            try renderPane(.media, model: model, scheme: scheme, name: "mac-automation-media-actions-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor func testMacActionsOff() throws {
        var off = model
        off.globalFeatures[.macActions] = false
        off.macActions = MacActionsConfig()
        off.macActionsAudit = []
        off.deviceFeatures = [:]
        off.openLinksRightAway = false
        for scheme in [ColorScheme.light, .dark] {
            try renderPane(.media, model: off, scheme: scheme, name: "mac-automation-media-actions-off-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor func testDevicesPaneWithHealth() throws {
        for scheme in [ColorScheme.light, .dark] {
            try renderPane(.devices, model: model, scheme: scheme, name: "mac-automation-devices-health-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor private func renderPane(_ pane: SettingsPane, model: SettingsModel, scheme: ColorScheme, name: String) throws {
        let view = BrandRoot(reduceMotion: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text(pane.title).font(BrandFont.heading(24)).frame(height: 30)
                SettingsPaneView(pane: pane, model: model, actions: SettingsActions())
            }
            .padding(32)
            .frame(width: 670, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
        }
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true)
            .environment(\.locale, Locale(identifier: "en_GB")))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
