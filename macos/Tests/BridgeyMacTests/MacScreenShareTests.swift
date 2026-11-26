import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import BridgeyMac

// Mac screen to phone (MacScreenShare.swift): grants, requests and consent, the stream, control through the
// shared contract, geometry and the input fence, and every stop path. Fakes only: no capture, no encoder, no
// CGEvent, no prompt.

private final class FakeLink: MacScreenLink, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var json: [(kind: String, payload: [String: Any])] = []
    private(set) var frames: [Data] = []
    var open = true

    func sendJSON(kind: String, payload: [String: Any]) -> Bool {
        lock.withLock {
            guard open else { return false }
            json.append((kind, payload))
            return true
        }
    }

    func sendFrame(_ plaintext: Data, written: @escaping (Bool) -> Void) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard open else { return false }
            frames.append(plaintext)
            return true
        }
        if accepted { written(true) }
        return accepted
    }

    func kinds() -> [String] { lock.withLock { json.map(\.kind) } }
    func last(_ kind: String) -> [String: Any]? { lock.withLock { json.last { $0.kind == kind }?.payload } }
    func all(_ kind: String) -> [[String: Any]] { lock.withLock { json.filter { $0.kind == kind }.map(\.payload) } }
}

private final class FakeSource: MacScreenSource {
    var started: (display: MacDisplayInfo, width: Int, height: Int)?
    var updates: [(Int, Int)] = []
    var stopped = false
    var marks: [(Double, Double)] = []
    var failed: ((String) -> Void)?
    var frames: ((CVPixelBuffer, Int64) -> Void)?

    func start(display: MacDisplayInfo, width: Int, height: Int, fps: Int, frames: @escaping (CVPixelBuffer, Int64) -> Void,
               failed: @escaping (String) -> Void) {
        started = (display, width, height)
        self.frames = frames
        self.failed = failed
    }

    func update(display: MacDisplayInfo, width: Int, height: Int) { updates.append((width, height)) }
    func stop() { stopped = true }
    func markInput(x: Double, y: Double) { marks.append((x, y)) }
}

private final class FakeEncoder: MacScreenEncoding {
    var onAccessUnit: ((MacScreenAccessUnit) -> Void)?
    var keyRequests = 0
    var bitrates: [Int] = []
    var resized: [(Int, Int)] = []
    var invalidated = false
    var encoded = 0

    func encode(_ image: CVPixelBuffer, captureMicros: Int64) { encoded += 1 }
    func requestKeyFrame() { keyRequests += 1 }
    func setBitrate(_ bitsPerSecond: Int) { bitrates.append(bitsPerSecond) }
    func resize(width: Int, height: Int) { resized.append((width, height)) }
    func invalidate() { invalidated = true }

    func emit(bytes: Int, key: Bool) {
        var data = Data([0, 0, 0, 1, key ? 0x65 : 0x41])
        data.append(Data(repeating: 0xAB, count: max(0, bytes - 5)))
        onAccessUnit?(MacScreenAccessUnit(data: data, key: key, parameterSets: key, captureMillis: 0, captureMicros: 0))
    }
}

@MainActor
private final class FakeIndicator: DisplayIndicating {
    var shown: (name: String, controlling: Bool, display: UInt32)?
    var onStop: (() -> Void)?
    var hides = 0

    func show(deviceName: String, controlling: Bool, displayID: UInt32, onStop: @escaping () -> Void) {
        shown = (deviceName, controlling, displayID)
        self.onStop = onStop
    }

    func hide() {
        shown = nil
        hides += 1
    }
}

@MainActor
private final class FakeConsent: DisplayConsentPresenting {
    var asked: String?
    var canAllow: (() -> Bool)?
    var answer: ((Bool) -> Void)?
    var dismissed = 0

    func ask(deviceName: String, canAllow: @escaping () -> Bool, answer: @escaping (Bool) -> Void) {
        asked = deviceName
        self.canAllow = canAllow
        self.answer = answer
    }

    func dismiss() {
        asked = nil
        dismissed += 1
    }
}

/// Two displays: a Retina main display and an external one to its left (a negative origin).
@MainActor
private final class TwoDisplays: MacDisplayProviding {
    var onChange: (() -> Void)?
    var list = [
        MacDisplayInfo(id: 5, name: "Built-in Retina Display", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: 3024, pixelHeight: 1964),
        MacDisplayInfo(id: 9, name: "Studio Display", bounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080),
    ]
    var mainDisplayID: UInt32 { 5 }
    func displays() -> [MacDisplayInfo] { list }
}

@MainActor
final class MacScreenShareTests: XCTestCase {
    private typealias SC = ScreenControl

    private var directory: URL!
    private var share: MacScreenShare!
    private var link: FakeLink!
    private var sources: [FakeSource] = []
    private var encoders: [FakeEncoder] = []
    private var injector: RecordingScreenInjector!
    private var indicator: FakeIndicator!
    private var consent: FakeConsent!
    private var displays: MacDisplayProviding!
    private var syntheticDisplays: SyntheticDisplays?
    private var statuses: [(device: String, payload: [String: Any])] = []
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var monotonic: UInt64 = 10_000
    private var capture = true
    private var accessibility = true
    private var controlGranted = false
    private var touchpad: String?
    private var focused: CGRect?
    private var grantsChanged = 0
    private var captureRequests = 0
    private var restricted: Set<String> = []
    private var peerAdvertising = true
    private let phone = "phone-1"
    private let identity = Data(repeating: 3, count: 65).base64EncodedString()
    private let connection = [UInt8](repeating: 7, count: 16)
    private let request = "3f2e1d0c-4b5a-4968-8776-a5b4c3d2e1f0"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screen-share-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// `unattended`: Unattended access as stored before the share starts. Off for the tests of explicit choices, so a
    /// phone without one reads Off as before 26 Nov; the switch has its own tests below.
    private func make(displays custom: MacDisplayProviding? = nil, unattended: Bool = false) {
        let grants = MacScreenGrants(directory: directory)
        if !unattended { XCTAssertTrue(grants.setUnattended(false)) }
        let synthetic = custom == nil ? SyntheticDisplays() : nil
        syntheticDisplays = synthetic
        displays = custom ?? synthetic
        link = FakeLink()
        injector = RecordingScreenInjector()
        indicator = FakeIndicator()
        consent = FakeConsent()
        let environment = MacScreenEnvironment(
            displays: displays, makeSource: { [unowned self] in
                let source = FakeSource()
                self.sources.append(source)
                return source
            }, makeEncoder: { [unowned self] _, _ in
                let encoder = FakeEncoder()
                self.encoders.append(encoder)
                return encoder
            }, injector: injector, indicator: indicator, consent: consent, grants: grants,
            captureAllowed: { [unowned self] in self.capture }, requestCapture: { [unowned self] in self.captureRequests += 1 },
            accessibility: { [unowned self] in self.accessibility },
            focusedWindow: { [unowned self] in self.focused }, clock: { [unowned self] in self.now }, monotonicMs: { [unowned self] in self.monotonic },
            defaults: nil, schedulesTimer: false)
        share = MacScreenShare(environment: environment)
        share.send = { [unowned self] device, kind, payload in
            XCTAssertEqual(kind, DisplayKinds.status)
            self.statuses.append((device, payload))
            return true
        }
        share.link = { [unowned self] _ in self.link.open ? self.link : nil }
        share.peer = { [unowned self] id in
            id == self.phone ? MacScreenPeer(name: "Pixel 9", identityKey: self.identity, transport: 4, connection: self.connection) : nil
        }
        share.identityKey = { [unowned self] id in id == self.phone ? self.identity : "b3RoZXI=" }
        share.isRestricted = { [unowned self] id in self.restricted.contains(id) }
        share.peerAdvertises = { [unowned self] _ in self.peerAdvertising }
        share.controlGrant = { [unowned self] _ in self.controlGranted }
        share.touchpadController = { [unowned self] in self.touchpad }
        share.onGrantsChange = { [unowned self] in self.grantsChanged += 1 }
    }

