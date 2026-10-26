import CryptoKit
import Foundation
import Network

/*
 * Download, check and keep the on-device code model. One file, about 253 MB, from the manifest's
 * URL on Round Robin's fork. The download resumes with an HTTP Range request after a pause, a lost
 * network or an app restart; the SHA-256 is checked at the end, and a damaged file is fetched once
 * more before Bridgey says so. The folder is in the edition's Application Support and is excluded
 * from backups.
 */

enum CodeModelDownloadError: Equatable {
    case noSpace(needed: Int64, available: Int64)
    case offline
    case checksum
    case server(Int)
    case disk
}

struct CodeModelDownload: Equatable {
    enum State: Equatable {
        case running
        case paused
        case verifying
        case failed(CodeModelDownloadError)
    }

    var manifest: CodeModelManifest
    var received: Int64
    var state: State
    var bytesPerSecond: Double?
    var secondsLeft: Double?

    var fraction: Double { manifest.size > 0 ? min(1, max(0, Double(received) / Double(manifest.size))) : 0 }
}

struct CodeModelTestResult: Equatable {
    /// The code the guard accepted, or nil.
    let code: String?
    let seconds: TimeInterval
    /// The model had to load first, so the time includes loading.
    let loaded: Bool
    let failed: Bool
}

/// Where the model lives: `~/Library/Application Support/in.roundrobin.bridgey/Models/`.
struct CodeModelFiles: Sendable {
    let directory: URL

    static func standard() -> CodeModelFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return CodeModelFiles(directory: base.appendingPathComponent("\(Edition.supportFolderName)/Models", isDirectory: true))
    }

    var installedRecord: URL { directory.appendingPathComponent("installed.json") }
    var downloadRecord: URL { directory.appendingPathComponent("download.json") }
    func model(_ fileName: String) -> URL { directory.appendingPathComponent(fileName) }
    func partial(_ manifest: CodeModelManifest) -> URL { directory.appendingPathComponent(manifest.fileName + ".part") }

    /// Creates the folder (owner only) and keeps it out of Time Machine and other backups.
    func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.excludeFromBackup(directory)
    }

    static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }

    func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// The download in progress, so it can resume after the app restarts.
struct CodeModelDownloadRecord: Codable, Equatable {
    let manifest: CodeModelManifest
    let userPaused: Bool
}

enum CodeModelTransportEvent: Sendable {
    case response(status: Int, contentRange: String?)
    case data(Data)
}

/// The network, behind a protocol so tests serve bytes from memory.
protocol CodeModelTransport: Sendable {
    /// A GET that streams the body. Cancelling the consuming task cancels the request.
    func get(_ url: URL, range: String?) -> AsyncThrowingStream<CodeModelTransportEvent, Error>
    /// A small GET (the manifest).
    func fetch(_ url: URL) async throws -> (Int, Data)
}

