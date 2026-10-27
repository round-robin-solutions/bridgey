import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import BridgeyMac

/// The grid's whole thumbnail path as it runs in the app: the scheduler, the real browse client
/// (PhoneFilesController, with its lanes, chunks and media budget) and the disk cache, against a phone on a
/// simulated LAN that answers the way BrowseServer does. The UI tests drive the scheduler with a fake service,
/// which never reports a replaced request as finished; the real client does, synchronously.
@MainActor
final class PhoneThumbnailPipelineTests: XCTestCase {
    private var directory: URL!
    private var phone: LoopbackPhone!
    private var controller: PhoneFilesController!
    private var scheduler: PhoneThumbnailScheduler!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-pipeline-\(UUID().uuidString)", isDirectory: true)
        phone = LoopbackPhone()
        controller = PhoneFilesController(host: phone)
        phone.controller = controller
        phone.link = (latency: 0.02, bytesPerSecond: 20_000_000)
        scheduler = PhoneThumbnailScheduler(service: controller, cache: PhoneThumbnailCache(directory: directory))
        scheduler.setPhone(phone.phoneID)
    }

    override func tearDownWithError() throws {
        scheduler.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// What a phone's camera roll looks like: screenshots, 4:3 photos, 16:9 videos and the odd square.
    private func library(_ count: Int) -> [PhoneFileEntry] {
        let shapes: [(String, Int, Int, String)] = [("Screenshot", 1080, 2412, "image/png"), ("IMG", 4000, 3000, "image/jpeg"),
                                                    ("VID", 1920, 1080, "video/mp4"), ("IMG", 3000, 4000, "image/jpeg"), ("SQ", 1080, 1080, "image/jpeg")]
        return (0..<count).map { index in
            let (prefix, width, height, mime) = shapes[index % shapes.count]
            return PhoneFileEntry(ref: .media(id: String(5_000 + index)), name: "\(prefix)_\(index)", isDirectory: false, size: 2_000_000 + Int64(index),
                                  modified: Date(timeIntervalSince1970: 1_790_000_000 - Double(index)), mimeType: mime, hasThumbnail: true,
                                  width: width, height: height)
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }

    private func filled(_ entries: [PhoneFileEntry]) -> Int { entries.filter { scheduler.box(for: $0).image != nil }.count }

    func testEveryVisibleCellOfAMixedLibraryGetsItsThumbnail() {
        let entries = library(200)
        phone.server = androidLikeThumbnailServer(entries)
        scheduler.setOrder(entries)
        let visible = Array(entries.prefix(36))
        visible.forEach(scheduler.appeared)
        waitUntil(5) { self.filled(visible) == visible.count }
        XCTAssertEqual(filled(visible), visible.count)
    }

    /// Cells keep appearing while the first request is on the wire (the grid laying out its next rows, a
    /// scroll, a page loading): the newer request replaces the older one and both must not end in a loop.
    func testCellsAppearingWhileARequestIsOnTheWireStillFill() {
        let entries = library(200)
        phone.server = androidLikeThumbnailServer(entries)
        scheduler.setOrder(entries)
        entries.prefix(30).forEach(scheduler.appeared)
        pump(0.005)
        entries[30..<36].forEach(scheduler.appeared)
        let visible = Array(entries.prefix(36))
        waitUntil(5) { self.filled(visible) == visible.count }
        let requests = phone.requests(BrowseKind.mediaThumbnails).count
        let cancels = phone.requests(BrowseKind.mediaCancel).count
        XCTAssertEqual(filled(visible), visible.count)
        // One flush asks up to three sizes; the second set of cells needs nothing new, so nothing is replaced.
        XCTAssertLessThanOrEqual(requests, 3, "requests=\(requests)")
        XCTAssertEqual(cancels, 0)
    }

    /// Scrolling away while a request is out replaces it once (the old items are cancelled on the phone) and
    /// the new screen fills; the replaced request reporting back must not start another replacement.
    func testScrollingAwayReplacesTheRequestOnceAndTheNewScreenFills() {
        let entries = library(300)
        phone.server = androidLikeThumbnailServer(entries)
        scheduler.setOrder(entries)
        entries.prefix(30).forEach(scheduler.appeared)
        pump(0.005)
        let first = phone.requests(BrowseKind.mediaThumbnails).count
        entries.prefix(30).forEach(scheduler.disappeared)
        let screen = Array(entries[200..<236])
        screen.forEach(scheduler.appeared)
        waitUntil(5) { self.filled(screen) == screen.count }
        pump(0.2)
        XCTAssertEqual(filled(screen), screen.count)
        XCTAssertLessThanOrEqual(phone.requests(BrowseKind.mediaThumbnails).count, first + 3, "one replacement")
        XCTAssertLessThanOrEqual(phone.requests(BrowseKind.mediaCancel).count, first)
    }

    /// A phone that answers `busy` is asked again after a pause, not on every turn of the run loop.
    func testAFailedRequestIsRetriedAfterAPauseNotInALoop() {
        let entries = library(40)
        phone.server = { kind, payload in
            guard let request = try? JSONDecoder().decode(MediaThumbnailsPayload.self, from: payload) else { return [] }
            return [(FolderKind.placesError, try! FolderJSON.encoder.encode(PlacesErrorPayload(requestId: request.requestId, code: "busy")))]
        }
        scheduler.setOrder(entries)
        entries.prefix(20).forEach(scheduler.appeared)
        pump(1)
        // The first flush's requests (one per size) end together with the first `busy`; no retry within the pause.
        XCTAssertLessThanOrEqual(phone.requests(BrowseKind.mediaThumbnails).count, 3)
        phone.server = androidLikeThumbnailServer(entries)
        let visible = Array(entries.prefix(20))
        waitUntil(5) { self.filled(visible) == visible.count }
        XCTAssertEqual(filled(visible), visible.count, "asked again after the pause")
    }
}

/// A phone that answers media.thumbnails like BrowseServer.thumbnails: each item scaled so its longest edge is
/// the asked size, encoded as JPEG, packed into batches of at most 44 KiB of plaintext, `done` on the last.
@MainActor
func androidLikeThumbnailServer(_ entries: [PhoneFileEntry]) -> (String, Data) -> [(String, Data)] {
    let byMediaID = Dictionary(entries.compactMap { entry -> (String, PhoneFileEntry)? in
        if case let .media(id) = entry.ref { return (id, entry) }
        return nil
    }, uniquingKeysWith: { first, _ in first })
    return { kind, payload in
        guard kind == BrowseKind.mediaThumbnails, let request = try? JSONDecoder().decode(MediaThumbnailsPayload.self, from: payload) else { return [] }
        let size = min(max(request.size, 64), 512)
        var batches: [(String, Data)] = []
        var thumbs: [ThumbPayload] = []
        var gone: [String] = []
        var bytes = 160
        func flush(done: Bool) {
            let batch = MediaThumbnailsBatchPayload(requestId: request.requestId, thumbs: thumbs, missing: gone, done: done)
            batches.append((BrowseKind.mediaThumbnailsBatch, try! FolderJSON.encoder.encode(batch)))
            thumbs = []
            gone = []
            bytes = 160
        }
        for item in request.items {
            guard let id = item.ref.mediaId, let entry = byMediaID[id], let width = entry.width, let height = entry.height else {
                gone.append(item.key)
                continue
            }
            let scale = min(1, Double(size) / Double(max(width, height)))
            let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
            let data = testJPEG(width: w, height: h, seed: Int(id) ?? 0).base64EncodedString()
            let cost = data.count + data.filter { $0 == "/" }.count + 120
            if bytes + cost > BrowseKind.mediaPartPlaintext, !thumbs.isEmpty { flush(done: false) }
            thumbs.append(ThumbPayload(key: item.key, mimeType: "image/jpeg", width: w, height: h, tint: "#446688", data: data))
            bytes += cost
        }
        flush(done: true)
        return batches
    }
}

/// A small photo-like JPEG (gradient plus noise), so decoding does real work.
func testJPEG(width: Int, height: Int, seed: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var state = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
    for y in stride(from: 0, to: height, by: 8) {
        for x in stride(from: 0, to: width, by: 8) {
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = CGFloat(state >> 24) / 255
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: noise, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 8, height: 8))
        }
    }
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return out as Data
}
