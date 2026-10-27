import Foundation

// Payloads of the draft folders and places messages (section 4.5): the decrypted JSON of one encrypted
// message each. Android: FolderMessages.kt, same fields. Optional fields are left out when nil; receivers
// treat a missing field and null alike, and ignore unknown fields.

enum FolderKind {
    static let placesList = "places.list"
    static let placesListed = "places.listed"
    static let placesBrowse = "places.browse"
    static let placesChildren = "places.children"
    static let placesCreateFolder = "places.create_folder"
    static let placesFolderCreated = "places.folder_created"
    static let placesError = "places.error"
    static let offer = "folders.offer"
    static let manifest = "folders.manifest"
    static let waiting = "folders.waiting"
    static let conflict = "folders.conflict"
    static let resolve = "folders.resolve"
    static let accept = "folders.accept"
    static let rejected = "folders.rejected"
    static let entryFailed = "folders.entry_failed"
    static let complete = "folders.complete"
    static let result = "folders.result"
    static let cancel = "folders.cancel"
    static let cancelAck = "folders.cancel.ack"

    static let placesKinds: Set<String> = [placesList, placesListed, placesBrowse, placesChildren, placesCreateFolder, placesFolderCreated, placesError]
    static let folderKinds: Set<String> = [offer, manifest, waiting, conflict, resolve, accept, rejected, entryFailed, complete, result, cancel, cancelAck]

    /// Plaintext limit per kind (4.2).
    static func plaintextLimit(_ kind: String) -> Int {
        [manifest, complete, result, placesListed, placesChildren].contains(kind) ? FolderLimits.largePlaintext : FolderLimits.smallPlaintext
    }
}

enum FolderJSON {
    /// Paths stay readable ("a/b", not "a\/b") and page sizes are what the receiver measures.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func isWireID(_ value: String?) -> Bool {
        guard let value, value.count == 36, value == value.lowercased() else { return false }
        return UUID(uuidString: value) != nil
    }

    static func isPlaceID(_ value: String?) -> Bool {
        guard let value else { return false }
        if value == defaultPlaceID { return true }
        return value.count == 22 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }
    }
}

let defaultPlaceID = "default"

/// Destination mode of the receiving device (3.2).
enum DestinationMode: String, Codable { case senderPicks = "sender_picks", receiverAsks = "receiver_asks", fixed }

/// "When a folder already exists" (3.3).
enum ConflictPolicy: String, Codable, CaseIterable { case ask, merge, replace, newFolder = "new_folder" }

/// An answer to the conflict question, and the `choice` field of folders.accept.
enum ConflictChoice: String, Codable { case none, merge, replace, newFolder = "new_folder", cancel }

struct PlacesListPayload: Codable, Equatable {
    var version = 1
    let requestId: String
}

struct PlaceInfo: Codable, Equatable, Identifiable, Hashable {
    let placeId: String
    let label: String
    let available: Bool
    let freeBytes: Int64?
    var id: String { placeId }
}

struct PlacesListedPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let mode: DestinationMode
    let places: [PlaceInfo]
    let fixedLabel: String?

    var isValid: Bool {
        version == 1 && FolderJSON.isWireID(requestId) && places.count <= FolderLimits.maxPlaces + 1 && places.allSatisfy { FolderJSON.isPlaceID($0.placeId) }
    }
}

struct PlacesBrowsePayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let placeId: String
    let path: String
    let cursor: String?
}

struct PlacesChildrenPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let placeId: String
    let path: String
    let folders: [String]
    let fileCount: Int
    let folderCount: Int
    let nextCursor: String?
}

struct PlacesCreateFolderPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let placeId: String
    let path: String
    let name: String
}

struct PlacesErrorPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let code: String
}

struct FolderDestination: Codable, Equatable, Hashable {
    let placeId: String
    let path: String
}

/// What the sender left out, for the receiver's activity item. Unknown counters are ignored.
struct SkippedCounts: Codable, Equatable {
    var links = 0
    var hidden = 0
    var system = 0
    var unreadable = 0
    var tooLarge = 0
    var notDownloaded = 0
    var tooLong = 0
    var other = 0

