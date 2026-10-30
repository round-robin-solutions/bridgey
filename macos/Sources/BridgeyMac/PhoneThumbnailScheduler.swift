import Combine
import Foundation

// Files 2.0: thumbnails for the Phone files window, built like an image pipeline (Nuke, Apple's PhotoKit
// sample) instead of one request the grid keeps replacing (beta 5 and 6 replaced and cancelled their own
// request in a loop: 2,403 cancels in 20 seconds and not one thumbnail on a live emulator, 2026-10-28).
//   - Every item has a state: waiting, on the wire, decoding, loaded (in the disk cache), unavailable (the phone
//     has no picture) or failed (no answer after retries).
//   - The grid says what is visible and what comes next. Visible items go first, then the next screens.
//   - A screen goes out as one request (one per thumbnail size, at most 64 items each; the phone sends each
//     thumbnail as soon as it is made), and the next screens as one more, at most three on the wire. A request
//     is cancelled only when none of its items is wanted any more: scrolling never throws away work that is
//     about to arrive. Visible items may push out a request that carries only items further ahead.
//   - The phone serves 60 media requests in 10 seconds. A fast scroll (each screen shares nothing with the one
//     before) sends nothing until it settles for 120 ms, prefetch waits while the budget runs low, and the
//     viewer always keeps room, so a long scroll never ends in a screen that waits 10 seconds for its turn.
//   - A request that fails (no answer in time, an error) is asked again after 0.5, 2 and 6 seconds; after that
//     the cell shows a clear "no preview" mark instead of a placeholder that never fills. `busy` from the phone
//     pauses new requests for a second without counting as a failure.
//   - Decoded images live in the cache's budgeted memory tier, and boxes far from the screen let go of their
//     image, so scrolling through 10,000 photos uses about as much memory as a few screens.
// Hover prefetch (PhoneHoverPrefetcher, below) fetches the preview-size image after 150 ms on a thumbnail.

/// What a cell shows for its thumbnail.
enum ThumbnailState: Equatable {
    /// Not here yet (or let go of to save memory): the tinted placeholder.
    case waiting
    case loaded
    /// The phone has no picture for this item, or sent one that does not decode: the type icon.
    case unavailable
    /// No answer after several tries: the "no preview" mark, until Refresh or a reconnect.
    case failed
}

/// One item's thumbnail, observed by its cell. `arrived` is true when it came after the cell first drew, so
/// the cell fades it in.
@MainActor
final class ThumbnailBox: ObservableObject {
    @Published private(set) var image: PhoneDecodedImage?
    @Published private(set) var state: ThumbnailState = .waiting
    @Published private(set) var arrived = false
    let key: String
    var tint: UInt32?
    /// When the scheduler last wanted it (for letting go of far-away images).
    fileprivate(set) var lastUsed: UInt64 = 0

    init(key: String, tint: UInt32?) {
        self.key = key
        self.tint = tint
    }

    func set(_ decoded: PhoneDecodedImage, animated: Bool) {
        if let image, image.pixelWidth >= decoded.pixelWidth {
            if state != .loaded { state = .loaded }
            return
        }
        arrived = animated
        image = decoded
        tint = decoded.tint ?? tint
        state = .loaded
    }

    /// The image is gone for good (unavailable, failed) or never came: only without an image.
    func mark(_ newState: ThumbnailState) {
        guard image == nil, state != newState else { return }
        state = newState
    }

    /// Lets go of the image to save memory; it comes back from the cache when the cell is wanted again.
    func release() {
        guard image != nil else { return }
        image = nil
        arrived = false
        state = .waiting
    }

    /// Screenshots and tests.
    func setForTesting(_ decoded: PhoneDecodedImage?, state: ThumbnailState? = nil) {
        arrived = false
        image = decoded
        self.state = state ?? (decoded == nil ? .waiting : .loaded)
    }
}

@MainActor
final class PhoneThumbnailScheduler {
    /// The widest grid cell in pixels on Retina: columns are 118 to 142 pt.
    static let cellPixels = Int((PhoneMediaGrid.cell + 24) * 2)
    /// The largest thumbnail the protocol allows (longest edge), and what the cache decodes up to.
    static let maxSize = BrowseLimits.maxThumbnailSize
    /// The sizes asked for: one request carries one size, so fewer sizes mean fewer requests.
    static let sizeSteps = [384, maxSize]

