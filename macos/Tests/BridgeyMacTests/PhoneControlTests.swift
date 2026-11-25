import AppKit
import XCTest
@testable import BridgeyMac

/// protocol/test-vectors/phone-control-v1.json from this Mac's side: what it reads from the phone and what it writes.
/// Android (PhoneControlVectorsTest) checks the same file.
final class PhoneControlVectorsTests: XCTestCase {
    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../protocol/test-vectors/phone-control-v1.json").standardizedFileURL
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func cases(_ name: String) throws -> [[String: Any]] { try XCTUnwrap(vectors[name] as? [[String: Any]]) }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func caps(_ value: Any?) throws -> ScreenControl.Capabilities { try ScreenControl.Capabilities.decode(object: value).get() }

    func testStartControlObjectsDecodeOrMakeTheStreamViewOnly() throws {
        for vector in try cases("startControl") {
            let name = vector["name"] as? String ?? ""
            let start = try XCTUnwrap(ScreenStart.decode(try data(vector["plaintext"]!)), "\(name): the start itself stays valid")
            guard let expect = vector["expect"] as? [String: Any] else {
                XCTAssertNil(start.control, name)
                continue
            }
            let control = try XCTUnwrap(start.control, name)
            XCTAssertEqual(control.stream, UInt64(expect["stream"] as! Int), name)
            XCTAssertEqual(control.transport, UInt64(expect["transport"] as! Int), name)
            XCTAssertEqual(control.geometry, ScreenControl.Geometry.decode(expect["geometry"]), name)
            XCTAssertEqual(control.capabilities, try caps(expect["capabilities"]), name)
            XCTAssertEqual(control.allowed, expect["allowed"] as? Bool, name)
        }
    }

    func testPhoneStreamMessagesDecodeAlike() throws {
        for vector in try cases("phoneStream") {
            let name = vector["name"] as? String ?? ""
            let bytes = try data(vector["plaintext"]!)
            let expect = vector["expect"] as? [String: Any]
            switch vector["kind"] as? String {
            case PhoneControlKinds.geometry:
                let message = PhoneGeometryMessage.decode(bytes)
                if let expect { XCTAssertEqual(message?.geometry, ScreenControl.Geometry.decode(expect["geometry"]), name) } else { XCTAssertNil(message, name) }
            case PhoneControlKinds.control:
                let message = PhoneControlMessage.decode(bytes)
                guard let expect else {
                    XCTAssertNil(message, name)
                    continue
                }
                let state = try XCTUnwrap(message, name).state
                switch expect["state"] as? String {
                case "waiting": XCTAssertEqual(state, .waiting, name)
                case "active":
                    let input = try XCTUnwrap(ScreenControl.InputCapabilities.decode(expect["input"]))
                    XCTAssertEqual(state, .active(session: UInt64(expect["session"] as! Int), input: input), name)
                case "ended": XCTAssertEqual(state, .ended(PhoneControlReason(rawValue: expect["reason"] as! String)!), name)
                case "refused": XCTAssertEqual(state, .refused(PhoneControlReason(rawValue: expect["reason"] as! String)!), name)
                case "available": XCTAssertEqual(state, .available(expect["allowed"] as! Bool), name)
                default: XCTFail(name)
                }
            default:
                XCTFail("unknown kind in \(name)")
            }
        }
    }

    func testTheControlMessagesThisMacWritesMatch() throws {
        var written = 0
        for vector in try cases("macStream") where vector["write"] as? Bool == true {
            let plaintext = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let streamID = plaintext["streamId"] as! String
            let sequence = plaintext["sequence"] as! Int
            let payload = plaintext["action"] as? String == "begin"
                ? phoneControlBeginPayload(streamID: streamID, sequence: sequence)
                : phoneControlEndPayload(streamID: streamID, sequence: sequence)
            XCTAssertEqual(payload as NSDictionary, plaintext as NSDictionary, vector["name"] as? String ?? "")
            written += 1
        }
        XCTAssertGreaterThanOrEqual(written, 2)
    }

