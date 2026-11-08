import AudioToolbox
import CoreAudio
import Darwin
import XCTest
@testable import BridgeyMac

/// Native resource checks use only this test process's silent output. No installed player,
/// microphone, recording, default route, or master-volume setting is changed.
final class CallMediaCoreAudioNativeTests: XCTestCase {
    override func setUpWithError() throws { try requireIsolatedCallAudioHost() }
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

    private func ownedTapIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioObjectID>.size) == 0, size <= 4096 else {
            throw CocoaError(.fileReadUnknown)
        }
        if size == 0 { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let capacity = size
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr,
              size == capacity else { throw CocoaError(.fileReadUnknown) }
        return objects
    }

    func testNativeUnmutedInputOnlyResourcesCanBePreparedAndReleased() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let queue = try silentOutput()
        defer { AudioQueueDispose(queue, true) }
        let target = CallMediaProcessTarget(sessionID: "isolated-silent-fixture", processObject: try processObject(getpid()), routeID: "fixture")
        let driver = CallMediaCoreAudioTap(queue: DispatchQueue(label: "bridgey.native-tap-fixture"))
        let tap: CallMediaProcessTap
        switch driver.create(target) {
        case .success(let value): tap = value
        case .failure(.permissionNeeded): throw XCTSkip("System audio permission denied for native test fixture")
        case .failure(let issue): XCTFail("Native mute-only tap creation failed: \(issue)"); return
        }
        defer { _ = driver.destroy(tap) }
        XCTAssertTrue(hasTap(tap.objectID))
        XCTAssertTrue(try ownedTapIDs().contains(tap.objectID))
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var description: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        XCTAssertEqual(AudioObjectGetPropertyData(tap.objectID, &address, 0, nil, &size, &description), noErr)
        let observed = try XCTUnwrap(description?.takeRetainedValue())
        XCTAssertEqual(observed.uuid, tap.uid, "the handle must retain the identity Core Audio actually created")
        XCTAssertEqual(observed.muteBehavior, .unmuted, "preparation/consent must leave output audible")
        XCTAssertNil(driver.preparationIssue(tap))
        let aggregate = try XCTUnwrap(tap.aggregateObject)
        XCTAssertNotEqual(aggregate, kAudioObjectUnknown)
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var outputBytes: UInt32 = 0
        XCTAssertEqual(AudioObjectGetPropertyDataSize(aggregate, &outputAddress, 0, nil, &outputBytes), noErr)
        XCTAssertEqual(outputBytes, 0, "the aggregate must have no physical output path")
        XCTAssertTrue(observed.isPrivate)
        XCTAssertFalse(observed.isExclusive)
        if #available(macOS 26.0, *) { XCTAssertFalse(observed.isProcessRestoreEnabled) }
        XCTAssertTrue(driver.destroy(CallMediaProcessTap(objectID: tap.objectID, uid: UUID())))
        XCTAssertTrue(hasTap(tap.objectID), "a recycled object number cannot grant ownership of another UUID")
        XCTAssertTrue(driver.destroy(tap))
        // Property support can be cached by the HAL client. Confirm the actual owned-object
        // inventory, with a bounded wait for the native removal notification, rather than
        // treating AudioObjectHasProperty as an object-lifetime API.
        let removed = expectation(for: NSPredicate { [self] _, _ in
            guard let ids = try? ownedTapIDs() else { return false }
            return !ids.contains(tap.objectID)
        }, evaluatedWith: nil)
        wait(for: [removed], timeout: 3)
        XCTAssertFalse(try ownedTapIDs().contains(tap.objectID))
        print("Native tap cleanup: absent from owned tap list; cached property support=\(hasTap(tap.objectID))")
        XCTAssertTrue(driver.destroy(tap), "already-destroyed resources count as released")
    }

    func testNativeUnstartedReaderCannotActivateMute() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        let queue = try silentOutput()
        defer { AudioQueueDispose(queue, true) }
        let target = CallMediaProcessTarget(sessionID: "isolated-silent-fixture", processObject: try processObject(getpid()), routeID: "fixture")
        let driver = CallMediaCoreAudioTap(queue: DispatchQueue(label: "bridgey.native-unstarted-fixture"))
        let tap = try driver.create(target).get()
        defer { _ = driver.destroy(tap) }
        XCTAssertThrowsError(try driver.activateMute(tap, permit: CallMediaPermit()).get())
        XCTAssertTrue(driver.destroy(tap))
    }
}
