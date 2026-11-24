import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// The Transfers window's pure parts: day groups and labels, filters, route chips, today's totals, the media and
/// row split, the rolling speed, and the strings.
final class TransfersWindowTests: XCTestCase {
    private let phone = "11111111-1111-1111-1111-111111111111"
    private let pixel = "22222222-2222-2222-2222-222222222222"
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 16, minute: 5))! }
    private let british = Locale(identifier: "en_GB")

    private func entry(_ id: String, _ date: Date, _ name: String, device: String? = nil, direction: TransferHistoryEntry.Direction = .received,
                       outcome: TransferHistoryEntry.Outcome = .completed, folder: Bool = false, bytes: Int64 = 1_000,
                       speed: Double? = nil) -> TransferHistoryEntry {
        let device = device ?? phone
        return TransferHistoryEntry(id: id, date: date, direction: direction, deviceID: device, deviceName: device == phone ? "OnePlus 11 5G" : "Pixel 8",
                                    name: name, isFolder: folder, fileCount: folder ? 48 : 1, bytes: bytes, outcome: outcome,
                                    localPath: "/tmp/\(name)", bytesPerSecond: speed)
    }

    private func items(_ entries: [TransferHistoryEntry], rows: [FileTransferRow] = []) -> [TransferItem] {
        TransferItems.make(entries: entries, rows: rows, deviceName: { $0 == self.phone ? "OnePlus 11 5G" : "Pixel 8" })
    }

    // MARK: Days

    func testDayGroupsAndBritishLabels() {
        let list = items([
            entry("a", now.addingTimeInterval(-600), "IMG_1.jpg"),
            entry("b", now.addingTimeInterval(-1_200), "Design brief v3.pdf", outcome: .failed),
            entry("c", now.addingTimeInterval(-86_400), "Invoices November.zip"),
            entry("d", calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 10))!, "Trip", folder: true),
            entry("e", calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 10))!, "clip.mp4"),
        ])
        let days = TransferDays.group(list, now: now, calendar: calendar, locale: british)
        XCTAssertEqual(days.map(\.title), ["Today", "Yesterday", "Sat 21 Nov", "Wed 31 Dec 2025"])
        XCTAssertEqual(days[0].media.map(\.id), ["a"])
        XCTAssertEqual(days[0].rows.map(\.id), ["b"])
        XCTAssertEqual(days[3].media.map(\.id), ["e"], "a video goes in the grid")
        XCTAssertEqual(Set(days.map(\.id)).count, days.count, "day ids are unique")
    }

    func testMediaAndRowSplit() {
        let list = items([
            entry("photo", now, "IMG_1.HEIC"),
            entry("video", now.addingTimeInterval(-1), "VID_1.mp4"),
            entry("failedPhoto", now.addingTimeInterval(-2), "IMG_2.jpg", outcome: .incomplete),
            entry("doc", now.addingTimeInterval(-3), "notes.txt"),
            entry("folder", now.addingTimeInterval(-4), "Photos", folder: true),
        ])
        let day = TransferDays.group(list, now: now, calendar: calendar, locale: british)[0]
        XCTAssertEqual(day.media.map(\.id), ["photo", "video"])
        XCTAssertEqual(day.rows.map(\.id), ["failedPhoto", "doc", "folder"], "failures, documents and folders are rows, newest first")
    }

    // MARK: Filters

    func testFiltersCombine() {
        let list = items([
            entry("photo", now, "IMG_0412.jpg"),
            entry("video", now, "VID_trip.mov", device: pixel, direction: .sent),
            entry("pdf", now, "Trip invoice.pdf", outcome: .failed),
            entry("folder", now, "Trip", direction: .sent, folder: true),
        ])
        func ids(_ filter: TransfersFilter) -> [String] { list.filter(filter.matches).map(\.id).sorted() }
        XCTAssertEqual(ids(TransfersFilter()), ["folder", "pdf", "photo", "video"])
        XCTAssertEqual(ids(TransfersFilter(category: .media)), ["photo", "video"])
        XCTAssertEqual(ids(TransfersFilter(category: .documents)), ["pdf"])
        XCTAssertEqual(ids(TransfersFilter(category: .folders)), ["folder"])
        XCTAssertEqual(ids(TransfersFilter(category: .failed)), ["pdf"])
        XCTAssertEqual(ids(TransfersFilter(deviceID: pixel)), ["video"])
        XCTAssertEqual(ids(TransfersFilter(direction: .sent)), ["folder", "video"])
        XCTAssertEqual(ids(TransfersFilter(direction: .received)), ["pdf", "photo"])
        XCTAssertEqual(ids(TransfersFilter(query: "trip")), ["folder", "pdf", "video"], "search is case insensitive, names only")
        XCTAssertEqual(ids(TransfersFilter(category: .media, query: "trip")), ["video"])
        XCTAssertEqual(ids(TransfersFilter(category: .folders, direction: .received)), [])
        XCTAssertTrue(TransfersFilter().isEmpty)
        XCTAssertFalse(TransfersFilter(query: "a").isEmpty)
    }

    // MARK: Rows joined with history

    func testItemsJoinRowsAndAddSessionFailures() {
        let failed = FileTransferRow(id: "pdf", name: "Design brief v3.pdf", status: "File transfer failed", active: false, startedAt: now,
                                     retryable: true, deviceID: phone)
        let interrupted = FileTransferRow(id: "queued", name: "Deck.key", status: "Transfer interrupted; reconnect to retry", active: false,
                                          startedAt: now.addingTimeInterval(-60), retryable: true, deviceID: phone)
        let running = FileTransferRow(id: "live", name: "VID.mp4", status: "Sending", active: true, deviceID: phone)
        let finished = FileTransferRow(id: "done", name: "a.txt", status: "a.txt saved on Android", active: false, deviceID: phone)
        let list = items([entry("pdf", now, "Design brief v3.pdf", direction: .sent, outcome: .failed)], rows: [failed, interrupted, running, finished])
        XCTAssertEqual(list.map(\.id), ["pdf", "queued"], "active and completed rows are not history")
        XCTAssertTrue(list[0].canRetry)
        XCTAssertEqual(list[0].reason, "Could not finish")
        XCTAssertEqual(TransferFailure.chip(list[0]), .failed)
        XCTAssertTrue(list[1].sessionOnly)
        XCTAssertEqual(list[1].reason, "OnePlus 11 5G disconnected")
        XCTAssertEqual(TransferFailure.chip(list[1]), .stopped)
        XCTAssertEqual(list[1].direction, .sent)
    }

    func testFailureReasonsInPlainWords() {
        func reason(_ status: String) -> String {
            TransferFailure.reason(row: FileTransferRow(id: "x", name: "x", status: status, active: false), outcome: .failed, deviceName: "Pixel 8")
        }
        XCTAssertEqual(reason(TransferStall.message), "No data for 2 minutes")
        XCTAssertEqual(reason("File verification failed"), "The file arrived damaged")
        XCTAssertEqual(reason("File transfer is turned off on Android"), "File transfer is off on Pixel 8")
        XCTAssertEqual(reason("Transfer cancelled"), "Cancelled")
        XCTAssertEqual(TransferFailure.reason(row: nil, outcome: .incomplete, deviceName: "", isFolder: true), "Not every file arrived")
        XCTAssertEqual(TransferFailure.reason(row: nil, outcome: .incomplete, deviceName: ""), "Stopped before the end")
    }

    // MARK: Live card

    func testLiveCardShowsTwoAndCountsTheRest() {
        let rows = [
            FileTransferRow(id: "q1", name: "a", status: "Queued", active: true, startedAt: now, queued: true),
            FileTransferRow(id: "r2", name: "b", status: "", active: true, startedAt: now.addingTimeInterval(2)),
            FileTransferRow(id: "r1", name: "c", status: "", active: true, startedAt: now.addingTimeInterval(1)),
            FileTransferRow(id: "r3", name: "d", status: "", active: true, startedAt: now.addingTimeInterval(3)),
            FileTransferRow(id: "done", name: "e", status: "", active: false, startedAt: now),
        ]
        let ordered = TransferLiveList.ordered(rows)
        XCTAssertEqual(ordered.map(\.id), ["r1", "r2", "r3", "q1"], "running first, oldest first, finished rows left out")
        let live = ordered.map { TransferLive.make($0, deviceName: { $0 }) }
        let split = TransferLiveList.split(live)
        XCTAssertEqual(split.shown.map(\.id), ["r1", "r2"])
        XCTAssertEqual(split.waiting, 2)
        XCTAssertEqual(TransferLiveList.split(live, limit: 1).waiting, 3, "a short window shows one row")
        let queuedOnly = TransferLiveList.split([live[3]])
        XCTAssertEqual(queuedOnly.shown.map(\.id), ["q1"], "with nothing running, the first queued row shows")
        XCTAssertEqual(queuedOnly.waiting, 0)
        XCTAssertEqual(TransfersText.waiting(2), "2 more waiting")
    }

    func testFolderLiveRowCountsPhotosOrFiles() {
        var progress = FolderProgress()
        progress.phase = .sending
        progress.filesDone = 12
        progress.filesTotal = 48
        progress.bytesDone = 88_000_000
        progress.bytesTotal = 326_000_000
        progress.recent = ["Trip/IMG_1.jpg", "Trip/IMG_2.HEIC"]
        var summary = FolderRowSummary(phoneName: "OnePlus 11 5G", displayName: "Trip to Pondicherry")
        summary.state = .running
        summary.incoming = true
        summary.progress = progress
        let row = FileTransferRow(id: "f", name: "Trip to Pondicherry", status: "", active: true, folder: summary, deviceID: phone)
        let live = TransferLive.make(row, deviceName: { _ in "OnePlus 11 5G" })
        XCTAssertEqual(live.fileProgress, "12 of 48 photos")
        XCTAssertTrue(live.incoming)
        XCTAssertEqual(live.fraction ?? 0, 88.0 / 326.0, accuracy: 0.0001)
        summary.progress.recent.append("Trip/notes.txt")
        let mixed = TransferLive.make(FileTransferRow(id: "f", name: "Trip", status: "", active: true, folder: summary), deviceName: { $0 })
        XCTAssertEqual(mixed.fileProgress, "12 of 48 files")
    }

    func testRollingSpeedAndTimeLeft() {
        let meter = TransferRollingSpeed()
        let start = now
        meter.record("a", bytes: 0, at: start)
        XCTAssertNil(meter.speed("a", now: start), "one sample says nothing yet")
        for second in 1...6 { meter.record("a", bytes: Int64(second) * 10_000_000, at: start.addingTimeInterval(Double(second))) }
        XCTAssertEqual(meter.speed("a", now: start.addingTimeInterval(6)) ?? 0, 10_000_000, accuracy: 1)
        // A burst moves the average only by its share of the last 3 seconds.
        meter.record("a", bytes: 100_000_000, at: start.addingTimeInterval(7))
        XCTAssertEqual(meter.speed("a", now: start.addingTimeInterval(7)) ?? 0, 20_000_000, accuracy: 1)
        XCTAssertEqual(meter.speed("a", now: start.addingTimeInterval(11)), 0, "nothing moved for the whole window")
        meter.keep([])
        XCTAssertNil(meter.speed("a", now: start))
        XCTAssertEqual(TransfersText.timeLeft(remaining: 54_000_000, bytesPerSecond: 21_400_000), "3 s left")
        XCTAssertEqual(TransfersText.timeLeft(remaining: 600_000_000, bytesPerSecond: 5_000_000), "2 min left")
        XCTAssertEqual(TransfersText.timeLeft(remaining: 30_000_000_000, bytesPerSecond: 5_000_000), "1 h 40 min left")
        XCTAssertNil(TransfersText.timeLeft(remaining: 10, bytesPerSecond: nil))
        XCTAssertNil(TransferSpeed.average(bytes: 500_000, since: start, now: start.addingTimeInterval(1)), "too small to say")
        XCTAssertEqual(TransferSpeed.average(bytes: 40_000_000, since: start, now: start.addingTimeInterval(2)) ?? 0, 20_000_000, accuracy: 1)
    }

    // MARK: Route chip

    func testRouteChips() {
        XCTAssertEqual(makeTransferRouteChip(tier: .lan, socketRoute: .sameNetwork, tunnelRoute: nil, relay: nil),
                       TransferRouteChip(text: "Same Wi-Fi", style: .lan))
        XCTAssertEqual(makeTransferRouteChip(tier: .socket, socketRoute: .privateNetwork, tunnelRoute: nil, relay: nil),
                       TransferRouteChip(text: "Tailscale", style: .privateNetwork))
        XCTAssertEqual(makeTransferRouteChip(tier: .socket, socketRoute: .otherNetwork, tunnelRoute: nil, relay: nil),
                       TransferRouteChip(text: "Private network", style: .privateNetwork))
        XCTAssertEqual(makeTransferRouteChip(tier: .tunnel, socketRoute: .sameNetwork, tunnelRoute: "lan", relay: nil),
                       TransferRouteChip(text: "Same Wi-Fi", style: .lan))
        XCTAssertEqual(makeTransferRouteChip(tier: .tunnel, socketRoute: .sameNetwork, tunnelRoute: "vpn", relay: "tailscale"),
                       TransferRouteChip(text: "Tailscale", style: .privateNetwork))
        XCTAssertEqual(makeTransferRouteChip(tier: .tunnel, socketRoute: .sameNetwork, tunnelRoute: "direct", relay: nil),
                       TransferRouteChip(text: "Direct", style: .direct))
        XCTAssertEqual(makeTransferRouteChip(tier: .tunnel, socketRoute: .sameNetwork, tunnelRoute: "relay", relay: "cf"),
                       TransferRouteChip(text: "Relay (Cloudflare)", style: .relay))
        XCTAssertEqual(makeTransferRouteChip(tier: .tunnel, socketRoute: .sameNetwork, tunnelRoute: "relay", relay: nil),
                       TransferRouteChip(text: "Relay", style: .relay))
        XCTAssertNil(makeTransferRouteChip(tier: .tunnel, socketRoute: .sameNetwork, tunnelRoute: nil, relay: nil))
    }

    // MARK: Totals

    func testTodaysTotalsFromHistory() {
        let entries = [
            entry("a", now.addingTimeInterval(-60), "VID.mp4", bytes: 400_000_000, speed: 38_200_000),
            entry("b", now.addingTimeInterval(-120), "IMG.jpg", bytes: 18_000_000, speed: 21_000_000),
            entry("c", now.addingTimeInterval(-86_400), "Old.zip", bytes: 2_000_000_000, speed: 90_000_000),
        ]
        let totals = TransferTotals.today(entries, now: now, calendar: calendar)
        XCTAssertEqual(totals?.bytes, 418_000_000)
        XCTAssertEqual(totals?.fastest, 38_200_000)
        XCTAssertEqual(TransferTotals.text(entries, now: now, calendar: calendar),
                       "Today: \(TransfersText.bytes(418_000_000)) moved, fastest \(TransfersText.bytes(38_200_000))/s")
        XCTAssertEqual(TransferTotals.text([entry("x", now, "a.txt", bytes: 5_000)], now: now, calendar: calendar),
                       "Today: \(TransfersText.bytes(5_000)) moved", "no speed known: no fastest")
        XCTAssertNil(TransferTotals.text([entries[2]], now: now, calendar: calendar), "nothing moved today")
    }

    // MARK: Kinds

    func testKindsAndTiles() {
        XCTAssertEqual(TransferKind.of(name: "IMG_1.HEIC", isFolder: false), .photo)
        XCTAssertEqual(TransferKind.of(name: "Record.mp4", isFolder: false), .video)
        XCTAssertEqual(TransferKind.of(name: "brief.pdf", isFolder: false), .document)
        XCTAssertEqual(TransferKind.of(name: "Photos", isFolder: true), .folder)
        XCTAssertEqual(TransferKind.of(name: "README", isFolder: false), .document)
        XCTAssertEqual(TransferTile.of(name: "brief.pdf", kind: .document), TransferTile(label: "PDF", symbol: nil, style: .warn))
        XCTAssertEqual(TransferTile.of(name: "accounts.json", kind: .document), TransferTile(label: "JSON", symbol: nil, style: .blue))
        XCTAssertEqual(TransferTile.of(name: "Invoices.zip", kind: .document).style, .purple)
        XCTAssertEqual(TransferTile.of(name: "archive.longext", kind: .document).symbol, "doc")
    }

    // MARK: History speed

    func testHistoryEntryKeepsSpeedAndOldFilesStillRead() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let timed = entry("a", now, "a.mp4", speed: 12_500_000)
        let round = try decoder.decode(TransferHistoryEntry.self, from: encoder.encode(timed))
        XCTAssertEqual(round.bytesPerSecond, 12_500_000)
        let untimed = try encoder.encode(entry("b", now, "b.txt"))
        XCTAssertFalse(String(decoding: untimed, as: UTF8.self).contains("bytesPerSecond"), "older builds see the same file")
        XCTAssertNil(try decoder.decode(TransferHistoryEntry.self, from: untimed).bytesPerSecond)
    }

    func testRowStartsMovingOnTheFirstBytes() {
        let start = now
        var row = FileTransferRow(id: "a", name: "a", status: "", active: true, bytesDone: 0)
        row.markMoving(previous: nil, bytes: 0, now: start)
        XCTAssertNil(row.movingSince)
        var next = FileTransferRow(id: "a", name: "a", status: "", active: true, bytesDone: 2_000_000)
        next.markMoving(previous: row, bytes: 2_000_000, now: start.addingTimeInterval(1))
        XCTAssertEqual(next.movingSince, start.addingTimeInterval(1))
        XCTAssertEqual(next.movingSinceBytes, 2_000_000)
        var later = FileTransferRow(id: "a", name: "a", status: "", active: false, bytesDone: 9_000_000)
        later.markMoving(previous: next, bytes: 9_000_000, now: start.addingTimeInterval(5))
        XCTAssertEqual(later.movingSince, start.addingTimeInterval(1), "the first moment stays")
        XCTAssertEqual(later.movingSinceBytes, 2_000_000)
    }

    // MARK: Strings

    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEveryKeyIsInEnglishAndRussianWithoutDashes() throws {
        let english = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings")) as? [String: String])
        let russian = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Resources/ru.lproj/Localizable.strings")) as? [String: String])
        let pattern = try NSRegularExpression(pattern: #"L10n\.text\("([^"]+)""#)
        var keys = Set<String>()
        for file in ["TransfersModel.swift", "TransfersWindowView.swift", "FileTransferWindow.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/BridgeyMac/\(file)"), encoding: .utf8)
            XCTAssertFalse(source.contains("\u{2014}"), "\(file) has an em dash")
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) { keys.insert(String(source[range])) }
            }
        }
        XCTAssertGreaterThan(keys.count, 30)
        for key in keys {
            let value = try XCTUnwrap(english[key], "\(key) is missing from en.lproj")
            let translated = try XCTUnwrap(russian[key], "\(key) is missing from ru.lproj")
            for text in [value, translated] {
                XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "\(key) has a dash")
            }
        }
    }
}

