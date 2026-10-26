import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

/// Codes from messages > On this Mac: manifest, acceptance, resume rules, checksum, engine choice, the
/// local engine with a fake model, and the download with a fake network. No real model or network.
final class CodeModelTests: XCTestCase {
    private let prefix = "https://github.com/round-robin-solutions/bridgey/releases/download/"

    private func manifest(version: Int = 1, size: Int64 = 2_000_000, sha256: String = String(repeating: "a", count: 64),
                          url: String? = nil, terms: String = "gemma-2026-04-01+bridgey-1") -> CodeModelManifest {
        CodeModelManifest(schema: 1, version: version, name: "Test model", url: url ?? prefix + "models/bridgey-otp-v\(version).gguf",
                          size: size, sha256: sha256, termsVersion: terms,
                          licenceURL: "https://ai.google.dev/gemma/terms", prohibitedUseURL: "https://ai.google.dev/gemma/prohibited_use_policy")
    }

    // MARK: Manifest

    func testParsesTheBundledManifest() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/otp-model.json")
        let parsed = try XCTUnwrap(CodeModelManifest.parse(Data(contentsOf: url), assetURLPrefix: prefix))
        XCTAssertEqual(parsed.schema, 1)
        XCTAssertEqual(parsed.fileName, "bridgey-otp-v\(parsed.version).gguf")
        XCTAssertTrue(parsed.url.hasSuffix("/models/" + parsed.fileName), "the asset is named like the file")
        XCTAssertGreaterThan(parsed.size, 200_000_000)
        XCTAssertLessThan(parsed.size, 300_000_000)
    }

    func testManifestRefusesAnythingUnsafeOrMalformed() throws {
        let encoder = JSONEncoder()
        XCTAssertNotNil(CodeModelManifest.parse(try encoder.encode(manifest()), assetURLPrefix: prefix))
        let bad: [CodeModelManifest] = [
            manifest(url: "http://github.com/round-robin-solutions/bridgey/releases/download/models/x.gguf"),
            manifest(url: "https://example.com/model.gguf"),
            manifest(sha256: "ABC"),
            manifest(sha256: String(repeating: "A", count: 64)),
            manifest(size: 10),
            manifest(size: 3_000_000_000),
            manifest(version: 0),
            manifest(terms: ""),
            CodeModelManifest(schema: 2, version: 1, name: "x", url: prefix + "models/x.gguf", size: 2_000_000, sha256: String(repeating: "a", count: 64),
                              termsVersion: "t", licenceURL: "https://a", prohibitedUseURL: "https://b"),
            CodeModelManifest(schema: 1, version: 1, name: "x", url: prefix + "models/x.gguf", size: 2_000_000, sha256: String(repeating: "a", count: 64),
                              termsVersion: "t", licenceURL: "http://a", prohibitedUseURL: "https://b"),
        ]
        for item in bad {
            XCTAssertNil(CodeModelManifest.parse(try encoder.encode(item), assetURLPrefix: prefix), "\(item)")
        }
        XCTAssertNil(CodeModelManifest.parse(Data("not json".utf8), assetURLPrefix: prefix))
        XCTAssertNil(CodeModelManifest.parse(try encoder.encode(manifest()), assetURLPrefix: "http://insecure/"))
    }

    func testNewestManifestWins() {
        let one = manifest(version: 1), two = manifest(version: 2)
        XCTAssertEqual(CodeModelManifest.newest(one, two), two)
        XCTAssertEqual(CodeModelManifest.newest(two, one), two)
        XCTAssertEqual(CodeModelManifest.newest(nil, one), one)
        XCTAssertEqual(CodeModelManifest.newest(one, nil), one)
    }

    // MARK: Acceptance

    func testAcceptanceIsRecordedWithDateAndVersionAndCoversOnlyTheSameTerms() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let record = CodeModelAcceptance(acceptedAt: date, modelVersion: 1, termsVersion: "gemma-2026-04-01+bridgey-1")
        let data = try XCTUnwrap(CodeModelAcceptance.encode([record]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"modelVersion\":1"))
        XCTAssertTrue(json.contains("2026-10-26"), "ISO 8601 date: \(json)")
        XCTAssertEqual(CodeModelAcceptance.decode(data), [record])
        XCTAssertEqual(CodeModelAcceptance.decode(nil), [])
        XCTAssertEqual(CodeModelAcceptance.decode(Data("[{]".utf8)), [])
        XCTAssertTrue(record.covers(manifest(version: 2)), "a new model under the same terms needs no new tick")
        XCTAssertFalse(record.covers(manifest(terms: "gemma-2027-01-01+bridgey-2")))
    }

    // MARK: Engine choice

    func testEngineDefaultsToThisMacExceptForAnEarlierCloudOptIn() {
        XCTAssertEqual(CodeEngine.stored(nil, codesWereEnabled: false), .local)
        XCTAssertEqual(CodeEngine.stored(nil, codesWereEnabled: true), .cloud)
        XCTAssertEqual(CodeEngine.stored("local", codesWereEnabled: true), .local)
        XCTAssertEqual(CodeEngine.stored("cloud", codesWereEnabled: false), .cloud)
        XCTAssertEqual(CodeEngine.stored("nonsense", codesWereEnabled: false), .local)
    }

    func testReaderUsesTheChosenEngine() async {
        let runner = FakeRunner(output: #"{"kind":"otp","code":"482913"}"#)
        let engine = LocalCodeEngine(modelPath: { "/tmp/model.gguf" }, makeRunner: { runner })
        let text = "OTP is 482913 for txn of INR 2,499.00. Do not share."
        let local = codeReader(engine: .local, local: engine, relay: nil, installID: "")
        XCTAssertTrue(local.source is LocalCodeSource)
        let outcome = await local.read(text: text, sender: "HDFCBK")
        XCTAssertEqual(outcome, .code("482913"))
        XCTAssertEqual(runner.prompts.last, "Find the one-time code in this SMS. Answer JSON.\nSender: HDFCBK\nSMS: \(text)")
        let cloud = codeReader(engine: .cloud, local: engine, relay: URL(string: "https://relay.example"), installID: String(repeating: "a", count: 64))
        XCTAssertTrue(cloud.source is CloudCodeSource)
        let noRelay = await codeReader(engine: .cloud, local: engine, relay: nil, installID: "").read(text: text, sender: nil)
        XCTAssertEqual(noRelay, .fallback(.notConfigured))
    }

    // MARK: Local engine

    func testPromptAnswersParseLikeTheResearchHarness() {
        XCTAssertEqual(CodeModelPrompt.parse(#"{"kind":"otp","code":"482913"}"#), .candidate("482913"))
        XCTAssertEqual(CodeModelPrompt.parse(#" {"kind":"otp","code":"G-482913"}<end_of_turn>"#), .candidate("G-482913"))
        XCTAssertEqual(CodeModelPrompt.parse(#"{"kind":"none","code":null}"#), .noCode)
        XCTAssertEqual(CodeModelPrompt.parse(#"{"kind":"otp","code":""}"#), .noCode)
        XCTAssertEqual(CodeModelPrompt.parse(#"{"kind":"otp","code":null}"#), .noCode)
        XCTAssertEqual(CodeModelPrompt.parse("I think the code is 482913"), .failed(.invalidResponse))
        XCTAssertEqual(CodeModelPrompt.parse(#"{"kind":"otp","code":"4829"#), .failed(.invalidResponse))
        XCTAssertTrue(CodeModelPrompt.isComplete(#"{"kind":"none","code":null}"#))
        XCTAssertFalse(CodeModelPrompt.isComplete(#"{"kind":"otp","co"#))
        XCTAssertEqual(CodeModelPrompt.user(sender: nil, text: " OTP 1234 "), "Find the one-time code in this SMS. Answer JSON.\nSender: \nSMS: OTP 1234")
    }

    func testLocalEngineLoadsOnceAndAnswersThroughTheGuard() async {
        let runner = FakeRunner(output: #"{"kind":"otp","code":"5minMe"}"#)
        var made = 0
        let engine = LocalCodeEngine(modelPath: { "/tmp/model.gguf" }, makeRunner: { made += 1; return runner })
        let reader = CodeReader(source: LocalCodeSource(engine: engine))
        let first = await reader.read(text: "Delivery in 5 min me aa jayega", sender: nil)
        XCTAssertEqual(first, .noCode, "the guard refuses words joined into a code")
        runner.output = #"{"kind":"otp","code":"7392"}"#
        let second = await reader.read(text: "OTP 7392 hai", sender: nil)
        XCTAssertEqual(second, .code("7392"))
        let status = await engine.status()
        XCTAssertTrue(status.loaded)
        XCTAssertEqual(status.loads, 1)
        XCTAssertEqual(made, 1)
        XCTAssertEqual(runner.loadedPaths, ["/tmp/model.gguf"])
    }

    func testLocalEngineUnloadsAfterIdleAndLoadsAgain() async throws {
        let runner = FakeRunner(output: #"{"kind":"none","code":null}"#)
        let engine = LocalCodeEngine(idleTimeout: 0.1, modelPath: { "/tmp/model.gguf" }, makeRunner: { runner })
        let first = await engine.timedAnswer(text: "Hello 1234", sender: nil)
        XCTAssertTrue(first.loaded)
        XCTAssertEqual(first.answer, .noCode)
        let warm = await engine.timedAnswer(text: "Hello 1234", sender: nil)
        XCTAssertFalse(warm.loaded)
        try await Task.sleep(nanoseconds: 400_000_000)
        let idle = await engine.status()
        XCTAssertFalse(idle.loaded, "unloaded after the idle timeout")
        XCTAssertEqual(runner.unloads, 1)
        let again = await engine.timedAnswer(text: "Hello 1234", sender: nil)
        XCTAssertTrue(again.loaded)
        let status = await engine.status()
        XCTAssertEqual(status.loads, 2)
    }

    func testLocalEngineFallsBackWithoutAModelOrWhenItFails() async {
        let missing = LocalCodeEngine(modelPath: { nil }, makeRunner: { FakeRunner(output: "") })
        let none = await CodeReader(source: LocalCodeSource(engine: missing)).read(text: "OTP 1234", sender: nil)
        XCTAssertEqual(none, .fallback(.modelMissing))
        XCTAssertEqual(none.diagnosticName, "model_missing")

        let broken = FakeRunner(output: "")
        broken.loadError = LocalModelError.loadFailed
        let failing = LocalCodeEngine(modelPath: { "/tmp/model.gguf" }, makeRunner: { broken })
        let failed = await CodeReader(source: LocalCodeSource(engine: failing)).read(text: "OTP 1234", sender: nil)
        XCTAssertEqual(failed, .fallback(.unavailable))

        let rambling = LocalCodeEngine(modelPath: { "/tmp/model.gguf" }, makeRunner: { FakeRunner(output: "The code is 1234") })
        let invalid = await CodeReader(source: LocalCodeSource(engine: rambling)).read(text: "OTP 1234", sender: nil)
        XCTAssertEqual(invalid, .fallback(.invalidResponse))
    }

    func testSlowModelStillFallsBackAtTheBudget() async {
        let runner = FakeRunner(output: #"{"kind":"otp","code":"1234"}"#)
        runner.delay = 1.0
        let engine = LocalCodeEngine(modelPath: { "/tmp/model.gguf" }, makeRunner: { runner })
        let started = Date()
        let outcome = await CodeReader(source: LocalCodeSource(engine: engine), budget: 0.2).read(text: "OTP 1234", sender: nil)
        XCTAssertEqual(outcome, .fallback(.timeout))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
    }

    // MARK: Resume rules

    func testResumePlan() {
        XCTAssertEqual(RangeResume.plan(partialSize: nil, expectedSize: 100, sameFile: true), .fresh)
        XCTAssertEqual(RangeResume.plan(partialSize: 0, expectedSize: 100, sameFile: true), .fresh)
        XCTAssertEqual(RangeResume.plan(partialSize: 40, expectedSize: 100, sameFile: true), .resume(from: 40))
        XCTAssertEqual(RangeResume.plan(partialSize: 40, expectedSize: 100, sameFile: false), .fresh)
        XCTAssertEqual(RangeResume.plan(partialSize: 100, expectedSize: 100, sameFile: true), .verify)
        XCTAssertEqual(RangeResume.plan(partialSize: 120, expectedSize: 100, sameFile: true), .fresh)
        XCTAssertNil(RangeResume.header(offset: 0))
        XCTAssertEqual(RangeResume.header(offset: 40), "bytes=40-")
    }

    func testRangeAnswers() {
        XCTAssertEqual(RangeResume.decide(status: 200, contentRange: nil, offset: 40, expectedSize: 100), .write(from: 0), "range ignored: start again")
        XCTAssertEqual(RangeResume.decide(status: 206, contentRange: "bytes 40-99/100", offset: 40, expectedSize: 100), .write(from: 40))
        XCTAssertEqual(RangeResume.decide(status: 206, contentRange: "bytes 40-99/*", offset: 40, expectedSize: 100), .write(from: 40))
        XCTAssertEqual(RangeResume.decide(status: 206, contentRange: "bytes 0-99/100", offset: 40, expectedSize: 100), .restart, "wrong start")
        XCTAssertEqual(RangeResume.decide(status: 206, contentRange: "bytes 40-99/200", offset: 40, expectedSize: 100), .restart, "a different file")
        XCTAssertEqual(RangeResume.decide(status: 206, contentRange: nil, offset: 40, expectedSize: 100), .restart)
        XCTAssertEqual(RangeResume.decide(status: 416, contentRange: "bytes */100", offset: 100, expectedSize: 100), .complete)
        XCTAssertEqual(RangeResume.decide(status: 416, contentRange: "bytes */100", offset: 40, expectedSize: 100), .restart)
        XCTAssertEqual(RangeResume.decide(status: 404, contentRange: nil, offset: 0, expectedSize: 100), .fail(status: 404))
        XCTAssertNil(RangeResume.parseContentRange("items 1-2/3"))
        XCTAssertNil(RangeResume.parseContentRange("bytes 9-2/30"))
        XCTAssertEqual(RangeResume.parseContentRange("bytes 1-2/3")?.total, 3)
    }

    func testTransferRateSmoothsAndEstimatesTimeLeft() {
        var rate = TransferRate()
        rate.add(time: 0, bytes: 0)
        XCTAssertNil(rate.bytesPerSecond)
        rate.add(time: 0.1, bytes: 1_000_000)
        XCTAssertNil(rate.bytesPerSecond, "too soon to say")
        rate.add(time: 1, bytes: 10_000_000)
        XCTAssertEqual(rate.bytesPerSecond ?? 0, 10_000_000, accuracy: 1)
        XCTAssertEqual(rate.secondsLeft(remaining: 50_000_000) ?? 0, 5, accuracy: 0.01)
        rate.add(time: 2, bytes: 12_000_000)
        XCTAssertEqual(rate.bytesPerSecond ?? 0, 7_600_000, accuracy: 1)
        rate.reset()
        XCTAssertNil(rate.secondsLeft(remaining: 1))
    }

    func testWordsForTheProgressLine() {
        XCTAssertEqual(CodeModelText.megabytes(253_115_200), "253 MB")
        XCTAssertEqual(CodeModelText.amount(112_400_000, of: 253_115_200), "112 of 253 MB")
        XCTAssertEqual(CodeModelText.timeLeft(16.2), "about 17 s left")
        XCTAssertEqual(CodeModelText.timeLeft(130), "about 3 min left")
        XCTAssertFalse(CodeModelText.failure(.offline).isEmpty)
        for error: CodeModelDownloadError in [.noSpace(needed: 253_000_000, available: 1_000), .offline, .checksum, .server(503), .server(0), .disk] {
            XCTAssertFalse(CodeModelText.failure(error).contains("\u{2014}"), "no em dashes")
        }
    }

    // MARK: Checksum

    func testSha256OfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try sha256Hex(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let big = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try big.write(to: url)
        XCTAssertEqual(try sha256Hex(of: url), SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined(), "read in pieces")
    }

    // MARK: Download

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-model-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func payload(_ size: Int = 1_500_000) -> (Data, String) {
        let data = Data((0..<size).map { UInt8(($0 * 7) % 256) })
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @MainActor
    private func store(_ transport: FakeModelTransport, manifest: CodeModelManifest, space: Int64? = 10_000_000_000,
                       runner: FakeRunner = FakeRunner(output: #"{"kind":"otp","code":"482913"}"#)) -> CodeModelStore {
        CodeModelStore(files: CodeModelFiles(directory: directory), transport: transport, bundledManifest: manifest,
                       manifestURL: URL(string: prefix + "models/otp-model.json"), assetURLPrefix: prefix,
                       spaceQuery: { _ in space }, makeRunner: { runner })
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @MainActor
    func testDownloadsChecksAndInstallsOutsideBackups() async throws {
        let (data, sha) = payload()
        let transport = FakeModelTransport(data: data)
        let model = manifest(size: Int64(data.count), sha256: sha)
        let runner = FakeRunner(output: #"{"kind":"otp","code":"482913"}"#)
        let store = store(transport, manifest: model, runner: runner)
        store.start()
        await waitUntil { store.installed != nil }
        let installed = try XCTUnwrap(store.installed)
        XCTAssertEqual(installed.version, 1)
        XCTAssertEqual(installed.sha256, sha)
        XCTAssertNil(store.download)
        XCTAssertTrue(store.justFinished)
        let file = directory.appendingPathComponent(model.fileName)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(store.modelPath, file.path)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("download.json").path))
        XCTAssertEqual(transport.ranges, [nil])

        // Settings' Test reads the sample with the model and times it.
        store.runTest()
        await waitUntil { store.testResult != nil }
        XCTAssertEqual(store.testResult?.code, "482913")
        XCTAssertEqual(store.testResult?.failed, false)
        // The warm-up after the download read the synthetic messages once.
        await waitUntil { runner.prompts.count >= CodeModelSample.warmUp.count + 1 }
        XCTAssertGreaterThanOrEqual(runner.prompts.count, CodeModelSample.warmUp.count + 1)

        // A second launch finds the model on disk.
        let again = self.store(transport, manifest: model)
        XCTAssertEqual(again.installed, installed)

        store.remove()
        XCTAssertNil(store.installed)
        XCTAssertNil(store.modelPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testResumesWithARangeAfterTheNetworkDrops() async throws {
        let (data, sha) = payload()
        let transport = FakeModelTransport(data: data)
        transport.dropAfter = [600_000]
        let store = store(transport, manifest: manifest(size: Int64(data.count), sha256: sha))
        store.start()
        await waitUntil { store.download?.state == .failed(.offline) }
        XCTAssertEqual(store.download?.state, .failed(.offline))
        let kept = try XCTUnwrap(store.download?.received)
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, Int64(data.count))
        store.retry()
        await waitUntil { store.installed != nil }
        XCTAssertNotNil(store.installed)
        XCTAssertEqual(transport.ranges.count, 2)
        XCTAssertEqual(transport.ranges.last ?? nil, "bytes=\(kept)-")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("bridgey-otp-v1.gguf")), data)
    }

    @MainActor
    func testPauseSurvivesARestartAndResumes() async throws {
        let (data, sha) = payload(3_000_000)
        let transport = FakeModelTransport(data: data)
        transport.chunkDelay = 0.03
        let model = manifest(size: Int64(data.count), sha256: sha)
        let first = store(transport, manifest: model)
        first.start()
        await waitUntil { (first.download?.received ?? 0) > 100_000 }
        first.pause()
        XCTAssertEqual(first.download?.state, .paused)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(first.download?.received ?? 0, Int64(data.count))

        // The app quits and opens again: the download is still there, paused where it stopped.
        transport.chunkDelay = 0
        let second = store(transport, manifest: model)
        let restored = try XCTUnwrap(second.download)
        XCTAssertEqual(restored.state, .paused, "a pause by the user stays paused")
        XCTAssertGreaterThan(restored.received, 0)
        second.resume()
        await waitUntil { second.installed != nil }
        XCTAssertNotNil(second.installed)
        XCTAssertEqual(transport.ranges.last ?? nil, "bytes=\(restored.received)-")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(model.fileName)), data)
    }

    @MainActor
    func testAnInterruptedDownloadCarriesOnAfterARestart() async throws {
        let (data, sha) = payload()
        let model = manifest(size: Int64(data.count), sha256: sha)
        // What a quit mid-download leaves: part of the file and a record that it was running.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.prefix(500_000).write(to: directory.appendingPathComponent(model.fileName + ".part"))
        try JSONEncoder().encode(CodeModelDownloadRecord(manifest: model, userPaused: false)).write(to: directory.appendingPathComponent("download.json"))
        let transport = FakeModelTransport(data: data)
        let store = store(transport, manifest: model)
        await waitUntil { store.installed != nil }
        XCTAssertNotNil(store.installed)
        XCTAssertEqual(transport.ranges, ["bytes=500000-"])
    }

    @MainActor
    func testServerThatIgnoresRangesStartsTheFileAgain() async throws {
        let (data, sha) = payload()
        let transport = FakeModelTransport(data: data)
        transport.dropAfter = [400_000]
        transport.ignoreRanges = true
        let store = store(transport, manifest: manifest(size: Int64(data.count), sha256: sha))
        store.start()
        await waitUntil { store.download?.state == .failed(.offline) }
        store.retry()
        await waitUntil { store.installed != nil }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("bridgey-otp-v1.gguf")), data)
    }

    @MainActor
    func testDamagedFileIsFetchedOnceMoreThenReported() async throws {
        let (data, _) = payload()
        let transport = FakeModelTransport(data: data)
        let store = store(transport, manifest: manifest(size: Int64(data.count), sha256: String(repeating: "0", count: 64)))
        store.start()
        await waitUntil { store.download?.state == .failed(.checksum) }
        XCTAssertEqual(store.download?.state, .failed(.checksum))
        XCTAssertEqual(transport.ranges, [nil, nil], "one automatic retry from the start")
        XCTAssertNil(store.installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bridgey-otp-v1.gguf.part").path), "the damaged file is deleted")
    }

    @MainActor
    func testDamagedOnceThenGoodInstalls() async throws {
        let (data, sha) = payload()
        let transport = FakeModelTransport(data: data)
        transport.corruptFirst = true
        let store = store(transport, manifest: manifest(size: Int64(data.count), sha256: sha))
        store.start()
        await waitUntil { store.installed != nil }
        XCTAssertNotNil(store.installed)
        XCTAssertEqual(transport.ranges.count, 2)
    }

    @MainActor
    func testNotEnoughSpaceStopsBeforeDownloading() async {
        let (data, sha) = payload()
        let transport = FakeModelTransport(data: data)
        let store = store(transport, manifest: manifest(size: Int64(data.count), sha256: sha), space: 50_000_000)
        store.start()
        XCTAssertEqual(store.download?.state, .failed(.noSpace(needed: Int64(data.count), available: 50_000_000)))
        XCTAssertTrue(transport.ranges.isEmpty, "nothing was requested")
        store.cancel()
        XCTAssertNil(store.download)
    }

    @MainActor
    func testServerErrorsAreReportedAndCancelCleansUp() async {
        let (data, sha) = payload()
        let transport = FakeModelTransport(data: data)
        transport.status = 503
        let store = store(transport, manifest: manifest(size: Int64(data.count), sha256: sha))
        store.start()
        await waitUntil { store.download?.state == .failed(.server(503)) }
        XCTAssertEqual(store.download?.state, .failed(.server(503)))
        store.cancel()
        XCTAssertNil(store.download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("download.json").path))
    }

    @MainActor
    func testAnUpdateFromTheManifestReplacesTheOldModel() async throws {
        let (one, shaOne) = payload(1_200_000)
        let (two, shaTwo) = payload(1_300_000)
        let transport = FakeModelTransport(data: one)
        let first = manifest(version: 1, size: Int64(one.count), sha256: shaOne)
        let store = store(transport, manifest: first)
        store.start()
        await waitUntil { store.installed != nil }
        XCTAssertNil(store.update)

        let second = manifest(version: 2, size: Int64(two.count), sha256: shaTwo)
        transport.manifestBody = try JSONEncoder().encode(second)
        await store.refreshManifest(force: true)
        XCTAssertEqual(store.update, second)
        transport.data = two
        store.start()
        await waitUntil { store.installed?.version == 2 }
        XCTAssertEqual(store.installed?.version, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.fileName).path), "the old file is removed")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(second.fileName)), two)
        XCTAssertNil(store.update)
    }
}

// MARK: - Fakes

final class FakeRunner: LocalModelRunner, @unchecked Sendable {
    var output: String
    var loadError: Error?
    var delay: TimeInterval = 0
    private let lock = NSLock()
    private(set) var loadedPaths: [String] = []
    private var promptLog: [String] = []
    var prompts: [String] { lock.withLock { promptLog } }
    private(set) var unloads = 0
    private var loaded = false

    init(output: String) { self.output = output }

    func load(path: String) throws {
        if let loadError { throw loadError }
        loadedPaths.append(path)
        loaded = true
    }

    func complete(user: String, maxTokens: Int) throws -> String {
        precondition(loaded)
        lock.withLock { promptLog.append(user) }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return output
    }

    func unload() {
        if loaded { unloads += 1 }
        loaded = false
    }
}

/// Serves `data` in 64 KB pieces, honouring Range unless told not to; can drop the connection
/// after a number of bytes (once per entry in `dropAfter`), corrupt the first body, or fail.
final class FakeModelTransport: CodeModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    var data: Data
    var dropAfter: [Int] = []
    var ignoreRanges = false
    var corruptFirst = false
    var status = 200
    var chunkDelay: TimeInterval = 0
    var manifestBody = Data()
    private var requested: [String?] = []

    init(data: Data) { self.data = data }

    var ranges: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func get(_ url: URL, range: String?) -> AsyncThrowingStream<CodeModelTransportEvent, Error> {
        lock.lock()
        requested.append(range)
        let drop = dropAfter.isEmpty ? nil : dropAfter.removeFirst()
        let corrupt = corruptFirst
        corruptFirst = false
        let body = data
        let status = status
        let delay = chunkDelay
        let ignore = ignoreRanges
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var start = 0
                if !ignore, let range, let from = Int(range.dropFirst(6).dropLast()) { start = from }
                guard status == 200 else {
                    continuation.yield(.response(status: status, contentRange: nil))
                    continuation.finish()
                    return
                }
                if start > 0 {
                    continuation.yield(.response(status: 206, contentRange: "bytes \(start)-\(body.count - 1)/\(body.count)"))
                } else {
                    continuation.yield(.response(status: 200, contentRange: nil))
                }
                var offset = start
                var sent = 0
                while offset < body.count {
                    if Task.isCancelled { return continuation.finish(throwing: CancellationError()) }
                    if let drop, sent >= drop { return continuation.finish(throwing: URLError(.networkConnectionLost)) }
                    let end = min(body.count, offset + 65_536)
                    var piece = body.subdata(in: offset..<end)
                    if corrupt, offset == 0 { piece[0] ^= 0xFF }
                    continuation.yield(.data(piece))
                    sent += piece.count
                    offset = end
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetch(_ url: URL) async throws -> (Int, Data) {
        (200, lock.withLock { manifestBody })
    }
}
