package dev.bridgey.android.ui

import android.app.Application
import android.content.ComponentName
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import dev.bridgey.android.PairDialog
import dev.bridgey.android.PairingFailure
import dev.bridgey.android.PairingRequest
import dev.bridgey.android.PairingState
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.activity.ActivityItem
import dev.bridgey.android.activity.ActivityKind
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupEvent
import dev.bridgey.android.setup.SetupFacts
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupState
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.core.discovery.DiscoveredPeer
import java.util.Calendar
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 0.10 pairing: the phone's pairing screen, the pairing sheet in every state (the code check, waiting, the other end
 * confirmed, paired, each failure), the home stream's Allow pairing card and setup's Pair step, light and dark.
 * PNGs are written only with -Pscreenshots=<dir>, as <screen>-<light|dark>.png.
 */
@OptIn(ExperimentalRoborazziApi::class)
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w412dp-h915dp-port-xxhdpi")
class PairingScreenshotTest {
    private val zone: TimeZone = TimeZone.getTimeZone("Asia/Kolkata")
    private val now: Long = Calendar.getInstance(zone).apply {
        set(2026, Calendar.OCTOBER, 27, 10, 30, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

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
    private fun capture(name: String, dialog: Boolean = true, content: @Composable () -> Unit) {
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
            val file = "$directory/$name-${theme()}.png"
            if (dialog) captureScreenRoboImage(file) else scenario.onActivity { it.window.decorView.captureRoboImage(file) }
        }
    }

    private val mac = "Rahul's MacBook Pro"
    private val trusted = listOf(TrustedDevice("work", "Work MacBook"))
    private val peers = listOf(
        DiscoveredPeer("mbp-svc", "mbp", mac, "macos", 1, "10.0.0.5", 42_458),
        DiscoveredPeer("work-svc", "work", "Work MacBook", "macos", 1, "10.0.0.3", 42_458),
    )

    private val activity get() = listOf(
        ActivityItem(2, ActivityKind.CLIPBOARD_SENT, "work", "Work MacBook", null, "Room 2 at 4, bring the deck", null, false, false, 1, now - 20 * 60_000),
        ActivityItem(1, ActivityKind.FILE_RECEIVED, "work", "Work MacBook", "invoice-oct.pdf", null, null, false, false, 1, now - 50 * 60_000),
    )

    /** The home screen behind the sheets, with [live] cards on top of the stream. */
    @Composable
    private fun Home(live: List<LiveCard> = emptyList()) {
        val rings = deviceRings(trusted, peers, emptyList(), PairingState.Idle)
        HomeScreen(
            state = HomeState(rings = rings, target = sendTarget(rings, null), activity = activity, live = live, canSendClipboard = false, now = now),
            actions = HomeActions(),
            snackbar = remember { SnackbarHostState() },
            deviceName = { it.deviceName },
        )
    }

    private val token = "token"

    private fun sheet(name: String, state: PairingState) = capture(name) {
        Home()
        PairingSheet(state, PairingSheetActions(), stillProgress = 0.4f)
    }

    private fun sheets() {
        sheet("sheet-connecting", PairingState.Connecting(mac))
        sheet("sheet-waiting-for-allow", PairingState.WaitingForAllow(mac))
        sheet("verification-check", PairingState.Verification(mac, "482913", token))
        sheet("verification-waiting", PairingState.Verification(mac, "482913", token, localConfirmed = true))
        sheet("verification-remote-confirmed", PairingState.Verification(mac, "482913", token, remoteConfirmed = true))
        sheet("sheet-paired", PairingState.Paired("mbp", mac))
    }

    @Test fun sheetsLight() = sheets()

    @Test @Config(qualifiers = "+night") fun sheetsDark() = sheets()

    private fun failures() = PairingFailure.entries.forEach { reason ->
        sheet("failed-${reason.name.lowercase().replace('_', '-')}", PairingState.Failed(reason, mac))
    }

    @Test fun failuresLight() = failures()

    @Test @Config(qualifiers = "+night") fun failuresDark() = failures()

    private fun pairScreen(name: String, request: PairingRequest? = null, armedSeconds: Int = 0) = capture(name) {
        Home()
        PairDialog(
            peers = peers,
            trustedIds = trusted.mapTo(HashSet()) { it.id },
            connectedIds = emptySet(),
            onPair = {},
            onDismiss = {},
            request = request,
            armedSeconds = armedSeconds,
        )
    }

    private fun pairScreens() {
        pairScreen("pair-screen-ready")
        pairScreen("pair-screen-request", request = PairingRequest("mbp", mac, oldVersion = false))
        pairScreen("pair-screen-countdown", armedSeconds = 118)
        pairScreen("pair-screen-old-version", request = PairingRequest("old", "Old iMac", oldVersion = true))
    }

    @Test fun pairScreensLight() = pairScreens()

    @Test @Config(qualifiers = "+night") fun pairScreensDark() = pairScreens()

    private fun homeCards() {
        capture("home-pairing-request", dialog = false) { Home(listOf(LiveCard.PairingRequest(PairingRequest("mbp", mac, oldVersion = false)))) }
        capture("home-pairing-ready", dialog = false) { Home(listOf(LiveCard.PairingReady(118))) }
        capture("home-pairing-old-version", dialog = false) { Home(listOf(LiveCard.PairingRequest(PairingRequest("old", "Old iMac", oldVersion = true)))) }
    }

    @Test fun homeCardsLight() = homeCards()

    @Test @Config(qualifiers = "+night") fun homeCardsDark() = homeCards()

    private val nearby = listOf(SetupNearbyMac("a", mac, paired = false), SetupNearbyMac("b", "Mac mini", paired = false))
    private val quickPair: SetupState get() = SetupFlow.reduce(SetupState(), SetupEvent.ChooseQuick)

    private fun setupPair(name: String, sheet: PairingState? = null, request: PairingRequest? = null, armedSeconds: Int = 0, paired: List<String> = emptyList()) =
        capture(name) {
            SetupScreen(
                SetupUiState(quickPair, sampleSettingsState(now), paired, nearby, pairingRequest = request, armedSeconds = armedSeconds),
                SetupActions(),
            )
            sheet?.let { PairingSheet(it, PairingSheetActions(), stillProgress = 0.4f) }
        }

    private fun setupSteps() {
        setupPair("setup-pair-ready")
        setupPair("setup-pair-request", request = PairingRequest("mbp", mac, oldVersion = false))
        setupPair("setup-pair-verification", sheet = PairingState.Verification(mac, "482913", token))
        setupPair("setup-pair-waiting", sheet = PairingState.Verification(mac, "482913", token, localConfirmed = true))
        setupPair("setup-pair-waiting-for-allow", sheet = PairingState.WaitingForAllow(mac))
        setupPair("setup-pair-failed", sheet = PairingState.Failed(PairingFailure.MISMATCH_REMOTE, mac))
        setupPair("setup-pair-paired", sheet = PairingState.Paired("mbp", mac), paired = listOf(mac))
        // The question path's Pair page, for a person with no Mac paired yet.
        val facts = SetupFacts(paired = false)
        val question = listOf(
            SetupEvent.StartQuestions(SetupBundles.answers(setOf("notifications"), emptyMap())),
        ).fold(SetupFlow.reduce(SetupState(), SetupEvent.ChooseAdvanced)) { s, e -> SetupFlow.reduce(s, e, facts) }
        capture("setup-question-pair-ready") {
            SetupScreen(SetupUiState(question, sampleSettingsState(now), emptyList(), nearby, facts = facts), SetupActions())
        }
    }

    @Test fun setupStepsLight() = setupSteps()

    @Test @Config(qualifiers = "+night") fun setupStepsDark() = setupSteps()

    @Test
    fun theCodeReadsInTwoGroupsAndDigitByDigit() {
        assertEquals("482 913", groupedPairingCode("482913"))
        assertEquals("4 8 2 9 1 3", spokenPairingCode("482913"))
        assertEquals("1:58", pairingCountdown(118))
        assertEquals("0:05", pairingCountdown(5))
    }
}