    var total: Int { links + hidden + system + unreadable + tooLarge + notDownloaded + tooLong + other }
}

struct FolderOfferPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let rootName: String
    let fileCount: Int
    let folderCount: Int
    let totalSize: Int64
    let pageCount: Int
    let manifestSha256: String
    let destination: FolderDestination?
    let resume: Bool
    let skipped: SkippedCounts?
    /// Files 2.0 browse: the entries land directly in the destination (uploads and downloads); top-level
    /// clashes become copies, nothing is merged or replaced.
    var into: Bool? = nil
    /// Files 2.0 browse: this offer answers the receiver's places.download.
    var downloadRequestId: String? = nil

    var isInto: Bool { into == true }
}

struct ManifestPagePayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let page: Int
    let entries: [ManifestEntry]
}

struct FolderWaitingPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let reason: String
    let timeoutSeconds: Int

    static let destination = "destination"
    static let conflict = "conflict"
}

struct FolderConflictPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let existing: String
    let clashingFiles: Int?
    let clashingFolders: Int?
    let newFolderName: String
    let choices: [ConflictChoice]
    let timeoutSeconds: Int

    var existingIsFile: Bool { existing == "file" }
}

struct FolderResolvePayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let choice: ConflictChoice
}

struct FolderAcceptPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let rootName: String
    let destinationLabel: String
    let choice: ConflictChoice
    let completedBitmap: String?
}

struct FolderRejectedPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let code: String
    let entry: Int?
    let neededBytes: Int64?
    let freeBytes: Int64?
}

struct FolderEntryFailedPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let entry: Int
    let transferId: String
    let code: String
}

struct FailedEntry: Codable, Equatable {
    let entry: Int
    let code: String
}

struct FolderCompletePayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let sentFiles: Int
    let failedCount: Int
    let failed: [FailedEntry]
}

struct FolderResultPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let status: String
    let savedFiles: Int
    let savedBytes: Int64
    let createdFolders: Int
    let renamedFiles: Int
    let replacedFiles: Int
    let failedCount: Int
    let failed: [FailedEntry]

    var isComplete: Bool { status == "complete" }
}

struct FolderCancelPayload: Codable, Equatable {
    var version = 1
    let folderTransferId: String
    let reason: String
    let code: String?

    static let user = "user"
    static let timeout = "timeout"
    static let policy = "policy"
    static let error = "error"
}

/// files.offer inside a folder transfer (4.6): the usual fields plus the folder, the entry index and its path.
struct FolderFileOfferPayload: Codable, Equatable {
    let transferId: String
    let name: String
    let mimeType: String
    let size: Int64
    let sha256: String
    let folderTransferId: String
    let entry: Int
    let path: String
}

/// Sender side: splits a manifest into pages of at most 256 entries and 32 KiB of plaintext. Nil when it
/// needs more than 128 pages or 4 MiB. An empty folder has no pages.
enum ManifestPager {
    static func pages(folderTransferID: String, entries: [ManifestEntry]) -> [ManifestPagePayload]? {
        let encoder = FolderJSON.encoder
        let overhead = ((try? encoder.encode(ManifestPagePayload(folderTransferId: folderTransferID, page: FolderLimits.maxPages, entries: [])))?.count ?? 128) + 16
        var pages: [ManifestPagePayload] = []
        var current: [ManifestEntry] = []
        var currentBytes = 0
        var totalBytes = 0
        func flush() {
            guard !current.isEmpty else { return }
            pages.append(ManifestPagePayload(folderTransferId: folderTransferID, page: pages.count, entries: current))
            totalBytes += currentBytes + overhead
            current = []
            currentBytes = 0
        }
        for entry in entries {
            let size = ((try? encoder.encode(entry))?.count ?? FolderLimits.maxPageBytes) + 1
            if current.count == FolderLimits.maxEntriesPerPage || overhead + currentBytes + size > FolderLimits.maxPageBytes { flush() }
            current.append(entry)
            currentBytes += size
        }
        flush()
        guard pages.count <= FolderLimits.maxPages, totalBytes <= FolderLimits.maxManifestBytes else { return nil }
        return pages
    }
}
