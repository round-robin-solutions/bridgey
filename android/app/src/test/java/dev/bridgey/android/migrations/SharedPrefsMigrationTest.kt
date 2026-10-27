package dev.bridgey.android.migrations

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.AppUpdater
import dev.bridgey.android.AttachPreferences
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BridgeyLogging
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.KnownAddressBook
import dev.bridgey.android.LoggingPolicy
import dev.bridgey.android.SharedPreferencesAddressBookStore
import dev.bridgey.android.TrustedDevice
import dev.bridgey.android.UpdateChannel
import dev.bridgey.android.folders.ConflictPolicy
import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.DestinationMode
import dev.bridgey.android.folders.FolderDestination
import dev.bridgey.android.migrations.MigrationFixtures.KEY_A
import dev.bridgey.android.migrations.MigrationFixtures.KEY_B
import dev.bridgey.android.migrations.MigrationFixtures.KEY_C
import dev.bridgey.android.migrations.MigrationFixtures.MAC_A
import dev.bridgey.android.migrations.MigrationFixtures.MAC_B
import dev.bridgey.android.migrations.MigrationFixtures.MAC_C
import dev.bridgey.android.migrations.MigrationFixtures.ORPHAN_NAME_ID
import dev.bridgey.android.ui.UiPreferences
import dev.bridgey.android.ui.attach.AttachTab
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.StateFlow
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * A phone on every edition release from Beta 1 on upgrades to this build: its trusted Macs, its
 * settings and its other preferences must load unchanged from the `shared_prefs` files that release
 * wrote. Each snapshot is in `protocol/test-vectors/migrations/android/shared_prefs/beta.N`.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SharedPrefsMigrationTest(private val release: Int) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "beta.{0}")
        fun releases(): List<Array<Any>> = MigrationFixtures.sharedPrefsReleases.map { arrayOf<Any>(it) }
    }

    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()

    @Before
    fun install() {
        MigrationFixtures.installSharedPrefs(context, release)
    }

    @After
    fun resetLogging() {
        BridgeyLogging.policy = LoggingPolicy()
    }

    // MARK: Trust (bridgey.trust, unchanged since upstream 0.1)

    @Test
    fun trustedMacsAndTheirKeysSurvive() {
        val trust = TrustRegistryProbe(context)
        assertEquals(setOf(MAC_A, MAC_B, MAC_C), trust.ids())
        assertEquals(KEY_A, trust.identityKey(MAC_A))
        assertEquals(KEY_B, trust.identityKey(MAC_B))
        assertEquals(KEY_C, trust.identityKey(MAC_C))
        assertEquals(
            listOf(TrustedDevice(MAC_A, "Test Mac A"), TrustedDevice(MAC_B, "Test Mac B"), TrustedDevice(MAC_C, "Unknown device")),
            trust.devices(),
        )
        // A name without a key was never trust.
        assertNull(trust.identityKey(ORPHAN_NAME_ID))
        assertFalse(ORPHAN_NAME_ID in trust.ids())
    }

    @Test
    fun trustWrittenByThisBuildKeepsTheOlderEntries() {
        TrustRegistryProbe(context).save(MAC_C, "Test Mac C", KEY_C)
        val reloaded = TrustRegistryProbe(context)
        assertEquals(setOf(MAC_A, MAC_B, MAC_C), reloaded.ids())
        assertEquals(KEY_A, reloaded.identityKey(MAC_A))
        assertTrue(TrustedDevice(MAC_C, "Test Mac C") in reloaded.devices())
    }

    // MARK: Settings (bridgey.settings)

    @Test
    fun settingsSurvive() {
        assertSettings(BridgeySettings(context, "Default name"))
    }

    @Test
    fun settingsWrittenByThisBuildKeepTheOlderValues() {
        BridgeySettings(context, "Default name").setKeepWifiAwake(release >= 8)
        BridgeySettings(context, "Default name").setGlobal(BridgeyFeature.PING, false)
        val reloaded = BridgeySettings(context, "Default name")
        assertSettings(reloaded, pingOff = true)
    }

    private fun assertSettings(settings: BridgeySettings, pingOff: Boolean = false) {
        val state = settings.state.value
        assertEquals("Test Phone", state.deviceName)

        // Share screen with Macs is off by default even on installs from before off-until-chosen.
        val globals = BridgeyFeature.entries.associateWith { it != BridgeyFeature.CLIPBOARD && it != BridgeyFeature.MEDIA && it != BridgeyFeature.SCREEN }
            .plus(BridgeyFeature.REMOTE_INPUT to (release >= 9))
            .plus(BridgeyFeature.PING to !pingOff)
        assertEquals(globals, state.globalFeatures)

        val macA = mutableMapOf(BridgeyFeature.NOTIFICATIONS to false, BridgeyFeature.CALLS to true)
        if (release >= 9) macA[BridgeyFeature.REMOTE_INPUT] = true
        assertEquals(mapOf(MAC_A to macA, MAC_B to mapOf(BridgeyFeature.FILES to false)), state.deviceFeatures)
        assertFalse(settings.isEnabled(BridgeyFeature.NOTIFICATIONS, MAC_A))
        assertTrue(settings.isEnabled(BridgeyFeature.NOTIFICATIONS, MAC_B))
        assertFalse(settings.isEnabled(BridgeyFeature.FILES, MAC_B))

        assertEquals(mapOf("com.example.chat" to "Chat App", "com.example.mail" to "Mail App"), state.notificationApplications)
        assertEquals(setOf("com.example.mail"), state.disabledNotificationPackages)
        assertFalse(settings.isNotificationApplicationEnabled("com.example.mail"))
        assertTrue(state.directCallsEnabled)

        // Beta 4: Automatic clipboard. Before it, the defaults apply.
        assertEquals(release < 4, state.autoClipboardGlobal)
        assertEquals(if (release >= 4) mapOf(MAC_A to true) else emptyMap<String, Boolean>(), state.autoClipboardDevices)
        assertEquals(release >= 4, state.backgroundClipboardEnabled)

        // Beta 5: Copy images and files.
        assertEquals(release < 5, state.clipboardFilesEnabled)
        assertEquals(if (release >= 5) 100_000_000L else 25_000_000L, state.clipboardEagerLimit)

        // Beta 8: Keep Wi-Fi awake.
        assertEquals(release >= 8, state.keepWifiAwake)

        // Beta 10: folders.
        if (release >= 10) {
            assertEquals(DestinationMode.FIXED, state.folderMode)
            assertEquals(ConflictPolicy.MERGE, state.folderConflict)
            assertEquals("q3Jx0bVv1eG7tq8Wm2l5wA", state.folderDefaultPlace)
            assertTrue(state.allowReplaceFromOtherDevices)
            assertEquals(
                listOf(FolderDestination(DEFAULT_PLACE_ID, "Trips"), FolderDestination("q3Jx0bVv1eG7tq8Wm2l5wA", "Photos/2026")),
                state.recentFolderDestinations,
            )
        } else {
            assertEquals(DestinationMode.SENDER_PICKS, state.folderMode)
            assertEquals(ConflictPolicy.ASK, state.folderConflict)
            assertEquals(DEFAULT_PLACE_ID, state.folderDefaultPlace)
            assertFalse(state.allowReplaceFromOtherDevices)
            assertTrue(state.recentFolderDestinations.isEmpty())
        }

        // Beta 11: fresh screenshots and Privacy > Logging.
        assertEquals(release < 11, state.screenshotSendEnabled)
        val logging = if (release >= 11) LoggingPolicy(connection = false, callNumbers = true, remoteControl = false) else LoggingPolicy()
        assertEquals(logging, state.logging)
        assertEquals(logging, BridgeyLogging.policy)
    }

    // MARK: Files 2.0 (0.8.0-rr.1): a phone upgrading from any beta gets the defaults

    @Test
    fun files2DefaultsApplyToEveryOlderRelease() {
        val state = BridgeySettings(context, "Default name").state.value
        // B1: browsing and downloading on by default; writing stays behind the replace switch's old key.
        assertTrue(state.allowBrowseFromOtherDevices)
        assertEquals(release >= 10, state.allowReplaceFromOtherDevices)
        val attach = AttachPreferences(context)
        assertEquals(AttachTab.MEDIA, attach.tab)
        assertNull(attach.lastTarget)
        assertFalse(attach.documentsCardDismissed)
        assertFalse(attach.mediaAsked)
    }

    // MARK: Other preferences

    @Test
    fun appearanceAndPrivacyPreferencesSurvive() {
        val ui = UiPreferences(context)
        assertEquals("Show previews in activity", release < 2, ui.showPreviews.value)
        assertEquals(release >= 2, ui.reduceMotion.value)
        assertEquals(release >= 4, ui.tileAdded.value)
        assertEquals(release >= 8, ui.batteryPromptShown.value)
    }

    @Test
    fun updateChannelSurvives() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val state = AppUpdater(context, scope).state.value
            assertEquals(UpdateChannel.BETA, state.channel)
            assertEquals(1_792_918_800_000L, state.lastCheckedAt)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun deviceIdAndOnboardingSurvive() {
        // Read by BridgeyApplication and MainActivity straight from these files.
        val main = context.getSharedPreferences("bridgey", Context.MODE_PRIVATE)
        assertEquals(MigrationFixtures.PHONE_ID, main.getString("device_id", null))
        assertTrue(main.getBoolean("bridgey_enabled", false))
        assertTrue(context.getSharedPreferences("bridgey_onboarding", Context.MODE_PRIVATE).getBoolean("completed", false))
    }

    @Test
    fun reconnectAddressBookSurvives() {
        val book = KnownAddressBook(SharedPreferencesAddressBookStore(context))
        if (release < 8) {
            assertTrue(book.addresses(MAC_A).isEmpty())
            return
        }
        assertEquals(listOf("192.168.1.20", "test-mac-a.local", "fd00::20"), book.addresses(MAC_A).map { it.host })
        assertEquals(1_793_005_200_000L, book.lastConnected(MAC_A))
        assertEquals(listOf("10.0.0.7"), book.addresses(MAC_B).map { it.host })
        assertNull(book.lastConnected(MAC_B))
    }
}

/**
 * `AndroidTrustRegistry` is private to PairingCoordinator.kt (it sits next to the Keystore identity).
 * Reflection reaches it without widening production code; a rename fails here loudly.
 */
internal class TrustRegistryProbe(context: Context) {
    private val type = Class.forName("dev.bridgey.android.AndroidTrustRegistry")
    private val instance: Any = type.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context)

    private fun method(name: String, vararg parameters: Class<*>) = type.getDeclaredMethod(name, *parameters).apply { isAccessible = true }

    fun identityKey(deviceId: String): String? = method("identityKey", String::class.java).invoke(instance, deviceId) as String?

    @Suppress("UNCHECKED_CAST")
    fun ids(): Set<String> = (method("getTrustedDeviceIds").invoke(instance) as StateFlow<Set<String>>).value

    @Suppress("UNCHECKED_CAST")
    fun devices(): List<TrustedDevice> = (method("getTrustedDevices").invoke(instance) as StateFlow<List<TrustedDevice>>).value

    fun save(deviceId: String, name: String, identityKey: String) {
        method("save", String::class.java, String::class.java, String::class.java).invoke(instance, deviceId, name, identityKey)
    }
}
