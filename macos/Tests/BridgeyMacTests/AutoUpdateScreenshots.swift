import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Update all devices automatically: Settings > Updates with the switch and its status lines, the notice
/// (start, countdown, started by a phone) and a run held by a call. Light and dark.
/// Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter AutoUpdateScreenshots
final class AutoUpdateScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-4111-8111-111111111111"
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 14, minute: 2))!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func item(_ id: String, _ name: String, local: Bool = false, step: UpdateRunStep) -> UpdateRunItem {
        UpdateRunItem(id: id, name: name, isLocal: local, fromApp: "0.10.0-rr.1-beta.10", fromBuild: 263_011_402,
                      targetApp: "0.10.0-rr.1-beta.11", targetBuild: 263_020_900, channel: .beta, step: step,
                      startedAt: now.addingTimeInterval(-30), stepSince: now.addingTimeInterval(-30))
    }

    private func run(phone: UpdateRunStep, mac: UpdateRunStep, countdown: TimeInterval? = nil, hold: UpdateBusy? = nil) -> UpdateRun {
        UpdateRun(id: "auto", startedAt: now.addingTimeInterval(-30), items: [
            item(phoneID, "OnePlus 11", step: phone),
            item(UpdatePlan.localID, "This Mac", local: true, step: mac),
        ], countdownUntil: countdown.map { now.addingTimeInterval($0) }, updatedAt: now, auto: true, hold: hold)
    }

    private var lastRun: AutoRunRecord {
        var record = AutoRunRecord(run: run(phone: .done("0.10.0-rr.1-beta.10"), mac: .done("0.10.0-rr.1-beta.10")))
        record.at = now.addingTimeInterval(-26 * 3600)
        record.version = "0.10.0-rr.1-beta.10"
        return record
    }

    private var settingsStates: [(String, AutoUpdateDisplay)] {
        [
            ("on", AutoUpdateDisplay(enabled: true, choice: nil, available: true, checksOff: false, channel: .beta, decision: .nothingToDo,
                                     lastRun: lastRun, now: now)),
            ("waiting", AutoUpdateDisplay(enabled: true, choice: nil, available: true, checksOff: false, channel: .beta,
                                          decision: .wait(.call, device: "OnePlus 11", until: now.addingTimeInterval(300)), lastRun: lastRun, now: now)),
            ("later", AutoUpdateDisplay(enabled: true, choice: true, available: true, checksOff: false, channel: .stable,
                                        decision: .later(until: now.addingTimeInterval(3600)), lastRun: lastRun, now: now)),
            ("off", AutoUpdateDisplay(enabled: false, choice: nil, available: true, checksOff: false, channel: .stable, decision: .off, now: now)),
        ]
    }

    @MainActor func testSettings() throws {
        for scheme in [ColorScheme.light, .dark] {
            for (name, display) in settingsStates {
                var model = SettingsModel()
                model.deviceName = "Rahul\u{2019}s MacBook Pro"
                model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
                model.channel = display.channel
                model.automaticallyChecks = true
                model.updatesAvailable = true
                model.canCheckForUpdates = true
                model.lastCheck = now.addingTimeInterval(-300)
                model.now = now
                model.shortVersion = "0.10.0-rr.1-beta.10"
                model.updateFlow = .idle
                model.remoteStartUpdates = true
                model.autoUpdate = display
                let view = BrandRoot(reduceMotion: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(SettingsPane.updates.title).font(BrandFont.heading(24)).frame(height: 30)
                        SettingsPaneView(pane: .updates, model: model, actions: SettingsActions())
                    }
                    .padding(32)
                    .frame(width: 670, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
                }
                try write(view, scheme: scheme, name: "mac-settings-auto-update-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @MainActor func testNotice() throws {
        let states: [(String, AutoNoticeState)] = [
            ("starting", AutoNoticeState.make(run: run(phone: .downloading(40), mac: .ready), now: now.addingTimeInterval(-28),
                                              currentVersion: "0.10.0-rr.1-beta.10", closedRunID: nil)),
            ("countdown", AutoNoticeState.make(run: run(phone: .restarting, mac: .ready, countdown: 42), now: now, currentVersion: "0.10.0-rr.1-beta.10", closedRunID: nil)),
            ("started-by", .startedBy("OnePlus 11")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, state) in states {
                let content = AutoNoticeContent()
                content.state = state
                content.now = now
                let view = BrandRoot(reduceMotion: false) {
                    AutoUpdateNoticeView(content: content, later: {}, restartNow: {}, close: {})
                        .padding(24)
                        .background(scheme == .dark ? Color(hex: 0x1B2230) : Color(hex: 0xC9D3DE))
                }
                try write(view, scheme: scheme, name: "mac-notice-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @MainActor func testPanelHeldByACall() throws {
        for scheme in [ColorScheme.light, .dark] {
            let held = run(phone: .done("0.10.0-rr.1-beta.11"), mac: .ready, hold: .call)
            var model = PanelModel()
            model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
            model.rings = deviceRings(trusted: [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")], peers: [], state: model.state)
            model.available = Set(BridgeyFeature.allCases)
            model.now = now
            model.appVersion = "0.10.0-rr.1-beta.10"
            model.updateAll = UpdateAllDisplay(plan: UpdatePlan(), run: held, now: now)
            let view = BrandRoot(reduceMotion: false) {
                StreamPanelView(model: model, actions: PanelActions())
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(24)
            .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
            try write(view, scheme: scheme, name: "mac-panel-auto-update-held-\(scheme == .dark ? "dark" : "light")")
        }
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
