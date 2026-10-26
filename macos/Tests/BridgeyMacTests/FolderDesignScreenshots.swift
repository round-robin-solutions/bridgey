import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Files 2.0 on the Mac, rendered with ImageRenderer from sample state. Runs only when BRIDGEY_SCREENSHOT_DIR is set:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter FolderDesignScreenshots
final class FolderDesignScreenshots: XCTestCase {
    private var directory: URL!
    private let calendar = Calendar.current
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 41))!
    private let phoneID = "11111111-1111-1111-1111-111111111111"

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Sample state

    private let places = [
        PlaceInfo(placeId: "default", label: "Download/Bridgey", available: true, freeBytes: 81_604_378_624),
        PlaceInfo(placeId: "q3Jx0bVv1eG7tq8Wm2l5wA", label: "Pictures", available: true, freeBytes: 81_604_378_624),
        PlaceInfo(placeId: "Zr8m2Pq0aLk4xT7bNc1yWe", label: "Documents", available: true, freeBytes: 81_604_378_624),
        PlaceInfo(placeId: "Hh5c9Vd2kQe8rT1uYp3oZx", label: "Trip (USB drive)", available: false, freeBytes: nil),
    ]

    private var sheetState: FolderSheetState {
        var state = FolderSheetState()
        state.phoneName = "OnePlus 11"
        state.folderName = "Photos"
        state.rootName = "Photos"
        state.places = places
        state.placeID = "q3Jx0bVv1eG7tq8Wm2l5wA"
        state.path = ["Trip"]
        state.folders = ["2019", "Beach", "Day trips", "Family", "Mountains"]
        state.scanning = false
        state.fileCount = 124
        state.folderCount = 9
        state.totalSize = 2_469_606_195
        state.skipped = SkippedCounts(links: 3, hidden: 12, system: 48)
        state.hashing = 0.42
        return state
    }

    private var browserState: FolderSheetState {
        var state = sheetState
        state.path = ["Trip", "2019"]
        state.folders = ["Barcelona", "Lisbon", "Porto"]
        state.newFolderOpen = true
        state.newFolderName = "Trip 2026"
        state.skipped = SkippedCounts(links: 0, hidden: 4, system: 0)
        state.packages = ["Itinerary.rtfd"]
        state.hashing = nil
        state.options = FolderScanOptions(includeHidden: false, includeSystem: true)
        return state
    }

    private var conflictState: FolderConflictState {
        let conflict = FolderConflictPayload(folderTransferId: "f", existing: "folder", clashingFiles: 12, clashingFolders: 3,
                                             newFolderName: "Photos (1)", choices: [.merge, .replace, .newFolder], timeoutSeconds: 180)
        return FolderConflictState(name: "Photos", destination: "Pictures/Trip",
                                   message: FolderText.conflictMessage(conflict, name: "Photos", destination: "Pictures/Trip", totalFiles: 124),
                                   choices: conflict.choices, newFolderName: "Photos (1)", deadline: now.addingTimeInterval(161))
    }

    private var folderRow: FileTransferRow {
        var progress = FolderProgress()
        progress.phase = .sending
        progress.filesDone = 37
        progress.filesTotal = 124
        progress.bytesDone = 812_000_000
        progress.bytesTotal = 2_300_000_000
        progress.bytesPerSecond = 12_000_000
        progress.currentPath = "2019/Beach/IMG_0412.HEIC"
        progress.currentBytes = 1_900_000
        progress.currentSize = 3_400_000
        progress.failures = [FolderFailure(entry: 17, path: "2019/Notes/draft.pages", code: "source_changed")]
        progress.failedCount = 1
        progress.recent = (0..<37).map { String(format: "2019/Beach/IMG_%04d.HEIC", 375 + $0) }
        progress.rootName = "Photos"
        progress.destinationLabel = "Pictures/Trip"
        progress.choice = .merge
        var summary = FolderRowSummary(phoneName: "OnePlus 11", displayName: "Photos")
        summary.destinationLabel = "Pictures/Trip"
        summary.state = .running
        summary.progress = progress
        summary.skipped = SkippedCounts(links: 3, hidden: 12)
        return FileTransferRow(id: "folder", name: "Photos", status: FolderText.status(summary, now: now), active: true,
                               startedAt: now, folder: summary)
    }

    private var queuedRow: FileTransferRow {
        var summary = FolderRowSummary(phoneName: "OnePlus 11", displayName: "Receipts 2026")
        summary.state = .queued
        summary.fixedLabel = nil
        return FileTransferRow(id: "queued", name: "Receipts 2026", status: "Queued", active: true, startedAt: now.addingTimeInterval(1),
                               queued: true, folder: summary)
    }

    private var panelModel: PanelModel {
        var model = PanelModel()
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.rings = deviceRings(trusted: [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")],
                                  peers: [DiscoveredPeer(serviceName: "OnePlus 11", deviceIDHint: phoneID, deviceNameHint: "OnePlus 11",
                                                         platformHint: "android", protocolVersionHint: 1, host: "10.0.0.2", port: 4000)],
                                  state: model.state)
        model.battery = RemoteBatteryStatus(level: 76, isCharging: true)
        model.transfers = [folderRow, queuedRow]
        model.fileTransferActive = true
        model.rows = streamRows([
            ActivityItem(id: 2, kind: .folderSent, deviceID: phoneID, deviceName: "OnePlus 11", fileName: "Receipts", preview: nil, appName: nil,
                         sensitive: false, automatic: false, count: 1, at: now.addingTimeInterval(-600), bytes: 48_000_000,
                         content: FolderActivityDetail(links: 3, hidden: 12).encoded, fileCount: 31, destination: "Documents"),
            ActivityItem(id: 1, kind: .fileSent, deviceID: phoneID, deviceName: "OnePlus 11", fileName: "invoice-oct.pdf", preview: nil, appName: nil,
                         sensitive: false, automatic: false, count: 1, at: now.addingTimeInterval(-1_800)),
        ], now: now)
        model.now = now
        model.available = Set(BridgeyFeature.allCases)
        model.clipboardLine = "Room 2 at 4, bring the deck"
        return model
    }

    // MARK: Renders

    @MainActor func testFolderScreens() throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try write(FolderSendSheetView(state: sheetState, actions: FolderSheetActions()), scheme: scheme, name: "mac-send-sheet-\(suffix)")
            try write(FolderSendSheetView(state: browserState, actions: FolderSheetActions()), scheme: scheme, name: "mac-destination-browser-\(suffix)")
            try write(FolderConflictView(state: conflictState, now: now, answer: { _ in }), scheme: scheme, name: "mac-conflict-\(suffix)")
            try writePanel(panelModel, scheme: scheme, name: "mac-stream-folder-\(suffix)")
        }
        var expanded = panelModel
        expanded.expandedTransfers = ["folder"]
        try writePanel(expanded, scheme: .light, name: "mac-stream-folder-expanded-light")
    }

    @MainActor private func writePanel(_ model: PanelModel, scheme: ColorScheme, name: String) throws {
        let view = StreamPanelView(model: model, actions: PanelActions())
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(20)
        try write(view, scheme: scheme, name: name)
    }

    @MainActor private func write<V: View>(_ content: V, scheme: ColorScheme, name: String) throws {
        let view = BrandRoot(reduceMotion: false) { content }
            .padding(24)
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
