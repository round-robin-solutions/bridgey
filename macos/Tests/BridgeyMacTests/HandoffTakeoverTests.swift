import Foundation
import XCTest
@testable import BridgeyMac

/// Let Bridgey handle copy and paste (HandoffTakeover.swift, HandoffControl.swift): turning Handoff off remembers
/// each key, turning the takeover off puts back exactly that, and `BridgeyMac --handoff` does the same steps.
/// A fake `defaults` stands in for the real one, so nothing here touches this Mac's Handoff.
final class HandoffTakeoverTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var system: FakeHandoffSystem!
    private var directory: URL!

    private let advertising = HandoffDefaults.advertisingKey
    private let receiving = HandoffDefaults.receivingKey

    override func setUpWithError() throws {
        suiteName = "bridgey-handoff-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        system = FakeHandoffSystem()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: HandoffTakeoverStore {
        HandoffTakeoverStore(defaults: defaults, system: HandoffDefaults(runner: system.runner))
    }

    // MARK: Values

    func testStoredStateRoundTripsAndBadValuesAreRejected() {
        for advertising in [HandoffKeyValue.unset, .yes, .no] {
            for receiving in [HandoffKeyValue.unset, .yes, .no] {
                let state = HandoffState(advertising: advertising, receiving: receiving)
                XCTAssertEqual(HandoffState(stored: state.stored), state)
            }
        }
        XCTAssertEqual(HandoffState.systemDefault.stored, "unset,unset")
        XCTAssertNil(HandoffState(stored: ""))
        XCTAssertNil(HandoffState(stored: "unset"))
        XCTAssertNil(HandoffState(stored: "unset,maybe"))
        XCTAssertNil(HandoffState(stored: "no,no,no"))
        XCTAssertTrue(HandoffState.off.isOff)
        XCTAssertFalse(HandoffState.systemDefault.isOff)
        XCTAssertFalse(HandoffState(advertising: .no, receiving: .unset).isOff, "one direction still on")
    }

    func testReadsTheKeysTheWayDefaultsPrintsThem() throws {
        let handoff = HandoffDefaults(runner: system.runner)
        XCTAssertEqual(try handoff.read(), .systemDefault, "missing keys mean on")
        system.keys = [advertising: "1", receiving: "0"]
        XCTAssertEqual(try handoff.read(), HandoffState(advertising: .yes, receiving: .no))
        system.keys = [advertising: "garbage"]
        XCTAssertThrowsError(try handoff.read()) { XCTAssertEqual($0 as? HandoffError, .unreadable) }
        system.keys = [:]
        system.broken = true
        XCTAssertThrowsError(try handoff.read()) { XCTAssertEqual($0 as? HandoffError, .unreadable) }
    }

    func testDeletingAKeyThatIsAlreadyMissingIsFine() throws {
        let handoff = HandoffDefaults(runner: system.runner)
        try handoff.write(.systemDefault)
        XCTAssertEqual(system.keys, [:])
        XCTAssertEqual(system.calls.filter { $0[1] == "delete" }.count, 2)
        // A delete that fails while the key is still there is a failure.
        system.keys = [advertising: "0"]
        system.failing = [advertising]
        XCTAssertThrowsError(try handoff.write(.systemDefault)) { XCTAssertEqual($0 as? HandoffError, .writeFailed(self.advertising)) }
    }

    func testWritesUseCurrentHostAndTheRightCommands() throws {
        try HandoffDefaults(runner: system.runner).write(HandoffState(advertising: .yes, receiving: .no))
        XCTAssertEqual(system.calls, [
            ["-currentHost", "write", HandoffDefaults.domain, advertising, "-bool", "YES"],
            ["-currentHost", "write", HandoffDefaults.domain, receiving, "-bool", "NO"],
        ])
    }

    // MARK: Turning off and putting back

    func testFromTheDefaultTurnsOffThenDeletesBothKeysAgain() throws {
        store.setChoice(true)
        XCTAssertEqual(try store.reconcile(), .off)
        XCTAssertEqual(system.keys, [advertising: "0", receiving: "0"])
        XCTAssertEqual(defaults.string(forKey: HandoffTakeoverStore.priorKey), "unset,unset")
        XCTAssertTrue(store.applied)
        // Again: nothing to do, the first state stays remembered.
        system.calls = []
        XCTAssertEqual(try store.reconcile(), .off)
        XCTAssertTrue(system.calls.allSatisfy { $0[1] == "read" })
        XCTAssertEqual(store.prior, .systemDefault)

        store.setChoice(false)
        XCTAssertEqual(try store.reconcile(), .systemDefault)
        XCTAssertEqual(system.keys, [:], "both keys deleted, the way a Mac that never changed Handoff has them")
        XCTAssertNil(defaults.object(forKey: HandoffTakeoverStore.priorKey))
        XCTAssertFalse(store.applied)
    }

    func testAMixedEarlierStateComesBackExactly() throws {
        system.keys = [advertising: "1"]
        store.setChoice(true)
        try store.reconcile()
        XCTAssertEqual(system.keys, [advertising: "0", receiving: "0"])
        XCTAssertEqual(store.prior, HandoffState(advertising: .yes, receiving: .unset))
        store.setChoice(false)
        XCTAssertEqual(try store.reconcile(), HandoffState(advertising: .yes, receiving: .unset))
        XCTAssertEqual(system.keys, [advertising: "1"])
    }

    func testHandoffAlreadyOffStaysOff() throws {
        system.keys = [advertising: "0", receiving: "0"]
        store.setChoice(true)
        try store.reconcile()
        XCTAssertEqual(store.prior, .off)
        store.setChoice(false)
        XCTAssertEqual(try store.reconcile(), .off)
        XCTAssertEqual(system.keys, [advertising: "0", receiving: "0"], "it was off before Bridgey, so it stays off")
    }

    func testTurnedBackOnInSystemSettingsShowsAndForceTurnsItOffAgain() throws {
        store.setChoice(true)
        try store.reconcile()
        // The person turns Handoff on in System Settings, which writes YES.
        system.keys = [advertising: "1", receiving: "1"]
        let now = try store.system.read()
        XCTAssertTrue(store.overridden(now))
        // A plain reconcile (launch, sync) leaves their change alone.
        XCTAssertEqual(try store.reconcile(), HandoffState(advertising: .yes, receiving: .yes))
        // Turn off again: off, and the first earlier state is still what comes back.
        XCTAssertEqual(try store.reconcile(force: true), .off)
        XCTAssertFalse(store.overridden(.off))
        XCTAssertEqual(store.prior, .systemDefault)
        store.setChoice(false)
        try store.reconcile()
        XCTAssertEqual(system.keys, [:])
        XCTAssertFalse(store.overridden(.systemDefault), "not overridden once the takeover is off")
    }

    func testAWriteThatFailsHalfWayStillRestores() throws {
        system.failing = [receiving]
        store.setChoice(true)
        XCTAssertThrowsError(try store.reconcile()) { XCTAssertEqual($0 as? HandoffError, .writeFailed(self.receiving)) }
        XCTAssertEqual(system.keys, [advertising: "0"])
        XCTAssertEqual(store.prior, .systemDefault, "remembered before the first write")
        system.failing = []
        store.setChoice(false)
        XCTAssertEqual(try store.reconcile(), .systemDefault)
        XCTAssertEqual(system.keys, [:])
        XCTAssertFalse(store.applied)
    }

    func testAFailedRestoreKeepsWhatToRestoreForNextTime() throws {
        store.setChoice(true)
        try store.reconcile()
        system.failing = [advertising]
        store.setChoice(false)
        XCTAssertThrowsError(try store.reconcile())
        XCTAssertEqual(store.prior, .systemDefault)
        system.failing = []
        try store.reconcile()
        XCTAssertEqual(system.keys, [:])
        XCTAssertFalse(store.applied)
    }

    func testUnreadableHandoffChangesNothing() {
        system.keys = [advertising: "maybe"]
        store.setChoice(true)
        XCTAssertThrowsError(try store.reconcile()) { XCTAssertEqual($0 as? HandoffError, .unreadable) }
        XCTAssertFalse(store.applied)
        XCTAssertTrue(system.calls.allSatisfy { $0[1] == "read" })
    }

    /// Reset > Settings and Everything clear the choice but keep what to restore; the next launch puts Handoff back.
    func testAResetClearsTheChoiceAndTheNextLaunchRestores() throws {
        system.keys = [receiving: "1"]
        store.setChoice(true)
        try store.reconcile()
        let reset = LocalDataReset(defaults: defaults)
        XCTAssertTrue(reset.keys(.settings).contains(HandoffTakeoverStore.choiceKey))
        for choice in [ResetChoice.settings, .everything] {
            for item in LocalDataReset.items(choice) {
                XCTAssertFalse(reset.keys(item).contains(HandoffTakeoverStore.priorKey), "\(choice) \(item)")
            }
        }
        for key in reset.keys(.settings) { defaults.removeObject(forKey: key) }
        XCTAssertFalse(store.choice)
        XCTAssertTrue(store.applied)
        let outcome = store.perform(nil)
        XCTAssertEqual(outcome, HandoffOutcome(takeover: false, applied: false, state: HandoffState(advertising: .unset, receiving: .yes), error: nil))
        XCTAssertEqual(system.keys, [receiving: "1"])
    }

    // MARK: Commands

    func testCommandsReportTheirOutcome() {
        XCTAssertEqual(store.perform(.status), HandoffOutcome(takeover: false, applied: false, state: .systemDefault, error: nil))
        XCTAssertEqual(store.perform(.off), HandoffOutcome(takeover: true, applied: true, state: .off, error: nil))
        XCTAssertTrue(store.choice)
        system.keys = [advertising: "1", receiving: "1"]
        let overridden = store.perform(.status)
        XCTAssertTrue(overridden.overridden)
        // `off` again turns it off again, as the button does.
        XCTAssertEqual(store.perform(.off), HandoffOutcome(takeover: true, applied: true, state: .off, error: nil))
        XCTAssertEqual(store.perform(.on), HandoffOutcome(takeover: false, applied: false, state: .systemDefault, error: nil))
        XCTAssertEqual(system.keys, [:])
        XCTAssertFalse(store.perform(.status).overridden)
    }

    func testAFailedCommandReportsTheErrorAndWhatItCouldRead() {
        system.failing = [advertising]
        let outcome = store.perform(.off)
        XCTAssertEqual(outcome.error, .writeFailed(advertising))
        XCTAssertEqual(outcome.state, .systemDefault)
        XCTAssertTrue(outcome.takeover)
        XCTAssertTrue(outcome.applied)
        system.broken = true
        let broken = store.perform(.status)
        XCTAssertEqual(broken.error, .unreadable)
        XCTAssertNil(broken.state)
        XCTAssertFalse(broken.overridden)
    }

    func testControlRequestsCarryTheHandoffCommand() {
        for command in [HandoffCommand.off, .on, .status] {
            let request = UpdateControlRequest(command: .handoff, handoff: command)
            XCTAssertEqual(UpdateControlRequest.decode(request.line.dropLast()), request)
        }
        XCTAssertNil(UpdateControlRequest.decode(Data(#"{"version":1,"command":"handoff"}"#.utf8)), "handoff needs a command")
        XCTAssertNil(UpdateControlRequest.decode(Data(#"{"version":1,"command":"handoff","handoff":"toggle"}"#.utf8)))
        XCTAssertNil(UpdateControlRequest.decode(Data(#"{"version":1,"command":"handoff","handoff":1}"#.utf8)))
        XCTAssertNil(UpdateControlRequest.decode(Data(#"{"version":1,"command":"update-all","handoff":"off"}"#.utf8))?.handoff,
                     "only handoff reads it")
        XCTAssertFalse(String(decoding: UpdateControlRequest(command: .updateAll).line, as: UTF8.self).contains("handoff"))
    }

    // MARK: Command line

    private func runCLI(_ arguments: [String]) -> (code: Int32, lines: [String]) {
        var lines: [String] = []
        let environment = HandoffControl.Environment(socketPath: directory.appendingPathComponent("none.sock").path, store: store,
                                                     output: { lines.append($0) })
        let code = HandoffControl.run(arguments: ["BridgeyMac"] + arguments, environment: environment)
        return (code, lines)
    }

    func testCommandLineWithoutTheAppDoesItHere() {
        let off = runCLI(["--handoff", "off"])
        XCTAssertEqual(off.code, 0)
        XCTAssertEqual(off.lines, ["Let Bridgey handle copy and paste: on", "Apple Handoff on this Mac: off",
                                   "Bridgey by Round Robin is not running, so this was done here. Your other Macs follow the next time it opens."]
                       .map { $0.replacingOccurrences(of: "Bridgey by Round Robin", with: Edition.displayName) })
        XCTAssertEqual(system.keys, [advertising: "0", receiving: "0"])
        XCTAssertTrue(store.choice)

        let status = runCLI(["--handoff", "STATUS"])
        XCTAssertEqual(status.code, 0)
        XCTAssertEqual(status.lines, ["Let Bridgey handle copy and paste: on", "Apple Handoff on this Mac: off"])

        let on = runCLI(["--handoff", "on"])
        XCTAssertEqual(on.code, 0)
        XCTAssertEqual(on.lines.prefix(2), ["Let Bridgey handle copy and paste: off", "Apple Handoff on this Mac: on"])
        XCTAssertEqual(system.keys, [:])
        XCTAssertFalse(store.choice)
    }

    func testCommandLineJSONAndFailures() throws {
        let json = runCLI(["--handoff", "off", "--json"])
        XCTAssertEqual(json.code, 0)
        XCTAssertEqual(json.lines.count, 2)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(state["event"] as? String, "handoff")
        XCTAssertEqual(state["handoff"] as? String, "off")
        XCTAssertEqual(state["takeover"] as? Bool, true)
        XCTAssertEqual(state["running"] as? Bool, false)
        XCTAssertEqual(state["advertising"] as? String, "no")
        XCTAssertEqual(json.lines[1], #"{"event":"result","result":"done"}"#)

        system.failing = [advertising]
        let failed = runCLI(["--handoff", "on", "--json"])
        XCTAssertEqual(failed.code, 1)
        XCTAssertEqual(failed.lines.last, #"{"event":"result","key":"ActivityAdvertisingAllowed","reason":"write_failed","result":"failed"}"#)
        let words = runCLI(["--handoff", "on"])
        XCTAssertEqual(words.code, 1)
        XCTAssertTrue(words.lines[0].hasPrefix("Error: could not change Handoff (ActivityAdvertisingAllowed)."))

        for bad in [["--handoff"], ["--handoff", "toggle"], ["--handoff", "--json"]] {
            let usage = runCLI(bad)
            XCTAssertEqual(usage.code, 2, "\(bad)")
            XCTAssertEqual(usage.lines, [HandoffControl.usage])
        }
    }

    func testCommandLineWords() {
        func state(_ fields: [String: Any]) -> [String: Any] { (["event": "handoff", "running": true] as [String: Any]).merging(fields) { $1 } }
        let done: [String: Any] = ["event": "result", "result": "done"]
        XCTAssertEqual(HandoffControl.lines([state(["takeover": true, "handoff": "on", "overridden": true]), done], command: .status),
                       ["Let Bridgey handle copy and paste: on", "Apple Handoff on this Mac: on",
                        "Handoff was turned back on in System Settings. Run BridgeyMac --handoff off to turn it off again."])
        XCTAssertEqual(HandoffControl.lines([state(["takeover": false, "handoff": "off"]), done], command: .on),
                       ["Let Bridgey handle copy and paste: off", "Apple Handoff on this Mac: off",
                        "Handoff is off in System Settings, so it stays off. Turn it on in System Settings > General > AirDrop & Handoff."])
        XCTAssertEqual(HandoffControl.lines([state(["takeover": false, "handoff": "partly"]), done], command: .status),
                       ["Let Bridgey handle copy and paste: off", "Apple Handoff on this Mac: partly on (one direction only)"])
        XCTAssertEqual(HandoffControl.lines([["event": "result", "result": "failed", "reason": "unreadable"]], command: .status),
                       ["Error: could not read the Handoff setting on this Mac."])
        XCTAssertEqual(HandoffControl.lines([["event": "result", "result": "refused", "reason": "bad_request"]], command: .off), [])
        XCTAssertEqual(HandoffControl.word(nil), "unknown")
        XCTAssertEqual(HandoffControl.word(HandoffState(advertising: .yes, receiving: .no)), "partly")
        for line in [HandoffControl.usage, HandoffText.title, HandoffText.detail, HandoffText.overridden, HandoffText.failed] {
            XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"), line)
        }
    }

    func testSettingsLine() {
        XCTAssertNil(HandoffDisplay().stateLine)
        XCTAssertEqual(HandoffDisplay(state: .off).stateLine, "Apple Handoff: off")
        XCTAssertEqual(HandoffDisplay(state: .systemDefault).stateLine, "Apple Handoff: on")
        XCTAssertEqual(HandoffDisplay(state: HandoffState(advertising: .unset, receiving: .no)).stateLine, "Apple Handoff: partly on")
    }

    /// The app's model: the switch applies through the queue and shows the result.
    @MainActor
    func testTheAppModelAppliesAndShows() async {
        let model = HandoffTakeover(store: store)
        XCTAssertFalse(model.takeover)
        let off = await model.run(.off)
        XCTAssertEqual(off.state, .off)
        XCTAssertTrue(model.takeover)
        XCTAssertEqual(model.state, .off)
        XCTAssertFalse(model.failed)
        system.keys = [advertising: "1", receiving: "1"]
        await model.run(.status)
        XCTAssertTrue(model.overridden)
        await model.run(nil, force: true)
        XCTAssertFalse(model.overridden)
        system.failing = [advertising]
        await model.run(.on)
        XCTAssertTrue(model.failed)
        system.failing = []
        await model.run(.on)
        XCTAssertFalse(model.failed)
        XCTAssertFalse(model.takeover)
        XCTAssertEqual(system.keys, [:])
    }
}

/// `defaults -currentHost` for the two Handoff keys, in memory. Booleans print as 1 or 0, like the real one.
final class FakeHandoffSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [String: String] = [:]
    private var _calls: [[String]] = []
    private var _failing: Set<String> = []
    private var _broken = false

    var keys: [String: String] { get { locked { _keys } } set { locked { _keys = newValue } } }
    var calls: [[String]] { get { locked { _calls } } set { locked { _calls = newValue } } }
    /// Writes and deletes of these keys fail.
    var failing: Set<String> { get { locked { _failing } } set { locked { _failing = newValue } } }
    /// `defaults` cannot run at all.
    var broken: Bool { get { locked { _broken } } set { locked { _broken = newValue } } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var runner: HandoffDefaultsRunner {
        HandoffDefaultsRunner { [self] arguments in self.handle(arguments) }
    }

    private func handle(_ arguments: [String]) -> (status: Int32, output: String)? {
        locked {
            _calls.append(arguments)
            guard !_broken, arguments.count >= 4, arguments[0] == "-currentHost", arguments[2] == HandoffDefaults.domain else { return nil }
            let key = arguments[3]
            switch arguments[1] {
            case "read":
                guard let value = _keys[key] else { return (1, "") }
                return (0, value + "\n")
            case "write":
                guard !_failing.contains(key), arguments.count == 6, arguments[4] == "-bool" else { return (1, "") }
                _keys[key] = arguments[5] == "YES" ? "1" : "0"
                return (0, "")
            case "delete":
                guard !_failing.contains(key), _keys[key] != nil else { return (1, "") }
                _keys[key] = nil
                return (0, "")
            default:
                return nil
            }
        }
    }
}
