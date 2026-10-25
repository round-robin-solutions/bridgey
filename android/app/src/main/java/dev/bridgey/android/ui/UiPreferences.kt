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

    fun setReduceMotion(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_REDUCE_MOTION, enabled).apply()
        mutableReduceMotion.value = enabled
    }

    private companion object {
        const val KEY_REDUCE_MOTION = "reduce_motion"
    }
}
