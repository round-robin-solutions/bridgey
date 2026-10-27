import AppKit
import Foundation

// Sections 3.1 to 3.5 and 7.1 to 7.3: every folder this Mac sends, from the drop to the activity item.
// One FolderSendSession per running folder, each on its own serial queue; everything else on the main
// thread. The coordinator (Pairing.swift) owns the per-phone queue and the sockets and talks to this class
// through `FolderSenderHost`.

@MainActor
protocol FolderSenderHost: AnyObject {
    /// A transport bound to the phone's current session, and that session's identity; nil when not connected.
    func folderTransport(for phoneID: String) -> (transport: FolderTransport, session: ObjectIdentifier)?
    /// The phone's draft keys, nil when it is not connected or has not sent its features yet.
    func folderSupport(for phoneID: String) -> (folders: Bool, places: Bool)?
    func phoneName(_ phoneID: String) -> String
    func folderRowChanged(_ row: FileTransferRow)
    func folderRowRemoved(_ id: String)
    /// Adds the folder to the phone's send queue (it starts when the queue reaches it).
    func enqueueFolder(_ id: String, phoneID: String)
    /// The folder no longer owns the phone's queue.
    func folderEnded(_ id: String)
    func folderStatus(_ text: String)
    func recordFolderActivity(_ kind: ActivityKind, phoneID: String, name: String, fileCount: Int, bytes: Int64, destination: String?, detail: FolderActivityDetail)
    var folderReduceMotion: Bool { get }
    var folderScanDefaults: FolderScanOptions { get }
}

final class FolderCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

@MainActor
final class FolderSender {
    private final class Item {
        let id: String
        let phoneID: String
        var root: URL
        var options: FolderScanOptions
        var displayName: String
        var scan: FolderScan?
        var hashed: FolderScan?
        var hashing: Double?
        var scanToken = FolderCancelToken()
        var mode: DestinationMode?
        var fixedLabel: String?
        var destination: FolderDestination?
        var destinationLabel: String?
        var state: FolderRowState = .preparing
        var progress = FolderProgress()
        var startWhenReady = false
        var inQueue = false
        var session: FolderSendSession?
        var sessionQueue: DispatchQueue?
        var sessionToken: ObjectIdentifier?
        var journal: FolderJournal?
        var resuming = false
        var endText: String?
        var canResume = false
        var canSendAgain = false
        let startedAt: Date
        var journalDirty = false
        /// The hashed scan of the last attempt: a resume reuses its hashes when nothing changed on disk.
        var previous: FolderScan?
        /// Automatic resumes in a row without a finished file; stops a loop with a stuck phone.
        var autoResumes = 0

        init(id: String, phoneID: String, root: URL, options: FolderScanOptions, startedAt: Date) {
            self.id = id
            self.phoneID = phoneID
            self.root = root
            self.options = options
            displayName = root.lastPathComponent
            self.startedAt = startedAt
        }
    }

    private weak var host: FolderSenderHost?
    private let journals: FolderJournalStore
    private let memory: FolderDestinationMemory
    let places: PlacesClient
    let ownership = FolderFileOwnership()
    private let clock: FolderClock
    private let scanQueue = DispatchQueue(label: "in.roundrobin.bridgey.folder-scan", qos: .userInitiated)
    private var items: [String: Item] = [:]
    private var sheet: (id: String, controller: FolderSheetWindowController, browse: Int, cursor: String?)?
    private var pendingSheets: [(id: String, listed: PlacesListedPayload)] = []
    private var question: (id: String, controller: FolderConflictWindowController)?
    /// Folders waiting for their places.list, one at a time (the phone allows 4 requests in flight).
    private var placesWaiting: [String] = []
    private var placesAsking: String?

    init(host: FolderSenderHost, journals: FolderJournalStore = FolderJournalStore(), memory: FolderDestinationMemory = FolderDestinationMemory(),
         clock: FolderClock = DispatchFolderClock(queue: .main)) {
        self.host = host
        self.journals = journals
        self.memory = memory
        self.clock = clock
        places = PlacesClient(clock: clock)
    }

    // MARK: Start-up and connections

    /// Journals from an earlier run: their folders resume when the phone next connects.
    func loadJournals() {
        defer { sweepExpired() }
        for journal in journals.load(now: Date()) where items[journal.folderTransferId] == nil {
            let item = Item(id: journal.folderTransferId, phoneID: journal.deviceID, root: journal.resolveRoot(), options: journal.options, startedAt: journal.createdAt)
            item.displayName = journal.displayName
            item.journal = journal
            item.destination = journal.destination
            item.destinationLabel = journal.destinationLabel
            item.state = .interrupted
            item.canResume = true
            item.canSendAgain = true
            item.progress.filesTotal = journal.fileCount
            item.progress.bytesTotal = journal.totalSize
            item.progress.filesDone = journal.completed.count
            item.progress.rootName = journal.rootName
            item.progress.destinationLabel = journal.destinationLabel
            items[item.id] = item
            publish(item)
        }
    }

    /// The phone sent its features (after connecting, or later): resume what was interrupted. A folder still
    /// bound to an older session of the same phone (a replaced duplicate) is interrupted first.
    func phoneReady(_ phoneID: String) {
        guard let support = host?.folderSupport(for: phoneID), support.folders,
              let token = host?.folderTransport(for: phoneID)?.session else { return }
        for item in items.values where item.phoneID == phoneID && item.state == .running && item.sessionToken != nil && item.sessionToken != token {
            interruptSession(item)
        }
        let now = Date()
        for item in items.values.sorted(by: { $0.startedAt < $1.startedAt })
        where item.phoneID == phoneID && item.state == .interrupted && item.journal != nil && !item.inQueue {
            guard let journal = item.journal, journal.canResume(now: now) else {
                expire(item)
                continue
            }
            queueResume(item)
        }
    }

