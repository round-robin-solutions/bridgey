import AppKit
import CoreAudio
import CCallMediaTap
import Foundation

/// Exact-process private taps, with an input-only discard reader. Startup stays unmuted;
/// only a confirmed reader can activate mute-while-reading. No player/master volume writes.
final class CallMediaCoreAudioTap: CallMediaProcessTapDriver {
    private let queue: DispatchQueue
    private var readers: [UUID: OpaquePointer] = [:]
    private var readerObservers: [UUID: [() -> Void]] = [:]
    private var preparationIssues: [UUID: CallMediaIssue] = [:]
    private var targetObservers: [String: (UUID, (CallMediaIssue) -> Void)] = [:]
    init(queue: DispatchQueue) { self.queue = queue }

    deinit { for reader in readers.values { _ = BridgeyCallTapRelease(reader) } }

    func target(for session: CallMediaSession) -> Result<CallMediaProcessTarget, CallMediaIssue> {
        guard #available(macOS 14.2, *) else { return .failure(.selectiveMuteUnavailable) }
        guard CallMediaMacScripts.isScripted(session.bundleID), !session.protectedCallAudio else {
            return .failure(.callAudioProtected)
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: session.bundleID).first,
              !app.isTerminated, let launched = app.launchDate,
              session.id == "\(session.bundleID):\(app.processIdentifier):\(launched.timeIntervalSince1970)" else {
            return .failure(.sessionGone)
        }
        var pid = app.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard translated == noErr, object != kAudioObjectUnknown,
              Self.integer(object, kAudioProcessPropertyPID) == UInt32(pid),
              Self.string(object, kAudioProcessPropertyBundleID) == session.bundleID else {
            return .failure(.sessionGone)
        }
        guard Self.integer(object, kAudioProcessPropertyIsRunningInput) == 0 else {
            return .failure(.callAudioProtected)
        }
        guard Self.integer(object, kAudioProcessPropertyIsRunningOutput) == 1,
              let devices = Self.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
              !devices.isEmpty, devices.count <= 8 else { return .failure(.selectiveMuteUnavailable) }
        var routes: [String] = []
        for device in devices.sorted() {
            guard Self.integer(device, kAudioDevicePropertyDeviceIsAlive) == 1,
                  let uid = Self.string(device, kAudioDevicePropertyDeviceUID), !uid.isEmpty else {
                return .failure(.selectiveMuteUnavailable)
            }
            routes.append(uid)
        }
        return .success(CallMediaProcessTarget(sessionID: session.id, processObject: object,
                                               routeID: CallMediaMacScripts.contentID(routes)))
    }

