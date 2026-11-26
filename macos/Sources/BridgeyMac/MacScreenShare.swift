import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import os

/*
 * Mac screen to phone, draft `screen_control_draft1` (docs/protocol.md, "Mac screen to phone"): this Mac as the
 * source. Unattended access (on by default) lets a paired device with no choice of its own see this screen without
 * asking; each device can be set to Off, Ask each time or Allow without asking instead, and servers and agents never
 * get anything (MacScreenGrants). A request asks the person on this Mac only with Ask each time; the stream then runs
 * on the phone's session, paced by its acks (MacScreenStreamSender). Control is a separate permission (the existing
 * Remote control grant plus Accessibility) and goes through the shared contract's HostSession: every input packet
 * is checked against a fresh local authority, every release is applied before anything is injected, and positions
 * map onto the selected display only. The pill names the viewer for the whole stream, with Stop.
 */

let screenControlFeatureKey = "screen_control_draft1"

/// Every display.* kind (docs/protocol.md). Sent or handled by this Mac.
enum DisplayKinds {
    static let request = "display.request"
    static let status = "display.status"
    static let start = "display.start"
    static let started = "display.started"
    static let frame = "display.frame"
    static let ack = "display.ack"
    static let stats = "display.stats"
    static let geometry = "display.geometry"
    static let control = "display.control"
    static let input = "display.input"
    static let stop = "display.stop"

    /// The viewer's stream messages, decrypted outside the message ID window.
    static let fromViewerStream: Set<String> = [started, ack, control, stop]
}

/// What this Mac knows about the session a phone is connected on, for the contract's binding.
struct MacScreenPeer: Equatable {
    let name: String
    let identityKey: String
    /// This Mac's generation for that session (one counter per process).
    let transport: UInt64
    /// HMAC of the session key over the session ID (ScreenControl.connectionNonce).
    let connection: [UInt8]
}

/// The pill while a phone views or controls this Mac.
@MainActor
protocol DisplayIndicating: AnyObject {
    func show(deviceName: String, controlling: Bool, displayID: UInt32, onStop: @escaping () -> Void)
    func hide()
}

/// The prompt for Ask each time.
@MainActor
protocol DisplayConsentPresenting: AnyObject {
    /// `canAllow` is read when Allow is pressed: while any remote control session runs, Allow does nothing.
    func ask(deviceName: String, canAllow: @escaping () -> Bool, answer: @escaping (Bool) -> Void)
    func dismiss()
}

/// The pieces of the system the host uses; tests and test instances replace them.
@MainActor
struct MacScreenEnvironment {
    var displays: MacDisplayProviding
    var makeSource: () -> MacScreenSource
    var makeEncoder: (Int, Int) -> MacScreenEncoding
    var injector: ScreenControlInjecting
    var indicator: DisplayIndicating
    var consent: DisplayConsentPresenting
    var grants: MacScreenGrants
    /// Screen Recording, never prompting (CGPreflightScreenCaptureAccess).
    var captureAllowed: () -> Bool
    /// macOS asks for Screen Recording; only from Settings, when a phone's choice (or Unattended access) changes from Off.
    var requestCapture: () -> Void
    /// Accessibility, never prompting.
    var accessibility: () -> Bool
    var focusedWindow: () -> CGRect?
    var clock: () -> Date = Date.init
    var monotonicMs: () -> UInt64 = { UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
    var defaults: UserDefaults? = .standard
    var schedulesTimer = true
}

@MainActor
final class MacScreenShare: ObservableObject {
    static let displayDefaultsKey = "settings.screenShare.display"
    nonisolated static let auditMode = "screen"

    /// A phone sees (and maybe controls) this Mac now.
    struct Session: Equatable {
        let deviceID: String
        let deviceName: String
        var controlling: Bool
        let startedAt: Date
    }

    @Published private(set) var active: Session?
    /// The phone whose request waits for Allow on this Mac.
    @Published private(set) var asking: String?
    /// Bumped when a grant changes, so Settings redraws.
    @Published private(set) var grantsVersion = 0
    @Published private(set) var displayList: [MacDisplayInfo] = []
    @Published private(set) var selectedDisplayID: UInt32?

    // Set by the coordinator.
    /// display.status through the shared message ID window; false when not connected.
    var send: (_ deviceID: String, _ kind: String, _ payload: [String: Any]) -> Bool = { _, _, _ in false }
    /// The stream link bound to the phone's current session.
    var link: (_ deviceID: String) -> MacScreenLink? = { _ in nil }
    var peer: (_ deviceID: String) -> MacScreenPeer? = { _ in nil }
    var identityKey: (_ deviceID: String) -> String? = { _ in nil }
    /// A server or agent paired with this Mac (or a device paired over the tailnet until trusted): never any screen access.
    var isRestricted: (_ deviceID: String) -> Bool = { _ in false }
    /// The phone's own map shows screen_control_draft1.
    var peerAdvertises: (_ deviceID: String) -> Bool = { _ in false }
    /// Remote control on here and allowed for that phone (control is a separate permission).
    var controlGrant: (_ deviceID: String) -> Bool = { _ in false }
    /// The phone controlling this Mac by touchpad (remote_input_draft1), if any.
    var touchpadController: () -> String? = { nil }
    /// A grant changed: features.update to every phone and a redraw.
    var onGrantsChange: () -> Void = {}
    var audit: RemoteControlAuditLog?

