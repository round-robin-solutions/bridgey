package dev.bridgey.android.updates

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Update all: the receiver's gate, the not-applied rule, the planner and the run (docs/protocol.md "Update all"). */
class UpdateAllTest {
    private var now = 1_800_000_000_000L
    private val clock = { now }

    private fun status(
        state: UpdateState = UpdateState.CURRENT,
        app: String = "0.9.0-rr.3-beta.2",
        build: Long = 903002,
        channel: WireChannel = WireChannel.BETA,
        target: String? = null,
        targetBuild: Long? = null,
        reason: UpdateReason? = null,
        remoteStart: Boolean = true,
        checkedAt: Long = now - 60_000,
        platform: UpdatePlatform = UpdatePlatform.MACOS,
        progress: Int? = null,
    ) = UpdateStatus(platform, "rr", app, build, channel, state, target, targetBuild, progress, reason, remoteStart, checkedAt)

    private val beta3 = "0.9.0-rr.3-beta.3"

    // MARK: Gate

    private fun facts(
        on: Boolean = true,
        available: Boolean = true,
        busy: Boolean = false,
        notApplied: NotApplied? = null,
        offered: Long? = 903003,
    ) = UpdateGateFacts(on, available, busy, notApplied, offered)

    private val start = UpdateStart("5b0c9e2a-7d41-4c3f-8e5a-1f2b3c4d5e6f", retry = false)

    @Test fun gateRefusesWhenSwitchedOffOrManual() {
        val gate = UpdateStartGate(clock)
        assertEquals(UpdateRefusal.DISABLED, gate.decide("mac", start, facts(on = false)))
        assertEquals(UpdateRefusal.MANUAL, gate.decide("mac", start, facts(available = false)))
        // Neither counted toward the rate: the next real start is accepted.
        assertNull(gate.decide("mac", start, facts()))
    }

    @Test fun gateRateLimitsEachDevice() {
        val gate = UpdateStartGate(clock)
        assertNull(gate.decide("mac", start, facts()))
        now += 10_000
        assertEquals(UpdateRefusal.RATE_LIMITED, gate.decide("mac", start, facts()))
        // Another Mac is not limited by the first.
        assertNull(gate.decide("other", start, facts()))
        now += 20_000
        assertNull(gate.decide("mac", start, facts()))
        repeat(3) {
            now += 31_000
            assertNull(gate.decide("mac", start, facts()))
        }
        now += 31_000
        // Five accepted within the hour: the sixth is refused, and refused starts do not count.
        assertEquals(UpdateRefusal.RATE_LIMITED, gate.decide("mac", start, facts()))
        now += 60L * 60 * 1000
        assertNull(gate.decide("mac", start, facts()))
    }

    @Test fun gateNeverRetriesAVersionThatDidNotApplyUnlessThePersonAsks() {
        val gate = UpdateStartGate(clock)
        val marker = NotApplied(903003, beta3)
        assertEquals(UpdateRefusal.NOT_APPLIED, gate.decide("mac", start, facts(notApplied = marker)))
        now += 31_000
        assertEquals(UpdateRefusal.NOT_APPLIED, gate.decide("other", start, facts(notApplied = marker, offered = null)))
        now += 31_000
        assertNull(gate.decide("mac", start.copy(retry = true), facts(notApplied = marker)))
        now += 31_000
        // A newer build than the one that failed is a new update.
        assertNull(gate.decide("other", start, facts(notApplied = marker, offered = 903004)))
    }

    @Test fun gateSaysBusy() {
        assertEquals(UpdateRefusal.BUSY, UpdateStartGate(clock).decide("mac", start, facts(busy = true)))
    }

    // MARK: Not applied

    @Test fun pendingInstallSettlesAtStart() {
        val pending = PendingInstall(903003, beta3, now - 60_000)
        assertNull(settlePendingInstall(null, 903002, now))
        assertNull(settlePendingInstall(pending, 903003, now))
        assertNull(settlePendingInstall(pending, 903004, now))
        assertEquals(NotApplied(903003, beta3), settlePendingInstall(pending, 903002, now))
        assertNull(settlePendingInstall(pending.copy(at = now - NOT_APPLIED_WINDOW_MILLIS), 903002, now))
        assertNull(settlePendingInstall(pending.copy(at = now + 5_000), 903002, now))
        assertEquals(NotApplied(1, "x"), notAppliedStillMatches(NotApplied(1, "x"), null))
        assertEquals(NotApplied(1, "x"), notAppliedStillMatches(NotApplied(1, "x"), 1))
        assertNull(notAppliedStillMatches(NotApplied(1, "x"), 2))
    }

