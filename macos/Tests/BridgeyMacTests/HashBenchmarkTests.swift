import XCTest
@testable import BridgeyMac

final class HashBenchmarkTests: XCTestCase {
    func testBlake3OfficialVectors() {
        XCTAssertEqual(Blake3Vectors.cases.count, 35)
        XCTAssertEqual(Blake3Vectors.failures(), [])
    }

    func testEmptyInputHash() {
        let h = Blake3BlockHasher()
        XCTAssertEqual(Blake3Vectors.hex(h.digest()), "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
    }

    func testExtrapolationScalesToTenGigabytes() {
        let base = BenchModeResult(mode: .writeOnly, bytes: 1_000_000_000, wallSeconds: 4, cpuSeconds: 1)
        let b3 = BenchModeResult(mode: .blake3Block, bytes: 1_000_000_000, wallSeconds: 5, cpuSeconds: 3)
        let e = benchExtrapolate(baseline: base, result: b3)
        XCTAssertEqual(e.wallSeconds, 50, accuracy: 1e-9)
        XCTAssertEqual(e.extraWallSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(e.extraCpuSeconds, 20, accuracy: 1e-9)
        XCTAssertEqual(base.mbPerSecond, 250, accuracy: 1e-9)
    }

    func testSpaceRule() {
        let gib: Int64 = 1024 * 1024 * 1024
        XCTAssertEqual(benchRequiredFreeBytes(gib), 3 * gib)
        XCTAssertTrue(benchHasEnoughSpace(free: 3 * gib, fileBytes: gib))
        XCTAssertFalse(benchHasEnoughSpace(free: 3 * gib - 1, fileBytes: gib))
    }

    func testEngineRunsEveryModeAndCleansUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let results = try HashBenchmark(dir: dir).runAll(fileBytes: Int64(4 * benchBlockBytes))
        XCTAssertEqual(results.map(\.mode), BenchMode.allCases)
        XCTAssertTrue(results.allSatisfy { $0.verifyMismatches == 0 })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        let report = BenchReport(sizeBytes: Int64(4 * benchBlockBytes), startedAt: Date(), device: "test", appVersion: "t", vectorsPassed: true, readNote: "n", results: results)
        let json = try JSONSerialization.jsonObject(with: Data(report.jsonString().utf8)) as? [String: Any]
        XCTAssertEqual((json?["modes"] as? [Any])?.count, 5)
        XCTAssertFalse(report.jsonString().contains("\u{2014}"))
    }
}
