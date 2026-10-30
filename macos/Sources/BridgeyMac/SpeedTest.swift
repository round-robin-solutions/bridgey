import CoreWLAN
import Foundation
import Network
import SwiftUI

// Speed test (draft files_fast_draft1; docs/transfer-speed.md, docs/protocol.md "Speed test"). Settings > Developer
// and experimental > Transfer speed: about 15 seconds over the real session with a chosen phone: round trips first, then
// 7 seconds of test bytes each way, paced and acknowledged exactly like file chunks. Both apps show megabytes a
// second each way, the round trip, each side's Wi-Fi link where it can be read, whether the phone held its Wi-Fi
// power-save lock, and a verdict in plain words. Android has the same code in SpeedTest.kt.

enum SpeedKind {
    static let start = "speed.start"
    static let ready = "speed.ready"
    static let turn = "speed.turn"
    static let done = "speed.done"
    static let result = "speed.result"
    static let cancel = "speed.cancel"
    static let ping = "speed.ping"
    static let pong = "speed.pong"
    static let ack = "speed.ack"
}

enum SpeedLimits {
    static let maximumPlaintext = 1024
    static let secondsPerDirection = 7
    static let pings = 10
    static let answerTimeout: TimeInterval = 5
    static let stallTimeout: TimeInterval = 5
    /// Throughput counts from here on, so TCP and the window have warmed up.
    static let warmUp: TimeInterval = 1
}

/// One device's own view of its network for this test. No names, addresses or network names.
struct SpeedLink: Codable, Equatable {
    var platform: String
    /// "wifi", "ethernet", "hotspot" (the phone is the Mac's access point) or "other".
    var network: String
    /// "2.4", "5" or "6" (GHz).
    var band: String?
    /// The Wi-Fi transmit rate in Mbit/s.
    var linkMbps: Int?
    /// 4 to 7 for Wi-Fi 4 to Wi-Fi 7.
    var standard: Int?
    var widthMhz: Int?
    /// Phone only: the Wi-Fi power-save lock was held for the test, and the screen was on (Android applies the
    /// low-latency lock only while the screen is on).
    var lockHeld: Bool?
    var screenOn: Bool?

    static func decode(_ object: Any?) -> SpeedLink? {
        guard let object = object as? [String: Any], let platform = object["platform"] as? String, (1...16).contains(platform.utf8.count),
              let network = object["network"] as? String, ["wifi", "ethernet", "hotspot", "other"].contains(network) else { return nil }
        func int(_ key: String, _ range: ClosedRange<Int>) -> Int? {
            guard let value = jsonInteger(object[key]), range.contains(Int(value)) else { return nil }
            return Int(value)
        }
        let band = (object["band"] as? String).flatMap { ["2.4", "5", "6"].contains($0) ? $0 : nil }
        return SpeedLink(platform: platform, network: network, band: band, linkMbps: int("linkMbps", 1...100_000), standard: int("standard", 4...7),
                         widthMhz: int("widthMhz", 20...320), lockHeld: jsonBool(object["lockHeld"]), screenOn: jsonBool(object["screenOn"]))
    }

    var json: [String: Any] {
        var object: [String: Any] = ["platform": platform, "network": network]
        object["band"] = band
        object["linkMbps"] = linkMbps
        object["standard"] = standard
        object["widthMhz"] = widthMhz
        object["lockHeld"] = lockHeld
        object["screenOn"] = screenOn
        return object
    }
}

/// The JSON speed.* payloads, decoded strictly: version 1, a UUID test ID, numbers in range. Anything else is nil
/// (a payload with another version is ignored, like every draft).
enum SpeedPayload: Equatable {
    case start(testId: String, seconds: Int, link: SpeedLink)
    case ready(testId: String, status: String, link: SpeedLink?)
    case turn(testId: String, bytesPerSecond: Int64)
    case done(testId: String, bytesPerSecond: Int64)
    case result(testId: String, forward: Int64?, back: Int64?, roundTripMs: Double?, loadedRoundTripMs: Double?)

