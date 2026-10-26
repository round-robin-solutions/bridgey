import Foundation

/*
 * Codes from messages, "On this Mac": the on-device code model. A fine-tuned Gemma 3 270M (GGUF,
 * Q4_K_M) that Bridgey downloads once, on first use, from a release on Round Robin's fork, pinned by
 * SHA-256 in a small manifest. llama.cpp runs it in-process with Metal (LlamaRunner.swift). The
 * model loads on the first code message and unloads after 15 idle minutes.
 *
 * This file holds the parts with no UI: the engine choice, the manifest, the acceptance record, the
 * HTTP Range resume rules, the speed estimate, the prompt and the engine. CodeModelStore.swift does
 * the download; CodeModelViews.swift draws it.
 */

/// Which engine reads codes. On this Mac is the default; Cloud is opt-in with its own warning.
enum CodeEngine: String, CaseIterable, Equatable {
    case local
    case cloud

    /// The stored choice. A Mac that turned codes on before there was a choice had agreed to the
    /// cloud, so it keeps the cloud until the user picks again.
    static func stored(_ value: String?, codesWereEnabled: Bool) -> CodeEngine {
        if let value, let engine = CodeEngine(rawValue: value) { return engine }
        return codesWereEnabled ? .cloud : .local
    }
}

// MARK: - Manifest

/// The model manifest, a JSON asset on the fork's `models` release. A newer `version` there is offered
/// as an update without an app update. The app also ships the manifest it was built with.
struct CodeModelManifest: Codable, Equatable {
    static let schema = 1

    let schema: Int
    let version: Int
    /// Shown in Settings, e.g. "Gemma 3 270M, fine-tuned for codes".
    let name: String
    let url: String
    let size: Int64
    let sha256: String
    /// The terms the user accepts; a change asks again before the next download.
    let termsVersion: String
    let licenceURL: String
    let prohibitedUseURL: String

    static let maximumBytes: Int64 = 2_000_000_000

    var fileName: String { "bridgey-otp-v\(version).gguf" }

    /// Nil unless the manifest is well formed and its model comes from `assetURLPrefix` over HTTPS.
    static func parse(_ data: Data, assetURLPrefix: String) -> CodeModelManifest? {
        guard data.count <= 16_384, let manifest = try? JSONDecoder().decode(CodeModelManifest.self, from: data) else { return nil }
        return manifest.isValid(assetURLPrefix: assetURLPrefix) ? manifest : nil
    }

    func isValid(assetURLPrefix: String) -> Bool {
        guard schema == Self.schema, version >= 1, !name.isEmpty, !termsVersion.isEmpty else { return false }
        guard assetURLPrefix.hasPrefix("https://"), url.hasPrefix(assetURLPrefix), URL(string: url) != nil else { return false }
        guard size > 1_000_000, size <= Self.maximumBytes else { return false }
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return false }
        return licenceURL.hasPrefix("https://") && prohibitedUseURL.hasPrefix("https://")
    }

    /// The newer of two manifests (the bundled one and the one fetched), by version.
    static func newest(_ a: CodeModelManifest?, _ b: CodeModelManifest?) -> CodeModelManifest? {
        guard let a else { return b }
        guard let b else { return a }
        return b.version > a.version ? b : a
    }
}

/// The user's acceptance of the model's terms, kept on this Mac with the date and model version.
struct CodeModelAcceptance: Codable, Equatable {
    let acceptedAt: Date
    let modelVersion: Int
    let termsVersion: String

    func covers(_ manifest: CodeModelManifest) -> Bool { termsVersion == manifest.termsVersion }

    static func encode(_ records: [CodeModelAcceptance]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(records)
    }

    static func decode(_ data: Data?) -> [CodeModelAcceptance] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CodeModelAcceptance].self, from: data)) ?? []
    }
}

/// The model file on disk, written after its SHA-256 matched.
struct InstalledCodeModel: Codable, Equatable {
    let version: Int
    let name: String
    let size: Int64
    let sha256: String
    let fileName: String
    let installedAt: Date
}

// MARK: - Resume

/// HTTP Range rules for the download, kept pure so they are tested without a network.
enum RangeResume {
    enum Plan: Equatable {
        case fresh
        case resume(from: Int64)
        /// The partial file is already complete: only the checksum is left.
        case verify
    }

    /// What to do with a partial file of `partialSize` bytes for a model of `expectedSize` bytes.
    /// A partial file only counts when it was written for the same file (same SHA-256).
    static func plan(partialSize: Int64?, expectedSize: Int64, sameFile: Bool) -> Plan {
        guard sameFile, let partialSize, partialSize > 0 else { return .fresh }
        if partialSize == expectedSize { return .verify }
        if partialSize > expectedSize { return .fresh }
        return .resume(from: partialSize)
    }

