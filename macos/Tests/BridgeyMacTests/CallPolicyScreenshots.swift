import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Settings > Calls with "When another app asks to call", and the call confirmation alert with its
/// Don't ask again box, light and dark. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter CallPolicyScreenshots
final class CallPolicyScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render the call policy screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(BrandFont.isAvailable, "bundled fonts should load from Resources/Fonts")
    }

    private var callsModel: SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.trustedDevices = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
        model.rings = deviceRings(trusted: model.trustedDevices, peers: [], state: model.state)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.remoteFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.shortcutKeys = [.clipboard: "C", .call: "P", .link: "Off", .ping: "Off"]
        model.otherAppCallPolicy = .ask
        return model
    }

    @MainActor func testCallsPane() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                SettingsWindowView(model: callsModel, actions: SettingsActions(), pane: .constant(.calls))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            try write(view.padding(24).background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0)),
                      scheme: scheme, name: "mac-settings-calls-\(scheme == .dark ? "dark" : "light")")
        }
    }

    /// The real NSAlert, laid out and drawn into a bitmap without showing it. Skipped, never faked,
    /// when AppKit cannot draw it here.
    @MainActor func testConfirmationAlert() throws {
        _ = NSApplication.shared
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let alert = makeCallConfirmationAlert(number: "+91 98765 43210", phoneName: "OnePlus 11")
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            guard let frame = alert.window.contentView?.superview ?? alert.window.contentView else {
                throw XCTSkip("NSAlert has no content view to draw")
            }
            frame.frame = NSRect(origin: .zero, size: alert.window.frame.size)
            frame.layoutSubtreeIfNeeded()
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                throw XCTSkip("NSAlert cannot be drawn into a bitmap here")
            }
            // Draw under the alert's own appearance so the dynamic colours resolve.
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                frame.cacheDisplay(in: frame.bounds, to: rep)
            }
            guard let data = rep.representation(using: .png, properties: [:]) else { throw XCTSkip("no PNG data") }
            try data.write(to: directory.appendingPathComponent("mac-call-alert-\(name).png"))
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