    static func decode(kind: String, plaintext: Data) -> SpeedPayload? {
        guard plaintext.count <= SpeedLimits.maximumPlaintext, isStrictJSONObject(plaintext),
              let object = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              jsonInteger(object["version"]) == 1, let testId = (object["testId"] as? String)?.lowercased(),
              UUID(uuidString: testId) != nil else { return nil }
        func rate(_ key: String) -> Int64? {
            guard let value = jsonInteger(object[key]), value >= 0, value <= 1_000_000_000_000 else { return nil }
            return Int64(value)
        }
        func millis(_ key: String) -> Double? {
            guard let value = object[key] as? NSNumber, !(value === kCFBooleanTrue || value === kCFBooleanFalse),
                  value.doubleValue.isFinite, (0...60_000).contains(value.doubleValue) else { return nil }
            return value.doubleValue
        }
        switch kind {
        case SpeedKind.start:
            guard let seconds = jsonInteger(object["seconds"]), (2...15).contains(seconds), let link = SpeedLink.decode(object["link"]) else { return nil }
            return .start(testId: testId, seconds: Int(seconds), link: link)
        case SpeedKind.ready:
            guard let status = object["status"] as? String, ["ready", "busy", "disabled"].contains(status) else { return nil }
            return .ready(testId: testId, status: status, link: SpeedLink.decode(object["link"]))
        case SpeedKind.turn:
            guard let value = rate("bytesPerSecond") else { return nil }
            return .turn(testId: testId, bytesPerSecond: value)
        case SpeedKind.done:
            guard let value = rate("bytesPerSecond") else { return nil }
            return .done(testId: testId, bytesPerSecond: value)
        case SpeedKind.result:
            return .result(testId: testId, forward: rate("forwardBytesPerSecond"), back: rate("backBytesPerSecond"),
                           roundTripMs: millis("roundTripMs"), loadedRoundTripMs: millis("loadedRoundTripMs"))
        default:
            return nil
        }
    }

