package dev.bridgey.android.setup

import android.content.Context
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.featureOnByDefault

/**
 * Which feature defaults this install uses, decided once and stored, so an update never changes
 * an existing install's settings. Fresh installs (0.10 beta 2 on) start with every optional
 * feature off until setup, a bundle or Settings turns it on; installs from before keep the old
 * defaults (most features on). Settings > Reset > Settings keeps the generation, so a reset goes
 * back to this install's own defaults.
 */
object DefaultsGeneration {
    /** Not cleared by Reset > Settings (it clears `bridgey.settings`). */
    const val PREFERENCES = "bridgey.install"
    const val KEY = "defaults_generation"

    /** Installs from before 0.10 beta 2: features on by default, as they always were. */
    const val FEATURES_ON = 1

    /** Every optional feature off until it is chosen. */
    const val OFF_UNTIL_CHOSEN = 2

    /**
     * [stored]: the generation recorded earlier, if any. [priorInstall]: this phone ran Bridgey
     * before (its device ID existed before this launch), from a build that recorded no generation.
     */
    fun resolve(stored: Int?, priorInstall: Boolean): Int = stored ?: if (priorInstall) FEATURES_ON else OFF_UNTIL_CHOSEN

    fun featureDefault(feature: BridgeyFeature, generation: Int): Boolean =
        if (generation >= OFF_UNTIL_CHOSEN) false else featureOnByDefault(feature)

    /** Reads the stored generation, or decides and stores it. Call before anything writes the device ID. */
    fun settle(context: Context, priorInstall: Boolean): Int {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val stored = if (preferences.contains(KEY)) preferences.getInt(KEY, FEATURES_ON) else null
        return resolve(stored, priorInstall).also { if (stored == null) preferences.edit().putInt(KEY, it).apply() }
    }
}
