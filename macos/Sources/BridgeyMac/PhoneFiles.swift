import CryptoKit
import Foundation

// Files 2.0, second slice (draft, protocol.md "Draft: phone files, media and folders both ways"): what the
// Phone files window, the send sheet and the Tray need from the transfer engine. The engine
// (PhoneFilesController, owned by PairingCoordinator) implements `PhoneFilesService`; the UI only talks to the
// protocol, and tests and screenshots use fakes. Every callback arrives on the main thread.

/// One item on the phone (protocol `ref`): an item in a place, or a photo or video from the media library.
enum PhoneRef: Hashable, Codable {
    case place(placeId: String, path: String, name: String)
    case media(id: String)

    /// Stable text for cache keys and table identity (never shown, never logged).
    var identity: String {
        switch self {
        case let .place(placeId, path, name): return "p\u{1F}\(placeId)\u{1F}\(path)\u{1F}\(name)"
        case let .media(id): return "m\u{1F}\(id)"
        }
    }
}

enum PhoneMediaAccess: String, Codable, Equatable {
    case full, partial, none
}

struct PhonePlace: Identifiable, Equatable, Hashable {
    let id: String
    let label: String
    let available: Bool
    let freeBytes: Int64?
}

/// `places.listed` for browsing.
struct PhoneBrowseInfo: Equatable {
    var places: [PhonePlace]
    /// "Allow other devices to change files here" on the phone: uploads are allowed.
    var writable: Bool
    var media: PhoneMediaAccess
    /// At least one place is indexed for recent documents.
    var documents: Bool
}

/// A file or folder as the phone listed it (`places.files_page` entry or `media.page` item).
struct PhoneFileEntry: Identifiable, Equatable, Hashable {
    let ref: PhoneRef
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?
    let mimeType: String?
    let hasThumbnail: Bool
    var width: Int? = nil
    var height: Int? = nil
    var durationMs: Int64? = nil
    /// Display path ("Camera", "Documents/Invoices"), from media.page.
    var location: String? = nil

    var id: String { ref.identity }

    var isImage: Bool { mimeType?.hasPrefix("image/") == true }
    var isVideo: Bool { mimeType?.hasPrefix("video/") == true }

    /// Content-addressed cache key (protocol: device ID, ref, modified and size always mean the same bytes).
    /// A SHA-256 hex digest, so no name ever reaches the disk cache's file names.
    func cacheKey(phoneID: String) -> String {
        let modifiedMillis = modified.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? -1
        return PhoneFilesDigest.hex("\(phoneID)\u{1F}\(ref.identity)\u{1F}\(modifiedMillis)\u{1F}\(size ?? -1)")
    }
}

enum PhoneFileSort: String, CaseIterable, Codable {
    case name, modified, size, kind
}

struct PhoneFilesPage: Equatable {
    var entries: [PhoneFileEntry]
    var folderCount: Int
    var fileCount: Int
    var nextCursor: String?
    var writable: Bool
}

enum PhoneMediaKind: String, CaseIterable, Codable {
    /// Photos and videos, newest first.
    case media
    /// Recent documents from indexed places.
    case files
    /// Both, newest first.
    case recent
}

struct PhoneMediaPage: Equatable {
    var items: [PhoneFileEntry]
    var nextCursor: String?
    var access: PhoneMediaAccess
    /// The phone is refreshing its document index; list again later for more.
    var indexing: Bool
}

/// A decoded-ready thumbnail or preview image as the phone sent it (WebP or JPEG bytes).
struct PhoneImage: Equatable {
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
    /// Average colour, 0xRRGGBB, for placeholders.
    let tint: UInt32?
}

enum PhoneFilesError: Error, Equatable {
    /// The phone is not connected.
    case notConnected
    /// The phone did not advertise files_browse_draft1 (older Bridgey, or browsing is off on the phone).
    case notBrowsable
    /// No answer within 8 seconds.
    case timeout
    /// places.error or folders.rejected with its code (`read_only`, `not_found`, `busy`, ...).
    case code(String)
    /// Cancelled by the caller.
    case cancelled
}

/// A running request or transfer that the caller can stop.
final class PhoneFilesCancellable {
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    static let none = PhoneFilesCancellable {}

    func cancel() {
        let action = onCancel
        onCancel = nil
        action?()
    }
}

/// Progress of a download or upload (a folder transfer underneath).
struct PhoneTransferProgress: Equatable {
    enum Phase: String { case preparing, waiting, transferring, finishing }
    var phase: Phase = .preparing
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Int64 = 0

    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

/// Where a download lands and how it shows.
enum PhoneDownloadPurpose: Equatable {
    /// Download button: the Received files folder, a transfer row, history, Finder metadata.
    case save
    /// Dragged to Finder (a file promise): the folder Finder named; a row and history too.
    case dragOut
    /// Opened for Quick Look or preview: a private cache folder, no row, no history.
    case preview
}

/// The route to a phone; hover prefetch runs on LAN only (relay and metered routes later).
enum PhoneRoute: Equatable {
    case lan, relay, unknown
}

struct BrowsablePhone: Identifiable, Equatable {
    let id: String
    let name: String
    /// Advertised files_browse_draft1 (else the window explains how to turn browsing on).
    let browsable: Bool
    let route: PhoneRoute
}

@MainActor
protocol PhoneFilesService: AnyObject {
    /// Connected phones, browsable or not.
    var phones: [BrowsablePhone] { get }
    /// Called whenever `phones` changes (connects, disconnects, features.update).
    var onPhonesChanged: (() -> Void)? { get set }