    // MARK: Planner

    private fun peer(id: String, name: String, status: UpdateStatus?, connected: Boolean = true, supports: Boolean = true) =
        PeerUpdateInfo(id, name, connected, supports, status)

    private val localCurrent = status(platform = UpdatePlatform.ANDROID, app = "0.9.0-rr.3-beta.3", build = 903003)

    @Test fun planSkipsEachDeviceItCannotUpdateAndSaysWhy() {
        val plan = planUpdateAll(
            localCurrent, "This phone",
            listOf(
                peer("a", "Away Mac", status(), connected = false),
                peer("b", "Upstream Mac", null, supports = false),
                peer("c", "Quiet Mac", null),
                peer("d", "Dev Mac", status(state = UpdateState.MANUAL)),
                peer("e", "Failed Mac", status(state = UpdateState.FAILED, reason = UpdateReason.NOT_APPLIED, target = beta3, targetBuild = 903003)),
                peer("f", "Locked Mac", status(state = UpdateState.AVAILABLE, target = beta3, targetBuild = 903003, remoteStart = false)),
                peer("g", "Fresh Mac", status()),
            ),
            now,
        )
        assertEquals(
            listOf(
                "Away Mac" to UpdateSkipReason.OFFLINE, "Dev Mac" to UpdateSkipReason.BY_HAND, "Failed Mac" to UpdateSkipReason.NOT_APPLIED,
                "Locked Mac" to UpdateSkipReason.REMOTE_OFF, "Quiet Mac" to UpdateSkipReason.NO_STATUS, "Upstream Mac" to UpdateSkipReason.BY_HAND,
            ),
            plan.skipped.map { it.name to it.reason },
        )
        assertEquals(listOf("Fresh Mac", "This phone"), plan.upToDate)
        assertTrue(plan.targets.isEmpty())
        assertFalse(plan.visible)
    }

    @Test fun planPutsPeersFirstAndThisPhoneLast() {
        val local = status(state = UpdateState.AVAILABLE, platform = UpdatePlatform.ANDROID, target = beta3, targetBuild = 903003)
        val plan = planUpdateAll(
            local, "This phone",
            listOf(
                peer("w", "Work Mac", status(state = UpdateState.AVAILABLE, target = beta3, targetBuild = 903003)),
                peer("m", "MacBook Pro", status(state = UpdateState.DOWNLOADING, target = beta3, targetBuild = 903003, progress = 10)),
                peer("s", "Studio", status(state = UpdateState.FAILED, reason = UpdateReason.DOWNLOAD)),
            ),
            now,
        )
        assertEquals(listOf("MacBook Pro", "Studio", "Work Mac", "This phone"), plan.targets.map { it.name })
        assertEquals(LOCAL_DEVICE_ID, plan.targets.last().deviceId)
        assertTrue(plan.includesLocal)
        assertEquals(3, plan.peerTargets.size)
        assertTrue(plan.visible)
        assertFalse(plan.channelsDiffer)
        assertNull(plan.targets.first { it.name == "Studio" }.to)
    }

    @Test fun aPeerThatHasNotCheckedForAnHourChecksAndUpdatesIfNewer() {
        val plan = planUpdateAll(
            localCurrent, "This phone",
            listOf(
                peer("o", "Old check", status(checkedAt = now - UPDATE_STALE_CHECK_MILLIS, channel = WireChannel.STABLE, app = "0.9.0-rr.2", build = 902000)),
                peer("n", "Never", status(checkedAt = 0)),
                peer("u", "Update", status(state = UpdateState.AVAILABLE, target = beta3, targetBuild = 903003)),
            ),
            now,
        )
        assertEquals(listOf("Never", "Old check", "Update"), plan.targets.map { it.name })
        assertNull(plan.targets[0].to)
        assertTrue(plan.channelsDiffer)
        assertTrue(plan.visible)
        // Only stale peers: nothing known to update, so Update all is not offered.
        val stale = planUpdateAll(localCurrent, "This phone", listOf(peer("n", "Never", status(checkedAt = 0))), now)
        assertFalse(stale.visible)
    }

    @Test fun thisPhoneIsSkippedWhenItCannotUpdateAndIncludedAfterAFailure() {
        val manual = planUpdateAll(status(state = UpdateState.MANUAL, platform = UpdatePlatform.ANDROID), "This phone", emptyList(), now)
        assertEquals(listOf(PlanSkip(LOCAL_DEVICE_ID, "This phone", UpdateSkipReason.BY_HAND)), manual.skipped)
        val failed = planUpdateAll(
            status(state = UpdateState.FAILED, reason = UpdateReason.NOT_APPLIED, target = beta3, targetBuild = 903003, platform = UpdatePlatform.ANDROID),
            "This phone", emptyList(), now,
        )
        // The person is sitting here: Update all on this phone may try it again.
        assertEquals(listOf(LOCAL_DEVICE_ID), failed.targets.map { it.deviceId })
    }

