import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The accessibility and localisation review's screenshots: the surfaces it changed, light and dark, in English and
/// Russian (Russian runs about 30% longer, so this is where text has to fit). Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter AccessibilityL10nScreenshots
@MainActor
final class AccessibilityL10nScreenshots: XCTestCase {
    private var directory: URL!
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        L10n.bundle = .main
        L10n.language = nil
        super.tearDown()
    }

    func testSurfaces() throws {
        for language in ["en", "ru"] {
            L10n.bundle = try XCTUnwrap(Bundle(path: Self.resources.appendingPathComponent("\(language).lproj").path))
            L10n.language = language
            let settings = SettingsSearchScreenshots().model
            for scheme in [ColorScheme.light, .dark] {
                let tag = "\(language)-\(scheme == .dark ? "dark" : "light")"
                for group in SettingsGroup.allCases {
                    try write(SettingsWindowView(model: settings, actions: SettingsActions(), group: .constant(group)),
                              size: SettingsWindowView.size, scheme: scheme, language: language, name: "mac-settings-\(group.rawValue)-\(tag)")
                    try write(VStack(alignment: .leading, spacing: 16) {
                        SettingsGroupView(group: group, model: settings, actions: SettingsActions())
                    }
                    .padding(.horizontal, 40).padding(.vertical, 32)
                    .environment(\.settingsExpandAll, true),
                    size: CGSize(width: SettingsWindowView.size.width - 220, height: 0), scheme: scheme, language: language,
                    name: "mac-settings-\(group.rawValue)-more-\(tag)")
                }
                try write(MessagesView(model: MessagesScreenshots().searchModel, actions: MessagesActions(), copiedMessage: nil), size: MessagesView.size,
                          scheme: scheme, language: language, name: "mac-messages-search-\(tag)")
                try write(MessagesView(model: MessagesScreenshots().model, actions: MessagesActions(), copiedMessage: nil), size: MessagesView.size,
                          scheme: scheme, language: language, name: "mac-messages-\(tag)")
                try write(StreamPanelView(model: DesignScreenshots().connectedModel, actions: PanelActions()),
                          size: CGSize(width: StreamPanelView.width, height: 0), scheme: scheme, language: language, name: "mac-panel-\(tag)")
                let transfers = TransfersWindowScreenshots()
                try write(TransfersWindowView(state: transfers.state(), live: transfers.feed(true), filter: .constant(TransfersFilter()),
                                              selection: .constant("record"), pendingSend: .constant(nil)),
                          size: TransfersWindowView.size, scheme: scheme, language: language, name: "mac-transfers-\(tag)")
                try write(CallsView(model: CallsScreenshots().model, actions: CallsActions()), size: CGSize(width: 420, height: 620),
                          scheme: scheme, language: language, name: "mac-calls-\(tag)")
                let call = CallCardContent()
                call.call = RemoteCallStatus(notificationID: "n1", deviceID: "d1", applicationName: "Phone", caller: "Anna Kapoor", detail: "",
                                             type: "ongoing", actions: [RemoteCallAction(id: "hang", title: "Hang up")])
                try write(CallOverlayView(content: call, hide: {}, perform: { _ in }), size: CGSize(width: 380, height: 0),
                          scheme: scheme, language: language, name: "mac-call-card-\(tag)")
                // The drawn checkbox and switch, off and on: the empty checkbox's outline has to stand out (3:1).
                try write(VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: .constant(false)) { Text(L10n.text("folders.sheet.includeSystem", fallback: "Include system files")) }
                        .toggleStyle(BrandCheckboxStyle())
                    Toggle(isOn: .constant(true)) { Text(L10n.text("folders.sheet.includeSystem", fallback: "Include system files")) }
                        .toggleStyle(BrandCheckboxStyle())
                    Toggle(isOn: .constant(false)) { Text(L10n.text("settings.reduceMotion", fallback: "Reduce motion")) }
                        .toggleStyle(BrandSwitchStyle())
                    Toggle(isOn: .constant(true)) { Text(L10n.text("settings.reduceMotion", fallback: "Reduce motion")) }
                        .toggleStyle(BrandSwitchStyle())
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(scheme == .dark ? BrandPalette.dark.s1 : BrandPalette.light.s1))
                .padding(20),
                size: CGSize(width: 360, height: 0), scheme: scheme, language: language, name: "mac-controls-\(tag)")
                let code = CodeFloatContent()
                code.card = LiveCodeCard(id: "a", code: "482913", sender: "HDFC Bank", deviceName: "OnePlus 11", receivedAt: Date())
                try write(CodeFloatView(content: code, copy: {}, close: {}), size: CGSize(width: 360, height: 0),
                          scheme: scheme, language: language, name: "mac-code-float-\(tag)")
            }
        }
    }

    /// Height 0: the view's own height.
    private func write<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, language: String, name: String) throws {
        let framed = BrandRoot(reduceMotion: false) {
            if size.height > 0 {
                AnyView(view.frame(width: size.width, height: size.height))
            } else {
                AnyView(view.frame(width: size.width).fixedSize(horizontal: false, vertical: true))
            }
        }
        .background(scheme == .dark ? Color(hex: 0x0A101D) : BrandPalette.light.bg)
        let renderer = ImageRenderer(content: framed
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true)
            .environment(\.locale, Locale(identifier: language == "ru" ? "ru_RU" : "en_GB")))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
