import Foundation
import XCTest
@testable import BridgeyMac

/// protocol/test-vectors/files-fast-v1.json (binary frames, speed.* payloads, the verdict): Android
/// (FastTransferVectorsTest.kt) decodes the same vectors. Regenerate with protocol/tools/fast_vectors.py.
final class FastTransferVectorsTests: XCTestCase {
    private var vectors: [String: Any] = [:]
    private var key = Data()

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/files-fast-v1.json")
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vectors["keyBase64"] as? String)))
    }

    private func each(_ group: String, file: StaticString = #filePath, line: UInt = #line, _ check: ([String: Any]) throws -> Bool) throws {
        let list = try XCTUnwrap(vectors[group] as? [[String: Any]])
        XCTAssertGreaterThan(list.count, 5)
        let failed = list.filter { ((try? check($0)) ?? false) == false }.map { $0["name"] as! String }
        XCTAssertEqual(failed, [], "\(group) vectors that decode differently from the contract", file: file, line: line)
    }

    /// The frame through the session's reader, then the body decoder: decoded fields, "skip" or "reject".
    private func decode(_ frame: Data) -> Any {
        var reader = ProtocolFrameReader()
        reader.binaryAllowed = true
        reader.append(frame)
        guard let next = try? reader.nextFrame() else { return "reject" }
        guard case let .binary(kind, body) = next else { return "reject" }
        guard kind == FastFrame.chunkKind || kind == FastFrame.speedKind else { return "skip" }
        guard let payload = try? openFastFrameBody(kind: kind, body: body, key: key) else { return "reject" }
        return ["kind": Int(payload.kind), "id": payload.id, "sequence": payload.sequence, "plaintextBase64": payload.plaintext.base64EncodedString()]
    }

    func testFastFrames() throws {
        try each("fastFrame") { vector in
            var frame = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(vector["frameBase64"] as? String)))
            if let total = vector["zeroPadTo"] as? Int { frame.append(Data(count: total - frame.count)) }
            let decoded = decode(frame)
            guard NSArray(object: decoded).isEqual(to: [vector["expect"] as Any]) else { return false }
            if vector["write"] as? Bool == true, let expect = vector["expect"] as? [String: Any] {
                let written = try sealFastFrame(kind: UInt8(expect["kind"] as! Int), id: expect["id"] as! String,
                                                sequence: Int64(expect["sequence"] as! Int),
                                                plaintext: Data(base64Encoded: expect["plaintextBase64"] as! String)!, key: key,
                                                nonce: Data(base64Encoded: vector["nonceBase64"] as! String)!)
                return written == frame
            }
            return true
        }
    }

    func testSpeedPayloads() throws {
        func link(_ value: SpeedLink?) -> Any {
            guard let value else { return NSNull() }
            func n(_ x: Any?) -> Any { x ?? NSNull() }
            return ["platform": value.platform, "network": value.network, "band": n(value.band), "linkMbps": n(value.linkMbps),
                    "standard": n(value.standard), "widthMhz": n(value.widthMhz), "lockHeld": n(value.lockHeld), "screenOn": n(value.screenOn)]
        }
        try each("speedPayload") { vector in
            let data: Data
            if let raw = vector["plaintextString"] as? String { data = Data(raw.utf8) }
            else { data = try JSONSerialization.data(withJSONObject: vector["plaintext"] as Any) }
            let decoded: Any
            switch SpeedPayload.decode(kind: vector["kind"] as! String, plaintext: data) {
            case nil: decoded = "reject"
            case let .start(testId, seconds, value)?: decoded = ["testId": testId, "seconds": seconds, "link": link(value)]
            case let .ready(testId, status, value)?: decoded = ["testId": testId, "status": status, "link": link(value)]
            case let .turn(testId, rate)?, let .done(testId, rate)?: decoded = ["testId": testId, "bytesPerSecond": rate]
            case let .result(testId, forward, back, roundTrip, loaded)?:
                func n(_ x: Any?) -> Any { x ?? NSNull() }
                decoded = ["testId": testId, "forward": n(forward), "back": n(back), "roundTripMs": n(roundTrip), "loadedRoundTripMs": n(loaded)]
            }
            return NSArray(object: decoded).isEqual(to: [vector["expect"] as Any])
        }
    }

    func testSpeedPayloadsRoundTrip() throws {
        let link = SpeedLink(platform: "macos", network: "wifi", band: "5", linkMbps: 1201, standard: 6, widthMhz: 80)
        let id = UUID().uuidString.lowercased()
        for payload: SpeedPayload in [.start(testId: id, seconds: 7, link: link), .ready(testId: id, status: "busy", link: nil),
                                      .turn(testId: id, bytesPerSecond: 123), .done(testId: id, bytesPerSecond: 0),
                                      .result(testId: id, forward: 1, back: 2, roundTripMs: 3.5, loadedRoundTripMs: nil)] {
            let kind: String
            switch payload {
            case .start: kind = SpeedKind.start
            case .ready: kind = SpeedKind.ready
            case .turn: kind = SpeedKind.turn
            case .done: kind = SpeedKind.done
            case .result: kind = SpeedKind.result
            }
            XCTAssertEqual(SpeedPayload.decode(kind: kind, plaintext: try XCTUnwrap(payload.json)), payload)
        }
    }

    func testSpeedVerdicts() throws {
        try each("speedVerdict") { vector in
            let mac = try XCTUnwrap(SpeedLink.decode(vector["mac"]))
            let phone = SpeedLink.decode(vector["phone"])
            let verdict = SpeedVerdict.evaluate(mac: mac, phone: phone, best: vector["bestBytesPerSecond"] as! Double)
            let decoded: [String: Any] = ["route": verdict.route.rawValue, "low": Int(verdict.expected.lowerBound), "high": Int(verdict.expected.upperBound),
                                          "asExpected": verdict.asExpected, "advice": verdict.advice.map(\.rawValue)]
            return NSDictionary(dictionary: decoded).isEqual(to: vector["expect"] as! [String: Any])
        }
    }
}

