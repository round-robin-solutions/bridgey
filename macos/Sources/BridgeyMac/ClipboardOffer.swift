import CryptoKit
import Foundation
import UniformTypeIdentifiers

/*
 * Clipboard offers (`clipboard_files_draft1`, docs/protocol.md): the other device learns about a
 * copy at once and the data moves when someone pastes. This file is the pure part: the wire
 * model, its validation and limits, and the eager-push rule. Everything here is unit tested.
 */

/// The `features.update` key both peers must advertise before any message below is used.
let clipboardFilesFeatureKey = "clipboard_files_draft1"

enum ClipboardOfferLimits {
    static let maximumItems = 100
    static let maximumPlaintextBytes = 40_960
    /// All inline items of one offer together, decoded.
    static let maximumInlineBytes = 16 * 1024
    static let maximumItemSize: Int64 = 10 * 1024 * 1024 * 1024
    static let maximumNameLength = 255
    static let maximumMimeLength = 255
    static let fetchStartTimeout: TimeInterval = 15
    static let stallTimeout: TimeInterval = 30
    static let maximumConcurrentTransfers = 4
    static let cacheMaximumAge: TimeInterval = 24 * 60 * 60
    static let cacheMaximumBytes: Int64 = 2_000_000_000
    static let chunkSize = 24 * 1024
}

/// "Send right away up to": what the sender pushes right after an offer. Decimal megabytes,
/// as people read file sizes; `.askWhenPasting` pushes nothing.
enum ClipboardEagerLimit: Int64, CaseIterable, Identifiable {
    case fiveMB = 5_000_000
    case twentyFiveMB = 25_000_000
    case hundredMB = 100_000_000
    case askWhenPasting = 0

    static let `default` = ClipboardEagerLimit.twentyFiveMB
    var id: Int64 { rawValue }
    var bytes: Int64 { rawValue }

    init(bytes: Int64) {
        self = ClipboardEagerLimit(rawValue: bytes) ?? .default
    }
}

enum ClipboardItemKind: String, Codable, Equatable {
    case text, html, image, file
}

struct ClipboardOfferItem: Codable, Equatable {
    var index: Int
    var kind: ClipboardItemKind
    var mime: String
    var name: String?
    var size: Int64
    var sha256: String?
    var inline: String?
}

struct ClipboardOffer: Codable, Equatable {
    var version: Int = 1
    var offerId: String
    var createdAt: Int64
    var sensitive: Bool?
    var items: [ClipboardOfferItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var isText: Bool { items.first?.kind == .text }

    /// Decodes and validates a received plaintext; nil when malformed or out of bounds.
    static func decode(_ plaintext: Data) -> ClipboardOffer? {
        guard plaintext.count <= ClipboardOfferLimits.maximumPlaintextBytes,
              let offer = try? JSONDecoder().decode(ClipboardOffer.self, from: plaintext) else { return nil }
        return offer.validated()
    }

    /// The offer with file names reduced to their last path component, or nil when it breaks a rule.
    func validated() -> ClipboardOffer? {
        guard version == 1,
              UUID(uuidString: offerId) != nil,
              createdAt >= 0,
              (1...ClipboardOfferLimits.maximumItems).contains(items.count) else { return nil }
        let kinds = items.map(\.kind)
        let textOffer = kinds == [.text] || kinds == [.text, .html]
        let mediaOffer = kinds.allSatisfy { $0 == .image || $0 == .file }
        guard textOffer || mediaOffer else { return nil }
        var inlineTotal = 0
        var cleaned: [ClipboardOfferItem] = []
        for (position, item) in items.enumerated() {
            guard item.index == position,
                  clipboardMimeIsValid(item.mime),
                  (0...ClipboardOfferLimits.maximumItemSize).contains(item.size) else { return nil }
            var copy = item
            if item.kind == .file {
                guard let name = item.name.flatMap(clipboardSanitizedName) else { return nil }
                copy.name = name
            } else {
                copy.name = nil
            }
            if let hash = item.sha256 {
                guard Data(base64Encoded: hash)?.count == 32 else { return nil }
            }
            if let inline = item.inline {
                guard let hash = item.sha256,
                      let data = Data(base64Encoded: inline),
                      Int64(data.count) == item.size,
                      Data(SHA256.hash(data: data)).base64EncodedString() == hash else { return nil }
                inlineTotal += data.count
                guard inlineTotal <= ClipboardOfferLimits.maximumInlineBytes else { return nil }
            }
            cleaned.append(copy)
        }
        var result = self
        result.items = cleaned
        return result
    }

    /// Encodes for sending, keeping the plaintext within the limit: inline data goes first, then
    /// long names are shortened (keeping the extension), then trailing items are dropped.
    func encodedForSending() -> (offer: ClipboardOffer, data: Data)? {
        var offer = self
        let encoder = JSONEncoder()
        func fits(_ value: ClipboardOffer) -> Data? {
            guard let data = try? encoder.encode(value), data.count <= ClipboardOfferLimits.maximumPlaintextBytes else { return nil }
            return data
        }
        if let data = fits(offer) { return (offer, data) }
        offer.items = offer.items.map { var item = $0; item.inline = nil; return item }
        if let data = fits(offer) { return (offer, data) }
        offer.items = offer.items.map { var item = $0; item.name = item.name.map { clipboardShortenedName($0, limit: 64) }; return item }
        while offer.items.count > 1 {
            if let data = fits(offer) { return (offer, data) }
            offer.items.removeLast()
        }
        return fits(offer).map { (offer, $0) }
    }

    func inlineData(at index: Int) -> Data? {
        guard items.indices.contains(index), let inline = items[index].inline else { return nil }
        return Data(base64Encoded: inline)
    }
}

/// Which items the sender pushes right after an offer: in index order while the running total
/// stays within the limit. Inline items are already there and are skipped.
func clipboardEagerIndices(_ items: [ClipboardOfferItem], limit: Int64) -> [Int] {
    guard limit > 0 else { return [] }
    var total: Int64 = 0
    var result: [Int] = []
    for item in items where item.inline == nil {
        guard total + item.size <= limit else { break }
        total += item.size
        result.append(item.index)
    }
    return result
}

func clipboardMimeIsValid(_ mime: String) -> Bool {
    guard (1...ClipboardOfferLimits.maximumMimeLength).contains(mime.count) else { return false }
    let parts = mime.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
    return !mime.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == " " }
}

