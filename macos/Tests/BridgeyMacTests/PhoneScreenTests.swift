import Foundation
import XCTest
@testable import BridgeyMac

/// The frame header, reassembly, Annex B, the sequence guard and parameter sets.
final class PhoneScreenProtocolTests: XCTestCase {
    private let stream = "6c2e9a14-3b5d-4e7f-8a90-1b2c3d4e5f60"
    private let sps = Data([0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40, 0x78])
    private let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])
    private let idr = Data([0x65, 0x88, 0x84, 0x21])

    private func part(_ frame: UInt32, _ index: Int, last: Bool, key: Bool = false, sequence: Int = 1, payload: Data? = nil) -> ScreenFramePart {
        ScreenFramePart(streamID: stream, sequence: sequence, frame: frame, part: index, key: key, parameterSets: key, last: last,
                        captureMicros: 5, payload: payload ?? (index == 0 ? Data([0, 0, 0, 1, 0x41, UInt8(frame & 0xFF)]) : Data([UInt8(index)])))
    }

    func testHeaderRoundTripsAndChecksItsLimits() throws {
        let original = part(7, 0, last: true, key: true, sequence: 42)
        let encoded = original.encoded()
        XCTAssertEqual(encoded.count, 40 + original.payload.count)
        XCTAssertEqual(encoded[0], 1)
        XCTAssertEqual(encoded[1], 0x07)
        XCTAssertEqual(ScreenFramePart.decode(encoded), original)
        var badVersion = encoded
        badVersion[0] = 2
        XCTAssertNil(ScreenFramePart.decode(badVersion))
        XCTAssertNil(ScreenFramePart.decode(encoded.prefix(40)), "header only")
        let middle = part(7, 1, last: false, payload: Data([0xAA]))
        XCTAssertEqual(ScreenFramePart.decode(middle.encoded())?.payload, Data([0xAA]), "later parts need no start code")
        let noStart = part(7, 0, last: true, payload: Data([0x41, 0x9A]))
        XCTAssertNil(ScreenFramePart.decode(noStart.encoded()))
        let big = part(7, 1, last: true, payload: Data(count: 32_768))
        XCTAssertNotNil(ScreenFramePart.decode(big.encoded()))
        XCTAssertNil(ScreenFramePart.decode(part(7, 1, last: true, payload: Data(count: 32_769)).encoded()))
    }

    func testAssemblerJoinsPartsInOrderAndLosesFramesOutOfOrder() {
        var assembler = ScreenFrameAssembler()
        XCTAssertEqual(assembler.add(part(1, 0, last: false, key: true)), .pending)
        XCTAssertEqual(assembler.add(part(1, 1, last: false)), .pending)
        guard case let .complete(frame) = assembler.add(part(1, 2, last: true)) else { return XCTFail("frame 1") }
        XCTAssertEqual(frame.frame, 1)
        XCTAssertTrue(frame.key)
        XCTAssertEqual(frame.data, Data([0, 0, 0, 1, 0x41, 1, 1, 2]))
        // A part of a finished frame is dropped quietly.
        XCTAssertEqual(assembler.add(part(1, 0, last: true)), .ignored)
        // Part 1 before part 0: lost.
        XCTAssertEqual(assembler.add(part(2, 1, last: true)), .lost(frame: 2))
        XCTAssertEqual(assembler.add(part(2, 0, last: true)), .ignored, "a lost frame stays lost")
        // A later frame starts before this one finished: the unfinished one is lost.
        XCTAssertEqual(assembler.add(part(3, 0, last: false)), .pending)
        XCTAssertEqual(assembler.add(part(4, 0, last: true)), .lost(frame: 4), "4 is complete, but 3 was lost and 4 is not a key frame")
        XCTAssertEqual(assembler.add(part(5, 0, last: false, key: true)), .pending)
        guard case let .complete(next) = assembler.add(part(5, 1, last: true)) else { return XCTFail("frame 5") }
        XCTAssertTrue(next.key)
    }

    func testAKeyFrameAfterALostOneStillDecodes() {
        var assembler = ScreenFrameAssembler()
        XCTAssertEqual(assembler.add(part(1, 0, last: false)), .pending)
        guard case let .complete(frame) = assembler.add(part(2, 0, last: true, key: true)) else { return XCTFail("key frame") }
        XCTAssertEqual(frame.frame, 2)
    }

    func testAnnexBSplitsNALUnitsAndBuildsAVCC() {
        var accessUnit = Data([0, 0, 0, 1])
        accessUnit.append(sps)
        accessUnit.append(contentsOf: [0, 0, 0, 1])
        accessUnit.append(pps)
        accessUnit.append(contentsOf: [0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1])
        accessUnit.append(idr)
        accessUnit.append(contentsOf: [0, 0])
        let units = AnnexB.nalUnits(accessUnit)
        XCTAssertEqual(units, [sps, pps, Data([0x09, 0xF0]), idr], "trailing zeros and start codes are not part of a unit")
        let split = AnnexB.avcc(accessUnit)
        XCTAssertEqual(split.sps, sps)
        XCTAssertEqual(split.pps, [pps])
        XCTAssertTrue(split.hasIDR)
        XCTAssertEqual(split.avcc, Data([0, 0, 0, 4]) + idr, "parameter sets and the delimiter are left out")
        XCTAssertTrue(annexBStartsWithStartCode(Data([0, 0, 1, 0x65])))
        XCTAssertTrue(annexBStartsWithStartCode(Data([0, 0, 0, 1, 0x65])))
        XCTAssertFalse(annexBStartsWithStartCode(Data([0, 0, 2, 1])))
        XCTAssertFalse(annexBStartsWithStartCode(Data([0, 0])))
    }

    func testSequenceIsAHighWaterMarkAfterTheStart() {
        var sequence = ScreenSequence(after: 1)
        XCTAssertFalse(sequence.accept(1), "the start's own sequence")
        XCTAssertTrue(sequence.accept(2))
        XCTAssertFalse(sequence.accept(2), "a replay")
        XCTAssertTrue(sequence.accept(10), "gaps are fine")
        XCTAssertFalse(sequence.accept(9))
        XCTAssertTrue(sequence.accept(ScreenLimits.maximumSequence))
        XCTAssertFalse(sequence.accept(ScreenLimits.maximumSequence + 1))
    }

    func testAckWritesKeyframeOnlyWhenAsked() {
        XCTAssertNil(screenAckPayload(streamID: stream, sequence: 2, frame: 3, decodeMs: 4, keyframe: false)["keyframe"])
        XCTAssertEqual(screenAckPayload(streamID: stream, sequence: 2, frame: 3, decodeMs: 4, keyframe: true)["keyframe"] as? Bool, true)
        XCTAssertEqual(screenAckPayload(streamID: stream, sequence: 2, frame: 3, decodeMs: 90_000, keyframe: false)["decodeMs"] as? Int, 60_000)
    }
}

