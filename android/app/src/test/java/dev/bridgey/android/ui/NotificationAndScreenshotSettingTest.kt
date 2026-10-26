package dev.bridgey.android.ui

import android.app.Application
import android.app.Notification
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color as AndroidColor
import android.os.Looper
import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.RemoteViews
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.graphics.ColorUtils
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.R
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.UpdateUiState
import dev.bridgey.android.ui.theme.BridgeyTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The connection notification as the system draws it (DecoratedCustomViewStyle header, our content,
 * the Turn off action) on a light and a dark shade, and Settings > Clipboard with Send a fresh
 * screenshot. The notification is inflated with the app theme, as the system does, so a theme
 * attribute that stays dark on a dark shade fails here. PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class NotificationAndScreenshotSettingTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()

    @Before
    fun setUp() {
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun dark(): Boolean = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    private fun theme() = if (dark()) "dark" else "light"

    private fun directory() = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"

    /** Approximate Android 16 shade cards (neutral Material You surfaces). */
    private fun shadeColor() = if (dark()) AndroidColor.parseColor("#1F1F23") else AndroidColor.parseColor("#F3F1F6")

    private fun notification(): Notification {
        val content = RemoteViews(context.packageName, R.layout.notification_clipboard).apply {
            setTextViewText(R.id.notification_status, "Connected to Work Mac")
            setTextViewText(R.id.notification_send, context.getString(R.string.notification_send_copied_text))
        }
        val turnOff = PendingIntent.getService(context, 4, Intent("off"), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(context, "bridgey_clipboard_v2")
            .setSmallIcon(R.drawable.ic_bridgey_notification)
            .setContentTitle("Bridgey")
            .setContentText("Connected to Work Mac")
            .setStyle(Notification.DecoratedCustomViewStyle())
            .setCustomContentView(content)
            .setCustomBigContentView(content)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, context.getString(R.string.notification_turn_off), turnOff)
            .build()
    }

    private fun renderNotification() {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            var status: TextView? = null
            var send: TextView? = null
            scenario.onActivity { activity ->
                // The system inflates with the app's theme (Theme.Bridgey, a light theme).
                val appThemed = ContextThemeWrapper(activity, R.style.Theme_Bridgey)
                val density = activity.resources.displayMetrics.density
                val card = FrameLayout(activity).apply {
                    background = android.graphics.drawable.GradientDrawable().apply {
                        setColor(shadeColor())
                        cornerRadius = 24 * density
                    }
                }
                val decorated = Notification.Builder.recoverBuilder(appThemed, notification()).createBigContentView()
                val view = decorated.apply(appThemed, card)
                card.addView(view)
                val page = FrameLayout(activity).apply {
                    setBackgroundColor(if (dark()) AndroidColor.BLACK else AndroidColor.parseColor("#DADCE0"))
                    val pad = (12 * density).toInt()
                    setPadding(pad, (48 * density).toInt(), pad, pad)
                    addView(card, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
                }
                activity.setContentView(page)
                status = view.findViewById(R.id.notification_status)
                send = view.findViewById(R.id.notification_send)
            }
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }

            // The status follows the shade: light text on dark, dark text on light, at least 4.5:1.
            val statusColor = status!!.currentTextColor
            val opaque = ColorUtils.compositeColors(statusColor, shadeColor())
            val contrast = ColorUtils.calculateContrast(opaque, shadeColor())
            assertTrue("status contrast $contrast on ${theme()} shade", contrast >= 4.5)
            assertEquals(dark(), ColorUtils.calculateLuminance(opaque) > 0.5)
            assertEquals(View.VISIBLE, status!!.visibility)
            // The button keeps midnight text on the aurora, the same on either shade.
            assertEquals(AndroidColor.parseColor("#050B18"), send!!.currentTextColor)
            assertTrue(send!!.height >= (48 * context.resources.displayMetrics.density).toInt())

            scenario.onActivity { it.window.decorView.captureRoboImage("${directory()}/android-notification-${theme()}.png") }
        }
    }

    @Test fun notificationLight() = renderNotification()

    @Test @Config(qualifiers = "+night") fun notificationDark() = renderNotification()

    @Test
    fun buttonLabelContrastOnTheAurora() {
        val midnight = AndroidColor.parseColor("#050B18")
        listOf("#9B7CFF", "#54C7F5", "#5EF2B2").forEach { stop ->
            val contrast = ColorUtils.calculateContrast(midnight, AndroidColor.parseColor(stop))
            assertTrue("midnight on $stop is $contrast", contrast >= 4.5)
        }
    }

    private fun settingsClipboard(screenshotOn: Boolean, filesOn: Boolean = true, suffix: String = "") {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.enableEdgeToEdge()
                activity.setContent {
                    BridgeyTheme {
                        SettingsScreen(
                            state = SettingsState(
                                deviceName = "OnePlus 11",
                                connectionStatus = "Connected to Work Mac",
                                connected = true,
                                pairedCount = 2,
                                globalFeatures = BridgeyFeature.entries.associateWith { true },
                                directCallsEnabled = true,
                                autoClipboardEnabled = true,
                                backgroundClipboardEnabled = false,
                                backgroundClipboardStatus = dev.bridgey.android.BackgroundClipboardStatus.READY,
                                backgroundClipboardCommand = "",
                                clipboardFilesEnabled = filesOn,
                                screenshotSendEnabled = screenshotOn,
                                tileAddSupported = true,
                                tileAdded = true,
                                notificationAppsEnabled = 12,
                                notificationAppsTotal = 48,
                                appNotificationsEnabled = true,
                                notificationAccessEnabled = true,
                                reduceMotion = false,
                                showPreviews = true,
                                activityCount = 6,
                                update = UpdateUiState(channel = UpdateChannel.STABLE, lastCheckedAt = 0L),
                                installedVersion = "0.8.0",
                                now = 0L,
                            ),
                            actions = SettingsActions(),
                            section = SettingsSection.CLIPBOARD,
                        )
                    }
                }
                val density = activity.resources.displayMetrics.density
                val insets = WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, (40 * density).toInt(), 0, 0))
                    .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, (24 * density).toInt()))
                    .build()
                ViewCompat.dispatchApplyWindowInsets(activity.window.decorView, insets)
            }
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            scenario.onActivity { it.window.decorView.captureRoboImage("${directory()}/android-settings-clipboard$suffix-${theme()}.png") }
        }
    }

    @Test fun settingsClipboardLight() = settingsClipboard(screenshotOn = true)

    @Test @Config(qualifiers = "+night") fun settingsClipboardDark() = settingsClipboard(screenshotOn = true)

    @Test fun settingsClipboardScreenshotOffLight() = settingsClipboard(screenshotOn = false, suffix = "-screenshot-off")

    @Test @Config(qualifiers = "+night") fun settingsClipboardFilesOffDark() =
        settingsClipboard(screenshotOn = true, filesOn = false, suffix = "-files-off")
}
