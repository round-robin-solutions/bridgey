import AppKit
import Foundation

/*
 * Phone screen to Mac, draft `screen_draft1` (docs/protocol.md). "Show Phone Screen" asks the phone
 * to share; the phone needs a tap and Android's own consent every time, then starts a stream that
 * this Mac shows in a window. Off by default ("Show phone screens" in Settings > Remote control).
 * View only. This class owns the switch, requests, the streams' lifecycle and this Mac's messages;
 * ScreenStreamReceiver does the per-frame work off the main thread.
 */

/// Opens, updates and closes the per-phone windows (PhoneScreenWindow.swift); tests replace it.
@MainActor
protocol PhoneScreenPresenter: AnyObject {
    /// Opens the window for a new stream and returns where frames are shown. `controllable`: the phone may be controlled
    /// from it (phone_control_draft1), so it has the control bar.
    func open(deviceID: String, phoneName: String, width: Int, height: Int, controllable: Bool, onClose: @escaping () -> Void) -> ScreenDisplaySink?
    func update(deviceID: String, stats: ScreenStats)
    func resize(deviceID: String, width: Int, height: Int)
    func bringToFront(deviceID: String)
    /// `message`: shown briefly before the window closes; nil closes it at once.
    func close(deviceID: String, message: String?)
    /// Phone control's state for the window's bar.
    func updateControl(deviceID: String, control: PhoneControlView)
}

/// What the window shows about controlling the phone.
struct PhoneControlView: Equatable {
    enum Phase: Equatable { case off, starting, waiting, active }

    /// The stream is control-capable: the phone shows phone_control_draft1 and has a grant for this Mac.
    var capable = false
    /// The phone said control may be asked for now (its accessibility service is on).
    var allowed = false
    var phase = Phase.off
    var input = ScreenControl.InputCapabilities()
    /// Why control ended or was refused, until it starts again.
    var note: PhoneControlReason?
    /// The stream's size for positions: the control geometry.
    var width = 0
    var height = 0
    /// Changes whenever gestures in progress must be forgotten (geometry change, control ended).
    var epoch = 0
}

@MainActor
final class PhoneScreen: ObservableObject {
    static let lifetime: TimeInterval = 120
    static let spacing: TimeInterval = 3
    static let streamTimeout: TimeInterval = 6
    /// Ended streams stay refused (a recorded stream replayed later in the same connection is not shown as live).
    static let rememberedStreams = 1_024
    static let defaultsKey = "settings.screen.show"

    struct Request: Equatable {
        let id: String
        let deviceID: String
        let phoneName: String
        let at: Date
    }

    final class Stream {
        let streamID: String
        let deviceID: String
        let phoneName: String
        let receiver: ScreenStreamReceiver
        var macSequence = 0
        var stats: ScreenStats?
        /// phone_control_draft1: the control object of screen.start, the current geometry and this session's nonce.
        let offer: PhoneControlOffer?
        var geometry: ScreenControl.Geometry?
        let connection: [UInt8]
        var control = PhoneControlView()
        var sender: PhoneControlSender?
        /// Input sent this session, by operation, for the log (never positions or text).
        var sent: [String: Int] = [:]

        init(streamID: String, deviceID: String, phoneName: String, receiver: ScreenStreamReceiver, offer: PhoneControlOffer? = nil,
             connection: [UInt8] = []) {
            self.streamID = streamID
            self.deviceID = deviceID
            self.phoneName = phoneName
            self.receiver = receiver
            self.offer = offer
            self.connection = connection
            geometry = offer?.geometry
            if let offer {
                control = PhoneControlView(capable: true, allowed: offer.allowed, width: Int(offer.geometry.width), height: Int(offer.geometry.height))
            }
        }

        func nextSequence() -> Int {
            macSequence += 1
            return macSequence
        }
    }