/// URLSession, no cache and no cookies; a 30 second stall counts as a lost connection.
struct URLSessionCodeModelTransport: CodeModelTransport {
    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = false
        return configuration
    }

    func get(_ url: URL, range: String?) -> AsyncThrowingStream<CodeModelTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            let relay = StreamRelay(continuation: continuation)
            let session = URLSession(configuration: Self.configuration(), delegate: relay, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.setValue("BridgeyRR/1 (macOS)", forHTTPHeaderField: "User-Agent")
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    func fetch(_ url: URL) async throws -> (Int, Data) {
        let session = URLSession(configuration: Self.configuration())
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("BridgeyRR/1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private final class StreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let continuation: AsyncThrowingStream<CodeModelTransportEvent, Error>.Continuation

        init(continuation: AsyncThrowingStream<CodeModelTransportEvent, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            continuation.yield(.response(status: http?.statusCode ?? 0, contentRange: http?.value(forHTTPHeaderField: "Content-Range")))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            session.finishTasksAndInvalidate()
        }
    }
}

/// How a download attempt ended, short of success.
enum CodeModelTransferFailure: Error, Equatable {
    case restart
    case server(Int)
    case disk
    case offline
    case tooLarge
}

/// One HTTP attempt: asks for the bytes after `offset`, writes them to the partial file and returns
/// the partial file's size when the body ends. `progress` gets the running total.
func transferCodeModel(manifest: CodeModelManifest, offset: Int64, partial: URL, transport: CodeModelTransport,
                       progress: @Sendable (Int64) -> Void) async throws -> Int64 {
    guard let url = URL(string: manifest.url) else { throw CodeModelTransferFailure.server(0) }
    var handle: FileHandle?
    defer { try? handle?.close() }
    var written: Int64 = offset
    var lastReport: UInt64 = 0
    func report() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastReport >= 100_000_000 || written == manifest.size else { return }
        lastReport = now
        progress(written)
    }
    do {
        for try await event in transport.get(url, range: RangeResume.header(offset: offset)) {
            switch event {
            case let .response(status, contentRange):
                switch RangeResume.decide(status: status, contentRange: contentRange, offset: offset, expectedSize: manifest.size) {
                case let .write(from):
                    handle = try openPartial(partial, keeping: from)
                    written = from
                    progress(written)
                case .complete:
                    return offset
                case .restart:
                    throw CodeModelTransferFailure.restart
                case let .fail(status):
                    throw CodeModelTransferFailure.server(status)
                }
            case let .data(data):
                guard let handle else { throw CodeModelTransferFailure.server(0) }
                written += Int64(data.count)
                guard written <= manifest.size else { throw CodeModelTransferFailure.tooLarge }
                do { try handle.write(contentsOf: data) } catch { throw CodeModelTransferFailure.disk }
                report()
            }
        }
    } catch let failure as CodeModelTransferFailure {
        throw failure
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as URLError {
        if Task.isCancelled { throw CancellationError() }
        throw isConnectionLoss(error) ? CodeModelTransferFailure.offline : CodeModelTransferFailure.server(0)
    } catch {
        if Task.isCancelled { throw CancellationError() }
        throw CodeModelTransferFailure.disk
    }
    if Task.isCancelled { throw CancellationError() }
    return written
}

/// Errors that mean "no network right now", as opposed to a server or TLS problem.
func isConnectionLoss(_ error: URLError) -> Bool {
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
        true
    default:
        false
    }
}

/// Opens the partial file for writing after its first `keeping` bytes (0 starts it again).
private func openPartial(_ url: URL, keeping: Int64) throws -> FileHandle {
    let manager = FileManager.default
    do {
        if keeping == 0 || !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CodeModelTransferFailure.disk }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(keeping))
        try handle.seekToEnd()
        return handle
    } catch {
        throw CodeModelTransferFailure.disk
    }
}

/// SHA-256 of a file, read in 1 MB pieces.
func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Thread-safe holder for the installed model's path, read by the engine on its own queue.
final class CodeModelPathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ path: String?) {
        lock.lock()
        value = path
        lock.unlock()
    }
}

/// Lets the network monitor reach the store without keeping it alive.
private final class WeakCodeModelStore: @unchecked Sendable {
    weak var store: CodeModelStore?
    init(_ store: CodeModelStore) { self.store = store }
}

@MainActor
final class CodeModelStore: ObservableObject {
    /// Space kept free on top of the model, so the download never fills the disk.
    static let spaceMargin: Int64 = 100_000_000
    /// How often the manifest is fetched for updates, at most.
    static let manifestInterval: TimeInterval = 6 * 60 * 60

    /// The newest manifest known (bundled or fetched); nil when this build has none.
    @Published private(set) var manifest: CodeModelManifest?
    @Published private(set) var installed: InstalledCodeModel?
    @Published private(set) var download: CodeModelDownload?
    @Published private(set) var availableSpace: Int64?
    @Published private(set) var testResult: CodeModelTestResult?
    @Published private(set) var testing = false
    /// The panel's "ready" card after a download, until dismissed.
    @Published private(set) var justFinished = false

    let engine: LocalCodeEngine
    private let files: CodeModelFiles
    private let transport: CodeModelTransport
    private let manifestURL: URL?
    private let assetURLPrefix: String
    private let spaceQuery: @Sendable (URL) -> Int64?
    private let path = CodeModelPathBox()
    private var task: Task<Void, Never>?
    private var checksumFailures = 0
    private var restarts = 0
    private var rate = TransferRate()
    private var lastPublish: TimeInterval = 0
    private var lastManifestFetch: Date?
    private var monitor: NWPathMonitor?
    private let clock: () -> TimeInterval

