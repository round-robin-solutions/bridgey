import AudioToolbox
import CoreAudio
import CCallMediaTap
import Darwin
import Foundation

// An isolated native acceptance tool, separate from Bridgey's app/UI, settings and accounts.
// The source emits silence; the owner uses the exact C++ lifecycle used by the live backend.
func report(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
func property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}
func processObject(_ pid: pid_t) -> AudioObjectID? {
    var pid = pid, value = AudioObjectID(kAudioObjectUnknown)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), &pid, &size, &value)
    return status == noErr && value != kAudioObjectUnknown ? value : nil
}
func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr ? Int(size) / MemoryLayout<AudioObjectID>.size : nil
}
func source() -> Int32 {
    var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var queue: AudioQueueRef?
    let created = AudioQueueNewOutput(&format, { _, queue, buffer in
        memset(buffer.pointee.mAudioData, 0, Int(buffer.pointee.mAudioDataBytesCapacity))
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }, nil, nil, nil, 0, &queue)
    guard created == noErr, let queue else { report(["phase": "source", "status": created]); return 1 }
    defer { AudioQueueDispose(queue, true) }
    for _ in 0..<3 {
        var buffer: AudioQueueBufferRef?
        let allocated = AudioQueueAllocateBuffer(queue, 4096, &buffer)
        guard allocated == noErr, let buffer else { report(["phase": "source-buffer", "status": allocated]); return 1 }
        memset(buffer.pointee.mAudioData, 0, 4096)
        buffer.pointee.mAudioDataByteSize = 4096
        let enqueued = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        guard enqueued == noErr else { report(["phase": "source-enqueue", "status": enqueued]); return 1 }
    }
    let started = AudioQueueStart(queue, nil)
    guard started == noErr, let object = processObject(getpid()) else {
        report(["phase": "source-start", "status": started]); return 1
    }
    report(["phase": "source-ready", "pid": getpid(), "processObject": object,
            "defaultOutput": property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0])
    while let command = readLine(), command != "quit" {
        if command == "state" {
            report(["phase": "source-state", "pid": getpid(),
                    "runningOutput": property(object, kAudioProcessPropertyIsRunningOutput) ?? 0,
                    "defaultOutput": property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0])
        }
    }
    return 0
}
func owner(_ process: AudioObjectID) -> Int32 {
    guard Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") is String else {
        report(["phase": "usage-description", "error": "Package the probe as its isolated .app before starting audio capture"])
        return 2
    }
    var status: OSStatus = noErr
    var owned = BridgeyCallTapPrepare(process, UUID().uuidString as CFString, &status)
    guard let initial = owned else { report(["phase": "prepare", "status": status]); return 1 }
    let aggregate = BridgeyCallTapAggregate(initial)
    report(["phase": "prepared-unmuted", "pid": getpid(), "status": status,
            "tap": BridgeyCallTapObject(initial), "aggregate": aggregate,
            "inputStreams": streams(aggregate, scope: kAudioObjectPropertyScopeInput) ?? -1,
            "outputStreams": streams(aggregate, scope: kAudioObjectPropertyScopeOutput) ?? -1])
    defer { if let remaining = owned { _ = BridgeyCallTapRelease(remaining) } }
    while let command = readLine(), command != "quit" {
        guard let current = owned else { report(["phase": command, "released": true]); continue }
        switch command {
        case "start": status = BridgeyCallTapStart(current)
        case "arm": status = BridgeyCallTapArm(current)
        case "stop": status = BridgeyCallTapStop(current)
        case "release":
            status = BridgeyCallTapRelease(current)
            if status == noErr { owned = nil }
        case "state": status = noErr
        default: report(["phase": "invalid-command"]); continue
        }
        if let remaining = owned {
            report(["phase": command, "status": status, "reading": BridgeyCallTapIsReading(remaining),
                    "closing": BridgeyCallTapIsClosing(remaining), "operation": String(cString: BridgeyCallTapLastOperation(remaining)),
                    "aggregateRunning": property(BridgeyCallTapAggregate(remaining), kAudioDevicePropertyDeviceIsRunning) ?? 0,
                    "defaultOutput": property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0])
        } else { report(["phase": command, "status": status, "released": true]) }
    }
    return 0
}
let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "--source" { exit(source()) }
if arguments.count == 3, arguments[1] == "--owner", let process = UInt32(arguments[2]), process != kAudioObjectUnknown {
    exit(owner(process))
}
report(["usage": "CallMediaTapProbe --source | --owner <isolated-source-process-object>"])
exit(2)