    /// One phone disconnected: its folders stop where they are.
    func phoneDisconnected(_ phoneID: String) {
        places.cancelAll(phoneID: phoneID)
        for item in Array(items.values) where item.phoneID == phoneID {
            item.inQueue = false
            item.startWhenReady = false
            switch item.state {
            case .running:
                interruptSession(item)
            case .preparing, .choosing, .queued:
                if sheet?.id == item.id {
                    // The sheet goes, and with it the folder (nothing was sent).
                    closeSheet()
                    continue
                }
                pendingSheets.removeAll { $0.id == item.id }
                if item.journal != nil {
                    item.state = .interrupted
                    item.session = nil
                } else {
                    item.scanToken.cancel()
                    end(item, state: .incomplete, text: L10n.text("folders.end.lost", fallback: "Connection lost"), sendAgain: true)
                }
            default:
                break
            }
            publish(item)
        }
    }

    /// Forget device: its journals, last destination and folders go.
    func forget(_ phoneID: String) {
        phoneDisconnected(phoneID)
        journals.deleteAll(deviceID: phoneID)
        memory.forget(phoneID)
        for item in Array(items.values) where item.phoneID == phoneID {
            items.removeValue(forKey: item.id)
            host?.folderRowRemoved(item.id)
        }
    }

    func owns(_ id: String) -> Bool { items[id] != nil }

    /// Files 2.0 browse: files and folders into a folder of a place (an `into` offer). Nil when it cannot start.
    func upload(_ request: UploadRequest) -> String? {
        request.completion(.failure(.code(FolderCode.unsupported)))
        return nil
    }

    // MARK: Sending

    /// Folders dropped or picked for one phone. Each becomes one queue item. False when the phone cannot
    /// receive folders (nothing is sent; the status says so).
    @discardableResult
    func send(_ folders: [URL], to phoneID: String) -> Bool {
        guard let host else { return false }
        guard let support = host.folderSupport(for: phoneID), support.folders else {
            host.folderStatus(FolderText.cannotReceive(host.phoneName(phoneID)))
            return false
        }
        let now = Date()
        for (index, url) in folders.enumerated() {
            let item = Item(id: UUID().uuidString.lowercased(), phoneID: phoneID, root: url, options: host.folderScanDefaults,
                            startedAt: now.addingTimeInterval(Double(index) / 1_000))
            items[item.id] = item
            publish(item)
            startScan(item)
            if support.places {
                placesWaiting.append(item.id)
            } else {
                enqueue(item)
            }
        }
        askNextPlaces()
        return true
    }

    private func askNextPlaces() {
        guard placesAsking == nil else { return }
        while !placesWaiting.isEmpty {
            let id = placesWaiting.removeFirst()
            guard let item = items[id], item.state == .preparing else { continue }
            placesAsking = id
            askPlaces(item)
            return
        }
    }

    private func askPlaces(_ item: Item) {
        guard let host, let wire = host.folderTransport(for: item.phoneID) else {
            placesAsking = nil
            end(item, state: .incomplete, text: L10n.text("folders.end.lost", fallback: "Connection lost"), sendAgain: true)
            askNextPlaces()
            return
        }
        let send: PlacesClient.Send = { kind, payload in wire.transport.send(kind: kind, payload: payload, transferID: nil, sequence: nil) }
        places.list(phoneID: item.phoneID, send: send) { [weak self] result in
            guard let self else { return }
            self.placesAsking = nil
            defer { self.askNextPlaces() }
            guard let item = self.items[item.id], item.state == .preparing || item.state == .choosing else { return }
            switch result {
            case let .success(listed):
                item.mode = listed.mode
                switch listed.mode {
                case .senderPicks:
                    self.presentSheet(item, listed: listed)
                case .receiverAsks:
                    self.enqueue(item)
                case .fixed:
                    item.fixedLabel = listed.fixedLabel
                    self.enqueue(item)
                }
            case .failure(.timeout):
                self.end(item, state: .incomplete, text: FolderText.noAnswer(host.phoneName(item.phoneID)), sendAgain: true)
            case .failure(.notConnected):
                self.end(item, state: .incomplete, text: L10n.text("folders.end.lost", fallback: "Connection lost"), sendAgain: true)
            case let .failure(.code(code)):
                self.end(item, state: .incomplete, text: FolderText.rejection(code: code, phone: host.phoneName(item.phoneID), needed: nil, free: nil), sendAgain: true)
            }
        }
    }

    private func enqueue(_ item: Item) {
        if let problem = item.scan?.problem {
            refuse(item, problem)
            return
        }
        item.state = .queued
        item.inQueue = true
        publish(item)
        host?.enqueueFolder(item.id, phoneID: item.phoneID)
    }

    private func refuse(_ item: Item, _ problem: FolderLimitProblem) {
        end(item, state: .incomplete, text: problem.message(folder: item.displayName), sendAgain: false)
    }

    /// The phone's queue reached this folder.
    func start(_ id: String) {
        guard let item = items[id], item.state == .queued else {
            host?.folderEnded(id)
            return
        }
        item.state = .running
        item.progress.phase = .offered
        if let problem = item.scan?.problem {
            refuse(item, problem)
            host?.folderEnded(id)
            return
        }
        if item.hashed != nil {
            beginSession(item)
        } else {
            item.startWhenReady = true
            item.state = .preparing
            if item.scan == nil && item.hashing == nil { startScan(item) }
            publish(item)
        }
    }

