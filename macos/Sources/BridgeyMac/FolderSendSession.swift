import CryptoKit
import Foundation
import UniformTypeIdentifiers

// Sections 4.4 to 4.8, sender side: one folder transfer to one phone. The session is a state machine that
// must be driven from one serial queue (the owner wraps every call); it never touches the UI. Transport,
// clock and files are injected so tests run it synchronously.

/// Sends one protocol message to the phone this folder goes to. Thread-safe.
protocol FolderTransport: AnyObject {
    /// An encrypted message whose plaintext is `payload` (JSON, or raw chunk bytes).
    @discardableResult
    func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool
    /// An outer-only message (no ciphertext), such as files.cancel or folders.cancel.ack.
    func sendOuter(kind: String, transferID: String)
}

protocol FolderTimer: AnyObject { func cancel() }

protocol FolderClock: AnyObject {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> FolderTimer
}

/// The production clock: wall time, timers on the session's queue.
final class DispatchFolderClock: FolderClock {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    var now: Date { Date() }

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> FolderTimer {
        let item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
        return DispatchFolderTimer(item: item)
    }

    private final class DispatchFolderTimer: FolderTimer {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}

/// Reads one file of the folder in order.
protocol FolderChunkReader: AnyObject {
    /// Up to `count` bytes; empty at the end of the file.
    func read(upTo count: Int) throws -> Data
    func close()
}

protocol FolderFileSource: AnyObject {
    func open(entry: Int) throws -> FolderChunkReader
}

final class DiskFolderFileSource: FolderFileSource {
    private let sources: [URL]

    init(sources: [URL]) { self.sources = sources }

    func open(entry: Int) throws -> FolderChunkReader {
        guard sources.indices.contains(entry) else { throw PairingError.invalidMessage }
        return DiskChunkReader(handle: try FileHandle(forReadingFrom: sources[entry]))
    }

    private final class DiskChunkReader: FolderChunkReader {
        let handle: FileHandle
        init(handle: FileHandle) { self.handle = handle }
        func read(upTo count: Int) throws -> Data { try handle.read(upToCount: count) ?? Data() }
        func close() { try? handle.close() }
    }
}

/// What a folder needs to go out: the hashed manifest and what the offer says about it.
struct FolderSendPlan {
    let folderTransferID: String
    let rootName: String
    let displayName: String
    let entries: [ManifestEntry]
    let fileCount: Int
    let folderCount: Int
    let totalSize: Int64
    let manifestSha256: String
    let pages: [ManifestPagePayload]
    let destination: FolderDestination?
    let skipped: SkippedCounts
    let resume: Bool
    /// Files 2.0 browse: the entries land directly in the destination (uploads, downloads).
    var into = false
    /// Files 2.0 browse: the offer answers the receiver's places.download.
    var downloadRequestId: String?

    init(folderTransferID: String, scan: FolderScan, destination: FolderDestination?, resume: Bool, into: Bool = false) {
        self.into = into
        self.folderTransferID = folderTransferID
        rootName = scan.rootName
        displayName = scan.displayName
        entries = scan.entries
        fileCount = scan.fileCount
        folderCount = scan.folderCount
        totalSize = scan.totalSize
        manifestSha256 = scan.manifestDigest
        pages = ManifestPager.pages(folderTransferID: folderTransferID, entries: scan.entries) ?? []
        self.destination = destination
        skipped = scan.skipped
        self.resume = resume
    }

