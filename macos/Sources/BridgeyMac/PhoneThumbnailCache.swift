import AppKit
import CoreGraphics
import Foundation
import ImageIO

// Files 2.0: the content-addressed cache behind the Phone files window. Keys are PhoneFileEntry.cacheKey
// (a SHA-256 of device, ref, modified and size), so the same key always means the same bytes and nothing
// ever goes stale; a changed file gets a new key. Two tiers:
//   - memory: decoded CGImages in a least-recently-used map with a hard byte budget per kind (thumbnails
//     about 96 MB, previews about 64 MB), tints in a dictionary. NSCache's limit is only a hint: a long scroll
//     through 2,000 photos held 1.5 GB (2026-10-28);
//   - disk: Caches/<support folder>/PhoneFiles/<kind>/<key>, a 0700 folder of 0600 files, least recently used
//     pruned past a byte budget (about 300 MB). File names are digests, so no name reaches the disk.
// Disk reads, writes and decoding run on a utility queue; completions come back on the main thread.

/// Decoded images by key, least recently used dropped first once the bytes pass the budget. Thread-safe.
final class PhoneImageMemory: @unchecked Sendable {
    let byteBudget: Int
    private let lock = NSLock()
    private var entries: [String: (image: PhoneDecodedImage, bytes: Int, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    private(set) var bytes = 0

    init(byteBudget: Int) { self.byteBudget = byteBudget }

    func get(_ key: String) -> PhoneDecodedImage? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        tick += 1
        entry.tick = tick
        entries[key] = entry
        return entry.image
    }

    func set(_ key: String, _ image: PhoneDecodedImage) {
        let cost = max(1, image.pixelWidth * image.pixelHeight * 4)
        lock.lock(); defer { lock.unlock() }
        tick += 1
        if let old = entries[key] { bytes -= old.bytes }
        entries[key] = (image, cost, tick)
        bytes += cost
        guard bytes > byteBudget else { return }
        // Down to 85% at once, so a scroll does not evict on every insert.
        let target = byteBudget * 85 / 100
        for (oldKey, entry) in entries.sorted(by: { $0.value.tick < $1.value.tick }) where bytes > target && oldKey != key {
            entries.removeValue(forKey: oldKey)
            bytes -= entry.bytes
        }
    }

    func removeAll() {
        lock.lock(); entries.removeAll(); bytes = 0; lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

/// A decoded image ready to draw, with the phone's average colour.
final class PhoneDecodedImage {
    let image: CGImage
    let tint: UInt32?
    let pixelWidth: Int
    let pixelHeight: Int

    init(image: CGImage, tint: UInt32?) {
        self.image = image
        self.tint = tint
        pixelWidth = image.width
        pixelHeight = image.height
    }
}

enum PhoneCacheKind: String, CaseIterable {
    /// Grid thumbnails (288 to 512 px, sized so the short edge covers a square cell). The folder name changed
    /// when the sizing did, so thumbnails made at the old 256 px are fetched again rather than stretched.
    case thumbnail = "thumbs2"
    /// Preview-size images (about 1600 px), from hover prefetch or opening.
    case preview = "previews"
    /// The first bytes of a video (media.range), for an instant start.
    case range = "ranges"
}

final class PhoneThumbnailCache: @unchecked Sendable {
    static let shared = PhoneThumbnailCache(directory: PhoneThumbnailCache.defaultDirectory())

    /// Disk budget for all kinds together.
    let byteBudget: Int64
    private let directory: URL?
    /// Decoded thumbnails (the grid) and previews (the viewer), each with its own budget.
    let thumbnailMemory: PhoneImageMemory
    let previewMemory: PhoneImageMemory
    private let queue = DispatchQueue(label: "bridgey.phonefiles.cache", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var tints: [String: UInt32] = [:]
    private var writesSincePrune = 0
    /// File names on disk per kind, read once at start: `contains` runs for every cell on every scroll and
    /// must not stat the disk on the main thread. Nil until the first listing finished.
    private var diskIndex: [PhoneCacheKind: Set<String>]?
    /// Writes and deletions while the index is still being read, applied when it is installed.
    private var pendingIndex: [(kind: PhoneCacheKind, name: String, added: Bool)] = []

    /// `directory` nil keeps everything in memory (tests and screenshots).
    init(directory: URL?, byteBudget: Int64 = 300 * 1024 * 1024, memoryBytes: Int = 96 * 1024 * 1024, previewMemoryBytes: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.byteBudget = byteBudget
        thumbnailMemory = PhoneImageMemory(byteBudget: memoryBytes)
        previewMemory = PhoneImageMemory(byteBudget: previewMemoryBytes)
        if let directory {
            for kind in PhoneCacheKind.allCases {
                try? FileManager.default.createDirectory(at: directory.appendingPathComponent(kind.rawValue, isDirectory: true),
                                                         withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            queue.async { [self] in
                for name in Self.retiredFolders {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))
                }
                var index: [PhoneCacheKind: Set<String>] = [:]
                for kind in PhoneCacheKind.allCases {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(kind.rawValue).path)) ?? []
                    index[kind] = Set(names.filter { !$0.hasPrefix(".") })
                }
                lock.lock()
                for change in pendingIndex {
                    if change.added { index[change.kind, default: []].insert(change.name) } else { index[change.kind]?.remove(change.name) }
                }
                pendingIndex.removeAll()
                diskIndex = index
                lock.unlock()
            }
        }
    }

    /// Folders of earlier cache layouts, deleted on start.
    static let retiredFolders = ["thumbs"]

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/PhoneFiles", isDirectory: true)
    }

    // MARK: Memory

    func memoryImage(_ key: String, kind: PhoneCacheKind = .thumbnail) -> PhoneDecodedImage? {
        memory(kind)?.get(key)
    }

    private func memory(_ kind: PhoneCacheKind) -> PhoneImageMemory? {
        switch kind {
        case .thumbnail: thumbnailMemory
        case .preview: previewMemory
        case .range: nil
        }
    }

    /// The tint for placeholders, when any tier knows it.
    func tint(_ key: String) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        return tints[key]
    }