    func places(phoneID: String, completion: @escaping (Result<PhoneBrowseInfo, PhoneFilesError>) -> Void)

    func listFiles(phoneID: String, placeId: String, path: String, sort: PhoneFileSort, descending: Bool, cursor: String?,
                   completion: @escaping (Result<PhoneFilesPage, PhoneFilesError>) -> Void)

    func listMedia(phoneID: String, kind: PhoneMediaKind, cursor: String?, limit: Int,
                   completion: @escaping (Result<PhoneMediaPage, PhoneFilesError>) -> Void)

    /// Thumbnails in the order given (visible first), batched on the media lane. A new call with the same
    /// `lane` replaces the previous one (what was not sent yet is cancelled on the phone). `deliver` runs once
    /// per thumbnail as it arrives; `finished` once with the entries that have no thumbnail.
    @discardableResult
    func thumbnails(phoneID: String, entries: [PhoneFileEntry], size: Int, lane: String,
                    deliver: @escaping (PhoneFileEntry, PhoneImage) -> Void,
                    finished: @escaping (Result<[PhoneFileEntry], PhoneFilesError>) -> Void) -> PhoneFilesCancellable

    /// A preview-size image (videos: the poster frame), on the media lane.
    @discardableResult
    func preview(phoneID: String, entry: PhoneFileEntry, size: Int,
                 completion: @escaping (Result<PhoneImage, PhoneFilesError>) -> Void) -> PhoneFilesCancellable

    /// Raw bytes of a file, unverified, for previews only (a video's first seconds, streamed playback).
    /// `progress` reports bytes received so far, so a caller can decide whether to keep a half-done prefetch.
    @discardableResult
    func range(phoneID: String, entry: PhoneFileEntry, offset: Int64, length: Int64,
               progress: @escaping (Int64) -> Void,
               completion: @escaping (Result<Data, PhoneFilesError>) -> Void) -> PhoneFilesCancellable

    /// Downloads into `directory` (verified folder transfer; clashing names become copies). `completion` gets
    /// the top-level items as saved.
    @discardableResult
    func download(phoneID: String, refs: [PhoneRef], into directory: URL, purpose: PhoneDownloadPurpose,
                  progress: @escaping (PhoneTransferProgress) -> Void,
                  completion: @escaping (Result<[URL], PhoneFilesError>) -> Void) -> PhoneFilesCancellable

    /// Uploads local files and folders into a folder of a place (`into` offer). Fails with `read_only` when
    /// the phone does not allow changes. Shows as a transfer row like any send.
    @discardableResult
    func upload(phoneID: String, urls: [URL], placeId: String, path: String,
                progress: @escaping (PhoneTransferProgress) -> Void,
                completion: @escaping (Result<Void, PhoneFilesError>) -> Void) -> PhoneFilesCancellable
}

/// Until the engine is wired: nothing is browsable.
final class UnavailablePhoneFiles: PhoneFilesService {
    var phones: [BrowsablePhone] { [] }
    var onPhonesChanged: (() -> Void)?

    func places(phoneID: String, completion: @escaping (Result<PhoneBrowseInfo, PhoneFilesError>) -> Void) {
        completion(.failure(.notBrowsable))
    }

    func listFiles(phoneID: String, placeId: String, path: String, sort: PhoneFileSort, descending: Bool, cursor: String?,
                   completion: @escaping (Result<PhoneFilesPage, PhoneFilesError>) -> Void) {
        completion(.failure(.notBrowsable))
    }

    func listMedia(phoneID: String, kind: PhoneMediaKind, cursor: String?, limit: Int,
                   completion: @escaping (Result<PhoneMediaPage, PhoneFilesError>) -> Void) {
        completion(.failure(.notBrowsable))
    }

    func thumbnails(phoneID: String, entries: [PhoneFileEntry], size: Int, lane: String,
                    deliver: @escaping (PhoneFileEntry, PhoneImage) -> Void,
                    finished: @escaping (Result<[PhoneFileEntry], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        finished(.failure(.notBrowsable))
        return .none
    }

    func preview(phoneID: String, entry: PhoneFileEntry, size: Int,
                 completion: @escaping (Result<PhoneImage, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        completion(.failure(.notBrowsable))
        return .none
    }

    func range(phoneID: String, entry: PhoneFileEntry, offset: Int64, length: Int64,
               progress: @escaping (Int64) -> Void,
               completion: @escaping (Result<Data, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        completion(.failure(.notBrowsable))
        return .none
    }

    func download(phoneID: String, refs: [PhoneRef], into directory: URL, purpose: PhoneDownloadPurpose,
                  progress: @escaping (PhoneTransferProgress) -> Void,
                  completion: @escaping (Result<[URL], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        completion(.failure(.notBrowsable))
        return .none
    }

    func upload(phoneID: String, urls: [URL], placeId: String, path: String,
                progress: @escaping (PhoneTransferProgress) -> Void,
                completion: @escaping (Result<Void, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        completion(.failure(.notBrowsable))
        return .none
    }
}

enum PhoneFilesDigest {
    static func hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
