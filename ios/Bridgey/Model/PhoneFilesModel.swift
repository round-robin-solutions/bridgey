import Foundation
import UIKit

/// The phone's files (`files_browse_draft1`, area 3): its places and folders, its photos and recent documents, downloads
/// to this device's received files and uploads into the folder being browsed. bridgey_core asks the phone within its
/// budgets and moves the files (rust/client/src/phone_files.rs); this model keeps what each screen shows, as the
/// Windows app does (PhoneFilesViewModel.cs). Thumbnails stay in memory.
@MainActor
final class PhoneFilesModel: ObservableObject, SessionFeature {
    private(set) weak var app: AppModel?
    private var client: CoreClient?

    @Published private(set) var phoneID: String?
    /// Browsing works: Files at both ends and the phone allows it.
    @Published private(set) var available = false
    /// What each open screen shows, by its location.
    @Published private(set) var listings: [Location: Listing] = [:]
    /// Thumbnails by item key.
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var transfers: [Transfer] = []
    @Published var notice: String?
    @Published var sort: Sort = .name

    /// Requests waiting for their answer: request ID to the location it fills.
    private var requests: [String: Location] = [:]
    private var thumbnailKeys: Set<String> = []
    private var nextKey = 0

    enum Sort: String, CaseIterable, Identifiable {
        case name, modified, size, kind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .modified: String(localized: "Date modified")
            case .size: String(localized: "Size")
            case .kind: String(localized: "Kind")
            }
        }
    }

    /// Something that can be listed: the phone's places, a folder, or one of its media lists.
    enum Location: Hashable {
        case places
        case folder(placeID: String, path: String, title: String)
        case photos
        case documents
        case recent

        var title: String {
            switch self {
            case .places: String(localized: "Files")
            case let .folder(_, path, title): path.isEmpty ? title : String(path.split(separator: "/").last ?? "")
            case .photos: String(localized: "Photos and videos")
            case .documents: String(localized: "Documents")
            case .recent: String(localized: "Recent")
            }
        }

        var mediaKind: String? {
            switch self {
            case .photos: "media"
            case .documents: "files"
            case .recent: "recent"
            default: nil
            }
        }
    }

    struct Listing: Equatable {
        var items: [Item] = []
        var loading = true
        var nextCursor: String?
        /// A next page is on its way: it adds to the list.
        var loadingMore = false
        var writable = false
        var error: String?
        /// The places screen: which media lists the phone offers.
        var media = false
        var documents = false
    }

    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case place, folder, file }

        /// Stable within a listing; also the thumbnail key.
        let id: String
        var kind: Kind
        var name: String
        var size: Int64?
        var modified: Int64?
        var mimeType: String?
        var hasThumbnail = false
        /// What the phone resolves for a download or a thumbnail.
        var ref: [String: String]?
        /// A place: its ID, and whether it can be opened now.
        var placeID: String?
        var placeAvailable = true
        var freeBytes: Int64?
        var width: Int64?
        var height: Int64?
        var durationMs: Int64?

        var isImageOrVideo: Bool {
            guard let m = mimeType else { return false }
            return m.hasPrefix("image/") || m.hasPrefix("video/")
        }
    }

    /// A download or an upload with its progress.
    struct Transfer: Identifiable, Equatable {
        let id: String
        var download: Bool
        var title: String
        var detail = ""
        var progress: Double = 0
        var running = true
        var failed = false
        /// Where a download landed.
        var folder: String?
    }

    // MARK: Session

    func attach(_ app: AppModel) { self.app = app }

    func clientChanged(_ client: CoreClient?) {
        self.client = client
        if client == nil {
            listings = [:]
            requests = [:]
            thumbnails = [:]
            thumbnailKeys = []
            available = false
            for i in transfers.indices where transfers[i].running {
                transfers[i].running = false
                transfers[i].failed = true
                transfers[i].detail = problem("interrupted")
            }
        }
    }

    func handle(_ e: CoreEvent) {
        switch e.kind {
        case .features, .connected, .disconnected:
            if e.deviceID == phoneID { loadStatus() }
        case .phoneFiles where e.deviceID == phoneID:
            apply(e.name ?? "", e.json)
        default:
            break
        }
    }

    private func apply(_ what: String, _ d: [String: Any]) {
        switch what {
        case "status":
            let was = available
            loadStatus()
            if !was, available {
                if listings.isEmpty { load(.places) } else { for location in listings.keys { load(location) } }
            }
        case "places":
            guard let id = d["requestId"] as? String, let location = requests.removeValue(forKey: id) else { break }
            var listing = Listing(loading: false)
            if let error = d["error"] as? String {
                listing.error = problem(error)
            } else {
                listing.items = (d["places"] as? [[String: Any]] ?? []).compactMap(Self.place)
                listing.writable = d["writable"] as? Bool ?? false
                listing.media = (d["media"] as? String ?? "none") != "none"
                listing.documents = d["documents"] as? Bool ?? false
            }
            listings[location] = listing
        case "list", "media":
            guard let id = d["requestId"] as? String, let location = requests.removeValue(forKey: id) else { break }
            var listing = listings[location] ?? Listing()
            listing.loading = false
            if let error = d["error"] as? String {
                listing.error = problem(error)
                listings[location] = listing
                break
            }
            let more: [Item] = what == "list"
                ? (d["entries"] as? [[String: Any]] ?? []).compactMap { self.entry($0, in: location) }
                : (d["items"] as? [[String: Any]] ?? []).compactMap { self.mediaItem($0) }
            // A page after the first adds to the list; the first replaces it.
            listing.items = listing.loadingMore ? listing.items + more : more
            listing.loadingMore = false
            listing.nextCursor = d["nextCursor"] as? String
            if what == "list" { listing.writable = d["writable"] as? Bool ?? false }
            listings[location] = listing
            requestThumbnails(more)
        case "thumbnails":
            for t in d["thumbs"] as? [[String: Any]] ?? [] {
                guard let key = t["key"] as? String, thumbnailKeys.contains(key),
                      let data = (t["data"] as? String).flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) else { continue }
                thumbnails[key] = image
            }
        case "download":
            transfer(d, download: true)
        case "upload":
            transfer(d, download: false)
            // New files show up in the folder they went to.
            if let state = d["state"] as? String, state == "done" || state == "incomplete",
               let dest = d["destination"] as? [String: Any], let place = dest["placeId"] as? String, let path = dest["path"] as? String {
                for location in listings.keys {
                    if case let .folder(p, f, _) = location, p == place, f == path { load(location) }
                }
            }
        default:
            break
        }
    }

    // MARK: Showing

    func show(_ deviceID: String) {
        if phoneID != deviceID {
            phoneID = deviceID
            listings = [:]
            requests = [:]
            thumbnails = [:]
            thumbnailKeys = []
            notice = nil
        }
        loadStatus()
        if available, listings[.places] == nil { load(.places) }
    }

    private func loadStatus() {
        available = command(["op": "status"])["available"] as? Bool ?? false
    }

    /// One short line about why nothing can show, or nil.
    var statusText: String? {
        guard let id = phoneID else { return nil }
        let name = app?.deviceName(id) ?? String(localized: "the phone")
        guard app?.device(id)?.connected == true else { return String(localized: "\(name) isn’t connected.") }
        guard available else { return String(localized: "Turn on Let other devices browse this phone in Bridgey on \(name).") }
        return nil
    }

    /// A screen appeared: its listing from the phone (again).
    func load(_ location: Location) {
        guard phoneID != nil else { return }
        var listing = listings[location] ?? Listing()
        listing.loading = true
        listing.error = nil
        listing.nextCursor = nil
        listing.loadingMore = false
        listings[location] = listing
        ask(location, cursor: nil)
    }

    func loadMore(_ location: Location) {
        guard var listing = listings[location], let cursor = listing.nextCursor, !listing.loadingMore else { return }
        listing.loadingMore = true
        listings[location] = listing
        ask(location, cursor: cursor)
    }

    private func ask(_ location: Location, cursor: String?) {
        var cmd: [String: Any]
        switch location {
        case .places:
            cmd = ["op": "places"]
        case let .folder(place, path, _):
            cmd = ["op": "list", "placeId": place, "path": path, "sort": sort.rawValue, "descending": sort == .modified || sort == .size]
        case .photos, .documents, .recent:
            cmd = ["op": "media", "kind": location.mediaKind ?? "media", "limit": 100]
        }
        if let cursor { cmd["cursor"] = cursor }
        let answer = command(cmd)
        if let id = answer["requestId"] as? String, Self.ok(answer) {
            requests[id] = location
        } else {
            var listing = listings[location] ?? Listing()
            listing.loading = false
            listing.loadingMore = false
            listing.error = problem(answer["error"] as? String ?? "")
            listings[location] = listing
        }
    }

    /// Sort changed: the folders on screen again.
    func resort() {
        for location in listings.keys { if case .folder = location { load(location) } }
    }

    private func requestThumbnails(_ items: [Item]) {
        let wanted = items.filter { $0.hasThumbnail && $0.ref != nil && thumbnails[$0.id] == nil }
        for batch in stride(from: 0, to: wanted.count, by: 64).map({ Array(wanted[$0..<min($0 + 64, wanted.count)]) }) {
            let list: [[String: Any]] = batch.map { ["key": $0.id, "ref": $0.ref!] }
            batch.forEach { thumbnailKeys.insert($0.id) }
            _ = command(["op": "thumbnails", "items": list, "size": 192])
        }
    }

    // MARK: Moving files

    /// Downloads files or folders to this device's received files (the Files app shows them).
    func download(_ items: [Item]) {
        let refs = items.compactMap(\.ref)
        guard !refs.isEmpty else { return }
        let answer = command(["op": "download", "items": refs])
        guard Self.ok(answer), let id = answer["requestId"] as? String else {
            notice = answer["error"] as? String == "not_connected" ? problem("not_connected") : String(localized: "That can’t be downloaded.")
            return
        }
        let title = items.count == 1 ? items[0].name : String(localized: "\(items.count) items")
        transfers.insert(Transfer(id: id, download: true, title: title, detail: String(localized: "Preparing on the phone")), at: 0)
    }

    /// Adds files picked in the Files app to a folder on the phone. They are copied first, as for sending.
    func upload(_ urls: [URL], to location: Location) {
        guard case let .folder(place, path, _) = location, !urls.isEmpty else { return }
        var files: [[String: Any]] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let copy = try? AppModel.copyForSending(url) else {
                notice = String(localized: "The file couldn’t be read.")
                return
            }
            files.append(["path": copy.path, "name": url.lastPathComponent])
        }
        let answer = command(["op": "upload", "placeId": place, "path": path, "files": files])
        guard Self.ok(answer), let id = answer["uploadId"] as? String else {
            notice = answer["error"] as? String == "not_connected" ? problem("not_connected") : String(localized: "Those files can’t be added.")
            return
        }
        uploadCopies[id] = files.compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent() } }
        let title = urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) files")
        transfers.insert(Transfer(id: id, download: false, title: title, detail: String(localized: "Getting ready")), at: 0)
    }

    private var uploadCopies: [String: [URL]] = [:]

    func cancel(_ t: Transfer) {
        _ = command(t.download ? ["op": "cancel_download", "requestId": t.id] : ["op": "cancel_upload", "uploadId": t.id])
    }

    func clear(_ t: Transfer) {
        transfers.removeAll { $0.id == t.id }
    }

    private func transfer(_ d: [String: Any], download: Bool) {
        guard let id = d[download ? "requestId" : "uploadId"] as? String else { return }
        guard let i = transfers.firstIndex(where: { $0.id == id }) else {
            // A folder the phone sent on its own lands in the received files too.
            guard download, d["pushed"] as? Bool == true else { return }
            transfers.insert(Transfer(id: id, download: true, title: d["rootName"] as? String ?? ""), at: 0)
            return transfer(d, download: download)
        }
        var t = transfers[i]
        let state = d["state"] as? String ?? ""
        let files = Self.int(d["files"]) ?? 0, done = Self.int(d["filesDone"]) ?? 0
        let bytes = Self.int(d["bytes"]) ?? 0, total = Self.int(d["total"]) ?? 0
        if total > 0 { t.progress = min(1, max(0, Double(bytes) / Double(total))) }
        if let folder = d["folder"] as? String { t.folder = folder }
        if let root = d["rootName"] as? String, !root.isEmpty, t.title.isEmpty { t.title = root }
        let size = { (n: Int64) in ByteCountFormatter.file(UInt64(max(0, n))) }
        switch state {
        case "hashing":
            t.detail = String(localized: "Getting ready")
        case "started", "offered":
            t.detail = String(localized: "Preparing on the phone")
        case "waiting":
            t.detail = String(localized: "Waiting for \(phoneName)")
        case "receiving", "sending":
            t.detail = files > 1 ? String(localized: "\(done) of \(files) files, \(size(bytes)) of \(size(total))")
                : total > 0 ? String(localized: "\(size(bytes)) of \(size(total))") : ""
        case "finishing":
            t.detail = String(localized: "Finishing")
        case "done":
            t.running = false
            t.progress = 1
            t.detail = download && (Self.int(d["renamed"]) ?? 0) > 0
                ? String(localized: "Done. Items with names already here were numbered.") : String(localized: "Done")
        case "incomplete":
            t.running = false
            t.failed = done == 0
            let failed = Self.int(d["failed"]) ?? 0
            t.detail = failed == 1 ? String(localized: "Done, but 1 item didn’t make it")
                : failed > 1 ? String(localized: "Done, but \(failed) items didn’t make it") : String(localized: "Stopped part way")
        case "cancelled":
            t.running = false
            t.detail = String(localized: "Cancelled")
        default:
            t.running = false
            t.failed = true
            t.detail = problem(d["error"] as? String ?? "")
        }
        transfers[i] = t
        if !t.running, !download, let copies = uploadCopies.removeValue(forKey: id) {
            for folder in copies { try? FileManager.default.removeItem(at: folder) }
        }
    }

    // MARK: Helpers

    private var phoneName: String { phoneID.flatMap { app?.deviceName($0) } ?? String(localized: "the phone") }

    /// What a code from the library or the phone means.
    func problem(_ code: String) -> String {
        let phone = phoneName
        switch code {
        case "not_connected": return String(localized: "\(phone) isn’t connected.")
        case "timeout": return String(localized: "\(phone) didn’t answer. Try again.")
        case "cancelled": return String(localized: "Cancelled")
        case "interrupted": return String(localized: "It stopped: \(phone) disconnected.")
        case "read_only": return String(localized: "Turn on Allow other devices to change files here on \(phone) to add files.")
        case "not_found": return String(localized: "This item is no longer on the phone.")
        case "place_unavailable": return String(localized: "Bridgey on \(phone) lost access to this folder. Grant it again on the phone.")
        case "busy": return String(localized: "\(phone) is busy. Try again in a moment.")
        case "insufficient_space": return String(localized: "There isn’t enough free space.")
        case "policy", "feature_off": return String(localized: "Turn on Let other devices browse this phone in Bridgey on \(phone).")
        case "no_folder": return String(localized: "Files is off in Settings, so there’s nowhere to save.")
        default: return String(localized: "Something went wrong on \(phone).")
        }
    }

    private func command(_ cmd: [String: Any]) -> [String: Any] {
        guard let client, let id = phoneID else { return ["ok": false, "error": "not_connected"] }
        return client.phone(.phoneFiles, deviceID: id, command: cmd)
    }

    private func key() -> String {
        nextKey += 1
        return "t\(nextKey)"
    }

    nonisolated static func ok(_ answer: [String: Any]) -> Bool { answer["ok"] as? Bool == true }

    nonisolated static func int(_ value: Any?) -> Int64? { MessagesModel.int(value) }

    nonisolated static func place(_ p: [String: Any]) -> Item? {
        guard let id = p["placeId"] as? String else { return nil }
        let label = (p["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Phone storage")
        return Item(id: "place:\(id)", kind: .place, name: label, placeID: id, placeAvailable: p["available"] as? Bool ?? false,
                    freeBytes: int(p["freeBytes"]))
    }

    private func entry(_ e: [String: Any], in location: Location) -> Item? {
        guard case let .folder(place, path, _) = location, let name = e["name"] as? String else { return nil }
        let dir = e["dir"] as? Bool ?? false
        return Item(id: key(), kind: dir ? .folder : .file, name: name, size: Self.int(e["size"]), modified: Self.int(e["modified"]),
                    mimeType: e["mimeType"] as? String, hasThumbnail: e["thumb"] as? Bool ?? false,
                    ref: ["placeId": place, "path": path, "name": name], placeID: place)
    }

    private func mediaItem(_ m: [String: Any]) -> Item? {
        guard let name = m["name"] as? String, let raw = m["ref"] as? [String: Any] else { return nil }
        let ref = raw.compactMapValues { $0 as? String }
        return Item(id: key(), kind: .file, name: name, size: Self.int(m["size"]), modified: Self.int(m["modified"]),
                    mimeType: m["mimeType"] as? String, hasThumbnail: m["thumb"] as? Bool ?? false, ref: ref,
                    width: Self.int(m["width"]), height: Self.int(m["height"]), durationMs: Self.int(m["durationMs"]))
    }
}