    var json: Data? {
        var object: [String: Any] = ["version": 1]
        switch self {
        case let .start(testId, seconds, link):
            object["testId"] = testId; object["seconds"] = seconds; object["link"] = link.json
        case let .ready(testId, status, link):
            object["testId"] = testId; object["status"] = status; object["link"] = link?.json
        case let .turn(testId, rate), let .done(testId, rate):
            object["testId"] = testId; object["bytesPerSecond"] = rate
        case let .result(testId, forward, back, roundTrip, loaded):
            object["testId"] = testId
            object["forwardBytesPerSecond"] = forward
            object["backBytesPerSecond"] = back
            object["roundTripMs"] = roundTrip.map { ($0 * 10).rounded() / 10 }
            object["loadedRoundTripMs"] = loaded.map { ($0 * 10).rounded() / 10 }
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

// MARK: - Verdict

/// What the numbers mean, in plain words. Both apps use the same rules (SpeedTest.kt).
struct SpeedVerdict: Equatable {
    enum Route: String { case sameRouter, macWired, hotspot, unknown }
    /// Where the estimate comes from: the link rates, typical Wi-Fi 6 values, or none (the route is not Wi-Fi or Ethernet).
    enum Basis: String { case linkRates, typical, none }
    enum Advice: String { case phone24, mac24, screenOff, weakLink, tryHotspot }

    let route: Route
    let basis: Basis
    /// The estimate for this route, in MB/s (0...0 without one).
    let expected: ClosedRange<Double>
    /// The better direction reached at least 70% of the low end (always true without an estimate).
    let asExpected: Bool
    let advice: [Advice]

    /// Goodput over one Wi-Fi hop is about half to three quarters of the transmit rate: phones on Wi-Fi 6 (2x2, 80 MHz,
    /// a 1,201 Mbit/s link) measured 900 Mbit/s down and 540 to 600 up (Aggarwal et al., INFOCOM 2021; see
    /// docs/transfer-speed.md). Estimates, not measurements of this app.
    static let efficiency: ClosedRange<Double> = 0.5...0.75

    static func evaluate(mac: SpeedLink, phone: SpeedLink?, best bytesPerSecond: Double) -> SpeedVerdict {
        let route: Route
        if phone?.network == "hotspot" { route = .hotspot }
        else if mac.network == "ethernet", phone?.network == "wifi" { route = .macWired }
        else if mac.network == "wifi", phone?.network == "wifi" { route = .sameRouter }
        else { route = .unknown }
        // Not Wi-Fi or Ethernet on both sides (a cable, a VPN, an emulator): nothing to compare with.
        if route == .unknown { return SpeedVerdict(route: route, basis: .none, expected: 0...0, asExpected: true, advice: []) }
        func mbps(_ value: Double) -> ClosedRange<Double> {
            (value * efficiency.lowerBound / 8).rounded()...(value * efficiency.upperBound / 8).rounded()
        }
        let rate: Double?
        switch route {
        case .sameRouter:
            // Through one access point every byte crosses the air twice: the two hops share the airtime.
            if let a = mac.linkMbps, let b = phone?.linkMbps, a > 0, b > 0 { rate = 1 / (1 / Double(a) + 1 / Double(b)) } else { rate = nil }
        case .macWired:
            rate = phone?.linkMbps.map(Double.init)
        default:
            rate = mac.linkMbps.map(Double.init)
        }
        // Typical values when a link rate is not readable: Wi-Fi 6, 2x2, 80 MHz (the same source).
        let expected = rate.map(mbps) ?? (route == .sameRouter ? 30...45 : route == .macWired ? 50...75 : 50...90)
        let megabytes = bytesPerSecond / 1_000_000
        let asExpected = megabytes >= expected.lowerBound * 0.7
        var advice: [Advice] = []
        if !asExpected {
            if phone?.band == "2.4" { advice.append(.phone24) }
            if mac.network == "wifi", mac.band == "2.4" { advice.append(.mac24) }
            if phone?.screenOn == false { advice.append(.screenOff) }
            if advice.isEmpty { advice.append(.weakLink) }
        }
        if route == .sameRouter { advice.append(.tryHotspot) }
        return SpeedVerdict(route: route, basis: rate == nil ? .typical : .linkRates, expected: expected, asExpected: asExpected, advice: advice)
    }
}

/// A finished test, as both apps show it.
struct SpeedReport: Equatable {
    var macToPhone: Double?
    var phoneToMac: Double?
    var roundTripMs: Double?
    var loadedRoundTripMs: Double?
    var mac: SpeedLink
    var phone: SpeedLink?
    var verdict: SpeedVerdict

    /// The text for Copy results: numbers and link facts only, never names, addresses or identifiers.
    func plainText(version: String) -> String {
        func rate(_ value: Double?) -> String { value.map { String(format: "%.1f MB/s", $0 / 1_000_000) } ?? "n/a" }
        func link(_ value: SpeedLink?) -> String {
            guard let value else { return "unknown" }
            var parts = [value.network]
            if let band = value.band { parts.append("\(band) GHz") }
            if let standard = value.standard { parts.append("Wi-Fi \(standard)") }
            if let width = value.widthMhz { parts.append("\(width) MHz") }
            if let mbps = value.linkMbps { parts.append("\(mbps) Mbit/s") }
            if let lock = value.lockHeld { parts.append(lock ? "power-save lock held" : "power-save lock not held") }
            if let screen = value.screenOn { parts.append(screen ? "screen on" : "screen off") }
            return parts.joined(separator: ", ")
        }
        return [
            "Bridgey speed test (Mac \(version))",
            "Mac to phone: \(rate(macToPhone))",
            "Phone to Mac: \(rate(phoneToMac))",
            "Round trip: \(roundTripMs.map { String(format: "%.0f ms", $0) } ?? "n/a") idle, \(loadedRoundTripMs.map { String(format: "%.0f ms", $0) } ?? "n/a") during the test",
            "Mac link: \(link(mac))",
            "Phone link: \(link(phone))",
            "Route: \(verdict.route.rawValue); " + {
                let range = "\(Int(verdict.expected.lowerBound)) to \(Int(verdict.expected.upperBound)) MB/s"
                switch verdict.basis {
                case .none: return "no estimate"
                case .linkRates: return "estimate \(range) from the link rates; " + (verdict.asExpected ? "reached" : "below the estimate")
                case .typical: return "estimate \(range), typical for Wi-Fi 6; " + (verdict.asExpected ? "reached" : "below the estimate")
                }
            }(),
        ].joined(separator: "\n")
    }
}

// MARK: - Link facts on this Mac

enum MacSpeedLink {
    /// This Mac's side of the session's route: Wi-Fi (with what CoreWLAN reads without location access), Ethernet,
    /// or other (loopback, VPN).
    static func current(path: NWPath?) -> SpeedLink {
        var link = SpeedLink(platform: "macos", network: "other")
        if path?.usesInterfaceType(.wiredEthernet) == true {
            link.network = "ethernet"
        } else if path?.usesInterfaceType(.wifi) == true {
            link.network = "wifi"
            if let interface = CWWiFiClient.shared().interface() {
                let rate = interface.transmitRate()
                if rate > 0 { link.linkMbps = Int(rate.rounded()) }
                if let channel = interface.wlanChannel() {
                    // Raw values, so the 6 GHz band reads on every SDK: 1, 2, 3 are 2.4, 5, 6 GHz; widths 20 to 160 MHz.
                    link.band = [1: "2.4", 2: "5", 3: "6"][channel.channelBand.rawValue]
                    link.widthMhz = [1: 20, 2: 40, 3: 80, 4: 160][channel.channelWidth.rawValue]
                }
                switch interface.activePHYMode().rawValue {
                case 4: link.standard = 4
                case 5: link.standard = 5
                case 6: link.standard = 6
                case 7: link.standard = 7
                default: break
                }
            }
        }
        return link
    }
}

// MARK: - The test

/// How the speed test reaches one phone. Thread-safe; `sendData` is called from a worker thread.
protocol SpeedTestLink: AnyObject {
    func sendEncrypted(kind: String, payload: Data) -> Bool
    func sendOuter(kind: String, testId: String, sequence: Int64?)
    func sendData(testId: String, sequence: Int64, plaintext: Data) -> Bool
    var path: NWPath? { get }
}

@MainActor
protocol SpeedTestHost: AnyObject {
    /// Nil when the phone is not connected or does not advertise files_fast_draft1.
    func speedLink(for phoneID: String) -> SpeedTestLink?
    var speedPhones: [(id: String, name: String)] { get }
}

/// Sends test bytes for `seconds` in a paced window and measures what the other side acknowledged.
final class SpeedSender: @unchecked Sendable {
    let pacer = TransferPacer(fast: true)
    private let lock = NSLock()
    private var acked: Int64 = -1
    private var startAt: TimeInterval = 0
    private var warmBytes: (at: TimeInterval, bytes: Int64)?
    private var lastAck: (at: TimeInterval, bytes: Int64)?
    private var lastAckWall = ProcessInfo.processInfo.systemUptime
    private var cancelled = false

    func acknowledged(_ testId: String, sequence: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard sequence > acked else { return }
            acked = sequence
            let bytes = (sequence + 1) * Int64(pacer.chunkSize)
            lastAck = (now, bytes)
            lastAckWall = now
            if warmBytes == nil, now - startAt >= SpeedLimits.warmUp { warmBytes = (now, bytes) }
        }
        pacer.acknowledged(testId, through: sequence)
    }

    func cancel() {
        lock.withLock { cancelled = true }
        pacer.cancel()
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Bytes a second acknowledged after the warm-up, so far.
    var rate: Double {
        lock.withLock {
            guard let warm = warmBytes, let last = lastAck, last.at > warm.at else { return 0 }
            return Double(last.bytes - warm.bytes) / (last.at - warm.at)
        }
    }

    func run(testId: String, seconds: Int, link: SpeedTestLink, progress: @escaping (Double, Double) -> Void,
             completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = Data(count: self.pacer.chunkSize)
            self.lock.withLock {
                self.startAt = ProcessInfo.processInfo.systemUptime
                self.lastAckWall = self.startAt
            }
            var sequence: Int64 = 0
            var lastReport = self.startAt
            var ok = true
            while !self.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - self.startAt
                if elapsed >= Double(seconds) { break }
                if now - self.lock.withLock({ self.lastAckWall }) > SpeedLimits.stallTimeout { ok = false; break }
                do {
                    try self.pacer.waitForRoom(chunk.count, timeout: SpeedLimits.stallTimeout) { self.isCancelled }
                } catch {
                    ok = false
                    break
                }
                self.pacer.didSend(testId, sequence: sequence, bytes: chunk.count)
                guard link.sendData(testId: testId, sequence: sequence, plaintext: chunk) else { ok = false; break }
                sequence += 1
                if now - lastReport >= 0.25 {
                    lastReport = now
                    progress(min(1, elapsed / Double(seconds)), self.rate)
                }
            }
            if ok, !self.isCancelled { ok = (try? self.pacer.waitForAll(timeout: SpeedLimits.stallTimeout) { self.isCancelled }) != nil }
            completion(ok && !self.isCancelled)
        }
    }
}

@MainActor
final class SpeedTest: ObservableObject {
    static let shared = SpeedTest()

