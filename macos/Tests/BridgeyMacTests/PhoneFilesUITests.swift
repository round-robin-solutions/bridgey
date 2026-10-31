import Foundation
import XCTest
@testable import BridgeyMac

@MainActor
final class PhoneFilesUITests: XCTestCase {
    private var directory: URL!
    private let phone = UIFakeImages.phoneID

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phonefiles-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    private func makeModel(_ fake: UIFakePhoneFiles, cache: PhoneThumbnailCache? = nil, suite: String = UUID().uuidString) -> PhoneFilesModel {
        let defaults = UserDefaults(suiteName: suite)!
        return PhoneFilesModel(service: fake, cache: cache ?? PhoneThumbnailCache(directory: directory.appendingPathComponent("cache")),
                               defaults: defaults, listingCache: PhoneListingCache(directory: directory.appendingPathComponent("listings")),
                               receivedFolder: { self.directory.appendingPathComponent("Received") },
                               previewFolder: directory.appendingPathComponent("originals"))
    }

    // MARK: Cache

    func testCacheFrameKeepsTint() {
        let framed = PhoneThumbnailCache.frame(Data([1, 2, 3]), tint: 0xA1B2C3)
        let back = PhoneThumbnailCache.unframe(framed)
        XCTAssertEqual(back?.data, Data([1, 2, 3]))
        XCTAssertEqual(back?.tint, 0xA1B2C3)
        XCTAssertNil(PhoneThumbnailCache.unframe(PhoneThumbnailCache.frame(Data(), tint: nil))?.tint)
        XCTAssertNil(PhoneThumbnailCache.unframe(Data("nope".utf8)))
    }

    func testCachePersistsAcrossInstancesOwnerOnly() throws {
        let folder = directory.appendingPathComponent("persist")
        let entry = UIFakeImages.media(1)[0]
        let key = entry.cacheKey(phoneID: phone)
        let first = PhoneThumbnailCache(directory: folder)
        let stored = expectation(description: "stored")
        first.store(key, image: PhoneImage(data: UIFakeImages.jpeg(width: 256, height: 256, seed: 3), mimeType: "image/jpeg", width: 256, height: 256, tint: 0x112233),
                    maxPixel: 256) { decoded in
            XCTAssertEqual(decoded?.pixelWidth, 256)
            stored.fulfill()
        }
        wait(for: [stored], timeout: 3)
        wait(until: { first.contains(key, kind: .thumbnail) })
        let second = PhoneThumbnailCache(directory: folder)
        XCTAssertNil(second.memoryImage(key))
        let loaded = second.loadSync(key, maxPixel: 128)
        XCTAssertNotNil(loaded)
        XCTAssertLessThanOrEqual(max(loaded!.pixelWidth, loaded!.pixelHeight), 128, "decoded downsampled")
        XCTAssertEqual(loaded?.tint, 0x112233)
        let file = folder.appendingPathComponent(PhoneCacheKind.thumbnail.rawValue).appendingPathComponent(key)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(PhoneCacheKind.thumbnail.rawValue).path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testCacheDeletesThumbnailsOfTheOldSizing() throws {
        let folder = directory.appendingPathComponent("retired")
        let old = folder.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: old.appendingPathComponent(String(repeating: "a", count: 64)))
        _ = PhoneThumbnailCache(directory: folder)
        wait(until: { !FileManager.default.fileExists(atPath: old.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PhoneCacheKind.thumbnail.rawValue).path))
    }

    func testCacheRejectsKeysThatAreNotDigests() {
        let cache = PhoneThumbnailCache(directory: directory.appendingPathComponent("keys"))
        XCTAssertFalse(cache.contains("../../etc/passwd", kind: .thumbnail))
        cache.storeData("IMG_0001.jpg", kind: .range, data: Data([1]))
        XCTAssertNil(cache.data("IMG_0001.jpg", kind: .range))
    }

