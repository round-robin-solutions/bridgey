import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Settings search in each state, light and dark, at the window's real size (880 x 600). Runs only when
/// BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter SettingsSearchScreenshots
@MainActor
final class SettingsSearchScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(BrandFont.isAvailable, "bundled fonts should load from Resources/Fonts")
    }

    private var model: SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"), TrustedDeviceInfo(id: tabletID, name: "Pixel Tablet")]
        model.trustedDevices = trusted
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.rings = deviceRings(trusted: trusted, peers: [], state: model.state)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, !$0.needsDeviceGrant) })
        model.codesEnabled = true
        model.codesEmail = true
        model.shortVersion = "0.2.0"
        model.versionDescription = "0.2.0 (beta 22)"
        model.connect = ConnectDisplay(available: true, controlConfigured: true, running: true, presence: "online")
        model.connectAway = true
        model.agents = AgentsDisplay(phones: [phoneID: AgentsMirrorPhoneState(agents: [
            AgentDevice(deviceId: "agent-1", name: "Contabo Europe", platform: "cli", app: "bridgey 0.2.0", os: "linux x86_64",
                        pairedAt: 1, online: true, grants: [], activity: []),
        ], receivedAt: Date())], live: [phoneID])
        return model
    }

    func testSearchStates() throws {
        let codes = SettingsSearchTarget(pane: .notifications, scope: nil, title: L10n.text("codes.toggle", fallback: "Show codes from text messages"))
        let states: [(String, SettingsPane, String, Int, SettingsSearchTarget?, Bool)] = [
            ("typing", .devices, "ot", 0, nil, true),
            ("results-otp", .devices, "otp", 1, nil, true),
            ("results-relay", .devices, "relay", 0, nil, true),
            ("results-russian", .devices, "обновление", 0, nil, true),
            ("results-device", .devices, "oneplus", 0, nil, true),
            ("no-results", .devices, "dark mode", 0, nil, true),
            ("highlighted-row", .notifications, "otp", 0, codes, false),
        ]
        for (name, pane, query, selection, target, focus) in states {
            for scheme in [ColorScheme.light, .dark] {
                let view = BrandRoot(reduceMotion: false) {
                    SettingsWindowView(model: model, actions: SettingsActions(), pane: .constant(pane),
                                       searchQuery: query, searchSelection: selection, searchTarget: target, showsSearchFocus: focus)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                try write(view.padding(24).background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0)),
                          scheme: scheme, name: "mac-search-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
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