    func testCapabilitiesAndNegotiation() throws {
        for vector in try cases("capabilities") where vector["side"] as? String == "mac" {
            XCTAssertEqual(macControllerCapabilities, try caps(vector["expect"]))
        }
        for vector in try cases("negotiated") {
            let result = ScreenControl.Capabilities.negotiatedInput(host: try caps(vector["host"]), controller: try caps(vector["controller"]))
            if let expect = vector["expect"] as? [String: Any] {
                XCTAssertEqual(try result.get(), ScreenControl.InputCapabilities.decode(expect), vector["name"] as? String ?? "")
            } else {
                XCTAssertThrowsError(try result.get(), vector["name"] as? String ?? "")
            }
        }
    }
}

/// The sender: numbering, coalescing per finger, ordered transitions, budgets, geometry acknowledgement and Stop.
final class PhoneControlSenderTests: XCTestCase {
    private var now: UInt64 = 10_000
    private lazy var sender = PhoneControlSender(clock: { [unowned self] in self.now })
    private let binding = PhoneControlSender.Binding(transport: 3, connection: Array(repeating: 9, count: 16), stream: 1)
    private let all = ScreenControl.InputCapabilities(pointer: true, touch: true, keys: true, text: true, navigation: true)

    func testNothingGoesWithoutASessionAndTheFirstPacketAcknowledgesTheGeometry() {
        XCTAssertFalse(sender.submit(.navigate(.back)))
        XCTAssertTrue(sender.flush().isEmpty)
        let first = sender.begin(session: 4, input: all, binding: binding, geometryGeneration: 2)
        XCTAssertEqual(first.map(\.input), [.geometryAck])
        XCTAssertEqual(first.first?.seq, 1)
        XCTAssertEqual(first.first?.geometry, 2)
        XCTAssertEqual(first.first?.session, 4)
        XCTAssertEqual(first.first?.transport, 3)
        XCTAssertEqual(try ScreenControl.Packet.decode(first[0].encoded()).get(), first[0])
        XCTAssertTrue(sender.begin(session: 4, input: all, binding: .init(transport: 3, connection: Array(repeating: 0, count: 16), stream: 1), geometryGeneration: 2).isEmpty)
    }