/// The header's window buttons, and clicks on the header reaching its controls under the tall title bar.
@MainActor
final class TransfersWindowChromeTests: XCTestCase {
    func testButtonsCentreInTheHeaderAndHeaderControlsTakeClicks() throws {
        _ = NSApplication.shared
        let window = TransfersNSWindow(contentRect: NSRect(x: 200, y: 200, width: 820, height: 640),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        var tapped = 0
        let probe = VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { tapped += 1 } label: { Color.red.frame(width: 160, height: 30) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .frame(height: TransfersWindowView.headerHeight)
            Spacer()
        }
        .frame(width: 820, height: 640)
        window.contentView = NSHostingView(rootView: probe.ignoresSafeArea())
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        window.placeWindowButtons()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.placeWindowButtons()

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let centre = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        XCTAssertEqual(window.frame.height - centre.y, TransfersWindowView.headerHeight / 2, accuracy: 2, "buttons centre in the header")
        XCTAssertEqual(close.convert(close.bounds, to: nil).minX, 18, accuracy: 2)

        // A click in the middle of the button, 29 pt from the top: inside the tall title bar.
        let point = NSPoint(x: 820 - 18 - 80, y: window.frame.height - TransfersWindowView.headerHeight / 2)
        let hit = window.contentView?.superview?.hitTest(point)
        let reachesContent = hit.map { $0.isDescendant(of: window.contentView!) } ?? false
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(tapped, 1, "the header control took the click (hit view: \(hit.map { String(describing: type(of: $0)) } ?? "none"), content: \(reachesContent))")
    }
}
