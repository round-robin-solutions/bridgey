package dev.bridgey.android.updates

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Update all devices automatically: the setting, the checks, the waits, Later, the lowest-ID rule and the run's hold. */
class AutoUpdateTest {
    private var now = 1_800_000_000_000L
    private val clock = { now }
    private val beta3 = "0.9.0-rr.3-beta.3"

    private fun status(
        state: UpdateState = UpdateState.CURRENT,
        build: Long = 903002,
        target: String? = null,
        targetBuild: Long? = null,
        reason: UpdateReason? = null,
        remoteStart: Boolean = true,
        auto: Boolean = false,
        busy: UpdateBusy? = null,
        platform: UpdatePlatform = UpdatePlatform.MACOS,
        checkedAt: Long = now - 60_000,
    ) = UpdateStatus(platform, "rr", "0.9.0-rr.3-beta.2", build, WireChannel.BETA, state, target, targetBuild, null, reason, remoteStart, checkedAt, auto, busy)

    private fun available(auto: Boolean = true, busy: UpdateBusy? = null, platform: UpdatePlatform = UpdatePlatform.ANDROID) =
        status(UpdateState.AVAILABLE, target = beta3, targetBuild = 903003, auto = auto, busy = busy, platform = platform)

    private fun facts(
        local: UpdateStatus = available(),
        localBusy: UpdateBusy? = null,
        peers: List<AutoPeer> = emptyList(),
        localId: String = "b-phone",
        enabled: Boolean = true,
        runActive: Boolean = false,
        updatingForPeer: Boolean = false,
        idle: Boolean = false,
    ) = AutoFacts(now, enabled, localId, "This phone", local, localBusy, peers, runActive, updatingForPeer, idle)

    private fun decide(facts: AutoFacts, memory: AutoMemory = AutoMemory()) = AutoUpdatePolicy.decide(facts, memory)

    // MARK: The setting and the checks

    @Test fun onByDefaultForBetaAndNightlyOffForStable() {
        assertFalse(AutoUpdateRules.enabled(null, WireChannel.STABLE))
        assertTrue(AutoUpdateRules.enabled(null, WireChannel.BETA))
        assertTrue(AutoUpdateRules.enabled(null, WireChannel.NIGHTLY))
    }

    @Test fun anExplicitChoiceSurvivesChannelChanges() {
        // No choice yet: it follows the channel as the person moves between channels.
        val channels = listOf(WireChannel.STABLE, WireChannel.NIGHTLY, WireChannel.BETA, WireChannel.STABLE)
        assertEquals(listOf(false, true, true, false), channels.map { AutoUpdateRules.enabled(null, it) })
        // Turned off on Nightly: stays off on every channel; turned on on Stable: stays on.
        assertEquals(listOf(false, false, false, false), channels.map { AutoUpdateRules.enabled(false, it) })
        assertEquals(listOf(true, true, true, true), channels.map { AutoUpdateRules.enabled(true, it) })
    }

    @Test fun atStartItWaitsAMinuteForPairedMacsToReconnect() {
        val t0 = 1_793_091_600_000L
        assertTrue(AutoUpdateRules.settling(t0, t0 + 5_000, listOf("mac"), emptySet()))
        assertFalse(AutoUpdateRules.settling(t0, t0 + 5_000, listOf("mac"), setOf("mac")))
        assertFalse("a Mac that stays away is left out after a minute", AutoUpdateRules.settling(t0, t0 + 60_000, listOf("mac"), emptySet()))
        assertFalse(AutoUpdateRules.settling(t0, t0 + 5_000, emptyList(), emptySet()))
    }

    @Test fun checksEvery30MinutesOn6HoursOnStableAndDailyOff() {
        assertEquals(30L * 60_000, AutoUpdateRules.checkInterval(true, WireChannel.BETA))
        assertEquals(30L * 60_000, AutoUpdateRules.checkInterval(true, WireChannel.NIGHTLY))
        assertEquals(6L * 60 * 60_000, AutoUpdateRules.checkInterval(true, WireChannel.STABLE))
        assertEquals(24L * 60 * 60_000, AutoUpdateRules.checkInterval(false, WireChannel.NIGHTLY))
        assertEquals(24L * 60 * 60_000, AutoUpdateRules.checkInterval(false, WireChannel.STABLE))
    }