    private func requestData(id: String? = nil, viewer: [String: Any]? = nil) -> Data {
        let caps: [String: Any] = viewer ?? ["v": 1, "screenViewer": true, "h264Decode": true,
                                             "inputController": ["pointer": true, "keys": true, "text": true]]
        return try! JSONSerialization.data(withJSONObject: ["version": 1, "requestId": id ?? request, "capabilities": caps])
    }

    private func lastStatus() -> String? { statuses.last?.payload["status"] as? String }

    private func viewer(_ kind: String, _ fields: [String: Any]) {
        guard let stream = share.stream else { return XCTFail("no stream") }
        viewerSequence += 1
        var payload: [String: Any] = ["version": 1, "streamId": stream.streamID, "sequence": viewerSequence]
        payload.merge(fields) { $1 }
        share.receiveStream(kind: kind, data: try! JSONSerialization.data(withJSONObject: payload), from: phone)
    }

    private var viewerSequence = 0
    private var inputSequence: UInt64 = 0

    /// A stream running with the viewer's started, `grant` already chosen.
    private func streaming(grant: MacScreenGrantMode = .always) {
        share.setGrant(grant, for: phone)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        if grant == .ask { consent.answer?(true) }
        XCTAssertNotNil(share.stream, "stream started")
        viewer(DisplayKinds.started, [:])
    }

    private func controlling() throws -> UInt64 {
        controlGranted = true
        streaming()
        viewer(DisplayKinds.control, ["action": "begin"])
        let active = try XCTUnwrap(link.last(DisplayKinds.control))
        XCTAssertEqual(active["state"] as? String, "active")
        let session = UInt64(try XCTUnwrap(active["session"] as? Int))
        inputSequence = 0
        send(.geometryAck, session: session)
        return session
    }

    private func send(_ input: SC.Input, session: UInt64, geometry: UInt64? = nil, connection override: [UInt8]? = nil) {
        guard let stream = share.stream else { return }
        inputSequence += 1
        let packet = SC.Packet(v: 1, session: session, transport: 4, connection: override ?? connection, stream: stream.number,
                               geometry: geometry ?? stream.geometry.generation, seq: inputSequence, input: input)
        share.receiveInput(packet.encoded(), from: phone, via: MacScreenPeer(name: "Pixel 9", identityKey: identity, transport: 4,
                                                                             connection: override ?? connection))
    }

    // MARK: Grants

