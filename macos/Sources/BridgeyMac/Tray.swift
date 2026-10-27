import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

// The Tray (Files 2.0): a Yoink-style shelf that collects files, folders, images, text and links from drops,
// then sends them together. Files and folders are kept as bookmarks (never copied); only in-memory data (an
// image dragged from a browser) is copied into the Tray's own owner-only folder. Persists across restarts.

/// What a drop carried, in the order it was dropped.
enum DropPayload: Equatable {
    case files([URL])
    /// Image bytes with no file behind them, with a file extension for the copy.
    case image(Data, ext: String)
    case text(String)
    case link(URL)

    static let maximumTextBytes = 32 * 1024

    /// Reads a drag pasteboard: file URLs first; else a web link, an image, or text.
    static func from(pasteboard: NSPasteboard) -> [DropPayload] {
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty { return [.files(fileURLs)] }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let link = urls.first(where: { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }) {
            return [.link(link)]
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
                            (NSPasteboard.PasteboardType("public.heic"), "heic")] {
            if let data = pasteboard.data(forType: type) { return [.image(data, ext: ext)] }
        }
        if let tiff = pasteboard.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.image(png, ext: "png")]
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !text.contains(" ") {
                return [.link(url)]
            }
            return [.text(text)]
        }
        return []
    }

    /// Reads SwiftUI drop providers (drop tiles, the Tray window) the same way.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([DropPayload]) -> Void) {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            loadFileURLs(fileProviders) { urls in completion(urls.isEmpty ? [] : [.files(urls)]) }
            return
        }
        guard let provider = providers.first else {
            Task { @MainActor in completion([]) }
            return
        }
        let deliver: (DropPayload?) -> Void = { payload in Task { @MainActor in completion(payload.map { [$0] } ?? []) } }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                deliver(url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? .link($0) : nil })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return deliver(nil) }
                let ext = provider.registeredTypeIdentifiers.compactMap { UTType($0)?.preferredFilenameExtension }.first ?? "png"
                deliver(.image(data, ext: ext))
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                deliver(value.isEmpty ? nil : .text(value))
            }
        } else {
            deliver(nil)
        }
    }

    var itemCount: Int {
        if case let .files(urls) = self { return urls.count }
        return 1
    }
}

struct TrayItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, folder, data, text, link }

    let id: String
    let kind: Kind
    let name: String
    let size: Int64
    let addedAt: Date
    /// Files and folders: a bookmark, so a moved or renamed item is still found.
    var bookmark: Data?
    /// Files and folders: the last known path (for display and as a fallback).
    var path: String?
    /// Data: the copy's file name inside the Tray's own folder.
    var storedName: String?
    /// Text and links.
    var text: String?
}

@MainActor
final class TrayStore: ObservableObject {
    static let shared = TrayStore(directory: TrayStore.defaultDirectory())
    static let maximumItems = 200

