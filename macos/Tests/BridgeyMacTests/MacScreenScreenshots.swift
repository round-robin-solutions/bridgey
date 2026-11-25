import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Mac screen to phone: the Remote control pane with This Mac's screen (a viewer active, one phone on Ask each
/// time, Screen Recording missing), the Ask each time prompt and the pill, light and dark. Runs only when
/// BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter MacScreenScreenshots
final class MacScreenScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor func testRemoteControlPaneWithThisMacsScreen() throws {
        var model = SettingsModel()
        model.state = .connected(deviceID: phoneID, peerName: "Pixel 9")
        model.trustedDevices = [TrustedDeviceInfo(id: phoneID, name: "Pixel 9"), TrustedDeviceInfo(id: tabletID, name: "Pixel Tablet")]
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.deviceFeatures = [phoneID: [.remoteInput: true]]
        model.accessibilityTrusted = true
        model.screenGrants = [phoneID: .always, tabletID: .ask]
        model.screenDisplays = [ScreenDisplayChoice(id: 1, name: "Built-in Retina Display"), ScreenDisplayChoice(id: 2, name: "Studio Display")]
        model.screenDisplayID = 1
        model.screenRecordingAllowed = false
        model.screenSession = MacScreenShare.Session(deviceID: phoneID, deviceName: "Pixel 9", controlling: true,
                                                     startedAt: Date(timeIntervalSince1970: 1_795_000_000))
        model.phoneScreenControl = [phoneID: true]
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
            try write(view, scheme: scheme, name: "mac-display-settings-\(suffix(scheme))")
        }
    }

    @MainActor func testPromptAndPill() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: true) {
                VStack(alignment: .leading, spacing: 20) {
                    DisplayConsentPrompt(deviceName: "Pixel 9", blocked: false, allow: {}, deny: {})
                    DisplayConsentPrompt(deviceName: "Pixel 9", blocked: true, allow: {}, deny: {})
                    RemoteControlPill(title: String(format: L10n.text("display.pill.viewing", fallback: "%@ is viewing this screen"), "Pixel 9"),
                                      symbol: "rectangle.on.rectangle", onStop: {})
                    RemoteControlPill(title: String(format: L10n.text("display.pill.controlling", fallback: "%@ is viewing and controlling this screen"), "Pixel 9"),
                                      symbol: "cursorarrow.rays", onStop: {})
                }
                .padding(28)
                .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
            }
            try write(view, scheme: scheme, name: "mac-display-prompt-and-pill-\(suffix(scheme))")
        }
    }

    private func suffix(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

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
