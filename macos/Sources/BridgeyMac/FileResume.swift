import CryptoKit
import Darwin
import Foundation

// Resuming a file from its last verified chunk (draft files_resume_draft1; docs/file-resume.md, docs/protocol.md
// "Resuming files"). A retry of an interrupted single file is offered `resumable`; a receiver that kept a verified
// partial of that content from that device answers files.resume with its verified length and the SHA-256 of those
// bytes; the sender checks the hash against its own file and answers files.resume.ack with that offset, or 0. The
// session client (rust/client/src/resume.rs) is the reference and Android has the same rules in FileResume.kt.
// Checked against protocol/test-vectors/files-resume-v1.json.

enum FileResume {
    /// The feature key: a capability, advertised on every protocol 2 session.
    static let featureKey = "files_resume_draft1"
    /// Offsets are whole blocks (or the whole file), so a sender checks them against the hashes it kept while hashing
    /// the file for the offer. Only larger files are offered resumable.
    static let block: Int64 = 1_048_576
    /// A kept partial lives until 24 hours after it last grew (the folders journal's window).
    static let lifetimeMilliseconds: Int64 = 24 * 60 * 60 * 1000
    static let perDevice = 4
    static let total = 16
    static let maximumKeptBytes: Int64 = 20 * 1024 * 1024 * 1024
    /// The receiver syncs and records at least this often while a resumable file comes in.
    static let checkpointEvery: Int64 = 64 * 1024 * 1024
    /// files.resume and files.resume.ack plaintexts.
    static let maximumMessage = 1024
    /// How long a sender waits for the answer to a resumable offer; each files.resume.wait starts it again.
    static let answerWindow: TimeInterval = 120
    /// How often a receiver re-reading a kept partial sends files.resume.wait.
    static let waitEvery: TimeInterval = 30
    static let partSuffix = ".bridgey-part"

    static func isResumable(size: Int64) -> Bool { size > block }

    static func nowMilliseconds(_ date: Date = Date()) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// The SHA-256 so far: `hasher` is a value, so finalizing it leaves the caller's running hash as it was.
    static func digest(_ hasher: SHA256) -> Data {
        Data(hasher.finalize())
    }

