package dev.bridgey.android.remote

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Settings > Remote control on this phone: how fast the pointer moves, and the volume keys. */
data class RemotePreferencesState(
    /** 1 (slow) to 5 (fast). */
    val pointerSpeed: Int = DEFAULT_POINTER_SPEED,
    /** Volume down for the next slide, volume up for the previous one. Off by default. */
    val volumeKeysChangeSlides: Boolean = false,
) {
    companion object {
        const val DEFAULT_POINTER_SPEED = 3
        val POINTER_SPEEDS = 1..5
    }
}

class RemoteInputPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("bridgey.remote", Context.MODE_PRIVATE)
    private val mutableState = MutableStateFlow(
        RemotePreferencesState(
            pointerSpeed = preferences.getInt(KEY_POINTER_SPEED, RemotePreferencesState.DEFAULT_POINTER_SPEED)
                .takeIf { it in RemotePreferencesState.POINTER_SPEEDS } ?: RemotePreferencesState.DEFAULT_POINTER_SPEED,
            volumeKeysChangeSlides = preferences.getBoolean(KEY_VOLUME_KEYS, false),
        ),
    )
    val state: StateFlow<RemotePreferencesState> = mutableState.asStateFlow()

    fun setPointerSpeed(level: Int) {
        val value = level.coerceIn(RemotePreferencesState.POINTER_SPEEDS)
        preferences.edit().putInt(KEY_POINTER_SPEED, value).apply()
        mutableState.value = mutableState.value.copy(pointerSpeed = value)
    }

    fun setVolumeKeysChangeSlides(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_VOLUME_KEYS, enabled).apply()
        mutableState.value = mutableState.value.copy(volumeKeysChangeSlides = enabled)
    }

    private companion object {
        const val KEY_POINTER_SPEED = "pointer_speed"
        const val KEY_VOLUME_KEYS = "volume_keys_slides"
    }
}

/**
 * The presentation screen claims the volume keys while it is shown and the setting is on.
 * MainActivity asks it before the system changes the volume.
 */
object VolumeKeyRouter {
    @Volatile var handler: ((volumeUp: Boolean) -> Unit)? = null
}
