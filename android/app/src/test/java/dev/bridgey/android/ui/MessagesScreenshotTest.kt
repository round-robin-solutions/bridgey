package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.setup.PermissionCatalog
import dev.bridgey.android.setup.PermissionFacts
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupFeatures
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupState
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.util.Calendar
import java.util.TimeZone
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Text messages: its Settings page (on, SMS allowed, contacts not yet, a dual-SIM phone), the setup
 * follow-up, and the Permissions page with SMS and Contacts, light and dark at the design's phone
 * size. Always rendered; PNGs only with -Pscreenshots=<dir>.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class MessagesScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 27, 9, 41, 20)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private val theme: String
        get() {
            val night = ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
            return if (night) "dark" else "light"
        }

    private fun capture(name: String, content: @Composable () -> Unit) {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.enableEdgeToEdge()
                activity.setContent { BridgeyTheme { content() } }
                val density = activity.resources.displayMetrics.density
                val insets = WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, (40 * density).toInt(), 0, 0))
                    .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, (24 * density).toInt()))
                    .build()
                ViewCompat.dispatchApplyWindowInsets(activity.window.decorView, insets)
            }
            repeat(3) { shadowOf(Looper.getMainLooper()).idle() }
            val directory = System.getProperty("bridgey.screenshots") ?: "build/outputs/roborazzi"
            scenario.onActivity { it.window.decorView.captureRoboImage("$directory/android-$name-$theme.png") }
        }
    }

    private fun settingsPage() = capture("sms-settings") {
        SettingsScreen(
            state = sampleSettingsState(now).copy(
                messages = MessagesSettingsState(smsAllowed = true, contactsAllowed = false, dualSim = true, simsAllowed = true, replyAsSms = false),
            ),
            actions = SettingsActions(),
            section = SettingsSection.MESSAGES,
        )
    }

    @Test fun settingsPageLight() = settingsPage()

    @Test @Config(qualifiers = "+night") fun settingsPageDark() = settingsPage()

    /** Turned on, nothing allowed yet: the warnings and Allow buttons. */
    private fun settingsNeedsAccess() = capture("sms-settings-needs-access") {
        SettingsScreen(
            state = sampleSettingsState(now).copy(messages = MessagesSettingsState(dualSim = false)),
            actions = SettingsActions(),
            section = SettingsSection.MESSAGES,
        )
    }

    @Test fun settingsNeedsAccessLight() = settingsNeedsAccess()

    @Test @Config(qualifiers = "+night") fun settingsNeedsAccessDark() = settingsNeedsAccess()

    private val facts = SetupFacts(
        paired = true,
        current = SetupFeatures.all.flatMap { it.settings }.associateWith { "false" },
        granted = setOf(PermissionKind.POST_NOTIFICATIONS),
        dualSim = true,
    )

    private fun question() = capture("sms-setup-question") {
        val flow = listOf(SetupEvent.ChooseAdvanced, SetupEvent.StartQuestions(SetupBundles.answers(setOf("messages"), emptyMap())))
            .fold(SetupState()) { state, event -> SetupFlow.reduce(state, event, facts) }
        SetupScreen(
            SetupUiState(flow, sampleSettingsState(now), listOf("Personal Mac"), facts = facts, pickedBundles = setOf("messages")),
            SetupActions(),
        )
    }

    @Test fun questionLight() = question()

    @Test @Config(qualifiers = "+night") fun questionDark() = question()

    private fun permissions() = capture("sms-permissions") {
        val entries = PermissionCatalog.entries(
            PermissionFacts(
                sdkInt = 35, labBuild = false,
                granted = setOf(PermissionKind.NOTIFICATION_ACCESS, PermissionKind.POST_NOTIFICATIONS, PermissionKind.SMS, PermissionKind.BATTERY),
                smsOn = true, dualSim = true,
            ),
        )
        PermissionsScreen(entries.filter { it.kind in setOf(PermissionKind.PHONE_CALLS, PermissionKind.SMS, PermissionKind.CONTACTS) } + entries.filterNot { it.kind in setOf(PermissionKind.PHONE_CALLS, PermissionKind.SMS, PermissionKind.CONTACTS) }, onBack = {}, onManage = {})
    }

    @Test fun permissionsLight() = permissions()

    @Test @Config(qualifiers = "+night") fun permissionsDark() = permissions()

    @Test fun textMessagesIsOnInTheSample() {
        org.junit.Assert.assertTrue(sampleSettingsState(now).featureOn(BridgeyFeature.SMS))
    }
}
