import AppKit
import CryptoKit
import Foundation

/*
 * Sending clipboard offers from the Mac: the current outgoing offer, the transfers that serve
 * fetches and eager pushes, and building offers from what was copied. Files are read once,
 * hashing while they stream; the hash goes out in files.complete.
 */

/// Where an offered item's bytes come from.
enum ClipboardOutgoingSource: Equatable {
    /// Long text or HTML, in memory.
    case data(Data)
    /// A copy in the outgoing cache (pasteboard images).
    case copy(URL)
    /// The user's own file; size and modification time as offered, to notice changes.
    case original(URL, size: Int64, modified: Date)
}

struct ClipboardFileRef: Equatable {
    let url: URL
    let name: String
    let size: Int64
    let modified: Date
    let mime: String
}

struct ClipboardImageClip: Equatable {
    let data: Data
    let mime: String
    /// Base64 SHA-256 of `data`.
    let hash: String

    init(data: Data, mime: String) {
        self.data = data
        self.mime = mime
        hash = clipboardDataHash(data)
    }
}

enum ClipboardOfferBuilder {
    static func newOfferID() -> String { UUID().uuidString.lowercased() }

    static func createdAt(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func text(_ text: String, html: String?, sensitive: Bool, now: Date = Date()) -> (ClipboardOffer, [ClipboardOutgoingSource]) {
        var budget = ClipboardOfferLimits.maximumInlineBytes
        var items: [ClipboardOfferItem] = []
        var sources: [ClipboardOutgoingSource] = []
        for (kind, value) in [(ClipboardItemKind.text, Optional(text)), (.html, html.flatMap { $0.isEmpty ? nil : $0 })] {
            guard let value else { continue }
            let data = Data(value.utf8)
            var item = ClipboardOfferItem(index: items.count, kind: kind, mime: kind == .text ? "text/plain" : "text/html",
                                          name: nil, size: Int64(data.count), sha256: clipboardDataHash(data), inline: nil)
            if data.count <= budget {
                item.inline = data.base64EncodedString()
                budget -= data.count
            }
            items.append(item)
            sources.append(.data(data))
        }
        let offer = ClipboardOffer(offerId: newOfferID(), createdAt: createdAt(now), sensitive: sensitive ? true : nil, items: items)
        return (offer, sources)
    }

    /// Writes each image to the outgoing cache, so memory is released and fetches can stream it.
    static func images(_ images: [ClipboardImageClip], cache: ClipboardCache, now: Date = Date()) -> (ClipboardOffer, [ClipboardOutgoingSource])? {
        let offerID = newOfferID()
        guard let directory = try? cache.outgoingDirectory(offerID: offerID) else { return nil }
        var budget = ClipboardOfferLimits.maximumInlineBytes
        var items: [ClipboardOfferItem] = []
        var sources: [ClipboardOutgoingSource] = []
        for image in images.prefix(ClipboardOfferLimits.maximumItems) {
            let index = items.count
            let url = directory.appendingPathComponent("\(index).\(clipboardFileExtension(forMime: image.mime))")
            guard FileManager.default.createFile(atPath: url.path, contents: image.data, attributes: [.posixPermissions: 0o600]) else { continue }
            var item = ClipboardOfferItem(index: index, kind: .image, mime: image.mime, name: nil,
                                          size: Int64(image.data.count), sha256: image.hash, inline: nil)
            if image.data.count <= budget {
                item.inline = image.data.base64EncodedString()
                budget -= image.data.count
            }
            items.append(item)
            sources.append(.copy(url))
        }
        guard !items.isEmpty else { cache.removeOutgoing(offerID: offerID); return nil }
        return (ClipboardOffer(offerId: offerID, createdAt: createdAt(now), sensitive: nil, items: items), sources)
    }

    /// Files are not read (tiny ones aside, which go inline); their hash is computed as they stream.
    static func files(_ files: [ClipboardFileRef], now: Date = Date()) -> (ClipboardOffer, [ClipboardOutgoingSource])? {
        var budget = ClipboardOfferLimits.maximumInlineBytes
        var items: [ClipboardOfferItem] = []
        var sources: [ClipboardOutgoingSource] = []
        for file in files.prefix(ClipboardOfferLimits.maximumItems) where file.size <= ClipboardOfferLimits.maximumItemSize {
            guard let name = clipboardSanitizedName(file.name) else { continue }
            var item = ClipboardOfferItem(index: items.count, kind: .file, mime: clipboardMimeIsValid(file.mime) ? file.mime : "application/octet-stream",
                                          name: name, size: file.size, sha256: nil, inline: nil)
            if file.size <= Int64(budget), let data = try? Data(contentsOf: file.url), Int64(data.count) == file.size {
                item.inline = data.base64EncodedString()
                item.sha256 = clipboardDataHash(data)
                budget -= data.count
            }
            items.append(item)
            sources.append(.original(file.url, size: file.size, modified: file.modified))
        }
        guard !items.isEmpty else { return nil }
        return (ClipboardOffer(offerId: newOfferID(), createdAt: createdAt(now), sensitive: nil, items: items), sources)
    }
}

/// Encrypts and sends one chunk on the session it was made for, waiting for the network to take
/// it. Called from a background queue.
final class ClipboardChunkSender: @unchecked Sendable {
    let send: (_ chunk: Data, _ sequence: Int64, _ transferID: String) -> Bool