    func testGrantsAreBoundToTheKeyAndPrivate() throws {
        let grants = MacScreenGrants(directory: directory)
        XCTAssertTrue(grants.unattended, "Unattended access is on by default")
        XCTAssertEqual(grants.mode(for: phone, identityKey: identity), .always)
        XCTAssertTrue(grants.setUnattended(false))
        XCTAssertEqual(grants.mode(for: phone, identityKey: identity), .off)
        XCTAssertTrue(grants.set(.ask, for: phone, identityKey: identity))
        XCTAssertEqual(grants.mode(for: phone, identityKey: identity), .ask)
        XCTAssertEqual(grants.mode(for: phone, identityKey: "b3RoZXI="), .off, "a new pinned key has no choice of its own")
        XCTAssertNil(grants.explicitMode(for: phone, identityKey: "b3RoZXI="))
        XCTAssertEqual(grants.mode(for: phone, identityKey: nil), .off)
        grants.set(.always, for: phone, identityKey: identity)
        let reloaded = MacScreenGrants(directory: directory)
        XCTAssertEqual(reloaded.mode(for: phone, identityKey: identity), .always)
        let attributes = try FileManager.default.attributesOfItem(atPath: reloaded.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        reloaded.prune(keeping: [])
        XCTAssertEqual(MacScreenGrants(directory: directory).mode(for: phone, identityKey: identity), .off)
        reloaded.set(.ask, for: phone, identityKey: identity)
        reloaded.remove(phone)
        XCTAssertEqual(MacScreenGrants(directory: directory).mode(for: phone, identityKey: identity), .off)
        XCTAssertFalse(try String(contentsOf: reloaded.fileURL, encoding: .utf8).contains(identity), "the identity key itself is never stored")
        // Never part of settings sync.
        XCTAssertFalse(SyncKey.allCases.map(\.rawValue).contains { $0.contains("screenShare") || $0.contains("screen_control") || $0.contains("grant") })
    }

    func testAdvertisedOnlyToAPhoneWithAGrant() {
        make()
        XCTAssertFalse(share.advertised(to: phone))
        share.setGrant(.ask, for: phone)
        XCTAssertTrue(share.advertised(to: phone))
        XCTAssertFalse(share.advertised(to: "phone-2"))
        XCTAssertEqual(grantsChanged, 1)
        share.forget(phone)
        XCTAssertFalse(share.advertised(to: phone))
    }

    // MARK: Unattended access (26 Nov)

    /// Every combination of the switch, the device's own choice, a server or agent and the pinned key.
    func testGrantResolutionTable() {
        typealias G = MacScreenGrants
        for unattended in [true, false] {
            for explicit in [nil, MacScreenGrantMode.off, .ask, .always] {
                XCTAssertEqual(G.resolve(explicit: explicit, unattended: unattended, restricted: true, keyKnown: true), .off,
                               "a server or agent never gets anything (\(unattended), \(String(describing: explicit)))")
                XCTAssertEqual(G.resolve(explicit: explicit, unattended: unattended, restricted: false, keyKnown: false), .off,
                               "no pinned key, no access")
                let expected: MacScreenGrantMode = explicit ?? (unattended ? .always : .off)
                XCTAssertEqual(G.resolve(explicit: explicit, unattended: unattended, restricted: false, keyKnown: true), expected,
                               "an explicit choice wins; Default follows the switch")
            }
        }
    }

    func testExplicitChoicesSurviveTheSwitchAndAReload() {
        let grants = MacScreenGrants(directory: directory)
        let other = Data(repeating: 9, count: 65).base64EncodedString()
        grants.set(.off, for: phone, identityKey: identity)
        grants.set(.ask, for: "phone-2", identityKey: other)
        XCTAssertEqual(grants.mode(for: phone, identityKey: identity), .off, "an explicit Off is kept, not removed")
        XCTAssertEqual(grants.mode(for: "phone-3", identityKey: other), .always, "Default follows the switch")
        grants.setUnattended(false)
        grants.setUnattended(true)
        let reloaded = MacScreenGrants(directory: directory)
        XCTAssertTrue(reloaded.unattended)
        XCTAssertEqual(reloaded.explicitMode(for: phone, identityKey: identity), .off)
        XCTAssertEqual(reloaded.explicitMode(for: "phone-2", identityKey: other), .ask)
        XCTAssertNil(reloaded.explicitMode(for: "phone-3", identityKey: other))
        reloaded.setUnattended(false)
        XCTAssertEqual(MacScreenGrants(directory: directory).mode(for: "phone-3", identityKey: other), .off)
        XCTAssertEqual(MacScreenGrants(directory: directory).mode(for: "phone-2", identityKey: other), .ask)
        reloaded.set(nil, for: "phone-2", identityKey: other)
        XCTAssertNil(MacScreenGrants(directory: directory).explicitMode(for: "phone-2", identityKey: other), "Default removes the choice")
        // A device that pairs again with another key follows the switch, like a newly paired device.
        reloaded.setUnattended(true)
        XCTAssertEqual(reloaded.mode(for: phone, identityKey: other), .always)
    }

    func testAMissingFileIsTheDefaultsAndAnUnreadableOneGrantsNothing() throws {
        XCTAssertTrue(MacScreenGrants(directory: directory).unattended, "no file yet: on")
        let grants = MacScreenGrants(directory: directory)
        grants.set(.always, for: phone, identityKey: identity)
        try FileManager.default.removeItem(at: grants.fileURL)
        try Data("{not json".utf8).write(to: grants.fileURL)
        let damaged = MacScreenGrants(directory: directory)
        XCTAssertFalse(damaged.unattended, "an unreadable file fails closed")
        XCTAssertEqual(damaged.mode(for: phone, identityKey: identity), .off)
        try FileManager.default.removeItem(at: grants.fileURL)
        try Data(#"{"grants":{},"unattended":true,"version":2}"#.utf8).write(to: grants.fileURL)
        XCTAssertFalse(MacScreenGrants(directory: directory).unattended, "another version fails closed too")
        // The next save writes a good file again.
        XCTAssertTrue(damaged.setUnattended(true))
        XCTAssertTrue(MacScreenGrants(directory: directory).unattended)
    }

    func testTheSwitchLetsADeviceWithoutAChoiceInAndOff() {
        make(unattended: true)
        XCTAssertTrue(share.unattended)
        XCTAssertNil(share.explicitGrant(for: phone))
        XCTAssertEqual(share.grantMode(for: phone), .always)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertNil(consent.asked, "no prompt")
        XCTAssertNotNil(share.stream)
        XCTAssertEqual(indicator.shown?.name, "Pixel 9", "the pill and Stop still show")
        viewer(DisplayKinds.started, [:])
        XCTAssertTrue(share.setUnattended(false))
        XCTAssertNil(share.stream, "a device on Default loses access with the switch")
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "disabled")
        XCTAssertFalse(share.advertised(to: phone))
        XCTAssertGreaterThanOrEqual(grantsChanged, 1)
    }

    func testAnExplicitChoiceWinsOverTheSwitch() {
        make(unattended: true)
        XCTAssertTrue(share.setGrant(.ask, for: phone))
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(consent.asked, "Pixel 9", "Ask each time still asks with the switch on")
        consent.answer?(false)
        XCTAssertTrue(share.setGrant(.off, for: phone))
        XCTAssertFalse(share.advertised(to: phone))
        XCTAssertTrue(share.setUnattended(false))
        XCTAssertTrue(share.setGrant(.always, for: phone))
        XCTAssertEqual(share.grantMode(for: phone), .always, "Allow without asking stays with the switch off")
    }

    func testServersAndAgentsNeverGetAccess() {
        make(unattended: true)
        XCTAssertTrue(share.setGrant(.always, for: phone))
        restricted = [phone]
        XCTAssertEqual(share.grantMode(for: phone), .off, "not even with a stored Allow without asking")
        XCTAssertFalse(share.advertised(to: phone))
        share.receiveRequest(requestData(), from: phone, deviceName: "contabo-europe")
        XCTAssertEqual(lastStatus(), "disabled")
        XCTAssertNil(share.stream)
        XCTAssertFalse(share.setGrant(.ask, for: phone))
        XCTAssertFalse(share.setGrant(.always, for: phone))
        XCTAssertTrue(share.setGrant(.off, for: phone), "Off can always be chosen")
        XCTAssertTrue(share.setGrant(nil, for: phone))
        XCTAssertEqual(share.grantMode(for: phone), .off)
    }

    /// Security review 1.0, with the switch: while anything controls this Mac nothing may give a device more.
    func testNothingRaisesAccessWhileThisMacIsControlled() throws {
        make(unattended: false)
        XCTAssertTrue(share.setGrant(.off, for: phone))
        touchpad = phone
        XCTAssertFalse(share.setUnattended(true), "turning the switch on is refused")
        XCTAssertFalse(share.unattended)
        XCTAssertFalse(share.setGrant(.ask, for: phone))
        touchpad = nil
        XCTAssertTrue(share.setUnattended(true))
        touchpad = phone
        XCTAssertFalse(share.setGrant(nil, for: phone), "back to Default would raise Off to Allow without asking")
        XCTAssertEqual(share.explicitGrant(for: phone), .off)
        XCTAssertTrue(share.setUnattended(false), "turning the switch off always works")
        XCTAssertTrue(share.setGrant(nil, for: phone), "Default with the switch off gives nothing more")
        XCTAssertEqual(share.grantMode(for: phone), .off)
        touchpad = nil
        XCTAssertTrue(share.setUnattended(true))
        XCTAssertEqual(share.grantMode(for: phone), .always)
        // Screen control counts too.
        _ = try controlling()
        XCTAssertFalse(share.allowPossible)
        XCTAssertTrue(share.setUnattended(false), "turning the switch off works while controlled")
        XCTAssertFalse(share.setUnattended(true))
        XCTAssertFalse(share.setGrant(.ask, for: "phone-2"), "raising another device is refused too")
        XCTAssertNil(share.explicitGrant(for: "phone-2"))
        XCTAssertTrue(share.setGrant(.ask, for: phone), "lowering works while controlled")
    }

    /// A device marked as a server mid-stream (its own map, or a first pairing over the tailnet): the stream ends, and so
    /// does a prompt waiting for an answer.
    func testADeviceThatBecomesRestrictedLosesItsStreamAndPrompt() {
        make(unattended: true)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        viewer(DisplayKinds.started, [:])
        restricted = [phone]
        share.policyChanged()
        XCTAssertNil(share.stream)
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "disabled")
        restricted = []
        XCTAssertTrue(share.setGrant(.ask, for: phone))
        now += 4
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(consent.asked, "Pixel 9")
        restricted = [phone]
        share.policyChanged()
        XCTAssertNil(consent.asked, "the prompt goes")
        XCTAssertNil(share.asking)
        XCTAssertEqual(lastStatus(), "disabled")
    }