    var offer: FolderOfferPayload {
        FolderOfferPayload(
            folderTransferId: folderTransferID, rootName: rootName, fileCount: fileCount, folderCount: folderCount,
            totalSize: totalSize, pageCount: pages.count, manifestSha256: manifestSha256, destination: destination,
            resume: resume, skipped: skipped.total > 0 ? skipped : nil,
            into: into ? true : nil, downloadRequestId: downloadRequestId
        )
    }
}

enum FolderPhase: Equatable {
    case offered
    /// The phone is waiting for its user ("destination" or "conflict"), until `deadline`.
    case waiting(reason: String, deadline: Date)
    /// The Mac asks its user (mode a, folder exists), until `deadline`.
    case asking(deadline: Date)
    case sending
    case completing
    case cancelling
    case finished
}

struct FolderFailure: Equatable {
    let entry: Int
    let path: String
    let code: String
}

/// A snapshot for rows and cards.
struct FolderProgress: Equatable {
    var phase: FolderPhase = .offered
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Double = 0
    var currentPath: String?
    var currentBytes: Int64 = 0
    var currentSize: Int64 = 0
    var failures: [FolderFailure] = []
    var failedCount = 0
    /// The last completed paths, newest last, at most 200.
    var recent: [String] = []
    var rootName: String?
    var destinationLabel: String?
    var choice: ConflictChoice?
}

/// How a folder transfer ended.
enum FolderOutcome: Equatable {
    case done(FolderResultPayload)
    /// folders.complete went out but no folders.result came within 30 s.
    case unconfirmed
    case rejected(code: String, neededBytes: Int64?, freeBytes: Int64?)
    /// An outer-only folders.rejected or files.rejected: Files is off on the phone.
    case filesOff
    case cancelledHere
    case cancelledByPhone(reason: String)
    /// The phone did not answer the offer, or did not finish its question in time.
    case noAnswer
    /// Nobody answered the conflict question on this Mac.
    case questionTimedOut
    case interrupted
}

protocol FolderSessionEvents: AnyObject {
    func folderProgress(_ progress: FolderProgress)
    func folderAsks(_ conflict: FolderConflictPayload, deadline: Date)
    /// The question was answered elsewhere or timed out: close it.
    func folderQuestionClosed()
    /// A file finished; `completed` holds every entry known to be done.
    func folderEntriesCompleted(_ completed: Set<Int>, at date: Date)
    func folderAccepted(_ accept: FolderAcceptPayload)
    func folderFinished(_ outcome: FolderOutcome, progress: FolderProgress)
}

/// Confined to one serial queue by its owner, so it is safe to hand to that queue.
final class FolderSendSession: @unchecked Sendable {
    static let chunkSize = 24 * 1024
    static let recentLimit = 200
    static let chunkAckTimeout: TimeInterval = 10
    /// Waiting for files.complete.ack with no chunk outstanding (the phone verifies and renames).
    static let completeAckTimeout: TimeInterval = 60
    static let cancelRetryInterval: TimeInterval = 5
    static let cancelAttempts = 3
    static let progressInterval: TimeInterval = 0.25

    let plan: FolderSendPlan
    var folderTransferID: String { plan.folderTransferID }
    private(set) var phase: FolderPhase = .offered
    private(set) var progress = FolderProgress()

    private let transport: FolderTransport
    private let clock: FolderClock
    private let files: FolderFileSource
    private weak var events: FolderSessionEvents?
    private let makeID: () -> String
    private let fileOwnership: FolderFileOwnership?

    /// Entries known to be on the phone already (journal, then the accept's bitmap).
    private var completed: Set<Int>
    private var pending: [Int] = []
    private var current: CurrentFile?
    private var flights: [String: Flight] = [:]
    private var flightOrder: [String] = []
    private var senderFailures: [FailedEntry] = []
    private var sentFiles = 0
    private var waitTimer: FolderTimer?
    private var watchdog: FolderTimer?
    private var lastAckProgress: Date
    private var lastEmit = Date.distantPast
    private var speedSample: (at: Date, bytes: Int64)?
    private var cancelAttemptsLeft = 0
    private var cancelReason = FolderCancelPayload.user
    private var cancelCode: String?
    private var pendingOutcome: FolderOutcome?
    private var completedBytes: Int64 = 0

