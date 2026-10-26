import Foundation
import XCTest
@testable import BridgeyMac

final class FolderSendSessionTests: XCTestCase {
    private let folderID = "4b0c9d5e-0000-4000-8000-000000000001"
    private var transport: FakeFolderTransport!
    private var clock: ManualFolderClock!
    private var events: RecordingFolderEvents!
    private var ids: SequentialIDs!
    private var files: MemoryFolderFiles!
    private var ownership: FolderFileOwnership!

    override func setUp() {
        transport = FakeFolderTransport()
        clock = ManualFolderClock()
        events = RecordingFolderEvents()
        ids = SequentialIDs()
        ownership = FolderFileOwnership()
    }

    private func session(_ scan: FolderScan, contents: [Int: Data], destination: FolderDestination? = FolderDestination(placeId: "default", path: "Trip"),
                         resume: Bool = false, done: Set<Int> = []) -> FolderSendSession {
        files = MemoryFolderFiles(contents: contents)
        let plan = FolderSendPlan(folderTransferID: folderID, scan: scan, destination: destination, resume: resume)
        return FolderSendSession(plan: plan, alreadyCompleted: done, transport: transport, clock: clock, files: files, events: events,
                                 fileOwnership: ownership, makeID: ids.make)
    }

    private func accept(_ session: FolderSendSession, bitmap: String? = nil, choice: ConflictChoice = .none) {
        session.receivedAccept(FolderAcceptPayload(folderTransferId: folderID, rootName: "Photos", destinationLabel: "Pictures/Trip", choice: choice, completedBitmap: bitmap))
    }

