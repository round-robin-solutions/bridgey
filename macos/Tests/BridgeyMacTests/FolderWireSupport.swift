import CryptoKit
import Foundation
import XCTest
@testable import BridgeyMac

/// The phone, played by this Mac's own folder sender: every message of a FolderSendSession reaches a
/// FolderReceiveSession and back, over one serial queue, as the socket would carry them.
final class FolderWire: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.folder-wire")
    var sender: FolderSendSession?
    var receiver: FolderReceiveSession?
    var makeReceiver: ((FolderOfferPayload) -> FolderReceiveSession)?
    /// Messages to the receiver that are dropped (a cut connection).
    var cut = false
    private(set) var toReceiverKinds: [String] = []
    private(set) var toSenderKinds: [String] = []
    lazy var toReceiver = ToReceiver(wire: self)
    lazy var toSender = ToSender(wire: self)

    private struct Completion: Decodable {
        let transferId: String
        let sha256: String
    }

    final class ToReceiver: FolderTransport, @unchecked Sendable {
        weak var wire: FolderWire?
        init(wire: FolderWire) { self.wire = wire }

        func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
            guard let wire, !wire.cut else { return true }
            wire.queue.async { wire.deliverToReceiver(kind: kind, payload: payload, transferID: transferID, sequence: sequence) }
            return true
        }

        func sendOuter(kind: String, transferID: String) {
            guard let wire, !wire.cut else { return }
            wire.queue.async {
                wire.toReceiverKinds.append(kind)
                if kind == "files.cancel" { wire.receiver?.fileCancelled(transferID) }
            }
        }
    }

    final class ToSender: SequencedFolderTransport, @unchecked Sendable {
        weak var wire: FolderWire?
        init(wire: FolderWire) { self.wire = wire }

        func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
            guard let wire, !wire.cut else { return true }
            wire.queue.async { wire.deliverToSender(kind: kind, payload: payload) }
            return true
        }

        func sendOuter(kind: String, transferID: String) {
            guard let wire, !wire.cut else { return }
            wire.queue.async { wire.deliverOuterToSender(kind: kind, transferID: transferID, sequence: nil) }
        }

        func sendOuterSequenced(kind: String, transferID: String, sequence: Int64) {
            guard let wire, !wire.cut else { return }
            wire.queue.async { wire.deliverOuterToSender(kind: kind, transferID: transferID, sequence: sequence) }
        }
    }

    private func deliverToReceiver(kind: String, payload: Data, transferID: String?, sequence: Int64?) {
        toReceiverKinds.append(kind)
        let decoder = JSONDecoder()
        switch kind {
        case FolderKind.offer:
            guard let offer = try? decoder.decode(FolderOfferPayload.self, from: payload), let session = makeReceiver?(offer) else { return }
            receiver = session
            session.start()
        case FolderKind.manifest:
            if let page = try? decoder.decode(ManifestPagePayload.self, from: payload) { receiver?.manifestPage(page, plaintextBytes: payload.count) }
        case "files.offer":
            if let offer = try? decoder.decode(FolderFileOfferPayload.self, from: payload) { receiver?.fileOffer(offer) }
        case "files.chunk":
            if let transferID, let sequence { receiver?.chunk(transferID, sequence: sequence, data: payload) }
        case "files.complete":
            if let done = try? decoder.decode(Completion.self, from: payload) { receiver?.fileComplete(done.transferId, sha256: done.sha256) }
        case FolderKind.complete:
            if let done = try? decoder.decode(FolderCompletePayload.self, from: payload) { receiver?.folderComplete(done) }
        case FolderKind.cancel:
            if let cancel = try? decoder.decode(FolderCancelPayload.self, from: payload) { receiver?.cancelledBySender(cancel) }
        default:
            break
        }
    }

    private func deliverToSender(kind: String, payload: Data) {
        toSenderKinds.append(kind)
        let decoder = JSONDecoder()
        guard let sender else { return }
        switch kind {
        case FolderKind.waiting: if let value = try? decoder.decode(FolderWaitingPayload.self, from: payload) { sender.receivedWaiting(value) }
        case FolderKind.accept: if let value = try? decoder.decode(FolderAcceptPayload.self, from: payload) { sender.receivedAccept(value) }
        case FolderKind.rejected: if let value = try? decoder.decode(FolderRejectedPayload.self, from: payload) { sender.receivedRejected(value) }
        case FolderKind.entryFailed: if let value = try? decoder.decode(FolderEntryFailedPayload.self, from: payload) { sender.receivedEntryFailed(value) }
        case FolderKind.result: if let value = try? decoder.decode(FolderResultPayload.self, from: payload) { sender.receivedResult(value) }
        case FolderKind.cancel: if let value = try? decoder.decode(FolderCancelPayload.self, from: payload) { sender.receivedCancel(value) }
        default: break
        }
    }

    private func deliverOuterToSender(kind: String, transferID: String, sequence: Int64?) {
        toSenderKinds.append(kind)
        guard let sender else { return }
        switch kind {
        case "files.accept": sender.fileAccepted(transferID)
        case "files.chunk.ack": if let sequence { sender.chunkAcknowledged(transferID, sequence: sequence) }
        case "files.complete.ack": sender.completeAcknowledged(transferID)
        case FolderKind.cancelAck: sender.receivedCancelAck()
        default: break
        }
    }
}