    @Test fun deviceRowsListThisPhoneFirst() {
        val rows = deviceUpdateRows(
            localCurrent, "This phone",
            listOf(peer("z", "Zed", null, connected = false), peer("a", "Alpha", status(state = UpdateState.AVAILABLE, remoteStart = false, target = beta3))),
        )
        assertEquals(listOf("This phone", "Alpha", "Zed"), rows.map { it.name })
        assertEquals(listOf(null, UpdateSkipReason.REMOTE_OFF, UpdateSkipReason.OFFLINE), rows.map { it.skip })
    }

    // MARK: The run

    private class FakeEffects : UpdateRunEffects {
        val starts = mutableListOf<Pair<String, UpdateStart>>()
        var prepared = 0
        var committed = 0
        var connected = true
        private var counter = 0
        override fun sendStart(deviceId: String, start: UpdateStart): Boolean {
            starts += deviceId to start
            return connected
        }
        override fun prepareLocal() { prepared++ }
        override fun commitLocal() { committed++ }
        override fun newRequestId(): String = "00000000-0000-4000-8000-%012d".format(++counter)
    }

    private fun plan(withLocal: Boolean = true) = planUpdateAll(
        if (withLocal) status(state = UpdateState.AVAILABLE, platform = UpdatePlatform.ANDROID, target = beta3, targetBuild = 903003) else localCurrent,
        "This phone",
        listOf(
            peer("a", "MacBook Pro", status(state = UpdateState.AVAILABLE, target = beta3, targetBuild = 903003)),
            peer("b", "Work Mac", status(state = UpdateState.AVAILABLE, target = beta3, targetBuild = 903003)),
        ),
        now,
    )

    private fun UpdateRunMachine.item(id: String) = run!!.items.first { it.deviceId == id }

    private fun accepted(effects: FakeEffects, id: String) =
        UpdateResult(effects.starts.last { it.first == id }.second.requestId, UpdateResultStatus.ACCEPTED)

