import Foundation
import XCTest
@testable import BridgeyMac

/// The real on-device engine (llama.cpp, Metal) on the 42 synthetic benchmark messages. Runs only
/// when BRIDGEY_OTP_MODEL points at the GGUF file; BRIDGEY_OTP_REPORT, if set, gets a JSON summary:
///   BRIDGEY_OTP_MODEL=/tmp/model.gguf swift test --filter CodeModelBenchmark
final class CodeModelBenchmark: XCTestCase {
    func testRealModelOnTheBenchmarkMessages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BRIDGEY_OTP_MODEL"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set BRIDGEY_OTP_MODEL to the model file to run the benchmark")
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../protocol/test-vectors/otp-samples.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let samples = try XCTUnwrap(root["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 42)

        let engine = LocalCodeEngine(modelPath: { path }, makeRunner: { LlamaRunner() })
        let cold = await engine.timedAnswer(text: CodeModelSample.text, sender: CodeModelSample.sender)
        XCTAssertTrue(cold.loaded)

        var times: [Double] = []
        var found = 0, missed = 0, harmful = 0, correctNone = 0
        var failures: [String] = []
        for sample in samples {
            let id = sample["id"] as! String
            let body = sample["body"] as! String
            let sender = sample["sender"] as! String
            let expected = Set((sample["code"] as! [String]).map { $0.replacingOccurrences(of: "G-", with: "").filter { $0 != "-" && $0 != " " }.uppercased() })
            let timed = await engine.timedAnswer(text: body, sender: sender)
            times.append(timed.seconds)
            var shown: String?
            if case let .candidate(code) = timed.answer { shown = CodeGuard.accept(code, in: body) }
            switch (expected.isEmpty, shown) {
            case (true, nil): correctNone += 1
            case (true, .some): harmful += 1; failures.append("\(id): showed a code for a message without one")
            case (false, nil): missed += 1; failures.append("\(id): missed")
            case let (false, .some(code)):
                if expected.contains(code.uppercased()) { found += 1 } else { harmful += 1; failures.append("\(id): wrong code") }
            }
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        // A second pass (warm), then an unload and a reload, as after 15 idle minutes.
        var warm: [Double] = []
        for sample in samples {
            let body = sample["body"] as! String
            let sender = sample["sender"] as! String
            warm.append(await engine.timedAnswer(text: body, sender: sender).seconds)
        }
        warm.sort()
        engine.unload()
        let reload = await engine.timedAnswer(text: CodeModelSample.text, sender: CodeModelSample.sender)
        let summary: [String: Any] = [
            "warm_median_seconds": warm[warm.count / 2], "warm_p95_seconds": warm[min(warm.count - 1, Int((Double(warm.count) * 0.95).rounded(.up)) - 1)],
            "warm_max_seconds": warm.last ?? 0, "reload_first_seconds": reload.seconds, "first_pass_seconds": times.map { ($0 * 1000).rounded() / 1000 },
            "messages": samples.count, "codes_found": found, "codes_total": samples.filter { !($0["code"] as! [String]).isEmpty }.count,
            "no_code_correct": correctNone, "missed": missed, "harmful": harmful,
            "cold_first_seconds": cold.seconds, "median_seconds": median, "p95_seconds": p95, "max_seconds": sorted.last ?? 0,
            "failures": failures,
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        if let report = environment["BRIDGEY_OTP_REPORT"] { try json.write(to: URL(fileURLWithPath: report)) }
        XCTAssertEqual(harmful, 0, failures.joined(separator: "; "))
        XCTAssertLessThan(median, CodeRelay.budget, "well inside the 2 s budget")
    }
}

/// The real download path against the published `models` release: manifest, pause part-way, resume
/// with a Range request, SHA-256 check, install. Runs only when BRIDGEY_OTP_LIVE_DIR is set (a
/// scratch folder; about 253 MB):
///   BRIDGEY_OTP_LIVE_DIR=/tmp/bridgey-live swift test --filter CodeModelLiveDownload
final class CodeModelLiveDownload: XCTestCase {
    @MainActor func testDownloadsThePublishedModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["BRIDGEY_OTP_LIVE_DIR"], !path.isEmpty else {
            throw XCTSkip("Set BRIDGEY_OTP_LIVE_DIR to download the published model")
        }
        let prefix = "https://github.com/round-robin-solutions/bridgey/releases/download/"
        let manifestURL = try XCTUnwrap(URL(string: prefix + "models/otp-model.json"))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let store = CodeModelStore(files: CodeModelFiles(directory: directory), bundledManifest: nil, manifestURL: manifestURL, assetURLPrefix: prefix)
        await store.refreshManifest(force: true)
        let manifest = try XCTUnwrap(store.manifest, "the published manifest parses")
        print("manifest version \(manifest.version), \(manifest.size) bytes, sha256 \(manifest.sha256)")
        let started = Date()
        store.start()
        let quarter = manifest.size / 4
        while (store.download?.received ?? 0) < quarter, store.installed == nil, Date().timeIntervalSince(started) < 600 {
            if case .failed = store.download?.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        store.pause()
        let pausedAt = try XCTUnwrap(store.download?.received)
        print("paused at \(pausedAt) bytes after \(Date().timeIntervalSince(started)) s")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        store.resume()
        while store.installed == nil, Date().timeIntervalSince(started) < 900 {
            if case let .failed(error) = store.download?.state { XCTFail("download failed: \(error)"); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let installed = try XCTUnwrap(store.installed)
        XCTAssertEqual(installed.sha256, manifest.sha256)
        print("installed \(installed.fileName) in \(Date().timeIntervalSince(started)) s at \(store.modelPath ?? "")")
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
