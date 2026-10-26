import Foundation
import XCTest
@testable import BridgeyMac

/// Runs protocol/test-vectors/folders-v1.json, the vectors Android runs too.
final class FolderVectorsTests: XCTestCase {
    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/folders-v1.json")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func string(_ value: Any) -> String {
        if let text = value as? String { return text }
        let object = value as! [String: Any]
        let parts = Array(repeating: object["part"] as! String, count: object["times"] as! Int)
        return parts.joined(separator: object["join"] as? String ?? "") + (object["suffix"] as? String ?? "")
    }

    private func strings(_ value: Any?) -> [String] { (value as! [Any]).map(string) }

    private func same(_ a: String?, _ b: String) -> Bool { a.map { Array($0.unicodeScalars) == Array(b.unicodeScalars) } ?? false }

    func testPortableNames() {
        for case let item as [String: Any] in vectors["portableNames"] as! [Any] {
            let input = string(item["input"]!)
            let expected = string(item["portable"]!)
            let converted = PortableName.convert(input)
            XCTAssertTrue(same(converted, expected), "convert(\(input.debugDescription)) = \(converted.debugDescription), want \(expected.debugDescription)")
            XCTAssertTrue(PortableName.isPortable(converted), expected)
            XCTAssertTrue(same(PortableName.convert(converted), converted), "idempotent \(expected)")
        }
    }

    func testNamesThatAreNotPortable() {
        for name in strings(vectors["notPortable"]) {
            XCTAssertFalse(PortableName.isPortable(name), name.debugDescription)
        }
    }

    func testManifestPaths() {
        let paths = vectors["manifestPaths"] as! [String: Any]
        strings(paths["valid"]).forEach { XCTAssertTrue(FolderPaths.isValidManifestPath($0), String($0.prefix(40))) }
        strings(paths["invalid"]).forEach { XCTAssertFalse(FolderPaths.isValidManifestPath($0), String($0.prefix(40)).debugDescription) }
    }

    func testExistingPaths() {
        let paths = vectors["existingPaths"] as! [String: Any]
        strings(paths["valid"]).forEach { XCTAssertTrue(FolderPaths.isValidExistingPath($0), String($0.prefix(40))) }
        strings(paths["invalid"]).forEach { XCTAssertFalse(FolderPaths.isValidExistingPath($0), String($0.prefix(40)).debugDescription) }
    }

    func testCaseClashesAreRenamedInByteOrder() {
        for case let item as [String: Any] in vectors["caseClashes"] as! [Any] {
            let siblings = (item["siblings"] as! [[String: Any]]).map { (name: $0["name"] as! String, isDirectory: $0["dir"] as! Bool) }
            let resolved = ConflictNames.resolveSiblings(siblings).map(\.name)
            let expected = strings(item["resolved"])
            XCTAssertEqual(resolved.map { Array($0.unicodeScalars) }, expected.map { Array($0.unicodeScalars) }, "\(siblings)")
        }
    }

    func testConflictNames() {
        for case let item as [String: Any] in vectors["conflictNames"] as! [Any] {
            let taken = Set(strings(item["taken"]).map(caseKey))
            let result = ConflictNames.firstFree(item["name"] as! String, isDirectory: item["dir"] as! Bool) { taken.contains($0) }
            XCTAssertEqual(result, item["result"] as! String)
        }
    }

    func testSystemFileListMatchesTheSharedConstant() {
        let system = vectors["systemFiles"] as! [String: Any]
        XCTAssertEqual(Set(strings(system["names"]).map { $0.unicodeScalars.map(\.value) }), Set(SystemFiles.names.map { $0.unicodeScalars.map(\.value) }))
        XCTAssertEqual(system["appleDoublePrefix"] as? String, SystemFiles.appleDoublePrefix)
        for case let item as [String: Any] in system["classify"] as! [Any] {
            let name = item["name"] as! String
            XCTAssertEqual(SystemFiles.classify(name, hiddenFlag: item["hiddenFlag"] as? Bool ?? false).rawValue, item["class"] as? String, name.debugDescription)
        }
    }

    func testSystemFilesStayOutUnlessTheirOwnOptionIsOn() {
        XCTAssertFalse(SystemFiles.included(.system, includeHidden: true, includeSystem: false))
        XCTAssertTrue(SystemFiles.included(.system, includeHidden: false, includeSystem: true))
        XCTAssertFalse(SystemFiles.included(.hidden, includeHidden: false, includeSystem: true))
        XCTAssertTrue(SystemFiles.included(.hidden, includeHidden: true, includeSystem: false))
        XCTAssertFalse(SystemFiles.included(.partial, includeHidden: true, includeSystem: true))
        XCTAssertTrue(SystemFiles.included(.normal, includeHidden: false, includeSystem: false))
    }

    func testManifestDigest() throws {
        let digest = vectors["manifestDigest"] as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: digest["entries"]!)
        let entries = try JSONDecoder().decode([ManifestEntry].self, from: data)
        XCTAssertEqual(ManifestDigest.compute(rootName: digest["rootName"] as! String, entries: entries), digest["sha256"] as? String)
    }

    func testCompletedBitmap() {
        let bitmap = vectors["bitmap"] as! [String: Any]
        let set = Set(bitmap["set"] as! [Int])
        let size = bitmap["size"] as! Int
        XCTAssertEqual(CompletedBitmap.encode(size: size) { set.contains($0) }, bitmap["base64"] as? String)
        XCTAssertEqual(CompletedBitmap.decode(bitmap["base64"] as! String, size: size), set)
        XCTAssertNil(CompletedBitmap.decode("CQ==", size: size))
    }

    func testManifestOrderIsDepthFirstWithSiblingsByBytes() {
        let paths = ["b", "a/z", "A", "a", "a/b/c", "a/b", ".env"]
        XCTAssertEqual(paths.sorted(by: FolderPaths.precedes), [".env", "A", "a", "a/b", "a/b/c", "a/z", "b"])
    }

    func testPagerKeepsPagesWithinLimitsAndRoundTrips() throws {
        let id = UUID().uuidString.lowercased()
        let entries = (0..<1_000).map { ManifestEntry.file(String(format: "f%04d-", $0) + String(repeating: "x", count: 150), size: 3, sha256: "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=") }
        let pages = try XCTUnwrap(ManifestPager.pages(folderTransferID: id, entries: entries))
        for page in pages {
            XCTAssertLessThanOrEqual(page.entries.count, 256)
            XCTAssertLessThanOrEqual(try FolderJSON.encoder.encode(page).count, 32 * 1024)
        }
        XCTAssertEqual(pages.flatMap(\.entries), entries)
        XCTAssertEqual(pages.map(\.page), Array(0..<pages.count))
        XCTAssertNil(ManifestPager.pages(folderTransferID: id, entries: (0..<(128 * 256 + 1)).map { ManifestEntry.dir("d\($0)") }))
        XCTAssertEqual(ManifestPager.pages(folderTransferID: id, entries: [])?.count, 0)
    }

    func testDirectoryEntriesEncodeWithoutFileFields() throws {
        let json = String(decoding: try FolderJSON.encoder.encode(ManifestEntry.dir("a/b")), as: UTF8.self)
        XCTAssertEqual(json, #"{"type":"dir","path":"a/b"}"#)
    }

    func testOfferRoundTripsWithWireNames() throws {
        let offer = FolderOfferPayload(folderTransferId: UUID().uuidString.lowercased(), rootName: "Photos", fileCount: 1, folderCount: 0,
                                       totalSize: 5, pageCount: 1, manifestSha256: "x", destination: FolderDestination(placeId: defaultPlaceID, path: "Trip"),
                                       resume: false, skipped: SkippedCounts(hidden: 2, system: 3))
        let data = try FolderJSON.encoder.encode(offer)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["destination"] as? [String: Any])?["placeId"] as? String, "default")
        XCTAssertEqual((object["skipped"] as? [String: Any])?["system"] as? Int, 3)
        XCTAssertEqual(try JSONDecoder().decode(FolderOfferPayload.self, from: data), offer)
        let conflict = try JSONDecoder().decode(FolderConflictPayload.self, from: Data(#"{"version":1,"folderTransferId":"x","existing":"folder","clashingFiles":null,"clashingFolders":3,"newFolderName":"Photos (1)","choices":["merge","replace","new_folder"],"timeoutSeconds":180,"extra":true}"#.utf8))
        XCTAssertNil(conflict.clashingFiles)
        XCTAssertEqual(conflict.choices, [.merge, .replace, .newFolder])
    }

    func testWireIDsAndPlaceIDs() {
        XCTAssertTrue(FolderJSON.isWireID("4b0c9d5e-1111-2222-3333-444455556666"))
        XCTAssertFalse(FolderJSON.isWireID("4B0C9D5E-1111-2222-3333-444455556666"))
        XCTAssertTrue(FolderJSON.isPlaceID("default"))
        XCTAssertTrue(FolderJSON.isPlaceID("q3Jx0bVv1eG7tq8Wm2l5wA"))
        XCTAssertFalse(FolderJSON.isPlaceID("content://com.android.externalstorage.documents/tree/primary"))
    }

    func testResumeWindowIsTwentyFourHoursAfterTheLastProgress() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(FolderTimeouts.canResume(lastProgress: start, now: start.addingTimeInterval(23 * 3600)))
        XCTAssertFalse(FolderTimeouts.canResume(lastProgress: start, now: start.addingTimeInterval(24 * 3600)))
    }

    /// One golden payload per message kind: what the phone sends must decode here, and what this Mac builds must match.
    func testGoldenMessagesDecodeAndRoundTrip() throws {
        let messages = vectors["messages"] as! [String: Any]
        func data(_ kind: String) throws -> Data { try JSONSerialization.data(withJSONObject: messages[kind]!) }
        func canonical(_ data: Data) throws -> NSDictionary {
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return stripNulls(object) as! NSDictionary
        }
        func check<T: Codable & Equatable>(_ type: T.Type, _ kind: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
            let decoded = try JSONDecoder().decode(T.self, from: try data(kind))
            XCTAssertEqual(try canonical(try FolderJSON.encoder.encode(decoded)), try canonical(try data(kind)), kind, file: file, line: line)
            return decoded
        }
        _ = try check(PlacesListPayload.self, "places.list")
        let listed = try check(PlacesListedPayload.self, "places.listed")
        XCTAssertTrue(listed.isValid)
        XCTAssertEqual(listed.mode, .senderPicks)
        XCTAssertNil(listed.places[1].freeBytes)
        _ = try check(PlacesBrowsePayload.self, "places.browse")
        XCTAssertEqual(try check(PlacesChildrenPayload.self, "places.children").folders, ["2019", "Beach"])
        _ = try check(PlacesCreateFolderPayload.self, "places.create_folder")
        _ = try check(PlacesCreateFolderPayload.self, "places.folder_created")
        XCTAssertEqual(try check(PlacesErrorPayload.self, "places.error").code, FolderCode.notFound)
        let offer = try check(FolderOfferPayload.self, "folders.offer")
        let page = try check(ManifestPagePayload.self, "folders.manifest")
        XCTAssertEqual(ManifestDigest.compute(rootName: offer.rootName, entries: page.entries), offer.manifestSha256)
        XCTAssertEqual(try check(FolderWaitingPayload.self, "folders.waiting").reason, FolderWaitingPayload.destination)
        XCTAssertEqual(try check(FolderConflictPayload.self, "folders.conflict").choices, [.merge, .replace, .newFolder])
        XCTAssertEqual(try check(FolderResolvePayload.self, "folders.resolve").choice, .merge)
        XCTAssertNil(try check(FolderAcceptPayload.self, "folders.accept").completedBitmap)
        XCTAssertEqual(try check(FolderRejectedPayload.self, "folders.rejected").neededBytes, 2_548_170_955)
        XCTAssertEqual(try check(FolderEntryFailedPayload.self, "folders.entry_failed").entry, 2)
        XCTAssertEqual(try check(FolderCompletePayload.self, "folders.complete").failed, [FailedEntry(entry: 3, code: FolderCode.sourceChanged)])
        XCTAssertFalse(try check(FolderResultPayload.self, "folders.result").isComplete)
        XCTAssertEqual(try check(FolderCancelPayload.self, "folders.cancel").reason, FolderCancelPayload.user)
        XCTAssertEqual(try check(FolderFileOfferPayload.self, "files.offer").path, "2019/IMG_0001.jpg")
    }

    private func stripNulls(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { !($0.value is NSNull) }.mapValues(stripNulls)
        }
        if let array = value as? [Any] { return array.map(stripNulls) }
        return value
    }
}
