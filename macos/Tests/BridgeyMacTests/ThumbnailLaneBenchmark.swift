import Foundation
import XCTest
@testable import BridgeyMac

/// Thumbnails through the real browse client over a simulated LAN link: time to the first screen (30) and to
/// 200, and how much of each batch is image data. Prints the numbers; the asserts are generous budgets so a
/// slow CI runner does not fail, the printed values are what the report quotes.
///
/// Link model: 2 ms one way (4 ms RTT), 40 MB/s (about 320 Mbit/s of Wi-Fi 5 goodput), base64 on the wire,
/// and 3 ms of phone work per thumbnail (loadThumbnail from MediaStore's cache plus WebP encoding).
@MainActor
final class ThumbnailLaneBenchmark: XCTestCase {
    private struct Result {
        var first30: TimeInterval = 0
        var all: TimeInterval = 0
        var requests = 0
        var batches = 0
        var payloadBytes = 0
        var imageBytes = 0
    }

    private func run(thumbBytes: Int, count: Int = 200) -> Result {
        let phone = LoopbackPhone()
        let controller = PhoneFilesController(host: phone)
        phone.controller = controller
        phone.link = (latency: 0.002, bytesPerSecond: 40_000_000)
        let perThumb: TimeInterval = 0.003
        var result = Result()
        let server = thumbnailServer(bytes: thumbBytes)
        phone.server = { kind, payload in
            let answers = server(kind, payload)
            result.requests += kind == BrowseKind.mediaThumbnails ? 1 : 0
            for (_, data) in answers {
                result.batches += 1
                result.payloadBytes += data.count
                if let batch = try? JSONDecoder().decode(MediaThumbnailsBatchPayload.self, from: data) {
                    result.imageBytes += batch.thumbs.reduce(0) { $0 + $1.data.count }
                }
            }
            return answers
        }
        // Phone work scales with the thumbnails in each batch: spread over its messages.
        let perBatch = Int((Double(BrowseKind.mediaPartPlaintext) / Double(thumbBytes * 4 / 3 + 120)).rounded(.down))
        phone.workPerMessage = perThumb * Double(max(1, perBatch))
        var delivered = 0
        var done = false
        let start = Date()
        controller.thumbnails(phoneID: phone.phoneID, entries: mediaEntries(count), size: 256, lane: "grid", deliver: { _, _ in
            delivered += 1
            if delivered == 30 { result.first30 = Date().timeIntervalSince(start) }
        }, finished: { _ in
            result.all = Date().timeIntervalSince(start)
            done = true
        })
        waitUntil(30) { done }
        XCTAssertEqual(delivered, count)
        return result
    }

    /// 500 ms on a Mac (about 115 to 140 ms measured on an M4). Shared CI runners (CI=1, as RR CI's
    /// GitHub-hosted lane sets) run the simulated link 5 to 7 times slower: 320 to 870 ms over three
    /// runs on macos-15 on 2026-10-31, so there the budget only catches a lane that got several times slower.
    private static var coldBudget: TimeInterval { ProcessInfo.processInfo.environment["CI"] == nil ? 0.5 : 2.0 }

    func testThumbnailLaneOverSimulatedLAN() {
        for size in [9_000, 20_000] {
            let result = run(thumbBytes: size)
            let efficiency = Double(result.imageBytes) / Double(max(1, result.payloadBytes))
            print(String(format: "BENCH thumbnails %d B each: first 30 in %.0f ms, 200 in %.0f ms, %d requests, %d batches, %.1f%% of batch plaintext is image data",
                         size, result.first30 * 1_000, result.all * 1_000, result.requests, result.batches, efficiency * 100))
            XCTAssertLessThan(result.first30, Self.coldBudget, "first screen within the \(Int(Self.coldBudget * 1_000)) ms cold budget")
            XCTAssertGreaterThan(efficiency, 0.9)
        }
    }
}
