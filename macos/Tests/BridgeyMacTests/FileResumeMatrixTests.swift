import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

/// The matrix in docs/file-resume.md, driven with the app's own pieces in temporary folders and connected in
/// process the way PairingCoordinator connects them: OutgoingFileTransfer hashes, offers and answers files.resume;
/// ResumePartials.openIncoming, IncomingFileTransfer and the private record file receive, keep and resume. Sender
/// drop and restart, receiver drop and restart, a whole file kept, a changed source, a tampered or expired partial,
/// a peer without the key, cancel and forget, the 64 MiB checkpoint after a crash, files.resume.wait during a long
/// re-read, and automatic retry on and off.
final class FileResumeMatrixTests: XCTestCase {
    private let peer = "7e57d00d-0000-4000-8000-0000000000aa"
    private let mib: Int64 = 1_048_576
    /// Not a whole number of blocks, so the last piece is short.
    private let size = 6 * 1_048_576 + 12_345
    private let chunk = 64 * 1024
    /// Where an interrupted attempt stops: two chunks past 3 MiB, so the kept record says 3 MiB.
    private var cut: Int64 { 3 * mib + 2 * Int64(chunk) }

    private final class Receiver {
        let directory: URL
        let recordsURL: URL
        var now: Int64 = 1_786_550_000_000
        var partials: ResumePartials!

        init(directory: URL) {
            self.directory = directory
            recordsURL = directory.deletingLastPathComponent().appendingPathComponent("records-\(UUID().uuidString)/file-resume.json")
            restart()
        }

        var access: ReceiveDirectoryAccess { ReceiveDirectoryAccess(url: directory, scoped: false) }

        /// The app starting again: the records reloaded and swept.
        func restart() {
            partials = ResumePartials(fileURL: recordsURL) { [unowned self] in self.now }
            partials.load()
        }

        var parts: [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(FileResume.partSuffix) }
        }

