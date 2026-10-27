import Foundation

// Payloads of the draft browse messages (protocol.md "Draft: phone files, media and folders both ways"):
// places.list for browsing, places.files, media.*, places.download. The Mac only asks; the phone serves.
// Android: browse/ in the app, same fields. Optional fields are left out when nil; unknown fields are ignored.

/// The phone serves browse requests (`places.files`, `media.*`, `places.download`) and accepts uploads.
let filesBrowseFeatureKey = "files_browse_draft1"
/// The device accepts folders.offer from its peer. The first slice's Mac advertised folders_draft1 while it
/// only sent folders, so phones look for this key before sending a folder to a Mac.
let foldersReceiveFeatureKey = "folders_receive_draft1"

enum BrowseKind {
    static let placesFiles = "places.files"
    static let placesFilesPage = "places.files_page"
    static let mediaList = "media.list"
    static let mediaPage = "media.page"
    static let mediaThumbnails = "media.thumbnails"
    static let mediaThumbnailsBatch = "media.thumbnails_batch"
    static let mediaPreview = "media.preview"
    static let mediaPreviewPart = "media.preview_part"
    static let mediaRange = "media.range"
    static let mediaRangePart = "media.range_part"
    static let mediaCancel = "media.cancel"
    static let placesDownload = "places.download"
    static let placesDownloadStarted = "places.download_started"

    /// Answers from the phone this Mac routes to its browse client.
    static let answerKinds: Set<String> = [placesFilesPage, mediaPage, mediaThumbnailsBatch, mediaPreviewPart, mediaRangePart, placesDownloadStarted]
    /// Requests a Mac never serves (a phone, or a confused peer, sending them here is ignored).
    static let requestKinds: Set<String> = [placesFiles, mediaList, mediaThumbnails, mediaPreview, mediaRange, mediaCancel, placesDownload]

    /// Plaintext limits: requests 8 KiB, pages 32 KiB, streamed media parts 44 KiB.
    static let mediaPartPlaintext = 45_056

    static func plaintextLimit(_ kind: String) -> Int {
        switch kind {
        case mediaThumbnailsBatch, mediaPreviewPart, mediaRangePart: return mediaPartPlaintext
        case placesFilesPage, mediaPage: return FolderLimits.largePlaintext
        default: return FolderLimits.smallPlaintext
        }
    }
}

enum BrowseLimits {
    static let maxThumbnailItems = 64
    static let maxThumbnailBytes = 24 * 1024
    static let minThumbnailSize = 64
    static let maxThumbnailSize = 512
    static let minPreviewSize = 512
    static let maxPreviewSize = 2048
    static let maxPreviewBytes = 1024 * 1024
    static let maxRangeLength: Int64 = 4 * 1024 * 1024
    static let maxPartData = 32 * 1024
    static let maxDownloadItems = 100
    static let maxListLimit = 200
    /// Media lane budget on the phone: active requests and requests per 10 seconds.
    static let mediaActive = 4
    static let mediaPerWindow = 60
    static let mediaWindow: TimeInterval = 10
}

/// Extra error code of this draft.
extension FolderCode {
    static let readOnly = "read_only"
}

/// The wire form of a `ref`: an item in a place, or a media library item.
struct WireRef: Codable, Equatable, Hashable {
    var placeId: String?
    var path: String?
    var name: String?
    var mediaId: String?

    init(placeId: String? = nil, path: String? = nil, name: String? = nil, mediaId: String? = nil) {
        self.placeId = placeId
        self.path = path
        self.name = name
        self.mediaId = mediaId
    }

    init(_ ref: PhoneRef) {
        switch ref {
        case let .place(placeId, path, name):
            self.placeId = placeId
            self.path = path
            self.name = name
        case let .media(id):
            mediaId = id
        }
    }

    /// Nil when it is neither form, or a field breaks the rules (existing-path rules, one component name,
    /// a decimal media ID of at most 20 digits).
    var ref: PhoneRef? {
        if let mediaId {
            guard placeId == nil, !mediaId.isEmpty, mediaId.count <= 20, mediaId.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return .media(id: mediaId)
        }
        guard let placeId, FolderJSON.isPlaceID(placeId), let path, FolderPaths.isValidExistingPath(path),
              let name, !name.isEmpty, FolderPaths.isValidExistingPath(name), !name.contains("/") else { return nil }
        return .place(placeId: placeId, path: path, name: name)
    }
}

struct BrowsePlacesListPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    var purpose = "browse"
}

/// places.listed with the browse fields. Older phones leave them out (they never get here: browsing needs
/// files_browse_draft1).
struct BrowsePlacesListedPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let mode: DestinationMode
    let places: [PlaceInfo]
    let fixedLabel: String?
    let writable: Bool?
    let media: String?
    let documents: Bool?

    var info: PhoneBrowseInfo {
        PhoneBrowseInfo(
            places: places.map { PhonePlace(id: $0.placeId, label: $0.label, available: $0.available, freeBytes: $0.freeBytes) },
            writable: writable ?? false,
            media: media.flatMap(PhoneMediaAccess.init(rawValue:)) ?? .none,
            documents: documents ?? false
        )
    }

    var isValid: Bool {
        version == 1 && FolderJSON.isWireID(requestId) && places.count <= FolderLimits.maxPlaces + 1 && places.allSatisfy { FolderJSON.isPlaceID($0.placeId) }
    }
}

