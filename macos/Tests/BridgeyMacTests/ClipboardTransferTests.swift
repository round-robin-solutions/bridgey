import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

/// The Mac's clipboard data paths with fakes: the pasteboard data provider (read from a second
/// process on a named pasteboard, as a pasting app would), clipboard-purpose transfers into the
/// cache, superseding, and the sending side's fetch rules and streaming.
final class ClipboardTransferTests: XCTestCase {
    private var cacheRoot: URL!
    private var cache: ClipboardCache!
    private var pasteboard: NSPasteboard!
    private var sent: [String] = []
    private var fetches: [ClipboardFetchPayload] = []
    /// Work the fake phone does on the next provider spin.
    private var pending: [() -> Void] = []

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cliptransfer-\(UUID().uuidString)", isDirectory: true)
        cache = ClipboardCache(root: cacheRoot)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("bridgey-test-\(UUID().uuidString)"))
        sent = []
        fetches = []
        pending = []
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private func hash(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }

    @MainActor private func makeInbox(connected: Bool = true) -> ClipboardInbox {
        let inbox = ClipboardInbox(cache: cache, pasteboard: pasteboard, showProgressAfter: 0.3, blockedAfter: 30)
        inbox.transport = ClipboardInboxTransport(
            isConnected: { connected },
            sendFetch: { [unowned self] fetch in self.fetches.append(fetch); self.sent.append("fetch"); return true },
            sendAccept: { [unowned self] _ in self.sent.append("accept") },
            sendCompleteAck: { [unowned self] _ in self.sent.append("complete.ack") },
            sendCancel: { [unowned self] _ in self.sent.append("cancel") }
        )
        inbox.spin = { [unowned self] seconds in
            if !self.pending.isEmpty { self.pending.removeFirst()() }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: min(seconds, 0.01)))
        }
        return inbox
    }

    /// The phone's side of a transfer: offer, chunks, complete.
    @MainActor private func phoneSends(_ data: Data, to inbox: ClipboardInbox, offerID: String, index: Int, transferID: @escaping () -> String) {
        pending.append {
            inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID(), name: "x", mimeType: "image/png",
                                                             size: Int64(data.count), sha256: nil, offerId: offerID, index: index),
                                      outerTransferID: transferID())
        }
        var sequence: Int64 = 0
        stride(from: 0, to: data.count, by: ClipboardOfferLimits.chunkSize).forEach { start in
            let chunk = data.subdata(in: start..<min(start + ClipboardOfferLimits.chunkSize, data.count))
            let number = sequence
            pending.append { inbox.handleChunk(transferID: transferID(), sequence: number, data: chunk) }
            sequence += 1
        }
        pending.append { inbox.handleComplete(transferID: transferID(), sha256: self.hash(data)) }
    }

    @MainActor private func offer(_ items: [ClipboardOfferItem]) -> ClipboardOffer {
        ClipboardOffer(offerId: UUID().uuidString.lowercased(), createdAt: 1, sensitive: nil, items: items)
    }

    /// Reads the named pasteboard from another process, like a pasting app, while this one serves it.
    @MainActor private func readFromAnotherProcess(_ expression: String, timeout: TimeInterval = 30) throws -> String {
        let script = "ObjC.import('AppKit'); var pb = $.NSPasteboard.pasteboardWithName('\(pasteboard.name.rawValue)'); \(expression)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        if process.isRunning { process.terminate() }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Data provider

    @MainActor func testInlineItemsAreOnThePasteboardWithoutAFetch() throws {
        let inbox = makeInbox()
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                                  bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
        let item = ClipboardOfferItem(index: 0, kind: .image, mime: "image/png", name: nil, size: Int64(png.count),
                                      sha256: hash(png), inline: png.base64EncodedString())
        inbox.accept(offer([item]), deviceID: "phone", peerName: "OnePlus 11")
        XCTAssertEqual(try readFromAnotherProcess("pb.dataForType('public.png').length"), String(png.count))
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertFalse(pasteboard.types?.contains(ClipboardInbox.transientType) == true, "cached items may go to clipboard history")
    }

    @MainActor func testLazyFileIsFetchedWhenAnotherAppPastesIt() throws {
        let inbox = makeInbox()
        let data = Data((0..<60_000).map { UInt8($0 % 251) })
        let video = ClipboardOfferItem(index: 0, kind: .file, mime: "video/mp4", name: "video.mp4", size: Int64(data.count), sha256: nil, inline: nil)
        let clip = offer([video])
        var pasted: [ClipboardOfferSummary] = []
        inbox.onPasted = { summary, _ in pasted.append(summary) }
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        XCTAssertTrue(pasteboard.types?.contains(ClipboardInbox.transientType) == true,
                      "clipboard managers that honour nspasteboard.org do not pull a big item")
        XCTAssertTrue(fetches.isEmpty, "nothing moves until someone pastes")
        phoneSends(data, to: inbox, offerID: clip.offerId, index: 0) { self.fetches.first?.transferId ?? "" }

        let url = try readFromAnotherProcess("pb.stringForType('public.file-url').js")
        let file = try XCTUnwrap(URL(string: url))
        XCTAssertEqual(file.lastPathComponent, "video.mp4", "the original name")
        XCTAssertTrue(file.path.hasPrefix(cacheRoot.path), "into the clipboard cache, never Downloads")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(fetches.first?.offerId, clip.offerId)
        XCTAssertEqual(sent, ["fetch", "accept", "complete.ack"])
        XCTAssertEqual(pasted.map(\.fileName), ["video.mp4"])
        XCTAssertTrue(cache.isHandedOut(offerID: clip.offerId, index: 0))

        // A second paste is served from the cache.
        XCTAssertEqual(try readFromAnotherProcess("pb.stringForType('public.file-url').js"), url)
        XCTAssertEqual(fetches.count, 1)
    }

    @MainActor func testLongTextIsFetchedAsPlainText() throws {
        let inbox = makeInbox()
        let text = String(repeating: "Bridgey ", count: 6_000)
        let data = Data(text.utf8)
        let clip = offer([ClipboardOfferItem(index: 0, kind: .text, mime: "text/plain", name: nil, size: Int64(data.count), sha256: hash(data), inline: nil)])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        phoneSends(data, to: inbox, offerID: clip.offerId, index: 0) { self.fetches.first?.transferId ?? "" }
        XCTAssertEqual(try readFromAnotherProcess("pb.stringForType('public.utf8-plain-text').js.length"), String(text.count))
    }

    @MainActor func testDisconnectedPasteReturnsNothingAndReports() throws {
        let inbox = makeInbox(connected: false)
        var failures: [ClipboardPasteFailure] = []
        inbox.onPasteFailed = { failure, _ in failures.append(failure) }
        let clip = offer([ClipboardOfferItem(index: 0, kind: .file, mime: "application/pdf", name: "a.pdf", size: 5, sha256: nil, inline: nil)])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        XCTAssertEqual(try readFromAnotherProcess("var s = pb.stringForType('public.file-url'); s.isNil() ? 'nil' : s.js"), "nil")
        XCTAssertEqual(failures, [.notConnected])
        XCTAssertTrue(fetches.isEmpty)
    }

    @MainActor func testRefusedFetchReturnsNothing() throws {
        let inbox = makeInbox()
        var failures: [ClipboardPasteFailure] = []
        inbox.onPasteFailed = { failure, _ in failures.append(failure) }
        let clip = offer([ClipboardOfferItem(index: 0, kind: .file, mime: "application/pdf", name: "a.pdf", size: 5, sha256: nil, inline: nil)])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        pending.append {
            inbox.handleError(ClipboardErrorPayload(offerId: clip.offerId, index: 0, transferId: self.fetches[0].transferId, code: .changed))
        }
        XCTAssertEqual(try readFromAnotherProcess("var s = pb.stringForType('public.file-url'); s.isNil() ? 'nil' : s.js"), "nil")
        XCTAssertEqual(failures, [.refused(.changed)])
    }

    @MainActor func testWaitGivesUpWhenTheMainQueueCannotDrain() {
        let inbox = ClipboardInbox(cache: cache, pasteboard: pasteboard, showProgressAfter: 10, blockedAfter: 0.2)
        inbox.transport = ClipboardInboxTransport(isConnected: { true }, sendFetch: { _ in true }, sendCancel: { [unowned self] _ in self.sent.append("cancel") })
        inbox.spin = { _ in Thread.sleep(forTimeInterval: 0.02) }
        let clip = offer([ClipboardOfferItem(index: 0, kind: .file, mime: "application/pdf", name: "a.pdf", size: 5, sha256: nil, inline: nil)])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        let received = ClipboardInbox.Received(offer: clip, deviceID: "phone", peerName: "OnePlus 11")
        guard case .failure(.blocked) = inbox.waitForFile(received, index: 0) else { return XCTFail("expected blocked") }
        XCTAssertEqual(sent, ["cancel"])
    }

    @MainActor func testProgressPanelAppearsForSlowPastesAndCancelStops() {
        final class FakeProgress: ClipboardPasteProgress {
            var shown: String?
            var cancel: (() -> Void)?
            var hidden = false
            func show(peerName: String, onCancel: @escaping () -> Void) { shown = peerName; cancel = onCancel }
            func update(fraction: Double?) {}
            func hide() { hidden = true }
        }
        let inbox = makeInbox()
        let progress = FakeProgress()
        inbox.progress = progress
        var spins = 0
        inbox.spin = { _ in
            spins += 1
            Thread.sleep(forTimeInterval: 0.02)
            RunLoop.current.run(mode: .default, before: Date())
            if progress.shown != nil { progress.cancel?() }
        }
        let clip = offer([ClipboardOfferItem(index: 0, kind: .file, mime: "application/pdf", name: "a.pdf", size: 5, sha256: nil, inline: nil)])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        let received = ClipboardInbox.Received(offer: clip, deviceID: "phone", peerName: "OnePlus 11")
        guard case .failure(.cancelled) = inbox.waitForFile(received, index: 0) else { return XCTFail("expected cancelled") }
        XCTAssertEqual(progress.shown, "OnePlus 11")
        XCTAssertTrue(progress.hidden)
        XCTAssertGreaterThanOrEqual(spins, 10, "not shown before about 300 ms")
        XCTAssertEqual(sent.last, "cancel")
    }

    // MARK: Clipboard-purpose transfers

    @MainActor func testEagerPushGoesToTheCacheWithoutAnyFilesPath() throws {
        let inbox = makeInbox()
        let data = Data(repeating: 3, count: 30_000)
        let clip = offer([ClipboardOfferItem(index: 0, kind: .image, mime: "image/jpeg", name: nil, size: Int64(data.count), sha256: hash(data), inline: nil)])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        let transferID = UUID().uuidString.lowercased()
        XCTAssertTrue(inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID, name: "image.jpg", mimeType: "image/jpeg",
                                                                       size: Int64(data.count), sha256: hash(data), offerId: clip.offerId, index: 0),
                                                outerTransferID: transferID))
        XCTAssertTrue(inbox.owns(transferID))
        inbox.handleChunk(transferID: transferID, sequence: 0, data: data.prefix(24_576))
        inbox.handleChunk(transferID: transferID, sequence: 1, data: data.suffix(from: 24_576))
        inbox.handleComplete(transferID: transferID, sha256: hash(data))
        let cached = try XCTUnwrap(cache.cachedFile(offerID: clip.offerId, index: 0))
        XCTAssertTrue(cached.path.hasPrefix(cacheRoot.path))
        XCTAssertEqual(try Data(contentsOf: cached), data)
        XCTAssertEqual(sent, ["accept", "complete.ack"])
        XCTAssertFalse(cache.isHandedOut(offerID: clip.offerId, index: 0))
    }

    @MainActor func testPushesForUnknownOrSupersededOffersAreDeclined() {
        let inbox = makeInbox()
        let first = offer([ClipboardOfferItem(index: 0, kind: .image, mime: "image/png", name: nil, size: 10, sha256: nil, inline: nil)])
        inbox.accept(first, deviceID: "phone", peerName: "OnePlus 11")
        inbox.accept(offer(first.items), deviceID: "phone", peerName: "OnePlus 11")
        let transferID = UUID().uuidString
        XCTAssertFalse(inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID, name: "image.png", mimeType: "image/png",
                                                                        size: 10, sha256: nil, offerId: first.offerId, index: 0),
                                                 outerTransferID: transferID), "superseded")
        XCTAssertFalse(inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID, name: "image.png", mimeType: "image/png",
                                                                        size: 10, sha256: nil, offerId: UUID().uuidString, index: 0),
                                                 outerTransferID: transferID), "unknown")
        XCTAssertFalse(inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID, name: "image.png", mimeType: "image/png",
                                                                        size: 11, sha256: nil, offerId: inbox.current!.offer.offerId, index: 0),
                                                 outerTransferID: transferID), "size differs from the offer")
        XCTAssertEqual(sent, ["cancel", "cancel", "cancel"])
    }

    @MainActor func testCorruptTransfersAreDropped() {
        let inbox = makeInbox()
        let data = Data(repeating: 1, count: 100)
        let clip = offer([ClipboardOfferItem(index: 0, kind: .image, mime: "image/png", name: nil, size: 100, sha256: hash(data), inline: nil)])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        let transferID = UUID().uuidString
        inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID, name: "image.png", mimeType: "image/png", size: 100,
                                                         sha256: nil, offerId: clip.offerId, index: 0), outerTransferID: transferID)
        inbox.handleChunk(transferID: transferID, sequence: 0, data: Data(repeating: 2, count: 100))
        inbox.handleComplete(transferID: transferID, sha256: hash(Data(repeating: 2, count: 100)))
        XCTAssertNil(cache.cachedFile(offerID: clip.offerId, index: 0), "the hash in the offer wins")
        XCTAssertEqual(sent, ["accept", "cancel"])
        XCTAssertTrue(inbox.owns(transferID), "late chunks are still recognised and dropped quietly")
    }

    @MainActor func testNewOfferCancelsFetchesAndDropsUnusedItems() throws {
        let inbox = makeInbox()
        let clip = offer([
            ClipboardOfferItem(index: 0, kind: .image, mime: "image/png", name: nil, size: 10, sha256: nil, inline: nil),
            ClipboardOfferItem(index: 1, kind: .image, mime: "image/png", name: nil, size: 10, sha256: nil, inline: nil),
        ])
        inbox.accept(clip, deviceID: "phone", peerName: "OnePlus 11")
        let pasted = try cache.prepareItem(offerID: clip.offerId, index: 0, name: "image.png")
        FileManager.default.createFile(atPath: pasted.path, contents: Data([1]))
        cache.markHandedOut(offerID: clip.offerId, index: 0)
        let unused = try cache.prepareItem(offerID: clip.offerId, index: 1, name: "image.png")
        FileManager.default.createFile(atPath: unused.path, contents: Data([1]))
        let transferID = UUID().uuidString
        inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID, name: "image.png", mimeType: "image/png", size: 10,
                                                         sha256: nil, offerId: clip.offerId, index: 1), outerTransferID: transferID)
        // A push for an item already cached is declined; drop the cached copy to test the running one.
        try? FileManager.default.removeItem(at: unused)
        inbox.handleTransferOffer(ClipboardTransferOffer(transferId: transferID, name: "image.png", mimeType: "image/png", size: 10,
                                                         sha256: nil, offerId: clip.offerId, index: 1), outerTransferID: transferID)
        sent = []
        inbox.accept(offer(clip.items), deviceID: "phone", peerName: "OnePlus 11")
        XCTAssertEqual(sent, ["cancel"], "the running transfer of the old offer stops")
        XCTAssertNotNil(cache.cachedFile(offerID: clip.offerId, index: 0), "handed out: kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.deletingLastPathComponent().path), "never handed out: deleted")
    }

    @MainActor func testPasteboardWritesWaitForAPasteInProgress() {
        let inbox = makeInbox()
        var ran = false
        inbox.performPasteboardWrite { ran = true }
        XCTAssertTrue(ran, "no paste in progress: immediate")
    }

    // MARK: Sending side

    @MainActor private func makeOutbox(changeCount: @escaping () -> Int = { 1 }) -> (ClipboardOutbox, () -> [String]) {
        var log: [String] = []
        let outbox = ClipboardOutbox(cache: cache)
        outbox.available = { true }
        outbox.pasteboardChangeCount = changeCount
        outbox.transport = ClipboardOutboxTransport(
            isConnected: { true },
            sendEncrypted: { kind, payload, _ in
                if kind == "clipboard.error", let error = try? JSONDecoder().decode(ClipboardErrorPayload.self, from: payload) {
                    log.append("error:\(error.code.rawValue)")
                } else {
                    log.append(kind)
                }
                return true
            },
            sendCancel: { _ in log.append("cancel") },
            chunkSender: { nil }
        )
        return (outbox, { log })
    }

    @MainActor func testFetchesAreRefusedWithTheRightCode() throws {
        var changeCount = 1
        let (outbox, log) = makeOutbox(changeCount: { changeCount })
        let file = cacheRoot.appendingPathComponent("doc.pdf")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
        let (draft, sources) = try XCTUnwrap(ClipboardOfferBuilder.files([ClipboardFileRef(url: file, name: "doc.pdf", size: 3,
                                                                                           modified: values.contentModificationDate!, mime: "application/pdf")]))
        outbox.begin(offer: draft, sources: sources, changeCount: 1, deviceID: "phone")
        func fetch(_ offerID: String = draft.offerId, _ index: Int = 0) -> ClipboardFetchPayload {
            ClipboardFetchPayload(offerId: offerID, index: index, transferId: UUID().uuidString)
        }
        XCTAssertNil(outbox.refusal(for: fetch()))
        XCTAssertEqual(outbox.refusal(for: fetch(UUID().uuidString)), .expired)
        XCTAssertEqual(outbox.refusal(for: fetch(draft.offerId, 1)), .expired)
        changeCount = 2
        XCTAssertEqual(outbox.refusal(for: fetch()), .changed, "the Mac's clipboard changed since the offer")
        changeCount = 1
        try Data([1, 2, 3, 4]).write(to: file)
        XCTAssertEqual(outbox.refusal(for: fetch()), .changed, "the file changed since the offer")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(outbox.refusal(for: fetch()), .unavailable)
        outbox.available = { false }
        XCTAssertEqual(outbox.refusal(for: fetch()), .disabled)
        outbox.handleFetch(fetch())
        XCTAssertEqual(log(), ["error:disabled"])
    }

    @MainActor func testEagerPushesStartOneAtATimeWithinTheLimit() throws {
        let (outbox, log) = makeOutbox()
        let small = Data(repeating: 1, count: 20_000)
        let (draft, sources) = try XCTUnwrap(ClipboardOfferBuilder.images([
            ClipboardImageClip(data: small, mime: "image/png"), ClipboardImageClip(data: small, mime: "image/png"),
        ], cache: cache))
        outbox.begin(offer: draft, sources: sources, changeCount: 1, deviceID: "phone")
        outbox.startEagerPushes(limit: ClipboardEagerLimit.twentyFiveMB.bytes)
        XCTAssertEqual(log(), ["files.offer"], "pushes run one after another")
        XCTAssertEqual(outbox.activeCount, 1)
        outbox.supersede()
        XCTAssertEqual(log(), ["files.offer", "cancel"])
        XCTAssertEqual(outbox.activeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("outgoing/\(draft.offerId)").path),
                       "outgoing copies of a superseded offer are deleted")

        let (other, otherLog) = makeOutbox()
        let (again, againSources) = try XCTUnwrap(ClipboardOfferBuilder.images([ClipboardImageClip(data: small, mime: "image/png")], cache: cache))
        other.begin(offer: again, sources: againSources, changeCount: 1, deviceID: "phone")
        other.startEagerPushes(limit: ClipboardEagerLimit.askWhenPasting.bytes)
        XCTAssertEqual(otherLog(), [], "Always ask when pasting pushes nothing")
    }

    @MainActor func testOutgoingTransferHashesWhileStreamingWithAcknowledgements() throws {
        let data = Data((0..<200_000).map { UInt8($0 % 233) })
        let transfer = ClipboardOutgoingTransfer(transferID: "t", offerID: "o", index: 0, size: Int64(data.count), isFetch: true, source: .data(data))
        let collected = NSMutableData()
        let sender = ClipboardChunkSender { chunk, sequence, _ in
            collected.append(chunk)
            transfer.acknowledge(sequence: sequence)
            return true
        }
        let done = expectation(description: "streamed")
        var result: Result<String, ClipboardStreamError>?
        transfer.stream(with: sender) { value in
            result = value
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try result?.get(), hash(data))
        XCTAssertEqual(collected as Data, data)
    }

    @MainActor func testOutgoingTransferNoticesAFileThatGrew() throws {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let file = cacheRoot.appendingPathComponent("grow.bin")
        try Data(repeating: 1, count: 100).write(to: file)
        let transfer = ClipboardOutgoingTransfer(transferID: "t", offerID: "o", index: 0, size: 50, isFetch: true,
                                                 source: .original(file, size: 50, modified: Date()))
        let sender = ClipboardChunkSender { _, sequence, _ in transfer.acknowledge(sequence: sequence); return true }
        let done = expectation(description: "streamed")
        var result: Result<String, ClipboardStreamError>?
        transfer.stream(with: sender) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        guard case .failure(.changed) = result else { return XCTFail("expected changed, got \(String(describing: result))") }
    }

    // MARK: Coordinator wiring

    @MainActor func testClipboardTransfersBypassTheFilesFeatureAndFolder() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BridgeyMac/Pairing.swift"), encoding: .utf8)
        let offerCase = try XCTUnwrap(source.range(of: "case \"files.offer\":"))
        let body = source[offerCase.upperBound...].prefix(600)
        let clipboardCheck = try XCTUnwrap(body.range(of: "receiveClipboardTransferOffer"))
        let filesCheck = try XCTUnwrap(body.range(of: "featureEnabled(.files"))
        XCTAssertLessThan(clipboardCheck.lowerBound, filesCheck.lowerBound, "clipboard data never needs the Files feature")
        let handler = try XCTUnwrap(source.range(of: "private func receiveClipboardTransferOffer"))
        let handlerBody = source[handler.upperBound...].prefix(2_000)
        for forbidden in ["receiveDirectoryAccess", "beginFileTransferUI", "activateFileViewerSelecting", "incomingFiles["] {
            XCTAssertFalse(handlerBody.contains(forbidden), forbidden)
        }
        let inbox = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BridgeyMac/ClipboardInbox.swift"), encoding: .utf8)
        for forbidden in ["NSLog(", "print(", "receiveDirectoryAccess", "downloadsDirectory"] {
            XCTAssertFalse(inbox.contains(forbidden), forbidden)
        }
    }
}
