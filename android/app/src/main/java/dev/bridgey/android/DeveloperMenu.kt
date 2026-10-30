package dev.bridgey.android

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Settings > About: tapping the version [TAPS] times in a row (each within [WINDOW_MILLIS] of the last) turns on the
 * hidden Developer and experimental menu, like Android's build number. Once on, the menu is its own Settings row and
 * a tap on the version opens it, until it is turned off inside the menu. Kept on this phone only: its preferences file
 * is not one settings sync reads (dev.bridgey.android.sync), so the state never syncs. The Mac has the same rules in
 * DeveloperMenu.swift.
 */
internal class DeveloperMenu(private val prefs: SharedPreferences, private val now: () -> Long = SystemClock::elapsedRealtime) {
    constructor(context: Context) : this(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE))

    /** What a tap on the version did. */
    sealed interface Tap {
        /** Counting, nothing to show yet. */
        data object Counting : Tap

        /** Counting: [left] more taps turn the menu on. */
        data class Remaining(val left: Int) : Tap

        /** This tap turned the menu on. */
        data object Unlocked : Tap

        /** The menu was already on: open it. */
        data object Open : Tap
    }

    private val mutableEnabled = MutableStateFlow(prefs.getBoolean(KEY, false))
    val enabled: StateFlow<Boolean> = mutableEnabled.asStateFlow()
    private var taps = 0
    private var lastTapAt = Long.MIN_VALUE

    fun tap(): Tap {
        if (mutableEnabled.value) return Tap.Open
        val at = now()
        if (lastTapAt == Long.MIN_VALUE || at - lastTapAt > WINDOW_MILLIS) taps = 0
        lastTapAt = at
        taps += 1
        if (taps >= TAPS) {
            taps = 0
            prefs.edit().putBoolean(KEY, true).apply()
            mutableEnabled.value = true
            return Tap.Unlocked
        }
        val left = TAPS - taps
        return if (left <= SHOW_FROM) Tap.Remaining(left) else Tap.Counting
    }

    /** "Turn off developer menu" inside the menu: the row goes away until the version is tapped again. */
    fun turnOff() {
        prefs.edit().putBoolean(KEY, false).apply()
        mutableEnabled.value = false
        taps = 0
        lastTapAt = Long.MIN_VALUE
    }

    companion object {
        const val TAPS = 5
        const val WINDOW_MILLIS = 3_000L
        /** The toast starts once this many taps are left. */
        const val SHOW_FROM = 3
        const val PREFERENCES = "bridgey_developer"
        const val KEY = "developer_menu"
    }
}

/** Developer menu > Transfers: how files travel to one connected device right now. */
data class TransferPath(
    val deviceName: String,
    /** Both ends speak files_fast_draft1 on this session: binary frames and the byte window. */
    val fast: Boolean,
    /** A Connect anywhere tunnel's route ("vpn", "direct", "relay"), or null on the local network. */
    val tunnelRoute: String?,
)
