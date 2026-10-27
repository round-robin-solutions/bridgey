package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.Box
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.codes.CodeAccessStatus
import dev.bridgey.android.codes.CodeLinkMac
import dev.bridgey.android.setup.OemBattery
import dev.bridgey.android.setup.PermissionCatalog
import dev.bridgey.android.setup.PermissionFacts
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.QuickStep
import dev.bridgey.android.setup.ResetChoice
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupFacts
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
 * v0.10 setup, permissions, reset, What's new, OEM checklist, Codes link picker and Obtainium, at
 * the design's 412 x 915 dp phone size, light and dark. PNGs are written only with -Pscreenshots=<dir>,
 * as android-<screen>-<light|dark>.png.
 */
@OptIn(ExperimentalRoborazziApi::class)
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class SetupScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 27, 10, 30, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private val oem = OemBattery.checklist("OnePlus", "OnePlus")

    private val settings: SettingsState
        get() = sampleSettingsState(now).copy(
            update = sampleSettingsState(now).update.copy(channel = UpdateChannel.BETA),
            codes = CodesSettingsState(
                access = CodeAccessStatus.HIDDEN,
                linkApplies = true,
                linked = true,
                linkTargets = listOf(CodeLinkMac("personal", "Personal Mac"), CodeLinkMac("work", "Work MacBook")),
                linkTarget = CodeLinkMac("personal", "Personal Mac"),
                linkedMac = CodeLinkMac("personal", "Personal Mac"),
            ),
            setup = SetupSettingsState(oem = oem),
        )

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    private fun theme(): String {
        val night = ApplicationProvider.getApplicationContext<Application>().resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
        return if (night) "dark" else "light"
    }

    /** [dialog]: capture every window, so the dialog is in the picture with the page behind it. */
    private fun capture(name: String, dialog: Boolean = false, content: @Composable () -> Unit) {
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
            val file = "$directory/android-$name-${theme()}.png"
            if (dialog) {
                captureScreenRoboImage(file)
            } else {
                scenario.onActivity { it.window.decorView.captureRoboImage(file) }
            }
        }
    }

    private fun setup(name: String, flow: SetupState, settings: SettingsState = this.settings, paired: List<String> = emptyList(), nearby: List<SetupNearbyMac> = emptyList()) =
        capture(name) { SetupScreen(SetupUiState(flow, settings, paired, nearby, oem), SetupActions()) }

    private fun flow(vararg events: SetupEvent) = events.fold(SetupState()) { state, event -> SetupFlow.reduce(state, event) }

    private fun welcome() = setup("setup-welcome", SetupState())

    @Test fun welcomeLight() = welcome()

    @Test @Config(qualifiers = "+night") fun welcomeDark() = welcome()

    private fun quickPair() = setup(
        "setup-quick-pair", flow(SetupEvent.ChooseQuick),
        nearby = listOf(SetupNearbyMac("a", "Personal Mac", paired = false), SetupNearbyMac("b", "Mac mini", paired = false)),
    )

    @Test fun quickPairLight() = quickPair()

    @Test @Config(qualifiers = "+night") fun quickPairDark() = quickPair()

    private fun quickNotifications() = setup(
        "setup-quick-notifications", flow(SetupEvent.ChooseQuick, SetupEvent.Next),
        settings = settings.copy(notificationAccessEnabled = false), paired = listOf("Personal Mac"),
    )

    @Test fun quickNotificationsLight() = quickNotifications()

    @Test @Config(qualifiers = "+night") fun quickNotificationsDark() = quickNotifications()

    /** The battery step with OnePlus's checklist (the OEM checklist in setup). */
    private fun quickBattery() = setup(
        "setup-quick-battery", flow(SetupEvent.ChooseQuick, SetupEvent.Next, SetupEvent.Next),
        settings = settings.copy(batteryExempt = false), paired = listOf("Personal Mac"),
    )

    @Test fun quickBatteryLight() = quickBattery()

    @Test @Config(qualifiers = "+night") fun quickBatteryDark() = quickBattery()

    private val paired = listOf("Personal Mac", "Work MacBook")

    private fun facts(flowSettings: SettingsState = settings, granted: Set<PermissionKind> = emptySet()) = SetupFacts(
        paired = true,
        current = mapOf(dev.bridgey.android.setup.SetupSetting.FEATURE_REMOTE_INPUT to "false"),
        granted = granted,
        duplicateApps = listOf("com.whatsapp" to "WhatsApp", "org.telegram.messenger" to "Telegram", "com.Slack" to "Slack", "com.microsoft.teams" to "Microsoft Teams"),
        codesLinkApplies = true,
    )

    private fun questions(name: String, flow: SetupState, typedText: String = "", picked: Set<String> = emptySet(), dialog: Boolean = false) =
        capture(name, dialog) {
            SetupScreen(
                SetupUiState(flow, settings.copy(batteryExempt = false), paired, emptyList(), oem, facts = facts(), typedText = typedText, pickedBundles = picked),
                SetupActions(),
            )
        }

    /** The flow at question [id], having said Not now to the ones before it. */
    private fun at(id: String, answers: Map<String, String> = emptyMap()): SetupState {
        var state = SetupFlow.reduce(SetupFlow.reduce(SetupState(), SetupEvent.ChooseAdvanced), SetupEvent.StartQuestions(), facts())
        while ((state.screen as? dev.bridgey.android.setup.SetupScreen.Question)?.id != id) {
            val current = (state.screen as dev.bridgey.android.setup.SetupScreen.Question).id
            state = answers[current]?.let { SetupFlow.reduce(state, SetupEvent.Answer(current, it), facts(granted = PermissionKind.entries.toSet())) }
                ?: SetupFlow.reduce(state, SetupEvent.NotNow, facts())
        }
        return state
    }

    private fun intro() = questions("setup-intro-typed", flow(SetupEvent.ChooseAdvanced), typedText = "I mainly want my WhatsApp notifications and to send photos to my Mac", picked = setOf("clipboard"))

    @Test fun introLight() = intro()

    @Test @Config(qualifiers = "+night") fun introDark() = intro()

    private fun clipboardQuestion() = questions("setup-question-clipboard", at("clipboard"))

    @Test fun clipboardQuestionLight() = clipboardQuestion()

    @Test @Config(qualifiers = "+night") fun clipboardQuestionDark() = clipboardQuestion()

    private fun appsQuestion() = questions("setup-question-apps", at("notification_apps"))

    @Test fun appsQuestionLight() = appsQuestion()

    @Test @Config(qualifiers = "+night") fun appsQuestionDark() = appsQuestion()

    private fun updatesQuestion() = questions("setup-question-updates", at("updates").copy(answers = mapOf("updates" to "early")))

    @Test fun updatesQuestionLight() = updatesQuestion()

    @Test @Config(qualifiers = "+night") fun updatesQuestionDark() = updatesQuestion()

    /** Calls: Yes needs Phone and calls, asked right after the answer. */
    private fun permission() = questions(
        "setup-question-permission",
        SetupFlow.reduce(at("calls"), SetupEvent.Answer("calls", "yes"), facts()),
    )

    @Test fun permissionLight() = permission()

    @Test @Config(qualifiers = "+night") fun permissionDark() = permission()

    /** Not allowed: the next card says so in one line. */
    private fun deniedNote() = questions(
        "setup-question-denied-note",
        SetupFlow.reduce(SetupFlow.reduce(at("calls"), SetupEvent.Answer("calls", "yes"), facts()), SetupEvent.PermissionResult(false), facts()),
    )

    @Test fun deniedNoteLight() = deniedNote()

    @Test @Config(qualifiers = "+night") fun deniedNoteDark() = deniedNote()

    private fun summaryState(): SetupState {
        var state = at("updates", mapOf("clipboard" to "auto", "notifications" to "yes", "notification_apps" to "picked:com.whatsapp,org.telegram.messenger", "files" to "yes"))
        state = SetupFlow.reduce(state, SetupEvent.Answer("updates", "early"), facts())
        state = state.copy(answers = state.answers + ("calls" to "yes"), denied = mapOf("calls" to PermissionKind.PHONE_CALLS), summaryOff = setOf("files"))
        while (state.screen != dev.bridgey.android.setup.SetupScreen.Summary) state = SetupFlow.reduce(state, SetupEvent.NotNow, facts())
        return state
    }

    private fun summary() = questions("setup-summary", summaryState())

    @Test fun summaryLight() = summary()

    @Test @Config(qualifiers = "+night") fun summaryDark() = summary()

    private fun leave() = questions("setup-leave", at("files", mapOf("clipboard" to "auto")).copy(confirmLeave = true), dialog = true)

    @Test fun leaveLight() = leave()

    @Test @Config(qualifiers = "+night") fun leaveDark() = leave()

    private fun done() = setup(
        "setup-done",
        flow(SetupEvent.ChooseQuick, SetupEvent.StepDone(QuickStep.PAIR), SetupEvent.Next, SetupEvent.Skip, SetupEvent.Skip),
        settings = settings.copy(notificationAccessEnabled = false, batteryExempt = false),
        paired = listOf("Personal Mac"),
    )

    @Test fun doneLight() = done()

    @Test @Config(qualifiers = "+night") fun doneDark() = done()

    private val permissionEntries = PermissionCatalog.entries(
        PermissionFacts(
            sdkInt = 35,
            labBuild = true,
            granted = setOf(PermissionKind.NOTIFICATION_ACCESS, PermissionKind.POST_NOTIFICATIONS, PermissionKind.BATTERY, PermissionKind.INSTALL_PACKAGES),
            notificationsOn = true,
            callsOn = true,
            screenshotOn = false,
            backgroundClipboardOn = false,
        ),
    )

    private fun permissions() = capture("permissions") { PermissionsScreen(permissionEntries, onBack = {}, onManage = {}) }

    @Test fun permissionsLight() = permissions()

    @Test @Config(qualifiers = "+night") fun permissionsDark() = permissions()

    private fun explainer() = capture("permission-explainer", dialog = true) {
        PermissionsScreen(permissionEntries, onBack = {}, onManage = {})
        PermissionExplainerDialog(PermissionKind.PHONE_CALLS, onContinue = {}, onDismiss = {})
    }

    @Test fun explainerLight() = explainer()

    @Test @Config(qualifiers = "+night") fun explainerDark() = explainer()

    private fun reset() = capture("reset") { ResetScreen(null, ResetChoice.ACTIVITY_AND_LOGS, {}, {}, {}) }

    @Test fun resetLight() = reset()

    @Test @Config(qualifiers = "+night") fun resetDark() = reset()

    private fun resetConfirm() = capture("reset-confirm", dialog = true) { ResetScreen(ResetChoice.SETTINGS, null, {}, {}, {}) }

    @Test fun resetConfirmLight() = resetConfirm()

    @Test @Config(qualifiers = "+night") fun resetConfirmDark() = resetConfirm()

    private fun whatsNew() = capture("whats-new", dialog = true) {
        SettingsScreen(state = settings, actions = SettingsActions())
        WhatsNewDialog(
            version = "0.6.0-rr.1-beta.14",
            notes = "- A new first-run setup: get started quickly, or go through every feature.\n" +
                "- Settings, Privacy, Permissions lists every permission and why Bridgey asks.\n" +
                "- Settings, Privacy, Reset Bridgey on this device.\n" +
                "- Codes from messages shows which Mac the phone is linked to.",
            reviewSetup = true,
            onDismiss = {},
            onReviewSetup = {},
            onOpenNotes = {},
        )
    }

    @Test fun whatsNewLight() = whatsNew()

    @Test @Config(qualifiers = "+night") fun whatsNewDark() = whatsNew()

    private fun whatsNewBanner() = capture("whats-new-banner") {
        Box {
            HomeScreen(
                HomeState(rings = emptyList(), target = null, activity = emptyList(), live = emptyList(), canSendClipboard = false, now = now),
                HomeActions(), SnackbarHostState(), deviceName = { "" },
            )
            WhatsNewBanner(onOpen = {}, onDismiss = {})
        }
    }

    @Test fun whatsNewBannerLight() = whatsNewBanner()

    @Test @Config(qualifiers = "+night") fun whatsNewBannerDark() = whatsNewBanner()

    /** Settings > General with OnePlus's battery steps. */
    private fun oemChecklist() = capture("oem-checklist") {
        SettingsScreen(state = settings.copy(batteryExempt = false), actions = SettingsActions(), section = SettingsSection.GENERAL)
    }

    @Test fun oemChecklistLight() = oemChecklist()

    @Test @Config(qualifiers = "+night") fun oemChecklistDark() = oemChecklist()

    /** Settings > Notifications: "Link to Personal Mac", then the picker over it. */
    private fun codesLink() = capture("codes-link") {
        SettingsScreen(state = settings, actions = SettingsActions(), section = SettingsSection.NOTIFICATIONS)
    }

    @Test fun codesLinkLight() = codesLink()

    @Test @Config(qualifiers = "+night") fun codesLinkDark() = codesLink()

    private fun codesLinkPicker() = capture("codes-link-picker", dialog = true) {
        SettingsScreen(state = settings, actions = SettingsActions(), section = SettingsSection.NOTIFICATIONS)
        CodesLinkPicker(settings.codes.linkTargets, "personal", onDismiss = {}, onLink = {})
    }

    @Test fun codesLinkPickerLight() = codesLinkPicker()

    @Test @Config(qualifiers = "+night") fun codesLinkPickerDark() = codesLinkPicker()

    private fun obtainium() = capture("obtainium") { SettingsScreen(state = settings, actions = SettingsActions(), section = SettingsSection.ABOUT) }

    @Test fun obtainiumLight() = obtainium()

    @Test @Config(qualifiers = "+night") fun obtainiumDark() = obtainium()

    private fun privacy() = capture("settings-privacy-setup") { SettingsScreen(state = settings, actions = SettingsActions(), section = SettingsSection.PRIVACY) }

    @Test fun privacyLight() = privacy()

    @Test @Config(qualifiers = "+night") fun privacyDark() = privacy()
}