    private func bytes(_ count: Int, _ seed: UInt8 = 1) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed }) }

    private var threeFiles: (FolderScan, [Int: Data]) {
        memoryScan(dirs: ["2019", "2019/Empty"], files: [("2019/a.jpg", bytes(10)), ("b.txt", bytes(30_000, 2)), ("c.txt", Data())])
    }

    // MARK: Offer

    func testOfferThenEveryManifestPageWithTheFolderIDOutside() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        XCTAssertEqual(transport.kinds, [FolderKind.offer, FolderKind.manifest])
        let offerMessage = transport.messages[0]
        XCTAssertEqual(offerMessage.transferID, folderID)
        let offer = transport.decode(FolderOfferPayload.self, offerMessage)
        XCTAssertEqual(offer.fileCount, 3)
        XCTAssertEqual(offer.folderCount, 2)
        XCTAssertEqual(offer.totalSize, 30_010)
        XCTAssertEqual(offer.pageCount, 1)
        XCTAssertFalse(offer.resume)
        XCTAssertEqual(offer.destination, FolderDestination(placeId: "default", path: "Trip"))
        XCTAssertEqual(offer.manifestSha256, ManifestDigest.compute(rootName: "Photos", entries: scan.entries))
        let page = transport.decode(ManifestPagePayload.self, transport.messages[1])
        XCTAssertEqual(page.page, 0)
        // Siblings by UTF-8 bytes: "Empty" before "a.jpg".
        XCTAssertEqual(page.entries.map(\.path), ["2019", "2019/Empty", "2019/a.jpg", "b.txt", "c.txt"])
        XCTAssertNil(transport.messages[1].transferID)
    }

    func testEmptyFolderIsAnOfferWithoutPagesAndCompletesAtOnce() {
        let (scan, contents) = memoryScan()
        let session = session(scan, contents: contents, destination: nil)
        session.start()
        XCTAssertEqual(transport.kinds, [FolderKind.offer])
        let offer = transport.decode(FolderOfferPayload.self, transport.messages[0])
        XCTAssertEqual(offer.pageCount, 0)
        XCTAssertNil(offer.destination)
        accept(session)
        XCTAssertEqual(transport.kinds.last, FolderKind.complete)
        let complete = transport.decode(FolderCompletePayload.self, transport.messages.last!)
        XCTAssertEqual(complete.sentFiles, 0)
        XCTAssertEqual(complete.failedCount, 0)
    }

    func testNoAnswerWithinFifteenSecondsCancelsWithTimeout() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        clock.advance(14.9)
        XCTAssertFalse(transport.kinds.contains(FolderKind.cancel))
        clock.advance(0.2)
        let cancel = transport.decode(FolderCancelPayload.self, transport.of(FolderKind.cancel)[0])
        XCTAssertEqual(cancel.reason, "timeout")
        XCTAssertEqual(cancel.code, "timeout")
        XCTAssertEqual(transport.of(FolderKind.cancel)[0].transferID, folderID)
        session.receivedCancelAck()
        XCTAssertEqual(events.outcome, .noAnswer)
    }

    // MARK: Waiting and the conflict question

    func testWaitingShowsTheCountdownAndRestartsTheWait() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents, destination: nil)
        session.start()
        clock.advance(10)
        session.receivedWaiting(FolderWaitingPayload(folderTransferId: folderID, reason: "destination", timeoutSeconds: 180))
        XCTAssertEqual(session.phase, .waiting(reason: "destination", deadline: clock.now.addingTimeInterval(180)))
        let summary = FolderRowSummary(phoneName: "OnePlus 11", displayName: "Photos", state: .running, progress: events.progress.last!)
        XCTAssertEqual(FolderText.status(summary, now: clock.now.addingTimeInterval(19)), "Waiting for OnePlus 11: choose where to save (2:41)")
        clock.advance(194)
        XCTAssertFalse(transport.kinds.contains(FolderKind.cancel), "the sender waits 195 s on a remote question")
        // The reason changes: the wait starts again.
        session.receivedWaiting(FolderWaitingPayload(folderTransferId: folderID, reason: "conflict", timeoutSeconds: 180))
        clock.advance(194)
        XCTAssertFalse(transport.kinds.contains(FolderKind.cancel))
        clock.advance(1.1)
        XCTAssertEqual(transport.decode(FolderCancelPayload.self, transport.of(FolderKind.cancel)[0]).code, "timeout")
    }

    func testConflictAsksOnThisMacAndSendsTheAnswer() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        let conflict = FolderConflictPayload(folderTransferId: folderID, existing: "folder", clashingFiles: 12, clashingFolders: 3,
                                             newFolderName: "Photos (1)", choices: [.merge, .replace, .newFolder], timeoutSeconds: 180)
        session.receivedConflict(conflict)
        XCTAssertEqual(events.questions.count, 1)
        XCTAssertEqual(events.questions[0].1, clock.now.addingTimeInterval(180))
        clock.advance(60)
        session.resolve(.merge)
        let resolve = transport.decode(FolderResolvePayload.self, transport.of(FolderKind.resolve)[0])
        XCTAssertEqual(resolve.choice, .merge)
        XCTAssertEqual(events.questionsClosed, 1)
        accept(session, choice: .merge)
        XCTAssertEqual(session.phase, .sending)
        XCTAssertEqual(events.accepted.first?.choice, .merge)
        XCTAssertEqual(FolderText.conflictMessage(conflict, name: "Photos", destination: "Pictures/Trip", totalFiles: 124),
                       "\u{201C}Photos\u{201D} already exists in Pictures/Trip. 12 of 124 files have the same names.")
        let unknown = FolderConflictPayload(folderTransferId: folderID, existing: "folder", clashingFiles: nil, clashingFolders: nil,
                                            newFolderName: "Photos (1)", choices: [.merge], timeoutSeconds: 180)
        XCTAssertTrue(FolderText.conflictMessage(unknown, name: "Photos", destination: "Pictures/Trip", totalFiles: 124).hasSuffix("Some files may have the same names."))
    }

    func testUnansweredQuestionCancelsAfterThreeMinutes() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        session.receivedConflict(FolderConflictPayload(folderTransferId: folderID, existing: "file", clashingFiles: nil, clashingFolders: nil,
                                                       newFolderName: "Photos (1)", choices: [.newFolder], timeoutSeconds: 180))
        clock.advance(179)
        XCTAssertTrue(transport.of(FolderKind.cancel).isEmpty)
        clock.advance(1)
        let cancel = transport.decode(FolderCancelPayload.self, transport.of(FolderKind.cancel)[0])
        XCTAssertEqual(cancel.reason, "timeout")
        XCTAssertEqual(cancel.code, "timeout")
        XCTAssertEqual(events.questionsClosed, 1)
        // No acknowledgement: resent twice 5 s apart, then treated as cancelled.
        clock.advance(10)
        XCTAssertEqual(transport.of(FolderKind.cancel).count, 3)
        XCTAssertNil(events.outcome)
        clock.advance(5)
        XCTAssertEqual(events.outcome, .questionTimedOut)
        // A late answer does nothing.
        session.resolve(.newFolder)
        XCTAssertTrue(transport.of(FolderKind.resolve).isEmpty)
    }

    func testCancelOnTheQuestionEndsHere() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        session.receivedConflict(FolderConflictPayload(folderTransferId: folderID, existing: "folder", clashingFiles: 1, clashingFolders: 0,
                                                       newFolderName: "Photos (1)", choices: [.merge, .newFolder], timeoutSeconds: 180))
        session.resolve(.cancel)
        XCTAssertEqual(transport.decode(FolderResolvePayload.self, transport.of(FolderKind.resolve)[0]).choice, .cancel)
        XCTAssertEqual(events.outcome, .cancelledHere)
    }

    func testRejectionsEndTheTransferAndSayWhy() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        session.receivedRejected(FolderRejectedPayload(folderTransferId: folderID, code: "insufficient_space", entry: nil, neededBytes: 2_000_000_000, freeBytes: 1_000_000_000))
        XCTAssertEqual(events.outcome, .rejected(code: "insufficient_space", neededBytes: 2_000_000_000, freeBytes: 1_000_000_000))
        let words = FolderText.rejection(code: "insufficient_space", phone: "OnePlus 11", needed: 2_000_000_000, free: 1_000_000_000)
        XCTAssertTrue(words.hasPrefix("Not enough space on OnePlus 11: needs "), words)
        XCTAssertEqual(FolderText.rejection(code: "busy", phone: "OnePlus 11", needed: nil, free: nil), "OnePlus 11 is busy with another folder. Try again in a moment.")
        XCTAssertEqual(FolderText.rejection(code: "resume_unavailable", phone: "OnePlus 11", needed: nil, free: nil), "OnePlus 11 can\u{2019}t resume this folder. Send it again.")
        XCTAssertEqual(FolderText.rejection(code: "place_unavailable", phone: "OnePlus 11", needed: nil, free: nil), "That folder is no longer available on OnePlus 11")
        XCTAssertEqual(FolderText.rejection(code: "not_found", phone: "OnePlus 11", needed: nil, free: nil), "That folder no longer exists on OnePlus 11")
    }

    func testOuterOnlyRejectionMeansFilesIsOff() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        session.receivedPolicyRejection()
        XCTAssertEqual(events.outcome, .filesOff)
    }

    func testPhoneCancelIsAcknowledgedAndWorded() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents, destination: nil)
        session.start()
        session.receivedCancel(FolderCancelPayload(folderTransferId: folderID, reason: "timeout", code: "timeout"))
        XCTAssertEqual(transport.messages.last?.kind, FolderKind.cancelAck)
        XCTAssertNil(transport.messages.last?.payload)
        XCTAssertEqual(transport.messages.last?.transferID, folderID)
        XCTAssertEqual(events.outcome, .cancelledByPhone(reason: "timeout"))
        let progress = FolderProgress()
        XCTAssertEqual(FolderText.outcome(.cancelledByPhone(reason: "timeout"), name: "Photos", phone: "OnePlus 11", destination: nil, progress: progress),
                       "Cancelled: nobody chose a folder on OnePlus 11")
        XCTAssertEqual(FolderText.outcome(.cancelledByPhone(reason: "user"), name: "Photos", phone: "OnePlus 11", destination: nil, progress: progress),
                       "Cancelled on OnePlus 11")
    }

    // MARK: Files

    func testFilesGoOutInManifestOrderWithoutWaitingForAccept() throws {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        transport.clear()
        accept(session)
        let offers = transport.of("files.offer").map { transport.decode(FolderFileOfferPayload.self, $0) }
        XCTAssertEqual(offers.map(\.entry), [2, 3, 4])
        XCTAssertEqual(offers.map(\.path), ["2019/a.jpg", "b.txt", "c.txt"])
        XCTAssertEqual(offers.map(\.name), ["a.jpg", "b.txt", "c.txt"])
        XCTAssertEqual(offers.map(\.folderTransferId), [folderID, folderID, folderID])
        XCTAssertEqual(Set(offers.map(\.transferId)).count, 3)
        XCTAssertEqual(offers[0].sha256, scan.entries[2].sha256)
        XCTAssertEqual(offers[0].mimeType, "image/jpeg")
        for (message, offer) in zip(transport.of("files.offer"), offers) {
            XCTAssertEqual(message.transferID, offer.transferId)
            XCTAssertEqual(ownership.folder(of: offer.transferId), folderID)
        }
        // Without any files.accept: a.jpg (1 chunk), b.txt (2 chunks), c.txt (empty, no chunk).
        XCTAssertEqual(transport.kinds, ["files.offer", "files.chunk", "files.complete",
                                         "files.offer", "files.chunk", "files.chunk", "files.complete",
                                         "files.offer", "files.complete"])
        let chunks = transport.of("files.chunk")
        XCTAssertEqual(chunks.map(\.sequence), [0, 0, 1])
        XCTAssertEqual(chunks[1].payload! + chunks[2].payload!, contents[3])
        let complete = transport.decode(FileCompleteProbe.self, transport.of("files.complete")[1])
        XCTAssertEqual(complete.transferId, offers[1].transferId)
        XCTAssertEqual(complete.sha256, offers[1].sha256)
        XCTAssertEqual(transport.of("files.complete")[1].transferID, offers[1].transferId)
        // files.accept is tolerated; the folder completes after every files.complete.ack.
        offers.forEach { session.fileAccepted($0.transferId) }
        XCTAssertFalse(transport.kinds.contains(FolderKind.complete))
        offers.forEach { session.completeAcknowledged($0.transferId) }
        let done = transport.decode(FolderCompletePayload.self, transport.of(FolderKind.complete)[0])
        XCTAssertEqual(done.sentFiles, 3)
        XCTAssertEqual(done.failed, [])
        XCTAssertEqual(events.completed.last, [2, 3, 4])
        XCTAssertEqual(session.progress.recent, ["2019/a.jpg", "b.txt", "c.txt"])
    }

    func testAtMostSixtyFourChunksAreUnacknowledgedAcrossTheFolder() {
        let chunk = FolderSendSession.chunkSize
        let (scan, contents) = memoryScan(files: [("big.bin", bytes(chunk * 100)), ("small.bin", bytes(10))])
        let session = session(scan, contents: contents)
        session.start()
        transport.clear()
        accept(session)
        XCTAssertEqual(transport.of("files.chunk").count, 64)
        let big = transport.of("files.offer")[0].transferID!
        session.chunkAcknowledged(big, sequence: 9)
        XCTAssertEqual(transport.of("files.chunk").count, 74)
        session.chunkAcknowledged(big, sequence: 73)
        // big.bin's last chunks go out, then small.bin follows straight away, before big.bin is acknowledged.
        XCTAssertEqual(transport.of("files.chunk").filter { $0.transferID == big }.count, 100)
        XCTAssertEqual(transport.of("files.offer").count, 2)
        XCTAssertEqual(transport.of("files.chunk").count, 101)
        XCTAssertEqual(transport.kinds.filter { $0 == "files.complete" }.count, 2)
        // Chunks of different files never interleave.
        var seen: [String] = []
        for message in transport.messages where message.kind == "files.chunk" {
            if seen.last != message.transferID {
                XCTAssertFalse(seen.contains(message.transferID!))
                seen.append(message.transferID!)
            }
        }
    }

    func testAtMostThirtyTwoFilesAwaitCompletion() {
        let (scan, contents) = memoryScan(files: (0..<40).map { (String(format: "f%02d.txt", $0), bytes(5, UInt8($0))) })
        let session = session(scan, contents: contents)
        session.start()
        transport.clear()
        accept(session)
        XCTAssertEqual(transport.of("files.offer").count, 32)
        XCTAssertEqual(transport.of("files.complete").count, 32)
        let first = transport.of("files.offer")[0].transferID!
        session.chunkAcknowledged(first, sequence: 0)
        XCTAssertEqual(transport.of("files.offer").count, 32, "a chunk acknowledgement does not free a completion slot")
        session.completeAcknowledged(first)
        XCTAssertEqual(transport.of("files.offer").count, 33)
    }

    func testEntryFailedStopsThatFileAndCarriesOn() {
        let chunk = FolderSendSession.chunkSize
        let (scan, contents) = memoryScan(files: [("a.bin", bytes(chunk * 80)), ("b.txt", bytes(10))])
        let session = session(scan, contents: contents)
        session.start()
        transport.clear()
        accept(session)
        let a = transport.of("files.offer")[0].transferID!
        XCTAssertEqual(transport.of("files.chunk").count, 64)
        session.receivedEntryFailed(FolderEntryFailedPayload(folderTransferId: folderID, entry: 0, transferId: a, code: "io_error"))
        XCTAssertEqual(transport.of("files.chunk").filter { $0.transferID == a }.count, 64, "no more chunks of the failed file")
        XCTAssertEqual(transport.of("files.offer").count, 2)
        let b = transport.of("files.offer")[1].transferID!
        session.completeAcknowledged(b)
        let complete = transport.decode(FolderCompletePayload.self, transport.of(FolderKind.complete)[0])
        XCTAssertEqual(complete.sentFiles, 1)
        XCTAssertEqual(complete.failedCount, 0, "folders.complete lists sender-side failures only")
        XCTAssertEqual(session.progress.failures, [FolderFailure(entry: 0, path: "a.bin", code: "io_error")])
        XCTAssertEqual(FolderText.failureReason("io_error"), "Could not be saved")
    }

    func testAFileChangedSinceTheScanIsCancelledAndReportedAsSourceChanged() {
        let (scan, contents) = memoryScan(files: [("a.txt", bytes(100)), ("b.txt", bytes(10))])
        let session = session(scan, contents: contents)
        files.override[0] = bytes(100, 9)
        session.start()
        transport.clear()
        accept(session)
        let a = transport.of("files.offer")[0].transferID!
        XCTAssertEqual(transport.messages.first { $0.transferID == a && $0.kind == "files.cancel" }?.payload, nil)
        XCTAssertTrue(transport.messages.contains { $0.transferID == a && $0.kind == "files.cancel" })
        XCTAssertFalse(transport.messages.contains { $0.transferID == a && $0.kind == "files.complete" })
        session.completeAcknowledged(transport.of("files.offer")[1].transferID!)
        let complete = transport.decode(FolderCompletePayload.self, transport.of(FolderKind.complete)[0])
        XCTAssertEqual(complete.failed, [FailedEntry(entry: 0, code: "source_changed")])
        XCTAssertEqual(complete.failedCount, 1)
        XCTAssertEqual(complete.sentFiles, 1)
    }

    func testAShorterFileIsCaughtWhileReading() {
        let (scan, contents) = memoryScan(files: [("a.txt", bytes(100))])
        let session = session(scan, contents: contents)
        files.override[0] = bytes(10)
        session.start()
        accept(session)
        XCTAssertTrue(transport.kinds.contains("files.cancel"))
        let complete = transport.decode(FolderCompletePayload.self, transport.of(FolderKind.complete)[0])
        XCTAssertEqual(complete.failed.first?.code, "source_changed")
    }

    // MARK: Cancel, interruption, result

    func testCancelStopsTheFolderAndResendsUntilAcknowledged() {
        let chunk = FolderSendSession.chunkSize
        let (scan, contents) = memoryScan(files: [("a.bin", bytes(chunk * 80)), ("b.txt", bytes(10))])
        let session = session(scan, contents: contents)
        session.start()
        accept(session)
        let a = transport.of("files.offer")[0].transferID!
        session.cancel()
        let cancel = transport.decode(FolderCancelPayload.self, transport.of(FolderKind.cancel)[0])
        XCTAssertEqual(cancel.reason, "user")
        XCTAssertNil(cancel.code)
        let chunksBefore = transport.of("files.chunk").count
        session.chunkAcknowledged(a, sequence: 63)
        XCTAssertEqual(transport.of("files.chunk").count, chunksBefore, "the current file stops")
        XCTAssertEqual(transport.of("files.offer").count, 1, "waiting files are not sent")
        clock.advance(5)
        XCTAssertEqual(transport.of(FolderKind.cancel).count, 2)
        session.receivedCancelAck()
        XCTAssertEqual(events.outcome, .cancelledHere)
        clock.advance(20)
        XCTAssertEqual(transport.of(FolderKind.cancel).count, 2)
    }

    func testInterruptionStopsQuietly() {
        let (scan, contents) = threeFiles
        let session = session(scan, contents: contents)
        session.start()
        accept(session)
        let count = transport.messages.count
        session.interrupt()
        XCTAssertEqual(events.outcome, .interrupted)
        XCTAssertEqual(transport.messages.count, count)
        session.completeAcknowledged(transport.of("files.offer")[0].transferID!)
        XCTAssertEqual(transport.messages.count, count)
    }

    func testStalledAcknowledgementsInterruptTheFolder() {
        let chunk = FolderSendSession.chunkSize
        let (scan, contents) = memoryScan(files: [("a.bin", bytes(chunk * 80))])
        let session = session(scan, contents: contents)
        session.start()
        accept(session)
        clock.advance(9)
        XCTAssertNil(events.outcome)
        session.chunkAcknowledged(transport.of("files.offer")[0].transferID!, sequence: 5)
        clock.advance(9)
        XCTAssertNil(events.outcome)
        clock.advance(2)
        XCTAssertEqual(events.outcome, .interrupted)
    }

    func testResultConfirmsAndAMissingResultIsReported() {
        let (scan, contents) = threeFiles
        var session = self.session(scan, contents: contents)
        session.start()
        accept(session)
        transport.of("files.offer").forEach { session.completeAcknowledged($0.transferID!) }
        XCTAssertEqual(session.phase, .completing)
        let result = FolderResultPayload(folderTransferId: folderID, status: "complete", savedFiles: 3, savedBytes: 30_010, createdFolders: 2,
                                         renamedFiles: 0, replacedFiles: 0, failedCount: 0, failed: [])
        session.receivedResult(result)
        XCTAssertEqual(events.outcome, .done(result))
        XCTAssertEqual(FolderText.outcome(.done(result), name: "Photos", phone: "OnePlus 11", destination: "Pictures/Trip", progress: session.progress),
                       "Photos saved on OnePlus 11 in Pictures/Trip")

        transport.clear()
        events = RecordingFolderEvents()
        session = self.session(scan, contents: contents)
        session.start()
        accept(session)
        transport.of("files.offer").forEach { session.completeAcknowledged($0.transferID!) }
        clock.advance(29)
        XCTAssertNil(events.outcome)
        clock.advance(1)
        XCTAssertEqual(events.outcome, .unconfirmed)
        XCTAssertEqual(FolderText.outcome(.unconfirmed, name: "Photos", phone: "OnePlus 11", destination: nil, progress: FolderProgress()), "Not confirmed by OnePlus 11")
    }

    // MARK: Resume

    func testResumeSkipsDoneEntriesAndUsesNewTransferIDs() {
        let (scan, contents) = memoryScan(dirs: ["d"], files: [("a.txt", bytes(10)), ("b.txt", bytes(10)), ("c.txt", bytes(10)), ("d/e.txt", bytes(10))])
        // Entries: 0 a.txt, 1 b.txt, 2 c.txt, 3 d, 4 d/e.txt. The journal knows a.txt; the phone's bitmap says c.txt and d.
        let session = session(scan, contents: contents, resume: true, done: [0])
        session.start()
        let offer = transport.decode(FolderOfferPayload.self, transport.messages[0])
        XCTAssertTrue(offer.resume)
        XCTAssertEqual(offer.folderTransferId, folderID)
        XCTAssertEqual(transport.of(FolderKind.manifest).count, 1, "the manifest is sent again")
        transport.clear()
        accept(session, bitmap: CompletedBitmap.encode(size: 5) { [2, 3].contains($0) })
        let offers = transport.of("files.offer").map { transport.decode(FolderFileOfferPayload.self, $0) }
        XCTAssertEqual(offers.map(\.entry), [1, 4])
        XCTAssertEqual(offers.map(\.transferId), ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"])
        XCTAssertEqual(session.progress.filesDone, 2)
    }

    func testOwnershipRemembersFinishedIDsWithinItsLimit() {
        let ownership = FolderFileOwnership(limit: 3)
        (1...5).forEach { ownership.add("t\($0)", folder: "f") }
        XCTAssertNil(ownership.folder(of: "t1"))
        XCTAssertNil(ownership.folder(of: "t2"))
        XCTAssertEqual(ownership.folder(of: "t5"), "f")
        XCTAssertNil(ownership.folder(of: nil))
    }

    private struct FileCompleteProbe: Decodable {
        let transferId: String
        let sha256: String
    }
}
