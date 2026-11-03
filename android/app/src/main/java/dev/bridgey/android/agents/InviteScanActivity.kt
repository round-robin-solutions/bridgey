package dev.bridgey.android.agents

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import dev.bridgey.android.MainActivity
import dev.bridgey.android.R
import dev.bridgey.android.ui.BarIconButton
import dev.bridgey.android.ui.BridgeyIcons
import dev.bridgey.android.ui.motion.springIn
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Scans the QR code bridgey pair shows in the terminal (ZXing on the camera's luminance plane, light-on-dark codes
 * too). A bridgey://pair link opens Bridgey's "Pair with <name>?"; anything else is ignored. Nothing is stored.
 */
class InviteScanActivity : ComponentActivity() {
    private val analysis = Executors.newSingleThreadExecutor()
    private val found = AtomicBoolean(false)
    private var previewView: PreviewView? = null

    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val view = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        previewView = view
        setContent {
            BridgeyTheme {
                Box(Modifier.fillMaxSize().background(Color.Black)) {
                    AndroidView(factory = { view }, modifier = Modifier.fillMaxSize())
                    BarIconButton(
                        BridgeyIcons.Close, stringResource(R.string.action_close), { finish() },
                        modifier = Modifier.align(Alignment.TopStart).statusBarsPadding().padding(4.dp),
                    )
                    Text(
                        stringResource(R.string.agent_invite_scan_hint),
                        style = BridgeyType.bodyText,
                        color = Color.White,
                        modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(24.dp).springIn()
                            .clip(RoundedCornerShape(16.dp)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 16.dp, vertical = 10.dp),
                    )
                }
            }
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera()
        else permission.launch(Manifest.permission.CAMERA)
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = runCatching { future.get() }.getOrNull() ?: return@addListener finish()
            val preview = Preview.Builder().build().also { it.surfaceProvider = previewView?.surfaceProvider }
            val imageAnalysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            val reader = QRCodeReader()
            imageAnalysis.setAnalyzer(analysis) { image -> decode(reader, image) }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, imageAnalysis)
            }.onFailure { finish() }
        }, androidx.core.content.ContextCompat.getMainExecutor(this))
    }

    private fun decode(reader: QRCodeReader, image: ImageProxy) {
        try {
            if (found.get()) return
            val plane = image.planes[0]
            val buffer = plane.buffer
            val data = ByteArray(buffer.remaining()).also(buffer::get)
            val source = PlanarYUVLuminanceSource(data, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
            val text = runCatching { reader.decode(BinaryBitmap(HybridBinarizer(source)), HINTS).text }.getOrNull()
            reader.reset()
            if (text != null && text.startsWith(INVITE_SCHEME_PREFIX, ignoreCase = true) && found.compareAndSet(false, true)) {
                runOnUiThread {
                    startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(text), this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                    finish()
                }
            }
        } finally {
            image.close()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        analysis.shutdown()
    }

    private companion object {
        val HINTS = mapOf(
            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
            DecodeHintType.TRY_HARDER to true,
            // Terminal codes are often light on dark.
            DecodeHintType.ALSO_INVERTED to true,
        )
    }
}
