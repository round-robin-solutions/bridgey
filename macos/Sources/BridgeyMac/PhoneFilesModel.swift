import AppKit
import Combine
import Foundation

// Files 2.0: the Phone files window's state. Sections like Telegram's attach sheet (Media, Files, Folders,
// Recent from phone); every listing opens from the last copy on this Mac first, then refreshes from the phone,
// so reopening is instant. Names live only in memory and in the owner-only caches; nothing here is logged.

enum PhoneFilesSection: String, CaseIterable, Identifiable {
    case media, files, folders, recent
    var id: String { rawValue }
}

/// One listing (a section, or the open folder) with paging.
struct PhoneListing: Equatable {
    var entries: [PhoneFileEntry] = []
    var nextCursor: String?
    var loading = false
    var loaded = false
    var error: PhoneFilesError?
    /// Media only.
    var access: PhoneMediaAccess = .full
    var indexing = false
    /// Folders only.
    var writable = false
    var folderCount = 0
    var fileCount = 0

    var canLoadMore: Bool { nextCursor != nil && !loading }
}

/// The open preview: what shows now, and what is still coming.
struct PhonePreviewState: Equatable {
    enum Quality: Int { case none, thumbnail, preview, original }

    let entry: PhoneFileEntry
    var quality: Quality = .none
    var originalProgress: PhoneTransferProgress?
    var originalURL: URL?
    var error: PhoneFilesError?
    /// When the preview was opened, for the hover-to-open measurement.
    let openedAt: Date
    var previewShownAt: Date?

    static func == (lhs: PhonePreviewState, rhs: PhonePreviewState) -> Bool {
        lhs.entry == rhs.entry && lhs.quality == rhs.quality && lhs.originalProgress == rhs.originalProgress
            && lhs.originalURL == rhs.originalURL && lhs.error == rhs.error
    }
}

/// A download or upload running from this window, shown in the status strip.
struct PhoneFilesActivity: Identifiable, Equatable {
    enum Kind { case download, upload, quickLook }
    let id: String
    let kind: Kind
    let title: String
    var progress: PhoneTransferProgress
    var cancellable: PhoneFilesCancellable?

    static func == (lhs: PhoneFilesActivity, rhs: PhoneFilesActivity) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.progress == rhs.progress
    }
}

@MainActor
final class PhoneFilesModel: ObservableObject {
    static let pageSize = 120

    @Published private(set) var phones: [BrowsablePhone] = []
    @Published private(set) var phoneID: String?
    @Published var section: PhoneFilesSection = .media {
        didSet { if section != oldValue { sectionChanged() } }
    }
    @Published private(set) var info: PhoneBrowseInfo?
    @Published private(set) var infoError: PhoneFilesError?
    @Published private(set) var listings: [PhoneFilesSection: PhoneListing] = [:]
    @Published private(set) var placeID: String?
    @Published private(set) var path: [String] = []
    @Published private(set) var sort: PhoneFileSort = .name
    @Published private(set) var descending = false
    @Published var selection: Set<String> = []
    @Published private(set) var saved: [String: URL] = [:]
    @Published private(set) var activities: [PhoneFilesActivity] = []
    @Published var preview: PhonePreviewState?
    @Published private(set) var previewImage: PhoneDecodedImage?
    @Published private(set) var notice: String?
    @Published var dropTargeted = false
    /// Screenshots pin "now" so day headers and dates do not depend on when they render.
    var displayNow: Date?

    let service: PhoneFilesService
    let cache: PhoneThumbnailCache
    let thumbnails: PhoneThumbnailScheduler
    let prefetch: PhoneHoverPrefetcher
    private let defaults: UserDefaults
    private let listingCache: PhoneListingCache
    private let receivedFolder: () -> URL
    private let previewFolder: URL
    private var generation = 0
    private var noticeClear: DispatchWorkItem?
    private var lastAnchor: String?