    func testTransitionsStayInOrderAndEachFingersMotionIsCoalesced() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        XCTAssertTrue(sender.submit(.touch(contact: 0, phase: .down, x: 0.1, y: 0.1)))
        XCTAssertTrue(sender.submit(.touch(contact: 1, phase: .down, x: 0.9, y: 0.1)))
        XCTAssertTrue(sender.submit(.touch(contact: 0, phase: .move, x: 0.2, y: 0.1)))
        XCTAssertTrue(sender.submit(.touch(contact: 1, phase: .move, x: 0.8, y: 0.1)))
        XCTAssertTrue(sender.submit(.touch(contact: 0, phase: .move, x: 0.3, y: 0.1)))
        XCTAssertTrue(sender.submit(.touch(contact: 1, phase: .move, x: 0.7, y: 0.1)))
        XCTAssertEqual(sender.pending, 4, "one move per finger waits")
        XCTAssertTrue(sender.submit(.touch(contact: 0, phase: .up, x: 0.3, y: 0.1)))
        let packets = sender.flush()
        XCTAssertEqual(packets.map(\.input), [
            .touch(contact: 0, phase: .down, x: 0.1, y: 0.1), .touch(contact: 1, phase: .down, x: 0.9, y: 0.1),
            .touch(contact: 0, phase: .move, x: 0.3, y: 0.1), .touch(contact: 1, phase: .move, x: 0.7, y: 0.1),
            .touch(contact: 0, phase: .up, x: 0.3, y: 0.1),
        ])
        XCTAssertEqual(packets.map(\.seq), [2, 3, 4, 5, 6])
    }

    func testUnmatchedTransitionsAndUnsupportedInputAreRefused() {
        _ = sender.begin(session: 1, input: ScreenControl.InputCapabilities(pointer: true, touch: true, navigation: true), binding: binding, geometryGeneration: 1)
        XCTAssertFalse(sender.submit(.touch(contact: 0, phase: .up, x: 0.5, y: 0.5)))
        XCTAssertFalse(sender.submit(.touch(contact: 0, phase: .move, x: 0.5, y: 0.5)))
        XCTAssertFalse(sender.submit(.touch(contact: 10, phase: .down, x: 0.5, y: 0.5)))
        XCTAssertFalse(sender.submit(.touch(contact: 0, phase: .down, x: 1.5, y: 0.5)))
        XCTAssertFalse(sender.submit(.text("no typing on Android 12")))
        XCTAssertFalse(sender.submit(.key(.enter, down: true)))
        XCTAssertEqual(sender.dropped, 6)
    }

    func testModifierKeysNeverGo() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        XCTAssertFalse(sender.submit(.key(.control, down: true)))
        XCTAssertFalse(sender.submit(.key(.meta, down: true)))
        XCTAssertTrue(sender.press(.left, shift: true))
        XCTAssertEqual(sender.flush().map(\.input), [.key(.shift, down: true), .key(.left, down: true), .key(.left, down: false), .key(.shift, down: false)])
    }

    func testFastTypingJoinsIntoOnePacket() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        for character in "Hello" { XCTAssertTrue(sender.submit(.text(String(character)))) }
        XCTAssertEqual(sender.flush().map(\.input), [.text("Hello")])
    }

    func testBudgetsHoldBackButNeverDropATransition() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        for _ in 0..<20 { sender.submit(.navigate(.back)) }
        XCTAssertEqual(sender.flush().count, 16, "16 discrete a second, under the phone's 20")
        XCTAssertEqual(sender.pending, 4)
        now += 1_000
        XCTAssertEqual(sender.flush().count, 4)
    }

    func testScrollAccumulatesAndSplitsAtTheContractBound() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        sender.submit(.scroll(dx: 0, dy: 700, x: 0.5, y: 0.5))
        sender.submit(.scroll(dx: 0, dy: 700, x: 0.5, y: 0.6))
        XCTAssertEqual(sender.flush().map(\.input), [.scroll(dx: 0, dy: 1_000, x: 0.5, y: 0.6), .scroll(dx: 0, dy: 400, x: 0.5, y: 0.6)])
    }

    func testAGeometryChangeDropsWhatWasNotSentAndAcknowledgesFirst() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        sender.submit(.touch(contact: 0, phase: .down, x: 0.5, y: 0.5))
        sender.submit(.navigate(.home))
        let ack = sender.geometryChanged(2)
        XCTAssertEqual(ack.map(\.input), [.geometryAck])
        XCTAssertEqual(ack.first?.geometry, 2)
        XCTAssertEqual(sender.pending, 0)
        XCTAssertTrue(sender.geometryChanged(2).isEmpty, "an old or repeated generation changes nothing")
        XCTAssertTrue(sender.submit(.touch(contact: 0, phase: .down, x: 0.5, y: 0.5)), "the finger was forgotten with the geometry")
    }

    func testStopIsNeverRateLimitedAndEndsTheSession() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        for _ in 0..<40 { sender.submit(.navigate(.back)) }
        _ = sender.flush()
        let stop = sender.stop()
        XCTAssertEqual(stop?.input, .stop)
        XCTAssertFalse(sender.active)
        XCTAssertNil(sender.stop())
    }

    func testAHeartbeatEveryTwoSeconds() {
        _ = sender.begin(session: 1, input: all, binding: binding, geometryGeneration: 1)
        XCTAssertTrue(sender.flush().isEmpty)
        now += 2_000
        XCTAssertEqual(sender.flush().map(\.input), [.heartbeat])
    }
}

/// The window's mapping of mouse, trackpad and keyboard to phone input.
@MainActor
final class PhoneScreenInputTests: XCTestCase {
    private var sent: [PhoneControlAction] = []
    private var pressed: [(ScreenControl.Key, Bool)] = []
    private var later: [() -> Void] = []
    private var on = true

    /// A 400 by 800 view showing a 720 by 1600 stream: 360 by 800 picture with 20-point bars left and right.
    private func make() -> PhoneScreenInput {
        let input = PhoneScreenInput()
        input.send = { [unowned self] in sent.append($0); return true }
        input.press = { [unowned self] key, shift in pressed.append((key, shift)); return true }
        input.layout = { (CGSize(width: 400, height: 800), 720, 1600) }
        input.active = { [unowned self] in on }
        input.schedule = { [unowned self] _, work in later.append(work) }
        return input
    }

    func testAClickIsATapAtThePictureFraction() {
        let input = make()
        input.mouseDown(at: CGPoint(x: 200, y: 400))
        input.mouseUp(at: CGPoint(x: 200, y: 400))
        XCTAssertEqual(sent, [.touch(contact: 0, phase: .down, x: 0.5, y: 0.5), .touch(contact: 0, phase: .up, x: 0.5, y: 0.5)])
    }