    init(files: CodeModelFiles = .standard(),
         transport: CodeModelTransport = URLSessionCodeModelTransport(),
         bundledManifest: CodeModelManifest?,
         manifestURL: URL?,
         assetURLPrefix: String,
         spaceQuery: @escaping @Sendable (URL) -> Int64? = { CodeModelStore.volumeSpace($0) },
         idleTimeout: TimeInterval = LocalCodeEngine.defaultIdleTimeout,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeRunner: @escaping () -> LocalModelRunner = { LlamaRunner() }) {
        self.files = files
        self.transport = transport
        self.manifestURL = manifestURL
        self.assetURLPrefix = assetURLPrefix
        self.spaceQuery = spaceQuery
        self.clock = clock
        let box = path
        engine = LocalCodeEngine(idleTimeout: idleTimeout, modelPath: { box.get() }, makeRunner: makeRunner)
        manifest = bundledManifest?.isValid(assetURLPrefix: assetURLPrefix) == true ? bundledManifest : nil
        restore()
    }

    /// The app's settings: the manifest shipped in the bundle and the edition's URLs from Info.plist.
    static func live() -> CodeModelStore {
        let bundle = Bundle.main
        let prefix = (bundle.object(forInfoDictionaryKey: "BridgeyAssetURLPrefix") as? String) ?? ""
        let bundled = bundle.url(forResource: "otp-model", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
            .flatMap { CodeModelManifest.parse($0, assetURLPrefix: prefix) }
        let manifestURL = (bundle.object(forInfoDictionaryKey: "BridgeyCodeModelManifestURL") as? String)
            .flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return CodeModelStore(bundledManifest: bundled, manifestURL: manifestURL, assetURLPrefix: prefix)
    }

    nonisolated static func volumeSpace(_ url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    var isAvailable: Bool { manifest != nil && localCodeModelSupported() }
    var isReady: Bool { installed != nil }
    var modelPath: String? { path.get() }

    /// A newer model than the one on this Mac.
    var update: CodeModelManifest? {
        guard let installed, let manifest, manifest.version > installed.version else { return nil }
        return manifest
    }

    // MARK: Restore

    private func restore() {
        if let data = try? Data(contentsOf: files.installedRecord),
           let record = try? Self.decoder.decode(InstalledCodeModel.self, from: data),
           files.size(of: files.model(record.fileName)) == record.size {
            installed = record
            path.set(files.model(record.fileName).path)
        }
        if let data = try? Data(contentsOf: files.downloadRecord),
           let record = try? Self.decoder.decode(CodeModelDownloadRecord.self, from: data),
           record.manifest.isValid(assetURLPrefix: assetURLPrefix) {
            manifest = CodeModelManifest.newest(manifest, record.manifest)
            let received = files.size(of: files.partial(record.manifest)) ?? 0
            download = CodeModelDownload(manifest: record.manifest, received: min(received, record.manifest.size), state: .paused)
            // Interrupted (quit, restart) rather than paused by the user: carry on.
            if !record.userPaused { resume() }
        }
    }

    // MARK: Download

    /// Starts the download of the newest model (or resumes one already on disk).
    func start() {
        guard let manifest else { return }
        if let download, download.manifest == manifest {
            if download.state != .running && download.state != .verifying { resume() }
            return
        }
        cancelTask()
        removePartials(except: nil)
        checksumFailures = 0
        restarts = 0
        download = CodeModelDownload(manifest: manifest, received: 0, state: .paused)
        resume()
    }

    func pause() {
        guard var current = download, current.state == .running else { return }
        cancelTask()
        current.state = .paused
        current.bytesPerSecond = nil
        current.secondsLeft = nil
        download = current
        writeRecord(current.manifest, userPaused: true)
    }

    func resume() {
        guard var current = download else { return }
        if case .verifying = current.state { return }
        if case .running = current.state, task != nil { return }
        do { try files.prepare() } catch {
            current.state = .failed(.disk)
            download = current
            return
        }
        let partial = files.partial(current.manifest)
        let onDisk = files.size(of: partial)
        let plan = RangeResume.plan(partialSize: onDisk, expectedSize: current.manifest.size, sameFile: true)
        let offset: Int64 = switch plan {
        case .fresh: 0
        case let .resume(from): from
        case .verify: current.manifest.size
        }
        refreshSpace()
        let needed = current.manifest.size - offset
        if needed > 0, let free = availableSpace, free < needed + Self.spaceMargin {
            current.state = .failed(.noSpace(needed: needed, available: free))
            download = current
            return
        }
        current.received = offset
        current.state = .running
        current.bytesPerSecond = nil
        current.secondsLeft = nil
        download = current
        writeRecord(current.manifest, userPaused: false)
        rate.reset()
        rate.add(time: clock(), bytes: offset)
        if plan == .verify {
            verify(current.manifest)
            return
        }
        let manifest = current.manifest
        let transport = transport
        let owner = WeakCodeModelStore(self)
        // Inherits the main actor; the transfer itself runs off it.
        task = Task {
            do {
                let size = try await transferCodeModel(manifest: manifest, offset: offset, partial: partial, transport: transport) { received in
                    Task { @MainActor in owner.store?.progressed(received, manifest: manifest) }
                }
                owner.store?.transferEnded(manifest: manifest, size: size)
            } catch is CancellationError {
                return
            } catch let failure as CodeModelTransferFailure {
                owner.store?.transferFailed(failure, manifest: manifest)
            } catch {
                owner.store?.transferFailed(.disk, manifest: manifest)
            }
        }
        startMonitor()
    }

    /// Stops and deletes what was downloaded so far.
    func cancel() {
        cancelTask()
        if let manifest = download?.manifest { try? FileManager.default.removeItem(at: files.partial(manifest)) }
        try? FileManager.default.removeItem(at: files.downloadRecord)
        download = nil
        stopMonitor()
    }

    /// Try again after an error (the partial file is kept unless it was damaged).
    func retry() {
        guard let current = download, case .failed = current.state else { return }
        if current.state == .failed(.checksum) { checksumFailures = 0 }
        restarts = 0
        resume()
    }

    private func progressed(_ received: Int64, manifest: CodeModelManifest) {
        guard var current = download, current.manifest == manifest, current.state == .running else { return }
        let now = clock()
        rate.add(time: now, bytes: received)
        // At most five updates a second: enough for a smooth bar, cheap for SwiftUI.
        guard now - lastPublish >= 0.2 || received >= manifest.size else { return }
        lastPublish = now
        current.received = received
        current.bytesPerSecond = rate.bytesPerSecond
        current.secondsLeft = rate.secondsLeft(remaining: manifest.size - received)
        download = current
    }

    private func transferEnded(manifest: CodeModelManifest, size: Int64) {
        task = nil
        guard var current = download, current.manifest == manifest else { return }
        guard size == manifest.size else {
            // The body ended early (the connection closed): keep what arrived, as for a lost network.
            current.received = size
            current.state = .failed(.offline)
            download = current
            return
        }
        current.received = size
        download = current
        verify(manifest)
    }

    private func transferFailed(_ failure: CodeModelTransferFailure, manifest: CodeModelManifest) {
        task = nil
        guard var current = download, current.manifest == manifest else { return }
        switch failure {
        case .restart, .tooLarge:
            try? FileManager.default.removeItem(at: files.partial(manifest))
            current.received = 0
            restarts += 1
            guard restarts <= 2 else {
                current.state = .failed(.server(0))
                download = current
                return
            }
            download = current
            resume()
            return
        case .offline:
            current.state = .failed(.offline)
        case let .server(status):
            current.state = .failed(.server(status))
        case .disk:
            refreshSpace()
            if let free = availableSpace, free < manifest.size - current.received + Self.spaceMargin {
                current.state = .failed(.noSpace(needed: manifest.size - current.received, available: free))
            } else {
                current.state = .failed(.disk)
            }
        }
        current.received = files.size(of: files.partial(manifest)) ?? current.received
        current.bytesPerSecond = nil
        current.secondsLeft = nil
        download = current
    }

    private func verify(_ manifest: CodeModelManifest) {
        guard var current = download else { return }
        current.state = .verifying
        current.received = manifest.size
        current.bytesPerSecond = nil
        current.secondsLeft = nil
        download = current
        let partial = files.partial(manifest)
        let owner = WeakCodeModelStore(self)
        task = Task {
            let digest = await Task.detached(priority: .utility) { try? sha256Hex(of: partial) }.value
            owner.store?.verified(manifest, digest: digest)
        }
    }

    private func verified(_ manifest: CodeModelManifest, digest: String?) {
        task = nil
        guard var current = download, current.manifest == manifest else { return }
        let partial = files.partial(manifest)
        guard digest == manifest.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            checksumFailures += 1
            current.received = 0
            if checksumFailures < 2 {
                // Damaged once: fetch it again before saying anything.
                current.state = .paused
                download = current
                resume()
            } else {
                current.state = .failed(.checksum)
                download = current
                try? FileManager.default.removeItem(at: files.downloadRecord)
            }
            return
        }
        let target = files.model(manifest.fileName)
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: partial, to: target)
            try? CodeModelFiles.excludeFromBackup(target)
            let record = InstalledCodeModel(version: manifest.version, name: manifest.name, size: manifest.size, sha256: manifest.sha256,
                                            fileName: manifest.fileName, installedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
            try Self.encoder.encode(record).write(to: files.installedRecord, options: .atomic)
            let previous = installed
            installed = record
            path.set(target.path)
            engine.unload()
            if let previous, previous.fileName != record.fileName {
                try? FileManager.default.removeItem(at: files.model(previous.fileName))
            }
            try? FileManager.default.removeItem(at: files.downloadRecord)
            download = nil
            checksumFailures = 0
            testResult = nil
            justFinished = true
            stopMonitor()
            warmUp()
        } catch {
            current.state = .failed(.disk)
            download = current
        }
    }