    @Test fun wakingUpAndNetworkChangesCheckAtMostEvery10Minutes() {
        assertTrue(AutoUpdateRules.eventCheckAllowed(0, 0, now))
        assertFalse(AutoUpdateRules.eventCheckAllowed(now - 9 * 60_000, 0, now))
        assertFalse(AutoUpdateRules.eventCheckAllowed(now - 60L * 60_000, now - 9 * 60_000, now))
        assertTrue(AutoUpdateRules.eventCheckAllowed(now - 10 * 60_000, now - 11 * 60_000, now))
        // A clock set back does not block checks.
        assertTrue(AutoUpdateRules.eventCheckAllowed(now + 60_000, 0, now))
    }

    // MARK: Deciding

    @Test fun offStartsNothingAndForgets() {
        val step = decide(facts(enabled = false), AutoMemory(targetBuild = 903003, laterCount = 2))
        assertEquals(AutoDecision.Off, step.decision)
        assertEquals(AutoMemory(), step.memory)
    }

    @Test fun startsWhenThisPhoneHasANewerBuild() {
        val step = decide(facts())
        assertEquals(AutoDecision.Start(903003, now), step.decision)
        assertEquals(903003L, step.memory.targetBuild)
        assertEquals(now, step.memory.foundAt)
        assertEquals(AutoDecision.NothingToDo, decide(facts(local = status(platform = UpdatePlatform.ANDROID))).decision)
        assertEquals(
            AutoDecision.NotApplied,
            decide(facts(local = status(UpdateState.FAILED, reason = UpdateReason.NOT_APPLIED, target = beta3, targetBuild = 903003, platform = UpdatePlatform.ANDROID))).decision,
        )
    }

    @Test fun waitsForSomeoneBusyHereOrOnAPeerAndLooksAgainEveryFiveMinutes() {
        val first = decide(facts(localBusy = UpdateBusy.CALL))
        assertEquals(AutoDecision.Wait(UpdateBusy.CALL, null, now + AUTO_RECHECK_MILLIS), first.decision)
        assertEquals(AutoLog.Waiting(UpdateBusy.CALL, null), first.log)
        // The call ended a minute later: still waiting until the next look.
        now += 60_000
        val second = decide(facts(), first.memory)
        assertTrue(second.decision is AutoDecision.Wait)
        assertNull(second.log)
        now += AUTO_RECHECK_MILLIS
        assertTrue(decide(facts(), second.memory).decision is AutoDecision.Start)
        // A Mac's person is sharing their screen: wait, named.
        val peer = AutoPeer("a-mac", "Work Mac", status(busy = UpdateBusy.SCREEN_SHARE))
        val onPeer = decide(facts(peers = listOf(peer)))
        assertEquals(AutoDecision.Wait(UpdateBusy.SCREEN_SHARE, "Work Mac", now + AUTO_RECHECK_MILLIS), onPeer.decision)
        assertEquals(AutoLog.Waiting(UpdateBusy.SCREEN_SHARE, "Work Mac"), onPeer.log)
        // Still busy at the next look: the same wait is not logged again; something else is.
        now += AUTO_RECHECK_MILLIS
        val again = decide(facts(peers = listOf(peer)), onPeer.memory)
        assertTrue(again.decision is AutoDecision.Wait)
        assertNull(again.log)
        now += AUTO_RECHECK_MILLIS
        val call = decide(facts(peers = listOf(peer), localBusy = UpdateBusy.CALL), again.memory)
        // A call here comes first.
        assertEquals(AutoLog.Waiting(UpdateBusy.CALL, null), call.log)
    }

    @Test fun laterWaitsAnHourAndAfterThreeOnlyWhenIdle() {
        var memory = decide(facts()).memory
        repeat(AUTO_MAX_LATER) { index ->
            memory = memory.later(now)
            assertEquals(AutoDecision.Later(now + AUTO_LATER_MILLIS), decide(facts(), memory).decision)
            now += AUTO_LATER_MILLIS
            val next = decide(facts(), memory)
            if (index < AUTO_MAX_LATER - 1) assertTrue(next.decision is AutoDecision.Start)
            memory = next.memory
        }
        assertEquals(AutoDecision.WaitForIdle, decide(facts(), memory).decision)
        assertTrue(decide(facts(idle = true), memory).decision is AutoDecision.Start)
    }

    @Test fun aNewerBuildStartsAfresh() {
        val memory = decide(facts()).memory.later(now).later(now).later(now)
        now += AUTO_LATER_MILLIS
        assertEquals(AutoDecision.WaitForIdle, decide(facts(), memory).decision)
        val newer = status(UpdateState.AVAILABLE, target = "0.9.0-rr.3-beta.4", targetBuild = 903004, platform = UpdatePlatform.ANDROID)
        val step = decide(facts(local = newer), memory)
        assertEquals(AutoDecision.Start(903004, now), step.decision)
        assertEquals(0, step.memory.laterCount)
    }

