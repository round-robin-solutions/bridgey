package dev.bridgey.android.camera

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.FileProvider
import dev.bridgey.android.BridgeyApplication
import dev.bridgey.android.R
import dev.bridgey.android.ui.CameraPhase
import dev.bridgey.android.ui.CameraScreen
import dev.bridgey.android.ui.CameraUiActions
import dev.bridgey.android.ui.CameraUiState
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The full-screen camera for one Mac's photo request. It opens only from a tap on Bridgey's
 * notification or while Bridgey is already in front, never over the lock screen. One shutter;
 * the photo goes to that Mac as an ordinary file and leaves the cache once the Mac saved it.
 */
class CameraActivity : ComponentActivity() {
    private var request: CameraRequest? = null
    private var ui by mutableStateOf(CameraUiState("Mac", CameraPhase.STARTING))
    private var capture: ImageCapture? = null
    private var previewView: PreviewView? = null
    private var openedSent = false

    /** The Mac heard how this ended (sent, cancelled, failed): nothing more to say. */
    private var outcomeSent = false

    private val permissionLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            startCamera()
        } else {
            ui = ui.copy(phase = CameraPhase.NEEDS_PERMISSION, permanentlyDenied = !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA))
            request?.let { pairing().sendCameraStatus(it.deviceId, it.requestId, CameraStatus.PERMISSION_REQUIRED) }
        }
    }

    private fun pairing() = (application as BridgeyApplication).pairing

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val app = application as BridgeyApplication
        if (!app.isPrimaryUser) { finish(); return }
        val deviceId = intent?.getStringExtra(EXTRA_DEVICE_ID).orEmpty()
        val requestId = intent?.getStringExtra(EXTRA_REQUEST_ID).orEmpty()
        CameraNotifier.dismiss(this, deviceId)
        removeOldPhotos(cacheDir)
        val current = app.pairing.camera.current(deviceId, requestId)
        request = current
        ui = when {
            current == null -> CameraUiState(intent?.getStringExtra(EXTRA_MAC_NAME) ?: "Mac", CameraPhase.ENDED)
            hasCameraPermission() -> CameraUiState(current.macName, CameraPhase.STARTING)
            else -> CameraUiState(current.macName, CameraPhase.NEEDS_PERMISSION)
        }
        previewView = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        setContent {
            BridgeyTheme {
                CameraScreen(
                    ui,
                    CameraUiActions(
                        shutter = ::takePhoto,
                        cancel = ::cancel,
                        allow = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                        openAppSettings = {
                            runCatching {
                                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
                            }
                        },
                    ),
                    preview = { previewView?.let { view -> AndroidView(factory = { view }) } },
                )
            }
        }
        // Back cancels the request, like the close button.
        onBackPressedDispatcher.addCallback(this, object : androidx.activity.OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = cancel()
        })
        if (current != null && ui.phase == CameraPhase.STARTING) startCamera()
    }

    override fun onResume() {
        super.onResume()
        // Allowed in app settings and back: the request may still be open.
        if (ui.phase == CameraPhase.NEEDS_PERMISSION && hasCameraPermission() && request != null) startCamera()
    }

    override fun onDestroy() {
        if (isFinishing && !outcomeSent) sendOutcome(CameraStatus.CANCELLED)
        super.onDestroy()
    }

    private fun hasCameraPermission() = checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun startCamera() {
        val view = previewView ?: return
        ui = ui.copy(phase = CameraPhase.STARTING, problem = null)
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val started = runCatching {
                val provider = future.get()
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val imageCapture = ImageCapture.Builder().setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY).build()
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageCapture)
                capture = imageCapture
            }.isSuccess
            if (!started) {
                ui = ui.copy(phase = CameraPhase.FAILED, problem = getString(R.string.camera_unavailable))
                sendOutcome(CameraStatus.FAILED)
                return@addListener
            }
            ui = ui.copy(phase = CameraPhase.READY)
            val current = request
            if (!openedSent && current != null) {
                openedSent = true
                pairing().sendCameraStatus(current.deviceId, current.requestId, CameraStatus.OPENED)
            }
        }, androidx.core.content.ContextCompat.getMainExecutor(this))
    }

    private fun takePhoto() {
        val current = request ?: return
        val imageCapture = capture ?: return
        if (pairing().camera.current(current.deviceId, current.requestId) == null) {
            ui = ui.copy(phase = CameraPhase.ENDED)
            outcomeSent = true
            return
        }
        ui = ui.copy(phase = CameraPhase.CAPTURING, problem = null)
        val folder = File(cacheDir, CACHE_FOLDER).apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val file = File(folder, "Photo-$stamp.jpg")
        imageCapture.takePicture(
            ImageCapture.OutputFileOptions.Builder(file).build(),
            androidx.core.content.ContextCompat.getMainExecutor(this),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) = send(current, file)

                override fun onError(exception: ImageCaptureException) {
                    file.delete()
                    ui = ui.copy(phase = CameraPhase.READY, problem = getString(R.string.camera_capture_failed))
                }
            },
        )
    }

    private fun send(current: CameraRequest, file: File) {
        val pairing = pairing()
        val uri = runCatching { FileProvider.getUriForFile(this, "$packageName.fileprovider", file) }.getOrNull()
        ui = ui.copy(phase = CameraPhase.SENDING)
        pairing.sendCameraStatus(current.deviceId, current.requestId, CameraStatus.SENDING)
        val queued = uri != null && pairing.sendCameraPhoto(current, uri) { saved ->
            // Saved on the Mac: the photo leaves this phone. A failed one stays for Retry, and is
            // removed the next time the camera opens.
            if (saved) file.delete() else pairing.sendCameraStatus(current.deviceId, current.requestId, CameraStatus.FAILED)
        }
        outcomeSent = true
        if (!queued) {
            file.delete()
            pairing.sendCameraStatus(current.deviceId, current.requestId, CameraStatus.FAILED)
            pairing.camera.finish(current.deviceId, current.requestId)
            ui = ui.copy(phase = CameraPhase.FAILED, problem = getString(R.string.camera_send_failed, current.macName))
            return
        }
        Toast.makeText(applicationContext, getString(R.string.camera_sending, current.macName), Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun cancel() {
        if (!outcomeSent) sendOutcome(CameraStatus.CANCELLED)
        finish()
    }

    private fun sendOutcome(status: CameraStatus) {
        val current = request ?: return
        outcomeSent = true
        val pairing = pairing()
        if (pairing.camera.finish(current.deviceId, current.requestId)) pairing.sendCameraStatus(current.deviceId, current.requestId, status)
    }

    companion object {
        const val EXTRA_DEVICE_ID = "dev.bridgey.android.extra.CAMERA_DEVICE_ID"
        const val EXTRA_REQUEST_ID = "dev.bridgey.android.extra.CAMERA_REQUEST_ID"
        const val EXTRA_MAC_NAME = "dev.bridgey.android.extra.CAMERA_MAC_NAME"
        const val CACHE_FOLDER = "camera"

        fun intent(context: Context, request: CameraRequest): Intent = Intent(context, CameraActivity::class.java)
            .putExtra(EXTRA_DEVICE_ID, request.deviceId)
            .putExtra(EXTRA_REQUEST_ID, request.requestId)
            .putExtra(EXTRA_MAC_NAME, request.macName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

        /** Photos left from failed sends go after an hour. */
        fun removeOldPhotos(cacheDir: File, now: Long = System.currentTimeMillis()) {
            File(cacheDir, CACHE_FOLDER).listFiles()?.forEach { if (now - it.lastModified() > 60 * 60_000L) it.delete() }
        }
    }
}

/** The notifications that lead to the camera: one per Mac, gone when the request ends. */
object CameraNotifier {
    private const val CHANNEL_ID = "bridgey_camera_v1"

    private fun id(deviceId: String) = 68_000 + (deviceId.hashCode() and 0xFFF)

    private fun channel(context: Context, manager: NotificationManager) {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, context.getString(R.string.camera_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                description = context.getString(R.string.camera_channel_detail)
            },
        )
    }

    /** The phone is locked: tapping asks for the unlock first, then opens the camera. */
    fun showLocked(context: Context, request: CameraRequest) =
        show(context, request, context.getString(R.string.camera_unlock_title), context.getString(R.string.camera_unlock_text, request.macName))

    /** Unlocked but Bridgey is not in front: Android needs a tap to open the camera. */
    fun showAsk(context: Context, request: CameraRequest) =
        show(context, request, context.getString(R.string.camera_ask_title, request.macName), context.getString(R.string.camera_ask_text))

    private fun show(context: Context, request: CameraRequest, title: String, text: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        channel(context, manager)
        val pending = PendingIntent.getActivity(
            context, id(request.deviceId), CameraActivity.intent(context, request),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(pending)
            .addAction(Notification.Action.Builder(null, context.getString(R.string.camera_take_photo), pending).build())
            .setAutoCancel(true)
            .setTimeoutAfter(CAMERA_REQUEST_LIFETIME_MILLIS)
            .build()
        runCatching { manager.notify(id(request.deviceId), notification) }
    }

    fun dismiss(context: Context, deviceId: String) {
        if (deviceId.isNotEmpty()) context.getSystemService(NotificationManager::class.java).cancel(id(deviceId))
    }
}
