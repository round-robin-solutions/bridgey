import AVFoundation
import CBlake3
import CWebP
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Before sending: makes optimised copies (resized and re-encoded images, stripped metadata, compressed
// videos, zipped folders) in a cache keyed by the original's content hash (BLAKE3) and the settings, so a
// retry or a second send of the same file does no work. Originals are never modified. Pure file work: no
// UI, safe to run off the main thread.

enum SendOptimizerError: Error, Equatable {
    case cancelled
    case unreadable
    case encodeFailed
}

/// What happened to one item.
struct OptimizedItem: Equatable {
    let source: URL
    /// What to send: the cached copy, or the source itself when nothing applied or the copy was not better.
    let output: URL
    let originalBytes: Int64
    let outputBytes: Int64

    var changed: Bool { output != source }
}

/// Stops long work (video export) from another thread.
final class OptimizerCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

enum ImageKind: Equatable {
    case photo(hasAlpha: Bool)
    /// Animated (GIF, APNG), vector, RAW or unknown: always sent as it is.
    case untouched
}

/// The video settings each preset maps to. Pure, unit tested.
struct VideoPreset: Equatable {
    let longEdge: Int
    let videoBitrate: Int
    let audioBitrate: Int

    static func preset(_ mode: SendOptimization.VideoMode) -> VideoPreset? {
        switch mode {
        case .original: nil
        case .hd1080Balanced: VideoPreset(longEdge: 1920, videoBitrate: 6_000_000, audioBitrate: 128_000)
        case .hd1080Small: VideoPreset(longEdge: 1920, videoBitrate: 3_000_000, audioBitrate: 96_000)
        case .hd720Balanced: VideoPreset(longEdge: 1280, videoBitrate: 3_000_000, audioBitrate: 128_000)
        case .hd720Small: VideoPreset(longEdge: 1280, videoBitrate: 1_500_000, audioBitrate: 96_000)
        }
    }

    /// Output size for a source of `width` x `height`: fits the long edge, never upscales, even numbers.
    func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        let scale = long > longEdge ? Double(longEdge) / Double(long) : 1
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// Worth re-encoding: the source is larger than the target or its bitrate clearly higher.
    func applies(width: Int, height: Int, sourceBitrate: Double) -> Bool {
        max(width, height) > longEdge || sourceBitrate > Double(videoBitrate) * 1.25
    }

    /// Expected output bytes for `seconds` of video, for the chip's estimate.
    func estimatedBytes(seconds: Double) -> Int64 { Int64(Double(videoBitrate + audioBitrate) / 8 * seconds) }
}

enum SendOptimizer {
    // MARK: Entry

    /// Optimises one file or folder. Returns the source untouched when nothing applies.
    static func optimize(_ url: URL, with options: SendOptimization, cache: URL = cacheDirectory(),
                         cancel: OptimizerCancel = OptimizerCancel()) async throws -> OptimizedItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        let original = Int64(values?.fileSize ?? 0)
        let untouched = OptimizedItem(source: url, output: url, originalBytes: original, outputBytes: original)
        if values?.isDirectory == true {
            guard options.folderMode == .zip else { return untouched }
            return try zipFolder(url, cache: cache, cancel: cancel)
        }
        guard let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return untouched }
        if type.conforms(to: .image), options.imageMode == .optimize || options.stripsMetadata {
            return try optimizeImage(url, type: type, options: options, cache: cache, original: original, cancel: cancel)
        }
        if type.conforms(to: .movie) || type.conforms(to: .video), options.videoMode != .original {
            return try await optimizeVideo(url, options: options, cache: cache, original: original, cancel: cancel)
        }
        return untouched
    }

    /// Whether `url` would change under `options` (cheap: type only), so a send with nothing to do skips the
    /// preparation step altogether.
    static func mightChange(_ url: URL, with options: SendOptimization) -> Bool {
        if options.isOriginal { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if values?.isDirectory == true { return options.folderMode == .zip }
        guard let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) else { return false }
        if type.conforms(to: .image) { return (options.imageMode == .optimize || options.stripsMetadata) && imageKind(type: type) != .untouched }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return options.videoMode != .original }
        return false
    }

    static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("\(Edition.supportFolderName)/SendOptimized", isDirectory: true)
    }

    /// Keeps the cache bounded: oldest entries go once it holds more than `limit` bytes.
    static func trimCache(_ cache: URL = cacheDirectory(), limit: Int64 = 2 * 1024 * 1024 * 1024) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentAccessDateKey, .totalFileAllocatedSizeKey]
        guard let entries = try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: keys) else { return }
        var sized: [(URL, Date, Int64)] = []
        for entry in entries {
            var bytes: Int64 = 0
            if let files = manager.enumerator(at: entry, includingPropertiesForKeys: keys) {
                for case let file as URL in files {
                    bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                }
            }
            let date = (try? entry.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            sized.append((entry, date, bytes))
        }
        var total = sized.reduce(0) { $0 + $1.2 }
        for (entry, _, bytes) in sized.sorted(by: { $0.1 < $1.1 }) where total > limit {
            try? manager.removeItem(at: entry)
            total -= bytes
        }
    }

    // MARK: Cache keys

    /// BLAKE3 of the file's bytes, hex.
    static func contentHash(_ url: URL, cancel: OptimizerCancel = OptimizerCancel()) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SendOptimizerError.unreadable }
        defer { try? handle.close() }
        var state = blake3_hasher()
        blake3_hasher_init(&state)
        while true {
            if cancel.isCancelled { throw SendOptimizerError.cancelled }
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { blake3_hasher_update(&state, $0.baseAddress, $0.count) }
        }
        var out = [UInt8](repeating: 0, count: Int(BLAKE3_OUT_LEN))
        blake3_hasher_finalize(&state, &out, out.count)
        return out.map { String(format: "%02x", $0) }.joined()
    }

    /// The cache folder for one source and one set of settings: content hash plus the settings that change
    /// the bytes. The same file under another name or path hits the same entry.
    static func cacheKey(contentHash: String, fingerprint: String) -> String {
        var state = blake3_hasher()
        blake3_hasher_init(&state)
        let text = Array("\(contentHash)|\(fingerprint)".utf8)
        text.withUnsafeBytes { blake3_hasher_update(&state, $0.baseAddress, $0.count) }
        var out = [UInt8](repeating: 0, count: 16)
        blake3_hasher_finalize(&state, &out, out.count)
        return out.map { String(format: "%02x", $0) }.joined()
    }

    private static func cached(_ folder: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
              let file = files.first(where: { !$0.lastPathComponent.hasPrefix(".") }) else { return nil }
        // Touch the folder so trimming keeps recently used entries.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return folder.appendingPathComponent(file.lastPathComponent)
    }

    /// Writes into the cache atomically: a temporary folder renamed into place.
    private static func store(_ data: Data, name: String, in folder: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = temporary.appendingPathComponent(name)
        guard manager.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            try? manager.removeItem(at: temporary)
            throw SendOptimizerError.encodeFailed
        }
        try? manager.removeItem(at: folder)
        try manager.moveItem(at: temporary, to: folder)
        return folder.appendingPathComponent(name)
    }

    private static func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    // MARK: Images

    static func imageKind(type: UTType, source: CGImageSource? = nil) -> ImageKind {
        if type.conforms(to: .gif) || type.conforms(to: .svg) || type.conforms(to: .rawImage) || type.identifier == "com.adobe.pdf" { return .untouched }
        if type.conforms(to: .icns) || type.conforms(to: .ico) { return .untouched }
        guard let source else { return .photo(hasAlpha: false) }
        if CGImageSourceGetCount(source) > 1 { return .untouched }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return .photo(hasAlpha: properties?[kCGImagePropertyHasAlpha] as? Bool ?? false)
    }

    private static func optimizeImage(_ url: URL, type: UTType, options: SendOptimization, cache: URL, original: Int64,
                                      cancel: OptimizerCancel) throws -> OptimizedItem {
        let untouched = OptimizedItem(source: url, output: url, originalBytes: original, outputBytes: original)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return untouched }
        guard case let .photo(hasAlpha) = imageKind(type: type, source: source) else { return untouched }
        let hash = try contentHash(url, cancel: cancel)
        let folder = cache.appendingPathComponent(cacheKey(contentHash: hash, fingerprint: options.imageFingerprint), isDirectory: true)
        if let hit = cached(folder) { return result(url, hit, original: original, options: options) }
        if cancel.isCancelled { throw SendOptimizerError.cancelled }
        let data: Data
        let ext: String
        if options.imageMode == .optimize {
            (data, ext) = try encodeResized(source, hasAlpha: hasAlpha, sourceType: type, options: options)
        } else {
            data = try stripOnly(source, type: type, options: options)
            ext = url.pathExtension
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let output = try store(data, name: ext.isEmpty ? stem : "\(stem).\(ext)", in: folder)
        return result(url, output, original: original, options: options)
    }

    /// Uses the copy when it is smaller, or when metadata had to go; otherwise the original.
    private static func result(_ source: URL, _ output: URL, original: Int64, options: SendOptimization) -> OptimizedItem {
        let bytes = size(output)
        if bytes < original || options.stripsMetadata {
            return OptimizedItem(source: source, output: output, originalBytes: original, outputBytes: bytes)
        }
        return OptimizedItem(source: source, output: source, originalBytes: original, outputBytes: original)
    }

    /// Resize (never up) and re-encode as JPEG or WebP. Images with transparency keep it: WebP, or PNG when
    /// JPEG was chosen.
    static func encodeResized(_ source: CGImageSource, hasAlpha: Bool, sourceType: UTType, options: SendOptimization) throws -> (Data, String) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = min(max(width, height), options.maxEdge)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, longEdge),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { throw SendOptimizerError.encodeFailed }
        let quality = Double(options.quality) / 100
        switch options.format {
        case .webp:
            return (try encodeWebP(image, quality: Float(options.quality), alpha: hasAlpha), "webp")
        case .jpeg where hasAlpha:
            return (try encode(image, type: .png, properties: filteredProperties(properties, options: options, oriented: true)), "png")
        case .jpeg:
            var metadata = filteredProperties(properties, options: options, oriented: true)
            metadata[kCGImageDestinationLossyCompressionQuality] = quality
            return (try encode(image, type: .jpeg, properties: metadata), "jpg")
        }
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw SendOptimizerError.encodeFailed }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SendOptimizerError.encodeFailed }
        return data as Data
    }

    /// libwebp's simple encoder; WebP output carries no metadata at all.
    static func encodeWebP(_ image: CGImage, quality: Float, alpha: Bool) throws -> Data {
        let width = image.width
        let height = image.height
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw SendOptimizerError.encodeFailed }
        if alpha { unpremultiply(&pixels) }
        var output: UnsafeMutablePointer<UInt8>?
        let count = pixels.withUnsafeBufferPointer { buffer in
            WebPEncodeRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(stride), quality, &output)
        }
        guard count > 0, let output else { throw SendOptimizerError.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: count)
    }

    private static func unpremultiply(_ pixels: inout [UInt8]) {
        var index = 0
        while index < pixels.count {
            let a = Int(pixels[index + 3])
            if a > 0 && a < 255 {
                for channel in 0..<3 { pixels[index + channel] = UInt8(min(255, Int(pixels[index + channel]) * 255 / a)) }
            }
            index += 4
        }
    }

    /// Lossless where ImageIO can (JPEG, PNG, HEIC, TIFF): the image data is copied, only metadata changes.
    static func stripOnly(_ source: CGImageSource, type: UTType, options: SendOptimization) throws -> Data {
        let data = NSMutableData()
        let outputType = (CGImageSourceGetType(source) ?? type.identifier as CFString)
        guard let destination = CGImageDestinationCreateWithData(data, outputType, 1, nil) else { throw SendOptimizerError.encodeFailed }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let mutable = CGImageMetadataCreateMutableCopy(metadata) {
            removeTags(from: mutable, options: options)
            let copyOptions: [CFString: Any] = [
                kCGImageDestinationMetadata: mutable,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: options.stripLocation,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(destination, source, copyOptions as CFDictionary, &error) {
                return data as Data
            }
        }
        // Formats ImageIO cannot copy losslessly: re-encode at high quality with filtered metadata.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SendOptimizerError.encodeFailed }
        var filtered = filteredProperties(properties, options: options, oriented: false)
        filtered[kCGImageDestinationLossyCompressionQuality] = 0.95
        let fallback = NSMutableData()
        guard let second = CGImageDestinationCreateWithData(fallback, outputType, 1, nil) else { throw SendOptimizerError.encodeFailed }
        CGImageDestinationAddImage(second, image, filtered as CFDictionary)
        guard CGImageDestinationFinalize(second) else { throw SendOptimizerError.encodeFailed }
        return fallback as Data
    }

    /// XMP and EXIF paths for each group.
    static let locationPrefixes = ["exif:GPS", "exifEX:GPS", "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location"]
    static let cameraPrefixes = ["tiff:Make", "tiff:Model", "exifEX:LensMake", "exifEX:LensModel", "exifEX:LensSerialNumber",
                                 "exifEX:BodySerialNumber", "exifEX:CameraOwnerName", "aux:", "tiff:Software", "xmp:CreatorTool"]
    static let datePrefixes = ["exif:DateTimeOriginal", "exif:DateTimeDigitized", "tiff:DateTime", "xmp:CreateDate", "xmp:ModifyDate",
                               "xmp:MetadataDate", "photoshop:DateCreated", "exif:SubsecTime", "exifEX:OffsetTime", "exif:OffsetTime"]

    private static func removeTags(from metadata: CGMutableImageMetadata, options: SendOptimization) {
        var prefixes: [String] = []
        if options.stripLocation { prefixes += locationPrefixes }
        if options.stripCamera { prefixes += cameraPrefixes }
        if options.stripDates { prefixes += datePrefixes }
        guard !prefixes.isEmpty else { return }
        var doomed: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: false] as CFDictionary) { path, _ in
            let name = path as String
            if prefixes.contains(where: { name.hasPrefix($0) }) { doomed.append(name) }
            return true
        }
        for path in doomed { CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) }
    }

    /// Properties for a re-encoded image: what the settings keep, orientation reset when pixels were rotated.
    static func filteredProperties(_ properties: [CFString: Any], options: SendOptimization, oriented: Bool) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if options.stripCamera {
                for key in [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSerialNumber,
                            kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifMakerNote] {
                    exif.removeValue(forKey: key)
                }
            }
            if options.stripDates {
                for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifSubsecTime,
                            kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifSubsecTimeDigitized,
                            kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized] {
                    exif.removeValue(forKey: key)
                }
            }
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if options.stripCamera {
                for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFHostComputer] {
                    tiff.removeValue(forKey: key)
                }
            }
            if options.stripDates { tiff.removeValue(forKey: kCGImagePropertyTIFFDateTime) }
            if oriented { tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation) }
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if !options.stripLocation, let gps = properties[kCGImagePropertyGPSDictionary] {
            result[kCGImagePropertyGPSDictionary] = gps
        }
        if !options.stripCamera, let maker = properties[kCGImagePropertyMakerAppleDictionary] {
            result[kCGImagePropertyMakerAppleDictionary] = maker
        }
        if let profile = properties[kCGImagePropertyProfileName] { result[kCGImagePropertyProfileName] = profile }
        if !oriented, let orientation = properties[kCGImagePropertyOrientation] { result[kCGImagePropertyOrientation] = orientation }
        if oriented { result[kCGImagePropertyOrientation] = 1 }
        return result
    }

    // MARK: Folders

    /// Zips through the file coordinator (the same archive Finder's Compress makes), into the cache.
    private static func zipFolder(_ url: URL, cache: URL, cancel: OptimizerCancel) throws -> OptimizedItem {
        let original = TrayStore.folderSize(url)
        // Folders change often and hashing every file would cost more than zipping: key by the tree's
        // names, sizes and dates instead.
        let signature = folderSignature(url)
        let folder = cache.appendingPathComponent(cacheKey(contentHash: signature, fingerprint: "zip1"), isDirectory: true)
        if let hit = cached(folder) {
            return OptimizedItem(source: url, output: hit, originalBytes: original, outputBytes: size(hit))
        }
        var coordinatorError: NSError?
        var thrown: Error?
        var output: URL?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                if cancel.isCancelled { throw SendOptimizerError.cancelled }
                let manager = FileManager.default
                try manager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let temporary = cache.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let target = temporary.appendingPathComponent("\(url.lastPathComponent).zip")
                try manager.copyItem(at: zipURL, to: target)
                try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                try? manager.removeItem(at: folder)
                try manager.moveItem(at: temporary, to: folder)
                output = folder.appendingPathComponent(target.lastPathComponent)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        if coordinatorError != nil { throw SendOptimizerError.unreadable }
        guard let output else { throw SendOptimizerError.encodeFailed }
        return OptimizedItem(source: url, output: output, originalBytes: original, outputBytes: size(output))
    }

    static func folderSignature(_ url: URL) -> String {
        var lines: [String] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: Set(keys))
                lines.append("\(file.path.dropFirst(url.path.count))|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        return cacheKey(contentHash: lines.sorted().joined(separator: "\n"), fingerprint: url.lastPathComponent)
    }

    // MARK: Videos

    struct VideoInfo {
        let track: AVAssetTrack
        let naturalSize: CGSize
        let transform: CGAffineTransform
        /// Displayed size (rotation applied).
        let width: Int
        let height: Int
        let bitrate: Double
        let seconds: Double
    }

    static func videoInfo(_ asset: AVAsset) async -> VideoInfo? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform, rate) = try? await track.load(.naturalSize, .preferredTransform, .estimatedDataRate),
              let duration = try? await asset.load(.duration) else { return nil }
        let shown = naturalSize.applying(transform)
        return VideoInfo(track: track, naturalSize: naturalSize, transform: transform, width: Int(abs(shown.width).rounded()),
                         height: Int(abs(shown.height).rounded()), bitrate: Double(rate), seconds: duration.seconds)
    }

    private static func optimizeVideo(_ url: URL, options: SendOptimization, cache: URL, original: Int64,
                                      cancel: OptimizerCancel) async throws -> OptimizedItem {
        let untouched = OptimizedItem(source: url, output: url, originalBytes: original, outputBytes: original)
        guard let preset = VideoPreset.preset(options.videoMode) else { return untouched }
        let asset = AVURLAsset(url: url)
        guard let info = await videoInfo(asset) else { return untouched }
        let width = info.width
        let height = info.height
        guard width > 0, height > 0, preset.applies(width: width, height: height, sourceBitrate: info.bitrate) else { return untouched }
        let hash = try contentHash(url, cancel: cancel)
        let folder = cache.appendingPathComponent(cacheKey(contentHash: hash, fingerprint: options.videoFingerprint), isDirectory: true)
        if let hit = cached(folder) { return result(url, hit, original: original, options: SendOptimization.original) }
        let manager = FileManager.default
        try manager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = cache.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = temporary.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).mp4")
        do {
            try await VideoTranscoder.transcode(asset: asset, info: info, to: target, preset: preset, cancel: cancel)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try? manager.removeItem(at: folder)
        try manager.moveItem(at: temporary, to: folder)
        return result(url, folder.appendingPathComponent(target.lastPathComponent), original: original, options: SendOptimization.original)
    }

    /// The chip's estimate for one item without doing the work (images: nil, they are fast enough to make).
    static func estimatedVideoBytes(_ url: URL, options: SendOptimization) async -> Int64? {
        guard let preset = VideoPreset.preset(options.videoMode), let info = await videoInfo(AVURLAsset(url: url)),
              preset.applies(width: info.width, height: info.height, sourceBitrate: info.bitrate) else { return nil }
        return preset.estimatedBytes(seconds: info.seconds)
    }
}

