package dev.bridgey.android.ui

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Settings that only change how the app looks and moves on this phone. */
class UiPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("bridgey.ui", Context.MODE_PRIVATE)
    private val mutableReduceMotion = MutableStateFlow(preferences.getBoolean(KEY_REDUCE_MOTION, false))
    val reduceMotion: StateFlow<Boolean> = mutableReduceMotion.asStateFlow()

    private val mutableShowPreviews = MutableStateFlow(preferences.getBoolean(KEY_SHOW_PREVIEWS, true))

    /** Settings > Privacy > Show previews in activity. */
    val showPreviews: StateFlow<Boolean> = mutableShowPreviews.asStateFlow()

    fun setShowPreviews(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_SHOW_PREVIEWS, enabled).apply()
        mutableShowPreviews.value = enabled
    }

    fun setReduceMotion(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_REDUCE_MOTION, enabled).apply()
        mutableReduceMotion.value = enabled
    }

    private val mutableTileAdded = MutableStateFlow(preferences.getBoolean(KEY_TILE_ADDED, false))

    /** Whether the Quick Settings tile has been added, so the "Add" button can be hidden. */
    val tileAdded: StateFlow<Boolean> = mutableTileAdded.asStateFlow()

    fun setTileAdded(added: Boolean) {
        preferences.edit().putBoolean(KEY_TILE_ADDED, added).apply()
        mutableTileAdded.value = added
    }

    private companion object {
        const val KEY_REDUCE_MOTION = "reduce_motion"
        const val KEY_SHOW_PREVIEWS = "show_activity_previews"
        const val KEY_TILE_ADDED = "qs_tile_added"
    }
}
