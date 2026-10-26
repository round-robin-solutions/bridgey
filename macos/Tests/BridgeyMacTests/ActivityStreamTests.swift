import Foundation
import XCTest
@testable import BridgeyMac

final class ActivityStreamTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func add(
        _ items: [ActivityItem],
        _ kind: ActivityKind,
        at offset: TimeInterval = 0,
        id: Int64,
        device: String = "phone-1",
        app: String? = nil,
        preview: String? = nil,
        file: String? = nil
    ) -> [ActivityItem] {
        ActivityHistory.add(
            items, kind: kind, deviceID: device, deviceName: "OnePlus 11", fileName: file,
            preview: preview, appName: app, now: now.addingTimeInterval(offset), nextID: id
        )
    }

    // MARK: Cap and expiry

    func testStreamKeepsAtMostTwoHundredItemsNewestFirst() {
        var items: [ActivityItem] = []
        for index in 0..<205 {
            items = add(items, .pingReceived, at: TimeInterval(index), id: Int64(index + 1))
        }
        XCTAssertEqual(items.count, ActivityHistory.maximumItems)
        XCTAssertEqual(items.first?.id, 205)
        XCTAssertEqual(items.last?.id, 6)
    }

    func testItemsExpireAfterSevenDaysAndFutureItemsAreDropped() {
        let old = ActivityItem(id: 1, kind: .pingSent, deviceID: nil, deviceName: "A", fileName: nil, preview: nil, appName: nil,
                               sensitive: false, automatic: false, count: 1, at: now.addingTimeInterval(-ActivityHistory.maximumAge - 1))
        let edge = ActivityItem(id: 2, kind: .pingSent, deviceID: nil, deviceName: "A", fileName: nil, preview: nil, appName: nil,
                                sensitive: false, automatic: false, count: 1, at: now.addingTimeInterval(-ActivityHistory.maximumAge + 1))
        let future = ActivityItem(id: 3, kind: .pingSent, deviceID: nil, deviceName: "A", fileName: nil, preview: nil, appName: nil,
                                  sensitive: false, automatic: false, count: 1, at: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(ActivityHistory.prune([old, edge, future], now: now).map(\.id), [2])
    }

    @MainActor func testLogPrunesExpiredItemsWhenShown() {
        var clock = now
        let log = ActivityLog(store: nil) { clock }
        log.record(.pingSent, deviceID: "d", deviceName: "Phone", previews: true)
        clock = clock.addingTimeInterval(ActivityHistory.maximumAge + 60)
        log.prune()
        XCTAssertTrue(log.items.isEmpty)
    }

    // MARK: Grouping

    func testAlertsGroupPerDeviceAndAppWithinFifteenMinutes() {
        var items: [ActivityItem] = []
        items = add(items, .notificationsShown, at: 0, id: 1, app: "WhatsApp")
        items = add(items, .notificationsShown, at: 60, id: 2, app: "WhatsApp")
        items = add(items, .notificationsShown, at: 5 * 60, id: 3, app: "WhatsApp")
        items = add(items, .notificationsShown, at: 14 * 60, id: 4, app: "WhatsApp")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].count, 4)
        XCTAssertEqual(ActivityText.title(items[0], showPreviews: true), "4 WhatsApp alerts")

        // A different app, a different device and a gap past the window each start a new item.
        items = add(items, .notificationsShown, at: 15 * 60, id: 5, app: "Slack")
        items = add(items, .notificationsShown, at: 15 * 60 + 1, id: 6, device: "phone-2", app: "WhatsApp")
        items = add(items, .notificationsShown, at: 30 * 60, id: 7, app: "WhatsApp")
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first?.id, 7)
        XCTAssertEqual(items.first?.count, 1)
    }

    func testCallsFromTheSameCallerMergeOnlyWithinAMinute() {
        var items: [ActivityItem] = []
        items = add(items, .callShown, at: 0, id: 1, preview: "Mum")
        items = add(items, .callShown, at: 30, id: 2, preview: "Mum")
        XCTAssertEqual(items.map(\.count), [2])
        items = add(items, .callShown, at: 120, id: 3, preview: "Mum")
        items = add(items, .callShown, at: 121, id: 4, preview: "Dad")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(ActivityText.title(items[0], showPreviews: true), "Call from Dad")
    }

    func testOtherEventsNeverMerge() {
        var items: [ActivityItem] = []
        items = add(items, .clipboardReceived, at: 0, id: 1, preview: "same")
        items = add(items, .clipboardReceived, at: 1, id: 2, preview: "same")
        XCTAssertEqual(items.count, 2)
    }

    func testStreamRowsGroupTodayYesterdayAndEarlier() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 41))!
        func item(_ id: Int64, _ date: Date) -> ActivityItem {
            ActivityItem(id: id, kind: .pingSent, deviceID: "d", deviceName: "Phone", fileName: nil, preview: nil, appName: nil,
                         sensitive: false, automatic: false, count: 1, at: date)
        }
        let items = [
            item(1, today.addingTimeInterval(-60)),
            item(2, calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 59))!),
            item(3, calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 0, minute: 1))!),
            item(4, calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!),
        ]
        let rows = streamRows(items, now: today, calendar: calendar)
        XCTAssertEqual(rows.map(\.id), [
            "header:0", "item:1",
            "header:1", "item:2", "item:3",
            "header:2", "item:4",
        ])
        XCTAssertEqual(streamRows(items, deviceID: "other", now: today, calendar: calendar), [])
    }

    // MARK: Previews

    func testPreviewCollapsesWhitespaceAndCutsAtEightyCharacters() {
        XCTAssertEqual(ActivityHistory.preview("  Room 2\n\n at 4,\tbring  the deck "), "Room 2 at 4, bring the deck")
        XCTAssertNil(ActivityHistory.preview(" \n\t "))
        XCTAssertNil(ActivityHistory.preview(nil))

        let exact = String(repeating: "a", count: 80)
        XCTAssertEqual(ActivityHistory.preview(exact), exact)

        let long = String(repeating: "word ", count: 40)
        let cut = ActivityHistory.preview(long)!
        XCTAssertLessThanOrEqual(cut.count, 80)
        XCTAssertTrue(cut.hasSuffix("\u{2026}"))
        XCTAssertFalse(cut.contains("  "))
        XCTAssertFalse(cut.dropLast().hasSuffix(" "))

        // Never splits an emoji or other grapheme cluster.
        let emoji = String(repeating: "\u{1F469}\u{200D}\u{1F4BB}", count: 100)
        let emojiCut = ActivityHistory.preview(emoji)!
        XCTAssertEqual(emojiCut.count, 80)
        XCTAssertTrue(emojiCut.dropLast().allSatisfy { $0 == "\u{1F469}\u{200D}\u{1F4BB}" })
    }

    func testOnlyClipboardAndCallsKeepPreviewsAndOnlyAlertsKeepAppNames() {
        var items: [ActivityItem] = []
        items = add(items, .linkReceived, id: 1, app: "Chrome", preview: "https://example.com/secret", file: "x.pdf")
        XCTAssertNil(items[0].preview)
        XCTAssertNil(items[0].appName)
        XCTAssertNil(items[0].fileName)
        items = add(items, .fileReceived, at: 1, id: 2, preview: "text", file: " invoice-oct.pdf ")
        XCTAssertEqual(items[0].fileName, "invoice-oct.pdf")
        XCTAssertNil(items[0].preview)
    }

    func testSensitiveClipsKeepNoText() {
        let items = ActivityHistory.add([], kind: .clipboardSent, deviceID: "d", deviceName: "Phone", preview: "hunter2",
                                        sensitive: true, now: now, nextID: 1)
        XCTAssertNil(items[0].preview)
        XCTAssertTrue(items[0].sensitive)
        XCTAssertEqual(ActivityText.detail(items[0], showPreviews: true), "Hidden")
    }

    @MainActor func testPreviewsOffStoresNoPreviewAppNameOrCaller() {
        let log = ActivityLog(store: nil) { self.now }
        log.record(.clipboardReceived, deviceID: "d", deviceName: "Phone", preview: "Room 2 at 4", previews: false)
        log.record(.notificationsShown, deviceID: "d", deviceName: "Phone", appName: "WhatsApp", previews: false)
        log.record(.callShown, deviceID: "d", deviceName: "Phone", preview: "Mum", previews: false)
        XCTAssertTrue(log.items.allSatisfy { $0.preview == nil && $0.appName == nil })
        let titles = log.items.map { ActivityText.title($0, showPreviews: true) }
        XCTAssertEqual(titles, ["Incoming call", "1 alert", "Copied text from Phone"])
        XCTAssertFalse(titles.joined().contains("WhatsApp"))
        XCTAssertFalse(titles.joined().contains("Mum"))
    }

    func testTurningPreviewsOffHidesStoredPreviews() {
        var items: [ActivityItem] = []
        items = add(items, .clipboardReceived, id: 1, preview: "Room 2 at 4")
        items = add(items, .notificationsShown, at: 1, id: 2, app: "WhatsApp")
        items = add(items, .callShown, at: 2, id: 3, preview: "Mum")
        let shown = items.map { ActivityText.title($0, showPreviews: true) + (ActivityText.detail($0, showPreviews: true) ?? "") }
        XCTAssertTrue(shown.joined().contains("Room 2 at 4"))
        XCTAssertTrue(shown.joined().contains("WhatsApp"))
        XCTAssertTrue(shown.joined().contains("Mum"))
        let hidden = items.map { ActivityText.title($0, showPreviews: false) + (ActivityText.detail($0, showPreviews: false) ?? "") }
        XCTAssertFalse(hidden.joined().contains("Room 2 at 4"))
        XCTAssertFalse(hidden.joined().contains("WhatsApp"))
        XCTAssertFalse(hidden.joined().contains("Mum"))
        XCTAssertEqual(hidden, ["Incoming call", "1 alert", "Copied text from OnePlus 11"])
    }

    // MARK: Storage

    @MainActor func testStoreRoundTripsOwnerOnlyAndClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(ActivityStore.fileName)
        let store = ActivityStore(fileURL: file)
        let log = ActivityLog(store: store) { self.now }
        log.record(.fileReceived, deviceID: "d", deviceName: "Phone", fileName: "invoice-oct.pdf", previews: true)
        log.record(.clipboardSent, deviceID: "d", deviceName: "Phone", preview: "hello", automatic: true, previews: true)
        store.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = store.load(now: now)
        XCTAssertEqual(loaded, log.items)
        XCTAssertEqual(loaded.first?.automatic, true)

        let reopened = ActivityLog(store: store) { self.now }
        XCTAssertEqual(reopened.items.count, 2)
        reopened.record(.pingSent, deviceID: "d", deviceName: "Phone", previews: true)
        XCTAssertEqual(Set(reopened.items.map(\.id)).count, 3, "ids stay unique after a reload")
        reopened.clear()
        XCTAssertTrue(reopened.items.isEmpty)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDefaultFileLivesInTheEditionSupportFolder() {
        let path = ActivityStore.defaultFileURL().path
        XCTAssertTrue(path.hasSuffix("/Application Support/\(Edition.supportFolderName)/activity-stream.json"), path)
    }

    func testDecodeDropsUnknownAndCleansFields() {
        let json = """
        [{"id":1,"kind":"teleport","deviceName":"A","sensitive":false,"automatic":false,"count":1,"at":\(Int(now.timeIntervalSince1970 * 1000))},
         {"id":2,"kind":"link_received","deviceName":"A","preview":"https://secret","appName":"X","count":99999,"at":\(Int(now.timeIntervalSince1970 * 1000))},
         {"kind":"ping_sent","at":0}]
        """
        let items = ActivityHistory.decode(Data(json.utf8), now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .linkReceived)
        XCTAssertNil(items[0].preview)
        XCTAssertNil(items[0].appName)
        XCTAssertEqual(items[0].count, 9_999)
        XCTAssertTrue(ActivityHistory.decode(Data("not json".utf8), now: now).isEmpty)
    }

    // MARK: Folders (Files 2.0)

    /// The record's field set, pinned on purpose: folders added fileCount, bytes (shared with clipboard offers)
    /// and destination. Folder and destination names stay on this Mac like file names.
    func testTheRecordFieldsArePinned() throws {
        let item = ActivityItem(id: 1, kind: .folderSent, deviceID: "d", deviceName: "OnePlus 11", fileName: "Photos", preview: nil, appName: nil,
                                sensitive: false, automatic: false, count: 1, at: now, bytes: 2_469_606_195, content: "links=3", fileCount: 124,
                                destination: "Pictures/Trip")
        let json = try JSONSerialization.jsonObject(with: ActivityHistory.encode([item])) as! [[String: Any]]
        XCTAssertEqual(Set(json[0].keys), ["id", "kind", "deviceID", "deviceName", "fileName", "sensitive", "automatic", "count", "at",
                                           "bytes", "content", "fileCount", "destination"])
        XCTAssertEqual(Set(ActivityKind.allCases.map(\.rawValue)).isSuperset(of: ["folder_sent", "folder_received", "folder_incomplete"]), true)
        XCTAssertEqual([ActivityKind.folderSent, .folderReceived, .folderIncomplete].map(\.category), [.files, .files, .files])
    }

    func testFolderItemsKeepCountsAndDestinationAndOldItemsStillDecode() {
        let long = String(repeating: "p", count: 300)
        var items = ActivityHistory.add([], kind: .folderSent, deviceID: "d", deviceName: "OnePlus 11", fileName: "Photos", bytes: 2_469_606_195,
                                        content: FolderActivityDetail(links: 3, hidden: 12).encoded, fileCount: 124, destination: long, now: now, nextID: 1)
        XCTAssertEqual(items[0].fileCount, 124)
        XCTAssertEqual(items[0].bytes, 2_469_606_195)
        XCTAssertEqual(items[0].destination?.count, ActivityHistory.maximumNameLength)
        // Other kinds never keep folder fields.
        items = ActivityHistory.add(items, kind: .pingSent, deviceID: "d", deviceName: "OnePlus 11", bytes: 5, content: "links=3", fileCount: 3,
                                    destination: "x", now: now, nextID: 2)
        XCTAssertNil(items[0].fileCount)
        XCTAssertNil(items[0].destination)
        XCTAssertNil(items[0].bytes)
        XCTAssertNil(items[0].content)
        let roundTrip = ActivityHistory.decode(try! ActivityHistory.encode(items), now: now)
        XCTAssertEqual(roundTrip, items)
        let old = """
        [{"id":7,"kind":"file_sent","deviceName":"A","fileName":"a.pdf","sensitive":false,"automatic":false,"count":1,"at":\(Int(now.timeIntervalSince1970 * 1000))}]
        """
        let decoded = ActivityHistory.decode(Data(old.utf8), now: now)
        XCTAssertEqual(decoded.first?.fileName, "a.pdf")
        XCTAssertNil(decoded.first?.fileCount)
    }

    func testFolderTitlesAndDetails() {
        let size = ByteCountFormatter.string(fromByteCount: 2_469_606_195, countStyle: .file)
        let done = ByteCountFormatter.string(fromByteCount: 812_000_000, countStyle: .file)
        func item(_ kind: ActivityKind, _ detail: FolderActivityDetail, destination: String? = "Pictures/Trip") -> ActivityItem {
            ActivityItem(id: 1, kind: kind, deviceID: "d", deviceName: "OnePlus 11", fileName: "Photos", preview: nil, appName: nil,
                         sensitive: false, automatic: false, count: 1, at: now, bytes: 2_469_606_195, content: detail.encoded,
                         fileCount: 124, destination: destination)
        }
        let sent = item(.folderSent, FolderActivityDetail(links: 3, hidden: 12, choice: "merge", kept: 12))
        XCTAssertEqual(ActivityText.title(sent, showPreviews: true), "Sent folder Photos (124 files, \(size)) to OnePlus 11 \u{203A} Pictures/Trip")
        XCTAssertEqual(ActivityText.detail(sent, showPreviews: true), "Merged, 12 kept as copies \u{00B7} 3 links and 12 hidden items skipped")
        let incomplete = item(.folderIncomplete, FolderActivityDetail(doneFiles: 37, doneBytes: 812_000_000, failed: 3, end: "lost"), destination: nil)
        XCTAssertEqual(ActivityText.title(incomplete, showPreviews: true), "Folder Photos incomplete: 37 of 124 files (\(done)) to OnePlus 11")
        XCTAssertEqual(ActivityText.detail(incomplete, showPreviews: true), "Connection lost \u{00B7} 3 files failed")
        let cancelled = item(.folderIncomplete, FolderActivityDetail(doneFiles: 0, doneBytes: 0, end: "cancelled"))
        XCTAssertEqual(ActivityText.detail(cancelled, showPreviews: true), "Cancelled")
        let renamed = item(.folderSent, FolderActivityDetail(choice: "new_folder", replaced: 0, savedAs: "Photos (1)"))
        XCTAssertEqual(ActivityText.detail(renamed, showPreviews: true), "Saved as Photos (1)")
        let replaced = item(.folderSent, FolderActivityDetail(system: 48, choice: "replace", replaced: 12))
        XCTAssertEqual(ActivityText.detail(replaced, showPreviews: true), "12 files replaced \u{00B7} 48 system files skipped")
        XCTAssertNil(ActivityText.detail(item(.folderSent, FolderActivityDetail()), showPreviews: true))
        XCTAssertEqual(activityVisual(.folderSent).symbol, "folder")
        // The detail survives names with separators.
        XCTAssertEqual(FolderActivityDetail(FolderActivityDetail(savedAs: "a;b=c (1)").encoded).savedAs, "a;b=c (1)")
    }

    // MARK: Privacy

    @MainActor func testNothingFromTheStreamReachesDiagnostics() throws {
        let secret = "Room 2 at 4, bring the deck"
        let log = ActivityLog(store: nil) { self.now }
        log.record(.clipboardReceived, deviceID: "d", deviceName: "Secret Phone", preview: secret, previews: true)
        log.record(.fileReceived, deviceID: "d", deviceName: "Secret Phone", fileName: "secret-invoice.pdf", previews: true)
        let diagnostics = BridgeyDiagnostics()
        diagnostics.record(category: "clipboard", event: "text_received")
        let report = try diagnostics.report(connectionState: "connected", transfers: [], localFeatures: [:], remoteFeatures: [:])
        let text = String(decoding: report, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("secret-invoice"))
        XCTAssertFalse(text.contains("Secret Phone"))
    }

    func testStreamCodeNeverLogsOrFeedsDiagnostics() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BridgeyMac")
        for name in ["ActivityStream.swift", "StreamModel.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["NSLog(", "print(", "os_log", "Logger(", "diagnostics"] {
                let code = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("*") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                XCTAssertFalse(code.joined(separator: "\n").contains(forbidden), "\(name) uses \(forbidden)")
            }
        }
        // The coordinator's stream hooks pass through recordActivity only; the diagnostics
        // exporter never reads the activity log.
        let pairing = try String(contentsOf: sources.appendingPathComponent("Pairing.swift"), encoding: .utf8)
        let exportStart = try XCTUnwrap(pairing.range(of: "func exportDiagnostics()"))
        let exportBody = pairing[exportStart.upperBound...].prefix(1_500)
        XCTAssertFalse(exportBody.contains("activity"))
        let diagnosticsSource = try String(contentsOf: sources.appendingPathComponent("BridgeyDiagnostics.swift"), encoding: .utf8)
        XCTAssertFalse(diagnosticsSource.contains("Activity"))
    }
}
