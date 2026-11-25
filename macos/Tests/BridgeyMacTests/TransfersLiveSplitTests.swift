import Combine
import XCTest
@testable import BridgeyMac

/// A clock and a run loop for timed work: blocks run in order as the clock moves past them.
@MainActor
final class FakeSchedule {
    var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, block: @MainActor () -> Void)] = []

    var schedule: TransfersCoalescer.Schedule { { [unowned self] delay, block in self.pending.append((self.now + delay, block)) } }

    /// Moves the clock to `time`, running every block due by then (and those they schedule) in order.
    func advance(to time: TimeInterval) {
        while let index = pending.indices.min(by: { pending[$0].at < pending[$1].at }), pending[index].at <= time {
            let job = pending.remove(at: index)
            now = max(now, job.at)
            job.block()
        }
        now = time
    }
}

/// The Transfers window under load: progress redraws the live card alone, history is rebuilt only when it changes,
/// refreshes are coalesced, and a run of transfers brings the window forward once.
@MainActor
final class TransfersLiveSplitTests: XCTestCase {
    private let phone = "11111111-1111-1111-1111-111111111111"
    private let now = Date(timeIntervalSince1970: 1_795_600_000)

    private func entries(_ count: Int) -> [TransferHistoryEntry] {
        (0..<count).map { index in
            TransferHistoryEntry(id: "h\(index)", date: now.addingTimeInterval(-Double(index) * 600 - 60), direction: index % 2 == 0 ? .received : .sent,
                                 deviceID: phone, deviceName: "OnePlus 11 5G", name: index % 3 == 0 ? "IMG_\(index).jpg" : "file \(index).pdf",
                                 bytes: 1_000_000, outcome: .completed, localPath: "/tmp/bridgey-tests-none/\(index)")
        }
    }

    private func receiving(_ bytes: Int64, active: Bool = true) -> FileTransferRow {
        FileTransferRow(id: "live", name: "big.bin", status: active ? "Receiving big.bin" : "Saved big.bin", active: active, startedAt: now,
                        lastProgressAt: now, deviceID: phone, incoming: true, bytesDone: bytes, bytesTotal: 2_000_000_000)
    }

    func testProgressRedrawsTheLiveCardAloneAndHistoryOnlyWhenItChanges() {
        let model = TransfersWindowModel()
        var history = entries(2_000)
        let connected = [TransferDevice(id: phone, name: "OnePlus 11 5G")]
        model.refresh(TransfersSource(rows: [receiving(0)], entries: history, connected: connected), now: now)
        XCTAssertEqual(model.state.items.count, 2_000)
        XCTAssertTrue(model.state.hasLive)
        XCTAssertEqual(model.feed.live.map(\.id), ["live"])

        var stateChanges = 0
        var feedChanges = 0
        let watching = [model.objectWillChange.sink { stateChanges += 1 }, model.feed.objectWillChange.sink { feedChanges += 1 }]
        for step in 1...40 {
            model.refresh(TransfersSource(rows: [receiving(Int64(step) * 50_000_000)], entries: history, connected: connected),
                          now: now.addingTimeInterval(Double(step) * 0.25))
        }
        XCTAssertEqual(stateChanges, 0, "progress leaves the window's state (and so the history) alone")
        XCTAssertGreaterThanOrEqual(feedChanges, 40, "the live card follows every step")
        XCTAssertEqual(model.feed.live.first?.bytesDone, 2_000_000_000)
        XCTAssertEqual(model.feed.speeds["live"] ?? 0, 200_000_000, accuracy: 1, "50 MB a quarter second")

        // It finishes: one change, with the new entry at the top and the live card gone.
        history.insert(TransferHistoryEntry(id: "live", date: now.addingTimeInterval(10), direction: .received, deviceID: phone,
                                            deviceName: "OnePlus 11 5G", name: "big.bin", bytes: 2_000_000_000, outcome: .completed), at: 0)
        model.refresh(TransfersSource(rows: [receiving(2_000_000_000, active: false)], entries: history, connected: connected),
                      now: now.addingTimeInterval(10.25))
        XCTAssertEqual(stateChanges, 1)
        XCTAssertEqual(model.state.items.first?.id, "live")
        XCTAssertFalse(model.state.hasLive)
        XCTAssertTrue(model.feed.live.isEmpty)

        // Nothing new: nothing published.
        let feedBefore = feedChanges
        model.refresh(TransfersSource(rows: [receiving(2_000_000_000, active: false)], entries: history, connected: connected),
                      now: now.addingTimeInterval(11))
        XCTAssertEqual(stateChanges, 1)
        XCTAssertEqual(feedChanges, feedBefore)
        withExtendedLifetime(watching) {}
    }

