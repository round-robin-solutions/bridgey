import AudioToolbox
import CoreAudio
import CCallMediaTap
import Darwin
import Foundation
import Security

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
func source(instance: UUID) -> Int32 {
    guard ProcessInfo.processInfo.environment["BRIDGEY_CALL_AUDIO_ISOLATED"] == "1" else {
        report(["phase": "isolated-audio-host-required"]); return 3
    }
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
            "instance": instance.uuidString,
            "defaultOutput": property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0])
    while let command = readLine() {
        if command == "quit" { return 0 }
        let parts = command.split(separator: " ")
        if parts.count == 2, parts[0] == "state", let challenge = UUID(uuidString: String(parts[1])) {
            report(["phase": "source-state", "pid": getpid(),
                    "instance": instance.uuidString, "challenge": challenge.uuidString,
                    "processObject": processObject(getpid()) ?? 0,
                    "runningOutput": property(object, kAudioProcessPropertyIsRunningOutput) ?? 0,
                    "defaultOutput": property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0])
        }
    }
    // A killed owner closes stdin. Keep its silent source alive briefly so the independent
    // native supervisor can verify target/control continuity, then clean up automatically.
    Thread.sleep(forTimeInterval: 30)
    return 0
}

struct FixtureSourceIdentity {
    let pid: pid_t
    let object: AudioObjectID
    let instance: UUID

    func matches(_ frame: [String: Any], challenge: UUID) -> Bool {
        frame["phase"] as? String == "source-state" &&
            (frame["pid"] as? NSNumber)?.int32Value == pid &&
            (frame["processObject"] as? NSNumber)?.uint32Value == object &&
            frame["instance"] as? String == instance.uuidString &&
            frame["challenge"] as? String == challenge.uuidString &&
            (frame["runningOutput"] as? NSNumber)?.intValue == 1
    }
}

func fixtureEnvironment() -> [String: String] {
    // A fixture needs no CI credentials or XCTest/DYLD injection from its launcher.
    let keys: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING", "BRIDGEY_CALL_AUDIO_ISOLATED"]
    return ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
}

func signingIdentity(_ pid: pid_t) -> (URL, Data)? {
    var dynamic: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
                                        SecCSFlags(), &dynamic) == errSecSuccess, let dynamic,
          SecCodeCheckValidity(dynamic, SecCSFlags(), nil) == errSecSuccess else { return nil }
    var code: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamic, SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any],
          let executable = values[kSecCodeInfoMainExecutable as String] as? URL,
          let hash = values[kSecCodeInfoUnique as String] as? Data else { return nil }
    return (executable.resolvingSymlinksInPath(), hash)
}

/// Owns the child and its private pipes. It cannot be constructed from an external PID or
/// audio-object argument. Every validation requires a fresh source-mode challenge response.
final class SilentFixtureSource {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let instance = UUID()
    private(set) var identity: FixtureSourceIdentity?
    private(set) var failure = "not-started"

    func start() -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        // Only the designated stdio duplicates may reach a child; a second source must not
        // inherit a first source's writer and accidentally extend its orphan lifetime.
        for handle in [input.fileHandleForReading, input.fileHandleForWriting,
                       output.fileHandleForReading, output.fileHandleForWriting] {
            let flags = fcntl(handle.fileDescriptor, F_GETFD)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else { return false }
        }
        process.executableURL = executable
        process.arguments = ["--source", instance.uuidString]
        process.environment = fixtureEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        guard let frame = readFrame(), frame["phase"] as? String == "source-ready",
              (frame["pid"] as? NSNumber)?.int32Value == process.processIdentifier,
              frame["instance"] as? String == instance.uuidString,
              let object = (frame["processObject"] as? NSNumber)?.uint32Value, object != kAudioObjectUnknown else { return false }
        identity = FixtureSourceIdentity(pid: process.processIdentifier, object: object, instance: instance)
        return validate()
    }

    func validate() -> Bool {
        failure = "not-running"
        guard process.isRunning, let identity else { return false }
        failure = "signature"
        guard let mine = signingIdentity(getpid()), let child = signingIdentity(process.processIdentifier),
              mine.0 == child.0, mine.1 == child.1 else { return false }
        failure = "audio-process-identity"
        guard processObject(identity.pid) == identity.object,
              property(identity.object, kAudioProcessPropertyPID) == UInt32(identity.pid) else { return false }
        failure = "source-mode-response"
        let challenge = UUID()
        do { try input.fileHandleForWriting.write(contentsOf: Data("state \(challenge.uuidString)\n".utf8)) }
        catch { return false }
        guard let frame = readFrame() else { return false }
        let valid = process.isRunning && identity.matches(frame, challenge: challenge) && processObject(identity.pid) == identity.object
        if valid { failure = "none" }
        return valid
    }

    private func readFrame() -> [String: Any]? {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while data.count < 8192 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, Int32(max(1, remaining * 1000))) > 0 else { return nil }
            // Foundation's read(upToCount:) may wait for the whole requested length on a
            // pipe. A single POSIX read consumes only the bytes poll says are available.
            var bytes = [UInt8](repeating: 0, count: min(4096, 8192 - data.count))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd.fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            data.append(contentsOf: bytes.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                guard newline == data.index(before: data.endIndex) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
        return nil
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
}