    func rememberTint(_ key: String, _ tint: UInt32?) {
        guard let tint else { return }
        lock.lock(); tints[key] = tint; lock.unlock()
    }

    // MARK: Disk

    /// Whether the disk tier holds `key` (no decoding).
    func contains(_ key: String, kind: PhoneCacheKind) -> Bool {
        if memoryImage(key, kind: kind) != nil { return true }
        guard let url = fileURL(key, kind) else { return false }
        lock.lock()
        let indexed = diskIndex?[kind]?.contains(key)
        lock.unlock()
        return indexed ?? FileManager.default.fileExists(atPath: url.path)
    }

    private func indexDisk(_ url: URL, added: Bool) {
        guard let kind = PhoneCacheKind(rawValue: url.deletingLastPathComponent().lastPathComponent) else { return }
        let name = url.lastPathComponent
        lock.lock()
        if diskIndex != nil {
            if added { diskIndex?[kind, default: []].insert(name) } else { diskIndex?[kind]?.remove(name) }
        } else {
            pendingIndex.append((kind, name, added))
        }
        lock.unlock()
    }

    /// Memory first, then disk; decoded and downsampled to `maxPixel` off the main thread.
    func load(_ key: String, kind: PhoneCacheKind = .thumbnail, maxPixel: Int,
              completion: @escaping @MainActor (PhoneDecodedImage?) -> Void) {
        if let hit = memoryImage(key, kind: kind) {
            MainActor.assumeIsolated { completion(hit) }
            return
        }
        guard let url = fileURL(key, kind) else {
            MainActor.assumeIsolated { completion(nil) }
            return
        }
        queue.async { [self] in
            let decoded = readDecoded(url, maxPixel: maxPixel)
            if let decoded {
                insert(decoded, key: key, kind: kind)
                touch(url)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(decoded) } }
        }
    }

    /// The same as `load`, blocking, for perf tests and background batches.
    func loadSync(_ key: String, kind: PhoneCacheKind = .thumbnail, maxPixel: Int) -> PhoneDecodedImage? {
        if let hit = memoryImage(key, kind: kind) { return hit }
        guard let url = fileURL(key, kind), let decoded = readDecoded(url, maxPixel: maxPixel) else { return nil }
        insert(decoded, key: key, kind: kind)
        return decoded
    }

    /// Stores what the phone sent and hands back the decoded image.
    func store(_ key: String, kind: PhoneCacheKind = .thumbnail, image: PhoneImage, maxPixel: Int,
               completion: @escaping @MainActor (PhoneDecodedImage?) -> Void) {
        rememberTint(key, image.tint)
        queue.async { [self] in
            let decoded = Self.decode(image.data, maxPixel: maxPixel).map { PhoneDecodedImage(image: $0, tint: image.tint) }
            if let decoded { insert(decoded, key: key, kind: kind) }
            if let url = fileURL(key, kind) { write(Self.frame(image.data, tint: image.tint), to: url) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(decoded) } }
        }
    }

    /// Raw bytes (video ranges): written as they are, tint unused.
    func storeData(_ key: String, kind: PhoneCacheKind, data: Data) {
        guard let url = fileURL(key, kind) else { return }
        queue.async { [self] in write(Self.frame(data, tint: nil), to: url) }
    }

    func data(_ key: String, kind: PhoneCacheKind) -> Data? {
        guard let url = fileURL(key, kind), let framed = try? Data(contentsOf: url) else { return nil }
        touch(url)
        return Self.unframe(framed)?.data
    }

    /// Everything, memory and disk (Settings > Privacy > Clear, or a forgotten phone).
    func removeAll() {
        thumbnailMemory.removeAll()
        previewMemory.removeAll()
        lock.lock(); tints.removeAll(); lock.unlock()
        guard let directory else { return }
        lock.lock()
        if diskIndex != nil { for kind in PhoneCacheKind.allCases { diskIndex?[kind] = [] } }
        pendingIndex.removeAll()
        lock.unlock()
        for kind in PhoneCacheKind.allCases {
            let folder = directory.appendingPathComponent(kind.rawValue, isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Bytes on disk, all kinds.
    func diskBytes() -> Int64 { diskFiles().reduce(0) { $0 + $1.size } }

    /// Deletes the least recently used files until the disk tier fits the budget.
    func prune() {
        var files = diskFiles()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > byteBudget else { return }
        files.sort { $0.used < $1.used }
        let target = byteBudget * 9 / 10
        for file in files where total > target {
            try? FileManager.default.removeItem(at: file.url)
            indexDisk(file.url, added: false)
            total -= file.size
        }
    }

    // MARK: Internals

    private func insert(_ decoded: PhoneDecodedImage, key: String, kind: PhoneCacheKind) {
        memory(kind)?.set(key, decoded)
        rememberTint(key, decoded.tint)
    }

    private func fileURL(_ key: String, _ kind: PhoneCacheKind) -> URL? {
        guard let directory, key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        return directory.appendingPathComponent(kind.rawValue, isDirectory: true).appendingPathComponent(key)
    }

    private func readDecoded(_ url: URL, maxPixel: Int) -> PhoneDecodedImage? {
        guard let framed = try? Data(contentsOf: url, options: .mappedIfSafe), let entry = Self.unframe(framed),
              let image = Self.decode(entry.data, maxPixel: maxPixel) else { return nil }
        return PhoneDecodedImage(image: image, tint: entry.tint)
    }

    private func write(_ data: Data, to url: URL) {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
        } else {
            indexDisk(url, added: true)
        }
        lock.lock()
        writesSincePrune += 1
        let due = writesSincePrune >= 200
        if due { writesSincePrune = 0 }
        lock.unlock()
        if due { prune() }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func diskFiles() -> [(url: URL, size: Int64, used: Date)] {
        guard let directory else { return [] }
        var files: [(URL, Int64, Date)] = []
        for kind in PhoneCacheKind.allCases {
            let folder = directory.appendingPathComponent(kind.rawValue, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for url in contents {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                files.append((url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast))
            }
        }
        return files
    }

    /// "BTH1", a flag byte, three tint bytes, then the image bytes.
    static func frame(_ data: Data, tint: UInt32?) -> Data {
        var header = Data("BTH1".utf8)
        header.append(tint == nil ? 0 : 1)
        let value = tint ?? 0
        header.append(contentsOf: [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        return header + data
    }

    static func unframe(_ framed: Data) -> (data: Data, tint: UInt32?)? {
        guard framed.count >= 8, framed.prefix(4) == Data("BTH1".utf8) else { return nil }
        let bytes = [UInt8](framed[framed.startIndex + 4 ..< framed.startIndex + 8])
        let tint: UInt32? = bytes[0] == 1 ? (UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) : nil
        return (framed.subdata(in: framed.startIndex + 8 ..< framed.endIndex), tint)
    }

    /// Decodes WebP, JPEG, HEIC or PNG, downsampled so the longest edge is at most `maxPixel`.
    static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
