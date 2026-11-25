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

/// Without notification permission, received files are revealed in Finder a batch at a time.
@MainActor
final class ReceivedRevealBatcherTests: XCTestCase {
    private func url(_ index: Int) -> URL { URL(fileURLWithPath: "/R/f\(index).bin") }

    private func makeBatcher(_ fake: FakeSchedule, busy: @escaping () -> Bool = { false }, reveals: @escaping ([URL]) -> Void) -> ReceivedRevealBatcher {
        ReceivedRevealBatcher(quiet: 1, clock: { fake.now }, schedule: fake.schedule, busy: busy, reveal: reveals)
    }

    func testABatchIsRevealedOnceTogether() {
        let fake = FakeSchedule()
        var reveals: [[URL]] = []
        let batcher = makeBatcher(fake) { reveals.append($0) }
        for index in 0..<200 {
            fake.advance(to: Double(index) * 0.3)
            batcher.add([url(index)])
        }
        fake.advance(to: 59.7 + 0.9)
        XCTAssertTrue(reveals.isEmpty, "not while files keep coming")
        fake.advance(to: 61)
        XCTAssertEqual(reveals.count, 1, "200 files bring Finder forward once")
        XCTAssertEqual(reveals.first, (0..<200).map(url), "all of them, in the order they came")
    }

    func testASingleFileIsRevealedOnItsOwn() {
        let fake = FakeSchedule()
        var reveals: [[URL]] = []
        let batcher = makeBatcher(fake) { reveals.append($0) }
        batcher.add([url(1)])
        fake.advance(to: 0.5)
        XCTAssertTrue(reveals.isEmpty)
        fake.advance(to: 1)
        XCTAssertEqual(reveals, [[url(1)]])
        // A file a while later is its own reveal.
        fake.advance(to: 30)
        batcher.add([url(2)])
        fake.advance(to: 31)
        XCTAssertEqual(reveals, [[url(1)], [url(2)]])
    }

    func testItWaitsForWhatIsStillArriving() {
        let fake = FakeSchedule()
        var reveals: [[URL]] = []
        var busy = true
        let batcher = makeBatcher(fake, busy: { busy }) { reveals.append($0) }
        batcher.add([url(1)])
        fake.advance(to: 20)
        XCTAssertTrue(reveals.isEmpty, "a long file still on its way")
        batcher.add([url(2)])
        busy = false
        fake.advance(to: 20.9)
        XCTAssertTrue(reveals.isEmpty)
        fake.advance(to: 22)
        XCTAssertEqual(reveals, [[url(1), url(2)]])
    }

    func testAtMostTwoHundredAndEachOnce() {
        let fake = FakeSchedule()
        var reveals: [[URL]] = []
        let batcher = makeBatcher(fake) { reveals.append($0) }
        batcher.add((0..<250).map(url))
        batcher.add([url(0), URL(fileURLWithPath: "/R/./f1.bin")])
        fake.advance(to: 2)
        XCTAssertEqual(reveals.count, 1)
        XCTAssertEqual(reveals.first?.count, ReceivedNotificationGrouper.maxPaths)
        XCTAssertEqual(reveals.first?.prefix(3).map(\.lastPathComponent), ["f0.bin", "f1.bin", "f2.bin"])
        XCTAssertEqual(Set(reveals.first ?? []).count, ReceivedNotificationGrouper.maxPaths, "a file that came twice is selected once")
    }
}