final class FastTransferTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    func testOneMebibyteChunkRoundTripsAndOneByteMoreIsRefused() throws {
        let plaintext = Data((0..<FastFrame.maximumPlaintext).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let frame = try sealFastFrame(kind: FastFrame.chunkKind, id: "t", sequence: 9, plaintext: plaintext, key: key)
        var reader = ProtocolFrameReader()
        reader.binaryAllowed = true
        reader.append(frame)
        guard case let .binary(kind, body)? = try reader.nextFrame() else { return XCTFail("no binary frame") }
        XCTAssertEqual(try openFastFrameBody(kind: kind, body: body, key: key).plaintext, plaintext)
        XCTAssertThrowsError(try sealFastFrame(kind: 1, id: "t", sequence: 0, plaintext: plaintext + Data([0]), key: key))
    }

    func testReaderMixesJSONAndBinaryFramesAcrossAnySplit() throws {
        let json1 = Data(#"{"kind":"files.chunk.ack","sessionId":"s","transferId":"t","sequence":1}"#.utf8) + Data([0x0A])
        let binary = try sealFastFrame(kind: FastFrame.chunkKind, id: "t", sequence: 2, plaintext: Data(repeating: 0x0A, count: 70_000), key: key)
        let json2 = Data(#"{"kind":"heartbeat.ping","sessionId":"s","messageId":"m"}"#.utf8) + Data([0x0D, 0x0A])
        let stream = json1 + binary + json2
        for split in [1, 2, 5, 6, 7, 100, 4096, 65_536, stream.count] {
            var reader = ProtocolFrameReader()
            reader.binaryAllowed = true
            var kinds: [String] = []
            var offset = 0
            while offset < stream.count {
                let end = min(stream.count, offset + split)
                reader.append(stream.subdata(in: offset..<end))
                offset = end
                while let frame = try reader.nextFrame() {
                    switch frame {
                    case let .message(message): kinds.append(message.kind)
                    case let .binary(kind, body):
                        XCTAssertEqual(try openFastFrameBody(kind: kind, body: body, key: key).sequence, 2)
                        kinds.append("binary")
                    }
                }
            }
            XCTAssertEqual(kinds, ["files.chunk.ack", "binary", "heartbeat.ping"], "split \(split)")
            XCTAssertTrue(reader.buffer.isEmpty)
        }
    }

    func testWithoutBinaryAllowedTheMarkerIsAnInvalidJSONFrame() {
        var reader = ProtocolFrameReader()
        reader.append(Data([FastFrame.marker, 1, 0, 0, 0, 1, 0x41, 0x0A]))
        XCTAssertThrowsError(try reader.next())
    }

    func testBinaryBodiesOverTheLimitCloseTheSession() {
        var reader = ProtocolFrameReader()
        reader.binaryAllowed = true
        var header = Data([FastFrame.marker, 1])
        var length = UInt32(FastFrame.maximumBody + 1).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        reader.append(header)
        XCTAssertThrowsError(try reader.nextFrame())
    }

    func testLegacyPacerKeepsSixtyFourChunks() {
        let pacer = TransferPacer(fast: false)
        XCTAssertEqual(pacer.chunkSize, 24 * 1024)
        for sequence in 0..<64 {
            XCTAssertTrue(pacer.canSend(pacer.chunkSize))
            pacer.didSend("t", sequence: Int64(sequence), bytes: pacer.chunkSize)
        }
        XCTAssertFalse(pacer.canSend(pacer.chunkSize))
        pacer.acknowledged("t", through: 0)
        XCTAssertTrue(pacer.canSend(pacer.chunkSize))
    }

    func testFastWindowGrowsOnQuickAcknowledgementsAndShrinksOnQueueing() {
        var clock: TimeInterval = 100
        let pacer = TransferPacer(fast: true) { clock }
        XCTAssertEqual(pacer.windowBytes, TransferPacer.initialWindow)
        var sequence: Int64 = 0
        // A fast link: every chunk acknowledged 2 ms later while the window is full.
        for _ in 0..<200 {
            while pacer.canSend(pacer.chunkSize) {
                pacer.didSend("t", sequence: sequence, bytes: pacer.chunkSize)
                sequence += 1
            }
            clock += 0.002
            pacer.acknowledged("t", through: sequence - 1)
        }
        let grown = pacer.windowBytes
        XCTAssertGreaterThan(grown, TransferPacer.initialWindow * 4)
        XCTAssertLessThanOrEqual(grown, TransferPacer.maximumWindow)
        // A queue builds: acknowledgements now take 200 ms, far over the 2 ms base.
        for _ in 0..<20 {
            while pacer.canSend(pacer.chunkSize) {
                pacer.didSend("t", sequence: sequence, bytes: pacer.chunkSize)
                sequence += 1
            }
            clock += 0.2
            pacer.acknowledged("t", through: sequence - 1)
        }
        XCTAssertLessThan(pacer.windowBytes, grown / 4)
        XCTAssertGreaterThanOrEqual(pacer.windowBytes, Int64(2 * FastFrame.chunkSize))
    }

    func testFastPacerAlwaysLetsOneChunkThroughAndForgetFreesTheWindow() {
        let pacer = TransferPacer(fast: true)
        XCTAssertTrue(pacer.canSend(FastFrame.maximumPlaintext * 8))
        pacer.didSend("a", sequence: 0, bytes: Int(TransferPacer.initialWindow))
        XCTAssertFalse(pacer.canSend(FastFrame.chunkSize))
        pacer.forget("a")
        XCTAssertEqual(pacer.unacknowledgedBytes, 0)
        XCTAssertTrue(pacer.canSend(FastFrame.chunkSize))
    }

    func testWaitForRoomReturnsWhenAnAcknowledgementArrives() throws {
        let pacer = TransferPacer(fast: true)
        pacer.didSend("t", sequence: 0, bytes: Int(TransferPacer.initialWindow))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { pacer.acknowledged("t", through: 0) }
        let started = Date()
        try pacer.waitForRoom(FastFrame.chunkSize, timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        pacer.didSend("t", sequence: 1, bytes: Int(pacer.windowBytes))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { pacer.cancel() }
        XCTAssertThrowsError(try pacer.waitForRoom(FastFrame.chunkSize, timeout: 5))
    }

    func testSpeedMeterSmoothsAndGivesTimeLeft() {
        var meter = TransferSpeedMeter()
        XCTAssertTrue(meter.update(bytes: 0, at: 0))
        XCTAssertFalse(meter.update(bytes: 1_000, at: 0.1))
        XCTAssertTrue(meter.update(bytes: 10_000_000, at: 0.5))
        XCTAssertEqual(meter.bytesPerSecond, 20_000_000, accuracy: 1)
        _ = meter.update(bytes: 15_000_000, at: 1.0)
        XCTAssertLessThan(meter.bytesPerSecond, 20_000_000)
        XCTAssertGreaterThan(meter.bytesPerSecond, 10_000_000)
        XCTAssertNotNil(meter.secondsLeft(remaining: 30_000_000))
        XCTAssertNil(meter.secondsLeft(remaining: 0))
    }
}