    /// BridgeySettings tells the coordinator when a device is marked or unmarked as a server (wired to policyChanged).
    @MainActor
    func testMarkingAnAgentIsAnnounced() {
        let suite = "bridgey-agents-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BridgeySettings(defaults: defaults)
        var changed: [String] = []
        settings.onAgentsChange = { changed.append($0) }
        settings.markAgent(phone)
        settings.markAgent(phone)
        settings.unmarkAgent(phone)
        settings.unmarkAgent(phone)
        XCTAssertEqual(changed, [phone, phone], "once per real change")
    }

    /// Lowering a device to Ask each time ends a stream that started without asking; one the person allowed here stays.
    func testLoweringToAskEndsAStreamThatWasNotAsked() {
        make(unattended: true)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        viewer(DisplayKinds.started, [:])
        XCTAssertTrue(share.setGrant(.ask, for: phone))
        XCTAssertNil(share.stream, "it was never asked for")
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "disabled")
        now += 4
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        consent.answer?(true)
        XCTAssertNotNil(share.stream)
        XCTAssertTrue(share.setGrant(.always, for: phone))
        XCTAssertTrue(share.setGrant(.ask, for: phone))
        XCTAssertNotNil(share.stream, "the person allowed this one on the prompt")
    }

    func testDefaultShowsWhatItGivesNow() {
        XCTAssertEqual(MacScreenSettings.choiceTitle(nil, now: .always), "Default (Allow without asking)")
        XCTAssertEqual(MacScreenSettings.choiceTitle(nil, now: .off), "Default (Off)")
        XCTAssertEqual(MacScreenSettings.choiceTitle(.ask, now: .ask), "Ask each time")
        XCTAssertEqual(MacScreenSettings.defaultTitle, "Default")
    }

    func testTurningTheSwitchOnAsksForScreenRecordingOnlyWhenMissing() {
        make(unattended: false)
        capture = true
        XCTAssertTrue(share.setUnattended(true))
        XCTAssertEqual(captureRequests, 0)
        XCTAssertTrue(share.setUnattended(false))
        capture = false
        XCTAssertTrue(share.setUnattended(true))
        XCTAssertEqual(captureRequests, 1)
        XCTAssertTrue(share.setUnattended(true), "no change, no prompt")
        XCTAssertEqual(captureRequests, 1)
    }

    // MARK: Requests

    func testRequestRules() {
        make()
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(lastStatus(), "disabled")
        share.setGrant(.ask, for: phone)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(statuses.count, 1, "at most one request every 3 seconds")
        now += 4
        capture = false
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(lastStatus(), "permission")
        capture = true
        now += 4
        share.screenLockChanged(true)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(lastStatus(), "locked")
        share.screenLockChanged(false)
        now += 4
        share.receiveRequest(requestData(viewer: ["v": 1, "screenViewer": true]), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(lastStatus(), "failed", "a viewer that cannot decode H.264")
        now += 4
        share.receiveRequest(Data("{\"version\":1}".utf8), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(statuses.count, 4, "a malformed request is dropped without an answer")
    }

    func testAskEachTimeShowsThePromptAndAllowStarts() throws {
        make()
        share.setGrant(.ask, for: phone)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(lastStatus(), "waiting")
        XCTAssertEqual(consent.asked, "Pixel 9")
        XCTAssertEqual(share.asking, "Pixel 9")
        XCTAssertNil(share.stream)
        share.receiveRequest(requestData(id: "6c1b2a39-4857-4f6e-8d7c-0b1a29384756"), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(statuses.count, 1, "one open request per phone")
        consent.answer?(true)
        let start = try XCTUnwrap(link.last(DisplayKinds.start))
        XCTAssertEqual(start["requestId"] as? String, request)
        XCTAssertEqual(start["sequence"] as? Int, 1)
        XCTAssertEqual(start["control"] as? Bool, false, "no control permission")
        let geometry = try XCTUnwrap(start["geometry"] as? [String: Any])
        XCTAssertEqual(geometry["width"] as? Int, 1920)
        XCTAssertEqual(geometry["height"] as? Int, 1246)
        XCTAssertEqual(geometry["generation"] as? Int, 1)
        XCTAssertEqual(start["displayName"] as? String, "Test pattern")
        XCTAssertEqual(indicator.shown?.name, "Pixel 9")
        XCTAssertEqual(indicator.shown?.controlling, false)
        XCTAssertEqual(share.active?.deviceName, "Pixel 9")
        XCTAssertEqual(sources.first?.started?.width, 1920)
        XCTAssertNil(share.asking)
    }

    func testDenyAndExpiryAnswerDeclined() {
        make()
        share.setGrant(.ask, for: phone)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        consent.answer?(false)
        XCTAssertEqual(lastStatus(), "declined")
        XCTAssertNil(share.stream)
        now += 4
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        now += DisplayLimits.requestLifetime
        share.tick()
        XCTAssertEqual(lastStatus(), "declined")
        XCTAssertNil(consent.asked)
    }

    func testAllowDoesNothingWhileAnythingControlsThisMac() {
        make()
        share.setGrant(.ask, for: phone)
        touchpad = "another-phone"
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(consent.canAllow?(), false)
        share.answerPendingPrompt(true)
        XCTAssertNil(share.stream)
        touchpad = nil
        XCTAssertEqual(consent.canAllow?(), true)
        share.answerPendingPrompt(true)
        XCTAssertNotNil(share.stream)
    }

    /// Security review 1.0: a phone controlling this Mac could open Settings and raise its own screen grant.
    func testAGrantCannotBeRaisedWhileAnythingControlsThisMac() throws {
        make()
        share.setGrant(.ask, for: phone)
        touchpad = phone
        XCTAssertFalse(share.setGrant(.always, for: phone))
        XCTAssertEqual(share.grantMode(for: phone), .ask)
        XCTAssertTrue(share.setGrant(.off, for: phone), "lowering always works")
        XCTAssertEqual(share.grantMode(for: phone), .off)
        XCTAssertFalse(share.setGrant(.ask, for: phone))
        touchpad = nil
        XCTAssertTrue(share.setGrant(.always, for: phone))
        XCTAssertEqual(share.grantMode(for: phone), .always)
        // Screen control counts too: Settings (and the grant guard) see this Mac as controlled.
        _ = try controlling()
        XCTAssertFalse(share.allowPossible)
    }

    /// Security review 1.0: the touchpad could press Allow on this prompt itself, with a button released as its session
    /// ended. A click Bridgey injected never counts; a person's does.
    func testAnInjectedClickNeverPressesAllow() throws {
        let point = CGPoint(x: 10, y: 10)
        let injected = try XCTUnwrap(CGEvent(mouseEventSource: InjectedEvents.source(), mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
        let person = try XCTUnwrap(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .leftMouseUp,
                                           mouseCursorPosition: point, mouseButton: .left))
        XCTAssertEqual(injected.getIntegerValueField(.eventSourceUserData), InjectedEvents.marker)
        XCTAssertFalse(DisplayConsentRules.allowTakes(canAllow: true, event: NSEvent(cgEvent: injected)))
        XCTAssertTrue(DisplayConsentRules.allowTakes(canAllow: true, event: NSEvent(cgEvent: person)))
        XCTAssertTrue(DisplayConsentRules.allowTakes(canAllow: true, event: nil))
        XCTAssertFalse(DisplayConsentRules.allowTakes(canAllow: false, event: NSEvent(cgEvent: person)))
    }

    func testAllowWithoutAskingStartsAtOnceAndAnotherPhoneIsBusy() {
        make()
        share.setGrant(.always, for: phone)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertNil(consent.asked)
        XCTAssertNotNil(share.stream)
        XCTAssertTrue(statuses.isEmpty)
        share.setGrant(.always, for: "phone-2")
        share.receiveRequest(requestData(), from: "phone-2", deviceName: "Tablet")
        XCTAssertEqual(lastStatus(), "busy", "one stream at a time")
    }

    func testANewRequestEndsTheOldStreamAndAReconnectNeverResumes() {
        make()
        share.setGrant(.ask, for: phone)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        consent.answer?(true)
        let first = share.stream
        XCTAssertNotNil(first)
        share.disconnected(phone)
        XCTAssertNil(share.stream)
        XCTAssertTrue(sources[0].stopped)
        XCTAssertTrue(encoders[0].invalidated)
        XCTAssertFalse(link.kinds().contains(DisplayKinds.stop), "a disconnect sends nothing")
        // After the reconnect: nothing runs until the phone asks again, and Ask each time asks again.
        share.receiveRequest(requestData(id: "6c1b2a39-4857-4f6e-8d7c-0b1a29384756"), from: phone, deviceName: "Pixel 9")
        XCTAssertEqual(lastStatus(), "waiting")
        XCTAssertNil(share.stream)
        consent.answer?(true)
        XCTAssertFalse(share.stream === first)
        now += 4
        share.receiveRequest(requestData(id: "11111111-2222-4333-8444-555555555555"), from: phone, deviceName: "Pixel 9")
        XCTAssertNil(share.stream, "the watching phone asked again: the old stream ended")
        XCTAssertEqual(lastStatus(), "waiting")
    }

    // MARK: The stream

    func testStartedAsksForAKeyFrameAndFramesArePaced() throws {
        make()
        streaming()
        let encoder = try XCTUnwrap(encoders.first)
        XCTAssertGreaterThanOrEqual(encoder.keyRequests, 1)
        encoder.emit(bytes: 40_000, key: true)
        XCTAssertEqual(link.frames.count, 2, "40,000 bytes go in two parts")
        let part = try XCTUnwrap(ScreenFramePart.decode(link.frames[0]))
        XCTAssertEqual(part.streamID, share.stream?.streamID)
        XCTAssertEqual(part.sequence, 2, "start was 1")
        XCTAssertTrue(part.key && part.parameterSets && !part.last)
        XCTAssertTrue(try XCTUnwrap(ScreenFramePart.decode(link.frames[1])).last)
        for _ in 0..<5 { encoder.emit(bytes: 1_000, key: false) }
        encoder.emit(bytes: 1_000, key: false)
        XCTAssertEqual(link.frames.count, 7, "six frames in flight at most")
        viewer(DisplayKinds.ack, ["frame": 6, "decodeMs": 2])
        encoder.emit(bytes: 1_000, key: false)
        XCTAssertEqual(link.frames.count, 7, "after a drop only a key frame goes")
        encoder.emit(bytes: 1_000, key: true)
        XCTAssertEqual(link.frames.count, 8)
    }

    func testStatsGoOutEverySecondOnceStarted() throws {
        make()
        share.setGrant(.always, for: phone)
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        let stream = try XCTUnwrap(share.stream)
        share.tick()
        XCTAssertEqual(stream.sender.phase, .starting)
        XCTAssertTrue(link.all(DisplayKinds.stats).isEmpty, "nothing before display.started")
        viewer(DisplayKinds.started, [:])
        share.tick()
        XCTAssertEqual(link.all(DisplayKinds.stats).count, 1)
    }

    func testViewerStopEndsTheStreamWithoutAnAnswer() {
        make()
        streaming()
        viewer(DisplayKinds.stop, ["reason": "left_screen"])
        XCTAssertNil(share.stream)
        XCTAssertEqual(indicator.hides, 1)
        XCTAssertFalse(link.kinds().contains(DisplayKinds.stop))
    }

    func testOutOfSequenceViewerMessagesAreDropped() {
        make()
        streaming()
        guard let stream = share.stream else { return XCTFail() }
        let stale = try! JSONSerialization.data(withJSONObject: ["version": 1, "streamId": stream.streamID, "sequence": 1, "reason": "user"])
        share.receiveStream(kind: DisplayKinds.stop, data: stale, from: phone)
        XCTAssertNotNil(share.stream, "sequence 1 was display.started")
        share.receiveStream(kind: DisplayKinds.stop, data: stale, from: "phone-2")
        XCTAssertNotNil(share.stream)
    }

    // MARK: Control

    func testControlIsRefusedWithoutItsOwnPermission() throws {
        make()
        streaming()
        viewer(DisplayKinds.control, ["action": "begin"])
        XCTAssertEqual(link.last(DisplayKinds.control)?["state"] as? String, "refused")
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "disabled")
        controlGranted = true
        accessibility = false
        viewer(DisplayKinds.control, ["action": "begin"])
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "permission")
        accessibility = true
        touchpad = "phone-2"
        viewer(DisplayKinds.control, ["action": "begin"])
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "busy")
        touchpad = nil
        viewer(DisplayKinds.control, ["action": "begin"])
        let active = try XCTUnwrap(link.last(DisplayKinds.control))
        XCTAssertEqual(active["state"] as? String, "active")
        XCTAssertEqual(active["input"] as? NSDictionary, ["pointer": true, "touch": false, "keys": true, "text": true, "navigation": false])
        XCTAssertEqual(indicator.shown?.controlling, true)
        XCTAssertEqual(share.controllerDevice, phone)
    }

    func testInputMapsOntoTheRetinaDisplayAfterTheGeometryAck() throws {
        make()
        let session = try controlling()
        send(.pointer(x: 0.5, y: 0.5), session: session)
        XCTAssertEqual(injector.events.last, .move(CGPoint(x: 756.39375, y: 491.3940609951846), held: []))
        send(.button(.primary, down: true, x: 0, y: 0), session: session)
        send(.button(.primary, down: false, x: 1, y: 1), session: session)
        XCTAssertEqual(injector.events.suffix(2), [.button(.left, down: true, CGPoint(x: 0.39375, y: 0.3940609951845907)),
                                                   .button(.left, down: false, CGPoint(x: 1511.60625, y: 981.6059390048154))])
        send(.pointer(x: 1.2, y: 0.5), session: session)
        XCTAssertEqual(injector.count, 3, "outside the display: nothing")
        send(.text("Hello, Привет"), session: session)
        XCTAssertEqual(injector.events.last, .text("Hello, Привет"))
        XCTAssertEqual(sources[0].marks.count, 3, "the test pattern marks every positioned input")
    }

    func testInputBeforeTheGeometryAckIsRefused() throws {
        make()
        controlGranted = true
        streaming()
        viewer(DisplayKinds.control, ["action": "begin"])
        let session = UInt64(try XCTUnwrap(link.last(DisplayKinds.control)?["session"] as? Int))
        send(.pointer(x: 0.5, y: 0.5), session: session)
        XCTAssertEqual(injector.count, 0)
    }

    func testNegativeOriginDisplayIsMappedWithoutLeavingIt() throws {
        let two = TwoDisplays()
        make(displays: two)
        share.setSelectedDisplay(9)
        let session = try controlling()
        let start = try XCTUnwrap(link.last(DisplayKinds.start))
        XCTAssertEqual((start["geometry"] as? [String: Any])?["source"] as? Int, 9)
        send(.pointer(x: 0.25, y: 0.75), session: session)
        XCTAssertEqual(injector.events.last, .move(CGPoint(x: -1439.5, y: 609.5), held: []))
        send(.pointer(x: 1, y: 0), session: session)
        guard case let .move(point, _) = try XCTUnwrap(injector.events.last) else { return XCTFail() }
        XCTAssertTrue(two.list[1].bounds.contains(point))
    }

    func testGeometryChangeReleasesHoldsFirstAndFencesInputUntilTheNewAck() throws {
        make()
        let session = try controlling()
        send(.button(.primary, down: true, x: 0.5, y: 0.5), session: session)
        injector.clear()
        syntheticDisplays?.resize(width: 1280, height: 800)
        XCTAssertEqual(injector.events.first, .button(.left, down: false, CGPoint(x: 756.39375, y: 491.3940609951846)),
                       "the held button is released before anything else")
        let geometry = try XCTUnwrap(link.last(DisplayKinds.geometry)?["geometry"] as? [String: Any])
        XCTAssertEqual(geometry["generation"] as? Int, 2)
        XCTAssertEqual(geometry["width"] as? Int, 1920)
        XCTAssertEqual(geometry["height"] as? Int, 1200)
        XCTAssertEqual(encoders[0].resized.last?.0, 1920)
        XCTAssertEqual(sources[0].updates.last?.1, 1200)
        injector.clear()
        send(.pointer(x: 0.5, y: 0.5), session: session, geometry: 1)
        send(.pointer(x: 0.5, y: 0.5), session: session, geometry: 2)
        XCTAssertEqual(injector.count, 0, "old geometry refused, new geometry not acknowledged yet")
        send(.geometryAck, session: session, geometry: 2)
        send(.pointer(x: 0.5, y: 0.5), session: session, geometry: 2)
        XCTAssertEqual(injector.count, 1)
        XCTAssertEqual(link.last(DisplayKinds.control)?["state"] as? String, "active", "control goes on")
    }

    func testLocalStopReleasesHoldsAndNothingIsInjectedAfterwards() throws {
        make()
        let session = try controlling()
        send(.button(.primary, down: true, x: 0.5, y: 0.5), session: session)
        send(.key(.shift, down: true), session: session)
        injector.clear()
        indicator.onStop?()
        XCTAssertEqual(injector.events, [.button(.left, down: false, CGPoint(x: 756.39375, y: 491.3940609951846)),
                                         .key(.shift, down: false, shift: false)])
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "local_stop")
        XCTAssertNil(share.stream)
        XCTAssertNil(share.controllerDevice)
        send(.pointer(x: 0.5, y: 0.5), session: session)
        XCTAssertEqual(injector.count, 2)
    }

    func testViewerEndsControlAndTheStreamGoesOn() throws {
        make()
        let session = try controlling()
        viewer(DisplayKinds.control, ["action": "end"])
        XCTAssertEqual(link.last(DisplayKinds.control)?["state"] as? String, "ended")
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "user")
        XCTAssertNotNil(share.stream)
        XCTAssertEqual(indicator.shown?.controlling, false)
        send(.pointer(x: 0.5, y: 0.5), session: session)
        XCTAssertEqual(injector.count, 0)
        // A new begin gets a new session with a fresh authority.
        viewer(DisplayKinds.control, ["action": "begin"])
        let again = try XCTUnwrap(link.last(DisplayKinds.control))
        XCTAssertEqual(again["state"] as? String, "active")
        XCTAssertGreaterThan(UInt64(try XCTUnwrap(again["session"] as? Int)), session)
    }

    func testTypingWithTheFocusOnAnotherDisplayEndsControlAsFocus() throws {
        make(displays: TwoDisplays())
        let session = try controlling()
        focused = CGRect(x: -1800, y: 0, width: 800, height: 600)
        send(.text("secret"), session: session)
        XCTAssertFalse(injector.events.contains(.text("secret")))
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "focus")
        XCTAssertNil(share.controllerDevice)
        XCTAssertNotNil(share.stream, "viewing goes on")
    }

    func testAModifierKeyIsNeverPostedAndEndsControl() throws {
        make()
        let session = try controlling()
        send(.key(.meta, down: true), session: session)
        XCTAssertEqual(injector.count, 0)
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "invalid")
    }

    func testAMalformedPacketEndsControl() throws {
        make()
        _ = try controlling()
        share.receiveInput(Data("{\"v\":1}".utf8), from: phone, via: MacScreenPeer(name: "Pixel 9", identityKey: identity, transport: 4, connection: connection))
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "invalid")
    }

    func testAPacketFromAnotherSessionIsRejectedWithoutStoppingControl() throws {
        make()
        let session = try controlling()
        send(.pointer(x: 0.5, y: 0.5), session: session, connection: [UInt8](repeating: 8, count: 16))
        XCTAssertEqual(injector.count, 0)
        XCTAssertEqual(share.controllerDevice, phone)
    }

    func testRevokingControlOrTheGrantAndLockingEndThings() throws {
        make()
        _ = try controlling()
        controlGranted = false
        share.policyChanged()
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "disabled")
        XCTAssertNotNil(share.stream)
        share.setGrant(.off, for: phone)
        XCTAssertNil(share.stream)
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "disabled")
        share.setGrant(.always, for: phone)
        now += 4
        share.receiveRequest(requestData(), from: phone, deviceName: "Pixel 9")
        XCTAssertNotNil(share.stream)
        share.screenLockChanged(true)
        XCTAssertNil(share.stream)
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "locked")
    }

    func testControlTimesOutAfterSixSilentSeconds() throws {
        make()
        _ = try controlling()
        monotonic += 6_000
        share.tick()
        XCTAssertEqual(link.last(DisplayKinds.control)?["reason"] as? String, "timeout")
        XCTAssertNotNil(share.stream)
    }

    func testLosingScreenRecordingEndsTheStream() {
        make()
        streaming()
        capture = false
        share.tick()
        XCTAssertNil(share.stream)
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "permission")
    }

    func testAPhoneThatStopsAdvertisingIsSentNothingMore() {
        make()
        streaming()
        peerAdvertising = false
        share.peerChanged(phone)
        XCTAssertNil(share.stream)
        XCTAssertFalse(link.kinds().contains(DisplayKinds.stop))
    }

    func testTheSelectedDisplayGoingAwayStopsAsSourceChanged() {
        let two = TwoDisplays()
        make(displays: two)
        share.setSelectedDisplay(9)
        streaming()
        two.list.removeLast()
        two.onChange?()
        XCTAssertNil(share.stream)
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "source_changed")
    }

    func testTheTouchpadIsBusyWhileAnotherPhoneControlsThroughAStream() throws {
        make()
        _ = try controlling()
        let host = RemoteInputHost(injector: NoInjection(), indicator: NoIndicator(),
                                   audit: RemoteControlAuditLog(store: RemoteControlAuditStore(fileURL: directory.appendingPathComponent("audit.json"))),
                                   accessibility: { true }, schedulesTimer: false)
        var sent: [[String: Any]] = []
        host.isAllowed = { _ in true }
        host.send = { _, _, payload in
            sent.append(payload)
            return true
        }
        host.controlledElsewhere = { [unowned self] id in self.share.controllerDevice.map { $0 != id } ?? false }
        let start = try JSONSerialization.data(withJSONObject: ["version": 1, "inputSessionId": "0b9a54a2-6a4c-4b9e-8f45-3c2a1d0e9f11", "sequence": 1, "mode": "touchpad"])
        host.receive(kind: "input.session.start", payload: start, deviceID: "phone-2", deviceName: "Tablet")
        XCTAssertEqual(sent.last?["reason"] as? String, "busy")
        XCTAssertNil(host.active)
    }
}

