import Foundation
import XCTest
@testable import BridgeyMac

/// Local history from older releases: the activity stream (Beta 4, 5 and 10 shapes), notification
/// history (unchanged since before the edition) and the remote control audit (Beta 9).
final class MigrationHistoryTests: XCTestCase {
    private typealias F = MigrationFixtures
    private var directory: URL!
    private let now = MigrationFixtures.base.addingTimeInterval(24 * 60 * 60)

    override func setUpWithError() throws {
        directory = try F.temporaryDirectory("history")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func copy(_ fixture: String, as name: String) throws -> URL {
        let target = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: F.url(fixture), to: target)
        return target
    }

    // MARK: Activity stream

    private func item(_ id: Int64, _ kind: ActivityKind, minutes: Double, device: String? = MigrationFixtures.phoneA,
                      name: String = "Test Phone A", fileName: String? = nil, preview: String? = nil, appName: String? = nil,
                      sensitive: Bool = false, automatic: Bool = false, count: Int = 1, bytes: Int64? = nil,
                      content: String? = nil, fileCount: Int? = nil, destination: String? = nil) -> ActivityItem {
        ActivityItem(id: id, kind: kind, deviceID: device, deviceName: name, fileName: fileName, preview: preview, appName: appName,
                     sensitive: sensitive, automatic: automatic, count: count, at: F.base.addingTimeInterval(minutes * 60),
                     bytes: bytes, content: content, fileCount: fileCount, destination: destination)
    }

    private func expectedStream(_ release: Int) -> [ActivityItem] {
        var items: [ActivityItem] = []
        if release >= 10 {
            items.append(item(12, .folderSent, minutes: 120, fileName: "Trip", bytes: 52_428_800, content: "done=12;links=3",
                              fileCount: 12, destination: "Pictures/Trip"))
            items.append(item(11, .folderIncomplete, minutes: 90, fileName: "Scans", bytes: 1_048_576, content: "done=3;failed=1;end=timeout",
                              fileCount: 4, destination: "Download/Bridgey/Scans"))
        }
        if release >= 5 {
            items.append(item(10, .clipOfferSent, minutes: 60, bytes: 2_100_000, content: "image"))
            items.append(item(9, .clipPasted, minutes: 50, fileName: "video.mp4", bytes: 340_000_000, content: "file"))
        }
        items.append(item(8, .clipboardSent, minutes: 40, preview: "Automatic copy from the Mac", automatic: true))
        items.append(item(6, .clipboardSent, minutes: 20, preview: "Meeting notes for Tuesday"))
        items.append(item(5, .clipboardReceived, minutes: 15, sensitive: true))
        items.append(item(4, .notificationsShown, minutes: 10, appName: "Chat App", count: 4))
        items.append(item(3, .fileReceived, minutes: 5, fileName: "report.pdf"))
        items.append(item(2, .callShown, minutes: 2, preview: "Test Caller"))
        items.append(item(1, .paired, minutes: 0, device: F.phoneB, name: "Test Phone B"))
        return items
    }

    @MainActor
    func testEveryShippedActivityShapeLoadsCompletely() throws {
        for release in [4, 5, 10] {
            let url = try copy("activity/activity-stream.beta.\(release).json", as: ActivityStore.fileName)
            let log = ActivityLog(store: ActivityStore(fileURL: url), clock: { self.now })
            XCTAssertEqual(log.items, expectedStream(release), "beta.\(release)")
        }
    }

    @MainActor
    func testAnUpgradedStreamIsRewrittenWithoutLosingItems() throws {
        for release in [4, 5, 10] {
            let url = try copy("activity/activity-stream.beta.\(release).json", as: ActivityStore.fileName)
            let store = ActivityStore(fileURL: url)
            ActivityLog(store: store, clock: { self.now }).record(.pingReceived, deviceID: F.phoneA, deviceName: "Test Phone A", previews: true)
            store.flush()
            let reloaded = ActivityLog(store: ActivityStore(fileURL: url), clock: { self.now }).items
            XCTAssertEqual(reloaded.first?.kind, .pingReceived, "beta.\(release)")
            XCTAssertEqual(reloaded.first?.id, (expectedStream(release).map(\.id).max() ?? 0) + 1, "beta.\(release): ids stay unique")
            XCTAssertEqual(Array(reloaded.dropFirst()), expectedStream(release), "beta.\(release)")
        }
    }

