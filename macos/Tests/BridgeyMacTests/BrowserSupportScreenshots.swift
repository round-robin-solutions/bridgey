import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Settings > Media and actions > Browser extensions in its states, light and dark. Runs only when
/// BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter BrowserSupportScreenshots
final class BrowserSupportScreenshots: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor func testBrowserExtensionsRow() throws {
        let states: [(String, BrowserSupportDisplay)] = [
            ("off", BrowserSupportDisplay()),
            ("installed", BrowserSupportDisplay(enabled: true, browsers: ["Google Chrome", "Arc", "Firefox"])),
            ("no-browser", BrowserSupportDisplay(enabled: true, problem: .noBrowser)),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(states, id: \.0) { _, display in
                        BrowserSupportCard(display: display, actions: SettingsActions())
                    }
                }
                .padding(32)
                .frame(width: 670, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
            }
            let renderer = ImageRenderer(content: view
                .environment(\.colorScheme, scheme)
                .environment(\.snapshotRendering, true)
                .environment(\.locale, Locale(identifier: "en_GB")))
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("mac-browser-extensions-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
