import AppKit
import AVFoundation
import AVKit
import QuickLookUI
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Regression tests for what failed live on 2026-10-28 (rr/phone-files-flawless): each test names the failure it
/// guards. The thumbnail scheduler's own tests are in PhoneFilesUITests and PhoneThumbnailPipelineTests.
@MainActor
final class PhoneFilesFlawlessTests: XCTestCase {
    private var directory: URL!
    private let phone = UIFakeImages.phoneID

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phonefiles-flawless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func makeModel(_ fake: PhoneFilesService) -> PhoneFilesModel {
        PhoneFilesModel(service: fake, cache: PhoneThumbnailCache(directory: nil), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                        listingCache: PhoneListingCache(directory: nil), receivedFolder: { self.directory.appendingPathComponent("Received") },
                        previewFolder: directory.appendingPathComponent("originals"))
    }

    private func loadedModel(_ fake: UIFakePhoneFiles) -> PhoneFilesModel {
        let model = makeModel(fake)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        return model
    }

    // MARK: The viewer

    /// Space used to download the whole original before showing anything (two minutes for a 196 MB video,
    /// with the window frozen). It now opens the viewer at once and asks for the preview ahead of thumbnails.
    func testSpaceOpensTheViewerAtOnceWithAnUrgentPreview() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(10)
        let model = loadedModel(fake)
        let entry = model.currentEntries[2]
        model.selection = [entry.id]
        model.togglePreview()
        XCTAssertEqual(model.preview?.entry.id, entry.id, "open before anything arrives")
        XCTAssertTrue(fake.downloads.isEmpty, "no download for a preview")
        XCTAssertEqual(fake.urgentPreviews, 1)
        wait(until: { model.preview?.quality == .preview })
        XCTAssertEqual(model.previewImage?.pixelWidth, 1600)
        model.togglePreview()
        XCTAssertNil(model.preview, "Space again goes back to the grid")
    }

    func testArrowsMoveThroughTheListingAndSkipFolders() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(5)
        let model = loadedModel(fake)
        let entries = model.currentEntries
        model.selection = [entries[0].id]
        model.togglePreview()
        model.showAdjacent(1)
        XCTAssertEqual(model.preview?.entry.id, entries[1].id)
        XCTAssertEqual(model.selection, [entries[1].id], "the grid's selection follows")
        model.showAdjacent(-1)
        model.showAdjacent(-1)
        XCTAssertEqual(model.preview?.entry.id, entries[0].id, "stops at the first item")
        for _ in 0..<10 { model.showAdjacent(1) }
        XCTAssertEqual(model.preview?.entry.id, entries[4].id, "stops at the last")
    }

    /// Rapid Space and arrow presses never queue previews: each new item cancels the one before.
    func testRapidPressesCancelPreviewsInsteadOfQueueingThem() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(30)
        fake.simulated = .init(rtt: 0.3)
        let model = loadedModel(fake)
        let entries = model.currentEntries
        model.selection = [entries[0].id]
        for _ in 0..<15 {
            model.togglePreview()
            model.togglePreview()
        }
        model.togglePreview()
        for _ in 0..<20 { model.showAdjacent(1) }
        XCTAssertEqual(model.preview?.entry.id, entries[20].id)
        XCTAssertLessThanOrEqual(fake.previewRequests - fake.cancelledPreviews, 1, "at most the preview on screen is asked for")
        XCTAssertLessThanOrEqual(fake.previewRequests, 2, "a held key does not spend the phone's budget")
        wait(until: { model.preview?.quality == .preview }, timeout: 3)
        XCTAssertEqual(model.preview?.quality, .preview, "the item the viewer stopped on gets its preview")
    }

    /// A photo deleted on the phone: the viewer says so (no endless spinner) and the item leaves the grid.
    func testAnItemDeletedOnThePhoneLeavesTheGrid() {
        let service = DeletingPhoneFiles()
        service.media = UIFakeImages.media(4)
        let model = makeModel(service)
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        let gone = model.currentEntries[1]
        service.deleted = [gone.id]
        model.selection = [gone.id]
        model.togglePreview()
        wait(until: { model.preview?.error != nil })
        XCTAssertEqual(model.preview?.error, PhoneFilesError.code(FolderCode.notFound))
        XCTAssertFalse(model.currentEntries.contains { $0.id == gone.id })
        XCTAssertTrue(model.selection.isEmpty)
    }

    /// A second Space or Play while the original downloads joins that download; before, the second request was
    /// dropped without a word and Quick Look never opened for that item again in the session.
    func testASecondRequestForAnOriginalJoinsTheRunningDownload() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(2)
        fake.simulated = .init(rtt: 0.1)
        let model = loadedModel(fake)
        let entry = model.currentEntries[0]
        var results: [Result<URL, PhoneFilesError>] = []
        model.loadOriginal(entry) { results.append($0) }
        model.loadOriginal(entry) { results.append($0) }
        XCTAssertEqual(fake.downloads.count, 1)
        wait(until: { results.count == 2 })
        XCTAssertEqual(results.count, 2)
        XCTAssertNotNil(try? results[0].get())
        XCTAssertEqual(try? results[0].get(), try? results[1].get())
    }

    // MARK: Downloads that cannot finish

    /// The phone answered places.download_started but its folder offer never came: the download ends with a
    /// timeout instead of waiting for ever (which blocked Quick Look of that item for the session).
    func testADownloadWhoseOfferNeverComesTimesOut() throws {
        let loopback = LoopbackPhone()
        let clock = ManualFolderClock()
        let controller = PhoneFilesController(host: loopback, clock: clock)
        loopback.controller = controller
        var result: Result<[URL], PhoneFilesError>?
        controller.download(phoneID: loopback.phoneID, refs: [.media(id: "5")], into: directory, purpose: .preview,
                            progress: { _ in }, completion: { result = $0 })
        let request = loopback.decode(PlacesDownloadPayload.self, try XCTUnwrap(loopback.requests(BrowseKind.placesDownload).first))
        loopback.deliver(BrowseKind.placesDownloadStarted, PlacesDownloadStartedPayload(requestId: request.requestId, folderTransferId: "00000000-0000-4000-8000-000000000042",
                                                                                         rootName: "IMG_5.jpg", fileCount: 1, folderCount: 0, totalSize: 10))
        clock.advance(PhoneFilesController.offerTimeout - 1)
        XCTAssertNil(result)
        clock.advance(2)
        guard case .failure(.timeout)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(loopback.cancelledDownloads.count, 1)
    }

    /// Saves wait as long as they need: they may queue behind other downloads on the phone.
    func testASaveIsNeverTimedOut() throws {
        let loopback = LoopbackPhone()
        let clock = ManualFolderClock()
        let controller = PhoneFilesController(host: loopback, clock: clock)
        loopback.controller = controller
        var result: Result<[URL], PhoneFilesError>?
        controller.download(phoneID: loopback.phoneID, refs: [.media(id: "5")], into: directory, purpose: .save,
                            progress: { _ in }, completion: { result = $0 })
        let request = loopback.decode(PlacesDownloadPayload.self, try XCTUnwrap(loopback.requests(BrowseKind.placesDownload).first))
        loopback.deliver(BrowseKind.placesDownloadStarted, PlacesDownloadStartedPayload(requestId: request.requestId, folderTransferId: "00000000-0000-4000-8000-000000000044",
                                                                                         rootName: "IMG_5.jpg", fileCount: 1, folderCount: 0, totalSize: 10))
        clock.advance(PhoneFilesController.offerTimeout * 5)
        XCTAssertNil(result)
    }

    /// A preview that was still waiting for its offer fails when the phone disconnects; a save keeps waiting.
    func testADisconnectFailsAPreviewWaitingForItsOffer() throws {
        let receiver = FolderReceiver(host: nil, journals: ReceiveJournalStore(directory: directory.appendingPathComponent("journals")))
        var preview: Result<[URL], PhoneFilesError>?
        var save: Result<[URL], PhoneFilesError>?
        let waitingPreview = ExpectedDownload(requestId: "a", phoneID: phone, directory: directory, purpose: .preview, progress: { _ in }, completion: { preview = $0 })
        let waitingSave = ExpectedDownload(requestId: "b", phoneID: phone, directory: directory, purpose: .save, progress: { _ in }, completion: { save = $0 })
        receiver.expect(waitingPreview)
        receiver.expect(waitingSave)
        receiver.phoneDisconnected(phone)
        guard case .failure(.notConnected)? = preview else { return XCTFail("\(String(describing: preview))") }
        XCTAssertNil(save)
    }

    /// Live test 2026-10-30: the phone app restarted in the middle of a Phone files download and the Mac showed it
    /// "waiting" for over 20 minutes. Now a save or drag that the phone does not carry on with fails after
    /// FolderReceiver.downloadResumeTimeout, as an error the window offers Retry for.
    func testASaveThePhoneDoesNotContinueAfterADisconnectFails() throws {
        let clock = ManualFolderClock()
        let receiver = FolderReceiver(host: nil, journals: ReceiveJournalStore(directory: directory.appendingPathComponent("journals")),
                                      makeClock: { _ in clock })
        var started: Result<[URL], PhoneFilesError>?
        var waiting: Result<[URL], PhoneFilesError>?
        let running = ExpectedDownload(requestId: "a", phoneID: phone, directory: directory, purpose: .save, progress: { _ in }, completion: { started = $0 })
        running.started = true
        let queued = ExpectedDownload(requestId: "b", phoneID: phone, directory: directory, purpose: .dragOut, progress: { _ in }, completion: { waiting = $0 })
        receiver.expect(running)
        receiver.expect(queued)
        receiver.phoneDisconnected(phone)
        clock.advance(FolderReceiver.downloadResumeTimeout - 1)
        XCTAssertNil(started)
        XCTAssertNil(waiting)
        clock.advance(2)
        guard case .failure(.interrupted)? = started, case .failure(.interrupted)? = waiting else {
            return XCTFail("\(String(describing: started)) \(String(describing: waiting))")
        }
        XCTAssertTrue(running.cancelled, "the receive is cancelled, so a late offer is declined")
        XCTAssertTrue(PhoneFilesText.isTransient(.interrupted), "the window offers Retry")
        XCTAssertTrue(PhoneFilesText.error(.interrupted, phone: "Pixel").contains("Pixel"))
    }

    /// A download the phone carries on with after the reconnect (it offers it again, bytes arrive) is not failed.
    func testASaveThatResumesAfterADisconnectIsNotFailed() throws {
        let clock = ManualFolderClock()
        let receiver = FolderReceiver(host: nil, journals: ReceiveJournalStore(directory: directory.appendingPathComponent("journals")),
                                      makeClock: { _ in clock })
        var result: Result<[URL], PhoneFilesError>?
        let running = ExpectedDownload(requestId: "a", phoneID: phone, directory: directory, purpose: .save, progress: { _ in }, completion: { result = $0 })
        running.started = true
        receiver.expect(running)
        receiver.phoneDisconnected(phone)
        clock.advance(10)
        running.activity += 1  // What the receiver does when the phone offers it again or its bytes arrive.
        clock.advance(FolderReceiver.downloadResumeTimeout * 3)
        XCTAssertNil(result)
        XCTAssertFalse(running.cancelled)
    }

    /// An offer that did arrive is not timed out.
    func testAStartedDownloadIsNotTimedOut() throws {
        let loopback = LoopbackPhone()
        let clock = ManualFolderClock()
        let controller = PhoneFilesController(host: loopback, clock: clock)
        loopback.controller = controller
        var result: Result<[URL], PhoneFilesError>?
        controller.download(phoneID: loopback.phoneID, refs: [.media(id: "5")], into: directory, purpose: .preview,
                            progress: { _ in }, completion: { result = $0 })
        let request = loopback.decode(PlacesDownloadPayload.self, try XCTUnwrap(loopback.requests(BrowseKind.placesDownload).first))
        loopback.deliver(BrowseKind.placesDownloadStarted, PlacesDownloadStartedPayload(requestId: request.requestId, folderTransferId: "00000000-0000-4000-8000-000000000043",
                                                                                         rootName: "IMG_5.jpg", fileCount: 1, folderCount: 0, totalSize: 10))
        loopback.expected.first?.started = true
        clock.advance(PhoneFilesController.offerTimeout * 3)
        XCTAssertNil(result)
    }

    /// A preview download cut off by a disconnect fails at once and leaves no journal, so the viewer can offer
    /// to try again; before, it waited for a resume and stayed "Waiting for the phone".
    func testAPreviewDownloadCutOffFailsAtOnceWithoutAJournal() throws {
        let base = directory.appendingPathComponent("sim", isDirectory: true)
        let sim = PhoneSim(base: base)
        try Data(repeating: 7, count: 40_000_000).write(to: sim.phoneFiles.appendingPathComponent("VID_1.mp4"))
        let cache = base.appendingPathComponent("Preview", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var result: Result<[URL], PhoneFilesError>?
        var cut = false
        sim.controller.download(phoneID: sim.phoneID, refs: [.place(placeId: "default", path: "", name: "VID_1.mp4")], into: cache, purpose: .preview,
                                progress: { progress in
                                    // The phone drops as soon as the transfer runs.
                                    guard progress.phase == .transferring, !cut else { return }
                                    cut = true
                                    sim.receiver.phoneDisconnected(sim.phoneID)
                                }, completion: { result = $0 })
        wait(until: { result != nil }, timeout: 10)
        XCTAssertTrue(cut)
        guard case .failure(.notConnected)? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertTrue(sim.receiver.journals.recover().isEmpty, "nothing left to resume")
    }

    // MARK: Quick Look and video

    /// The panel holds its data source without retaining it and may ask from any thread: the source is a
    /// thread-safe snapshot owned by the window.
    func testQuickLookSourceAnswersFromAnyThread() {
        let source = PhoneQuickLookSource()
        source.items = (0..<50).map { URL(fileURLWithPath: "/tmp/item-\($0).jpg") }
        let group = DispatchGroup()
        nonisolated(unsafe) var counts: [Int] = []
        let lock = NSLock()
        for index in 0..<64 {
            group.enter()
            DispatchQueue.global().async {
                let count = source.numberOfPreviewItems(in: nil)
                let item = source.previewPanel(nil, previewItemAt: index % 60)
                lock.withLock { counts.append(count + (item == nil ? 1_000 : 0)) }
                group.leave()
            }
        }
        group.wait()
        // Indexes 0 to 59, then 0 to 3 again: 54 in range, 10 past the end.
        XCTAssertEqual(counts.filter { $0 == 50 }.count, 54, "items in range answer")
        XCTAssertEqual(counts.filter { $0 == 1_050 }.count, 10, "out of range answers nil, never traps")
    }

    func testTheWindowLetsGoOfQuickLookWhenItCloses() {
        let window = PhoneFilesNSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(window.acceptsPreviewPanelControl(nil), "nothing to show: the panel is not taken over")
        window.quickLookSource.items = [URL(fileURLWithPath: "/tmp/a.jpg")]
        XCTAssertTrue(window.acceptsPreviewPanelControl(nil))
        window.close()
    }

    /// Pressing Play aborted the app: SwiftUI's VideoPlayer needs AVKit loaded and nothing linked it ("failed to
    /// demangle superclass of VideoPlayerView", macOS 27). The viewer now uses AVPlayerView, which links AVKit.
    func testTheVideoPlayerViewLoadsAndLaysOut() throws {
        XCTAssertNotNil(NSClassFromString("AVPlayerView"), "AVKit is loaded with the app")
        let url = directory.appendingPathComponent("none.mp4")
        let host = NSHostingView(rootView: PhoneVideoPlayer(player: AVPlayer(url: url)).frame(width: 320, height: 180))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.05)
        XCTAssertNotNil(firstSubview(of: host, as: AVPlayerView.self))
        window.close()
    }

    func testNoSourceUsesSwiftUIVideoPlayer() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BridgeyMac", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(" VideoPlayer(player"), "\(file.lastPathComponent) uses SwiftUI's VideoPlayer; use PhoneVideoPlayer")
        }
    }

    private func firstSubview<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = firstSubview(of: subview, as: type) { return match } }
        return nil
    }

    // MARK: Memory and the cache

    func testTheMemoryTierKeepsItsBudget() {
        let memory = PhoneImageMemory(byteBudget: 10 * 256 * 256 * 4)
        for index in 0..<40 { memory.set("k\(index)", UIFakeImages.decoded(seed: index)) }
        XCTAssertLessThanOrEqual(memory.bytes, memory.byteBudget)
        XCTAssertNil(memory.get("k0"), "oldest first")
        XCTAssertNotNil(memory.get("k39"))
        // Reading makes an image recent.
        let kept = (31..<40).first { memory.get("k\($0)") != nil }!
        _ = memory.get("k\(kept)")
        for index in 40..<45 { memory.set("k\(index)", UIFakeImages.decoded(seed: index)) }
        XCTAssertNotNil(memory.get("k\(kept)"))
    }

    func testTheDiskIndexAnswersWithoutTouchingTheDisk() {
        let folder = directory.appendingPathComponent("index")
        let cache = PhoneThumbnailCache(directory: folder)
        let key = PhoneFilesDigest.hex("index-test")
        let stored = expectation(description: "stored")
        cache.store(key, image: PhoneImage(data: UIFakeImages.jpeg(width: 64, height: 64, seed: 2), mimeType: "image/jpeg", width: 64, height: 64, tint: nil),
                    maxPixel: 64) { _ in stored.fulfill() }
        wait(for: [stored], timeout: 3)
        cache.thumbnailMemory.removeAll()
        wait(until: { cache.contains(key, kind: .thumbnail) })
        XCTAssertTrue(cache.contains(key, kind: .thumbnail))
        cache.removeAll()
        XCTAssertFalse(cache.contains(key, kind: .thumbnail))
    }

    // MARK: The grid

    private func gridWindow(_ model: PhoneFilesModel, width: CGFloat = 760, height: CGFloat = 600) -> (NSWindow, PhoneMediaGridController) {
        let controller = PhoneMediaGridController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = controller.scrollView
        controller.update(model: model, palette: .dark, reduceMotion: true)
        window.layoutIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
        spin(0.05)
        return (window, controller)
    }

    func testSectionsUseTheDayTheItemWasTaken() {
        let now = UIFakeImages.base
        var entries = UIFakeImages.media(6, now: now)
        // Modified a year ago, taken today: grouped by when it was taken, as the phone sorts.
        for index in entries.indices { entries[index].taken = now.addingTimeInterval(-Double(index / 3) * 86_400) }
        let old = entries[0]
        entries[0] = PhoneFileEntry(ref: old.ref, name: old.name, isDirectory: false, size: old.size, modified: now.addingTimeInterval(-400 * 86_400),
                                    mimeType: old.mimeType, hasThumbnail: true, taken: now)
        let sections = PhoneMediaSections.make(entries, now: now)
        XCTAssertEqual(sections.sections.map(\.count), [3, 3])
        XCTAssertEqual(sections.sections.first?.title, PhoneFilesText.day(now, now: now))
        XCTAssertEqual(sections.indexPath(ofFlat: 4), IndexPath(item: 1, section: 1))
        XCTAssertEqual(sections.entry(at: IndexPath(item: 2, section: 0))?.id, entries[2].id)
        XCTAssertNil(sections.entry(at: IndexPath(item: 3, section: 0)))
    }

    func testCellsAreSquareAndFillTheWidth() {
        XCTAssertEqual(PhoneGridLayout.side(for: 400), 120, "three 120 pt columns in 400 pt")
        for width in stride(from: 300, through: 1600, by: 37) {
            let side = PhoneGridLayout.side(for: CGFloat(width))
            XCTAssertGreaterThanOrEqual(side, PhoneGridLayout.minCell)
            XCTAssertLessThanOrEqual(side, PhoneGridLayout.maxCell)
        }
    }

    /// The scheduler hears exactly what is on screen, in order, and loads the next page well before the end.
    func testTheGridReportsTheItemsOnScreen() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(300)
        let model = loadedModel(fake)
        let (window, controller) = gridWindow(model)
        defer { window.close() }
        wait(until: { !fake.thumbnailRequests.isEmpty })
        let first = fake.thumbnailRequests.first?.keys ?? []
        XCTAssertEqual(first.first, model.currentEntries[0].id, "the top left cell first")
        let visibleCount = controller.collectionView.visibleItems().count
        XCTAssertGreaterThan(visibleCount, 10)
        XCTAssertLessThan(visibleCount, 80)
        controller.collectionView.scroll(NSPoint(x: 0, y: 4_000))
        wait(until: { fake.listRequests.count > 1 })
        XCTAssertGreaterThan(fake.listRequests.count, 1, "the next page loads before the end")
    }

    /// Cells are reused: scrolling through 2,000 items keeps about two screens of cell views alive.
    func testScrollingThroughTwoThousandItemsKeepsFewCells() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(2_000)
        let model = loadedModel(fake)
        model.loadMore()
        for _ in 0..<20 {
            wait(until: { !model.listing(.media).loading })
            model.loadMore()
        }
        wait(until: { model.listing(.media).entries.count == 2_000 }, timeout: 5)
        let (window, controller) = gridWindow(model)
        defer { window.close() }
        let height = controller.collectionView.frame.height
        var y: CGFloat = 0
        var most = 0
        while y < height {
            controller.collectionView.scroll(NSPoint(x: 0, y: y))
            spin(0.002)
            most = max(most, controller.collectionView.subviews.count)
            y += 500
        }
        XCTAssertLessThan(most, 200, "views: \(most)")
        XCTAssertLessThanOrEqual(model.thumbnails.boxesHoldingImages, model.thumbnails.imageBoxLimit + 120)
    }

    /// A cell whose picture never came shows a clear mark, not the loading placeholder.
    func testCellsShowTheFallbackForMissingAndFailedThumbnails() {
        func shown(_ fake: UIFakePhoneFiles, retryDelays: [TimeInterval]? = nil) -> Set<ThumbnailState> {
            fake.media = UIFakeImages.media(3)
            let model = loadedModel(fake)
            if let retryDelays { model.thumbnails.retryDelays = retryDelays }
            let (window, controller) = gridWindow(model)
            defer { window.close() }
            wait(until: { model.currentEntries.allSatisfy { model.thumbnails.box(for: $0).state != .waiting } }, timeout: 3)
            spin(0.05)
            return Set(controller.collectionView.visibleItems().compactMap { ($0 as? PhoneMediaItem)?.cell.shownState })
        }
        // The phone sends bytes that do not decode: "No preview".
        let missing = UIFakePhoneFiles()
        missing.defaultThumbnail = Data([1, 2, 3])
        XCTAssertEqual(shown(missing), [.unavailable])
        // The phone never answers: "Couldn't load" after the retries.
        let silent = UIFakePhoneFiles()
        silent.thumbnailFailure = .timeout
        XCTAssertEqual(shown(silent, retryDelays: [0.01, 0.01]), [.failed])
    }

    func testSpaceAndArrowsInTheGridDriveTheViewer() {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(8)
        let model = loadedModel(fake)
        let (window, controller) = gridWindow(model)
        defer { window.close() }
        let entries = model.currentEntries
        model.selection = [entries[0].id]
        controller.update(model: model, palette: .dark, reduceMotion: true)
        func press(_ code: UInt16, _ characters: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            controller.collectionView.keyDown(with: event)
        }
        press(49, " ")
        XCTAssertEqual(model.preview?.entry.id, entries[0].id)
        press(124, "")
        XCTAssertEqual(model.preview?.entry.id, entries[1].id)
        press(53, "\u{1B}")
        XCTAssertNil(model.preview)
        controller.update(model: model, palette: .dark, reduceMotion: true)
        XCTAssertEqual(controller.collectionView.selectionIndexPaths, [IndexPath(item: 1, section: 0)], "the grid shows the item the viewer stopped on")
    }
}

