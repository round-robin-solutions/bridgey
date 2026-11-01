import AppKit
import Combine
import Darwin
import Foundation

/*
 * Let Bridgey handle copy and paste: turns Apple's Handoff off on this Mac, so Universal Clipboard and Handoff's
 * file copy stop racing Bridgey's automatic clipboard, and puts it back the way it was when turned off again.
 *
 * Handoff is two ByHost keys of com.apple.coreservices.useractivityd, the ones System Settings > General >
 * AirDrop & Handoff writes: ActivityAdvertisingAllowed and ActivityReceivingAllowed. A missing key means on.
 * Turning the takeover on remembers what each key was (missing, YES or NO) and writes both NO; turning it off
 * writes back exactly that, deleting a key that was missing. AirDrop has its own switch and is not touched.
 *
 * useractivityd reads the change at once: on macOS 27.2 it ignored the next advertisement six seconds after the
 * write, with the same process running (outputs/bridgey/clipboard-handoff-media/notes.md), so nothing restarts.
 *
 * The choice syncs to the person's other Macs (SyncKey.handoffTakeover, only to peers that advertise
 * handoff_takeover_draft1); each Mac applies it and keeps its own earlier state. It never goes to a phone.
 * The earlier state lives outside `settings.`, so Reset > Settings and Everything clear the choice but keep
 * what to restore: the next launch puts Handoff back.
 */

/// Mac only, always true on this build: this device applies `handoff.takeover`, so settings sync sends it here.
/// Read outside knownDraftFeatureKeys, so the golden vectors and Android stay as they are.
let handoffTakeoverFeatureKey = "handoff_takeover_draft1"

/// One of the two Handoff keys as `defaults` shows it.
enum HandoffKeyValue: String, Equatable, Sendable {
    /// No key: the system default, which is on.
    case unset
    case yes
    case no

    var allows: Bool { self != .no }
}

/// Handoff on this Mac.
struct HandoffState: Equatable, Sendable {
    var advertising: HandoffKeyValue
    var receiving: HandoffKeyValue

    static let systemDefault = HandoffState(advertising: .unset, receiving: .unset)
    static let off = HandoffState(advertising: .no, receiving: .no)

    /// Both directions are off, the way System Settings turns Handoff off.
    var isOff: Bool { !advertising.allows && !receiving.allows }

    /// "unset,unset": how the earlier state is stored.
    var stored: String { "\(advertising.rawValue),\(receiving.rawValue)" }

    init(advertising: HandoffKeyValue, receiving: HandoffKeyValue) {
        self.advertising = advertising
        self.receiving = receiving
    }

    init?(stored: String) {
        let parts = stored.split(separator: ",").map(String.init)
        guard parts.count == 2, let advertising = HandoffKeyValue(rawValue: parts[0]),
              let receiving = HandoffKeyValue(rawValue: parts[1]) else { return nil }
        self.init(advertising: advertising, receiving: receiving)
    }
}

/// Runs `/usr/bin/defaults`. Tests swap it, so they never touch the real system.
struct HandoffDefaultsRunner: Sendable {
    var run: @Sendable (_ arguments: [String]) -> (status: Int32, output: String)?

