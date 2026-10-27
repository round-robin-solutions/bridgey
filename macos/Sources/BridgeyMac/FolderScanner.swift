import CryptoKit
import Darwin
import Foundation

// Section 7.2: turns a folder on this Mac into a manifest. The scan (names, counts, limits) is quick and
// runs first; hashing reads every file once (1 MiB reads) and can take a while, so it is separate and
// reports progress. Both run on a background queue. Symbolic links and Finder aliases are never followed.

/// "Include hidden files" and "Include system files" for one send (Settings > Files has the defaults).
struct FolderScanOptions: Equatable, Codable {
    var includeHidden = false
    var includeSystem = false
}

/// One child as the scanner sees it. `FolderListing` reads these from the disk; tests can inject them.
struct FolderScanItem {
    let name: String
    let url: URL
    var isDirectory = false
    var isRegularFile = false
    var isSymbolicLink = false
    var isAlias = false
    var isPackage = false
    var isHidden = false
    /// A mount point inside the folder (another volume).
    var isVolume = false
    var size: Int64 = 0
    var modified: Date?
    /// Lives only in iCloud (or another provider) and reading it would start a download.
    var notDownloaded = false
    var readable = true
}

protocol FolderListing {
    /// The direct children of a folder, in any order. Throws when the folder cannot be read.
    func children(of url: URL) throws -> [FolderScanItem]
}

struct DiskFolderListing: FolderListing {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .isHiddenKey,
        .isVolumeKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey,
    ]

    /// Names come from readdir: FileManager leaves out AppleDouble "._" files next to their main file, and
    /// the hidden and system rules are ours (with "Include system files" on, "._" files are sent too).
    func children(of url: URL) throws -> [FolderScanItem] {
        guard let directory = url.withUnsafeFileSystemRepresentation({ $0.flatMap { opendir($0) } }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." || name.isEmpty { continue }
            names.append(name)
        }
        return names.map { Self.item(url.appendingPathComponent($0)) }
    }

    static func item(_ url: URL) -> FolderScanItem {
        let values = try? url.resourceValues(forKeys: Set(keys))
        var item = FolderScanItem(name: url.lastPathComponent, url: url)
        item.isSymbolicLink = values?.isSymbolicLink ?? false
        item.isAlias = (values?.isAliasFile ?? false) && !item.isSymbolicLink
        item.isDirectory = values?.isDirectory ?? false
        item.isRegularFile = values?.isRegularFile ?? false
        item.isPackage = values?.isPackage ?? false
        item.isHidden = values?.isHidden ?? false
        item.isVolume = values?.isVolume ?? false
        item.size = Int64(values?.fileSize ?? 0)
        item.modified = values?.contentModificationDate
        var info = stat()
        let dataless = lstat(url.path, &info) == 0 && (info.st_flags & UInt32(SF_DATALESS)) != 0
        if let status = values?.ubiquitousItemDownloadingStatus {
            item.notDownloaded = status != .current || dataless
        } else {
            item.notDownloaded = dataless
        }
        if item.isRegularFile { item.readable = FileManager.default.isReadableFile(atPath: url.path) }
        return item
    }
}

/// Why a folder is refused before anything is sent (5.4).
enum FolderLimitProblem: Equatable {
    case tooManyFiles(Int)
    case tooManyFolders(Int)
    case tooDeep
    case tooBig(Int64)
    case manifestTooLarge
    case unreadable

