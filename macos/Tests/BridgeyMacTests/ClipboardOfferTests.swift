import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

/// Clipboard offers (`clipboard_files_draft1`): the wire model, limits, eager pushes, the cache,
/// de-duplication and the activity stream. Nothing here touches NSPasteboard.general or the
/// real Application Support folder.
final class ClipboardOfferTests: XCTestCase {
    private let offerID = "5b1f3a5e-7d0c-4f6e-9a51-0c2f6f7d1e0b"

    private func hash(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }

    private func item(_ index: Int, _ kind: ClipboardItemKind, size: Int64 = 10, name: String? = nil, mime: String? = nil,
                      inline: Data? = nil) -> ClipboardOfferItem {
        ClipboardOfferItem(
            index: index, kind: kind,
            mime: mime ?? (kind == .image ? "image/png" : kind == .text ? "text/plain" : kind == .html ? "text/html" : "application/pdf"),
            name: name ?? (kind == .file ? "report.pdf" : nil),
            size: inline.map { Int64($0.count) } ?? size,
            sha256: inline.map(hash),
            inline: inline?.base64EncodedString()
        )
    }

    private func offer(_ items: [ClipboardOfferItem], id: String? = nil) -> ClipboardOffer {
        ClipboardOffer(offerId: id ?? offerID, createdAt: 1_786_550_000_000, sensitive: nil, items: items)
    }

    private func encoded(_ value: ClipboardOffer) -> Data { try! JSONEncoder().encode(value) }

    // MARK: Validation

    func testValidOffersDecode() throws {
        let media = offer([item(0, .image, size: 2_202_009), item(1, .file, size: 356_515_840, name: "video.mp4", mime: "video/mp4")])
        XCTAssertEqual(ClipboardOffer.decode(encoded(media)), media)
        let text = offer([item(0, .text, inline: Data("hello".utf8)), item(1, .html, size: 50_000)])
        XCTAssertEqual(ClipboardOffer.decode(encoded(text))?.items.count, 2)
        // The shape in docs/protocol.md, written by hand.
        let json = """
        {"version":1,"offerId":"\(offerID)","createdAt":1786550000000,"sensitive":false,
         "items":[{"index":0,"kind":"file","mime":"video/mp4","name":"clips/video.mp4","size":356515840}]}
        """
        let decoded = try XCTUnwrap(ClipboardOffer.decode(Data(json.utf8)))
        XCTAssertEqual(decoded.items[0].name, "video.mp4", "receivers keep only the last path component")
        XCTAssertNil(decoded.items[0].sha256)
    }