    /// The longest edge to ask for so the short edge still covers a square cell: the phone scales by the
    /// longest edge and the grid crops to a square, so a 1080 x 2412 screenshot asked at 256 px would come back
    /// 115 px wide and be stretched 2.5 times. Unknown dimensions get the largest size.
    static func size(for entry: PhoneFileEntry) -> Int {
        guard let width = entry.width, let height = entry.height, width > 0, height > 0 else { return maxSize }
        let needed = Double(cellPixels) * Double(max(width, height)) / Double(min(width, height))
        return sizeSteps.first { Double($0) >= needed.rounded(.up) } ?? maxSize
    }

    /// Items after the last visible one fetched ahead when the view gives no list of its own (file lists).
    static let prefetchAhead = 48
    /// Requests on the wire at once (the phone serves 4 media requests: one stays free for previews).
    static let maxInFlight = 3
    /// Items per request (the protocol's limit).
    static let visibleBatch = BrowseLimits.maxThumbnailItems
    static let aheadBatch = BrowseLimits.maxThumbnailItems
    /// Prefetch waits until this many items ahead need a request (or nothing else is on the wire), so a slow
    /// scroll does not send a request per row.
    static let aheadMinimum = 24
    /// After a jump (a screen that shares nothing with the one before), new requests wait this long.
    static let settle: TimeInterval = 0.12
    /// Of the phone's 60 media requests per 10 seconds: the grid stops below this, prefetch well before.
    static let budgetVisible = BrowseLimits.mediaPerWindow - 8
    static let budgetAhead = BrowseLimits.mediaPerWindow - 28
    /// Pauses before asking again after a failed request; one more failure shows the fallback.
    static let retryDelays: [TimeInterval] = [0.5, 2, 6]
    /// After `busy` from the phone, no new request for this long.
    static let busyPause: TimeInterval = 1
    /// Boxes holding an image; past this, boxes far from the screen let go of theirs.
    static let imageBoxLimit = 240

    private enum Phase: Equatable {
        case idle
        case wire(Int)
        case decoding
        case loaded
        case unavailable
        case failed
    }

    private struct Item {
        var phase: Phase = .idle
        var attempts = 0
        var retryAt: Date?
    }

    private final class Request {
        let id: Int
        let size: Int
        let count: Int
        let started: Date
        var remaining: Set<String>
        var handle: PhoneFilesCancellable?
        var firstAt: Date?

        init(id: Int, size: Int, keys: [String], started: Date) {
            self.id = id
            self.size = size
            count = keys.count
            self.started = started
            remaining = Set(keys)
        }
    }

    /// What happened, for the logs and the perf harness (counts only).
    struct Stats: Equatable {
        var requests = 0
        var cancels = 0
        var delivered = 0
        var unavailable = 0
        var failures = 0
        var diskHits = 0
    }

    private let service: PhoneFilesService
    let cache: PhoneThumbnailCache
    private let clock: () -> Date
    private var phoneID: String?
    private var boxes: [String: ThumbnailBox] = [:]
    private var keyMemo: [PhoneFileEntry: String] = [:]
    private var items: [String: Item] = [:]
    private var requests: [Int: Request] = [:]
    private var nextRequestID = 0
    /// Rows that appeared (file lists) by entry ID; the grid passes its visible items in order instead.
    private var appearedRows: [String: PhoneFileEntry] = [:]
    private var visibleList: [PhoneFileEntry]?
    private var aheadList: [PhoneFileEntry]?
    /// The listing's order, to sort appeared rows and look ahead of them.
    private var order: [PhoneFileEntry] = []
    private var index: [String: Int] = [:]
    private var diskLoads = Set<String>()
    /// Keys whose disk copy would not load: they come from the phone again.
    private var diskBroken = Set<String>()
    private var imageBoxes = Set<String>()
    private var pumpScheduled = false
    private var retryWork: DispatchWorkItem?
    private var retryAt: Date?
    private var busyUntil: Date?
    /// The phone went away: nothing is asked until `resume`.
    private var paused = false
    /// The visible items of the last report, to tell a scroll from a jump.
    private var lastVisibleIDs = Set<String>()
    private var settleUntil: Date?
    private var tick: UInt64 = 0
    private var firstScreen: (started: Date, logged: Bool)?
    private(set) var stats = Stats()
    /// Timing hook for the perf harness: every visible item has its picture or its fallback.
    var onVisibleFilled: (() -> Void)?
    /// The class defaults; tests shorten them.
    var retryDelays = PhoneThumbnailScheduler.retryDelays
    var busyPause = PhoneThumbnailScheduler.busyPause
    var imageBoxLimit = PhoneThumbnailScheduler.imageBoxLimit

