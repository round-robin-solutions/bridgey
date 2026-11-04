package dev.bridgey.android.media

import android.app.Application
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Looper
import android.provider.Settings
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.shadows.PlaybackInfoBuilder

/** Only Robolectric-owned playback/session/audio objects; never a device's real player or output. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class AndroidCallMediaPlatformTest {
    private val application = RuntimeEnvironment.getApplication()
    private val sessions = application.getSystemService(MediaSessionManager::class.java)
    private val audio = application.getSystemService(AudioManager::class.java)
    private val platform = AndroidCallMediaPlatform(application)
    private var stop: (() -> Unit)? = null

    @Before fun onlyASpeakerIsAvailable() {
        Settings.Global.putInt(application.contentResolver, Settings.Global.BOOT_COUNT, 1)
        shadowOf(audio).setOutputDevices(listOf(AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER).build()))
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 6, 0)
        audio.mode = AudioManager.MODE_NORMAL
    }

    @After fun cleanup() { stop?.invoke() }

    private fun player(tag: String, usage: Int = AudioAttributes.USAGE_MEDIA): MediaController {
        val token = MediaSession(application, tag).sessionToken
        val controller = MediaController(application, token)
        shadowOf(controller).setPlaybackInfo(PlaybackInfoBuilder.newBuilder()
            .setVolumeType(MediaController.PlaybackInfo.PLAYBACK_TYPE_LOCAL)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(usage).build())
            .setVolumeControl(2).setMaxVolume(15).setCurrentVolume(6).build())
        shadowOf(controller).setPlaybackState(state(PlaybackState.STATE_PLAYING))
        shadowOf(sessions).addController(controller)
        return controller
    }

    private fun state(value: Int) = PlaybackState.Builder()
        .setState(value, 100, if (value == PlaybackState.STATE_PLAYING) 1f else 0f)
        .setActions(PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY).build()

    @Test fun snapshotsUseOpaqueStableSessionIdsAndClassifyVoiceAudioAsProtected() {
        player("music"); player("call", AudioAttributes.USAGE_VOICE_COMMUNICATION)
        stop = platform.observe { }
        val first = platform.snapshot()
        val second = platform.snapshot()

        assertEquals(2, first.sessions.size)
        assertEquals(first.sessions.map { it.id }, second.sessions.map { it.id })
        assertEquals(1, first.sessions.count { it.mediaOrGame })
        assertTrue(first.sessions.none { it.id.contains("music") || it.id.contains("call") })
    }

    @Test fun transportCommandsAreExplicitPauseAndPlayAndNeverAPlaybackToggle() {
        val player = player("music")
        stop = platform.observe { }
        val id = platform.snapshot().sessions.single().id
        assertTrue(platform.pause(id))
        assertEquals(PlaybackState.ACTION_PAUSE, shadowOf(player.transportControls).lastPerformedAction)

        shadowOf(player).setPlaybackState(state(PlaybackState.STATE_PAUSED))
        assertTrue(platform.play(id))
        assertEquals(PlaybackState.ACTION_PLAY, shadowOf(player.transportControls).lastPerformedAction)
    }

    @Test fun voiceSessionsCannotReceivePlaybackCommands() {
        val call = player("call", AudioAttributes.USAGE_VOICE_COMMUNICATION)
        stop = platform.observe { }
        val id = platform.snapshot().sessions.single().id

        assertFalse(platform.pause(id))
        assertEquals(0L, shadowOf(call.transportControls).lastPerformedAction)
    }

    @Test fun destroyedSessionsCannotBeRestoredOrMistakenForAnotherSession() {
        val player = player("music")
        stop = platform.observe { }
        val id = platform.snapshot().sessions.single().id
        shadowOf(player).executeOnSessionDestroyed()
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(platform.snapshot().sessions.isEmpty())
        assertFalse(platform.play(id))
        assertFalse(platform.pause(id))
    }

    @Test fun observablePausedSeekChangesTheRestorationRevision() {
        val player = player("music")
        stop = platform.observe { }
        shadowOf(player).setPlaybackState(state(PlaybackState.STATE_PAUSED))
        val before = platform.snapshot().sessions.single()
        shadowOf(player).setPlaybackState(PlaybackState.Builder(state(PlaybackState.STATE_PAUSED))
            .setState(PlaybackState.STATE_PAUSED, 500, 0f).build())
        val after = platform.snapshot().sessions.single()

        assertEquals(before.id, after.id)
        assertNotEquals(before.revision, after.revision)
    }

    @Test fun streamMuteIsRefusedInCommunicationModeAndWithAmbiguousOutputs() {
        stop = platform.observe { }
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        val call = platform.snapshot().music!!
        assertFalse(call.safeToMute)
        assertEquals(null, platform.muteMusic(call))

        audio.mode = AudioManager.MODE_NORMAL
        shadowOf(audio).setOutputDevices(listOf(
            AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER).build(),
            AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_WIRED_HEADPHONES).build(),
        ))
        val routes = platform.snapshot().music!!
        assertFalse(routes.safeToMute)
        assertEquals(null, platform.muteMusic(routes))
    }

    @Test fun ownedMediaStreamMuteDoesNotChangeTheVoiceOrRingerStreams() {
        stop = platform.observe { }
        audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, 3, 0)
        audio.setStreamVolume(AudioManager.STREAM_RING, 4, 0)
        val before = platform.snapshot().music!!
        assertTrue(before.safeToMute)
        val muted = platform.muteMusic(before)!!

        assertTrue(audio.isStreamMute(AudioManager.STREAM_MUSIC))
        assertEquals(3, audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL))
        assertEquals(4, audio.getStreamVolume(AudioManager.STREAM_RING))
        assertTrue(platform.restoreMusic(muted, before))
        assertFalse(audio.isStreamMute(AudioManager.STREAM_MUSIC))
    }

    @Test fun laterVolumeOrRouteChangesInvalidateTheMuteLease() {
        stop = platform.observe { }
        val before = platform.snapshot().music!!
        val muted = platform.muteMusic(before)!!
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, 2, 0)

        assertFalse(platform.restoreMusic(muted, before))
    }

    @Test fun stoppingObservationUnregistersEverySessionCallback() {
        val player = player("music")
        stop = platform.observe { }
        assertTrue(shadowOf(player).callbacks.isNotEmpty())
        stop!!.invoke(); stop = null
        assertTrue(shadowOf(player).callbacks.isEmpty())
    }

    @Test fun processRestartRecoversOnlyOwnedSoundAndNeverIssuesAPlayCommand() {
        val player = player("music")
        stop = platform.observe { }
        val before = platform.snapshot().music!!
        platform.muteMusic(before)!!
        stop!!.invoke(); stop = null

        AndroidCallMediaPlatform(application)

        assertFalse(audio.isStreamMute(AudioManager.STREAM_MUSIC))
        assertEquals(0L, shadowOf(player.transportControls).lastPerformedAction)
    }

    @Test fun routeChangeWithPersistentMuteBlocksResetUntilThePersonUnmutes() {
        stop = platform.observe { }
        val before = platform.snapshot().music!!
        val owned = platform.muteMusic(before)!!
        shadowOf(audio).setOutputDevices(listOf(AudioDeviceInfoBuilder.newBuilder().setType(AudioDeviceInfo.TYPE_WIRED_HEADPHONES).build()))
        platform.abandonMusic(owned)

        assertFalse(platform.prepareForReset())
        assertTrue(audio.isStreamMute(AudioManager.STREAM_MUSIC))
        audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
        assertTrue(platform.prepareForReset())
    }

    @Test fun explicitLeaveAsIsRelinquishesEvenAMutedRecoveryRecord() {
        stop = platform.observe { }
        val before = platform.snapshot().music!!
        val owned = platform.muteMusic(before)!!
        platform.abandonMusic(owned, explicit = true)
        AndroidCallMediaPlatform(application)
        assertTrue(audio.isStreamMute(AudioManager.STREAM_MUSIC))
        assertTrue(platform.prepareForReset())
    }
}