    func testCachePrunesLeastRecentlyUsedToBudget() throws {
        let folder = directory.appendingPathComponent("prune")
        let cache = PhoneThumbnailCache(directory: folder, byteBudget: 50_000)
        let keys = (0..<8).map { PhoneFilesDigest.hex("k\($0)") }
        for (index, key) in keys.enumerated() {
            cache.storeData(key, kind: .range, data: Data(count: 10_000))
            wait(until: { cache.contains(key, kind: .range) })
            let file = folder.appendingPathComponent("ranges").appendingPathComponent(key)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 100))], ofItemAtPath: file.path)
        }
        // Reading touches: key 0 becomes the most recently used.
        XCTAssertNotNil(cache.data(keys[0], kind: .range))
        cache.prune()
        XCTAssertLessThanOrEqual(cache.diskBytes(), 50_000)
        XCTAssertTrue(cache.contains(keys[0], kind: .range), "recently read survives")
        XCTAssertFalse(cache.contains(keys[1], kind: .range), "oldest goes first")
    }

    func testCacheKeysNeverContainNames() {
        let entry = UIFakeImages.media(1)[0]
        let key = entry.cacheKey(phoneID: phone)
        XCTAssertEqual(key.count, 64)
        XCTAssertFalse(key.contains("IMG"))
        var changed = entry
        changed = PhoneFileEntry(ref: entry.ref, name: entry.name, isDirectory: false, size: (entry.size ?? 0) + 1, modified: entry.modified,
                                 mimeType: entry.mimeType, hasThumbnail: true)
        XCTAssertNotEqual(changed.cacheKey(phoneID: phone), key, "a changed file gets a new key")
    }

    // MARK: Scheduler

    private func scheduler(_ fake: UIFakePhoneFiles, cache: PhoneThumbnailCache = PhoneThumbnailCache(directory: nil)) -> PhoneThumbnailScheduler {
        let scheduler = PhoneThumbnailScheduler(service: fake, cache: cache)
        scheduler.setPhone(phone)
        return scheduler
    }

    func testSchedulerAsksTheScreenFirstThenWhatComesNext() {
        let fake = UIFakePhoneFiles()
        fake.simulated = .init(rtt: 0.5)
        let entries = UIFakeImages.media(200)
        let scheduler = scheduler(fake)
        scheduler.setOrder(entries)
        for entry in entries[10..<30].reversed() { scheduler.appeared(entry) }
        spin(0.01)
        let keys = fake.thumbnailRequests.map(\.keys)
        XCTAssertEqual(keys.count, 2, "one request for the screen, one for the next screen")
        XCTAssertEqual(keys.first, entries[10..<30].map(\.id), "the visible items, in grid order")
        XCTAssertEqual(keys.last?.first, entries[30].id, "then the next screen")
        XCTAssertEqual(keys.last?.count, PhoneThumbnailScheduler.prefetchAhead)
        XCTAssertEqual(Set(fake.thumbnailRequests.map(\.lane)).count, keys.count, "no request replaces another")
        XCTAssertEqual(fake.cancelledThumbnailRequests, 0)
    }

    /// Items of different sizes go in different requests (one size per request), still at most three on the wire.
    func testOneRequestPerSizeAndAtMostThreeOnTheWire() {
        let fake = UIFakePhoneFiles()
        fake.simulated = .init(rtt: 0.5)
        let scheduler = scheduler(fake)
        let entries: [PhoneFileEntry] = (0..<300).map { (index: Int) -> PhoneFileEntry in
            let tall = index % 2 == 0
            return PhoneFileEntry(ref: .media(id: String(70_000 + index)), name: "M\(index)", isDirectory: false, size: 1, modified: nil,
                                  mimeType: "image/jpeg", hasThumbnail: true, width: tall ? 1080 : 4000, height: tall ? 2412 : 3000)
        }
        scheduler.setOrder(entries)
        scheduler.setVisible(Array(entries[0..<20]), ahead: Array(entries[20..<200]))
        spin(0.01)
        XCTAssertEqual(scheduler.requestsInFlight, PhoneThumbnailScheduler.maxInFlight)
        XCTAssertEqual(fake.thumbnailRequests.count, PhoneThumbnailScheduler.maxInFlight)
        let sizes: [Set<Int>] = fake.thumbnailRequests.map { request in Set(request.keys.compactMap { fake.thumbnailSizes[$0] }) }
        XCTAssertTrue(sizes.allSatisfy { $0.count == 1 }, "one size per request")
        let first: [String] = fake.thumbnailRequests[0].keys + fake.thumbnailRequests[1].keys
        let screen: [String] = entries[0..<20].map { $0.id }
        XCTAssertEqual(Set(first), Set(screen), "the screen goes first")
    }

    /// Beta 5 and 6 replaced their own request on every turn of the run loop (2,403 cancels in 20 seconds live):
    /// a request is now cancelled only when nothing in it is wanted any more.
    func testScrollingKeepsRequestsThatAreStillWantedAndDropsTheRest() {
        let fake = UIFakePhoneFiles()
        fake.simulated = .init(rtt: 0.5)
        let entries = UIFakeImages.media(400)
        let scheduler = scheduler(fake)
        scheduler.setOrder(entries)
        scheduler.setVisible(Array(entries[0..<12]), ahead: [])
        spin(0.01)
        XCTAssertEqual(fake.thumbnailRequests.count, 1)
        // A small scroll: half of the first screen is still visible.
        scheduler.setVisible(Array(entries[6..<18]), ahead: [])
        spin(0.01)
        XCTAssertEqual(fake.cancelledThumbnailRequests, 0, "the first request still carries visible items")
        XCTAssertEqual(fake.thumbnailRequests.last?.keys, entries[12..<18].map(\.id), "only what is new is asked for")
        // A jump far away: nothing of the earlier requests is wanted; new requests wait for the scroll to settle.
        scheduler.setVisible(Array(entries[300..<312]), ahead: [])
        spin(0.01)
        XCTAssertEqual(fake.cancelledThumbnailRequests, 2, "both earlier requests gave their slot back")
        XCTAssertEqual(fake.thumbnailRequests.count, 2, "nothing sent while the scroll flies past")
        spin(PhoneThumbnailScheduler.settle + 0.05)
        XCTAssertEqual(fake.thumbnailRequests.last?.keys, entries[300..<312].map(\.id))
        XCTAssertEqual(scheduler.requestsInFlight, 1)
        wait(until: { entries[300..<312].allSatisfy { scheduler.box(for: $0).image != nil } }, timeout: 3)
        XCTAssertTrue(entries[300..<312].allSatisfy { scheduler.box(for: $0).image != nil })
        XCTAssertEqual(scheduler.state(of: entries[0]), "idle", "cancelled items are asked again when they come back")
    }

    /// Visible items never wait behind items further ahead.
    func testVisibleItemsPushOutARequestForItemsAhead() {
        let fake = UIFakePhoneFiles()
        fake.simulated = .init(rtt: 0.5)
        let entries = UIFakeImages.media(400)
        let scheduler = scheduler(fake)
        scheduler.setOrder(entries)
        // Three requests: the screen, then two of 64 coming items each.
        scheduler.setVisible(Array(entries[0..<6]), ahead: Array(entries[6..<200]))
        spin(0.01)
        XCTAssertEqual(fake.thumbnailRequests.count, 3)
        // Every request still carries wanted items (all of them are ahead now), but a new screen needs a slot:
        // the newest request that carries nothing visible gives way.
        scheduler.setVisible(Array(entries[300..<306]), ahead: Array(entries[0..<200]))
        spin(PhoneThumbnailScheduler.settle + 0.05)
        XCTAssertEqual(fake.cancelledThumbnailRequests, 1)
        XCTAssertEqual(fake.thumbnailRequests.last?.keys, entries[300..<306].map(\.id))
        XCTAssertEqual(scheduler.requestsInFlight, PhoneThumbnailScheduler.maxInFlight)
        XCTAssertEqual(scheduler.state(of: entries[0]), "wire", "the first screen's request kept going")
    }

    func testSchedulerFillsFromMemoryAndDiskWithoutTheNetwork() {
        let fake = UIFakePhoneFiles()
        let entries = UIFakeImages.media(4)
        let cache = PhoneThumbnailCache(directory: directory.appendingPathComponent("warm"))
        for entry in entries {
            let done = expectation(description: "stored")
            cache.store(entry.cacheKey(phoneID: phone), image: PhoneImage(data: fake.defaultThumbnail, mimeType: "image/jpeg", width: 256, height: 256, tint: nil),
                        maxPixel: 256) { _ in done.fulfill() }
            wait(for: [done], timeout: 3)
        }
        wait(until: { entries.allSatisfy { cache.contains($0.cacheKey(phoneID: self.phone), kind: .thumbnail) } })
        let fresh = PhoneThumbnailCache(directory: directory.appendingPathComponent("warm"))
        let scheduler = scheduler(fake, cache: fresh)
        scheduler.setOrder(entries)
        entries.forEach(scheduler.appeared)
        wait(until: { entries.allSatisfy { scheduler.box(for: $0).image != nil } })
        XCTAssertTrue(entries.allSatisfy { scheduler.box(for: $0).image != nil })
        XCTAssertTrue(fake.thumbnailRequests.isEmpty, "everything came from disk")
        XCTAssertFalse(scheduler.box(for: entries[0]).arrived, "disk hits draw without a fade")
        // A second scheduler for the same phone starts filled from memory.
        let other = self.scheduler(fake, cache: fresh)
        XCTAssertNotNil(other.box(for: entries[0]).image)
    }

    func testMissingAndUndecodableThumbnailsShowTheFallbackAndAreNotAskedAgain() {
        let fake = UIFakePhoneFiles()
        let entries = UIFakeImages.media(3)
        fake.defaultThumbnail = Data()
        fake.thumbnailBytes = [entries[0].id: UIFakeImages.jpeg(width: 64, height: 64, seed: 1)]
        let scheduler = scheduler(fake)
        scheduler.setOrder(entries)
        entries.forEach(scheduler.appeared)
        wait(until: { scheduler.box(for: entries[0]).image != nil && scheduler.box(for: entries[1]).state == .unavailable })
        XCTAssertEqual(scheduler.box(for: entries[1]).state, .unavailable, "bytes that do not decode: the fallback, not a placeholder")
        spin(0.05)
        let count = fake.thumbnailRequests.count
        entries.forEach(scheduler.disappeared)
        entries.forEach(scheduler.appeared)
        spin(0.05)
        XCTAssertEqual(fake.thumbnailRequests.count, count, "not asked for again")
        scheduler.retryFailed()
        spin(0.05)
        XCTAssertGreaterThan(fake.thumbnailRequests.count, count, "Refresh asks again")
    }

    /// A request that fails is asked again after a pause, then the cell shows "Couldn't load", never a blank.
    func testFailedThumbnailsAreRetriedThenShowAFallback() {
        let fake = UIFakePhoneFiles()
        fake.thumbnailFailure = .timeout
        let entries = UIFakeImages.media(4)
        let scheduler = scheduler(fake)
        scheduler.retryDelays = [0.05, 0.05, 0.05]
        scheduler.setOrder(entries)
        entries.forEach(scheduler.appeared)
        wait(until: { entries.allSatisfy { scheduler.box(for: $0).state == .failed } }, timeout: 3)
        XCTAssertTrue(entries.allSatisfy { scheduler.box(for: $0).state == .failed })
        XCTAssertEqual(fake.thumbnailRequests.count, 4, "the first try and three retries, one request each")
        spin(0.2)
        XCTAssertEqual(fake.thumbnailRequests.count, 4, "no loop once it gave up")
        // Recovers on Refresh once the phone answers again.
        fake.thumbnailFailure = nil
        scheduler.retryFailed()
        wait(until: { entries.allSatisfy { scheduler.box(for: $0).image != nil } }, timeout: 3)
        XCTAssertTrue(entries.allSatisfy { scheduler.box(for: $0).image != nil })
    }

    func testBusyPausesWithoutCountingAsAFailure() {
        let fake = UIFakePhoneFiles()
        fake.thumbnailFailure = .code(FolderCode.busy)
        let entries = UIFakeImages.media(4)
        let scheduler = scheduler(fake)
        scheduler.busyPause = 0.2
        scheduler.setOrder(entries)
        entries.forEach(scheduler.appeared)
        spin(0.1)
        XCTAssertEqual(fake.thumbnailRequests.count, 1, "no request while the phone asks for a pause")
        fake.thumbnailFailure = nil
        wait(until: { entries.allSatisfy { scheduler.box(for: $0).image != nil } }, timeout: 3)
        XCTAssertTrue(entries.allSatisfy { scheduler.box(for: $0).image != nil }, "busy never ends in the fallback")
    }

    func testADisconnectPausesAndTheReconnectAsksAgain() {
        let fake = UIFakePhoneFiles()
        fake.thumbnailFailure = .notConnected
        let entries = UIFakeImages.media(4)
        let scheduler = scheduler(fake)
        scheduler.setOrder(entries)
        entries.forEach(scheduler.appeared)
        spin(0.1)
        XCTAssertEqual(fake.thumbnailRequests.count, 1)
        XCTAssertTrue(entries.allSatisfy { scheduler.box(for: $0).state == .waiting }, "a dropped phone is not a failed thumbnail")
        fake.thumbnailFailure = nil
        scheduler.resume()
        wait(until: { entries.allSatisfy { scheduler.box(for: $0).image != nil } }, timeout: 3)
        XCTAssertTrue(entries.allSatisfy { scheduler.box(for: $0).image != nil })
    }

    /// Memory follows the screen: boxes far away let go of their images; they come back from the cache.
    func testImagesFarFromTheScreenAreReleasedAndComeBack() {
        let fake = UIFakePhoneFiles()
        let entries = UIFakeImages.media(300)
        let scheduler = scheduler(fake)
        scheduler.imageBoxLimit = 40
        scheduler.setOrder(entries)
        for start in stride(from: 0, to: 240, by: 10) {
            let screen = Array(entries[start..<(start + 20)])
            scheduler.setVisible(screen, ahead: [])
            wait(until: { screen.allSatisfy { scheduler.box(for: $0).image != nil } }, timeout: 3)
        }
        XCTAssertLessThanOrEqual(scheduler.boxesHoldingImages, 40 + 20, "images held follow the screen, not the scroll")
        XCTAssertNil(scheduler.box(for: entries[0]).image, "the first screen let go")
        let requests = fake.thumbnailRequests.count
        let first = Array(entries[0..<20])
        scheduler.setVisible(first, ahead: [])
        wait(until: { first.allSatisfy { scheduler.box(for: $0).image != nil } }, timeout: 3)
        XCTAssertTrue(first.allSatisfy { scheduler.box(for: $0).image != nil })
        XCTAssertEqual(fake.thumbnailRequests.count, requests, "it came back from the cache, not the phone")
    }

    func testCacheKeyHexMatchesTheDigest() {
        XCTAssertEqual(PhoneFilesDigest.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(PhoneFilesDigest.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: Hover prefetch

    func testHoverPrefetchOnlyOnLanAfterTheDelay() {
        let fake = UIFakePhoneFiles()
        let prefetch = PhoneHoverPrefetcher(service: fake, cache: PhoneThumbnailCache(directory: nil))
        prefetch.phoneID = phone
        let entry = UIFakeImages.media(1)[0]
        prefetch.route = .relay
        prefetch.hoverBegan(entry)
        spin(0.25)
        XCTAssertEqual(fake.previewRequests, 0, "not on relay")
        prefetch.route = .lan
        let began = Date()
        prefetch.hoverBegan(entry)
        spin(0.05)
        // A loaded runner can return from a 50 ms spin after the 150 ms timer is due; the early
        // check only means something while the delay has really not passed.
        if Date().timeIntervalSince(began) < PhoneHoverPrefetcher.delay {
            XCTAssertEqual(fake.previewRequests, 0, "not before 150 ms")
        }
        spin(0.2)
        XCTAssertEqual(fake.previewRequests, 1)
    }

    func testHoverLeavingEarlyCancelsAndAtMostThreeRun() {
        let fake = UIFakePhoneFiles()
        fake.simulated = .init(rtt: 1)
        var now = Date()
        let prefetch = PhoneHoverPrefetcher(service: fake, cache: PhoneThumbnailCache(directory: nil), clock: { now })
        prefetch.phoneID = phone
        prefetch.route = .lan
        let entries = UIFakeImages.media(6).filter { !$0.isVideo }
        entries.prefix(4).forEach(prefetch.fire)
        XCTAssertEqual(prefetch.inFlight, 3, "at most three in flight")
        XCTAssertEqual(fake.previewRequests, 4)
        XCTAssertEqual(fake.cancelledPreviews, 1, "the oldest not past half made room")
        prefetch.hoverEnded(entries[3])
        XCTAssertEqual(prefetch.inFlight, 2, "left before half: cancelled")
        now = now.addingTimeInterval(1)
        prefetch.hoverEnded(entries[2])
        XCTAssertEqual(prefetch.inFlight, 2, "past half: kept")
    }

    func testHoverOnVideoFetchesPosterAndFirstSeconds() {
        let fake = UIFakePhoneFiles()
        let cache = PhoneThumbnailCache(directory: directory.appendingPathComponent("video"))
        let prefetch = PhoneHoverPrefetcher(service: fake, cache: cache)
        prefetch.phoneID = phone
        prefetch.route = .lan
        let video = UIFakeImages.media(7)[3]
        XCTAssertTrue(video.isVideo)
        prefetch.fire(video)
        XCTAssertEqual(fake.previewRequests, 1)
        XCTAssertEqual(fake.rangeRequests, 1)
        let key = video.cacheKey(phoneID: phone)
        wait(until: { cache.contains(key, kind: .range) && cache.contains(key, kind: .preview) && prefetch.inFlight == 0 })
        XCTAssertEqual(cache.data(key, kind: .range)?.count, Int(PhoneHoverPrefetcher.videoHeadBytes))
        XCTAssertEqual(prefetch.inFlight, 0)
        prefetch.fire(video)
        XCTAssertEqual(fake.previewRequests, 1, "cached: nothing fetched again")
    }

    // MARK: Model

    func testMediaPagesAppendWithoutDuplicates() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(300)
        let model = makeModel(fake)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        XCTAssertEqual(model.listing(.media).entries.count, PhoneFilesModel.pageSize)
        model.loadMore()
        model.loadMore()
        wait(until: { !model.listing(.media).loading })
        XCTAssertEqual(model.listing(.media).entries.count, PhoneFilesModel.pageSize * 2, "a second loadMore while loading is ignored")
        model.loadMore()
        wait(until: { !model.listing(.media).loading })
        XCTAssertEqual(model.listing(.media).entries.count, 300)
        XCTAssertFalse(model.listing(.media).canLoadMore)
        XCTAssertEqual(Set(model.listing(.media).entries.map(\.id)).count, 300)
    }

    func testPartialPhotosBannerClearsOnRefreshAndReconnect() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(10)
        fake.info.media = .partial
        let model = makeModel(fake)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        XCTAssertEqual(model.listing(.media).access, .partial)
        // Allow all on the phone, then Refresh.
        fake.info.media = .full
        model.refresh()
        wait(until: { !model.listing(.media).loading && model.listing(.media).access == .full })
        XCTAssertEqual(model.listing(.media).access, .full)
        // Back to the chosen photos, then the phone drops and reconnects.
        fake.info.media = .partial
        let phones = fake.phones
        fake.phones = []
        fake.onPhonesChanged?()
        fake.phones = phones
        fake.onPhonesChanged?()
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading && model.listing(.media).access == .partial })
        XCTAssertEqual(model.listing(.media).access, .partial)
        fake.info.media = .full
        fake.phones = []
        fake.onPhonesChanged?()
        fake.phones = phones
        fake.onPhonesChanged?()
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading && model.listing(.media).access == .full })
        XCTAssertEqual(model.listing(.media).access, .full)
    }

    func testGridAsksForThumbnailsThatCoverASquareCell() {
        let fake = UIFakePhoneFiles()
        let shapes = [(1080, 2412), (4000, 3000), (3000, 3000), (1920, 1080)]
        fake.media = shapes.enumerated().map { index, shape in
            PhoneFileEntry(ref: .media(id: String(40_000 + index)), name: "M\(index)", isDirectory: false, size: 1_000,
                           modified: UIFakeImages.base.addingTimeInterval(-Double(index)), mimeType: "image/png", hasThumbnail: true,
                           width: shape.0, height: shape.1)
        }
        let model = makeModel(fake)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        for entry in model.currentEntries { model.thumbnails.appeared(entry) }
        wait(until: { fake.thumbnailSizes.count == shapes.count })
        XCTAssertEqual(fake.media.map { fake.thumbnailSizes[$0.id] }, [512, 384, 384, 512])
    }

    func testReopeningShowsTheLastListingAtOnce() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(30)
        let suite = UUID().uuidString
        let first = makeModel(fake, suite: suite)
        first.start(preferred: phone)
        wait(until: { first.listing(.media).loaded && !first.listing(.media).loading })
        fake.simulated = .init(rtt: 5)
        let second = PhoneFilesModel(service: fake, cache: PhoneThumbnailCache(directory: nil), defaults: UserDefaults(suiteName: suite)!,
                                     listingCache: PhoneListingCache(directory: directory.appendingPathComponent("listings")))
        second.start(preferred: nil)
        XCTAssertEqual(second.phoneID, phone, "the last phone")
        XCTAssertEqual(second.listing(.media).entries.count, 30, "from the local copy before the phone answers")
        XCTAssertTrue(second.listing(.media).loading)
    }

    func testFoldersNavigateSortAndRemember() {
        let fake = UIFakePhoneFiles()
        fake.info = PhoneBrowseInfo(places: UIFakeImages.places, writable: false, media: .full, documents: true)
        fake.folders["q3Jx0bVv1eG7tq8Wm2l5wA/Trip"] = UIFakeImages.folder()
        fake.folders["q3Jx0bVv1eG7tq8Wm2l5wA/Trip/Beach"] = []
        let suite = UUID().uuidString
        let model = makeModel(fake, suite: suite)
        model.start(preferred: phone)
        model.open(place: "q3Jx0bVv1eG7tq8Wm2l5wA")
        XCTAssertEqual(model.section, .folders)
        let trip = PhoneFileEntry(ref: .place(placeId: "q3Jx0bVv1eG7tq8Wm2l5wA", path: "", name: "Trip"), name: "Trip", isDirectory: true,
                                  size: nil, modified: nil, mimeType: nil, hasThumbnail: false)
        model.activate(trip)
        XCTAssertEqual(model.path, ["Trip"])
        wait(until: { model.listing(.folders).loaded && !model.listing(.folders).loading })
        XCTAssertEqual(model.listing(.folders).entries.count, UIFakeImages.folder().count)
        XCTAssertFalse(model.writable)
        model.activate(model.listing(.folders).entries.first { $0.name == "Beach" }!)
        XCTAssertEqual(model.path, ["Trip", "Beach"])
        model.goTo(depth: 0)
        XCTAssertEqual(model.path, ["Trip"])
        model.setSort(.size)
        XCTAssertEqual(model.sort, .size)
        XCTAssertTrue(model.descending, "size starts largest first")
        model.setSort(.size)
        XCTAssertFalse(model.descending, "the same column flips")
        let again = makeModel(fake, suite: suite)
        again.start(preferred: nil)
        XCTAssertEqual(again.section, .folders)
        XCTAssertEqual(again.placeID, "q3Jx0bVv1eG7tq8Wm2l5wA")
        XCTAssertEqual(again.path, ["Trip"])
        XCTAssertEqual(again.sort, .size)
    }

    func testUploadNeedsTheChangeSwitch() {
        let fake = UIFakePhoneFiles()
        fake.info = PhoneBrowseInfo(places: UIFakeImages.places, writable: false, media: .full, documents: true)
        fake.folders["q3Jx0bVv1eG7tq8Wm2l5wA/"] = UIFakeImages.folder()
        let model = makeModel(fake)
        model.start(preferred: phone)
        model.open(place: "q3Jx0bVv1eG7tq8Wm2l5wA")
        wait(until: { model.listing(.folders).loaded && !model.listing(.folders).loading })
        let file = directory.appendingPathComponent("a.txt")
        try? Data("a".utf8).write(to: file)
        XCTAssertFalse(model.upload([file]))
        XCTAssertTrue(fake.uploads.isEmpty, "read-only: nothing is sent")
        XCTAssertNotNil(model.notice)
        fake.info.writable = true
        model.refresh()
        wait(until: { model.listing(.folders).loaded && !model.listing(.folders).loading && model.writable })
        XCTAssertTrue(model.upload([file]))
        XCTAssertEqual(fake.uploads.first?.placeId, "q3Jx0bVv1eG7tq8Wm2l5wA")
        XCTAssertEqual(fake.uploads.first?.path, "")
    }

    func testDownloadSavesToReceivedFilesAndRemembersTheItem() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(5)
        let model = makeModel(fake)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        let entry = model.listing(.media).entries[1]
        model.click(entry, command: false, shift: false)
        model.downloadSelection()
        XCTAssertEqual(fake.downloads.first?.purpose, .save)
        XCTAssertEqual(fake.downloads.first?.directory.lastPathComponent, "Received")
        XCTAssertEqual(model.activities.count, 1)
        wait(until: { model.activities.isEmpty })
        XCTAssertNotNil(model.savedURL(entry))
    }

    func testQuickLookOriginalIsFetchedOncePerFile() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(2)
        let model = makeModel(fake)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        let entry = model.listing(.media).entries[0]
        var opened: URL?
        model.fetchOriginal(entry) { opened = $0 }
        wait(until: { opened != nil })
        XCTAssertEqual(fake.downloads.last?.purpose, .preview)
        XCTAssertTrue(opened!.path.contains(entry.cacheKey(phoneID: phone)))
        var again: URL?
        model.fetchOriginal(entry) { again = $0 }
        XCTAssertEqual(again?.resolvingSymlinksInPath(), opened?.resolvingSymlinksInPath())
        XCTAssertEqual(fake.downloads.count, 1)
    }

    func testSelectionWithShiftAndCommand() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(10)
        let model = makeModel(fake)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        let entries = model.currentEntries
        model.click(entries[2], command: false, shift: false)
        model.click(entries[5], command: false, shift: true)
        XCTAssertEqual(model.selection, Set(entries[2...5].map(\.id)))
        model.click(entries[3], command: true, shift: false)
        XCTAssertEqual(model.selection.count, 3)
        XCTAssertEqual(model.targets(for: entries[9]).map(\.id), [entries[9].id], "an item outside the selection drags alone")
        XCTAssertEqual(model.targets(for: entries[2]).count, 3)
    }

    func testOpeningPreviewShowsThumbnailThenPreview() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(1)
        fake.simulated = .init(rtt: 0.02)
        let cache = PhoneThumbnailCache(directory: nil)
        let model = makeModel(fake, cache: cache)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        let entry = model.currentEntries[0]
        let box = model.thumbnails.box(for: entry)
        model.thumbnails.appeared(entry)
        wait(until: { box.image != nil })
        model.openPreview(entry)
        XCTAssertEqual(model.preview?.quality, .thumbnail, "the cached thumbnail at once")
        wait(until: { model.preview?.quality == .preview })
        XCTAssertEqual(model.previewImage?.pixelWidth, 1600)
    }

    func testNotBrowsablePhoneLoadsNothing() {
        let fake = UIFakePhoneFiles(phones: [BrowsablePhone(id: phone, name: "Pixel 8", browsable: false, route: .lan)])
        let model = makeModel(fake)
        model.start(preferred: nil)
        spin(0.05)
        XCTAssertEqual(model.phoneID, phone)
        XCTAssertTrue(fake.listRequests.isEmpty)
        XCTAssertTrue(PhoneFilesText.error(.notBrowsable, phone: "Pixel 8").contains("Pixel 8"))
    }

    func testMediaGroupsByDay() {
        let now = UIFakeImages.base
        let groups = PhoneMediaGrid.groups(UIFakeImages.media(40, now: now), now: now)
        XCTAssertGreaterThan(groups.count, 1)
        XCTAssertEqual(groups.first?.title, PhoneFilesText.day(now, now: now))
        XCTAssertEqual(Set(groups.map(\.title)).count, groups.count, "titles are unique ids")
        XCTAssertEqual(groups.reduce(0) { $0 + $1.entries.count }, 40)
    }

    func testHistoryGroupsAndFilters() {
        let now = UIFakeImages.base
        let entries = [
            TransferHistoryEntry(id: "1", date: now, direction: .received, deviceID: phone, deviceName: "OnePlus 11", name: "IMG_1.jpg",
                                 bytes: 10, outcome: .completed, localPath: "/tmp/IMG_1.jpg", download: true),
            TransferHistoryEntry(id: "2", date: now.addingTimeInterval(-3_600), direction: .sent, deviceID: phone, deviceName: "OnePlus 11",
                                 name: "Photos", isFolder: true, fileCount: 124, bytes: 2_000_000, outcome: .incomplete, destination: "Pictures/Trip"),
            TransferHistoryEntry(id: "3", date: now.addingTimeInterval(-86_400 * 2), direction: .received, deviceID: "other", deviceName: "Pixel",
                                 name: "Notes.txt", bytes: 5, outcome: .completed),
        ]
        let groups = TransferHistoryView.groups(entries, now: now)
        XCTAssertEqual(groups.map(\.entries.count), [2, 1])
        var filter = TransferHistoryFilter()
        filter.query = "trip"
        XCTAssertEqual(entries.filter(filter.matches).map(\.id), ["2"], "destination is searched")
        filter = TransferHistoryFilter(direction: .received)
        XCTAssertEqual(entries.filter(filter.matches).map(\.id), ["1", "3"])
        filter.deviceID = "other"
        XCTAssertEqual(entries.filter(filter.matches).map(\.id), ["3"])
    }

    func testTextFormatting() {
        XCTAssertEqual(PhoneFilesText.duration(14_000), "0:14")
        XCTAssertEqual(PhoneFilesText.duration(3_725_000), "1:02:05")
        XCTAssertNil(PhoneFilesText.duration(nil))
        let pdf = UIFakeImages.documents()[0]
        XCTAssertTrue(PhoneFilesText.quickLookable(pdf))
        XCTAssertEqual(PhoneFilesText.uniformType(pdf), .pdf)
        let zip = UIFakeImages.documents()[6]
        XCTAssertFalse(PhoneFilesText.quickLookable(zip))
        XCTAssertEqual(PhoneFilesText.symbol(zip), "doc.zipper")
    }
}
