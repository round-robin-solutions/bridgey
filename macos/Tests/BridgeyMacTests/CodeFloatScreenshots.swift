import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The floating Copy code card and its Settings row, rendered with ImageRenderer from sample state,
/// light and dark. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter CodeFloatScreenshots
final class CodeFloatScreenshots: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor private func content(code: String, sender: String, copied: Bool) -> CodeFloatContent {
        let content = CodeFloatContent()
        content.card = LiveCodeCard(id: "a", code: code, sender: sender, deviceName: "OnePlus 11", receivedAt: Date())
        content.copied = copied
        return content
    }

    @MainActor func testCard() throws {
        let states: [(String, String, String, Bool)] = [
            ("ready", "482913", "HDFC Bank", false),
            ("copied", "482913", "HDFC Bank", true),
            ("alphanumeric", "G-715204", "Google", false),
            ("long-sender", "7392", "Amazon Pay India Private Limited", false),
        ]
        for (name, code, sender, copied) in states {
            for scheme in [ColorScheme.light, .dark] {
                let model = content(code: code, sender: sender, copied: copied)
                let view = BrandRoot(reduceMotion: false) {
                    CodeFloatView(content: model, copy: {}, close: {})
                }
                .padding(28)
                .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
                try write(view, scheme: scheme, name: "code-float-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    @MainActor func testSettingsRow() throws {
        for option in CodeFloatSetting.allCases {
            var model = SettingsModel()
            model.state = .connected(deviceID: "11111111-1111-1111-1111-111111111111", peerName: "OnePlus 11")
            model.codesEnabled = true
            model.codesEngine = .local
            model.codeAccess = .status(.allowed)
            model.codesFloat = option
            var display = CodeModelDisplay()
            display.availableSpace = 51_300_000_000
            model.codeModel = display
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
                try write(view, scheme: scheme, name: "code-float-settings-\(option.rawValue)-\(scheme == .dark ? "dark" : "light")")
            }
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