    func testAFinishedRowAndDeviceNamesRebuildTheHistory() {
        let model = TransfersWindowModel()
        let history = entries(3)
        model.refresh(TransfersSource(rows: [], entries: history), now: now)
        XCTAssertEqual(model.state.items.map(\.id), ["h0", "h1", "h2"])
        // A queued file stopped by a disconnect: a failure history never saw, added from its row.
        let stopped = FileTransferRow(id: "stopped", name: "deck.key", status: "Transfer interrupted; reconnect to retry", active: false,
                                      startedAt: now, retryable: true, lastProgressAt: now, deviceID: "p2")
        model.refresh(TransfersSource(rows: [stopped], entries: history, trusted: [TransferDevice(id: "p2", name: "Pixel 8")]), now: now)
        XCTAssertEqual(model.state.items.first?.id, "stopped")
        XCTAssertEqual(model.state.items.first?.deviceName, "Pixel 8")
        XCTAssertEqual(model.state.devices.map(\.id), ["p2", phone])
        model.refresh(TransfersSource(rows: [stopped], entries: history, trusted: [TransferDevice(id: "p2", name: "Pixel 9")]), now: now)
        XCTAssertEqual(model.state.items.first?.deviceName, "Pixel 9", "a renamed device shows its new name")
    }

    func testTheLiveCardKeepsItsRouteAndNewDaysMoveTheTitles() {
        let model = TransfersWindowModel()
        let chip = TransferRouteChip(text: "Same Wi-Fi", style: .lan)
        let source = TransfersSource(rows: [receiving(10)], entries: entries(2), connected: [TransferDevice(id: phone, name: "OnePlus 11 5G")],
                                     route: { _ in chip })
        model.refresh(source, now: now)
        XCTAssertEqual(model.state.routes[phone], chip)
        var changes = 0
        let watching = model.objectWillChange.sink { changes += 1 }
        model.refresh(source, now: now.addingTimeInterval(60))
        XCTAssertEqual(changes, 0)
        model.refresh(source, now: now.addingTimeInterval(36 * 3_600))
        XCTAssertEqual(changes, 1, "a new day moves Today and Yesterday")
        withExtendedLifetime(watching) {}
    }

    func testTheCoalescerRunsAtMostOncePerInterval() {
        let fake = FakeSchedule()
        var runs: [TimeInterval] = []
        let coalescer = TransfersCoalescer(interval: 0.2, clock: { fake.now }, schedule: fake.schedule) { runs.append(fake.now) }
        coalescer.signal()
        fake.advance(to: 0)
        XCTAssertEqual(runs, [0], "the first change after a quiet spell runs at once")
        // 1,000 progress reports in a second.
        for step in 1...1_000 {
            fake.advance(to: Double(step) / 1_000)
            coalescer.signal()
        }
        fake.advance(to: 2)
        XCTAssertLessThanOrEqual(runs.count, 7)
        XCTAssertGreaterThanOrEqual(runs.count, 5)
        for (earlier, later) in zip(runs, runs.dropFirst()) { XCTAssertGreaterThanOrEqual(later - earlier, 0.2 - 1e-9) }
        XCTAssertEqual(runs.last ?? 0, 1.2, accuracy: 0.01, "the last report is drawn")
        coalescer.signal()
        fake.advance(to: 2)
        XCTAssertEqual(runs.last, 2, "after a quiet spell, at once again")
    }

    func testARunOfTransfersBringsTheWindowForwardOnce() {
        var auto = TransfersAutoShow()
        auto.activeChanged(true, at: 0)
        XCTAssertTrue(auto.transferStarted(at: 0))
        // 200 files from a phone, one after another, nothing active for a moment between them.
        for index in 1...200 {
            let time = Double(index) * 0.3
            XCTAssertFalse(auto.transferStarted(at: time - 0.1), "more files in the same file's run")
            auto.activeChanged(false, at: time)
            auto.activeChanged(true, at: time + 0.15)
            XCTAssertFalse(auto.transferStarted(at: time + 0.15))
        }
        auto.activeChanged(false, at: 70)
        auto.activeChanged(true, at: 75)
        XCTAssertFalse(auto.transferStarted(at: 75), "5 s later is still the same run")
        auto.activeChanged(false, at: 80)
        auto.activeChanged(true, at: 95)
        XCTAssertTrue(auto.transferStarted(at: 95), "after 10 s with nothing moving, a new run")
        auto.activeChanged(false, at: 96)
        XCTAssertTrue(auto.transferStarted(at: 120), "a start reported before activity counts too")
    }

    func testHistoryLinesAreFlatSoTheListStaysLazy() {
        let items = (0..<10).map { index in
            TransferItem(id: "i\(index)", date: now.addingTimeInterval(-Double(index)), name: index < 7 ? "IMG_\(index).jpg" : "doc \(index).pdf",
                         kind: index < 7 ? .photo : .document, direction: .received, deviceID: phone, deviceName: "OnePlus", bytes: 1,
                         fileCount: 1, outcome: .completed, localURL: nil, reason: nil, chip: nil, canRetry: false, canResume: false, sessionOnly: false)
        }
        let days = TransferDays.group(items, now: now, calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_GB"))
        let lines = TransferHistoryLine.lines(days, columns: 3)
        XCTAssertEqual(lines.count, 1 + 3 + 3)
        guard case .title = lines[0], case let .grid(_, first, false) = lines[1], case let .grid(_, last, true) = lines[3],
              case let .row(row) = lines[4] else { return XCTFail("title, grid rows, then rows: \(lines.map(\.id))") }
        XCTAssertEqual(first.map(\.id), ["i0", "i1", "i2"])
        XCTAssertEqual(last.map(\.id), ["i6"])
        XCTAssertEqual(row.id, "i7")
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count, "ids are unique")
        XCTAssertEqual(TransferHistoryLine.lines(days, columns: 0).count, 1 + 7 + 3, "at least one column")
    }
}
