import Combine
import Foundation

// Files 2.0: what makes the Phone files grid feel instant.
//   - Every visible cell observes one ThumbnailBox. A memory hit fills the box before the cell's first frame,
//     a disk hit a few milliseconds later, the phone after one batched round trip.
//   - Cells report onAppear/onDisappear; one flush per run-loop turn turns that into one job on the "grid" lane
//     (a media.thumbnails request per size): visible items first (in grid order), then the next screen as
//     prefetch. A job is replaced only when a visible cell needs an item it does not carry, so items scrolled
//     away are cancelled on the phone and a job answering part by part is left to finish.
//   - Hover prefetch (PhoneHoverPrefetcher): after 150 ms on a thumbnail, the preview-size image (and for a
//     video the first ~2 MB) is fetched into the same content-addressed cache, at most 3 at a time, LAN only.

/// One cell's thumbnail. `arrived` is true when it came after the cell first drew, so the cell fades it in.
@MainActor
final class ThumbnailBox: ObservableObject {
    @Published private(set) var image: PhoneDecodedImage?
    @Published private(set) var arrived = false
    let key: String
    var tint: UInt32?

    init(key: String, tint: UInt32?) {
        self.key = key
        self.tint = tint
    }

    func set(_ decoded: PhoneDecodedImage, animated: Bool) {
        guard image == nil || image!.pixelWidth < decoded.pixelWidth else { return }
        arrived = animated
        image = decoded
        tint = decoded.tint ?? tint
    }

    /// Screenshots and tests.
    func setForTesting(_ decoded: PhoneDecodedImage?) {
        arrived = false
        image = decoded
    }
}

@MainActor
final class PhoneThumbnailScheduler {
    /// The widest grid cell in pixels on Retina: columns are 118 to 142 pt.
    static let cellPixels = Int((PhoneMediaGrid.cell + 24) * 2)
    /// The largest thumbnail the protocol allows (longest edge), and what the cache decodes up to.
    static let maxSize = BrowseLimits.maxThumbnailSize
    /// The sizes asked for, so one flush makes at most this many requests.
    static let sizeSteps = [288, 384, maxSize]

    /// The longest edge to ask for so the short edge still covers a square cell: the phone scales by the
    /// longest edge and the grid crops to a square, so a 1080 x 2412 screenshot asked at 256 px would come back
    /// 115 px wide and be stretched 2.5 times. Unknown dimensions get the largest size.
    static func size(for entry: PhoneFileEntry) -> Int {
        guard let width = entry.width, let height = entry.height, width > 0, height > 0 else { return maxSize }
        let needed = Double(cellPixels) * Double(max(width, height)) / Double(min(width, height))
        return sizeSteps.first { Double($0) >= needed.rounded(.up) } ?? maxSize
    }
    /// How many items past the last visible one are prefetched.
    static let prefetchAhead = 48
    /// At most this many items per media.thumbnails request (protocol limit 64).
    static let maxPerRequest = 64

    private let service: PhoneFilesService
    private let cache: PhoneThumbnailCache
    private var phoneID: String?
    private var boxes: [String: ThumbnailBox] = [:]
    private var visible: [String: PhoneFileEntry] = [:]
    /// The grid's order, to put visible items first and prefetch the next screen.
    private var order: [PhoneFileEntry] = []
    private var index: [String: Int] = [:]
    private var requested = Set<String>()
    private var missing = Set<String>()
    /// Arrived from the phone, still decoding: never asked for again meanwhile.
    private var decoding = Set<String>()
    private var flushScheduled = false
    private var current: PhoneFilesCancellable?
    /// Counts requests on the grid lane. A request the next one replaced still reports back (the client ends it
    /// as cancelled, synchronously, inside the next call); only the latest one may touch `current` and
    /// `requested`, or the replaced one empties them and every flush replaces the request again.
    private var generation = 0
    /// After a failed request (timeout, busy) visible cells ask again after this long, not on the next turn.
    static let retryAfterFailure: TimeInterval = 2
    private var retry: DispatchWorkItem?
    /// Timing hooks for the perf harness: when every visible box was filled.
    var onVisibleFilled: (() -> Void)?