    init(service: PhoneFilesService, cache: PhoneThumbnailCache = .shared, defaults: UserDefaults = .standard,
         listingCache: PhoneListingCache = .shared, receivedFolder: @escaping () -> URL = PhoneFilesPaths.receivedFolder,
         previewFolder: URL = PhoneFilesPaths.previewFolder()) {
        self.service = service
        self.cache = cache
        self.defaults = defaults
        self.listingCache = listingCache
        self.receivedFolder = receivedFolder
        self.previewFolder = previewFolder
        thumbnails = PhoneThumbnailScheduler(service: service, cache: cache)
        prefetch = PhoneHoverPrefetcher(service: service, cache: cache)
        sort = PhoneFileSort(rawValue: defaults.string(forKey: Keys.sort) ?? "") ?? .name
        descending = defaults.bool(forKey: Keys.descending)
        section = PhoneFilesSection(rawValue: defaults.string(forKey: Keys.section) ?? "") ?? .media
        service.onPhonesChanged = { [weak self] in self?.phonesChanged() }
        phones = service.phones
    }

    // MARK: Phones

    var phone: BrowsablePhone? { phones.first { $0.id == phoneID } }
    var phoneName: String { phone?.name ?? L10n.text("phonefiles.phone", fallback: "Phone") }

    /// Opens on `preferred`, else the last phone, else the first browsable one.
    func start(preferred: String?) {
        phones = service.phones
        let last = defaults.string(forKey: Keys.phone)
        let pick = [preferred, last].compactMap { $0 }.first { id in phones.contains { $0.id == id } }
            ?? phones.first(where: \.browsable)?.id ?? phones.first?.id
        select(phone: pick, force: true)
    }

    func select(phone id: String?, force: Bool = false) {
        guard force || id != phoneID else { return }
        generation += 1
        phoneID = id
        defaults.set(id, forKey: Keys.phone)
        thumbnails.setPhone(id)
        prefetch.cancelAll()
        prefetch.phoneID = id
        prefetch.route = phone?.route ?? .unknown
        info = nil
        infoError = nil
        listings = [:]
        selection = []
        saved = [:]
        preview = nil
        guard let id, phone?.browsable == true else { return }
        placeID = defaults.string(forKey: Keys.place(id))
        path = (defaults.string(forKey: Keys.path(id)) ?? "").split(separator: "/").map(String.init)
        loadInfo()
        loadSection(section, reset: true)
    }

    private func phonesChanged() {
        let previous = phone
        phones = service.phones
        let now = phone
        if now == nil, let first = phones.first(where: \.browsable) ?? phones.first {
            select(phone: first.id)
        } else if now?.browsable != previous?.browsable {
            select(phone: phoneID, force: true)
        } else {
            prefetch.route = now?.route ?? .unknown
        }
    }

    // MARK: Loading

