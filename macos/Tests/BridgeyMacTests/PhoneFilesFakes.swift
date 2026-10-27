import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import BridgeyMac

/// A phone behind PhoneFilesService for the browse UI tests, screenshots and the perf harness. With
/// `simulated` set, every answer waits like a LAN would: one round trip, the bytes at the given bandwidth,
/// and the phone's own work (thumbnail encoding in parallel on `phoneThreads`).
@MainActor
final class UIFakePhoneFiles: PhoneFilesService {
    struct Network {
        /// Round trip in seconds.
        var rtt: TimeInterval = 0.004
        /// Bytes per second on the link.
        var bandwidth: Double = 30_000_000
        /// Phone time to make one 256 px thumbnail (MediaStore thumbnail cache, then WebP encode).
        var thumbnailWork: TimeInterval = 0.006
        /// Phone time to make one 1600 px preview.
        var previewWork: TimeInterval = 0.030
        var phoneThreads = 4
    }

    var phones: [BrowsablePhone]
    var onPhonesChanged: (() -> Void)?
    var info = PhoneBrowseInfo(places: [], writable: false, media: .full, documents: true)
    var media: [PhoneFileEntry] = []
    var files: [PhoneFileEntry] = []
    var folders: [String: [PhoneFileEntry]] = [:]
    var simulated: Network?
    var thumbnailBytes: [String: Data] = [:]
    var defaultThumbnail = UIFakeImages.jpeg(width: 256, height: 256, seed: 1)
    var previewImage = UIFakeImages.jpeg(width: 1600, height: 1200, seed: 2, quality: 0.6)
    var uploadResult: Result<Void, PhoneFilesError> = .success(())

    private(set) var thumbnailRequests: [(lane: String, keys: [String])] = []
    private(set) var cancelledThumbnailRequests = 0
    private(set) var previewRequests = 0
    private(set) var cancelledPreviews = 0
    private(set) var rangeRequests = 0
    private(set) var cancelledRanges = 0
    private(set) var downloads: [(refs: [PhoneRef], directory: URL, purpose: PhoneDownloadPurpose)] = []
    private(set) var uploads: [(urls: [URL], placeId: String, path: String)] = []
    private(set) var listRequests: [(kind: String, cursor: String?)] = []
    private var lanes: [String: UUID] = [:]

    init(phones: [BrowsablePhone] = [BrowsablePhone(id: UIFakeImages.phoneID, name: "OnePlus 11", browsable: true, route: .lan)]) {
        self.phones = phones
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping () -> Void) {
        if seconds <= 0 {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
        }
    }

    private func wire(_ bytes: Int) -> TimeInterval {
        guard let simulated else { return 0 }
        return Double(bytes) / simulated.bandwidth
    }

    func places(phoneID: String, completion: @escaping (Result<PhoneBrowseInfo, PhoneFilesError>) -> Void) {
        let info = self.info
        after(simulated?.rtt ?? 0) { completion(.success(info)) }
    }

    func listFiles(phoneID: String, placeId: String, path: String, sort: PhoneFileSort, descending: Bool, cursor: String?,
                   completion: @escaping (Result<PhoneFilesPage, PhoneFilesError>) -> Void) {
        listRequests.append(("files:\(placeId)/\(path)", cursor))
        let all = folders["\(placeId)/\(path)"] ?? []
        let start = Int(cursor ?? "0") ?? 0
        let page = Array(all.dropFirst(start).prefix(200))
        let next = start + page.count < all.count ? String(start + page.count) : nil
        let writable = info.writable
        after((simulated?.rtt ?? 0) + wire(page.count * 120)) {
            completion(.success(PhoneFilesPage(entries: page, folderCount: all.filter(\.isDirectory).count,
                                               fileCount: all.filter { !$0.isDirectory }.count, nextCursor: next, writable: writable)))
        }
    }