    private func startScan(_ item: Item, reuse: FolderScan? = nil) {
        item.scanToken.cancel()
        let token = FolderCancelToken()
        item.scanToken = token
        item.scan = nil
        item.hashed = nil
        item.hashing = nil
        let root = item.root
        let options = item.options
        let id = item.id
        scanQueue.async { [weak self] in
            let scan = FolderScanner.scan(root, options: options, isCancelled: { token.isCancelled })
            guard !token.isCancelled else { return }
            DispatchQueue.main.async { self?.scanned(id, scan, token: token) }
            guard scan.problem == nil else { return }
            if let reuse, Self.sameFiles(reuse, scan) {
                // Nothing changed since the last attempt (names, sizes, dates): its hashes still hold, and the
                // running hash while sending catches anything that changed without touching those.
                var hashed = reuse
                hashed.sources = scan.sources
                DispatchQueue.main.async { self?.hashed(id, hashed, token: token) }
                return
            }
            var last = Date.distantPast
            let hashed = FolderHasher.hash(scan, progress: { done, total in
                let now = Date()
                guard now.timeIntervalSince(last) >= 0.1 else { return }
                last = now
                let fraction = Double(done) / Double(max(total, 1))
                DispatchQueue.main.async { self?.hashProgress(id, fraction, token: token) }
            }, isCancelled: { token.isCancelled })
            guard let hashed, !token.isCancelled else { return }
            DispatchQueue.main.async { self?.hashed(id, hashed, token: token) }
        }
        publish(item)
    }

    nonisolated private static func sameFiles(_ old: FolderScan, _ new: FolderScan) -> Bool {
        guard old.rootName == new.rootName, old.entries.count == new.entries.count else { return false }
        return zip(old.entries, new.entries).allSatisfy { $0.type == $1.type && $0.path == $1.path && $0.size == $1.size && $0.modified == $1.modified }
    }

    private func scanned(_ id: String, _ scan: FolderScan, token: FolderCancelToken) {
        guard let item = items[id], item.scanToken === token else { return }
        item.scan = scan
        item.hashing = scan.problem == nil ? 0 : nil
        item.progress.filesTotal = scan.fileCount
        item.progress.bytesTotal = scan.totalSize
        if sheet?.id == id { updateSheetSummary(item) }
        if let problem = scan.problem, item.state != .choosing, item.state != .preparing || item.startWhenReady || item.inQueue {
            let started = item.startWhenReady
            item.startWhenReady = false
            refuse(item, problem)
            if started { host?.folderEnded(id) }
            return
        }
        publish(item)
    }

    private func hashProgress(_ id: String, _ fraction: Double, token: FolderCancelToken) {
        guard let item = items[id], item.scanToken === token, item.hashed == nil else { return }
        item.hashing = fraction
        if sheet?.id == id { sheet?.controller.model.state.hashing = fraction }
        publish(item)
    }

    private func hashed(_ id: String, _ scan: FolderScan, token: FolderCancelToken) {
        guard let item = items[id], item.scanToken === token else { return }
        item.hashed = scan
        item.hashing = nil
        item.progress.filesTotal = scan.fileCount
        item.progress.bytesTotal = scan.totalSize
        if sheet?.id == id {
            sheet?.controller.model.state.hashing = nil
            updateSheetSummary(item)
        }
        if item.resuming, let journal = item.journal, scan.manifestDigest != journal.manifestSha256 {
            // The folder changed since: the phone's journal cannot match. Offer Send again.
            journals.delete(journal.folderTransferId)
            item.journal = nil
            end(item, state: .incomplete, text: L10n.text("folders.end.changed", fallback: "The folder changed since it was sent. Send it again."), sendAgain: true)
            record(item, .folderIncomplete, end: "changed")
            return
        }
        if item.startWhenReady {
            item.startWhenReady = false
            item.state = .running
            beginSession(item)
        } else {
            publish(item)
        }
    }

    private func beginSession(_ item: Item) {
        guard let host, let hashed = item.hashed else { return }
        guard let wire = host.folderTransport(for: item.phoneID) else {
            item.state = item.journal != nil ? .interrupted : .incomplete
            item.endText = item.journal == nil ? L10n.text("folders.end.lost", fallback: "Connection lost") : nil
            item.canSendAgain = true
            item.canResume = item.journal != nil
            item.inQueue = false
            publish(item)
            host.folderEnded(item.id)
            return
        }
        let plan = FolderSendPlan(folderTransferID: item.id, scan: hashed, destination: item.resuming ? item.journal?.destination : item.destination, resume: item.resuming)
        let queue = DispatchQueue(label: "in.roundrobin.bridgey.folder-send", qos: .userInitiated)
        let relay = FolderSessionRelay(owner: self, id: item.id)
        let session = FolderSendSession(
            plan: plan,
            alreadyCompleted: Set(item.resuming ? item.journal?.completed ?? [] : []),
            transport: wire.transport,
            clock: DispatchFolderClock(queue: queue),
            files: DiskFolderFileSource(sources: hashed.sources),
            events: relay,
            fileOwnership: ownership
        )
        relay.session = session
        item.session = session
        item.sessionQueue = queue
        item.sessionToken = wire.session
        item.state = .running
        item.endText = nil
        item.canResume = false
        item.canSendAgain = false
        item.progress = FolderProgress()
        item.progress.filesTotal = hashed.fileCount
        item.progress.bytesTotal = hashed.totalSize
        item.progress.rootName = hashed.rootName
        BridgeyLog.plugin.notice("folder offer transfer=\(String(item.id.prefix(8)), privacy: .public) files=\(hashed.fileCount, privacy: .public) folders=\(hashed.folderCount, privacy: .public) resume=\(item.resuming, privacy: .public)")
        publish(item)
        queue.async { session.start() }
    }

    private func onSession(_ item: Item, _ body: @escaping (FolderSendSession) -> Void) {
        guard let session = item.session, let queue = item.sessionQueue else { return }
        queue.async { body(session) }
    }