    /// Settings > Remote control > Show phone screens. Off by default on every install.
    @Published private(set) var enabled: Bool
    /// The open request per phone.
    @Published private(set) var pending: [String: Request] = [:]
    /// The panel's line about the latest request or stream.
    @Published private(set) var status: String? {
        didSet { if status != oldValue { scheduleClear(status) } }
    }
    /// Phones whose screen is showing now.
    @Published private(set) var streaming: Set<String> = []

    /// Sends one encrypted `screen.*` message to a connected phone; false when it is not connected.
    var send: (_ deviceID: String, _ kind: String, _ payload: [String: Any]) -> Bool = { _, _, _ in false }
    var onSettingsChange: () -> Void = {}
    /// The phone shows phone_control_draft1 (and this Mac shows phone screens): its stream may be controlled.
    var phoneControlAvailable: (_ deviceID: String) -> Bool = { _ in false }
    weak var presenter: PhoneScreenPresenter?
    /// Monotonic milliseconds for the control sender's budgets.
    var monotonicMs: () -> UInt64 = { UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    private let defaults: UserDefaults?
    private let clock: () -> Date
    private var lastRequest: [String: Date] = [:]
    private(set) var streams: [String: Stream] = [:]
    private(set) var endedStreamIDs: [String] = []
    private var ticker: Timer?
    private var flusher: Timer?

    init(defaults: UserDefaults? = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        enabled = defaults?.bool(forKey: Self.defaultsKey) ?? false
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        defaults?.set(on, forKey: Self.defaultsKey)
        enabled = on
        if !on {
            for stream in Array(streams.values) { stop(stream, reason: .disabled, message: L10n.text("screen.ended.disabledHere", fallback: "Show phone screens is off on this Mac")) }
            pending.removeAll()
        }
        onSettingsChange()
    }

    // MARK: Asking

    /// Asks `deviceID` to share its screen. Returns the request ID, or nil when the screen already shows,
    /// a request is still open or the last one was under 3 seconds ago.
    @discardableResult
    func request(from deviceID: String, phoneName: String) -> String? {
        tick()
        if streams[deviceID] != nil {
            presenter?.bringToFront(deviceID: deviceID)
            return nil
        }
        let now = clock()
        if pending[deviceID] != nil {
            status = screenStatusText(.waiting, phone: phoneName)
            return nil
        }
        if let last = lastRequest[deviceID], now.timeIntervalSince(last) < Self.spacing { return nil }
        guard enabled else { return nil }
        let id = UUID().uuidString.lowercased()
        guard send(deviceID, "screen.request", screenRequestPayload(id)) else {
            status = String(format: L10n.text("screen.status.notConnected", fallback: "%@ is not connected"), phoneName)
            return nil
        }
        lastRequest[deviceID] = now
        pending[deviceID] = Request(id: id, deviceID: deviceID, phoneName: phoneName, at: now)
        status = String(format: L10n.text("screen.status.asked", fallback: "Asking %@ to share its screen"), phoneName)
        ensureTicker()
        return id
    }

    /// `screen.status` from a phone, for its open request only.
    func received(status wire: ScreenStatus, requestID: String, from deviceID: String, phoneName: String) {
        tick()
        guard let request = pending[deviceID], request.id == requestID else { return }
        status = screenStatusText(wire, phone: phoneName)
        if wire != .waiting { pending.removeValue(forKey: deviceID) }
    }

    // MARK: Streams

    /// A decrypted `screen.start` from `deviceID`, whose session key is `key` and session ID `sessionID`.
    func receiveStart(_ data: Data, from deviceID: String, phoneName: String, key: Data, sessionID: String = "") {
        guard enabled else {
            if let streamID = ScreenStart.streamID(of: data) { refuse(streamID, deviceID: deviceID, reason: .disabled) }
            return
        }
        guard let start = ScreenStart.decode(data) else {
            if let streamID = ScreenStart.streamID(of: data), !isKnown(streamID) { refuse(streamID, deviceID: deviceID, reason: .invalid) }
            BridgeyLog.screen.notice("screen start refused reason=invalid peer=\(shortDeviceID(deviceID), privacy: .public)")
            return
        }
        guard !isKnown(start.streamID) else { return }
        if let previous = streams[deviceID] {
            // The phone started a new stream: the old one ends here without a message.
            end(previous, message: nil)
        }
        let receiver = ScreenStreamReceiver(streamID: start.streamID, deviceID: deviceID, key: key, startSequence: start.sequence)
        // A control-capable stream (phone_control_draft1): only from a phone that shows the key; a bad object means view only.
        let offer = phoneControlAvailable(deviceID) ? start.control : nil
        let stream = Stream(streamID: start.streamID, deviceID: deviceID, phoneName: phoneName, receiver: receiver, offer: offer,
                            connection: offer == nil ? [] : ScreenControl.connectionNonce(sessionKey: key, sessionID: sessionID))
        receiver.onAck = { [weak self, weak stream] frame, decodeMs, keyframe in
            guard let self, let stream, self.streams[deviceID] === stream else { return }
            _ = self.send(deviceID, "screen.ack", screenAckPayload(streamID: stream.streamID, sequence: stream.nextSequence(),
                                                                   frame: frame, decodeMs: decodeMs, keyframe: keyframe))
        }
        receiver.onStats = { [weak self, weak stream] stats in
            guard let self, let stream, self.streams[deviceID] === stream else { return }
            stream.stats = stats
            self.presenter?.update(deviceID: deviceID, stats: stats)
        }
        receiver.onSize = { [weak self, weak stream] width, height in
            guard let self, let stream, self.streams[deviceID] === stream else { return }
            self.presenter?.resize(deviceID: deviceID, width: width, height: height)
        }
        receiver.onGeometry = { [weak self, weak stream] message in
            guard let self, let stream, self.streams[deviceID] === stream else { return }
            self.geometryChanged(stream, message.geometry)
        }
        receiver.onControl = { [weak self, weak stream] message in
            guard let self, let stream, self.streams[deviceID] === stream else { return }
            self.controlMessage(stream, message.state)
        }
        receiver.onStop = { [weak self, weak stream] reason in
            guard let self, let stream, self.streams[deviceID] === stream else { return }
            BridgeyLog.screen.notice("screen stopped by phone stream=\(String(stream.streamID.prefix(8)), privacy: .public) reason=\(reason.rawValue, privacy: .public)")
            self.end(stream, message: screenEndedText(reason, phone: stream.phoneName))
        }
        streams[deviceID] = stream
        streaming.insert(deviceID)
        if let request = pending[deviceID], start.requestID == nil || start.requestID == request.id {
            pending.removeValue(forKey: deviceID)
        }
        status = nil
        if let sink = presenter?.open(deviceID: deviceID, phoneName: phoneName, width: start.width, height: start.height,
                                      controllable: offer != nil,
                                      onClose: { [weak self, weak stream] in
                                          guard let self, let stream, self.streams[deviceID] === stream else { return }
                                          self.stop(stream, reason: .closed, message: nil)
                                      }) {
            receiver.attach(sink)
        }
        if offer != nil { presenter?.updateControl(deviceID: deviceID, control: stream.control) }
        _ = send(deviceID, "screen.started", screenStartedPayload(streamID: start.streamID, sequence: stream.nextSequence()))
        BridgeyLog.screen.notice("screen started stream=\(String(start.streamID.prefix(8)), privacy: .public) size=\(start.width, privacy: .public)x\(start.height, privacy: .public) fps=\(start.fps, privacy: .public) bitrate=\(start.bitrate, privacy: .public) requested=\(start.requestID != nil, privacy: .public)")
        ensureTicker()
    }

    /// `screen.frame`, `screen.stats` or `screen.stop` from `deviceID`, still encrypted.
    func receiveStream(kind: String, nonce: String, ciphertext: String, from deviceID: String) {
        guard enabled, let stream = streams[deviceID] else { return }
        stream.receiver.receive(kind: kind, nonce: nonce, ciphertext: ciphertext)
    }

    /// Stop in the window, or the window closed.
    func stopShowing(_ deviceID: String) {
        guard let stream = streams[deviceID] else { return }
        stop(stream, reason: .closed, message: nil)
    }

    func disconnected(_ deviceID: String) {
        pending.removeValue(forKey: deviceID)
        if let stream = streams[deviceID] {
            end(stream, message: String(format: L10n.text("screen.ended.disconnected", fallback: "%@ disconnected"), stream.phoneName))
        }
    }

    func clearStatus() { status = nil }

    /// Request expiry and stream timeouts; runs every second while something is open.
    func tick() {
        let now = clock()
        for (deviceID, request) in pending where now.timeIntervalSince(request.at) >= Self.lifetime {
            pending.removeValue(forKey: deviceID)
            status = String(format: L10n.text("screen.status.expired", fallback: "No answer from %@"), request.phoneName)
        }
        for stream in Array(streams.values) where now.timeIntervalSince(stream.receiver.lastActivity) >= Self.streamTimeout {
            stop(stream, reason: .timeout, message: String(format: L10n.text("screen.ended.timeout", fallback: "Lost the screen of %@"), stream.phoneName))
        }
        if pending.isEmpty && streams.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: Phone control (phone_control_draft1)

    /// Control in the window: asks the phone, which checks its grant and may ask the person there.
    func beginControl(_ deviceID: String) {
        guard let stream = streams[deviceID], stream.offer != nil, stream.control.allowed, stream.control.phase == .off else { return }
        stream.control.phase = .starting
        stream.control.note = nil
        _ = send(deviceID, PhoneControlKinds.control, phoneControlBeginPayload(streamID: stream.streamID, sequence: stream.nextSequence()))
        publishControl(stream)
        BridgeyLog.screen.notice("phone control asked stream=\(String(stream.streamID.prefix(8)), privacy: .public)")
    }

    /// Stop control in the window: the picture stays.
    func endControl(_ deviceID: String) {
        guard let stream = streams[deviceID] else { return }
        switch stream.control.phase {
        case .off:
            return
        case .starting, .waiting:
            _ = send(deviceID, PhoneControlKinds.control, phoneControlEndPayload(streamID: stream.streamID, sequence: stream.nextSequence()))
        case .active:
            if let stop = stream.sender?.stop() { sendInput(stream, stop) }
        }
        endControlLocally(stream, note: nil)
    }

    /// One action from the window: false when it was not taken (no control, not supported, a full queue).
    @discardableResult
    func controlInput(_ deviceID: String, _ action: PhoneControlAction) -> Bool {
        guard let stream = streams[deviceID], stream.control.phase == .active, let sender = stream.sender else { return false }
        let taken = sender.submit(action)
        if taken {
            switch action {
            case .touch(_, .move, _, _), .scroll: break
            // Transitions go at once when the budget allows; motion waits for the next flush.
            default: flushControl(stream)
            }
        }
        return taken
    }

    /// One press and release of a named key, with Shift around it when asked.
    @discardableResult
    func pressKey(_ deviceID: String, _ key: ScreenControl.Key, shift: Bool = false) -> Bool {
        guard let stream = streams[deviceID], stream.control.phase == .active, let sender = stream.sender else { return false }
        let taken = sender.press(key, shift: shift)
        if taken { flushControl(stream) }
        return taken
    }

    /// The phone's latest map shows phone_control_draft1 or no longer does. Without it nothing more may be sent: control
    /// ends here as turned off on the phone (its own `ended` may never be read once the key is gone).
    func phoneControlChanged(_ deviceID: String, available: Bool) {
        guard let stream = streams[deviceID], stream.offer != nil else { return }
        if available {
            if !stream.control.allowed {
                stream.control.allowed = true
                publishControl(stream)
            }
            return
        }
        stream.control.allowed = false
        if stream.control.phase == .off {
            publishControl(stream)
        } else {
            BridgeyLog.screen.notice("phone control over reason=key_off")
            endControlLocally(stream, note: .disabled)
        }
    }

    /// The stream's control state (tests and the test instance's status).
    func controlState(_ deviceID: String) -> PhoneControlView? { streams[deviceID]?.control }

    /// Input sent in this control session, by operation (the test instance's status).
    func controlSent(_ deviceID: String) -> [String: Int] { streams[deviceID]?.sent ?? [:] }

    /// The packets that may go now; about 60 times a second while any phone is controlled.
    func flushControl() {
        for stream in streams.values where stream.control.phase == .active { flushControl(stream) }
    }

    private func flushControl(_ stream: Stream) {
        guard let sender = stream.sender else { return }
        for packet in sender.flush() { sendInput(stream, packet) }
    }

    private func sendInput(_ stream: Stream, _ packet: ScreenControl.Packet) {
        _ = send(stream.deviceID, PhoneControlKinds.input, packet.json)
        let op: String = switch packet.input {
        case let .touch(_, phase, _, _): "touch_\(phase.rawValue)"
        case .scroll: "scroll"
        case .navigate: "navigate"
        case .text: "text"
        case .key: "key"
        case .geometryAck: "geometry_ack"
        case .heartbeat: "heartbeat"
        case .stop: "stop"
        case .pointer, .button: "pointer"
        }
        stream.sent[op, default: 0] += 1
        if op != "heartbeat" && op != "touch_move" && op != "scroll" {
            BridgeyLog.screen.notice("phone control sent op=\(op, privacy: .public) seq=\(packet.seq, privacy: .public)")
        }
    }

    private func controlMessage(_ stream: Stream, _ state: PhoneControlState) {
        guard let offer = stream.offer else { return }
        switch state {
        case .waiting:
            guard stream.control.phase == .starting else { return }
            stream.control.phase = .waiting
        case let .active(session, input):
            guard stream.control.phase == .starting || stream.control.phase == .waiting, let geometry = stream.geometry else { return }
            let sender = PhoneControlSender(clock: monotonicMs)
            let packets = sender.begin(session: session, input: input,
                                       binding: PhoneControlSender.Binding(transport: offer.transport, connection: stream.connection, stream: offer.stream),
                                       geometryGeneration: geometry.generation)
            guard !packets.isEmpty else {
                endControlLocally(stream, note: .failed)
                return
            }
            stream.sender = sender
            stream.sent = [:]
            stream.control.phase = .active
            stream.control.input = input
            stream.control.note = nil
            packets.forEach { sendInput(stream, $0) }
            ensureFlusher()
            BridgeyLog.screen.notice("phone control active session=\(session, privacy: .public) text=\(input.text, privacy: .public)")
        case let .ended(reason), let .refused(reason):
            BridgeyLog.screen.notice("phone control over reason=\(reason.rawValue, privacy: .public) sent=\(stream.sent.description, privacy: .public)")
            endControlLocally(stream, note: reason == .user ? nil : reason)
            return
        case let .available(allowed):
            stream.control.allowed = allowed
        }
        publishControl(stream)
    }

    private func geometryChanged(_ stream: Stream, _ geometry: ScreenControl.Geometry) {
        guard let current = stream.geometry, geometry.generation > current.generation, geometry.source == current.source else { return }
        stream.geometry = geometry
        stream.control.width = Int(geometry.width)
        stream.control.height = Int(geometry.height)
        stream.control.epoch += 1
        // Input not sent yet is dropped and the new generation acknowledged before anything else.
        stream.sender?.geometryChanged(geometry.generation).forEach { sendInput(stream, $0) }
        publishControl(stream)
        BridgeyLog.screen.notice("phone control geometry generation=\(geometry.generation, privacy: .public) size=\(geometry.width, privacy: .public)x\(geometry.height, privacy: .public)")
    }

    private func endControlLocally(_ stream: Stream, note: PhoneControlReason?) {
        stream.sender?.end()
        stream.sender = nil
        guard stream.control.phase != .off || note != nil else { return }
        stream.control.phase = .off
        stream.control.note = note
        stream.control.epoch += 1
        if streams[stream.deviceID] === stream { publishControl(stream) }
        if !streams.values.contains(where: { $0.control.phase == .active }) {
            flusher?.invalidate()
            flusher = nil
        }
    }

    private func publishControl(_ stream: Stream) {
        presenter?.updateControl(deviceID: stream.deviceID, control: stream.control)
    }

    private func ensureFlusher() {
        guard flusher == nil, defaults != nil else { return }
        flusher = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushControl() }
        }
    }