    private final class CurrentFile {
        let entry: Int
        let transferID: String
        let size: Int64
        let reader: FolderChunkReader
        var hasher = SHA256()
        var sent: Int64 = 0
        var sequence: Int64 = 0
        init(entry: Int, transferID: String, size: Int64, reader: FolderChunkReader) {
            self.entry = entry
            self.transferID = transferID
            self.size = size
            self.reader = reader
        }
    }

    private struct Flight {
        let entry: Int
        let size: Int64
        var chunksSent: Int64 = 0
        var acked: Int64 = -1
        var completeSent = false

        var unacked: Int64 { max(0, chunksSent - (acked + 1)) }
        var ackedBytes: Int64 { min(size, (acked + 1) * Int64(FolderSendSession.chunkSize)) }
    }

    init(
        plan: FolderSendPlan,
        alreadyCompleted: Set<Int> = [],
        transport: FolderTransport,
        clock: FolderClock,
        files: FolderFileSource,
        events: FolderSessionEvents?,
        fileOwnership: FolderFileOwnership? = nil,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.plan = plan
        completed = alreadyCompleted
        self.transport = transport
        self.clock = clock
        self.files = files
        self.events = events
        self.fileOwnership = fileOwnership
        self.makeID = makeID
        lastAckProgress = clock.now
        progress.filesTotal = plan.fileCount
        progress.bytesTotal = plan.totalSize
        progress.rootName = plan.rootName
    }

    // MARK: Offer and answers

    /// Sends the offer and every manifest page, then waits 15 s for the first answer.
    func start() {
        guard phase == .offered, let offer = try? FolderJSON.encoder.encode(plan.offer) else { return }
        transport.send(kind: FolderKind.offer, payload: offer, transferID: folderTransferID, sequence: nil)
        for page in plan.pages {
            guard let data = try? FolderJSON.encoder.encode(page) else { continue }
            transport.send(kind: FolderKind.manifest, payload: data, transferID: nil, sequence: nil)
        }
        refreshCompletedCounts()
        armWait(FolderTimeouts.firstAnswer)
        emit(force: true)
    }

    func receivedWaiting(_ payload: FolderWaitingPayload) {
        guard payload.folderTransferId == folderTransferID, isBeforeAccept else { return }
        let shown = TimeInterval(min(max(payload.timeoutSeconds, 1), FolderTimeouts.questionSeconds))
        if case .asking = phase { events?.folderQuestionClosed() }
        phase = .waiting(reason: payload.reason, deadline: clock.now.addingTimeInterval(shown))
        armWait(FolderTimeouts.senderQuestionWait)
        emit(force: true)
    }

    func receivedConflict(_ payload: FolderConflictPayload) {
        guard payload.folderTransferId == folderTransferID, isBeforeAccept else { return }
        let seconds = TimeInterval(min(max(payload.timeoutSeconds, 1), FolderTimeouts.questionSeconds))
        let deadline = clock.now.addingTimeInterval(seconds)
        phase = .asking(deadline: deadline)
        waitTimer?.cancel()
        waitTimer = clock.schedule(after: seconds) { [weak self] in self?.questionTimedOut() }
        events?.folderAsks(payload, deadline: deadline)
        emit(force: true)
    }

    /// The user's answer to the conflict question. Cancel ends the transfer here.
    func resolve(_ choice: ConflictChoice) {
        guard case .asking = phase else { return }
        events?.folderQuestionClosed()
        let payload = FolderResolvePayload(folderTransferId: folderTransferID, choice: choice)
        if let data = try? FolderJSON.encoder.encode(payload) {
            transport.send(kind: FolderKind.resolve, payload: data, transferID: nil, sequence: nil)
        }
        if choice == .cancel {
            finish(.cancelledHere)
            return
        }
        phase = .offered
        armWait(FolderTimeouts.firstAnswer)
        emit(force: true)
    }

