import Darwin
import Foundation
import XCTest
@testable import CallMediaTapProbe

final class CallMediaTapProbeBindingTests: XCTestCase {
    func testOnlyTheExactLiveSourceFrameCanMatchItsOwnerChallenge() {
        let identity = FixtureSourceIdentity(pid: 123, object: 456, instance: UUID())
        let challenge = UUID()
        let frame: [String: Any] = ["phase": "source-state", "pid": 123, "processObject": 456,
            "instance": identity.instance.uuidString, "challenge": challenge.uuidString, "runningOutput": 1]
        XCTAssertTrue(identity.matches(frame, challenge: challenge))
        for (key, value) in [("pid", 124 as Any), ("processObject", 457 as Any), ("instance", UUID().uuidString as Any),
                             ("phase", "owner-state" as Any), ("runningOutput", 0 as Any)] {
            var replaced = frame; replaced[key] = value
            XCTAssertFalse(identity.matches(replaced, challenge: challenge))
        }
        XCTAssertFalse(identity.matches(frame, challenge: UUID()))
    }

    func testArbitraryAudioObjectCLIFormIsRejectedWithoutStartingCapture() throws {
        let result = try runProbe(["--owner", "456"])
        XCTAssertEqual(result.0, 2)
        XCTAssertNotNil(result.1["usage"])
        XCTAssertNil(result.1["tap"])
    }

    func testOwnedSourceBindingAndExitChecksWithoutAnyCapture() throws {
        try requireIsolatedCallAudioHost()
        guard #available(macOS 14.2, *) else { throw XCTSkip("Native process objects require macOS 14.2") }
        let result = try runProbe(["--binding-check"])
        XCTAssertEqual(result.0, 0, "\(result.1)")
        for key in ["valid", "replacementRejected", "unrelatedRejected", "exitedRejected"] {
            XCTAssertEqual(result.1[key] as? Bool, true, key)
        }
        XCTAssertEqual(result.1["captureStarted"] as? Bool, false)
    }

    private func runProbe(_ arguments: [String]) throws -> (Int32, [String: Any]) {
        let binary = Bundle(for: Self.self).bundleURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("CallMediaTapProbe")
        let child = Process(), pipe = Pipe()
        child.executableURL = binary
        child.arguments = arguments
        child.environment = fixtureEnvironment()
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        let stopped = expectation(description: "owned probe exits")
        child.terminationHandler = { _ in stopped.fulfill() }
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        wait(for: [stopped], timeout: 15)
        guard !child.isRunning else { throw CocoaError(.executableRuntimeMismatch) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertLessThan(data.count, 8192)
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (child.terminationStatus, frame)
    }
}