    // MARK: Private

    private func stop(_ stream: Stream, reason: ScreenStopReason, message: String?) {
        _ = send(stream.deviceID, "screen.stop", screenStopPayload(streamID: stream.streamID, sequence: stream.nextSequence(), reason: reason))
        BridgeyLog.screen.notice("screen stopped here stream=\(String(stream.streamID.prefix(8)), privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        end(stream, message: message)
    }

    private func end(_ stream: Stream, message: String?) {
        guard streams[stream.deviceID] === stream else { return }
        streams.removeValue(forKey: stream.deviceID)
        streaming.remove(stream.deviceID)
        endControlLocally(stream, note: nil)
        stream.receiver.finish()
        remember(stream.streamID)
        presenter?.close(deviceID: stream.deviceID, message: message)
        if let message { status = message }
    }

    private func refuse(_ streamID: String, deviceID: String, reason: ScreenStopReason) {
        _ = send(deviceID, "screen.stop", screenStopPayload(streamID: streamID, sequence: 1, reason: reason))
        remember(streamID)
    }

    private func isKnown(_ streamID: String) -> Bool {
        endedStreamIDs.contains(streamID) || streams.values.contains { $0.streamID == streamID }
    }

    private func remember(_ streamID: String) {
        endedStreamIDs.removeAll { $0 == streamID }
        endedStreamIDs.append(streamID)
        if endedStreamIDs.count > Self.rememberedStreams { endedStreamIDs.removeFirst(endedStreamIDs.count - Self.rememberedStreams) }
    }

    private func ensureTicker() {
        guard ticker == nil, defaults != nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The panel line fades after eight seconds unless something newer replaced it.
    private func scheduleClear(_ line: String?) {
        guard let line else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.status == line { self?.status = nil }
        }
    }
}

func screenStatusText(_ status: ScreenStatus, phone: String) -> String {
    switch status {
    case .waiting: String(format: L10n.text("screen.status.waiting", fallback: "Tap the notification on %@"), phone)
    case .declined: String(format: L10n.text("screen.status.declined", fallback: "%@ did not share its screen"), phone)
    case .busy: String(format: L10n.text("screen.status.busy", fallback: "%@ is sharing its screen with another Mac"), phone)
    case .disabled: String(format: L10n.text("screen.status.disabled", fallback: "Share screen with Macs is off on %@"), phone)
    case .failed: String(format: L10n.text("screen.status.failed", fallback: "%@ could not share its screen"), phone)
    }
}

/// The line the window shows before it closes when the phone ends the stream.
func screenEndedText(_ reason: ScreenStopReason, phone: String) -> String {
    switch reason {
    case .user, .ended: String(format: L10n.text("screen.ended.phone", fallback: "Sharing stopped on %@"), phone)
    case .screenOff: String(format: L10n.text("screen.ended.screenOff", fallback: "%@ locked its screen"), phone)
    case .disabled: String(format: L10n.text("screen.status.disabled", fallback: "Share screen with Macs is off on %@"), phone)
    case .timeout: String(format: L10n.text("screen.ended.timeout", fallback: "Lost the screen of %@"), phone)
    case .closed, .invalid, .failed: String(format: L10n.text("screen.ended.failed", fallback: "The screen of %@ stopped"), phone)
    }
}
