package dev.bridgey.android.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallMediaControllerTest {
    private class Clock : CallMediaScheduler {
        private data class Task(val at: Long, val run: () -> Unit, var cancelled: Boolean = false)
        private val tasks = mutableListOf<Task>()
        var now = 0L
        override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
            val entry = Task(now + delayMs, task)
            tasks += entry
            return { entry.cancelled = true }
        }
        fun advance(ms: Long = 0) {
            val until = now + ms
            while (true) {
                val next = tasks.filter { !it.cancelled && it.at <= until }.minByOrNull { it.at } ?: break
                tasks.remove(next); now = next.at; next.run()
            }
            now = until
        }
    }

    private class Platform : CallMediaPlatform {
        val sessions = linkedMapOf<String, CallMediaSession>()
        var availability = CallMediaAvailability.AVAILABLE
        var confirmPause = true
        var unknownMusic = false
        var truncated = false
        var music = CallMediaMusicState(6, false, "speaker", 1, false, true)
        var observer: (() -> Unit)? = null
        val paused = mutableListOf<String>()
        val played = mutableListOf<String>()
        var muteCount = 0
        var restoreCount = 0
        var observes = 0
        var stops = 0
        var canMute = true
        var observeDenied = false

        fun add(id: String = "music", state: CallMediaPlayback = CallMediaPlayback.PLAYING,
                canPause: Boolean = true, canPlay: Boolean = true, media: Boolean = true, local: Boolean = true) {
            sessions[id] = CallMediaSession(id, state, canPause, canPlay, media, 1, local, "$id/item")
        }
        fun state(id: String, state: CallMediaPlayback) {
            sessions.getValue(id).let { sessions[id] = it.copy(playback = state, revision = it.revision + 1) }
            changed()
        }
        fun changed() { observer?.invoke() }
        override fun observe(changed: () -> Unit): () -> Unit {
            if (observeDenied) throw SecurityException()
            observer = changed; observes += 1
            return { observer = null; stops += 1 }
        }
        override fun snapshot() = CallMediaSnapshot(
            availability,
            sessions.values.toList(),
            music.copy(active = unknownMusic || sessions.values.any { it.localPlayback && it.playback == CallMediaPlayback.PLAYING }),
            truncated,
        )
        override fun pause(sessionId: String): Boolean {
            paused += sessionId
            if (confirmPause) state(sessionId, CallMediaPlayback.PAUSED)
            return true
        }
        override fun play(sessionId: String): Boolean {
            played += sessionId
            state(sessionId, CallMediaPlayback.PLAYING)
            return true
        }
        override fun muteMusic(expected: CallMediaMusicState): CallMediaMusicState? {
            if (!canMute) return null
            muteCount += 1
            music = music.copy(muted = true, volume = 0, revision = music.revision + 1)
            changed()
            return snapshot().music
        }
        override fun restoreMusic(owned: CallMediaMusicState, previous: CallMediaMusicState): Boolean {
            if (music.volume != owned.volume || music.muted != owned.muted || music.route != owned.route || music.revision != owned.revision) return false
            restoreCount += 1
            music = music.copy(volume = previous.volume, muted = previous.muted, revision = music.revision + 1)
            changed()
            return true
        }
        fun changeVolume(volume: Int, muted: Boolean = volume == 0) {
            music = music.copy(volume = volume, muted = muted, revision = music.revision + 1)
            changed()
        }
    }

    private val clock = Clock()
    private val platform = Platform()
    private val results = mutableListOf<CallMediaResult>()
    private val controller = CallMediaController(platform, clock, now = { clock.now }, onResult = results::add)

    private fun start(policy: CallMediaPolicy = CallMediaPolicy(), localCall: Boolean = false) {
        controller.updateCalls(setOf("phone/call-1"), policy, localCall)
        clock.advance()
    }
    private fun finish() { controller.updateCalls(emptySet(), CallMediaPolicy(), false); clock.advance() }

    @Test fun defaultsAndPolicyKeysMatchTheChosenBehavior() {
        assertEquals("pause_then_mute", CallMediaPolicy().mode.key)
        assertEquals("restore_and_resume", CallMediaPolicy().restoration.key)
        assertEquals(setOf("pause_then_mute", "pause_only", "mute_only"), CallMediaMode.entries.map { it.key }.toSet())
        assertEquals(setOf("restore_and_resume", "restore_sound", "leave_as_is"), CallMediaRestoration.entries.map { it.key }.toSet())
    }

    @Test fun pausesEveryPlayingMediaSessionAndOnlyResumesOwnedSessions() {
        platform.add("music"); platform.add("video")
        platform.add("already-paused", CallMediaPlayback.PAUSED)
        start()

        assertEquals(listOf("music", "video"), platform.paused)
        assertEquals(2, controller.result.paused)
        assertEquals(CallMediaPhase.APPLIED, controller.result.phase)
        assertEquals(0, platform.muteCount)
        finish()

        assertEquals(listOf("music", "video"), platform.played)
        assertEquals(1, platform.stops)
        assertEquals(CallMediaPhase.IDLE, controller.result.phase)
    }

    @Test fun duplicateSnapshotsAndOverlappingCallsNeverQuietAgainOrRestoreEarly() {
        platform.add(); start()
        platform.state("music", CallMediaPlayback.PLAYING)
        clock.advance()
        controller.updateCalls(setOf("phone/call-1", "phone/call-2"), CallMediaPolicy(), false)
        controller.updateCalls(setOf("phone/call-2"), CallMediaPolicy(), false)
        clock.advance()

        assertEquals(listOf("music"), platform.paused)
        assertTrue(platform.played.isEmpty())
        assertTrue(CallMediaReason.MANUAL_PLAYBACK in controller.result.reasons)
        finish()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun lastCallAloneEndsTheQuietInterval() {
        platform.add(); start()
        controller.updateCalls(setOf("a", "b"), CallMediaPolicy(), false)
        controller.updateCalls(setOf("b"), CallMediaPolicy(), false)
        assertTrue(platform.played.isEmpty())
        finish()
        assertEquals(listOf("music"), platform.played)
    }

    @Test fun waitsForConfirmationBeforeUsingMuteFallback() {
        platform.add(); platform.confirmPause = false
        start()
        assertEquals(CallMediaPhase.PENDING, controller.result.phase)
        clock.advance(749)
        assertEquals(0, platform.muteCount)
        clock.advance(1)

        assertEquals(1, platform.muteCount)
        assertTrue(controller.result.muted)
        assertEquals(0, controller.result.paused)
        finish()
        assertEquals(1, platform.restoreCount)
        assertTrue("an unconfirmed pause never authorizes resume", platform.played.isEmpty())
    }

    @Test fun observedPauseBeforeTheDeadlineAvoidsMute() {
        platform.add(); platform.confirmPause = false
        start()
        clock.advance(400)
        platform.state("music", CallMediaPlayback.PAUSED)
        clock.advance()
        clock.advance(1_000)

        assertEquals(0, platform.muteCount)
        assertEquals(1, controller.result.paused)
    }

    @Test fun explicitPauseOnlyNeverMutesAnUncooperativePlayer() {
        platform.add(canPause = false)
        start(CallMediaPolicy(mode = CallMediaMode.PAUSE_ONLY))
        assertTrue(platform.paused.isEmpty())
        assertEquals(0, platform.muteCount)
        assertEquals(CallMediaPhase.PARTIAL, controller.result.phase)
        assertEquals(1, controller.result.unsupported)
    }

    @Test fun muteOnlyDoesNotPauseAndNormalCallEndRestoresOwnedSound() {
        platform.add()
        start(CallMediaPolicy(mode = CallMediaMode.MUTE_ONLY))
        assertTrue(platform.paused.isEmpty())
        assertEquals(1, platform.muteCount)
        assertTrue(controller.result.muted)
        finish()
        assertEquals(1, platform.restoreCount)
        assertTrue(platform.played.isEmpty())
    }

    @Test fun manualPauseThenPlayOfTheSameMutedSessionRestoresSoundWithoutQuietingAgain() {
        platform.add()
        val policy = CallMediaPolicy(mode = CallMediaMode.MUTE_ONLY)
        start(policy)
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance()
        assertEquals(0, platform.restoreCount)

        platform.state("music", CallMediaPlayback.PLAYING); clock.advance()
        controller.updateCalls(setOf("phone/call-1", "phone/call-2"), policy, false)
        clock.advance()

        assertEquals(1, platform.restoreCount)
        assertEquals(1, platform.muteCount)
        assertFalse(controller.result.muted)
        assertTrue(CallMediaReason.MANUAL_PLAYBACK in controller.result.reasons)
        assertTrue(platform.paused.isEmpty())
        finish()
        assertEquals(1, platform.restoreCount)
        assertTrue(platform.played.isEmpty())
    }

    @Test fun manualPauseThenPlayOfTheSameFallbackMutedSessionRestoresSoundWithoutAnotherPause() {
        platform.add(); platform.confirmPause = false
        start(); clock.advance(750)
        assertEquals(1, platform.muteCount)
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance()
        assertEquals(0, platform.restoreCount)

        platform.state("music", CallMediaPlayback.PLAYING); clock.advance()
        controller.updateCalls(setOf("phone/call-1", "phone/call-2"), CallMediaPolicy(), false)
        clock.advance()

        assertEquals(1, platform.restoreCount)
        assertEquals(1, platform.muteCount)
        assertEquals(listOf("music"), platform.paused)
        assertFalse(controller.result.muted)
        assertTrue(CallMediaReason.MANUAL_PLAYBACK in controller.result.reasons)
        finish()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun muteCanCoverMusicWithoutAnExposedMediaSessionButReportsStreamScope() {
        platform.unknownMusic = true
        start()
        assertEquals(1, platform.muteCount)
        assertTrue(controller.result.muted)
        assertEquals(0, controller.result.paused)
    }

    @Test fun restartingNonSessionMusicRestoresSoundAndDoesNotMuteAgain() {
        platform.unknownMusic = true
        start()
        platform.unknownMusic = false; platform.changed(); clock.advance()
        assertEquals(0, platform.restoreCount)
        platform.unknownMusic = true; platform.changed(); clock.advance()

        assertEquals(1, platform.restoreCount)
        assertEquals(1, platform.muteCount)
        assertTrue(CallMediaReason.MANUAL_PLAYBACK in controller.result.reasons)
        assertFalse(controller.result.muted)
        finish()
        assertEquals(1, platform.restoreCount)
    }

    @Test fun pausingAnExposedSessionDoesNotHideRemainingNonSessionPlayback() {
        platform.add()
        platform.unknownMusic = true
        start()

        assertEquals(listOf("music"), platform.paused)
        assertEquals(1, controller.result.paused)
        assertEquals(0, platform.muteCount)
        assertEquals(CallMediaPhase.PARTIAL, controller.result.phase)
        assertEquals(1, controller.result.unsupported)
        assertTrue(CallMediaReason.UNEXPOSED_PLAYBACK in controller.result.reasons)
        controller.updateCalls(setOf("phone/call-1", "phone/call-2"), CallMediaPolicy(), false)
        assertEquals(CallMediaPhase.PARTIAL, controller.result.phase)
        assertEquals(0, platform.muteCount)
    }

    @Test fun localCallAndCommunicationSafetyNeverPermitFallbackMute() {
        platform.add(canPause = false)
        start(localCall = true)
        assertEquals(0, platform.muteCount)
        assertTrue(CallMediaReason.CALL_AUDIO_PROTECTED in controller.result.reasons)
    }

    @Test fun unsafeOrAmbiguousOutputNeverGetsMuted() {
        platform.add(canPause = false)
        platform.music = platform.music.copy(safeToMute = false)
        start()
        assertEquals(0, platform.muteCount)
        assertEquals(CallMediaPhase.PARTIAL, controller.result.phase)
    }

    @Test fun protectedCallSessionsAreNeverPausedOrSilencedWithStreamMute() {
        platform.add("call", media = false)
        platform.add("video", canPause = false)
        start()
        assertTrue(platform.paused.isEmpty())
        assertEquals(0, platform.muteCount)
        assertTrue(CallMediaReason.CALL_AUDIO_PROTECTED in controller.result.reasons)
    }

    @Test fun remoteRendererCannotBeClaimedMutedByChangingThePhoneStream() {
        platform.add("cast", canPause = false, local = false)
        start()
        assertEquals(0, platform.muteCount)
        assertEquals(1, controller.result.unsupported)
        assertEquals(CallMediaPhase.PARTIAL, controller.result.phase)
    }

    @Test fun aSessionLimitNeverPermitsBlindStreamMute() {
        platform.add(canPause = false); platform.truncated = true
        start()
        assertEquals(0, platform.muteCount)
        assertTrue(CallMediaReason.SESSION_LIMIT in controller.result.reasons)
    }

    @Test fun newManualPlaybackIsAllowedAndReleasesOwnedMute() {
        platform.add(canPause = false); start()
        assertEquals(1, platform.muteCount)
        platform.add("new-video")
        platform.changed(); clock.advance()
        assertEquals(1, platform.restoreCount)
        assertEquals(1, platform.muteCount)
        assertTrue(platform.paused.isEmpty())
        assertFalse(controller.result.muted)
        finish()
        assertEquals(1, platform.restoreCount)
    }

    @Test fun startingAnExistingPreviouslyPausedSessionAlsoCountsAsManualPlayback() {
        platform.add(canPause = false)
        platform.add("paused-video", CallMediaPlayback.PAUSED)
        start()
        platform.state("paused-video", CallMediaPlayback.PLAYING); clock.advance()
        assertEquals(1, platform.restoreCount)
        assertEquals(1, platform.muteCount)
    }

    @Test fun noNewSessionIsPausedAfterInitialQuietingEvenUnderAnotherCall() {
        platform.add(); start()
        platform.add("new-video")
        platform.changed(); clock.advance()
        controller.updateCalls(setOf("phone/call-1", "phone/call-2"), CallMediaPolicy(), false)
        assertEquals(listOf("music"), platform.paused)
    }

    @Test fun volumeChangesGiveUpMuteOwnershipEvenWhenTheVolumeReturnsToTheMutedValue() {
        platform.add(canPause = false); start()
        platform.changeVolume(4, false); clock.advance()
        platform.changeVolume(0, true); clock.advance()
        finish()
        assertEquals(0, platform.restoreCount)
        assertTrue(platform.music.muted)
    }

    @Test fun routeChangesPreventRestoringTheOldRouteVolume() {
        platform.add(canPause = false); start()
        platform.music = platform.music.copy(route = "headphones", revision = platform.music.revision + 1)
        platform.changed(); clock.advance()
        finish()
        assertEquals(0, platform.restoreCount)
    }

    @Test fun aLocalCallStartingLaterRestoresOwnedSoundImmediately() {
        platform.add(canPause = false); start()
        controller.updateCalls(setOf("phone/call-1", "local/call"), CallMediaPolicy(), true)
        assertEquals(1, platform.restoreCount)
        assertEquals(1, platform.muteCount)
    }

    @Test fun soundOnlyChoiceLeavesBridgeyPausedSessionsPaused() {
        platform.add(); start(CallMediaPolicy(restoration = CallMediaRestoration.RESTORE_SOUND))
        controller.release(CallMediaReleaseReason.CALLS_ENDED)
        assertTrue(platform.played.isEmpty())
    }

    @Test fun leaveAsIsChoiceRetainsOwnedMuteAtNormalCallEnd() {
        platform.add(canPause = false)
        start(CallMediaPolicy(restoration = CallMediaRestoration.LEAVE_AS_IS))
        controller.release(CallMediaReleaseReason.CALLS_ENDED)
        assertEquals(0, platform.restoreCount)
    }

    @Test fun settingsCanChangeTheAfterCallChoiceWithoutRepeatingTheQuietOperation() {
        platform.add(); start()
        controller.updatePolicy(CallMediaPolicy(restoration = CallMediaRestoration.RESTORE_SOUND))
        controller.release(CallMediaReleaseReason.CALLS_ENDED)
        assertTrue(platform.played.isEmpty())
        assertEquals(listOf("music"), platform.paused)
    }

    @Test fun stopSeekAndReplacementOfAPausedSessionNeverAuthorizeAutoResume() {
        platform.add(); start()
        platform.sessions["music"] = platform.sessions.getValue("music").copy(revision = 10)
        platform.changed(); clock.advance()
        finish()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun cachedPlayingPositionIsProjectedToCaptureTimeBeforeOwnedPauseRestoration() {
        clock.advance(10_000)
        platform.add(); platform.confirmPause = false
        platform.sessions["music"] = platform.sessions.getValue("music").copy(
            positionMs = callMediaPosition(1_000, 1f, 1_000, clock.now, playing = true),
            positionTimeMs = clock.now,
            playbackSpeed = 1f,
        )
        start()
        clock.advance(400)
        platform.sessions["music"] = platform.sessions.getValue("music").copy(
            playback = CallMediaPlayback.PAUSED,
            positionMs = 10_400,
            positionTimeMs = clock.now,
            playbackSpeed = 0f,
            revision = 2,
        )
        platform.changed(); clock.advance()
        assertEquals(1, controller.result.paused)
        clock.advance(10_000)
        finish()

        assertEquals(listOf("music"), platform.played)
        assertEquals(0, platform.muteCount)
    }

    @Test fun aRealSeekBeyondExpectedPlaybackProgressNeverAuthorizesAutoResume() {
        clock.advance(10_000)
        platform.add(); platform.confirmPause = false
        platform.sessions["music"] = platform.sessions.getValue("music").copy(
            positionMs = callMediaPosition(1_000, 1f, 1_000, clock.now, playing = true),
            positionTimeMs = clock.now,
            playbackSpeed = 1f,
        )
        start()
        clock.advance(400)
        platform.sessions["music"] = platform.sessions.getValue("music").copy(
            playback = CallMediaPlayback.PAUSED,
            positionMs = 30_400,
            positionTimeMs = clock.now,
            playbackSpeed = 0f,
            revision = 2,
        )
        platform.changed(); clock.advance(); finish()

        assertTrue(platform.played.isEmpty())
    }

    @Test fun cachedPositionProjectionHonorsSpeedAndKeepsPausedSamplesFixed() {
        assertEquals(19_000L, callMediaPosition(1_000, 2f, 1_000, 10_000, playing = true))
        assertEquals(5_000L, callMediaPosition(10_000, -1f, 1_000, 6_000, playing = true))
        assertEquals(0L, callMediaPosition(1_000, -1f, 1_000, 5_000, playing = true))
        assertEquals(1_000L, callMediaPosition(1_000, 1f, 1_000, 10_000, playing = false))
        assertEquals(-1L, callMediaPosition(-1, 1f, 1_000, 10_000, playing = true))
        assertEquals(-1L, callMediaPosition(1_000, Float.NaN, 1_000, 10_000, playing = true))
        assertEquals(-1L, callMediaPosition(1_000, Float.POSITIVE_INFINITY, 1_000, 10_000, playing = true))
        assertEquals(-1L, callMediaPosition(1_000, 1f, -1, 10_000, playing = true))
        assertEquals(-1L, callMediaPosition(1_000, 1f, 10_000, 1_000, playing = true))
    }

    @Test fun destroyedOrStoppedPlayersNeverGetPlayedAtCallEnd() {
        platform.add("destroyed"); platform.add("stopped"); start()
        platform.sessions.remove("destroyed")
        platform.state("stopped", CallMediaPlayback.STOPPED)
        clock.advance(); finish()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun aPlayerWithoutExplicitPlaySupportIsNotBlindlyToggledAtCallEnd() {
        platform.add(canPlay = false); start(); finish()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun disconnectDisableAndShutdownRestoreOwnedSoundButNeverAutoplay() {
        listOf(CallMediaReleaseReason.DISABLED, CallMediaReleaseReason.DISCONNECTED, CallMediaReleaseReason.SHUTDOWN).forEach { reason ->
            val p = Platform().apply { add("music"); add("broken", canPause = false) }
            val c = CallMediaController(p, clock, now = { clock.now })
            c.updateCalls(setOf("call"), CallMediaPolicy(restoration = CallMediaRestoration.LEAVE_AS_IS), false)
            c.release(reason)
            assertEquals(reason.name, 1, p.restoreCount)
            assertTrue(reason.name, p.played.isEmpty())
        }
    }

    @Test fun permissionLossClearsPlaybackOwnershipAndReleasesOwnedSound() {
        platform.add("music"); platform.add("broken", canPause = false)
        start()
        platform.availability = CallMediaAvailability.PERMISSION_NEEDED
        platform.changed(); clock.advance()
        assertEquals(CallMediaPhase.UNAVAILABLE, controller.result.phase)
        assertEquals(1, platform.restoreCount)
        platform.availability = CallMediaAvailability.AVAILABLE
        finish()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun noPermissionIsReportedAndNeverAttemptsPlaybackCommands() {
        platform.add(); platform.observeDenied = true
        start()
        assertEquals(CallMediaPhase.UNAVAILABLE, controller.result.phase)
        assertTrue(CallMediaReason.PERMISSION_NEEDED in controller.result.reasons)
        assertTrue(platform.paused.isEmpty())
        assertEquals(0, platform.muteCount)
    }

    @Test fun callEndingBeforePauseDeadlineCancelsLateMute() {
        platform.add(); platform.confirmPause = false
        start(); finish(); clock.advance(10_000)
        assertEquals(0, platform.muteCount)
        assertTrue(platform.played.isEmpty())
    }

    @Test fun alreadyMutedMediaNeverGrantsUnmuteOwnership() {
        platform.add(canPause = false)
        platform.music = platform.music.copy(volume = 0, muted = true)
        start(); finish()
        assertEquals(0, platform.muteCount)
        assertEquals(0, platform.restoreCount)
    }

    @Test fun fallbackFailureIsNotRetriedOnEveryMetadataOrCallSnapshot() {
        platform.add(canPause = false); platform.canMute = false
        start()
        platform.canMute = true
        repeat(4) { platform.changed(); clock.advance() }
        controller.updateCalls(setOf("phone/call-1", "phone/call-2"), CallMediaPolicy(), false)
        assertEquals(0, platform.muteCount)
        assertTrue(CallMediaReason.MUTE_UNAVAILABLE in controller.result.reasons)
    }

    @Test fun pauseConfirmedJustAfterTheLastCallEndsIsResumedWithinTheOriginalDeadline() {
        platform.add(); platform.confirmPause = false; start()
        clock.advance(300)
        finish()
        assertTrue(platform.played.isEmpty())
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance()
        assertEquals(listOf("music"), platform.played)
        assertEquals(1, platform.stops)
    }

    @Test fun lateConfirmationNeverResumesAfterDisableLossOrANewCall() {
        platform.add(); platform.confirmPause = false; start()
        clock.advance(100); finish()
        controller.release(CallMediaReleaseReason.DISCONNECTED)
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun lateConfirmationCannotResumeANewContentItemInTheSameSession() {
        platform.add(); platform.confirmPause = false; start()
        clock.advance(100); finish()
        platform.sessions["music"] = platform.sessions.getValue("music").copy(contentId = "replacement")
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun lateConfirmationCannotResumeAfterItsBoundedDeadline() {
        platform.add(); platform.confirmPause = false; start()
        clock.advance(100); finish(); clock.advance(650)
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun replacedContentWhilePauseIsPendingGivesOwnershipBackToThePerson() {
        platform.add(); platform.confirmPause = false; start()
        platform.sessions["music"] = platform.sessions.getValue("music").copy(contentId = "replacement")
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance(); finish()
        assertTrue(platform.played.isEmpty())
    }

    @Test fun aNewCallCancelsLateEndRestorationFromThePreviousInterval() {
        platform.add(); platform.confirmPause = false; start()
        clock.advance(100); finish()
        controller.updateCalls(setOf("new-call"), CallMediaPolicy(), false)
        platform.state("music", CallMediaPlayback.PAUSED); clock.advance()
        assertTrue(platform.played.isEmpty())
        finish()
        assertEquals(listOf("music"), platform.played)
    }

    @Test fun missingContentIdentityReportsLimitedRestoreAndNeverAutoplays() {
        platform.add()
        platform.sessions["music"] = platform.sessions.getValue("music").copy(contentId = null)
        start()
        assertTrue(CallMediaReason.RESTORE_UNVERIFIED in controller.result.reasons)
        assertEquals(CallMediaPhase.PARTIAL, controller.result.phase)
        finish()
        assertTrue(platform.played.isEmpty())
    }
}