    func testRejectsMixedOrMalformedShapes() {
        XCTAssertNil(offer([item(0, .html)]).validated(), "html without text")
        XCTAssertNil(offer([item(0, .text), item(1, .image)]).validated(), "text mixed with media")
        XCTAssertNil(offer([item(0, .text), item(1, .text)]).validated(), "two text items")
        XCTAssertNil(offer([item(0, .html), item(1, .text)]).validated(), "html first")
        XCTAssertNil(offer([]).validated(), "no items")
        XCTAssertNil(offer([item(1, .image)]).validated(), "index must be the position")
        XCTAssertNil(offer([item(0, .file, name: "")]).validated(), "files need a name")
        XCTAssertNil(offer([item(0, .file, name: "..")]).validated())
        XCTAssertNil(offer([item(0, .image, mime: "png")]).validated(), "mime is type/subtype")
        XCTAssertNil(offer([item(0, .image, mime: "image/png\n")]).validated())
        XCTAssertNil(offer([item(0, .image, size: -1)]).validated())
        XCTAssertNil(offer([item(0, .image, size: ClipboardOfferLimits.maximumItemSize + 1)]).validated())
        XCTAssertNotNil(offer([item(0, .image, size: ClipboardOfferLimits.maximumItemSize)]).validated())
        XCTAssertNil(offer([item(0, .image)], id: "not-a-uuid").validated())
        var wrongVersion = offer([item(0, .image)])
        wrongVersion.version = 2
        XCTAssertNil(wrongVersion.validated())
        var badHash = item(0, .image)
        badHash.sha256 = Data(repeating: 1, count: 31).base64EncodedString()
        XCTAssertNil(offer([badHash]).validated())
        XCTAssertNil(ClipboardOffer.decode(Data(#"{"version":1,"offerId":"\#(offerID)","createdAt":1,"items":[{"index":0,"kind":"sticker","mime":"image/png","size":1}]}"#.utf8)),
                     "unknown kinds are rejected")
    }

    func testItemCountIsBounded() {
        let hundred = (0..<100).map { item($0, .image) }
        XCTAssertNotNil(offer(hundred).validated())
        XCTAssertNil(offer(hundred + [item(100, .image)]).validated())
    }

    func testInlineDataMustMatchSizeHashAndBudget() {
        let data = Data("tiny".utf8)
        var wrongSize = item(0, .image, inline: data)
        wrongSize.size += 1
        XCTAssertNil(offer([wrongSize]).validated())
        var wrongHash = item(0, .image, inline: data)
        wrongHash.sha256 = hash(Data("other".utf8))
        XCTAssertNil(offer([wrongHash]).validated())
        var noHash = item(0, .image, inline: data)
        noHash.sha256 = nil
        XCTAssertNil(offer([noHash]).validated(), "inline needs sha256")
        let half = Data(repeating: 7, count: ClipboardOfferLimits.maximumInlineBytes / 2)
        XCTAssertNotNil(offer([item(0, .image, inline: half), item(1, .image, inline: half)]).validated())
        XCTAssertNil(offer([item(0, .image, inline: half), item(1, .image, inline: half + Data([1]))]).validated(),
                     "all inline items together stay within 16 KiB")
    }

    func testOversizedPlaintextIsRejectedAndSendingStaysWithinTheLimit() throws {
        let longName = String(repeating: "n", count: 250) + ".pdf"
        let longMime = "application/" + String(repeating: "x", count: 200)
        let many = (0..<100).map { item($0, .file, name: longName, mime: longMime) }
        let big = offer(many)
        XCTAssertGreaterThan(encoded(big).count, ClipboardOfferLimits.maximumPlaintextBytes)
        XCTAssertNil(ClipboardOffer.decode(encoded(big)), "over 40,960 bytes")
        let (sent, data) = try XCTUnwrap(big.encodedForSending())
        XCTAssertLessThanOrEqual(data.count, ClipboardOfferLimits.maximumPlaintextBytes)
        XCTAssertEqual(sent.items.count, 100, "shortened names keep every item")
        XCTAssertTrue(sent.items.allSatisfy { $0.name!.hasSuffix(".pdf") && $0.name!.count <= 64 })
        XCTAssertNotNil(ClipboardOffer.decode(data))
        // The frame stays under the transport limit once encrypted and wrapped.
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let sealed = try encrypt(data, key: key)
        let frame = try JSONEncoder().encode(PairingMessage(kind: "clipboard.offer", sessionId: UUID().uuidString,
                                                             messageId: UUID().uuidString, nonce: sealed.nonce, ciphertext: sealed.ciphertext))
        XCTAssertLessThan(frame.count, maximumProtocolFrameBytes)
    }

    func testTextOffersInlineWhatFitsAndHashEverything() throws {
        let long = String(repeating: "a", count: 40_000)
        let (offer, sources) = ClipboardOfferBuilder.text(long, html: "<b>x</b>", sensitive: true)
        XCTAssertEqual(offer.items.map(\.kind), [.text, .html])
        XCTAssertNil(offer.items[0].inline, "40 KB of text is fetched, not inlined")
        XCTAssertNotNil(offer.items[1].inline, "the small HTML rides along")
        XCTAssertEqual(offer.sensitive, true)
        XCTAssertEqual(offer.items[0].sha256, hash(Data(long.utf8)))
        XCTAssertEqual(sources.count, 2)
        XCTAssertNotNil(offer.validated())
    }

    // MARK: Eager pushes

    func testEagerPushesAreCumulativeInIndexOrderAndSkipInline() {
        let items = [
            item(0, .image, size: 10_000_000),
            item(1, .image, inline: Data("x".utf8)),
            item(2, .image, size: 10_000_000),
            item(3, .image, size: 6_000_000),
            item(4, .image, size: 1),
        ]
        XCTAssertEqual(clipboardEagerIndices(items, limit: ClipboardEagerLimit.twentyFiveMB.bytes), [0, 2],
                       "stops at the first item that does not fit")
        XCTAssertEqual(clipboardEagerIndices(items, limit: ClipboardEagerLimit.hundredMB.bytes), [0, 2, 3, 4])
        XCTAssertEqual(clipboardEagerIndices(items, limit: ClipboardEagerLimit.askWhenPasting.bytes), [])
        XCTAssertEqual(clipboardEagerIndices([item(0, .image, size: 25_000_000)], limit: 25_000_000), [0], "at the threshold counts")
        XCTAssertEqual(clipboardEagerIndices([item(0, .image, size: 25_000_001)], limit: 25_000_000), [])
    }

    func testEagerLimitSettingDefaultsToTwentyFiveMegabytes() {
        XCTAssertEqual(ClipboardEagerLimit.default.bytes, 25_000_000)
        XCTAssertEqual(ClipboardEagerLimit(bytes: 123), .default, "unknown stored values fall back")
        XCTAssertEqual(ClipboardEagerLimit(bytes: 0), .askWhenPasting)
        XCTAssertEqual(ClipboardEagerLimit.allCases.map(eagerLimitTitle), ["5 MB", "25 MB", "100 MB", "Always ask when pasting"])
    }

    // MARK: De-duplication and the copy rules

    private func snapshot(changeCount: Int = 1, types: [String] = [], text: String? = nil, files: [ClipboardFileRef] = [],
                          images: [ClipboardImageClip] = [], folders: Bool = false, offers: Bool = true) -> ClipboardSnapshot {
        ClipboardSnapshot(changeCount: changeCount, types: types, text: text, html: nil, files: files, images: images,
                          skippedFolders: folders, offersAvailable: offers)
    }

    private func file(_ path: String, size: Int64 = 100, modified: TimeInterval = 1_000) -> ClipboardFileRef {
        ClipboardFileRef(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent, size: size,
                         modified: Date(timeIntervalSince1970: modified), mime: "video/mp4")
    }

    func testFileFingerprintUsesPathSizeAndTimeWithoutReadingContent() {
        // These files do not exist: the fingerprint never opens them.
        let base = clipboardFileFingerprint([("/nowhere/video.mp4", 2_000_000_000, Date(timeIntervalSince1970: 1_000))])
        XCTAssertEqual(base, clipboardFileFingerprint([("/nowhere/video.mp4", 2_000_000_000, Date(timeIntervalSince1970: 1_000))]))
        XCTAssertNotEqual(base, clipboardFileFingerprint([("/nowhere/video.mp4", 2_000_000_001, Date(timeIntervalSince1970: 1_000))]))
        XCTAssertNotEqual(base, clipboardFileFingerprint([("/nowhere/video.mp4", 2_000_000_000, Date(timeIntervalSince1970: 1_001))]))
        XCTAssertNotEqual(base, clipboardFileFingerprint([("/nowhere/other.mp4", 2_000_000_000, Date(timeIntervalSince1970: 1_000))]))
    }

    func testCopiedFilesAndImagesAreOfferedOnceEach() {
        var filter = AutoClipboardFilter()
        let video = file("/Users/me/video.mp4")
        XCTAssertEqual(filter.decide(snapshot(changeCount: 1, files: [video])), .offerFiles([video], skippedFolders: false))
        XCTAssertEqual(filter.decide(snapshot(changeCount: 2, files: [video])), .skip(.duplicate), "same path, size and time")
        let touched = file("/Users/me/video.mp4", modified: 2_000)
        XCTAssertEqual(filter.decide(snapshot(changeCount: 3, files: [touched])), .offerFiles([touched], skippedFolders: false))
        let image = ClipboardImageClip(data: Data([1, 2, 3]), mime: "image/png")
        XCTAssertEqual(filter.decide(snapshot(changeCount: 4, images: [image])), .offerImages([image]))
        XCTAssertEqual(filter.decide(snapshot(changeCount: 5, images: [ClipboardImageClip(data: Data([1, 2, 3]), mime: "image/png")])), .skip(.duplicate))
    }

    func testLongTextIsOfferedOnlyWhenOffersAreAvailable() {
        let long = String(repeating: "a", count: maximumClipboardContentBytes + 1)
        var filter = AutoClipboardFilter()
        XCTAssertEqual(filter.decide(snapshot(types: ["public.utf8-plain-text"], text: long, offers: false)), .skip(.tooLarge),
                       "older peers keep the 32 KiB limit")
        var offering = AutoClipboardFilter()
        XCTAssertEqual(offering.decide(snapshot(types: ["public.utf8-plain-text"], text: long)), .offerText(text: long, html: nil))
        var small = AutoClipboardFilter()
        XCTAssertEqual(small.decide(snapshot(types: ["public.utf8-plain-text"], text: "short")), .send(text: "short", html: nil),
                       "short text keeps clipboard.update even between edition peers")
    }

    func testFoldersAreSkippedAndSecretsAndOwnWritesNeverOffered() {
        var filter = AutoClipboardFilter()
        XCTAssertEqual(filter.decide(snapshot(changeCount: 1, types: ["public.file-url"], folders: true)), .skip(.folder))
        let doc = file("/Users/me/a.pdf")
        XCTAssertEqual(filter.decide(snapshot(changeCount: 2, types: ["public.file-url"], files: [doc], folders: true)),
                       .offerFiles([doc], skippedFolders: true), "files go, folders are reported")
        var secret = AutoClipboardFilter()
        XCTAssertEqual(secret.decide(snapshot(types: ["public.png", "org.nspasteboard.ConcealedType"],
                                              images: [ClipboardImageClip(data: Data([9]), mime: "image/png")])), .skip(.secret))
        var own = AutoClipboardFilter()
        own.noteOwnWrite(changeCount: 7)
        XCTAssertEqual(own.decide(snapshot(changeCount: 7, files: [doc])), .skip(.ownWrite))
        XCTAssertTrue(own.isOwnWrite(7))
    }

    func testImagesFromAnOlderPeerViewStayNotText() {
        var filter = AutoClipboardFilter()
        XCTAssertEqual(filter.decide(snapshot(types: ["public.png"], offers: false)), .skip(.notText))
    }

    @MainActor func testPasteboardImagesPreferPngAndConvertTiff() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        let tiff = try XCTUnwrap(rep.tiffRepresentation)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let tiffOnly = NSPasteboardItem()
        tiffOnly.setData(tiff, forType: .tiff)
        let converted = try XCTUnwrap(ClipboardContentReader.image(from: tiffOnly))
        XCTAssertEqual(converted.mime, "image/png", "Android cannot decode TIFF")
        XCTAssertNotNil(NSBitmapImageRep(data: converted.data))
        let both = NSPasteboardItem()
        both.setData(tiff, forType: .tiff)
        both.setData(png, forType: .png)
        XCTAssertEqual(ClipboardContentReader.image(from: both)?.data, png)
    }

    // MARK: Cache

    private func temporaryCache(maximumBytes: Int64 = ClipboardOfferLimits.cacheMaximumBytes, clock: @escaping () -> Date = Date.init) -> ClipboardCache {
        ClipboardCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("clipcache-\(UUID().uuidString)", isDirectory: true),
                       maximumBytes: maximumBytes, clock: clock)
    }