func bindingCheck() -> Int32 {
    guard ProcessInfo.processInfo.environment["BRIDGEY_CALL_AUDIO_ISOLATED"] == "1" else {
        report(["phase": "isolated-audio-host-required"]); return 3
    }
    let source = SilentFixtureSource(), other = SilentFixtureSource()
    defer { source.stop(); other.stop() }
    guard source.start(), other.start(), let identity = source.identity, let unrelated = other.identity else {
        report(["phase": "binding-check", "valid": false, "sourceFailure": source.failure, "controlFailure": other.failure]); return 4
    }
    let challenge = UUID()
    let frame: [String: Any] = ["phase": "source-state", "pid": identity.pid, "processObject": identity.object,
        "instance": identity.instance.uuidString, "challenge": challenge.uuidString, "runningOutput": 1]
    var wrongObject = frame; wrongObject["processObject"] = unrelated.object
    var wrongPID = frame; wrongPID["pid"] = unrelated.pid
    var wrongInstance = frame; wrongInstance["instance"] = unrelated.instance.uuidString
    let valid = source.validate() && other.validate() && identity.matches(frame, challenge: challenge)
    let rejectsReplacement = !identity.matches(wrongObject, challenge: challenge)
    let rejectsUnrelated = !identity.matches(wrongPID, challenge: challenge) && !identity.matches(wrongInstance, challenge: challenge)
    source.stop()
    let rejectsExit = !source.validate()
    report(["phase": "binding-check", "valid": valid, "replacementRejected": rejectsReplacement,
            "unrelatedRejected": rejectsUnrelated, "exitedRejected": rejectsExit, "captureStarted": false])
    return valid && rejectsReplacement && rejectsUnrelated && rejectsExit ? 0 : 4
}

func owner() -> Int32 {
    guard ProcessInfo.processInfo.environment["BRIDGEY_CALL_AUDIO_ISOLATED"] == "1" else {
        report(["phase": "isolated-audio-host-required"]); return 3
    }
    guard Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") is String else {
        report(["phase": "usage-description", "error": "Package the probe as its isolated .app before starting audio capture"])
        return 2
    }
    let source = SilentFixtureSource(), control = SilentFixtureSource()
    defer { source.stop(); control.stop() }
    guard source.start(), control.start(), let identity = source.identity, let controlIdentity = control.identity,
          source.validate(), control.validate() else { report(["phase": "source-not-verified"]); return 3 }
    let process = identity.object
    var status: OSStatus = noErr
    var owned = BridgeyCallTapPrepare(process, UUID().uuidString as CFString, &status)
    guard let initial = owned else { report(["phase": "prepare", "status": status]); return 1 }
    let aggregate = BridgeyCallTapAggregate(initial)
    report(["phase": "prepared-unmuted", "pid": getpid(), "status": status,
            "sourcePID": identity.pid, "sourceObject": identity.object,
            "controlPID": controlIdentity.pid, "controlObject": controlIdentity.object,
            "tap": BridgeyCallTapObject(initial), "aggregate": aggregate,
            "inputStreams": streams(aggregate, scope: kAudioObjectPropertyScopeInput) ?? -1,
            "outputStreams": streams(aggregate, scope: kAudioObjectPropertyScopeOutput) ?? -1])
    defer { if let remaining = owned { _ = BridgeyCallTapRelease(remaining) } }
    while let command = readLine(), command != "quit" {
        guard let current = owned else { report(["phase": command, "released": true]); continue }
        if command == "start" || command == "arm" {
            guard source.validate(), control.validate() else {
                report(["phase": "source-no-longer-verified"]); return 3
            }
        }
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
                    "sourceRunning": property(identity.object, kAudioProcessPropertyIsRunningOutput) ?? 0,
                    "controlRunning": property(controlIdentity.object, kAudioProcessPropertyIsRunningOutput) ?? 0,
                    "defaultOutput": property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0])
        } else { report(["phase": command, "status": status, "released": true]) }
    }
    return 0
}
let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--source", let instance = UUID(uuidString: arguments[2]) { exit(source(instance: instance)) }
if arguments.count == 2, arguments[1] == "--owner" { exit(owner()) }
if arguments.count == 2, arguments[1] == "--binding-check" { exit(bindingCheck()) }
// Inspection is read-only and limited to this exact probe binary. It lets the supervisor
// check the silent children after force-killing their owner without accessing other apps.
if arguments.count == 3, arguments[1] == "--inspect", let pid = pid_t(arguments[2]),
   let mine = signingIdentity(getpid()), let guest = signingIdentity(pid), mine.0 == guest.0, mine.1 == guest.1,
   let object = processObject(pid) {
    report(["phase": "fixture-state", "pid": pid, "processObject": object,
            "runningOutput": property(object, kAudioProcessPropertyIsRunningOutput) ?? 0])
    exit(0)
}
report(["usage": "CallMediaTapProbe --owner | --source <instance-UUID> | --inspect <fixture-PID> | --binding-check"])
exit(2)