@MainActor
private final class NoInjection: RemoteInputInjecting {
    func move(dx: Int, dy: Int, held: Set<PointerButton>) {}
    func button(_ button: PointerButton, down: Bool) {}
    func scroll(dx: Int, dy: Int, unit: ScrollUnit) {}
    func type(_ text: String) {}
    func press(_ strokes: [KeyStroke]) {}
}

@MainActor
private final class NoIndicator: RemoteControlIndicating {
    func show(deviceName: String, mode: RemoteInputMode, onStop: @escaping () -> Void) {}
    func hide() {}
    func showLaser(x: Int, y: Int, anchor: Bool) {}
    func hideLaser() {}
}

/// The pacing rules, as android .../screen/ScreenPacingTest.kt checks them for the phone's own stream.
final class MacScreenPacingTests: XCTestCase {
    func testFirstFrameMustBeAKeyFrame() {
        let pacer = MacScreenPacer()
        XCTAssertEqual(pacer.admit(bytes: 1000, key: false, bitrate: 4_000_000), .skip)
        XCTAssertEqual(pacer.admit(bytes: 1000, key: true, bitrate: 4_000_000), .send)
        XCTAssertEqual(pacer.admit(bytes: 1000, key: false, bitrate: 4_000_000), .send)
    }

    func testAtMostSixFramesInFlight() {
        let pacer = MacScreenPacer()
        for i in 0..<6 {
            XCTAssertEqual(pacer.admit(bytes: 100, key: i == 0, bitrate: 4_000_000), .send)
            pacer.sending(frame: UInt32(i + 1), bytes: 100, captureMillis: 0, nowMillis: 0)
        }
        XCTAssertEqual(pacer.admit(bytes: 100, key: false, bitrate: 4_000_000), .drop)
        _ = pacer.acknowledge(frame: 6, decodeMs: 0, nowMillis: 10)
        XCTAssertEqual(pacer.admit(bytes: 100, key: false, bitrate: 4_000_000), .skip)
        XCTAssertEqual(pacer.admit(bytes: 100, key: true, bitrate: 4_000_000), .send)
    }