    let environment: MacScreenEnvironment
    private var grants: MacScreenGrants { environment.grants }

    private struct PendingRequest {
        let requestID: String
        let deviceID: String
        let deviceName: String
        let capabilities: ScreenControl.Capabilities
        let at: Date
    }

    /// The stream that runs now.
    final class Stream {
        let deviceID: String
        let deviceName: String
        let requestID: String
        let viewer: ScreenControl.Capabilities
        let sender: MacScreenStreamSender
        let source: MacScreenSource
        let encoder: MacScreenEncoding
        let number: UInt64
        let startedAt: Date
        var display: MacDisplayInfo
        var geometry: ScreenControl.Geometry
        var control: ScreenControl.SessionInfo?
        var input = ScreenControl.InputCapabilities()
        var lastPoint: CGPoint?
        var counts: [String: Int] = [:]
        var rejected = 0
        var controlled = false
        /// Started after the person allowed it on this Mac's prompt (Ask each time). A stream that started without one ends
        /// when the device is lowered to Ask each time.
        var prompted = false
        /// Why the last keyboard authority was not ready (focus, permission or a key this Mac never posts).
        var ineligible: DisplayControlReason?

        var streamID: String { sender.streamID }

        init(deviceID: String, deviceName: String, requestID: String, viewer: ScreenControl.Capabilities, sender: MacScreenStreamSender,
             source: MacScreenSource, encoder: MacScreenEncoding, number: UInt64, startedAt: Date, display: MacDisplayInfo,
             geometry: ScreenControl.Geometry) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.requestID = requestID
            self.viewer = viewer
            self.sender = sender
            self.source = source
            self.encoder = encoder
            self.number = number
            self.startedAt = startedAt
            self.display = display
            self.geometry = geometry
        }
    }

    private var pending: [String: PendingRequest] = [:]
    private var lastRequestAt: [String: Date] = [:]
    private(set) var stream: Stream?
    private var host = ScreenControl.HostSession()
    private var streamCounter: UInt64 = 0
    private var authorityGeneration: UInt64 = 0
    private var lastAuthority: ScreenControl.Authority?
    private(set) var locked = false
    private var ticker: Timer?
    private var lockObservers: [NSObjectProtocol] = []

    /// What this Mac can do as a source: capture, H.264, and pointer, keys and text as a host. Never touch or
    /// navigation (no such input on a Mac). Support, not permission.
    static let hostCapabilities = ScreenControl.Capabilities(
        v: ScreenControl.version, screenSource: true, fullDisplaySource: true, h264Encode: true,
        inputHost: ScreenControl.InputCapabilities(pointer: true, keys: true, text: true), captureRestoreSupported: true)

    init(environment: MacScreenEnvironment) {
        self.environment = environment
        selectedDisplayID = (environment.defaults?.object(forKey: Self.displayDefaultsKey) as? NSNumber)?.uint32Value
        environment.displays.onChange = { [weak self] in self?.displaysChanged() }
        displayList = environment.displays.displays()
    }

    // MARK: Grants and advertising

    /// What the device gets now: its own choice, else Unattended access; never anything for a server or agent.
    func grantMode(for deviceID: String) -> MacScreenGrantMode {
        let key = identityKey(deviceID)
        return MacScreenGrants.resolve(explicit: grants.explicitMode(for: deviceID, identityKey: key), unattended: grants.unattended,
                                       restricted: isRestricted(deviceID), keyKnown: key != nil)
    }

    /// The device's own choice; nil when it follows Unattended access (Default in Settings).
    func explicitGrant(for deviceID: String) -> MacScreenGrantMode? {
        grants.explicitMode(for: deviceID, identityKey: identityKey(deviceID))
    }

    /// Settings > Remote control > This Mac's screen > Unattended access.
    var unattended: Bool { grants.unattended }

    /// screen_control_draft1 in this Mac's features.update to that phone.
    func advertised(to deviceID: String) -> Bool { grantMode(for: deviceID) != .off }

    /// Settings: a device's choice, or nil for Default (it follows Unattended access). A change that gives the device
    /// more than it has now asks macOS for Screen Recording if it is missing (the only place a prompt may come from).
    /// Raising is refused while anything controls this Mac (a phone could otherwise open Settings and allow itself,
    /// security review 1.0), also when going back to Default raises it; lowering always works. A server or agent can be
    /// set to Off, never higher.
    @discardableResult
    func setGrant(_ mode: MacScreenGrantMode?, for deviceID: String) -> Bool {
        guard let key = identityKey(deviceID) else { return false }
        let before = grantMode(for: deviceID)
        let after = MacScreenGrants.resolve(explicit: mode, unattended: grants.unattended, restricted: isRestricted(deviceID), keyKnown: true)
        if isRestricted(deviceID), let mode, mode != .off { return false }
        if after.rank > before.rank && !allowPossible { return false }
        guard grants.set(mode, for: deviceID, identityKey: key) else { return false }
        grantsVersion += 1
        if before == .off, after != .off, !environment.captureAllowed() { environment.requestCapture() }
        onGrantsChange()
        policyChanged()
        return true
    }