/// The last path component, without control characters or path separators; nil when nothing is left.
func clipboardSanitizedName(_ name: String) -> String? {
    let leaf = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    let cleaned = String(leaf.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == ":" ? "_" : Character($0) })
        .trimmingCharacters(in: .whitespaces)
    guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
    return String(cleaned.prefix(ClipboardOfferLimits.maximumNameLength))
}

func clipboardShortenedName(_ name: String, limit: Int) -> String {
    guard name.count > limit else { return name }
    let ext = (name as NSString).pathExtension
    let keep = max(1, limit - (ext.isEmpty ? 0 : ext.count + 1))
    let stem = String((name as NSString).deletingPathExtension.prefix(keep))
    return ext.isEmpty ? stem : "\(stem).\(ext)"
}

/// A file extension for a MIME type, for names of images and text that have none.
func clipboardFileExtension(forMime mime: String) -> String {
    switch mime.lowercased() {
    case "image/jpeg": return "jpg"
    case "text/plain": return "txt"
    case "text/html": return "html"
    default: return UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
    }
}

/// The name a clipboard-purpose transfer carries for an item without one.
func clipboardTransferName(for item: ClipboardOfferItem) -> String {
    if let name = item.name { return name }
    switch item.kind {
    case .image: return "image.\(clipboardFileExtension(forMime: item.mime))"
    case .text: return "clipboard.txt"
    case .html: return "clipboard.html"
    case .file: return "file"
    }
}

// MARK: Fetches, errors and clipboard-purpose transfers

struct ClipboardFetchPayload: Codable, Equatable {
    var version: Int = 1
    var offerId: String
    var index: Int
    var transferId: String

    func validated() -> ClipboardFetchPayload? {
        guard version == 1, UUID(uuidString: offerId) != nil, UUID(uuidString: transferId) != nil,
              (0..<ClipboardOfferLimits.maximumItems).contains(index) else { return nil }
        return self
    }
}

enum ClipboardErrorCode: String, Codable, Equatable {
    case expired, changed, unavailable, disabled, busy
    case tooLarge = "too_large"
}

struct ClipboardErrorPayload: Codable, Equatable {
    var version: Int = 1
    var offerId: String
    var index: Int
    var transferId: String
    var code: ClipboardErrorCode
}

/// `files.offer` with `purpose: "clipboard"`. `sha256` is omitted when the sender hashes while
/// it streams; the authoritative hash then arrives in `files.complete`.
struct ClipboardTransferOffer: Codable, Equatable {
    var transferId: String
    var name: String
    var mimeType: String
    var size: Int64
    var sha256: String?
    var purpose: String = "clipboard"
    var offerId: String
    var index: Int
}

/// Reads only the purpose of a decrypted `files.offer`.
struct FileOfferPurposeProbe: Decodable {
    let purpose: String?
}

struct ClipboardTransferComplete: Codable, Equatable {
    let transferId: String
    let sha256: String
}

// MARK: Summaries for the activity stream and the send bar

/// What an offer holds, in the words the stream uses.
struct ClipboardOfferSummary: Equatable {
    /// "text", "image" or "file".
    let content: String
    let count: Int
    let bytes: Int64
    /// The name of a single file; nil otherwise.
    let fileName: String?

    init(content: String, count: Int, bytes: Int64, fileName: String?) {
        self.content = content
        self.count = count
        self.bytes = bytes
        self.fileName = fileName
    }

    init(_ offer: ClipboardOffer) {
        let media = offer.items.filter { $0.kind == .image || $0.kind == .file }
        if offer.isText {
            content = "text"
            count = 1
            bytes = offer.items.first?.size ?? 0
            fileName = nil
        } else {
            content = media.allSatisfy { $0.kind == .image } ? "image" : "file"
            count = media.count
            bytes = media.reduce(0) { $0 + $1.size }
            fileName = media.count == 1 && media[0].kind == .file ? media[0].name : nil
        }
    }

    init(item: ClipboardOfferItem) {
        content = item.kind == .image ? "image" : (item.kind == .file ? "file" : "text")
        count = 1
        bytes = item.size
        fileName = item.kind == .file ? item.name : nil
    }
}

/// A stable fingerprint for de-duplication of copied files that never reads their contents:
/// path, size and modification time of each file.
func clipboardFileFingerprint(_ files: [(path: String, size: Int64, modified: Date)]) -> String {
    let joined = files.map { "\($0.path)\u{0}\($0.size)\u{0}\(Int64(($0.modified.timeIntervalSince1970 * 1000).rounded()))" }
        .joined(separator: "\n")
    return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
}

func clipboardDataHash(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).base64EncodedString()
}