    func loadInfo() {
        guard let phoneID else { return }
        let generation = self.generation
        service.places(phoneID: phoneID) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case let .success(info):
                self.info = info
                self.infoError = nil
                if self.placeID != nil, !info.places.contains(where: { $0.id == self.placeID }) {
                    self.placeID = nil
                    self.path = []
                }
            case let .failure(error):
                self.infoError = error
            }
        }
    }

    func listing(_ section: PhoneFilesSection) -> PhoneListing { listings[section] ?? PhoneListing() }

    var currentListing: PhoneListing { listing(section) }

    var currentEntries: [PhoneFileEntry] { currentListing.entries }

    var writable: Bool {
        if section == .folders, placeID != nil, listing(.folders).loaded { return listing(.folders).writable }
        return info?.writable ?? false
    }

    private func sectionChanged() {
        defaults.set(section.rawValue, forKey: Keys.section)
        selection = []
        thumbnails.stop()
        if listings[section]?.loaded != true { loadSection(section, reset: true) }
        thumbnails.setOrder(currentEntries)
    }

    func refresh() {
        loadInfo()
        loadSection(section, reset: true)
    }

    func loadMore() {
        guard currentListing.canLoadMore else { return }
        loadSection(section, reset: false)
    }

    /// Loads the first page (from the local copy at once when there is one) or the next.
    func loadSection(_ section: PhoneFilesSection, reset: Bool) {
        guard let phoneID, phone?.browsable == true else { return }
        if section == .folders, placeID == nil { return }
        var listing = reset ? PhoneListing() : (listings[section] ?? PhoneListing())
        let cacheKey = listingKey(section)
        if reset, let cached = listingCache.load(cacheKey) {
            listing.entries = cached.entries
            listing.writable = cached.writable
            listing.loaded = true
        }
        listing.loading = true
        listing.error = nil
        let cursor = reset ? nil : listing.nextCursor
        listings[section] = listing
        if section == self.section { thumbnails.setOrder(listing.entries) }
        let generation = self.generation
        let apply: (Result<PhoneListing, PhoneFilesError>) -> Void = { [weak self] result in
            guard let self, self.generation == generation, self.listingKey(section) == cacheKey else { return }
            var next = self.listings[section] ?? PhoneListing()
            next.loading = false
            switch result {
            case let .success(page):
                next.entries = reset ? page.entries : next.entries + page.entries.filter { entry in !next.entries.contains { $0.id == entry.id } }
                next.nextCursor = page.nextCursor
                next.access = page.access
                next.indexing = page.indexing
                next.writable = page.writable
                next.folderCount = page.folderCount
                next.fileCount = page.fileCount
                next.loaded = true
                next.error = nil
                if reset { self.listingCache.save(cacheKey, entries: Array(page.entries.prefix(Self.pageSize * 2)), writable: page.writable) }
            case let .failure(error):
                next.error = error
            }
            self.listings[section] = next
            if section == self.section { self.thumbnails.setOrder(next.entries) }
        }
        switch section {
        case .media, .files, .recent:
            let kind: PhoneMediaKind = section == .media ? .media : section == .files ? .files : .recent
            service.listMedia(phoneID: phoneID, kind: kind, cursor: cursor, limit: Self.pageSize) { result in
                apply(result.map { PhoneListing(entries: $0.items, nextCursor: $0.nextCursor, access: $0.access, indexing: $0.indexing) })
            }
        case .folders:
            guard let placeID else { return }
            service.listFiles(phoneID: phoneID, placeId: placeID, path: path.joined(separator: "/"), sort: sort, descending: descending,
                              cursor: cursor) { result in
                apply(result.map { PhoneListing(entries: $0.entries, nextCursor: $0.nextCursor, writable: $0.writable,
                                                folderCount: $0.folderCount, fileCount: $0.fileCount) })
            }
        }
    }

    private func listingKey(_ section: PhoneFilesSection) -> String {
        var parts = [phoneID ?? "", section.rawValue]
        if section == .folders { parts += [placeID ?? "", path.joined(separator: "/"), sort.rawValue, descending ? "d" : "a"] }
        return PhoneFilesDigest.hex(parts.joined(separator: "\u{1F}"))
    }

    // MARK: Folders

    var place: PhonePlace? { info?.places.first { $0.id == placeID } }

    func open(place id: String?) {
        placeID = id
        path = []
        section = .folders
        rememberLocation()
        selection = []
        if id == nil {
            listings[.folders] = nil
        } else {
            loadSection(.folders, reset: true)
        }
    }

    /// Breadcrumb: -1 is the place itself.
    func goTo(depth: Int) {
        guard depth < path.count - 1 || depth == -1 else { return }
        path = depth < 0 ? [] : Array(path.prefix(depth + 1))
        rememberLocation()
        selection = []
        loadSection(.folders, reset: true)
    }

    func enter(_ entry: PhoneFileEntry) {
        guard entry.isDirectory, case let .place(placeId, folder, name) = entry.ref else { return }
        placeID = placeId
        path = (folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)) + [name]
        section = .folders
        rememberLocation()
        selection = []
        loadSection(.folders, reset: true)
    }

    func setSort(_ next: PhoneFileSort) {
        if next == sort { descending.toggle() } else {
            sort = next
            descending = next == .modified || next == .size
        }
        defaults.set(sort.rawValue, forKey: Keys.sort)
        defaults.set(descending, forKey: Keys.descending)
        loadSection(.folders, reset: true)
    }

    private func rememberLocation() {
        guard let phoneID else { return }
        defaults.set(placeID, forKey: Keys.place(phoneID))
        defaults.set(path.joined(separator: "/"), forKey: Keys.path(phoneID))
    }

    // MARK: Selection

    var selectedEntries: [PhoneFileEntry] { currentEntries.filter { selection.contains($0.id) } }

    func click(_ entry: PhoneFileEntry, command: Bool, shift: Bool) {
        if command {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            lastAnchor = entry.id
        } else if shift, let anchor = lastAnchor, let from = currentEntries.firstIndex(where: { $0.id == anchor }),
                  let to = currentEntries.firstIndex(where: { $0.id == entry.id }) {
            selection = Set(currentEntries[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [entry.id]
            lastAnchor = entry.id
        }
    }

    /// Double click or Return: a folder opens, a file previews.
    func activate(_ entry: PhoneFileEntry) {
        if entry.isDirectory { enter(entry) } else { openPreview(entry) }
    }

    /// What a drag or a menu acts on: the selection when the item is in it, else the item alone.
    func targets(for entry: PhoneFileEntry) -> [PhoneFileEntry] {
        selection.contains(entry.id) ? selectedEntries : [entry]
    }

    // MARK: Preview

    func openPreview(_ entry: PhoneFileEntry) {
        guard let phoneID else { return }
        let key = entry.cacheKey(phoneID: phoneID)
        var state = PhonePreviewState(entry: entry, openedAt: Date())
        previewImage = nil
        if let large = cache.memoryImage(key, kind: .preview) {
            previewImage = large
            state.quality = .preview
            state.previewShownAt = Date()
        } else if let small = cache.memoryImage(key) {
            previewImage = small
            state.quality = .thumbnail
        }
        preview = state
        if state.quality != .preview, entry.hasThumbnail { loadPreviewImage(entry, key: key, phoneID: phoneID) }
        if let url = savedOriginal(entry) { preview?.originalURL = url }
    }

    private func loadPreviewImage(_ entry: PhoneFileEntry, key: String, phoneID: String) {
        let show: (PhoneDecodedImage?) -> Void = { [weak self] decoded in
            guard let self, let decoded, self.preview?.entry.id == entry.id else { return }
            if (self.preview?.quality.rawValue ?? 0) < PhonePreviewState.Quality.preview.rawValue {
                self.previewImage = decoded
                self.preview?.quality = .preview
                self.preview?.previewShownAt = Date()
            }
        }
        if cache.contains(key, kind: .preview) {
            cache.load(key, kind: .preview, maxPixel: PhoneHoverPrefetcher.previewSize) { decoded in show(decoded) }
            return
        }
        if previewImage == nil, cache.contains(key, kind: .thumbnail) {
            cache.load(key, maxPixel: PhoneThumbnailScheduler.maxSize) { [weak self] decoded in
                guard let self, let decoded, self.preview?.entry.id == entry.id, self.previewImage == nil else { return }
                self.previewImage = decoded
                self.preview?.quality = .thumbnail
            }
        }
        // A hover prefetch already on the wire: wait for it rather than asking twice.
        if prefetch.whenPreviewReady(entry, { [weak self] decoded in
            if decoded != nil { show(decoded) } else { self?.requestPreview(entry, key: key, phoneID: phoneID, show: show) }
        }) { return }
        requestPreview(entry, key: key, phoneID: phoneID, show: show)
    }

    private func requestPreview(_ entry: PhoneFileEntry, key: String, phoneID: String, show: @escaping (PhoneDecodedImage?) -> Void) {
        guard preview?.entry.id == entry.id else { return }
        service.preview(phoneID: phoneID, entry: entry, size: PhoneHoverPrefetcher.previewSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(image):
                self.cache.store(key, kind: .preview, image: image, maxPixel: PhoneHoverPrefetcher.previewSize) { decoded in show(decoded) }
            case let .failure(error):
                if self.preview?.entry.id == entry.id, self.previewImage == nil { self.preview?.error = error }
            }
        }
    }

    func closePreview() {
        preview = nil
        previewImage = nil
    }

    /// The original in the private preview folder (Quick Look, video playback), downloaded once per cache key.
    func fetchOriginal(_ entry: PhoneFileEntry, then: @escaping (URL) -> Void) {
        if let url = savedOriginal(entry) {
            then(url)
            return
        }
        guard let phoneID else { return }
        let folder = previewFolder.appendingPathComponent(entry.cacheKey(phoneID: phoneID), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = "ql-" + entry.id
        guard !activities.contains(where: { $0.id == id }) else { return }
        let handle = service.download(phoneID: phoneID, refs: [entry.ref], into: folder, purpose: .preview, progress: { [weak self] progress in
            self?.updateActivity(id, progress)
            if self?.preview?.entry.id == entry.id { self?.preview?.originalProgress = progress }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.finishActivity(id)
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                if self.preview?.entry.id == entry.id {
                    self.preview?.originalURL = url
                    self.preview?.originalProgress = nil
                }
                then(url)
            case let .failure(error):
                if self.preview?.entry.id == entry.id { self.preview?.originalProgress = nil }
                self.show(error)
            }
        })
        activities.append(PhoneFilesActivity(id: id, kind: .quickLook, title: entry.name, progress: PhoneTransferProgress(), cancellable: handle))
    }

    private func savedOriginal(_ entry: PhoneFileEntry) -> URL? {
        if let url = saved[entry.id], FileManager.default.fileExists(atPath: url.path) { return url }
        guard let phoneID else { return nil }
        let folder = previewFolder.appendingPathComponent(entry.cacheKey(phoneID: phoneID), isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.first { !$0.lastPathComponent.hasPrefix(".") }
    }

    // MARK: Downloads and uploads

    /// Download button: Received files, with a transfer row, history and Finder metadata.
    func downloadSelection() {
        let entries = selectedEntries.isEmpty ? (preview.map { [$0.entry] } ?? []) : selectedEntries
        download(entries, into: receivedFolder(), purpose: .save) { _ in }
    }

    /// Downloads into `directory`; the saved URLs come back in order.
    @discardableResult
    func download(_ entries: [PhoneFileEntry], into directory: URL, purpose: PhoneDownloadPurpose,
                  completion: @escaping (Result<[URL], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        guard let phoneID, !entries.isEmpty else {
            completion(.failure(.notConnected))
            return .none
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let title = entries.count == 1 ? entries[0].name
            : String(format: L10n.text("phonefiles.items", fallback: "%d items"), entries.count)
        let handle = service.download(phoneID: phoneID, refs: entries.map(\.ref), into: directory, purpose: purpose, progress: { [weak self] progress in
            self?.updateActivity(id, progress)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.finishActivity(id)
            switch result {
            case let .success(urls):
                for (entry, url) in zip(entries, urls) { self.saved[entry.id] = url }
                if purpose == .save {
                    self.show(String(format: L10n.text("phonefiles.saved", fallback: "Saved %@ to Received files"), title))
                }
            case let .failure(error):
                if error != .cancelled { self.show(error) }
            }
            completion(result)
        })
        activities.append(PhoneFilesActivity(id: id, kind: .download, title: title, progress: PhoneTransferProgress(), cancellable: handle))
        return handle
    }

    var canUpload: Bool { section == .folders && placeID != nil && writable && listing(.folders).loaded }

    /// Files dropped from Finder on the open folder.
    @discardableResult
    func upload(_ urls: [URL]) -> Bool {
        guard let phoneID, let placeID, !urls.isEmpty else { return false }
        guard writable else {
            show(String(format: L10n.text("phonefiles.readOnly", fallback: "Turn on Allow other devices to change files here on %@ to add files."), phoneName))
            return false
        }
        let id = UUID().uuidString
        let title = urls.count == 1 ? urls[0].lastPathComponent
            : String(format: L10n.text("phonefiles.items", fallback: "%d items"), urls.count)
        let folderPath = path.joined(separator: "/")
        let handle = service.upload(phoneID: phoneID, urls: urls, placeId: placeID, path: folderPath, progress: { [weak self] progress in
            self?.updateActivity(id, progress)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.finishActivity(id)
            switch result {
            case .success:
                if self.placeID == placeID, self.path.joined(separator: "/") == folderPath { self.loadSection(.folders, reset: true) }
            case let .failure(error):
                if error != .cancelled { self.show(error) }
            }
        })
        activities.append(PhoneFilesActivity(id: id, kind: .upload, title: title, progress: PhoneTransferProgress(), cancellable: handle))
        return true
    }

    func cancel(activity id: String) {
        activities.first { $0.id == id }?.cancellable?.cancel()
        finishActivity(id)
    }

    func savedURL(_ entry: PhoneFileEntry) -> URL? {
        guard let url = saved[entry.id], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func updateActivity(_ id: String, _ progress: PhoneTransferProgress) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].progress = progress
    }

    private func finishActivity(_ id: String) {
        activities.removeAll { $0.id == id }
    }

    // MARK: Notices

    func show(_ error: PhoneFilesError) { show(PhoneFilesText.error(error, phone: phoneName)) }

    func show(_ text: String) {
        notice = text
        noticeClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.notice = nil } }
        noticeClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: clear)
    }

    /// Window closed: requests stop, caches stay.
    func stop() {
        thumbnails.stop()
        prefetch.cancelAll()
    }

    // MARK: Screenshots and tests

    func setForTesting(phones: [BrowsablePhone], phoneID: String?, info: PhoneBrowseInfo?, section: PhoneFilesSection,
                       listings: [PhoneFilesSection: PhoneListing], placeID: String? = nil, path: [String] = []) {
        self.phones = phones
        self.phoneID = phoneID
        thumbnails.setPhone(phoneID)
        self.info = info
        self.listings = listings
        self.placeID = placeID
        self.path = path
        self.section = section
    }

    func setPreviewForTesting(_ state: PhonePreviewState?, image: PhoneDecodedImage?) {
        preview = state
        previewImage = image
    }

    func setActivitiesForTesting(_ list: [PhoneFilesActivity]) { activities = list }

    private enum Keys {
        static let phone = "phoneFiles.last.phone"
        static let section = "phoneFiles.last.section"
        static let sort = "phoneFiles.sort"
        static let descending = "phoneFiles.sort.descending"
        static func place(_ id: String) -> String { "phoneFiles.last.place.\(id)" }
        static func path(_ id: String) -> String { "phoneFiles.last.path.\(id)" }
    }
}

