import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import BridgeyMac

/// Send UX on the Mac (send sheet, drop tiles, toast, Tray, Before sending, chip popover), rendered with
/// ImageRenderer from sample state. Runs only when BRIDGEY_SCREENSHOT_DIR is set.
final class SendDesignScreenshots: XCTestCase {
    private var directory: URL!
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"
    private lazy var now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 41))!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Sample content

    static let palette: [(UInt32, UInt32)] = [
        (0x2B5876, 0x4E4376), (0xF2994A, 0xF2C94C), (0x11998E, 0x38EF7D), (0xEE9CA7, 0xFFDDE1), (0x0F2027, 0x2C5364),
        (0x8E2DE2, 0x4A00E0), (0xFF5F6D, 0xFFC371), (0x1D976C, 0x93F9B9), (0x373B44, 0x4286F4), (0xDA4453, 0x89216B),
    ]

    /// A photo-like gradient with a horizon, as a stand-in thumbnail.
    static func picture(_ index: Int, size: CGSize = CGSize(width: 200, height: 160)) -> NSImage {
        let (top, bottom) = palette[index % palette.count]
        return NSImage(size: size, flipped: false) { rect in
            let gradient = NSGradient(starting: NSColor(sendRGB: top), ending: NSColor(sendRGB: bottom))
            gradient?.draw(in: rect, angle: -90)
            NSColor.black.withAlphaComponent(0.18).setFill()
            let hill = NSBezierPath()
            hill.move(to: NSPoint(x: 0, y: rect.height * 0.25))
            hill.curve(to: NSPoint(x: rect.width, y: rect.height * 0.35), controlPoint1: NSPoint(x: rect.width * 0.3, y: rect.height * 0.55),
                       controlPoint2: NSPoint(x: rect.width * 0.6, y: rect.height * 0.1))
            hill.line(to: NSPoint(x: rect.width, y: 0))
            hill.line(to: NSPoint(x: 0, y: 0))
            hill.fill()
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width * 0.68, y: rect.height * 0.62, width: rect.width * 0.12, height: rect.width * 0.12)).fill()
            return true
        }
    }

    private func candidate(_ name: String, _ size: Int64, minutes: Double, screenshot: Bool = false) -> SendCandidate {
        SendCandidate(url: URL(fileURLWithPath: "/Users/rahul/Downloads/\(name)"), name: name, size: size,
                      date: now.addingTimeInterval(-minutes * 60), isDirectory: false, isScreenshot: screenshot)
    }

    private var sheetState: SendSheetState {
        var state = SendSheetState()
        state.targets = [SendTarget(id: phoneID, name: "OnePlus 11", battery: RemoteBatteryStatus(level: 76, isCharging: true)),
                         SendTarget(id: tabletID, name: "Galaxy Tab S9", battery: RemoteBatteryStatus(level: 41, isCharging: false))]
        state.targetID = phoneID
        state.recent = [
            candidate("IMG_4127.HEIC", 3_412_000, minutes: 3), candidate("Boarding pass.pdf", 182_000, minutes: 12),
            candidate("IMG_4126.HEIC", 2_978_000, minutes: 15), candidate("Invoice October.pdf", 96_000, minutes: 40),
            candidate("Slides v3.key", 14_200_000, minutes: 70), candidate("IMG_4101.JPG", 4_100_000, minutes: 95),
            candidate("Lease scan.pdf", 1_300_000, minutes: 180), candidate("Recording 12.m4a", 6_900_000, minutes: 240),
            candidate("IMG_4099.JPG", 3_800_000, minutes: 300), candidate("Notes.txt", 2_000, minutes: 360),
        ]
        state.screenshots = [
            candidate("Screenshot 2026-10-27 at 09.38.png", 812_000, minutes: 3, screenshot: true),
            candidate("Screenshot 2026-10-27 at 09.12.png", 640_000, minutes: 29, screenshot: true),
            candidate("Screenshot 2026-10-26 at 21.04.png", 1_120_000, minutes: 760, screenshot: true),
            candidate("Screenshot 2026-10-26 at 18.40.png", 702_000, minutes: 900, screenshot: true),
            candidate("Screenshot 2026-10-26 at 11.02.png", 498_000, minutes: 1_360, screenshot: true),
        ]
        state.selection = [state.recent[0].url, state.recent[2].url, state.screenshots[0].url]
        state.optimization = .recommended
        state.saving = 0.68
        return state
    }

    private func thumbnail(_ item: SendCandidate) -> NSImage? {
        let lower = item.name.lowercased()
        guard lower.hasSuffix(".heic") || lower.hasSuffix(".jpg") || lower.hasSuffix(".png") else {
            return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        }
        return Self.picture(abs(item.name.hashValue) % Self.palette.count)
    }

    // MARK: Renders

    @MainActor func testSendSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try write(SendSheetView(state: sheetState, actions: SendSheetActions(), thumbnail: thumbnail)
                .frame(height: 600), scheme: scheme, name: "mac-send-to-phone-\(suffix)")
        }
        var empty = SendSheetState()
        empty.targets = sheetState.targets
        empty.targetID = phoneID
        try write(SendSheetView(state: empty, actions: SendSheetActions()).frame(height: 440), scheme: .light, name: "mac-send-to-phone-empty-light")
    }

    private var panelModel: PanelModel {
        var model = PanelModel()
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.rings = deviceRings(trusted: [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")],
                                  peers: [DiscoveredPeer(serviceName: "OnePlus 11", deviceIDHint: phoneID, deviceNameHint: "OnePlus 11",
                                                         platformHint: "android", protocolVersionHint: 1, host: "10.0.0.2", port: 4000)],
                                  state: model.state)
        model.battery = RemoteBatteryStatus(level: 76, isCharging: true)
        model.now = now
        model.available = Set(BridgeyFeature.allCases)
        model.clipboardLine = "Room 2 at 4, bring the deck"
        return model
    }

    private var tileDevices: [DropTileDevice] {
        [DropTileDevice(id: phoneID, name: "OnePlus 11", battery: RemoteBatteryStatus(level: 76, isCharging: true)),
         DropTileDevice(id: tabletID, name: "Galaxy Tab S9", battery: RemoteBatteryStatus(level: 41, isCharging: false))]
    }

    @MainActor func testDropTilesAndToast() throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let panel = StreamPanelView(model: panelModel, actions: PanelActions())
                .fixedSize(horizontal: false, vertical: true)
                .overlay { DropTilesView(devices: tileDevices, trayCount: 2, chip: "Optimised", highlighted: .device(phoneID)) }
            try write(panel, scheme: scheme, name: "mac-drop-tiles-\(suffix)")
            let toast = DropToastModel(text: "Sending 3 items to OnePlus 11", actions: [
                DropToastAction(title: "Undo") {}, DropToastAction(title: "Send to\u{2026}") {},
            ])
            try write(DropToastView(model: toast), scheme: scheme, name: "mac-drop-toast-\(suffix)")
        }
    }

    @MainActor func testTray() throws {
        var state = TrayViewState()
        let at = now
        state.items = [
            TrayItem(id: "1", kind: .file, name: "IMG_4127.HEIC", size: 3_412_000, addedAt: at),
            TrayItem(id: "2", kind: .folder, name: "Receipts 2026", size: 48_200_000, addedAt: at),
            TrayItem(id: "3", kind: .data, name: "Image 2026-10-27 at 09.31.12.png", size: 412_000, addedAt: at),
            TrayItem(id: "4", kind: .link, name: "maps.google.com", size: 0, addedAt: at, text: "https://maps.google.com/?q=Gate+14"),
            TrayItem(id: "5", kind: .text, name: "Gate 14, boarding 18:40", size: 23, addedAt: at, text: "Gate 14, boarding 18:40"),
        ]
        state.targets = [SendTarget(id: phoneID, name: "OnePlus 11", battery: RemoteBatteryStatus(level: 76, isCharging: true)),
                         SendTarget(id: tabletID, name: "Galaxy Tab S9", battery: nil)]
        state.targetID = phoneID
        state.optimization = .recommended
        state.saving = 0.41
        let pictures: (TrayItem) -> NSImage? = { item in
            item.kind == .file || item.kind == .data ? Self.picture(Int(item.id) ?? 0) : nil
        }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try write(TrayView(state: state, actions: TrayActions(), thumbnail: pictures).frame(height: 470), scheme: scheme, name: "mac-tray-\(suffix)")
        }
        var sent = TrayViewState()
        sent.targets = state.targets
        sent.targetID = phoneID
        sent.banner = "Sent 5 items to OnePlus 11"
        try write(TrayView(state: sent, actions: TrayActions()).frame(height: 360), scheme: .light, name: "mac-tray-sent-light")
    }

    @MainActor func testOptimizationSettingsAndPopover() throws {
        let model = SendPreviewModel()
        var options = SendOptimization.recommended
        options.format = .webp
        options.quality = 70
        model.update(options)
        let deadline = Date().addingTimeInterval(10)
        while model.state.optimizedBytes == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotNil(model.state.optimizedBytes)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try write(SendOptimizationSettings(options: options, change: { _ in }, preview: model.state).frame(width: 560).padding(20),
                      scheme: scheme, name: "mac-settings-before-sending-\(suffix)")
            try write(SendOptimizationPopover(options: options, defaults: .default, change: { _ in }), scheme: scheme, name: "mac-chip-popover-\(suffix)")
        }
    }

    @MainActor func write<V: View>(_ content: V, scheme: ColorScheme, name: String, padding: CGFloat = 24) throws {
        let view = BrandRoot(reduceMotion: false) { content }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(padding)
            .background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0))
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

extension NSColor {
    convenience init(sendRGB rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
