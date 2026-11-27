import Foundation
import UIKit

/// An Android phone's or a Mac's screen on this device, and control of it. The phone or Mac decides at each request
/// (its grants and unattended access); this side asks, shows the stream and sends input while control is on.
/// Events come from the device's area (`screen` for a phone, `display` for a Mac); frames never do: a FramePump pulls
/// them into a VideoToolbox decoder and the display layer.
@MainActor
final class ScreenModel: ObservableObject, SessionFeature {
    typealias Command = ScreenCommands.Command

    enum Phase: Equatable {
        case idle
        /// The request is going out.
        case asking
        /// The phone or Mac hasn't answered yet; `needs` is what a phone says it still needs (unlock, accessibility,
        /// android_11).
        case waiting(needs: String?)
        case showing
        /// Over, with what to tell the person.
        case ended(String)
    }

    struct Stream: Equatable {
        var handle: UInt64
        var width: Int
        var height: Int
        /// The phone sends screenshots (unattended access without its video prompt): Slower mode.
        var screenshots: Bool
        /// The Mac's display.
        var displayName: String?
    }

    struct Control: Equatable {
        /// The stream can be controlled at all, and the phone or Mac allows it now.
        var capable = false
        var allowed = false
        /// off, starting, waiting or active.
        var phase = "off"
        var touch = false
        var pointer = false
        var keys = false
        var text = false
        var navigation = false
        /// Why control ended or was refused.
        var note: String?

        var available: Bool { capable && allowed }
        var active: Bool { phase == "active" }
    }

    private(set) weak var app: AppModel?
    private var client: CoreClient?
    private var pump: FramePump?

    /// The device whose screen is open, if any.
    @Published var viewing: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stream: Stream?
    @Published private(set) var control = Control()
    /// A picture has been decoded and shown.
    @Published private(set) var live = false
    @Published private(set) var fps: Int?
    /// A short message about the last thing that didn't work.
    @Published var notice: String?
    @Published private(set) var deviceName = ""
    @Published private(set) var area: PhoneArea?

    /// The surface the current stream is shown on.
    private(set) var display = ScreenDisplay()

    var isMac: Bool { area == .display }
    private var model: String { UIDevice.current.localizedModel }

    func attach(_ app: AppModel) { self.app = app }

    func clientChanged(_ client: CoreClient?) {
        self.client = client
        if client == nil {
            endStream()
            phase = .idle
            viewing = nil
        }
    }

    // MARK: Asking

    func open(_ device: DeviceItem) {
        guard let area = device.screenArea else { return }
        if viewing != nil { close(reason: "user") }
        self.area = area
        deviceName = device.name
        viewing = device.id
        request()
    }

    /// Asks again (Try again after it ended).
    func request() {
        guard let id = viewing, let area else { return }
        endStream()
        notice = nil
        phase = .asking
        guard let client else {
            phase = .ended(String(localized: "\(deviceName) isn’t connected."))
            return
        }
        let answer = client.phone(area, deviceID: id, command: ["op": "request"])
        if screenAnswerOK(answer) {
            if answer["showing"] as? Bool == true {
                // Already streaming here (another view asked): pick it up.
                let status = client.phone(area, deviceID: id, command: ["op": "status"])
                if let json = status["stream"] as? [String: Any] { started(json) } else { phase = .waiting(needs: nil) }
            } else {
                phase = .waiting(needs: nil)
            }
            return
        }
        switch answer["error"] as? String {
        case "feature_off": phase = .ended(String(localized: "\(deviceName) doesn’t share its screen with this \(model)."))
        case "too_soon": phase = .ended(String(localized: "Wait a few seconds, then try again."))
        case "not_connected": phase = .ended(String(localized: "\(deviceName) isn’t connected."))
        default: phase = .ended(String(localized: "\(deviceName) couldn’t share its screen."))
        }
    }

    /// Stop, or the view going away. A Mac hears why (`user` for Stop, `left_screen` when the app leaves the screen).
    func close(reason: String = "user") {
        if let id = viewing, let area, let client, phase != .idle, !isEnded {
            var command: Command = ["op": "stop"]
            if area == .display { command["reason"] = reason }
            _ = client.phone(area, deviceID: id, command: command)
        }
        endStream()
        phase = .idle
        viewing = nil
        notice = nil
    }

    private var isEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    // MARK: Events

    func handle(_ e: CoreEvent) {
        guard let area, e.kind == area.eventKind, let id = viewing, e.deviceID == id else { return }
        let json = e.json
        switch e.name {
        case "status":
            status(json["status"] as? String ?? "", needs: json["needs"] as? String)
        case "started":
            started(json)
        case "stats":
            guard stream?.handle == e.id else { return }
            fps = json["fps"] as? Int
        case "geometry":
            guard stream?.handle == e.id, let width = json["width"] as? Int, let height = json["height"] as? Int else { return }
            stream?.width = width
            stream?.height = height
        case "control":
            guard stream?.handle == e.id else { return }
            control = Self.control(json, current: control)
            if let note = control.note, !control.active { notice = controlNote(note) }
        case "stopped":
            guard stream == nil || stream?.handle == e.id else { return }
            let reason = json["reason"] as? String ?? "failed"
            let by = json["by"] as? String ?? ""
            endStream()
            // A replaced stream is followed by its new start.
            if reason == "replaced" { return }
            phase = .ended(by == "here" && ["user", "closed", "left_screen"].contains(reason) ? String(localized: "Stopped.") : stopText(reason))
        default:
            break
        }
    }