    init(service: PhoneFilesService, cache: PhoneThumbnailCache, clock: @escaping () -> Date = Date.init) {
        self.service = service
        self.cache = cache
        self.clock = clock
    }

    // MARK: Phone and listing

    func setPhone(_ id: String?) {
        guard id != phoneID else { return }
        cancelAllRequests()
        phoneID = id
        boxes.removeAll()
        keyMemo.removeAll()
        items.removeAll()
        appearedRows.removeAll()
        visibleList = nil
        aheadList = nil
        diskLoads.removeAll()
        diskBroken.removeAll()
        imageBoxes.removeAll()
        busyUntil = nil
        paused = false
        firstScreen = nil
    }

    func setOrder(_ entries: [PhoneFileEntry]) {
        order = entries
        index = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        schedulePump()
    }

    /// The content-addressed key (computed once per entry: the digest is the costly part of a flush).
    func cacheKey(_ entry: PhoneFileEntry) -> String {
        if let key = keyMemo[entry] { return key }
        let key = entry.cacheKey(phoneID: phoneID ?? "")
        keyMemo[entry] = key
        return key
    }

    func box(for entry: PhoneFileEntry) -> ThumbnailBox {
        let key = cacheKey(entry)
        if let box = boxes[key] { return box }
        let box = ThumbnailBox(key: key, tint: cache.tint(key))
        if let hit = cache.memoryImage(key) {
            box.set(hit, animated: false)
            imageBoxes.insert(key)
        } else if let phase = items[key]?.phase {
            if phase == .unavailable { box.mark(.unavailable) }
            if phase == .failed { box.mark(.failed) }
        }
        boxes[key] = box
        return box
    }

    // MARK: What is on screen

    /// The grid: visible items in order, and the ones coming next in the scroll direction.
    func setVisible(_ visible: [PhoneFileEntry], ahead: [PhoneFileEntry]) {
        if firstScreen == nil, !visible.isEmpty { firstScreen = (clock(), false) }
        let ids = Set(visible.map(\.id))
        if !lastVisibleIDs.isEmpty, !ids.isEmpty, ids.isDisjoint(with: lastVisibleIDs) {
            settleUntil = clock().addingTimeInterval(Self.settle)
        }
        if !ids.isEmpty { lastVisibleIDs = ids }
        visibleList = visible
        aheadList = ahead
        schedulePump()
    }

    /// File lists: a row came into view.
    func appeared(_ entry: PhoneFileEntry) {
        guard entry.hasThumbnail else { return }
        if firstScreen == nil { firstScreen = (clock(), false) }
        appearedRows[entry.id] = entry
        schedulePump()
    }

    func disappeared(_ entry: PhoneFileEntry) {
        guard appearedRows.removeValue(forKey: entry.id) != nil else { return }
        schedulePump()
    }

    /// Window closed or section changed: requests stop, what arrived stays.
    func stop() {
        cancelAllRequests()
        appearedRows.removeAll()
        visibleList = nil
        aheadList = nil
        retryWork?.cancel()
        retryWork = nil
        retryAt = nil
        firstScreen = nil
    }

    /// The phone is back (reconnected, or browsing turned on again): ask again.
    func resume() {
        guard paused else { return }
        paused = false
        schedulePump()
    }

    /// Refresh: everything that failed or was missing is asked for again.
    func retryFailed() {
        for (key, item) in items where item.phase == .failed || item.phase == .unavailable {
            items[key] = Item()
            boxes[key]?.mark(.waiting)
        }
        diskBroken.removeAll()
        paused = false
        busyUntil = nil
        schedulePump()
    }