enum PhoneFilesPaths {
    /// Settings > Files > Received files (the same default as BridgeySettings).
    static func receivedFolder() -> URL {
        if let path = UserDefaults.standard.string(forKey: "settings.receiveFolderPath") { return URL(fileURLWithPath: path, isDirectory: true) }
        return (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true))
            .appendingPathComponent("Bridgey", isDirectory: true)
    }

    /// Originals opened for Quick Look: a private cache, one 0700 folder per cache key.
    static func previewFolder() -> URL {
        PhoneThumbnailCache.defaultDirectory().appendingPathComponent("originals", isDirectory: true)
    }
}

/// The first pages of each listing, so the window opens on what was there last time. Owner-only JSON in Caches.
final class PhoneListingCache {
    static let shared = PhoneListingCache(directory: PhoneThumbnailCache.defaultDirectory().appendingPathComponent("listings", isDirectory: true))

    struct Stored: Codable {
        struct Entry: Codable {
            let ref: PhoneRef
            let name: String
            let isDirectory: Bool
            let size: Int64?
            let modified: Date?
            let mimeType: String?
            let hasThumbnail: Bool
            let width: Int?
            let height: Int?
            let durationMs: Int64?
            let location: String?
        }

        let entries: [Entry]
        let writable: Bool
    }

