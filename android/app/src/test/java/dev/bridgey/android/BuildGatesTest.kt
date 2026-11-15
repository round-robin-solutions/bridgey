package dev.bridgey.android

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.bridgey.android.setup.PermissionCatalog
import dev.bridgey.android.setup.PermissionFacts
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.SetupFeatures
import dev.bridgey.android.setup.SetupQuestions
import dev.bridgey.android.setup.SetupBundles
import dev.bridgey.android.setup.SetupTyped
import dev.bridgey.android.setup.SetupSummary
import dev.bridgey.android.setup.SetupState
import dev.bridgey.android.setup.SummaryItem
import dev.bridgey.android.setup.Answers
import dev.bridgey.android.setup.SetupFlow
import dev.bridgey.android.setup.SetupSetting
import dev.bridgey.android.sync.SyncUiState
import dev.bridgey.android.ui.SettingsSection
import dev.bridgey.android.ui.sampleSettingsState
import dev.bridgey.android.ui.search.SearchDevice
import dev.bridgey.android.ui.search.SettingsSearchRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** Runs in Debug, Play and QA: saved settings cannot restore a feature absent from this build. */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class BuildGatesTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val play: Boolean get() = BuildConfig.BUILD_TYPE == "play"

    @Before
    fun clear() {
        listOf("bridgey.settings", "bridgey.updates").forEach {
            context.getSharedPreferences(it, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }

    /** Google Play gets plain numbers (1.0.0-beta.3 is 1.0.0 there); the build number stays the versionCode. */
    @Test
    fun playVersionNameIsPlainNumbers() {
        if (play) {
            assertTrue(BuildConfig.VERSION_NAME, Regex("""^\d+\.\d+\.\d+$""").matches(BuildConfig.VERSION_NAME))
        } else {
            assertTrue(BuildConfig.VERSION_NAME, BuildConfig.VERSION_NAME.matches(Regex("""^\d+\.\d+\.\d+.*""")))
        }
        assertTrue(BuildConfig.VERSION_CODE > 0)
    }

    @Test
    fun smsCannotBeEnabledByAnUpgradeOrPairedDeviceInPlay() {
        context.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE).edit()
            .putBoolean("global.${BridgeyFeature.SMS.key}", true)
            .putBoolean("device.mac.${BridgeyFeature.SMS.key}", true).commit()
        val settings = BridgeySettings(context, "Phone")
        assertEquals(!play, settings.smsOn())
        assertEquals(!play, settings.isEnabled(BridgeyFeature.SMS, "mac"))
        settings.setGlobal(BridgeyFeature.SMS, enabled = true)
        settings.setForDevice("mac", BridgeyFeature.SMS, true)
        assertEquals(!play, settings.state.value.globalFeatures[BridgeyFeature.SMS])
        assertEquals(!play, settings.isEnabled(BridgeyFeature.SMS, "mac"))
        settings.setGlobal(BridgeyFeature.CLIPBOARD, enabled = true)
        assertTrue(settings.isEnabled(BridgeyFeature.CLIPBOARD, "mac"))
    }

    /** The Play build's Calls window has the keypad and SIM choice only: no contacts, no call log, never asked for. */
    @Test
    fun callsWindowLeavesContactsAndTheCallLogOutOfPlay() {
        assertEquals(!play, BuildGates.contacts)
        assertEquals(!play, BuildGates.callLog)
        val facts = PermissionFacts(sdkInt = 35, labBuild = false, granted = emptySet(), dialerOn = true)
        val kinds = PermissionCatalog.entries(facts).map { it.kind }
        assertEquals(!play, PermissionKind.CALL_LOG in kinds)
        assertEquals(!play, PermissionKind.CONTACTS in kinds)
        assertTrue(PermissionKind.PHONE_CALLS in kinds)
        // The feature itself is in every build, off by default and needing each Mac's own permission.
        val settings = BridgeySettings(context, "Phone", dev.bridgey.android.setup.DefaultsGeneration.FEATURES_ON)
        assertFalse(settings.state.value.globalFeatures[BridgeyFeature.DIALER] == true)
        settings.setGlobal(BridgeyFeature.DIALER, enabled = true)
        assertFalse("on, but this Mac is not allowed yet", settings.isEnabled(BridgeyFeature.DIALER, "mac"))
        settings.setForDevice("mac", BridgeyFeature.DIALER, true)
        assertTrue(settings.isEnabled(BridgeyFeature.DIALER, "mac"))
        assertFalse("another Mac still needs its own", settings.isEnabled(BridgeyFeature.DIALER, "other"))
    }

    @Test
    fun setupAndSettingsOnlyOfferBuiltFeatures() {
        assertEquals(!play, SetupFeatures.all.any { it.id == "messages" })
        assertEquals(!play, SetupQuestions.all.any { it.id == "messages" })
        assertEquals(!play, SetupBundles.all.any { it.id == "messages" })
        assertEquals(!play, SettingsSection.MESSAGES in SettingsSection.homeRows)
        assertEquals(!play, SettingsSection.UPDATES in SettingsSection.homeRows)
        if (play) assertFalse(BuildConfig.CODE_TEST_AVAILABLE)
    }

    @Test
    fun removedPermissionsAreAbsentFromTheCatalogAndSearch() {
        val catalog = PermissionCatalog.entries(PermissionFacts(35, false, emptySet(), smsOn = true))
        for (kind in listOf(PermissionKind.SMS, PermissionKind.CONTACTS, PermissionKind.INSTALL_PACKAGES)) {
            assertEquals(kind.name, !play, catalog.any { it.kind == kind })
        }
        assertTrue(catalog.any { it.kind == PermissionKind.NOTIFICATION_ACCESS })
        val results = SettingsSearchRegistry.resolve(context, true, SyncUiState(), listOf(SearchDevice("mac", "Test Mac", false)))
        for (id in listOf("permissions.sms", "permissions.contacts", "permissions.install", "messages.switch", "updates.status")) {
            assertEquals(id, !play, results.any { it.id == id })
        }
        assertEquals(!play, results.any { it.id.startsWith("device.mac.") && it.title == context.getString(R.string.feature_sms) })
    }

    @Test
    fun playUpdaterDoesNotCheckOrInstall() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val updater = AppUpdater(context, scope)
            assertEquals(!play, updater.canUpdate)
            if (play) {
                updater.checkNow()
                updater.commitPrepared()
                updater.install()
                assertFalse(updater.state.value.checking)
                assertFalse(updater.state.value.installing)
                assertEquals(0L, updater.state.value.lastCheckedAt)
            }
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun typedAndSavedUpdateChoicesCannotExposeAnUnbuiltUpdater() {
        val chosen = SetupTyped.match("beta and automatic updates")
        assertEquals(!play, "updates" in chosen)
        assertEquals(!play, "updates_auto" in chosen)
        val saved = SetupState(answers = mapOf("updates" to Answers.EARLY, "updates_auto" to Answers.YES))
        assertEquals(!play, SetupSummary.items(saved).filterIsInstance<SummaryItem.Chosen>().any { it.page == "UPDATES" })
        val changes = SetupFlow.startChanges(saved.answers)
        assertEquals(!play, changes.any { it.setting == SetupSetting.UPDATE_CHANNEL })
        assertEquals(!play, changes.any { it.setting == SetupSetting.AUTO_UPDATES })
    }

    @Test
    fun startupOnlyProbesInstallPermissionWhenSelfUpdateIsBuilt() {
        val settings = sampleSettingsState(1_000L)
        val noInstallApi = object : ContextWrapper(context) {
            override fun getPackageManager(): PackageManager =
                throw SecurityException("REQUEST_INSTALL_PACKAGES is not declared")
        }
        if (play) {
            val facts = permissionFacts(noInstallApi, settings)
            assertFalse(PermissionKind.INSTALL_PACKAGES in facts.granted)
        } else {
            assertThrows(SecurityException::class.java) { permissionFacts(noInstallApi, settings) }
        }
    }
}