    @Test fun startsEveryPeerAtOnceAndPreparesThisPhone() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        assertEquals(listOf("a", "b"), effects.starts.map { it.first })
        assertTrue(effects.starts.none { it.second.retry })
        assertEquals(1, effects.prepared)
        assertEquals(RunStep.STARTING, machine.item("a").step)
        assertEquals(RunStep.DOWNLOADING, machine.item(LOCAL_DEVICE_ID).step)
    }

    @Test fun aPeerGoesFromAcceptedToDoneThroughItsRestart() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onResult("a", accepted(effects, "a"))
        assertEquals(RunStep.CHECKING, machine.item("a").step)
        machine.onStatus("a", status(state = UpdateState.DOWNLOADING, target = beta3, targetBuild = 903003, progress = 40))
        assertEquals(RunStep.DOWNLOADING to 40, machine.item("a").let { it.step to it.progress })
        machine.onStatus("a", status(state = UpdateState.INSTALLING, target = beta3, targetBuild = 903003))
        assertEquals(RunStep.INSTALLING, machine.item("a").step)
        machine.onDisconnected("a")
        assertEquals(RunStep.RESTARTING, machine.item("a").step)
        machine.onStatus("a", status(app = beta3, build = 903003))
        assertEquals(RunStep.DONE to beta3, machine.item("a").let { it.step to it.newApp })
    }

    @Test fun aPeerBackOnItsOldBuildDidNotApplyAndIsNeverRetriedOnItsOwn() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onResult("a", accepted(effects, "a"))
        machine.onStatus("a", status(state = UpdateState.INSTALLING, target = beta3, targetBuild = 903003))
        machine.onDisconnected("a")
        machine.onStatus("a", status(state = UpdateState.FAILED, reason = UpdateReason.NOT_APPLIED, target = beta3, targetBuild = 903003))
        assertEquals(RunStep.NOT_APPLIED, machine.item("a").step)
        val before = effects.starts.size
        repeat(30) {
            now += 60_000
            machine.tick()
            machine.onStatus("a", status())
        }
        assertEquals(before, effects.starts.size)
        assertEquals(RunStep.NOT_APPLIED, machine.item("a").step)
        // Back on the old build and only "current": also not applied.
        val other = UpdateRunMachine(clock, FakeEffects().also { it.connected = true })
        other.start(plan(), "run2")
        other.onResult("b", UpdateResult(other.item("b").requestId!!, UpdateResultStatus.ACCEPTED))
        other.onStatus("b", status(state = UpdateState.INSTALLING, target = beta3, targetBuild = 903003))
        other.onDisconnected("b")
        other.onStatus("b", status())
        assertEquals(RunStep.NOT_APPLIED, other.item("b").step)
    }

    @Test fun retryIsThePersonsAndSaysSo() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onResult("a", UpdateResult(effects.starts[0].second.requestId, UpdateResultStatus.REFUSED, UpdateRefusal.NOT_APPLIED))
        assertEquals(RunStep.NOT_APPLIED, machine.item("a").step)
        assertTrue(machine.item("a").retryable)
        now += 5_000
        machine.retry("a")
        assertEquals(RunStep.STARTING, machine.item("a").step)
        assertTrue(effects.starts.last().second.retry)
        assertEquals(now, machine.item("a").startedAt)
        // A stale answer to the first request is ignored.
        machine.onResult("a", UpdateResult(effects.starts[0].second.requestId, UpdateResultStatus.REFUSED, UpdateRefusal.BUSY))
        assertEquals(RunStep.STARTING, machine.item("a").step)
        // Retry does nothing for a device that is fine, or for this phone.
        machine.retry("b")
        machine.retry(LOCAL_DEVICE_ID)
        assertEquals(3, effects.starts.size)
    }

    @Test fun refusalsAndCheckResults() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onResult("a", UpdateResult(effects.starts[0].second.requestId, UpdateResultStatus.REFUSED, UpdateRefusal.DISABLED))
        assertEquals(RunStep.FAILED to RunFailure.DISABLED, machine.item("a").let { it.step to it.failure })
        machine.onResult("b", accepted(effects, "b"))
        // Checked and found nothing newer: already up to date.
        machine.onStatus("b", status(state = UpdateState.CHECKING))
        machine.onStatus("b", status())
        assertEquals(RunStep.UP_TO_DATE, machine.item("b").step)
    }

    @Test fun waitsForThePersonOnAPeer() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onResult("a", accepted(effects, "a"))
        machine.onStatus("a", status(state = UpdateState.NEEDS_USER, reason = UpdateReason.CONFIRM, target = beta3, targetBuild = 903003))
        assertEquals(RunStep.NEEDS_USER, machine.item("a").step)
        assertEquals(RunSummary.WaitingFor("MacBook Pro"), summarizeRun(machine.run!!, now))
    }

    @Test fun timeoutsMarkFailuresAndSlowDevices() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(withLocal = false), "run")
        now += UPDATE_RESULT_TIMEOUT_MILLIS
        machine.tick()
        assertEquals(RunFailure.NO_ANSWER, machine.item("a").failure)

        val second = UpdateRunMachine(clock, effects)
        second.start(plan(withLocal = false), "run2")
        second.onResult("a", UpdateResult(second.item("a").requestId!!, UpdateResultStatus.ACCEPTED))
        second.onResult("b", UpdateResult(second.item("b").requestId!!, UpdateResultStatus.ACCEPTED))
        second.onStatus("a", status(state = UpdateState.DOWNLOADING, target = beta3, targetBuild = 903003))
        now += UPDATE_SLOW_AFTER_MILLIS
        assertTrue(second.item("a").isSlow(now))
        assertEquals(RunSummary.Slow("MacBook Pro", 3), summarizeRun(second.run!!, now))
        second.onDisconnected("b")
        now += UPDATE_LOST_AFTER_MILLIS
        second.tick()
        assertEquals(RunFailure.LOST_CONNECTION, second.item("b").failure)
        second.onStatus("a", status(state = UpdateState.INSTALLING, target = beta3, targetBuild = 903003))
        second.onDisconnected("a")
        now += UPDATE_RETURN_TIMEOUT_MILLIS
        second.tick()
        assertEquals(RunFailure.NO_RETURN, second.item("a").failure)
        assertTrue(second.run!!.finished)
    }

    @Test fun aStartThatCannotBeSentFailsAtOnce() {
        val effects = FakeEffects().apply { connected = false }
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(withLocal = false), "run")
        assertEquals(RunFailure.LOST_CONNECTION, machine.item("a").failure)
    }

    @Test fun thisPhoneInstallsLastAfterACountdown() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onLocalStatus(status(state = UpdateState.DOWNLOADING, platform = UpdatePlatform.ANDROID, progress = 50, target = beta3, targetBuild = 903003))
        machine.onLocalStatus(status(state = UpdateState.READY, platform = UpdatePlatform.ANDROID, target = beta3, targetBuild = 903003))
        // Ready, but the Macs are still going: no countdown yet.
        assertNull(machine.run!!.restartAt)
        for (id in listOf("a", "b")) {
            machine.onResult(id, accepted(effects, id))
            machine.onStatus(id, status(state = UpdateState.INSTALLING, target = beta3, targetBuild = 903003))
        }
        assertEquals(now + UPDATE_COUNTDOWN_MILLIS, machine.run!!.restartAt)
        now += 3_000
        assertEquals(RunSummary.Countdown(7), summarizeRun(machine.run!!, now))
        machine.tick()
        assertEquals(0, effects.committed)
        now += 7_000
        machine.tick()
        assertEquals(1, effects.committed)
        assertEquals(RunStep.INSTALLING, machine.item(LOCAL_DEVICE_ID).step)
        assertEquals(RunSummary.Restarting, summarizeRun(machine.run!!, now))
    }

    @Test fun laterStopsTheCountdown() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onLocalStatus(status(state = UpdateState.READY, platform = UpdatePlatform.ANDROID, target = beta3, targetBuild = 903003))
        for (id in listOf("a", "b")) {
            machine.onResult(id, accepted(effects, id))
            machine.onStatus(id, status(app = beta3, build = 903003))
        }
        assertTrue(machine.run!!.restartAt != null)
        machine.later()
        now += 60_000
        machine.tick()
        assertEquals(0, effects.committed)
        assertNull(machine.run!!.restartAt)
        assertEquals(RunSummary.ReadyLater, summarizeRun(machine.run!!, now))
        assertTrue(machine.run!!.finished)
    }

    @Test fun summaryNamesAVersionThatDidNotApply() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(withLocal = false), "run")
        machine.onResult("a", accepted(effects, "a"))
        machine.onStatus("a", status(app = beta3, build = 903003))
        machine.onResult("b", UpdateResult(machine.item("b").requestId!!, UpdateResultStatus.REFUSED, UpdateRefusal.NOT_APPLIED))
        assertEquals(RunSummary.Failed("Work Mac", 1, notApplied = true), summarizeRun(machine.run!!, now))
    }

    @Test fun summaryCountsAndFailures() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(withLocal = false), "run")
        assertEquals(RunSummary.Progress(0, 2), summarizeRun(machine.run!!, now))
        machine.onResult("a", accepted(effects, "a"))
        machine.onStatus("a", status(app = beta3, build = 903003))
        assertEquals(RunSummary.Progress(1, 2), summarizeRun(machine.run!!, now))
        machine.onResult("b", UpdateResult(machine.item("b").requestId!!, UpdateResultStatus.REFUSED, UpdateRefusal.RATE_LIMITED))
        assertEquals(RunSummary.Failed("Work Mac", 1), summarizeRun(machine.run!!, now))
        machine.retry("b")
        machine.onResult("b", UpdateResult(machine.item("b").requestId!!, UpdateResultStatus.ACCEPTED))
        machine.onStatus("b", status(app = beta3, build = 903003))
        assertEquals(RunSummary.AllUpdated(2), summarizeRun(machine.run!!, now))
    }

    @Test fun theRunSurvivesThisPhoneRestarting() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run")
        machine.onResult("a", accepted(effects, "a"))
        machine.onStatus("a", status(app = beta3, build = 903003))
        machine.onLocalStatus(status(state = UpdateState.INSTALLING, platform = UpdatePlatform.ANDROID, target = beta3, targetBuild = 903003))
        val saved = JSONObject(machine.run!!.toJson().toString())
        now += 20_000
        val updated = restoreUpdateRun(saved, beta3, 903003, now)!!
        assertEquals(RunStep.DONE to beta3, updated.local!!.let { it.step to it.newApp })
        assertEquals(RunStep.DONE, updated.items.first { it.deviceId == "a" }.step)
        // Work Mac was still starting: it counts as disconnected until its next status.
        assertEquals(now, updated.items.first { it.deviceId == "b" }.disconnectedAt)
        val notApplied = restoreUpdateRun(saved, "0.9.0-rr.3-beta.2", 903002, now)!!
        assertEquals(RunStep.NOT_APPLIED, notApplied.local!!.step)
        assertNull(restoreUpdateRun(saved, beta3, 903003, now + UPDATE_RUN_LIFETIME_MILLIS))
        assertNull(restoreUpdateRun(JSONObject("{}"), beta3, 903003, now))
        // A restored run picks up where it was.
        val resumed = UpdateRunMachine(clock, FakeEffects(), updated)
        resumed.onStatus("b", status(app = beta3, build = 903003))
        assertEquals(RunStep.DONE, resumed.item("b").step)
    }
}
