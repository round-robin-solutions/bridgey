import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Native settings component at narrow and wide widths. No app launch, pairing or preferences.
@MainActor
final class LocalAgentCodesScreenshots: XCTestCase {
    func testLocalCodesSettings() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".rrci-reports/local-agent-codes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var measurements: [[String: Int]] = []
        for width: CGFloat in [390, 880, 1440] {
            for dark in [false, true] {
                var heights: [Int] = []
                for on in [false, true] {
                    var options = LocalAgentCodeOptions()
                    options.enabled = on
                    let view = BrandRoot(reduceMotion: true) {
                        LocalAgentCodesCard(options: options, set: { _ in })
                            .padding(24)
                            .frame(width: width)
                    }
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.snapshotRendering, true)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 1
                    let cgImage = try XCTUnwrap(renderer.cgImage)
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
                    try data.write(to: directory.appendingPathComponent("local-codes-\(Int(width))-\(dark ? "dark" : "light")-\(on ? "on" : "off").png"))
                    XCTAssertEqual(cgImage.width, Int(width))
                    heights.append(cgImage.height)
                    measurements.append(["width": Int(width), "height": cgImage.height, "dark": dark ? 1 : 0, "on": on ? 1 : 0])
                }
                XCTAssertEqual(heights.first, heights.last, "The switch must not shift the form")
                let reference = BrandRoot(reduceMotion: true) {
                    CodesCard(model: SettingsModel(), actions: SettingsActions()).padding(24).frame(width: width)
                }
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.snapshotRendering, true)
                let renderer = ImageRenderer(content: reference)
                let image = try XCTUnwrap(renderer.cgImage)
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("reference-codes-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("layout.json"))
    }
}
