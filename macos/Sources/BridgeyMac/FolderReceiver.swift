import AppKit
import Foundation

// Folders sent to this Mac (phone to Mac) and downloads from the Phone files window: one FolderReceiveSession
// per folder, each on its own serial queue; everything else on the main thread. Settings > Files decides where
// pushed folders land ("Always save to Received files", or one Save-location panel) and what happens when the
// folder exists. Downloads land where they were asked to, without questions. Rows, activity, history and
// Finder metadata happen here when a folder ends.

@MainActor
protocol FolderReceiverHost: AnyObject {
    func folderTransport(for phoneID: String) -> (transport: FolderTransport, session: ObjectIdentifier)?
    func phoneName(_ phoneID: String) -> String
    var folderReceiveMode: MacFolderReceiveMode { get }
    var folderConflictPolicy: MacFolderConflictPolicy { get }
    var tagsReceivedFiles: Bool { get }
    func receiveDirectoryAccess() -> ReceiveDirectoryAccess
    func folderRowChanged(_ row: FileTransferRow)
    func folderRowRemoved(_ id: String)
    func folderStatus(_ text: String)
    func recordFolderActivity(_ kind: ActivityKind, phoneID: String, name: String, fileCount: Int, bytes: Int64, destination: String?, detail: FolderActivityDetail)
    func recordHistory(_ entry: TransferHistoryEntry)
    /// Files and folders that arrived complete (the received-file notification decides what to show).
    func receivedItems(_ urls: [URL], phoneID: String, purpose: PhoneDownloadPurpose?)
    var folderReduceMotion: Bool { get }
}

@MainActor
final class FolderReceiver {
    private final class Item {
        let id: String
        let phoneID: String
        var session: FolderReceiveSession?
        /// The session holds its events weakly: the item keeps the relay alive while the session runs.
        var relay: AnyObject?
        var queue: DispatchQueue?
        var access: ReceiveDirectoryAccess?
        var download: ExpectedDownload?
        let purpose: PhoneDownloadPurpose?
        var progress: ReceiveProgress
        var state: FolderRowState = .running
        var endText: String?
        var resumable = false
        let startedAt: Date
        let displayName: String
        let skipped: SkippedCounts

        init(id: String, phoneID: String, purpose: PhoneDownloadPurpose?, rootName: String, startedAt: Date, skipped: SkippedCounts) {
            self.id = id
            self.phoneID = phoneID
            self.purpose = purpose
            progress = ReceiveProgress(rootName: rootName)
            displayName = rootName
            self.startedAt = startedAt
            self.skipped = skipped
        }

        var active: Bool { state == .running }
    }

    private weak var host: FolderReceiverHost?
    let journals: ReceiveJournalStore
    private let makeClock: (DispatchQueue) -> FolderClock
    private var items: [String: Item] = [:]
    /// Per-file transfer ID to folder transfer ID.
    private var fileOwners: [String: String] = [:]
    /// Files of folders that ended: their late chunks are dropped quietly instead of closing the session.
    private var endedFiles: [String] = []
    private var endedFileSet = Set<String>()
    private var expected: [String: ExpectedDownload] = [:]
    private var question: (id: String, controller: FolderConflictWindowController)?
    private var panel: (id: String, panel: NSOpenPanel)?
    /// Called with the folder's top-level items when a pushed folder or a download completes (tests).
    var onFinished: ((String, ReceiveOutcome) -> Void)?

    init(host: FolderReceiverHost?, journals: ReceiveJournalStore = ReceiveJournalStore(),
         makeClock: @escaping (DispatchQueue) -> FolderClock = { DispatchFolderClock(queue: $0) }) {
        self.host = host
        self.journals = journals
        self.makeClock = makeClock
    }

    func attach(_ host: FolderReceiverHost) { self.host = host }

    // MARK: Downloads

    func expect(_ download: ExpectedDownload) {
        expected[download.requestId] = download
    }

    func cancelExpected(_ download: ExpectedDownload) {
        download.cancelled = true
        expected.removeValue(forKey: download.requestId)
        if let item = items.values.first(where: { $0.download === download }) { cancel(item.id) }
    }

    // MARK: Start-up