    static func equalInConstantTime(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    // MARK: Messages

    /// files.resume: the receiver holds the first `offset` bytes and this is their SHA-256.
    static func resumePayload(transferID: String, offset: Int64, prefix: Data) -> Data {
        let object: [String: Any] = ["version": 1, "transferId": transferID, "offset": NSNumber(value: offset),
                                     "prefixSha256": prefix.base64EncodedString()]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// files.resume.ack: the sender goes on from `offset` (the receiver's) or from byte zero, saying why.
    static func ackPayload(transferID: String, offset: Int64, reason: String?) -> Data {
        var object: [String: Any] = ["version": 1, "transferId": transferID, "offset": NSNumber(value: offset)]
        if let reason { object["reason"] = reason }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func object(_ plaintext: Data, transferID: String) -> [String: Any]? {
        guard plaintext.count <= maximumMessage, isStrictJSONObject(plaintext),
              let object = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              jsonInteger(object["version"]) == 1,
              object["transferId"] as? String == transferID else { return nil }
        return object
    }

    /// A files.resume for this transfer of `size` bytes: the offset (a positive whole number of blocks not above
    /// `size`, or `size` itself) and the 32-byte prefix hash, or nil.
    static func parseResume(_ plaintext: Data, transferID: String, size: Int64) -> (offset: Int64, prefix: Data)? {
        guard let object = object(plaintext, transferID: transferID),
              let raw = jsonInteger(object["offset"]) else { return nil }
        let offset = Int64(raw)
        guard offset >= 1, offset <= size, offset % block == 0 || offset == size,
              let text = object["prefixSha256"] as? String,
              let prefix = Data(base64Encoded: text), prefix.count == 32 else { return nil }
        return (offset, prefix)
    }

    /// A files.resume.ack answering a files.resume of `proposed` bytes: `proposed` or 0 (any reason), or nil.
    static func parseAck(_ plaintext: Data, transferID: String, proposed: Int64) -> Int64? {
        guard let object = object(plaintext, transferID: transferID),
              let raw = jsonInteger(object["offset"]) else { return nil }
        let offset = Int64(raw)
        return offset == proposed || offset == 0 ? offset : nil
    }

    /// The SHA-256 of a file's first `offset` bytes from the hashes kept at every block, when `offset` is a block
    /// boundary inside the file.
    static func blockPrefix(_ blocks: [Data], offset: Int64) -> Data? {
        guard offset > 0, offset % block == 0 else { return nil }
        let index = Int(offset / block) - 1
        return index < blocks.count ? blocks[index] : nil
    }

    /// What a sender answers to a files.resume for its file of `size` bytes with SHA-256 `sha256`: the receiver's
    /// offset when its prefix hash is this file's own, else 0 with `invalid` or `mismatch`.
    static func senderAnswer(_ plaintext: Data, transferID: String, size: Int64, sha256: Data, blocks: [Data]) -> (offset: Int64, reason: String?) {
        guard let (offset, prefix) = parseResume(plaintext, transferID: transferID, size: size) else { return (0, "invalid") }
        let ours = offset == size ? sha256 : blockPrefix(blocks, offset: offset)
        guard let ours, equalInConstantTime(ours, prefix) else { return (0, "mismatch") }
        return (offset, nil)
    }

    /// The SHA-256 of a file's first `length` bytes, read in 256 KiB pieces, and the hasher to continue from there.
    /// Throws when the file is shorter. A link at `url` is not followed.
    static func hashPrefix(of url: URL, length: Int64) throws -> (hasher: SHA256, digest: Data) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(descriptor) }
        return try hashPrefix(descriptor: descriptor, length: length)
    }

    /// The same through an open descriptor, from byte zero (`pread`, so the descriptor's offset does not move): the
    /// receiver re-reads the very file it will write to, never whatever its path names by then.
    static func hashPrefix(descriptor: Int32, length: Int64) throws -> (hasher: SHA256, digest: Data) {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var offset: Int64 = 0
        while offset < length {
            let want = Int(min(length - offset, Int64(buffer.count)))
            let count = buffer.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, want, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            hasher.update(data: Data(buffer[0..<count]))
            offset += Int64(count)
        }
        return (hasher, digest(hasher))
    }
}

/// A received file's `.bridgey-part`, opened so that nothing else can be written through it (security review 1.0):
/// anything that can write to the receive folder (a sandboxed app with access to Downloads, say) could otherwise put
/// a link where a partial waits, for up to a day, and the resume would cut the link's target and write the incoming
/// file into it; or plant a dangling link at a part's name before it is created.
enum ReceivedPartial {
    /// Opens `url` read and write without following a link at its name; `create` makes a new file and fails when the
    /// name exists in any form, which already proves it is ours and fresh. A kept partial (not `create`) is taken
    /// only as a plain file of this user with no other name. New files skip that check, so a receive folder on a
    /// network volume that reports another owner keeps working (review of PR #67); only resuming there falls back to
    /// starting from zero.
    static func open(_ url: URL, create: Bool) throws -> FileHandle {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (create ? O_CREAT | O_EXCL : 0)
        let descriptor = Darwin.open(url.path, flags, 0o600)
        guard descriptor >= 0 else { throw CocoaError(create ? .fileWriteFileExists : .fileReadNoPermission) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              create || (info.st_nlink == 1 && info.st_uid == geteuid()) else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        // Reads and writes block as usual; O_NONBLOCK only kept a FIFO at the name from hanging the open.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// `url` still names the file `handle` has open, as a plain file: checked before the part is moved into place,
    /// so a link swapped in meanwhile is never published as the received file.
    static func stillAt(_ url: URL, handle: FileHandle) -> Bool {
        var opened = stat()
        var named = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, lstat(url.path, &named) == 0 else { return false }
        return named.st_mode & S_IFMT == S_IFREG && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
    }
}

/// A running SHA-256 that remembers the prefix hash at every block boundary it passes: the last one (a receiver's
/// checkpoint) or all of them (a sender's, to answer files.resume without reading the file again).
struct ResumeHasher {
    private(set) var hasher = SHA256()
    private(set) var length: Int64 = 0
    private var last: (length: Int64, digest: Data)
    private(set) var blocks: [Data]?

    init(keepBlocks: Bool) {
        last = (0, FileResume.digest(SHA256()))
        blocks = keepBlocks ? [] : nil
    }

    /// Continues from a verified prefix of `length` bytes (a block boundary or the whole file).
    init(resumed hasher: SHA256, length: Int64, digest: Data) {
        self.hasher = hasher
        self.length = length
        last = (length, digest)
        blocks = nil
    }

    mutating func update(_ data: Data) {
        var start = data.startIndex
        while start < data.endIndex {
            let toBoundary = FileResume.block - length % FileResume.block
            let take = Int(min(toBoundary, Int64(data.endIndex - start)))
            let end = start + take
            hasher.update(data: data[start..<end])
            length += Int64(take)
            start = end
            if length % FileResume.block == 0 {
                let digest = FileResume.digest(hasher)
                last = (length, digest)
                blocks?.append(digest)
            }
        }
    }

    /// What a receiver may record of a file of `size` bytes: the whole file once it is all here, else the last block
    /// boundary, with the SHA-256 of the bytes before it.
    func checkpoint(size: Int64) -> (length: Int64, digest: Data) {
        length == size ? (size, FileResume.digest(hasher)) : last
    }

    func finalize() -> Data { FileResume.digest(hasher) }
}

/// One kept partial: whose file it is, how much of it is verified and where it is. Lives in the private record file,
/// never beside the received files.
struct ResumeRecord: Codable, Equatable {
    /// The device that sent it (authenticated), lowercase.
    var peer: String
    /// The offer's size and base64 SHA-256: the file's content identity.
    var size: Int64
    var sha256: String
    /// Verified bytes, on stable storage before this record named them, and their base64 SHA-256.
    var length: Int64
    var prefix: String
    /// The receive folder and the part file's name in it (`name.bridgey-part`).
    var dir: String
    var part: String
    /// The offered name, made safe: notices a changed source, and is the name it is saved under.
    var name: String
    /// When it last grew or was kept (Unix ms).
    var updated: Int64

    var directoryURL: URL { URL(fileURLWithPath: dir, isDirectory: true) }
    var partURL: URL { directoryURL.appendingPathComponent(part) }
    var key: String { partURL.standardizedFileURL.path }

    func expired(now: Int64) -> Bool {
        // A stamp far in the future means the clock went back: it counts as expired too.
        now >= updated &+ FileResume.lifetimeMilliseconds || updated > now &+ FileResume.lifetimeMilliseconds
    }

    var isValid: Bool {
        let hash = { (text: String) in Data(base64Encoded: text)?.count == 32 }
        return UUID(uuidString: peer) != nil && size >= 0 && length >= 0 && length <= size && hash(sha256) && hash(prefix)
            && dir.hasPrefix("/") && ResumeRecord.validPart(part)
    }

    /// Only names this app gives partials of single files: `something.bridgey-part`, never a path, so a damaged record
    /// cannot point a deletion anywhere else.
    static func validPart(_ name: String) -> Bool {
        name.hasSuffix(FileResume.partSuffix) && name.count > FileResume.partSuffix.count && !name.contains("/")
            && !name.contains("\0") && name.utf8.count <= 255
    }
}

/// The receiver's kept partials. Pure bookkeeping, as resume::Store: the caller deletes the part files it returns and
/// persists `encode()`.
struct ResumeStore {
    private(set) var records: [ResumeRecord] = []
    /// Part files a transfer is using now: never swept, evicted or claimed twice.
    private(set) var claimed: Set<String> = []

    init(records: [ResumeRecord] = []) { self.records = records }

    static func decode(_ data: Data?) -> ResumeStore {
        struct File: Decodable { let version: Int; let records: [LenientRecord] }
        struct LenientRecord: Decodable {
            let record: ResumeRecord?
            init(from decoder: Decoder) throws { record = try? ResumeRecord(from: decoder) }
        }
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else { return ResumeStore() }
        let valid = file.records.compactMap(\.record).map { record -> ResumeRecord in
            var record = record
            record.peer = record.peer.lowercased()
            return record
        }.filter(\.isValid)
        return ResumeStore(records: Array(valid.prefix(FileResume.total * 2)))
    }

    func encode() -> Data {
        struct File: Encodable { let version: Int; let records: [ResumeRecord] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(File(version: 1, records: records))) ?? Data()
    }

    private mutating func take(keeping keep: (ResumeRecord) -> Bool) -> [URL] {
        var gone: [URL] = []
        records.removeAll { record in
            let kept = keep(record)
            if !kept { gone.append(record.partURL) }
            return !kept
        }
        return gone
    }

    /// At start: drops what can no longer be resumed (expired, nothing verified, the part missing or shorter than its
    /// record). Returns the part files to delete.
    mutating func sweep(now: Int64, partLength: (URL) -> Int64?) -> [URL] {
        take { record in
            guard !record.expired(now: now), record.length > 0, let length = partLength(record.partURL) else { return false }
            return length >= record.length
        }
    }

    private mutating func expire(now: Int64) -> [URL] {
        let inUse = claimed
        return take { inUse.contains($0.key) || !$0.expired(now: now) }
    }

    /// A resumable offer from `peer`: the partial to resume (claimed until released) and the part files to delete.
    /// Only a record from the same device with the same size and SHA-256 in the folder files land in now matches.
    /// That device's free records with the same name but other content go: its source changed.
    mutating func claim(peer: String, size: Int64, sha256: String, name: String, dir: URL, now: Int64) -> (ResumeRecord?, [URL]) {
        let peer = peer.lowercased()
        var gone = expire(now: now)
        let directory = dir.standardizedFileURL.path
        let inUse = claimed
        let same = { (r: ResumeRecord) in r.peer == peer && r.size == size && r.sha256 == sha256 }
        let found = records.first { !inUse.contains($0.key) && same($0) && $0.length > 0 && $0.directoryURL.standardizedFileURL.path == directory }
        let keep = found?.key
        gone += take { r in
            let free = !inUse.contains(r.key) && r.key != keep
            let stale = r.peer == peer && (same(r) || (!name.isEmpty && r.name == name))
            return !(free && stale)
        }
        if let keep { claimed.insert(keep) }
        return (found, gone)
    }

    /// Saves a record, new or updated (matched by its part file), stamped `now` and claimed. Over the limits the oldest
    /// records not in use go. Returns the part files to delete.
    mutating func save(_ record: ResumeRecord, now: Int64) -> [URL] {
        var record = record
        record.peer = record.peer.lowercased()
        record.updated = now
        claimed.insert(record.key)
        if let index = records.firstIndex(where: { $0.key == record.key }) {
            records[index] = record
        } else {
            records.append(record)
        }
        var gone = expire(now: now)
        while true {
            let overPeer = records.filter { $0.peer == record.peer }.count > FileResume.perDevice
            let bytes = records.reduce(Int64(0)) { $0 + $1.length }
            if !overPeer && records.count <= FileResume.total && bytes <= FileResume.maximumKeptBytes { break }
            let candidates = records.enumerated().filter { !claimed.contains($0.element.key) && (!overPeer || $0.element.peer == record.peer) }
            // Everything left is in use: over the limit until a transfer ends.
            guard let oldest = candidates.min(by: { $0.element.updated < $1.element.updated }) else { break }
            gone.append(records.remove(at: oldest.offset).partURL)
        }
        return gone
    }

    /// The transfer using this partial ended: its record stays for a later attempt (`keep`) or goes. True when a
    /// record went.
    @discardableResult
    mutating func release(_ part: URL, keep: Bool) -> Bool {
        let key = part.standardizedFileURL.path
        claimed.remove(key)
        guard !keep else { return false }
        let before = records.count
        records.removeAll { $0.key == key }
        return records.count != before
    }

    /// The device was forgotten: its partials go. Returns the part files to delete.
    mutating func forget(peer: String) -> [URL] {
        let peer = peer.lowercased()
        let inUse = claimed
        return take { $0.peer != peer || inUse.contains($0.key) }
    }
}

/// The store with its private file (Application Support/<support folder>/file-resume.json) and the part files it
/// lets go. Main thread only.
final class ResumePartials {
    private(set) var store = ResumeStore()
    let fileURL: URL
    private let now: () -> Int64

    init(fileURL: URL = ResumePartials.defaultFileURL(), now: @escaping () -> Int64 = { FileResume.nowMilliseconds() }) {
        self.fileURL = fileURL
        self.now = now
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/file-resume.json")
    }

    /// At start: the records, less those that can no longer be resumed, whose part files are deleted.
    func load() {
        store = ResumeStore.decode(try? Data(contentsOf: fileURL))
        let gone = store.sweep(now: now()) { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return nil }
            return Int64(values.fileSize ?? 0)
        }
        if !gone.isEmpty { changed(gone) }
    }

    func claim(peer: String, size: Int64, sha256: String, name: String, dir: URL) -> ResumeRecord? {
        let (found, gone) = store.claim(peer: peer, size: size, sha256: sha256, name: name, dir: dir, now: now())
        if !gone.isEmpty { changed(gone) }
        return found
    }

    /// Saves a record; its bytes are on stable storage first.
    func save(_ record: ResumeRecord) {
        changed(store.save(record, now: now()))
    }

    /// Never deletes the part file itself: the transfer does when it lets the partial go.
    func release(_ part: URL, keep: Bool) {
        if store.release(part, keep: keep) { changed([]) }
    }

    func forget(peer: String) {
        let gone = store.forget(peer: peer)
        if !gone.isEmpty { changed(gone) }
    }

    private func changed(_ gone: [URL]) {
        for part in gone where ResumeRecord.validPart(part.lastPathComponent) {
            try? FileManager.default.removeItem(at: part)
        }
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: store.encode(), attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, fileURL.path) != 0 {
            try? manager.removeItem(at: temporary)
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

extension ResumePartials {
    /// The transfer for an offer: a kept partial of this content from this device when there is one (reopened, to be
    /// read again), else a new part, recorded at once when resumable so a crash leaves nothing behind.
    func openIncoming(_ offer: FileOfferPayload, from peer: String, access: ReceiveDirectoryAccess, resumable: Bool) -> IncomingFileTransfer? {
        if resumable, let record = claim(peer: peer, size: offer.size, sha256: offer.sha256, name: receivedFileName(offer.name), dir: access.url) {
            if let transfer = try? IncomingFileTransfer(resuming: record, offer: offer, directoryAccess: access) { return transfer }
            try? FileManager.default.removeItem(at: record.partURL)
            release(record.partURL, keep: false)
        }
        guard let transfer = try? IncomingFileTransfer(offer: offer, directoryAccess: access, resumable: resumable, peer: peer) else { return nil }
        if let record = transfer.initialRecord() { save(record) }
        return transfer
    }

    /// The transfer was interrupted (disconnect, timeout, quit): a resumable partial stays, synced and recorded;
    /// anything else goes as before.
    func keep(_ transfer: IncomingFileTransfer) {
        switch transfer.keepForLater() {
        case .unchanged:
            release(transfer.partialURL, keep: true)
        case let .record(record):
            save(record)
            release(transfer.partialURL, keep: true)
        case .discard:
            drop(transfer)
        }
    }

    /// The transfer ended for good (cancelled, invalid, failed): the partial and its record go.
    func drop(_ transfer: IncomingFileTransfer) {
        transfer.cancel()
        if transfer.resumable { release(transfer.partialURL, keep: false) }
    }

    /// files.complete came: saved or failed (`finish` deletes a failed part), the partial is never resumed again.
    func finished(_ transfer: IncomingFileTransfer) {
        if transfer.resumable { release(transfer.partialURL, keep: false) }
    }
}

/// A kept partial read again off the main thread before files.resume, with a call every `every` seconds meanwhile
/// (files.resume.wait), so a read longer than the sender's 120-second window does not make it cancel.
final class ResumeCheck {
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var finished = false

    /// Reads the partial `url` names (a link is not followed).
    convenience init(url: URL, length: Int64, every: TimeInterval = FileResume.waitEvery, held: TimeInterval = 0,
                     waiting: @escaping () -> Void, done: @escaping ((hasher: SHA256, digest: Data)?) -> Void) {
        self.init(descriptor: Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), length: length, every: every, held: held,
                  waiting: waiting, done: done)
    }

    /// `waiting` and `done` run on the main queue. `held` holds the read back first (tests only). Takes `descriptor`
    /// (closed when the read ends; -1 reads nothing): the app passes its own copy of the descriptor the transfer has
    /// open (IncomingFileTransfer.duplicateDescriptor), so the bytes checked are the ones it will write after.
    init(descriptor: Int32, length: Int64, every: TimeInterval = FileResume.waitEvery, held: TimeInterval = 0,
         waiting: @escaping () -> Void, done: @escaping ((hasher: SHA256, digest: Data)?) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + every, repeating: every)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFinished else { return }
            waiting()
        }
        self.timer = timer
        timer.resume()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if held > 0 { Thread.sleep(forTimeInterval: held) }
            let result = descriptor >= 0 ? try? FileResume.hashPrefix(descriptor: descriptor, length: length) : nil
            if descriptor >= 0 { Darwin.close(descriptor) }
            DispatchQueue.main.async {
                guard let self, self.finish() else { return }
                done(result)
            }
        }
    }