    // MARK: Model on disk

    /// Deletes the model and frees its space. Codes from messages then falls back to the plain notification.
    func remove() {
        cancel()
        engine.unload()
        if let installed { try? FileManager.default.removeItem(at: files.model(installed.fileName)) }
        try? FileManager.default.removeItem(at: files.installedRecord)
        installed = nil
        path.set(nil)
        testResult = nil
        justFinished = false
    }

    /// Reads a few synthetic messages once after a download, then the model unloads when idle as usual.
    private func warmUp() {
        let engine = engine
        Task.detached(priority: .utility) {
            for sample in CodeModelSample.warmUp { _ = await engine.answer(text: sample.text, sender: sample.sender) }
        }
    }

    /// Reads the sample message with the real model and times it.
    func runTest() {
        guard installed != nil, !testing else { return }
        testing = true
        let engine = engine
        let owner = WeakCodeModelStore(self)
        Task {
            let timed = await engine.timedAnswer(text: CodeModelSample.text, sender: CodeModelSample.sender)
            let code: String? = if case let .candidate(value) = timed.answer { CodeGuard.accept(value, in: CodeModelSample.text) } else { nil }
            let failed: Bool = if case .failed = timed.answer { true } else { false }
            owner.store?.testResult = CodeModelTestResult(code: code, seconds: timed.seconds, loaded: timed.loaded, failed: failed)
            owner.store?.testing = false
        }
    }

