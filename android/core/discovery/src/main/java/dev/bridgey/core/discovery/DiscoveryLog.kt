package dev.bridgey.core.discovery

import android.util.Log

/**
 * Logcat for discovery. The app turns it off with Settings > Privacy > Logging > Connection
 * events; nothing is written while [enabled] is false.
 */
object DiscoveryLog {
    @Volatile
    var enabled: Boolean = true

    private const val TAG = "Bridgey"

    fun i(message: String) {
        if (enabled) Log.i(TAG, message)
    }

    fun w(message: String, error: Throwable? = null) {
        if (!enabled) return
        if (error != null) Log.w(TAG, message, error) else Log.w(TAG, message)
    }
}