    // MARK: The pump

    private func schedulePump() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    /// Runs now (tests): fills from the caches, cancels what nobody wants, sends what is missing.
    func pumpNow() { pump() }

    private func wanted() -> (visible: [PhoneFileEntry], ahead: [PhoneFileEntry]) {
        let visible = visibleList ?? appearedRows.values.sorted { (index[$0.id] ?? .max) < (index[$1.id] ?? .max) }
        var ahead = aheadList ?? []
        if aheadList == nil, let last = visible.last.flatMap({ index[$0.id] }) {
            let upper = min(order.count, last + 1 + Self.prefetchAhead)
            if last + 1 < upper { ahead = Array(order[(last + 1)..<upper]) }
        }
        return (visible.filter(\.hasThumbnail), ahead.filter(\.hasThumbnail))
    }

    private func pump() {
        pumpScheduled = false
        guard let phoneID, !paused else { return }
        let (visible, ahead) = wanted()
        let now = clock()
        tick += 1
        var visibleNeeds: [PhoneFileEntry] = []
        var aheadNeeds: [PhoneFileEntry] = []
        var wantedKeys = Set<String>()
        var visibleKeys = Set<String>()
        var nextRetry: Date?
        for (isVisible, list) in [(true, visible), (false, ahead)] {
            for entry in list {
                let key = cacheKey(entry)
                guard wantedKeys.insert(key).inserted else { continue }
                if isVisible { visibleKeys.insert(key) }
                let box = self.box(for: entry)
                box.lastUsed = tick
                if box.image != nil { continue }
                var item = items[key] ?? Item()
                switch item.phase {
                case .wire, .decoding, .unavailable, .failed:
                    continue
                case .idle, .loaded:
                    if !diskBroken.contains(key), cache.contains(key, kind: .thumbnail) {
                        loadFromDisk(key)
                        continue
                    }
                    if item.phase == .loaded {
                        item.phase = .idle
                        items[key] = item
                    }
                    if let due = item.retryAt, due > now {
                        nextRetry = min(nextRetry ?? due, due)
                        continue
                    }
                    if isVisible { visibleNeeds.append(entry) } else { aheadNeeds.append(entry) }
                }
            }
        }
        // Requests none of whose items are wanted any more give their slot back.
        for id in requests.keys.sorted() where requests[id].map({ $0.remaining.isDisjoint(with: wantedKeys) }) == true {
            cancelRequest(id)
        }
        let used = service.mediaRequestsInWindow(phoneID: phoneID)
        if let busyUntil, busyUntil > now {
            nextRetry = min(nextRetry ?? busyUntil, busyUntil)
        } else if let settleUntil, settleUntil > now {
            // Still flying past screens: nothing new until the scroll settles.
            nextRetry = min(nextRetry ?? settleUntil, settleUntil)
        } else {
            busyUntil = nil
            settleUntil = nil
            // Visible items first: a request that only carries items further ahead makes room for them.
            if !visibleNeeds.isEmpty, requests.count >= Self.maxInFlight, used < Self.budgetVisible,
               let id = requests.keys.sorted().last(where: { requests[$0].map { $0.remaining.isDisjoint(with: visibleKeys) } == true }) {
                cancelRequest(id)
            }
            var budget = Self.budgetVisible - used
            send(&visibleNeeds, batch: Self.visibleBatch, budget: &budget, phoneID: phoneID)
            var aheadBudget = budget - (Self.budgetVisible - Self.budgetAhead)
            if aheadNeeds.count >= Self.aheadMinimum || requests.isEmpty {
                send(&aheadNeeds, batch: Self.aheadBatch, budget: &aheadBudget, phoneID: phoneID)
            }
            // Over budget: look again when the oldest request has left the phone's window.
            if (budget <= 0 && !visibleNeeds.isEmpty) || (aheadBudget <= 0 && !aheadNeeds.isEmpty) {
                let later = now.addingTimeInterval(0.5)
                nextRetry = min(nextRetry ?? later, later)
            }
        }
        if let nextRetry { armRetry(at: nextRetry) }
        trimImages(keeping: wantedKeys)
        checkFilled()
    }

