package dev.bridgey.android

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A fresh install starts with every feature off. Its features.update is what any phone with the
 * switches off has always sent (every key, false), so upstream peers read it as valid.
 */
class OffByDefaultProtocolTest {
    @Test
    fun everyFeatureOffIsAValidFeatureState() {
        val values = JSONObject()
        BridgeyFeature.entries.forEach { values.put(it.key, dev.bridgey.android.setup.DefaultsGeneration.featureDefault(it, dev.bridgey.android.setup.DefaultsGeneration.OFF_UNTIL_CHOSEN)) }
        val payload = JSONObject().put("version", 1).put("features", values).toString().toByteArray()
        val decoded = decodeFeatureState(payload)
        assertTrue(decoded.toString(), decoded is FeatureStateDecoding.State)
        decoded as FeatureStateDecoding.State
        // Keys read outside this map (FLAG_FEATURE_KEYS, decodeFeatureFlag) are checked where they are read.
        assertEquals(BridgeyFeature.entries.filter { it.key !in FLAG_FEATURE_KEYS }.associateWith { false }, decoded.features)
        assertTrue(FLAG_FEATURE_KEYS.none { decodeFeatureFlag(payload, it) })
    }
}
