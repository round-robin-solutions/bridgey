import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The Transfers window rendered with ImageRenderer from fixture state: live transfers, a failure, photos,
/// documents, folders, long names and the empty state, light and dark, at the default and the minimum size.
/// Runs only when BRIDGEY_SCREENSHOT_DIR is set; BRIDGEY_SCREENSHOT_FIXTURES may name a folder with
/// thumb-video.jpg and thumb-photo1.jpg to thumb-photo3.jpg for the thumbnails (else they are drawn):
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter TransfersWindowScreenshots
@MainActor
final class TransfersWindowScreenshots: XCTestCase {
    private var directory: URL!
    private let calendar = Calendar.current
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 16, minute: 5))!
    private let phone = "11111111-1111-1111-1111-111111111111"
    private let mac = "33333333-3333-3333-3333-333333333333"
    private let pixel = "22222222-2222-2222-2222-222222222222"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Fixtures

    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0, daysAgo: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: second, of: day)!
    }

    private func entry(_ id: String, _ date: Date, _ name: String, device: String? = nil, direction: TransferHistoryEntry.Direction = .received,
                       outcome: TransferHistoryEntry.Outcome = .completed, folder: Bool = false, files: Int = 1, bytes: Int64,
                       speed: Double? = nil) -> TransferHistoryEntry {
        let device = device ?? phone
        let names = [phone: "OnePlus 11 5G", mac: "Personal Mac", pixel: "Pixel 8"]
        return TransferHistoryEntry(id: id, date: date, direction: direction, deviceID: device, deviceName: names[device] ?? device, name: name,
                                    isFolder: folder, fileCount: files, bytes: bytes, outcome: outcome, localPath: "/tmp/transfers/\(name)",
                                    bytesPerSecond: speed)
    }

    private var entries: [TransferHistoryEntry] {
        [
            entry("record", at(15, 55), "Record_2026-11-24-15-53-12-e93.mp4", bytes: 24_600_000, speed: 38_200_000),
            entry("shot", at(10, 58), "Screenshot 2026-11-24 at 10.58.12.png", direction: .sent, bytes: 117_000),
            entry("img1", at(9, 14), "IMG20261124_091402.jpg", bytes: 6_800_000, speed: 22_000_000),
            entry("img2", at(9, 13, 55), "IMG20261124_091355.jpg", bytes: 7_100_000),
            entry("img3", at(9, 13, 40), "IMG20261124_091340.jpg", bytes: 5_900_000),
            entry("brief", at(11, 20), "Design brief v3.pdf", direction: .sent, outcome: .failed, bytes: 0),
            entry("json", at(8, 19), "microg-accounts-20261124-0818.json", bytes: 2_700),
            entry("trip", at(7, 2), "Trip to Hampi, December 2025 (all edited photos for the album)", direction: .sent, folder: true,
                  files: 124, bytes: 373_480_300),
            entry("zip", at(17, 40, daysAgo: 1), "Invoices November.zip", device: mac, bytes: 45_700_000),
            entry("deck", at(12, 5, daysAgo: 1), "Quarterly review deck final final v7.key", device: pixel, direction: .sent, outcome: .cancelled, bytes: 0),
            entry("lease", at(9, 30, daysAgo: 3), "Lease agreement.docx", bytes: 132_000),
        ]
    }

    private var failedRow: FileTransferRow {
        FileTransferRow(id: "brief", name: "Design brief v3.pdf", status: "Transfer interrupted; reconnect to retry", active: false,
                        startedAt: at(11, 20), retryable: true, deviceID: phone)
    }

    private var liveRows: [FileTransferRow] {
        let video = FileTransferRow(id: "live-video", name: "VID20261124_160212.mp4", status: "Sending", active: true, startedAt: at(16, 2),
                                    localURL: URL(fileURLWithPath: "/tmp/transfers/VID20261124_160212.mp4"), deviceID: phone,
                                    bytesDone: 139_000_000, bytesTotal: 193_000_000)
        var progress = FolderProgress()
        progress.phase = .sending
        progress.filesDone = 12
        progress.filesTotal = 48
        progress.bytesDone = 88_000_000
        progress.bytesTotal = 326_000_000
        progress.recent = (1...12).map { String(format: "IMG_%04d.jpg", $0) }
        progress.rootName = "Trip to Pondicherry"
        var summary = FolderRowSummary(phoneName: "OnePlus 11 5G", displayName: "Trip to Pondicherry")
        summary.state = .running
        summary.incoming = true
        summary.progress = progress
        let folder = FileTransferRow(id: "live-folder", name: "Trip to Pondicherry", status: "", active: true, startedAt: at(16, 3),
                                     folder: summary, deviceID: phone)
        let queued = (1...2).map { FileTransferRow(id: "queued-\($0)", name: "IMG_\($0).jpg", status: "Queued", active: true,
                                                    startedAt: at(16, 4), queued: true, deviceID: phone) }
        return [video, folder] + queued
    }

    private func image(_ name: String, tint: (NSColor, NSColor)) -> NSImage {
        if let folder = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_FIXTURES"],
           let loaded = NSImage(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(name)) {
            return loaded
        }
        let size = NSSize(width: 300, height: 190)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: tint.0, ending: tint.1)?.draw(in: rect, angle: 35)
            return true
        }
    }

    /// The live card's fixture rows and speeds.
    func feed(_ live: Bool) -> TransfersLiveFeed {
        guard live else { return TransfersLiveFeed() }
        let names = [phone: "OnePlus 11 5G", mac: "Personal Mac", pixel: "Pixel 8"]
        return TransfersLiveFeed(live: TransferLiveList.ordered(liveRows).map { TransferLive.make($0, deviceName: { names[$0] ?? $0 }) },
                                 speeds: ["live-video": 21_400_000, "live-folder": 18_900_000])
    }

    func state(live: Bool = true, empty: Bool = false) -> TransfersWindowState {
        var state = TransfersWindowState()
        state.now = now
        state.connected = [TransferDevice(id: phone, name: "OnePlus 11 5G"), TransferDevice(id: pixel, name: "Pixel 8")]
        state.devices = [TransferDevice(id: phone, name: "OnePlus 11 5G"), TransferDevice(id: mac, name: "Personal Mac"),
                         TransferDevice(id: pixel, name: "Pixel 8")]
        state.routes = [phone: TransferRouteChip(text: "Same Wi-Fi", style: .lan),
                        pixel: TransferRouteChip(text: "Relay (Cloudflare)", style: .relay)]
        guard !empty else { return state }
        let names = [phone: "OnePlus 11 5G", mac: "Personal Mac", pixel: "Pixel 8"]
        state.hasLive = live
        state.items = TransferItems.make(entries: entries, rows: [failedRow], deviceName: { names[$0] ?? $0 })
        state.missing = ["lease"]
        state.today = TransferTotals.text(entries, now: now)
        let green = (NSColor(calibratedRed: 0.36, green: 0.55, blue: 0.33, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.47, alpha: 1))
        let sky = (NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.75, alpha: 1), NSColor(calibratedRed: 0.40, green: 0.55, blue: 0.36, alpha: 1))
        state.previews = [
            "live-video": image("thumb-video.jpg", tint: green),
            "record": image("thumb-photo2.jpg", tint: green),
            "shot": image("thumb-photo3.jpg", tint: sky),
            "img1": image("thumb-photo1.jpg", tint: sky),
            "img2": image("thumb-video.jpg", tint: green),
            "img3": image("thumb-photo2.jpg", tint: sky),
        ]
        state.durations = ["live-video": "2:41", "record": "0:38"]
        state.hoveredID = "record"
        return state
    }

    // MARK: Renders

    func testTransfersWindow() throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try write(state(), selection: "record", size: TransfersWindowView.size, scheme: scheme, name: "transfers-820x640-\(suffix)")
            try write(state(), selection: "record", size: TransfersWindowView.minimumSize, scheme: scheme, name: "transfers-560x420-\(suffix)")
            try write(state(empty: true), live: false, size: TransfersWindowView.size, scheme: scheme, name: "transfers-empty-820x640-\(suffix)")
            try write(state(empty: true), live: false, size: TransfersWindowView.minimumSize, scheme: scheme, name: "transfers-empty-560x420-\(suffix)")
        }
        try write(state(live: false), live: false, filter: TransfersFilter(category: .failed), size: TransfersWindowView.size, scheme: .dark,
                  name: "transfers-failed-filter-dark")
        try write(state(), pending: [URL(fileURLWithPath: "/tmp/a.jpg")], size: TransfersWindowView.size, scheme: .light,
                  name: "transfers-device-picker-light")
    }

    private func write(_ state: TransfersWindowState, live: Bool = true, filter: TransfersFilter = TransfersFilter(), selection: String? = nil,
                       pending: [URL]? = nil, size: CGSize, scheme: ColorScheme, name: String) throws {
        let window = BrandRoot(reduceMotion: false) {
            TransfersWindowView(state: state, live: feed(live), filter: .constant(filter), selection: .constant(selection),
                                pendingSend: .constant(pending))
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) { trafficLights }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(scheme == .dark ? 0.6 : 0.12), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.22), radius: 30, y: 12)
        .padding(44)
        .background(scheme == .dark ? Color(hex: 0x1D2433) : Color(hex: 0xC9D3E0))
        let renderer = ImageRenderer(content: window
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true)
            .environment(\.locale, Locale(identifier: "en_GB")))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw XCTSkip("ImageRenderer produced no image") }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The window's own buttons, where TransfersNSWindow places them (ImageRenderer draws only the content).
    private var trafficLights: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { colour in
                Circle().fill(Color(hex: UInt32(colour))).frame(width: 12, height: 12)
            }
        }
        .padding(.leading, 18)
        .frame(height: TransfersWindowView.headerHeight)
    }
}
