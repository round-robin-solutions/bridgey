import Foundation
import Sparkle
import XCTest
@testable import BridgeyMac

/// Update all: the start gate, the not-applied memory, this Mac's status, the plan and the run.
final class UpdateAllTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_091_600)
    private let phone = "11111111-1111-4111-8111-111111111111"
    private let tablet = "22222222-2222-4222-8222-222222222222"

    private func status(_ state: PeerUpdateState = .current, app: String = "0.9.0-rr.3-beta.2", build: Int = 903002,
                        channel: UpdateChannel = .beta, target: String? = nil, targetBuild: Int? = nil,
                        reason: PeerUpdateReason? = nil, remoteStart: Bool = true, checkedAt: Date? = nil,
                        platform: UpdatePlatform = .android) -> PeerUpdateStatus {
        PeerUpdateStatus(platform: platform, edition: "rr", app: app, build: build, channel: channel, state: state, target: target,
                         targetBuild: targetBuild, reason: reason, remoteStart: remoteStart,
                         checkedAt: Int(((checkedAt ?? t0).timeIntervalSince1970 * 1000).rounded()))
    }

    private var macCurrent: PeerUpdateStatus { status(app: "0.9.0-rr.2", build: 902000, channel: .stable, platform: .macos) }
    private var macReady: PeerUpdateStatus {
        status(.ready, app: "0.9.0-rr.2", build: 902000, channel: .stable, target: "0.9.0-rr.3", targetBuild: 903000, platform: .macos)
    }

    private func ids() -> () -> String {
        var counter = 0
        return {
            counter += 1
            return String(format: "00000000-0000-4000-8000-%012d", counter)
        }
    }

    // MARK: Gate

    func testGateRefusesInOrderAndRateLimitsPerPhone() {
        var gate = UpdateStartGate()
        func decide(_ id: String = "p", retry: Bool = false, at seconds: TimeInterval, allowed: Bool = true, available: Bool = true,
                    notApplied: Bool = false, canStart: Bool = true) -> UpdateStartGate.Decision {
            gate.decide(deviceID: id, retry: retry, now: t0.addingTimeInterval(seconds), allowed: allowed, updaterAvailable: available,
                        notApplied: notApplied, canStart: canStart)
        }
        XCTAssertEqual(decide(at: 0, allowed: false), .refuse(.disabled))
        XCTAssertEqual(decide(at: 0, available: false), .refuse(.manual))
        XCTAssertEqual(decide(at: 0), .accept)
        XCTAssertEqual(decide(at: 10), .refuse(.rateLimited))
        XCTAssertEqual(decide("other", at: 10), .accept, "the limit is per phone")
        XCTAssertEqual(decide(at: 31, notApplied: true), .refuse(.notApplied))
        XCTAssertEqual(decide(retry: true, at: 62, notApplied: true), .accept, "Retry may try a version that did not apply")
        XCTAssertEqual(decide(at: 93, canStart: false), .refuse(.busy))
        XCTAssertEqual(decide(at: 124), .accept)
        // Five counted starts this hour: the sixth waits, and refused rate-limited starts did not count.
        XCTAssertEqual(decide(at: 155), .refuse(.rateLimited))
        XCTAssertEqual(decide(at: 3601), .accept)
    }

    // MARK: Not applied

    func testAttemptStoreReportsARelaunchOnTheOldBuild() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UpdateAllTests.\(UUID().uuidString)"))
        let store = UpdateAttemptStore(defaults: defaults)
        store.recordInstall(build: 903000, version: "0.9.0-rr.3", now: t0)
        store.launched(installedBuild: 903000, now: t0.addingTimeInterval(20))
        XCTAssertNil(store.notApplied)
        XCTAssertNil(store.pending)

        store.recordInstall(build: 904000, version: "0.9.0-rr.4", now: t0)
        store.launched(installedBuild: 903000, now: t0.addingTimeInterval(30))
        XCTAssertEqual(store.notApplied, UpdateAttemptStore.Attempt(build: 904000, version: "0.9.0-rr.4", at: t0))
        store.offered(build: 904000)
        XCTAssertNotNil(store.notApplied, "the same build stays blocked")
        store.offered(build: 905000)
        XCTAssertNil(store.notApplied, "a newer release may install")

        store.recordInstall(build: 906000, version: "0.9.0-rr.6", now: t0)
        store.launched(installedBuild: 903000, now: t0.addingTimeInterval(7200))
        XCTAssertNil(store.notApplied, "an old attempt is not reported")
    }

    // MARK: This Mac's status

    func testLocalStatusFollowsSparkle() {
        var inputs = LocalUpdateInputs(available: true, app: "0.9.0-rr.2", build: 902000, channel: .stable, flow: .idle, deferral: nil,
                                       offeredBuild: nil, failureReason: nil, lastCheck: t0, remoteStartAllowed: true, notApplied: nil)
        XCTAssertEqual(inputs.status.state, .current)
        XCTAssertEqual(inputs.status.checkedAt, 1_793_091_600_000)
        XCTAssertEqual(inputs.status.platform, .macos)
        XCTAssertTrue(inputs.status.remoteStart)

        inputs.offeredBuild = 903000
        inputs.flow = .available(UpdateOffer(version: "0.9.0-rr.3", notes: nil, downloaded: false, userInitiated: false))
        XCTAssertEqual(inputs.status.state, .available)
        XCTAssertEqual(inputs.status.target, "0.9.0-rr.3")
        XCTAssertEqual(inputs.status.targetBuild, 903000)
        inputs.flow = .downloading(version: "0.9.0-rr.3", received: 420, expected: 1000)
        XCTAssertEqual(inputs.status.state, .downloading)
        XCTAssertEqual(inputs.status.progress, 42)
        inputs.flow = .extracting(version: "0.9.0-rr.3", progress: 0.2)
        XCTAssertEqual(inputs.status.progress, 100)
        inputs.flow = .ready(version: "0.9.0-rr.3")
        XCTAssertEqual(inputs.status.state, .ready)
        inputs.flow = .installing(version: "0.9.0-rr.3")
        XCTAssertEqual(inputs.status.state, .installing)
        inputs.flow = .idle
        inputs.deferral = UpdateDeferral(version: "0.9.0-rr.3", kind: .onQuit)
        XCTAssertEqual(inputs.status.state, .ready)
        inputs.deferral = UpdateDeferral(version: "0.9.0-rr.3", kind: .later)
        XCTAssertEqual(inputs.status.state, .available)
        inputs.deferral = nil
        inputs.flow = .failed(message: "x")
        inputs.failureReason = .safety
        XCTAssertEqual(inputs.status.state, .failed)
        XCTAssertEqual(inputs.status.reason, .safety)

        inputs.flow = .upToDate
        inputs.notApplied = UpdateAttemptStore.Attempt(build: 903000, version: "0.9.0-rr.3", at: t0)
        XCTAssertEqual(inputs.status.state, .failed)
        XCTAssertEqual(inputs.status.reason, .notApplied)
        XCTAssertEqual(inputs.status.target, "0.9.0-rr.3")

        inputs.remoteStartAllowed = false
        XCTAssertFalse(inputs.status.remoteStart)
        inputs.available = false
        XCTAssertEqual(inputs.status.state, .manual)
        XCTAssertFalse(inputs.status.remoteStart)
    }

    func testSparkleErrorsBecomeReasons() {
        XCTAssertEqual(UpdateFlowText.errorReason(domain: NSURLErrorDomain, code: -1009), .check)
        XCTAssertEqual(UpdateFlowText.errorReason(domain: SUSparkleErrorDomain, code: 3001), .safety)
        XCTAssertEqual(UpdateFlowText.errorReason(domain: SUSparkleErrorDomain, code: 2001), .download)
        XCTAssertEqual(UpdateFlowText.errorReason(domain: SUSparkleErrorDomain, code: 4012), .installer)
        XCTAssertEqual(UpdateFlowText.errorReason(domain: SUSparkleErrorDomain, code: 4007), .cancelled)
        XCTAssertEqual(UpdateFlowText.errorReason(domain: "x", code: 1), .other)
    }

    func testStatusSentOnlyWhenMoreThanProgressChanged() {
        var a = status(.downloading, target: "0.9.0-rr.3-beta.3", targetBuild: 903003)
        a.progress = 10
        var b = a
        b.progress = 40
        XCTAssertTrue(a.sameApartFromProgress(b))
        b.state = .ready
        XCTAssertFalse(a.sameApartFromProgress(b))
    }

    // MARK: Plan

    private func plan(_ phones: [UpdateAllPhone], local: PeerUpdateStatus? = nil, now: Date? = nil) -> UpdatePlan {
        UpdatePlan.make(local: local ?? macCurrent, localName: "This Mac", phones: phones, now: now ?? t0.addingTimeInterval(60))
    }

    func testPlanSkipsWithReasonsAndPutsThisMacLast() {
        let phones = [
            UpdateAllPhone(id: "a", name: "OnePlus 11", connected: true, supportsUpdates: true,
                           status: status(.available, target: "0.9.0-rr.3-beta.3", targetBuild: 903003)),
            UpdateAllPhone(id: "b", name: "Pixel 8", connected: false, supportsUpdates: false, status: nil),
            UpdateAllPhone(id: "c", name: "Galaxy", connected: true, supportsUpdates: false, status: nil),
            UpdateAllPhone(id: "d", name: "Moto", connected: true, supportsUpdates: true, status: nil),
            UpdateAllPhone(id: "e", name: "Nokia", connected: true, supportsUpdates: true, status: status(.manual)),
            UpdateAllPhone(id: "f", name: "Fairphone", connected: true, supportsUpdates: true,
                           status: status(.failed, target: "x", reason: .notApplied)),
            UpdateAllPhone(id: "g", name: "Honor", connected: true, supportsUpdates: true, status: status(.available, target: "x", remoteStart: false)),
            UpdateAllPhone(id: "h", name: "Asus", connected: true, supportsUpdates: true, status: status()),
            UpdateAllPhone(id: "i", name: "Xperia", connected: true, supportsUpdates: true, status: status(checkedAt: t0.addingTimeInterval(-7200))),
        ]
        let result = plan(phones, local: macReady)
        XCTAssertEqual(result.entries.map(\.name), ["Asus", "Fairphone", "Galaxy", "Honor", "Moto", "Nokia", "OnePlus 11", "Pixel 8", "Xperia", "This Mac"])
        func kind(_ id: String) -> UpdatePlanEntry.Kind? { result.entries.first { $0.id == id }?.kind }
        XCTAssertEqual(kind("a"), .update(to: "0.9.0-rr.3-beta.3", toBuild: 903003))
        XCTAssertEqual(kind("b"), .skipped(.offline))
        XCTAssertEqual(kind("c"), .skipped(.byHand))
        XCTAssertEqual(kind("d"), .skipped(.noStatus))
        XCTAssertEqual(kind("e"), .skipped(.byHand))
        XCTAssertEqual(kind("f"), .skipped(.notApplied))
        XCTAssertEqual(kind("g"), .skipped(.remoteOff))
        XCTAssertEqual(kind("h"), .upToDate)
        XCTAssertEqual(kind("i"), .update(to: nil, toBuild: nil), "an old check: it checks its own channel")
        XCTAssertEqual(kind(UpdatePlan.localID), .update(to: "0.9.0-rr.3", toBuild: 903000))
        XCTAssertEqual(result.targets.last?.isLocal, true)
        XCTAssertTrue(result.visible)
        XCTAssertTrue(result.channelsDiffer)
        XCTAssertEqual(UpdateAllText.summary(result), "Updates 2 connected phones and this Mac")
        XCTAssertEqual(UpdateAllText.channelNote(result), "Each device stays on its own channel: OnePlus 11 on Beta, Xperia on Beta, this Mac on Stable.")
        XCTAssertEqual(UpdateAllText.help(result).components(separatedBy: "\n"),
                       ["OnePlus 11: 0.9.0-rr.3-beta.2 > beta.3", "Xperia: 0.9.0-rr.3-beta.2 > newest Beta, if newer", "This Mac: 0.9.0-rr.2 > 0.9.0-rr.3, restarts last"])
    }

    func testPlanIsHiddenWithoutAKnownUpdate() {
        let stale = UpdateAllPhone(id: "a", name: "OnePlus 11", connected: true, supportsUpdates: true, status: status(checkedAt: Date(timeIntervalSince1970: 0)))
        let result = plan([stale])
        XCTAssertEqual(result.targets.count, 1)
        XCTAssertFalse(result.visible, "only a stale check: nothing known to update")
        var manual = macCurrent
        manual.state = .manual
        XCTAssertEqual(plan([], local: manual).entries.last?.kind, .skipped(.byHand))
        XCTAssertEqual(UpdateAllText.summary(plan([], local: macReady)), "Updates this Mac")
        let one = UpdateAllPhone(id: "a", name: "OnePlus 11", connected: true, supportsUpdates: true, status: status(.available, target: "y"))
        XCTAssertEqual(UpdateAllText.summary(plan([one])), "Updates 1 connected phone")
        XCTAssertEqual(UpdateAllText.title(plan([one])), "Update ready for OnePlus 11")
    }

    // MARK: Run

    private func startedRun(local: Bool = true) -> (UpdateRun, [(deviceID: String, request: UpdateStartRequest)]) {
        let phones = [
            UpdateAllPhone(id: phone, name: "OnePlus 11", connected: true, supportsUpdates: true,
                           status: status(.available, target: "0.9.0-rr.3-beta.3", targetBuild: 903003)),
            UpdateAllPhone(id: tablet, name: "Pixel Tablet", connected: true, supportsUpdates: true,
                           status: status(.available, target: "0.9.0-rr.3-beta.3", targetBuild: 903003)),
        ]
        let started = UpdateRun.start(plan: plan(phones, local: local ? macReady : macCurrent), now: t0, newID: ids())!
        return (started.run, started.starts)
    }

    func testRunStartsEveryPhoneAndThisMacLast() {
        let (run, starts) = startedRun()
        XCTAssertEqual(starts.map(\.deviceID), [phone, tablet])
        XCTAssertTrue(starts.allSatisfy { !$0.request.retry })
        XCTAssertEqual(run.items.map(\.isLocal), [false, false, true])
        XCTAssertEqual(run.items[0].step, .starting)
        XCTAssertEqual(run.local?.step, .downloading(nil))
    }

    func testPhoneWalksToDoneAfterRestart() {
        let (initialRun, starts) = startedRun(local: false)
        var run = initialRun
        let request = starts[0].request
        run.result(from: phone, UpdateStartResult(requestID: "00000000-0000-4000-8000-000000000999"), now: t0)
        XCTAssertEqual(run.items[0].step, .starting, "another request's answer is ignored")
        run.result(from: phone, UpdateStartResult(requestID: request.requestID), now: t0.addingTimeInterval(1))
        XCTAssertEqual(run.items[0].step, .checking)
        var downloading = status(.downloading, target: "0.9.0-rr.3-beta.3", targetBuild: 903003)
        downloading.progress = 42
        run.status(from: phone, downloading, now: t0.addingTimeInterval(5))
        XCTAssertEqual(run.items[0].step, .downloading(42))
        XCTAssertEqual(UpdateAllText.step(run.items[0], countdownUntil: nil, now: t0), "Downloading 42%")
        run.status(from: phone, status(.installing, target: "0.9.0-rr.3-beta.3", targetBuild: 903003), now: t0.addingTimeInterval(30))
        XCTAssertEqual(run.items[0].step, .installing)
        run.disconnected(phone, now: t0.addingTimeInterval(31))
        XCTAssertEqual(run.items[0].step, .restarting)
        run.status(from: phone, status(app: "0.9.0-rr.3-beta.3", build: 903003), now: t0.addingTimeInterval(60))
        XCTAssertEqual(run.items[0].step, .done("0.9.0-rr.3-beta.3"))
    }

    func testRestartOnTheOldBuildIsNotAppliedAndNeverRetriedOnItsOwn() {
        let (initialRun, starts) = startedRun(local: false)
        var run = initialRun
        run.result(from: phone, UpdateStartResult(requestID: starts[0].request.requestID), now: t0)
        run.status(from: phone, status(.installing, target: "0.9.0-rr.3-beta.3", targetBuild: 903003), now: t0.addingTimeInterval(10))
        run.disconnected(phone, now: t0.addingTimeInterval(11))
        run.status(from: phone, status(), now: t0.addingTimeInterval(40))
        XCTAssertEqual(run.items[0].step, .notApplied)
        XCTAssertEqual(UpdateAllText.step(run.items[0], countdownUntil: nil, now: t0), "Update didn\u{2019}t apply")
        // Later statuses and ticks leave it alone: nothing is sent again on its own.
        run.status(from: phone, status(.available, target: "0.9.0-rr.3-beta.3", targetBuild: 903003), now: t0.addingTimeInterval(50))
        XCTAssertEqual(run.items[0].step, .notApplied)
        XCTAssertNil(run.retry(tablet, now: t0, newID: { "x" }), "a phone that did not fail has no Retry")
        XCTAssertEqual(run.tick(now: t0.addingTimeInterval(4000)), [])
        XCTAssertEqual(run.items[0].step, .notApplied)
        // Only Retry starts it again, marked as a retry.
        let retry = run.retry(phone, now: t0.addingTimeInterval(4100), newID: { "00000000-0000-4000-8000-0000000000aa" })
        XCTAssertEqual(retry, UpdateStartRequest(requestID: "00000000-0000-4000-8000-0000000000aa", retry: true))
        XCTAssertEqual(run.items[0].step, .starting)
    }

    func testRefusalsAndUpToDate() {
        let (initialRun, starts) = startedRun(local: false)
        var run = initialRun
        run.result(from: phone, UpdateStartResult(requestID: starts[0].request.requestID, refusal: .disabled), now: t0)
        XCTAssertEqual(run.items[0].step, .failed(.disabled))
        XCTAssertEqual(UpdateAllText.step(run.items[0], countdownUntil: nil, now: t0), "Didn\u{2019}t finish: updates from other devices are off there")
        run.result(from: tablet, UpdateStartResult(requestID: starts[1].request.requestID), now: t0)
        run.status(from: tablet, status(.checking), now: t0.addingTimeInterval(1))
        run.status(from: tablet, status(), now: t0.addingTimeInterval(3))
        XCTAssertEqual(run.items[1].step, .upToDate)
        XCTAssertTrue(run.finished)
        let capsule = UpdateAllText.capsule(run, now: t0.addingTimeInterval(4))
        XCTAssertEqual(capsule.label, "OnePlus 11: update didn\u{2019}t finish")
        XCTAssertEqual(capsule.action, .retry(phone))
    }

    func testStatusBeforeTheAnswerIsIgnored() {
        var (run, _) = startedRun(local: false)
        run.status(from: phone, status(), now: t0.addingTimeInterval(1))
        XCTAssertEqual(run.items[0].step, .starting)
    }

    func testTimeoutsAndSlowDevices() {
        let (initialRun, starts) = startedRun(local: false)
        var run = initialRun
        _ = run.tick(now: t0.addingTimeInterval(19))
        XCTAssertEqual(run.items[0].step, .starting)
        run.result(from: tablet, UpdateStartResult(requestID: starts[1].request.requestID), now: t0.addingTimeInterval(2))
        _ = run.tick(now: t0.addingTimeInterval(20))
        XCTAssertEqual(run.items[0].step, .failed(.noAnswer))
        XCTAssertNil(run.slowItem(now: t0.addingTimeInterval(179)))
        XCTAssertEqual(run.slowItem(now: t0.addingTimeInterval(180))?.id, tablet)
        XCTAssertEqual(UpdateAllText.capsule(run, now: t0.addingTimeInterval(240)).label, "Pixel Tablet is taking longer than usual \u{00B7} 4m")
        run.disconnected(tablet, now: t0.addingTimeInterval(200))
        _ = run.tick(now: t0.addingTimeInterval(379))
        XCTAssertEqual(run.items[1].step, .checking)
        _ = run.tick(now: t0.addingTimeInterval(380))
        XCTAssertEqual(run.items[1].step, .failed(.lostConnection))
    }

    func testRestartingTooLongFails() {
        let (initialRun, starts) = startedRun(local: false)
        var run = initialRun
        run.result(from: phone, UpdateStartResult(requestID: starts[0].request.requestID), now: t0)
        run.status(from: phone, status(.installing, target: "a", targetBuild: 903003), now: t0)
        run.disconnected(phone, now: t0.addingTimeInterval(1))
        _ = run.tick(now: t0.addingTimeInterval(900))
        XCTAssertEqual(run.items[0].step, .restarting)
        _ = run.tick(now: t0.addingTimeInterval(901))
        XCTAssertEqual(run.items[0].step, .failed(.noReturn))
        // It came back on the new build after all.
        run.status(from: phone, status(app: "0.9.0-rr.3-beta.3", build: 903003), now: t0.addingTimeInterval(950))
        XCTAssertEqual(run.items[0].step, .done("0.9.0-rr.3-beta.3"))
    }

    func testNeedsYouIsShownAndCountsAsHandedOver() {
        let (initialRun, starts) = startedRun()
        var run = initialRun
        run.result(from: phone, UpdateStartResult(requestID: starts[0].request.requestID), now: t0)
        run.result(from: tablet, UpdateStartResult(requestID: starts[1].request.requestID, refusal: .rateLimited), now: t0)
        run.status(from: phone, status(.needsUser, target: "0.9.0-rr.3-beta.3", targetBuild: 903003, reason: .confirm), now: t0.addingTimeInterval(20))
        XCTAssertEqual(run.items[0].step, .needsUser(.confirm))
        XCTAssertEqual(UpdateAllText.capsule(run, now: t0.addingTimeInterval(21)).label, "Waiting for you on OnePlus 11")
        XCTAssertEqual(UpdateAllText.needsUserDetail(run.items[0]), "Tap Update on OnePlus 11 to finish")
        XCTAssertTrue(run.phonesSettled)
    }

    func testThisMacCountsDownAfterThePhonesThenInstallsOrWaitsForLater() {
        let (initialRun, starts) = startedRun()
        var run = initialRun
        run.local(macReady, now: t0)
        XCTAssertEqual(run.local?.step, .ready)
        XCTAssertEqual(run.tick(now: t0.addingTimeInterval(1)), [])
        XCTAssertNil(run.countdownUntil, "phones first")
        for (index, start) in starts.enumerated() {
            let id = run.items[index].id
            run.result(from: id, UpdateStartResult(requestID: start.request.requestID), now: t0.addingTimeInterval(2))
            run.status(from: id, status(.installing, target: "0.9.0-rr.3-beta.3", targetBuild: 903003), now: t0.addingTimeInterval(3))
        }
        XCTAssertTrue(run.phonesSettled)
        XCTAssertEqual(run.tick(now: t0.addingTimeInterval(4)), [])
        XCTAssertEqual(run.countdownUntil, t0.addingTimeInterval(14))
        XCTAssertEqual(UpdateAllText.capsule(run, now: t0.addingTimeInterval(6.5)), UpdateAllText.Capsule(tone: .normal, label: "Restarting in 8 s", action: .later))

        var later = run
        later.later(now: t0.addingTimeInterval(7))
        XCTAssertEqual(later.local?.step, .later)
        XCTAssertNil(later.countdownUntil)
        XCTAssertEqual(later.tick(now: t0.addingTimeInterval(20)), [])
        XCTAssertTrue(later.installNow(now: t0.addingTimeInterval(30)))
        XCTAssertEqual(later.local?.step, .installing)

        XCTAssertEqual(run.tick(now: t0.addingTimeInterval(13)), [])
        XCTAssertEqual(run.tick(now: t0.addingTimeInterval(14)), [.installLocal])
        XCTAssertEqual(run.local?.step, .installing)
        XCTAssertEqual(UpdateAllText.capsule(run, now: t0.addingTimeInterval(14)).label, "Restarting\u{2026}")
    }

    func testRunSurvivesThisMacRelaunch() throws {
        let (initialRun, starts) = startedRun()
        var run = initialRun
        run.result(from: phone, UpdateStartResult(requestID: starts[0].request.requestID), now: t0)
        run.status(from: phone, status(.installing, target: "0.9.0-rr.3-beta.3", targetBuild: 903003), now: t0)
        run.local(macReady, now: t0)
        run.later(now: t0)
        XCTAssertTrue(run.installNow(now: t0.addingTimeInterval(1)))
        let data = try JSONEncoder().encode(run)
        var restored = try JSONDecoder().decode(UpdateRun.self, from: data)
        XCTAssertEqual(restored, run)
        var failed = restored
        restored.restored(installedApp: "0.9.0-rr.3", installedBuild: 903000, now: t0.addingTimeInterval(60))
        XCTAssertEqual(restored.local?.step, .done("0.9.0-rr.3"))
        XCTAssertEqual(restored.items[0].step, .restarting)
        failed.restored(installedApp: "0.9.0-rr.2", installedBuild: 902000, now: t0.addingTimeInterval(60))
        XCTAssertEqual(failed.local?.step, .notApplied)
    }

    func testAllUpdated() {
        let (initialRun, starts) = startedRun(local: false)
        var run = initialRun
        for (index, start) in starts.enumerated() {
            let id = run.items[index].id
            run.result(from: id, UpdateStartResult(requestID: start.request.requestID), now: t0)
            run.status(from: id, status(.installing, target: "b", targetBuild: 903003), now: t0)
            run.disconnected(id, now: t0)
            XCTAssertEqual(UpdateAllText.capsule(run, now: t0).label, index == 0 ? "0 of 2 updated" : "1 of 2 updated")
            run.status(from: id, status(app: "0.9.0-rr.3-beta.3", build: 903003), now: t0.addingTimeInterval(30))
        }
        XCTAssertEqual(UpdateAllText.capsule(run, now: t0.addingTimeInterval(31)), UpdateAllText.Capsule(tone: .done, label: "All updated", action: .dismiss))
    }

    // MARK: Driver

    @MainActor
    func testPeerRequestInstallsWithoutAsking() {
        let driver = InAppUpdateDriver()
        var installed: [String] = []
        driver.onWillInstall = { version, _ in installed.append(version) }
        var choice: SPUUserUpdateChoice?
        driver.showReady { choice = $0 }
        if case .ready = driver.flow {} else { XCTFail("the person here decides") }
        XCTAssertNil(choice)
        driver.later()

        driver.autoInstallUntil = Date().addingTimeInterval(60)
        driver.showReady { choice = $0 }
        XCTAssertEqual(choice, .install, "asked by a phone: no countdown, no prompt")
        if case .installing = driver.flow {} else { XCTFail("expected installing") }
        XCTAssertEqual(installed.count, 1)

        choice = nil
        driver.autoInstallUntil = Date().addingTimeInterval(-1)
        driver.showReady { choice = $0 }
        XCTAssertNil(choice, "the request expired")
        driver.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: 3001)) {}
        XCTAssertEqual(driver.failureReason, .safety)
        XCTAssertNil(driver.autoInstallUntil)
    }
}