    private func status(_ status: String, needs: String?) {
        switch status {
        case "waiting": if stream == nil { phase = .waiting(needs: needs) }
        case "declined": phase = .ended(String(localized: "\(deviceName) didn’t allow it."))
        case "busy": phase = .ended(String(localized: "\(deviceName) is showing its screen to another device."))
        case "disabled":
            phase = .ended(isMac
                ? String(localized: "\(deviceName) doesn’t share its screen with this \(model). Allow it in Bridgey on the Mac, in Settings › Remote control.")
                : String(localized: "\(deviceName) doesn’t share its screen with this \(model). Turn it on in Bridgey there."))
        case "permission": phase = .ended(String(localized: "\(deviceName) needs Screen Recording for Bridgey."))
        case "locked": phase = .ended(String(localized: "\(deviceName) is locked."))
        case "expired": phase = .ended(String(localized: "\(deviceName) didn’t answer."))
        default: phase = .ended(String(localized: "\(deviceName) couldn’t share its screen."))
        }
    }

    /// What a waiting phone still needs, in plain words.
    func waitingText(_ needs: String?) -> String {
        switch needs {
        case "unlock": String(localized: "Unlock \(deviceName) to share its screen.")
        case "accessibility": String(localized: "On \(deviceName), allow the request, or turn on Bridgey in Accessibility settings to share without asking.")
        case "android_11": String(localized: "On \(deviceName), allow the request. Sharing without asking needs Android 11 or later.")
        default: String(localized: "Waiting for \(deviceName) to allow it.")
        }
    }

    private func started(_ json: [String: Any]) {
        guard let handle = (json["stream"] as? NSNumber)?.uint64Value, let width = json["width"] as? Int, let height = json["height"] as? Int else { return }
        endStream()
        stream = Stream(handle: handle, width: width, height: height, screenshots: json["screenshots"] as? Bool == true,
                        displayName: (json["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        control = Self.control(json["control"] as? [String: Any] ?? [:], current: Control())
        phase = .showing
        live = false
        guard let client, let area, let id = viewing else { return }
        display = ScreenDisplay()
        let pump = FramePump(client: client, area: area, deviceID: id, stream: handle, sink: display,
                             onFirstFrame: { [weak self] in
                                 if let self, self.stream?.handle == handle { self.live = true }
                             },
                             onEnded: { [weak self] in
                                 guard let self, self.stream?.handle == handle else { return }
                                 // The stopped event says why; until then the picture stays.
                                 self.pump = nil
                             })
        self.pump = pump
        pump.start()
    }

    static func control(_ json: [String: Any], current: Control) -> Control {
        var c = current
        c.capable = json["capable"] as? Bool ?? c.capable
        c.allowed = json["allowed"] as? Bool ?? c.allowed
        c.phase = json["phase"] as? String ?? c.phase
        let input = json["input"] as? [String: Any] ?? [:]
        c.touch = input["touch"] as? Bool ?? false
        c.pointer = input["pointer"] as? Bool ?? false
        c.keys = input["keys"] as? Bool ?? false
        c.text = input["text"] as? Bool ?? false
        c.navigation = input["navigation"] as? Bool ?? false
        c.note = json["note"] as? String
        return c
    }

    private func endStream() {
        pump?.stop()
        pump = nil
        display.clear()
        stream = nil
        live = false
        fps = nil
        control = Control()
    }

    private func stopText(_ reason: String) -> String {
        switch reason {
        case "disconnected": String(localized: "\(deviceName) disconnected.")
        case "screen_off": String(localized: "The screen of \(deviceName) turned off.")
        case "locked": String(localized: "\(deviceName) is locked.")
        case "disabled": String(localized: "\(deviceName) stopped sharing its screen with this \(model).")
        case "permission": String(localized: "\(deviceName) needs Screen Recording for Bridgey.")
        case "source_changed": String(localized: "The shared display changed. Try again.")
        case "timeout": String(localized: "The stream stopped answering.")
        case "user", "closed", "ended", "local_stop": String(localized: "Stopped on \(deviceName).")
        default: String(localized: "The stream stopped. Try again.")
        }
    }

    private func controlNote(_ reason: String) -> String {
        switch reason {
        case "declined": String(localized: "\(deviceName) didn’t allow control.")
        case "disabled": String(localized: "Control is off for this \(model) on \(deviceName).")
        case "permission":
            isMac ? String(localized: "\(deviceName) needs Accessibility for Bridgey.")
                : String(localized: "Turn on Bridgey in Accessibility settings on \(deviceName).")
        case "locked": String(localized: "\(deviceName) is locked.")
        case "busy": String(localized: "Another device is controlling \(deviceName).")
        case "focus": String(localized: "Typing works only in windows on the shared display.")
        case "local_stop": String(localized: "Control was stopped on \(deviceName).")
        default: String(localized: "Control stopped.")
        }
    }

    // MARK: Control and input

    func setControl(_ on: Bool) {
        guard let id = viewing, let area, let client, stream != nil else { return }
        notice = nil
        let answer = client.phone(area, deviceID: id, command: ["op": on ? "control_begin" : "control_end"])
        if !screenAnswerOK(answer) {
            notice = String(localized: "\(deviceName) doesn’t allow control right now.")
        }
    }

    /// Sends input while control is on. Never Control, Alt or Meta (ScreenCommands has no way to).
    func send(_ commands: [Command]) {
        guard control.active, let id = viewing, let area, let client else { return }
        for command in commands {
            _ = client.phone(area, deviceID: id, command: command)
        }
    }

    func send(_ command: Command) { send([command]) }
}

/// `{"ok": true}`.
private func screenAnswerOK(_ answer: [String: Any]) -> Bool { answer["ok"] as? Bool == true }