    private func send(_ needs: inout [PhoneFileEntry], batch limit: Int, budget: inout Int, phoneID: String) {
        while requests.count < Self.maxInFlight, !needs.isEmpty, budget > 0 {
            budget -= 1
            let size = Self.size(for: needs[0])
            var batch: [PhoneFileEntry] = []
            var rest: [PhoneFileEntry] = []
            for entry in needs {
                if batch.count < limit, Self.size(for: entry) == size { batch.append(entry) } else { rest.append(entry) }
            }
            needs = rest
            start(batch, size: size, phoneID: phoneID)
        }
    }

    private func start(_ batch: [PhoneFileEntry], size: Int, phoneID: String) {
        nextRequestID += 1
        let id = nextRequestID
        let keys = batch.map(cacheKey)
        for key in keys { items[key, default: Item()].phase = .wire(id) }
        let request = Request(id: id, size: size, keys: keys, started: clock())
        requests[id] = request
        stats.requests += 1
        let handle = service.thumbnails(phoneID: phoneID, entries: batch, size: { _ in size }, lane: "grid.\(id)", deliver: { [weak self] entry, image in
            self?.delivered(id, entry: entry, image: image, phoneID: phoneID)
        }, finished: { [weak self] result in
            self?.finished(id, result: result, phoneID: phoneID)
        })
        // A request that could not start ended inside the call.
        requests[id]?.handle = handle
    }

    private func delivered(_ id: Int, entry: PhoneFileEntry, image: PhoneImage, phoneID: String) {
        guard phoneID == self.phoneID else { return }
        let key = cacheKey(entry)
        if let request = requests[id] {
            request.remaining.remove(key)
            if request.firstAt == nil { request.firstAt = clock() }
        }
        items[key, default: Item()].phase = .decoding
        stats.delivered += 1
        cache.store(key, image: image, maxPixel: Self.maxSize) { [weak self] decoded in
            guard let self, self.phoneID == phoneID else { return }
            if let decoded {
                self.items[key] = Item(phase: .loaded)
                self.diskBroken.remove(key)
                if let box = self.boxes[key] {
                    box.set(decoded, animated: true)
                    self.imageBoxes.insert(key)
                }
            } else {
                // Bytes that do not decode: the type icon, not asked for again until a refresh.
                self.items[key] = Item(phase: .unavailable)
                self.boxes[key]?.mark(.unavailable)
                self.stats.unavailable += 1
            }
            self.checkFilled()
        }
    }

    private func finished(_ id: Int, result: Result<[PhoneFileEntry], PhoneFilesError>, phoneID: String) {
        guard let request = requests.removeValue(forKey: id), phoneID == self.phoneID else { return }
        let now = clock()
        for key in request.remaining {
            guard items[key]?.phase == .wire(id) else { continue }
            var item = items[key] ?? Item()
            switch result {
            case .success:
                // Answered without it (in `missing`, or never mentioned): the phone has no picture.
                item = Item(phase: .unavailable)
                boxes[key]?.mark(.unavailable)
                stats.unavailable += 1
            case .failure(.cancelled):
                item.phase = .idle
            case .failure(.code(FolderCode.busy)):
                item.phase = .idle
                busyUntil = now.addingTimeInterval(busyPause)
            case .failure(.notConnected), .failure(.notBrowsable):
                item.phase = .idle
                paused = true
            case .failure:
                item.attempts += 1
                stats.failures += 1
                if item.attempts > retryDelays.count {
                    item.phase = .failed
                    item.retryAt = nil
                    boxes[key]?.mark(.failed)
                } else {
                    item.phase = .idle
                    item.retryAt = now.addingTimeInterval(retryDelays[item.attempts - 1])
                }
            }
            items[key] = item
        }
        let first = request.firstAt.map { Int($0.timeIntervalSince(request.started) * 1000) } ?? -1
        BridgeyLog.files.info("THUMBS request n=\(request.count, privacy: .public) size=\(request.size, privacy: .public) first_ms=\(first, privacy: .public) done_ms=\(Int(now.timeIntervalSince(request.started) * 1000), privacy: .public) result=\(Self.describe(result), privacy: .public)")
        schedulePump()
    }