    /// Settings: Unattended access. Turning it on is refused while anything controls this Mac (it raises every device
    /// on Default); turning it off always works and ends a stream to a device on Default.
    @discardableResult
    func setUnattended(_ on: Bool) -> Bool {
        guard on != grants.unattended else { return true }
        if on && !allowPossible { return false }
        guard grants.setUnattended(on) else { return false }
        grantsVersion += 1
        if on, !environment.captureAllowed() { environment.requestCapture() }
        onGrantsChange()
        policyChanged()
        return true
    }

    /// The phone was forgotten: its grant goes with it.
    func forget(_ deviceID: String) {
        grants.remove(deviceID)
        grantsVersion += 1
        policyChanged()
    }

    // MARK: Displays

    var selectedDisplay: MacDisplayInfo? {
        let list = environment.displays.displays()
        if let id = selectedDisplayID, let chosen = list.first(where: { $0.id == id }) { return chosen }
        return list.first { $0.id == environment.displays.mainDisplayID } ?? list.first
    }

    func setSelectedDisplay(_ id: UInt32?) {
        selectedDisplayID = id
        if let id { environment.defaults?.set(NSNumber(value: id), forKey: Self.displayDefaultsKey) } else {
            environment.defaults?.removeObject(forKey: Self.displayDefaultsKey)
        }
        // A new source is never retargeted: the stream ends and the phone asks again.
        if let current = stream, current.display.id != selectedDisplay?.id { endStream(current, reason: .sourceChanged, tell: true) }
    }

    func refreshDisplays() {
        let list = environment.displays.displays()
        if list != displayList { displayList = list }
    }

    // MARK: Requests

    /// A decrypted display.request from an authenticated phone.
    func receiveRequest(_ data: Data, from deviceID: String, deviceName: String) {
        guard let request = DisplayRequest.decode(data) else { return }
        let now = environment.clock()
        if let last = lastRequestAt[deviceID], now.timeIntervalSince(last) < DisplayLimits.requestSpacing { return }
        if pending[deviceID] != nil { return }
        lastRequestAt[deviceID] = now
        func answer(_ status: DisplayStatus) {
            _ = send(deviceID, DisplayKinds.status, DisplayPayloads.status(requestID: request.requestID, status: status))
            BridgeyLog.screen.notice("display request answered status=\(status.rawValue, privacy: .public) peer=\(shortDeviceID(deviceID), privacy: .public)")
        }
        let mode = grantMode(for: deviceID)
        guard mode != .off else { return answer(.disabled) }
        guard !locked else { return answer(.locked) }
        if let current = stream {
            guard current.deviceID == deviceID else { return answer(.busy) }
            // A new request from the phone that is watching: the old stream ends; this one is asked for again.
            endStream(current, reason: nil, tell: false)
        }
        guard environment.captureAllowed() else { return answer(.permission) }
        guard request.capabilities.screenViewer, request.capabilities.h264Decode else { return answer(.failed) }
        let entry = PendingRequest(requestID: request.requestID, deviceID: deviceID, deviceName: deviceName, capabilities: request.capabilities, at: now)
        switch mode {
        case .off:
            return
        case .always:
            begin(entry, prompted: false)
        case .ask:
            guard asking == nil else { return answer(.busy) }
            pending[deviceID] = entry
            asking = deviceName
            answer(.waiting)
            environment.consent.ask(deviceName: deviceName, canAllow: { [weak self] in self?.allowPossible ?? false }) { [weak self] allowed in
                self?.consentAnswered(deviceID: deviceID, requestID: request.requestID, allowed: allowed)
            }
            ensureTicker()
        }
    }

    /// Allow on the prompt does nothing while anything controls this Mac: a phone could otherwise press it itself.
    var allowPossible: Bool { touchpadController() == nil && !host.isActive }

    /// The prompt's answer (or a test instance's screen-allow / screen-deny).
    func consentAnswered(deviceID: String, requestID: String, allowed: Bool) {
        guard let entry = pending[deviceID], entry.requestID == requestID else { return }
        pending.removeValue(forKey: deviceID)
        asking = nil
        environment.consent.dismiss()
        func answer(_ status: DisplayStatus) {
            _ = send(deviceID, DisplayKinds.status, DisplayPayloads.status(requestID: requestID, status: status))
        }
        guard allowed else { return answer(.declined) }
        // Everything may have changed while the prompt was up.
        guard grantMode(for: deviceID) != .off else { return answer(.disabled) }
        guard !locked else { return answer(.locked) }
        guard stream == nil else { return answer(.busy) }
        guard environment.captureAllowed() else { return answer(.permission) }
        begin(entry, prompted: true)
    }

    /// The pending prompt, answered from a test instance's control file.
    func answerPendingPrompt(_ allowed: Bool) {
        guard let entry = pending.values.first else { return }
        if allowed && !allowPossible { return }
        consentAnswered(deviceID: entry.deviceID, requestID: entry.requestID, allowed: allowed)
    }

