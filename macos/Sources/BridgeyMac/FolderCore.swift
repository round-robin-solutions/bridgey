import CryptoKit
import Foundation

// Draft folders protocol (docs/folders-and-settings-sync.md, protocol.md "Draft: folders, places and
// settings sync"): names, paths, limits and the manifest digest. Pure code, so the shared vectors in
// protocol/test-vectors/folders-v1.json run in swift test. Android has the same rules in FolderCore.kt.
//
// Swift compares strings by canonical equivalence ("é" == "e\u{301}"), so every check that must see the
// exact code points compares unicode scalars or UTF-8 bytes instead.

enum FolderLimits {
    static let maxFiles = 10_000
    static let maxFolders = 2_000
    static let maxDepth = 32
    static let maxNameBytes = 220
    static let maxPathBytes = 1_024
    static let maxExistingComponentBytes = 255
    static let maxFileSize: Int64 = 10 * 1024 * 1024 * 1024
    static let maxTotalSize: Int64 = 1 << 40
    static let maxPages = 128
    static let maxEntriesPerPage = 256
    static let maxPageBytes = 32 * 1024
    static let maxManifestBytes = 4 * 1024 * 1024
    static let maxPlaces = 16
    static let maxBrowseNames = 500
    static let maxReportedFailures = 500
    static let maxFailuresBeforeCancel = 50
    static let smallPlaintext = 8 * 1024
    static let largePlaintext = 32 * 1024
    /// Pipelining inside a folder (4.6).
    static let chunkWindow = 64
    static let filesAwaitingCompletion = 32
}

enum FolderTimeouts {
    /// A question to a person (destination or conflict), counted by the device that asks.
    static let questionSeconds = 180
    /// The sender's own wait on a remote question: the question plus a margin.
    static let senderQuestionWait: TimeInterval = 195
    /// First answer after the last manifest page.
    static let firstAnswer: TimeInterval = 15
    /// Answer to a places request.
    static let placesAnswer: TimeInterval = 8
    /// folders.result after folders.complete.
    static let result: TimeInterval = 30
    /// Resume (Rahul, transfer engine A4/A5, 2026-10-26): an interrupted folder resumes by itself whenever
    /// both devices can reach each other, until 24 hours after its last progress.
    static let resumeWindow: TimeInterval = 24 * 60 * 60

    static func canResume(lastProgress: Date, now: Date) -> Bool {
        now >= lastProgress && now.timeIntervalSince(lastProgress) < resumeWindow
    }
}

/// Draft feature keys (D20): advertised instead of the final keys until upstream accepts the design.
let foldersFeatureKey = "folders_draft1"
let placesFeatureKey = "places_draft1"