    enum Phase: Equatable {
        case idle
        case connecting
        case roundTrips
        /// Test bytes this Mac sends, then the phone's.
        case sending, receiving
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var phoneID: String?
    @Published private(set) var phoneName = ""
    /// 0 to 1 over the whole test.
    @Published private(set) var progress: Double = 0
    @Published private(set) var liveBytesPerSecond: Double = 0
    @Published private(set) var report: SpeedReport?

    weak var host: SpeedTestHost?

    private final class Run {
        let testId: String
        let phoneID: String
        let initiator: Bool
        let seconds: Int
        let link: SpeedTestLink
        var local: SpeedLink
        var remote: SpeedLink?
        var pingsSent: [Int64: TimeInterval] = [:]
        var roundTrips: [Double] = []
        var sender: SpeedSender?
        var forward: Double?
        var back: Double?
        var loadedRoundTrip: Double?
        var receivedSequence: Int64 = -1
        var lastData = ProcessInfo.processInfo.systemUptime
        var timer: DispatchWorkItem?

        init(testId: String, phoneID: String, initiator: Bool, seconds: Int, link: SpeedTestLink, local: SpeedLink) {
            self.testId = testId
            self.phoneID = phoneID
            self.initiator = initiator
            self.seconds = seconds
            self.link = link
            self.local = local
        }
    }