    /// Journals from an earlier run: part files go, the rest resume when the phone offers them again.
    func loadJournals() {
        for record in journals.recover() {
            let header = record.header
            guard items[header.folderTransferId] == nil else { continue }
            let purpose = ReceiveLabels.purpose(header.purpose)
            let item = Item(id: header.folderTransferId, phoneID: header.peerID, purpose: purpose, rootName: header.displayName,
                            startedAt: header.createdAt, skipped: SkippedCounts())
            item.state = .interrupted
            item.resumable = true
            item.progress.filesTotal = header.fileCount
            item.progress.bytesTotal = header.totalSize
            item.progress.filesDone = record.done.count
            item.progress.destinationLabel = header.destinationLabel
            items[item.id] = item
            publish(item)
        }
    }

    // MARK: Messages from the phone

    func owns(_ folderID: String) -> Bool { items[folderID] != nil }

    func ownsFile(_ transferID: String?) -> Bool { transferID.map { fileOwners[$0] != nil || endedFileSet.contains($0) } ?? false }

    /// folders.offer, folders.manifest, folders.complete and folders.cancel for folders coming to this Mac.
    /// Returns false when the message is not for a receive (the sender handles it).
    func receive(kind: String, payload: Data?, outerTransferID: String?, from phoneID: String) -> Bool {
        guard let payload else {
            // Outer only: a folders.cancel.ack for a cancel this Mac sent.
            return kind == FolderKind.cancelAck && outerTransferID.map { items[$0] != nil } == true
        }
        let probe = try? JSONDecoder().decode(Probe.self, from: payload)
        switch kind {
        case FolderKind.offer:
            receiveOffer(payload, from: phoneID)
            return true
        case FolderKind.manifest:
            guard let probe, let item = items[probe.folderTransferId], item.phoneID == phoneID else { return false }
            guard let page = try? JSONDecoder().decode(ManifestPagePayload.self, from: payload), page.version == 1,
                  (1...FolderLimits.maxEntriesPerPage).contains(page.entries.count) else {
                onSession(item) { $0.invalidMessage() }
                return true
            }
            let size = payload.count
            onSession(item) { $0.manifestPage(page, plaintextBytes: size) }
            return true
        case FolderKind.complete:
            guard let probe, let item = items[probe.folderTransferId], item.phoneID == phoneID else { return false }
            guard let complete = try? JSONDecoder().decode(FolderCompletePayload.self, from: payload) else {
                onSession(item) { $0.invalidMessage() }
                return true
            }
            onSession(item) { $0.folderComplete(complete) }
            return true
        case FolderKind.cancel:
            guard let probe, let item = items[probe.folderTransferId], item.phoneID == phoneID else { return false }
            let cancel = (try? JSONDecoder().decode(FolderCancelPayload.self, from: payload))
                ?? FolderCancelPayload(folderTransferId: probe.folderTransferId, reason: FolderCancelPayload.error, code: nil)
            if item.session != nil {
                onSession(item) { $0.cancelledBySender(cancel) }
            } else {
                host?.folderTransport(for: phoneID)?.transport.sendOuter(kind: FolderKind.cancelAck, transferID: probe.folderTransferId)
                if item.state == .interrupted {
                    // The phone gave up on an interrupted folder: it no longer resumes.
                    journals.delete(item.id)
                    end(item, state: .incomplete, text: FolderText.incomplete(progress: folderProgress(item)))
                }
            }
            return true
        default:
            return false
        }
    }

    private struct Probe: Decodable {
        let folderTransferId: String
    }

    private func reject(_ id: String, code: String, phoneID: String) {
        guard let wire = host?.folderTransport(for: phoneID),
              let data = try? FolderJSON.encoder.encode(FolderRejectedPayload(folderTransferId: id, code: code, entry: nil, neededBytes: nil, freeBytes: nil)) else { return }
        wire.transport.send(kind: FolderKind.rejected, payload: data, transferID: id, sequence: nil)
        BridgeyLog.plugin.notice("folder receive rejected transfer=\(String(id.prefix(8)), privacy: .public) code=\(code, privacy: .public)")
    }