    init(send: @escaping (Data, Int64, String) -> Bool) {
        self.send = send
    }
}

struct ClipboardOutboxTransport {
    var isConnected: () -> Bool = { false }
    /// Encrypts `payload` and sends it as `kind`, with `transferID` in the outer message.
    var sendEncrypted: (_ kind: String, _ payload: Data, _ transferID: String?) -> Bool = { _, _, _ in false }
    var sendCancel: (String) -> Void = { _ in }
    var chunkSender: () -> ClipboardChunkSender? = { nil }
}

enum ClipboardStreamError: Error, Equatable {
    case cancelled, changed, unavailable, connection
}

/// One clipboard-purpose transfer from the Mac. Streams on a background queue with at most 64
/// chunks unacknowledged, like files.
final class ClipboardOutgoingTransfer: @unchecked Sendable {
    static let acknowledgementWindow: Int64 = 64

    let transferID: String
    let offerID: String
    let index: Int
    let size: Int64
    let isFetch: Bool
    let source: ClipboardOutgoingSource
    private let lock = NSLock()
    private var cancelled = false
    private let acknowledgement = NSCondition()
    private var acknowledgedSequence: Int64 = -1

    init(transferID: String, offerID: String, index: Int, size: Int64, isFetch: Bool, source: ClipboardOutgoingSource) {
        self.transferID = transferID
        self.offerID = offerID
        self.index = index
        self.size = size
        self.isFetch = isFetch
        self.source = source
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
        acknowledgement.lock()
        acknowledgement.broadcast()
        acknowledgement.unlock()
    }

    func acknowledge(sequence: Int64) {
        acknowledgement.lock()
        acknowledgedSequence = max(acknowledgedSequence, sequence)
        acknowledgement.broadcast()
        acknowledgement.unlock()
    }

    private func waitForAcknowledgement(_ sequence: Int64) throws {
        acknowledgement.lock()
        defer { acknowledgement.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while acknowledgedSequence < sequence && !isCancelled {
            if !acknowledgement.wait(until: deadline) { throw ClipboardStreamError.connection }
        }
        if isCancelled { throw ClipboardStreamError.cancelled }
    }

    /// Streams every chunk, then reports the SHA-256 of what was sent.
    func stream(with sender: ClipboardChunkSender, completion: @escaping (Result<String, ClipboardStreamError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                completion(.success(try self.streamChunks(sender)))
            } catch let error as ClipboardStreamError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unavailable))
            }
        }
    }

    private func streamChunks(_ sender: ClipboardChunkSender) throws -> String {
        var hasher = SHA256()
        var sent: Int64 = 0
        var sequence: Int64 = 0
        let next = try reader()
        while let chunk = try next(), !chunk.isEmpty {
            guard !isCancelled else { throw ClipboardStreamError.cancelled }
            guard sent + Int64(chunk.count) <= size else { throw ClipboardStreamError.changed }
            hasher.update(data: chunk)
            guard sender.send(chunk, sequence, transferID) else { throw ClipboardStreamError.connection }
            if sequence >= Self.acknowledgementWindow - 1 {
                try waitForAcknowledgement(sequence - (Self.acknowledgementWindow - 1))
            }
            sequence += 1
            sent += Int64(chunk.count)
        }
        guard sent == size else { throw ClipboardStreamError.changed }
        if sequence > 0 { try waitForAcknowledgement(sequence - 1) }
        guard !isCancelled else { throw ClipboardStreamError.cancelled }
        return Data(hasher.finalize()).base64EncodedString()
    }

    /// A function returning the next chunk, or nil at the end.
    private func reader() throws -> () throws -> Data? {
        let chunkSize = ClipboardOfferLimits.chunkSize
        switch source {
        case let .data(data):
            var offset = 0
            return {
                guard offset < data.count else { return nil }
                let end = min(offset + chunkSize, data.count)
                defer { offset = end }
                return data.subdata(in: offset..<end)
            }
        case let .copy(url), let .original(url, _, _):
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw ClipboardStreamError.unavailable }
            return {
                do {
                    let data = try handle.read(upToCount: chunkSize)
                    if data == nil || data?.isEmpty == true { try? handle.close() }
                    return data
                } catch {
                    try? handle.close()
                    throw ClipboardStreamError.unavailable
                }
            }
        }
    }
}

