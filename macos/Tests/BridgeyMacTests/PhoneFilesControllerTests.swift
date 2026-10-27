import Foundation
import XCTest
@testable import BridgeyMac

@MainActor
final class PhoneFilesControllerTests: XCTestCase {
    private var phone: LoopbackPhone!
    private var clock: ManualFolderClock!
    private var controller: PhoneFilesController!
    private let ids = SequentialIDs()

    override func setUp() async throws {
        phone = LoopbackPhone()
        clock = ManualFolderClock()
        let ids = self.ids
        controller = PhoneFilesController(host: phone, clock: clock, makeID: { ids.make() })
        phone.controller = controller
    }

    // MARK: Negotiation and listing

    func testNothingIsSentToAPhoneWithoutTheBrowseKey() {
        phone.browsable = false
        var result: Result<PhoneBrowseInfo, PhoneFilesError>?
        controller.places(phoneID: phone.phoneID) { result = $0 }
        guard case .failure(.notBrowsable) = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertTrue(phone.sent.isEmpty)
    }

    func testPlacesForBrowsingCarryTheWritableAndMediaFields() throws {
        var info: PhoneBrowseInfo?
        controller.places(phoneID: phone.phoneID) { info = try? $0.get() }
        let request = try XCTUnwrap(phone.requests(FolderKind.placesList).first)
        let json = try JSONSerialization.jsonObject(with: request.payload!) as! [String: Any]
        XCTAssertEqual(json["purpose"] as? String, "browse")
        let requestId = json["requestId"] as! String
        phone.deliver(FolderKind.placesListed, BrowsePlacesListedPayload(
            requestId: requestId, mode: .receiverAsks,
            places: [PlaceInfo(placeId: "default", label: "Download/Bridgey", available: true, freeBytes: 5),
                     PlaceInfo(placeId: "q3Jx0bVv1eG7tq8Wm2l5wA", label: "Pictures", available: false, freeBytes: nil)],
            fixedLabel: nil, writable: true, media: "partial", documents: true))
        XCTAssertEqual(info?.places.map(\.label), ["Download/Bridgey", "Pictures"])
        XCTAssertEqual(info?.writable, true)
        XCTAssertEqual(info?.media, .partial)
        XCTAssertEqual(info?.documents, true)
        XCTAssertEqual(controller.inFlight, 0)
    }

