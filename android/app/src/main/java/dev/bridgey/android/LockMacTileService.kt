package dev.bridgey.android

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import dev.bridgey.android.actions.MacActionIds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * Quick Settings "Lock Mac": locks the Mac selected in Bridgey, when it allows this phone to.
 * Runs only after the phone is unlocked, so a locked phone cannot lock (or probe) the Mac.
 */
class LockMacTileService : TileService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var listening: Job? = null

    /** The selected Mac, when its list in this session includes Lock and nothing blocks it. */
    private fun target(app: BridgeyApplication): PairingState.Connected? {
        if (!app.isPrimaryUser || !app.isBridgeyEnabled) return null
        val connected = app.pairing.state.value as? PairingState.Connected ?: return null
        val entry = app.pairing.macActions.usableCatalog(connected.deviceId)?.entry(MacActionIds.LOCK) ?: return null
        return connected.takeIf { entry.blocked == null }
    }

    override fun onStartListening() {
        super.onStartListening()
        val app = application as BridgeyApplication
        if (!app.isPrimaryUser) { qsTile?.apply { state = Tile.STATE_UNAVAILABLE; updateTile() }; return }
        listening?.cancel()
        listening = scope.launch {
            combine(app.pairing.state, app.pairing.macActions.catalogs, app.pairing.macActions.live, app.pairing.connections) { _, _, _, _ -> }.collect {
                qsTile?.apply {
                    val target = target(app)
                    state = if (target != null) Tile.STATE_INACTIVE else Tile.STATE_UNAVAILABLE
                    label = getString(R.string.tile_lock_label)
                    if (Build.VERSION.SDK_INT >= 29) subtitle = target?.peerName ?: getString(R.string.tile_lock_unavailable)
                    updateTile()
                }
            }
        }
    }

    override fun onStopListening() { listening?.cancel(); listening = null; super.onStopListening() }
    override fun onDestroy() { scope.cancel(); super.onDestroy() }

    override fun onClick() {
        super.onClick()
        unlockAndRun {
            val app = application as BridgeyApplication
            val target = target(app) ?: return@unlockAndRun
            app.pairing.macActions.run(target.deviceId, MacActionIds.LOCK)
        }
    }
}
