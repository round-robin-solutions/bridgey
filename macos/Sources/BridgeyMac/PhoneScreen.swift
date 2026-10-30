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
    /// Opens the window for a new stream and returns where frames are shown.
    func open(deviceID: String, phoneName: String, width: Int, height: Int, onClose: @escaping () -> Void) -> ScreenDisplaySink?
    func update(deviceID: String, stats: ScreenStats)
    func resize(deviceID: String, width: Int, height: Int)
    func bringToFront(deviceID: String)
    /// `message`: shown briefly before the window closes; nil closes it at once.
    func close(deviceID: String, message: String?)
}

@MainActor
final class PhoneScreen: ObservableObject {
    static let lifetime: TimeInterval = 120
    static let spacing: TimeInterval = 3
    static let streamTimeout: TimeInterval = 6
    static let rememberedStreams = 16
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

        init(streamID: String, deviceID: String, phoneName: String, receiver: ScreenStreamReceiver) {
            self.streamID = streamID
            self.deviceID = deviceID
            self.phoneName = phoneName
            self.receiver = receiver
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
    weak var presenter: PhoneScreenPresenter?

    private let defaults: UserDefaults?
    private let clock: () -> Date
    private var lastRequest: [String: Date] = [:]
    private(set) var streams: [String: Stream] = [:]
    private(set) var endedStreamIDs: [String] = []
    private var ticker: Timer?

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

    /// A decrypted `screen.start` from `deviceID`, whose session key is `key`.
    func receiveStart(_ data: Data, from deviceID: String, phoneName: String, key: Data) {
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
        let stream = Stream(streamID: start.streamID, deviceID: deviceID, phoneName: phoneName, receiver: receiver)
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
                                      onClose: { [weak self, weak stream] in
                                          guard let self, let stream, self.streams[deviceID] === stream else { return }
                                          self.stop(stream, reason: .closed, message: nil)
                                      }) {
            receiver.attach(sink)
        }
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
