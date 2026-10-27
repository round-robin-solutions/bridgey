import Foundation
import UserNotifications
import XCTest
@testable import BridgeyMac

final class ReceivedNotificationTests: XCTestCase {
    private func item(_ path: String, folder: Bool = false) -> ReceivedItem { ReceivedItem(url: URL(fileURLWithPath: path), isFolder: folder) }

    func testOneFileIsItsOwnNotificationAndOpensTheFile() {
        var grouper = ReceivedNotificationGrouper(makeID: { "a" })
        let content = grouper.add([item("/Users/r/Downloads/Bridgey/IMG.jpg")], phoneID: "p1", phoneName: "OnePlus 11", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(content?.identifier, "bridgey.received.a")
        XCTAssertEqual(content?.title, "File from OnePlus 11")
        XCTAssertEqual(content?.body, "IMG.jpg")
        XCTAssertEqual(content?.open.path, "/Users/r/Downloads/Bridgey/IMG.jpg")
        XCTAssertEqual(content?.reveal.map(\.path), ["/Users/r/Downloads/Bridgey/IMG.jpg"])
    }

    func testABurstFromOnePhoneUpdatesOneNotificationInPlace() {
        var ids = 0
        var grouper = ReceivedNotificationGrouper(makeID: { ids += 1; return "g\(ids)" })
        let start = Date(timeIntervalSince1970: 100)
        var last: ReceivedNotificationContent?
        for index in 0..<12 {
            last = grouper.add([item("/R/f\(index).txt")], phoneID: "p1", phoneName: "OnePlus 11", at: start.addingTimeInterval(Double(index) * 2.5))
            XCTAssertEqual(last?.identifier, "bridgey.received.g1", "within 3 s of the previous item: same notification")
        }
        XCTAssertEqual(last?.title, "12 files from OnePlus 11")
        XCTAssertEqual(last?.body, "f0.txt, f1.txt, f2.txt and 9 more")
        XCTAssertEqual(last?.open.path, "/R", "Open opens the folder they landed in")
        XCTAssertEqual(last?.reveal.count, 12, "Show in Finder selects all of them")
        // Another phone is its own notification; a pause starts a new one.
        XCTAssertEqual(grouper.add([item("/R/x.txt")], phoneID: "p2", phoneName: "Pixel", at: start.addingTimeInterval(28))?.identifier, "bridgey.received.g2")
        XCTAssertEqual(grouper.add([item("/R/y.txt")], phoneID: "p1", phoneName: "OnePlus 11", at: start.addingTimeInterval(27.5 + 3.1))?.identifier, "bridgey.received.g3")
    }

    func testFoldersAndMixedBurstsAndSeveralDestinations() {
        var grouper = ReceivedNotificationGrouper(makeID: { "m" })
        let now = Date()
        let folder = grouper.add([item("/R/Photos", folder: true)], phoneID: "p", phoneName: "OnePlus 11", at: now)
        XCTAssertEqual(folder?.title, "Folder from OnePlus 11")
        XCTAssertEqual(folder?.open.path, "/R/Photos", "a folder opens in Finder")
        let mixed = grouper.add([item("/R/a.txt")], phoneID: "p", phoneName: "OnePlus 11", at: now.addingTimeInterval(1))
        XCTAssertEqual(mixed?.title, "2 items from OnePlus 11")
        XCTAssertEqual(ReceivedNotificationGrouper.commonFolder([URL(fileURLWithPath: "/R/A/a"), URL(fileURLWithPath: "/R/B/b")]).path, "/R")
        XCTAssertEqual(ReceivedNotificationGrouper.commonFolder([URL(fileURLWithPath: "/R/A/a"), URL(fileURLWithPath: "/Volumes/X/b")]).path, "/R/A")
    }

    func testShowInFinderSelectsAtMostTwoHundredButCountsAll() {
        var grouper = ReceivedNotificationGrouper(makeID: { "c" })
        let items = (0..<250).map { item("/R/\($0)") }
        let content = grouper.add(items, phoneID: "p", phoneName: "OnePlus 11", at: Date())
        XCTAssertEqual(content?.title, "250 files from OnePlus 11")
        XCTAssertEqual(content?.reveal.count, 200)
    }

    func testActionRouting() {
        let info: [AnyHashable: Any] = [receivedPathsUserInfoKey: ["/R/a.txt", "/R/b.txt"], receivedOpenPathUserInfoKey: "/R"]
        XCTAssertEqual(ReceivedNotificationAction.route(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info), .open(URL(fileURLWithPath: "/R")))
        XCTAssertEqual(ReceivedNotificationAction.route(actionIdentifier: receivedOpenActionIdentifier, userInfo: info), .open(URL(fileURLWithPath: "/R")))
        XCTAssertEqual(ReceivedNotificationAction.route(actionIdentifier: receivedRevealActionIdentifier, userInfo: info),
                       .reveal([URL(fileURLWithPath: "/R/a.txt"), URL(fileURLWithPath: "/R/b.txt")]))
        XCTAssertEqual(ReceivedNotificationAction.route(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: info), .none)
        XCTAssertEqual(ReceivedNotificationAction.route(actionIdentifier: receivedRevealActionIdentifier, userInfo: [:]), .none)
    }

    func testTheCategoryHasOpenAndShowInFinder() {
        let category = MainActor.assumeIsolated { ReceivedNotifier.category }
        XCTAssertEqual(category.identifier, receivedNotificationCategory)
        XCTAssertEqual(category.actions.map(\.identifier), [receivedOpenActionIdentifier, receivedRevealActionIdentifier])
    }
}