private func scalarsEqual(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

/// Section 5.1: names that are safe on FAT-style storage, Android shared storage and macOS.
enum PortableName {
    private static let partSuffix = ".bridgey-part"
    private static let maxExtensionBytes = 16
    private static let reserved: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
    private static let replaced: Set<Unicode.Scalar> = Set("\"*/:<>?\\|".unicodeScalars)

    /// Steps 1 to 6.
    static func normalize(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            scalars.append(scalar.value < 0x20 || scalar.value == 0x7f || replaced.contains(scalar) ? "_" : scalar)
        }
        var value = trim(String(scalars))
        let head = String(value.unicodeScalars.prefix { $0 != "." })
        if reserved.contains(head.uppercased()) {
            value = head + "_" + String(value.unicodeScalars.dropFirst(head.unicodeScalars.count))
        }
        if value.lowercased().hasSuffix(partSuffix) { value += "_" }
        return value
    }

    /// The sender's conversion, steps 1 to 7.
    static func convert(_ name: String) -> String {
        let value = normalize(name)
        guard value.utf8.count > FolderLimits.maxNameBytes else { return value }
        let scalars = Array(value.unicodeScalars)
        var extensionScalars: [Unicode.Scalar] = []
        if let dot = scalars.lastIndex(of: "."), dot > 0 {
            let candidate = Array(scalars[dot...])
            if String(String.UnicodeScalarView(candidate)).utf8.count <= maxExtensionBytes { extensionScalars = candidate }
        }
        let extensionText = String(String.UnicodeScalarView(extensionScalars))
        let stem = scalars.dropLast(extensionScalars.count)
        var kept = String.UnicodeScalarView()
        var bytes = 0
        let limit = FolderLimits.maxNameBytes - extensionText.utf8.count
        for scalar in stem {
            let size = String(scalar).utf8.count
            if bytes + size > limit { break }
            kept.append(scalar)
            bytes += size
        }
        return trim(String(kept) + extensionText)
    }

    /// The receiver's check: the name does not change under steps 1 to 6 and fits in 220 bytes.
    static func isPortable(_ name: String) -> Bool {
        !name.isEmpty && scalarsEqual(normalize(name), name) && name.utf8.count <= FolderLimits.maxNameBytes
    }

    private static func trim(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let first = scalars.first, first == " " { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "." { scalars.removeLast() }
        return scalars.isEmpty ? "_" : String(String.UnicodeScalarView(scalars))
    }
}

/// The key two names clash under: NFC, then Unicode default lowercase.
func caseKey(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

/// Sections 5.2 and 5.3.
enum FolderPaths {
    /// A manifest path: portable components joined by "/", at most 32 components and 1,024 bytes.
    static func isValidManifestPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= FolderLimits.maxPathBytes else { return false }
        let parts = components(path)
        guard parts.count <= FolderLimits.maxDepth else { return false }
        return parts.allSatisfy(PortableName.isPortable)
    }

    /// A path of existing folders (browse, destination). "" is the place itself.
    static func isValidExistingPath(_ path: String) -> Bool {
        if path.isEmpty { return true }
        guard path.utf8.count <= FolderLimits.maxPathBytes else { return false }
        let parts = components(path)
        guard parts.count <= FolderLimits.maxDepth else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.count <= FolderLimits.maxExistingComponentBytes &&
                !part.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
    }

    /// Splits on "/" keeping empty components (so "a//b" and "a/" are caught).
    static func components(_ path: String) -> [String] {
        path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    static func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    static func compareUTF8(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }

    /// Manifest order: depth-first pre-order, siblings by the UTF-8 bytes of their names.
    static func precedes(_ a: String, _ b: String) -> Bool {
        let left = components(a), right = components(b)
        for (l, r) in zip(left, right) where !l.utf8.elementsEqual(r.utf8) { return compareUTF8(l, r) }
        return left.count < right.count
    }
}

/// D17: "Photos (1)" for folders, "name (1).ext" for files, the first free number. Comparison ignores case.
enum ConflictNames {
    static func numbered(_ name: String, _ number: Int, isDirectory: Bool) -> String {
        if isDirectory { return "\(name) (\(number))" }
        let scalars = Array(name.unicodeScalars)
        guard let dot = scalars.lastIndex(of: "."), dot > 0 else { return "\(name) (\(number))" }
        let stem = String(String.UnicodeScalarView(scalars[..<dot]))
        let ext = String(String.UnicodeScalarView(scalars[dot...]))
        return "\(stem) (\(number))\(ext)"
    }

    /// `name` itself when free, otherwise the first free numbered name. `taken` receives case keys.
    static func firstFree(_ name: String, isDirectory: Bool, taken: (String) -> Bool) -> String {
        if !taken(caseKey(name)) { return name }
        for number in 1...9_999 {
            let candidate = numbered(name, number, isDirectory: isDirectory)
            if !taken(caseKey(candidate)) { return candidate }
        }
        return numbered(name, 10_000 + Int.random(in: 0..<65_536), isDirectory: isDirectory)
    }

    /// Section 5.2, sender side: siblings sorted by UTF-8 bytes, each later clashing sibling renamed with the
    /// smallest free number. Returns (original index, final name) in that order.
    static func resolveSiblings(_ names: [(name: String, isDirectory: Bool)]) -> [(index: Int, name: String)] {
        let order = names.indices.sorted { FolderPaths.compareUTF8(names[$0].name, names[$1].name) }
        let originalKeys = Set(names.map { caseKey($0.name) })
        var assigned = Set<String>()
        return order.map { index in
            let (name, isDirectory) = names[index]
            let final = assigned.contains(caseKey(name))
                ? firstFree(name, isDirectory: isDirectory) { assigned.contains($0) || originalKeys.contains($0) }
                : name
            assigned.insert(caseKey(final))
            return (index, final)
        }
    }
}

/// The confirmed hidden and system file rules (Rahul, 2026-10-25). System files are matched by exact name
/// (plus the AppleDouble "._" prefix), never by a broad pattern, and are skipped unless "Include system
/// files" is on, even when hidden files are included.
enum SystemFiles {
    static let names: [String] = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        ".VolumeIcon.icns", ".localized", "Icon\r", "Thumbs.db", "ehthumbs.db", "desktop.ini", "$RECYCLE.BIN",
        "System Volume Information",
    ]
    static let appleDoublePrefix = "._"

    enum Kind: String { case normal, hidden, system, partial }

    static func classify(_ name: String, hiddenFlag: Bool = false) -> Kind {
        if name.lowercased().hasSuffix(".bridgey-part") { return .partial }
        if names.contains(where: { scalarsEqual($0, name) }) || name.hasPrefix(appleDoublePrefix) { return .system }
        if name.hasPrefix(".") || hiddenFlag { return .hidden }
        return .normal
    }

    static func included(_ kind: Kind, includeHidden: Bool, includeSystem: Bool) -> Bool {
        switch kind {
        case .normal: return true
        case .hidden: return includeHidden
        case .system: return includeSystem
        case .partial: return false
        }
    }
}

struct ManifestEntry: Codable, Equatable {
    enum Kind: String, Codable { case dir, file }

    let type: Kind
    let path: String
    let size: Int64?
    let sha256: String?
    let modified: Int64?

    static func dir(_ path: String) -> ManifestEntry { ManifestEntry(type: .dir, path: path, size: nil, sha256: nil, modified: nil) }

    static func file(_ path: String, size: Int64, sha256: String, modified: Int64? = nil) -> ManifestEntry {
        ManifestEntry(type: .file, path: path, size: size, sha256: sha256, modified: modified)
    }

    var isDirectory: Bool { type == .dir }
}

enum ManifestDigest {
    /// Section 4.5.1.
    static func compute(rootName: String, entries: [ManifestEntry]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("folder-manifest-v1\n\(rootName)\n".utf8))
        for entry in entries {
            let size = entry.isDirectory ? "0" : String(entry.size ?? 0)
            hasher.update(data: Data("\(entry.type.rawValue)\u{0}\(entry.path)\u{0}\(size)\u{0}\(entry.sha256 ?? "")\n".utf8))
        }
        return Data(hasher.finalize()).base64EncodedString()
    }
}