    @Test fun theLowestIdWithTheSettingOnStartsAndTheOthersYield() {
        val leader = AutoPeer("a-mac", "Work Mac", status(UpdateState.AVAILABLE, target = beta3, targetBuild = 903003, auto = true))
        val step = decide(facts(peers = listOf(leader)))
        assertEquals(AutoDecision.Yield("Work Mac", now + AUTO_YIELD_MILLIS), step.decision)
        // A lower ID without the setting does not count.
        val manual = leader.copy(status = leader.status.copy(auto = false))
        assertTrue(decide(facts(peers = listOf(manual))).decision is AutoDecision.Start)
        // After 15 minutes this phone starts its own update.
        now += AUTO_YIELD_MILLIS
        assertTrue(decide(facts(peers = listOf(leader)), step.memory).decision is AutoDecision.Start)
        // A device with nothing of its own never runs the leader's update for it.
        val nothing = decide(facts(local = status(platform = UpdatePlatform.ANDROID), peers = listOf(leader)), step.memory)
        assertTrue(nothing.decision is AutoDecision.Yield)
    }

    @Test fun theLeaderRunsUpdatesForPeersWithTheSettingOn() {
        val local = status(platform = UpdatePlatform.ANDROID)
        val follower = AutoPeer("z-mac", "Studio Mac", status(UpdateState.AVAILABLE, target = beta3, targetBuild = 903003, auto = true))
        assertEquals(AutoDecision.Start(903003, now), decide(facts(local = local, localId = "a-phone", peers = listOf(follower))).decision)
        // Not without its setting, or when it cannot be started from here.
        assertEquals(AutoDecision.NothingToDo, decide(facts(local = local, localId = "a-phone", peers = listOf(follower.copy(status = follower.status.copy(auto = false))))).decision)
        assertEquals(AutoDecision.NothingToDo, decide(facts(local = local, localId = "a-phone", peers = listOf(follower.copy(status = follower.status.copy(remoteStart = false))))).decision)
    }

    @Test fun aRunOrAnUpdateForAPeerBlocks() {
        assertEquals(AutoDecision.Running, decide(facts(runActive = true)).decision)
        assertEquals(AutoDecision.Running, decide(facts(updatingForPeer = true)).decision)
    }

    @Test fun aBuildThatJustRanWaitsAnHourBeforeAnotherAutomaticRun() {
        val started = decide(facts()).memory
        val ran = started.ran(now)
        assertEquals(now, ran.ranAt)
        assertEquals(AutoMemory().ran(now), AutoMemory())
        assertEquals(AutoDecision.Retry(now + AUTO_RETRY_MILLIS), decide(facts(), ran).decision)
        now += AUTO_RETRY_MILLIS
        assertTrue(decide(facts(), ran).decision is AutoDecision.Start)
    }

    @Test fun theCommandLineRuleNeverStartsOverARunOrSomeoneBusy() {
        assertEquals(AutoUpdatePolicy.Blocked.RunActive, AutoUpdatePolicy.commandLineBlocked(facts(runActive = true)))
        assertEquals(AutoUpdatePolicy.Blocked.UpdatingForPeer, AutoUpdatePolicy.commandLineBlocked(facts(updatingForPeer = true)))
        assertEquals(AutoUpdatePolicy.Blocked.Busy(UpdateBusy.CALL, null), AutoUpdatePolicy.commandLineBlocked(facts(localBusy = UpdateBusy.CALL)))
        assertNull(AutoUpdatePolicy.commandLineBlocked(facts(enabled = false)))
    }

    // MARK: Memory

    @Test fun theMemoryRoundTripsAndAnythingUnreadableStartsAfresh() {
        val memory = AutoMemory(903003, now - 5, 2, now + 7, now - 9, now + 11, UpdateBusy.PHONE_FILES, "Work Mac", now - 13)
        assertEquals(memory, AutoMemory.fromJson(JSONObject(memory.toJson().toString())))
        assertEquals(AutoMemory(), AutoMemory.fromJson(JSONObject(AutoMemory().toJson().toString())))
        assertEquals(AutoMemory(), AutoMemory.fromJson(null))
        assertEquals(AutoMemory(), AutoMemory.fromJson(JSONObject("""{"targetBuild":"x"}""")))
        assertEquals(UpdateBusy.OTHER, AutoMemory.fromJson(JSONObject("""{"waiting":"juggling"}""")).waiting)
    }

    // MARK: Busy on the wire

