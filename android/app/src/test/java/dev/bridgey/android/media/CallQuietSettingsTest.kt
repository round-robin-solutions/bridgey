package dev.bridgey.android.media

import android.app.Application
import android.content.Context
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.setup.DefaultsGeneration
import dev.bridgey.android.sync.SyncFeatureKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class CallQuietSettingsTest {
    private val app = RuntimeEnvironment.getApplication()

    @Test fun everyInstallGenerationStartsOffAndOldPeersNeverEnableIt() {
        listOf(DefaultsGeneration.FEATURES_ON, DefaultsGeneration.OFF_UNTIL_CHOSEN).forEach { generation ->
            val settings = BridgeySettings(app, "Phone", generation)
            assertFalse(settings.isEnabled(BridgeyFeature.CALL_QUIET, null))
            assertFalse(dev.bridgey.android.featureEnabledByLegacyPeer(BridgeyFeature.CALL_QUIET))
        }
    }

    @Test fun behaviorChoicesAndExplicitPeerOffSurviveReload() {
        val settings = BridgeySettings(app, "Phone")
        settings.setGlobal(BridgeyFeature.CALL_QUIET, true)
        settings.setForDevice("mac", BridgeyFeature.CALL_QUIET, false)
        settings.setCallMediaMode(CallMediaMode.MUTE_ONLY)
        settings.setCallMediaRestoration(CallMediaRestoration.LEAVE_AS_IS)
        val restored = BridgeySettings(app, "Phone")
        assertTrue(restored.isEnabled(BridgeyFeature.CALL_QUIET, null))
        assertFalse(restored.isEnabled(BridgeyFeature.CALL_QUIET, "mac"))
        assertEquals(CallMediaMode.MUTE_ONLY, restored.state.value.callMediaPolicy.mode)
        assertEquals(CallMediaRestoration.LEAVE_AS_IS, restored.state.value.callMediaPolicy.restoration)
    }

    @Test fun sensitiveFeatureAndPoliciesAreNotInGenericSync() {
        assertFalse(SyncFeatureKeys.values.contains(BridgeyFeature.CALL_QUIET))
        assertFalse(dev.bridgey.android.sync.SyncKey.entries.any { it.key.contains("quiet") })
    }

    @Test fun malformedSavedChoicesFallBackToTheAgreedDefaults() {
        app.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE).edit()
            .putString("calls.quiet.mode", "bad").putString("calls.quiet.restoration", "bad").commit()
        assertEquals(CallMediaPolicy(), BridgeySettings(app, "Phone").state.value.callMediaPolicy)
    }

    @Test fun aGlobalOptInDoesNotGrantAPeerAndTheRealPermissionRowExists() {
        val settings = BridgeySettings(app, "Phone")
        settings.setGlobal(BridgeyFeature.CALL_QUIET, true)
        assertTrue(settings.isEnabled(BridgeyFeature.CALL_QUIET, null))
        assertFalse(settings.isEnabled(BridgeyFeature.CALL_QUIET, "mac"))
        assertTrue(dev.bridgey.android.PermissionOrder.flatten().contains(BridgeyFeature.CALL_QUIET))
        settings.setForDevice("mac", BridgeyFeature.CALL_QUIET, true)
        assertTrue(settings.isEnabled(BridgeyFeature.CALL_QUIET, "mac"))
        assertFalse(settings.isEnabled(BridgeyFeature.CALL_QUIET, "another-mac"))
        settings.setForDevice("mac", BridgeyFeature.CALL_QUIET, false)
        assertFalse(settings.isEnabled(BridgeyFeature.CALL_QUIET, "mac"))
        settings.setGlobal(BridgeyFeature.CLIPBOARD, true)
        assertTrue("ordinary missing grants keep their existing defaults", settings.isEnabled(BridgeyFeature.CLIPBOARD, "mac"))
    }

}