    private func store(_ cache: ClipboardCache, offer: String, index: Int, bytes: Int, modified: Date? = nil) throws -> URL {
        let url = try cache.prepareItem(offerID: offer, index: index, name: "item-\(index).bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes)))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        return url
    }

    func testCacheFoldersAreOwnerOnlyInTheEditionFolder() throws {
        XCTAssertTrue(ClipboardCache.defaultRoot().path.hasSuffix("/Application Support/\(Edition.supportFolderName)/ClipboardCache"))
        let cache = temporaryCache()
        defer { cache.clear() }
        let url = try store(cache, offer: "a", index: 0, bytes: 3)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        XCTAssertEqual(cache.cachedFile(offerID: "a", index: 0)?.lastPathComponent, "item-0.bin")
    }

    func testSupersededItemsAreDeletedUnlessHandedOut() throws {
        let cache = temporaryCache()
        defer { cache.clear() }
        _ = try store(cache, offer: "old", index: 0, bytes: 3)
        _ = try store(cache, offer: "old", index: 1, bytes: 3)
        cache.markHandedOut(offerID: "old", index: 1)
        cache.removeSuperseded(offerID: "old")
        XCTAssertNil(cache.cachedFile(offerID: "old", index: 0))
        XCTAssertNotNil(cache.cachedFile(offerID: "old", index: 1), "a pasted file in a draft must stay readable")
    }

    func testCacheEvictsOldAndOversizedButKeepsProtectedOffers() throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let cache = temporaryCache(maximumBytes: 1_000) { now }
        defer { cache.clear() }
        _ = try store(cache, offer: "stale", index: 0, bytes: 10, modified: now.addingTimeInterval(-25 * 3600))
        _ = try store(cache, offer: "current", index: 0, bytes: 10, modified: now.addingTimeInterval(-26 * 3600))
        cache.enforceLimits(protecting: ["current"])
        XCTAssertNil(cache.cachedFile(offerID: "stale", index: 0), "older than 24 hours")
        XCTAssertNotNil(cache.cachedFile(offerID: "current", index: 0), "the current offer is never evicted")

        _ = try store(cache, offer: "first", index: 0, bytes: 600, modified: now.addingTimeInterval(-3_000))
        _ = try store(cache, offer: "second", index: 0, bytes: 600, modified: now.addingTimeInterval(-2_000))
        _ = try store(cache, offer: "running", index: 0, bytes: 600, modified: now.addingTimeInterval(-9_000))
        now = now.addingTimeInterval(1)
        cache.enforceLimits(protecting: ["current", "running"])
        XCTAssertNil(cache.cachedFile(offerID: "first", index: 0), "oldest goes first")
        XCTAssertNil(cache.cachedFile(offerID: "second", index: 0))
        XCTAssertNotNil(cache.cachedFile(offerID: "running", index: 0), "running transfers stay")
    }

