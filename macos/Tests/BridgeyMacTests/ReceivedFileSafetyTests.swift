import AppKit
import CoreServices
import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

/// Single files from a phone: their names, where they land, the quarantine mark, how many may
/// arrive at once, which phone may drive a transfer, and images that claim a huge canvas.
final class ReceivedFileSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("received-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Bridgey", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // MARK: Names

    func testNamesThatPointOutsideTheFolderBecomePlainNames() {
        XCTAssertEqual(receivedFileName(".."), "file")
        XCTAssertEqual(receivedFileName("."), "file")
        XCTAssertEqual(receivedFileName("a/.."), "file")
        XCTAssertEqual(receivedFileName("../x"), "x")
        XCTAssertEqual(receivedFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(receivedFileName("/"), "file")
        XCTAssertEqual(receivedFileName("   "), "file")
        XCTAssertEqual(receivedFileName("report:final.pdf"), "report_final.pdf")
        XCTAssertEqual(receivedFileName("photo.jpg"), "photo.jpg")
    }

    func testControlAndDirectionCharactersAreDropped() {
        XCTAssertEqual(receivedFileName("a\u{0}b.txt"), "ab.txt")
        XCTAssertEqual(receivedFileName("line\nbreak\t.txt"), "linebreak.txt")
        XCTAssertEqual(receivedFileName("invoice\u{202E}fdp.exe"), "invoicefdp.exe")
        XCTAssertEqual(receivedFileName("\u{2066}a\u{2069}\u{200E}\u{200F}.png"), "a.png")
        XCTAssertEqual(receivedFileName("\u{202E}.."), "file", "what is left after dropping is checked again")
        XCTAssertEqual(receivedFileName("\u{0}"), "file")
    }

    func testLongNamesAreCutToTheByteLimitKeepingTheExtension() {
        let ascii = receivedFileName(String(repeating: "a", count: 300) + ".pdf")
        XCTAssertLessThanOrEqual(ascii.utf8.count, maximumReceivedNameBytes)
        XCTAssertTrue(ascii.hasSuffix(".pdf"))
        let accented = receivedFileName(String(repeating: "\u{e9}", count: 200) + ".jpeg")
        XCTAssertLessThanOrEqual(accented.utf8.count, maximumReceivedNameBytes)
        XCTAssertTrue(accented.hasSuffix(".jpeg"))
        XCTAssertTrue(accented.hasPrefix("\u{e9}"))
        // The partial file and a numbered copy still fit in 255 bytes.
        XCTAssertLessThanOrEqual((ascii + " 10000.bridgey-part").utf8.count, 255)
        XCTAssertEqual(receivedFileName(String(repeating: "b", count: 300)).utf8.count, maximumReceivedNameBytes)
    }

    // MARK: Where files land

    func testOnlyNamesDirectlyInTheFolderAreContained() {
        XCTAssertTrue(receivedFileIsContained(directory.appendingPathComponent("x.txt"), in: directory))
        XCTAssertTrue(receivedFileIsContained(directory.appendingPathComponent("x.txt"), in: URL(fileURLWithPath: directory.path + "/")))
        XCTAssertFalse(receivedFileIsContained(directory.appendingPathComponent(".."), in: directory))
        XCTAssertFalse(receivedFileIsContained(directory.appendingPathComponent("../x"), in: directory))
        XCTAssertFalse(receivedFileIsContained(directory.appendingPathComponent("a/b"), in: directory))
        XCTAssertFalse(receivedFileIsContained(uniqueReceivedFileURL(directory.appendingPathComponent("..")), in: directory))
    }

    func testAFileNamedDotDotIsSavedInsideTheFolderAndQuarantined() throws {
        let data = Data("hello".utf8)
        let offer = FileOfferPayload(transferId: UUID().uuidString.lowercased(), name: "..", mimeType: "text/plain", size: Int64(data.count),
                                     sha256: Data(SHA256.hash(data: data)).base64EncodedString())
        let transfer = try IncomingFileTransfer(offer: offer, directoryAccess: ReceiveDirectoryAccess(url: directory, scoped: false))
        try transfer.append(data, sequence: 0)
        let saved = try transfer.finish(expectedHash: offer.sha256)
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertEqual(saved.lastPathComponent, "file")
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertTrue(FinderMetadata.isQuarantined(saved))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path), ["Bridgey"],
                       "nothing was written beside the receive folder")
    }

    func testQuarantineMarksFilesAndFolders() throws {
        let file = directory.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        XCTAssertFalse(FinderMetadata.isQuarantined(file))
        XCTAssertTrue(FinderMetadata.quarantine(file))
        XCTAssertTrue(FinderMetadata.isQuarantined(file))
        let properties = try XCTUnwrap(try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeOtherDownload as String)
        XCTAssertNotNil(properties[kLSQuarantineAgentNameKey as String])
        XCTAssertTrue(FinderMetadata.quarantine(directory))
        XCTAssertTrue(FinderMetadata.isQuarantined(directory))
    }

    // MARK: Admission

    func testAtMostFourFilesPerPhoneAndEightInAll() {
        XCTAssertEqual(incomingFileAdmission(size: 10, phoneActive: 3, totalActive: 7, freeBytes: nil, reservedBytes: 0), .accept)
        XCTAssertEqual(incomingFileAdmission(size: 10, phoneActive: 4, totalActive: 4, freeBytes: nil, reservedBytes: 0), .busy)
        XCTAssertEqual(incomingFileAdmission(size: 10, phoneActive: 0, totalActive: 8, freeBytes: nil, reservedBytes: 0), .busy)
    }

    func testFreeSpaceCountsWhatRunningFilesStillWrite() {
        let margin = IncomingFileLimits.spaceMargin
        XCTAssertEqual(incomingFileAdmission(size: 100, phoneActive: 0, totalActive: 0, freeBytes: margin + 100, reservedBytes: 0), .accept)
        XCTAssertEqual(incomingFileAdmission(size: 101, phoneActive: 0, totalActive: 0, freeBytes: margin + 100, reservedBytes: 0), .noSpace)
        XCTAssertEqual(incomingFileAdmission(size: 100, phoneActive: 1, totalActive: 1, freeBytes: margin + 100, reservedBytes: 1), .noSpace)
        XCTAssertEqual(incomingFileAdmission(size: 0, phoneActive: 0, totalActive: 0, freeBytes: 0, reservedBytes: 0), .noSpace, "the margin stays free")
    }

    // MARK: Ownership

    func testTransferFramesCountOnlyFromTheOwningPhone() {
        XCTAssertTrue(transferBelongs(owner: "phone-a", to: "phone-a"))
        XCTAssertFalse(transferBelongs(owner: "phone-a", to: "phone-b"))
        XCTAssertFalse(transferBelongs(owner: nil, to: "phone-a"))
    }

    // MARK: Images

    @MainActor func testImagesAboveOneHundredMegapixelsAreNotDecoded() throws {
        let small = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        XCTAssertTrue(imageDataFitsPixelLimit(small))
        XCTAssertNotNil(ClipboardInbox.pngData(from: small))
        let huge = pngHeader(width: 20_000, height: 20_000)
        XCTAssertFalse(imageDataFitsPixelLimit(huge))
        XCTAssertNil(ClipboardInbox.pngData(from: huge))
        XCTAssertNil(PhoneThumbnailCache.decode(huge, maxPixel: 256))
        let file = directory.appendingPathComponent("huge.png")
        try huge.write(to: file)
        XCTAssertFalse(imageFileFitsPixelLimit(file))
        XCTAssertFalse(imageDataFitsPixelLimit(Data("not an image".utf8)))
    }

    /// A PNG signature and header chunk claiming `width` x `height`, with no pixel data.
    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: Data) {
            var length = UInt32(body.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            let typed = Data(type.utf8) + body
            data.append(typed)
            var crc = crc32(typed).bigEndian
            data.append(Data(bytes: &crc, count: 4))
        }
        var header = Data()
        for value in [width, height] {
            var big = value.bigEndian
            header.append(Data(bytes: &big, count: 4))
        }
        header.append(contentsOf: [8, 6, 0, 0, 0])
        chunk("IHDR", header)
        chunk("IEND", Data())
        return data
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