    private func receiveOffer(_ payload: Data, from phoneID: String) {
        guard let host else { return }
        guard let offer = try? JSONDecoder().decode(FolderOfferPayload.self, from: payload), FolderJSON.isWireID(offer.folderTransferId) else {
            if let probe = try? JSONDecoder().decode(Probe.self, from: payload), FolderJSON.isWireID(probe.folderTransferId) {
                reject(probe.folderTransferId, code: FolderCode.invalidMessage, phoneID: phoneID)
            }
            return
        }
        let id = offer.folderTransferId
        if let problem = Self.problem(offer) { return reject(id, code: problem, phoneID: phoneID) }
        if let existing = items[id] {
            guard existing.phoneID == phoneID, !existing.active else { return }
        }
        if items.values.contains(where: { $0.phoneID == phoneID && $0.active }) { return reject(id, code: FolderCode.busy, phoneID: phoneID) }
        guard let wire = host.folderTransport(for: phoneID) else { return }

        var download: ExpectedDownload?
        var purpose: PhoneDownloadPurpose?
        var directory: URL?
        var access: ReceiveDirectoryAccess?
        let record = offer.resume ? journals.read(id) : nil
        if let requestID = offer.downloadRequestId {
            if let waiting = expected[requestID], waiting.phoneID == phoneID {
                guard !waiting.cancelled else { return reject(id, code: FolderCode.declined, phoneID: phoneID) }
                download = waiting
                purpose = waiting.purpose
            } else if let record, record.header.downloadRequestId == requestID, record.header.peerID == phoneID {
                purpose = ReceiveLabels.purpose(record.header.purpose)
            } else {
                return reject(id, code: FolderCode.policy, phoneID: phoneID)
            }
            guard offer.isInto else { return reject(id, code: FolderCode.invalidMessage, phoneID: phoneID) }
            if purpose == .save || purpose == nil {
                access = host.receiveDirectoryAccess()
                directory = access?.url
            } else {
                directory = download?.directory ?? record.map { URL(fileURLWithPath: $0.header.directoryPath, isDirectory: true) }
            }
        } else {
            // An `into` offer only ever answers a download this Mac asked for.
            guard !offer.isInto else { return reject(id, code: FolderCode.policy, phoneID: phoneID) }
            if host.folderReceiveMode == .fixed || offer.resume {
                access = host.receiveDirectoryAccess()
                directory = access?.url
            }
        }
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let phone = host.phoneName(phoneID)
        let plan = ReceivePlan(
            directory: directory,
            destinationLabel: directory.map(ReceiveLabels.label(for:)) ?? "",
            policy: host.folderConflictPolicy,
            downloadRequestId: offer.downloadRequestId,
            purpose: purpose,
            whereFrom: purpose == .preview ? nil : FinderMetadata.whereFrom(phoneName: phone),
            displayName: offer.rootName
        )
        let item = Item(id: id, phoneID: phoneID, purpose: purpose, rootName: offer.rootName, startedAt: items[id]?.startedAt ?? Date(),
                        skipped: offer.skipped ?? SkippedCounts())
        item.download = download
        item.access = access
        item.progress.filesTotal = offer.fileCount
        item.progress.bytesTotal = offer.totalSize
        let queue = DispatchQueue(label: "in.roundrobin.bridgey.folder-receive", qos: .userInitiated)
        let relay = FolderReceiveRelay(owner: self, id: id)
        let session = FolderReceiveSession(offer: offer, peerID: phoneID, peerName: phone, plan: plan, transport: wire.transport,
                                           clock: makeClock(queue), journals: journals, events: relay) { line in
            BridgeyLog.plugin.notice("folder receive \(String(id.prefix(8)), privacy: .public) \(line, privacy: .public)")
        }
        relay.session = session
        item.session = session
        item.relay = relay
        item.queue = queue
        items[id] = item
        publish(item)
        queue.async { session.start() }
    }

