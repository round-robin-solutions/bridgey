import AudioToolbox
import CoreAudio
import Darwin
import XCTest
@testable import BridgeyMac

/// Native resource checks use only this test process's silent output. No installed player,
/// microphone, recording, default route, or master-volume setting is changed.
final class CallMediaCoreAudioNativeTests: XCTestCase {
    private func processObject(_ pid: pid_t) throws -> AudioObjectID {
        var pid = pid, object = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr, object != kAudioObjectUnknown else {
            throw XCTSkip("This runner has no Core Audio process object for the silent fixture")
        }
        return object
    }

    private func silentOutput() throws -> AudioQueueRef {
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var queue: AudioQueueRef?
        let status = AudioQueueNewOutput(&format, { _, queue, buffer in
            memset(buffer.pointee.mAudioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
            buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }, nil, nil, nil, 0, &queue)
        guard status == noErr, let queue else { throw XCTSkip("No native output device for the silent fixture: \(status)") }
        do {
            for _ in 0..<3 {
                var buffer: AudioQueueBufferRef?
                guard AudioQueueAllocateBuffer(queue, 4096, &buffer) == noErr, let buffer else {
                    throw XCTSkip("Could not allocate the silent fixture")
                }
                memset(buffer.pointee.mAudioData, 0, 4096)
                buffer.pointee.mAudioDataByteSize = 4096
                XCTAssertEqual(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), noErr)
            }
            guard AudioQueueStart(queue, nil) == noErr else { throw XCTSkip("Silent fixture cannot start on this runner") }
            return queue
        } catch { AudioQueueDispose(queue, true); throw error }
    }

    private func hasTap(_ tap: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(tap, &address)
    }

    func testNativePrivateMuteResourceCanBeCreatedVerifiedAndReleased() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let queue = try silentOutput()
        defer { AudioQueueDispose(queue, true) }
        let target = CallMediaProcessTarget(sessionID: "isolated-silent-fixture", processObject: try processObject(getpid()), routeID: "fixture")
        let driver = CallMediaCoreAudioTap(queue: DispatchQueue(label: "bridgey.native-tap-fixture"))
        let tap: UInt32
        switch driver.create(target) {
        case .success(let value): tap = value
        case .failure(.permissionNeeded): throw XCTSkip("System audio permission denied for native test fixture")
        case .failure(let issue): XCTFail("Native mute-only tap creation failed: \(issue)"); return
        }
        defer { _ = driver.destroy(tap) }
        XCTAssertTrue(hasTap(tap))
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var description: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description), noErr)
        let observed = try XCTUnwrap(description?.takeRetainedValue())
        XCTAssertEqual(observed.muteBehavior, .muted)
        XCTAssertTrue(observed.isPrivate)
        XCTAssertFalse(observed.isExclusive)
        if #available(macOS 26.0, *) { XCTAssertFalse(observed.isProcessRestoreEnabled) }
        XCTAssertTrue(driver.destroy(tap))
        XCTAssertFalse(hasTap(tap))
        XCTAssertTrue(driver.destroy(tap), "already-destroyed resources count as released")
    }

    func testNativeOwnerForceKillDoesNotLeaveItsPrivateMuteResource() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let queue = try silentOutput()
        defer { AudioQueueDispose(queue, true) }
        let object = try processObject(getpid())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-tap-crash-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("owner.json")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "BridgeyMacTests.CallMediaCoreAudioNativeTests/testIsolatedTapOwnerFixture",
                           Bundle(for: Self.self).bundleURL.path]
        child.environment = ProcessInfo.processInfo.environment.merging([
            "BRIDGEY_TAP_FIXTURE_OBJECT": String(object), "BRIDGEY_TAP_FIXTURE_REPORT": report.path,
        ]) { _, new in new }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
        let ready = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: report.path) }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        let data = try Data(contentsOf: report)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        guard result["permissionDenied"] != 1 else { throw XCTSkip("System audio permission denied for native child fixture") }
        let tap = UInt32(try XCTUnwrap(result["tap"]))
        XCTAssertEqual(result["pid"], Int(child.processIdentifier), "only the owned child may be killed")
        guard hasTap(tap) else {
            throw XCTSkip("Private tap is hidden from its supervisor; crash cleanup cannot be verified by this runner")
        }
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        let gone = expectation(for: NSPredicate { [self] _, _ in !hasTap(tap) }, evaluatedWith: nil)
        wait(for: [gone], timeout: 5)
        XCTAssertFalse(hasTap(tap))
    }

    func testIsolatedTapOwnerFixture() throws {
        guard let text = ProcessInfo.processInfo.environment["BRIDGEY_TAP_FIXTURE_OBJECT"],
              let object = UInt32(text),
              let path = ProcessInfo.processInfo.environment["BRIDGEY_TAP_FIXTURE_REPORT"] else {
            throw XCTSkip("Child fixture only")
        }
        let driver = CallMediaCoreAudioTap(queue: DispatchQueue(label: "bridgey.native-child-tap"))
        let result = driver.create(CallMediaProcessTarget(sessionID: "isolated-parent-fixture", processObject: object, routeID: "fixture"))
        var report = ["pid": Int(getpid())]
        let tap: UInt32
        switch result {
        case .success(let value): tap = value; report["tap"] = Int(value)
        case .failure(let issue):
            report["permissionDenied"] = issue == .permissionNeeded ? 1 : 0
            try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: path), options: .atomic)
            return
        }
        defer { _ = driver.destroy(tap) }
        try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: path), options: .atomic)
        // The supervisor kills this fixture, not a real app. A bounded deadline also cleans up
        // after a failed supervisor rather than leaving a permanent helper process.
        Thread.sleep(forTimeInterval: 20)
    }
}