/// folders.accept completedBitmap: bit i (least significant bit first) set when entry i is done.
enum CompletedBitmap {
    static func encode(size: Int, done: (Int) -> Bool) -> String {
        var bytes = [UInt8](repeating: 0, count: (size + 7) / 8)
        for index in 0..<size where done(index) { bytes[index / 8] |= UInt8(1 << (index % 8)) }
        return Data(bytes).base64EncodedString()
    }

    /// Nil when `value` is not base64 or too short for `size` entries.
    static func decode(_ value: String, size: Int) -> Set<Int>? {
        guard let data = Data(base64Encoded: value), data.count >= (size + 7) / 8 else { return nil }
        let bytes = [UInt8](data)
        return Set((0..<size).filter { (bytes[$0 / 8] >> UInt8($0 % 8)) & 1 == 1 })
    }
}

/// Error codes of section 4.8.
enum FolderCode {
    static let unsupported = "unsupported"
    static let policy = "policy"
    static let busy = "busy"
    static let invalidMessage = "invalid_message"
    static let invalidManifest = "invalid_manifest"
    static let limitExceeded = "limit_exceeded"
    static let insufficientSpace = "insufficient_space"
    static let placeUnavailable = "place_unavailable"
    static let notFound = "not_found"
    static let exists = "exists"
    static let invalidName = "invalid_name"
    static let timeout = "timeout"
    static let declined = "declined"
    static let ioError = "io_error"
    static let verificationFailed = "verification_failed"
    static let sourceChanged = "source_changed"
    static let unreadable = "unreadable"
    static let resumeUnavailable = "resume_unavailable"
    static let tooManyFailures = "too_many_failures"
    static let cancelled = "cancelled"
}