    func testTheLetterboxSendsNothingAndADragStaysOnTheEdge() {
        let input = make()
        input.mouseDown(at: CGPoint(x: 10, y: 400))
        input.mouseDragged(at: CGPoint(x: 100, y: 400))
        input.mouseUp(at: CGPoint(x: 100, y: 400))
        XCTAssertTrue(sent.isEmpty)
        input.mouseDown(at: CGPoint(x: 380, y: 400))
        input.mouseDragged(at: CGPoint(x: 395, y: 400))
        XCTAssertEqual(sent.last, .touch(contact: 0, phase: .move, x: 1, y: 0.5))
    }

    func testNothingIsSentUnlessControlIsOn() {
        on = false
        let input = make()
        input.mouseDown(at: CGPoint(x: 200, y: 400))
        input.scroll(dx: 0, dy: 10, precise: true, at: CGPoint(x: 200, y: 400))
        XCTAssertFalse(input.key(keyCode: 0, characters: "a", modifiers: []))
        XCTAssertTrue(sent.isEmpty)
    }

    func testARightClickIsALongPress() {
        let input = make()
        input.rightMouseDown(at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(sent, [.touch(contact: 0, phase: .down, x: 0.5, y: 0.25)])
        later.forEach { $0() }
        XCTAssertEqual(sent.last, .touch(contact: 0, phase: .up, x: 0.5, y: 0.25))
    }

    func testScrollingMovesTheContentByStreamPixels() {
        let input = make()
        // 360 view points show 720 stream pixels: 10 points are 20 pixels; fractions carry over.
        input.scroll(dx: 0, dy: 10, precise: true, at: CGPoint(x: 200, y: 400))
        input.scroll(dx: 0.25, dy: 0, precise: true, at: CGPoint(x: 200, y: 400))
        input.scroll(dx: 0.25, dy: 0, precise: true, at: CGPoint(x: 200, y: 400))
        XCTAssertEqual(sent, [.scroll(dx: 0, dy: 20, x: 0.5, y: 0.5), .scroll(dx: 1, dy: 0, x: 0.5, y: 0.5)])
        sent.removeAll()
        input.scroll(dx: 0, dy: -1, precise: false, at: CGPoint(x: 200, y: 400))
        XCTAssertEqual(sent, [.scroll(dx: 0, dy: -48, x: 0.5, y: 0.5)], "a wheel line is 24 points")
    }

    func testAPinchIsTwoFingersMovingApart() {
        let input = make()
        input.magnify(0, phase: .began, at: CGPoint(x: 200, y: 400))
        input.magnify(0.5, phase: .changed, at: CGPoint(x: 200, y: 400))
        input.magnify(0, phase: .ended, at: CGPoint(x: 200, y: 400))
        let downs = sent.filter { if case .touch(_, .down, _, _) = $0 { return true }; return false }
        let ups = sent.filter { if case .touch(_, .up, _, _) = $0 { return true }; return false }
        XCTAssertEqual(downs.count, 2)
        XCTAssertEqual(ups.count, 2)
        guard case let .touch(0, .down, x0, _) = downs[0], case let .touch(0, .up, x1, _) = ups[0] else { return XCTFail() }
        XCTAssertLessThan(x1, x0, "the left finger moved further left")
    }

    func testKeysBecomeNamedKeysOrTextAndShortcutsStayOnTheMac() {
        let input = make()
        XCTAssertTrue(input.key(keyCode: 36, characters: "\r", modifiers: []))
        XCTAssertTrue(input.key(keyCode: 123, characters: "\u{F702}", modifiers: [.shift]))
        XCTAssertTrue(input.key(keyCode: 0, characters: "ä", modifiers: []))
        XCTAssertFalse(input.key(keyCode: 13, characters: "w", modifiers: [.command]))
        XCTAssertFalse(input.key(keyCode: 0, characters: "a", modifiers: [.control]))
        XCTAssertEqual(pressed.map(\.0), [.enter, .left])
        XCTAssertEqual(pressed.map(\.1), [false, true])
        XCTAssertEqual(sent, [.text("ä")])
    }

    func testPasteTypesLinesWithReturnBetweenThemInChunks() {
        let input = make()
        XCTAssertTrue(input.paste("one\r\ntwo"))
        XCTAssertEqual(sent, [.text("one"), .text("two")])
        XCTAssertEqual(pressed.map(\.0), [.enter])
        XCTAssertEqual(PhoneScreenInput.chunks(String(repeating: "я", count: 600)).map { $0.unicodeScalars.count }, [256, 256, 88])
    }
}

/// The coordinator: a control-capable stream, the phone's answers, geometry and endings.
@MainActor
final class PhoneScreenControlTests: XCTestCase {
    private var sent: [(kind: String, payload: [String: Any])] = []
    private var presenter: PhoneScreenFakePresenter!
    private let streamID = "0d3c2b1a-5948-4776-a5b4-c3d2e1f00a1b"
    private let key = Data(repeating: 7, count: 32)
    private var shows = true

