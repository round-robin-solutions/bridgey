import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The Photos and Videos grid keeps a clean square grid whatever shape the thumbnails are: tall phone
/// screenshots (1080 x 2412), landscape photos and videos are cropped into their square cells, never
/// stretching a row or spilling into the gutters.
@MainActor
final class PhoneMediaGridLayoutTests: XCTestCase {
    private let phone = UIFakeImages.phoneID
    private let now = UIFakeImages.base

    /// 3 columns of exactly 120 pt: 16 + 120 + 4 + 120 + 4 + 120 + 16.
    private let width: CGFloat = 400
    private let cell: CGFloat = 120

    private func entries(_ count: Int) -> [PhoneFileEntry] {
        (0..<count).map { index in
            PhoneFileEntry(ref: .media(id: String(20_000 + index)), name: "Screenshot_\(index).png", isDirectory: false, size: 900_000,
                           modified: now.addingTimeInterval(-Double(index) * 60), mimeType: "image/png", hasThumbnail: true,
                           width: 1080, height: 2412)
        }
    }

    private func solid(width: Int, height: Int) -> PhoneDecodedImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return PhoneDecodedImage(image: context.makeImage()!, tint: nil)
    }

    /// The grid alone (no window chrome, transparent around the cells) at scale 1.
    private func render(thumbnail: (Int) -> PhoneDecodedImage, count: Int = 6) throws -> CGImage {
        let list = entries(count)
        let model = PhoneFilesModel(service: UIFakePhoneFiles(), cache: PhoneThumbnailCache(directory: nil),
                                    defaults: UserDefaults(suiteName: UUID().uuidString)!, listingCache: PhoneListingCache(directory: nil))
        model.setForTesting(phones: [BrowsablePhone(id: phone, name: "OnePlus 11 5G", browsable: true, route: .lan)], phoneID: phone,
                            info: PhoneBrowseInfo(places: [], writable: false, media: .full, documents: false),
                            section: .media, listings: [.media: PhoneListing(entries: list, loaded: true)])
        for (index, entry) in list.enumerated() { model.thumbnails.box(for: entry).setForTesting(thumbnail(index)) }
        let view = BrandRoot(reduceMotion: true) {
            PhoneMediaGrid(model: model, promises: PhoneFilePromises(model: nil), quickLook: { _ in }, showInFinder: { _ in }, now: now)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
        }
        let renderer = ImageRenderer(content: view.environment(\.snapshotRendering, true).environment(\.locale, Locale(identifier: "en_GB")))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    /// Alpha of the pixel at (x, y), y down from the top.
    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let bytes = pixels(image)
        return bytes[(y * image.width + x) * 4 + 3]
    }

    private var pixelCache: [ObjectIdentifier: [UInt8]] = [:]

    private func pixels(_ image: CGImage) -> [UInt8] {
        if let hit = pixelCache[ObjectIdentifier(image)] { return hit }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        pixelCache[ObjectIdentifier(image)] = bytes
        return bytes
    }

    /// Rows painted by cells: any opaque pixel down the middle of the first column.
    private func cellRows(_ image: CGImage) -> [Int] {
        (0..<image.height).filter { alpha(image, x: 16 + Int(cell / 2), y: $0) > 200 }
    }

    func testTallScreenshotThumbnailsKeepSquareCells() throws {
        // What a phone sends for a 1080 x 2412 screenshot asked at 256 px: 115 x 256.
        let tall = try render { _ in self.solid(width: 115, height: 256) }
        let square = try render { _ in self.solid(width: 256, height: 256) }
        XCTAssertEqual(tall.height, square.height, "tall thumbnails must not make rows taller than square ones")
        let rows = cellRows(tall)
        XCTAssertEqual(rows.count, Int(cell) * 2, "two rows of 120 pt square cells")
    }

    func testLandscapeAndTallThumbnailsStayInsideTheirCells() throws {
        let image = try render { index in
            switch index % 3 {
            case 0: return self.solid(width: 256, height: 144) // a 16:9 video frame
            case 1: return self.solid(width: 115, height: 256) // a phone screenshot
            default: return self.solid(width: 256, height: 192) // a 4:3 photo
            }
        }
        let rows = cellRows(image)
        XCTAssertFalse(rows.isEmpty)
        // The gutters between columns and the margins beside the grid stay empty on every row of cells.
        let gutters = [8, 16 + 120 + 2, 16 + 244 + 2, 16 + 368 + 8]
        for x in gutters {
            let painted = rows.filter { alpha(image, x: x, y: $0) != 0 }
            XCTAssertTrue(painted.isEmpty, "thumbnails spill into the gutter at x \(x) on \(painted.count) rows")
        }
    }

    // MARK: Thumbnail sizes

    private func entry(width: Int?, height: Int?) -> PhoneFileEntry {
        PhoneFileEntry(ref: .media(id: "1"), name: "a", isDirectory: false, size: 1, modified: nil, mimeType: "image/jpeg",
                       hasThumbnail: true, width: width, height: height)
    }

    /// The short edge of the thumbnail the phone makes (it scales by the longest edge, never up).
    private func shortEdge(_ width: Int, _ height: Int) -> Int {
        let size = PhoneThumbnailScheduler.size(for: entry(width: width, height: height))
        let scale = min(1, Double(size) / Double(max(width, height)))
        return Int((Double(min(width, height)) * scale).rounded())
    }

    func testThumbnailsAreAskedLargeEnoughToCoverASquareCell() {
        // The widest cell is 142 pt, 284 px on Retina.
        XCTAssertEqual(PhoneThumbnailScheduler.cellPixels, 284)
        XCTAssertGreaterThanOrEqual(shortEdge(3000, 3000), 284)
        XCTAssertGreaterThanOrEqual(shortEdge(4000, 3000), 284)
        XCTAssertGreaterThanOrEqual(shortEdge(3000, 4000), 284)
        XCTAssertGreaterThanOrEqual(shortEdge(6000, 4000), 284)
        XCTAssertGreaterThanOrEqual(shortEdge(1920, 1080), 284)
        XCTAssertGreaterThanOrEqual(shortEdge(1080, 1920), 284)
        // A 1080 x 2412 screenshot is capped by the protocol's 512 px: 229 px across, twice the old 115.
        XCTAssertEqual(shortEdge(1080, 2412), 229)
        XCTAssertEqual(PhoneThumbnailScheduler.size(for: entry(width: 3000, height: 3000)), 288)
        XCTAssertEqual(PhoneThumbnailScheduler.size(for: entry(width: 4000, height: 3000)), 384)
        XCTAssertEqual(PhoneThumbnailScheduler.size(for: entry(width: 1080, height: 2412)), 512)
        XCTAssertEqual(PhoneThumbnailScheduler.size(for: entry(width: nil, height: nil)), 512)
        XCTAssertEqual(PhoneThumbnailScheduler.size(for: entry(width: 0, height: 100)), 512)
    }
}
