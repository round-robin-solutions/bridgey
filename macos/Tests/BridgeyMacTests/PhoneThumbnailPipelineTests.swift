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
        // Three small requests at a time, the rest as slots free; nothing that is still wanted is cancelled.
        XCTAssertLessThanOrEqual(requests, 12, "requests=\(requests)")
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
        XCTAssertLessThanOrEqual(phone.requests(BrowseKind.mediaThumbnails).count, first + 12, "no request storm")
        XCTAssertLessThanOrEqual(phone.requests(BrowseKind.mediaCancel).count, first, "only the requests of the screen left behind")
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
        pump(0.8)
        // The first requests end with `busy`; nothing more is asked during the pause.
        XCTAssertLessThanOrEqual(phone.requests(BrowseKind.mediaThumbnails).count, PhoneThumbnailScheduler.maxInFlight)
        phone.server = androidLikeThumbnailServer(entries)
        let visible = Array(entries.prefix(20))
        waitUntil(5) { self.filled(visible) == visible.count }
        XCTAssertEqual(filled(visible), visible.count, "asked again after the pause")
    }

    /// A fast scroll through 2,000 items, then a stop: the screen where the scroll stops fills, requests for
    /// screens flown past are cancelled rather than answered, and the client never exceeds the phone's budget.
    func testAFastScrollFillsTheScreenWhereItStops() {
        let entries = library(2_000)
        phone.server = androidLikeThumbnailServer(entries, reuseImages: true)
        scheduler.setOrder(entries)
        var start = 0
        while start < 1_800 {
            let screen = Array(entries[start..<(start + 36)])
            scheduler.setVisible(screen, ahead: Array(entries[(start + 36)..<(start + 108)]))
            pump(0.016)
            start += 48
        }
        let stop = Array(entries[1_800..<1_836])
        scheduler.setVisible(stop, ahead: Array(entries[1_836..<1_908]))
        waitUntil(5) { self.filled(stop) == stop.count }
        XCTAssertEqual(filled(stop), stop.count)
        let requests = phone.requests(BrowseKind.mediaThumbnails).count
        let cancels = phone.requests(BrowseKind.mediaCancel).count
        print("FASTSCROLL requests=\(requests) cancels=\(cancels) controller=\(controller.activeMediaRequests)")
        XCTAssertLessThanOrEqual(cancels, requests)
        XCTAssertLessThanOrEqual(controller.activeMediaRequests, BrowseLimits.mediaActive)
    }

    /// Replays what the real phone code sent (BrowseServer and AndroidThumbnails on an emulator's MediaStore,
    /// recorded as JSON: items, then per size the request and its batches) through the grid. Off unless
    /// BRIDGEY_REAL_THUMBS points at a recording, since it is about 700 KB of WebP.
    func testRecordedPhoneAnswersFillTheGrid() throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_REAL_THUMBS"] else { throw XCTSkip("Set BRIDGEY_REAL_THUMBS to a recording") }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        let entries = items.map { item in
            PhoneFileEntry(ref: .media(id: item["mediaId"] as! String), name: item["name"] as! String, isDirectory: false,
                           size: (item["size"] as! NSNumber).int64Value, modified: Date(timeIntervalSince1970: (item["modified"] as! NSNumber).doubleValue / 1000),
                           mimeType: item["mimeType"] as? String, hasThumbnail: true, width: item["width"] as? Int, height: item["height"] as? Int)
        }
        // Per size, the phone's thumbnail for each media ID, as it went on the wire.
        var recorded: [Int: [String: ThumbPayload]] = [:]
        for answer in try XCTUnwrap(root["answers"] as? [[String: Any]]) {
            let request = answer["request"] as! [String: Any]
            let keys = (request["items"] as! [[String: Any]]).map { ($0["key"] as! String, ($0["ref"] as! [String: Any])["mediaId"] as! String) }
            let byKey = Dictionary(uniqueKeysWithValues: keys)
            for batch in answer["batches"] as! [[String: Any]] {
                let decoded = try JSONDecoder().decode(MediaThumbnailsBatchPayload.self, from: JSONSerialization.data(withJSONObject: batch))
                for thumb in decoded.thumbs { recorded[request["size"] as! Int, default: [:]][byKey[thumb.key]!] = thumb }
            }
        }
        var asked: [Int] = []
        phone.server = { kind, payload in
            guard kind == BrowseKind.mediaThumbnails, let request = try? JSONDecoder().decode(MediaThumbnailsPayload.self, from: payload) else { return [] }
            asked.append(request.size)
            var batches: [(String, Data)] = []
            var thumbs: [ThumbPayload] = []
            var bytes = 160
            for item in request.items {
                guard let thumb = recorded[request.size]?[item.ref.mediaId ?? ""] else { continue }
                let cost = thumb.data.count + thumb.data.filter { $0 == "/" }.count + 120
                if bytes + cost > BrowseKind.mediaPartPlaintext, !thumbs.isEmpty {
                    batches.append((BrowseKind.mediaThumbnailsBatch, try! FolderJSON.encoder.encode(MediaThumbnailsBatchPayload(requestId: request.requestId, thumbs: thumbs, missing: [], done: false))))
                    thumbs = []
                    bytes = 160
                }
                thumbs.append(ThumbPayload(key: item.key, mimeType: thumb.mimeType, width: thumb.width, height: thumb.height, tint: thumb.tint, data: thumb.data))
                bytes += cost
            }
            batches.append((BrowseKind.mediaThumbnailsBatch, try! FolderJSON.encoder.encode(MediaThumbnailsBatchPayload(requestId: request.requestId, thumbs: thumbs, missing: [], done: true))))
            for (_, data) in batches { XCTAssertLessThanOrEqual(data.count, BrowseKind.mediaPartPlaintext) }
            return batches
        }
        scheduler.setOrder(entries)
        // The way the grid lays out: the first rows, then the rest of the screen a moment later.
        entries.prefix(7).forEach(scheduler.appeared)
        pump(0.005)
        entries.dropFirst(7).forEach(scheduler.appeared)
        waitUntil(5) { self.filled(entries) == entries.count }
        for entry in entries {
            let image = scheduler.box(for: entry).image
            print("REPLAY \(entry.name) asked \(PhoneThumbnailScheduler.size(for: entry)) got \(image.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "nothing")")
        }
        print("REPLAY requests \(asked) cancels \(phone.requests(BrowseKind.mediaCancel).count)")
        XCTAssertEqual(filled(entries), entries.count)
    }
}

/// A phone that answers media.thumbnails like BrowseServer.thumbnails: each item scaled so its longest edge is
/// the asked size, encoded as JPEG, packed into batches of at most 44 KiB of plaintext, `done` on the last.
@MainActor
func androidLikeThumbnailServer(_ entries: [PhoneFileEntry], reuseImages: Bool = false) -> (String, Data) -> [(String, Data)] {
    let byMediaID = Dictionary(entries.compactMap { entry -> (String, PhoneFileEntry)? in
        if case let .media(id) = entry.ref { return (id, entry) }
        return nil
    }, uniquingKeysWith: { first, _ in first })
    // One JPEG per shape when reusing, so a long run does not spend its time encoding test images.
    var made: [String: String] = [:]
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
            let shape = "\(w)x\(h)"
            let data = reuseImages ? (made[shape] ?? testJPEG(width: w, height: h, seed: 1).base64EncodedString())
                : testJPEG(width: w, height: h, seed: Int(id) ?? 0).base64EncodedString()
            if reuseImages { made[shape] = data }
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