    @Published private(set) var items: [TrayItem] = []

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("tray.json") }
    private var dataDirectory: URL { directory.appendingPathComponent("Items", isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
        items = load()
        purgeOrphans()
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { items.isEmpty }

    /// Adds what a drop carried; returns the new items.
    @discardableResult
    func add(_ payloads: [DropPayload], now: Date = Date()) -> [TrayItem] {
        // Whole milliseconds, as stored, so an item reads back equal.
        let now = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded() / 1000)
        var added: [TrayItem] = []
        for payload in payloads {
            switch payload {
            case let .files(urls):
                for url in urls where !items.contains(where: { $0.path == url.path }) && !added.contains(where: { $0.path == url.path }) {
                    if let item = Self.fileItem(url, now: now) { added.append(item) }
                }
            case let .image(data, ext):
                let id = UUID().uuidString.lowercased()
                let name = "Image \(Self.stamp(now)).\(ext)"
                let folder = dataDirectory.appendingPathComponent(id, isDirectory: true)
                guard Self.writeOwnerOnly(data, to: folder.appendingPathComponent(name)) else { continue }
                added.append(TrayItem(id: id, kind: .data, name: name, size: Int64(data.count), addedAt: now, storedName: name))
            case let .text(text):
                let value = String(text.prefix(DropPayload.maximumTextBytes))
                added.append(TrayItem(id: UUID().uuidString.lowercased(), kind: .text, name: ActivityHistory.preview(value) ?? value,
                                      size: Int64(value.utf8.count), addedAt: now, text: value))
            case let .link(url):
                added.append(TrayItem(id: UUID().uuidString.lowercased(), kind: .link, name: url.host ?? url.absoluteString,
                                      size: 0, addedAt: now, text: url.absoluteString))
            }
        }
        guard !added.isEmpty else { return [] }
        items = Array((items + added).suffix(Self.maximumItems))
        save()
        return added
    }

    func remove(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
        deleteData(of: [item])
    }

    /// Empties the Tray; the removed items can come back with `restore` until `purge` runs.
    @discardableResult
    func clear() -> [TrayItem] {
        let removed = items
        items = []
        save()
        return removed
    }

    func restore(_ removed: [TrayItem]) {
        let known = Set(items.map(\.id))
        items = Array((removed.filter { !known.contains($0.id) } + items).suffix(Self.maximumItems))
        save()
    }

    /// Deletes the copies of items that are no longer in the Tray (after the Undo window).
    func purge() { purgeOrphans() }

    /// Where an item is on disk now: bookmarks are resolved (and refreshed when stale).
    func url(for item: TrayItem) -> URL? {
        switch item.kind {
        case .file, .folder:
            if let bookmark = item.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    if stale || url.path != item.path, let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index].path = url.path
                        items[index].bookmark = (try? url.bookmarkData()) ?? bookmark
                        save()
                    }
                    return url
                }
            }
            return item.path.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        case .data:
            return item.storedName.map { dataDirectory.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent($0) }
        case .text, .link:
            return nil
        }
    }

    /// What a send of `selection` (nil: everything) carries: files and folders, and texts and links. For a
    /// send, image copies move to the dropped-data folder first, so clearing the Tray never pulls a file
    /// out from under a queued transfer.
    func sendables(_ selection: [TrayItem]? = nil, forSending: Bool = false) -> (urls: [URL], texts: [String]) {
        var urls: [URL] = []
        var texts: [String] = []
        for item in selection ?? items {
            switch item.kind {
            case .data:
                guard let url = url(for: item) else { continue }
                if forSending, let data = try? Data(contentsOf: url), let copy = DroppedData.write(data, ext: url.pathExtension, name: item.name) {
                    urls.append(copy)
                } else {
                    urls.append(url)
                }
            case .file, .folder: if let url = url(for: item) { urls.append(url) }
            case .text, .link: if let text = item.text { texts.append(text) }
            }
        }
        return (urls, texts)
    }

    // MARK: Storage

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/Tray", isDirectory: true)
    }

    nonisolated static func fileItem(_ url: URL, now: Date) -> TrayItem? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .nameKey])
        guard let values else { return nil }
        let directory = values.isDirectory ?? false
        let size = directory ? Self.folderSize(url) : Int64(values.fileSize ?? 0)
        return TrayItem(id: UUID().uuidString.lowercased(), kind: directory ? .folder : .file, name: values.name ?? url.lastPathComponent,
                        size: size, addedAt: now, bookmark: try? url.bookmarkData(), path: url.path)
    }

    /// Bounded: a huge folder stops counting after 20,000 entries (the total is then a lower bound).
    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let file as URL in enumerator {
            count += 1
            if count > 20_000 { break }
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    nonisolated private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    private func load() -> [TrayItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([TrayItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(items) else { return }
        _ = Self.writeOwnerOnly(data, to: fileURL)
    }

    private func deleteData(of removed: [TrayItem]) {
        for item in removed where item.kind == .data {
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(item.id, isDirectory: true))
        }
    }

    private func purgeOrphans() {
        let keep = Set(items.filter { $0.kind == .data }.map(\.id))
        let folders = (try? FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Atomic and owner-only: 0700 folders, a 0600 file renamed into place.
    @discardableResult
    nonisolated static func writeOwnerOnly(_ data: Data, to target: URL) -> Bool {
        let manager = FileManager.default
        var folder = target.deletingLastPathComponent()
        var created: [URL] = []
        while !manager.fileExists(atPath: folder.path) {
            created.append(folder)
            folder = folder.deletingLastPathComponent()
        }
        for directory in created.reversed() {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(temporary.path, target.path) != 0 {
            try? manager.removeItem(at: temporary)
            return false
        }
        return true
    }
}
