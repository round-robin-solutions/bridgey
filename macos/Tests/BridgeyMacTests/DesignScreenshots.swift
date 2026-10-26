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
    }

    @MainActor func testSettings() throws {
        for pane in SettingsPane.allCases {
            try render(settings: settingsModel, pane: pane, scheme: .dark, name: "settings-dark-\(pane.rawValue)")
            try render(settings: settingsModel, pane: pane, scheme: .light, name: "settings-light-\(pane.rawValue)")
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