    func testListingPagesFollowTheCursorAndKeepTheRefs() throws {
        var pages: [PhoneFilesPage] = []
        controller.listFiles(phoneID: phone.phoneID, placeId: "default", path: "Trip", sort: .modified, descending: true, cursor: nil) {
            if let page = try? $0.get() { pages.append(page) }
        }
        var request = phone.decode(PlacesFilesPayload.self, try XCTUnwrap(phone.requests(BrowseKind.placesFiles).last))
        XCTAssertEqual(request.sort, "modified")
        XCTAssertTrue(request.descending)
        XCTAssertNil(request.cursor)
        let first = (0..<200).map { PlacesFileEntryPayload(name: "IMG_\($0).jpg", dir: false, size: 10, modified: 1_790_000_000_000, mimeType: "image/jpeg", thumb: true) }
        phone.deliver(BrowseKind.placesFilesPage, PlacesFilesPagePayload(requestId: request.requestId, placeId: "default", path: "Trip", entries: first,
                                                                          folderCount: 1, fileCount: 250, nextCursor: "o200", writable: false))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].entries.count, 200)
        XCTAssertEqual(pages[0].nextCursor, "o200")
        XCTAssertEqual(pages[0].entries[3].ref, .place(placeId: "default", path: "Trip", name: "IMG_3.jpg"))
        XCTAssertTrue(pages[0].entries[3].hasThumbnail)

        controller.listFiles(phoneID: phone.phoneID, placeId: "default", path: "Trip", sort: .modified, descending: true, cursor: "o200") {
            if let page = try? $0.get() { pages.append(page) }
        }
        request = phone.decode(PlacesFilesPayload.self, try XCTUnwrap(phone.requests(BrowseKind.placesFiles).last))
        XCTAssertEqual(request.cursor, "o200")
        let rest = [PlacesFileEntryPayload(name: "Beach", dir: true, size: nil, modified: nil, mimeType: nil, thumb: false),
                    // Not addressable: never shown.
                    PlacesFileEntryPayload(name: "a/b", dir: false, size: 1, modified: nil, mimeType: nil, thumb: false)]
        phone.deliver(BrowseKind.placesFilesPage, PlacesFilesPagePayload(requestId: request.requestId, placeId: "default", path: "Trip", entries: rest,
                                                                          folderCount: 1, fileCount: 250, nextCursor: nil, writable: false))
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[1].entries.map(\.name), ["Beach"])
        XCTAssertNil(pages[1].nextCursor)
    }

    func testAPageOverTwoHundredEntriesIsRefused() throws {
        var result: Result<PhoneFilesPage, PhoneFilesError>?
        controller.listFiles(phoneID: phone.phoneID, placeId: "default", path: "", sort: .name, descending: false, cursor: nil) { result = $0 }
        let request = phone.decode(PlacesFilesPayload.self, try XCTUnwrap(phone.requests(BrowseKind.placesFiles).last))
        let entries = (0..<201).map { PlacesFileEntryPayload(name: "f\($0)", dir: false, size: 1, modified: nil, mimeType: nil, thumb: false) }
        phone.deliver(BrowseKind.placesFilesPage, PlacesFilesPagePayload(requestId: request.requestId, placeId: "default", path: "", entries: entries,
                                                                          folderCount: 0, fileCount: 201, nextCursor: nil, writable: false))
        guard case .failure(.code(FolderCode.invalidMessage)) = result else { return XCTFail("\(String(describing: result))") }
    }

    func testListingErrorsAndTimeouts() throws {
        var first: Result<PhoneFilesPage, PhoneFilesError>?
        controller.listFiles(phoneID: phone.phoneID, placeId: "default", path: "Gone", sort: .name, descending: false, cursor: nil) { first = $0 }
        let request = phone.decode(PlacesFilesPayload.self, try XCTUnwrap(phone.requests(BrowseKind.placesFiles).last))
        phone.deliver(FolderKind.placesError, PlacesErrorPayload(requestId: request.requestId, code: FolderCode.notFound))
        guard case .failure(.code(FolderCode.notFound)) = first else { return XCTFail() }

        var second: Result<PhoneMediaPage, PhoneFilesError>?
        controller.listMedia(phoneID: phone.phoneID, kind: .media, cursor: nil, limit: 500) { second = $0 }
        XCTAssertEqual(phone.decode(MediaListPayload.self, try XCTUnwrap(phone.requests(BrowseKind.mediaList).last)).limit, 200)
        clock.advance(7.9)
        XCTAssertNil(second)
        clock.advance(0.2)
        guard case .failure(.timeout) = second else { return XCTFail() }
    }

    func testMediaPagesMapRefsAndAccess() throws {
        var page: PhoneMediaPage?
        controller.listMedia(phoneID: phone.phoneID, kind: .recent, cursor: nil, limit: 50) { page = try? $0.get() }
        let request = phone.decode(MediaListPayload.self, try XCTUnwrap(phone.requests(BrowseKind.mediaList).last))
        XCTAssertEqual(request.kind, "recent")
        var media = WireRef(.media(id: "42"))
        media.placeId = nil
        let items = [
            MediaItemPayload(ref: media, name: "IMG_1.HEIC", size: 2_000_000, modified: 1_790_000_000_000, mimeType: "image/heic",
                             width: 4032, height: 3024, durationMs: nil, thumb: true, location: "Camera"),
            MediaItemPayload(ref: WireRef(.place(placeId: "Zr8m2Pq0aLk4xT7bNc1yWe", path: "Invoices", name: "May.pdf")), name: "May.pdf", size: 90_000,
                             modified: 1_789_000_000_000, mimeType: "application/pdf", width: nil, height: nil, durationMs: nil, thumb: false,
                             location: "Documents/Invoices"),
            // Neither form: dropped.
            MediaItemPayload(ref: WireRef(placeId: nil, path: nil, name: nil, mediaId: nil), name: "x", size: 1, modified: nil, mimeType: nil,
                             width: nil, height: nil, durationMs: nil, thumb: false, location: nil),
            // A media ID that is not decimal: dropped.
            MediaItemPayload(ref: WireRef(placeId: nil, path: nil, name: nil, mediaId: "content://media/1"), name: "y", size: 1, modified: nil,
                             mimeType: nil, width: nil, height: nil, durationMs: nil, thumb: false, location: nil),
        ]
        phone.deliver(BrowseKind.mediaPage, MediaPagePayload(requestId: request.requestId, kind: "recent", items: items, nextCursor: "c2", access: "full", indexing: true))
        XCTAssertEqual(page?.items.map(\.name), ["IMG_1.HEIC", "May.pdf"])
        XCTAssertEqual(page?.items.first?.ref, .media(id: "42"))
        XCTAssertEqual(page?.items.first?.width, 4032)
        XCTAssertEqual(page?.items.last?.location, "Documents/Invoices")
        XCTAssertEqual(page?.access, .full)
        XCTAssertEqual(page?.indexing, true)
    }

    // MARK: Thumbnails

    func testThumbnailsArriveInOrderAcrossBatchesAndReportMissing() {
        phone.server = thumbnailServer(bytes: 9_000, missing: ["1003"])
        var delivered: [String] = []
        var missing: [PhoneFileEntry]?
        let entries = mediaEntries(10) + [PhoneFileEntry(ref: .place(placeId: "default", path: "", name: "notes.txt"), name: "notes.txt",
                                                         isDirectory: false, size: 10, modified: nil, mimeType: "text/plain", hasThumbnail: false)]
        controller.thumbnails(phoneID: phone.phoneID, entries: entries, size: 256, lane: "grid", deliver: { entry, image in
            delivered.append(entry.name)
            XCTAssertEqual(image.tint, 0x336699)
            XCTAssertEqual(image.data.count, 9_000)
        }, finished: { missing = try? $0.get() })
        XCTAssertEqual(delivered, (0..<10).filter { $0 != 3 }.map { "IMG_\($0).jpg" })
        XCTAssertEqual(Set(missing?.map(\.name) ?? []), ["IMG_3.jpg", "notes.txt"])
        // The text file was never asked for; 10 thumbnails at 9 KB need three batches of at most 44 KiB.
        let request = phone.decode(MediaThumbnailsPayload.self, phone.requests(BrowseKind.mediaThumbnails)[0])
        XCTAssertEqual(request.items.count, 10)
        XCTAssertEqual(request.size, 256)
        XCTAssertEqual(controller.activeMediaRequests, 0)
    }

    func testOversizedThumbnailsAreDroppedAsMissing() {
        phone.server = thumbnailServer(bytes: 30_000)
        var delivered = 0
        var missing: [PhoneFileEntry]?
        controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(1), size: 9_999, lane: "grid", deliver: { _, _ in delivered += 1 },
                              finished: { missing = try? $0.get() })
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(missing?.count, 1)
        XCTAssertEqual(phone.decode(MediaThumbnailsPayload.self, phone.requests(BrowseKind.mediaThumbnails)[0]).size, 512)
    }

    func testLargeJobsSplitIntoRequestsOfSixtyFourAndKeepFourActive() {
        var finished: Result<[PhoneFileEntry], PhoneFilesError>?
        controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(400), size: 256, lane: "grid", deliver: { _, _ in },
                              finished: { finished = $0 })
        // 400 entries: 7 requests; only 4 go out until answers free the lane.
        XCTAssertEqual(phone.requests(BrowseKind.mediaThumbnails).count, 4)
        XCTAssertEqual(controller.activeMediaRequests, 4)
        let sizes = phone.requests(BrowseKind.mediaThumbnails).map { phone.decode(MediaThumbnailsPayload.self, $0).items.count }
        XCTAssertEqual(sizes, [64, 64, 64, 64])
        phone.server = thumbnailServer(bytes: 100)
        let first = phone.decode(MediaThumbnailsPayload.self, phone.requests(BrowseKind.mediaThumbnails)[0])
        for (kind, data) in thumbnailServer(bytes: 100)(BrowseKind.mediaThumbnails, try! FolderJSON.encoder.encode(first)) {
            controller.handle(kind: kind, payload: data, from: phone.phoneID)
        }
        // The freed slot went to the fifth request, whose answer came at once from the server.
        XCTAssertGreaterThanOrEqual(phone.requests(BrowseKind.mediaThumbnails).count, 5)
        XCTAssertNil(finished)
    }

    func testANewJobOnTheSameLaneCancelsTheOldOneOnThePhone() {
        var oldResult: Result<[PhoneFileEntry], PhoneFilesError>?
        var oldDelivered = 0
        controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(100), size: 256, lane: "grid", deliver: { _, _ in oldDelivered += 1 },
                              finished: { oldResult = $0 })
        let oldIDs = phone.requests(BrowseKind.mediaThumbnails).map { phone.decode(MediaThumbnailsPayload.self, $0).requestId }
        XCTAssertEqual(oldIDs.count, 2)
        controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(10), size: 256, lane: "grid", deliver: { _, _ in }, finished: { _ in })
        XCTAssertEqual(oldResult.map { if case .failure(.cancelled) = $0 { return true } else { return false } }, true)
        let cancels = phone.requests(BrowseKind.mediaCancel).map { phone.decode(MediaCancelPayload.self, $0).requestId }
        XCTAssertEqual(cancels, oldIDs)
        // A late batch of the old job is ignored.
        let late = MediaThumbnailsBatchPayload(requestId: oldIDs[0], thumbs: [ThumbPayload(key: "k0", mimeType: "image/webp", width: 1, height: 1, tint: nil,
                                                                                           data: Data([1]).base64EncodedString())], missing: nil, done: true)
        XCTAssertFalse(controller.handle(kind: BrowseKind.mediaThumbnailsBatch, payload: try! FolderJSON.encoder.encode(late), from: phone.phoneID))
        XCTAssertEqual(oldDelivered, 0)
        XCTAssertEqual(controller.activeMediaRequests, 1)
    }

    func testCancellingStopsTheJobAndOtherLanesKeepGoing() {
        var hover: Result<[PhoneFileEntry], PhoneFilesError>?
        let grid = controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(10), size: 256, lane: "grid", deliver: { _, _ in }, finished: { _ in })
        controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(2), size: 256, lane: "hover", deliver: { _, _ in }, finished: { hover = $0 })
        grid.cancel()
        XCTAssertEqual(phone.requests(BrowseKind.mediaCancel).count, 1)
        XCTAssertNil(hover)
        XCTAssertEqual(controller.activeMediaRequests, 1)
    }

    func testTheClientStaysUnderSixtyMediaRequestsInTenSeconds() {
        for index in 0..<70 {
            controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(1), size: 256, lane: "lane\(index)", deliver: { _, _ in }, finished: { _ in })
            // Answer every request at once, so only the window limits sending.
            if let last = phone.requests(BrowseKind.mediaThumbnails).last {
                for (kind, data) in thumbnailServer(bytes: 10)(BrowseKind.mediaThumbnails, last.payload!) { controller.handle(kind: kind, payload: data, from: phone.phoneID) }
            }
        }
        XCTAssertEqual(phone.requests(BrowseKind.mediaThumbnails).count, 60)
        phone.server = thumbnailServer(bytes: 10)
        clock.advance(10.1)
        XCTAssertEqual(phone.requests(BrowseKind.mediaThumbnails).count, 70)
    }

    func testADisconnectFailsEverythingAtOnce() {
        var result: Result<[PhoneFileEntry], PhoneFilesError>?
        controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(5), size: 256, lane: "grid", deliver: { _, _ in }, finished: { result = $0 })
        controller.phoneDisconnected(phone.phoneID)
        guard case .failure(.notConnected) = result else { return XCTFail() }
        XCTAssertEqual(controller.inFlight, 0)
    }

    // MARK: Previews and ranges

    func testPreviewPartsAreJoinedInOrder() throws {
        var image: PhoneImage?
        controller.preview(phoneID: phone.phoneID, entry: mediaEntries(1)[0], size: 4096) { image = try? $0.get() }
        let request = phone.decode(MediaPreviewPayload.self, try XCTUnwrap(phone.requests(BrowseKind.mediaPreview).first))
        XCTAssertEqual(request.size, 2048)
        XCTAssertEqual(request.ref.mediaId, "1000")
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        let parts = stride(from: 0, to: bytes.count, by: 32_768).map { bytes.subdata(in: $0..<min($0 + 32_768, bytes.count)) }
        for (index, part) in parts.enumerated() {
            phone.deliver(BrowseKind.mediaPreviewPart, MediaPreviewPartPayload(requestId: request.requestId, index: index, count: parts.count, mimeType: "image/jpeg",
                                                                                width: 2048, height: 1536, tint: "#102030", data: part.base64EncodedString()))
            if index < parts.count - 1 { XCTAssertNil(image) }
        }
        XCTAssertEqual(image?.data, bytes)
        XCTAssertEqual(image?.width, 2048)
        XCTAssertEqual(image?.tint, 0x102030)
    }

    func testPreviewPartsOutOfOrderFail() throws {
        var result: Result<PhoneImage, PhoneFilesError>?
        controller.preview(phoneID: phone.phoneID, entry: mediaEntries(1)[0], size: 1024) { result = $0 }
        let request = phone.decode(MediaPreviewPayload.self, try XCTUnwrap(phone.requests(BrowseKind.mediaPreview).first))
        phone.deliver(BrowseKind.mediaPreviewPart, MediaPreviewPartPayload(requestId: request.requestId, index: 1, count: 2, mimeType: "image/jpeg",
                                                                            width: 1, height: 1, tint: nil, data: Data([1]).base64EncodedString()))
        guard case .failure(.code(FolderCode.invalidMessage)) = result else { return XCTFail() }
    }

    func testRangesSplitAtFourMebibytesAndReportProgress() throws {
        let file = PhoneFileEntry(ref: .media(id: "77"), name: "clip.mp4", isDirectory: false, size: 20_000_000,
                                  modified: Date(timeIntervalSince1970: 1_790_000_000), mimeType: "video/mp4", hasThumbnail: true)
        var progress: [Int64] = []
        var result: Data?
        phone.server = { kind, payload in
            guard kind == BrowseKind.mediaRange, let request = try? JSONDecoder().decode(MediaRangePayload.self, from: payload) else { return [] }
            var answers: [(String, Data)] = []
            var offset = request.offset
            let end = request.offset + request.length
            while offset < end {
                let count = Int(min(32_768, end - offset))
                let part = MediaRangePartPayload(requestId: request.requestId, offset: offset, fileSize: 20_000_000, modified: 1_790_000_000_000,
                                                 data: Data(repeating: UInt8(offset % 200), count: count).base64EncodedString(), last: offset + Int64(count) >= end)
                answers.append((BrowseKind.mediaRangePart, try! FolderJSON.encoder.encode(part)))
                offset += Int64(count)
            }
            return answers
        }
        controller.range(phoneID: phone.phoneID, entry: file, offset: 0, length: 6_000_000, progress: { progress.append($0) }) { result = try? $0.get() }
        let deadline = Date().addingTimeInterval(5)
        while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(result?.count, 6_000_000)
        XCTAssertEqual(phone.requests(BrowseKind.mediaRange).map { phone.decode(MediaRangePayload.self, $0).length }, [4_194_304, 1_805_696])
        XCTAssertEqual(progress.last, 6_000_000)
    }

    func testARangeOfAChangedFileFails() throws {
        let file = PhoneFileEntry(ref: .media(id: "77"), name: "clip.mp4", isDirectory: false, size: 1_000, modified: nil, mimeType: "video/mp4", hasThumbnail: true)
        var result: Result<Data, PhoneFilesError>?
        controller.range(phoneID: phone.phoneID, entry: file, offset: 0, length: 100, progress: { _ in }) { result = $0 }
        let request = phone.decode(MediaRangePayload.self, try XCTUnwrap(phone.requests(BrowseKind.mediaRange).first))
        phone.deliver(BrowseKind.mediaRangePart, MediaRangePartPayload(requestId: request.requestId, offset: 0, fileSize: 2_000, modified: nil,
                                                                        data: Data(count: 100).base64EncodedString(), last: true))
        guard case .failure(.code(FolderCode.sourceChanged)) = result else { return XCTFail() }
    }

    // MARK: Downloads and uploads

    func testDownloadRegistersBeforeAskingAndLearnsTheTransfer() throws {
        let directory = FileManager.default.temporaryDirectory
        var progress: [PhoneTransferProgress] = []
        controller.download(phoneID: phone.phoneID, refs: [.media(id: "5"), .place(placeId: "default", path: "", name: "Trip")], into: directory,
                            purpose: .save, progress: { progress.append($0) }, completion: { _ in })
        XCTAssertEqual(phone.expected.count, 1)
        let request = phone.decode(PlacesDownloadPayload.self, try XCTUnwrap(phone.requests(BrowseKind.placesDownload).first))
        XCTAssertEqual(request.items.count, 2)
        XCTAssertEqual(phone.expected[0].requestId, request.requestId)
        phone.deliver(BrowseKind.placesDownloadStarted, PlacesDownloadStartedPayload(requestId: request.requestId, folderTransferId: "00000000-0000-4000-8000-000000000099",
                                                                                      rootName: "IMG_5.jpg", fileCount: 12, folderCount: 2, totalSize: 9_000))
        XCTAssertEqual(phone.expected[0].folderTransferId, "00000000-0000-4000-8000-000000000099")
        XCTAssertEqual(progress.last?.filesTotal, 12)
    }

    func testDownloadRefusedByThePhoneFinishesAndForgetsTheExpectation() throws {
        var result: Result<[URL], PhoneFilesError>?
        controller.download(phoneID: phone.phoneID, refs: [.media(id: "5")], into: FileManager.default.temporaryDirectory, purpose: .preview,
                            progress: { _ in }, completion: { result = $0 })
        let request = phone.decode(PlacesDownloadPayload.self, try XCTUnwrap(phone.requests(BrowseKind.placesDownload).first))
        phone.deliver(FolderKind.placesError, PlacesErrorPayload(requestId: request.requestId, code: FolderCode.notFound))
        guard case .failure(.code(FolderCode.notFound)) = result else { return XCTFail() }
        XCTAssertEqual(phone.cancelledDownloads.count, 1)
    }

    func testUploadGoesToTheHostWithItsDestination() {
        controller.upload(phoneID: phone.phoneID, urls: [URL(fileURLWithPath: "/tmp/a.txt")], placeId: "default", path: "Inbox", progress: { _ in }, completion: { _ in })
        XCTAssertEqual(phone.uploads.first?.destination, FolderDestination(placeId: "default", path: "Inbox"))
    }

    func testRoutesFromAddresses() {
        XCTAssertEqual(PhoneRouteClassifier.route(host: "192.168.1.20"), .lan)
        XCTAssertEqual(PhoneRouteClassifier.route(host: "10.0.0.4"), .lan)
        XCTAssertEqual(PhoneRouteClassifier.route(host: "172.20.1.1"), .lan)
        XCTAssertEqual(PhoneRouteClassifier.route(host: "fe80::1%en0"), .lan)
        XCTAssertEqual(PhoneRouteClassifier.route(host: "OnePlus-11.local"), .lan)
        XCTAssertEqual(PhoneRouteClassifier.route(host: "100.71.43.72"), .relay)
        XCTAssertEqual(PhoneRouteClassifier.route(host: "8.8.8.8"), .unknown)
        XCTAssertEqual(PhoneRouteClassifier.route(host: nil), .unknown)
    }
}
