package dev.bridgey.android.screen

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.ui.DeviceDestinationSelection
import dev.bridgey.android.ui.destinationChoices
import dev.bridgey.android.ui.ScreenDestinationSheet
import dev.bridgey.android.ui.theme.BridgeyTheme
import androidx.activity.result.contract.ActivityResultContracts
import dev.bridgey.android.BridgeyApplication

/**
 * A transparent step that opens Android's screen capture dialog. A fresh consent Intent every time, as
 * Android 14 and later require; the result goes straight to the service and is never kept or reused.
 */
class ScreenConsentActivity : ComponentActivity() {
    private val consent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val app = application as BridgeyApplication
        val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID).orEmpty()
        val macName = intent.getStringExtra(EXTRA_MAC_NAME).orEmpty()
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID)
        val data = result.data
        if (result.resultCode == Activity.RESULT_OK && data != null && deviceId.isNotEmpty() &&
            app.isBridgeyEnabled && app.pairing.connections.value.any { it.deviceId == deviceId } &&
            app.pairing.isFeatureAvailable(BridgeyFeature.SCREEN, deviceId)) {
            app.screenShare.consentGranted(this, deviceId, macName, requestId, result.resultCode, data)
        } else {
            app.screenShare.consentDeclined(deviceId, requestId)
        }
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as BridgeyApplication
        if (!app.isPrimaryUser || !app.isBridgeyEnabled) { finish(); return }
        if (intent.getBooleanExtra(EXTRA_CHOOSE_DEVICE, false)) {
            setContent {
                val connections by app.pairing.connections.collectAsStateWithLifecycle()
                val trusted by app.pairing.trustedDevices.collectAsStateWithLifecycle()
                val settings by app.settings.state.collectAsStateWithLifecycle()
                val revision by app.pairing.smartRoutingRevision.collectAsStateWithLifecycle()
                val choices = androidx.compose.runtime.remember(connections, trusted, settings, revision) {
                    destinationChoices(this, app.pairing, BridgeyFeature.SCREEN)
                }
                var selected by rememberSaveable { mutableStateOf<String?>(null) }
                var unavailable by rememberSaveable { mutableStateOf(false) }
                BridgeyTheme {
                    ScreenDestinationSheet(choices, selected, unavailable,
                        select = { selected = it; unavailable = false },
                        continueSharing = {
                            val target = DeviceDestinationSelection.selected(choices, selected)
                            if (target == null || !launchConsent(target.deviceId, target.name, null)) unavailable = true
                        }, cancel = ::finish)
                }
            }
        } else {
            val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID)
            if (deviceId.isNullOrEmpty()) { finish(); return }
            if (savedInstanceState == null && !launchConsent(deviceId, intent.getStringExtra(EXTRA_MAC_NAME).orEmpty(), intent.getStringExtra(EXTRA_REQUEST_ID))) finish()
        }
    }

    /** The chosen identity is rechecked and pinned before requesting fresh Android consent. */
    private fun launchConsent(deviceId: String, macName: String, requestId: String?): Boolean {
        val app = application as BridgeyApplication
        if (!app.isBridgeyEnabled || app.pairing.connections.value.none { it.deviceId == deviceId } ||
            !app.pairing.isFeatureAvailable(BridgeyFeature.SCREEN, deviceId)) return false
        intent.removeExtra(EXTRA_CHOOSE_DEVICE)
        intent.putExtra(EXTRA_DEVICE_ID, deviceId).putExtra(EXTRA_MAC_NAME, macName)
        if (app.screenShare.state.value.phase == ScreenShareState.Phase.IDLE) app.screenShare.markAsking(deviceId, macName)
        ScreenNotifier.dismissAsk(this, deviceId)
        val manager = getSystemService(MediaProjectionManager::class.java)
        return runCatching { consent.launch(manager.createScreenCaptureIntent()); true }.getOrElse {
            app.screenShare.consentDeclined(deviceId, requestId)
            false
        }
    }

    companion object {
        private const val EXTRA_CHOOSE_DEVICE = "dev.bridgey.android.extra.SCREEN_CHOOSE_DEVICE"

        fun chooseIntent(context: Context): Intent = Intent(context, ScreenConsentActivity::class.java)
            .putExtra(EXTRA_CHOOSE_DEVICE, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

        const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.SCREEN_CONSENT_DEVICE_ID"
        const val EXTRA_MAC_NAME = "dev.bridgey.android.extra.SCREEN_CONSENT_MAC_NAME"
        const val EXTRA_REQUEST_ID = "dev.bridgey.android.extra.SCREEN_CONSENT_REQUEST_ID"

        fun intent(context: Context, deviceId: String, macName: String, requestId: String?): Intent =
            Intent(context, ScreenConsentActivity::class.java)
                .putExtra(EXTRA_DEVICE_ID, deviceId)
                .putExtra(EXTRA_MAC_NAME, macName)
                .apply { requestId?.let { putExtra(EXTRA_REQUEST_ID, it) } }
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }
}