    func listMedia(phoneID: String, kind: PhoneMediaKind, cursor: String?, limit: Int,
                   completion: @escaping (Result<PhoneMediaPage, PhoneFilesError>) -> Void) {
        listRequests.append((kind.rawValue, cursor))
        let all: [PhoneFileEntry]
        switch kind {
        case .media: all = media
        case .files: all = files
        case .recent: all = (media.prefix(20) + files.prefix(20)).sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        let start = Int(cursor ?? "0") ?? 0
        let page = Array(all.dropFirst(start).prefix(limit))
        let next = start + page.count < all.count ? String(start + page.count) : nil
        let access = info.media
        after((simulated?.rtt ?? 0) + wire(page.count * 140)) {
            completion(.success(PhoneMediaPage(items: kind == .media && access == .none ? [] : page, nextCursor: next, access: access, indexing: false)))
        }
    }

    func thumbnails(phoneID: String, entries: [PhoneFileEntry], size: Int, lane: String,
                    deliver: @escaping (PhoneFileEntry, PhoneImage) -> Void,
                    finished: @escaping (Result<[PhoneFileEntry], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        let token = UUID()
        if lanes[lane] != nil { cancelledThumbnailRequests += 1 }
        lanes[lane] = token
        thumbnailRequests.append((lane, entries.map(\.id)))
        let live = { [weak self] in self?.lanes[lane] == token }
        var clock = simulated?.rtt ?? 0
        let threads = Double(max(1, simulated?.phoneThreads ?? 1))
        var missing: [PhoneFileEntry] = []
        for (index, entry) in entries.enumerated() {
            guard let data = thumbnailBytes[entry.id] ?? (entry.hasThumbnail ? defaultThumbnail : nil) else {
                missing.append(entry)
                continue
            }
            // Phone work runs on several threads; the link carries one batch after another.
            let work = (simulated?.thumbnailWork ?? 0) / threads
            clock += work + wire(data.count)
            let image = PhoneImage(data: data, mimeType: "image/jpeg", width: 256, height: 256, tint: UInt32(0x334455 + index * 0x010101))
            after(clock) { if live() { deliver(entry, image) } }
        }
        after(clock + 0.0005) { [weak self] in
            guard live() else { return }
            self?.lanes[lane] = nil
            finished(.success(missing))
        }
        return PhoneFilesCancellable { [weak self] in
            guard let self, self.lanes[lane] == token else { return }
            self.lanes[lane] = nil
            self.cancelledThumbnailRequests += 1
        }
    }

    func preview(phoneID: String, entry: PhoneFileEntry, size: Int,
                 completion: @escaping (Result<PhoneImage, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        previewRequests += 1
        var cancelled = false
        let data = previewImage
        let delay = (simulated?.rtt ?? 0) + (simulated?.previewWork ?? 0) + wire(data.count)
        after(delay) { if !cancelled { completion(.success(PhoneImage(data: data, mimeType: "image/jpeg", width: 1600, height: 1200, tint: 0x223344))) } }
        return PhoneFilesCancellable { [weak self] in
            cancelled = true
            self?.cancelledPreviews += 1
        }
    }

    func range(phoneID: String, entry: PhoneFileEntry, offset: Int64, length: Int64,
               progress: @escaping (Int64) -> Void,
               completion: @escaping (Result<Data, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        rangeRequests += 1
        var cancelled = false
        let parts = max(1, Int(length / 32_768))
        let partTime = wire(32_768)
        for part in 1...parts {
            after((simulated?.rtt ?? 0) + partTime * Double(part)) { if !cancelled { progress(Int64(part) * 32_768) } }
        }
        after((simulated?.rtt ?? 0) + partTime * Double(parts) + 0.0005) {
            if !cancelled { completion(.success(Data(count: Int(length)))) }
        }
        return PhoneFilesCancellable { [weak self] in
            cancelled = true
            self?.cancelledRanges += 1
        }
    }

    func download(phoneID: String, refs: [PhoneRef], into directory: URL, purpose: PhoneDownloadPurpose,
                  progress: @escaping (PhoneTransferProgress) -> Void,
                  completion: @escaping (Result<[URL], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        downloads.append((refs, directory, purpose))
        var cancelled = false
        let all = media + files + folders.values.flatMap { $0 }
        after(simulated?.rtt ?? 0) {
            guard !cancelled else { return }
            progress(PhoneTransferProgress(phase: .transferring, filesDone: 0, filesTotal: refs.count, bytesDone: 0, bytesTotal: 1000))
            var urls: [URL] = []
            for ref in refs {
                let name = all.first { $0.ref == ref }?.name ?? "item"
                let url = directory.appendingPathComponent(name)
                try? Data("x".utf8).write(to: url)
                urls.append(url)
            }
            completion(.success(urls))
        }
        return PhoneFilesCancellable { cancelled = true }
    }

    func upload(phoneID: String, urls: [URL], placeId: String, path: String,
                progress: @escaping (PhoneTransferProgress) -> Void,
                completion: @escaping (Result<Void, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        uploads.append((urls, placeId, path))
        let result = uploadResult
        after(0) { completion(result) }
        return .none
    }
}

enum UIFakeImages {
    static let phoneID = "22222222-2222-2222-2222-222222222222"

    /// A deterministic photo-like image: a soft two-colour gradient with a few shapes.
    static func cgImage(width: Int, height: Int, seed: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [
            [(0.98, 0.62, 0.38), (0.35, 0.20, 0.55)], [(0.30, 0.65, 0.85), (0.05, 0.18, 0.35)],
            [(0.55, 0.80, 0.45), (0.12, 0.35, 0.22)], [(0.95, 0.85, 0.55), (0.75, 0.35, 0.25)],
            [(0.70, 0.75, 0.85), (0.25, 0.28, 0.40)], [(0.92, 0.55, 0.65), (0.30, 0.15, 0.30)],
        ]
        let palette = palettes[abs(seed) % palettes.count]
        let colors = palette.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        var rng = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        func next() -> CGFloat {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(rng >> 33) / CGFloat(UInt32.max >> 1)
        }
        for _ in 0..<5 {
            context.setFillColor(CGColor(red: next(), green: next(), blue: next(), alpha: 0.35))
            let size = CGFloat(min(width, height)) * (0.2 + next() * 0.4)
            context.fillEllipse(in: CGRect(x: next() * CGFloat(width), y: next() * CGFloat(height), width: size, height: size))
        }
        return context.makeImage()!
    }

    static func jpeg(width: Int, height: Int, seed: Int, quality: Double = 0.72) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage(width: width, height: height, seed: seed),
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func decoded(seed: Int, size: Int = 256) -> PhoneDecodedImage {
        PhoneDecodedImage(image: cgImage(width: size, height: size, seed: seed), tint: nil)
    }

    static let base = Date(timeIntervalSince1970: 1_792_999_260) // 26 October 2026, 09:41 local-ish

    static func media(_ count: Int, now: Date = base) -> [PhoneFileEntry] {
        (0..<count).map { index in
            let video = index % 7 == 3
            return PhoneFileEntry(ref: .media(id: String(10_000 + index)),
                                  name: video ? "VID_2026\(String(format: "%04d", index)).mp4" : "IMG_2026\(String(format: "%04d", index)).jpg",
                                  isDirectory: false, size: Int64(2_400_000 + index * 1_337), modified: now.addingTimeInterval(-Double(index) * 5_400),
                                  mimeType: video ? "video/mp4" : "image/jpeg", hasThumbnail: true, width: 4000, height: 3000,
                                  durationMs: video ? Int64(14_000 + index * 900) : nil, location: index % 5 == 0 ? "Screenshots" : "Camera")
        }
    }

    static func documents(now: Date = base) -> [PhoneFileEntry] {
        let items: [(String, String, String, Int64)] = [
            ("Invoice October.pdf", "application/pdf", "Documents/Invoices", 284_112),
            ("Boarding pass BLR-DEL.pdf", "application/pdf", "Download/Bridgey", 91_230),
            ("Quarterly plan.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "Documents", 48_200),
            ("Notes from Mahima.txt", "text/plain", "Documents", 3_410),
            ("Project deck.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation", "Documents/Work", 5_480_000),
            ("Lease agreement.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "Documents", 132_000),
            ("Photos backup.zip", "application/zip", "Download/Bridgey", 812_000_000),
            ("Recipe.md", "text/markdown", "Documents", 2_100),
        ]
        return items.enumerated().map { index, item in
            PhoneFileEntry(ref: .place(placeId: "Zr8m2Pq0aLk4xT7bNc1yWe", path: item.2, name: item.0), name: item.0, isDirectory: false,
                           size: item.3, modified: now.addingTimeInterval(-Double(index) * 20_000 - 1_800), mimeType: item.1,
                           hasThumbnail: item.1 == "application/pdf", location: item.2)
        }
    }

    static func folder(now: Date = base) -> [PhoneFileEntry] {
        let place = "q3Jx0bVv1eG7tq8Wm2l5wA"
        var entries = ["2019", "Beach", "Day trips", "Family"].enumerated().map { index, name in
            PhoneFileEntry(ref: .place(placeId: place, path: "Trip", name: name), name: name, isDirectory: true, size: nil,
                           modified: now.addingTimeInterval(-Double(index + 1) * 86_400 * 3), mimeType: nil, hasThumbnail: false)
        }
        entries += (0..<9).map { index in
            PhoneFileEntry(ref: .place(placeId: place, path: "Trip", name: "IMG_\(4410 + index).HEIC"), name: "IMG_\(4410 + index).HEIC",
                           isDirectory: false, size: Int64(3_100_000 + index * 91_000), modified: now.addingTimeInterval(-Double(index) * 3_600 - 600),
                           mimeType: "image/heic", hasThumbnail: true)
        }
        entries.append(PhoneFileEntry(ref: .place(placeId: place, path: "Trip", name: "Itinerary.pdf"), name: "Itinerary.pdf", isDirectory: false,
                                      size: 412_000, modified: now.addingTimeInterval(-86_400 * 9), mimeType: "application/pdf", hasThumbnail: true))
        return entries
    }

    static let places = [
        PhonePlace(id: "default", label: "Download/Bridgey", available: true, freeBytes: 81_604_378_624),
        PhonePlace(id: "q3Jx0bVv1eG7tq8Wm2l5wA", label: "Pictures", available: true, freeBytes: 81_604_378_624),
        PhonePlace(id: "Zr8m2Pq0aLk4xT7bNc1yWe", label: "Documents", available: true, freeBytes: 81_604_378_624),
        PhonePlace(id: "Hh5c9Vd2kQe8rT1uYp3oZx", label: "Trip (USB drive)", available: false, freeBytes: nil),
    ]
}
