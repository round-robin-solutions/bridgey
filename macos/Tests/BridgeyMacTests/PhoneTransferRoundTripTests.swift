import Foundation
import XCTest
@testable import BridgeyMac

/// A whole phone for downloads and uploads: the browse client, the receiver and the sender of this Mac on one
/// side; on the other, a phone played by this Mac's folder sender (downloads) and receive session (uploads),
/// over queues, as a socket would carry the messages.
@MainActor
final class PhoneSim: PhoneFilesHost, FolderReceiverHost, FolderSenderHost {
    let phoneID = "22222222-2222-2222-2222-222222222222"
    let phoneQueue = DispatchQueue(label: "test.phone")
    let received: URL
    /// The phone's files for downloads, and its folder that uploads land in.
    let phoneFiles: URL
    let phoneInbox: URL
    var browsable = true
    var receiveMode: MacFolderReceiveMode = .fixed
    var policy: MacFolderConflictPolicy = .ask
    var tag = false
    nonisolated(unsafe) var allowUploads = true
    var overrideTransport: FolderTransport?
    private(set) var rows: [String: FileTransferRow] = [:]
    let history = TransferHistoryStore(fileURL: nil)
    var activities: [ActivityKind] = []

    lazy var controller = PhoneFilesController(host: self)
    lazy var receiver = FolderReceiver(host: self, journals: ReceiveJournalStore(directory: received.deletingLastPathComponent().appendingPathComponent("receive-journals")))
    lazy var sender = FolderSender(host: self, journals: FolderJournalStore(directory: received.deletingLastPathComponent().appendingPathComponent("send-journals")))
    lazy var macToPhone = MacToPhone(sim: self)

    // Phone side (phoneQueue only).
    nonisolated(unsafe) var phoneSender: FolderSendSession?
    nonisolated(unsafe) var phoneReceiver: FolderReceiveSession?
    nonisolated(unsafe) var phoneReceiveEvents = ReceiveRecorder()
    nonisolated(unsafe) var phoneSenderEvents = RecordingFolderEvents()

