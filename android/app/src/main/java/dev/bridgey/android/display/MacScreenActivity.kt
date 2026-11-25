package dev.bridgey.android.display

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.PowerManager
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.ui.MacScreenActions
import dev.bridgey.android.ui.MacScreenScreen
import dev.bridgey.android.ui.theme.BridgeyTheme

/**
 * A Mac's screen on this phone, in its own activity so rotating keeps the surface and the decoder (configChanges in
 * the manifest). The stream runs only while this screen is shown: leaving it, or the phone's screen turning off,
 * stops the stream, and coming back shows Start again rather than starting by itself.
 */
class MacScreenActivity : ComponentActivity() {
    private lateinit var hub: DisplayViewerHub
    private lateinit var surfaceView: SurfaceView

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val app = application as BridgeyApplication
        val deviceId = intent?.getStringExtra(EXTRA_DEVICE_ID)
        if (!app.isPrimaryUser || deviceId.isNullOrEmpty()) {
            finish()
            return
        }
        val macName = intent?.getStringExtra(EXTRA_MAC_NAME) ?: "Mac"
        hub = app.display
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        surfaceView = SurfaceView(this).apply {
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) = hub.surface(holder.surface)
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
                override fun surfaceDestroyed(holder: SurfaceHolder) = hub.surface(null)
            })
        }
        setContent {
            BridgeyTheme {
                val state by hub.state.collectAsStateWithLifecycle()
                MacScreenScreen(
                    state = state,
                    actions = MacScreenActions(
                        back = ::finish,
                        stop = { hub.close(DisplayStopReason.USER) },
                        startAgain = hub::startAgain,
                        control = { on -> if (on) hub.beginControl() else hub.endControl() },
                        input = hub::input,
                        press = hub::press,
                    ),
                    picture = { modifier -> AndroidView(factory = { surfaceView }, modifier = modifier) },
                )
            }
        }
        // A new viewer asks again; a restored one (the process came back) does too, never resuming a stream.
        if (savedInstanceState == null || hub.state.value.deviceId != deviceId || !hub.state.value.streaming) hub.open(deviceId, macName)
    }

    override fun onStop() {
        super.onStop()
        if (!::hub.isInitialized || isChangingConfigurations) return
        val interactive = getSystemService(PowerManager::class.java)?.isInteractive != false
        hub.close(if (interactive) DisplayStopReason.LEFT_SCREEN else DisplayStopReason.SCREEN_OFF)
    }

    companion object {
        private const val EXTRA_DEVICE_ID = "deviceId"
        private const val EXTRA_MAC_NAME = "macName"

        fun intent(context: Context, deviceId: String, macName: String): Intent =
            Intent(context, MacScreenActivity::class.java)
                .putExtra(EXTRA_DEVICE_ID, deviceId)
                .putExtra(EXTRA_MAC_NAME, macName)

        fun open(context: Context, deviceId: String, macName: String) {
            val intent = intent(context, deviceId, macName)
            if (context !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching { context.startActivity(intent) }
        }
    }
}