        var records: [ResumeRecord] { partials.store.records }
    }

    private enum End: Equatable {
        case saved(URL)
        case interrupted
        case cancelled
    }

    private func temporaryDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-matrix-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pattern(_ count: Int, salt: UInt8 = 0) -> Data { Data((0..<count).map { UInt8(($0 * 31) % 251) ^ salt }) }

    private func setUpPair(_ tag: String) throws -> (source: URL, receiver: Receiver) {
        let base = try temporaryDirectory(tag)
        let received = base.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source/video.mov")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pattern(size).write(to: source)
        return (source, Receiver(directory: received))
    }

    /// One attempt as the coordinator runs it: a fresh OutgoingFileTransfer (a new transfer ID, hashed again) offers;
    /// the receiver opens a kept partial or a new part; a kept one is read again and proposed; the sender answers;
    /// chunks follow from the agreed offset numbered from 0. Stops after `stopAt` bytes of the file (the session
    /// drops: the receiver keeps), cancels there, or completes. Returns where the receiver started and how it ended.
    @discardableResult
    private func attempt(_ source: URL, to receiver: Receiver, resumeOn: Bool = true, stopAt: Int64? = nil, cancel: Bool = false,
                         reread: ((IncomingFileTransfer, Int64) -> (hasher: SHA256, digest: Data)?)? = nil) throws -> (start: Int64, end: End) {
        let transferID = UUID().uuidString.lowercased()
        let outgoing = try OutgoingFileTransfer(url: source, transferID: transferID, cancellation: FileCancellationToken())
        outgoing.resumable = FileResume.isResumable(size: outgoing.offer.size) && resumeOn
        let offer = try JSONDecoder().decode(FileOfferPayload.self, from: try outgoing.offerPayload())
        XCTAssertEqual(offer.resumable?.value == true, outgoing.resumable)
        let resumable = offer.resumable?.value == true && FileResume.isResumable(size: offer.size) && resumeOn
        let incoming = try XCTUnwrap(receiver.partials.openIncoming(offer, from: peer, access: receiver.access, resumable: resumable))
        var start: Int64 = 0
        if case let .checking(length, _) = incoming.phase {
            let result = reread?(incoming, length) ?? (try? FileResume.hashPrefix(of: incoming.partialURL, length: length))
            switch incoming.applyCheck(result) {
            case let .propose(_, payload):
                let (offset, reason) = outgoing.resumeAnswer(payload)
                switch incoming.applyAck(FileResume.ackPayload(transferID: transferID, offset: offset, reason: reason)) {
                case .resume: start = offset
                case let .restart(record): if let record { receiver.partials.save(record) }
                case .invalid, .failed: XCTFail("the answer is taken")
                }
            case let .restart(record):
                if let record { receiver.partials.save(record) }
            case .failed:
                XCTFail("the partial could be cut back")
            }
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        var sent = start
        var sequence: Int64 = 0
        while stopAt.map({ sent < $0 }) ?? true, let data = try handle.read(upToCount: chunk), !data.isEmpty {
            try incoming.append(data, sequence: sequence, maximumChunk: FastFrame.maximumPlaintext)
            sequence += 1
            sent += Int64(data.count)
            if let record = incoming.checkpointIfDue() { receiver.partials.save(record) }
        }
        if cancel {
            receiver.partials.drop(incoming)
            return (start, .cancelled)
        }
        if stopAt != nil {
            receiver.partials.keep(incoming)
            return (start, .interrupted)
        }
        let saved = try incoming.finish(expectedHash: outgoing.offer.sha256)
        receiver.partials.finished(incoming)
        return (start, .saved(saved))
    }

    /// Sends the file again in full and checks what arrived and that nothing is left behind. Returns the start.
    private func sendAgain(_ source: URL, to receiver: Receiver, resumeOn: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws -> Int64 {
        let (start, end) = try attempt(source, to: receiver, resumeOn: resumeOn)
        guard case let .saved(url) = end else { XCTFail("saved", file: file, line: line); return start }
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: source), "the whole file, verified", file: file, line: line)
        XCTAssertEqual(receiver.parts, [], "no partial left", file: file, line: line)
        XCTAssertEqual(receiver.records, [], "no record left", file: file, line: line)
        return start
    }

    func testResumesAfterTheSenderDropsAndRestarts() throws {
        let (source, receiver) = try setUpPair("sender")
        XCTAssertEqual(try attempt(source, to: receiver, stopAt: cut).end, .interrupted)
        XCTAssertEqual(receiver.records.count, 1, "one partial kept")
        XCTAssertEqual(receiver.records.first?.length, 3 * mib, "verified to the last whole block")
        XCTAssertEqual(receiver.parts.count, 1)
        // The sender keeps nothing: a restarted sender hashes again under a new transfer ID and the receiver decides.
        XCTAssertEqual(try sendAgain(source, to: receiver), 3 * mib, "resumed after the kept 3 MiB, not from byte zero")
    }

    func testResumesAfterTheReceiverDropsAndRestarts() throws {
        let (source, receiver) = try setUpPair("receiver")
        try attempt(source, to: receiver, stopAt: cut)
        receiver.restart()
        XCTAssertEqual(receiver.records.count, 1, "the record is in private storage, outside the receive folder")
        XCTAssertFalse(receiver.recordsURL.path.hasPrefix(receiver.directory.path))
        XCTAssertEqual(try sendAgain(source, to: receiver), 3 * mib)
    }

    func testAKeptPartsNameIsChosenWhenSavingAndNeverOverwrites() throws {
        let (source, receiver) = try setUpPair("names")
        try attempt(source, to: receiver, stopAt: cut)
        XCTAssertEqual(receiver.parts.map(\.lastPathComponent), ["video.mov.bridgey-part"])
        // Meanwhile something else took the name the part reserved.
        let other = receiver.directory.appendingPathComponent("video.mov")
        try Data("someone else's".utf8).write(to: other)
        let (start, end) = try attempt(source, to: receiver)
        XCTAssertEqual(start, 3 * mib)
        guard case let .saved(url) = end else { return XCTFail("saved") }
        XCTAssertEqual(url.lastPathComponent, "video 2.mov")
        XCTAssertEqual(try Data(contentsOf: other), Data("someone else's".utf8), "never overwritten")
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: source))
    }

    func testAWholeFileKeptCompletesWithoutAChunk() throws {
        let (source, receiver) = try setUpPair("whole")
        // Every byte arrived, but files.complete never did.
        try attempt(source, to: receiver, stopAt: Int64(size))
        XCTAssertEqual(receiver.records.first?.length, Int64(size))
        XCTAssertEqual(try sendAgain(source, to: receiver), Int64(size))
    }

    func testAChangedSourceStartsFromZeroAndDropsTheOldPartial() throws {
        let (source, receiver) = try setUpPair("changed")
        try attempt(source, to: receiver, stopAt: cut)
        let old = try XCTUnwrap(receiver.records.first)
        // Same name and size, other bytes: another SHA-256, so nothing kept can be part of it.
        try pattern(size, salt: 0x5A).write(to: source)
        let transferID = UUID().uuidString.lowercased()
        let outgoing = try OutgoingFileTransfer(url: source, transferID: transferID, cancellation: FileCancellationToken())
        outgoing.resumable = true
        let offer = try JSONDecoder().decode(FileOfferPayload.self, from: try outgoing.offerPayload())
        let incoming = try XCTUnwrap(receiver.partials.openIncoming(offer, from: peer, access: receiver.access, resumable: true))
        XCTAssertEqual(incoming.phase, .receiving, "from byte zero")
        XCTAssertFalse(receiver.records.contains { $0.sha256 == old.sha256 }, "the old partial's record went")
        receiver.partials.drop(incoming)
        XCTAssertEqual(try sendAgain(source, to: receiver), 0)
    }

    func testATamperedPartialStartsFromZero() throws {
        let (source, receiver) = try setUpPair("tampered")
        try attempt(source, to: receiver, stopAt: cut)
        let part = try XCTUnwrap(receiver.parts.first)
        var bytes = try Data(contentsOf: part)
        bytes[1000] ^= 0xFF
        try bytes.write(to: part)
        XCTAssertEqual(try sendAgain(source, to: receiver), 0, "the kept bytes no longer match their record")
    }

    func testAShorterOrMissingPartialStartsFromZero() throws {
        let (source, receiver) = try setUpPair("short")
        try attempt(source, to: receiver, stopAt: cut)
        let part = try XCTUnwrap(receiver.parts.first)
        let handle = try FileHandle(forUpdating: part)
        try handle.truncate(atOffset: UInt64(mib))
        try handle.close()
        XCTAssertEqual(try sendAgain(source, to: receiver), 0)
        try attempt(source, to: receiver, stopAt: cut)
        try FileManager.default.removeItem(at: try XCTUnwrap(receiver.parts.first))
        receiver.restart()
        XCTAssertEqual(receiver.records, [], "a missing partial is swept at start")
        XCTAssertEqual(try sendAgain(source, to: receiver), 0)
    }

    func testAnExpiredPartialIsSweptAtStart() throws {
        let (source, receiver) = try setUpPair("expired")
        try attempt(source, to: receiver, stopAt: cut)
        // A day and a minute later.
        receiver.now += FileResume.lifetimeMilliseconds + 60_000
        receiver.restart()
        XCTAssertEqual(receiver.parts, [], "swept when the app started")
        XCTAssertEqual(receiver.records, [])
        XCTAssertEqual(try sendAgain(source, to: receiver), 0)
    }

    func testAPeerWithoutTheKeyKeepsTheOldBehaviour() throws {
        let (source, receiver) = try setUpPair("old")
        // Not resumable: an interruption deletes the partial and a retry starts at zero.
        try attempt(source, to: receiver, resumeOn: false, stopAt: cut)
        XCTAssertEqual(receiver.parts, [], "no partial kept")
        XCTAssertEqual(receiver.records, [])
        XCTAssertEqual(try sendAgain(source, to: receiver, resumeOn: false), 0)
        // And a file of one block or less is never offered resumable.
        let small = source.deletingLastPathComponent().appendingPathComponent("small.bin")
        try pattern(Int(mib)).write(to: small)
        let outgoing = try OutgoingFileTransfer(url: small, transferID: UUID().uuidString.lowercased(), cancellation: FileCancellationToken())
        outgoing.resumable = FileResume.isResumable(size: outgoing.offer.size)
        XCTAssertNil(try JSONDecoder().decode(FileOfferPayload.self, from: try outgoing.offerPayload()).resumable)
        XCTAssertFalse(String(decoding: try outgoing.offerPayload(), as: UTF8.self).contains("resumable"))
    }

    func testACancelOrForgettingTheDeviceRemovesThePartial() throws {
        let (source, receiver) = try setUpPair("cancel")
        XCTAssertEqual(try attempt(source, to: receiver, stopAt: cut, cancel: true).end, .cancelled)
        XCTAssertEqual(receiver.parts, [])
        XCTAssertEqual(receiver.records, [])
        // Kept, then resumed and cancelled: the partial goes with it.
        try attempt(source, to: receiver, stopAt: cut)
        let (start, _) = try attempt(source, to: receiver, stopAt: 5 * mib, cancel: true)
        XCTAssertEqual(start, 3 * mib, "resumed")
        XCTAssertEqual(receiver.parts, [])
        XCTAssertEqual(receiver.records, [])
        // Kept, then the device is forgotten: its partials go too, another device's stay.
        try attempt(source, to: receiver, stopAt: cut)
        let otherPart = receiver.directory.appendingPathComponent("theirs.bin.bridgey-part")
        try pattern(Int(mib)).write(to: otherPart)
        receiver.partials.save(ResumeRecord(peer: "7e57d00d-0000-4000-8000-0000000000bb", size: 2 * mib, sha256: Data(SHA256.hash(data: Data("x".utf8))).base64EncodedString(),
                                            length: mib, prefix: Data(SHA256.hash(data: pattern(Int(mib)))).base64EncodedString(),
                                            dir: receiver.directory.path, part: otherPart.lastPathComponent, name: "theirs.bin", updated: 0))
        receiver.partials.release(otherPart, keep: true)
        receiver.partials.forget(peer: peer.uppercased())
        XCTAssertEqual(receiver.parts.map(\.lastPathComponent), ["theirs.bin.bridgey-part"])
        XCTAssertEqual(receiver.records.map(\.part), ["theirs.bin.bridgey-part"])
    }

    func testAnAnswerThatIsNotTheProposalCancelsAndAChunkBeforeTheAnswerIsInvalid() throws {
        let (source, receiver) = try setUpPair("invalid")
        try attempt(source, to: receiver, stopAt: cut)
        let outgoing = try OutgoingFileTransfer(url: source, transferID: UUID().uuidString.lowercased(), cancellation: FileCancellationToken())
        outgoing.resumable = true
        let offer = try JSONDecoder().decode(FileOfferPayload.self, from: try outgoing.offerPayload())
        let incoming = try XCTUnwrap(receiver.partials.openIncoming(offer, from: peer, access: receiver.access, resumable: true))
        guard case let .checking(length, _) = incoming.phase else { return XCTFail("kept") }
        guard case .propose = incoming.applyCheck(try? FileResume.hashPrefix(of: incoming.partialURL, length: length)) else { return XCTFail("proposed") }
        XCTAssertThrowsError(try incoming.append(Data([1]), sequence: 0), "a chunk before files.resume.ack")
        XCTAssertEqual(incoming.applyAck(FileResume.ackPayload(transferID: offer.transferId, offset: mib, reason: nil)), .invalid)
        receiver.partials.drop(incoming)
        XCTAssertEqual(receiver.parts, [])
        XCTAssertEqual(receiver.records, [])
    }

    func testAMismatchFromTheSenderRestartsInsideTheSameTransfer() throws {
        let (source, receiver) = try setUpPair("mismatch")
        try attempt(source, to: receiver, stopAt: cut)
        let outgoing = try OutgoingFileTransfer(url: source, transferID: UUID().uuidString.lowercased(), cancellation: FileCancellationToken())
        outgoing.resumable = true
        let offer = try JSONDecoder().decode(FileOfferPayload.self, from: try outgoing.offerPayload())
        let incoming = try XCTUnwrap(receiver.partials.openIncoming(offer, from: peer, access: receiver.access, resumable: true))
        guard case let .checking(length, _) = incoming.phase else { return XCTFail("kept") }
        _ = incoming.applyCheck(try? FileResume.hashPrefix(of: incoming.partialURL, length: length))
        guard case let .restart(record) = incoming.applyAck(FileResume.ackPayload(transferID: offer.transferId, offset: 0, reason: "mismatch")) else {
            return XCTFail("from byte zero")
        }
        XCTAssertEqual(record?.length, 0, "the record now says nothing is verified")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: incoming.partialURL.path)[.size] as? Int, 0, "the partial was emptied")
        let data = try Data(contentsOf: source)
        var sequence: Int64 = 0
        var start = 0
        while start < data.count {
            let end = min(data.count, start + chunk)
            try incoming.append(data.subdata(in: start..<end), sequence: sequence, maximumChunk: FastFrame.maximumPlaintext)
            sequence += 1
            start = end
        }
        XCTAssertEqual(try Data(contentsOf: try incoming.finish(expectedHash: offer.sha256)), data)
    }

    /// A crash (no clean end) keeps what the last 64 MiB checkpoint recorded; the bytes after it are cut off on resume.
    func testTheCheckpointEvery64MiBSurvivesACrash() throws {
        let base = try temporaryDirectory("checkpoint")
        let received = base.appendingPathComponent("received", isDirectory: true)
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        let receiver = Receiver(directory: received)
        let source = base.appendingPathComponent("big.bin")
        let big = Int(FileResume.checkpointEvery) + 3 * Int(mib) + 777
        try pattern(big).write(to: source)
        let outgoing = try OutgoingFileTransfer(url: source, transferID: UUID().uuidString.lowercased(), cancellation: FileCancellationToken())
        outgoing.resumable = true
        let offer = try JSONDecoder().decode(FileOfferPayload.self, from: try outgoing.offerPayload())
        let incoming = try XCTUnwrap(receiver.partials.openIncoming(offer, from: peer, access: receiver.access, resumable: true))
        XCTAssertEqual(receiver.records.first?.length, 0, "a record from the start, with nothing verified")
        let handle = try FileHandle(forReadingFrom: source)
        var sequence: Int64 = 0
        var sent: Int64 = 0
        while sent < FileResume.checkpointEvery + 2 * mib, let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            try incoming.append(data, sequence: sequence, maximumChunk: FastFrame.maximumPlaintext)
            sequence += 1
            sent += Int64(data.count)
            if let record = incoming.checkpointIfDue() { receiver.partials.save(record) }
        }
        try handle.close()
        XCTAssertEqual(receiver.records.first?.length, FileResume.checkpointEvery, "recorded at 64 MiB, after syncing")
        // The app dies here: no keep. The next start finds the record and a longer part.
        receiver.restart()
        XCTAssertEqual(receiver.records.first?.length, FileResume.checkpointEvery)
        XCTAssertEqual(try sendAgain(source, to: receiver), FileResume.checkpointEvery)
    }

    /// The receiver's re-read takes longer than the sender's answer window: files.resume.wait keeps coming meanwhile,
    /// and each one refreshes the sender's waiting row, which the stall sweep would otherwise fail at 120 seconds.
    func testFilesResumeWaitKeepsTheSenderWaitingDuringALongReread() throws {
        let (source, receiver) = try setUpPair("wait")
        try attempt(source, to: receiver, stopAt: cut)
        let waited = expectation(description: "waits")
        waited.expectedFulfillmentCount = 3
        waited.assertForOverFulfill = false
        let done = expectation(description: "read again")
        var waits = 0
        let part = try XCTUnwrap(receiver.parts.first)
        var result: (hasher: SHA256, digest: Data)?
        let check = ResumeCheck(url: part, length: 3 * mib, every: 0.05, held: 0.5, waiting: {
            waits += 1
            waited.fulfill()
        }, done: { value in
            result = value
            done.fulfill()
        })
        wait(for: [waited, done], timeout: 10, enforceOrder: true)
        withExtendedLifetime(check) {}
        XCTAssertGreaterThanOrEqual(waits, 3)
        let afterDone = waits
        XCTAssertEqual(result?.digest.base64EncodedString(), receiver.records.first?.prefix, "the re-read matches the record")
        let settle = expectation(description: "no more waits")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(waits, afterDone, "no wait after the answer")
        // The sender's row: refreshed by each wait (PairingCoordinator updates it), never stalled while waits come.
        let offeredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let silent = FileTransferRow(id: "t", name: "video.mov", status: "Waiting for Android…", active: true, lastProgressAt: offeredAt)
        var refreshed = silent
        refreshed.lastProgressAt = offeredAt.addingTimeInterval(4 * FileResume.waitEvery)
        let later = offeredAt.addingTimeInterval(FileResume.answerWindow + 30)
        XCTAssertEqual(TransferStall.stalledIDs([silent], now: later), ["t"], "without a wait the window ends")
        XCTAssertEqual(TransferStall.stalledIDs([refreshed], now: later), [], "a wait 30 seconds ago keeps it waiting")
        XCTAssertLessThan(FileResume.waitEvery * 2, TransferStall.timeout, "waits come well inside the window")
        _ = source
    }

    func testACancelledCheckSendsNoWaitAndNoAnswer() throws {
        let (source, receiver) = try setUpPair("cancelled-check")
        try attempt(source, to: receiver, stopAt: cut)
        var calls = 0
        let check = ResumeCheck(url: try XCTUnwrap(receiver.parts.first), length: 3 * mib, every: 0.05, held: 0.3,
                                waiting: { calls += 1 }, done: { _ in calls += 100 })
        check.cancel()
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settle.fulfill() }
        wait(for: [settle], timeout: 3)
        XCTAssertEqual(calls, 0)
    }

    func testAutomaticRetryOnAndOff() throws {
        let phone = peer, other = "7e57d00d-0000-4000-8000-0000000000bb"
        let interrupted = Date(timeIntervalSince1970: 1_800_000_000)
        var list = AutoResumeList()
        // The one in flight and the queued one, oldest first whatever order they were found in.
        list.interrupted([(id: "queued", startedAt: interrupted.addingTimeInterval(-5)), (id: "sending", startedAt: interrupted.addingTimeInterval(-60))],
                         phone: phone, at: interrupted)
        list.interrupted([(id: "elsewhere", startedAt: interrupted)], phone: other, at: interrupted)
        XCTAssertEqual(list.due(phone: phone, now: interrupted.addingTimeInterval(600), enabled: true), ["sending", "queued"])
        XCTAssertEqual(list.due(phone: phone, now: interrupted.addingTimeInterval(700), enabled: true), [], "once")
        XCTAssertEqual(list.entries.map(\.id), ["elsewhere"], "another phone's files wait for it")
        // Off: nothing goes again, and nothing waits for later.
        list.interrupted([(id: "a", startedAt: interrupted)], phone: phone, at: interrupted)
        XCTAssertEqual(list.due(phone: phone, now: interrupted.addingTimeInterval(60), enabled: false), [])
        XCTAssertEqual(list.due(phone: phone, now: interrupted.addingTimeInterval(61), enabled: true), [])
        // After 24 hours the partial has expired: nothing goes again by itself.
        list.interrupted([(id: "b", startedAt: interrupted)], phone: phone, at: interrupted)
        XCTAssertEqual(list.due(phone: phone, now: interrupted.addingTimeInterval(AutoResumeList.window), enabled: true), [])
        // Cancelled or retried by hand: it leaves the list.
        list.interrupted([(id: "c", startedAt: interrupted)], phone: phone, at: interrupted)
        list.remove("c")
        XCTAssertEqual(list.due(phone: phone, now: interrupted.addingTimeInterval(60), enabled: true), [])
    }

    @MainActor
    func testTheSettingIsOnByDefaultAndRemembered() throws {
        let suiteName = "bridgey-resume-setting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = BridgeySettings(defaults: defaults)
        XCTAssertTrue(settings.autoResumeFiles, "Resume interrupted files automatically is on by default")
        settings.setAutoResumeFiles(false)
        XCTAssertFalse(BridgeySettings(defaults: defaults).autoResumeFiles)
    }

    func testTheKeyIsAdvertisedAsADraftCapability() {
        XCTAssertEqual(FileResume.featureKey, "files_resume_draft1")
        let index = knownDraftFeatureKeys.firstIndex(of: FileResume.featureKey)
        XCTAssertEqual(index.map { knownDraftFeatureKeys[$0 - 1] }, filesFastFeatureKey, "right after files_fast_draft1, as on Android")
    }
}