    private let directory: URL?
    private var memory: [String: (entries: [PhoneFileEntry], writable: Bool)] = [:]

    init(directory: URL?) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    func load(_ key: String) -> (entries: [PhoneFileEntry], writable: Bool)? {
        if let hit = memory[key] { return hit }
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(key)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let entries = stored.entries.map {
            PhoneFileEntry(ref: $0.ref, name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified, mimeType: $0.mimeType,
                           hasThumbnail: $0.hasThumbnail, width: $0.width, height: $0.height, durationMs: $0.durationMs, location: $0.location)
        }
        memory[key] = (entries, stored.writable)
        return (entries, stored.writable)
    }

    func save(_ key: String, entries: [PhoneFileEntry], writable: Bool) {
        memory[key] = (entries, writable)
        guard let directory else { return }
        let stored = Stored(entries: entries.map {
            Stored.Entry(ref: $0.ref, name: $0.name, isDirectory: $0.isDirectory, size: $0.size, modified: $0.modified, mimeType: $0.mimeType,
                         hasThumbnail: $0.hasThumbnail, width: $0.width, height: $0.height, durationMs: $0.durationMs, location: $0.location)
        }, writable: writable)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let target = directory.appendingPathComponent(key)
        let temporary = directory.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, target.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }

    func removeAll() {
        memory.removeAll()
        guard let directory else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
