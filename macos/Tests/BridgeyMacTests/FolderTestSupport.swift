import CryptoKit
import Foundation
@testable import BridgeyMac

/// Records what a folder session sends, in order.
final class FakeFolderTransport: FolderTransport {
    struct Message {
        let kind: String
        let payload: Data?
        let transferID: String?
        let sequence: Int64?
    }

    private(set) var messages: [Message] = []

    func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
        messages.append(Message(kind: kind, payload: payload, transferID: transferID, sequence: sequence))
        return true
    }

    func sendOuter(kind: String, transferID: String) {
        messages.append(Message(kind: kind, payload: nil, transferID: transferID, sequence: nil))
    }

    var kinds: [String] { messages.map(\.kind) }

    func of(_ kind: String) -> [Message] { messages.filter { $0.kind == kind } }

    func decode<T: Decodable>(_ type: T.Type, _ message: Message) -> T {
        try! JSONDecoder().decode(type, from: message.payload!)
    }

    func clear() { messages.removeAll() }
}

/// A clock moved by hand; timers fire in order while it advances.
final class ManualFolderClock: FolderClock {
    final class Timer: FolderTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private(set) var now: Date
    private var timers: [(due: Date, order: Int, timer: Timer, action: () -> Void)] = []
    private var counter = 0

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> FolderTimer {
        let timer = Timer()
        counter += 1
        timers.append((now.addingTimeInterval(seconds), counter, timer, action))
        return timer
    }

    func advance(_ seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while true {
            timers.removeAll { $0.timer.cancelled }
            guard let next = timers.filter({ $0.due <= target }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) else { break }
            timers.removeAll { $0.order == next.order }
            now = max(now, next.due)
            next.action()
        }
        now = target
    }
}

/// Files served from memory; `override` returns other bytes than the manifest says (changed on disk).
final class MemoryFolderFiles: FolderFileSource {
    var contents: [Int: Data]
    var override: [Int: Data] = [:]
    var unreadable: Set<Int> = []

    init(contents: [Int: Data]) { self.contents = contents }

    func open(entry: Int) throws -> FolderChunkReader {
        guard !unreadable.contains(entry), let data = override[entry] ?? contents[entry] else { throw CocoaError(.fileReadNoPermission) }
        return Reader(data: data)
    }

    final class Reader: FolderChunkReader {
        let data: Data
        var offset = 0
        init(data: Data) { self.data = data }
        func read(upTo count: Int) throws -> Data {
            let end = min(data.count, offset + count)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
        func close() {}
    }
}

final class RecordingFolderEvents: FolderSessionEvents {
    var progress: [FolderProgress] = []
    var questions: [(FolderConflictPayload, Date)] = []
    var questionsClosed = 0
    var completed: [Set<Int>] = []
    var accepted: [FolderAcceptPayload] = []
    var finished: [(FolderOutcome, FolderProgress)] = []

    func folderProgress(_ progress: FolderProgress) { self.progress.append(progress) }
    func folderAsks(_ conflict: FolderConflictPayload, deadline: Date) { questions.append((conflict, deadline)) }
    func folderQuestionClosed() { questionsClosed += 1 }
    func folderEntriesCompleted(_ completed: Set<Int>, at date: Date) { self.completed.append(completed) }
    func folderAccepted(_ accept: FolderAcceptPayload) { accepted.append(accept) }
    func folderFinished(_ outcome: FolderOutcome, progress: FolderProgress) { finished.append((outcome, progress)) }

    var outcome: FolderOutcome? { finished.last?.0 }
}

func sha256Base64(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }

/// A hashed scan built from memory: `files` are (path, bytes); `dirs` are folder paths.
func memoryScan(rootName: String = "Photos", dirs: [String] = [], files: [(String, Data)] = []) -> (FolderScan, [Int: Data]) {
    var scan = FolderScan(root: URL(fileURLWithPath: "/tmp/\(rootName)"), displayName: rootName, rootName: rootName, options: FolderScanOptions())
    var all: [(ManifestEntry, Data?)] = dirs.map { (.dir($0), nil) }
    all += files.map { (ManifestEntry.file($0.0, size: Int64($0.1.count), sha256: sha256Base64($0.1)), $0.1) }
    all.sort { FolderPaths.precedes($0.0.path, $1.0.path) }
    var contents: [Int: Data] = [:]
    for (index, item) in all.enumerated() {
        scan.entries.append(item.0)
        scan.sources.append(URL(fileURLWithPath: "/tmp/\(rootName)/\(item.0.path)"))
        if let data = item.1 { contents[index] = data }
    }
    scan.fileCount = files.count
    scan.folderCount = dirs.count
    scan.totalSize = files.reduce(Int64(0)) { $0 + Int64($1.1.count) }
    scan.hashed = true
    return (scan, contents)
}

/// Sequential lowercase UUIDs, so tests can tell transfer IDs apart.
final class SequentialIDs {
    private var next = 0
    func make() -> String {
        next += 1
        return String(format: "00000000-0000-4000-8000-%012d", next)
    }
}