    static let system = HandoffDefaultsRunner { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum HandoffError: Error, Equatable, Sendable {
    /// `defaults` did not run, or printed something that is not a boolean.
    case unreadable
    /// A write or delete failed: the key that failed.
    case writeFailed(String)
}

/// The keys, read and written with `defaults -currentHost`.
struct HandoffDefaults: Sendable {
    static let domain = "com.apple.coreservices.useractivityd"
    static let advertisingKey = "ActivityAdvertisingAllowed"
    static let receivingKey = "ActivityReceivingAllowed"

    var runner: HandoffDefaultsRunner = .system

    func read() throws -> HandoffState {
        HandoffState(advertising: try read(Self.advertisingKey), receiving: try read(Self.receivingKey))
    }

    /// A missing key (or domain) makes `defaults read` fail: that is `unset`.
    private func read(_ key: String) throws -> HandoffKeyValue {
        guard let result = runner.run(["-currentHost", "read", Self.domain, key]) else { throw HandoffError.unreadable }
        guard result.status == 0 else { return .unset }
        switch result.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "yes", "true": return .yes
        case "0", "no", "false": return .no
        default: throw HandoffError.unreadable
        }
    }

    func write(_ state: HandoffState) throws {
        try write(Self.advertisingKey, state.advertising)
        try write(Self.receivingKey, state.receiving)
    }

    private func write(_ key: String, _ value: HandoffKeyValue) throws {
        let arguments: [String]
        switch value {
        case .unset: arguments = ["-currentHost", "delete", Self.domain, key]
        case .yes: arguments = ["-currentHost", "write", Self.domain, key, "-bool", "YES"]
        case .no: arguments = ["-currentHost", "write", Self.domain, key, "-bool", "NO"]
        }
        guard let result = runner.run(arguments) else { throw HandoffError.writeFailed(key) }
        // Deleting a key that is already missing fails; that is the state asked for.
        if result.status != 0 && !(value == .unset && (try? read(key)) == .unset) { throw HandoffError.writeFailed(key) }
    }
}

/// What `--handoff` asks for: off turns Handoff off (Bridgey takes over), on puts it back the way it was.
enum HandoffCommand: String, Sendable {
    case off, on, status
}

/// The state after a step, and the error if it failed (`state` is then what could still be read).
struct HandoffOutcome: Equatable, Sendable {
    var takeover: Bool
    var applied: Bool
    var state: HandoffState?
    var error: HandoffError?

    /// Someone turned Handoff on again in System Settings while the takeover is on here.
    var overridden: Bool { takeover && applied && state.map { !$0.isOff } == true }
}

/// The choice and what to restore, and the steps that apply them. Used by the app and by `--handoff`; the
/// caller runs one at a time (the app on its own queue, the command line alone). UserDefaults is thread safe
/// and the runner is Sendable, so the store may go to that queue.
struct HandoffTakeoverStore: @unchecked Sendable {
    /// The choice: synced, and cleared by Reset > Settings.
    static let choiceKey = "settings.handoff.takeover"
    /// What Handoff was before this Mac turned it off ("unset,unset"); set while the takeover is applied here.
    /// Not a setting, so a reset keeps it and the next launch restores Handoff.
    static let priorKey = "handoff.prior"

    let defaults: UserDefaults
    var system = HandoffDefaults()

    var choice: Bool { defaults.bool(forKey: Self.choiceKey) }
    var prior: HandoffState? { defaults.string(forKey: Self.priorKey).flatMap(HandoffState.init(stored:)) }
    /// This Mac turned Handoff off and has not put it back yet.
    var applied: Bool { prior != nil }

    func setChoice(_ on: Bool) { defaults.set(on, forKey: Self.choiceKey) }

    /// Makes Handoff follow the choice: turns it off (remembering what it was) or puts it back. `force` turns it
    /// off again after the person turned it on in System Settings. Returns the state afterwards.
    @discardableResult
    func reconcile(force: Bool = false) throws -> HandoffState {
        let current = try system.read()
        if choice {
            if !applied {
                // Remember first: if a write fails half way, turning the switch off still restores both keys.
                defaults.set(current.stored, forKey: Self.priorKey)
                try system.write(.off)
            } else if force && current != .off {
                try system.write(.off)
            } else {
                return current
            }
        } else if let prior {
            try system.write(prior)
            defaults.removeObject(forKey: Self.priorKey)
        } else {
            return current
        }
        return try system.read()
    }

    /// The person turned Handoff back on in System Settings while the takeover is on here.
    func overridden(_ state: HandoffState) -> Bool { choice && applied && !state.isOff }