@MainActor
final class ClipboardOutbox {
    struct Current {
        let offer: ClipboardOffer
        let sources: [ClipboardOutgoingSource]
        /// The pasteboard change count the offer describes.
        let changeCount: Int
        let deviceID: String
    }

    private(set) var current: Current?
    private(set) var transfers: [String: ClipboardOutgoingTransfer] = [:]
    var transport = ClipboardOutboxTransport()
    /// Clipboard and Copy images and files are on for both devices.
    var available: () -> Bool = { false }
    var pasteboardChangeCount: () -> Int = { NSPasteboard.general.changeCount }
    let cache: ClipboardCache
    private var pushQueue: [Int] = []
    private var pushing: String?
    private var timeouts: [String: DispatchWorkItem] = [:]
    private var finishedTransferIDs: [String] = []

    init(cache: ClipboardCache) {
        self.cache = cache
    }

    var activeCount: Int { transfers.count }

    func owns(_ transferID: String?) -> Bool {
        guard let transferID else { return false }
        return transfers[transferID] != nil || finishedTransferIDs.contains(transferID)
    }

    /// A running transfer, and `deviceID` is the phone the offer went to.
    func serves(_ transferID: String?, to deviceID: String) -> Bool {
        guard let transferID, transfers[transferID] != nil else { return false }
        return current?.deviceID == deviceID
    }

    /// A new outgoing offer replaces the previous one.
    func begin(offer: ClipboardOffer, sources: [ClipboardOutgoingSource], changeCount: Int, deviceID: String) {
        supersede()
        current = Current(offer: offer, sources: sources, changeCount: changeCount, deviceID: deviceID)
    }

    /// Stops serving the current offer (a newer clip in either direction).
    func supersede() {
        pushQueue = []
        pushing = nil
        for transfer in transfers.values {
            transport.sendCancel(transfer.transferID)
            finish(transfer.transferID)
        }
        if let old = current { cache.removeOutgoing(offerID: old.offer.offerId) }
        current = nil
    }

    /// The session ended: running transfers stop; the offer stays for the same phone.
    func connectionLost() {
        pushQueue = []
        pushing = nil
        for transfer in transfers.values { finish(transfer.transferID) }
    }

    func clearAll() {
        supersede()
    }

    // MARK: Fetches and eager pushes

    /// Validates a fetch and either starts its transfer or answers clipboard.error.
    func handleFetch(_ fetch: ClipboardFetchPayload) {
        if let code = refusal(for: fetch) {
            sendError(code, offerID: fetch.offerId, index: fetch.index, transferID: fetch.transferId)
            return
        }
        start(index: fetch.index, transferID: fetch.transferId, isFetch: true)
    }

    func refusal(for fetch: ClipboardFetchPayload) -> ClipboardErrorCode? {
        guard available() else { return .disabled }
        guard let current, current.offer.offerId == fetch.offerId, current.offer.items.indices.contains(fetch.index) else { return .expired }
        guard transfers[fetch.transferId] == nil else { return .busy }
        guard pasteboardChangeCount() == current.changeCount else { return .changed }
        let item = current.offer.items[fetch.index]
        guard item.size <= ClipboardOfferLimits.maximumItemSize else { return .tooLarge }
        switch current.sources[fetch.index] {
        case .data: break
        case let .copy(url):
            guard FileManager.default.isReadableFile(atPath: url.path) else { return .unavailable }
        case let .original(offered, size, modified):
            // A fresh URL: resource values are cached per URL, and the file may have changed.
            let url = URL(fileURLWithPath: offered.path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path) else { return .unavailable }
            if Int64(values.fileSize ?? -1) != size || values.contentModificationDate != modified { return .changed }
        }
        guard activeCount < ClipboardOfferLimits.maximumConcurrentTransfers else { return .busy }
        return nil
    }

