import Foundation
import XCTest
@testable import BridgeyMac

final class PhoneFreeSpaceTests: XCTestCase {
    func testAtMostOnceEveryTwentySecondsWithOneTrailingRequest() {
        var throttle = FreeSpaceThrottle()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(throttle.request("p", now: start), .ask)
        XCTAssertEqual(throttle.request("p", now: start.addingTimeInterval(5)), .later(15))
        XCTAssertEqual(throttle.request("p", now: start.addingTimeInterval(6)), .alreadyWaiting)
        XCTAssertEqual(throttle.request("other", now: start.addingTimeInterval(6)), .ask, "per phone")
        throttle.trailingDone("p")
        XCTAssertEqual(throttle.request("p", now: start.addingTimeInterval(20)), .ask)
        throttle.forget("p")
        XCTAssertEqual(throttle.request("p", now: start.addingTimeInterval(21)), .ask, "a reconnect asks at once")
    }

    func testDecodingWithAndWithoutTheFields() throws {
        let id = UUID().uuidString.lowercased()
        let withField = Data(#"{"version":1,"requestId":"\#(id)","mode":"fixed","places":[],"fixedLabel":"Download/Bridgey","defaultFreeBytes":5000000000}"#.utf8)
        let listed = try JSONDecoder().decode(PlacesListedPayload.self, from: withField)
        XCTAssertEqual(FreeSpaceReading.bytes(from: listed), 5_000_000_000)
        let older = Data(#"{"version":1,"requestId":"\#(id)","mode":"sender_picks","places":[{"placeId":"default","label":"Download/Bridgey","available":true,"freeBytes":7},{"placeId":"q3Jx0bVv1eG7tq8Wm2l5wA","label":"Pictures","available":true,"freeBytes":9}],"fixedLabel":null}"#.utf8)
        XCTAssertEqual(FreeSpaceReading.bytes(from: try JSONDecoder().decode(PlacesListedPayload.self, from: older)), 7, "falls back to the default place")
        let none = Data(#"{"version":1,"requestId":"\#(id)","mode":"receiver_asks","places":[],"fixedLabel":null}"#.utf8)
        XCTAssertNil(FreeSpaceReading.bytes(from: try JSONDecoder().decode(PlacesListedPayload.self, from: none)))
        let browse = try JSONDecoder().decode(BrowsePlacesListedPayload.self, from: withField)
        XCTAssertEqual(browse.defaultFreeBytes, 5_000_000_000)

        let accept = Data(#"{"version":1,"folderTransferId":"\#(id)","rootName":"Photos","destinationLabel":"Pictures","choice":"none","completedBitmap":null,"freeBytes":123}"#.utf8)
        XCTAssertEqual(FreeSpaceReading.bytes(from: try JSONDecoder().decode(FolderAcceptPayload.self, from: accept)), 123)
        let oldAccept = Data(#"{"version":1,"folderTransferId":"\#(id)","rootName":"Photos","destinationLabel":"Pictures","choice":"none","completedBitmap":null}"#.utf8)
        XCTAssertNil(FreeSpaceReading.bytes(from: try JSONDecoder().decode(FolderAcceptPayload.self, from: oldAccept)))
        let negative = Data(#"{"version":1,"folderTransferId":"\#(id)","rootName":"Photos","destinationLabel":"P","choice":"none","completedBitmap":null,"freeBytes":-1}"#.utf8)
        XCTAssertNil(FreeSpaceReading.bytes(from: try JSONDecoder().decode(FolderAcceptPayload.self, from: negative)))
        // The encoder leaves the field out when it is unknown, so older phones see the payload they know.
        let encoded = try FolderJSON.encoder.encode(FolderAcceptPayload(folderTransferId: id, rootName: "P", destinationLabel: "D", choice: .none, completedBitmap: nil))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("freeBytes"))
    }

    func testFreeSpaceCheckCases() {
        let now = Date()
        let gib: Int64 = 1024 * 1024 * 1024
        let fresh = PhoneFreeSpace(bytes: 10 * gib, checkedAt: now)
        XCTAssertEqual(FreeSpaceCheck.evaluate(needed: 2 * gib, free: fresh, now: now), .ok)
        XCTAssertEqual(FreeSpaceCheck.evaluate(needed: 9 * gib + gib / 2, free: fresh, now: now), .warn(needed: 9 * gib + gib / 2, free: 10 * gib))
        XCTAssertEqual(FreeSpaceCheck.evaluate(needed: 10 * gib, free: fresh, now: now), .block(needed: 10 * gib, free: 10 * gib))
        let stale = PhoneFreeSpace(bytes: 10 * gib, checkedAt: now.addingTimeInterval(-6 * 60))
        XCTAssertEqual(FreeSpaceCheck.evaluate(needed: 11 * gib, free: stale, now: now), .warn(needed: 11 * gib, free: 10 * gib), "a stale value only warns")
        XCTAssertEqual(FreeSpaceCheck.evaluate(needed: 11 * gib, free: nil, now: now), .ok, "unknown space never blocks")
        XCTAssertTrue(FreeSpaceCheck.evaluate(needed: 10 * gib, free: fresh, now: now).blocks)
        XCTAssertNotNil(FreeSpaceCheck.evaluate(needed: 10 * gib, free: fresh, now: now).message(phoneName: "OnePlus 11"))
    }
}