    /// The offer's own checks (4.5): IDs, names, counts and limits. Nil when it may go on to its manifest.
    static func problem(_ offer: FolderOfferPayload) -> String? {
        guard offer.version == 1 else { return FolderCode.unsupported }
        guard PortableName.isPortable(offer.rootName) else { return FolderCode.invalidManifest }
        guard offer.fileCount >= 0, offer.folderCount >= 0, offer.totalSize >= 0, offer.pageCount >= 0,
              Data(base64Encoded: offer.manifestSha256)?.count == 32 else { return FolderCode.invalidMessage }
        if (offer.fileCount + offer.folderCount == 0) != (offer.pageCount == 0) { return FolderCode.invalidManifest }
        if offer.fileCount > FolderLimits.maxFiles || offer.folderCount > FolderLimits.maxFolders || offer.totalSize > FolderLimits.maxTotalSize ||
            offer.pageCount > FolderLimits.maxPages { return FolderCode.limitExceeded }
        if offer.fileCount + offer.folderCount > offer.pageCount * FolderLimits.maxEntriesPerPage || offer.fileCount + offer.folderCount < offer.pageCount {
            return FolderCode.invalidManifest
        }
        if let requestID = offer.downloadRequestId, !FolderJSON.isWireID(requestID) { return FolderCode.invalidMessage }
        return nil
    }

    /// files.offer inside a folder coming here. False when it is not one (no folderTransferId).
    func fileOffer(_ payload: Data, from phoneID: String) -> Bool {
        guard let offer = try? JSONDecoder().decode(FolderFileOfferPayload.self, from: payload) else { return false }
        guard let item = items[offer.folderTransferId], item.phoneID == phoneID, FolderJSON.isWireID(offer.transferId) else { return false }
        fileOwners[offer.transferId] = item.id
        onSession(item) { $0.fileOffer(offer) }
        return true
    }

    func chunk(_ transferID: String, sequence: Int64, data: Data, from phoneID: String) -> Bool {
        if endedFileSet.contains(transferID) { return true }
        guard let folderID = fileOwners[transferID] else { return false }
        guard let item = items[folderID], item.phoneID == phoneID else { return true }
        onSession(item) { $0.chunk(transferID, sequence: sequence, data: data) }
        return true
    }

    func fileComplete(_ transferID: String, sha256: String, from phoneID: String) -> Bool {
        if endedFileSet.contains(transferID) { return true }
        guard let folderID = fileOwners[transferID] else { return false }
        guard let item = items[folderID], item.phoneID == phoneID else { return true }
        onSession(item) { $0.fileComplete(transferID, sha256: sha256) }
        return true
    }

    func fileCancelled(_ transferID: String, from phoneID: String) -> Bool {
        if endedFileSet.contains(transferID) { return true }
        guard let folderID = fileOwners[transferID] else { return false }
        guard let item = items[folderID], item.phoneID == phoneID else { return true }
        onSession(item) { $0.fileCancelled(transferID) }
        return true
    }

    private func onSession(_ item: Item, _ body: @escaping (FolderReceiveSession) -> Void) {
        guard let session = item.session, let queue = item.queue else { return }
        queue.async { body(session) }
    }

    // MARK: Connections and row actions

    func phoneDisconnected(_ phoneID: String) {
        for item in items.values where item.phoneID == phoneID && item.session != nil { onSession(item) { $0.interrupt() } }
    }

    func forget(_ phoneID: String) {
        phoneDisconnected(phoneID)
        journals.deleteAll(peerID: phoneID)
        for item in Array(items.values) where item.phoneID == phoneID {
            items.removeValue(forKey: item.id)
            host?.folderRowRemoved(item.id)
        }
        for (key, download) in expected where download.phoneID == phoneID {
            expected.removeValue(forKey: key)
            download.finish(.failure(.notConnected))
        }
    }

    func cancel(_ id: String) {
        guard let item = items[id] else { return }
        if item.session != nil {
            onSession(item) { $0.cancelHere() }
        } else if item.state == .interrupted {
            journals.delete(id)
            item.resumable = false
            end(item, state: .incomplete, text: L10n.text("folders.end.cancelled", fallback: "Cancelled"))
        }
    }

    func cancelAll() {
        for item in items.values where item.active { cancel(item.id) }
    }

    func clearFinished() {
        for item in Array(items.values) where item.state == .done || (item.state == .incomplete && !item.resumable) {
            items.removeValue(forKey: item.id)
        }
    }

    // MARK: Session events (main thread)