    func testLeftoverPartialsAreRemovedAtLaunch() throws {
        let cache = temporaryCache()
        defer { cache.clear() }
        let final = try cache.prepareItem(offerID: "o", index: 0, name: "video.mp4")
        let partial = cache.partialURL(for: final)
        FileManager.default.createFile(atPath: partial.path, contents: Data([1]))
        XCTAssertNil(cache.cachedFile(offerID: "o", index: 0), "a partial is not a cached item")
        cache.removePartials()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    // MARK: Activity stream

    private func clip(_ kind: ActivityKind, content: String, count: Int = 1, bytes: Int64 = 2_100_000, file: String? = nil,
                      automatic: Bool = false, previews: Bool = true) -> ActivityItem {
        ActivityHistory.add([], kind: kind, deviceID: "phone", deviceName: "OnePlus 11", fileName: previews ? file : nil,
                            automatic: automatic, count: count, bytes: bytes, content: content,
                            now: Date(timeIntervalSince1970: 1_800_000_000), nextID: 1)[0]
    }

    func testStreamTitlesForClipboardOffers() {
        let size = ByteCountFormatter.string(fromByteCount: 2_100_000, countStyle: .file)
        XCTAssertEqual(ActivityText.title(clip(.clipOfferReceived, content: "image"), showPreviews: true), "Copied image from OnePlus 11 (\(size))")
        let video = clip(.clipPasted, content: "file", bytes: 340_000_000, file: "video.mp4")
        let big = ByteCountFormatter.string(fromByteCount: 340_000_000, countStyle: .file)
        XCTAssertEqual(ActivityText.title(video, showPreviews: true), "Pasted video.mp4 from OnePlus 11 (\(big))")
        XCTAssertEqual(ActivityText.title(video, showPreviews: false), "Pasted a file from OnePlus 11 (\(big))", "previews off: no names")
        XCTAssertEqual(ActivityText.title(clip(.clipOfferSent, content: "file", count: 3), showPreviews: true), "Copied 3 files")
        XCTAssertEqual(ActivityText.title(clip(.clipOfferSent, content: "image"), showPreviews: true), "Copied image (\(size))")
        XCTAssertEqual(ActivityText.title(clip(.clipOfferReceived, content: "text"), showPreviews: true), "Copied text from OnePlus 11 (\(size))")
        XCTAssertEqual(ActivityText.title(clip(.clipOfferReceived, content: "image", count: 2), showPreviews: true), "Copied 2 images from OnePlus 11")
        XCTAssertEqual(ActivityText.title(clip(.clipPasteFailed, content: "file"), showPreviews: true), "Couldn\u{2019}t paste from OnePlus 11")
        XCTAssertEqual(ActivityText.detail(clip(.clipOfferSent, content: "image", automatic: true), showPreviews: true),
                       "Automatic, ready to paste on OnePlus 11")
        XCTAssertEqual(ActivityText.detail(clip(.clipOfferReceived, content: "image"), showPreviews: true), "Ready to paste here")
        XCTAssertEqual(activityVisual(clip(.clipOfferReceived, content: "image")).symbol, "photo")
        XCTAssertEqual(activityVisual(clip(.clipOfferReceived, content: "file")).symbol, "doc")
    }

    @MainActor func testPreviewsOffKeepsNoFileNameAndPastesMerge() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let log = ActivityLog(store: nil) { clock }
        log.record(.clipOfferReceived, deviceID: "phone", deviceName: "OnePlus 11", fileName: "secret-plan.pdf",
                   count: 1, bytes: 10, content: "file", previews: false)
        XCTAssertNil(log.items[0].fileName)
        log.record(.clipPasted, deviceID: "phone", deviceName: "OnePlus 11", fileName: "a.pdf", count: 1, bytes: 100, content: "file", previews: true)
        clock = clock.addingTimeInterval(20)
        log.record(.clipPasted, deviceID: "phone", deviceName: "OnePlus 11", fileName: "b.pdf", count: 1, bytes: 50, content: "file", previews: true)
        XCTAssertEqual(log.items.count, 2, "two pastes within a minute read as one")
        XCTAssertEqual(log.items[0].count, 2)
        XCTAssertEqual(log.items[0].bytes, 150)
        XCTAssertNil(log.items[0].fileName)
        XCTAssertEqual(ActivityText.title(log.items[0], showPreviews: true), "Pasted 2 files from OnePlus 11")
        clock = clock.addingTimeInterval(61)
        log.record(.clipPasted, deviceID: "phone", deviceName: "OnePlus 11", count: 1, bytes: 5, content: "image", previews: true)
        XCTAssertEqual(log.items.count, 3)
    }

    func testClipItemsRoundTripWithSizeAndContentOnly() throws {
        let item = clip(.clipOfferReceived, content: "file", count: 3, bytes: 42, file: nil)
        let data = try ActivityHistory.encode([item])
        let keys = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first?.keys)
        XCTAssertEqual(Set(keys), ["id", "kind", "deviceID", "deviceName", "sensitive", "automatic", "count", "at", "bytes", "content"])
        XCTAssertEqual(ActivityHistory.decode(data, now: item.at), [item])
        let ping = ActivityHistory.add([], kind: .pingSent, deviceID: "d", deviceName: "P", count: 5, bytes: 9, content: "file",
                                       now: item.at, nextID: 1)[0]
        XCTAssertNil(ping.bytes)
        XCTAssertNil(ping.content)
        XCTAssertEqual(ping.count, 1, "only offers carry an item count")
    }
}
