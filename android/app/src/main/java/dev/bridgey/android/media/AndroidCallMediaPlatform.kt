package dev.bridgey.android.media

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.database.ContentObserver
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.AudioPlaybackConfiguration
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import dev.bridgey.android.BridgeyNotificationListenerService
import java.util.UUID
import java.io.File
import java.security.MessageDigest

class AndroidCallMediaScheduler(private val handler: Handler = Handler(Looper.getMainLooper())) : CallMediaScheduler {
    override fun schedule(delayMs: Long, task: () -> Unit): () -> Unit {
        val runnable = Runnable(task)
        handler.postDelayed(runnable, delayMs)
        return { handler.removeCallbacks(runnable) }
    }
}

/**
 * Public Android media-session controls through the already enabled notification listener.
 * No audio focus acquisition, synthetic playback, master mute or privileged media permission.
 * The caller owns start/stop and calls every method on the main thread.
 */
@SuppressLint("MissingPermission") // Enabled NotificationListener component is the documented alternative to MEDIA_CONTENT_CONTROL.
class AndroidCallMediaPlatform(
    context: Context,
    private val notificationListener: ComponentName = ComponentName(context, BridgeyNotificationListenerService::class.java),
    private val handler: Handler = Handler(Looper.getMainLooper()),
) : CallMediaPlatform {
    private val context = context.applicationContext
    private val sessions = this.context.getSystemService(MediaSessionManager::class.java)
    private val audio = this.context.getSystemService(AudioManager::class.java)
    private var changed: (() -> Unit)? = null
    private var observing = false
    private val entries = linkedMapOf<MediaSession.Token, Entry>()
    private val destroyed = mutableSetOf<MediaSession.Token>()
    private var truncated = false
    private var musicRevision = 0L
    private var lastMusic: MusicSignature? = null
    private var knownOutputs = emptySet<Int>()
    private val muteJournal = CallMediaMuteJournal(File(this.context.noBackupFilesDir, "call-media-mute.json"))

    private data class MusicSignature(val volume: Int, val muted: Boolean, val route: String)
    private data class SessionSignature(val state: Int, val position: Long, val speed: Float, val updatedAt: Long)

    private inner class Entry(val controller: MediaController) {
        val id = UUID.randomUUID().toString()
        var revision = 0L
        var signature: SessionSignature? = null
        val callback = object : MediaController.Callback() {
            override fun onPlaybackStateChanged(state: PlaybackState?) { changed?.invoke() }
            override fun onMetadataChanged(metadata: MediaMetadata?) { changed?.invoke() }
            override fun onAudioInfoChanged(info: MediaController.PlaybackInfo) { changed?.invoke() }
            override fun onSessionDestroyed() {
                destroyed += controller.sessionToken
                while (destroyed.size > MAX_SESSIONS * 2) destroyed.remove(destroyed.first())
                entries.remove(controller.sessionToken)
                runCatching { controller.unregisterCallback(this) }
                changed?.invoke()
            }
        }

        fun snapshot(): CallMediaSession {
            val state = controller.playbackState
            val next = SessionSignature(state?.state ?: PlaybackState.STATE_NONE, state?.position ?: 0, state?.playbackSpeed ?: 0f,
                state?.lastPositionUpdateTime ?: 0)
            if (signature != next) { signature = next; revision += 1 }
            val info = controller.playbackInfo
            val usage = info?.audioAttributes?.usage
            return CallMediaSession(
                id = id,
                playback = when (state?.state) {
                    PlaybackState.STATE_PLAYING, PlaybackState.STATE_FAST_FORWARDING, PlaybackState.STATE_REWINDING -> CallMediaPlayback.PLAYING
                    PlaybackState.STATE_PAUSED -> CallMediaPlayback.PAUSED
                    PlaybackState.STATE_STOPPED -> CallMediaPlayback.STOPPED
                    else -> CallMediaPlayback.OTHER
                },
                canPause = state != null && state.actions and PlaybackState.ACTION_PAUSE != 0L,
                canPlay = state != null && state.actions and PlaybackState.ACTION_PLAY != 0L,
                mediaOrGame = usage == AudioAttributes.USAGE_MEDIA || usage == AudioAttributes.USAGE_GAME,
                revision = revision,
                localPlayback = info?.playbackType == MediaController.PlaybackInfo.PLAYBACK_TYPE_LOCAL,
                contentId = contentIdentity(controller.metadata),
                positionMs = state?.position ?: -1,
            )
        }
    }

    private val sessionListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        synchronize(controllers.orEmpty())
        changed?.invoke()
    }
    private val outputListener = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            val next = knownOutputs + addedDevices.orEmpty().filter { it.isSink }.map { it.id }
            if (next != knownOutputs) musicRevision += 1
            knownOutputs = next
            changed?.invoke()
        }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            val next = knownOutputs - removedDevices.orEmpty().map { it.id }.toSet()
            // A removed/reconnected output invalidates an old lease even if its ID is reused.
            if (next != knownOutputs) musicRevision += 1
            knownOutputs = next
            changed?.invoke()
        }
    }
    private val playbackListener = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>?) { changed?.invoke() }
    }
    private val settingsListener = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) { changed?.invoke() }
    }

    init { recoverOwnedMute() }

    override fun observe(changed: () -> Unit): () -> Unit {
        stop()
        checkNotNull(sessions) { "Media sessions are unavailable" }
        checkNotNull(audio) { "Audio controls are unavailable" }
        this.changed = changed
        observing = true
        try {
            knownOutputs = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).mapTo(mutableSetOf()) { it.id }
            sessions.addOnActiveSessionsChangedListener(sessionListener, notificationListener, handler)
            audio.registerAudioDeviceCallback(outputListener, handler)
            audio.registerAudioPlaybackCallback(playbackListener, handler)
            // There is no public stream-volume broadcast. Observe public system-setting changes,
            // then read the current public AudioManager state; never inspect hidden settings keys.
            context.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, settingsListener)
            synchronize(sessions.getActiveSessions(notificationListener))
        } catch (failure: RuntimeException) {
            stop()
            throw failure
        }
        return ::stop
    }

    override fun snapshot(): CallMediaSnapshot {
        if (sessions == null || audio == null) return CallMediaSnapshot(CallMediaAvailability.UNAVAILABLE)
        return try {
            synchronize(sessions.getActiveSessions(notificationListener))
            CallMediaSnapshot(
                availability = CallMediaAvailability.AVAILABLE,
                sessions = entries.values.map(Entry::snapshot),
                music = musicState(),
                truncated = truncated,
            )
        } catch (_: SecurityException) {
            CallMediaSnapshot(CallMediaAvailability.PERMISSION_NEEDED)
        }
    }

    override fun pause(sessionId: String): Boolean = control(sessionId, play = false)
    override fun play(sessionId: String): Boolean = control(sessionId, play = true)

    private fun control(id: String, play: Boolean): Boolean {
        val entry = entries.values.firstOrNull { it.id == id } ?: return false
        val now = entry.snapshot()
        if (!now.mediaOrGame || (if (play) !now.canPlay else !now.canPause)) return false
        if (play && now.playback != CallMediaPlayback.PAUSED || !play && now.playback != CallMediaPlayback.PLAYING) return false
        return runCatching {
            if (play) entry.controller.transportControls.play() else entry.controller.transportControls.pause()
            true
        }.getOrDefault(false)
    }

    override fun muteMusic(expected: CallMediaMusicState): CallMediaMusicState? {
        val manager = audio ?: return null
        val before = musicState() ?: return null
        if (!sameOwnedState(before, expected) || !before.safeToMute || before.muted || before.volume == 0) return null
        val boot = bootCount() ?: return null
        if (!muteJournal.prepare(boot, before)) return null
        return runCatching {
            manager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
            val after = musicState()
            if (after != null && after.muted && after.route == before.route) {
                if (muteJournal.applied(boot, before, after)) after
                else { restoreMusic(after, before); null }
            } else {
                if (after?.muted == false) muteJournal.clear()
                else if (after != null) muteJournal.requireManualFix()
                // If the post-mutation read failed, keep the durable pre-mutation record.
                null
            }
        }.getOrNull()
    }

    override fun restoreMusic(owned: CallMediaMusicState, previous: CallMediaMusicState): Boolean {
        val manager = audio ?: return false
        val now = musicState() ?: return false
        if (!sameOwnedState(now, owned) || now.route != previous.route || !now.muted || previous.muted) {
            abandonMusic(owned)
            return false
        }
        return runCatching {
            // ADJUST_UNMUTE preserves Android's pre-mute index. Do not set an index or touch call,
            // notification or ringer streams, and never change a newly selected route.
            manager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
            val restored = musicState()?.muted == false
            if (restored) muteJournal.clear()
            restored
        }.getOrDefault(false)
    }

    override fun abandonMusic(owned: CallMediaMusicState, explicit: Boolean) {
        if (explicit || musicState()?.muted == false) muteJournal.clear()
        else muteJournal.requireManualFix()
    }

    /** Reset must keep data/recovery when an owned mute could not safely be restored. */
    fun prepareForReset(): Boolean {
        recoverOwnedMute()
        return !muteJournal.exists()
    }

    /** Process restart restores sound only, never a player. New boot/route/manual volume wins. */
    private fun recoverOwnedMute() {
        val record = muteJournal.read()
        if (record == null) {
            if (muteJournal.exists() && musicState()?.muted == false) muteJournal.clear()
            return
        }
        val current = musicState() ?: return
        if (!current.muted) { muteJournal.clear(); return }
        if (record.manualFix) return
        val expected = record.applied
        val sameApplied = expected == null && current.volume in setOf(0, record.previous.volume) ||
            expected != null && current.volume == expected.volume
        if (record.boot == bootCount() && current.muted && !record.previous.muted &&
            current.route == record.previous.route && sameApplied
        ) {
            runCatching {
                audio?.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
                if (musicState()?.muted == false) muteJournal.clear()
            }
        } else {
            muteJournal.requireManualFix()
        }
    }

    private fun bootCount(): Int? = runCatching {
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1).takeIf { it >= 0 }
    }.getOrNull()

    private fun musicState(): CallMediaMusicState? {
        val manager = audio ?: return null
        return runCatching {
            val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter {
                it.type != AudioDeviceInfo.TYPE_BUILTIN_EARPIECE && it.type != AudioDeviceInfo.TYPE_TELEPHONY
            }
            val route = outputs.sortedBy { it.id }.joinToString(",") { "${it.id}:${it.type}" }
            val signature = MusicSignature(manager.getStreamVolume(AudioManager.STREAM_MUSIC), manager.isStreamMute(AudioManager.STREAM_MUSIC), route)
            if (signature != lastMusic) { lastMusic = signature; musicRevision += 1 }
            val communication = manager.activePlaybackConfigurations.any {
                it.audioAttributes.usage == AudioAttributes.USAGE_VOICE_COMMUNICATION ||
                    it.audioAttributes.usage == AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING ||
                    it.audioAttributes.usage == AudioAttributes.USAGE_UNKNOWN
            }
            CallMediaMusicState(
                volume = signature.volume,
                muted = signature.muted,
                route = route,
                revision = musicRevision,
                active = manager.isMusicActive,
                // Available outputs are not a public active-route API on all supported Android
                // versions. Refuse a stream mute whenever the destination is ambiguous.
                safeToMute = manager.mode == AudioManager.MODE_NORMAL && !manager.isVolumeFixed && outputs.size == 1 && !communication,
                protectedCallAudio = manager.mode != AudioManager.MODE_NORMAL || communication,
            )
        }.getOrNull()
    }

    private fun sameOwnedState(now: CallMediaMusicState, owned: CallMediaMusicState): Boolean =
        now.volume == owned.volume && now.muted == owned.muted && now.route == owned.route && now.revision == owned.revision

    private fun contentIdentity(metadata: MediaMetadata?): String? {
        if (metadata == null) return null
        val fields = listOf(MediaMetadata.METADATA_KEY_MEDIA_ID, MediaMetadata.METADATA_KEY_MEDIA_URI,
            MediaMetadata.METADATA_KEY_TITLE, MediaMetadata.METADATA_KEY_ARTIST, MediaMetadata.METADATA_KEY_ALBUM)
            .map { metadata.getString(it).orEmpty() }
        if (fields.all(String::isEmpty)) return null
        if (fields.any { it.length > 4_096 }) return null
        val identity = fields.joinToString("\u0000") + "\u0000" + metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)
        return MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    private fun synchronize(controllers: List<MediaController>) {
        truncated = controllers.size > MAX_SESSIONS
        val current = controllers.take(MAX_SESSIONS).filterNot { it.sessionToken in destroyed }.associateBy { it.sessionToken }
        entries.keys.filterNot(current::containsKey).forEach { token ->
            entries.remove(token)?.let { entry -> runCatching { entry.controller.unregisterCallback(entry.callback) } }
        }
        current.forEach { (token, controller) ->
            if (token !in entries) {
                val entry = Entry(controller)
                entries[token] = entry
                if (observing) controller.registerCallback(entry.callback, handler)
            }
        }
    }

    private fun stop() {
        changed = null
        if (observing) {
            runCatching { sessions?.removeOnActiveSessionsChangedListener(sessionListener) }
            runCatching { audio?.unregisterAudioDeviceCallback(outputListener) }
            runCatching { audio?.unregisterAudioPlaybackCallback(playbackListener) }
            runCatching { context.contentResolver.unregisterContentObserver(settingsListener) }
        }
        observing = false
        entries.values.forEach { entry -> runCatching { entry.controller.unregisterCallback(entry.callback) } }
        entries.clear(); destroyed.clear(); truncated = false
    }

    companion object { private const val MAX_SESSIONS = 32 }
}
