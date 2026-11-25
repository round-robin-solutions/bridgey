package dev.bridgey.android.display

import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.DeviceLinkState
import dev.bridgey.android.FeatureStateDecoding
import dev.bridgey.android.decodeFeatureFlag
import dev.bridgey.android.decodeFeatureState
import dev.bridgey.android.featureEnabledByLegacyPeer
import dev.bridgey.android.featureOnByDefault
import dev.bridgey.android.setup.DefaultsGeneration
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mixed versions: the key is optional, read outside the golden map, and nothing older changes meaning. */
class DisplayFeatureTest {
    private fun map(vararg extra: Pair<String, Any>): ByteArray {
        val features = JSONObject()
            .put("clipboard", true).put("files", true).put("notifications", true).put("battery", true).put("find_device", true)
        extra.forEach { (key, value) -> features.put(key, value) }
        return JSONObject().put("version", 1).put("features", features).toString().toByteArray()
    }

    @Test fun theKeyIsTheProtocolsKey() = assertEquals(SCREEN_CONTROL_FEATURE_KEY, BridgeyFeature.SCREEN_CONTROL.key)

    @Test fun anOlderMacWithoutTheKeyNeverOffersIt() {
        val state = decodeFeatureState(map()) as FeatureStateDecoding.State
        assertFalse(BridgeyFeature.SCREEN_CONTROL in state.features)
        assertFalse(decodeFeatureFlag(map(), SCREEN_CONTROL_FEATURE_KEY))
        assertFalse(featureEnabledByLegacyPeer(BridgeyFeature.SCREEN_CONTROL))
        assertEquals(false, DeviceLinkState().remoteFeatures[BridgeyFeature.SCREEN_CONTROL])
    }

    @Test fun onlyJsonTrueTurnsItOnAndAWrongTypeNeverInvalidatesTheMap() {
        assertTrue(decodeFeatureFlag(map(SCREEN_CONTROL_FEATURE_KEY to true), SCREEN_CONTROL_FEATURE_KEY))
        assertFalse(decodeFeatureFlag(map(SCREEN_CONTROL_FEATURE_KEY to false), SCREEN_CONTROL_FEATURE_KEY))
        assertFalse(decodeFeatureFlag(map(SCREEN_CONTROL_FEATURE_KEY to "yes"), SCREEN_CONTROL_FEATURE_KEY))
        assertTrue(decodeFeatureState(map(SCREEN_CONTROL_FEATURE_KEY to "yes")) is FeatureStateDecoding.State)
    }

    @Test fun phoneScreenSharingAndTheTouchpadKeepTheirOwnKeys() {
        val state = decodeFeatureState(map("screen_draft1" to true, "remote_input_draft1" to true, SCREEN_CONTROL_FEATURE_KEY to false)) as FeatureStateDecoding.State
        assertEquals(true, state.features[BridgeyFeature.SCREEN])
        assertEquals(true, state.features[BridgeyFeature.REMOTE_INPUT])
        val other = decodeFeatureState(map(SCREEN_CONTROL_FEATURE_KEY to true)) as FeatureStateDecoding.State
        assertEquals(false, other.features[BridgeyFeature.SCREEN])
        assertEquals(false, other.features[BridgeyFeature.REMOTE_INPUT])
    }

    @Test fun onWhereFeaturesWereOnByDefaultOffUntilChosenOnFreshInstalls() {
        assertTrue(featureOnByDefault(BridgeyFeature.SCREEN_CONTROL))
        assertTrue(DefaultsGeneration.featureDefault(BridgeyFeature.SCREEN_CONTROL, DefaultsGeneration.FEATURES_ON))
        assertFalse(DefaultsGeneration.featureDefault(BridgeyFeature.SCREEN_CONTROL, DefaultsGeneration.OFF_UNTIL_CHOSEN))
    }

    @Test fun thePhoneAsksOnlyAsAViewerAndController() {
        val caps = viewerCapabilities()
        assertTrue(caps.screenViewer && caps.h264Decode)
        assertFalse(caps.screenSource || caps.fullDisplaySource || caps.h264Encode)
        assertEquals(InputCapabilities(), caps.inputHost)
    }
}
