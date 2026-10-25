import Foundation

/*
 * The app-private clipboard cache, under the edition's Application Support folder:
 *
 *   ClipboardCache/<offerId>/<index>/<original name>    data received from the phone
 *   ClipboardCache/<offerId>/<index>/.handed-out        an app was given this item
 *   ClipboardCache/outgoing/<offerId>/<index>.<ext>     copies of Mac clipboard images
 *
 * Rules (docs/protocol.md): superseded items that were never handed to an app are deleted at
 * once; nothing is kept longer than 24 hours; the total stays under 2 GB, oldest first; the
 * current offer and running transfers are never evicted. Names, sizes and contents never reach
 * the log or diagnostics.
 */
final class ClipboardCache {
    static let partialSuffix = "bridgey-part"
    private static let handedOutMarker = ".handed-out"
    private static let outgoingFolder = "outgoing"

    let root: URL
    let maximumAge: TimeInterval
    let maximumBytes: Int64
    private let clock: () -> Date
    private let fileManager = FileManager.default

    init(
        root: URL = ClipboardCache.defaultRoot(),
        maximumAge: TimeInterval = ClipboardOfferLimits.cacheMaximumAge,
        maximumBytes: Int64 = ClipboardOfferLimits.cacheMaximumBytes,
        clock: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.clock = clock
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/ClipboardCache", isDirectory: true)
    }

    // MARK: Received items

    func itemDirectory(offerID: String, index: Int) -> URL {
        root.appendingPathComponent(offerID, isDirectory: true).appendingPathComponent(String(index), isDirectory: true)
    }

    /// Creates the item's folder and returns where its completed file goes.
    func prepareItem(offerID: String, index: Int, name: String) throws -> URL {
        let directory = itemDirectory(offerID: offerID, index: index)
        try makeDirectory(root)
        try makeDirectory(directory.deletingLastPathComponent())
        try makeDirectory(directory)
        return directory.appendingPathComponent(clipboardSanitizedName(name) ?? "file")
    }

    func partialURL(for finalURL: URL) -> URL {
        finalURL.appendingPathExtension(Self.partialSuffix)
    }

    /// The completed file of an item, if it was received.
    func cachedFile(offerID: String, index: Int) -> URL? {
        let directory = itemDirectory(offerID: offerID, index: index)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".\(Self.partialSuffix)") }
            .sorted()
            .first
            .map { directory.appendingPathComponent($0) }
    }

    func markHandedOut(offerID: String, index: Int) {
        let marker = itemDirectory(offerID: offerID, index: index).appendingPathComponent(Self.handedOutMarker)
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        fileManager.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    func isHandedOut(offerID: String, index: Int) -> Bool {
        fileManager.fileExists(atPath: itemDirectory(offerID: offerID, index: index).appendingPathComponent(Self.handedOutMarker).path)
    }

    /// A superseded offer: deletes every item no app was given; handed-out items stay until
    /// they age out or the cap evicts them.
    func removeSuperseded(offerID: String) {
        let offerDirectory = root.appendingPathComponent(offerID, isDirectory: true)
        guard let indexes = try? fileManager.contentsOfDirectory(atPath: offerDirectory.path) else { return }
        for name in indexes {
            guard let index = Int(name) else { continue }
            if !isHandedOut(offerID: offerID, index: index) {
                try? fileManager.removeItem(at: itemDirectory(offerID: offerID, index: index))
            }
        }
        if (try? fileManager.contentsOfDirectory(atPath: offerDirectory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: offerDirectory)
        }
    }

    /// Drops whatever an item holds (a failed or cancelled transfer), unless it was handed out.
    func removeItem(offerID: String, index: Int) {
        guard !isHandedOut(offerID: offerID, index: index) else { return }
        try? fileManager.removeItem(at: itemDirectory(offerID: offerID, index: index))
    }

    // MARK: Outgoing copies

    func outgoingDirectory(offerID: String) throws -> URL {
        let parent = root.appendingPathComponent(Self.outgoingFolder, isDirectory: true)
        try makeDirectory(root)
        try makeDirectory(parent)
        let directory = parent.appendingPathComponent(offerID, isDirectory: true)
        try makeDirectory(directory)
        return directory
    }

    func removeOutgoing(offerID: String) {
        try? fileManager.removeItem(at: root.appendingPathComponent(Self.outgoingFolder, isDirectory: true)
            .appendingPathComponent(offerID, isDirectory: true))
    }

    // MARK: Cleanup

    /// Leftover partial files from a run that ended mid-transfer. Called at launch.
    func removePartials() {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == Self.partialSuffix {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Age and size limits. `protecting` holds offer IDs that must stay (the current offers and
    /// any with a running transfer).
    func enforceLimits(protecting: Set<String> = []) {
        let now = clock()
        var entries = cacheEntries()
        for entry in entries where !protecting.contains(entry.offerID) && now.timeIntervalSince(entry.date) > maximumAge {
            try? fileManager.removeItem(at: entry.url)
        }
        entries = cacheEntries()
        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maximumBytes {
            guard !protecting.contains(entry.offerID) else { continue }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.bytes
        }
        removeEmptyOfferFolders()
    }

    func totalBytes() -> Int64 {
        cacheEntries().reduce(0) { $0 + $1.bytes }
    }

    /// Clear activity and Forget device.
    func clear() {
        try? fileManager.removeItem(at: root)
    }

    private struct Entry {
        let url: URL
        let offerID: String
        let bytes: Int64
        let date: Date
    }

    /// One entry per received item folder and per outgoing offer folder.
    private func cacheEntries() -> [Entry] {
        var entries: [Entry] = []
        guard let offers = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        for offer in offers where !offer.hasPrefix(".") {
            let offerURL = root.appendingPathComponent(offer, isDirectory: true)
            if offer == Self.outgoingFolder {
                for outgoing in (try? fileManager.contentsOfDirectory(atPath: offerURL.path)) ?? [] {
                    let url = offerURL.appendingPathComponent(outgoing, isDirectory: true)
                    let (bytes, date) = measure(url)
                    entries.append(Entry(url: url, offerID: outgoing, bytes: bytes, date: date))
                }
            } else {
                for index in (try? fileManager.contentsOfDirectory(atPath: offerURL.path)) ?? [] where Int(index) != nil {
                    let url = offerURL.appendingPathComponent(index, isDirectory: true)
                    let (bytes, date) = measure(url)
                    entries.append(Entry(url: url, offerID: offer, bytes: bytes, date: date))
                }
            }
        }
        return entries
    }

    /// Total bytes and the newest modification date under a folder.
    private func measure(_ url: URL) -> (Int64, Date) {
        var bytes: Int64 = 0
        var newest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                bytes += Int64(values?.fileSize ?? 0)
                if let date = values?.contentModificationDate, date > newest { newest = date }
            }
        }
        return (bytes, newest)
    }

    private func removeEmptyOfferFolders() {
        for offer in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where offer != Self.outgoingFolder {
            let url = root.appendingPathComponent(offer, isDirectory: true)
            if (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func makeDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