/// Records what a receive session reports; can answer its questions.
final class ReceiveRecorder: FolderReceiveEvents, @unchecked Sendable {
    var progress: [ReceiveProgress] = []
    var destinationAsks: [Date] = []
    var conflicts: [ReceiveConflictQuestion] = []
    var closed = 0
    var finished: [(ReceiveOutcome, ReceiveProgress)] = []
    var onConflict: ((ReceiveConflictQuestion) -> Void)?
    var onDestination: (() -> Void)?
    var onFinished: (() -> Void)?
    var onProgress: ((ReceiveProgress) -> Void)?

    func receiveProgress(_ progress: ReceiveProgress) {
        self.progress.append(progress)
        onProgress?(progress)
    }
    func receiveAsksDestination(deadline: Date) {
        destinationAsks.append(deadline)
        onDestination?()
    }
    func receiveAsksConflict(_ question: ReceiveConflictQuestion) {
        conflicts.append(question)
        onConflict?(question)
    }
    func receiveQuestionClosed() { closed += 1 }
    func receiveFinished(_ outcome: ReceiveOutcome, progress: ReceiveProgress) {
        finished.append((outcome, progress))
        onFinished?()
    }
}

/// A temporary folder tree: `files` maps relative paths to contents; `dirs` are extra (empty) folders.
@discardableResult
func makeTree(_ name: String, files: [String: Data], dirs: [String] = [], in base: URL) throws -> URL {
    let root = base.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for dir in dirs { try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
    for (path, data) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    return root
}

func hashedScan(_ root: URL) -> FolderScan {
    FolderHasher.hash(FolderScanner.scan(root, options: FolderScanOptions()))!
}

func hashedScan(items: [URL]) -> FolderScan {
    FolderHasher.hash(FolderScanner.scan(items: items, options: FolderScanOptions()))!
}

func temporaryFolder(_ label: String = "bridgey-tests") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Every file under `root` as relative path to contents (folders end in "/").
func treeContents(_ root: URL) -> [String: Data] {
    var result: [String: Data] = [:]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [:] }
    let base = root.resolvingSymlinksInPath().standardizedFileURL.path
    for case let url as URL in enumerator {
        let path = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1))
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            result[path + "/"] = Data()
        } else {
            result[path] = try? Data(contentsOf: url)
        }
    }
    return result
}

/// Waits on the main run loop until `condition` holds (or the time runs out).
@MainActor
func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

/// Blocks until the wire's queue drained what was posted so far, several rounds deep.
func drain(_ queue: DispatchQueue, rounds: Int = 200) {
    for _ in 0..<rounds { queue.sync {} }
}