    func receivedAccept(_ payload: FolderAcceptPayload) {
        guard payload.folderTransferId == folderTransferID, isBeforeAccept else { return }
        if case .asking = phase { events?.folderQuestionClosed() }
        waitTimer?.cancel()
        if let bitmap = payload.completedBitmap, let done = CompletedBitmap.decode(bitmap, size: plan.entries.count) {
            completed.formUnion(done)
        }
        progress.rootName = payload.rootName
        progress.destinationLabel = payload.destinationLabel
        progress.choice = payload.choice
        events?.folderAccepted(payload)
        phase = .sending
        pending = plan.entries.indices.filter { !plan.entries[$0].isDirectory && !completed.contains($0) }
        refreshCompletedCounts()
        lastAckProgress = clock.now
        armWatchdog()
        emit(force: true)
        pump()
    }

    func receivedRejected(_ payload: FolderRejectedPayload) {
        guard payload.folderTransferId == folderTransferID, phase != .finished else { return }
        finish(.rejected(code: payload.code, neededBytes: payload.neededBytes, freeBytes: payload.freeBytes))
    }

    /// The outer-only form: Files is off on the phone.
    func receivedPolicyRejection() {
        guard phase != .finished else { return }
        finish(.filesOff)
    }

    func receivedCancel(_ payload: FolderCancelPayload) {
        guard payload.folderTransferId == folderTransferID else { return }
        transport.sendOuter(kind: FolderKind.cancelAck, transferID: folderTransferID)
        guard phase != .finished else { return }
        if phase == .cancelling {
            finish(pendingOutcome ?? .cancelledHere)
            return
        }
        stopCurrentFile(sendCancel: false)
        finish(.cancelledByPhone(reason: payload.reason))
    }

    func receivedCancelAck() {
        guard phase == .cancelling else { return }
        finish(pendingOutcome ?? .cancelledHere)
    }

    func receivedEntryFailed(_ payload: FolderEntryFailedPayload) {
        guard payload.folderTransferId == folderTransferID, phase == .sending || phase == .completing else { return }
        guard plan.entries.indices.contains(payload.entry) else { return }
        if current?.entry == payload.entry { stopCurrentFile(sendCancel: false) }
        if let id = flights.first(where: { $0.value.entry == payload.entry })?.key { removeFlight(id) }
        pending.removeAll { $0 == payload.entry }
        recordFailure(entry: payload.entry, code: payload.code, senderSide: false)
        lastAckProgress = clock.now
        emit(force: true)
        pump()
    }

    func receivedResult(_ payload: FolderResultPayload) {
        guard payload.folderTransferId == folderTransferID, phase == .completing else { return }
        finish(.done(payload))
    }

    // MARK: Files inside the folder

    /// Tolerated: inside a folder the sender does not wait for files.accept.
    func fileAccepted(_ transferID: String) {}

    func chunkAcknowledged(_ transferID: String, sequence: Int64) {
        guard var flight = flights[transferID], sequence > flight.acked else { return }
        flight.acked = min(sequence, flight.chunksSent - 1)
        flights[transferID] = flight
        lastAckProgress = clock.now
        emit()
        pump()
    }

    func completeAcknowledged(_ transferID: String) {
        guard let flight = flights[transferID], flight.completeSent else { return }
        removeFlight(transferID)
        completed.insert(flight.entry)
        progress.filesDone += 1
        completedBytes += flight.size
        progress.recent.append(plan.entries[flight.entry].path)
        if progress.recent.count > Self.recentLimit { progress.recent.removeFirst(progress.recent.count - Self.recentLimit) }
        lastAckProgress = clock.now
        events?.folderEntriesCompleted(completed, at: clock.now)
        emit()
        pump()
    }

    /// The phone cancelled one file (files.cancel) or refused it (files.rejected means Files is off).
    func fileCancelledByPhone(_ transferID: String) {
        transport.sendOuter(kind: "files.cancel.ack", transferID: transferID)
        guard let flight = flights[transferID] else { return }
        if current?.transferID == transferID { stopCurrentFile(sendCancel: false) }
        removeFlight(transferID)
        recordFailure(entry: flight.entry, code: FolderCode.cancelled, senderSide: false)
        emit(force: true)
        pump()
    }