    func dismissFinished() { justFinished = false }

    func refreshSpace() {
        availableSpace = spaceQuery(files.directory)
    }

    /// Fetches the manifest for updates, at most every six hours unless `force`.
    func refreshManifest(force: Bool = false) async {
        guard let manifestURL else { return }
        if !force, let lastManifestFetch, Date().timeIntervalSince(lastManifestFetch) < Self.manifestInterval { return }
        lastManifestFetch = Date()
        guard let result = try? await transport.fetch(manifestURL), result.0 == 200,
              let fetched = CodeModelManifest.parse(result.1, assetURLPrefix: assetURLPrefix) else { return }
        manifest = CodeModelManifest.newest(manifest, fetched)
    }

    // MARK: Helpers

    private func cancelTask() {
        task?.cancel()
        task = nil
    }

    private func removePartials(except keep: URL?) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? []
        for name in names where name.hasSuffix(".part") {
            let url = files.directory.appendingPathComponent(name)
            if url != keep { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func writeRecord(_ manifest: CodeModelManifest, userPaused: Bool) {
        guard let data = try? Self.encoder.encode(CodeModelDownloadRecord(manifest: manifest, userPaused: userPaused)) else { return }
        try? data.write(to: files.downloadRecord, options: .atomic)
    }

    /// Back online after a lost connection: the download carries on by itself.
    private func startMonitor() {
        guard monitor == nil else { return }
        let created = NWPathMonitor()
        let owner = WeakCodeModelStore(self)
        created.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in owner.store?.networkReturned() }
        }
        created.start(queue: DispatchQueue(label: "in.roundrobin.bridgey.code-model.network"))
        monitor = created
    }

    private func networkReturned() {
        guard let current = download, current.state == .failed(.offline) else { return }
        resume()
    }

    private func stopMonitor() {
        monitor?.cancel()
        monitor = nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