    func testBytesInFlightStayWithinTheWindow() {
        let pacer = MacScreenPacer()
        XCTAssertEqual(pacer.windowBytes(4_000_000), 125_000)
        XCTAssertEqual(pacer.windowBytes(300_000), 65_536)
        XCTAssertEqual(pacer.admit(bytes: 100_000, key: true, bitrate: 4_000_000), .send)
        pacer.sending(frame: 1, bytes: 100_000, captureMillis: 0, nowMillis: 0)
        XCTAssertEqual(pacer.admit(bytes: 30_000, key: false, bitrate: 4_000_000), .drop)
        XCTAssertEqual(MacScreenPacer().admit(bytes: 500_000, key: true, bitrate: 300_000), .send, "an empty pipe takes a big key frame")
    }

    func testAnAckGivesTheRoundTripAndLatency() {
        let pacer = MacScreenPacer()
        _ = pacer.admit(bytes: 1000, key: true, bitrate: 4_000_000)
        pacer.sending(frame: 1, bytes: 1000, captureMillis: 100, nowMillis: 110)
        pacer.written(frame: 1, nowMillis: 112)
        _ = pacer.admit(bytes: 1000, key: false, bitrate: 4_000_000)
        pacer.sending(frame: 2, bytes: 1000, captureMillis: 133, nowMillis: 140)
        pacer.written(frame: 2, nowMillis: 141)
        XCTAssertEqual(pacer.acknowledge(frame: 1, decodeMs: 4, nowMillis: 130), MacScreenPacer.AckSample(rttMillis: 14, latencyMillis: 23))
        XCTAssertEqual(pacer.framesInFlight, 1)
        XCTAssertNil(pacer.acknowledge(frame: 1, decodeMs: 0, nowMillis: 150))
        XCTAssertEqual(pacer.acknowledge(frame: 2, decodeMs: 0, nowMillis: 150), MacScreenPacer.AckSample(rttMillis: 9, latencyMillis: 13))
        XCTAssertEqual(pacer.bytesInFlight, 0)
        XCTAssertNil(pacer.oldestWrittenAtMillis())
    }

