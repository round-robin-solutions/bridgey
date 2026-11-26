import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Settings search in each state, and every group, light and dark, at the window's real size (880 x 600); every group
/// also at its full height. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
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
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        model.deviceFeatures = [tabletID: [.clipboard: false, .notifications: false], phoneID: [.remoteInput: true]]
        model.notificationsAuthorized = true
        model.receiveFolderPath = "/Users/rb/Downloads/Bridgey"
        model.accessibilityTrusted = true
        model.screenRecordingAllowed = true
        model.screenDisplays = [ScreenDisplayChoice(id: 1, name: "Built-in Retina Display")]
        model.screenDisplayID = 1
        model.mediaPlayer = .automatic
        model.updatesAvailable = true
        model.canCheckForUpdates = true
        model.lastCheck = Date(timeIntervalSince1970: 1_795_000_000)
        model.setup.permissions = SetupPermission.allCases.map {
            PermissionStatus(permission: $0, system: $0 == .notifications ? .allowed : .notDetermined, needed: PermissionNeeds().needed($0))
        }
        model.agents = AgentsDisplay(phones: [phoneID: AgentsMirrorPhoneState(agents: [
            AgentDevice(deviceId: "agent-1", name: "Contabo Europe", platform: "cli", app: "bridgey 0.2.0", os: "linux x86_64",
                        pairedAt: 1, online: true, grants: [], activity: []),
        ], receivedAt: Date())], live: [phoneID])
        return model
    }

    func testSearchStates() throws {
        let codes = SettingsSearchTarget(group: .phone, scope: nil, title: L10n.text("codes.toggle", fallback: "Show codes from text messages"), card: .codes)
        // A row inside More options: the jump opens them, then highlights it.
        let eager = SettingsSearchTarget(group: .sharing, scope: nil, title: L10n.text("settings.clipboardEager", fallback: "Send right away up to"),
                                         card: .clipboard, expand: .clipboard)
        let states: [(String, SettingsGroup, String, Int, SettingsSearchTarget?, Bool)] = [
            ("typing", .devices, "ot", 0, nil, true),
            ("results-otp", .devices, "otp", 1, nil, true),
            ("results-relay", .devices, "relay", 0, nil, true),
            ("results-russian", .devices, "обновление", 0, nil, true),
            ("results-device", .devices, "oneplus", 0, nil, true),
            ("no-results", .devices, "dark mode", 0, nil, true),
            ("highlighted-row", .phone, "otp", 0, codes, false),
            ("more", .sharing, "send right away", 0, eager, false),
        ]
        for (name, group, query, selection, target, focus) in states {
            for scheme in [ColorScheme.light, .dark] {
                try write(window(group: group, query: query, selection: selection, target: target, focus: focus, scheme: scheme),
                          scheme: scheme, name: "mac-search-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    /// Every group: the window as it opens, and the whole group at its natural height (the window scrolls it).
    func testGroups() throws {
        for group in SettingsGroup.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                try write(window(group: group, scheme: scheme), scheme: scheme, name: "mac-\(group.rawValue)-\(suffix)")
                let full = BrandRoot(reduceMotion: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(group.title).font(BrandFont.heading(24)).frame(height: 30)
                        SettingsGroupView(group: group, model: model, actions: SettingsActions())
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(width: SettingsWindowView.size.width - 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
                }
                try write(full, scheme: scheme, name: "mac-\(group.rawValue)-full-\(suffix)")
            }
        }
    }

    private func window(group: SettingsGroup, query: String = "", selection: Int = 0, target: SettingsSearchTarget? = nil, focus: Bool = false,
                        scheme: ColorScheme) -> some View {
        let view = BrandRoot(reduceMotion: false) {
            SettingsWindowView(model: model, actions: SettingsActions(), group: .constant(group),
                               searchQuery: query, searchSelection: selection, searchTarget: target, showsSearchFocus: focus)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        return view.padding(24).background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
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