    // MARK: Cancel and interruption

    /// Cancel on this Mac: folders.cancel, resent up to 3 times 5 s apart until folders.cancel.ack.
    func cancel(reason: String = FolderCancelPayload.user, code: String? = nil, outcome: FolderOutcome = .cancelledHere) {
        guard phase != .finished, phase != .cancelling else { return }
        if case .asking = phase { events?.folderQuestionClosed() }
        stopCurrentFile(sendCancel: false)
        waitTimer?.cancel()
        watchdog?.cancel()
        pending.removeAll()
        cancelReason = reason
        cancelCode = code
        pendingOutcome = outcome
        cancelAttemptsLeft = Self.cancelAttempts
        phase = .cancelling
        sendCancelAttempt()
        emit(force: true)
    }

    /// The connection is gone (or stalled): stop without sending anything.
    func interrupt() {
        guard phase != .finished else { return }
        if case .asking = phase { events?.folderQuestionClosed() }
        stopCurrentFile(sendCancel: false)
        finish(.interrupted)
    }

    // MARK: Internals

    private var isBeforeAccept: Bool {
        switch phase {
        case .offered, .waiting, .asking: return true
        default: return false
        }
    }

    private func armWait(_ seconds: TimeInterval) {
        waitTimer?.cancel()
        waitTimer = clock.schedule(after: seconds) { [weak self] in
            guard let self, self.isBeforeAccept else { return }
            self.cancel(reason: FolderCancelPayload.timeout, code: FolderCode.timeout, outcome: .noAnswer)
        }
    }

    private func questionTimedOut() {
        guard case .asking = phase else { return }
        // cancel() closes the question.
        cancel(reason: FolderCancelPayload.timeout, code: FolderCode.timeout, outcome: .questionTimedOut)
    }

    private func sendCancelAttempt() {
        guard phase == .cancelling else { return }
        guard cancelAttemptsLeft > 0 else {
            // No acknowledgement after three tries: treated as cancelled.
            finish(pendingOutcome ?? .cancelledHere)
            return
        }
        cancelAttemptsLeft -= 1
        let payload = FolderCancelPayload(folderTransferId: folderTransferID, reason: cancelReason, code: cancelCode)
        if let data = try? FolderJSON.encoder.encode(payload) {
            transport.send(kind: FolderKind.cancel, payload: data, transferID: folderTransferID, sequence: nil)
        }
        waitTimer?.cancel()
        waitTimer = clock.schedule(after: Self.cancelRetryInterval) { [weak self] in self?.sendCancelAttempt() }
    }

    private var unackedChunks: Int64 { flights.values.reduce(0) { $0 + $1.unacked } }
    /// Files offered and not yet acknowledged as complete (the one being sent included).
    private var openFiles: Int { flights.count }

    /// Sends what the windows allow: at most 64 chunks unacknowledged across the folder, at most 32 files
    /// awaiting files.complete.ack, one file's chunks at a time.
    private func pump() {
        guard phase == .sending else { return }
        var budget = FolderLimits.chunkWindow * 2
        while phase == .sending, budget > 0 {
            budget -= 1
            if current == nil {
                guard let next = pending.first else { break }
                guard openFiles < FolderLimits.filesAwaitingCompletion else { break }
                pending.removeFirst()
                startFile(next)
                continue
            }
            guard let file = current else { break }
            if file.sent < file.size {
                guard unackedChunks < Int64(FolderLimits.chunkWindow) else { break }
                sendChunk(file)
            } else {
                finishFile(file)
            }
        }
        if phase == .sending, current == nil, pending.isEmpty, flights.isEmpty {
            sendComplete()
        } else if phase == .sending, budget == 0 {
            // Give acknowledgements a turn on the queue, then carry on.
            _ = clock.schedule(after: 0) { [weak self] in self?.pump() }
        }
    }