    fileprivate func sessionProgress(_ id: String, _ progress: ReceiveProgress, session: FolderReceiveSession) {
        guard let item = items[id], item.session === session else { return }
        item.progress = progress
        if let download = item.download, !download.isFinished {
            var update = PhoneTransferProgress(phase: progress.waiting == nil ? .transferring : .waiting)
            update.filesDone = progress.filesDone
            update.filesTotal = progress.filesTotal
            update.bytesDone = progress.bytesDone
            update.bytesTotal = progress.bytesTotal
            update.bytesPerSecond = Int64(progress.bytesPerSecond)
            download.progress(update)
        }
        publish(item)
    }

    fileprivate func sessionAsksDestination(_ id: String, deadline: Date, session: FolderReceiveSession) {
        guard let item = items[id], item.session === session, let host else { return }
        closePanel()
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = L10n.text("folders.receive.saveHere", fallback: "Save Here")
        open.message = String(format: L10n.text("folders.receive.choose", fallback: "Choose where to save \u{201C}%1$@\u{201D} from %2$@"),
                              item.displayName, host.phoneName(item.phoneID))
        open.directoryURL = host.receiveDirectoryAccess().url
        open.level = .floating
        panel = (id, open)
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard let self else { return }
            if self.panel?.panel === open { self.panel = nil }
            let url = response == .OK ? open.url : nil
            guard let item = self.items[id], item.session === session else { return }
            self.onSession(item) { $0.answerDestination(url) }
        }
    }

    fileprivate func sessionAsksConflict(_ id: String, _ asked: ReceiveConflictQuestion, session: FolderReceiveSession) {
        guard let item = items[id], item.session === session, let host else { return }
        question?.controller.dismiss()
        let payload = FolderConflictPayload(folderTransferId: id, existing: asked.existingIsFile ? "file" : "folder", clashingFiles: asked.clashingFiles,
                                            clashingFolders: nil, newFolderName: asked.newFolderName, choices: asked.choices,
                                            timeoutSeconds: FolderTimeouts.questionSeconds)
        let state = FolderConflictState(
            name: item.displayName, destination: asked.destinationLabel,
            message: FolderText.conflictMessage(payload, name: item.displayName, destination: asked.destinationLabel, totalFiles: item.progress.filesTotal),
            choices: asked.choices, newFolderName: asked.newFolderName, deadline: asked.deadline
        )
        let controller = FolderConflictWindowController(state: state, reduceMotion: host.folderReduceMotion) { [weak self] choice in
            guard let self, let item = self.items[id], item.session === session else { return }
            self.question = nil
            self.onSession(item) { $0.answerConflict(choice) }
        }
        question = (id, controller)
        controller.show()
    }

    fileprivate func sessionQuestionClosed(_ id: String) {
        if let question, question.id == id {
            self.question = nil
            question.controller.dismiss()
        }
        if panel?.id == id { closePanel() }
    }

    private func closePanel() {
        guard let open = panel?.panel else { return }
        panel = nil
        open.cancel(nil)
    }

    fileprivate func sessionFinished(_ id: String, _ outcome: ReceiveOutcome, progress: ReceiveProgress, session: FolderReceiveSession) {
        guard let item = items[id], item.session === session, let host else { return }
        item.session = nil
        item.relay = nil
        item.queue = nil
        item.progress = progress
        sessionQuestionClosed(id)
        for (transferID, folderID) in fileOwners where folderID == id {
            fileOwners.removeValue(forKey: transferID)
            endedFiles.append(transferID)
            endedFileSet.insert(transferID)
        }
        while endedFiles.count > 4_096 { endedFileSet.remove(endedFiles.removeFirst()) }
        let phone = host.phoneName(item.phoneID)
        let name = progress.rootName
        let label = progress.destinationLabel
        switch outcome {
        case .complete:
            item.access = nil
            if item.purpose != .preview { FinderMetadata.finish(progress.savedURLs, phoneName: phone, tag: host.tagsReceivedFiles) }
            let text = Self.savedText(name: name, destination: label)
            end(item, state: .done, text: text)
            if item.purpose != .preview {
                host.folderStatus(text)
                record(item, .folderReceived, outcome: .completed)
            }
            host.receivedItems(progress.savedURLs, phoneID: item.phoneID, purpose: item.purpose)
            finishDownload(item, .success(progress.savedURLs))
        case let .incomplete(code):
            item.access = nil
            if item.purpose != .preview, !progress.savedURLs.isEmpty {
                FinderMetadata.finish(progress.savedURLs, phoneName: phone, tag: host.tagsReceivedFiles)
            }
            end(item, state: .incomplete, text: FolderText.incomplete(progress: folderProgress(item)))
            if item.purpose != .preview { record(item, .folderIncomplete, outcome: code == FolderCode.cancelled ? .cancelled : .incomplete, end: code) }
            finishDownload(item, .failure(code == FolderCode.cancelled ? .cancelled : .code(code ?? "incomplete")))
        case let .cancelled(code):
            item.access = nil
            let text = code == FolderCode.declined || code == FolderCode.cancelled
                ? L10n.text("folders.end.cancelled", fallback: "Cancelled")
                : FolderText.rejection(code: code, phone: L10n.text("folders.receive.thisMac", fallback: "this Mac"), needed: nil, free: nil)
            end(item, state: .incomplete, text: text)
            finishDownload(item, .failure(code == FolderCode.cancelled || code == FolderCode.declined ? .cancelled : .code(code)))
        case .timedOut:
            item.access = nil
            end(item, state: .incomplete, text: L10n.text("folders.end.questionTimeout", fallback: "Cancelled: nobody answered on this Mac"))
            finishDownload(item, .failure(.code(FolderCode.timeout)))
        case let .interrupted(resumable):
            item.resumable = resumable
            if resumable {
                item.state = .interrupted
                item.endText = nil
                publish(item)
                if let download = item.download, !download.isFinished {
                    var update = PhoneTransferProgress(phase: .waiting)
                    update.filesDone = progress.filesDone
                    update.filesTotal = progress.filesTotal
                    update.bytesDone = progress.bytesDone
                    update.bytesTotal = progress.bytesTotal
                    download.progress(update)
                }
            } else {
                item.access = nil
                end(item, state: .incomplete, text: L10n.text("folders.end.lost", fallback: "Connection lost"))
                if item.purpose != .preview { record(item, .folderIncomplete, outcome: .incomplete, end: "lost") }
                finishDownload(item, .failure(.notConnected))
            }
        }
        onFinished?(id, outcome)
    }

    private func finishDownload(_ item: Item, _ result: Result<[URL], PhoneFilesError>) {
        guard let download = item.download else { return }
        expected.removeValue(forKey: download.requestId)
        download.finish(result)
    }

    static func savedText(name: String, destination: String?) -> String {
        guard let destination, !destination.isEmpty else {
            return String(format: L10n.text("folders.receive.done.noPlace", fallback: "%@ saved on this Mac"), name)
        }
        return String(format: L10n.text("folders.receive.done", fallback: "%1$@ saved in %2$@"), name, destination)
    }

    private func end(_ item: Item, state: FolderRowState, text: String?) {
        item.state = state
        item.endText = text
        publish(item)
    }

    private func record(_ item: Item, _ kind: ActivityKind, outcome: TransferHistoryEntry.Outcome, end: String? = nil) {
        guard let host else { return }
        var detail = FolderActivityDetail(links: item.skipped.links, hidden: item.skipped.hidden, system: item.skipped.system, end: end)
        detail.failed = item.progress.failedCount
        detail.kept = item.progress.renamedFiles
        detail.replaced = item.progress.replacedFiles
        if let choice = item.progress.choice, choice != .none { detail.choice = choice.rawValue }
        if item.progress.choice == .newFolder { detail.savedAs = item.progress.rootName }
        if kind == .folderIncomplete {
            detail.doneFiles = item.progress.filesDone
            detail.doneBytes = item.progress.bytesDone
        }
        let top = item.progress.savedURLs
        let singleFile = item.purpose != nil && top.count == 1 && item.progress.filesTotal == 1 && !(top.first?.hasDirectoryPath ?? false)
        host.recordFolderActivity(singleFile ? .fileReceived : kind, phoneID: item.phoneID, name: top.count == 1 ? top[0].lastPathComponent : item.progress.rootName,
                                  fileCount: item.progress.filesTotal, bytes: item.progress.bytesTotal, destination: item.progress.destinationLabel, detail: detail)
        host.recordHistory(TransferHistoryEntry(
            id: item.id, date: Date(), direction: .received, deviceID: item.phoneID, deviceName: host.phoneName(item.phoneID),
            name: top.count == 1 ? top[0].lastPathComponent : item.progress.rootName,
            isFolder: !singleFile, fileCount: item.progress.filesTotal,
            bytes: outcome == .completed ? item.progress.bytesTotal : item.progress.bytesDone, outcome: outcome,
            localPath: (top.count == 1 ? top.first : top.first?.deletingLastPathComponent())?.path,
            destination: item.progress.destinationLabel, download: item.purpose != nil
        ))
    }

    private func folderProgress(_ item: Item) -> FolderProgress {
        var progress = FolderProgress()
        let receive = item.progress
        switch receive.waiting {
        case let .destination(deadline), let .conflict(deadline): progress.phase = .asking(deadline: deadline)
        case .manifest: progress.phase = .offered
        case nil: progress.phase = item.active ? .sending : .finished
        }
        progress.filesDone = receive.filesDone
        progress.filesTotal = receive.filesTotal
        progress.bytesDone = receive.bytesDone
        progress.bytesTotal = receive.bytesTotal
        progress.bytesPerSecond = receive.bytesPerSecond
        progress.currentPath = receive.currentPath
        progress.currentBytes = receive.currentBytes
        progress.currentSize = receive.currentSize
        progress.failures = receive.failures
        progress.failedCount = receive.failedCount
        progress.rootName = receive.rootName
        progress.destinationLabel = receive.destinationLabel
        progress.choice = receive.choice
        return progress
    }

    private func publish(_ item: Item) {
        guard let host, item.purpose != .preview else { return }
        var summary = FolderRowSummary(phoneName: host.phoneName(item.phoneID), displayName: item.displayName)
        summary.incoming = true
        summary.destinationLabel = item.progress.destinationLabel
        summary.state = item.state
        summary.progress = folderProgress(item)
        summary.skipped = item.skipped
        summary.endText = item.endText
        summary.canResume = false
        summary.canSendAgain = false
        let top = item.progress.savedURLs
        host.folderRowChanged(FileTransferRow(
            id: item.id,
            name: top.count == 1 ? top[0].lastPathComponent : item.displayName,
            status: FolderText.status(summary, now: Date()),
            active: item.active,
            startedAt: item.startedAt,
            retryable: false,
            queued: false,
            folder: summary,
            localURL: top.count == 1 ? top[0] : top.first?.deletingLastPathComponent()
        ))
    }
}

