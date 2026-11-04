package dev.bridgey.android.media

import android.Manifest
import android.app.Application
import android.app.Notification
import android.os.Looper
import android.os.UserHandle
import android.service.notification.StatusBarNotification
import android.telephony.TelephonyManager
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class CallQuietSourcesTest {
    private val app = RuntimeEnvironment.getApplication<Application>()
    private val telephony = app.getSystemService(TelephonyManager::class.java)
    private val states = mutableListOf<Pair<Set<String>, Boolean>>()
    private val sources = CallQuietSources(app, { ids, uncertain -> states += ids to uncertain })

    @Before fun grantedPhoneStateOnly() {
        shadowOf(app).grantPermissions(Manifest.permission.READ_PHONE_STATE)
        shadowOf(app).denyPermissions(Manifest.permission.ANSWER_PHONE_CALLS)
    }
    @After fun stop() { sources.update(false) }

    private fun call(): StatusBarNotification {
        val value = Notification.Builder(app, "test").setCategory(Notification.CATEGORY_CALL).setOngoing(true).build()
        value.extras.putInt("android.callType", 2)
        return StatusBarNotification("voip.test", "voip.test", 7, null, 1, 0, value, UserHandle.of(0), null, 1)
    }

    @Test fun cellularObservationDoesNotNeedListenerBindingOrAnswerPermission() {
        sources.update(true)
        shadowOf(Looper.getMainLooper()).idle()
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_OFFHOOK)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(states.last().first.any { it.startsWith("cell_") })
        assertFalse(states.last().second)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_IDLE)
        shadowOf(Looper.getMainLooper()).idleFor(1_500, TimeUnit.MILLISECONDS)
        assertTrue(states.last().first.isEmpty())
        assertFalse(states.last().second)
    }

    @Test fun losingNotificationStateDoesNotGetClearedByAnUnrelatedCellularEnd() {
        sources.update(true)
        val call = call()
        sources.notificationPosted(call, cellularSource = false)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_OFFHOOK)
        shadowOf(Looper.getMainLooper()).idle()
        assertTrue(states.last().first.size == 2)

        sources.notificationsDisconnected()
        assertTrue(states.last().first.single().startsWith("cell_"))
        assertTrue(states.last().second)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_IDLE)
        shadowOf(Looper.getMainLooper()).idleFor(1_500, TimeUnit.MILLISECONDS)
        assertTrue(states.last().first.isEmpty())
        assertTrue(states.last().second)

        sources.notificationsConnected(emptyList())
        assertFalse(states.last().second)
    }

    @Test fun neverAvailablePhoneStateDoesNotInventUncertainty() {
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        sources.notificationPosted(call(), cellularSource = false)
        assertTrue(states.last().first.isNotEmpty())
        assertFalse(states.last().second)
    }

    @Test fun notificationStateEndsOnlyAfterTheExistingRekeyGrace() {
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        val call = call()
        sources.notificationPosted(call, false)
        sources.notificationRemoved(call)
        assertTrue(states.last().first.isNotEmpty())
        shadowOf(Looper.getMainLooper()).idleFor(1_500, TimeUnit.MILLISECONDS)
        assertTrue(states.last().first.isEmpty())
        assertFalse(states.last().second)
    }

    @Test fun revokedCellularPermissionCreatesOnlyCellularUncertaintyUntilFreshObservation() {
        sources.update(true)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_OFFHOOK)
        shadowOf(Looper.getMainLooper()).idle()
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        assertTrue(states.last().second)
        assertTrue(states.last().first.isEmpty())
        sources.notificationsConnected(emptyList())
        assertTrue(states.last().second)

        shadowOf(app).grantPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        shadowOf(Looper.getMainLooper()).idle()
        assertFalse(states.last().second)
        assertTrue(states.last().first.isNotEmpty())
    }
}
