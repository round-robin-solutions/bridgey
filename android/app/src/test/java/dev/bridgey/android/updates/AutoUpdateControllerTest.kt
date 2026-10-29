package dev.bridgey.android.updates

import dev.bridgey.android.activity.ActivityKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The automatic run's glue: memory kept across restarts, the activity stream entries, the last run, and the notice model. */
class AutoUpdateControllerTest {
    private var now = 1_800_000_000_000L
    private val clock = { now }
    private val beta3 = "0.9.0-rr.3-beta.3"

    private class MapStore : AutoStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String): String? = values[key]
        override fun write(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    private data class Entry(val kind: ActivityKind, val deviceId: String?, val name: String, val content: String?)

    private inner class FakeEffects(var plan: UpdatePlan? = null) : AutoUpdateController.Effects {
        val entries = mutableListOf<Entry>()
        val runs = mutableListOf<Long>()
        override fun startRun(refreshBefore: Long): UpdatePlan? {
            runs += refreshBefore
            return plan
        }
        override fun record(kind: ActivityKind, deviceId: String?, deviceName: String, content: String?) {
            entries += Entry(kind, deviceId, deviceName, content)
        }
    }

    private fun status(
        state: UpdateState = UpdateState.CURRENT,
        build: Long = 903002,
        target: String? = null,
        targetBuild: Long? = null,
        busy: UpdateBusy? = null,
        remoteStart: Boolean = true,
        platform: UpdatePlatform = UpdatePlatform.MACOS,
    ) = UpdateStatus(platform, "rr", "0.9.0-rr.3-beta.2", build, WireChannel.BETA, state, target, targetBuild, null, null, remoteStart, now - 60_000, busy = busy)

    private val local = status(UpdateState.AVAILABLE, target = beta3, targetBuild = 903003, platform = UpdatePlatform.ANDROID)

    private fun facts(localBusy: UpdateBusy? = null, peers: List<AutoPeer> = emptyList(), runActive: Boolean = false) =
        AutoFacts(now, true, "b-phone", "This phone", local, localBusy, peers, runActive, updatingForPeer = false, idle = false)

    private fun plan(vararg peers: PeerUpdateInfo) = planUpdateAll(local, "This phone", peers.toList(), now)

    @Test fun startsTheRunAndNamesEverySkippedDeviceButOnesWithoutAStatus() {
        val effects = FakeEffects(
            plan(
                PeerUpdateInfo("w", "Work Mac", true, true, status(UpdateState.AVAILABLE, target = beta3, targetBuild = 903003, remoteStart = false)),
                PeerUpdateInfo("s", "Studio Mac", false, true, null),
                PeerUpdateInfo("q", "Quiet Mac", true, true, null),
            ),
        )
        val controller = AutoUpdateController(clock, MapStore(), effects)
        assertEquals(AutoDecision.Start(903003, now), controller.evaluate(facts()))
        assertEquals(listOf(now), effects.runs)
        assertEquals(
            listOf(
                Entry(ActivityKind.UPDATE_AUTO_SKIPPED, "s", "Studio Mac", "offline"),
                Entry(ActivityKind.UPDATE_AUTO_SKIPPED, "w", "Work Mac", "remote_off"),
            ),
            effects.entries,
        )
        assertFalse(controller.pending)
    }

    @Test fun aWaitIsLoggedOnceWithTheDeviceAndKeptAcrossARestart() {
        val store = MapStore()
        val effects = FakeEffects()
        val controller = AutoUpdateController(clock, store, effects)
        val peer = AutoPeer("w", "Work Mac", status(busy = UpdateBusy.CALL))
        assertTrue(controller.evaluate(facts(peers = listOf(peer))) is AutoDecision.Wait)
        assertTrue(controller.pending)
        now += 60_000
        controller.evaluate(facts(peers = listOf(peer)))
        assertEquals(listOf(Entry(ActivityKind.UPDATE_AUTO_WAITING, "w", "Work Mac", "call")), effects.entries)
        // A new process remembers the wait: the next look is still five minutes after the first.
        val restarted = AutoUpdateController(clock, store, FakeEffects())
        assertEquals(controller.memory, restarted.memory)
        assertTrue(restarted.evaluate(facts()) is AutoDecision.Wait)
        assertTrue(effects.runs.isEmpty())
    }

    @Test fun laterIsRememberedAcrossARestart() {
        val store = MapStore()
        val controller = AutoUpdateController(clock, store, FakeEffects())
        // The automatic run started for this build (the fake starts nothing), then Later on its notice.
        assertTrue(controller.evaluate(facts()) is AutoDecision.Start)
        controller.evaluate(facts(runActive = true))
        controller.later(903003)
        val restarted = AutoUpdateController(clock, store, FakeEffects())
        assertEquals(AutoDecision.Later(now + AUTO_LATER_MILLIS), restarted.evaluate(facts()))
        assertTrue(restarted.pending)
    }

    private fun item(id: String, name: String, step: RunStep, failure: RunFailure? = null, platform: UpdatePlatform = UpdatePlatform.MACOS) =
        RunItem(id, name, "0.9.0-rr.3-beta.2", 903002, beta3, 903003, WireChannel.BETA, platform, step, failure = failure, newApp = if (step == RunStep.DONE) beta3 else null)

    @Test fun anAutomaticRunThatEndsIsRecordedOnceWithItsFailures() {
        val store = MapStore()
        val effects = FakeEffects()
        val controller = AutoUpdateController(clock, store, effects)
        controller.evaluate(facts())
        controller.evaluate(facts(runActive = true))
        val run = UpdateRun(
            "run", now - 60_000,
            listOf(
                item("m", "MacBook Pro", RunStep.DONE),
                item("w", "Work Mac", RunStep.FAILED, RunFailure.NO_ANSWER),
                item("x", "Mac mini", RunStep.NOT_APPLIED),
                item(LOCAL_DEVICE_ID, "This phone", RunStep.READY, platform = UpdatePlatform.ANDROID),
            ),
            later = true, auto = true,
        )
        controller.runEnded(run, 903003)
        controller.runEnded(run, 903003)
        assertEquals(AutoRunRecord(now, beta3, 1, 4, 2, later = true), controller.lastRun)
        assertEquals(
            listOf(
                Entry(ActivityKind.UPDATE_AUTO_FAILED, "w", "Work Mac", "no_answer"),
                Entry(ActivityKind.UPDATE_AUTO_FAILED, "x", "Mac mini", AUTO_FAILED_NOT_APPLIED),
            ),
            effects.entries,
        )
        assertEquals(now, controller.memory.ranAt)
        // Settings still shows it after a restart.
        assertEquals(controller.lastRun, AutoUpdateController(clock, store, FakeEffects()).lastRun)
        assertEquals(controller.lastRun, AutoRunRecord.fromJson(controller.lastRun!!.toJson().toString()))
        // A tapped run is not an automatic one, but what it left on offer still waits before an automatic run.
        val tapped = AutoUpdateController(clock, MapStore(), FakeEffects())
        tapped.runEnded(run.copy(id = "tapped", auto = false), 903003)
        assertNull(tapped.lastRun)
        assertEquals(AutoDecision.Retry(now + AUTO_RETRY_MILLIS), tapped.evaluate(facts()))
    }

    @Test fun laterOnATappedRunPutsTheAutomaticUpdateOffToo() {
        val controller = AutoUpdateController(clock, MapStore(), FakeEffects())
        // A tapped run was going: the memory never saw this build.
        controller.evaluate(facts(runActive = true))
        controller.later(903003)
        assertEquals(AutoDecision.Later(now + AUTO_LATER_MILLIS), controller.evaluate(facts()))
        controller.later(null)
        assertEquals(1, controller.memory.laterCount)
    }

    @Test fun thisPhoneUpdatedAutomaticallySaysSoOnceAfterItsRestart() {
        val store = MapStore()
        val effects = FakeEffects()
        val controller = AutoUpdateController(clock, store, effects)
        val run = UpdateRun("run", now - 60_000, listOf(item(LOCAL_DEVICE_ID, "This phone", RunStep.DONE, platform = UpdatePlatform.ANDROID)), auto = true)
        controller.restored(run, 903003, beta3, "This phone")
        controller.restored(run, 903003, beta3, "This phone")
        controller.restored(run.copy(auto = false), 903003, beta3, "This phone")
        assertEquals(listOf(Entry(ActivityKind.UPDATE_AUTO_DONE, null, "This phone", beta3)), effects.entries)
    }

    @Test fun anAutomaticStartFromAMacSaysWhoAndThenUpdatedAutomatically() {
        val store = MapStore()
        val effects = FakeEffects()
        val controller = AutoUpdateController(clock, store, effects)
        controller.peerStartAccepted("w", "Work Mac", UpdateStart("5b0c9e2a-7d41-4c3f-8e5a-1f2b3c4d5e6f", retry = false, auto = true), 903002)
        assertEquals(now, controller.peerStartAt)
        assertEquals(listOf(Entry(ActivityKind.UPDATE_AUTO_STARTED_BY, "w", "Work Mac", null)), effects.entries)
        // Bridgey restarted into the new build.
        now += 2 * 60_000
        val restarted = AutoUpdateController(clock, store, effects)
        restarted.settleMarker(903003, beta3, "This phone")
        restarted.settleMarker(903003, beta3, "This phone")
        assertEquals(Entry(ActivityKind.UPDATE_AUTO_DONE, null, "This phone", beta3), effects.entries.last())
        assertEquals(2, effects.entries.size)
        // A tapped start leaves no marker; a marker that never led to a newer build expires.
        val other = MapStore()
        val quiet = FakeEffects()
        AutoUpdateController(clock, other, quiet).peerStartAccepted("w", "Work Mac", UpdateStart("5b0c9e2a-7d41-4c3f-8e5a-1f2b3c4d5e6f", retry = false), 903002)
        assertTrue(quiet.entries.isEmpty())
        assertNull(other.read(AutoUpdateController.KEY_MARKER))
        AutoUpdateController(clock, other, quiet).peerStartAccepted("w", "Work Mac", UpdateStart("5b0c9e2a-7d41-4c3f-8e5a-1f2b3c4d5e6f", retry = false, auto = true), 903002)
        now += AutoUpdateController.MARKER_LIFETIME_MILLIS
        AutoUpdateController(clock, other, quiet).settleMarker(903002, "0.9.0-rr.3-beta.2", "This phone")
        assertNull(other.read(AutoUpdateController.KEY_MARKER))
    }

    @Test fun aHeldAutomaticRunLogsWhoItWaitsForOnce() {
        val effects = FakeEffects()
        val controller = AutoUpdateController(clock, MapStore(), effects)
        val ready = UpdateRun(
            "run", now,
            listOf(item("m", "MacBook Pro", RunStep.DONE), item(LOCAL_DEVICE_ID, "This phone", RunStep.READY, platform = UpdatePlatform.ANDROID)),
            auto = true, hold = UpdateBusy.TRANSFER,
        )
        val peers = listOf(AutoPeer("m", "MacBook Pro", status(build = 903003)))
        controller.runLook(ready, UpdateBusy.TRANSFER to null, peers, "This phone")
        controller.runLook(ready, UpdateBusy.TRANSFER to null, peers, "This phone")
        controller.runLook(ready.copy(hold = UpdateBusy.CALL), UpdateBusy.CALL to "MacBook Pro", peers, "This phone")
        assertEquals(
            listOf(
                Entry(ActivityKind.UPDATE_AUTO_WAITING, null, "This phone", "transfer"),
                Entry(ActivityKind.UPDATE_AUTO_WAITING, "m", "MacBook Pro", "call"),
            ),
            effects.entries,
        )
        // Not while this phone is still downloading, and never for a tapped run.
        val quiet = FakeEffects()
        val other = AutoUpdateController(clock, MapStore(), quiet)
        other.runLook(ready.copy(items = ready.items.map { if (it.isLocal) it.copy(step = RunStep.DOWNLOADING) else it }), UpdateBusy.CALL to null, peers, "This phone")
        other.runLook(ready.copy(auto = false), UpdateBusy.CALL to null, peers, "This phone")
        assertTrue(quiet.entries.isEmpty())
    }

    @Test fun settingsSaysWhatItWaitsFor() {
        assertEquals(AutoCondition.Waiting(UpdateBusy.CALL, "Work Mac"), autoCondition(AutoDecision.Wait(UpdateBusy.CALL, "Work Mac", now), null, null, now))
        assertEquals(AutoCondition.PutOff(now + 5), autoCondition(AutoDecision.Later(now + 5), null, null, now))
        assertEquals(AutoCondition.IdleOnly, autoCondition(AutoDecision.WaitForIdle, null, null, now))
        assertEquals(AutoCondition.Yielding("Work Mac"), autoCondition(AutoDecision.Yield("Work Mac", now), null, null, now))
        assertEquals(AutoCondition.Retrying(now + 9), autoCondition(AutoDecision.Retry(now + 9), null, null, now))
        assertNull(autoCondition(AutoDecision.NothingToDo, null, null, now))
        val held = UpdateRun(
            "run", now,
            listOf(item("m", "MacBook Pro", RunStep.DONE), item(LOCAL_DEVICE_ID, "This phone", RunStep.READY, platform = UpdatePlatform.ANDROID)),
            auto = true, hold = UpdateBusy.CALL,
        )
        assertEquals(AutoCondition.Waiting(UpdateBusy.CALL, "MacBook Pro"), autoCondition(AutoDecision.Running, held, UpdateBusy.CALL to "MacBook Pro", now))
        assertNull(autoCondition(AutoDecision.Running, held.copy(hold = null), null, now))
        assertEquals(30L * 60_000, AutoUpdateView(on = true, channel = WireChannel.NIGHTLY).checkEvery)
        assertEquals(24L * 60 * 60_000, AutoUpdateView(supported = false, on = true, channel = WireChannel.NIGHTLY).checkEvery)
    }

    @Test fun theNoticeShowsTheVersionWhoGoesFirstAndTheCountdown() {
        val run = UpdateRun(
            "run", now,
            listOf(item("m", "MacBook Pro", RunStep.CHECKING), item(LOCAL_DEVICE_ID, "This phone", RunStep.DOWNLOADING, platform = UpdatePlatform.ANDROID)),
            auto = true,
        )
        assertEquals(AutoNotice(beta3, listOf("MacBook Pro"), true, null, null, false), AutoNotice.of(run, now))
        val counting = run.copy(items = listOf(item("m", "MacBook Pro", RunStep.DONE), item(LOCAL_DEVICE_ID, "This phone", RunStep.READY, platform = UpdatePlatform.ANDROID)), restartAt = now + 60_000)
        assertEquals(now + 60_000, AutoNotice.of(counting, now)!!.restartAt)
        assertEquals(UpdateBusy.CALL, AutoNotice.of(counting.copy(restartAt = null, hold = UpdateBusy.CALL), now)!!.held)
        // Gone for a tapped run, after Later, and when the run is over.
        assertNull(AutoNotice.of(run.copy(auto = false), now))
        assertNull(AutoNotice.of(counting.copy(restartAt = null, later = true), now))
        assertNull(AutoNotice.of(null, now))
    }
}
