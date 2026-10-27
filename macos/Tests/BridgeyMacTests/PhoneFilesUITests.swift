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

    func testSchedulerAsksVisibleFirstThenPrefetchInOneRequest() {
        let fake = UIFakePhoneFiles()
        let entries = UIFakeImages.media(200)
        let scheduler = PhoneThumbnailScheduler(service: fake, cache: PhoneThumbnailCache(directory: nil))
        scheduler.setPhone(phone)
        scheduler.setOrder(entries)
        for entry in entries[10..<30].reversed() { scheduler.appeared(entry) }
        spin(0.01)
        XCTAssertEqual(fake.thumbnailRequests.count, 1, "one flush, one request")
        let keys = fake.thumbnailRequests[0].keys
        XCTAssertEqual(Array(keys.prefix(20)), entries[10..<30].map(\.id), "visible items first, in grid order")
        XCTAssertEqual(keys.count, PhoneThumbnailScheduler.maxPerRequest)
        XCTAssertEqual(keys[20], entries[30].id, "then the next screen")
        XCTAssertEqual(fake.thumbnailRequests[0].lane, "grid")
    }

    func testSchedulerReplacesTheLaneWhenScrolling() {
        let fake = UIFakePhoneFiles()
        fake.simulated = .init(rtt: 0.2)
        let entries = UIFakeImages.media(400)
        let scheduler = PhoneThumbnailScheduler(service: fake, cache: PhoneThumbnailCache(directory: nil))
        scheduler.setPhone(phone)
        scheduler.setOrder(entries)
        entries[0..<20].forEach(scheduler.appeared)
        spin(0.01)
        entries[0..<20].forEach(scheduler.disappeared)
        entries[300..<320].forEach(scheduler.appeared)
        spin(0.01)
        XCTAssertEqual(fake.thumbnailRequests.count, 2)
        XCTAssertEqual(fake.thumbnailRequests[1].keys.first, entries[300].id)
        XCTAssertEqual(fake.cancelledThumbnailRequests, 1, "the first request was replaced")
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
        let scheduler = PhoneThumbnailScheduler(service: fake, cache: fresh)
        scheduler.setPhone(phone)
        scheduler.setOrder(entries)
        entries.forEach(scheduler.appeared)
        wait(until: { entries.allSatisfy { scheduler.box(for: $0).image != nil } })
        XCTAssertTrue(entries.allSatisfy { scheduler.box(for: $0).image != nil })
        XCTAssertTrue(fake.thumbnailRequests.isEmpty, "everything came from disk")
        XCTAssertFalse(scheduler.box(for: entries[0]).arrived, "disk hits draw without a fade")
        // A second box for the same entry starts filled from memory.
        let other = PhoneThumbnailScheduler(service: fake, cache: fresh)
        other.setPhone(phone)
        XCTAssertNotNil(other.box(for: entries[0]).image)
    }

    func testSchedulerDoesNotAskAgainForMissingThumbnails() {
        let fake = UIFakePhoneFiles()
        let entries = UIFakeImages.media(3)
        fake.defaultThumbnail = Data()
        fake.thumbnailBytes = [entries[0].id: UIFakeImages.jpeg(width: 64, height: 64, seed: 1)]
        let scheduler = PhoneThumbnailScheduler(service: fake, cache: PhoneThumbnailCache(directory: nil))
        scheduler.setPhone(phone)
        scheduler.setOrder(entries)
        entries.forEach(scheduler.appeared)
        wait(until: { scheduler.box(for: entries[0]).image != nil })
        spin(0.05)
        let count = fake.thumbnailRequests.count
        entries.forEach(scheduler.disappeared)
        entries.forEach(scheduler.appeared)
        spin(0.05)
        XCTAssertEqual(fake.thumbnailRequests.count, count, "a thumbnail that failed to decode or is missing is not asked for again")
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
        prefetch.hoverBegan(entry)
        spin(0.05)
        XCTAssertEqual(fake.previewRequests, 0, "not before 150 ms")
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
        XCTAssertEqual(fake.media.map { fake.thumbnailSizes[$0.id] }, [512, 384, 288, 512])
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
