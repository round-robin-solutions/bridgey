import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/*
 * Receiving clipboard offers on the Mac. One NSPasteboardItem per offered item, with a data
 * provider for its types. When an app pastes something that is not here yet, the provider asks
 * the phone for it and waits, like Universal Clipboard: the pasting app blocks (it waits at least
 * 70 s, measured on macOS 27), and a small progress panel with Cancel appears after about 300 ms.
 *
 * Waiting keeps the main run loop turning (events and the main queue), so the session keeps
 * receiving chunks. The provider is called on the main thread from the pasteboard's run-loop
 * source; if the main thread is already inside a main-queue block that spins its own run loop
 * (a modal panel opened from DispatchQueue.main.async), the main queue cannot drain and the
 * provider gives up after a second instead of hanging. Pasteboard writes that arrive while a
 * provider waits are deferred until it returns.
 */

/// How the inbox reaches the phone; the coordinator implements it over the session.
struct ClipboardInboxTransport {
    var isConnected: () -> Bool = { false }
    var sendFetch: (ClipboardFetchPayload) -> Bool = { _ in false }
    var sendAccept: (String) -> Void = { _ in }
    var sendCompleteAck: (String) -> Void = { _ in }
    var sendCancel: (String) -> Void = { _ in }
}

enum ClipboardPasteFailure: Error, Equatable {
    case notConnected
    case cancelled
    case refused(ClipboardErrorCode?)
    case timedOut
    /// The main queue could not drain while waiting (see the note at the top).
    case blocked
}

/// The progress panel, behind a protocol so tests run without windows.
@MainActor
protocol ClipboardPasteProgress: AnyObject {
    func show(peerName: String, onCancel: @escaping () -> Void)
    func update(fraction: Double?)
    func hide()
}

final class ClipboardWaitFlag: @unchecked Sendable {
    var value = false
}

@MainActor
final class ClipboardInbox {
    struct Received {
        let offer: ClipboardOffer
        let deviceID: String
        let peerName: String
    }

    final class Transfer {
        let transferID: String
        let offerID: String
        let index: Int
        /// Asked for by a paste here (a lazy fetch), rather than pushed by the phone.
        let isFetch: Bool
        let expectedSize: Int64
        let offeredHash: String?
        var finalURL: URL?
        var partialURL: URL?
        var handle: FileHandle?
        var hasher = SHA256()
        var received: Int64 = 0
        var nextSequence: Int64 = 0
        var started = false
        var lastActivity: Date
        var result: Result<URL, ClipboardPasteFailure>?

        init(transferID: String, offerID: String, index: Int, isFetch: Bool, expectedSize: Int64, offeredHash: String?, now: Date) {
            self.transferID = transferID
            self.offerID = offerID
            self.index = index
            self.isFetch = isFetch
            self.expectedSize = expectedSize
            self.offeredHash = offeredHash
            lastActivity = now
        }