    private func startFile(_ index: Int) {
        let entry = plan.entries[index]
        guard let size = entry.size, let sha = entry.sha256 else { return }
        let transferID = makeID()
        let reader: FolderChunkReader
        do {
            reader = try files.open(entry: index)
        } catch {
            recordFailure(entry: index, code: FolderCode.unreadable, senderSide: true)
            return
        }
        fileOwnership?.add(transferID, folder: folderTransferID)
        let name = FolderPaths.components(entry.path).last ?? entry.path
        let offer = FolderFileOfferPayload(
            transferId: transferID, name: name, mimeType: Self.mimeType(for: name), size: size, sha256: sha,
            folderTransferId: folderTransferID, entry: index, path: entry.path
        )
        guard let data = try? FolderJSON.encoder.encode(offer) else {
            reader.close()
            return
        }
        transport.send(kind: "files.offer", payload: data, transferID: transferID, sequence: nil)
        current = CurrentFile(entry: index, transferID: transferID, size: size, reader: reader)
        flights[transferID] = Flight(entry: index, size: size)
        flightOrder.append(transferID)
        progress.currentPath = entry.path
        progress.currentBytes = 0
        progress.currentSize = size
        emit()
    }

    private func sendChunk(_ file: CurrentFile) {
        let wanted = Int(min(Int64(Self.chunkSize), file.size - file.sent))
        let data: Data
        do {
            data = try file.reader.read(upTo: wanted)
        } catch {
            abandonCurrentFile(code: FolderCode.unreadable)
            return
        }
        guard !data.isEmpty else {
            // The file got shorter since the scan.
            abandonCurrentFile(code: FolderCode.sourceChanged)
            return
        }
        file.hasher.update(data: data)
        transport.send(kind: "files.chunk", payload: data, transferID: file.transferID, sequence: file.sequence)
        file.sequence += 1
        file.sent += Int64(data.count)
        flights[file.transferID]?.chunksSent = file.sequence
        progress.currentBytes = file.sent
        emit()
    }

    private func finishFile(_ file: CurrentFile) {
        let extra = (try? file.reader.read(upTo: 1)) ?? Data()
        file.reader.close()
        let digest = Data(file.hasher.finalize()).base64EncodedString()
        guard extra.isEmpty, digest == plan.entries[file.entry].sha256 else {
            // Changed since the manifest was built: the phone drops what it has of it.
            current = nil
            transport.sendOuter(kind: "files.cancel", transferID: file.transferID)
            removeFlight(file.transferID)
            recordFailure(entry: file.entry, code: FolderCode.sourceChanged, senderSide: true)
            emit(force: true)
            return
        }
        let payload = FileCompletion(transferId: file.transferID, sha256: digest)
        if let data = try? JSONEncoder().encode(payload) {
            transport.send(kind: "files.complete", payload: data, transferID: file.transferID, sequence: nil)
        }
        flights[file.transferID]?.completeSent = true
        sentFiles += 1
        current = nil
        progress.currentPath = nil
    }

    private func abandonCurrentFile(code: String) {
        guard let file = current else { return }
        file.reader.close()
        current = nil
        transport.sendOuter(kind: "files.cancel", transferID: file.transferID)
        removeFlight(file.transferID)
        recordFailure(entry: file.entry, code: code, senderSide: true)
        emit(force: true)
    }

    private func stopCurrentFile(sendCancel: Bool) {
        guard let file = current else { return }
        file.reader.close()
        current = nil
        progress.currentPath = nil
        if sendCancel { transport.sendOuter(kind: "files.cancel", transferID: file.transferID) }
    }

    private func removeFlight(_ transferID: String) {
        flights.removeValue(forKey: transferID)
        flightOrder.removeAll { $0 == transferID }
    }

    private func recordFailure(entry: Int, code: String, senderSide: Bool) {
        progress.failedCount += 1
        if progress.failures.count < FolderLimits.maxReportedFailures {
            progress.failures.append(FolderFailure(entry: entry, path: plan.entries[entry].path, code: code))
        }
        if senderSide, senderFailures.count < FolderLimits.maxReportedFailures {
            senderFailures.append(FailedEntry(entry: entry, code: code))
        }
        if senderSide { senderFailureCount += 1 }
    }