    init(service: PhoneFilesService, cache: PhoneThumbnailCache) {
        self.service = service
        self.cache = cache
    }

    func setPhone(_ id: String?) {
        guard id != phoneID else { return }
        phoneID = id
        generation += 1
        retry?.cancel()
        retry = nil
        current?.cancel()
        current = nil
        boxes.removeAll()
        visible.removeAll()
        requested.removeAll()
        missing.removeAll()
        decoding.removeAll()
    }

    func setOrder(_ entries: [PhoneFileEntry]) {
        order = entries
        index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func box(for entry: PhoneFileEntry) -> ThumbnailBox {
        let key = entry.cacheKey(phoneID: phoneID ?? "")
        if let box = boxes[key] { return box }
        let box = ThumbnailBox(key: key, tint: cache.tint(key))
        if let hit = cache.memoryImage(key) { box.set(hit, animated: false) }
        boxes[key] = box
        return box
    }

    func appeared(_ entry: PhoneFileEntry) {
        guard entry.hasThumbnail else { return }
        visible[entry.id] = entry
        scheduleFlush()
    }

    func disappeared(_ entry: PhoneFileEntry) {
        guard visible.removeValue(forKey: entry.id) != nil else { return }
        if boxes.count > 800 { trim() }
        scheduleFlush()
    }

    /// Stops the grid lane (window closed, section changed).
    func stop() {
        generation += 1
        retry?.cancel()
        retry = nil
        current?.cancel()
        current = nil
        visible.removeAll()
        requested.removeAll()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    /// Fills visible boxes from disk, and asks the phone for the rest plus the next screen, in one request.
    func flush() {
        guard let phoneID else { return }
        let visibleEntries = visible.values.sorted { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
        var network: [PhoneFileEntry] = []
        for entry in visibleEntries {
            let box = self.box(for: entry)
            if box.image != nil { continue }
            if cache.contains(box.key, kind: .thumbnail) {
                cache.load(box.key, maxPixel: Self.maxSize) { [weak self, weak box] decoded in
                    guard let box else { return }
                    if let decoded {
                        box.set(decoded, animated: false)
                        self?.checkFilled()
                    } else {
                        self?.network([entry])
                    }
                }
            } else if !missing.contains(box.key), !decoding.contains(box.key) {
                network.append(entry)
            }
        }
        let visibleCount = network.count
        // The next screen, as prefetch, only while something visible is still missing or ahead is uncached.
        if let last = visibleEntries.last.flatMap({ index[$0.id] }) {
            let upper = min(order.count, last + 1 + Self.prefetchAhead)
            if last + 1 < upper {
                for entry in order[(last + 1)..<upper] where entry.hasThumbnail {
                    let key = entry.cacheKey(phoneID: phoneID)
                    if cache.memoryImage(key) == nil, !cache.contains(key, kind: .thumbnail), !missing.contains(key), !decoding.contains(key) {
                        network.append(entry)
                    }
                }
            }
        }
        let wanted = Array(network.prefix(Self.maxPerRequest))
        // Every visible cell that needs the phone is already on the wire: let that request finish. Prefetch
        // drifting is no reason to replace it: answers arriving part by part (one request per size) move the
        // prefetch window on every turn, and replacing cancels what is about to arrive.
        let visibleNeeded = Set(network.prefix(visibleCount).map { $0.cacheKey(phoneID: phoneID) })
        if current != nil, visibleNeeded.isSubset(of: requested) {
            checkFilled()
            return
        }
        guard !wanted.isEmpty else {
            checkFilled()
            return
        }
        request(wanted, phoneID: phoneID)
    }

    private func network(_ entries: [PhoneFileEntry]) {
        guard let phoneID else { return }
        request(entries, phoneID: phoneID)
    }

    private func request(_ entries: [PhoneFileEntry], phoneID: String) {
        generation += 1
        let generation = generation
        retry?.cancel()
        retry = nil
        var ended = false
        let handle = service.thumbnails(phoneID: phoneID, entries: entries, size: Self.size(for:), lane: "grid", deliver: { [weak self] entry, image in
            guard let self, self.phoneID == phoneID else { return }
            let key = entry.cacheKey(phoneID: phoneID)
            let box = self.boxes[key]
            self.decoding.insert(key)
            self.cache.store(key, image: image, maxPixel: Self.maxSize) { [weak self, weak box] decoded in
                self?.decoding.remove(key)
                if let decoded {
                    box?.set(decoded, animated: true)
                } else {
                    // Bytes that do not decode count as missing: never asked for again.
                    self?.missing.insert(key)
                }
                self?.checkFilled()
            }
        }, finished: { [weak self] result in
            // A replaced or stopped request: the newer one owns the lane.
            guard let self, self.phoneID == phoneID, self.generation == generation else { return }
            ended = true
            if case let .success(none) = result {
                for entry in none { self.missing.insert(entry.cacheKey(phoneID: phoneID)) }
            }
            self.current = nil
            self.requested.removeAll()
            // Anything still visible and empty (scrolled into view meanwhile) gets the next request; after a
            // failure, not before a pause, so a phone answering `busy` or not at all is not asked in a loop.
            guard self.visible.values.contains(where: { entry in
                let key = self.box(for: entry).key
                return self.box(for: entry).image == nil && !self.missing.contains(key) && !self.decoding.contains(key)
            }) else { return }
            switch result {
            case .success:
                self.scheduleFlush()
            case .failure(.cancelled):
                break
            case .failure:
                let retry = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.retry = nil
                        self?.flush()
                    }
                }
                self.retry = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryAfterFailure, execute: retry)
            }
        })
        // A request with nothing to send ends inside the call.
        guard !ended, generation == self.generation else { return }
        requested = Set(entries.map { $0.cacheKey(phoneID: phoneID) })
        current = handle
    }

