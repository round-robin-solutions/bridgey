import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Settings sync: the General switch, the sync marks, each phone's switch on the Devices page (one phone
/// with sync off on its side) and the activity item, light and dark. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter SettingsSyncScreenshots
final class SettingsSyncScreenshots: XCTestCase {
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
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, !$0.needsDeviceGrant) })
        model.remoteFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.phoneFeatures = [phoneID: model.remoteFeatures, tabletID: model.remoteFeatures]
        model.now = at(9, 41)
        model.reduceMotion = true
        model.showPreviews = false
        model.folderReceiveMode = .ask
        model.folderConflictPolicy = .merge
        model.settingsSyncEnabled = true
        model.phoneSettingsSync = [phoneID: true, tabletID: false]
        model.notificationsAuthorized = true
        return model
    }

    @MainActor func testSettingsSyncPanes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try renderPane(.general, model: model, scheme: scheme, name: "mac-settings-sync-general-\(suffix)")
            try renderPane(.devices, model: model, scheme: scheme, name: "mac-settings-sync-devices-\(suffix)")
            var different = model
            different.syncStatus[.featureCalls] = SyncRowStatus(differentOn: ["OnePlus 11"])
            try renderPane(.calls, model: different, scheme: scheme, name: "mac-settings-sync-different-\(suffix)")
            var waiting = model
            waiting.notificationsAuthorized = false
            waiting.syncStatus[.featureNotifications] = SyncRowStatus(localWaiting: true)
            try renderPane(.notifications, model: waiting, scheme: scheme, name: "mac-settings-sync-waiting-\(suffix)")
            var choose = model
            choose.syncExcluded = [.featureCamera, .codesEnabled]
            let sheet = BrandRoot(reduceMotion: false) {
                SyncChoicesView(model: choose, actions: SettingsActions(), done: {})
                    .fixedSize(horizontal: false, vertical: true)
            }
            try write(sheet, scheme: scheme, name: "mac-settings-sync-choose-\(suffix)")
        }
    }

    @MainActor func testFirstConnectQuestion() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                SyncQuestionView(phone: "OnePlus 11", use: {}, keep: {}).fixedSize(horizontal: false, vertical: true)
            }
            try write(view, scheme: scheme, name: "mac-settings-sync-first-connect-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor func testActivityItem() throws {
        let items = [
            ActivityItem(id: 3, kind: .settingsSynced, deviceID: phoneID, deviceName: "OnePlus 11", fileName: nil, preview: nil, appName: nil,
                         sensitive: false, automatic: false, count: 1, at: at(9, 40), content: "reduce_motion=0,calls=1"),
            ActivityItem(id: 2, kind: .settingsSynced, deviceID: tabletID, deviceName: "Pixel Tablet", fileName: nil, preview: nil, appName: nil,
                         sensitive: false, automatic: false, count: 1, at: at(9, 12), content: "folder_destination=1,auto_clipboard=1"),
            ActivityItem(id: 1, kind: .fileSent, deviceID: phoneID, deviceName: "OnePlus 11", fileName: "invoice-oct.pdf", preview: nil, appName: nil,
                         sensitive: false, automatic: false, count: 1, at: at(8, 55)),
        ]
        var panel = PanelModel()
        panel.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        panel.rings = deviceRings(trusted: [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")], peers: [], state: panel.state)
        panel.rows = streamRows(items, now: at(9, 41))
        panel.now = at(9, 41)
        panel.available = Set(BridgeyFeature.allCases)
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                StreamPanelView(model: panel, actions: PanelActions())
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(24)
            .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            try write(view, scheme: scheme, name: "mac-settings-sync-activity-\(scheme == .dark ? "dark" : "light")")
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
        try write(view, scheme: scheme, name: name)
    }

    @MainActor private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
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