struct PlacesFilesPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let placeId: String
    let path: String
    let cursor: String?
    let sort: String
    let descending: Bool
}

struct PlacesFileEntryPayload: Codable, Equatable {
    let name: String
    let dir: Bool
    let size: Int64?
    let modified: Int64?
    let mimeType: String?
    let thumb: Bool?
}

struct PlacesFilesPagePayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let placeId: String
    let path: String
    let entries: [PlacesFileEntryPayload]
    let folderCount: Int?
    let fileCount: Int?
    let nextCursor: String?
    let writable: Bool?

    /// Entries the Mac can address again: one existing component each, at most 200.
    func page() -> PhoneFilesPage? {
        guard version == 1, entries.count <= BrowseLimits.maxListLimit else { return nil }
        let items = entries.compactMap { entry -> PhoneFileEntry? in
            guard !entry.name.isEmpty, !entry.name.contains("/"), FolderPaths.isValidExistingPath(entry.name) else { return nil }
            return PhoneFileEntry(
                ref: .place(placeId: placeId, path: path, name: entry.name),
                name: entry.name,
                isDirectory: entry.dir,
                size: entry.dir ? nil : entry.size.map { max(0, $0) },
                modified: entry.modified.map(BrowseTime.date),
                mimeType: entry.dir ? nil : entry.mimeType,
                hasThumbnail: !entry.dir && entry.thumb == true
            )
        }
        return PhoneFilesPage(entries: items, folderCount: folderCount ?? items.filter(\.isDirectory).count,
                              fileCount: fileCount ?? items.filter { !$0.isDirectory }.count, nextCursor: nextCursor, writable: writable ?? false)
    }
}

struct MediaListPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let kind: String
    let cursor: String?
    let limit: Int
}

struct MediaItemPayload: Codable, Equatable {
    let ref: WireRef
    let name: String
    let size: Int64?
    let modified: Int64?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let durationMs: Int64?
    let thumb: Bool?
    let location: String?
}

struct MediaPagePayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let kind: String
    let items: [MediaItemPayload]
    let nextCursor: String?
    let access: String?
    let indexing: Bool?

    func page() -> PhoneMediaPage? {
        guard version == 1, items.count <= BrowseLimits.maxListLimit else { return nil }
        let entries = items.compactMap { item -> PhoneFileEntry? in
            guard let ref = item.ref.ref, !item.name.isEmpty else { return nil }
            var entry = PhoneFileEntry(
                ref: ref, name: item.name, isDirectory: false, size: item.size.map { max(0, $0) },
                modified: item.modified.map(BrowseTime.date), mimeType: item.mimeType, hasThumbnail: item.thumb == true
            )
            entry.width = item.width
            entry.height = item.height
            entry.durationMs = item.durationMs
            entry.location = item.location.map { String($0.prefix(128)) }
            return entry
        }
        return PhoneMediaPage(items: entries, nextCursor: nextCursor, access: access.flatMap(PhoneMediaAccess.init(rawValue:)) ?? .none,
                              indexing: indexing ?? false)
    }
}

struct ThumbnailItemPayload: Codable, Equatable {
    let key: String
    let ref: WireRef
}

struct MediaThumbnailsPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let items: [ThumbnailItemPayload]
    let size: Int
    let replaces: String?
}

struct ThumbPayload: Codable, Equatable {
    let key: String
    let mimeType: String
    let width: Int
    let height: Int
    let tint: String?
    let data: String
}

struct MediaThumbnailsBatchPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let thumbs: [ThumbPayload]
    let missing: [String]?
    let done: Bool
}

struct MediaPreviewPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let ref: WireRef
    let size: Int
    let replaces: String?
}

struct MediaPreviewPartPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let index: Int
    let count: Int
    let mimeType: String
    let width: Int
    let height: Int
    let tint: String?
    let data: String
}

struct MediaRangePayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let ref: WireRef
    let offset: Int64
    let length: Int64
    let replaces: String?
}

struct MediaRangePartPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let offset: Int64
    let fileSize: Int64
    let modified: Int64?
    let data: String
    let last: Bool
}

struct MediaCancelPayload: Codable, Equatable {
    var version = 1
    let requestId: String
}

struct PlacesDownloadPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let items: [WireRef]
}

struct PlacesDownloadStartedPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let folderTransferId: String
    let rootName: String
    let fileCount: Int
    let folderCount: Int
    let totalSize: Int64
}

enum BrowseTime {
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(millis) / 1_000) }
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
}

enum BrowseColor {
    /// "#rrggbb" to 0xRRGGBB; nil for anything else.
    static func tint(_ value: String?) -> UInt32? {
        guard let value, value.count == 7, value.hasPrefix("#"), let number = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return number
    }
}

/// A request ID probe for answers (every answer carries the request it answers).
struct BrowseRequestProbe: Decodable {
    let requestId: String
}