        var fraction: Double? {
            guard started else { return nil }
            return expectedSize == 0 ? 1 : min(1, Double(received) / Double(expectedSize))
        }
    }

    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private(set) var current: Received?
    private(set) var transfers: [String: Transfer] = [:]
    var transport = ClipboardInboxTransport()
    let cache: ClipboardCache
    var pasteboard: NSPasteboard
    var progress: ClipboardPasteProgress?
    /// Offer IDs the cache must keep besides ours (the outgoing offer).
    var protectedOfferIDs: () -> Set<String> = { [] }
    /// Keeps events and the main queue moving while a provider waits.
    var spin: (TimeInterval) -> Void = { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: $0)) }
    /// A paste moved data (a lazy fetch completed).
    var onPasted: (ClipboardOfferSummary, Received) -> Void = { _, _ in }
    /// A paste that waited could not get its data. Not called for Cancel.
    var onPasteFailed: (ClipboardPasteFailure, Received) -> Void = { _, _ in }
    /// Bridgey wrote the pasteboard at this change count (so it is never sent back).
    var onPasteboardWritten: (Int, Received) -> Void = { _, _ in }

    private let clock: () -> Date
    private var providers: [ClipboardItemProvider] = []
    private var providing = 0
    private var deferredWrites: [() -> Void] = []
    private var watchdogScheduled = false
    private var finishedTransferIDs: [String] = []
    let showProgressAfter: TimeInterval
    let blockedAfter: TimeInterval

    init(
        cache: ClipboardCache,
        pasteboard: NSPasteboard = .general,
        clock: @escaping () -> Date = Date.init,
        showProgressAfter: TimeInterval = 0.3,
        blockedAfter: TimeInterval = 1
    ) {
        self.cache = cache
        self.pasteboard = pasteboard
        self.clock = clock
        self.showProgressAfter = showProgressAfter
        self.blockedAfter = blockedAfter
    }

    /// Ours, running or recently finished (late chunks of a cancelled transfer are dropped
    /// quietly instead of reaching the Files path).
    func owns(_ transferID: String?) -> Bool {
        guard let transferID else { return false }
        return transfers[transferID] != nil || finishedTransferIDs.contains(transferID)
    }

    // MARK: Offers

    /// Puts a validated offer on the pasteboard, superseding the previous one.
    func accept(_ offer: ClipboardOffer, deviceID: String, peerName: String) {
        supersede()
        let received = Received(offer: offer, deviceID: deviceID, peerName: peerName)
        current = received
        performPasteboardWrite { [weak self] in
            guard let self, self.current?.offer.offerId == offer.offerId else { return }
            let items = self.pasteboardItems(for: received)
            self.pasteboard.clearContents()
            self.pasteboard.writeObjects(items)
            self.onPasteboardWritten(self.pasteboard.changeCount, received)
        }
    }

    /// A newer clip replaced the current offer: stop its transfers and drop what no app was given.
    func supersede() {
        for transfer in transfers.values where transfer.result == nil {
            transport.sendCancel(transfer.transferID)
            finish(transfer, .failure(.cancelled))
        }
        if let old = current { cache.removeSuperseded(offerID: old.offer.offerId) }
        current = nil
    }

    /// The connection dropped: running transfers fail; the offer stays, so a paste after
    /// reconnecting can still fetch.
    func connectionLost() {
        for transfer in transfers.values where transfer.result == nil {
            finish(transfer, .failure(.notConnected))
        }
        transfers.removeAll()
    }

    /// Clear activity and Forget device.
    func clearAll() {
        supersede()
        cache.clear()
    }

    /// Runs a pasteboard write now, or once the waiting provider has returned.
    func performPasteboardWrite(_ work: @escaping () -> Void) {
        if providing > 0 { deferredWrites.append(work) } else { work() }
    }

    func pasteboardItems(for received: Received) -> [NSPasteboardItem] {
        let offer = received.offer
        let provider = { (types: [NSPasteboard.PasteboardType: Int]) -> ClipboardItemProvider in
            let value = ClipboardItemProvider(inbox: self, offerID: offer.offerId, indexForType: types)
            // Kept until the pasteboard is done with them (pasteboardFinishedWithDataProvider).
            self.providers.append(value)
            if self.providers.count > 400 { self.providers.removeFirst(self.providers.count - 400) }
            return value
        }
        if offer.isText {
            let item = NSPasteboardItem()
            var lazy: [NSPasteboard.PasteboardType: Int] = [:]
            for entry in offer.items {
                let type: NSPasteboard.PasteboardType = entry.kind == .html ? .html : .string
                if let data = offer.inlineData(at: entry.index) { item.setData(data, forType: type) } else { lazy[type] = entry.index }
            }
            if !lazy.isEmpty {
                item.setDataProvider(provider(lazy), forTypes: Array(lazy.keys).sorted { $0.rawValue > $1.rawValue })
                item.setData(Data(), forType: Self.transientType)
            }
            return [item]
        }
        return offer.items.map { entry in
            let item = NSPasteboardItem()
            let types = Self.pasteboardTypes(for: entry)
            if let data = offer.inlineData(at: entry.index), types != [.fileURL] {
                item.setData(data, forType: types[0])
                if types.count > 1, let png = Self.pngData(from: data) { item.setData(png, forType: .png) }
            } else if offer.inlineData(at: entry.index) != nil, let url = materializeInline(received, index: entry.index) {
                item.setString(url.absoluteString, forType: .fileURL)
            } else {
                item.setDataProvider(provider(Dictionary(uniqueKeysWithValues: types.map { ($0, entry.index) })), forTypes: types)
                item.setData(Data(), forType: Self.transientType)
            }
            return item
        }
    }

    /// The pasteboard types an item is offered as on the Mac.
    static func pasteboardTypes(for item: ClipboardOfferItem) -> [NSPasteboard.PasteboardType] {
        switch item.kind {
        case .text: return [.string]
        case .html: return [.html]
        case .file: return [.fileURL]
        case .image:
            guard let type = UTType(mimeType: item.mime), type.conforms(to: .image) else { return [.fileURL] }
            let native = NSPasteboard.PasteboardType(type.identifier)
            return native == .png ? [.png] : [native, .png]
        }
    }

    // MARK: Providing data

    func provide(offerID: String, index: Int, type: NSPasteboard.PasteboardType, item: NSPasteboardItem) {
        providing += 1
        let data = data(offerID: offerID, index: index, type: type)
        providing -= 1
        if providing == 0 && !deferredWrites.isEmpty {
            let writes = deferredWrites
            deferredWrites = []
            DispatchQueue.main.async { writes.forEach { $0() } }
        }
        if let data { item.setData(data, forType: type) }
    }

    func data(offerID: String, index: Int, type: NSPasteboard.PasteboardType) -> Data? {
        guard let received = current, received.offer.offerId == offerID, received.offer.items.indices.contains(index) else {
            // An older offer still on a pasteboard: only what is cached can be served.
            return cache.cachedFile(offerID: offerID, index: index).flatMap { representation(file: $0, item: nil, type: type) }
        }
        let entry = received.offer.items[index]
        if let inline = received.offer.inlineData(at: index), type != .fileURL {
            return representation(data: inline, item: entry, type: type)
        }
        switch waitForFile(received, index: index) {
        case let .success(file):
            cache.markHandedOut(offerID: offerID, index: index)
            return representation(file: file, item: entry, type: type)
        case let .failure(failure):
            if failure != .cancelled { onPasteFailed(failure, received) }
            return nil
        }
    }

    private func representation(file: URL, item: ClipboardOfferItem?, type: NSPasteboard.PasteboardType) -> Data? {
        if type == .fileURL { return Data(file.absoluteString.utf8) }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return representation(data: data, item: item, type: type)
    }

    private func representation(data: Data, item: ClipboardOfferItem?, type: NSPasteboard.PasteboardType) -> Data? {
        guard type == .png, let item, Self.pasteboardTypes(for: item).first != .png else { return data }
        return Self.pngData(from: data)
    }

    static func pngData(from data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    /// Tiny inline files still need a file on disk for a file URL.
    private func materializeInline(_ received: Received, index: Int) -> URL? {
        let entry = received.offer.items[index]
        guard let data = received.offer.inlineData(at: index),
              let url = try? cache.prepareItem(offerID: received.offer.offerId, index: index, name: clipboardTransferName(for: entry)) else { return nil }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        cache.markHandedOut(offerID: received.offer.offerId, index: index)
        return url
    }

    /// The item's file: from the cache, from a push already running, or fetched now.
    func waitForFile(_ received: Received, index: Int) -> Result<URL, ClipboardPasteFailure> {
        let offerID = received.offer.offerId
        let running = transfers.values.first { $0.offerID == offerID && $0.index == index && $0.result == nil }
        if running == nil, let file = cache.cachedFile(offerID: offerID, index: index) { return .success(file) }
        let transfer: Transfer
        if let running {
            transfer = running
        } else {
            guard transport.isConnected() else { return .failure(.notConnected) }
            let entry = received.offer.items[index]
            let created = Transfer(
                transferID: UUID().uuidString.lowercased(), offerID: offerID, index: index, isFetch: true,
                expectedSize: entry.size, offeredHash: entry.sha256, now: clock()
            )
            transfers[created.transferID] = created
            guard transport.sendFetch(ClipboardFetchPayload(offerId: offerID, index: index, transferId: created.transferID)) else {
                transfers.removeValue(forKey: created.transferID)
                return .failure(.notConnected)
            }
            transfer = created
        }
        return wait(for: transfer, peerName: received.peerName)
    }

    private func wait(for transfer: Transfer, peerName: String) -> Result<URL, ClipboardPasteFailure> {
        let started = clock()
        let canary = ClipboardWaitFlag()
        DispatchQueue.main.async { canary.value = true }
        var shown = false
        while transfer.result == nil {
            let elapsed = clock().timeIntervalSince(started)
            if !canary.value && elapsed > blockedAfter {
                transport.sendCancel(transfer.transferID)
                finish(transfer, .failure(.blocked))
                break
            }
            checkTimeout(transfer)
            if transfer.result != nil { break }
            if !shown && elapsed >= showProgressAfter, let progress {
                shown = true
                progress.show(peerName: peerName) { [weak self, weak transfer] in
                    guard let self, let transfer, transfer.result == nil else { return }
                    self.transport.sendCancel(transfer.transferID)
                    self.finish(transfer, .failure(.cancelled))
                }
            }
            if shown { progress?.update(fraction: transfer.fraction) }
            spin(0.05)
        }
        if shown { progress?.hide() }
        return transfer.result ?? .failure(.cancelled)
    }

    // MARK: Transfers (messages from the phone, on the main queue)

    /// `files.offer` with purpose clipboard: the answer to our fetch, or an eager push.
    /// Returns false when declined (a `files.cancel` was sent).
    @discardableResult
    func handleTransferOffer(_ offer: ClipboardTransferOffer, outerTransferID: String?) -> Bool {
        let transferID = offer.transferId
        guard outerTransferID == nil || outerTransferID == transferID, UUID(uuidString: transferID) != nil else {
            transport.sendCancel(transferID)
            return false
        }
        let transfer: Transfer
        if let pending = transfers[transferID] {
            guard pending.result == nil, !pending.started, pending.offerID == offer.offerId, pending.index == offer.index,
                  pending.expectedSize == offer.size else {
                transport.sendCancel(transferID)
                if pending.result == nil { finish(pending, .failure(.refused(nil))) }
                return false
            }
            transfer = pending
        } else {
            guard let received = current, received.offer.offerId == offer.offerId,
                  received.offer.items.indices.contains(offer.index) else {
                transport.sendCancel(transferID)
                return false
            }
            let entry = received.offer.items[offer.index]
            let busy = transfers.values.contains { $0.offerID == offer.offerId && $0.index == offer.index && $0.result == nil }
            guard entry.inline == nil, !busy, entry.size == offer.size,
                  cache.cachedFile(offerID: offer.offerId, index: offer.index) == nil else {
                transport.sendCancel(transferID)
                return false
            }
            transfer = Transfer(transferID: transferID, offerID: offer.offerId, index: offer.index, isFetch: false,
                                expectedSize: entry.size, offeredHash: entry.sha256, now: clock())
            transfers[transferID] = transfer
        }
        guard offer.size <= ClipboardOfferLimits.maximumItemSize,
              offer.sha256 == nil || offer.sha256 == transfer.offeredHash || transfer.offeredHash == nil,
              let item = current?.offer.items[safe: offer.index],
              let finalURL = try? cache.prepareItem(offerID: offer.offerId, index: offer.index, name: clipboardTransferName(for: item)) else {
            transport.sendCancel(transferID)
            finish(transfer, .failure(.refused(nil)))
            return false
        }
        let partial = cache.partialURL(for: finalURL)
        FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            transport.sendCancel(transferID)
            finish(transfer, .failure(.refused(nil)))
            return false
        }
        transfer.finalURL = finalURL
        transfer.partialURL = partial
        transfer.handle = handle
        transfer.started = true
        transfer.lastActivity = clock()
        transport.sendAccept(transferID)
        scheduleWatchdog()
        return true
    }

    func handleChunk(transferID: String, sequence: Int64, data: Data) {
        guard let transfer = transfers[transferID], transfer.result == nil else { return }
        guard transfer.started, let handle = transfer.handle, sequence == transfer.nextSequence,
              data.count <= ClipboardOfferLimits.chunkSize,
              transfer.received + Int64(data.count) <= transfer.expectedSize,
              (try? handle.write(contentsOf: data)) != nil else {
            transport.sendCancel(transferID)
            finish(transfer, .failure(.refused(nil)))
            return
        }
        transfer.hasher.update(data: data)
        transfer.received += Int64(data.count)
        transfer.nextSequence += 1
        transfer.lastActivity = clock()
    }

    func handleComplete(transferID: String, sha256: String) {
        guard let transfer = transfers[transferID], transfer.result == nil else { return }
        try? transfer.handle?.close()
        transfer.handle = nil
        let actual = Data(transfer.hasher.finalize()).base64EncodedString()
        guard transfer.started, transfer.received == transfer.expectedSize, sha256 == actual,
              transfer.offeredHash == nil || transfer.offeredHash == actual,
              let partial = transfer.partialURL, let final = transfer.finalURL else {
            transport.sendCancel(transferID)
            finish(transfer, .failure(.refused(nil)))
            return
        }
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            transport.sendCancel(transferID)
            finish(transfer, .failure(.refused(nil)))
            return
        }
        transport.sendCompleteAck(transferID)
        finish(transfer, .success(final))
        if transfer.isFetch, let received = current, received.offer.offerId == transfer.offerID {
            onPasted(ClipboardOfferSummary(item: received.offer.items[transfer.index]), received)
        }
        cache.enforceLimits(protecting: protectedNow())
    }

    /// `files.cancel` from the phone for one of our transfers.
    func handleCancel(transferID: String) {
        guard let transfer = transfers[transferID], transfer.result == nil else { return }
        finish(transfer, .failure(.refused(nil)))
    }

    func handleError(_ payload: ClipboardErrorPayload) {
        guard let transfer = transfers[payload.transferId], transfer.result == nil,
              transfer.offerID == payload.offerId, transfer.index == payload.index else { return }
        finish(transfer, .failure(.refused(payload.code)))
    }

    private func finish(_ transfer: Transfer, _ result: Result<URL, ClipboardPasteFailure>) {
        guard transfer.result == nil else { return }
        transfer.result = result
        try? transfer.handle?.close()
        transfer.handle = nil
        if case .failure = result {
            if let partial = transfer.partialURL { try? FileManager.default.removeItem(at: partial) }
        }
        // Finished transfers leave the table; a waiting provider keeps its own reference.
        if transfers[transfer.transferID] === transfer { transfers.removeValue(forKey: transfer.transferID) }
        finishedTransferIDs.append(transfer.transferID)
        if finishedTransferIDs.count > 64 { finishedTransferIDs.removeFirst(finishedTransferIDs.count - 64) }
    }

    private func checkTimeout(_ transfer: Transfer) {
        guard transfer.result == nil else { return }
        let idle = clock().timeIntervalSince(transfer.lastActivity)
        let limit = transfer.started ? ClipboardOfferLimits.stallTimeout : ClipboardOfferLimits.fetchStartTimeout
        if idle > limit {
            transport.sendCancel(transfer.transferID)
            finish(transfer, .failure(.timedOut))
        }
    }

    /// Times out pushes nobody waits for.
    private func scheduleWatchdog() {
        guard !watchdogScheduled else { return }
        watchdogScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.watchdogScheduled = false
            self.transfers.values.forEach(self.checkTimeout)
            if self.transfers.values.contains(where: { $0.result == nil }) { self.scheduleWatchdog() }
        }
    }

    private func protectedNow() -> Set<String> {
        var ids = protectedOfferIDs()
        if let current { ids.insert(current.offer.offerId) }
        transfers.values.filter { $0.result == nil }.forEach { ids.insert($0.offerID) }
        return ids
    }

    /// The pasteboard no longer needs a provider: its contents were replaced (another copy on
    /// this Mac). Drops the provider, and the offer when it was the current one.
    func providerFinished(_ provider: ClipboardItemProvider) {
        providers.removeAll { $0 === provider }
        guard current?.offer.offerId == provider.offerID, providing == 0 else { return }
        supersede()
    }
}

