package dev.bridgey.android.routing

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.bridgey.android.BridgeySettings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class SmartRoutingSettingsTest {
    @Test fun preferenceSurvivesRestartAndForgettingTheDeviceClearsIt() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        context.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE).edit().clear().commit()
        val settings = BridgeySettings(context, "Phone")
        assertTrue(settings.state.value.smartNotificationRouting)
        assertNull(settings.state.value.preferredNotificationDeviceId)
        settings.setSmartNotificationRouting(false)
        settings.setPreferredNotificationDeviceId("preferred-mac")
        val restored = BridgeySettings(context, "Phone")
        assertFalse(restored.state.value.smartNotificationRouting)
        assertEquals("preferred-mac", restored.state.value.preferredNotificationDeviceId)
        restored.removeDevice("preferred-mac")
        assertNull(BridgeySettings(context, "Phone").state.value.preferredNotificationDeviceId)
    }
}
