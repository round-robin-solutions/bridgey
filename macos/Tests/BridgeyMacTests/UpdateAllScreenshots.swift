import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Update all in the menu-bar panel and in Settings > Updates: the preview, a run in progress (one phone
/// downloading, one slow, one restarting), a finished run, and a phone that waits for its person.
/// Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter UpdateAllScreenshots
final class UpdateAllScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-4111-8111-111111111111"
    private let tabletID = "22222222-2222-4222-8222-222222222222"
    private let motoID = "33333333-3333-4333-8333-333333333333"
    private let galaxyID = "44444444-4444-4444-8444-444444444444"
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 16, minute: 5))!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func millis(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    private func phoneStatus(_ state: PeerUpdateState, app: String, build: Int, channel: UpdateChannel, target: String? = nil,
                             targetBuild: Int? = nil, checked: Date? = nil) -> PeerUpdateStatus {
        PeerUpdateStatus(platform: .android, edition: "rr", app: app, build: build, channel: channel, state: state, target: target,
                         targetBuild: targetBuild, remoteStart: true, checkedAt: millis(checked ?? now.addingTimeInterval(-600)))
    }

    private var macStatus: PeerUpdateStatus {
        PeerUpdateStatus(platform: .macos, edition: "rr", app: "0.9.0-rr.2", build: 902000, channel: .stable, state: .available,
                         target: "0.9.0-rr.3", targetBuild: 903000, remoteStart: true, checkedAt: millis(now.addingTimeInterval(-300)))
    }

    private var plan: UpdatePlan {
        UpdatePlan.make(local: macStatus, localName: "This Mac", phones: [
            UpdateAllPhone(id: phoneID, name: "OnePlus 11", connected: true, supportsUpdates: true,
                           status: phoneStatus(.available, app: "0.9.0-rr.3-beta.2", build: 903002, channel: .beta,
                                               target: "0.9.0-rr.3-beta.3", targetBuild: 903003)),
            UpdateAllPhone(id: tabletID, name: "Pixel Tablet", connected: true, supportsUpdates: true,
                           status: phoneStatus(.current, app: "0.9.0-rr.2", build: 902000, channel: .stable, checked: now.addingTimeInterval(-86_400))),
            UpdateAllPhone(id: motoID, name: "Moto g", connected: true, supportsUpdates: false, status: nil),
            UpdateAllPhone(id: galaxyID, name: "Galaxy S23", connected: false, supportsUpdates: false, status: nil),
        ], now: now)
    }

    private func item(_ id: String, _ name: String, local: Bool = false, from: String, fromBuild: Int, to: String?, toBuild: Int?,
                      channel: UpdateChannel, step: UpdateRunStep, started: TimeInterval = -40) -> UpdateRunItem {
        UpdateRunItem(id: id, name: name, isLocal: local, fromApp: from, fromBuild: fromBuild, targetApp: to, targetBuild: toBuild,
                      channel: channel, step: step, startedAt: now.addingTimeInterval(started), stepSince: now.addingTimeInterval(started))
    }

    private func run(_ phone: UpdateRunStep, _ tablet: UpdateRunStep, _ moto: UpdateRunStep, mac: UpdateRunStep, slowTablet: Bool = false) -> UpdateRun {
        UpdateRun(id: "run", startedAt: now.addingTimeInterval(-240), items: [
            item(phoneID, "OnePlus 11", from: "0.9.0-rr.3-beta.2", fromBuild: 903002, to: "0.9.0-rr.3-beta.3", toBuild: 903003, channel: .beta, step: phone),
            item(tabletID, "Pixel Tablet", from: "0.9.0-rr.2", fromBuild: 902000, to: "0.9.0-rr.3", toBuild: 903000, channel: .stable, step: tablet,
                 started: slowTablet ? -250 : -40),
            item(motoID, "Moto g", from: "0.9.0-rr.2", fromBuild: 902000, to: "0.9.0-rr.3", toBuild: 903000, channel: .stable, step: moto),
            item(UpdatePlan.localID, "This Mac", local: true, from: "0.9.0-rr.2", fromBuild: 902000, to: "0.9.0-rr.3", toBuild: 903000,
                 channel: .stable, step: mac),
        ], updatedAt: now)
    }

    private var states: [(String, UpdateAllDisplay)] {
        [
            ("preview", UpdateAllDisplay(plan: plan, run: nil, previewOpen: true, now: now)),
            ("progress", UpdateAllDisplay(plan: plan, run: run(.downloading(42), .checking, .restarting, mac: .ready, slowTablet: true), now: now)),
            ("done", UpdateAllDisplay(plan: plan, run: run(.done("0.9.0-rr.3-beta.3"), .done("0.9.0-rr.3"), .upToDate, mac: .done("0.9.0-rr.3")), now: now)),
            ("needs-you", UpdateAllDisplay(plan: plan, run: run(.needsUser(.confirm), .done("0.9.0-rr.3"), .restarting, mac: .ready), now: now)),
        ]
    }

    @MainActor func testPanel() throws {
        for scheme in [ColorScheme.light, .dark] {
            for (name, display) in states {
                var model = PanelModel()
                model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
                let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"), TrustedDeviceInfo(id: tabletID, name: "Pixel Tablet")]
                model.rings = deviceRings(trusted: trusted, peers: [], state: model.state)
                model.available = Set(BridgeyFeature.allCases)
                model.clipboardLine = "Room 2 at 4, bring the deck"
                model.now = now
                model.update = .available(UpdateOffer(version: "0.9.0-rr.3", notes: nil, downloaded: false, userInitiated: false))
                model.appVersion = "0.9.0-rr.2"
                model.updateAll = display
                let view = BrandRoot(reduceMotion: false) {
                    StreamPanelView(model: model, actions: PanelActions())
                }
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(24)
                .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
                try write(view, scheme: scheme, name: "mac-panel-update-all-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @MainActor func testSettings() throws {
        for scheme in [ColorScheme.light, .dark] {
            for (name, display) in states {
                var model = SettingsModel()
                model.deviceName = "Rahul\u{2019}s MacBook Pro"
                model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
                model.channel = .stable
                model.automaticallyChecks = true
                model.updatesAvailable = true
                model.canCheckForUpdates = true
                model.lastCheck = now.addingTimeInterval(-300)
                model.now = now
                model.shortVersion = "0.9.0-rr.2"
                model.updateFlow = name == "preview"
                    ? .available(UpdateOffer(version: "0.9.0-rr.3", notes: nil, downloaded: false, userInitiated: false))
                    : name == "done" ? .idle : .ready(version: "0.9.0-rr.3")
                if name == "done" { model.shortVersion = "0.9.0-rr.3" }
                model.updateAll = display
                model.remoteStartUpdates = true
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
                try write(view, scheme: scheme, name: "mac-update-all-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
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