    func testBitrateComesDownOnDropsAtMostEveryHalfSecond() {
        let rate = MacScreenBitrate(startMillis: 0)
        XCTAssertEqual(rate.onDrop(nowMillis: 1000), 3_000_000)
        XCTAssertNil(rate.onDrop(nowMillis: 1200))
        XCTAssertEqual(rate.onDrop(nowMillis: 1500), 2_250_000)
        for i in 0..<20 { _ = rate.onDrop(nowMillis: 2000 + Int64(i) * 500) }
        XCTAssertEqual(rate.bitrate, MacScreenRates.minBitrate)
    }

    func testBitrateComesDownWhenTheRoundTripGrows() {
        let rate = MacScreenBitrate(startMillis: 0)
        XCTAssertNil(rate.onRtt(10, nowMillis: 100))
        XCTAssertNil(rate.onRtt(85, nowMillis: 200))
        XCTAssertEqual(rate.onRtt(95, nowMillis: 600), 3_000_000)
        XCTAssertEqual(rate.minRttMillis, 10)
    }

    func testBitrateGrowsAfterTwoCalmSeconds() {
        let rate = MacScreenBitrate(startMillis: 0)
        XCTAssertNil(rate.tick(nowMillis: 1999))
        XCTAssertEqual(rate.tick(nowMillis: 2000), 4_600_000)
        XCTAssertNil(rate.tick(nowMillis: 3000))
        for i in 0..<40 { _ = rate.tick(nowMillis: 4000 + Int64(i) * 2000) }
        XCTAssertEqual(rate.bitrate, MacScreenRates.maxBitrate)
    }

