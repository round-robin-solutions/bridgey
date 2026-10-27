package dev.bridgey.android.screen

import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Quick Settings "Share screen": active while this phone shares its screen (a tap stops it); otherwise a tap
 * opens Android's consent dialog for the selected Mac, or the only Mac screen sharing is available with.
 */
class ScreenShareTileService : TileService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var listening: Job? = null

    override fun onStartListening() {
        super.onStartListening()
        val app = application as BridgeyApplication
        if (!app.isPrimaryUser) { qsTile?.apply { state = Tile.STATE_UNAVAILABLE; updateTile() }; return }
        listening?.cancel()
        listening = scope.launch {
            combine(app.pairing.state, app.pairing.connections, app.screenShare.state, app.settings.state) { _, _, share, _ -> share }.collect { share ->
                qsTile?.apply {
                    val target = if (app.isBridgeyEnabled) app.pairing.screenTarget() else null
                    state = when {
                        share.active -> Tile.STATE_ACTIVE
                        target != null -> Tile.STATE_INACTIVE
                        else -> Tile.STATE_UNAVAILABLE
                    }
                    label = getString(R.string.tile_screen_label)
                    if (Build.VERSION.SDK_INT >= 29) {
                        subtitle = when {
                            share.active -> share.macName
                            target != null -> target.second
                            else -> getString(R.string.tile_screen_unavailable)
                        }
                    }
                    updateTile()
                }
            }
        }
    }

    override fun onStopListening() { listening?.cancel(); listening = null; super.onStopListening() }
    override fun onDestroy() { scope.cancel(); super.onDestroy() }

    // Below Android 14 only the Intent form exists; 14 and later use the PendingIntent form.
    @android.annotation.SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val app = application as BridgeyApplication
        if (!app.isPrimaryUser) return
        if (app.screenShare.state.value.active) {
            app.screenShare.stop(ScreenStopReason.USER)
            return
        }
        unlockAndRun {
            val (deviceId, macName) = app.pairing.screenTarget() ?: return@unlockAndRun
            app.screenShare.markAsking(deviceId, macName)
            val intent = ScreenConsentActivity.intent(this, deviceId, macName, null)
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
    }
}
