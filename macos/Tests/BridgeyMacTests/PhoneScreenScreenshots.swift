import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Phone screen to Mac: the window (live and ended), the panel while waiting for the phone, and the
/// Remote control pane with Show phone screens, light and dark. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter PhoneScreenScreenshots
final class PhoneScreenScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let calendar = Calendar.current

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var stats: ScreenStats {
        ScreenStats(streamID: "6c2e9a14-3b5d-4e7f-8a90-1b2c3d4e5f60", sequence: 40, latencyMs: 48, rttMs: 6, bitrate: 4_000_000,
                    sentBitrate: 2_100_000, fps: 30, dropped: 0)
    }

    @MainActor func testWindow() throws {
        for scheme in [ColorScheme.light, .dark] {
            let live = PhoneScreenWindowModel(phoneName: "OnePlus 11")
            live.stats = stats
            live.hasFrame = true
            try write(window(live), scheme: scheme, name: "mac-screen-window-\(suffix(scheme))")
            let ended = PhoneScreenWindowModel(phoneName: "OnePlus 11")
            ended.hasFrame = true
            ended.endedMessage = screenEndedText(.user, phone: "OnePlus 11")
            try write(window(ended), scheme: scheme, name: "mac-screen-window-ended-\(suffix(scheme))")
        }
    }

    @MainActor func testPanelWaitingForThePhone() throws {
        var model = PanelModel()
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
        let peer = DiscoveredPeer(serviceName: "OnePlus 11", deviceIDHint: phoneID, deviceNameHint: "OnePlus 11", platformHint: "android",
                                  protocolVersionHint: 1, host: "10.0.0.2", port: 4000)
        model.rings = deviceRings(trusted: trusted, peers: [peer], state: model.state)
        model.battery = RemoteBatteryStatus(level: 76, isCharging: true)
        model.now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 41))!
        model.available = Set(BridgeyFeature.allCases)
        model.screenPhones = [phoneID]
        model.screenPhone = "OnePlus 11"
        model.status = screenStatusText(.waiting, phone: "OnePlus 11")
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                StreamPanelView(model: model, actions: PanelActions())
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(24)
            .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
            try write(view, scheme: scheme, name: "mac-screen-panel-waiting-\(suffix(scheme))")
        }
    }

    @MainActor func testRemoteControlPaneWithPhoneScreen() throws {
        var model = SettingsModel()
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.trustedDevices = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, $0 != .remoteInput) })
        model.phoneScreenEnabled = true
        model.accessibilityTrusted = false
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(SettingsPane.remoteControl.title).font(BrandFont.heading(24)).frame(height: 30)
                    SettingsPaneView(pane: .remoteControl, model: model, actions: SettingsActions())
                }
                .padding(32)
                .frame(width: 670, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            }
            try write(view, scheme: scheme, name: "mac-screen-settings-remote-control-\(suffix(scheme))")
        }
    }

    // MARK: Helpers

    private func suffix(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    /// The window at 405 by 900 points of video, with a title bar like macOS draws it.
    @MainActor private func window(_ model: PhoneScreenWindowModel) -> some View {
        BrandRoot(reduceMotion: true) {
            VStack(spacing: 0) {
                TitleBar(title: String(format: L10n.text("screen.window.title", fallback: "%@ screen"), model.phoneName))
                PhoneScreenWindowContent(model: model, stop: {}) {
                    SamplePhoneScreen().frame(width: 405, height: 900)
                }
                .frame(width: 405, height: 900 + PhoneScreenHeader.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(28)
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

private struct TitleBar: View {
    let title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.85))
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                Spacer()
            }
            .padding(.leading, 12)
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(scheme == .dark ? Color(hex: 0x2B2D31) : Color(hex: 0xE9E9EB))
    }
}

/// A stand-in for a decoded phone frame: a home screen with a clock and app tiles.
private struct SamplePhoneScreen: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x1B2A4A), Color(hex: 0x3B2F6B), Color(hex: 0x0E5A6E)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                HStack {
                    Text("9:41").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: 12))
                    Image(systemName: "battery.75percent").font(.system(size: 13))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.top, 12)
                Text("9:41").font(.system(size: 72, weight: .light)).foregroundStyle(.white).padding(.top, 70)
                Text("Tuesday, 27 October").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                let colors: [UInt32] = [0x54C7F5, 0x5EF2B2, 0x9B7CFF, 0xFFB4A8, 0xF4F7FA, 0x6AD3FF, 0xCDBDFF, 0x5EF2B2]
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 26), count: 4), spacing: 28) {
                    ForEach(colors.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: colors[index]).opacity(0.9)).frame(width: 64, height: 64)
                    }
                }
                .padding(.bottom, 56)
                Capsule().fill(.white.opacity(0.7)).frame(width: 120, height: 5).padding(.bottom, 10)
            }
        }
    }
}