    init(base: URL) {
        received = base.appendingPathComponent("Received", isDirectory: true)
        phoneFiles = base.appendingPathComponent("PhoneFiles", isDirectory: true)
        phoneInbox = base.appendingPathComponent("PhoneInbox", isDirectory: true)
        for url in [received, phoneFiles, phoneInbox] { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    // PhoneFilesHost.
    func browseTransport(for phoneID: String) -> FolderTransport? { macToPhone }
    func browsePhones() -> [BrowsablePhone] { [BrowsablePhone(id: phoneID, name: "OnePlus 11", browsable: browsable, route: .lan)] }
    func expectDownload(_ download: ExpectedDownload) { receiver.expect(download) }
    func cancelDownload(_ download: ExpectedDownload) { receiver.cancelExpected(download) }
    func startUpload(_ upload: UploadRequest) -> String? { sender.upload(upload) }
    func cancelUpload(_ id: String) { sender.cancel(id) }

    // FolderReceiverHost and FolderSenderHost.
    func folderTransport(for phoneID: String) -> (transport: FolderTransport, session: ObjectIdentifier)? {
        let transport = overrideTransport ?? macToPhone
        return (transport, ObjectIdentifier(transport))
    }
    func folderSupport(for phoneID: String) -> (folders: Bool, places: Bool)? { (true, true) }
    func phoneName(_ phoneID: String) -> String { "OnePlus 11" }
    var folderReceiveMode: MacFolderReceiveMode { receiveMode }
    var folderConflictPolicy: MacFolderConflictPolicy { policy }
    var tagsReceivedFiles: Bool { tag }
    func receiveDirectoryAccess() -> ReceiveDirectoryAccess { ReceiveDirectoryAccess(url: received, scoped: false) }
    func folderRowChanged(_ row: FileTransferRow) { rows[row.id] = row }
    func folderRowRemoved(_ id: String) { rows.removeValue(forKey: id) }
    func folderStatus(_ text: String) {}
    func recordFolderActivity(_ kind: ActivityKind, phoneID: String, name: String, fileCount: Int, bytes: Int64, destination: String?, detail: FolderActivityDetail) {
        activities.append(kind)
    }
    func recordHistory(_ entry: TransferHistoryEntry) { history.record(entry) }
    var folderReduceMotion: Bool { true }
    var folderScanDefaults: FolderScanOptions { FolderScanOptions() }
    func enqueueFolder(_ id: String, phoneID: String) { DispatchQueue.main.async { self.sender.start(id) } }
    func folderEnded(_ id: String) {}

    /// Messages from this Mac to the phone: browse requests, download replies and upload messages.
    final class MacToPhone: SequencedFolderTransport, @unchecked Sendable {
        weak var sim: PhoneSim?
        let queue: DispatchQueue
        init(sim: PhoneSim) {
            self.sim = sim
            queue = sim.phoneQueue
        }

        private struct Completion: Decodable {
            let transferId: String
            let sha256: String
        }

        func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
            queue.async { [weak self] in self?.phone(kind: kind, payload: payload, transferID: transferID, sequence: sequence) }
            return true
        }

        func sendOuter(kind: String, transferID: String) { sendOuterSequenced(kind: kind, transferID: transferID, sequence: -1) }

        func sendOuterSequenced(kind: String, transferID: String, sequence: Int64) {
            queue.async { [weak self] in
                guard let sim = self?.sim else { return }
                switch kind {
                case "files.accept": sim.phoneSender?.fileAccepted(transferID)
                case "files.chunk.ack": sim.phoneSender?.chunkAcknowledged(transferID, sequence: sequence)
                case "files.complete.ack": sim.phoneSender?.completeAcknowledged(transferID)
                case FolderKind.cancelAck: sim.phoneSender?.receivedCancelAck()
                case "files.cancel": sim.phoneReceiver?.fileCancelled(transferID)
                default: break
                }
            }
        }

        /// The phone, on its own queue.
        private func phone(kind: String, payload: Data, transferID: String?, sequence: Int64?) {
            guard let sim else { return }
            let decoder = JSONDecoder()
            switch kind {
            case BrowseKind.placesDownload:
                guard let request = try? decoder.decode(PlacesDownloadPayload.self, from: payload) else { return }
                let urls = request.items.compactMap { ref -> URL? in
                    guard case let .place(_, path, name)? = ref.ref else { return nil }
                    return sim.phoneFiles.appendingPathComponent(path).appendingPathComponent(name)
                }
                let scan = hashedScan(items: urls)
                let id = UUID().uuidString.lowercased()
                let started = PlacesDownloadStartedPayload(requestId: request.requestId, folderTransferId: id, rootName: scan.rootName,
                                                           fileCount: scan.fileCount, folderCount: scan.folderCount, totalSize: scan.totalSize)
                let data = try! FolderJSON.encoder.encode(started)
                DispatchQueue.main.async { sim.controller.handle(kind: BrowseKind.placesDownloadStarted, payload: data, from: sim.phoneID) }
                var plan = FolderSendPlan(folderTransferID: id, scan: scan, destination: nil, resume: false, into: true)
                plan.downloadRequestId = request.requestId
                let session = FolderSendSession(plan: plan, transport: PhoneToMac(sim: sim), clock: DispatchFolderClock(queue: sim.phoneQueue),
                                                files: DiskFolderFileSource(sources: scan.sources), events: sim.phoneSenderEvents)
                sim.phoneSender = session
                session.start()
            // Download replies from the Mac's receiver.
            case FolderKind.accept: if let value = try? decoder.decode(FolderAcceptPayload.self, from: payload) { sim.phoneSender?.receivedAccept(value) }
            case FolderKind.waiting: if let value = try? decoder.decode(FolderWaitingPayload.self, from: payload) { sim.phoneSender?.receivedWaiting(value) }
            case FolderKind.rejected: if let value = try? decoder.decode(FolderRejectedPayload.self, from: payload) { sim.phoneSender?.receivedRejected(value) }
            case FolderKind.entryFailed: if let value = try? decoder.decode(FolderEntryFailedPayload.self, from: payload) { sim.phoneSender?.receivedEntryFailed(value) }
            case FolderKind.result: if let value = try? decoder.decode(FolderResultPayload.self, from: payload) { sim.phoneSender?.receivedResult(value) }
            // Uploads from the Mac's sender.
            case FolderKind.offer:
                guard let offer = try? decoder.decode(FolderOfferPayload.self, from: payload) else { return }
                if offer.isInto, !sim.allowUploads {
                    let rejected = FolderRejectedPayload(folderTransferId: offer.folderTransferId, code: FolderCode.readOnly, entry: nil, neededBytes: nil, freeBytes: nil)
                    let back = PhoneReceiverToMac(sim: sim)
                    _ = back.send(kind: FolderKind.rejected, payload: try! FolderJSON.encoder.encode(rejected), transferID: offer.folderTransferId, sequence: nil)
                    return
                }
                let plan = ReceivePlan(directory: sim.phoneInbox.appendingPathComponent(offer.destination?.path ?? ""), destinationLabel: "Inbox", policy: .merge,
                                       downloadRequestId: nil, purpose: nil, whereFrom: nil, displayName: offer.rootName)
                let session = FolderReceiveSession(offer: offer, peerID: "mac", peerName: "Mac", plan: plan, transport: PhoneReceiverToMac(sim: sim),
                                                   clock: DispatchFolderClock(queue: sim.phoneQueue), journals: nil, events: sim.phoneReceiveEvents)
                sim.phoneReceiver = session
                session.start()
            case FolderKind.manifest:
                if let page = try? decoder.decode(ManifestPagePayload.self, from: payload) { sim.phoneReceiver?.manifestPage(page, plaintextBytes: payload.count) }
            case "files.offer":
                if let offer = try? decoder.decode(FolderFileOfferPayload.self, from: payload) { sim.phoneReceiver?.fileOffer(offer) }
            case "files.chunk":
                if let transferID, let sequence { sim.phoneReceiver?.chunk(transferID, sequence: sequence, data: payload) }
            case "files.complete":
                if let done = try? decoder.decode(Completion.self, from: payload) { sim.phoneReceiver?.fileComplete(done.transferId, sha256: done.sha256) }
            case FolderKind.complete:
                if let done = try? decoder.decode(FolderCompletePayload.self, from: payload) { sim.phoneReceiver?.folderComplete(done) }
            case FolderKind.cancel:
                guard let cancel = try? decoder.decode(FolderCancelPayload.self, from: payload) else { return }
                if let receiver = sim.phoneReceiver, receiver.id == cancel.folderTransferId { receiver.cancelledBySender(cancel) } else { sim.phoneSender?.receivedCancel(cancel) }
            default:
                break
            }
        }
    }


    /// The phone's folder sender to this Mac's receiver (downloads), hopping to the main thread.
    final class PhoneToMac: FolderTransport, @unchecked Sendable {
        weak var sim: PhoneSim?
        init(sim: PhoneSim) { self.sim = sim }

        private struct Completion: Decodable {
            let transferId: String
            let sha256: String
        }

        func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
            DispatchQueue.main.async { [self] in
                guard let sim = self.sim else { return }
                let phoneID = sim.phoneID
                switch kind {
                case "files.offer": _ = sim.receiver.fileOffer(payload, from: phoneID)
                case "files.chunk": if let transferID, let sequence { _ = sim.receiver.chunk(transferID, sequence: sequence, data: payload, from: phoneID) }
                case "files.complete":
                    if let done = try? JSONDecoder().decode(Completion.self, from: payload) { _ = sim.receiver.fileComplete(done.transferId, sha256: done.sha256, from: phoneID) }
                default: _ = sim.receiver.receive(kind: kind, payload: payload, outerTransferID: transferID, from: phoneID)
                }
            }
            return true
        }

        func sendOuter(kind: String, transferID: String) {
            DispatchQueue.main.async { [self] in
                guard let sim = self.sim else { return }
                if kind == "files.cancel" { _ = sim.receiver.fileCancelled(transferID, from: sim.phoneID) } else {
                    _ = sim.receiver.receive(kind: kind, payload: nil, outerTransferID: transferID, from: sim.phoneID)
                }
            }
        }
    }