/// A phone where some items were deleted after the listing.
@MainActor
final class DeletingPhoneFiles: PhoneFilesService {
    private let inner = UIFakePhoneFiles()
    var deleted = Set<String>()
    var media: [PhoneFileEntry] {
        get { inner.media }
        set { inner.media = newValue }
    }
    var phones: [BrowsablePhone] { inner.phones }
    var onPhonesChanged: (() -> Void)? {
        get { inner.onPhonesChanged }
        set { inner.onPhonesChanged = newValue }
    }

    func places(phoneID: String, completion: @escaping (Result<PhoneBrowseInfo, PhoneFilesError>) -> Void) {
        inner.places(phoneID: phoneID, completion: completion)
    }

    func listFiles(phoneID: String, placeId: String, path: String, sort: PhoneFileSort, descending: Bool, cursor: String?,
                   completion: @escaping (Result<PhoneFilesPage, PhoneFilesError>) -> Void) {
        inner.listFiles(phoneID: phoneID, placeId: placeId, path: path, sort: sort, descending: descending, cursor: cursor, completion: completion)
    }

    func listMedia(phoneID: String, kind: PhoneMediaKind, cursor: String?, limit: Int,
                   completion: @escaping (Result<PhoneMediaPage, PhoneFilesError>) -> Void) {
        inner.listMedia(phoneID: phoneID, kind: kind, cursor: cursor, limit: limit, completion: completion)
    }