    private func checkFilled() {
        guard let onVisibleFilled, !visible.isEmpty else { return }
        let filled = visible.values.allSatisfy { box(for: $0).image != nil || missing.contains(box(for: $0).key) }
        if filled { onVisibleFilled() }
    }

    /// Boxes for items far away are dropped when there are many, so memory follows the visible window.
    func trim(keeping limit: Int = 800) {
        guard boxes.count > limit, let phoneID else { return }
        let keep = Set(visible.values.map { $0.cacheKey(phoneID: phoneID) })
        for key in boxes.keys where !keep.contains(key) {
            boxes.removeValue(forKey: key)
            if boxes.count <= limit / 2 { break }
        }
    }
}

/// Hover prefetch: rest the pointer on a thumbnail for 150 ms and its preview is fetched in the background.
@MainActor
final class PhoneHoverPrefetcher {
    static let delay: TimeInterval = 0.15
    static let maxInFlight = 3
    static let previewSize = 1600
    /// A video's first seconds: enough for AVPlayer to start while the rest downloads.
    static let videoHeadBytes: Int64 = 2 * 1024 * 1024

    private struct Fetch {
        let entry: PhoneFileEntry
        let started: Date
        var preview: PhoneFilesCancellable?
        var range: PhoneFilesCancellable?
        var previewDone = false
        var rangeDone: Bool
        var rangeBytes: Int64 = 0
        /// Someone opened the item: never cancelled by the pointer leaving.
        var pinned = false
    }

    private let service: PhoneFilesService
    private let cache: PhoneThumbnailCache
    private let clock: () -> Date
    private var pending: (entry: PhoneFileEntry, timer: DispatchWorkItem)?
    private var fetches: [String: Fetch] = [:]
    /// Previews opened while their prefetch was still on the wire wait for it instead of asking again.
    private var waiters: [String: [(PhoneDecodedImage?) -> Void]] = [:]
    private var order: [String] = []
    var phoneID: String?
    var route: PhoneRoute = .unknown
    /// Counted for the report: started, kept after the pointer left, cancelled.
    private(set) var started = 0
    private(set) var cancelled = 0

    init(service: PhoneFilesService, cache: PhoneThumbnailCache, clock: @escaping () -> Date = Date.init) {
        self.service = service
        self.cache = cache
        self.clock = clock
    }

    var inFlight: Int { fetches.count }

