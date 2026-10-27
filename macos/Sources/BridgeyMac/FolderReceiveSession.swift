import CryptoKit
import Darwin
import Foundation

// Sections 4.4 to 4.7 and 7.4, receiving side on the Mac: one folder from the phone (pushed, or a download
// this Mac asked for). Port of android FolderReceiveSession.kt over FileManager. A state machine driven from
// one serial queue by its owner (FolderReceiver); it never touches the UI. Files are written as hidden
// ".name.bridgey-part" files and moved into place atomically after verification; a symbolic link in the
// destination is a clash and is never followed.

extension FolderTransport {
    /// files.chunk.ack carries the chunk's sequence outside; transports that can, override this.
    func sendOuter(kind: String, transferID: String, sequence: Int64?) {
        if let sequence, let sequenced = self as? SequencedFolderTransport {
            sequenced.sendOuterSequenced(kind: kind, transferID: transferID, sequence: sequence)
        } else {
            sendOuter(kind: kind, transferID: transferID)
        }
    }
}

/// A transport that can put a sequence on an outer-only message (files.chunk.ack).
protocol SequencedFolderTransport: FolderTransport {
    func sendOuterSequenced(kind: String, transferID: String, sequence: Int64)
}

/// Receiver side of the manifest (4.5): pages in order, validated against the offer. Port of ManifestAssembler.
struct ManifestAssembler {
    enum Result: Equatable {
        case needMore
        case complete([ManifestEntry])
        case rejected(code: String, entry: Int?)
    }

    private let offer: FolderOfferPayload
    private var entries: [ManifestEntry] = []
    private var directories = Set<String>()
    private var siblingKeys: [String: Set<String>] = [:]
    private var nextPage = 0
    private var bytes = 0
    private var files = 0
    private var folders = 0
    private var total: Int64 = 0
    private var finished: Result?

    init(offer: FolderOfferPayload) { self.offer = offer }

    var expectedEntries: Int { offer.fileCount + offer.folderCount }

    mutating func completeWithoutPages() -> Result? {
        guard offer.pageCount == 0 else { return nil }
        let result: Result = ManifestDigest.compute(rootName: offer.rootName, entries: []) == offer.manifestSha256
            ? .complete([]) : .rejected(code: FolderCode.invalidManifest, entry: nil)
        finished = result
        return result
    }

    mutating func add(_ page: ManifestPagePayload, pageBytes: Int) -> Result {
        if let finished { return finished }
        func reject(_ code: String = FolderCode.invalidManifest, _ entry: Int? = nil) -> Result {
            let result = Result.rejected(code: code, entry: entry)
            finished = result
            return result
        }
        guard page.folderTransferId == offer.folderTransferId, page.page == nextPage else { return reject() }
        bytes += pageBytes
        guard bytes <= FolderLimits.maxManifestBytes else { return reject(FolderCode.limitExceeded) }
        for entry in page.entries {
            let index = entries.count
            guard index < expectedEntries, FolderPaths.isValidManifestPath(entry.path) else { return reject(FolderCode.invalidManifest, index) }
            if let previous = entries.last, !FolderPaths.precedes(previous.path, entry.path) { return reject(FolderCode.invalidManifest, index) }
            let parent = FolderPaths.parent(entry.path)
            if !parent.isEmpty, !directories.contains(parent) { return reject(FolderCode.invalidManifest, index) }
            guard siblingKeys[parent, default: []].insert(caseKey(FolderPaths.leaf(entry.path))).inserted else { return reject(FolderCode.invalidManifest, index) }
            if entry.isDirectory {
                directories.insert(entry.path)
                folders += 1
                if folders > offer.folderCount { return reject(FolderCode.invalidManifest, index) }
            } else {
                files += 1
                guard files <= offer.fileCount, let size = entry.size, size >= 0, size <= FolderLimits.maxFileSize,
                      let hash = entry.sha256, Data(base64Encoded: hash)?.count == 32 else { return reject(FolderCode.invalidManifest, index) }
                total += size
                if total > offer.totalSize { return reject(FolderCode.invalidManifest, index) }
            }
            entries.append(entry)
        }
        nextPage += 1
        if nextPage < offer.pageCount { return .needMore }
        guard entries.count == expectedEntries, files == offer.fileCount, folders == offer.folderCount, total == offer.totalSize else {
            return reject(FolderCode.invalidManifest, entries.count < expectedEntries ? entries.count : nil)
        }
        guard ManifestDigest.compute(rootName: offer.rootName, entries: entries) == offer.manifestSha256 else { return reject() }
        let result = Result.complete(entries)
        finished = result
        return result
    }
}