    private func interruptSession(_ item: Item) {
        item.state = item.journal != nil ? .interrupted : .incomplete
        onSession(item) { $0.interrupt() }
    }

    private func queueResume(_ item: Item) {
        guard let journal = item.journal else { return }
        let reuse = item.hashed ?? item.previous
        item.resuming = true
        item.root = journal.resolveRoot()
        item.options = journal.options
        item.destination = journal.destination
        item.state = .queued
        item.inQueue = true
        item.canResume = false
        item.endText = nil
        item.hashed = nil
        item.scan = nil
        startScan(item, reuse: reuse)
        publish(item)
        host?.enqueueFolder(item.id, phoneID: item.phoneID)
        BridgeyLog.plugin.notice("folder resume queued transfer=\(String(item.id.prefix(8)), privacy: .public)")
    }

    private func expire(_ item: Item) {
        if let journal = item.journal { journals.delete(journal.folderTransferId) }
        item.journal = nil
        end(item, state: .incomplete, text: FolderText.incomplete(progress: item.progress), sendAgain: true)
        record(item, .folderIncomplete, end: "lost")
    }

    /// Interrupted folders whose 24 hours ran out while the phone stayed away: their journals go.
    private func sweepExpired() {
        let now = Date()
        for item in Array(items.values) where item.state == .interrupted {
            if let journal = item.journal, !journal.canResume(now: now) { expire(item) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.sweepExpired() }
    }

    // MARK: Row actions

    /// Cancel on the row, Cancel All, or the queue: the whole folder stops.
    func cancel(_ id: String) {
        guard let item = items[id] else { return }
        switch item.state {
        case .running:
            if item.session != nil {
                onSession(item) { $0.cancel() }
            } else {
                item.startWhenReady = false
                item.scanToken.cancel()
                end(item, state: .incomplete, text: L10n.text("folders.end.cancelled", fallback: "Cancelled"), sendAgain: true)
                host?.folderEnded(id)
            }
        case .preparing, .choosing, .queued:
            if sheet?.id == id { closeSheet() }
            pendingSheets.removeAll { $0.id == id }
            item.scanToken.cancel()
            let wasStarted = item.startWhenReady
            if let journal = item.journal { journals.delete(journal.folderTransferId) }
            item.journal = nil
            end(item, state: .incomplete, text: L10n.text("folders.end.cancelled", fallback: "Cancelled"), sendAgain: true)
            if wasStarted { host?.folderEnded(id) }
        case .interrupted:
            if let journal = item.journal { journals.delete(journal.folderTransferId) }
            item.journal = nil
            end(item, state: .incomplete, text: L10n.text("folders.end.cancelled", fallback: "Cancelled"), sendAgain: true)
            record(item, .folderIncomplete, end: "cancelled")
        case .done, .incomplete:
            break
        }
    }

    /// Cancel All: every folder that is preparing, waiting in the queue or running. Interrupted folders keep
    /// their Resume.
    func cancelAll() {
        for item in Array(items.values) where [.preparing, .choosing, .queued, .running].contains(item.state) { cancel(item.id) }
    }

    /// The coordinator removed the folder from the queue before it started: Cancel on a queued folder
    /// (`text` nil), or Files turned off (`text` says so).
    func removedFromQueue(_ id: String, text: String?) {
        guard let item = items[id] else { return }
        item.inQueue = false
        guard let text else {
            cancel(id)
            return
        }
        item.scanToken.cancel()
        if item.journal != nil {
            item.state = .interrupted
            item.endText = text
            item.canResume = true
            item.canSendAgain = true
            publish(item)
        } else {
            end(item, state: .incomplete, text: text, sendAgain: true)
        }
    }

    /// Resume on the row: the same transfer, offered again with resume.
    func resume(_ id: String) {
        guard let item = items[id], item.journal != nil, item.state == .interrupted || (item.state == .incomplete && item.canResume) else { return }
        guard let support = host?.folderSupport(for: item.phoneID), support.folders else {
            host?.folderStatus(String(format: L10n.text("folders.resume.offline", fallback: "Connect %@ to resume"), host?.phoneName(item.phoneID) ?? ""))
            return
        }
        guard let journal = item.journal, journal.canResume(now: Date()) else {
            expire(item)
            return
        }
        queueResume(item)
    }

    /// Send again: a new transfer with new IDs, which may ask about the existing folder again.
    func sendAgain(_ id: String) {
        guard let item = items[id] else { return }
        let root = item.journal?.resolveRoot() ?? item.root
        if let journal = item.journal { journals.delete(journal.folderTransferId) }
        items.removeValue(forKey: id)
        host?.folderRowRemoved(id)
        send([root], to: item.phoneID)
    }

    func canResume(_ id: String) -> Bool { items[id].map { $0.journal != nil && ($0.state == .interrupted || $0.canResume) } ?? false }
    func canSendAgain(_ id: String) -> Bool { items[id]?.canSendAgain ?? false }

    func clearFinished() {
        for item in Array(items.values) where item.state == .done || (item.state == .incomplete && item.journal == nil) {
            items.removeValue(forKey: item.id)
        }
    }

    // MARK: Messages from the phone

    /// A decrypted folders.* or places.* payload, or an outer-only message (`payload` nil).
    func receive(kind: String, payload: Data?, outerTransferID: String?, from phoneID: String) {
        if FolderKind.placesKinds.contains(kind) {
            if let payload { places.handle(kind: kind, payload: payload, from: phoneID) }
            return
        }
        let decoder = JSONDecoder()
        guard let payload else {
            // Outer only: folders.cancel.ack, or folders.rejected when Files is off on the phone.
            guard let id = outerTransferID, let item = items[id], item.phoneID == phoneID else { return }
            switch kind {
            case FolderKind.cancelAck: onSession(item) { $0.receivedCancelAck() }
            case FolderKind.rejected: onSession(item) { $0.receivedPolicyRejection() }
            default: break
            }
            return
        }
        guard let probe = try? decoder.decode(FolderProbe.self, from: payload), probe.version == 1 else { return }
        let item = items[probe.folderTransferId].flatMap { $0.phoneID == phoneID ? $0 : nil }
        switch kind {
        case FolderKind.waiting:
            guard let item, let value = try? decoder.decode(FolderWaitingPayload.self, from: payload) else { return }
            onSession(item) { $0.receivedWaiting(value) }
        case FolderKind.conflict:
            guard let item, let value = try? decoder.decode(FolderConflictPayload.self, from: payload) else { return }
            onSession(item) { $0.receivedConflict(value) }
        case FolderKind.accept:
            guard let item, let value = try? decoder.decode(FolderAcceptPayload.self, from: payload) else { return }
            onSession(item) { $0.receivedAccept(value) }
        case FolderKind.rejected:
            guard let item, let value = try? decoder.decode(FolderRejectedPayload.self, from: payload) else { return }
            onSession(item) { $0.receivedRejected(value) }
        case FolderKind.entryFailed:
            guard let item, let value = try? decoder.decode(FolderEntryFailedPayload.self, from: payload) else { return }
            onSession(item) { $0.receivedEntryFailed(value) }
        case FolderKind.result:
            guard let item, let value = try? decoder.decode(FolderResultPayload.self, from: payload) else { return }
            onSession(item) { $0.receivedResult(value) }
        case FolderKind.cancel:
            guard let value = try? decoder.decode(FolderCancelPayload.self, from: payload) else { return }
            if let item, item.session != nil {
                onSession(item) { $0.receivedCancel(value) }
            } else {
                // Not running here (finished, or never known): acknowledge anyway, as the cancel is idempotent.
                host?.folderTransport(for: phoneID)?.transport.sendOuter(kind: FolderKind.cancelAck, transferID: probe.folderTransferId)
            }
        default:
            break
        }
    }

    /// files.accept, files.chunk.ack, files.complete.ack, files.cancel and files.rejected for a file inside a
    /// folder. Returns false when the transfer ID is not a folder file.
    func receiveFile(kind: String, transferID: String?, sequence: Int64?, from phoneID: String) -> Bool {
        guard let transferID, let folderID = ownership.folder(of: transferID) else { return false }
        guard let item = items[folderID], item.phoneID == phoneID else { return true }
        switch kind {
        case "files.accept": onSession(item) { $0.fileAccepted(transferID) }
        case "files.chunk.ack": if let sequence { onSession(item) { $0.chunkAcknowledged(transferID, sequence: sequence) } }
        case "files.complete.ack": onSession(item) { $0.completeAcknowledged(transferID) }
        case "files.cancel": onSession(item) { $0.fileCancelledByPhone(transferID) }
        case "files.rejected": onSession(item) { $0.receivedPolicyRejection() }
        default: break
        }
        return true
    }

    private struct FolderProbe: Decodable {
        var version = 1
        let folderTransferId: String
    }

    // MARK: Session events (main thread)

    fileprivate func sessionProgress(_ id: String, _ progress: FolderProgress, session: FolderSendSession) {
        guard let item = items[id], item.session === session, item.state == .running else { return }
        item.progress = progress
        publish(item)
    }

    fileprivate func sessionAsks(_ id: String, _ conflict: FolderConflictPayload, deadline: Date, session: FolderSendSession) {
        guard let item = items[id], item.session === session, let host else { return }
        question?.controller.dismiss()
        let destination = item.destinationLabel ?? host.phoneName(item.phoneID)
        let state = FolderConflictState(
            name: item.hashed?.rootName ?? item.displayName,
            destination: destination,
            message: FolderText.conflictMessage(conflict, name: item.hashed?.rootName ?? item.displayName, destination: destination, totalFiles: item.progress.filesTotal),
            choices: conflict.choices.filter { $0 != .cancel && $0 != .none },
            newFolderName: conflict.newFolderName,
            deadline: deadline
        )
        let controller = FolderConflictWindowController(state: state, reduceMotion: host.folderReduceMotion) { [weak self] choice in
            guard let self, let item = self.items[id], item.session === session else { return }
            self.question = nil
            self.onSession(item) { $0.resolve(choice) }
        }
        question = (id, controller)
        controller.show()
    }

    fileprivate func sessionQuestionClosed(_ id: String) {
        guard let question, question.id == id else { return }
        self.question = nil
        question.controller.dismiss()
    }

    fileprivate func sessionAccepted(_ id: String, _ accept: FolderAcceptPayload, session: FolderSendSession) {
        guard let item = items[id], item.session === session, let hashed = item.hashed, let host else { return }
        item.destinationLabel = accept.destinationLabel
        if var journal = item.journal {
            journal.destinationLabel = accept.destinationLabel
            journal.lastProgressAt = Date()
            journal.deviceName = host.phoneName(item.phoneID)
            item.journal = journal
            journals.save(journal)
        } else {
            let journal = FolderJournal(
                folderTransferId: id, deviceID: item.phoneID, deviceName: host.phoneName(item.phoneID),
                rootPath: item.root.path, bookmark: try? item.root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                displayName: item.displayName, rootName: hashed.rootName, options: item.options, destination: item.destination,
                destinationLabel: accept.destinationLabel, manifestSha256: hashed.manifestDigest, fileCount: hashed.fileCount,
                totalSize: hashed.totalSize, createdAt: Date(), lastProgressAt: Date(), completed: []
            )
            item.journal = journal
            journals.save(journal)
        }
        BridgeyLog.plugin.notice("folder accepted transfer=\(String(id.prefix(8)), privacy: .public) choice=\(accept.choice.rawValue, privacy: .public)")
    }

    fileprivate func sessionCompleted(_ id: String, _ completed: Set<Int>, at date: Date, session: FolderSendSession) {
        guard let item = items[id], item.session === session, var journal = item.journal else { return }
        item.autoResumes = 0
        journal.completed = completed.sorted()
        journal.lastProgressAt = date
        item.journal = journal
        // Written at most once a second: a lost line only means the phone's bitmap covers that file.
        guard !item.journalDirty else { return }
        item.journalDirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak item] in
            guard let self, let item else { return }
            item.journalDirty = false
            if let journal = item.journal { self.journals.save(journal) }
        }
    }

    fileprivate func sessionFinished(_ id: String, _ outcome: FolderOutcome, progress: FolderProgress, session: FolderSendSession) {
        guard let item = items[id], item.session === session, let host else { return }
        item.session = nil
        item.sessionQueue = nil
        item.sessionToken = nil
        item.progress = progress
        item.resuming = false
        item.inQueue = false
        if question?.id == id { sessionQuestionClosed(id) }
        let phone = host.phoneName(item.phoneID)
        let name = progress.destinationLabel != nil ? progress.rootName ?? item.displayName : item.displayName
        let text = FolderText.outcome(outcome, name: name, phone: phone, destination: item.destinationLabel, progress: progress)
        BridgeyLog.plugin.notice("folder ended transfer=\(String(id.prefix(8)), privacy: .public) outcome=\(Self.logName(outcome), privacy: .public) done=\(progress.filesDone, privacy: .public) failed=\(progress.failedCount, privacy: .public)")
        switch outcome {
        case .interrupted:
            item.previous = item.hashed
            if let journal = item.journal {
                journals.save(journal)
                item.state = .interrupted
                item.endText = nil
                item.canResume = true
                item.canSendAgain = true
                publish(item)
                // Still connected (acknowledgements stalled, or a newer session replaced the old one): try again
                // now, a few times; after that the row keeps Resume.
                if host.folderSupport(for: item.phoneID)?.folders == true, item.autoResumes < 3 {
                    item.autoResumes += 1
                    host.folderEnded(id)
                    queueResume(item)
                    return
                }
            } else {
                end(item, state: .incomplete, text: L10n.text("folders.end.lost", fallback: "Connection lost"), sendAgain: true)
                record(item, .folderIncomplete, end: "lost")
            }
        case let .done(result):
            dropJournal(item)
            if result.isComplete {
                end(item, state: .done, text: text, sendAgain: false)
                record(item, .folderSent, result: result)
            } else {
                end(item, state: .incomplete, text: text, sendAgain: true)
                record(item, .folderIncomplete, result: result)
            }
            host.folderStatus(text)
        case .unconfirmed:
            dropJournal(item)
            end(item, state: .incomplete, text: text, sendAgain: true)
            record(item, .folderIncomplete, end: "unconfirmed")
        case let .rejected(code, _, _):
            dropJournal(item)
            end(item, state: .incomplete, text: text, sendAgain: code != FolderCode.limitExceeded)
            record(item, .folderIncomplete, end: code)
        case .filesOff:
            dropJournal(item)
            end(item, state: .incomplete, text: text, sendAgain: true)
        case .cancelledHere:
            dropJournal(item)
            end(item, state: .incomplete, text: text, sendAgain: true)
            record(item, .folderIncomplete, end: "cancelled")
        case .cancelledByPhone:
            dropJournal(item)
            end(item, state: .incomplete, text: text, sendAgain: true)
            record(item, .folderIncomplete, end: "phone_cancelled")
        case .noAnswer, .questionTimedOut:
            dropJournal(item)
            end(item, state: .incomplete, text: text, sendAgain: true)
            record(item, .folderIncomplete, end: "timeout")
        }
        host.folderEnded(id)
    }

    private static func logName(_ outcome: FolderOutcome) -> String {
        switch outcome {
        case let .done(result): return result.isComplete ? "complete" : "incomplete"
        case .unconfirmed: return "unconfirmed"
        case let .rejected(code, _, _): return "rejected_\(code)"
        case .filesOff: return "files_off"
        case .cancelledHere: return "cancelled"
        case .cancelledByPhone: return "cancelled_remote"
        case .noAnswer: return "no_answer"
        case .questionTimedOut: return "question_timeout"
        case .interrupted: return "interrupted"
        }
    }

    private func dropJournal(_ item: Item) {
        if let journal = item.journal { journals.delete(journal.folderTransferId) }
        item.journal = nil
    }

    private func end(_ item: Item, state: FolderRowState, text: String?, sendAgain: Bool) {
        item.state = state
        item.endText = text
        item.canSendAgain = sendAgain
        item.canResume = false
        item.hashing = nil
        item.inQueue = false
        publish(item)
    }

    private func record(_ item: Item, _ kind: ActivityKind, result: FolderResultPayload? = nil, end: String? = nil) {
        guard let host else { return }
        let skipped = item.hashed?.skipped ?? item.scan?.skipped ?? SkippedCounts()
        var detail = FolderActivityDetail(links: skipped.links, hidden: skipped.hidden, system: skipped.system, end: end)
        detail.failed = max(item.progress.failedCount, result?.failedCount ?? 0)
        if let result {
            detail.kept = result.renamedFiles
            detail.replaced = result.replacedFiles
        }
        if let choice = item.progress.choice, choice != .none { detail.choice = choice.rawValue }
        if item.progress.choice == .newFolder { detail.savedAs = item.progress.rootName }
        if kind == .folderIncomplete {
            detail.doneFiles = item.progress.filesDone
            detail.doneBytes = item.progress.bytesDone
        }
        host.recordFolderActivity(kind, phoneID: item.phoneID, name: item.displayName, fileCount: item.progress.filesTotal,
                                  bytes: item.progress.bytesTotal, destination: item.destinationLabel, detail: detail)
    }

    // MARK: Rows

    private func publish(_ item: Item) {
        guard let host else { return }
        var summary = FolderRowSummary(phoneName: host.phoneName(item.phoneID), displayName: item.displayName)
        summary.destinationLabel = item.destinationLabel
        summary.fixedLabel = item.fixedLabel
        summary.state = item.state
        summary.progress = item.progress
        summary.hashing = item.state == .preparing ? item.hashing : nil
        summary.skipped = item.hashed?.skipped ?? item.scan?.skipped ?? SkippedCounts()
        summary.endText = item.endText
        summary.canResume = item.journal != nil && (item.state == .interrupted || item.canResume)
        summary.canSendAgain = item.canSendAgain
        let active = [.preparing, .choosing, .queued, .running].contains(item.state)
        host.folderRowChanged(FileTransferRow(
            id: item.id,
            name: item.displayName,
            status: FolderText.status(summary, now: Date()),
            active: active,
            startedAt: item.startedAt,
            retryable: !active && (summary.canResume || summary.canSendAgain),
            queued: item.state == .queued,
            folder: summary
        ))
    }

    // MARK: Send sheet

    private func presentSheet(_ item: Item, listed: PlacesListedPayload) {
        guard sheet == nil else {
            item.state = .choosing
            pendingSheets.append((item.id, listed))
            publish(item)
            return
        }
        guard let host else { return }
        item.state = .choosing
        let ordered = listed.places.filter { $0.placeId == defaultPlaceID } + listed.places.filter { $0.placeId != defaultPlaceID }
        var state = FolderSheetState()
        state.phoneName = host.phoneName(item.phoneID)
        state.folderName = item.displayName
        state.rootName = item.scan?.rootName ?? PortableName.convert(item.displayName)
        state.places = ordered
        state.options = item.options
        let last = memory.last(for: item.phoneID)
        if let last, ordered.contains(where: { $0.placeId == last.placeId && $0.available }) {
            state.placeID = last.placeId
            state.path = FolderPaths.components(last.path)
        } else {
            state.placeID = ordered.first { $0.available }?.placeId
        }
        let model = FolderSheetModel(state: state)
        let controller = FolderSheetWindowController(model: model, reduceMotion: host.folderReduceMotion)
        sheet = (item.id, controller, 0, nil)
        model.actions = sheetActions(item.id)
        controller.onClose = { [weak self] in self?.sheetClosed(item.id, sent: false) }
        updateSheetSummary(item)
        publish(item)
        controller.show()
        browse(reset: true, fallbackToRoot: true)
    }

    private func sheetActions(_ id: String) -> FolderSheetActions {
        var actions = FolderSheetActions()
        actions.selectPlace = { [weak self] placeID in
            guard let self, let model = self.sheetModel(id) else { return }
            model.state.placeID = placeID
            model.state.path = []
            self.browse(reset: true)
        }
        actions.open = { [weak self] name in
            guard let self, let model = self.sheetModel(id) else { return }
            model.state.path.append(name)
            self.browse(reset: true)
        }
        actions.goTo = { [weak self] depth in
            guard let self, let model = self.sheetModel(id) else { return }
            model.state.path = Array(model.state.path.prefix(depth))
            self.browse(reset: true)
        }
        actions.loadMore = { [weak self] in self?.browse(reset: false) }
        actions.showNewFolder = { [weak self] open in
            guard let model = self?.sheetModel(id) else { return }
            model.state.newFolderOpen = open
            if !open { model.state.newFolderName = "" }
        }
        actions.setNewFolderName = { [weak self] name in self?.sheetModel(id)?.state.newFolderName = name }
        actions.createFolder = { [weak self] in self?.createFolder(id) }
        actions.setIncludeHidden = { [weak self] value in self?.changeOptions(id) { $0.includeHidden = value } }
        actions.setIncludeSystem = { [weak self] value in self?.changeOptions(id) { $0.includeSystem = value } }
        actions.send = { [weak self] in self?.sheetSend(id) }
        actions.cancel = { [weak self] in self?.sheet?.controller.window?.close() }
        return actions
    }

    private func sheetModel(_ id: String) -> FolderSheetModel? {
        guard let sheet, sheet.id == id else { return nil }
        return sheet.controller.model
    }

    private func updateSheetSummary(_ item: Item) {
        guard let model = sheetModel(item.id) else { return }
        let scan = item.hashed ?? item.scan
        model.state.scanning = scan == nil
        model.state.rootName = scan?.rootName ?? model.state.rootName
        model.state.fileCount = scan?.fileCount ?? 0
        model.state.folderCount = scan?.folderCount ?? 0
        model.state.totalSize = scan?.totalSize ?? 0
        model.state.skipped = scan?.skipped ?? SkippedCounts()
        model.state.packages = scan?.packages ?? []
        model.state.renamed = scan?.renamed ?? 0
        model.state.problem = scan?.problem?.message(folder: item.displayName)
        model.state.hashing = item.hashed == nil && scan?.problem == nil && scan != nil ? (item.hashing ?? 0) : nil
        model.state.options = item.options
    }

    private func changeOptions(_ id: String, _ change: (inout FolderScanOptions) -> Void) {
        guard let item = items[id] else { return }
        change(&item.options)
        startScan(item)
        updateSheetSummary(item)
    }

    private func browse(reset: Bool, fallbackToRoot: Bool = false) {
        guard let sheet, let item = items[sheet.id], let host, let wire = host.folderTransport(for: item.phoneID) else { return }
        let model = sheet.controller.model
        guard let placeID = model.state.placeID else { return }
        let path = model.state.path.joined(separator: "/")
        let generation = sheet.browse + 1
        self.sheet?.browse = generation
        if reset {
            model.state.folders = []
            self.sheet?.cursor = nil
        }
        model.state.loading = true
        model.state.error = nil
        let cursor = reset ? nil : sheet.cursor
        let id = sheet.id
        places.browse(phoneID: item.phoneID, placeId: placeID, path: path, cursor: cursor,
                      send: { kind, payload in wire.transport.send(kind: kind, payload: payload, transferID: nil, sequence: nil) }) { [weak self] result in
            guard let self, let current = self.sheet, current.id == id, current.browse == generation else { return }
            model.state.loading = false
            switch result {
            case let .success(children):
                model.state.folders += children.folders.filter { !$0.hasPrefix(".") }
                model.state.hasMore = children.nextCursor != nil
                self.sheet?.cursor = children.nextCursor
            case .failure(.code(FolderCode.notFound)) where fallbackToRoot && !model.state.path.isEmpty:
                model.state.path = []
                self.browse(reset: true)
            case .failure(.timeout):
                model.state.error = FolderText.noAnswer(host.phoneName(item.phoneID))
            case let .failure(.code(code)):
                model.state.error = FolderText.rejection(code: code, phone: host.phoneName(item.phoneID), needed: nil, free: nil)
            case .failure(.notConnected):
                model.state.error = L10n.text("folders.end.lost", fallback: "Connection lost")
            }
        }
    }

    private func createFolder(_ id: String) {
        guard let model = sheetModel(id), !model.state.creating, let item = items[id], let host,
              let placeID = model.state.placeID, let wire = host.folderTransport(for: item.phoneID) else { return }
        let name = model.state.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.state.creating = true
        model.state.error = nil
        let path = model.state.path.joined(separator: "/")
        places.createFolder(phoneID: item.phoneID, placeId: placeID, path: path, name: name,
                            send: { kind, payload in wire.transport.send(kind: kind, payload: payload, transferID: nil, sequence: nil) }) { [weak self] result in
            guard let self, let model = self.sheetModel(id) else { return }
            model.state.creating = false
            switch result {
            case let .success(created):
                model.state.newFolderOpen = false
                model.state.newFolderName = ""
                model.state.path.append(created.name)
                self.browse(reset: true)
            case .failure(.timeout):
                model.state.error = FolderText.noAnswer(host.phoneName(item.phoneID))
            case .failure(.code(FolderCode.exists)):
                model.state.error = L10n.text("folders.sheet.exists", fallback: "A folder with that name is already there.")
            case let .failure(.code(code)):
                model.state.error = FolderText.rejection(code: code, phone: host.phoneName(item.phoneID), needed: nil, free: nil)
            case .failure(.notConnected):
                model.state.error = L10n.text("folders.end.lost", fallback: "Connection lost")
            }
        }
    }

    private func sheetSend(_ id: String) {
        guard let model = sheetModel(id), model.state.canSend, let item = items[id],
              let place = model.state.selectedPlace else { return }
        let path = model.state.path.joined(separator: "/")
        let destination = FolderDestination(placeId: place.placeId, path: path)
        item.destination = destination
        item.destinationLabel = ([place.label] + model.state.path).joined(separator: "/")
        memory.remember(destination, for: item.phoneID)
        sheetClosed(id, sent: true)
        enqueue(item)
    }

    private func sheetClosed(_ id: String, sent: Bool) {
        guard let current = sheet, current.id == id else { return }
        sheet = nil
        current.controller.dismiss()
        if !sent, let item = items[id] {
            item.scanToken.cancel()
            items.removeValue(forKey: id)
            host?.folderRowRemoved(id)
        }
        if !pendingSheets.isEmpty {
            let next = pendingSheets.removeFirst()
            if let item = items[next.id] { presentSheet(item, listed: next.listed) }
        }
    }

    private func closeSheet() {
        guard let current = sheet else { return }
        sheetClosed(current.id, sent: false)
    }
}

