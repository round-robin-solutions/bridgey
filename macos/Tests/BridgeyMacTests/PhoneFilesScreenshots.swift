import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The Phone files and History windows, light and dark, from sample state. Runs only with BRIDGEY_SCREENSHOT_DIR:
///   BRIDGEY_SCREENSHOT_DIR=/tmp/shots swift test --filter PhoneFilesScreenshots
@MainActor
final class PhoneFilesScreenshots: XCTestCase {
    private var directory: URL!
    private let phone = UIFakeImages.phoneID
    private let now = UIFakeImages.base

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_SCREENSHOT_DIR to render design screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var phones: [BrowsablePhone] {
        [BrowsablePhone(id: phone, name: "OnePlus 11", browsable: true, route: .lan),
         BrowsablePhone(id: "33333333-3333-3333-3333-333333333333", name: "Pixel 8", browsable: false, route: .relay)]
    }

    private func model(section: PhoneFilesSection, listing: PhoneListing, placeID: String? = nil, path: [String] = [],
                       writable: Bool = true, fill: Bool = true) -> PhoneFilesModel {
        let fake = UIFakePhoneFiles()
        let model = PhoneFilesModel(service: fake, cache: PhoneThumbnailCache(directory: nil), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    listingCache: PhoneListingCache(directory: nil))
        model.setForTesting(phones: phones, phoneID: phone,
                            info: PhoneBrowseInfo(places: UIFakeImages.places, writable: writable, media: .full, documents: true),
                            section: section, listings: [section: listing], placeID: placeID, path: path)
        model.displayNow = now
        if fill {
            for (index, entry) in listing.entries.enumerated() where entry.hasThumbnail {
                model.thumbnails.box(for: entry).setForTesting(UIFakeImages.decoded(seed: index))
            }
        }
        return model
    }

    func testMediaGrid() throws {
        var listing = PhoneListing(entries: UIFakeImages.media(36, now: now), loaded: true)
        listing.nextCursor = "36"
        let model = model(section: .media, listing: listing)
        model.selection = [listing.entries[1].id, listing.entries[2].id]
        // A few still loading: their tint shows first.
        for entry in listing.entries.suffix(6) {
            let box = model.thumbnails.box(for: entry)
            box.setForTesting(nil)
            box.tint = 0x6B5A4E
        }
        try render(model, name: "mac-phonefiles-media")
    }

    func testFiles() throws {
        let model = model(section: .files, listing: PhoneListing(entries: UIFakeImages.documents(now: now), loaded: true))
        model.selection = [UIFakeImages.documents(now: now)[0].id]
        try render(model, name: "mac-phonefiles-files")
    }

    func testFolderReadOnly() throws {
        var listing = PhoneListing(entries: UIFakeImages.folder(now: now), loaded: true)
        listing.writable = false
        listing.folderCount = 4
        listing.fileCount = 10
        let model = model(section: .folders, listing: listing, placeID: "q3Jx0bVv1eG7tq8Wm2l5wA", path: ["Trip"], writable: false)
        try render(model, name: "mac-phonefiles-folder-readonly")
    }

    func testPlaces() throws {
        let model = model(section: .folders, listing: PhoneListing(), placeID: nil)
        try render(model, name: "mac-phonefiles-places")
    }

    func testRecentWithDownload() throws {
        let mixed = (UIFakeImages.media(6, now: now) + UIFakeImages.documents(now: now).prefix(5))
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let model = model(section: .recent, listing: PhoneListing(entries: Array(mixed), loaded: true))
        model.setActivitiesForTesting([PhoneFilesActivity(id: "d", kind: .download, title: "Invoice October.pdf",
                                                          progress: PhoneTransferProgress(phase: .transferring, filesDone: 0, filesTotal: 1,
                                                                                          bytesDone: 180_000, bytesTotal: 284_112))])
        try render(model, name: "mac-phonefiles-recent")
    }

    func testUploadDrop() throws {
        var listing = PhoneListing(entries: UIFakeImages.folder(now: now), loaded: true)
        listing.writable = true
        let model = model(section: .folders, listing: listing, placeID: "q3Jx0bVv1eG7tq8Wm2l5wA", path: ["Trip"], writable: true)
        model.dropTargeted = true
        try render(model, name: "mac-phonefiles-upload-drop")
    }

    func testPreview() throws {
        let entries = UIFakeImages.media(12, now: now)
        let model = model(section: .media, listing: PhoneListing(entries: entries, loaded: true))
        var state = PhonePreviewState(entry: entries[0], openedAt: now)
        state.quality = .preview
        state.originalProgress = PhoneTransferProgress(phase: .transferring, filesDone: 0, filesTotal: 1, bytesDone: 1_400_000, bytesTotal: 2_400_000)
        model.setPreviewForTesting(state, image: PhoneDecodedImage(image: UIFakeImages.cgImage(width: 1600, height: 1200, seed: 4), tint: nil))
        try render(model, name: "mac-phonefiles-preview")
    }

