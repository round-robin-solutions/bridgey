import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Isolated model renders for visual review; no playback, sessions, installed-app state or
/// permissions are touched. RR CI can opt in with BRIDGEY_SCREENSHOT_DIR and retain the PNGs.
@MainActor
final class CallMediaScreenshots: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render call-media screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testCallsSettingsDesktop() throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in CallMediaMode.allCases {
                var model = SettingsModel()
                model.deviceName = "Linked Mac"
                model.trustedDevices = [TrustedDeviceInfo(id: "phone", name: "Linked phone")]
                model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
                model.deviceFeatures = ["phone": [.callQuiet: true]]
                model.callMediaMode = mode
                model.callMediaRestoration = mode == .pauseOnly ? .restoreSound : mode == .muteOnly ? .leaveAsIs : .restoreAndResume
                model.callMediaStatuses = ["phone": "1 paused, 0 muted · Some apps cannot be controlled"]
                model.callMediaCanRestoreSound = mode == .muteOnly
                if mode == .muteOnly {
                    model.callMediaRecovery = [CallMediaRecoveryItem(id: "owned-test-player", bundleID: MediaPlayer.musicBundleID,
                        originalVolume: 50, temporaryMute: true)]
                }
                let view = BrandRoot(reduceMotion: true) {
                    SettingsWindowView(model: model, actions: SettingsActions(), pane: .constant(.calls))
                        .frame(width: 880, height: 700)
                }.frame(width: 1440, height: 900)
                try write(view, scheme: scheme, name: "mac-call-media-settings-\(mode.rawValue)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testManualSourcePanelAt390() throws {
        for scheme in [ColorScheme.light, .dark] {
            for active in [false, true] {
                var model = PanelModel()
                model.state = .connected(deviceID: "phone", peerName: "Linked phone")
                model.available = Set(BridgeyFeature.allCases)
                model.callMediaEnabled = true
                model.callMediaManual = active
                model.rows = []
                let view = BrandRoot(reduceMotion: true) {
                    StreamPanelView(model: model, actions: PanelActions()).frame(width: 360)
                }.frame(width: 390, height: 844, alignment: .top)
                try write(view, scheme: scheme, name: "mac-call-media-manual-\(active ? "on" : "off")-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testTemporaryMuteRecoveryCard() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [590.0, 390.0] {
                var model = SettingsModel()
                model.globalFeatures[.callQuiet] = true
                model.callMediaMode = .muteOnly
                model.callMediaRestoration = .restoreSound
                model.callMediaCanRestoreSound = true
                model.callMediaRecovery = [CallMediaRecoveryItem(id: "fixture", bundleID: MediaPlayer.musicBundleID,
                    originalVolume: 50, temporaryMute: true)]
                let view = BrandRoot(reduceMotion: true) {
                    CallMediaSettingsCard(model: model, actions: SettingsActions())
                        .frame(width: width, alignment: .top)
                }
                try write(view, scheme: scheme,
                    name: "mac-call-media-recovery-\(Int(width))-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    /// Retain the exact owned-built helper beside native UI proof. Copying it is artifact
    /// preparation only: this test does not execute capture or claim permission/crash proof.
    func testNativeAcceptanceProbeArtifact() throws {
        let binary = Bundle(for: Self.self).bundleURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("CallMediaTapProbe")
        let attributes = try FileManager.default.attributesOfItem(atPath: binary.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1024 * 1024,
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("Owned native probe product is missing or outside its artifact bounds"); return
        }
        let native = directory.appendingPathComponent("native-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let destination = native.appendingPathComponent("CallMediaTapProbe")
        try FileManager.default.copyItem(at: binary, to: destination)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: repository.appendingPathComponent("scripts/rr/package-call-mute-probe.sh"),
            to: native.appendingPathComponent("package-call-mute-probe.sh"))
        let digest = SHA256.hash(data: try Data(contentsOf: destination)).map { String(format: "%02x", $0) }.joined()
        let manifest = ["source": ProcessInfo.processInfo.environment["RR_CI_REVISION"] ?? "unknown",
                        "binary": "CallMediaTapProbe", "sha256": digest,
                        "purpose": "Isolated native acceptance; does not prove recording permission or crash behavior by itself"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
            .write(to: native.appendingPathComponent("provenance.json"))
    }

    private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true).environment(\.locale, Locale(identifier: "en_GB")))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw XCTSkip("ImageRenderer produced no PNG")
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