    static func header(offset: Int64) -> String? { offset > 0 ? "bytes=\(offset)-" : nil }

    enum Decision: Equatable {
        /// Write the body after `offset` bytes already on disk (0 starts the file again).
        case write(from: Int64)
        /// The server says the range starts at the end: the file is complete.
        case complete
        /// The answer does not fit the partial file: delete it and ask for the whole file.
        case restart
        case fail(status: Int)
    }

    /// Reads the server's answer to a request that asked for bytes from `offset`.
    static func decide(status: Int, contentRange: String?, offset: Int64, expectedSize: Int64) -> Decision {
        switch status {
        case 200:
            // A full body: the server ignored the range, so the file starts again.
            return .write(from: 0)
        case 206:
            guard let range = contentRange.flatMap(parseContentRange), range.start == offset,
                  range.total == nil || range.total == expectedSize else { return .restart }
            return .write(from: offset)
        case 416:
            return offset == expectedSize ? .complete : .restart
        default:
            return .fail(status: status)
        }
    }

    /// "bytes 100-252/253" or "bytes */253".
    static func parseContentRange(_ value: String) -> (start: Int64?, end: Int64?, total: Int64?)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst(6)
        let halves = spec.split(separator: "/", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return nil }
        let total = halves[1] == "*" ? nil : Int64(halves[1])
        if halves[0] == "*" { return (nil, nil, total) }
        let bounds = halves[0].split(separator: "-", maxSplits: 1).map { Int64($0) }
        guard bounds.count == 2, let start = bounds[0], let end = bounds[1], start <= end else { return nil }
        return (start, end, total)
    }
}

/// A smoothed transfer speed and time left, from (time, total bytes) samples.
struct TransferRate: Equatable {
    private(set) var bytesPerSecond: Double?
    private var last: (time: TimeInterval, bytes: Int64)?

    /// Adds a sample; samples closer than half a second are skipped so the figure stays calm.
    mutating func add(time: TimeInterval, bytes: Int64) {
        guard let last else {
            self.last = (time, bytes)
            return
        }
        let elapsed = time - last.time
        guard elapsed >= 0.5 else { return }
        let instant = Double(max(0, bytes - last.bytes)) / elapsed
        bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
        self.last = (time, bytes)
    }

    /// Restarts the estimate, e.g. after a pause.
    mutating func reset() {
        bytesPerSecond = nil
        last = nil
    }

    func secondsLeft(remaining: Int64) -> Double? {
        guard let bytesPerSecond, bytesPerSecond > 1 else { return nil }
        return Double(max(0, remaining)) / bytesPerSecond
    }

    static func == (lhs: TransferRate, rhs: TransferRate) -> Bool { lhs.bytesPerSecond == rhs.bytesPerSecond }
}

// MARK: - Prompt and answer

/// The prompt the model was trained on (research `common.py`, `user_prompt`) and its JSON answer.
enum CodeModelPrompt {
    static let instruction = "Find the one-time code in this SMS. Answer JSON."
    static let maximumAnswerTokens = 24

    static func user(sender: String?, text: String) -> String {
        let from = CodeRelay.prefix(sender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", utf16Limit: CodeRelay.maximumSenderLength)
        return "\(instruction)\nSender: \(from)\nSMS: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// `{"kind":"otp","code":"482913"}` gives a candidate, `{"kind":"none","code":null}` no code;
    /// anything else is an invalid answer (the plain notification shows).
    static func parse(_ output: String) -> CodeRelayAnswer {
        guard let open = output.firstIndex(of: "{"), let close = output[open...].firstIndex(of: "}"),
              let object = (try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8))) as? [String: Any],
              let kind = object["kind"] as? String else { return .failed(.invalidResponse) }
        guard kind == "otp", let code = object["code"] as? String, !code.isEmpty else { return .noCode }
        return .candidate(code)
    }

    /// The answer is complete once its JSON object closes.
    static func isComplete(_ output: String) -> Bool {
        guard let open = output.firstIndex(of: "{") else { return false }
        return output[open...].contains("}")
    }
}

// MARK: - Engine

/// Runs one model in-process. LlamaRunner is the real one; tests use a fake. Only ever used on the
/// engine's own queue.
protocol LocalModelRunner: AnyObject {
    func load(path: String) throws
    /// One greedy completion for one user message.
    func complete(user: String, maxTokens: Int) throws -> String
    func unload()
}

enum LocalModelError: Error, Equatable {
    case loadFailed
    case contextFailed
    case promptTooLong
    case decodeFailed
}

