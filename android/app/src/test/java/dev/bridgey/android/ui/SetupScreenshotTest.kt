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

    /** A fresh install: every feature off until chosen. */
    private fun facts(granted: Set<PermissionKind> = setOf(PermissionKind.POST_NOTIFICATIONS)) = SetupFacts(
        paired = true,
        current = dev.bridgey.android.setup.SetupFeatures.all.flatMap { it.settings }.associateWith { "false" },
        granted = granted,
        duplicateApps = listOf("com.whatsapp" to "WhatsApp", "org.telegram.messenger" to "Telegram", "com.Slack" to "Slack", "com.microsoft.teams" to "Microsoft Teams"),
        codesLinkApplies = true,
    )

    private fun questions(name: String, flow: SetupState, typedText: String = "", picked: Set<String> = emptySet(), dialog: Boolean = false, facts: SetupFacts = facts()) =
        capture(name, dialog) {
            SetupScreen(
                SetupUiState(flow, settings.copy(batteryExempt = false), paired, emptyList(), oem, facts = facts, typedText = typedText, pickedBundles = picked),
                SetupActions(),
            )
        }

    private fun go(state: SetupState, vararg events: SetupEvent, facts: SetupFacts = facts()) = events.fold(state) { s, e -> SetupFlow.reduce(s, e, facts) }

    private val started: SetupState
        get() = go(
            SetupFlow.reduce(SetupState(), SetupEvent.ChooseAdvanced),
            SetupEvent.StartQuestions(dev.bridgey.android.setup.SetupBundles.answers(setOf("notifications", "calls"), mapOf("clipboard" to "tap"))),
        )

    private fun intro() = questions("setup-intro", flow(SetupEvent.ChooseAdvanced), typedText = "copy paste and calls but no music", picked = setOf("notifications"))

    @Test fun introLight() = intro()

    @Test @Config(qualifiers = "+night") fun introDark() = intro()

    /** The first follow-up for Notifications: apps that have a Mac app. */
    private fun appsQuestion() = questions("setup-question-apps", started)

    @Test fun appsQuestionLight() = appsQuestion()

    @Test @Config(qualifiers = "+night") fun appsQuestionDark() = appsQuestion()

    private fun callsQuestion() = questions("setup-question-calls", go(started, SetupEvent.NotNow, SetupEvent.NotNow))

    @Test fun callsQuestionLight() = callsQuestion()

    @Test @Config(qualifiers = "+night") fun callsQuestionDark() = callsQuestion()

    private val atSwitches: SetupState get() = go(started, SetupEvent.NotNow, SetupEvent.NotNow, SetupEvent.Answer("calls", "yes"), SetupEvent.Switch("battery", true))

    private fun switches() = questions("setup-switches", atSwitches)

    @Test fun switchesLight() = switches()

    @Test @Config(qualifiers = "+night") fun switchesDark() = switches()

    /** One page: Notification access allowed, Phone and calls refused, the others not yet. */
    private fun setupPermissions() = questions(
        "setup-permissions",
        go(atSwitches, SetupEvent.Continue, SetupEvent.Asked(setOf(PermissionKind.PHONE_CALLS))),
        facts = facts(granted = setOf(PermissionKind.NOTIFICATION_ACCESS)),
    )

    @Test fun setupPermissionsLight() = setupPermissions()

    @Test @Config(qualifiers = "+night") fun setupPermissionsDark() = setupPermissions()

    private fun summary() = questions(
        "setup-summary",
        go(atSwitches, SetupEvent.Continue, SetupEvent.Asked(setOf(PermissionKind.PHONE_CALLS)), SetupEvent.Continue, facts = facts(granted = setOf(PermissionKind.NOTIFICATION_ACCESS, PermissionKind.BATTERY))),
        facts = facts(granted = setOf(PermissionKind.NOTIFICATION_ACCESS, PermissionKind.BATTERY)).let { f ->
            f.copy(current = f.current + mapOf(dev.bridgey.android.setup.SetupSetting.FEATURE_NOTIFICATIONS to "true", dev.bridgey.android.setup.SetupSetting.FEATURE_CALLS to "true", dev.bridgey.android.setup.SetupSetting.FEATURE_CLIPBOARD to "true", dev.bridgey.android.setup.SetupSetting.FEATURE_BATTERY to "true"))
        },
    )

    @Test fun summaryLight() = summary()

    @Test @Config(qualifiers = "+night") fun summaryDark() = summary()

    private fun leave() = questions("setup-leave", atSwitches.copy(confirmLeave = true), dialog = true)

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

    /** Settings > General on a Google Pixel: App battery usage, Adaptive Battery, Pause app activity if unused. */
    private fun pixelChecklist() = capture("oem-checklist-pixel") {
        SettingsScreen(
            state = settings.copy(batteryExempt = false, setup = SetupSettingsState(oem = OemBattery.checklist("Google", "google"))),
            actions = SettingsActions(),
            section = SettingsSection.GENERAL,
        )
    }

    @Test fun pixelChecklistLight() = pixelChecklist()

    @Test @Config(qualifiers = "+night") fun pixelChecklistDark() = pixelChecklist()

    /** Setup's Permissions page: Notification access was asked and is still off, so the restricted settings hint shows. */
    private fun permissionsRestricted() = questions(
        "setup-permissions-restricted",
        go(atSwitches, SetupEvent.Continue, SetupEvent.Asked(setOf(PermissionKind.NOTIFICATION_ACCESS))),
        facts = facts(granted = setOf(PermissionKind.POST_NOTIFICATIONS)),
    )

    @Test fun permissionsRestrictedLight() = permissionsRestricted()

    @Test @Config(qualifiers = "+night") fun permissionsRestrictedDark() = permissionsRestricted()

    /** The quick path's Notification access step after Allow, back with nothing granted. */
    private fun quickNotificationsRestricted() = setup(
        "setup-quick-notifications-restricted",
        flow(SetupEvent.ChooseQuick, SetupEvent.Next, SetupEvent.Asked(setOf(PermissionKind.NOTIFICATION_ACCESS))),
        settings = settings.copy(notificationAccessEnabled = false), paired = listOf("Personal Mac"),
    )

    @Test fun quickNotificationsRestrictedLight() = quickNotificationsRestricted()

    @Test @Config(qualifiers = "+night") fun quickNotificationsRestrictedDark() = quickNotificationsRestricted()

    /** Settings > Files with the two new switches (synced), scrolled down to them; hidden files differ on a Mac. */
    private fun filesHidden() = capture("settings-files-hidden") {
        SettingsScreen(
            state = settings.copy(
                folders = settings.folders.copy(includeHidden = true),
                sync = dev.bridgey.android.sync.SyncUiState(
                    rows = mapOf(dev.bridgey.android.sync.SyncKey.FOLDER_INCLUDE_HIDDEN to dev.bridgey.android.sync.SyncRowStatus(differentOn = listOf("Work Mac"))),
                ),
            ),
            actions = SettingsActions(),
            listState = androidx.compose.foundation.lazy.LazyListState(firstVisibleItemIndex = 0, firstVisibleItemScrollOffset = 1100),
            section = SettingsSection.FILES,
        )
    }

    @Test fun filesHiddenLight() = filesHidden()

    @Test @Config(qualifiers = "+night") fun filesHiddenDark() = filesHidden()

    private fun obtainium() = capture("obtainium") { SettingsScreen(state = settings, actions = SettingsActions(), section = SettingsSection.ABOUT) }

    @Test fun obtainiumLight() = obtainium()

    @Test @Config(qualifiers = "+night") fun obtainiumDark() = obtainium()

    private fun privacy() = capture("settings-privacy-setup") { SettingsScreen(state = settings, actions = SettingsActions(), section = SettingsSection.PRIVACY) }

    @Test fun privacyLight() = privacy()

    @Test @Config(qualifiers = "+night") fun privacyDark() = privacy()
}