/// Session events hop to the main thread, with the session they came from so stale ones are dropped.
private final class FolderReceiveRelay: FolderReceiveEvents, @unchecked Sendable {
    private weak var owner: FolderReceiver?
    private let id: String
    weak var session: FolderReceiveSession?

    init(owner: FolderReceiver, id: String) {
        self.owner = owner
        self.id = id
    }

    private func onMain(_ body: @escaping @MainActor (FolderReceiver, FolderReceiveSession) -> Void) {
        guard let session else { return }
        DispatchQueue.main.async { [weak owner] in
            guard let owner else { return }
            MainActor.assumeIsolated { body(owner, session) }
        }
    }

    func receiveProgress(_ progress: ReceiveProgress) { onMain { [id] in $0.sessionProgress(id, progress, session: $1) } }
    func receiveAsksDestination(deadline: Date) { onMain { [id] in $0.sessionAsksDestination(id, deadline: deadline, session: $1) } }
    func receiveAsksConflict(_ question: ReceiveConflictQuestion) { onMain { [id] in $0.sessionAsksConflict(id, question, session: $1) } }
    func receiveQuestionClosed() { onMain { [id] owner, _ in owner.sessionQuestionClosed(id) } }
    func receiveFinished(_ outcome: ReceiveOutcome, progress: ReceiveProgress) {
        onMain { [id] in $0.sessionFinished(id, outcome, progress: progress, session: $1) }
    }
}