    private var isFinished: Bool { lock.withLock { finished } }

    /// True the first time: the check ends here.
    private func finish() -> Bool {
        let first = lock.withLock { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if first { timer?.cancel(); timer = nil }
        return first
    }

    /// The transfer ended first: no more waits, and the result is dropped.
    func cancel() { _ = finish() }
}

/// Single files to a phone that a disconnect interrupted, sent again when it reconnects within 24 hours (Settings >
/// Files > Resume interrupted files automatically, on by default), oldest first, as folders resume.
struct AutoResumeList {
    struct Entry: Equatable {
        let id: String
        let phone: String
        let interruptedAt: Date
        let startedAt: Date
    }

    static let window: TimeInterval = 24 * 60 * 60
    private(set) var entries: [Entry] = []

    mutating func interrupted(_ files: [(id: String, startedAt: Date)], phone: String, at date: Date) {
        for file in files {
            entries.removeAll { $0.id == file.id }
            entries.append(Entry(id: file.id, phone: phone, interruptedAt: date, startedAt: file.startedAt))
        }
    }

    /// Cancelled, retried by hand or gone from the list.
    mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }

    /// The phone is back with Files and the resume key: the files to send again, oldest first. They leave the list,
    /// and so does anything of that phone older than 24 hours, or everything of it when the setting is off.
    mutating func due(phone: String, now: Date, enabled: Bool) -> [String] {
        let mine = entries.filter { $0.phone == phone }
        entries.removeAll { $0.phone == phone }
        guard enabled else { return [] }
        return mine.filter { now.timeIntervalSince($0.interruptedAt) < Self.window && $0.interruptedAt <= now.addingTimeInterval(60) }
            .sorted { $0.startedAt < $1.startedAt }
            .map(\.id)
    }
}