    func testStatsCoverOneSecond() {
        let window = MacScreenStatsWindow(startMillis: 0)
        for _ in 0..<30 { window.sent(10_000) }
        window.dropped()
        window.sample(MacScreenPacer.AckSample(rttMillis: 10, latencyMillis: 40))
        window.sample(MacScreenPacer.AckSample(rttMillis: 12, latencyMillis: 60))
        XCTAssertEqual(window.take(nowMillis: 1000, bitrate: 4_000_000),
                       MacScreenStats(latencyMs: 50, rttMs: 12, bitrate: 4_000_000, sentBitrate: 2_400_000, fps: 30, dropped: 1))
        XCTAssertEqual(window.take(nowMillis: 2000, bitrate: 4_000_000).fps, 0)
    }

    func testSenderTimesOutWithoutStartedAndStopsOnce() {
        let link = FakeLink()
        var now: Int64 = 0
        let sender = MacScreenStreamSender(link: link, clock: { now })
        var ended: [(DisplayStopReason, Bool)] = []
        sender.onEnded = { ended.append(($0, $1)) }
        XCTAssertTrue(sender.start { ["version": 1, "sequence": $0] })
        now = 4_999
        sender.tick()
        XCTAssertEqual(sender.phase, .starting)
        now = 5_000
        sender.tick()
        XCTAssertEqual(sender.phase, .ended)
        XCTAssertEqual(link.last(DisplayKinds.stop)?["reason"] as? String, "timeout")
        XCTAssertEqual(link.last(DisplayKinds.stop)?["sequence"] as? Int, 2)
        sender.stop(.user)
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.0, .timeout)
    }

    func testAnnexBFromAVCC() throws {
        let avcc = Data([0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 1, 0x06])
        let out = try XCTUnwrap(MacScreenEncoder.annexB(avcc: avcc, parameterSets: [Data([0x67, 0x42]), Data([0x68, 0xCE])]))
        XCTAssertEqual([UInt8](out), [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x06])
        XCTAssertNil(MacScreenEncoder.annexB(avcc: Data([0, 0, 0, 9, 0x65]), parameterSets: []), "a length past the end")
        XCTAssertNil(MacScreenEncoder.annexB(avcc: Data(), parameterSets: []))
    }

    func testTheTestPatternDrawsTheInputMarker() throws {
        let width = 192, height = 124
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        SyntheticScreenSource.draw(context, width: Double(width), height: Double(height), frame: 1, label: "Test", marker: (x: 0.75, y: 0.75))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // The crosshair's horizontal arm at 3/4 across and 3/4 down (bitmap rows run top down in memory).
        let row = Int(0.75 * Double(height)), column = Int(0.75 * Double(width)) + 3
        let offset = (row * width + column) * 4
        XCTAssertGreaterThan(pixels[offset], 200, "red")
        XCTAssertLessThan(pixels[offset + 2], 120, "not blue")
    }

    @MainActor
    func testTheSyntheticDisplayStreamsAtRetinaSizeAndResizes() {
        let displays = SyntheticDisplays()
        let display = displays.displays()[0]
        XCTAssertEqual(display.scale, 2)
        let size = DisplayGeometryRules.captureSize(nativeWidth: display.pixelWidth, nativeHeight: display.pixelHeight)
        XCTAssertEqual([size.width, size.height], [1920, 1246])
        var changed = 0
        displays.onChange = { changed += 1 }
        displays.resize(width: 1280, height: 800)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(displays.displays()[0].pixelWidth, 2560)
    }
}