    func observe(_ target: CallMediaProcessTarget, changed: @escaping (CallMediaIssue) -> Void)
        -> Result<() -> Void, CallMediaIssue> {
        var removals: [() -> Void] = []
        func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 _ callback: @escaping () -> Void) -> Bool {
            var address = Self.address(selector, scope: scope)
            let block: AudioObjectPropertyListenerBlock = { _, _ in callback() }
            guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return false }
            removals.append { [queue] in
                var address = Self.address(selector, scope: scope)
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
            return true
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        // Any route event invalidates ownership, including A -> B -> A/coalesced callbacks.
        let installed = add(system, kAudioHardwarePropertyDefaultOutputDevice, { changed(.changedByUser) }) &&
            add(system, kAudioHardwarePropertyServiceRestarted, { changed(.sessionGone) }) &&
            add(target.processObject, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput,
                { changed(.changedByUser) }) &&
            add(target.processObject, kAudioProcessPropertyIsRunningInput, { changed(.callAudioProtected) }) &&
            add(target.processObject, kAudioProcessPropertyIsRunningOutput, { changed(.changedByUser) }) &&
            add(system, kAudioHardwarePropertyProcessObjectList, {
                // Release only if this exact process object disappeared. Another app starting
                // audio must not release all media mutes.
                if Self.integer(target.processObject, kAudioProcessPropertyPID) == nil { changed(.sessionGone) }
            })
        guard installed else { removals.reversed().forEach { $0() }; return .failure(.selectiveMuteUnavailable) }
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) {
            [queue] _ in queue.async { changed(.sessionGone) }
        }
        let exit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) {
            [queue] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let launch = app.launchDate,
                  target.sessionID == "\(app.bundleIdentifier ?? ""):\(app.processIdentifier):\(launch.timeIntervalSince1970)" else { return }
            queue.async { changed(.sessionGone) }
        }
        // A player's explicit playback notification is a later user/app choice, even if its
        // final state equals the original. We do not infer volume intent from these notices.
        let notifications = DistributedNotificationCenter.default()
        let playback = notifications.addObserver(forName: Notification.Name(
            target.sessionID.hasPrefix(MediaPlayer.musicBundleID + ":") ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: nil) { [queue] _ in queue.async { changed(.changedByUser) } }
        let observer = UUID()
        targetObservers[target.sessionID] = (observer, changed)
        return .success { [weak self] in
            removals.reversed().forEach { $0() }
            workspace.removeObserver(sleep); workspace.removeObserver(exit)
            notifications.removeObserver(playback)
            if self?.targetObservers[target.sessionID]?.0 == observer {
                self?.targetObservers.removeValue(forKey: target.sessionID)
            }
        }
    }

    func create(_ target: CallMediaProcessTarget) -> Result<CallMediaProcessTap, CallMediaIssue> {
        guard #available(macOS 14.2, *) else { return .failure(.selectiveMuteUnavailable) }
        let uid = UUID()
        var status: OSStatus = noErr
        guard let reader = BridgeyCallTapPrepare(target.processObject, uid.uuidString as CFString, &status) else {
            return .failure(issue(status))
        }
        readers[uid] = reader
        let aggregate = BridgeyCallTapAggregate(reader)
        let tap = CallMediaProcessTap(objectID: BridgeyCallTapObject(reader), uid: uid, aggregateObject: aggregate)
        if status != noErr { preparationIssues[uid] = issue(status, reader: reader) }
        var removals: [() -> Void] = []
        if aggregate != kAudioObjectUnknown {
            for selector in [kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceIsAlive] {
                var address = Self.address(selector)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    guard let self, let current = self.readers[uid], !BridgeyCallTapIsClosing(current) else { return }
                    if Self.integer(aggregate, kAudioDevicePropertyDeviceIsAlive) != 1 ||
                        (BridgeyCallTapIsReading(current) && Self.integer(aggregate, kAudioDevicePropertyDeviceIsRunning) != 1) {
                        self.targetObservers[target.sessionID]?.1(.sessionGone)
                    }
                }
                if AudioObjectAddPropertyListenerBlock(aggregate, &address, queue, block) != noErr {
                    preparationIssues[uid] = .selectiveMuteUnavailable
                } else {
                    removals.append { [queue] in
                        var address = Self.address(selector)
                        AudioObjectRemovePropertyListenerBlock(aggregate, &address, queue, block)
                    }
                }
            }
        }
        readerObservers[uid] = removals
        return .success(tap)
    }

    func startReading(_ tap: CallMediaProcessTap) -> Result<Void, CallMediaIssue> {
        guard let reader = readers[tap.uid], BridgeyCallTapObject(reader) == tap.objectID else { return .failure(.sessionGone) }
        if let issue = preparationIssues[tap.uid] { return .failure(issue) }
        let status = BridgeyCallTapStart(reader)
        return status == noErr ? .success(()) : .failure(issue(status, reader: reader))
    }

    func activateMute(_ tap: CallMediaProcessTap, permit: CallMediaPermit) -> Result<Void, CallMediaIssue> {
        guard permit.isValid else { return .failure(.cancelled) }
        guard let reader = readers[tap.uid], BridgeyCallTapObject(reader) == tap.objectID else { return .failure(.sessionGone) }
        let status = BridgeyCallTapArm(reader)
        return status == noErr ? .success(()) : .failure(issue(status, reader: reader))
    }

    func preparationIssue(_ tap: CallMediaProcessTap) -> CallMediaIssue? { preparationIssues[tap.uid] }

    func destroy(_ tap: CallMediaProcessTap) -> Bool {
        guard let reader = readers[tap.uid] else { return true }
        guard BridgeyCallTapObject(reader) == tap.objectID else { return false }
        let status = BridgeyCallTapRelease(reader)
        guard status == noErr else { _ = issue(status, reader: reader); return false }
        readers.removeValue(forKey: tap.uid)
        preparationIssues.removeValue(forKey: tap.uid)
        readerObservers.removeValue(forKey: tap.uid)?.reversed().forEach { $0() }
        return true
    }

    private func issue(_ status: OSStatus, reader: OpaquePointer? = nil) -> CallMediaIssue {
        if let reader {
            NSLog("Bridgey call media: %@ failed (%d)", String(cString: BridgeyCallTapLastOperation(reader)), status)
        }
        // Missing callbacks and arbitrary HAL errors are not invented permission denials.
        return status == kAudioDevicePermissionsError ? .permissionNeeded : .commandFailed
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> [AudioObjectID]? {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0, size <= 32 * MemoryLayout<AudioObjectID>.size,
              size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let capacity = size
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr,
              size == capacity else { return nil }
        return values
    }
}