/// Session events arrive on the session's queue; this hops them to the main thread.
private final class FolderSessionRelay: FolderSessionEvents {
    weak var owner: FolderSender?
    weak var session: FolderSendSession?
    let id: String

    init(owner: FolderSender, id: String) {
        self.owner = owner
        self.id = id
    }

    private func onMain(_ body: @escaping @MainActor (FolderSender, FolderSendSession) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let owner = self.owner, let session = self.session else { return }
            body(owner, session)
        }
    }

    func folderProgress(_ progress: FolderProgress) {
        let id = id
        onMain { $0.sessionProgress(id, progress, session: $1) }
    }

    func folderAsks(_ conflict: FolderConflictPayload, deadline: Date) {
        let id = id
        onMain { $0.sessionAsks(id, conflict, deadline: deadline, session: $1) }
    }

    func folderQuestionClosed() {
        let id = id
        onMain { owner, _ in owner.sessionQuestionClosed(id) }
    }

    func folderEntriesCompleted(_ completed: Set<Int>, at date: Date) {
        let id = id
        onMain { $0.sessionCompleted(id, completed, at: date, session: $1) }
    }

    func folderAccepted(_ accept: FolderAcceptPayload) {
        let id = id
        onMain { $0.sessionAccepted(id, accept, session: $1) }
    }

    func folderFinished(_ outcome: FolderOutcome, progress: FolderProgress) {
        let id = id
        onMain { $0.sessionFinished(id, outcome, progress: progress, session: $1) }
    }
}