    private static func describe(_ result: Result<[PhoneFileEntry], PhoneFilesError>) -> String {
        switch result {
        case let .success(missing): return missing.isEmpty ? "ok" : "ok missing=\(missing.count)"
        case .failure(.cancelled): return "cancelled"
        case .failure(.timeout): return "timeout"
        case .failure(.notConnected): return "not_connected"
        case .failure(.notBrowsable): return "not_browsable"
        case .failure(.interrupted): return "interrupted"
        case let .failure(.code(code)): return code
        }
    }

    private func cancelRequest(_ id: Int) {
        guard let request = requests[id] else { return }
        stats.cancels += 1
        request.handle?.cancel()
        // The browse client reports a cancelled request at once; a service that does not, ends it here.
        if requests[id] != nil, let phoneID { finished(id, result: .failure(.cancelled), phoneID: phoneID) }
    }

    private func cancelAllRequests() {
        for id in requests.keys.sorted() { cancelRequest(id) }
        requests.removeAll()
    }

    private func loadFromDisk(_ key: String) {
        guard diskLoads.insert(key).inserted else { return }
        stats.diskHits += 1
        let phoneID = self.phoneID
        cache.load(key, maxPixel: Self.maxSize) { [weak self] decoded in
            guard let self, self.phoneID == phoneID else { return }
            self.diskLoads.remove(key)
            if let decoded {
                self.items[key] = Item(phase: .loaded)
                if let box = self.boxes[key] {
                    box.set(decoded, animated: false)
                    self.imageBoxes.insert(key)
                }
                self.checkFilled()
            } else {
                // The copy on disk is gone or damaged: ask the phone.
                self.diskBroken.insert(key)
                if self.items[key]?.phase == .loaded { self.items[key] = Item() }
                self.schedulePump()
            }
        }
    }

    private func armRetry(at date: Date) {
        if let retryAt, retryAt <= date, retryWork != nil { return }
        retryWork?.cancel()
        retryAt = date
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.retryWork = nil
                self?.retryAt = nil
                self?.pump()
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, date.timeIntervalSince(clock())), execute: work)
    }

    /// Boxes far from the screen let go of their images once many hold one; the cache keeps the bytes.
    private func trimImages(keeping wanted: Set<String>) {
        guard imageBoxes.count > imageBoxLimit else { return }
        let far = imageBoxes.filter { !wanted.contains($0) }.compactMap { boxes[$0] }.sorted { $0.lastUsed < $1.lastUsed }
        for box in far.prefix(imageBoxes.count - imageBoxLimit * 3 / 4) {
            box.release()
            imageBoxes.remove(box.key)
        }
    }

    private func checkFilled() {
        let visible = wanted().visible
        guard !visible.isEmpty else { return }
        let done = visible.allSatisfy { entry in
            let box = self.box(for: entry)
            return box.image != nil || box.state == .unavailable || box.state == .failed
        }
        guard done else { return }
        if let screen = firstScreen, !screen.logged {
            firstScreen = (screen.started, true)
            BridgeyLog.files.notice("THUMBS screen filled n=\(visible.count, privacy: .public) ms=\(Int(self.clock().timeIntervalSince(screen.started) * 1000), privacy: .public) requests=\(self.stats.requests, privacy: .public) cancels=\(self.stats.cancels, privacy: .public)")
        }
        onVisibleFilled?()
    }

    // MARK: Tests

    var requestsInFlight: Int { requests.count }
    var boxesHoldingImages: Int { imageBoxes.count }
    func state(of entry: PhoneFileEntry) -> String {
        switch items[cacheKey(entry)]?.phase ?? .idle {
        case .idle: "idle"
        case .wire: "wire"
        case .decoding: "decoding"
        case .loaded: "loaded"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }
}

/// Hover prefetch: rest the pointer on a thumbnail for 150 ms and its preview is fetched in the background.
@MainActor
final class PhoneHoverPrefetcher {
    static let delay: TimeInterval = 0.15
    static let maxInFlight = 3
    /// Media requests in the phone's 10-second window above which hovering prefetches nothing.
    static let budget = BrowseLimits.mediaPerWindow / 2
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
        // Prefetch only while the phone's media budget has plenty left: the grid and the viewer come first.
        guard service.mediaRequestsInWindow(phoneID: phoneID) < Self.budget else { return }
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