    private func make() -> PhoneScreen {
        let screen = PhoneScreen(defaults: nil)
        screen.send = { [unowned self] _, kind, payload in sent.append((kind, payload)); return true }
        screen.phoneControlAvailable = { [unowned self] _ in shows }
        presenter = PhoneScreenFakePresenter()
        screen.presenter = presenter
        screen.setEnabled(true)
        return screen
    }

    private func start(control: Any? = nil) -> Data {
        var payload: [String: Any] = ["version": 1, "streamId": streamID, "sequence": 1, "codec": "h264", "width": 720, "height": 1600, "fps": 30, "bitrate": 4_000_000]
        payload["control"] = control ?? ["stream": 1, "transport": 3, "geometry": ["generation": 1, "source": 1, "kind": "display", "width": 720, "height": 1600],
                                         "capabilities": ["v": 1, "screenSource": true, "fullDisplaySource": true, "h264Encode": true, "captureRequiresPrompt": true,
                                                          "inputHost": ["pointer": true, "touch": true, "keys": true, "text": true, "navigation": true]],
                                         "allowed": true]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func phone(_ screen: PhoneScreen, _ kind: String, _ payload: [String: Any]) throws {
        let receiver = try XCTUnwrap(screen.streams["a"]?.receiver)
        receiver.receivePlaintext(kind: kind, try JSONSerialization.data(withJSONObject: payload))
        receiver.sync()
        let delivered = expectation(description: kind)
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)
    }

    private var inputs: [[String: Any]] { sent.filter { $0.kind == PhoneControlKinds.input }.map { $0.payload["input"] as! [String: Any] } }

