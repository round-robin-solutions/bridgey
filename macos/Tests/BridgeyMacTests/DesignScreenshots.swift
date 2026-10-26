import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Renders the panel and Settings with ImageRenderer from sample state matching
/// outputs/bridgey/design/direction-b.png. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter DesignScreenshots
final class DesignScreenshots: XCTestCase {
    private var directory: URL!
    private let calendar = Calendar.current
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 41))!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(BrandFont.isAvailable, "bundled fonts should load from Resources/Fonts")
    }

    // MARK: Sample state

    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"

    private func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: hour, minute: minute))!
    }

    private func item(_ id: Int64, _ kind: ActivityKind, _ date: Date, preview: String? = nil, app: String? = nil, file: String? = nil, count: Int = 1, automatic: Bool = false) -> ActivityItem {
        ActivityItem(id: id, kind: kind, deviceID: phoneID, deviceName: "OnePlus 11", fileName: file, preview: preview, appName: app,
                     sensitive: false, automatic: automatic, count: count, at: date)
    }

    private var sampleItems: [ActivityItem] {
        [
            item(6, .clipboardReceived, now.addingTimeInterval(-15), preview: "Room 2 at 4, bring the deck"),
            item(5, .callShown, at(9, 40), preview: "Mum"),
            item(4, .fileSent, at(9, 12), file: "invoice-oct.pdf"),
            item(3, .notificationsShown, at(8, 55), app: "WhatsApp", count: 4),
            item(2, .linkReceived, at(8, 50)),
            item(1, .clipboardSent, calendar.date(byAdding: .day, value: -1, to: at(18, 20))!, preview: "Flight lands 6:40, gate B12", automatic: true),
        ]
    }

    private var trusted: [TrustedDeviceInfo] {
        [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"), TrustedDeviceInfo(id: tabletID, name: "Pixel Tablet")]
    }

    private func peer(_ id: String, _ name: String) -> DiscoveredPeer {
        DiscoveredPeer(serviceName: name, deviceIDHint: id, deviceNameHint: name, platformHint: "android", protocolVersionHint: 1, host: "10.0.0.2", port: 4000)
    }

    private var connectedModel: PanelModel {
        var model = PanelModel()
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.rings = deviceRings(trusted: trusted, peers: [peer(phoneID, "OnePlus 11"), peer(tabletID, "Pixel Tablet")], state: model.state)
        model.battery = RemoteBatteryStatus(level: 76, isCharging: true)
        model.rows = streamRows(sampleItems, now: now)
        model.now = now
        model.available = Set(BridgeyFeature.allCases)
        model.clipboardLine = "Room 2 at 4, bring the deck"
        model.mediaPlayer = .music
        model.autoClipboard = true
        return model
    }

    private var offlineModel: PanelModel {
        var model = PanelModel()
        model.state = .idle
        model.rings = deviceRings(trusted: trusted, peers: [], state: .idle)
        model.rows = streamRows(sampleItems, now: now)
        model.now = now
        model.clipboardLine = "Room 2 at 4, bring the deck"
        return model
    }

    /// The bug Rahul reported: the phone dropped at 02:56 and Bridgey keeps retrying it.
    private func reconnectingModel(struggling: Bool, single: Bool) -> PanelModel {
        var model = PanelModel()
        model.state = .idle
        let devices = single ? Array(trusted.prefix(1)) : trusted
        model.rings = deviceRings(trusted: devices, peers: [], connected: [], pairing: .idle,
                                  reconnecting: [phoneID: ReconnectDisplay(lastSeen: at(2, 56), struggling: struggling)])
        model.rows = streamRows(sampleItems, now: now)
        model.now = now
        model.clipboardLine = "Room 2 at 4, bring the deck"
        model.status = struggling ? nil : "Looking for devices\u{2026}"
        model.rediscovering = !struggling
        return model
    }

    private var liveModel: PanelModel {
        var model = connectedModel
        model.call = RemoteCallStatus(notificationID: "n", deviceID: phoneID, applicationName: "Phone", caller: "Mum", detail: "",
                                      type: "incoming", actions: [RemoteCallAction(id: "a", title: "Answer"), RemoteCallAction(id: "d", title: "Decline")])
        model.receivedLink = "https://roundrobin.in/bridgey"
        model.transfers = [FileTransferRow(id: "t", name: "holiday-photos.zip", status: "Sending holiday-photos.zip: 42% (18.4 MB of 43.7 MB)", active: true)]
        model.rows = Array(model.rows.prefix(4))
        return model
    }

    private var pairingModel: PanelModel {
        var model = PanelModel()
        model.state = .verification(peerName: "Galaxy S24", code: "482 913")
        model.pairingFlow = model.state
        model.rings = deviceRings(trusted: [], peers: [peer("33333333-3333-3333-3333-333333333333", "Galaxy S24")], state: model.state)
        model.now = now
        return model
    }

    private var failureModel: PanelModel {
        var model = PanelModel()
        model.state = .failed("Bridgey needs Local Network access. Allow it in System Settings, then try again.")
        model.pairingFlow = model.state
        model.rings = deviceRings(trusted: trusted, peers: [], state: .idle)
        model.now = now
        model.notificationPrompt = .request
        return model
    }

    private func updateModel(_ flow: UpdateFlow) -> PanelModel {
        var model = connectedModel
        model.update = flow
        model.appVersion = "0.6.0-rr.1-beta.9"
        return model
    }

    private var updateSettingsModel: SettingsModel {
        updatesModel(.available(longOffer))
    }

    /// Notes as rrrelease.py publishes them: a version heading, then one paragraph per Markdown line.
    private var longOffer: UpdateOffer {
        let lines = [
            "- Settings > Updates is one status card: what you have, what is ready, and one main button.",
            "- Release notes show as a list with Show all, and the full notes are one click away.",
            "- The menu bar card says beta.10 ready, then Restart to update.",
            "- Skip this version moved into the ⋯ menu.",
            "- One Keychain question per update instead of two.",
            "- Reconnects after sleep no longer wait for the next",
            "  discovery round.",
            "## Fixes",
            "- Several phones at once no longer fight over the clipboard.",
            "- The Files window remembers its size.",
        ]
        let html = "<h2>0.6.0-rr.1-beta.10</h2>" + lines.map { "<p>\($0)</p>" }.joined()
        return UpdateOffer(version: "0.6.0-rr.1-beta.10", notes: UpdateFlowText.plainNotes(html), downloaded: false, userInitiated: true,
                           notesURL: URL(string: "https://github.com/round-robin-solutions/bridgey/releases/tag/v0.6.0-rr.1-beta.10"))
    }

    private func updatesModel(_ flow: UpdateFlow, deferral: UpdateDeferral? = nil) -> SettingsModel {
        var model = settingsModel
        model.shortVersion = "0.6.0-rr.1-beta.9"
        model.versionDescription = "0.6.0-rr.1-beta.9 (69)"
        model.channel = .beta
        model.lastCheck = at(9, 30)
        model.updateFlow = flow
        model.updateDeferral = deferral
        return model
    }

    private var welcomeModel: PanelModel {
        var model = PanelModel()
        model.onboardingDone = false
        model.now = now
        return model
    }

    private var settingsModel: SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.trustedDevices = trusted
        model.rings = deviceRings(trusted: trusted, peers: [peer(phoneID, "OnePlus 11"), peer(tabletID, "Pixel Tablet")], state: model.state)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, $0 != .media) })
        model.remoteFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.launchAtLogin = true
        model.receiveFolderPath = NSHomeDirectory() + "/Downloads/Bridgey"
        model.shortcutKeys = [.clipboard: "C", .call: "P", .link: "Off", .ping: "Off"]
        model.mediaPlayer = .music
        model.pauseForCalls = true
        model.activityCount = 6
        model.channel = .stable
        model.automaticallyChecks = true
        model.lastCheck = at(9, 30)
        model.updatesAvailable = true
        model.canCheckForUpdates = true
        model.shortVersion = "0.6.0"
        model.versionDescription = "0.6.0 (60)"
        model.now = now
        // Remote control: on, granted to the phone, a session running, and a short log.
        model.deviceFeatures = [phoneID: [.remoteInput: true]]
        model.accessibilityTrusted = true
        model.remoteSession = RemoteInputHost.ActiveSession(inputSessionID: "s", deviceID: phoneID, deviceName: "OnePlus 11",
                                                            mode: .presentation, startedAt: at(9, 30))
        model.remoteAudit = [
            RemoteControlAuditEntry(id: "1", deviceID: phoneID, deviceName: "OnePlus 11", mode: "touchpad", accepted: true,
                                    startedAt: at(8, 2), endedAt: at(8, 14).addingTimeInterval(37), endReason: "local_stop",
                                    counts: ["pointer": 2140, "button": 36, "scroll": 48, "key": 12, "text": 3], dropped: 0, rejected: 0),
            RemoteControlAuditEntry(id: "2", deviceID: tabletID, deviceName: "Pixel Tablet", mode: "presentation", accepted: false,
                                    startedAt: at(7, 50), endedAt: at(7, 50), endReason: "disabled", counts: [:], dropped: 0, rejected: 0),
            RemoteControlAuditEntry(id: "3", deviceID: phoneID, deviceName: "OnePlus 11", mode: "presentation", accepted: true,
                                    startedAt: calendar.date(byAdding: .day, value: -1, to: at(16, 0))!,
                                    endedAt: calendar.date(byAdding: .day, value: -1, to: at(16, 41))!, endReason: "user",
                                    counts: ["present": 64], dropped: 0, rejected: 0),
        ]
        return model
    }

    private var remoteOffModel: SettingsModel {
        var model = settingsModel
        model.globalFeatures[.remoteInput] = false
        model.deviceFeatures = [:]
        model.accessibilityTrusted = false
        model.remoteSession = nil
        model.remoteAudit = []
        return model
    }

    // MARK: Rendering

    @MainActor func testPanels() throws {
        try render(panel: connectedModel, scheme: .dark, name: "panel-dark-connected")
        try render(panel: connectedModel, scheme: .light, name: "panel-light-connected")
        try render(panel: offlineModel, scheme: .light, name: "panel-light-offline")
        try render(panel: offlineModel, scheme: .dark, name: "panel-dark-offline")
        try render(panel: liveModel, scheme: .dark, name: "panel-dark-live-cards")
        try render(panel: liveModel, scheme: .light, name: "panel-light-live-cards")
        try render(panel: pairingModel, scheme: .light, name: "panel-light-pairing-code")
        try render(panel: failureModel, scheme: .dark, name: "panel-dark-failure")
        try render(panel: welcomeModel, scheme: .light, name: "panel-light-welcome")
        try render(panel: reconnectingModel(struggling: false, single: true), scheme: .light, name: "panel-light-reconnecting")
        try render(panel: reconnectingModel(struggling: true, single: true), scheme: .dark, name: "panel-dark-cant-reach")
        try render(panel: reconnectingModel(struggling: true, single: false), scheme: .light, name: "panel-light-cant-reach-two")
        var searching = welcomeModel
        searching.onboardingDone = true
        try render(panel: searching, scheme: .dark, name: "panel-dark-searching")
    }

    @MainActor func testReconnectingSettings() throws {
        var model = settingsModel
        model.state = .idle
        model.rings = deviceRings(trusted: trusted, peers: [], connected: [], pairing: .idle,
                                  reconnecting: [phoneID: ReconnectDisplay(lastSeen: at(2, 56), struggling: true)])
        model.rediscoverStatus = "Still can\u{2019}t reach OnePlus 11"
        try render(settings: model, pane: .devices, scheme: .light, name: "settings-light-devices-reconnecting")
        var storeIssue = offlineModel
        storeIssue.pairingStoreIssue = .keychainAccessDenied(-128)
        try render(panel: storeIssue, scheme: .light, name: "panel-light-pairing-store-keychain")
    }

    /// Settings > Updates in every state, plus the Stream panel's update card, light and dark,
    /// at the Settings window's real size (880 x 600).
    @MainActor func testUpdatesPaneStates() throws {
        let beta10 = "0.6.0-rr.1-beta.10"
        let states: [(String, SettingsModel)] = [
            ("up-to-date", updatesModel(.idle)),
            ("available", updatesModel(.available(longOffer))),
            ("checking", updatesModel(.checking)),
            ("downloading", updatesModel(.downloading(version: beta10, received: 6_400_000, expected: 15_200_000))),
            ("ready", updatesModel(.ready(version: beta10))),
            ("installing", updatesModel(.installing(version: beta10))),
            ("error", updatesModel(.failed(message: UpdateFlowText.errorMessage(domain: NSURLErrorDomain, code: -1009)))),
            ("later", updatesModel(.idle, deferral: UpdateDeferral(version: beta10, kind: .later))),
        ]
        for (name, model) in states {
            let height = try paneHeight(model, pane: .updates)
            let room = SettingsWindowView.size.height - 40  // the window footer
            XCTAssertLessThanOrEqual(height, room, "\(name): the Updates pane needs \(height) pt but the window has \(room) pt")
            print("updates pane \(name): \(height) of \(room) pt")
            for scheme in [ColorScheme.light, .dark] {
                try render(settings: model, pane: .updates, scheme: scheme, name: "mac-updates-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
        let panelStates: [(String, UpdateFlow)] = [
            ("available", .available(longOffer)),
            ("downloading", .downloading(version: beta10, received: 6_400_000, expected: 15_200_000)),
            ("ready", .ready(version: beta10)),
            ("error", .failed(message: UpdateFlowText.errorMessage(domain: NSURLErrorDomain, code: -1009))),
        ]
        for (name, flow) in panelStates {
            for scheme in [ColorScheme.light, .dark] {
                try render(panel: updateModel(flow), scheme: scheme, name: "mac-panel-update-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @MainActor func testSettings() throws {
        for pane in SettingsPane.allCases {
            try render(settings: settingsModel, pane: pane, scheme: .dark, name: "settings-dark-\(pane.rawValue)")
            try render(settings: settingsModel, pane: pane, scheme: .light, name: "settings-light-\(pane.rawValue)")
        }
        try render(settings: updateSettingsModel, pane: .updates, scheme: .dark, name: "settings-dark-updates-available")
        try render(settings: updateSettingsModel, pane: .updates, scheme: .light, name: "settings-light-updates-available")
    }

    /// Remote control before it is set up: off, no Accessibility, nothing granted.
    @MainActor func testRemoteControlSettingsOff() throws {
        try render(settings: remoteOffModel, pane: .remoteControl, scheme: .light, name: "settings-light-remoteControl-off")
        try render(settings: remoteOffModel, pane: .remoteControl, scheme: .dark, name: "settings-dark-remoteControl-off")
    }

    /// The whole Remote control pane at its natural height (the window scrolls it), for review.
    @MainActor func testRemoteControlPaneFull() throws {
        for scheme in [ColorScheme.dark, .light] {
            let view = BrandRoot(reduceMotion: false) {
                VStack(alignment: .leading, spacing: 16) {
                    RemoteControlPane(model: settingsModel, actions: SettingsActions())
                }
                .padding(32)
                .frame(width: 670)
                .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            }
            try write(view, scheme: scheme, name: "settings-\(scheme == .dark ? "dark" : "light")-remoteControl-full")
        }
    }

    /// The pill at the top of the screen while a phone controls this Mac, over a slide.
    @MainActor func testRemoteControlPill() throws {
        for scheme in [ColorScheme.dark, .light] {
            let view = BrandRoot(reduceMotion: false) {
                RemoteControlPillScene(scheme: scheme)
            }
            try write(view, scheme: scheme, name: "remote-pill-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor private func render(panel model: PanelModel, scheme: ColorScheme, name: String) throws {
        let view = BrandRoot(reduceMotion: false) {
            StreamPanelView(model: model, actions: PanelActions())
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(1)
        try write(Desk(scheme: scheme) { view }, scheme: scheme, name: name)
    }

    @MainActor private func render(settings model: SettingsModel, pane: SettingsPane, scheme: ColorScheme, name: String) throws {
        let view = BrandRoot(reduceMotion: false) {
            SettingsWindowView(model: model, actions: SettingsActions(), pane: .constant(pane))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        try write(view.padding(24).background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0)), scheme: scheme, name: name)
    }

    /// The scrolling column's natural height (title, pane and paddings) at the window's width.
    @MainActor private func paneHeight(_ model: SettingsModel, pane: SettingsPane) throws -> CGFloat {
        let view = BrandRoot(reduceMotion: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text(pane.title).font(BrandFont.heading(24)).frame(height: 30)
                SettingsPaneView(pane: pane, model: model, actions: SettingsActions())
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(width: SettingsWindowView.size.width - 210, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        let renderer = ImageRenderer(content: view.environment(\.snapshotRendering, true))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        return CGFloat(image.height)
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

/// A slice of desktop with the menu bar above the panel, as in the design board.
private struct Desk<Content: View>: View {
    let scheme: ColorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 16) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)))
                Image(systemName: "wifi").font(.system(size: 13))
                Image(systemName: "battery.75percent").font(.system(size: 14))
                Text("Sat 25 Oct 9:41").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(scheme == .dark ? Color(hex: 0xF4F7FA) : Color(hex: 0x050B18))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: 28)
            .background(scheme == .dark ? Color(hex: 0x050B18).opacity(0.55) : Color.white.opacity(0.6))
            content
                .compositingGroup()
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.25), radius: 16, y: 10)
                .padding(.trailing, 12)
                .padding(.bottom, 28)
        }
        .frame(width: 400)
        .background(
            ZStack {
                scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0)
                RadialGradient(colors: [BrandPalette.auroraPurple.opacity(scheme == .dark ? 0.35 : 0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
                RadialGradient(colors: [BrandPalette.auroraBlue.opacity(scheme == .dark ? 0.22 : 0.18), .clear], center: UnitPoint(x: 1, y: 0.3), startRadius: 0, endRadius: 420)
            }
        )
    }
}

/// The top of a screen during a slideshow: menu bar, the pill, a slide and the laser dot.
private struct RemoteControlPillScene: View {
    let scheme: ColorScheme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Spacer()
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)))
                Image(systemName: "wifi").font(.system(size: 13))
                Text("Sat 25 Oct 9:41").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(scheme == .dark ? Color(hex: 0xF4F7FA) : Color(hex: 0x050B18))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(scheme == .dark ? Color(hex: 0x050B18).opacity(0.55) : Color.white.opacity(0.6))
            RemoteControlPill(deviceName: "OnePlus 11", mode: .presentation, onStop: {})
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Q3 roadmap").font(.system(size: 30, weight: .bold)).foregroundStyle(Color(hex: 0x050B18))
                    Text("Ship remote input, then Files 2.0").font(.system(size: 17)).foregroundStyle(Color(hex: 0x4C5262))
                }
                .padding(28)
                RemoteLaserDot().offset(x: 420, y: 96)
            }
            .frame(width: 760, height: 220)
            .padding(.bottom, 20)
        }
        .frame(width: 860)
        .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
    }
}
