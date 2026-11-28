@testable import Bridgey
import CoreMedia
import XCTest

/// Touches to stream fractions and gestures to commands: the letterbox as display-v1.json pins it, the Mac's click,
/// and typed text split into text and key presses.
final class ScreenInputTests: XCTestCase {
    /// protocol/test-vectors/display-v1.json, read from the checkout the tests were built from (the simulator runs on
    /// the same Mac). Skipped when it can't be read.
    private func vectors() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("protocol/test-vectors/display-v1.json")
        guard let data = try? Data(contentsOf: file) else { throw XCTSkip("display-v1.json is not reachable from the simulator") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLetterboxMatchesTheVectors() throws {
        let cases = try XCTUnwrap(try vectors()["letterbox"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let view = c["view"] as! [Double], video = c["video"] as! [Double], touch = c["touch"] as! [Double]
            let got = Letterbox.fraction(view: CGSize(width: view[0], height: view[1]), video: CGSize(width: video[0], height: video[1]),
                                         point: CGPoint(x: touch[0], y: touch[1]))
            if let expect = c["expect"] as? [Double] {
                let p = try XCTUnwrap(got, name)
                XCTAssertEqual(Double(p.x), expect[0], accuracy: 1e-9, name)
                XCTAssertEqual(Double(p.y), expect[1], accuracy: 1e-9, name)
            } else {
                XCTAssertNil(got, "\(name): on the letterbox")
            }
        }
    }

    func testAFingerSlidingOntoTheLetterboxStaysOnTheEdge() {
        let p = Letterbox.clampedFraction(view: CGSize(width: 400, height: 800), video: CGSize(width: 1600, height: 1000), point: CGPoint(x: -20, y: 10))
        XCTAssertEqual(p, CGPoint(x: 0, y: 0))
        XCTAssertEqual(Letterbox.streamPixels(view: CGSize(width: 400, height: 800), video: CGSize(width: 1600, height: 1000), distance: CGPoint(x: 10, y: -5)),
                       CGPoint(x: 40, y: -20))
    }

    func testAMacTapIsPointerThenAClick() {
        let commands = ScreenCommands.click(at: CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(commands.map { $0["op"] as? String }, ["pointer", "button", "button"])
        XCTAssertEqual(commands[1]["down"] as? Bool, true)
        XCTAssertEqual(commands[2]["down"] as? Bool, false)
        XCTAssertEqual(commands[2]["button"] as? String, "primary")
        XCTAssertEqual(commands[0]["x"] as? Double, 0.25)
        XCTAssertEqual(ScreenCommands.click(at: .zero, button: "secondary")[1]["button"] as? String, "secondary")
    }

    func testTypedTextSplitsIntoTextAndKeys() {
        let commands = ScreenCommands.typed("hi\nthere\t\u{7}!")
        XCTAssertEqual(commands.map { $0["op"] as? String }, ["text", "press", "text", "press", "text"])
        XCTAssertEqual(commands.map { ($0["text"] ?? $0["key"]) as? String }, ["hi", "enter", "there", "tab", "!"])
        XCTAssertTrue(ScreenCommands.typed("").isEmpty)
        // Long pastes go in pieces the contract takes.
        XCTAssertEqual(ScreenCommands.typed(String(repeating: "a", count: 450)).count, 3)
    }

    func testOnlyNamedKeysAndNeverModifiers() {
        XCTAssertEqual(ScreenSurfaceView.namedKey(.keyboardLeftArrow), "left")
        XCTAssertEqual(ScreenSurfaceView.namedKey(.keyboardPageDown), "page_down")
        XCTAssertNil(ScreenSurfaceView.namedKey(.keyboardLeftControl))
        XCTAssertNil(ScreenSurfaceView.namedKey(.keyboardLeftGUI))
        XCTAssertNil(ScreenSurfaceView.namedKey(.keyboardLeftAlt))
    }

    func testAnnexBBecomesAVCCWithItsParameterSets() {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9, 9, 0, 0]
        let unit = annexB.withUnsafeBytes { H264.accessUnit($0) }
        XCTAssertEqual(unit.sps, Data([0x67, 1, 2]))
        XCTAssertEqual(unit.pps, Data([0x68, 3]))
        XCTAssertTrue(unit.hasPicture)
        XCTAssertEqual(unit.avcc, Data([0, 0, 0, 4, 0x65, 9, 9, 9]))
        XCTAssertEqual(H264.annexB(avcc: unit.avcc, sps: unit.sps, pps: unit.pps), Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9, 9]))
    }

    /// A key frame VideoToolbox encodes here decodes through the same path the stream uses.
    func testTheDecoderShowsAnEncodedFrame() throws {
        let frame = try XCTUnwrap(DemoScreens.encode(DemoScreens.phoneHome()), "VideoToolbox encodes the picture")
        let sink = CountingSink()
        let decoder = ScreenDecoder(sink: sink)
        let outcome = frame.withUnsafeBytes { decoder.decode($0, key: true) }
        XCTAssertEqual(outcome, .shown)
        XCTAssertEqual(sink.count, 1)
        // Without a key frame first, a new decoder shows nothing.
        let fresh = ScreenDecoder(sink: sink)
        XCTAssertEqual(frame.withUnsafeBytes { fresh.decode($0, key: false) }, .skipped)
    }
}

/// Counts the pictures a decoder hands over.
final class CountingSink: ScreenFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var shown = 0
    var count: Int { lock.withLock { shown } }
    func show(_ sample: CMSampleBuffer) { lock.withLock { shown += 1 } }
}