    func hoverBegan(_ entry: PhoneFileEntry) {
        pending?.timer.cancel()
        guard route == .lan, entry.hasThumbnail, phoneID != nil else { return }
        let timer = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire(entry) } }
        pending = (entry, timer)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: timer)
    }

    func hoverEnded(_ entry: PhoneFileEntry) {
        if pending?.entry.id == entry.id {
            pending?.timer.cancel()
            pending = nil
        }
        guard let fetch = fetches[entry.id] else { return }
        if !pastHalf(fetch) { cancel(entry.id) }
    }

    /// Fires the prefetch now (tests and the perf harness skip the 150 ms wait).
    func fire(_ entry: PhoneFileEntry) {
        pending = nil
        guard let phoneID, fetches[entry.id] == nil else { return }
        let key = entry.cacheKey(phoneID: phoneID)
        let needsPreview = !cache.contains(key, kind: .preview)
        let needsRange = entry.isVideo && !cache.contains(key, kind: .range)
        guard needsPreview || needsRange else { return }
        if fetches.count >= Self.maxInFlight, let oldest = order.first(where: { fetches[$0].map { !pastHalf($0) } ?? false }) {
            cancel(oldest)
        }
        guard fetches.count < Self.maxInFlight else { return }
        started += 1
        var fetch = Fetch(entry: entry, started: clock(), previewDone: !needsPreview, rangeDone: !needsRange)
        if needsPreview {
            fetch.preview = service.preview(phoneID: phoneID, entry: entry, size: Self.previewSize) { [weak self] result in
                guard let self else { return }
                guard case let .success(image) = result else {
                    self.previewReady(entry.id, nil)
                    return
                }
                // Done once it is in the cache, so an open right after finds it there.
                self.cache.store(key, kind: .preview, image: image, maxPixel: Self.previewSize) { [weak self] decoded in
                    self?.previewReady(entry.id, decoded)
                }
            }
        }
        if needsRange {
            let length = min(Self.videoHeadBytes, entry.size ?? Self.videoHeadBytes)
            fetch.range = service.range(phoneID: phoneID, entry: entry, offset: 0, length: max(1, length), progress: { [weak self] bytes in
                self?.fetches[entry.id]?.rangeBytes = bytes
            }, completion: { [weak self] result in
                guard let self else { return }
                if case let .success(data) = result { self.cache.storeData(key, kind: .range, data: data) }
                self.fetches[entry.id]?.rangeDone = true
                self.finishIfDone(entry.id)
            })
        }
        fetches[entry.id] = fetch
        order.append(entry.id)
    }

    /// When a prefetch for `entry`'s preview is running, `handler` gets its result and this returns true.
    func whenPreviewReady(_ entry: PhoneFileEntry, _ handler: @escaping (PhoneDecodedImage?) -> Void) -> Bool {
        guard let fetch = fetches[entry.id], !fetch.previewDone else { return false }
        waiters[entry.id, default: []].append(handler)
        fetches[entry.id]?.pinned = true
        return true
    }

    private func previewReady(_ id: String, _ decoded: PhoneDecodedImage?) {
        waiters.removeValue(forKey: id)?.forEach { $0(decoded) }
        fetches[id]?.previewDone = true
        finishIfDone(id)
    }

    func cancelAll() {
        pending?.timer.cancel()
        pending = nil
        for id in Array(fetches.keys) { cancel(id) }
    }

    /// More than half has arrived: the range by its bytes, the preview by time (the contract reports no
    /// preview progress; at LAN speed a preview takes about 40 ms, so one past 60 ms is treated as half done).
    private func pastHalf(_ fetch: Fetch) -> Bool {
        if fetch.pinned { return true }
        if !fetch.rangeDone {
            let expected = min(Self.videoHeadBytes, fetch.entry.size ?? Self.videoHeadBytes)
            return fetch.rangeBytes * 2 > expected
        }
        if !fetch.previewDone { return clock().timeIntervalSince(fetch.started) > 0.06 }
        return true
    }

    private func cancel(_ id: String) {
        guard let fetch = fetches.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        fetch.preview?.cancel()
        fetch.range?.cancel()
        cancelled += 1
        waiters.removeValue(forKey: id)?.forEach { $0(nil) }
    }

    private func finishIfDone(_ id: String) {
        guard let fetch = fetches[id], fetch.previewDone, fetch.rangeDone else { return }
        fetches.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }
}