    /// `prompted`: the person allowed this stream on this Mac's prompt.
    private func begin(_ entry: PendingRequest, prompted: Bool) {
        func answer(_ status: DisplayStatus) {
            _ = send(entry.deviceID, DisplayKinds.status, DisplayPayloads.status(requestID: entry.requestID, status: status))
        }
        guard let display = selectedDisplay else { return answer(.failed) }
        guard let link = link(entry.deviceID), let peer = peer(entry.deviceID) else { return }
        let size = DisplayGeometryRules.captureSize(nativeWidth: display.pixelWidth, nativeHeight: display.pixelHeight)
        streamCounter += 1
        let geometry = ScreenControl.Geometry(generation: 1, source: UInt64(display.id), kind: .display, width: UInt32(size.width),
                                              height: UInt32(size.height))
        let sender = MacScreenStreamSender(link: link)
        let encoder = environment.makeEncoder(size.width, size.height)
        let source = environment.makeSource()
        let current = Stream(deviceID: entry.deviceID, deviceName: entry.deviceName, requestID: entry.requestID, viewer: entry.capabilities,
                             sender: sender, source: source, encoder: encoder, number: streamCounter, startedAt: environment.clock(),
                             display: display, geometry: geometry)
        current.prompted = prompted
        encoder.onAccessUnit = { [weak sender] unit in sender?.encoded(unit) }
        sender.encoder = encoder
        sender.onEnded = { [weak self, weak current] reason, told in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.senderEnded(current, reason: reason, told: told) } }
        }
        stream = current
        let control = controlGrant(entry.deviceID) && environment.accessibility()
        let number = streamCounter
        let started = sender.start { sequence in
            DisplayPayloads.start(DisplayStartInfo(streamID: sender.streamID, sequence: sequence, requestID: entry.requestID, fps: MacScreenRates.fps,
                                                   bitrate: sender.currentBitrate, stream: number, transport: peer.transport, geometry: geometry,
                                                   capabilities: Self.hostCapabilities, control: control, displayName: display.name))
        }
        guard started, stream === current else {
            if stream === current { stream = nil }
            encoder.invalidate()
            return
        }
        source.start(display: display, width: size.width, height: size.height, fps: MacScreenRates.fps,
                     frames: { [weak encoder] image, micros in encoder?.encode(image, captureMicros: micros) },
                     failed: { [weak self, weak current] why in
                         DispatchQueue.main.async {
                             MainActor.assumeIsolated {
                                 guard let self, let current, self.stream === current else { return }
                                 BridgeyLog.screen.error("display source failed: \(why, privacy: .public)")
                                 self.endStream(current, reason: why == "screen_recording_not_allowed" ? .permission : .failed, tell: true)
                             }
                         }
                     })
        active = Session(deviceID: entry.deviceID, deviceName: entry.deviceName, controlling: false, startedAt: current.startedAt)
        environment.indicator.show(deviceName: entry.deviceName, controlling: false, displayID: display.id) { [weak self] in self?.stopLocally() }
        BridgeyLog.screen.notice("display stream begun stream=\(String(sender.streamID.prefix(8)), privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public) control=\(control, privacy: .public) peer=\(shortDeviceID(entry.deviceID), privacy: .public)")
        ensureTicker()
    }

    // MARK: The viewer's stream messages

    /// display.started, display.ack, display.control or display.stop from `deviceID`, decrypted.
    func receiveStream(kind: String, data: Data, from deviceID: String) {
        guard let current = stream, current.deviceID == deviceID else { return }
        switch kind {
        case DisplayKinds.started:
            guard let message = DisplayStarted.decode(data), message.streamID == current.streamID,
                  current.sender.acceptViewerSequence(message.sequence) else { return }
            current.sender.receiveStarted()
        case DisplayKinds.ack:
            guard let message = DisplayAck.decode(data), message.streamID == current.streamID,
                  current.sender.acceptViewerSequence(message.sequence) else { return }
            current.sender.receiveAck(frame: message.frame, decodeMs: message.decodeMs, keyframe: message.keyframe)
        case DisplayKinds.control:
            guard let message = DisplayViewerControl.decode(data), message.streamID == current.streamID,
                  current.sender.acceptViewerSequence(message.sequence) else { return }
            switch message.action {
            case .begin: beginControl(current)
            case .end:
                if host.isActive { controlStopped(current, transition: host.stop(.user), reason: .user) }
            }
        case DisplayKinds.stop:
            guard let message = DisplayStop.decode(data), message.streamID == current.streamID,
                  current.sender.acceptViewerSequence(message.sequence) else { return }
            BridgeyLog.screen.notice("display stopped by viewer reason=\(message.reason.rawValue, privacy: .public)")
            endStream(current, reason: message.reason, tell: false)
        default:
            break
        }
    }

    // MARK: Control

    private func beginControl(_ current: Stream) {
        func refuse(_ reason: DisplayControlReason) {
            current.sender.send(kind: DisplayKinds.control) { sequence in
                DisplayPayloads.control(streamID: current.streamID, sequence: sequence, state: .refused(reason))
            }
            BridgeyLog.screen.notice("display control refused reason=\(reason.rawValue, privacy: .public)")
        }
        guard current.sender.phase == .streaming else { return refuse(.invalid) }
        guard !host.isActive else { return }
        guard controlGrant(current.deviceID) else { return refuse(.disabled) }
        guard !locked else { return refuse(.locked) }
        guard environment.accessibility() else { return refuse(.permission) }
        if let other = touchpadController(), other != current.deviceID { return refuse(.busy) }
        guard let authority = authority(for: current, input: nil, fresh: true) else { return refuse(.failed) }
        switch host.begin(authority, geometry: current.geometry, nowMs: environment.monotonicMs()) {
        case let .success(info):
            let input = (try? ScreenControl.Capabilities.negotiatedInput(host: Self.hostCapabilities, controller: current.viewer).get()) ?? ScreenControl.InputCapabilities()
            current.control = info
            current.input = input
            current.controlled = true
            current.sender.send(kind: DisplayKinds.control) { sequence in
                DisplayPayloads.control(streamID: current.streamID, sequence: sequence, state: .active(session: info.session, input: input))
            }
            active?.controlling = true
            environment.indicator.show(deviceName: current.deviceName, controlling: true, displayID: current.display.id) { [weak self] in self?.stopLocally() }
            BridgeyLog.screen.notice("display control active session=\(info.session, privacy: .public)")
        case let .failure(rejection):
            refuse(Self.controlReason(for: rejection))
        }
    }

    /// The device controlling this Mac through a stream, if any.
    var controllerDevice: String? { host.isActive ? stream?.deviceID : nil }

    /// A decrypted display.input from `deviceID`, with the binding of the session it arrived on.
    func receiveInput(_ data: Data, from deviceID: String, via arrival: MacScreenPeer) {
        guard let current = stream, current.deviceID == deviceID, host.isActive else { return }
        let packet: ScreenControl.Packet
        switch ScreenControl.Packet.decode(data) {
        case let .success(decoded): packet = decoded
        case .failure:
            // Malformed input from the controlling phone stops control and releases what it held.
            controlStopped(current, transition: host.stop(.invalidInput), reason: .invalid)
            return
        }
        guard let authority = authority(for: current, input: packet.input, fresh: false) else { return }
        let sender = binding(deviceID: deviceID, peer: arrival)
        let transition = host.receive(authority, sender: sender, packet: packet, nowMs: environment.monotonicMs())
        switch transition.status {
        case .accepted:
            applyRelease(transition.release, in: current)
            inject(packet.input, in: current)
        case .rejected:
            applyRelease(transition.release, in: current)
            current.rejected += 1
        case let .stopped(reason):
            controlStopped(current, transition: transition, reason: controlReason(for: reason, in: current))
        }
    }

    /// Fresh local authority. Its generation advances whenever anything in it changes; `fresh` forces a new one (a
    /// genuinely new control session after a stop).
    private func authority(for current: Stream, input: ScreenControl.Input?, fresh: Bool) -> ScreenControl.Authority? {
        guard let peer = peer(current.deviceID) else { return nil }
        let accessibility = environment.accessibility()
        var ready = accessibility
        current.ineligible = accessibility ? nil : .permission
        var keyboard = false
        var key: ScreenControl.Key?
        switch input {
        case let .key(pressed, _):
            keyboard = true
            key = pressed
        case .text:
            keyboard = true
        default:
            break
        }
        if accessibility && keyboard {
            if let key, !key.allowedOnMac {
                ready = false
                current.ineligible = .invalid
            } else if !DisplayGeometryRules.keyboardEligible(display: current.display.bounds, focusedWindow: environment.focusedWindow(),
                                                              displayCount: environment.displays.displays().count) {
                ready = false
                current.ineligible = .focus
            }
        }
        var body = ScreenControl.Authority(
            generation: 0, binding: binding(deviceID: current.deviceID, peer: peer), stream: current.number,
            trustedDevice: identityKey(current.deviceID) != nil, viewGrant: grantMode(for: current.deviceID) != .off,
            controlGrant: controlGrant(current.deviceID), captureReady: environment.captureAllowed(), inputReady: ready, unlocked: !locked,
            streamActive: current.sender.phase == .streaming, host: Self.hostCapabilities, controller: current.viewer)
        if fresh || body != lastAuthority {
            authorityGeneration += 1
            lastAuthority = body
        }
        body.generation = authorityGeneration
        return body
    }

    private func binding(deviceID: String, peer: MacScreenPeer) -> ScreenControl.Binding {
        ScreenControl.Binding(peer: ScreenControl.PeerIdentity(device: Self.deviceDigest(deviceID), keySHA256: screenIdentityDigest(peer.identityKey)),
                              transport: peer.transport, connection: peer.connection)
    }

    /// The pinned device as 16 bytes: the first half of SHA-256 of its ID.
    static func deviceDigest(_ deviceID: String) -> [UInt8] { Array(SHA256.hash(data: Data(deviceID.utf8)).prefix(16)) }

    /// Every release the contract returns, before anything else is injected.
    private func applyRelease(_ release: ScreenControl.HeldInput, in current: Stream) {
        guard !release.isEmpty else { return }
        let point = current.lastPoint ?? CGPoint(x: current.display.bounds.midX, y: current.display.bounds.midY)
        for button in release.heldButtons { environment.injector.button(button.pointer, down: false, at: point) }
        for key in release.heldKeys where key.allowedOnMac { environment.injector.key(key, down: false, shift: false) }
    }

    private func inject(_ input: ScreenControl.Input, in current: Stream) {
        func point(_ x: Double, _ y: Double) -> CGPoint? {
            guard let mapped = DisplayGeometryRules.macPoint(geometry: current.geometry, bounds: current.display.bounds, x: x, y: y) else { return nil }
            current.lastPoint = mapped.point
            current.source.markInput(x: x, y: y)
            return mapped.point
        }
        let held = Set(host.held.heldButtons.map(\.pointer))
        switch input {
        case let .pointer(x, y):
            guard let at = point(x, y) else { return }
            environment.injector.moveTo(at, held: held)
            current.counts[RemoteInputEventType.pointer.rawValue, default: 0] += 1
        case let .button(button, down, x, y):
            guard let at = point(x, y) else { return }
            environment.injector.button(button.pointer, down: down, at: at)
            current.counts[RemoteInputEventType.button.rawValue, default: 0] += down ? 1 : 0
        case let .scroll(dx, dy, x, y):
            guard let at = point(x, y) else { return }
            environment.injector.scroll(dx: Int(dx), dy: Int(dy), at: at)
            current.counts[RemoteInputEventType.scroll.rawValue, default: 0] += 1
        case let .key(key, down):
            let shift = host.held.heldKeys.contains(.shift)
            environment.injector.key(key, down: down, shift: shift)
            current.counts[RemoteInputEventType.key.rawValue, default: 0] += down ? 1 : 0
        case let .text(text):
            environment.injector.type(text)
            current.counts[RemoteInputEventType.text.rawValue, default: 0] += 1
        case .touch, .navigate, .geometryAck, .heartbeat, .stop:
            break
        }
    }

    /// Control ended (the stream goes on): releases first, then `display.control` ended with the reason.
    private func controlStopped(_ current: Stream, transition: ScreenControl.Transition, reason: DisplayControlReason) {
        applyRelease(transition.release, in: current)
        guard current.control != nil else { return }
        current.control = nil
        current.sender.send(kind: DisplayKinds.control) { sequence in
            DisplayPayloads.control(streamID: current.streamID, sequence: sequence, state: .ended(reason))
        }
        if stream === current {
            active?.controlling = false
            environment.indicator.show(deviceName: current.deviceName, controlling: false, displayID: current.display.id) { [weak self] in self?.stopLocally() }
        }
        BridgeyLog.screen.notice("display control ended reason=\(reason.rawValue, privacy: .public)")
    }

    private func controlReason(for reason: ScreenControl.StopReason, in current: Stream) -> DisplayControlReason {
        switch reason {
        case .user: .user
        case .revoked: .disabled
        case .permissionLost: current.ineligible ?? .permission
        case .locked: .locked
        case .disconnected: .failed
        case .timeout: .timeout
        case .sequenceGap, .invalidInput, .geometryInvalid, .clock, .exhausted: .invalid
        case .rateLimited: .rate
        case .sourceChanged: .sourceChanged
        case .authorityChanged: localRefusal(current) ?? .failed
        }
    }

    /// Why this Mac would not allow control now, from its own state.
    private func localRefusal(_ current: Stream) -> DisplayControlReason? {
        if !controlGrant(current.deviceID) || grantMode(for: current.deviceID) == .off { return .disabled }
        if locked { return .locked }
        if !environment.accessibility() { return .permission }
        return current.ineligible
    }

    static func controlReason(for rejection: ScreenControl.Rejection) -> DisplayControlReason {
        switch rejection {
        case .grant, .identity: .disabled
        case .permission: .permission
        case .locked: .locked
        case .busy: .busy
        default: .failed
        }
    }

    /// Any change to grants, permissions, the lock or a device becoming restricted: control re-checks its authority, a
    /// stream without a grant ends, and so does one that started without a prompt when its device is now Ask each time.
    func policyChanged() {
        for (deviceID, entry) in pending where grantMode(for: deviceID) == .off {
            pending.removeValue(forKey: deviceID)
            asking = nil
            environment.consent.dismiss()
            _ = send(deviceID, DisplayKinds.status, DisplayPayloads.status(requestID: entry.requestID, status: .disabled))
        }
        guard let current = stream else { return }
        let mode = grantMode(for: current.deviceID)
        if mode == .off || (mode == .ask && !current.prompted) {
            endStream(current, reason: .disabled, tell: true)
            return
        }
        synchronizeControl(current)
    }

    private func synchronizeControl(_ current: Stream) {
        guard host.isActive, let authority = authority(for: current, input: nil, fresh: false) else { return }
        let transition = host.synchronize(authority)
        if case let .stopped(reason) = transition.status {
            controlStopped(current, transition: transition, reason: controlReason(for: reason, in: current))
        } else {
            applyRelease(transition.release, in: current)
        }
    }

    // MARK: Geometry

    private func displaysChanged() {
        displayList = environment.displays.displays()
        guard let current = stream else { return }
        guard let display = displayList.first(where: { $0.id == current.display.id }) else {
            endStream(current, reason: .sourceChanged, tell: true)
            return
        }
        current.display = display
        let size = DisplayGeometryRules.captureSize(nativeWidth: display.pixelWidth, nativeHeight: display.pixelHeight)
        guard size.width != Int(current.geometry.width) || size.height != Int(current.geometry.height) else { return }
        var geometry = current.geometry
        geometry.generation += 1
        geometry.width = UInt32(size.width)
        geometry.height = UInt32(size.height)
        if let info = current.control {
            let transition = host.geometryChanged(expected: info, geometry: geometry)
            if case let .stopped(reason) = transition.status {
                controlStopped(current, transition: transition, reason: controlReason(for: reason, in: current))
            } else {
                applyRelease(transition.release, in: current)
                current.control = host.info
            }
        }
        current.geometry = geometry
        current.lastPoint = nil
        current.sender.send(kind: DisplayKinds.geometry) { sequence in
            DisplayPayloads.geometry(streamID: current.streamID, sequence: sequence, geometry: geometry)
        }
        current.encoder.resize(width: size.width, height: size.height)
        current.source.update(display: display, width: size.width, height: size.height)
        current.sender.encoderRestarted()
        BridgeyLog.screen.notice("display geometry generation=\(geometry.generation, privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
    }

    // MARK: Ending

    /// Stop in the pill, the stop shortcut or Settings.
    func stopLocally() {
        guard let current = stream else { return }
        endStream(current, reason: .localStop, tell: true)
    }

    /// The phone's session closed: everything for it ends here, nothing is sent, and nothing resumes on reconnect.
    func disconnected(_ deviceID: String) {
        lastRequestAt.removeValue(forKey: deviceID)
        if pending.removeValue(forKey: deviceID) != nil {
            asking = nil
            environment.consent.dismiss()
        }
        if let current = stream, current.deviceID == deviceID { endStream(current, reason: nil, tell: false) }
    }

    /// The phone stopped advertising the key: nothing more may be sent to it.
    func peerChanged(_ deviceID: String) {
        guard !peerAdvertises(deviceID), let current = stream, current.deviceID == deviceID else { return }
        endStream(current, reason: .disabled, tell: false)
    }

    func screenLockChanged(_ isLocked: Bool) {
        locked = isLocked
        guard isLocked else { return }
        for (deviceID, entry) in pending {
            _ = send(deviceID, DisplayKinds.status, DisplayPayloads.status(requestID: entry.requestID, status: .locked))
        }
        if !pending.isEmpty {
            pending.removeAll()
            asking = nil
            environment.consent.dismiss()
        }
        if let current = stream { endStream(current, reason: .locked, tell: true) }
    }

    /// `reason` nil: ended without a word (a disconnect, or a new request from the same phone).
    func endStream(_ current: Stream, reason: DisplayStopReason?, tell: Bool) {
        guard stream === current else { return }
        stream = nil
        if host.isActive {
            let transition = host.stop(reason == nil ? .disconnected : .user)
            applyRelease(transition.release, in: current)
        }
        current.control = nil
        current.encoder.onAccessUnit = nil
        current.sender.stop(reason ?? .failed, tell: tell && reason != nil)
        current.source.stop()
        current.encoder.invalidate()
        active = nil
        environment.indicator.hide()
        record(current, reason: reason?.rawValue ?? "disconnected")
        BridgeyLog.screen.notice("display stream ended reason=\(reason?.rawValue ?? "disconnected", privacy: .public) told=\(tell, privacy: .public)")
    }

    private func senderEnded(_ current: Stream?, reason: DisplayStopReason, told: Bool) {
        guard let current, stream === current else { return }
        endStream(current, reason: reason, tell: false)
    }

    private func record(_ current: Stream, reason: String) {
        audit?.record(RemoteControlAuditEntry(
            id: current.streamID, deviceID: current.deviceID, deviceName: current.deviceName, mode: Self.auditMode, accepted: true,
            startedAt: current.startedAt, endedAt: environment.clock(), endReason: reason, counts: current.counts, dropped: 0,
            rejected: current.rejected))
    }

    // MARK: Timer

    /// Once a second while something is open: request expiry, stream timeouts and stats, control liveness and
    /// permissions.
    func tick() {
        let now = environment.clock()
        for (deviceID, entry) in pending where now.timeIntervalSince(entry.at) >= DisplayLimits.requestLifetime {
            consentAnswered(deviceID: deviceID, requestID: entry.requestID, allowed: false)
        }
        if let current = stream {
            if !environment.captureAllowed() {
                endStream(current, reason: .permission, tell: true)
            } else {
                current.sender.tick()
                if stream === current, host.isActive {
                    let transition = host.tick(environment.monotonicMs())
                    if case let .stopped(reason) = transition.status {
                        controlStopped(current, transition: transition, reason: controlReason(for: reason, in: current))
                    } else {
                        synchronizeControl(current)
                    }
                }
            }
        }
        if pending.isEmpty && stream == nil {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func ensureTicker() {
        guard ticker == nil, environment.schedulesTimer else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The screen locks or another user takes over: everything ends (RemoteInputHost does the same for the touchpad).
    func observeScreenLock() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let watch: [(NotificationCenter, String, Bool)] = [
            (distributed, "com.apple.screenIsLocked", true),
            (distributed, "com.apple.screenIsUnlocked", false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue, false),
        ]
        for (center, name, isLocked) in watch {
            lockObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLockChanged(isLocked || ConsoleSession.lockedNow()) }
            })
        }
        screenLockChanged(ConsoleSession.lockedNow())
    }

    // MARK: Test instance status

    /// The `screen` part of a test instance's status.json.
    func testStatus(injector: RecordingScreenInjector?) -> [String: Any] {
        var status: [String: Any] = ["asking": asking ?? NSNull(), "unattended": grants.unattended]
        guard let current = stream else {
            status["state"] = asking == nil ? "idle" : "asking"
            status["injected"] = injector?.count ?? 0
            return status
        }
        let stats = current.sender.lastStats
        status["state"] = current.sender.phase == .streaming ? "streaming" : "starting"
        status["viewer"] = current.deviceName
        status["viewerID"] = shortDeviceID(current.deviceID)
        status["stream"] = String(current.streamID.prefix(8))
        status["control"] = host.isActive ? "active" : (current.controlled ? "ended" : "off")
        status["controlSession"] = current.control.map { Int($0.session) } ?? NSNull()
        status["geometry"] = ["generation": Int(current.geometry.generation), "width": Int(current.geometry.width), "height": Int(current.geometry.height)]
        status["fps"] = stats?.fps ?? 0
        status["latencyMs"] = stats?.latencyMs ?? 0
        status["rttMs"] = stats?.rttMs ?? 0
        status["bitrate"] = stats?.bitrate ?? current.sender.currentBitrate
        status["sentBitrate"] = stats?.sentBitrate ?? 0
        status["framesSent"] = current.sender.sentCount
        status["dropped"] = current.sender.droppedCount
        status["injected"] = injector?.count ?? 0
        status["rejected"] = current.rejected
        if let point = injector?.lastPoint {
            status["lastPoint"] = ["x": Double(point.x), "y": Double(point.y)]
        }
        return status
    }
}

