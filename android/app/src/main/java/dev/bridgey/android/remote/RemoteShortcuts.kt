package dev.bridgey.android.remote

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.DeviceConnection
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R

/** A Mac the launcher's "Remote control" quick action opens. */
data class RemoteShortcutTarget(val deviceId: String, val name: String)

/** Connected Macs where remote control is on here and the Mac allows this phone. */
fun remoteShortcutTargets(connections: List<DeviceConnection>, enabledHere: (String) -> Boolean): List<RemoteShortcutTarget> =
    connections
        .filter { enabledHere(it.deviceId) && it.state.remoteFeatures[BridgeyFeature.REMOTE_INPUT] == true }
        .take(MAX_REMOTE_SHORTCUTS)
        .map { RemoteShortcutTarget(it.deviceId, it.peerName) }

private const val MAX_REMOTE_SHORTCUTS = 2

/**
 * The launcher quick action (long-press the Bridgey icon): "Control Personal Mac". Published only
 * while both sides allow remote control, and removed as soon as they do not.
 */
class RemoteShortcuts(private val context: Context) {
    private var published: List<RemoteShortcutTarget>? = null

    fun publish(targets: List<RemoteShortcutTarget>) {
        if (targets == published) return
        published = targets
        val manager = context.getSystemService(ShortcutManager::class.java) ?: return
        val shortcuts = targets.map { target ->
            ShortcutInfo.Builder(context, "$SHORTCUT_PREFIX${target.deviceId}")
                .setShortLabel(context.getString(R.string.remote_shortcut_short))
                .setLongLabel(context.getString(R.string.remote_shortcut_long, target.name))
                .setIcon(Icon.createWithResource(context, R.drawable.ic_shortcut_remote))
                .setIntent(intent(context, target.deviceId))
                .build()
        }
        runCatching { manager.dynamicShortcuts = shortcuts }
    }

    companion object {
        const val ACTION_REMOTE_CONTROL = "dev.bridgey.android.action.REMOTE_CONTROL"
        const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.DEVICE_ID"
        private const val SHORTCUT_PREFIX = "remote:"

        fun intent(context: Context, deviceId: String): Intent =
            Intent(ACTION_REMOTE_CONTROL)
                .setClass(context, MainActivity::class.java)
                .putExtra(EXTRA_DEVICE_ID, deviceId)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }
}