/// Requests, starts, refusals and the Mac's own sequence numbers.
@MainActor
final class PhoneScreenTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var sent: [(device: String, kind: String, payload: [String: Any])] = []
    private var presenter: FakePresenter!
    private let streamID = "6c2e9a14-3b5d-4e7f-8a90-1b2c3d4e5f60"
    private let key = Data(repeating: 7, count: 32)

    private func make(enabled: Bool = true) -> PhoneScreen {
        let screen = PhoneScreen(defaults: nil, clock: { [unowned self] in self.now })
        screen.send = { [unowned self] device, kind, payload in self.sent.append((device, kind, payload)); return true }
        presenter = FakePresenter()
        screen.presenter = presenter
        if enabled { screen.setEnabled(true) }
        return screen
    }

    private func start(_ fields: [String: Any] = [:]) -> Data {
        var payload: [String: Any] = ["version": 1, "streamId": streamID, "sequence": 1, "codec": "h264", "width": 720, "height": 1600,
                                      "fps": 30, "bitrate": 4_000_000]
        payload.merge(fields) { $1 }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testOffByDefault() {
        let screen = PhoneScreen(defaults: nil)
        XCTAssertFalse(screen.enabled)
        XCTAssertNil(screen.request(from: "a", phoneName: "P"), "nothing is asked while the switch is off")
    }

    func testOneOpenRequestPerPhoneAtMostEveryThreeSeconds() throws {
        let screen = make()
        let id = try XCTUnwrap(screen.request(from: "a", phoneName: "OnePlus 11"))
        XCTAssertEqual(sent.last?.kind, "screen.request")
        XCTAssertEqual(sent.last?.payload["requestId"] as? String, id)
        XCTAssertNil(screen.request(from: "a", phoneName: "OnePlus 11"), "one open request")
        XCTAssertNotNil(screen.request(from: "b", phoneName: "Pixel"), "another phone has its own")
        screen.received(status: .declined, requestID: id, from: "a", phoneName: "OnePlus 11")
        XCTAssertEqual(screen.status, "OnePlus 11 did not share its screen")
        XCTAssertNil(screen.request(from: "a", phoneName: "OnePlus 11"), "at most one every 3 seconds")
        now = now.addingTimeInterval(3)
        XCTAssertNotNil(screen.request(from: "a", phoneName: "OnePlus 11"))
    }

    func testWaitingKeepsTheRequestAndItExpiresAfterTwoMinutes() throws {
        let screen = make()
        let id = try XCTUnwrap(screen.request(from: "a", phoneName: "OnePlus 11"))
        screen.received(status: .waiting, requestID: id, from: "a", phoneName: "OnePlus 11")
        XCTAssertEqual(screen.status, "Tap the notification on OnePlus 11")
        XCTAssertNotNil(screen.pending["a"])
        screen.received(status: .busy, requestID: UUID().uuidString.lowercased(), from: "a", phoneName: "OnePlus 11")
        XCTAssertNotNil(screen.pending["a"], "another request's status changes nothing")
        now = now.addingTimeInterval(PhoneScreen.lifetime)
        screen.tick()
        XCTAssertNil(screen.pending["a"])
        XCTAssertEqual(screen.status, "No answer from OnePlus 11")
    }

    func testAStartOpensTheWindowAnswersStartedAndClearsTheRequest() throws {
        let screen = make()
        let id = try XCTUnwrap(screen.request(from: "a", phoneName: "OnePlus 11"))
        screen.receiveStart(start(["requestId": id.uppercased()]), from: "a", phoneName: "OnePlus 11", key: key)
        XCTAssertEqual(presenter.opened, ["a"])
        XCTAssertEqual(presenter.size, [720, 1600])
        XCTAssertNil(screen.pending["a"])
        XCTAssertEqual(screen.streaming, ["a"])
        XCTAssertEqual(sent.last?.kind, "screen.started")
        XCTAssertEqual(sent.last?.payload["sequence"] as? Int, 1)
        XCTAssertEqual(sent.last?.payload["streamId"] as? String, streamID)
        // A second request while it shows brings the window forward instead.
        XCTAssertNil(screen.request(from: "a", phoneName: "OnePlus 11"))
        XCTAssertEqual(presenter.fronted, ["a"])
        // Stop in the window: screen.stop closed with the Mac's next sequence.
        screen.stopShowing("a")
        XCTAssertEqual(sent.last?.kind, "screen.stop")
        XCTAssertEqual(sent.last?.payload["reason"] as? String, "closed")
        XCTAssertEqual(sent.last?.payload["sequence"] as? Int, 2)
        XCTAssertEqual(presenter.closed.last?.0, "a")
        XCTAssertTrue(screen.streaming.isEmpty)
        // The same stream ID is never started again.
        sent.removeAll()
        screen.receiveStart(start(), from: "a", phoneName: "OnePlus 11", key: key)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(presenter.opened, ["a"])
    }

    func testStartsAreRefusedWhenOffOrInvalid() {
        let off = make(enabled: false)
        off.receiveStart(start(), from: "a", phoneName: "P", key: key)
        XCTAssertEqual(sent.last?.kind, "screen.stop")
        XCTAssertEqual(sent.last?.payload["reason"] as? String, "disabled")
        XCTAssertEqual(sent.last?.payload["sequence"] as? Int, 1)
        XCTAssertTrue(presenter.opened.isEmpty)
        sent.removeAll()
        let on = make()
        on.receiveStart(start(["codec": "h265", "streamId": "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"]), from: "a", phoneName: "P", key: key)
        XCTAssertEqual(sent.last?.payload["reason"] as? String, "invalid")
        XCTAssertTrue(presenter.opened.isEmpty)
        sent.removeAll()
        on.receiveStart(Data("{not json".utf8), from: "a", phoneName: "P", key: key)
        XCTAssertTrue(sent.isEmpty, "no stream ID: nothing to answer")
    }

    func testTheLastSixteenEndedStreamsAreRemembered() {
        let screen = make()
        var ids: [String] = []
        for _ in 0..<17 {
            let id = UUID().uuidString.lowercased()
            ids.append(id)
            screen.receiveStart(start(["streamId": id]), from: "a", phoneName: "P", key: key)
            screen.stopShowing("a")
        }
        XCTAssertEqual(screen.endedStreamIDs.count, 16)
        XCTAssertFalse(screen.endedStreamIDs.contains(ids[0]))
        XCTAssertTrue(screen.endedStreamIDs.contains(ids[16]))
    }

    func testTimeoutDisconnectAndSwitchingOffEndTheStream() {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "OnePlus 11", key: key)
        // The receiver's last activity is the real clock: a stream with no traffic for 6 seconds ends.
        now = Date().addingTimeInterval(PhoneScreen.streamTimeout + 1)
        screen.tick()
        XCTAssertEqual(sent.last?.payload["reason"] as? String, "timeout")
        XCTAssertTrue(screen.streaming.isEmpty)
        screen.receiveStart(start(["streamId": UUID().uuidString]), from: "a", phoneName: "OnePlus 11", key: key)
        sent.removeAll()
        screen.disconnected("a")
        XCTAssertTrue(sent.isEmpty, "nothing is sent to a phone that is gone")
        XCTAssertEqual(presenter.closed.last?.1, "OnePlus 11 disconnected")
        screen.receiveStart(start(["streamId": UUID().uuidString]), from: "a", phoneName: "OnePlus 11", key: key)
        screen.setEnabled(false)
        XCTAssertEqual(sent.last?.payload["reason"] as? String, "disabled")
        XCTAssertTrue(screen.streaming.isEmpty)
    }

    func testThePhoneStopsTheStream() throws {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "OnePlus 11", key: key)
        let receiver = try XCTUnwrap(screen.streams["a"]?.receiver)
        let stop = try JSONSerialization.data(withJSONObject: screenStopPayload(streamID: streamID, sequence: 2, reason: .screenOff))
        receiver.receivePlaintext(kind: "screen.stop", stop)
        receiver.sync()
        let closed = expectation(description: "closed")
        DispatchQueue.main.async { closed.fulfill() }
        wait(for: [closed], timeout: 2)
        XCTAssertTrue(screen.streaming.isEmpty)
        XCTAssertEqual(presenter.closed.last?.1, "OnePlus 11 locked its screen")
        XCTAssertEqual(sent.last?.kind, "screen.started", "a stop from the phone is not answered")
    }

    func testStatsReachTheWindowAndAStaleSequenceIsDropped() throws {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "OnePlus 11", key: key)
        let receiver = try XCTUnwrap(screen.streams["a"]?.receiver)
        func stats(_ sequence: Int, _ latency: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "streamId": streamID, "sequence": sequence, "latencyMs": latency, "rttMs": 4,
                                                        "bitrate": 4_000_000, "sentBitrate": 2_100_000, "fps": 30, "dropped": 0])
        }
        receiver.receivePlaintext(kind: "screen.stats", try stats(3, 48))
        receiver.receivePlaintext(kind: "screen.stats", try stats(2, 99))
        receiver.sync()
        let delivered = expectation(description: "stats")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(presenter.stats.map(\.latencyMs), [48])
        XCTAssertEqual(screenStatsLine(presenter.stats.last), "48 ms \u{00B7} 2.1 Mb/s \u{00B7} 30 fps")
    }
}

@MainActor
private final class FakePresenter: PhoneScreenPresenter {
    var opened: [String] = []
    var size: [Int] = []
    var fronted: [String] = []
    var closed: [(String, String?)] = []
    var stats: [ScreenStats] = []

    func open(deviceID: String, phoneName: String, width: Int, height: Int, onClose: @escaping () -> Void) -> ScreenDisplaySink? {
        opened.append(deviceID)
        size = [width, height]
        return nil
    }

    func update(deviceID: String, stats: ScreenStats) { self.stats.append(stats) }
    func resize(deviceID: String, width: Int, height: Int) { size = [width, height] }
    func bringToFront(deviceID: String) { fronted.append(deviceID) }
    func close(deviceID: String, message: String?) { closed.append((deviceID, message)) }
}