/// Display stop reasons as the session log shows them.
func displayAuditReasonText(_ reason: String) -> String {
    switch DisplayStopReason(rawValue: reason) {
    case .user, .leftScreen: L10n.text("display.log.phone", fallback: "Stopped on the phone")
    case .screenOff: L10n.text("remote.reason.screenOff", fallback: "Phone screen turned off")
    case .localStop: L10n.text("remote.reason.localStop", fallback: "Stopped on this Mac")
    case .disabled: L10n.text("display.log.disabled", fallback: "Ended: permission turned off")
    case .permission: L10n.text("display.log.permission", fallback: "Ended: Screen Recording was turned off")
    case .locked: L10n.text("display.log.locked", fallback: "Ended: this Mac locked")
    case .sourceChanged: L10n.text("display.log.sourceChanged", fallback: "Ended: the shared display changed")
    case .timeout: L10n.text("display.log.timeout", fallback: "Ended: no answer from the phone")
    case .invalid, .failed: L10n.text("display.log.failed", fallback: "Ended: something went wrong")
    case nil: L10n.text("remote.reason.disconnected", fallback: "Connection lost")
    }
}

// MARK: Live setup

extension MacScreenShare {
    struct LiveSetup {
        let share: MacScreenShare
        /// Test instances only: what control would have injected.
        let testInjector: RecordingScreenInjector?
        let testDisplays: SyntheticDisplays?
    }

