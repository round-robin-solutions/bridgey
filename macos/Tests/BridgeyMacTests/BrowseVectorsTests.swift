import Foundation
import XCTest
@testable import BridgeyMac

/// protocol/test-vectors/browse-v1.json (generator protocol/tools/browse_vectors.py): the browse answers this Mac reads
/// from the phone, and the requests it writes (media.list, media.cancel). Android checks the same file from the other side.
@MainActor
final class BrowseVectorsTests: XCTestCase {
    private static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../protocol/test-vectors/browse-v1.json")

    private func cases(_ group: String) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.file)) as? [String: Any])
        let list = try XCTUnwrap(root[group] as? [[String: Any]], group)
        XCTAssertFalse(list.isEmpty, group)
        return list
    }

    /// The cases the Mac writes exactly.
    private func written(_ group: String) throws -> [[String: Any]] {
        let list = try cases(group).filter { $0["write"] as? Bool == true }
        XCTAssertFalse(list.isEmpty, group)
        return list
    }

    private static func data(_ object: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(object))
    }

    private static func same(_ a: Any, _ b: Any?) -> Bool {
        guard let b else { return false }
        return NSArray(array: [a]).isEqual(to: [b])
    }

    private static func rejects(_ vector: [String: Any]) -> Bool { vector["expect"] as? String == "reject" }

    private static func name(_ vector: [String: Any]) -> String { vector["name"] as? String ?? "?" }

    /// A value for a JSON comparison: nil is JSON null.
    private static func json(_ value: Any?) -> Any { value ?? NSNull() }

    /// A tint (0xRRGGBB) as the vectors write it: a number, or null.
    private static func tintJSON(_ tint: UInt32?) -> Any { tint.map { Int($0) } ?? NSNull() }

    // MARK: What this Mac reads from the phone

    func testPlacesFilesPage() throws {
        for vector in try cases("placesFilesPage") {
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let placeId = p["placeId"] as? String ?? ""
            let path = p["path"] as? String ?? ""
            let page = PlacesFilesPagePayload.page(from: try Self.data(p), placeId: placeId, path: path)
            if Self.rejects(vector) {
                XCTAssertNil(page, Self.name(vector))
                continue
            }
            let decoded = try XCTUnwrap(page, Self.name(vector))
            for entry in decoded.entries {
                XCTAssertEqual(entry.ref, .place(placeId: placeId, path: path, name: entry.name), Self.name(vector))
            }
            let entries: [[String: Any]] = decoded.entries.map { entry -> [String: Any] in
                ["name": entry.name, "dir": entry.isDirectory, "size": Self.json(entry.size), "modified": Self.json(entry.modified.map(BrowseTime.millis)),
                 "mimeType": Self.json(entry.mimeType), "thumb": entry.hasThumbnail]
            }
            let object: [String: Any] = ["entries": entries, "folderCount": decoded.folderCount, "fileCount": decoded.fileCount,
                                         "nextCursor": Self.json(decoded.nextCursor), "writable": decoded.writable]
            XCTAssertTrue(Self.same(object, vector["expect"]), Self.name(vector))
        }
    }

    func testPlacesDownloadStarted() throws {
        for vector in try cases("placesDownloadStarted") {
            let started = PlacesDownloadStartedPayload.parse(try Self.data(vector["plaintext"]))
            if Self.rejects(vector) {
                XCTAssertNil(started, Self.name(vector))
                continue
            }
            let decoded = try XCTUnwrap(started, Self.name(vector))
            let object: [String: Any] = ["folderTransferId": decoded.folderTransferId, "rootName": decoded.rootName, "fileCount": decoded.fileCount,
                                         "folderCount": decoded.folderCount, "totalSize": decoded.totalSize]
            XCTAssertTrue(Self.same(object, vector["expect"]), Self.name(vector))
        }
    }

    /// Thumbnails this Mac cannot use count as missing, in order, before the keys the phone listed as missing.
    func testMediaThumbnailsBatch() throws {
        for vector in try cases("mediaThumbnailsBatch") {
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let batch = MediaThumbnailsBatchPayload.parse(try Self.data(p))
            if Self.rejects(vector) {
                XCTAssertNil(batch, Self.name(vector))
                continue
            }
            let decoded = try XCTUnwrap(batch, Self.name(vector))
            var thumbs: [[String: Any]] = []
            var missing: [String] = []
            for thumb in decoded.thumbs {
                guard let image = thumb.image else {
                    missing.append(thumb.key)
                    continue
                }
                XCTAssertEqual(image.data.base64EncodedString(), thumb.data, Self.name(vector))
                thumbs.append(["key": thumb.key, "mimeType": image.mimeType, "width": image.width, "height": image.height, "tint": Self.tintJSON(image.tint)])
            }
            missing += decoded.missing ?? []
            let object: [String: Any] = ["thumbs": thumbs, "missing": missing, "done": decoded.done]
            XCTAssertTrue(Self.same(object, vector["expect"]), Self.name(vector))
        }
    }

    func testMediaPreviewPart() throws {
        for vector in try cases("mediaPreviewPart") {
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let parsed = MediaPreviewPartPayload.parse(try Self.data(p))
            if Self.rejects(vector) {
                XCTAssertNil(parsed, Self.name(vector))
                continue
            }
            let (part, bytes) = try XCTUnwrap(parsed, Self.name(vector))
            XCTAssertEqual(bytes.base64EncodedString(), p["data"] as? String, Self.name(vector))
            let object: [String: Any] = ["index": part.index, "count": part.count, "mimeType": part.mimeType, "width": part.width, "height": part.height,
                                         "tint": Self.tintJSON(BrowseColor.tint(part.tint))]
            XCTAssertTrue(Self.same(object, vector["expect"]), Self.name(vector))
        }
    }

    func testMediaRangePart() throws {
        for vector in try cases("mediaRangePart") {
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let parsed = MediaRangePartPayload.parse(try Self.data(p))
            if Self.rejects(vector) {
                XCTAssertNil(parsed, Self.name(vector))
                continue
            }
            let (part, bytes) = try XCTUnwrap(parsed, Self.name(vector))
            XCTAssertEqual(bytes.base64EncodedString(), p["data"] as? String, Self.name(vector))
            let object: [String: Any] = ["offset": part.offset, "fileSize": part.fileSize, "modified": Self.json(part.modified), "last": part.last]
            XCTAssertTrue(Self.same(object, vector["expect"]), Self.name(vector))
        }
    }

    // MARK: What this Mac writes

    /// media.list as PhoneFilesController.listMedia sends it.
    func testMediaListIsWrittenAsTheVectors() throws {
        for vector in try written("mediaList") {
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let requestId = try XCTUnwrap(p["requestId"] as? String)
            let phone = LoopbackPhone()
            let controller = PhoneFilesController(host: phone, clock: ManualFolderClock(), makeID: { requestId })
            phone.controller = controller
            let kind = try XCTUnwrap((p["kind"] as? String).flatMap(PhoneMediaKind.init(rawValue:)))
            let limit = try XCTUnwrap(p["limit"] as? Int)
            controller.listMedia(phoneID: phone.phoneID, kind: kind, cursor: p["cursor"] as? String, limit: limit) { _ in }
            let sent = try XCTUnwrap(phone.requests(BrowseKind.mediaList).last?.payload, Self.name(vector))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: object).isEqual(to: p), Self.name(vector))
        }
    }

    /// media.cancel as PhoneFilesController sends it when a preview the phone already has is cancelled.
    func testMediaCancelIsWrittenAsTheVectors() throws {
        for vector in try written("mediaCancel") {
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let requestId = try XCTUnwrap(p["requestId"] as? String)
            let phone = LoopbackPhone()
            let controller = PhoneFilesController(host: phone, clock: ManualFolderClock(), makeID: { requestId })
            phone.controller = controller
            let entry = PhoneFileEntry(ref: .media(id: "1000"), name: "IMG_0.jpg", isDirectory: false, size: 1_000, modified: nil,
                                       mimeType: "image/jpeg", hasThumbnail: true)
            let request = controller.preview(phoneID: phone.phoneID, entry: entry, size: 1024) { _ in }
            request.cancel()
            let sent = try XCTUnwrap(phone.requests(BrowseKind.mediaCancel).last?.payload, Self.name(vector))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: object).isEqual(to: p), Self.name(vector))
        }
    }
}