    /// One step, start to end: `off` chooses the takeover and turns Handoff off (again, if System Settings turned
    /// it on); `on` drops the choice and puts back what was there; `status` only reads. nil applies the stored
    /// choice (launch, the switch, a synced change).
    func perform(_ command: HandoffCommand?, force: Bool = false) -> HandoffOutcome {
        var failure: HandoffError?
        var state: HandoffState?
        do {
            switch command {
            case .off?:
                setChoice(true)
                state = try reconcile(force: true)
            case .on?:
                setChoice(false)
                state = try reconcile()
            case .status?:
                state = try system.read()
            case nil:
                state = try reconcile(force: force)
            }
        } catch {
            failure = error as? HandoffError ?? .unreadable
            state = try? system.read()
        }
        return HandoffOutcome(takeover: choice, applied: applied, state: state, error: failure)
    }
}


/// Settings > Clipboard > Let Bridgey handle copy and paste, on the main actor. `defaults` runs on its own queue,
/// one step at a time. It also serves `BridgeyMac --handoff` while the app runs (HandoffControl.swift).
@MainActor
final class HandoffTakeover: ObservableObject {
    static let shared = HandoffTakeover.live()

    @Published private(set) var takeover: Bool
    /// Handoff now, as last read; nil until the first read or when `defaults` cannot be read.
    @Published private(set) var state: HandoffState?
    /// The takeover is on here but someone turned Handoff on again in System Settings.
    @Published private(set) var overridden = false
    /// The last apply or restore failed.
    @Published private(set) var failed = false

    let store: HandoffTakeoverStore
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.handoff")
    private var refreshTimer: Timer?
    private var activation: AnyCancellable?
    private var controlServer: UpdateControlServer?

    init(store: HandoffTakeoverStore) {
        self.store = store
        takeover = store.choice
    }

    static func live() -> HandoffTakeover { HandoffTakeover(store: HandoffTakeoverStore(defaults: .standard)) }

    /// At launch: apply the choice (or restore after a reset), notice changes made in System Settings each
    /// time Bridgey comes to the front, and serve the command line.
    func start() {
        guard activation == nil else { return }
        Task { await run(nil) }
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
        startControlServer()
    }

    /// The switch, setup and a synced change.
    func set(_ on: Bool) {
        guard on != takeover || on != store.choice else { return }
        store.setChoice(on)
        takeover = on
        Task { await run(nil) }
    }

    /// Turn Handoff off again after it was turned on in System Settings.
    func reapply() { Task { await run(nil, force: true) } }

    /// Reads the current Handoff state (Settings shows it live).
    func refresh() { Task { await run(.status) } }

    /// While Settings > Clipboard is open, check every few seconds for a change in System Settings.
    func watch(_ on: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard on else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// One step on the queue, then what it shows. `command` nil applies the stored choice.
    @discardableResult
    func run(_ command: HandoffCommand?, force: Bool = false) async -> HandoffOutcome {
        let store = store
        let queue = queue
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<HandoffOutcome, Never>) in
            queue.async { continuation.resume(returning: store.perform(command, force: force)) }
        }
        if let error = outcome.error {
            BridgeyLog.clipboard.error("HANDOFF \(command?.rawValue ?? "apply", privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        if command != .status { failed = outcome.error != nil }
        show(outcome)
        return outcome
    }

    private func show(_ outcome: HandoffOutcome) {
        if takeover != outcome.takeover { takeover = outcome.takeover }
        if state != outcome.state { state = outcome.state }
        if overridden != outcome.overridden { overridden = outcome.overridden }
    }

    // MARK: Command line

    private func startControlServer() {
        let server = UpdateControlServer(path: UpdateControlSocket.defaultURL(fileName: HandoffControl.socketName).path) { [weak self] request, reply in
            Task { @MainActor in
                guard let self else { return reply.finish(.refused, reason: "not_ready", text: nil) }
                await self.handle(request, reply: reply)
            }
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            BridgeyLog.clipboard.error("HANDOFF_CONTROL start failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `--handoff off|on|status` from the command line, answered with the state and a result.
    func handle(_ request: UpdateControlRequest, reply: UpdateControlReply) async {
        guard request.command == .handoff, let command = request.handoff else {
            return reply.finish(.refused, reason: "bad_request", text: nil)
        }
        let outcome = await run(command)
        reply.send(HandoffControl.stateEvent(outcome, running: true))
        reply.send(HandoffControl.resultEvent(outcome))
        reply.close()
    }
}