    /// The app's host. A debug test instance with `BridgeyTestScreenSource` = `synthetic` in Info.plist gets the
    /// synthetic display and test pattern, a recorder instead of CGEvents, and Screen Recording and Accessibility
    /// treated as allowed for itself, so it never asks macOS for either and never moves the pointer.
    static func live() -> LiveSetup {
        let encoder: (Int, Int) -> MacScreenEncoding = { MacScreenEncoder(width: $0, height: $1) }
        if TestInstance.enabled, Bundle.main.object(forInfoDictionaryKey: "BridgeyTestScreenSource") as? String == "synthetic" {
            let displays = SyntheticDisplays()
            let injector = RecordingScreenInjector()
            let environment = MacScreenEnvironment(
                displays: displays, makeSource: { SyntheticScreenSource() }, makeEncoder: encoder, injector: injector,
                indicator: DisplayShareIndicator(), consent: DisplayConsentPanel(), grants: MacScreenGrants(), captureAllowed: { true },
                requestCapture: {}, accessibility: { true }, focusedWindow: { nil })
            let share = MacScreenShare(environment: environment)
            share.observeScreenLock()
            return LiveSetup(share: share, testInjector: injector, testDisplays: displays)
        }
        let environment = MacScreenEnvironment(
            displays: SystemDisplays(), makeSource: { ScreenCaptureKitSource() }, makeEncoder: encoder, injector: CGEventInjector(),
            indicator: DisplayShareIndicator(), consent: DisplayConsentPanel(), grants: MacScreenGrants(),
            // A test instance never asks macOS for anything, even on the real capture path.
            captureAllowed: ScreenRecordingAccess.isAllowed, requestCapture: TestInstance.enabled ? {} : ScreenRecordingAccess.request,
            accessibility: AccessibilityAccess.isTrusted, focusedWindow: FocusedWindow.frame)
        let share = MacScreenShare(environment: environment)
        share.observeScreenLock()
        return LiveSetup(share: share, testInjector: nil, testDisplays: nil)
    }
}

// MARK: The real pill and prompt

/// The remote control pill, with its own stop shortcut registration, on the shared display.
@MainActor
final class DisplayShareIndicator: DisplayIndicating {
    private let pill = RemoteControlIndicator(hotKeyIdentifier: 91)

    func show(deviceName: String, controlling: Bool, displayID: UInt32, onStop: @escaping () -> Void) {
        let title = controlling
            ? String(format: L10n.text("display.pill.controlling", fallback: "%@ is viewing and controlling this screen"), deviceName)
            : String(format: L10n.text("display.pill.viewing", fallback: "%@ is viewing this screen"), deviceName)
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
        pill.show(title: title, symbol: controlling ? "cursorarrow.rays" : "rectangle.on.rectangle", screen: screen, onStop: onStop)
    }

    func hide() { pill.hide() }
}
