package dev.bridgey.android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/** Receives PackageInstaller session status for Round Robin edition self-updates. Not exported. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INSTALL_STATUS) return
        val bridgey = context.applicationContext as? BridgeyApplication ?: return
        if (!bridgey.isPrimaryUser) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Only the system can deliver here (explicit, unexported receiver behind our PendingIntent);
                // the extra is Android's own install confirmation screen.
                val confirmation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                bridgey.updater.onInstallNeedsConfirmation(confirmation)
            }
            PackageInstaller.STATUS_SUCCESS -> bridgey.updater.onInstallFinished(null)
            PackageInstaller.STATUS_FAILURE_ABORTED -> bridgey.updater.onInstallFinished(UpdateError.CANCELLED)
            else -> bridgey.updater.onInstallFinished(UpdateError.INSTALLER)
        }
    }

    companion object {
        const val ACTION_INSTALL_STATUS = "dev.bridgey.android.UPDATE_INSTALL_STATUS"
    }
}