extension FolderPaths {
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func leaf(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// What the owner decided before the session starts.
struct ReceivePlan {
    /// Where it lands; nil: ask on this Mac (a Save-location panel).
    var directory: URL?
    var destinationLabel: String
    var policy: MacFolderConflictPolicy
    /// A download this Mac asked for (lands without questions).
    var downloadRequestId: String?
    var purpose: PhoneDownloadPurpose?
    /// "Bridgey: OnePlus 11" for kMDItemWhereFroms; nil for previews.
    var whereFrom: String?
    var displayName: String
}

enum ReceiveOutcome: Equatable {
    case complete
    /// Ended after the accept with entries missing.
    case incomplete(code: String?)
    /// Nothing written: rejected, declined or cancelled before the accept.
    case cancelled(code: String)
    /// Nobody answered on this Mac within 3 minutes.
    case timedOut
    /// The connection dropped; resumable when the journal stays.
    case interrupted(resumable: Bool)
}

enum ReceiveWaiting: Equatable {
    case manifest
    case destination(deadline: Date)
    case conflict(deadline: Date)
}

struct ReceiveProgress: Equatable {
    var waiting: ReceiveWaiting? = .manifest
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Double = 0
    var currentPath: String?
    var currentBytes: Int64 = 0
    var currentSize: Int64 = 0
    var failedCount = 0
    var failures: [FolderFailure] = []
    var renamedFiles = 0
    var replacedFiles = 0
    var rootName: String
    var destinationLabel: String?
    var choice: ConflictChoice?
    /// The saved items on this Mac: the root folder, or for `into` the top-level items.
    var savedURLs: [URL] = []
}

struct ReceiveConflictQuestion: Equatable {
    let existingIsFile: Bool
    let clashingFiles: Int?
    let newFolderName: String
    let choices: [ConflictChoice]
    let destinationLabel: String
    let deadline: Date
}

protocol FolderReceiveEvents: AnyObject {
    func receiveProgress(_ progress: ReceiveProgress)
    func receiveAsksDestination(deadline: Date)
    func receiveAsksConflict(_ question: ReceiveConflictQuestion)
    func receiveQuestionClosed()
    func receiveFinished(_ outcome: ReceiveOutcome, progress: ReceiveProgress)
}

final class FolderReceiveSession: @unchecked Sendable {
    enum Phase: Equatable { case manifest, askDestination, askConflict, receiving, done }

    static let clashCountTime: TimeInterval = 3
    static let progressInterval: TimeInterval = 0.25
    static let recentLimit = 200
    static let partSuffix = ".bridgey-part"
    /// Files above this size are written to a part file; smaller ones too (an atomic move costs nothing here).
    static let spaceMargin: Int64 = 64 * 1024 * 1024

    let offer: FolderOfferPayload
    let peerID: String
    private(set) var peerName: String
    var id: String { offer.folderTransferId }
    private(set) var phase: Phase = .manifest
    var isActive: Bool { phase != .done }

    private let transport: FolderTransport
    private let clock: FolderClock
    private let journals: ReceiveJournalStore?
    private weak var events: FolderReceiveEvents?
    private var plan: ReceivePlan
    private let log: (String) -> Void

    private var assembler: ManifestAssembler
    private var entries: [ManifestEntry] = []

    // Destination.
    private var directory: URL?
    private var existingIsDirectory: Bool?
    private var existingName: String?
    private var newFolderName: String
    private var offeredChoices: [ConflictChoice] = []
    private var clashingFiles: Int?

    // Receiving.
    private var choice: ConflictChoice = .none
    private var rootName: String
    private var root: URL?
    private var topNames: [String: String] = [:]
    private var journal: ReceiveJournalStore.Writer?
    private var dirURLs: [String: URL] = [:]
    private var doneDirs = Set<Int>()
    private var failedDirs = Set<String>()
    private var nextDirScan = 0
    private var listings: [String: [String: Existing]] = [:]
    private var done = Set<Int>()
    private var dropped = Set<String>()
    private var lastEntry = -1
    private var current: Incoming?
    private var failures: [FolderFailure] = []
    private var failedCount = 0
    private var createdFolders = 0
    private var renamedFiles = 0
    private var replacedFiles = 0
    private var bytesDone: Int64 = 0

    // Timers and progress.
    private var timer: FolderTimer?
    private var deadline: Date?
    private var waiting: ReceiveWaiting? = .manifest
    private var lastEmit = Date.distantPast
    private var speedSample: (at: Date, bytes: Int64)?
    private var bytesPerSecond: Double = 0

    private struct Existing {
        let name: String
        let isDirectory: Bool
    }

    private final class Incoming {
        let transferID: String
        let index: Int
        let entry: ManifestEntry
        let parent: URL
        let partURL: URL
        let finalName: String
        let replaces: Bool
        let renamed: Bool
        let handle: FileHandle
        var hasher = SHA256()
        var received: Int64 = 0
        var nextSequence: Int64 = 0

        init(transferID: String, index: Int, entry: ManifestEntry, parent: URL, partURL: URL, finalName: String, replaces: Bool, renamed: Bool, handle: FileHandle) {
            self.transferID = transferID
            self.index = index
            self.entry = entry
            self.parent = parent
            self.partURL = partURL
            self.finalName = finalName
            self.replaces = replaces
            self.renamed = renamed
            self.handle = handle
        }
    }

    init(offer: FolderOfferPayload, peerID: String, peerName: String, plan: ReceivePlan, transport: FolderTransport, clock: FolderClock,
         journals: ReceiveJournalStore?, events: FolderReceiveEvents, log: @escaping (String) -> Void = { _ in }) {
        self.offer = offer
        self.peerID = peerID
        self.peerName = peerName
        self.plan = plan
        self.transport = transport
        self.clock = clock
        self.journals = journals
        self.events = events
        self.log = log
        assembler = ManifestAssembler(offer: offer)
        rootName = offer.rootName
        newFolderName = offer.rootName
    }

    // MARK: Events from the owner (all on the session's queue)

    func start() {
        log("offer resume=\(offer.resume) into=\(offer.isInto) files=\(offer.fileCount) folders=\(offer.folderCount) pages=\(offer.pageCount)")
        emit(force: true)
        var copy = assembler
        if let immediate = copy.completeWithoutPages() {
            assembler = copy
            return manifestResult(immediate)
        }
        startTimer(FolderTimeouts.firstAnswer) { [weak self] in self?.reject(FolderCode.timeout) }
    }

    func manifestPage(_ page: ManifestPagePayload, plaintextBytes: Int) {
        guard phase == .manifest else { return }
        let result = assembler.add(page, pageBytes: plaintextBytes)
        if result != .needMore { manifestResult(result) }
    }

    func fileOffer(_ offer: FolderFileOfferPayload) {
        guard phase != .done else { return }
        guard phase == .receiving else { return entryFailed(offer.entry, offer.transferId, FolderCode.invalidMessage) }
        if let previous = current { failCurrent(previous, FolderCode.invalidMessage) }
        guard phase == .receiving else { return }
        let index = offer.entry
        guard entries.indices.contains(index), !entries[index].isDirectory, index > lastEntry else {
            return entryFailed(index, offer.transferId, FolderCode.invalidMessage)
        }
        let entry = entries[index]
        guard offer.path == entry.path, offer.name == FolderPaths.leaf(entry.path), offer.size == entry.size, offer.sha256 == entry.sha256 else {
            return entryFailed(index, offer.transferId, FolderCode.invalidMessage)
        }
        lastEntry = index
        ensureDirs(upTo: index)
        guard phase == .receiving else { return }
        let parentPath = FolderPaths.parent(entry.path)
        guard let parent = parentURL(parentPath), !failedDirs.contains(parentPath) else { return entryFailed(index, offer.transferId, FolderCode.ioError) }
        do {
            var siblings = try listing(parent)
            let leaf = parentPath.isEmpty ? (topNames[entry.path] ?? FolderPaths.leaf(entry.path)) : FolderPaths.leaf(entry.path)
            var finalName = leaf
            var replaces = false
            var renamed = false
            if let clash = siblings[caseKey(leaf)] {
                if clash.isDirectory || choice != .replace || offer.isIntoTop(parentPath: parentPath, into: self.offer.isInto) {
                    finalName = ConflictNames.firstFree(leaf, isDirectory: false) { siblings[$0] != nil }
                    renamed = finalName != leaf
                } else {
                    finalName = clash.name
                    replaces = true
                }
            }
            let partName = ConflictNames.firstFree(".\(finalName)\(Self.partSuffix)", isDirectory: false) { siblings[$0] != nil }
            if !replaces { siblings[caseKey(finalName)] = Existing(name: finalName, isDirectory: false) }
            siblings[caseKey(partName)] = Existing(name: partName, isDirectory: false)
            listings[parent.path] = siblings
            let partURL = parent.appendingPathComponent(partName)
            let fd = open(partURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw CocoaError(errno == ENOSPC ? .fileWriteOutOfSpace : .fileWriteUnknown) }
            journal?.part(index, partURL)
            current = Incoming(transferID: offer.transferId, index: index, entry: entry, parent: parent, partURL: partURL, finalName: finalName,
                               replaces: replaces, renamed: renamed, handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
        } catch {
            return storageFailure(index, offer.transferId, error)
        }
        transport.sendOuter(kind: "files.accept", transferID: offer.transferId)
        emit(force: true)
    }

    func chunk(_ transferID: String, sequence: Int64, data: Data) {
        guard !dropped.contains(transferID), phase == .receiving, let incoming = current, incoming.transferID == transferID else { return }
        guard sequence == incoming.nextSequence, incoming.received + Int64(data.count) <= incoming.entry.size ?? 0 else {
            return failCurrent(incoming, FolderCode.invalidMessage)
        }
        do {
            try incoming.handle.write(contentsOf: data)
        } catch {
            return failCurrent(incoming, Self.code(of: error))
        }
        incoming.hasher.update(data: data)
        incoming.received += Int64(data.count)
        incoming.nextSequence += 1
        bytesDone += Int64(data.count)
        transport.sendOuter(kind: "files.chunk.ack", transferID: transferID, sequence: sequence)
        emit()
    }

    func fileComplete(_ transferID: String, sha256: String) {
        guard !dropped.contains(transferID), phase == .receiving, let incoming = current, incoming.transferID == transferID else { return }
        do {
            try incoming.handle.synchronize()
            try incoming.handle.close()
        } catch {
            return failCurrent(incoming, Self.code(of: error), closed: true)
        }
        let actual = Data(incoming.hasher.finalize()).base64EncodedString()
        let expected = incoming.entry.sha256
        guard incoming.received == incoming.entry.size, sha256 == expected, actual == expected else {
            return failCurrent(incoming, FolderCode.verificationFailed, closed: true)
        }
        let target = incoming.parent.appendingPathComponent(incoming.finalName)
        // Replace swaps atomically over the old file, only now that the new one is verified; everything else
        // refuses to overwrite.
        let moved = incoming.replaces
            ? rename(incoming.partURL.path, target.path) == 0
            : renamex_np(incoming.partURL.path, target.path, UInt32(RENAME_EXCL)) == 0
        guard moved else { return failCurrent(incoming, errno == ENOSPC ? FolderCode.insufficientSpace : FolderCode.ioError, closed: true) }
        if var siblings = listings[incoming.parent.path] {
            siblings.removeValue(forKey: caseKey(incoming.partURL.lastPathComponent))
            listings[incoming.parent.path] = siblings
        }
        if let modified = incoming.entry.modified {
            try? FileManager.default.setAttributes([.modificationDate: BrowseTime.date(modified)], ofItemAtPath: target.path)
        }
        if let whereFrom = plan.whereFrom { FinderMetadata.setWhereFrom(target, whereFrom) }
        journal?.done(incoming.index)
        current = nil
        done.insert(incoming.index)
        if incoming.replaces { replacedFiles += 1 }
        if incoming.renamed { renamedFiles += 1 }
        transport.sendOuter(kind: "files.complete.ack", transferID: transferID)
        emit(force: done.count == offer.fileCount)
    }

    func fileCancelled(_ transferID: String) {
        if let incoming = current, incoming.transferID == transferID {
            discard(incoming, closed: false)
            current = nil
        }
        dropped.insert(transferID)
        transport.sendOuter(kind: "files.cancel.ack", transferID: transferID)
        emit(force: true)
    }

    func folderComplete(_ payload: FolderCompletePayload) {
        guard phase == .receiving else { return }
        if let incoming = current { failCurrent(incoming, FolderCode.invalidMessage) }
        guard phase == .receiving else { return }
        ensureDirs(upTo: entries.count)
        guard phase == .receiving else { return }
        let files = entries.indices.filter { !entries[$0].isDirectory }
        let dirs = entries.indices.filter { entries[$0].isDirectory }
        let complete = files.allSatisfy(done.contains) && dirs.allSatisfy(doneDirs.contains)
        failedCount += payload.failedCount
        let failed = Array((failures.map { FailedEntry(entry: $0.entry, code: $0.code) } + payload.failed).prefix(FolderLimits.maxReportedFailures))
        let result = FolderResultPayload(
            folderTransferId: id, status: complete ? "complete" : "incomplete", savedFiles: done.count,
            savedBytes: done.reduce(Int64(0)) { $0 + (entries[$1].size ?? 0) }, createdFolders: createdFolders,
            renamedFiles: renamedFiles, replacedFiles: replacedFiles, failedCount: failedCount, failed: failed
        )
        send(FolderKind.result, result)
        dropJournal()
        log("result complete=\(complete) saved=\(done.count) failed=\(failedCount) renamed=\(renamedFiles) replaced=\(replacedFiles)")
        finish(complete ? .complete : .incomplete(code: nil))
    }

    func cancelledBySender(_ payload: FolderCancelPayload) {
        if phase == .done {
            transport.sendOuter(kind: FolderKind.cancelAck, transferID: id)
            return
        }
        let accepted = root != nil
        abandonCurrent()
        dropJournal()
        transport.sendOuter(kind: FolderKind.cancelAck, transferID: id)
        log("cancelled by sender reason=\(payload.reason)")
        finish(accepted ? .incomplete(code: payload.code ?? FolderCode.cancelled) : .cancelled(code: payload.code ?? FolderCode.cancelled))
    }

    /// The answer to the Save-location panel: a folder, or nil (Cancel).
    func answerDestination(_ url: URL?) {
        guard phase == .askDestination else { return }
        cancelTimer()
        events?.receiveQuestionClosed()
        guard let url else { return cancel(reason: FolderCancelPayload.user, code: FolderCode.declined, outcome: .cancelled(code: FolderCode.declined)) }
        plan.destinationLabel = ReceiveLabels.label(for: url)
        prepare(url)
    }

    func answerConflict(_ answer: ConflictChoice) {
        guard phase == .askConflict, answer == .cancel || offeredChoices.contains(answer) else { return }
        cancelTimer()
        events?.receiveQuestionClosed()
        if answer == .cancel {
            cancel(reason: FolderCancelPayload.user, code: FolderCode.declined, outcome: .cancelled(code: FolderCode.declined))
        } else {
            accept(answer)
        }
    }

    /// Cancel on this Mac (the row, Cancel All, or a cancelled download).
    func cancelHere() {
        guard phase != .done else { return }
        let asking = phase == .askDestination || phase == .askConflict
        cancel(reason: FolderCancelPayload.user, code: asking ? FolderCode.declined : nil,
               outcome: root != nil ? .incomplete(code: FolderCode.cancelled) : .cancelled(code: FolderCode.cancelled))
    }

    /// A folder message that decrypted but is invalid.
    func invalidMessage() {
        switch phase {
        case .done: return
        case .manifest: reject(FolderCode.invalidMessage)
        default:
            cancel(reason: FolderCancelPayload.error, code: FolderCode.invalidMessage,
                   outcome: root != nil ? .incomplete(code: FolderCode.invalidMessage) : .cancelled(code: FolderCode.invalidMessage))
        }
    }

    /// The phone disconnected.
    func interrupt() {
        guard phase != .done else { return }
        abandonCurrent()
        let resumable = root != nil && journal != nil
        journal?.close()
        journal = nil
        log("interrupted resumable=\(resumable)")
        finish(.interrupted(resumable: resumable))
    }

    func owns(_ transferID: String) -> Bool { current?.transferID == transferID || dropped.contains(transferID) }

    // MARK: Manifest and destination

    private func manifestResult(_ result: ManifestAssembler.Result) {
        switch result {
        case let .rejected(code, entry):
            reject(code, entry: entry)
        case let .complete(list):
            cancelTimer()
            entries = list
            if offer.resume { resume() } else if let directory = plan.directory { prepare(directory) } else { askDestination() }
        case .needMore:
            break
        }
    }

    private func askDestination() {
        phase = .askDestination
        let due = clock.now.addingTimeInterval(TimeInterval(FolderTimeouts.questionSeconds))
        deadline = due
        waiting = .destination(deadline: due)
        send(FolderKind.waiting, FolderWaitingPayload(folderTransferId: id, reason: FolderWaitingPayload.destination, timeoutSeconds: FolderTimeouts.questionSeconds))
        startTimer(TimeInterval(FolderTimeouts.questionSeconds)) { [weak self] in self?.timeOut() }
        events?.receiveAsksDestination(deadline: due)
        log("waiting reason=destination")
        emit(force: true)
    }

    /// Free space, the existence check and the clash count, then the conflict decision (3.3).
    private func prepare(_ target: URL) {
        directory = target
        var info = stat()
        guard lstat(target.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return reject(FolderCode.placeUnavailable) }
        if let free = Self.freeBytes(target) {
            let needed = offer.totalSize + Self.spaceMargin
            if free < needed { return reject(FolderCode.insufficientSpace, neededBytes: needed, freeBytes: free) }
        }
        let siblings: [String: Existing]
        do {
            siblings = try listing(target)
        } catch {
            return reject(FolderCode.placeUnavailable)
        }
        if offer.isInto {
            // Uploads and downloads never merge or overwrite: a clashing top-level item becomes a copy.
            var taken = Set(siblings.keys)
            for entry in entries where !entry.path.contains("/") {
                let name = ConflictNames.firstFree(entry.path, isDirectory: entry.isDirectory) { taken.contains($0) }
                taken.insert(caseKey(name))
                if name != entry.path { topNames[entry.path] = name }
            }
            return accept(.none)
        }
        let hit = siblings[caseKey(offer.rootName)]
        existingName = hit?.name
        existingIsDirectory = hit?.isDirectory
        newFolderName = ConflictNames.firstFree(offer.rootName, isDirectory: true) { siblings[$0] != nil }
        guard let hit else { return accept(.none) }
        clashingFiles = hit.isDirectory ? countClashes(in: target.appendingPathComponent(hit.name)) : nil
        let choices: [ConflictChoice] = hit.isDirectory ? [.merge, .replace, .newFolder] : [.newFolder]
        switch plan.policy {
        case .ask:
            offeredChoices = choices
            askConflict()
        case .merge: accept(hit.isDirectory ? .merge : .newFolder)
        case .replace: accept(hit.isDirectory ? .replace : .newFolder)
        case .newFolder: accept(.newFolder)
        }
    }

    /// "12 of 124 files have the same names", or nil when counting takes longer than 3 seconds.
    private func countClashes(in existingRoot: URL) -> Int? {
        let limit = Date().addingTimeInterval(Self.clashCountTime)
        var dirs: [String: URL] = ["": existingRoot]
        var files = 0
        for entry in entries {
            if Date() > limit { return nil }
            guard let parent = dirs[FolderPaths.parent(entry.path)], let siblings = try? listing(parent),
                  let hit = siblings[caseKey(FolderPaths.leaf(entry.path))] else { continue }
            if entry.isDirectory {
                if hit.isDirectory { dirs[entry.path] = parent.appendingPathComponent(hit.name) }
            } else {
                files += 1
            }
        }
        return Date() > limit ? nil : files
    }

    private func askConflict() {
        phase = .askConflict
        let due = clock.now.addingTimeInterval(TimeInterval(FolderTimeouts.questionSeconds))
        deadline = due
        waiting = .conflict(deadline: due)
        send(FolderKind.waiting, FolderWaitingPayload(folderTransferId: id, reason: FolderWaitingPayload.conflict, timeoutSeconds: FolderTimeouts.questionSeconds))
        startTimer(TimeInterval(FolderTimeouts.questionSeconds)) { [weak self] in self?.timeOut() }
        events?.receiveAsksConflict(ReceiveConflictQuestion(existingIsFile: existingIsDirectory == false, clashingFiles: clashingFiles,
                                                            newFolderName: newFolderName, choices: offeredChoices,
                                                            destinationLabel: plan.destinationLabel, deadline: due))
        log("waiting reason=conflict clashes=\(clashingFiles ?? -1)")
        emit(force: true)
    }

    private func accept(_ requested: ConflictChoice) {
        guard let directory else { return reject(FolderCode.placeUnavailable) }
        let existingDir = existingIsDirectory == true ? existingName : nil
        choice = (requested == .merge || requested == .replace) && existingDir == nil ? (existingName != nil ? .newFolder : .none) : requested
        if offer.isInto {
            choice = .none
            root = directory
            rootName = offer.rootName
        } else {
            switch choice {
            case .merge, .replace:
                rootName = existingDir!
                root = directory.appendingPathComponent(rootName, isDirectory: true)
            default:
                var siblings = (try? listing(directory)) ?? [:]
                rootName = ConflictNames.firstFree(offer.rootName, isDirectory: true) { siblings[$0] != nil }
                let created = directory.appendingPathComponent(rootName, isDirectory: true)
                guard mkdir(created.path, 0o755) == 0 else { return reject(errno == ENOSPC ? FolderCode.insufficientSpace : FolderCode.placeUnavailable) }
                siblings[caseKey(rootName)] = Existing(name: rootName, isDirectory: true)
                listings[directory.path] = siblings
                listings[created.path] = [:]
                root = created
                if let whereFrom = plan.whereFrom { FinderMetadata.setWhereFrom(created, whereFrom) }
            }
        }
        dirURLs[""] = root
        journal = journals?.create(ReceiveJournalHeader(
            folderTransferId: id, peerID: peerID, peerName: peerName, manifestSha256: offer.manifestSha256, createdAt: clock.now,
            directoryPath: directory.path, rootPath: root!.path, rootName: rootName, choice: choice, into: offer.isInto,
            downloadRequestId: plan.downloadRequestId, purpose: plan.purpose.map(ReceiveLabels.purposeName), destinationLabel: plan.destinationLabel,
            topNames: topNames, fileCount: offer.fileCount, totalSize: offer.totalSize, displayName: plan.displayName
        ))
        beginReceiving(bitmap: nil)
    }

    private func beginReceiving(bitmap: String?) {
        phase = .receiving
        waiting = nil
        deadline = nil
        cancelTimer()
        send(FolderKind.accept, FolderAcceptPayload(folderTransferId: id, rootName: rootName,
                                                    destinationLabel: String(plan.destinationLabel.prefix(128)), choice: choice, completedBitmap: bitmap))
        log("accepted choice=\(choice.rawValue) resume=\(bitmap != nil)")
        emit(force: true)
    }

    // MARK: Resume (4.7)

    private func resume() {
        guard let journals, let record = journals.read(id), record.header.peerID == peerID,
              record.header.manifestSha256 == offer.manifestSha256, record.header.into == offer.isInto, record.canResume(now: clock.now) else {
            return reject(FolderCode.resumeUnavailable)
        }
        let header = record.header
        var info = stat()
        guard lstat(header.rootPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return reject(FolderCode.resumeUnavailable) }
        journals.cleanParts(record)
        directory = URL(fileURLWithPath: header.directoryPath, isDirectory: true)
        root = URL(fileURLWithPath: header.rootPath, isDirectory: true)
        rootName = header.rootName
        choice = header.choice
        topNames = header.topNames
        plan.destinationLabel = header.destinationLabel
        dirURLs[""] = root
        for (index, path) in record.dirs where entries.indices.contains(index) && entries[index].isDirectory {
            var dirInfo = stat()
            guard lstat(path, &dirInfo) == 0, (dirInfo.st_mode & S_IFMT) == S_IFDIR else { continue }
            dirURLs[entries[index].path] = URL(fileURLWithPath: path, isDirectory: true)
            doneDirs.insert(index)
        }
        for index in record.done where entries.indices.contains(index) && !entries[index].isDirectory {
            done.insert(index)
            bytesDone += entries[index].size ?? 0
        }
        journal = journals.reopen(id)
        beginReceiving(bitmap: CompletedBitmap.encode(size: entries.count) { done.contains($0) || doneDirs.contains($0) })
    }

    // MARK: Folders inside (4.6)

    private func parentURL(_ parentPath: String) -> URL? { dirURLs[parentPath] }

    /// Before file entry k, every folder entry below k exists.
    private func ensureDirs(upTo limit: Int) {
        while nextDirScan < limit, phase == .receiving {
            let index = nextDirScan
            nextDirScan += 1
            let entry = entries[index]
            guard entry.isDirectory, !doneDirs.contains(index) else { continue }
            let parentPath = FolderPaths.parent(entry.path)
            guard let parent = dirURLs[parentPath], !failedDirs.contains(parentPath) else {
                failedDirs.insert(entry.path)
                recordFailure(index, FolderCode.ioError)
                continue
            }
            do {
                var siblings = try listing(parent)
                let leaf = parentPath.isEmpty ? (topNames[entry.path] ?? FolderPaths.leaf(entry.path)) : FolderPaths.leaf(entry.path)
                let url: URL
                if let clash = siblings[caseKey(leaf)], clash.isDirectory, !(offer.isInto && parentPath.isEmpty) {
                    url = parent.appendingPathComponent(clash.name, isDirectory: true)
                } else {
                    // A file (or link) of that name: keep both, renaming the incoming folder.
                    let name = siblings[caseKey(leaf)] == nil ? leaf : ConflictNames.firstFree(leaf, isDirectory: true) { siblings[$0] != nil }
                    url = parent.appendingPathComponent(name, isDirectory: true)
                    guard mkdir(url.path, 0o755) == 0 else { throw CocoaError(errno == ENOSPC ? .fileWriteOutOfSpace : .fileWriteUnknown) }
                    siblings[caseKey(name)] = Existing(name: name, isDirectory: true)
                    listings[parent.path] = siblings
                    listings[url.path] = [:]
                    createdFolders += 1
                    if let whereFrom = plan.whereFrom, parentPath.isEmpty, offer.isInto { FinderMetadata.setWhereFrom(url, whereFrom) }
                }
                dirURLs[entry.path] = url
                doneDirs.insert(index)
                journal?.dir(index, url)
            } catch {
                let code = Self.code(of: error)
                if code == FolderCode.insufficientSpace { return stopFolder(code) }
                failedDirs.insert(entry.path)
                recordFailure(index, code)
            }
        }
    }

    // MARK: Failures

    private func storageFailure(_ index: Int, _ transferID: String, _ error: Error) {
        let code = Self.code(of: error)
        if code == FolderCode.ioError { entryFailed(index, transferID, code) } else { stopFolder(code) }
    }

    private func failCurrent(_ incoming: Incoming, _ code: String, closed: Bool = false) {
        current = nil
        discard(incoming, closed: closed)
        if code == FolderCode.placeUnavailable || code == FolderCode.insufficientSpace {
            dropped.insert(incoming.transferID)
            return stopFolder(code)
        }
        entryFailed(incoming.index, incoming.transferID, code)
    }

    /// Deletes a file that did not finish; the cut-off file restarts on resume.
    private func discard(_ incoming: Incoming, closed: Bool) {
        if !closed { try? incoming.handle.close() }
        unlink(incoming.partURL.path)
        if var siblings = listings[incoming.parent.path] {
            siblings.removeValue(forKey: caseKey(incoming.partURL.lastPathComponent))
            if !incoming.replaces { siblings.removeValue(forKey: caseKey(incoming.finalName)) }
            listings[incoming.parent.path] = siblings
        }
        journal?.abandoned(incoming.index)
        bytesDone -= incoming.received
    }

    private func entryFailed(_ index: Int, _ transferID: String, _ code: String) {
        dropped.insert(transferID)
        send(FolderKind.entryFailed, FolderEntryFailedPayload(folderTransferId: id, entry: index, transferId: transferID, code: code))
        recordFailure(index, code)
    }

    private func recordFailure(_ index: Int, _ code: String) {
        failedCount += 1
        if failures.count < FolderLimits.maxReportedFailures {
            failures.append(FolderFailure(entry: index, path: entries.indices.contains(index) ? entries[index].path : "", code: code))
        }
        log("entry failed code=\(code) failures=\(failedCount)")
        if failedCount >= FolderLimits.maxFailuresBeforeCancel, phase == .receiving {
            cancel(reason: FolderCancelPayload.error, code: FolderCode.tooManyFailures, outcome: .incomplete(code: FolderCode.tooManyFailures))
        } else {
            emit(force: true)
        }
    }

    private func stopFolder(_ code: String) {
        cancel(reason: FolderCancelPayload.error, code: code, outcome: .incomplete(code: code))
    }

    private func timeOut() {
        guard phase == .askDestination || phase == .askConflict else { return }
        events?.receiveQuestionClosed()
        cancel(reason: FolderCancelPayload.timeout, code: FolderCode.timeout, outcome: .timedOut)
    }

    private func abandonCurrent() {
        guard let incoming = current else { return }
        dropped.insert(incoming.transferID)
        discard(incoming, closed: false)
        current = nil
    }

    /// folders.cancel to the phone, then the end. Completed files stay; the file in progress is deleted.
    private func cancel(reason: String, code: String?, outcome: ReceiveOutcome) {
        abandonCurrent()
        send(FolderKind.cancel, FolderCancelPayload(folderTransferId: id, reason: reason, code: code), outer: true)
        dropJournal()
        log("cancelled reason=\(reason) code=\(code ?? "none")")
        finish(outcome)
    }

    /// folders.rejected before anything was written.
    private func reject(_ code: String, entry: Int? = nil, neededBytes: Int64? = nil, freeBytes: Int64? = nil) {
        guard phase != .done else { return }
        send(FolderKind.rejected, FolderRejectedPayload(folderTransferId: id, code: code, entry: entry, neededBytes: neededBytes, freeBytes: freeBytes), outer: true)
        log("rejected code=\(code)")
        finish(.cancelled(code: code))
    }

    private func dropJournal() {
        journal?.close()
        journal = nil
        journals?.delete(id)
    }

    private func finish(_ outcome: ReceiveOutcome) {
        phase = .done
        cancelTimer()
        waiting = nil
        deadline = nil
        events?.receiveFinished(outcome, progress: snapshot())
    }

    // MARK: Helpers

    private func send<P: Encodable>(_ kind: String, _ payload: P, outer: Bool = false) {
        guard let data = try? FolderJSON.encoder.encode(payload) else { return }
        transport.send(kind: kind, payload: data, transferID: outer ? id : nil, sequence: nil)
    }

    private func startTimer(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
        timer?.cancel()
        timer = clock.schedule(after: seconds) { [weak self] in
            guard let self, self.phase != .done else { return }
            action()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// The children of a folder by case key. Symbolic links count as files: never followed, always a clash.
    private func listing(_ url: URL) throws -> [String: Existing] {
        if let cached = listings[url.path] { return cached }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        var result: [String: Existing] = [:]
        for name in names {
            var info = stat()
            let isDirectory = lstat(url.appendingPathComponent(name).path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            result[caseKey(name)] = Existing(name: name, isDirectory: isDirectory)
        }
        listings[url.path] = result
        return result
    }

    static func freeBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func code(of error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue { return FolderCode.insufficientSpace }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return FolderCode.insufficientSpace }
        if nsError.domain == NSCocoaErrorDomain, [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(nsError.code) {
            return FolderCode.placeUnavailable
        }
        return FolderCode.ioError
    }

    private func snapshot() -> ReceiveProgress {
        var progress = ReceiveProgress(rootName: rootName)
        progress.waiting = waiting
        progress.filesDone = done.count
        progress.filesTotal = offer.fileCount
        progress.bytesDone = max(0, bytesDone)
        progress.bytesTotal = offer.totalSize
        progress.bytesPerSecond = bytesPerSecond
        progress.currentPath = current?.entry.path
        progress.currentBytes = current?.received ?? 0
        progress.currentSize = current?.entry.size ?? 0
        progress.failedCount = failedCount
        progress.failures = Array(failures.suffix(50))
        progress.renamedFiles = renamedFiles
        progress.replacedFiles = replacedFiles
        progress.destinationLabel = root != nil || phase == .askConflict ? plan.destinationLabel : nil
        progress.choice = root != nil ? choice : nil
        if let root {
            if offer.isInto {
                progress.savedURLs = entries.filter { !$0.path.contains("/") }.map { entry in
                    root.appendingPathComponent(topNames[entry.path] ?? entry.path, isDirectory: entry.isDirectory)
                }
            } else {
                progress.savedURLs = [root]
            }
        }
        return progress
    }

    private func emit(force: Bool = false) {
        let now = clock.now
        guard force || now.timeIntervalSince(lastEmit) >= Self.progressInterval else { return }
        if let sample = speedSample {
            let elapsed = now.timeIntervalSince(sample.at)
            if elapsed >= Self.progressInterval {
                let rate = Double(max(0, bytesDone - sample.bytes)) / elapsed
                bytesPerSecond = bytesPerSecond == 0 ? rate : bytesPerSecond * 0.7 + rate * 0.3
                speedSample = (now, bytesDone)
            }
        } else {
            speedSample = (now, bytesDone)
        }
        lastEmit = now
        events?.receiveProgress(snapshot())
    }
}

private extension FolderFileOfferPayload {
    /// Under `into`, a top-level file never replaces: it is a copy when it clashes.
    func isIntoTop(parentPath: String, into: Bool) -> Bool { into && parentPath.isEmpty }
}

enum ReceiveLabels {
    /// "Downloads/Bridgey": the folder's path under the home folder, else its full path; at most 128 characters.
    static func label(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        return String((relative.isEmpty ? url.lastPathComponent : relative).suffix(128))
    }

    static func purposeName(_ purpose: PhoneDownloadPurpose) -> String {
        switch purpose {
        case .save: return "save"
        case .dragOut: return "dragOut"
        case .preview: return "preview"
        }
    }

    static func purpose(_ name: String?) -> PhoneDownloadPurpose? {
        switch name {
        case "save": return .save
        case "dragOut": return .dragOut
        case "preview": return .preview
        default: return nil
        }
    }
}