    @Test fun theMostImportantBusyGoesOnTheWire() {
        assertEquals(UpdateBusy.CALL, UpdateBusy.mostImportant(setOf(UpdateBusy.TRANSFER, UpdateBusy.CALL, UpdateBusy.SETUP)))
        assertEquals(UpdateBusy.PHONE_FILES, UpdateBusy.mostImportant(setOf(UpdateBusy.TRANSFER, UpdateBusy.PHONE_FILES)))
        assertNull(UpdateBusy.mostImportant(emptySet()))
        assertEquals(UpdateBusy.OTHER, UpdateBusy.fromWire("knitting"))
    }

    @Test fun theNewFieldsRoundTripAndStayOutWhenUnset() {
        val busyStatus = status(UpdateState.AVAILABLE, target = beta3, targetBuild = 903003, auto = true, busy = UpdateBusy.REMOTE_CONTROL)
        val payload = updateStatusPayload(busyStatus)
        assertEquals(true, payload.get("auto"))
        assertEquals("remote_control", payload.get("busy"))
        assertEquals(busyStatus, decodeUpdateStatus(payload.toString().toByteArray()))
        val plain = updateStatusPayload(status())
        assertFalse(plain.has("auto"))
        assertFalse(plain.has("busy"))
        // An older build's status reads as not automatic and not busy; an unknown busy still counts as busy.
        assertEquals(false, decodeUpdateStatus(plain.toString().toByteArray())!!.auto)
        val unknown = JSONObject(plain.toString()).put("busy", "juggling")
        assertEquals(UpdateBusy.OTHER, decodeUpdateStatus(unknown.toString().toByteArray())!!.busy)
        // A wrong type is malformed.
        assertNull(decodeUpdateStatus(JSONObject(plain.toString()).put("auto", "yes").toString().toByteArray()))
        val start = UpdateStart("5b0c9e2a-7d41-4c3f-8e5a-1f2b3c4d5e6f", retry = false, auto = true)
        assertEquals(start, decodeUpdateStart(updateStartPayload(start).toString().toByteArray()))
        assertFalse(updateStartPayload(start.copy(auto = false)).has("auto"))
    }

    // MARK: The receiving device

    private val start = UpdateStart("5b0c9e2a-7d41-4c3f-8e5a-1f2b3c4d5e6f", retry = false)

    @Test fun anAutomaticStartFindsThePersonBusyAndIsRefusedATappedOneIsNot() {
        val facts = UpdateGateFacts(remoteStartOn = true, updaterAvailable = true, busy = false, notApplied = null, offeredBuild = 903003, personBusy = UpdateBusy.CALL)
        assertEquals(UpdateRefusal.BUSY, UpdateStartGate(clock).decide("mac", start.copy(auto = true), facts))
        assertNull(UpdateStartGate(clock).decide("mac", start, facts))
        assertNull(UpdateStartGate(clock).decide("mac", start.copy(auto = true), facts.copy(personBusy = null)))
        assertTrue(AutoStartRule.refusesBusy(start.copy(auto = true), UpdateBusy.TRANSFER))
        assertFalse(AutoStartRule.refusesBusy(start, UpdateBusy.TRANSFER))
    }

    // MARK: Planning and the run

    @Test fun peersThatSaidUpToDateBeforeThisBuildWasFoundCheckAgain() {
        val local = available()
        val early = PeerUpdateInfo("a", "Work Mac", true, true, status(checkedAt = now - 10 * 60_000))
        val late = PeerUpdateInfo("b", "MacBook Pro", true, true, status(checkedAt = now - 60_000))
        val plain = planUpdateAll(local, "This phone", listOf(early, late), now)
        assertEquals(listOf("MacBook Pro", "Work Mac"), plain.upToDate.take(2))
        val refreshed = planUpdateAll(local, "This phone", listOf(early, late), now, refreshBefore = now - 5 * 60_000)
        assertEquals(listOf("Work Mac", "This phone"), refreshed.targets.map { it.name })
        assertNull(refreshed.targets.first().to)
        assertEquals(listOf("MacBook Pro"), refreshed.upToDate)
    }

    private class FakeEffects : UpdateRunEffects {
        val starts = mutableListOf<Pair<String, UpdateStart>>()
        var committed = 0
        private var counter = 0
        override fun sendStart(deviceId: String, start: UpdateStart): Boolean {
            starts += deviceId to start
            return true
        }
        override fun prepareLocal() = Unit
        override fun commitLocal() { committed++ }
        override fun newRequestId(): String = "00000000-0000-4000-8000-%012d".format(++counter)
    }

