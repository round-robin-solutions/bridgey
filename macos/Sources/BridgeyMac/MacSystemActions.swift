import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IOKit.pwr_mgt

/*
 * The real operations behind Mac actions, public interfaces only (research in docs/automation.md):
 * - Lock: macOS has no public "lock now" call (SACLockScreenImmediate is private, CGSession is
 *   gone since macOS 11), so this posts the system's own Lock Screen shortcut, Control-Command-Q,
 *   with CGEvent. That needs Accessibility, the access remote control already uses.
 * - Sleep: IOKit IOPMSleepSystem, allowed for the logged-in user without admin rights or an
 *   Automation prompt (it is what `pmset sleepnow` calls).
 * - Screen saver: opens ScreenSaverEngine.app with NSWorkspace.
 * - Volume: CoreAudio on the default output device (virtual main volume and mute).
 * - Apps: NSWorkspace, by bundle identifier from the local list.
 * - Shortcuts: /usr/bin/shortcuts run <name>, the name from the local list as one argument (no
 *   shell), no input, at most 60 seconds.
 * Never called from tests: they use fakes of `MacSystemActing`.
 */
@MainActor
final class LiveMacSystemActions: MacSystemActing {
    static let shortcutTimeout: TimeInterval = 60
    private let queue = DispatchQueue(label: "\(Edition.identifier).actions")

    var accessibilityTrusted: Bool { AccessibilityAccess.isTrusted() }

    func lockScreen() -> Bool {
        guard AccessibilityAccess.isTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let q: CGKeyCode = 12
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: q, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func sleepSystem() -> Bool {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { return false }
        defer { IOServiceClose(port) }
        return IOPMSleepSystem(port) == kIOReturnSuccess
    }

    func startScreenSaver() -> Bool {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }

    // MARK: Volume

    func volume() -> MacVolumeState? {
        guard let device = CoreAudioOutput.defaultDevice(), let level = CoreAudioOutput.volume(device) else { return nil }
        return MacVolumeState(level: Int((level * 100).rounded()), muted: CoreAudioOutput.muted(device) ?? false)
    }

    func stepVolume(up: Bool) -> MacVolumeState? {
        guard let device = CoreAudioOutput.defaultDevice(), let level = CoreAudioOutput.volume(device) else { return nil }
        let next = steppedVolume(level, up: up)
        guard CoreAudioOutput.setVolume(device, next) else { return nil }
        // Like the volume keys: any change unmutes; reaching zero leaves it as it is.
        if up, CoreAudioOutput.muted(device) == true { _ = CoreAudioOutput.setMuted(device, false) }
        return volume()
    }

    func toggleMute() -> MacVolumeState? {
        guard let device = CoreAudioOutput.defaultDevice(), let muted = CoreAudioOutput.muted(device),
              CoreAudioOutput.setMuted(device, !muted) else { return nil }
        return volume()
    }

    func setVolume(_ level: Int) -> MacVolumeState? {
        guard let device = CoreAudioOutput.defaultDevice(),
              CoreAudioOutput.setVolume(device, Float32(min(max(level, 0), 100)) / 100) else { return nil }
        if level > 0, CoreAudioOutput.muted(device) == true { _ = CoreAudioOutput.setMuted(device, false) }
        return volume()
    }

    // MARK: Apps and Shortcuts

    func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func openApp(bundleID: String, completion: @escaping (Bool) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { completion(false); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async { completion(app != nil && error == nil) }
        }
    }

    func runShortcut(named name: String, completion: @escaping (ShortcutRunOutcome) -> Void) {
        let timeout = Self.shortcutTimeout
        queue.async {
            let outcome: ShortcutRunOutcome
            if let names = ShortcutsCLI.list(), !names.contains(name) {
                outcome = .notFound
            } else {
                outcome = ShortcutsCLI.run(name, timeout: timeout)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}

/// One volume key step: 1/16 of the range, snapped to the step grid.
func steppedVolume(_ level: Float32, up: Bool) -> Float32 {
    let steps = (min(max(level, 0), 1) * 16).rounded()
    return min(max(steps + (up ? 1 : -1), 0), 16) / 16
}

/// The `shortcuts` command line tool. Arguments go straight to the process: never a shell.
enum ShortcutsCLI {
    static let path = "/usr/bin/shortcuts"

    /// The names of the person's Shortcuts, or nil when the tool is missing or fails.
    static func list() -> [String]? {
        guard let output = runProcess(arguments: ["list"], timeout: 10, captureLimit: 512 * 1024) else { return nil }
        guard output.status == 0 else { return nil }
        return output.text.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
    }

    static func run(_ name: String, timeout: TimeInterval) -> ShortcutRunOutcome {
        guard let output = runProcess(arguments: ["run", name], timeout: timeout, captureLimit: 0) else { return .failed }
        if output.timedOut { return .timedOut }
        return output.status == 0 ? .done : .failed
    }

    private static func runProcess(arguments: [String], timeout: TimeInterval, captureLimit: Int) -> (status: Int32, text: String, timedOut: Bool)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = captureLimit > 0 ? pipe : FileHandle.nullDevice
        let timedOut = ProcessTimeoutFlag()
        let deadline = DispatchWorkItem { if process.isRunning { timedOut.set(); process.terminate() } }
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        var data = Data()
        if captureLimit > 0 {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                guard data.count + chunk.count <= captureLimit else { process.terminate(); break }
                data.append(chunk)
            }
        }
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "", timedOut.value)
    }
}

/// Set by the deadline when it stopped a process.
private final class ProcessTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

/// The default output device's volume and mute through CoreAudio.
enum CoreAudioOutput {
    static func defaultDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static func volume(_ device: AudioDeviceID) -> Float32? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return min(max(value, 0), 1)
    }

    static func setVolume(_ device: AudioDeviceID, _ level: Float32) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = min(max(level, 0), 1)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func muted(_ device: AudioDeviceID) -> Bool? {
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