    private var run: Run?

    var isRunning: Bool { run != nil }

    /// Starts a test with `phoneID` from this Mac.
    func start(with phoneID: String) {
        guard run == nil, let link = host?.speedLink(for: phoneID) else {
            phase = .failed("unavailable")
            return
        }
        let testId = UUID().uuidString.lowercased()
        let current = Run(testId: testId, phoneID: phoneID, initiator: true, seconds: SpeedLimits.secondsPerDirection, link: link,
                          local: MacSpeedLink.current(path: link.path))
        run = current
        self.phoneID = phoneID
        phoneName = host?.speedPhones.first { $0.id == phoneID }?.name ?? ""
        report = nil
        progress = 0
        liveBytesPerSecond = 0
        phase = .connecting
        guard let payload = SpeedPayload.start(testId: testId, seconds: current.seconds, link: current.local).json,
              link.sendEncrypted(kind: SpeedKind.start, payload: payload) else { return fail("unavailable") }
        arm(SpeedLimits.answerTimeout) { [weak self] in self?.fail("noAnswer") }
        BridgeyLog.files.notice("SPEED start test=\(testId.prefix(8), privacy: .public)")
    }

    func cancel() {
        guard let current = run else { return }
        current.link.sendOuter(kind: SpeedKind.cancel, testId: current.testId, sequence: nil)
        end(.failed("cancelled"))
    }

    /// The session with this phone ended.
    func phoneDisconnected(_ phoneID: String) {
        guard run?.phoneID == phoneID else { return }
        end(.failed("disconnected"))
    }

    // MARK: Messages