    /// The phone's receive session (uploads) back to this Mac's folder sender.
    final class PhoneReceiverToMac: SequencedFolderTransport, @unchecked Sendable {
        weak var sim: PhoneSim?
        init(sim: PhoneSim) { self.sim = sim }

        func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
            DispatchQueue.main.async { [self] in
                guard let sim = self.sim else { return }
                sim.sender.receive(kind: kind, payload: payload, outerTransferID: transferID, from: sim.phoneID)
            }
            return true
        }

        func sendOuter(kind: String, transferID: String) { deliver(kind, transferID, nil) }
        func sendOuterSequenced(kind: String, transferID: String, sequence: Int64) { deliver(kind, transferID, sequence) }

        private func deliver(_ kind: String, _ transferID: String, _ sequence: Int64?) {
            DispatchQueue.main.async { [self] in
                guard let sim = self.sim else { return }
                if !sim.sender.receiveFile(kind: kind, transferID: transferID, sequence: sequence, from: sim.phoneID) {
                    sim.sender.receive(kind: kind, payload: nil, outerTransferID: transferID, from: sim.phoneID)
                }
            }
        }
    }
}

@MainActor
final class PhoneTransferRoundTripTests: XCTestCase {
    private var base: URL!
    private var sim: PhoneSim!

    override func setUp() async throws {
        base = temporaryFolder("roundtrip")
        sim = PhoneSim(base: base)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testDownloadOfAFileAndAFolderIntoAFinderFolder() throws {
        try Data(repeating: 3, count: 150_000).write(to: sim.phoneFiles.appendingPathComponent("IMG_1.jpg"))
        let trip = try makeTree("Trip", files: ["a.txt": Data("a".utf8), "Day 1/b.txt": Data("b".utf8)], dirs: ["Empty"], in: sim.phoneFiles)
        let finder = base.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: finder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: finder.appendingPathComponent("IMG_1.jpg"))
        var progress: [PhoneTransferProgress] = []
        var result: Result<[URL], PhoneFilesError>?
        sim.controller.download(phoneID: sim.phoneID, refs: [.place(placeId: "default", path: "", name: "IMG_1.jpg"), .place(placeId: "default", path: "", name: "Trip")],
                                into: finder, purpose: .dragOut, progress: { progress.append($0) }, completion: { result = $0 })
        waitUntil { result != nil }
        let urls = try XCTUnwrap(try? result?.get())
        XCTAssertEqual(urls.map(\.lastPathComponent), ["IMG_1 (1).jpg", "Trip"])
        XCTAssertEqual(try Data(contentsOf: finder.appendingPathComponent("IMG_1.jpg")), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: urls[0]).count, 150_000)
        XCTAssertEqual(treeContents(urls[1]), treeContents(trip))
        XCTAssertEqual(FinderMetadata.whereFroms(urls[0]), ["Bridgey: OnePlus 11"])
        XCTAssertEqual(FinderMetadata.whereFroms(urls[1]), ["Bridgey: OnePlus 11"])
        XCTAssertEqual(progress.last?.bytesDone, 150_002)
        // One row with Show in Finder, one history entry marked as a download.
        waitUntil { self.sim.history.entries.count == 1 }
        let entry = try XCTUnwrap(sim.history.entries.first)
        XCTAssertEqual(entry.direction, .received)
        XCTAssertTrue(entry.download)
        XCTAssertEqual(entry.outcome, .completed)
        XCTAssertEqual(entry.fileCount, 3)
        XCTAssertNotNil(sim.rows.values.first?.localURL)
        XCTAssertEqual(sim.activities, [.folderReceived])
    }

    func testASingleFileDownloadIsAFileInHistory() throws {
        try Data("note".utf8).write(to: sim.phoneFiles.appendingPathComponent("note.txt"))
        var result: Result<[URL], PhoneFilesError>?
        sim.controller.download(phoneID: sim.phoneID, refs: [.place(placeId: "default", path: "", name: "note.txt")], into: base, purpose: .save,
                                progress: { _ in }, completion: { result = $0 })
        waitUntil { result != nil }
        // Save lands in Received files whatever folder was passed.
        XCTAssertEqual(try result?.get().first?.deletingLastPathComponent().standardizedFileURL, sim.received.standardizedFileURL)
        waitUntil { self.sim.history.entries.count == 1 }
        XCTAssertEqual(sim.history.entries.first?.isFolder, false)
        XCTAssertEqual(sim.history.entries.first?.name, "note.txt")
        XCTAssertEqual(sim.activities, [.fileReceived])
    }

    func testPreviewDownloadsLeaveNoRowsHistoryOrMetadata() throws {
        try Data("p".utf8).write(to: sim.phoneFiles.appendingPathComponent("p.txt"))
        let cache = base.appendingPathComponent("Preview", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var result: Result<[URL], PhoneFilesError>?
        sim.controller.download(phoneID: sim.phoneID, refs: [.place(placeId: "default", path: "", name: "p.txt")], into: cache, purpose: .preview,
                                progress: { _ in }, completion: { result = $0 })
        waitUntil { result != nil }
        let url = try XCTUnwrap(try? result?.get().first)
        XCTAssertEqual(try Data(contentsOf: url), Data("p".utf8))
        XCTAssertNil(FinderMetadata.whereFroms(url))
        XCTAssertTrue(sim.rows.isEmpty)
        XCTAssertTrue(sim.history.entries.isEmpty)
    }

    func testAnUnaskedIntoOfferIsRefused() throws {
        let id = UUID().uuidString.lowercased()
        let offer = FolderOfferPayload(folderTransferId: id, rootName: "x", fileCount: 1, folderCount: 0, totalSize: 1, pageCount: 1,
                                       manifestSha256: Data(count: 32).base64EncodedString(), destination: nil, resume: false, skipped: nil, into: true,
                                       downloadRequestId: UUID().uuidString.lowercased())
        var rejected: FolderRejectedPayload?
        sim.phoneSender = nil
        let recorder = Recorder()
        recorder.onRejected = { rejected = $0 }
        sim.overrideTransport = recorder
        XCTAssertTrue(sim.receiver.receive(kind: FolderKind.offer, payload: try FolderJSON.encoder.encode(offer), outerTransferID: id, from: sim.phoneID))
        XCTAssertEqual(rejected?.code, FolderCode.policy)
        XCTAssertTrue(sim.rows.isEmpty)
    }

    func testUploadLandsInThePhoneFolderAsCopies() throws {
        let local = base.appendingPathComponent("Mac", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let doc = local.appendingPathComponent("Report.pdf")
        try Data(repeating: 4, count: 80_000).write(to: doc)
        let folder = try makeTree("Slides", files: ["1.png": Data([1, 2, 3])], in: local)
        try Data("phone's".utf8).write(to: sim.phoneInbox.appendingPathComponent("Report.pdf"))
        var result: Result<Void, PhoneFilesError>?
        var progress: [PhoneTransferProgress] = []
        sim.controller.upload(phoneID: sim.phoneID, urls: [doc, folder], placeId: "default", path: "", progress: { progress.append($0) }, completion: { result = $0 })
        waitUntil { result != nil }
        XCTAssertNotNil(try? result?.get())
        XCTAssertEqual(try Data(contentsOf: sim.phoneInbox.appendingPathComponent("Report.pdf")), Data("phone's".utf8))
        XCTAssertEqual(try Data(contentsOf: sim.phoneInbox.appendingPathComponent("Report (1).pdf")).count, 80_000)
        XCTAssertEqual(try Data(contentsOf: sim.phoneInbox.appendingPathComponent("Slides/1.png")), Data([1, 2, 3]))
        XCTAssertFalse(progress.isEmpty)
        waitUntil { !self.sim.history.entries.isEmpty }
        XCTAssertEqual(sim.history.entries.first?.direction, .sent)
        XCTAssertEqual(sim.rows.values.first?.localURL, doc)
    }

    func testAnUploadToAReadOnlyPhoneFailsWithReadOnly() throws {
        sim.allowUploads = false
        let doc = base.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: doc)
        var result: Result<Void, PhoneFilesError>?
        sim.controller.upload(phoneID: sim.phoneID, urls: [doc], placeId: "default", path: "", progress: { _ in }, completion: { result = $0 })
        waitUntil { result != nil }
        guard case .failure(.code(FolderCode.readOnly))? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertTrue(sim.rows.values.first?.status.contains("doesn\u{2019}t allow changes") == true)
    }

    /// Captures what the receiver sends back for the unasked-offer test.
    final class Recorder: FolderTransport, @unchecked Sendable {
        var onRejected: ((FolderRejectedPayload) -> Void)?
        func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
            if kind == FolderKind.rejected, let value = try? JSONDecoder().decode(FolderRejectedPayload.self, from: payload) { onRejected?(value) }
            return true
        }
        func sendOuter(kind: String, transferID: String) {}
    }
}

