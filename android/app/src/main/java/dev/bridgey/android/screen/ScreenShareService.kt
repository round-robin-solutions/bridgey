package dev.bridgey.android.screen

import android.app.Activity
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.LogCategory
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * The foreground service a share runs in (type mediaProjection). Android 14+ order: the consent result
 * arrives, this service goes to the foreground with the mediaProjection type, and only then takes the
 * projection; its callback is registered before the VirtualDisplay is made. The ongoing notification with
 * Stop stays for as long as the service runs. The screen turning off ends the share.
 */
class ScreenShareService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var projection: MediaProjection? = null
    private var capture: ScreenCapture? = null
    private var ticker: ScheduledExecutorService? = null
    private var stream: ScreenStream? = null
    private var screenOffRegistered = false

    private val screenOff = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) stream?.stop(ScreenStopReason.SCREEN_OFF)
        }
    }

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // The status bar Stop, another app capturing, or the shared app closing.
            stream?.stop(ScreenStopReason.ENDED)
        }

        override fun onCapturedContentResize(width: Int, height: Int) {
            capture?.capturedContentResized(width, height)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as BridgeyApplication
        if (intent?.action != ACTION_START || stream != null) {
            if (stream == null) stopSelf()
            return START_NOT_STICKY
        }
        val deviceId = intent.getStringExtra(EXTRA_DEVICE_ID).orEmpty()
        val macName = intent.getStringExtra(EXTRA_MAC_NAME).orEmpty()
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID)
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        @Suppress("DEPRECATION")
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java) else intent.getParcelableExtra(EXTRA_RESULT_DATA)
        val notification = ScreenNotifier.sharing(this, macName, sharing = false)
        // Foreground with the mediaProjection type before the projection is taken (Android 14 rule).
        val foreground = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(ScreenNotifier.SHARING_NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(ScreenNotifier.SHARING_NOTIFICATION_ID, notification)
            }
        }.onFailure { BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "SCREEN foreground refused", it) }.isSuccess
        val taken = if (foreground && data != null) {
            runCatching { getSystemService(MediaProjectionManager::class.java).getMediaProjection(resultCode, data) }
                .onFailure { BridgeyLogging.w(LogCategory.REMOTE_CONTROL, "SCREEN projection refused", it) }.getOrNull()
        } else null
        if (taken == null) {
            requestId?.let { app.pairing.sendScreenStatus(deviceId, it, ScreenStatus.FAILED) }
            app.screenShare.streamEnded = {}
            app.screenShare.stop(ScreenStopReason.FAILED)
            finish()
            return START_NOT_STICKY
        }
        val created = app.screenShare.begin(deviceId, macName, requestId)
        if (created == null) {
            taken.stop()
            finish()
            return START_NOT_STICKY
        }
        val captureThread = HandlerThread("bridgey-screen-capture").also { it.start() }
        val handler = Handler(captureThread.looper)
        thread = captureThread
        projection = taken
        stream = created
        // Registered before the VirtualDisplay exists, as Android 14 requires.
        taken.registerCallback(projectionCallback, handler)
        app.screenShare.streamEnded = { main.post(::finish) }
        val hubStarted = created.onStarted
        created.onStarted = {
            hubStarted()
            ScreenNotifier.updateSharing(this, macName, sharing = true)
        }
        androidx.core.content.ContextCompat.registerReceiver(this, screenOff, IntentFilter(Intent.ACTION_SCREEN_OFF), androidx.core.content.ContextCompat.RECEIVER_NOT_EXPORTED)
        screenOffRegistered = true
        val newCapture = ScreenCapture(this, taken, created, handler) { reason -> created.stop(reason) }
        capture = newCapture
        handler.post { newCapture.start() }
        ticker = Executors.newSingleThreadScheduledExecutor { runnable -> Thread(runnable, "bridgey-screen-ticker") }.also {
            it.scheduleWithFixedDelay({ runCatching { created.tick() } }, 1, 1, TimeUnit.SECONDS)
        }
        return START_NOT_STICKY
    }

    /** Tears everything down once; the stream has already ended (or never started). */
    private fun finish() {
        ticker?.shutdownNow()
        ticker = null
        capture?.release()
        capture = null
        projection?.let { current ->
            runCatching { current.unregisterCallback(projectionCallback) }
            runCatching { current.stop() }
        }
        projection = null
        if (screenOffRegistered) {
            runCatching { unregisterReceiver(screenOff) }
            screenOffRegistered = false
        }
        thread?.quitSafely()
        thread = null
        stream = null
        (application as BridgeyApplication).screenShare.streamEnded = {}
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        // Killed or stopped from outside: the Mac hears it, then everything goes.
        stream?.let { if (it.phase != ScreenStreamPhase.ENDED) it.stop(ScreenStopReason.FAILED) }
        if (projection != null || capture != null) finish()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "dev.bridgey.android.action.SCREEN_SHARE_START"
        private const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.SCREEN_SERVICE_DEVICE_ID"
        private const val EXTRA_MAC_NAME = "dev.bridgey.android.extra.SCREEN_SERVICE_MAC_NAME"
        private const val EXTRA_REQUEST_ID = "dev.bridgey.android.extra.SCREEN_SERVICE_REQUEST_ID"
        private const val EXTRA_RESULT_CODE = "dev.bridgey.android.extra.SCREEN_SERVICE_RESULT_CODE"
        private const val EXTRA_RESULT_DATA = "dev.bridgey.android.extra.SCREEN_SERVICE_RESULT_DATA"

        fun startIntent(context: Context, deviceId: String, macName: String, requestId: String?, resultCode: Int, data: Intent): Intent =
            Intent(context, ScreenShareService::class.java).setAction(ACTION_START)
                .putExtra(EXTRA_DEVICE_ID, deviceId)
                .putExtra(EXTRA_MAC_NAME, macName)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, data)
                .apply { requestId?.let { putExtra(EXTRA_REQUEST_ID, it) } }
    }
}