    func receive(kind: String, plaintext: Data?, testId outerID: String?, sequence: Int64?, from phoneID: String) {
        switch kind {
        case SpeedKind.ping:
            guard let id = outerID, let sequence else { return }
            host?.speedLink(for: phoneID)?.sendOuter(kind: SpeedKind.pong, testId: id, sequence: sequence)
            return
        case SpeedKind.pong:
            guard let current = run, current.phoneID == phoneID, outerID == current.testId, let sequence,
                  let sent = current.pingsSent.removeValue(forKey: sequence) else { return }
            current.roundTrips.append((ProcessInfo.processInfo.systemUptime - sent) * 1000)
            if current.pingsSent.isEmpty, current.roundTrips.count >= SpeedLimits.pings { startSending(current) }
            return
        case SpeedKind.ack:
            guard let current = run, current.phoneID == phoneID, outerID == current.testId, let sequence else { return }
            current.sender?.acknowledged(current.testId, sequence: sequence)
            return
        case SpeedKind.cancel:
            guard let current = run, current.phoneID == phoneID, outerID == current.testId else { return }
            end(.failed("cancelledByPhone"))
            return
        default:
            break
        }
        guard let plaintext, let payload = SpeedPayload.decode(kind: kind, plaintext: plaintext) else { return }
        switch payload {
        case let .start(testId, seconds, link):
            guard run == nil, let reply = host?.speedLink(for: phoneID) else {
                let status = run == nil ? "disabled" : "busy"
                if let data = SpeedPayload.ready(testId: testId, status: status, link: nil).json {
                    _ = host?.speedLink(for: phoneID)?.sendEncrypted(kind: SpeedKind.ready, payload: data)
                }
                return
            }
            let current = Run(testId: testId, phoneID: phoneID, initiator: false, seconds: seconds, link: reply,
                              local: MacSpeedLink.current(path: reply.path))
            current.remote = link
            run = current
            self.phoneID = phoneID
            phoneName = host?.speedPhones.first { $0.id == phoneID }?.name ?? ""
            report = nil
            progress = 0
            phase = .receiving
            guard let data = SpeedPayload.ready(testId: testId, status: "ready", link: current.local).json,
                  reply.sendEncrypted(kind: SpeedKind.ready, payload: data) else { return fail("unavailable") }
            watchData(current)
        case let .ready(testId, status, link):
            guard let current = run, current.initiator, current.testId == testId, phase == .connecting else { return }
            guard status == "ready" else { return fail(status) }
            current.remote = link
            phase = .roundTrips
            for sequence in 1...Int64(SpeedLimits.pings) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(sequence - 1) * 0.03) { [weak self] in
                    guard let self, self.run === current else { return }
                    current.pingsSent[sequence] = ProcessInfo.processInfo.systemUptime
                    current.link.sendOuter(kind: SpeedKind.ping, testId: testId, sequence: sequence)
                }
            }
            arm(SpeedLimits.answerTimeout) { [weak self] in
                // Some pongs went missing: go on with what came back.
                guard let self, let current = self.run, self.phase == .roundTrips else { return }
                current.pingsSent.removeAll()
                self.startSending(current)
            }
        case let .turn(testId, rate):
            guard let current = run, !current.initiator, current.testId == testId else { return }
            current.forward = Double(rate)
            startSending(current)
        case let .done(testId, rate):
            guard let current = run, current.initiator, current.testId == testId else { return }
            current.back = Double(rate)
            finishInitiator(current)
        case let .result(testId, forward, back, roundTrip, loaded):
            guard let current = run, !current.initiator, current.testId == testId else { return }
            // The phone started it: forward is phone to Mac.
            let report = SpeedReport(phoneToMac: forward.map(Double.init), macToPhone: back.map(Double.init), roundTripMs: roundTrip,
                                     loadedRoundTripMs: loaded, mac: current.local, phone: current.remote)
            self.report = report
            end(.finished)
        }
    }

    /// Test bytes from the phone: acknowledged at once, then thrown away.
    func receiveData(_ payload: FastFramePayload, from phoneID: String) {
        guard let current = run, current.phoneID == phoneID, payload.id == current.testId,
              payload.sequence > current.receivedSequence else { return }
        current.receivedSequence = payload.sequence
        current.lastData = ProcessInfo.processInfo.systemUptime
        current.link.sendOuter(kind: SpeedKind.ack, testId: current.testId, sequence: payload.sequence)
    }

    // MARK: Phases

