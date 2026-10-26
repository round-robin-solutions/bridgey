import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Codes from messages > On this Mac, rendered with ImageRenderer from sample state, light and dark.
/// Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter CodeModelScreenshots
final class CodeModelScreenshots: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private let manifest = CodeModelManifest(
        schema: 1, version: 1, name: "Gemma 3 270M, fine-tuned for codes (Q4_K_M)",
        url: "https://github.com/round-robin-solutions/bridgey/releases/download/models/bridgey-otp-v1.gguf",
        size: 253_115_200, sha256: String(repeating: "a", count: 64), termsVersion: "gemma-2026-04-01+pup-2024-02-21+bridgey-1",
        licenceURL: "https://ai.google.dev/gemma/terms", prohibitedUseURL: "https://ai.google.dev/gemma/prohibited_use_policy"
    )

    private var installed: InstalledCodeModel {
        InstalledCodeModel(version: 1, name: manifest.name, size: manifest.size, sha256: manifest.sha256, fileName: manifest.fileName,
                           installedAt: Date(timeIntervalSince1970: 1_793_000_000))
    }

    private func settings(_ change: (inout CodeModelDisplay) -> Void) -> SettingsModel {
        var model = SettingsModel()
        model.state = .connected(deviceID: "11111111-1111-1111-1111-111111111111", peerName: "OnePlus 11")
        model.codesEnabled = true
        model.codesEngine = .local
        model.codeAccess = .status(.allowed)
        var display = CodeModelDisplay()
        display.manifest = manifest
        display.availableSpace = 51_300_000_000
        change(&display)
        model.codeModel = display
        return model
    }

    private var downloading: CodeModelDownload {
        CodeModelDownload(manifest: manifest, received: 112_400_000, state: .running, bytesPerSecond: 8_400_000, secondsLeft: 16.8)
    }

    @MainActor func testCodesSettingsStates() throws {
        var off = settings { _ in }
        off.codesEnabled = false
        let states: [(String, SettingsModel)] = [
            ("not-downloaded", off),
            ("downloading", settings { $0.download = downloading }),
            ("paused", settings { $0.download = CodeModelDownload(manifest: manifest, received: 112_400_000, state: .paused) }),
            ("error-offline", settings { $0.download = CodeModelDownload(manifest: manifest, received: 112_400_000, state: .failed(.offline)) }),
            ("error-space", settings { $0.download = CodeModelDownload(manifest: manifest, received: 0, state: .failed(.noSpace(needed: 253_115_200, available: 120_000_000))) }),
            ("error-checksum", settings { $0.download = CodeModelDownload(manifest: manifest, received: 0, state: .failed(.checksum)) }),
            ("ready", settings {
                $0.installed = installed
                $0.testResult = CodeModelTestResult(code: "482913", seconds: 0.11, loaded: false, failed: false)
            }),
            ("update", settings {
                $0.installed = installed
                $0.update = CodeModelManifest(schema: 1, version: 2, name: manifest.name, url: manifest.url, size: 254_000_000, sha256: manifest.sha256,
                                              termsVersion: manifest.termsVersion, licenceURL: manifest.licenceURL, prohibitedUseURL: manifest.prohibitedUseURL)
            }),
            ("cloud", {
                var model = settings { _ in }
                model.codesEngine = .cloud
                return model
            }()),
        ]
        for (name, model) in states {
            for scheme in [ColorScheme.light, .dark] {
                let view = BrandRoot(reduceMotion: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(SettingsPane.notifications.title).font(BrandFont.heading(24)).frame(height: 30)
                        CodesCard(model: model, actions: SettingsActions())
                    }
                    .padding(32)
                    .frame(width: 670, alignment: .leading)
                    .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
                }
                try write(view, scheme: scheme, name: "codes-settings-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @MainActor func testDownloadSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            var display = CodeModelDisplay()
            display.manifest = manifest
            display.availableSpace = 51_300_000_000
            let ticked = BrandRoot(reduceMotion: false) {
                CodeModelDownloadSheet(model: display, openURL: { _ in }, cancel: {}, download: {}, initiallyAccepted: true)
            }
            try write(ticked, scheme: scheme, name: "codes-sheet-accepted-\(scheme == .dark ? "dark" : "light")")
            let unticked = BrandRoot(reduceMotion: false) {
                CodeModelDownloadSheet(model: display, openURL: { _ in }, cancel: {}, download: {})
            }
            try write(unticked, scheme: scheme, name: "codes-sheet-\(scheme == .dark ? "dark" : "light")")
            display.availableSpace = 120_000_000
            let short = BrandRoot(reduceMotion: false) {
                CodeModelDownloadSheet(model: display, openURL: { _ in }, cancel: {}, download: {}, initiallyAccepted: true)
            }
            try write(short, scheme: scheme, name: "codes-sheet-no-space-\(scheme == .dark ? "dark" : "light")")
        }
    }

    @MainActor func testPanelCards() throws {
        let cards: [(String, CodeModelPanelState)] = [
            ("downloading", CodeModelPanelState(download: downloading)),
            ("error", CodeModelPanelState(download: CodeModelDownload(manifest: manifest, received: 112_400_000, state: .failed(.offline)))),
            ("ready", CodeModelPanelState(download: nil, finished: true)),
        ]
        for (name, card) in cards {
            for scheme in [ColorScheme.light, .dark] {
                let phone = "11111111-1111-1111-1111-111111111111"
                var model = PanelModel()
                model.state = .connected(deviceID: phone, peerName: "OnePlus 11")
                let peer = DiscoveredPeer(serviceName: "OnePlus 11", deviceIDHint: phone, deviceNameHint: "OnePlus 11", platformHint: "android",
                                          protocolVersionHint: 1, host: "10.0.0.2", port: 4000)
                model.rings = deviceRings(trusted: [TrustedDeviceInfo(id: phone, name: "OnePlus 11")], peers: [peer], state: model.state)
                model.battery = RemoteBatteryStatus(level: 76, isCharging: true)
                model.available = Set(BridgeyFeature.allCases)
                model.codeModel = card
                let view = BrandRoot(reduceMotion: false) {
                    StreamPanelView(model: model, actions: PanelActions())
                }
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(24)
                .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
                try write(view, scheme: scheme, name: "codes-panel-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @MainActor func testLicences() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                VStack(alignment: .leading, spacing: 16) { LicencesCard() }
                    .padding(32)
                    .frame(width: 670, alignment: .leading)
                    .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            }
            try write(view, scheme: scheme, name: "codes-licences-\(scheme == .dark ? "dark" : "light")")
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
