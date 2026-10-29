import Darwin
import Foundation
import XCTest
@testable import BridgeyMac

/// Phone to Mac and downloads: the Mac's receive session against the Mac's own folder sender playing the phone.
final class FolderReceiveSessionTests: XCTestCase {
    private var base: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        base = temporaryFolder("receive")
        destination = base.appendingPathComponent("Received", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func plan(_ policy: MacFolderConflictPolicy = .ask, directory: URL? = nil, download: String? = nil) -> ReceivePlan {
        ReceivePlan(directory: directory ?? destination, destinationLabel: "Received", policy: policy, downloadRequestId: download,
                    purpose: download == nil ? nil : .save, whereFrom: "Bridgey: OnePlus 11", displayName: "Photos")
    }

    private final class Run {
        let wire = FolderWire()
        let senderEvents = RecordingFolderEvents()
        let recorder = ReceiveRecorder()
        var scan: FolderScan!

        func wait(timeout: TimeInterval = 20) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let done = wire.queue.sync { !senderEvents.finished.isEmpty && !recorder.finished.isEmpty }
                if done { return }
                usleep(2_000)
            }
        }

        var outcome: ReceiveOutcome? { wire.queue.sync { recorder.finished.last?.0 } }
        var progress: ReceiveProgress? { wire.queue.sync { recorder.finished.last?.1 } }
        var senderOutcome: FolderOutcome? { wire.queue.sync { senderEvents.outcome } }
    }

    /// Starts a transfer of `scan` and returns at once; `run.wait()` blocks until both sides finished.
    @discardableResult
    private func start(_ scan: FolderScan, into: Bool = false, download: String? = nil, plan receivePlan: ReceivePlan,
                       journals: ReceiveJournalStore? = nil, id: String = UUID().uuidString.lowercased(), resume: Bool = false,
                       completed: Set<Int> = [], configure: ((Run) -> Void)? = nil) -> Run {
        let run = Run()
        run.scan = scan
        configure?(run)
        var sendPlan = FolderSendPlan(folderTransferID: id, scan: scan, destination: nil, resume: resume, into: into)
        sendPlan.downloadRequestId = download
        let wire = run.wire
        let recorder = run.recorder
        wire.makeReceiver = { offer in
            FolderReceiveSession(offer: offer, peerID: "phone-1", peerName: "OnePlus 11", plan: receivePlan, transport: wire.toSender,
                                 clock: DispatchFolderClock(queue: wire.queue), journals: journals, events: recorder)
        }
        let sender = FolderSendSession(plan: sendPlan, alreadyCompleted: completed, transport: wire.toReceiver, clock: DispatchFolderClock(queue: wire.queue),
                                       files: DiskFolderFileSource(sources: scan.sources), events: run.senderEvents)
        wire.sender = sender
        wire.queue.async { sender.start() }
        return run
    }

    private func photos() throws -> URL {
        try makeTree("Photos", files: [
            "a.txt": Data("alpha".utf8),
            "2019/b.jpg": Data(repeating: 7, count: 200_000),
            "2019/Beach/c.jpg": Data(repeating: 9, count: 3 * 24 * 1024 + 5),
        ], dirs: ["Empty", "2019/Beach/Deep"], in: base.appendingPathComponent("phone"))
    }

    func testAPushedFolderArrivesWholeWithEmptyFoldersAndWhereFrom() throws {
        let source = try photos()
        let run = start(hashedScan(source), plan: plan())
        run.wait()
        XCTAssertEqual(run.outcome, .complete)
        guard case let .done(result)? = run.senderOutcome else { return XCTFail("\(String(describing: run.senderOutcome))") }
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.savedFiles, 3)
        let saved = destination.appendingPathComponent("Photos")
        XCTAssertEqual(treeContents(saved), treeContents(source))
        XCTAssertEqual(FinderMetadata.whereFroms(saved.appendingPathComponent("2019/b.jpg")), ["Bridgey: OnePlus 11"])
        XCTAssertTrue(FinderMetadata.isQuarantined(saved), "the folder is marked as downloaded")
        XCTAssertTrue(FinderMetadata.isQuarantined(saved.appendingPathComponent("a.txt")))
        XCTAssertTrue(FinderMetadata.isQuarantined(saved.appendingPathComponent("2019/Beach/c.jpg")))
        XCTAssertEqual(run.progress?.savedURLs.map(\.lastPathComponent), ["Photos"])
        // No part files left behind.
        XCTAssertFalse(treeContents(destination).keys.contains { $0.hasSuffix(".bridgey-part") })
    }

    func testMergeKeepsClashingFilesAsCopies() throws {
        let source = try photos()
        try makeTree("Photos", files: ["a.txt": Data("old".utf8), "keep.txt": Data("mine".utf8)], in: destination)
        let run = start(hashedScan(source), plan: plan(.merge))
        run.wait()
        XCTAssertEqual(run.outcome, .complete)
        let saved = destination.appendingPathComponent("Photos")
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("a.txt")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("a (1).txt")), Data("alpha".utf8))
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("keep.txt")), Data("mine".utf8))
        XCTAssertEqual(run.progress?.renamedFiles, 1)
    }

    func testReplaceSwapsOnlyClashingFiles() throws {
        let source = try photos()
        try makeTree("Photos", files: ["a.txt": Data("old".utf8), "keep.txt": Data("mine".utf8)], in: destination)
        let run = start(hashedScan(source), plan: plan(.replace))
        run.wait()
        let saved = destination.appendingPathComponent("Photos")
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("a.txt")), Data("alpha".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("a (1).txt").path))
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("keep.txt")), Data("mine".utf8))
        XCTAssertEqual(run.progress?.replacedFiles, 1)
    }

    func testAskOnThisMacThenSaveAsNewFolder() throws {
        let source = try photos()
        try makeTree("Photos", files: ["x.txt": Data("x".utf8)], in: destination)
        let run = start(hashedScan(source), plan: plan(.ask)) { run in
            run.recorder.onConflict = { [weak run] question in
                XCTAssertEqual(question.choices, [.merge, .replace, .newFolder])
                XCTAssertEqual(question.newFolderName, "Photos (1)")
                XCTAssertEqual(question.clashingFiles, 0)
                run?.wire.queue.async { run?.wire.receiver?.answerConflict(.newFolder) }
            }
        }
        run.wait()
        XCTAssertEqual(run.outcome, .complete)
        XCTAssertEqual(run.wire.queue.sync { run.wire.toSenderKinds.contains(FolderKind.waiting) }, true)
        XCTAssertEqual(treeContents(destination.appendingPathComponent("Photos (1)")), treeContents(source))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Photos/x.txt")), Data("x".utf8))
    }

    func testAFileNamedLikeTheFolderOnlyAllowsANewFolder() throws {
        let source = try photos()
        try Data("file".utf8).write(to: destination.appendingPathComponent("photos"))
        let run = start(hashedScan(source), plan: plan(.merge))
        run.wait()
        XCTAssertEqual(run.outcome, .complete)
        XCTAssertEqual(run.progress?.rootName, "Photos (1)")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photos")), Data("file".utf8))
    }

    func testASymbolicLinkInTheDestinationIsNeverFollowed() throws {
        let source = try photos()
        let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Photos"), withDestinationURL: elsewhere)
        let run = start(hashedScan(source), plan: plan(.merge))
        run.wait()
        XCTAssertEqual(run.outcome, .complete)
        XCTAssertEqual(run.progress?.rootName, "Photos (1)")
        XCTAssertTrue(treeContents(elsewhere).isEmpty, "nothing was written through the link")
    }

    func testIntoDownloadsNeverMergeOrOverwrite() throws {
        let phone = base.appendingPathComponent("phone", isDirectory: true)
        let image = phone.appendingPathComponent("IMG.jpg")
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: image)
        let trip = try makeTree("Trip", files: ["t.txt": Data("trip".utf8)], in: phone)
        try Data("mine".utf8).write(to: destination.appendingPathComponent("IMG.jpg"))
        try makeTree("Trip", files: ["t.txt": Data("old trip".utf8)], in: destination)
        let id = UUID().uuidString.lowercased()
        let run = start(hashedScan(items: [image, trip]), into: true, download: id, plan: plan(.merge, download: id))
        run.wait()
        XCTAssertEqual(run.outcome, .complete)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("IMG.jpg")), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("IMG (1).jpg")).count, 1_000)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Trip/t.txt")), Data("old trip".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Trip (1)/t.txt")), Data("trip".utf8))
        XCTAssertEqual(Set(run.progress?.savedURLs.map(\.lastPathComponent) ?? []), ["IMG (1).jpg", "Trip (1)"])
    }

    func testResumeSkipsFinishedFilesAfterAnInterruption() throws {
        var files: [String: Data] = [:]
        for index in 0..<12 { files[String(format: "f%02d.bin", index)] = Data(repeating: UInt8(index), count: 60_000) }
        let source = try makeTree("Big", files: files, in: base.appendingPathComponent("phone"))
        let scan = hashedScan(source)
        let journals = ReceiveJournalStore(directory: base.appendingPathComponent("journals"))
        let id = UUID().uuidString.lowercased()
        let first = start(scan, plan: plan(.merge), journals: journals, id: id) { run in
            // Cut the line once five files are in place.
            let wire = run.wire
            run.recorder.onProgress = { progress in
                guard progress.filesDone >= 5, !wire.cut else { return }
                wire.cut = true
                wire.queue.async {
                    wire.receiver?.interrupt()
                    wire.sender?.interrupt()
                }
            }
        }
        first.wait()
        guard case .interrupted(resumable: true)? = first.outcome else { return XCTFail("\(String(describing: first.outcome))") }
        let record = try XCTUnwrap(journals.read(id))
        XCTAssertGreaterThanOrEqual(record.done.count, 5)
        // The phone resumes with the same ID; the Mac answers with its bitmap and only the rest arrives.
        let second = start(scan, plan: plan(.merge), journals: journals, id: id, resume: true, completed: [])
        second.wait()
        XCTAssertEqual(second.outcome, .complete)
        let offers = second.wire.queue.sync { second.wire.toReceiverKinds.filter { $0 == "files.offer" }.count }
        XCTAssertEqual(offers, 12 - record.done.count)
        XCTAssertEqual(treeContents(destination.appendingPathComponent("Big")), treeContents(source))
        XCTAssertNil(journals.read(id), "a finished folder drops its journal")
    }

    func testAResumeWithoutAMatchingJournalIsRefused() throws {
        let source = try photos()
        let run = start(hashedScan(source), plan: plan(), journals: ReceiveJournalStore(directory: base.appendingPathComponent("journals")), resume: true)
        run.wait()
        XCTAssertEqual(run.outcome, .cancelled(code: FolderCode.resumeUnavailable))
        guard case .rejected(code: FolderCode.resumeUnavailable, _, _)? = run.senderOutcome else { return XCTFail() }
    }

    func testFreeSpaceIsKnownForTheDestination() throws {
        // The receiver refuses a folder larger than the free space plus 64 MiB before writing anything.
        XCTAssertGreaterThan(FolderReceiveSession.freeBytes(destination) ?? 0, 0)
    }

    func testAskingForADestinationTimesOutAndCancels() throws {
        let (scan, _) = memoryScan(files: [("a.txt", Data("a".utf8))])
        let offer = FolderSendPlan(folderTransferID: UUID().uuidString.lowercased(), scan: scan, destination: nil, resume: false).offer
        let transport = FakeFolderTransport()
        let recorder = ReceiveRecorder()
        let clock = ManualFolderClock()
        var askPlan = plan()
        askPlan.directory = nil
        let session = FolderReceiveSession(offer: offer, peerID: "p", peerName: "Phone", plan: askPlan, transport: transport, clock: clock, journals: nil, events: recorder)
        session.start()
        session.manifestPage(ManifestPagePayload(folderTransferId: offer.folderTransferId, page: 0, entries: scan.entries), plaintextBytes: 500)
        XCTAssertEqual(recorder.destinationAsks.count, 1)
        XCTAssertEqual(transport.decode(FolderWaitingPayload.self, transport.of(FolderKind.waiting)[0]).reason, "destination")
        clock.advance(179)
        XCTAssertTrue(recorder.finished.isEmpty)
        clock.advance(2)
        XCTAssertEqual(recorder.finished.last?.0, .timedOut)
        XCTAssertEqual(transport.decode(FolderCancelPayload.self, transport.of(FolderKind.cancel)[0]).code, FolderCode.timeout)
        XCTAssertTrue(treeContents(destination).isEmpty)
    }

    func testAnAnsweredDestinationLandsThere() throws {
        let (scan, contents) = memoryScan(files: [("a.txt", Data("a".utf8))])
        let offer = FolderSendPlan(folderTransferID: UUID().uuidString.lowercased(), scan: scan, destination: nil, resume: false).offer
        let transport = FakeFolderTransport()
        let recorder = ReceiveRecorder()
        var askPlan = plan()
        askPlan.directory = nil
        let session = FolderReceiveSession(offer: offer, peerID: "p", peerName: "Phone", plan: askPlan, transport: transport, clock: ManualFolderClock(), journals: nil, events: recorder)
        session.start()
        session.manifestPage(ManifestPagePayload(folderTransferId: offer.folderTransferId, page: 0, entries: scan.entries), plaintextBytes: 500)
        let chosen = base.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        session.answerDestination(chosen)
        XCTAssertEqual(transport.decode(FolderAcceptPayload.self, transport.of(FolderKind.accept)[0]).destinationLabel, ReceiveLabels.label(for: chosen))
        let fileID = UUID().uuidString.lowercased()
        session.fileOffer(FolderFileOfferPayload(transferId: fileID, name: "a.txt", mimeType: "text/plain", size: 1, sha256: scan.entries[0].sha256!,
                                                 folderTransferId: offer.folderTransferId, entry: 0, path: "a.txt"))
        session.chunk(fileID, sequence: 0, data: contents[0]!)
        session.fileComplete(fileID, sha256: scan.entries[0].sha256!)
        session.folderComplete(FolderCompletePayload(folderTransferId: offer.folderTransferId, sentFiles: 1, failedCount: 0, failed: []))
        XCTAssertEqual(recorder.finished.last?.0, .complete)
        XCTAssertEqual(try Data(contentsOf: chosen.appendingPathComponent("Photos/a.txt")), Data("a".utf8))
        // Outer acknowledgements, the chunk's with its sequence.
        XCTAssertEqual(transport.of("files.chunk.ack").count, 1)
    }

    func testAChunkOutOfOrderFailsTheFileAndTheFolderGoesOn() throws {
        let (scan, contents) = memoryScan(files: [("a.txt", Data("aaaa".utf8)), ("b.txt", Data("b".utf8))])
        let offer = FolderSendPlan(folderTransferID: UUID().uuidString.lowercased(), scan: scan, destination: nil, resume: false).offer
        let transport = FakeFolderTransport()
        let recorder = ReceiveRecorder()
        let session = FolderReceiveSession(offer: offer, peerID: "p", peerName: "Phone", plan: plan(), transport: transport, clock: ManualFolderClock(), journals: nil, events: recorder)
        session.start()
        session.manifestPage(ManifestPagePayload(folderTransferId: offer.folderTransferId, page: 0, entries: scan.entries), plaintextBytes: 500)
        let first = UUID().uuidString.lowercased()
        session.fileOffer(FolderFileOfferPayload(transferId: first, name: "a.txt", mimeType: "text/plain", size: 4, sha256: scan.entries[0].sha256!,
                                                 folderTransferId: offer.folderTransferId, entry: 0, path: "a.txt"))
        session.chunk(first, sequence: 1, data: contents[0]!)
        XCTAssertEqual(transport.decode(FolderEntryFailedPayload.self, transport.of(FolderKind.entryFailed)[0]).code, FolderCode.invalidMessage)
        let second = UUID().uuidString.lowercased()
        session.fileOffer(FolderFileOfferPayload(transferId: second, name: "b.txt", mimeType: "text/plain", size: 1, sha256: scan.entries[1].sha256!,
                                                 folderTransferId: offer.folderTransferId, entry: 1, path: "b.txt"))
        session.chunk(second, sequence: 0, data: contents[1]!)
        session.fileComplete(second, sha256: scan.entries[1].sha256!)
        session.folderComplete(FolderCompletePayload(folderTransferId: offer.folderTransferId, sentFiles: 2, failedCount: 0, failed: []))
        XCTAssertEqual(recorder.finished.last?.0, .incomplete(code: nil))
        let result = transport.decode(FolderResultPayload.self, transport.of(FolderKind.result)[0])
        XCTAssertEqual(result.savedFiles, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Photos/a.txt").path))
        XCTAssertFalse(treeContents(destination).keys.contains { $0.hasSuffix(".bridgey-part") })
    }

    func testABadManifestIsRejected() throws {
        let (scan, _) = memoryScan(files: [("a.txt", Data("a".utf8))])
        let offer = FolderSendPlan(folderTransferID: UUID().uuidString.lowercased(), scan: scan, destination: nil, resume: false).offer
        let transport = FakeFolderTransport()
        let session = FolderReceiveSession(offer: offer, peerID: "p", peerName: "Phone", plan: plan(), transport: transport, clock: ManualFolderClock(),
                                           journals: nil, events: ReceiveRecorder())
        session.start()
        session.manifestPage(ManifestPagePayload(folderTransferId: offer.folderTransferId, page: 0, entries: [.file("../escape.txt", size: 1, sha256: scan.entries[0].sha256!)]),
                             plaintextBytes: 200)
        XCTAssertEqual(transport.decode(FolderRejectedPayload.self, transport.of(FolderKind.rejected)[0]).code, FolderCode.invalidManifest)
    }

    // MARK: Journal

    func testJournalIsOwnerOnlyAndCleansUpPartFiles() throws {
        let store = ReceiveJournalStore(directory: base.appendingPathComponent("journals"))
        let id = UUID().uuidString.lowercased()
        let header = ReceiveJournalHeader(folderTransferId: id, peerID: "p", peerName: "Phone", manifestSha256: "x", createdAt: BrowseTime.date(BrowseTime.millis(Date())), directoryPath: destination.path,
                                          rootPath: destination.path, rootName: "R", choice: .none, into: true, downloadRequestId: nil, purpose: "save",
                                          destinationLabel: "Received", topNames: ["IMG.jpg": "IMG (1).jpg"], fileCount: 2, totalSize: 3, displayName: "R")
        let writer = try XCTUnwrap(store.create(header))
        let part = destination.appendingPathComponent(".a b.txt.bridgey-part")
        try Data("partial".utf8).write(to: part)
        writer.dir(0, destination.appendingPathComponent("Sub folder"))
        writer.part(1, part)
        writer.done(2)
        writer.close()
        var info = stat()
        XCTAssertEqual(stat(base.appendingPathComponent("journals/\(id).journal").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(base.appendingPathComponent("journals").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let record = try XCTUnwrap(store.read(id))
        XCTAssertEqual(record.header, header)
        XCTAssertEqual(record.dirs[0], destination.appendingPathComponent("Sub folder").path)
        XCTAssertEqual(record.done, [2])
        XCTAssertEqual(store.recover().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "an unfinished part file goes on start")
    }

    func testOldJournalsAreDroppedOnStart() throws {
        let store = ReceiveJournalStore(directory: base.appendingPathComponent("journals"))
        let id = UUID().uuidString.lowercased()
        let header = ReceiveJournalHeader(folderTransferId: id, peerID: "p", peerName: "Phone", manifestSha256: "x", createdAt: Date(timeIntervalSinceNow: -90_000),
                                          directoryPath: "/tmp", rootPath: "/tmp", rootName: "R", choice: .none, into: false, downloadRequestId: nil,
                                          purpose: nil, destinationLabel: "", topNames: [:], fileCount: 0, totalSize: 0, displayName: "R")
        store.create(header)?.close()
        XCTAssertTrue(store.recover(now: Date().addingTimeInterval(25 * 3_600)).isEmpty)
        XCTAssertNil(store.read(id))
    }
}