    func message(folder: String) -> String {
        let number = Self.grouped
        switch self {
        case let .tooManyFiles(count):
            return String(format: L10n.text("folders.limit.files", fallback: "%1$@ has %2$@ files; the limit is %3$@. Send its subfolders separately."),
                          folder, number(count), number(FolderLimits.maxFiles))
        case let .tooManyFolders(count):
            return String(format: L10n.text("folders.limit.folders", fallback: "%1$@ has %2$@ folders; the limit is %3$@. Send its subfolders separately."),
                          folder, number(count), number(FolderLimits.maxFolders))
        case .tooDeep:
            return String(format: L10n.text("folders.limit.depth", fallback: "%1$@ has folders more than %2$@ levels deep. Send its subfolders separately."),
                          folder, number(FolderLimits.maxDepth))
        case let .tooBig(bytes):
            return String(format: L10n.text("folders.limit.size", fallback: "%1$@ holds %2$@; the limit is %3$@. Send its subfolders separately."),
                          folder, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                          ByteCountFormatter.string(fromByteCount: FolderLimits.maxTotalSize, countStyle: .file))
        case .manifestTooLarge:
            return String(format: L10n.text("folders.limit.manifest", fallback: "%@ has too many long names to send at once. Send its subfolders separately."), folder)
        case .unreadable:
            return String(format: L10n.text("folders.limit.unreadable", fallback: "Bridgey can\u{2019}t read %@."), folder)
        }
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// The scanned folder. `entries` are in manifest order; `sources` holds the file on this Mac for each entry.
/// Files have no `sha256` until `FolderHasher` has run.
struct FolderScan {
    let root: URL
    /// The folder's own name as Finder shows it, for the UI.
    let displayName: String
    /// The portable root name sent to the phone.
    let rootName: String
    let options: FolderScanOptions
    var entries: [ManifestEntry] = []
    var sources: [URL] = []
    var fileCount = 0
    var folderCount = 0
    var totalSize: Int64 = 0
    var skipped = SkippedCounts()
    /// Names changed to fit the phone (converted or numbered after a case clash).
    var renamed = 0
    /// Display names of packages sent as ordinary folders (the root first when it is one).
    var packages: [String] = []
    var problem: FolderLimitProblem?
    var hashed = false

    var isEmpty: Bool { entries.isEmpty }

    var manifestDigest: String { ManifestDigest.compute(rootName: rootName, entries: entries) }
}

enum FolderScanner {
    /// A placeholder hash, the length of a real one, to check the manifest size before hashing.
    private static let placeholderHash = Data(count: 32).base64EncodedString()

    /// Files 2.0 browse: several dropped files and folders as the top-level entries of one `into` transfer.
    /// The root name is the first item's portable name (display and digest only).
    static func scan(items: [URL], options: FolderScanOptions, listing: FolderListing = DiskFolderListing(), isCancelled: () -> Bool = { false }) -> FolderScan {
        let first = items.first?.lastPathComponent ?? "Files"
        let parent = items.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        var scan = FolderScan(root: parent, displayName: first, rootName: PortableName.convert(first), options: options)
        let children = items.map { DiskFolderListing.item($0) }
        var deepest = 0
        walk(children, relative: "", depth: 0, scan: &scan, deepest: &deepest, listing: listing, isCancelled: isCancelled)
        if scan.problem == nil {
            if scan.entries.isEmpty { scan.problem = .unreadable }
            else if scan.fileCount > FolderLimits.maxFiles { scan.problem = .tooManyFiles(scan.fileCount) }
            else if scan.folderCount > FolderLimits.maxFolders { scan.problem = .tooManyFolders(scan.folderCount) }
            else if deepest > FolderLimits.maxDepth { scan.problem = .tooDeep }
            else if scan.totalSize > FolderLimits.maxTotalSize { scan.problem = .tooBig(scan.totalSize) }
            else {
                let sized = scan.entries.map { $0.isDirectory ? $0 : ManifestEntry.file($0.path, size: $0.size ?? 0, sha256: placeholderHash, modified: $0.modified) }
                if ManifestPager.pages(folderTransferID: UUID().uuidString.lowercased(), entries: sized) == nil { scan.problem = .manifestTooLarge }
            }
        }
        return scan
    }

    static func scan(_ root: URL, options: FolderScanOptions, listing: FolderListing = DiskFolderListing(), isCancelled: () -> Bool = { false }) -> FolderScan {
        let rootValues = try? root.resourceValues(forKeys: [.isPackageKey])
        var scan = FolderScan(root: root, displayName: root.lastPathComponent, rootName: PortableName.convert(root.lastPathComponent), options: options)
        if rootValues?.isPackage == true { scan.packages.append(root.lastPathComponent) }
        if scan.rootName.precomposedStringWithCanonicalMapping.unicodeScalars.elementsEqual(root.lastPathComponent.precomposedStringWithCanonicalMapping.unicodeScalars) == false {
            scan.renamed += 1
        }
        guard let children = try? listing.children(of: root) else {
            scan.problem = .unreadable
            return scan
        }
        var deepest = 0
        walk(children, relative: "", depth: 0, scan: &scan, deepest: &deepest, listing: listing, isCancelled: isCancelled)
        if scan.problem == nil {
            if scan.fileCount > FolderLimits.maxFiles {
                scan.problem = .tooManyFiles(scan.fileCount)
            } else if scan.folderCount > FolderLimits.maxFolders {
                scan.problem = .tooManyFolders(scan.folderCount)
            } else if deepest > FolderLimits.maxDepth {
                scan.problem = .tooDeep
            } else if scan.totalSize > FolderLimits.maxTotalSize {
                scan.problem = .tooBig(scan.totalSize)
            } else {
                let sized = scan.entries.map { $0.isDirectory ? $0 : ManifestEntry.file($0.path, size: $0.size ?? 0, sha256: placeholderHash, modified: $0.modified) }
                if ManifestPager.pages(folderTransferID: UUID().uuidString.lowercased(), entries: sized) == nil { scan.problem = .manifestTooLarge }
            }
        }
        return scan
    }

    private struct Candidate {
        let item: FolderScanItem
        let name: String
    }

    private static func walk(_ children: [FolderScanItem], relative: String, depth: Int, scan: inout FolderScan, deepest: inout Int,
                             listing: FolderListing, isCancelled: () -> Bool) {
        guard !isCancelled() else { return }
        // Over a limit: keep counting so the message can say how many, but stop keeping entries.
        let keeping = scan.fileCount <= FolderLimits.maxFiles && scan.folderCount <= FolderLimits.maxFolders
        var candidates: [Candidate] = []
        for item in children {
            if item.isSymbolicLink || item.isAlias {
                scan.skipped.links += 1
                continue
            }
            let kind = SystemFiles.classify(item.name, hiddenFlag: item.isHidden)
            if kind == .partial { continue }
            if !SystemFiles.included(kind, includeHidden: scan.options.includeHidden, includeSystem: scan.options.includeSystem) {
                if kind == .system { scan.skipped.system += 1 } else { scan.skipped.hidden += 1 }
                continue
            }
            if item.isDirectory {
                if item.isVolume {
                    scan.skipped.other += 1
                    continue
                }
            } else if item.isRegularFile {
                if item.notDownloaded {
                    scan.skipped.notDownloaded += 1
                    continue
                }
                if !item.readable {
                    scan.skipped.unreadable += 1
                    continue
                }
                if item.size > FolderLimits.maxFileSize {
                    scan.skipped.tooLarge += 1
                    continue
                }
            } else {
                // Sockets, pipes, devices.
                scan.skipped.other += 1
                continue
            }
            candidates.append(Candidate(item: item, name: PortableName.convert(item.name)))
        }
        let resolved = ConflictNames.resolveSiblings(candidates.map { ($0.name, $0.item.isDirectory) })
        let ordered = resolved
            .map { (candidate: candidates[$0.index], final: $0.name) }
            .sorted { FolderPaths.compareUTF8($0.final, $1.final) }
        for (candidate, final) in ordered {
            guard !isCancelled() else { return }
            let item = candidate.item
            let path = FolderPaths.join(relative, final)
            if path.utf8.count > FolderLimits.maxPathBytes {
                scan.skipped.tooLong += 1
                continue
            }
            if !final.unicodeScalars.elementsEqual(item.name.precomposedStringWithCanonicalMapping.unicodeScalars) { scan.renamed += 1 }
            let entryDepth = depth + 1
            deepest = max(deepest, entryDepth)
            if item.isDirectory {
                // Read the folder first, so an unreadable one leaves no entry behind.
                guard let grandchildren = try? listing.children(of: item.url) else {
                    scan.skipped.unreadable += 1
                    continue
                }
                scan.folderCount += 1
                if item.isPackage && scan.packages.count < 20 { scan.packages.append(item.name) }
                if keeping && entryDepth <= FolderLimits.maxDepth {
                    scan.entries.append(.dir(path))
                    scan.sources.append(item.url)
                }
                if entryDepth > FolderLimits.maxDepth + 1 { continue }
                walk(grandchildren, relative: path, depth: entryDepth, scan: &scan, deepest: &deepest, listing: listing, isCancelled: isCancelled)
            } else {
                scan.fileCount += 1
                scan.totalSize += item.size
                if keeping && entryDepth <= FolderLimits.maxDepth {
                    let modified = item.modified.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
                    scan.entries.append(ManifestEntry(type: .file, path: path, size: item.size, sha256: nil, modified: modified))
                    scan.sources.append(item.url)
                }
            }
        }
    }
}

/// Reads every file of a scan once with SHA-256 in 1 MiB reads. A file that cannot be read any more is
/// dropped from the manifest and counted as unreadable; a file whose size changed keeps what was read.
enum FolderHasher {
    static let readSize = 1024 * 1024

    static func hash(_ scan: FolderScan, progress: (Int64, Int64) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) -> FolderScan? {
        var result = scan
        var entries: [ManifestEntry] = []
        var sources: [URL] = []
        var done: Int64 = 0
        let total = max(scan.totalSize, 1)
        var totalSize: Int64 = 0
        var fileCount = 0
        for (entry, source) in zip(scan.entries, scan.sources) {
            if entry.isDirectory {
                entries.append(entry)
                sources.append(source)
                continue
            }
            guard !isCancelled() else { return nil }
            guard let handle = try? FileHandle(forReadingFrom: source) else {
                result.skipped.unreadable += 1
                done += entry.size ?? 0
                continue
            }
            var hasher = SHA256()
            var read: Int64 = 0
            var failed = false
            while true {
                guard !isCancelled() else {
                    try? handle.close()
                    return nil
                }
                let data: Data
                do {
                    // nil at the end of the file.
                    guard let chunk = try handle.read(upToCount: readSize), !chunk.isEmpty else { break }
                    data = chunk
                } catch {
                    failed = true
                    break
                }
                hasher.update(data: data)
                read += Int64(data.count)
                progress(min(done + read, total), total)
                if read > FolderLimits.maxFileSize {
                    failed = true
                    break
                }
            }
            try? handle.close()
            done += entry.size ?? 0
            if failed {
                result.skipped.unreadable += 1
                continue
            }
            entries.append(ManifestEntry.file(entry.path, size: read, sha256: Data(hasher.finalize()).base64EncodedString(), modified: entry.modified))
            sources.append(source)
            totalSize += read
            fileCount += 1
        }
        result.entries = entries
        result.sources = sources
        result.fileCount = fileCount
        result.totalSize = totalSize
        result.hashed = true
        progress(total, total)
        return result
    }
}
