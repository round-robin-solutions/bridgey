import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Phone files performance, printed as "PERF ..." lines. Runs only with BRIDGEY_PERF=1 (timings vary by machine):
///   BRIDGEY_PERF=1 swift test --filter PhoneFilesPerfTests
/// The phone is UIFakePhoneFiles on a simulated LAN: 4 ms round trip, 30 MB/s, 6 ms of phone work per 256 px
/// thumbnail on 4 threads, 30 ms per 1600 px preview. Thumbnails are real 256 px JPEGs (sizes printed).
@MainActor
final class PhoneFilesPerfTests: XCTestCase {
    private var directory: URL!
    private let phone = UIFakeImages.phoneID
    /// What a 1000 x 660 window shows of the Media grid: 6 columns, a bit over 5 rows.
    private let visibleCount = 36

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["BRIDGEY_PERF"] == "1" else { throw XCTSkip("Set BRIDGEY_PERF=1 to run the perf harness") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phonefiles-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.0005)) }
    }

    private func fake(simulated: Bool) -> UIFakePhoneFiles {
        let fake = UIFakePhoneFiles()
        fake.media = UIFakeImages.media(5_000)
        fake.simulated = simulated ? .init() : nil
        fake.previewImage = UIFakeImages.jpeg(width: 1600, height: 1200, seed: 9, quality: 0.7, detail: 60_000)
        // Varied real thumbnails so decoding is not one cached image.
        for (index, entry) in fake.media.prefix(200).enumerated() {
            fake.thumbnailBytes[entry.id] = UIFakeImages.jpeg(width: 256, height: 192, seed: index, quality: 0.8, detail: 6_000)
        }
        return fake
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Opens the model and marks the first screen visible, the way the grid's cells do; returns seconds until
    /// every visible cell has its thumbnail (or the phone said it has none).
    private func firstPaint(_ model: PhoneFilesModel) -> TimeInterval {
        let start = Date()
        var filled: Date?
        model.thumbnails.onVisibleFilled = { if filled == nil { filled = Date() } }
        model.start(preferred: phone)
        wait(until: { model.listing(.media).entries.count >= self.visibleCount })
        model.currentEntries.prefix(visibleCount).forEach(model.thumbnails.appeared)
        wait(until: { filled != nil })
        return (filled ?? Date()).timeIntervalSince(start)
    }

    private func render(_ model: PhoneFilesModel) -> TimeInterval {
        let start = Date()
        let view = BrandRoot(reduceMotion: false) {
            PhoneFilesWindowView(model: model, promises: PhoneFilePromises(model: nil))
                .frame(width: PhoneFilesWindowView.size.width, height: PhoneFilesWindowView.size.height)
        }
        let renderer = ImageRenderer(content: view.environment(\.snapshotRendering, true))
        renderer.scale = 2
        _ = renderer.cgImage
        return Date().timeIntervalSince(start)
    }

    func testGridFirstPaintFromCacheAndColdOnLan() throws {
        let sizes = fake(simulated: false).thumbnailBytes.values.map(\.count)
        print("PERF thumbnail bytes: mean \(sizes.reduce(0, +) / max(1, sizes.count)), max \(sizes.max() ?? 0) (256 x 192 JPEG q0.8, photo-like texture)")

        // Cold: nothing on this Mac, the phone over the simulated LAN.
        var colds: [Double] = []
        for run in 0..<5 {
            let cacheFolder = directory.appendingPathComponent("cache-\(run)")
            let model = PhoneFilesModel(service: fake(simulated: true), cache: PhoneThumbnailCache(directory: cacheFolder),
                                        defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        listingCache: PhoneListingCache(directory: directory.appendingPathComponent("listings-\(run)")))
            colds.append(firstPaint(model) * 1000)
            // Let the disk writes land for the warm run.
            wait(until: { model.currentEntries.prefix(self.visibleCount).allSatisfy { model.cache.contains($0.cacheKey(phoneID: self.phone), kind: .thumbnail) } })
            model.stop()
        }
        // Warm: a new process's view of the same caches (fresh memory tier, listing and thumbnails on disk).
        var warms: [Double] = []
        var renders: [Double] = []
        for run in 0..<5 {
            let model = PhoneFilesModel(service: fake(simulated: true), cache: PhoneThumbnailCache(directory: directory.appendingPathComponent("cache-\(run)")),
                                        defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                        listingCache: PhoneListingCache(directory: directory.appendingPathComponent("listings-\(run)")))
            warms.append(firstPaint(model) * 1000)
            renders.append(render(model) * 1000)
            model.stop()
        }
        print(String(format: "PERF grid first paint cold on LAN (%d thumbnails): median %.1f ms, max %.1f ms (target 500)", visibleCount, percentile(colds, 0.5), colds.max() ?? 0))
        print(String(format: "PERF grid first paint from disk cache: median %.1f ms, max %.1f ms (target 150)", percentile(warms, 0.5), warms.max() ?? 0))
        print(String(format: "PERF one full window render (ImageRenderer, 2x): median %.1f ms", percentile(renders, 0.5)))
        XCTAssertLessThan(percentile(warms, 0.5), 150)
        XCTAssertLessThan(percentile(colds, 0.5), 500)
    }

    func testHoverToOpenWithAndWithoutPrefetch() throws {
        let service = fake(simulated: true)
        let model = PhoneFilesModel(service: service, cache: PhoneThumbnailCache(directory: directory.appendingPathComponent("hover")),
                                    defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                    listingCache: PhoneListingCache(directory: nil))
        model.start(preferred: phone)
        wait(until: { model.listing(.media).loaded && !model.listing(.media).loading })
        let photos = model.currentEntries.filter { !$0.isVideo }
        func open(_ entry: PhoneFileEntry) -> Double {
            model.openPreview(entry)
            wait(until: { model.preview?.previewShownAt != nil })
            let value = (model.preview?.previewShownAt ?? Date()).timeIntervalSince(model.preview!.openedAt) * 1000
            model.closePreview()
            return value
        }
        print("PERF preview bytes: \(service.previewImage.count) (1600 x 1200 JPEG q0.7)")
        var without: [Double] = []
        for entry in photos[0..<10] { without.append(open(entry)) }
        var with: [Double] = []
        for entry in photos[10..<20] {
            model.prefetch.fire(entry)
            wait(until: { model.prefetch.inFlight == 0 })
            // The disk write lands in the background; opening reads memory first, then disk.
            with.append(open(entry))
        }
        print(String(format: "PERF hover to open without prefetch: median %.1f ms, p95 %.1f ms", percentile(without, 0.5), percentile(without, 0.95)))
        print(String(format: "PERF hover to open with prefetch: median %.2f ms, p95 %.2f ms", percentile(with, 0.5), percentile(with, 0.95)))
        XCTAssertLessThan(percentile(with, 0.5), percentile(without, 0.5))
    }

    /// Scrolls a 5,000-item grid in a real window and times each frame (layout and display). Needs a window
    /// server session (the logged-in Mac); skipped otherwise.
    func testScrollingFrameTimes() throws {
        let service = fake(simulated: false)
        let model = PhoneFilesModel(service: service, cache: PhoneThumbnailCache(directory: nil),
                                    defaults: UserDefaults(suiteName: UUID().uuidString)!, listingCache: PhoneListingCache(directory: nil))
        var listing = PhoneListing(entries: service.media, loaded: true)
        listing.nextCursor = nil
        model.setForTesting(phones: service.phones, phoneID: phone, info: PhoneBrowseInfo(places: [], writable: false, media: .full, documents: true),
                            section: .media, listings: [.media: listing])
        let images = (0..<24).map { UIFakeImages.decoded(seed: $0) }
        for (index, entry) in service.media.enumerated() { model.thumbnails.box(for: entry).setForTesting(images[index % images.count]) }
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: PhoneFilesWindowView.size.width, height: PhoneFilesWindowView.size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BrandRoot(reduceMotion: false) {
            PhoneFilesWindowView(model: model, promises: PhoneFilePromises(model: model))
        })
        window.contentView = host
        window.orderFrontRegardless()
        wait(until: { false }, timeout: 0.5)
        guard let scroll = Self.find(NSScrollView.self, in: host) else { throw XCTSkip("No scroll view (no window server?)") }
        var frames: [Double] = []
        let step: CGFloat = 24
        let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        var y: CGFloat = 0
        while y < min(maximum, 40_000), frames.count < 900 {
            y += step
            let start = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            frames.append((CACurrentMediaTime() - start) * 1000)
        }
        window.orderOut(nil)
        print(String(format: "PERF scroll 5,000-item grid: %d frames of %.0f pt, p50 %.2f ms, p95 %.2f ms, max %.2f ms (16.7 ms is 60 fps, 8.3 ms is 120 fps)",
                     frames.count, step, percentile(frames, 0.5), percentile(frames, 0.95), frames.max() ?? 0))
        XCTAssertGreaterThan(frames.count, 50)
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }
}