    private func startSending(_ current: Run) {
        guard run === current, current.sender == nil else { return }
        current.timer?.cancel()
        phase = .sending
        let sender = SpeedSender()
        current.sender = sender
        let base: Double = current.initiator ? 0.05 : 0.5
        sender.run(testId: current.testId, seconds: current.seconds, link: current.link, progress: { [weak self] fraction, rate in
            DispatchQueue.main.async {
                guard let self, self.run === current else { return }
                self.progress = base + fraction * 0.45
                self.liveBytesPerSecond = rate
            }
        }, completion: { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.run === current else { return }
                guard ok else { return self.fail("stalled") }
                self.sent(current, rate: sender.rate, loaded: sender.pacer.smoothedRoundTrip.map { $0 * 1000 })
            }
        })
    }

    private func sent(_ current: Run, rate: Double, loaded: Double?) {
        current.loadedRoundTrip = loaded
        if current.initiator {
            current.forward = rate
            current.sender = nil
            guard let data = SpeedPayload.turn(testId: current.testId, bytesPerSecond: Int64(rate)).json,
                  current.link.sendEncrypted(kind: SpeedKind.turn, payload: data) else { return fail("unavailable") }
            phase = .receiving
            current.lastData = ProcessInfo.processInfo.systemUptime
            watchData(current)
            progress = 0.5
        } else {
            current.back = rate
            guard let data = SpeedPayload.done(testId: current.testId, bytesPerSecond: Int64(rate)).json,
                  current.link.sendEncrypted(kind: SpeedKind.done, payload: data) else { return fail("unavailable") }
            phase = .receiving
            progress = 0.95
            // The phone sends the full result next.
            arm(SpeedLimits.answerTimeout) { [weak self] in
                guard let self, let current = self.run else { return }
                self.report = SpeedReport(phoneToMac: current.forward, macToPhone: current.back, roundTripMs: nil,
                                          loadedRoundTripMs: current.loadedRoundTrip, mac: current.local, phone: current.remote)
                self.end(.finished)
            }
        }
    }

    private func finishInitiator(_ current: Run) {
        let sorted = current.roundTrips.sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        let report = SpeedReport(macToPhone: current.forward, phoneToMac: current.back, roundTripMs: median,
                                 loadedRoundTripMs: current.loadedRoundTrip, mac: current.local, phone: current.remote)
        if let data = SpeedPayload.result(testId: current.testId, forward: current.forward.map(Int64.init), back: current.back.map(Int64.init),
                                          roundTripMs: median, loadedRoundTripMs: current.loadedRoundTrip).json {
            _ = current.link.sendEncrypted(kind: SpeedKind.result, payload: data)
        }
        self.report = report
        BridgeyLog.files.notice("SPEED done macToPhone=\(Int((current.forward ?? 0) / 1000), privacy: .public)kB/s phoneToMac=\(Int((current.back ?? 0) / 1000), privacy: .public)kB/s rtt=\(Int(median ?? -1), privacy: .public)ms")
        end(.finished)
    }

    /// While the phone sends: fail when its bytes stop for 5 seconds. Checks twice a second until the run ends.
    private func watchData(_ current: Run) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.run === current else { return }
            if self.phase == .receiving, current.sender == nil,
               ProcessInfo.processInfo.systemUptime - current.lastData > SpeedLimits.stallTimeout + Double(current.seconds) {
                return self.fail("stalled")
            }
            if self.phase == .receiving, current.sender == nil, current.initiator {
                self.progress = min(0.98, self.progress + 0.5 / (2 * Double(current.seconds)))
            }
            self.watchData(current)
        }
    }

    private func arm(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
        run?.timer?.cancel()
        let item = DispatchWorkItem(block: action)
        run?.timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func fail(_ reason: String) {
        if let current = run, reason != "cancelledByPhone" {
            current.link.sendOuter(kind: SpeedKind.cancel, testId: current.testId, sequence: nil)
        }
        BridgeyLog.files.notice("SPEED failed reason=\(reason, privacy: .public)")
        end(.failed(reason))
    }

    private func end(_ final: Phase) {
        if let current = run {
            current.timer?.cancel()
            current.sender?.cancel()
        }
        run = nil
        phase = final
        if final == .finished { progress = 1 }
    }
}

extension SpeedReport {
    init(macToPhone: Double?, phoneToMac: Double?, roundTripMs: Double?, loadedRoundTripMs: Double?, mac: SpeedLink, phone: SpeedLink?) {
        self.init(macToPhone: macToPhone, phoneToMac: phoneToMac, roundTripMs: roundTripMs, loadedRoundTripMs: loadedRoundTripMs,
                  mac: mac, phone: phone,
                  verdict: SpeedVerdict.evaluate(mac: mac, phone: phone, best: max(macToPhone ?? 0, phoneToMac ?? 0)))
    }

    init(phoneToMac: Double?, macToPhone: Double?, roundTripMs: Double?, loadedRoundTripMs: Double?, mac: SpeedLink, phone: SpeedLink?) {
        self.init(macToPhone: macToPhone, phoneToMac: phoneToMac, roundTripMs: roundTripMs, loadedRoundTripMs: loadedRoundTripMs, mac: mac, phone: phone)
    }
}