/// One pasteboard item's data provider. The pasteboard calls it on the main thread.
final class ClipboardItemProvider: NSObject, NSPasteboardItemDataProvider {
    private weak var inbox: ClipboardInbox?
    let offerID: String
    let indexForType: [NSPasteboard.PasteboardType: Int]

    init(inbox: ClipboardInbox, offerID: String, indexForType: [NSPasteboard.PasteboardType: Int]) {
        self.inbox = inbox
        self.offerID = offerID
        self.indexForType = indexForType
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let index = indexForType[type] else { return }
        MainActor.assumeIsolated {
            inbox?.provide(offerID: offerID, index: index, type: type, item: item)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated {
            inbox?.providerFinished(self)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// "Pasting from OnePlus 11… 42%" with Cancel, shown while a paste waits for the phone.
@MainActor
final class ClipboardPasteProgressPanel: NSObject, ClipboardPasteProgress {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var onCancel: (() -> Void)?
    private var peerName = ""

    func show(peerName: String, onCancel: @escaping () -> Void) {
        self.peerName = peerName
        self.onCancel = onCancel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 92),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        let cancel = NSButton(title: L10n.text("action.cancel", fallback: "Cancel"), target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        panel.contentView = content
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.maxY - 140))
        }
        update(fraction: nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(fraction: Double?) {
        if let fraction {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
            bar.doubleValue = fraction
            label.stringValue = String(format: L10n.text("paste.progress.percent", fallback: "Pasting from %1$@\u{2026} %2$d%%"),
                                       peerName, Int((fraction * 100).rounded(.down)))
        } else {
            label.stringValue = String(format: L10n.text("paste.progress", fallback: "Pasting from %@\u{2026}"), peerName)
        }
    }

    func hide() {
        BridgeyWindows.orderOut(panel)
        panel = nil
        onCancel = nil
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}

/// The pasteboard change Bridgey made for a clipboard offer, so the send bar, Call and Send link
/// describe it instead of reading it (reading a lazy item would fetch it from the phone).
@MainActor
enum ClipboardOwnWrite {
    private(set) static var changeCount: Int?
    private(set) static var summary: ClipboardOfferSummary?
    private(set) static var peerName = ""
    /// Some data is fetched only when an app pastes.
    private(set) static var lazy = false

    static func record(changeCount: Int, offer: ClipboardOffer, peerName: String) {
        self.changeCount = changeCount
        summary = ClipboardOfferSummary(offer)
        self.peerName = peerName
        lazy = offer.items.contains { $0.inline == nil }
    }

    static func matches(_ changeCount: Int) -> Bool { self.changeCount == changeCount }

    static func isLazy(_ changeCount: Int) -> Bool { matches(changeCount) && lazy }

    /// "Image from OnePlus 11", "video.mp4 from OnePlus 11", "3 files from OnePlus 11".
    static func description(showNames: Bool = true) -> String? {
        guard let summary else { return nil }
        let what: String
        if summary.count > 1 {
            what = String.localizedStringWithFormat(
                L10n.text(summary.content == "image" ? "send.own.images" : "send.own.files",
                          fallback: summary.content == "image" ? "%d images" : "%d files"), summary.count)
        } else if summary.content == "image" {
            what = L10n.text("send.own.image", fallback: "Image")
        } else if summary.content == "text" {
            what = L10n.text("send.own.text", fallback: "Text")
        } else {
            what = (showNames ? summary.fileName : nil) ?? L10n.text("send.own.file", fallback: "File")
        }
        return String(format: L10n.text("send.own.from", fallback: "%1$@ from %2$@"), what, peerName)
    }
}
