import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Native settings component at narrow and wide widths. No app launch, pairing or preferences.
/// ImageRenderer cannot draw TextField/TextEditor; capture the mounted AppKit view instead.
@MainActor
final class LocalAgentCodesScreenshots: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".rrci-reports/local-agent-codes", isDirectory: true)
    }

    func testLocalCodesSettings() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var measurements: [[String: Int]] = []
        for width: CGFloat in [390, 880, 1440] {
            for dark in [false, true] {
                var heights: [Int] = []
                for on in [false, true] {
                    var options = LocalAgentCodeOptions()
                    options.enabled = on
                    let view = BrandRoot(reduceMotion: true) {
                        LocalAgentCodesCard(options: options, set: { _ in }).padding(24).frame(width: width)
                    }
                    .background(BrandPalette.forScheme(dark ? .dark : .light).bg)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.snapshotRendering, true)
                    let size = try capture(view, dark: dark, name: "local-codes-\(Int(width))-\(dark ? "dark" : "light")-\(on ? "on" : "off")")
                    XCTAssertEqual(size.width, width)
                    heights.append(Int(size.height))
                    measurements.append(["width": Int(width), "height": Int(size.height), "dark": dark ? 1 : 0, "on": on ? 1 : 0])
                }
                XCTAssertEqual(heights.first, heights.last, "The switch must not shift the form")
                let reference = BrandRoot(reduceMotion: true) {
                    CodesCard(model: SettingsModel(), actions: SettingsActions()).padding(24).frame(width: width)
                }
                .background(BrandPalette.forScheme(dark ? .dark : .light).bg)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.snapshotRendering, true)
                _ = try capture(reference, dark: dark, name: "reference-codes-\(Int(width))-\(dark ? "dark" : "light")")
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("layout.json"))
    }

    func testSwitchTransitionSamples() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = LocalCodeSettingsFixtureState()
        let view = BrandRoot(reduceMotion: false) { LocalCodeSettingsFixture(state: state).padding(24).frame(width: 880) }
            .background(BrandPalette.forScheme(.light).bg)
            .environment(\.colorScheme, .light)
        let (window, host) = mount(view, dark: false)
        defer { window.orderOut(nil); window.contentView = nil }
        try write(host, name: "switch-0ms")
        state.options.enabled = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.07))
        try write(host, name: "switch-70ms")
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        try write(host, name: "switch-settled")
        // These are native view bitmaps sampled during the transition, not compositor timing data.
    }

    private func mount<V: View>(_ view: V, dark: Bool) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        return (window, host)
    }

    private func capture<V: View>(_ view: V, dark: Bool, name: String) throws -> NSSize {
        let (window, host) = mount(view, dark: dark)
        defer { window.orderOut(nil); window.contentView = nil }
        try write(host, name: name)
        return host.bounds.size
    }

    private func write(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

@MainActor private final class LocalCodeSettingsFixtureState: ObservableObject {
    @Published var options = LocalAgentCodeOptions()
}

@MainActor private struct LocalCodeSettingsFixture: View {
    @ObservedObject var state: LocalCodeSettingsFixtureState
    var body: some View { LocalAgentCodesCard(options: state.options, set: { state.options = $0 }) }
}
