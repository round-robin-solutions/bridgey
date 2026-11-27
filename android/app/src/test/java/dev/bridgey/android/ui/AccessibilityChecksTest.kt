package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextLayoutResult
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.captureRoboImage
import com.google.android.apps.common.testing.accessibility.framework.AccessibilityCheckPreset
import com.google.android.apps.common.testing.accessibility.framework.AccessibilityCheckResult.AccessibilityCheckResultType
import com.google.android.apps.common.testing.accessibility.framework.AccessibilityViewCheckResult
import com.google.android.apps.common.testing.accessibility.framework.Parameters
import com.google.android.apps.common.testing.accessibility.framework.ViewChecker
import com.google.android.apps.common.testing.accessibility.framework.utils.contrast.BitmapImage
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.core.discovery.DiscoveredPeer
import dev.bridgey.android.PairingState
import dev.bridgey.android.RemoteBatteryStatus
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.display.DisplaySourceMessage
import dev.bridgey.android.display.DisplayViewState
import dev.bridgey.android.display.Geometry
import dev.bridgey.android.display.InputCapabilities
import dev.bridgey.android.display.SourceKind
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupFeatures
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupSetting
import dev.bridgey.android.setup.SetupState
import dev.bridgey.android.ui.theme.BridgeyTheme
import java.io.File
import java.util.Calendar
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowBuild

/**
 * The main screens through Google's Accessibility Test Framework (labels, touch targets, contrast, duplicate and
 * unexposed text) and a clipping check (text cut off rather than wrapped), twice: English, light, normal text; and
 * Russian, dark, text at 200%. A tall phone (412 x 2400 dp) so whole pages are composed and checked; every card's
 * More options are open. Fails on any ATF error, on any clipped text outside [mayTruncate], on a switch or checkbox
 * without an on/off state and on anything a screen reader would read twice. PNGs of every case are
 * written with -Pscreenshots=<dir>, as android-a11y-<screen>-<en-light-100|ru-dark-200>.png.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h2400dp-port-xhdpi")
class AccessibilityChecksTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 26, 16, 5, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    @Before
    fun setUp() {
        TimeZone.setDefault(zone)
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context.packageManager).addActivityIfNotPresent(ComponentName(context, ComponentActivity::class.java))
    }

    @After
    fun tearDown() {
        RuntimeEnvironment.setFontScale(1f)
    }

    /** One look at a screen: its locale and theme qualifiers and font scale. */
    private enum class Look(val qualifiers: String, val fontScale: Float) {
        EN_LIGHT_100("+en-rGB-notnight", 1f),
        RU_DARK_200("+ru-night", 2f),
    }

    // ---- Screens ----

    private val settings get() = sampleSettingsState(now)

    private fun settingsHome(look: Look) = check("settings-home", look) {
        SettingsScreen(state = settings, actions = SettingsActions(), section = null)
    }

    private fun group(group: SettingsGroup, look: Look) = check("settings-${group.name.lowercase()}", look) {
        CompositionLocalProvider(LocalCardsExpanded provides true) {
            SettingsScreen(
                state = settings.copy(globalFeatures = settings.globalFeatures + (BridgeyFeature.REMOTE_INPUT to true)),
                actions = SettingsActions(),
                group = group,
            )
        }
    }

    private val trusted = listOf(TrustedDevice("work", "Work MacBook"), TrustedDevice("personal", "Personal Mac"), TrustedDevice("mini", "Mac mini"))
    private val peers = listOf(DiscoveredPeer("personal-svc", "personal", "Personal Mac", "macos", 1, "10.0.0.3", 42_458))
    private val rings get() = deviceRings(trusted, peers, PairingState.Connected("work", "Work MacBook"))
    private val activity get() = listOf(
        ActivityItem(7, ActivityKind.CLIPBOARD_SENT, "work", "Work MacBook", null, "Room 2 at 4, bring the deck", null, false, false, 1, now - 20_000),
        ActivityItem(6, ActivityKind.CALL_SHOWN, "work", "Work MacBook", null, "Mum", null, false, false, 1, now - 60 * 60_000),
        ActivityItem(5, ActivityKind.FILE_RECEIVED, "personal", "Personal Mac", "invoice-oct.pdf", null, null, false, false, 1, now - 2 * 60 * 60_000),
        ActivityItem(2, ActivityKind.NOTIFICATIONS_SHOWN, "work", "Work MacBook", null, null, "WhatsApp", false, false, 4, now - 3 * 60 * 60_000),
        ActivityItem(1, ActivityKind.PING_RECEIVED, "work", "Work MacBook", null, null, null, false, false, 1, now - 26 * 60 * 60_000),
    )

    private fun home(look: Look) = check("home", look) {
        val rings = rings
        HomeScreen(
            state = HomeState(rings = rings, target = sendTarget(rings, null), activity = activity, live = emptyList(), canSendClipboard = true, now = now),
            actions = HomeActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { item -> rings.firstOrNull { it.deviceId == item.deviceId }?.name ?: item.deviceName },
        )
    }

    private fun device(tab: DeviceTab, look: Look) = check("device-${tab.name.lowercase()}", look) {
        val ring = rings.first()
        DeviceScreen(
            state = DeviceState(
                ring = ring,
                battery = RemoteBatteryStatus(76, isCharging = true),
                connected = true,
                available = BridgeyFeature.entries.toSet() - BridgeyFeature.MEDIA,
                ringing = false,
                permissions = listOf(
                    listOf(BridgeyFeature.CLIPBOARD), listOf(BridgeyFeature.FILES), listOf(BridgeyFeature.NOTIFICATIONS),
                    listOf(BridgeyFeature.CALLS), listOf(BridgeyFeature.MEDIA), listOf(BridgeyFeature.REMOTE_INPUT),
                    listOf(BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING), listOf(BridgeyFeature.LINKS), listOf(BridgeyFeature.BATTERY),
                ).map { features ->
                    PermissionRow(features, checked = true, globallyOff = false, remotelyOff = BridgeyFeature.MEDIA in features)
                },
                notificationAccess = true,
                notificationAppsEnabled = 12,
                autoClipboard = true,
                autoClipboardGlobalOn = true,
                activity = activity,
                live = emptyList(),
                now = now,
            ),
            actions = DeviceActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
            initialTab = tab,
        )
    }

    private val paired = listOf("Personal Mac", "Work MacBook")
    private fun facts(granted: Set<PermissionKind> = setOf(PermissionKind.POST_NOTIFICATIONS)) = SetupFacts(
        paired = true,
        current = SetupFeatures.all.flatMap { it.settings }.associateWith { "false" },
        granted = granted,
        duplicateApps = listOf("com.whatsapp" to "WhatsApp", "org.telegram.messenger" to "Telegram"),
        codesLinkApplies = true,
    )

    private fun go(state: SetupState, vararg events: SetupEvent) = events.fold(state) { s, e -> SetupFlow.reduce(s, e, facts()) }

    private val started: SetupState
        get() = go(
            SetupFlow.reduce(SetupState(), SetupEvent.ChooseAdvanced),
            SetupEvent.StartQuestions(SetupBundles.answers(setOf("notifications", "calls"), mapOf("clipboard" to "tap"))),
        )

    private val atSwitches: SetupState
        get() = go(started, SetupEvent.NotNow, SetupEvent.NotNow, SetupEvent.Answer("calls", "yes"), SetupEvent.Switch("battery", true))

    private fun setup(name: String, flow: SetupState, look: Look, facts: SetupFacts = facts()) = check(name, look) {
        SetupScreen(SetupUiState(flow, settings.copy(batteryExempt = false), paired, emptyList(), null, facts = facts), SetupActions())
    }

    private fun summaryFacts() = facts(granted = setOf(PermissionKind.NOTIFICATION_ACCESS, PermissionKind.BATTERY)).let { f ->
        f.copy(current = f.current + mapOf(SetupSetting.FEATURE_NOTIFICATIONS to "true", SetupSetting.FEATURE_CALLS to "true", SetupSetting.FEATURE_CLIPBOARD to "true"))
    }

    private val geometry = Geometry(1, 69_734_662, SourceKind.DISPLAY, 1920, 1246)
    private val stats = DisplaySourceMessage.Stats("s", 2, 28, 6, 4_000_000, 3_800_000, 30, 0)

    private fun macScreen(look: Look) = check("mac-screen-controlling", look) {
        MacScreenScreen(
            DisplayViewState(
                deviceId = "mac", macName = "MacBook Pro", displayName = "Built-in Retina Display",
                phase = DisplayViewState.Phase.STREAMING, geometry = geometry, controlAllowed = true,
                control = DisplayViewState.ControlPhase.ACTIVE, stats = stats,
                input = InputCapabilities(pointer = true, keys = true, text = true),
            ),
            MacScreenActions(),
            picture = { modifier -> Box(modifier.background(Brush.linearGradient(listOf(Color(0xFF2B5876), Color(0xFF4E4376))))) },
        )
    }

    // ---- Tests ----

    @Test fun settingsHome() = Look.entries.forEach { settingsHome(it) }
    @Test fun settingsDevices() = Look.entries.forEach { group(SettingsGroup.DEVICES, it) }
    @Test fun settingsSharing() = Look.entries.forEach { group(SettingsGroup.SHARING, it) }
    @Test fun settingsPhone() = Look.entries.forEach { group(SettingsGroup.PHONE, it) }
    @Test fun settingsControl() = Look.entries.forEach { group(SettingsGroup.CONTROL, it) }
    @Test fun settingsPrivacy() = Look.entries.forEach { group(SettingsGroup.PRIVACY, it) }
    @Test fun settingsApp() = Look.entries.forEach { group(SettingsGroup.APP, it) }
    @Test fun homeStream() = Look.entries.forEach { home(it) }
    @Test fun deviceActivity() = Look.entries.forEach { device(DeviceTab.ACTIVITY, it) }
    @Test fun devicePermissions() = Look.entries.forEach { device(DeviceTab.PERMISSIONS, it) }
    @Test fun setupQuestion() = Look.entries.forEach { setup("setup-question", started, it) }
    @Test fun setupSwitches() = Look.entries.forEach { setup("setup-switches", atSwitches, it) }
    @Test fun setupSummary() = Look.entries.forEach {
        val facts = summaryFacts()
        setup("setup-summary", go(atSwitches, SetupEvent.Continue, SetupEvent.Asked(setOf(PermissionKind.PHONE_CALLS)), SetupEvent.Continue), it, facts)
    }
    @Test fun macScreenViewer() = Look.entries.forEach { macScreen(it) }

    // ---- The checks ----

    private fun check(name: String, look: Look, content: @Composable () -> Unit) {
        RuntimeEnvironment.setQualifiers(look.qualifiers)
        RuntimeEnvironment.setFontScale(look.fontScale)
        val tag = "$name-${look.name.lowercase().replace('_', '-')}"
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
            System.getProperty("bridgey.screenshots")?.let { directory ->
                scenario.onActivity { it.window.decorView.captureRoboImage("$directory/android-a11y-$tag.png") }
            }
            scenario.onActivity { activity ->
                val root = activity.window.decorView
                warnings.clear()
                val problems = atfProblems(root) + clipped(root, look) + semanticsProblems(root)
                report(tag, problems + warnings)
                if (System.getenv("BRIDGEY_A11Y_REPORT_ONLY") == null) assertTrue("$tag:\n" + problems.joinToString("\n"), problems.isEmpty())
            }
        }
        // The window's own native buffers go with the activity; let them be collected before the next look.
        System.gc()
    }

    private val warnings = mutableListOf<String>()

    /** ATF's latest checks with a screenshot (for contrast); errors only, minus [suppressed]. */
    private fun atfProblems(root: View): List<String> {
        val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        root.draw(Canvas(bitmap))
        val parameters = Parameters().apply {
            putScreenCapture(BitmapImage(bitmap))
            setSaveViewImages(false)
        }
        val checks = AccessibilityCheckPreset.getAccessibilityHierarchyChecksForPreset(AccessibilityCheckPreset.LATEST)
        // ATF skips its work on Robolectric's own fingerprint.
        val fingerprint = Build.FINGERPRINT
        if (fingerprint == "robolectric") ShadowBuild.setFingerprint("roborazzi")
        val results: List<AccessibilityViewCheckResult> = try {
            ViewChecker().setObtainCharacterLocations(false).runChecksOnView(checks, root, parameters)
        } finally {
            if (fingerprint == "robolectric") ShadowBuild.setFingerprint(fingerprint)
            // About 16 MB of native pixels per look (824 x 4800). Freed now, not at some later GC: 28 of them in one JVM
            // were followed by a native crash (SIGSEGV in libc) in the next screenshot test on CI.
            bitmap.recycle()
        }
        if (System.getenv("BRIDGEY_A11Y_REPORT_ONLY") != null) {
            results.filter { it.type == AccessibilityCheckResultType.WARNING }.forEach {
                warnings += "ATF warning ${it.sourceCheckClass.simpleName}: ${it.getMessage(java.util.Locale.ENGLISH)} [${describe(it)}]"
            }
        }
        return results
            .filter { it.type == AccessibilityCheckResultType.ERROR }
            .filterNot(::suppressed)
            .map { "ATF ${it.sourceCheckClass.simpleName}: ${it.getMessage(java.util.Locale.ENGLISH)} [${describe(it)}]" }
    }

    private fun describe(result: AccessibilityViewCheckResult): String {
        val element = result.element ?: return "?"
        return listOfNotNull(element.className, element.contentDescription?.toString(), element.text?.toString(), element.boundsInScreen?.toString())
            .joinToString(" ")
    }

    /** ATF results that are not real problems on these screens. */
    private fun suppressed(result: AccessibilityViewCheckResult): Boolean = false

    /**
     * Text cut short: more lines than its maxLines (ellipsised or cut), or taller than the box it was given. Text that
     * may shorten is user content ([mayTruncate]) and anything at normal size that was designed to (only the large
     * text look is checked for ellipses).
     */
    private fun clipped(root: View, look: Look): List<String> = composeRoots(root).flatMap { owner ->
        val found = mutableListOf<String>()
        fun walk(node: SemanticsNode) {
            val text = node.config.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }
            val layout = node.config.getOrNull(SemanticsActions.GetTextLayoutResult)
            if (text != null && layout != null && mayTruncate().none { text.contains(it) }) {
                val results = mutableListOf<TextLayoutResult>()
                layout.action?.invoke(results)
                results.firstOrNull()?.let { r ->
                    val cutVertically = r.size.height + 1 < r.multiParagraph.height
                    val shortened = r.multiParagraph.didExceedMaxLines && look.fontScale > 1f
                    if (cutVertically || shortened) {
                        found += "clipped: \"$text\" (${if (cutVertically) "cut off" else "shortened"}, ${r.size.width}x${r.size.height} px of ${r.multiParagraph.height.toInt()})"
                    }
                }
            }
            node.children.forEach(::walk)
        }
        walk(owner.semanticsOwner.unmergedRootSemanticsNode)
        found
    }

    /**
     * What a screen reader hears, from the merged tree: a switch, checkbox or radio button says whether it is on, and
     * nothing is read twice (a description that already holds the visible label, as a chip once did).
     */
    private fun semanticsProblems(root: View): List<String> = composeRoots(root).flatMap { owner ->
        val found = mutableListOf<String>()
        fun walk(node: SemanticsNode) {
            val config = node.config
            val role = config.getOrNull(SemanticsProperties.Role)
            val described = config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
            val texts = config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }.filter { it.isNotBlank() }
            val name = (described + texts).joinToString(", ")
            if (role in Toggles && config.getOrNull(SemanticsProperties.ToggleableState) == null && config.getOrNull(SemanticsProperties.Selected) == null) {
                found += "no on/off state: $role \"$name\""
            }
            texts.filter { text -> described.any { it.contains(text) } }.forEach { found += "read twice: \"$it\" in \"$name\"" }
            node.children.forEach(::walk)
        }
        walk(owner.semanticsOwner.rootSemanticsNode)
        found
    }

    private fun composeRoots(view: View): List<ViewRootForTest> = buildList {
        if (view is ViewRootForTest) add(view)
        if (view is ViewGroup) for (i in 0 until view.childCount) addAll(composeRoots(view.getChildAt(i)))
    }

    private fun report(tag: String, problems: List<String>) {
        val file = File("build/reports/accessibility-checks.txt")
        file.parentFile?.mkdirs()
        file.appendText("== $tag (${problems.size})\n" + problems.joinToString("") { "$it\n" })
    }

    /**
     * Text that is meant to shorten with an ellipsis: user content (clips, file names, message previews) and the hint in
     * a one-line field (it goes as soon as you type).
     */
    private fun mayTruncate(): List<String> = listOf(
        "Room 2 at 4, bring the deck", "invoice-oct.pdf",
        ApplicationProvider.getApplicationContext<Application>().getString(dev.bridgey.android.R.string.composer_clipboard_hint),
    )

    private companion object {

        val Toggles = setOf(androidx.compose.ui.semantics.Role.Switch, androidx.compose.ui.semantics.Role.Checkbox, androidx.compose.ui.semantics.Role.RadioButton)
    }
}