    func thumbnails(phoneID: String, entries: [PhoneFileEntry], size: (PhoneFileEntry) -> Int, lane: String,
                    deliver: @escaping (PhoneFileEntry, PhoneImage) -> Void,
                    finished: @escaping (Result<[PhoneFileEntry], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        inner.thumbnails(phoneID: phoneID, entries: entries, size: size, lane: lane, deliver: deliver, finished: finished)
    }

    func preview(phoneID: String, entry: PhoneFileEntry, size: Int, urgent: Bool,
                 completion: @escaping (Result<PhoneImage, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        if deleted.contains(entry.id) {
            DispatchQueue.main.async { completion(.failure(.code(FolderCode.notFound))) }
            return .none
        }
        return inner.preview(phoneID: phoneID, entry: entry, size: size, urgent: urgent, completion: completion)
    }

    func range(phoneID: String, entry: PhoneFileEntry, offset: Int64, length: Int64, progress: @escaping (Int64) -> Void,
               completion: @escaping (Result<Data, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        inner.range(phoneID: phoneID, entry: entry, offset: offset, length: length, progress: progress, completion: completion)
    }

    func download(phoneID: String, refs: [PhoneRef], into directory: URL, purpose: PhoneDownloadPurpose,
                  progress: @escaping (PhoneTransferProgress) -> Void,
                  completion: @escaping (Result<[URL], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        inner.download(phoneID: phoneID, refs: refs, into: directory, purpose: purpose, progress: progress, completion: completion)
    }

    func upload(phoneID: String, urls: [URL], placeId: String, path: String, progress: @escaping (PhoneTransferProgress) -> Void,
                completion: @escaping (Result<Void, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        inner.upload(phoneID: phoneID, urls: urls, placeId: placeId, path: path, progress: progress, completion: completion)
    }
}