    func testMalformedAndUnknownActivityEntriesAreDroppedOneByOne() throws {
        let items = ActivityHistory.decode(try F.data("activity/activity-stream.malformed.json"), now: now)
        XCTAssertEqual(items.map(\.id), [47, 43, 40])
        XCTAssertNil(items[0].deviceID)
        XCTAssertNil(items[1].deviceID, "an empty device id is no device")
        XCTAssertEqual(items[1].count, 9_999)
        XCTAssertEqual(items[1].bytes, 0, "a negative size is clamped")
        XCTAssertNil(items[1].content, "an unknown content kind is dropped")
        XCTAssertNil(items[1].preview)
        XCTAssertEqual(items[2], item(40, .clipboardSent, minutes: 0, preview: "line one line two", automatic: true))
    }

    func testAnEntryOfTheWrongTypeDoesNotCostTheRestOfTheStream() throws {
        let items = ActivityHistory.decode(try F.data("activity/activity-stream.wrong-type.json"), now: now)
        XCTAssertEqual(items.map(\.id), [1])
    }

    func testAnUnreadableActivityFileStartsEmptyWithoutCrashing() {
        XCTAssertEqual(ActivityHistory.decode(Data("{ not json".utf8), now: now), [])
        XCTAssertEqual(ActivityHistory.decode(Data(#"{"items":[]}"#.utf8), now: now), [])
        XCTAssertEqual(ActivityHistory.decode(Data(repeating: 0x20, count: 600 * 1024), now: now), [], "over 512 KiB is not read")
    }

    // MARK: Notification history

    func testNotificationHistoryFromBeta1Loads() throws {
        let url = try copy("notification-history/notification-history.beta.1.json", as: "notification-history.json")
        let items = NotificationHistoryStore(fileURL: url).load(now: now)
        XCTAssertEqual(items.map(\.applicationName), ["Chat App", "Mail App"])
        XCTAssertEqual(items.first?.title, "Synthetic title")
        XCTAssertEqual(items.first?.text, "Synthetic message text")
        XCTAssertEqual(items.first?.receivedAt, F.base.addingTimeInterval(3_600))
        XCTAssertEqual(items.last?.text, "")
    }

    func testDamagedNotificationHistoryStartsEmptyWithoutCrashing() throws {
        let url = directory.appendingPathComponent("notification-history.json")
        try Data(#"[{"id":"x","packageName":"p"}]"#.utf8).write(to: url)
        XCTAssertEqual(NotificationHistoryStore(fileURL: url).load(now: now), [])
    }

    // MARK: Remote control audit

    func testRemoteControlAuditFromBeta9Loads() throws {
        let url = try copy("remote-control/remote-control-audit.beta.9.json", as: RemoteControlAuditStore.fileName)
        let entries = RemoteControlAuditStore(fileURL: url).load(now: now)
        XCTAssertEqual(entries.count, 2)
        let session = entries[0]
        XCTAssertTrue(session.accepted)
        XCTAssertEqual(session.deviceID, F.phoneA)
        XCTAssertEqual(session.mode, "touchpad")
        XCTAssertEqual(session.reason, .user)
        XCTAssertEqual(session.counts["pointer"], 120)
        XCTAssertEqual(session.dropped, 2)
        XCTAssertEqual(session.rejected, 1)
        XCTAssertEqual(session.duration, 20 * 60)
        let refused = entries[1]
        XCTAssertFalse(refused.accepted)
        XCTAssertNil(refused.mode)
        XCTAssertEqual(refused.reason, .permissionRequired)
    }

    func testDamagedRemoteControlAuditStartsEmptyWithoutCrashing() throws {
        let url = directory.appendingPathComponent(RemoteControlAuditStore.fileName)
        try Data("[{]".utf8).write(to: url)
        XCTAssertEqual(RemoteControlAuditStore(fileURL: url).load(now: now), [])
    }
}