    private var senderFailureCount = 0

    private func sendComplete() {
        let payload = FolderCompletePayload(folderTransferId: folderTransferID, sentFiles: sentFiles, failedCount: senderFailureCount, failed: senderFailures)
        if let data = try? FolderJSON.encoder.encode(payload) {
            transport.send(kind: FolderKind.complete, payload: data, transferID: nil, sequence: nil)
        }
        watchdog?.cancel()
        phase = .completing
        progress.currentPath = nil
        waitTimer?.cancel()
        waitTimer = clock.schedule(after: FolderTimeouts.result) { [weak self] in
            guard let self, self.phase == .completing else { return }
            self.finish(.unconfirmed)
        }
        emit(force: true)
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = clock.schedule(after: 1) { [weak self] in
            guard let self, self.phase == .sending else { return }
            let limit = self.unackedChunks > 0 ? Self.chunkAckTimeout : Self.completeAckTimeout
            if !self.flights.isEmpty, self.clock.now.timeIntervalSince(self.lastAckProgress) >= limit {
                // Chunk acknowledgements stopped: the file fails and the folder is interrupted.
                self.interrupt()
                return
            }
            self.armWatchdog()
        }
    }

    private func refreshCompletedCounts() {
        let doneFiles = completed.filter { plan.entries.indices.contains($0) && !plan.entries[$0].isDirectory }
        progress.filesDone = doneFiles.count
        completedBytes = doneFiles.reduce(Int64(0)) { $0 + (plan.entries[$1].size ?? 0) }
    }

    private func finish(_ outcome: FolderOutcome) {
        guard phase != .finished else { return }
        phase = .finished
        waitTimer?.cancel()
        watchdog?.cancel()
        if let file = current {
            file.reader.close()
            current = nil
        }
        progress.currentPath = nil
        progress.phase = .finished
        progress.bytesPerSecond = 0
        events?.folderFinished(outcome, progress: progress)
    }

    private func emit(force: Bool = false) {
        let now = clock.now
        progress.phase = phase
        let inFlight = flights.values.reduce(Int64(0)) { $0 + $1.ackedBytes }
        progress.bytesDone = min(progress.bytesTotal, completedBytes + inFlight)
        if !force, now.timeIntervalSince(lastEmit) < Self.progressInterval { return }
        if let sample = speedSample, now > sample.at {
            let elapsed = now.timeIntervalSince(sample.at)
            if elapsed >= 0.5 {
                let rate = Double(max(0, progress.bytesDone - sample.bytes)) / elapsed
                progress.bytesPerSecond = progress.bytesPerSecond == 0 ? rate : progress.bytesPerSecond * 0.7 + rate * 0.3
                speedSample = (now, progress.bytesDone)
            }
        } else if phase == .sending {
            speedSample = (now, progress.bytesDone)
        }
        lastEmit = now
        events?.folderProgress(progress)
    }

    static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "application/octet-stream" }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private struct FileCompletion: Codable {
        let transferId: String
        let sha256: String
    }
}

/// Which per-file transfer IDs belong to a folder transfer. Read on the main thread when a files.* message
/// arrives, written by sessions on their own queues. Remembers finished IDs too (bounded), so a late
/// acknowledgement never looks like an unknown transfer.
final class FolderFileOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [String: String] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 20_000) { self.limit = limit }

    func add(_ transferID: String, folder: String) {
        lock.withLock {
            if owners.updateValue(folder, forKey: transferID) == nil { order.append(transferID) }
            if order.count > limit {
                let drop = order.count - limit
                order.prefix(drop).forEach { owners.removeValue(forKey: $0) }
                order.removeFirst(drop)
            }
        }
    }

    func folder(of transferID: String?) -> String? {
        guard let transferID else { return nil }
        return lock.withLock { owners[transferID] }
    }
}