    func testAControlCapableStreamGetsTheBarAndControlStartsOnlyWhenThePhoneSaysSo() throws {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "Pixel", key: key, sessionID: "s1")
        XCTAssertEqual(presenter.controllable, [true])
        XCTAssertEqual(screen.controlState("a")?.allowed, true)
        screen.beginControl("a")
        XCTAssertEqual(sent.last?.kind, PhoneControlKinds.control)
        XCTAssertEqual(sent.last?.payload["action"] as? String, "begin")
        XCTAssertEqual(sent.last?.payload["sequence"] as? Int, 2)
        XCTAssertFalse(screen.controlInput("a", .navigate(.back)), "nothing goes before the phone answers")
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 2, "state": "waiting"])
        XCTAssertEqual(screen.controlState("a")?.phase, .waiting)
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 3, "state": "active", "session": 5,
                                                     "input": ["pointer": true, "touch": true, "keys": true, "text": true, "navigation": true]])
        XCTAssertEqual(screen.controlState("a")?.phase, .active)
        let ack = try XCTUnwrap(sent.last { $0.kind == PhoneControlKinds.input }?.payload)
        XCTAssertEqual(ack["session"] as? Int, 5)
        XCTAssertEqual(ack["transport"] as? Int, 3)
        XCTAssertEqual(ack["connection"] as? [Int], ScreenControl.connectionNonce(sessionKey: key, sessionID: "s1").map(Int.init))
        XCTAssertEqual((ack["input"] as? [String: Any])?["op"] as? String, "geometry_ack")
        XCTAssertTrue(screen.controlInput("a", .navigate(.home)))
        XCTAssertEqual(inputs.last?["action"] as? String, "home")
    }

    func testAPhoneWithoutTheKeyOrAMalformedObjectIsViewOnly() {
        shows = false
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "Pixel", key: key)
        XCTAssertEqual(presenter.controllable, [false])
        screen.beginControl("a")
        XCTAssertNotEqual(sent.last?.kind, PhoneControlKinds.control)
        shows = true
        let other = make()
        sent.removeAll()
        other.receiveStart(start(control: ["stream": 0]), from: "a", phoneName: "Pixel", key: key)
        XCTAssertEqual(presenter.controllable, [false])
        XCTAssertEqual(sent.map(\.kind), ["screen.started"], "the stream itself starts")
    }

    func testRotationDropsPendingInputAndAcknowledgesTheNewGeneration() throws {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "Pixel", key: key)
        screen.beginControl("a")
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 2, "state": "active", "session": 1,
                                                     "input": ["touch": true, "pointer": true, "navigation": true]])
        XCTAssertTrue(screen.controlInput("a", .touch(contact: 0, phase: .down, x: 0.5, y: 0.5)))
        XCTAssertTrue(screen.controlInput("a", .touch(contact: 0, phase: .move, x: 0.6, y: 0.5)))
        try phone(screen, PhoneControlKinds.geometry, ["version": 1, "streamId": streamID, "sequence": 3,
                                                      "geometry": ["generation": 2, "source": 1, "kind": "display", "width": 1600, "height": 720]])
        let last = try XCTUnwrap(sent.last?.payload)
        XCTAssertEqual(last["geometry"] as? Int, 2)
        XCTAssertEqual((last["input"] as? [String: Any])?["op"] as? String, "geometry_ack")
        screen.flushControl()
        XCTAssertEqual(inputs.last?["op"] as? String, "geometry_ack", "the queued move was dropped")
        XCTAssertEqual(screen.controlState("a")?.width, 1600)
        XCTAssertEqual(screen.controlState("a")?.epoch, 1)
    }

    func testThePhoneEndingControlShowsWhyAndTheStreamGoesOn() throws {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "Pixel", key: key)
        screen.beginControl("a")
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 2, "state": "refused", "reason": "permission"])
        XCTAssertEqual(screen.controlState("a")?.phase, .off)
        XCTAssertEqual(screen.controlState("a")?.note, .permission)
        XCTAssertEqual(phoneControlNoteText(.permission, phone: "Pixel"), "Turn on Bridgey control on Pixel")
        XCTAssertEqual(screen.streaming, ["a"])
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 3, "state": "available", "allowed": false])
        XCTAssertEqual(screen.controlState("a")?.allowed, false)
        sent.removeAll()
        screen.beginControl("a")
        XCTAssertTrue(sent.isEmpty, "control cannot be asked for while the phone says no")
    }

    func testThePhoneWithdrawingTheKeyEndsControlHere() throws {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "Pixel", key: key)
        screen.beginControl("a")
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 2, "state": "active", "session": 1,
                                                     "input": ["touch": true, "pointer": true, "navigation": true]])
        screen.phoneControlChanged("a", available: false)
        XCTAssertEqual(screen.controlState("a")?.phase, .off)
        XCTAssertEqual(screen.controlState("a")?.note, .disabled)
        XCTAssertEqual(screen.controlState("a")?.allowed, false)
        XCTAssertFalse(screen.controlInput("a", .navigate(.back)))
        screen.phoneControlChanged("a", available: true)
        XCTAssertEqual(screen.controlState("a")?.allowed, true)
    }

    func testStopControlSendsTheContractStopAndTheStreamStopEndsControl() throws {
        let screen = make()
        screen.receiveStart(start(), from: "a", phoneName: "Pixel", key: key)
        screen.beginControl("a")
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 2, "state": "active", "session": 1,
                                                     "input": ["touch": true, "pointer": true, "navigation": true]])
        screen.endControl("a")
        XCTAssertEqual(inputs.last?["op"] as? String, "stop")
        XCTAssertEqual(screen.controlState("a")?.phase, .off)
        screen.beginControl("a")
        try phone(screen, PhoneControlKinds.control, ["version": 1, "streamId": streamID, "sequence": 3, "state": "active", "session": 2,
                                                     "input": ["touch": true, "pointer": true, "navigation": true]])
        screen.stopShowing("a")
        XCTAssertNil(screen.controlState("a"))
        XCTAssertFalse(screen.controlInput("a", .navigate(.back)))
    }
}
