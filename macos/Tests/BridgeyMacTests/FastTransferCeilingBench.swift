import CryptoKit
import Foundation
import Network
import XCTest
@testable import BridgeyMac

/// The Mac side's transfer ceiling without the emulator: the frame code the app uses (FastTransfer.swift, the JSON
/// envelope with its protocol 2 tag) over TCP loopback, printed as "CEILING ..." lines. Runs only with BRIDGEY_PERF=1
/// (timings depend on the machine; docs/transfer-speed.md has the numbers):
///   BRIDGEY_PERF=1 swift test -c release --filter FastTransferCeilingBench
/// BRIDGEY_BENCH_MB changes the file size (default 1000 MB).
///
/// The receiver mirrors Session: NWConnection reads, frames split and decrypted on a serial receive queue, then the
/// batch goes to the main thread, which writes the file through IncomingFileTransfer (disk and SHA-256) and answers
/// each chunk with a tagged files.chunk.ack, as Pairing.receiveFast does. The sender mirrors OutgoingFileTransfer:
/// a worker thread reads the file, waits for room in a TransferPacer and seals each frame before NWConnection.send;
/// acks reach the pacer from the main thread.
final class FastTransferCeilingBench: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })
    private let envelopeKey = Data((0..<32).map { UInt8($0 + 7) })
    private let phone = "7e57d00d-0000-4000-8000-0000000000aa"
    private let mac = "7e57d00d-0000-4000-8000-0000000000bb"
    private var megabytes = 1000
    private var directory: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["BRIDGEY_PERF"] == "1" else { throw XCTSkip("Set BRIDGEY_PERF=1 to run the ceiling bench") }
        megabytes = Int(ProcessInfo.processInfo.environment["BRIDGEY_BENCH_MB"] ?? "") ?? 1000
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-ceiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func report(_ name: String, bytes: Int, seconds: Double, extra: String = "") {
        print("CEILING mac \(name): \(String(format: "%.0f", Double(bytes) / 1e6 / seconds)) MB/s (\(bytes / 1_000_000) MB in \(String(format: "%.2f", seconds)) s)\(extra)")
    }

    private func sourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-ceiling-\(megabytes).bin")
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) != megabytes * 1_000_000 {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            var generator = SystemRandomNumberGenerator()
            let block = Data((0..<1_000_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
            for _ in 0..<megabytes { try handle.write(contentsOf: block) }
            try handle.close()
        }
        return url
    }

    func testCodecAlone() throws {
        let chunk = Data((0..<FastFrame.chunkSize).map { UInt8(truncatingIfNeeded: $0) })
        let count = 2000
        var started = Date()
        let frames = try (0..<count).map { try sealFastFrame(kind: 1, id: "t", sequence: Int64($0), plaintext: chunk, key: key, sender: mac) }
        report("seal 256 KiB binary frames", bytes: count * chunk.count, seconds: Date().timeIntervalSince(started))
        started = Date()
        for frame in frames { _ = try openFastFrameBody(kind: 1, body: frame.subdata(in: 6..<frame.count), key: key, sender: mac) }
        report("open 256 KiB binary frames", bytes: count * chunk.count, seconds: Date().timeIntervalSince(started))
        var hasher = SHA256()
        started = Date()
        for _ in 0..<count { hasher.update(data: chunk) }
        _ = hasher.finalize()
        report("SHA-256", bytes: count * chunk.count, seconds: Date().timeIntervalSince(started))
    }

    func testRawTcpLoopback() throws {
        let total = megabytes * 1_000_000
        let (listener, accepted) = try listen()
        let client = try connect(listener)
        let server = try XCTUnwrap(accepted.wait())
        let done = expectation(description: "received")
        var received = 0
        let started = Date()
        func next() {
            server.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                received += data?.count ?? 0
                if received >= total || complete || error != nil { return done.fulfill() }
                next()
            }
        }
        next()
        let block = Data(count: 256 * 1024)
        let inFlight = DispatchSemaphore(value: 32)
        DispatchQueue.global(qos: .userInitiated).async {
            var sent = 0
            while sent < total {
                inFlight.wait()
                client.send(content: block, completion: .contentProcessed { _ in inFlight.signal() })
                sent += block.count
            }
        }
        wait(for: [done], timeout: 300)
        report("raw TCP loopback (NWConnection)", bytes: received, seconds: Date().timeIntervalSince(started))
        client.cancel()
        server.cancel()
        listener.cancel()
    }

    func testFastFramesWithAcksAndDisk() throws {
        try transfer("fast 256 KiB binary frames, acks, disk", fast: true)
    }

    func testLegacyJsonWithAcksAndDisk() throws {
        try transfer("legacy 24 KiB JSON chunks, acks, 64-chunk window, disk", fast: false)
    }

    // MARK: - Harness

    private final class Box<T> {
        var value: T?
        let semaphore = DispatchSemaphore(value: 0)
        func set(_ value: T) {
            self.value = value
            semaphore.signal()
        }

        func wait() -> T? {
            _ = semaphore.wait(timeout: .now() + 10)
            return value
        }
    }

    private func listen() throws -> (NWListener, Box<NWConnection>) {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = Box<NWConnection>()
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "bench.server"))
            accepted.set(connection)
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: DispatchQueue(label: "bench.listener"))
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        return (listener, accepted)
    }

    private func connect(_ listener: NWListener) throws -> NWConnection {
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        client.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        client.start(queue: DispatchQueue(label: "bench.client"))
        XCTAssertEqual(ready.wait(timeout: .now() + 10), .success)
        return client
    }

    /// Reads frames like Session.receive/parse: split and decrypt on a serial queue, deliver the batch on main.
    private final class Reader {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "bench.receive", qos: .userInitiated)
        private var frames = ProtocolFrameReader()
        private let open: (UInt8, Data) throws -> FastFramePayload
        private var replay = FastReplayGuard()
        var onMessage: ((PairingMessage) -> Void)?
        var onFast: ((FastFramePayload) -> Void)?

        init(_ connection: NWConnection, binary: Bool, open: @escaping (UInt8, Data) throws -> FastFramePayload) {
            self.connection = connection
            self.open = open
            frames.binaryAllowed = binary
        }

        func start() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
                queue.async { [self] in
                    if let data { frames.append(data) }
                    var messages: [PairingMessage] = []
                    var payloads: [FastFramePayload] = []
                    while let frame = try? frames.nextFrame() {
                        switch frame {
                        case let .message(message): messages.append(message)
                        case let .binary(kind, body):
                            guard let payload = try? open(kind, body), replay.accept(payload) else { continue }
                            payloads.append(payload)
                        }
                    }
                    if !complete, error == nil { start() }
                    DispatchQueue.main.async { [self] in
                        messages.forEach { onMessage?($0) }
                        payloads.forEach { onFast?($0) }
                    }
                }
            }
        }
    }

    private func send(_ message: PairingMessage, from sender: String, on connection: NWConnection) {
        var tagged = message
        tagged.tag = SessionSecurity.tag(envelopeKey: envelopeKey, senderDeviceID: sender, message: message)
        let encoded = try! JSONEncoder().encode(tagged)
        connection.send(content: encoded + Data([0x0A]), completion: .contentProcessed { _ in })
    }

    private func transfer(_ name: String, fast: Bool) throws {
        let source = try sourceFile()
        let total = megabytes * 1_000_000
        let transferID = UUID().uuidString.lowercased()
        let (listener, accepted) = try listen()
        let client = try connect(listener)
        let server = try XCTUnwrap(accepted.wait())
        let key = self.key
        let phone = self.phone
        let mac = self.mac
        let offer = FileOfferPayload(transferId: transferID, name: "ceiling.bin", mimeType: "application/octet-stream",
                                     size: Int64(total), sha256: "unchecked")
        let incoming = try IncomingFileTransfer(offer: offer, directoryAccess: ReceiveDirectoryAccess(url: directory, scoped: false))
        let done = expectation(description: "all acknowledged")
        var failure: String?
        var statusUpdates = 0

        // Receiver (the phone's role is played by this Mac's code: the Mac receiving from a phone).
        let receiver = Reader(server, binary: fast) { kind, body in try openFastFrameBody(kind: kind, body: body, key: key, sender: phone) }
        func received(_ data: Data, sequence: Int64) {
            do {
                try incoming.append(data, sequence: sequence, maximumChunk: FastFrame.maximumPlaintext)
            } catch {
                failure = "append \(sequence)"
                return
            }
            send(PairingMessage(kind: "files.chunk.ack", sessionId: "s", transferId: transferID, sequence: sequence), from: mac, on: server)
            if incoming.progressStatus() != nil { statusUpdates += 1 }
        }
        receiver.onFast = { received($0.plaintext, sequence: $0.sequence) }
        receiver.onMessage = { message in
            guard SessionSecurity.tagMatches(envelopeKey: self.envelopeKey, senderDeviceID: phone, message: message),
                  let nonce = message.nonce, let ciphertext = message.ciphertext, let sequence = message.sequence,
                  let plaintext = try? decrypt(nonce: nonce, ciphertext: ciphertext, key: key) else {
                failure = "json chunk"
                return
            }
            received(plaintext, sequence: sequence)
        }
        receiver.start()

        // Sender.
        let pacer = TransferPacer(fast: fast)
        let acks = Reader(client, binary: false) { _, _ in throw FastFrameError.malformed }
        acks.onMessage = { message in
            guard SessionSecurity.tagMatches(envelopeKey: self.envelopeKey, senderDeviceID: mac, message: message),
                  let sequence = message.sequence else { return }
            pacer.acknowledged(transferID, through: sequence)
        }
        acks.start()
        let started = Date()
        var finished = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                var sequence: Int64 = 0
                while let chunk = try handle.read(upToCount: pacer.chunkSize), !chunk.isEmpty {
                    try pacer.waitForRoom(chunk.count, timeout: 30)
                    pacer.didSend(transferID, sequence: sequence, bytes: chunk.count)
                    if fast {
                        let frame = try sealFastFrame(kind: FastFrame.chunkKind, id: transferID, sequence: sequence, plaintext: chunk,
                                                      key: key, sender: phone)
                        client.send(content: frame, completion: .contentProcessed { _ in })
                    } else {
                        let sealed = try encrypt(chunk, key: key)
                        self.send(PairingMessage(kind: "files.chunk", sessionId: "s", messageId: UUID().uuidString.lowercased(),
                                                 nonce: sealed.nonce, ciphertext: sealed.ciphertext, transferId: transferID,
                                                 sequence: sequence), from: phone, on: client)
                    }
                    sequence += 1
                }
                try pacer.waitForAll(timeout: 60)
                finished = Date()
            } catch {
                failure = "sender \(error)"
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 1200)
        XCTAssertNil(failure)
        XCTAssertEqual(incoming.receivedSize, Int64(total))
        incoming.cancel()
        let window = fast ? String(format: ", window %d KiB, base round trip %.2f ms, %d status updates", Int(pacer.windowBytes / 1024),
                                   (pacer.baseRoundTrip ?? 0) * 1000, statusUpdates) : ""
        report(name, bytes: total, seconds: finished.timeIntervalSince(started), extra: window)
        client.cancel()
        server.cancel()
        listener.cancel()
    }
}