/// The on-device engine: loads the model on first use, answers one message at a time on its own
/// queue, and unloads the model after `idleTimeout` without messages (or when it is removed).
final class LocalCodeEngine: @unchecked Sendable {
    static let defaultIdleTimeout: TimeInterval = 15 * 60

    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.code-model", qos: .userInitiated)
    private let makeRunner: () -> LocalModelRunner
    private let modelPath: @Sendable () -> String?
    private let idleTimeout: TimeInterval
    // Queue-confined state.
    private var runner: LocalModelRunner?
    private var loadedPath: String?
    private var idleUnload: DispatchWorkItem?
    private var loadCount = 0

    init(idleTimeout: TimeInterval = LocalCodeEngine.defaultIdleTimeout,
         modelPath: @escaping @Sendable () -> String?,
         makeRunner: @escaping () -> LocalModelRunner) {
        self.idleTimeout = idleTimeout
        self.modelPath = modelPath
        self.makeRunner = makeRunner
    }

    /// One answer, with how long it took and whether the model had to load first.
    struct Timed: Equatable {
        let answer: CodeRelayAnswer
        let seconds: TimeInterval
        let loaded: Bool
    }

    func answer(text: String, sender: String?) async -> CodeRelayAnswer {
        await timedAnswer(text: text, sender: sender).answer
    }

    func timedAnswer(text: String, sender: String?) async -> Timed {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.answerNow(text: text, sender: sender)) }
        }
    }

    /// Unloads now, e.g. after Remove model. The next message loads it again if a file is there.
    func unload() {
        queue.async { self.unloadNow() }
    }

    /// For tests: whether a model is in memory and how many times one was loaded.
    func status() async -> (loaded: Bool, loads: Int) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: (self.runner != nil, self.loadCount)) }
        }
    }

    private func answerNow(text: String, sender: String?) -> Timed {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> TimeInterval { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
        guard let path = modelPath() else {
            unloadNow()
            return Timed(answer: .failed(.modelMissing), seconds: 0, loaded: false)
        }
        var loaded = false
        do {
            if runner == nil || loadedPath != path {
                unloadNow()
                let fresh = makeRunner()
                try fresh.load(path: path)
                runner = fresh
                loadedPath = path
                loadCount += 1
                loaded = true
            }
            let output = try runner!.complete(user: CodeModelPrompt.user(sender: sender, text: text), maxTokens: CodeModelPrompt.maximumAnswerTokens)
            scheduleIdleUnload()
            return Timed(answer: CodeModelPrompt.parse(output), seconds: elapsed(), loaded: loaded)
        } catch {
            unloadNow()
            return Timed(answer: .failed(.unavailable), seconds: elapsed(), loaded: loaded)
        }
    }

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.unloadNow() }
        idleUnload = work
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    private func unloadNow() {
        idleUnload?.cancel()
        idleUnload = nil
        runner?.unload()
        runner = nil
        loadedPath = nil
    }
}

/// The local engine as a source for `CodeReader`.
struct LocalCodeSource: CodeAnswerSource {
    let engine: LocalCodeEngine

    func answer(text: String, sender: String?) async -> CodeRelayAnswer {
        await engine.answer(text: text, sender: sender)
    }
}

/// The reader for the chosen engine. Cloud needs a relay address in this build.
func codeReader(engine: CodeEngine, local: LocalCodeEngine, relay: URL?, installID: String) -> CodeReader {
    switch engine {
    case .local: CodeReader(source: LocalCodeSource(engine: local))
    case .cloud: CodeReader(baseURL: relay, installID: installID)
    }
}

/// llama.cpp's Apple framework needs macOS 13.3 or later.
func localCodeModelSupported(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
    version.majorVersion > 13 || (version.majorVersion == 13 && version.minorVersion >= 3)
}

/// A synthetic message for Settings' Test button.
enum CodeModelSample {
    static let sender = "HDFCBK"
    static let text = "OTP is 482913 for txn of INR 2,499.00 at AMAZON PAY on HDFC Bank card ending 4417. Valid till 14:32. Do not share OTP for security reasons."

    /// Synthetic messages of different lengths, read once right after a download. The first run of
    /// llama.cpp on a Mac compiles its Metal shaders (several seconds; macOS keeps them afterwards),
    /// so this keeps that cost away from the first real code.
    static let warmUp: [(sender: String, text: String)] = [
        ("AX-SWIGGY", "7392 is your Swiggy OTP."),
        (sender, text),
        ("JD-SBIINB", "Dear Customer, Rs 15,000.00 has been debited from your A/c XX8821 on 26-10-26 to UPI ref 629184736251. If not done by you, call 1800 1234 to block UPI. Your OTP 730164 for adding a new payee is valid for 10 minutes; never share it with anyone, including bank staff. Available balance Rs 1,24,560.18."),
    ]
}