    func testNotBrowsable() throws {
        let fake = UIFakePhoneFiles()
        let model = PhoneFilesModel(service: fake, cache: PhoneThumbnailCache(directory: nil), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    listingCache: PhoneListingCache(directory: nil))
        model.setForTesting(phones: [phones[1]], phoneID: phones[1].id, info: nil, section: .media, listings: [:])
        try render(model, name: "mac-phonefiles-not-browsable")
    }

    func testHistory() throws {
        let entries = [
            TransferHistoryEntry(id: "1", date: now.addingTimeInterval(-600), direction: .received, deviceID: phone, deviceName: "OnePlus 11",
                                 name: "IMG_4412.HEIC", bytes: 3_282_000, outcome: .completed, localPath: "/tmp/IMG_4412.HEIC", download: true),
            TransferHistoryEntry(id: "2", date: now.addingTimeInterval(-3_000), direction: .sent, deviceID: phone, deviceName: "OnePlus 11",
                                 name: "Photos", isFolder: true, fileCount: 124, bytes: 2_469_606_195, outcome: .completed, destination: "Pictures/Trip"),
            TransferHistoryEntry(id: "3", date: now.addingTimeInterval(-7_200), direction: .received, deviceID: phone, deviceName: "OnePlus 11",
                                 name: "Boarding pass BLR-DEL.pdf", bytes: 91_230, outcome: .completed, localPath: "/tmp/Boarding pass.pdf"),
            TransferHistoryEntry(id: "4", date: now.addingTimeInterval(-86_400 - 3_600), direction: .sent, deviceID: phone, deviceName: "OnePlus 11",
                                 name: "Project deck.key", bytes: 48_000_000, outcome: .cancelled),
            TransferHistoryEntry(id: "5", date: now.addingTimeInterval(-86_400 - 9_000), direction: .received, deviceID: "p8", deviceName: "Pixel 8",
                                 name: "Screen recording.mp4", bytes: 212_000_000, outcome: .incomplete, localPath: "/tmp/missing.mp4"),
            TransferHistoryEntry(id: "6", date: now.addingTimeInterval(-86_400 * 3), direction: .received, deviceID: phone, deviceName: "OnePlus 11",
                                 name: "Lease agreement.docx", bytes: 132_000, outcome: .completed, localPath: "/tmp/Lease agreement.docx"),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                TransferHistoryView(entries: entries, filter: .constant(TransferHistoryFilter()), exists: { $0.lastPathComponent != "missing.mp4" }, now: now)
                    .frame(width: TransferHistoryView.size.width, height: TransferHistoryView.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            try write(view.padding(24).background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0)), scheme: scheme,
                      name: "mac-history-\(scheme == .dark ? "dark" : "light")")
        }
    }

    func testTransferRowsWithShowInFinder() throws {
        var model = PanelModel()
        model.state = .connected(deviceID: phone, peerName: "OnePlus 11")
        model.rings = [DeviceRing(id: phone, deviceID: phone, name: "OnePlus 11", state: .connected, trusted: true, platform: "android", peer: nil)]
        model.targetDeviceID = phone
        model.available = Set(BridgeyFeature.allCases)
        model.hasTransferHistory = true
        model.now = now
        model.transfers = [
            FileTransferRow(id: "a", name: "IMG_4412.HEIC", status: "Saved to Downloads/Bridgey", active: false, startedAt: now,
                            localURL: URL(fileURLWithPath: "/tmp/IMG_4412.HEIC")),
            FileTransferRow(id: "b", name: "Invoice October.pdf", status: "Saved to Downloads/Bridgey", active: false, startedAt: now,
                            localURL: URL(fileURLWithPath: "/tmp/Invoice.pdf")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                StreamPanelView(model: model, actions: PanelActions())
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            try write(view.padding(24).background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0)), scheme: scheme,
                      name: "mac-panel-transfers-finder-\(scheme == .dark ? "dark" : "light")")
        }
    }

    // MARK: Rendering

    private func render(_ model: PhoneFilesModel, name: String) throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = BrandRoot(reduceMotion: false) {
                PhoneFilesWindowView(model: model, promises: PhoneFilePromises(model: nil))
                    .frame(width: PhoneFilesWindowView.size.width, height: PhoneFilesWindowView.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            try write(view.padding(24).background(scheme == .dark ? Color(hex: 0x0A1428) : Color(hex: 0xDFE7F0)), scheme: scheme,
                      name: "\(name)-\(scheme == .dark ? "dark" : "light")")
        }
    }

    private func write<V: View>(_ view: V, scheme: ColorScheme, name: String) throws {
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
