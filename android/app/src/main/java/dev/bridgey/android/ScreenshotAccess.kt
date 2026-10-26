package dev.bridgey.android

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.view.ViewTreeObserver
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Photo access for Settings > Clipboard > Send a fresh screenshot, asked from the app: when the switch
 * is turned on, and on the first in-app send while it is on (it is on by default). Denied turns the
 * setting off and says why; selected photos only (Android 14+) cannot see new screenshots, so the
 * setting goes off and a dialog offers the system Settings. Create it before the activity starts.
 */
internal class ScreenshotAccessController(
    private val activity: ComponentActivity,
    private val settings: () -> BridgeySettings,
) {
    enum class Prompt { PARTIAL, BLOCKED }

    /** The dialog to show, if any. */
    var prompt by mutableStateOf<Prompt?>(null)
        private set

    private val mutableMessages = MutableSharedFlow<String>(extraBufferCapacity = 4)

    /** One-off explanations for the snackbar. */
    val messages: Flow<String> = mutableMessages.asSharedFlow()

    private var enabling = false
    private var afterAnswer: (() -> Unit)? = null

    /** The person went to the system Settings from the dialog: full access on return turns the setting on. */
    private var enableOnReturn = false

    private val launcher = activity.registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { onAnswer() }

    private fun access() = PhotoPermissions.access(activity)

    /** The Settings switch. */
    fun setEnabled(on: Boolean) {
        if (!on) {
            settings().setScreenshotSendEnabled(false)
            return
        }
        when (access()) {
            PhotoAccess.FULL -> settings().setScreenshotSendEnabled(true)
            PhotoAccess.PARTIAL -> prompt = Prompt.PARTIAL
            PhotoAccess.NONE -> {
                enabling = true
                launcher.launch(PhotoPermissions.request)
            }
        }
    }

    /**
     * Before an in-app send: asks for photo access first when the setting is on without it and a
     * screenshot could go to the device ([offersAvailable]); [send] runs either way.
     */
    fun beforeSend(offersAvailable: Boolean, send: () -> Unit) {
        if (!settings().state.value.screenshotSendEnabled || !offersAvailable) return send()
        when (access()) {
            PhotoAccess.FULL -> send()
            PhotoAccess.PARTIAL -> {
                settings().setScreenshotSendEnabled(false)
                prompt = Prompt.PARTIAL
                send()
            }
            PhotoAccess.NONE -> {
                afterAnswer = send
                launcher.launch(PhotoPermissions.request)
            }
        }
    }

    private fun onAnswer() {
        val fromSwitch = enabling
        enabling = false
        when (access()) {
            PhotoAccess.FULL -> if (fromSwitch) settings().setScreenshotSendEnabled(true)
            PhotoAccess.PARTIAL -> {
                settings().setScreenshotSendEnabled(false)
                prompt = Prompt.PARTIAL
            }
            PhotoAccess.NONE -> {
                settings().setScreenshotSendEnabled(false)
                // Turned on again after "Don't ask again": Android shows nothing, so offer its Settings.
                if (fromSwitch && !activity.shouldShowRequestPermissionRationale(PhotoPermissions.main)) {
                    prompt = Prompt.BLOCKED
                } else {
                    mutableMessages.tryEmit(activity.getString(R.string.screenshot_off_denied))
                }
            }
        }
        // The clipboard can be read once the window has focus again, after the system dialog.
        afterAnswer?.let { send -> afterAnswer = null; runWhenFocused(send) }
    }

    fun openSettings() {
        prompt = null
        enableOnReturn = true
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)),
        )
    }

    fun dismiss() {
        prompt = null
    }

    /** From the activity's onResume. */
    fun onResume() {
        if (!enableOnReturn) return
        enableOnReturn = false
        if (access() == PhotoAccess.FULL) settings().setScreenshotSendEnabled(true)
    }

    private fun runWhenFocused(block: () -> Unit) {
        val view = activity.window.decorView
        if (view.hasWindowFocus()) return block()
        view.viewTreeObserver.addOnWindowFocusChangeListener(object : ViewTreeObserver.OnWindowFocusChangeListener {
            override fun onWindowFocusChanged(hasFocus: Boolean) {
                if (!hasFocus) return
                view.viewTreeObserver.removeOnWindowFocusChangeListener(this)
                view.post(block)
            }
        })
    }
}

@Composable
internal fun ScreenshotAccessDialog(controller: ScreenshotAccessController) {
    val prompt = controller.prompt ?: return
    AlertDialog(
        onDismissRequest = controller::dismiss,
        title = { Text(stringResource(R.string.screenshot_access_title)) },
        text = {
            Text(
                stringResource(
                    if (prompt == ScreenshotAccessController.Prompt.PARTIAL) R.string.screenshot_access_partial else R.string.screenshot_access_blocked,
                ),
            )
        },
        confirmButton = { Button(onClick = controller::openSettings) { Text(stringResource(R.string.screenshot_access_open_settings)) } },
        dismissButton = { TextButton(onClick = controller::dismiss) { Text(stringResource(R.string.screenshot_access_not_now)) } },
    )
}