/// HEVC with the hardware encoder (H.264 when HEVC cannot be written), AAC audio, MP4 container.
enum VideoTranscoder {
    static func transcode(asset: AVAsset, info: SendOptimizer.VideoInfo, to target: URL, preset: VideoPreset, cancel: OptimizerCancel) async throws {
        let videoTrack = info.track
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
        let natural = info.naturalSize
        let size = preset.outputSize(width: Int(abs(natural.width)), height: Int(abs(natural.height)))
        let readerVideo = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        readerVideo.alwaysCopiesSampleData = false
        guard reader.canAdd(readerVideo) else { throw SendOptimizerError.unreadable }
        reader.add(readerVideo)
        let codec: AVVideoCodecType = writer.canApply(outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: size.width,
                                                                       AVVideoHeightKey: size.height], forMediaType: .video) ? .hevc : .h264
        let writerVideo = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: preset.videoBitrate],
        ])
        writerVideo.transform = info.transform
        writerVideo.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerVideo) else { throw SendOptimizerError.encodeFailed }
        writer.add(writerVideo)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(readerVideo, writerVideo)]
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let readerAudio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let writerAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100, AVEncoderBitRateKey: preset.audioBitrate,
            ])
            writerAudio.expectsMediaDataInRealTime = false
            if reader.canAdd(readerAudio), writer.canAdd(writerAudio) {
                reader.add(readerAudio)
                writer.add(writerAudio)
                pairs.append((readerAudio, writerAudio))
            }
        }
        guard reader.startReading(), writer.startWriting() else { throw SendOptimizerError.encodeFailed }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        for (index, (output, input)) in pairs.enumerated() {
            group.enter()
            let pump = SamplePump(reader: reader, output: output, input: input, cancel: cancel) { group.leave() }
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "bridgey.optimize.video.\(index)")) { pump.run() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        if cancel.isCancelled || reader.status == .failed || reader.status == .cancelled {
            writer.cancelWriting()
            throw cancel.isCancelled ? SendOptimizerError.cancelled : SendOptimizerError.encodeFailed
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw SendOptimizerError.encodeFailed }
    }
}

/// Moves samples from a reader output to a writer input on the input's own queue (AVFoundation's objects
/// are used from that one queue only).
private final class SamplePump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let cancel: OptimizerCancel
    private let done: () -> Void
    private var finished = false

    init(reader: AVAssetReader, output: AVAssetReaderOutput, input: AVAssetWriterInput, cancel: OptimizerCancel, done: @escaping () -> Void) {
        self.reader = reader
        self.output = output
        self.input = input
        self.cancel = cancel
        self.done = done
    }

    func run() {
        while input.isReadyForMoreMediaData && !finished {
            if cancel.isCancelled { reader.cancelReading() }
            if let sample = output.copyNextSampleBuffer(), !cancel.isCancelled {
                if !input.append(sample) { reader.cancelReading() }
            } else {
                finished = true
                input.markAsFinished()
                done()
            }
        }
    }
}