    private fun plan() = planUpdateAll(
        available(),
        "This phone",
        listOf(PeerUpdateInfo("a", "Work Mac", true, true, status(UpdateState.AVAILABLE, target = beta3, targetBuild = 903003))),
        now,
    )

    /** Starts a run with the Mac done and this phone ready. */
    private fun readyRun(auto: Boolean, effects: FakeEffects = FakeEffects()): UpdateRunMachine {
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run", auto = auto)
        machine.onResult("a", UpdateResult(effects.starts.last().second.requestId, UpdateResultStatus.ACCEPTED))
        machine.onStatus("a", status(build = 903003))
        machine.onLocalStatus(status(UpdateState.READY, target = beta3, targetBuild = 903003, platform = UpdatePlatform.ANDROID))
        return machine
    }

    @Test fun automaticStartsSayAutoAndRetriesDoNot() {
        val effects = FakeEffects()
        val machine = UpdateRunMachine(clock, effects)
        machine.start(plan(), "run", auto = true)
        assertTrue(effects.starts.single().second.auto)
        machine.onResult("a", UpdateResult(effects.starts.last().second.requestId, UpdateResultStatus.REFUSED, UpdateRefusal.BUSY))
        assertEquals(RunFailure.BUSY, machine.run!!.items.first { it.deviceId == "a" }.failure)
        machine.retry("a")
        assertTrue(effects.starts.last().second.retry)
        assertFalse(effects.starts.last().second.auto)
        val tapped = FakeEffects()
        UpdateRunMachine(clock, tapped).start(plan(), "run2")
        assertFalse(tapped.starts.single().second.auto)
    }

    @Test fun anAutomaticRunCountsDownAMinuteATappedOneTenSeconds() {
        val auto = readyRun(auto = true)
        assertEquals(now + 60_000, auto.run!!.restartAt)
        assertEquals(RunSummary.Countdown(60), summarizeRun(auto.run!!, now))
        assertEquals(now + UPDATE_COUNTDOWN_MILLIS, readyRun(auto = false).run!!.restartAt)
    }

    @Test fun someoneBusyHoldsTheRestartAtOnceAndAnAutomaticRunLooksAgainInFiveMinutes() {
        val effects = FakeEffects()
        val machine = readyRun(auto = true, effects)
        now += 30_000
        machine.busy(UpdateBusy.CALL)
        assertNull(machine.run!!.restartAt)
        assertEquals(RunSummary.Held(UpdateBusy.CALL), summarizeRun(machine.run!!, now))
        // The call ended: still held until the next look, and never installed meanwhile.
        now += 60_000
        machine.busy(null)
        machine.tick()
        assertEquals(0, effects.committed)
        assertEquals(RunSummary.Held(UpdateBusy.CALL), summarizeRun(machine.run!!, now))
        now += AUTO_RECHECK_MILLIS
        machine.busy(null)
        assertEquals(now + AUTO_COUNTDOWN_MILLIS, machine.run!!.restartAt)
        now += AUTO_COUNTDOWN_MILLIS
        machine.tick()
        assertEquals(1, effects.committed)
    }

    @Test fun aTappedRunGoesOnAsSoonAsNobodyIsBusy() {
        val machine = readyRun(auto = false)
        machine.busy(UpdateBusy.TRANSFER)
        assertNull(machine.run!!.restartAt)
        now += 1_000
        machine.busy(null)
        assertEquals(now + UPDATE_COUNTDOWN_MILLIS, machine.run!!.restartAt)
    }

    @Test fun laterInAHeldRunStopsIt() {
        val effects = FakeEffects()
        val machine = readyRun(auto = true, effects)
        machine.busy(UpdateBusy.SCREEN_SHARE)
        machine.later()
        now += AUTO_RECHECK_MILLIS
        machine.busy(null)
        machine.tick()
        assertEquals(0, effects.committed)
        assertTrue(machine.run!!.finished)
        assertEquals(RunSummary.ReadyLater, summarizeRun(machine.run!!, now))
    }

    @Test fun anAutomaticRunSurvivesARestartAsAutomatic() {
        val machine = readyRun(auto = true)
        val restored = restoreUpdateRun(JSONObject(machine.run!!.toJson().toString()), beta3, 903003, now)!!
        assertTrue(restored.auto)
        assertEquals(AUTO_COUNTDOWN_MILLIS, restored.countdownMillis)
        assertFalse(restoreUpdateRun(JSONObject(readyRun(auto = false).run!!.toJson().toString()), beta3, 903003, now)!!.auto)
    }
}
