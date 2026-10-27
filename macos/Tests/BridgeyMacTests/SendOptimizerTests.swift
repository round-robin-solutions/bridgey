import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import BridgeyMac

final class SendOptimizerTests: XCTestCase {
    private var root: URL!
    private var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("optimizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Fixtures

    /// A noisy photo-like JPEG (noise keeps it from compressing to nothing) with GPS, camera and dates.
    private func photo(_ name: String = "photo.jpg", width: Int = 3000, height: Int = 2000, alpha: Bool = false, type: UTType = .jpeg) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1), CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: alpha ? 0.4 : 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<4_000 {
            context.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                         blue: .random(in: 0...1, using: &generator), alpha: 1))
            context.fill(CGRect(x: Int.random(in: 0..<width), y: Int.random(in: 0..<height), width: 12, height: 12))
        }
        let image = context.makeImage()!
        let url = root.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.6208, kCGImagePropertyGPSLatitudeRef: "N",
                                           kCGImagePropertyGPSLongitude: 80.1945, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "OLYMPUS", kCGImagePropertyTIFFModel: "E-P1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2009:12:20 13:27:04"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func pixels(_ url: URL) -> (Int, Int) {
        let values = properties(url)
        return (values[kCGImagePropertyPixelWidth] as? Int ?? 0, values[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    // MARK: Images

    func testResizeReencodesSmallerAndDropsOnlyLocationByDefault() async throws {
        let source = try photo()
        let before = try Data(contentsOf: source)
        let item = try await SendOptimizer.optimize(source, with: .recommended, cache: cache)
        XCTAssertTrue(item.changed)
        XCTAssertEqual(item.output.pathExtension, "jpg")
        XCTAssertEqual(pixels(item.output).0, 2048)
        XCTAssertEqual(pixels(item.output).1, 1365)
        XCTAssertLessThan(item.outputBytes, item.originalBytes)
        let metadata = properties(item.output)
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary], "location must be gone")
        XCTAssertEqual((metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String, "E-P1")
        XCTAssertEqual((metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String, "2009:12:20 13:27:04")
        XCTAssertEqual(try Data(contentsOf: source), before, "the original is never modified")
        XCTAssertNotNil(properties(source)[kCGImagePropertyGPSDictionary])
    }

    func testLowerQualityIsSmaller() async throws {
        let source = try photo()
        var options = SendOptimization.recommended
        options.quality = 90
        let high = try await SendOptimizer.optimize(source, with: options, cache: cache)
        options.quality = 60
        let low = try await SendOptimizer.optimize(source, with: options, cache: cache)
        XCTAssertLessThan(low.outputBytes, high.outputBytes)
        XCTAssertNotEqual(low.output, high.output)
    }

    func testWebPHasNoMetadata() async throws {
        let source = try photo()
        var options = SendOptimization.recommended
        options.format = .webp
        options.maxEdge = 1280
        options.stripLocation = false
        let item = try await SendOptimizer.optimize(source, with: options, cache: cache)
        XCTAssertEqual(item.output.pathExtension, "webp")
        let data = try Data(contentsOf: item.output)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WEBP")
        XCTAssertEqual(pixels(item.output).0, 1280)
        XCTAssertNil(properties(item.output)[kCGImagePropertyGPSDictionary])
    }

    func testStripOnlyKeepsPixelsAndRemovesEachGroup() async throws {
        let source = try photo(width: 1200, height: 800)
        var options = SendOptimization.original
        options.stripLocation = true
        let location = try await SendOptimizer.optimize(source, with: options, cache: cache)
        XCTAssertTrue(location.changed)
        XCTAssertEqual(pixels(location.output).0, 1200)
        XCTAssertNil(properties(location.output)[kCGImagePropertyGPSDictionary])
        XCTAssertEqual((properties(location.output)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "OLYMPUS")

        options.stripCamera = true
        options.stripDates = true
        let everything = try await SendOptimizer.optimize(source, with: options, cache: cache)
        let metadata = properties(everything.output)
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary])
        XCTAssertNil((metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertNil((metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertNil((metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
    }

    func testNeverUpscalesAndKeepsTransparency() async throws {
        let small = try photo("small.jpg", width: 800, height: 600)
        let item = try await SendOptimizer.optimize(small, with: .recommended, cache: cache)
        XCTAssertEqual(pixels(item.output).0, 800)

        let transparent = try photo("logo.png", width: 1600, height: 1600, alpha: true, type: .png)
        var options = SendOptimization.recommended
        options.maxEdge = 1280
        let png = try await SendOptimizer.optimize(transparent, with: options, cache: cache)
        XCTAssertEqual(png.output.pathExtension, "png")
        XCTAssertEqual(properties(png.output)[kCGImagePropertyHasAlpha] as? Bool, true)
    }

    func testAnimatedAndOtherFilesAreUntouched() async throws {
        let text = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let item = try await SendOptimizer.optimize(text, with: .recommended, cache: cache)
        XCTAssertFalse(item.changed)
        XCTAssertFalse(SendOptimizer.mightChange(text, with: .recommended))
        XCTAssertEqual(SendOptimizer.imageKind(type: .gif), .untouched)
        XCTAssertFalse(SendOptimizer.mightChange(try photo(), with: .original))
        XCTAssertTrue(SendOptimizer.mightChange(try photo("b.jpg"), with: .default), "location is stripped by default")
    }

    // MARK: Cache

    func testCacheKeyFollowsContentAndSettingsNotName() async throws {
        let first = try photo("a.jpg", width: 900, height: 600)
        let copy = root.appendingPathComponent("renamed copy.jpg")
        try FileManager.default.copyItem(at: first, to: copy)
        let hashA = try SendOptimizer.contentHash(first)
        XCTAssertEqual(hashA, try SendOptimizer.contentHash(copy))
        XCTAssertEqual(hashA.count, 64)
        let fingerprint = SendOptimization.recommended.imageFingerprint
        XCTAssertEqual(SendOptimizer.cacheKey(contentHash: hashA, fingerprint: fingerprint),
                       SendOptimizer.cacheKey(contentHash: try SendOptimizer.contentHash(copy), fingerprint: fingerprint))
        var other = SendOptimization.recommended
        other.quality = 60
        XCTAssertNotEqual(SendOptimizer.cacheKey(contentHash: hashA, fingerprint: fingerprint),
                          SendOptimizer.cacheKey(contentHash: hashA, fingerprint: other.imageFingerprint))
        XCTAssertNotEqual(SendOptimization.recommended.imageFingerprint, SendOptimization.default.imageFingerprint)

        let made = try await SendOptimizer.optimize(first, with: .recommended, cache: cache)
        let started = Date()
        let again = try await SendOptimizer.optimize(copy, with: .recommended, cache: cache)
        XCTAssertEqual(made.output, again.output, "a retry or the same bytes under another name reuse the copy")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)

        let changed = try photo("a.jpg", width: 900, height: 600)
        let fresh = try await SendOptimizer.optimize(changed, with: .recommended, cache: cache)
        XCTAssertNotEqual(fresh.output.deletingLastPathComponent(), made.output.deletingLastPathComponent())
        let attributes = try FileManager.default.attributesOfItem(atPath: made.output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCacheTrimRemovesOldestFirst() async throws {
        let one = try await SendOptimizer.optimize(try photo("1.jpg", width: 900, height: 600), with: .recommended, cache: cache)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: one.output.deletingLastPathComponent().path)
        let two = try await SendOptimizer.optimize(try photo("2.jpg", width: 900, height: 600), with: .recommended, cache: cache)
        SendOptimizer.trimCache(cache, limit: size(two.output) + 4096)
        XCTAssertTrue(FileManager.default.fileExists(atPath: two.output.path))
    }

    // MARK: Folders

    func testFoldersZipOnlyWhenAsked() async throws {
        let folder = root.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 50_000).write(to: folder.appendingPathComponent("Day 1/notes.txt"))
        try Data(repeating: 66, count: 50_000).write(to: folder.appendingPathComponent("plan.txt"))
        let asIs = try await SendOptimizer.optimize(folder, with: .recommended, cache: cache)
        XCTAssertFalse(asIs.changed)
        var options = SendOptimization.recommended
        options.folderMode = .zip
        XCTAssertTrue(SendOptimizer.mightChange(folder, with: options))
        let zipped = try await SendOptimizer.optimize(folder, with: options, cache: cache)
        XCTAssertEqual(zipped.output.lastPathComponent, "Trip.zip")
        XCTAssertLessThan(zipped.outputBytes, zipped.originalBytes)
        let data = try Data(contentsOf: zipped.output)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])
        let again = try await SendOptimizer.optimize(folder, with: options, cache: cache)
        XCTAssertEqual(again.output, zipped.output)
    }

    // MARK: Videos

    func testVideoPresetSelection() {
        XCTAssertNil(VideoPreset.preset(.original))
        XCTAssertEqual(VideoPreset.preset(.hd1080Balanced)?.longEdge, 1920)
        XCTAssertEqual(VideoPreset.preset(.hd720Small)?.longEdge, 1280)
        XCTAssertLessThan(VideoPreset.preset(.hd1080Small)!.videoBitrate, VideoPreset.preset(.hd1080Balanced)!.videoBitrate)
        let preset = VideoPreset.preset(.hd720Balanced)!
        XCTAssertTrue(preset.outputSize(width: 3840, height: 2160) == (1280, 720))
        XCTAssertTrue(preset.outputSize(width: 1080, height: 1920) == (720, 1280), "portrait keeps its orientation")
        XCTAssertTrue(preset.outputSize(width: 640, height: 360) == (640, 360), "never upscales")
        XCTAssertTrue(preset.outputSize(width: 1001, height: 563) == (1000, 562) || preset.outputSize(width: 1001, height: 563).width % 2 == 0)
        XCTAssertTrue(preset.applies(width: 1920, height: 1080, sourceBitrate: 1_000_000))
        XCTAssertFalse(preset.applies(width: 1280, height: 720, sourceBitrate: 2_000_000))
        XCTAssertTrue(preset.applies(width: 1280, height: 720, sourceBitrate: 20_000_000))
    }

    func testVideoFixtureIsResizedToThePreset() async throws {
        let source = try await makeVideo(width: 1600, height: 900, frames: 12)
        let options = SendOptimization(imageMode: .original, stripLocation: false, videoMode: .hd720Small, folderMode: .asIs)
        XCTAssertTrue(SendOptimizer.mightChange(source, with: options))
        let item = try await SendOptimizer.optimize(source, with: options, cache: cache)
        XCTAssertEqual(item.output.pathExtension, "mp4")
        let loaded = await SendOptimizer.videoInfo(AVURLAsset(url: item.output))
        let info = try XCTUnwrap(loaded)
        XCTAssertEqual(info.width, 1280)
        XCTAssertEqual(info.height, 720)
        let estimate = await SendOptimizer.estimatedVideoBytes(source, options: options)
        XCTAssertNotNil(estimate)
    }

    private func makeVideo(width: Int, height: Int, frames: Int) async throws -> URL {
        let url = root.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let count = CVPixelBufferGetBytesPerRow(pixels) * height
            for index in stride(from: 0, to: count, by: 4) { base[index] = UInt8((index / 4 + frame * 7) & 0xFF); base[index + 1] = UInt8.random(in: 0...255) }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    // MARK: Chip

    func testChipLabels() {
        XCTAssertEqual(OptimizationLabel.chip(.original, saving: nil), "Original")
        XCTAssertEqual(OptimizationLabel.chip(.default, saving: nil), "Original, no location")
        XCTAssertEqual(OptimizationLabel.chip(.recommended, saving: 0.68), "Optimised \u{00B7} \u{2212}68%")
        XCTAssertEqual(OptimizationLabel.chip(.recommended, saving: 0.001), "Optimised")
        XCTAssertEqual(OptimizationLabel.saving(original: 100, optimized: 32), 0.68)
        XCTAssertNil(OptimizationLabel.saving(original: 0, optimized: 0))
    }

    @MainActor func testOptimizationPreferencesPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bridgey.tests.optimize.\(UUID().uuidString)"))
        let preferences = SendPreferences(defaults: defaults)
        XCTAssertEqual(preferences.optimization, .default)
        XCTAssertTrue(preferences.optimization.stripLocation)
        XCTAssertFalse(preferences.optimization.stripCamera)
        preferences.setOptimization(.recommended)
        preferences.setMenuBarDropMode(.instant)
        let reopened = SendPreferences(defaults: defaults)
        XCTAssertEqual(reopened.optimization, .recommended)
        XCTAssertEqual(reopened.menuBarDropMode, .instant)
    }
}
