import Foundation
import XCTest
@testable import BridgeyMac

final class TailscaleSetupTests: XCTestCase {
    func testOfficialApplicationAndCommandLineDetectionWithoutReadingTheHost() {
        let app = URL(fileURLWithPath: "/fixture/Applications/Renamed Tailscale.app")
        let binary = app.appendingPathComponent("Contents/MacOS/Tailscale")
        XCTAssertEqual(TailscaleInstallation.locate(applications: [app], binaries: ["/fixture/tailscale"],
                                                   executable: { $0 == binary }),
                       TailscaleInstallation(application: app, executable: binary))
        XCTAssertEqual(TailscaleInstallation.locate(applications: [app], binaries: ["/fixture/tailscale"],
                                                   executable: { $0.path == "/fixture/tailscale" }),
                       TailscaleInstallation(application: app, executable: URL(fileURLWithPath: "/fixture/tailscale")))
        XCTAssertEqual(TailscaleInstallation.locate(applications: [], binaries: ["/fixture/cli"], executable: { _ in true }),
                       TailscaleInstallation(application: nil, executable: URL(fileURLWithPath: "/fixture/cli")))
        XCTAssertEqual(TailscaleInstallation.locate(applications: [], binaries: [], executable: { _ in false }),
                       TailscaleInstallation(application: nil, executable: nil))
    }

    func testBackendStatesAreDistinctFromAnEmptyPeerList() {
        let states: [(String, TailscaleSetupState)] = [
            ("NeedsLogin", .needsLogin), ("Stopped", .stopped), ("NeedsMachineAuth", .needsApproval),
            ("Starting", .starting), ("Running", .running), ("NoState", .unavailable),
            ("InUseOtherUser", .unavailable), ("FutureUnknown", .unavailable),
        ]
        for (backend, expected) in states {
            let data = Data("{\"BackendState\":\"\(backend)\",\"Peer\":{}}".utf8)
            XCTAssertEqual(TailscaleSnapshot.decode(data).state, expected, backend)
        }
        XCTAssertEqual(TailscaleSnapshot.decode(Data("{}".utf8)).state, .unavailable)
        XCTAssertEqual(TailscaleSnapshot.decode(Data("invalid".utf8)).state, .unavailable)
        let legacy = Data(#"{"Peer":{"p":{"HostName":"fixture","TailscaleIPs":["100.90.0.3"],"Online":true}}}"#.utf8)
        XCTAssertEqual(TailnetStatus.parse(legacy).count, 1, "legacy peer parser remains independent")
        XCTAssertEqual(TailscaleSnapshot.decode(legacy).state, .unavailable, "setup status needs a verified backend state")
        XCTAssertEqual(TailnetProbe.snapshot(installation: TailscaleInstallation(application: nil, executable: nil)).state, .notInstalled)
        XCTAssertEqual(TailnetProbe.snapshot(installation: TailscaleInstallation(application: URL(fileURLWithPath: "/fixture/app"), executable: nil)).state, .unavailable)
    }

    func testExitedChildOutputIsFullyRetainedAndOnlyStatusIsRequested() throws {
        let data = Data(#"{"BackendState":"Running","Peer":{}}"#.utf8)
        let result = try withCommand("""
        [ "$1" = status ] && [ "$2" = --json ] && [ "$#" = 2 ] || exit 9
        printf '%s' '{"BackendState":"Running","Peer":{}}'
        """) { TailscaleStatusCommand.run(executable: $0) }
        XCTAssertEqual(result, .output(data))
    }

    func testCommandErrorsAndOutputBudgetAreRecoverable() throws {
        XCTAssertEqual(try withCommand("exit 7") { TailscaleStatusCommand.run(executable: $0) }, .unavailable)
        XCTAssertEqual(try withCommand("printf '123456789'") {
            TailscaleStatusCommand.run(executable: $0, outputLimit: 4)
        }, .outputTooLarge)
        XCTAssertEqual(TailscaleStatusCommand.run(executable: URL(fileURLWithPath: "/nonexistent/fixture/tailscale")), .unavailable)
    }

    func testIgnoringTermCannotHoldTheStatusProbeIndefinitely() throws {
        // exec leaves only the exact owned sleep process; its inherited ignored TERM requires KILL.
        let start = ProcessInfo.processInfo.systemUptime
        let result = try withCommand("trap '' TERM\nexec /bin/sleep 30") {
            TailscaleStatusCommand.run(executable: $0, timeout: 0.1)
        }
        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }

    @MainActor func testConcurrentRefreshesShareOneHeldProbe() async {
        let gate = TailscaleRefreshGate()
        let probe = HeldProbe()
        let first = Task { await gate.read { await probe.read() } }
        await probe.waitUntilStarted()
        // Both calls are on MainActor: the second enters the pending gate before this release
        // task can run, so overlap is explicit rather than based on an arbitrary sleep.
        let release = Task { await probe.finish() }
        let secondResult = await gate.read { await probe.read() }
        let firstResult = await first.value
        await release.value
        XCTAssertEqual(firstResult.state, .running)
        XCTAssertEqual(secondResult.state, .running)
        let count = await probe.count
        XCTAssertEqual(count, 1)
    }

    func testPeerProbesAreBoundedAndEveryAddressIsConsidered() async {
        let counter = ProbeCounter()
        let addresses = (0..<31).map { "fixture-\($0)" }
        let found = await TailnetProbe.answering(addresses: addresses, limit: 3) { address in
            await counter.probe(address)
        }
        XCTAssertEqual(found, Set(addresses))
        let maximum = await counter.maximum
        let seen = await counter.seen
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertEqual(seen, Set(addresses))
    }

    private func withCommand<T>(_ script: String, work: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-tailscale-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = directory.appendingPathComponent("fixture")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        return try work(command)
    }
}

private actor HeldProbe {
    var count = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiter: CheckedContinuation<TailscaleSnapshot, Never>?

    func read() async -> TailscaleSnapshot {
        count += 1
        return await withCheckedContinuation { continuation in
            resultWaiter = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if resultWaiter != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() {
        resultWaiter?.resume(returning: TailscaleSnapshot(state: .running))
        resultWaiter = nil
    }
}

private actor ProbeCounter {
    var active = 0
    var maximum = 0
    var seen = Set<String>()

    func probe(_ address: String) async -> Bool {
        active += 1
        maximum = max(maximum, active)
        seen.insert(address)
        await Task.yield()
        active -= 1
        return true
    }
}