    /// Pushes small items right after the offer, one at a time.
    func startEagerPushes(limit: Int64) {
        guard let current else { return }
        pushQueue = clipboardEagerIndices(current.offer.items, limit: limit)
        pumpPushes()
    }

    private func pumpPushes() {
        guard pushing == nil, current != nil, activeCount < ClipboardOfferLimits.maximumConcurrentTransfers,
              !pushQueue.isEmpty, transport.isConnected() else { return }
        let index = pushQueue.removeFirst()
        let transferID = UUID().uuidString.lowercased()
        pushing = transferID
        if !start(index: index, transferID: transferID, isFetch: false) {
            pushing = nil
            pumpPushes()
        }
    }

    @discardableResult
    private func start(index: Int, transferID: String, isFetch: Bool) -> Bool {
        guard let current, current.offer.items.indices.contains(index) else { return false }
        let item = current.offer.items[index]
        let transfer = ClipboardOutgoingTransfer(transferID: transferID, offerID: current.offer.offerId, index: index,
                                                 size: item.size, isFetch: isFetch, source: current.sources[index])
        let offer = ClipboardTransferOffer(transferId: transferID, name: clipboardTransferName(for: item), mimeType: item.mime,
                                           size: item.size, sha256: item.sha256, offerId: current.offer.offerId, index: index)
        guard let payload = try? JSONEncoder().encode(offer) else { return false }
        transfers[transferID] = transfer
        guard transport.sendEncrypted("files.offer", payload, transferID) else {
            finish(transferID)
            return false
        }
        schedule(timeout: 10, for: transferID)
        return true
    }

    // MARK: Messages from the phone

    func handleAccept(_ transferID: String) {
        guard let transfer = transfers[transferID] else { return }
        timeouts.removeValue(forKey: transferID)?.cancel()
        guard let sender = transport.chunkSender() else { finish(transferID); return }
        transfer.stream(with: sender) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.streamFinished(transfer, result) }
            }
        }
    }

    private func streamFinished(_ transfer: ClipboardOutgoingTransfer, _ result: Result<String, ClipboardStreamError>) {
        guard transfers[transfer.transferID] === transfer else { return }
        switch result {
        case let .success(hash):
            guard let payload = try? JSONEncoder().encode(ClipboardTransferComplete(transferId: transfer.transferID, sha256: hash)),
                  transport.sendEncrypted("files.complete", payload, transfer.transferID) else {
                finish(transfer.transferID)
                return
            }
            schedule(timeout: 15, for: transfer.transferID)
        case let .failure(error):
            switch error {
            case .changed: sendError(.changed, offerID: transfer.offerID, index: transfer.index, transferID: transfer.transferID)
            case .unavailable: sendError(.unavailable, offerID: transfer.offerID, index: transfer.index, transferID: transfer.transferID)
            case .cancelled, .connection: break
            }
            finish(transfer.transferID)
        }
    }

    func handleChunkAck(_ transferID: String, sequence: Int64) {
        transfers[transferID]?.acknowledge(sequence: sequence)
    }

    func handleCompleteAck(_ transferID: String) {
        guard transfers[transferID] != nil else { return }
        finish(transferID)
    }

    /// The phone cancelled or declined (`files.cancel`, `files.rejected`).
    func handleCancel(_ transferID: String) {
        guard let transfer = transfers[transferID] else { return }
        transfer.cancel()
        finish(transferID)
    }

    private func sendError(_ code: ClipboardErrorCode, offerID: String, index: Int, transferID: String) {
        guard let payload = try? JSONEncoder().encode(ClipboardErrorPayload(offerId: offerID, index: index, transferId: transferID, code: code)) else { return }
        _ = transport.sendEncrypted("clipboard.error", payload, transferID)
    }

    private func schedule(timeout seconds: TimeInterval, for transferID: String) {
        timeouts.removeValue(forKey: transferID)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let transfer = self.transfers[transferID] else { return }
            transfer.cancel()
            self.transport.sendCancel(transferID)
            self.finish(transferID)
        }
        timeouts[transferID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish(_ transferID: String) {
        timeouts.removeValue(forKey: transferID)?.cancel()
        guard let transfer = transfers.removeValue(forKey: transferID) else { return }
        transfer.cancel()
        finishedTransferIDs.append(transferID)
        if finishedTransferIDs.count > 64 { finishedTransferIDs.removeFirst(finishedTransferIDs.count - 64) }
        if pushing == transferID {
            pushing = nil
            pumpPushes()
        }
    }
}
