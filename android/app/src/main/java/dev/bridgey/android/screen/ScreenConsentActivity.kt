package dev.bridgey.android.screen

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import androidx.activity.ComponentActivity
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
        if (result.resultCode == Activity.RESULT_OK && data != null && deviceId.isNotEmpty()) {
            app.screenShare.consentGranted(this, deviceId, macName, requestId, result.resultCode, data)
        } else {
            app.screenShare.consentDeclined(deviceId, requestId)
        }
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as BridgeyApplication
        if (!app.isPrimaryUser || intent.getStringExtra(EXTRA_DEVICE_ID).isNullOrEmpty()) { finish(); return }
        if (savedInstanceState != null) return
        val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID).orEmpty()
        // From the notification: the hub learns the dialog is open (it is already when the app opened it).
        if (app.screenShare.state.value.phase == ScreenShareState.Phase.IDLE) {
            app.screenShare.markAsking(deviceId, intent.getStringExtra(EXTRA_MAC_NAME).orEmpty())
        }
        ScreenNotifier.dismissAsk(this, deviceId)
        val manager = getSystemService(MediaProjectionManager::class.java)
        runCatching { consent.launch(manager.createScreenCaptureIntent()) }.onFailure {
            app.screenShare.consentDeclined(deviceId, intent.getStringExtra(EXTRA_REQUEST_ID))
            finish()
        }
    }

    companion object {
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
