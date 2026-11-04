package dev.bridgey.android

import android.Manifest
import android.app.Application
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
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
@Config(sdk = [26, 30, 31, 35], application = Application::class)
@LooperMode(LooperMode.Mode.PAUSED)
class PhoneCallStateObserverTest {
    private val application = RuntimeEnvironment.getApplication<Application>()
    private val telephony = application.getSystemService(TelephonyManager::class.java)
    private val observed = mutableListOf<Int>()
    private val observer = PhoneCallStateObserver(application) { observed.add(it) }

    @Before fun allowPhoneState() {
        shadowOf(application).grantPermissions(Manifest.permission.READ_PHONE_STATE)
    }

    @After fun stop() {
        observer.stop()
    }

    @Test fun registeredListenerReceivesCallEndOnOldAndNewAndroid() {
        observer.start()
        shadowOf(Looper.getMainLooper()).idle()
        observed.clear()

        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_RINGING)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_OFFHOOK)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_IDLE)
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(
            listOf(TelephonyManager.CALL_STATE_RINGING, TelephonyManager.CALL_STATE_OFFHOOK, TelephonyManager.CALL_STATE_IDLE),
            observed,
        )
    }

    @Test fun stopUnregistersAndRejectsAnAlreadyQueuedCallback() {
        observer.start()
        shadowOf(Looper.getMainLooper()).idle()
        val deliverStale = registeredCallback()
        observer.stop()
        observed.clear()

        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_RINGING)
        deliverStale(TelephonyManager.CALL_STATE_IDLE)
        shadowOf(Looper.getMainLooper()).idle()

        assertTrue(observed.isEmpty())
    }

    @Test fun replacingTheRegistrationCannotDeliverFromTheOldListener() {
        observer.start()
        shadowOf(Looper.getMainLooper()).idle()
        val deliverStale = registeredCallback()
        observer.start()
        shadowOf(Looper.getMainLooper()).idle()
        observed.clear()

        deliverStale(TelephonyManager.CALL_STATE_IDLE)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_OFFHOOK)
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(listOf(TelephonyManager.CALL_STATE_OFFHOOK), observed)
    }

    @Suppress("DEPRECATION")
    @Test fun removedCallNotificationFinallyEndsWhenThePhoneGoesIdle() {
        val main = Handler(Looper.getMainLooper())
        val ended = mutableListOf<String>()
        val calls = CallLifecycle(
            scheduler = { delay, task ->
                val runnable = Runnable(task)
                main.postDelayed(runnable, delay)
                val cancel: () -> Unit = { main.removeCallbacks(runnable) }
                cancel
            },
            telephonyState = { telephonyCallType(telephony.callState) },
            endCall = { id, _ -> ended.add(id) },
        )
        val callObserver = PhoneCallStateObserver(application) { state ->
            calls.telephonyChanged(telephonyCallType(state))
        }
        try {
            shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_OFFHOOK)
            callObserver.start()
            shadowOf(Looper.getMainLooper()).idle()
            calls.forwarded("call", "dialer-key", "dialer.app", telephony = true)
            calls.notificationRemoved("dialer-key")
            shadowOf(Looper.getMainLooper()).idleFor(CallLifecycle.REKEY_GRACE_MS, TimeUnit.MILLISECONDS)
            assertTrue(ended.isEmpty())

            shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_IDLE)
            shadowOf(Looper.getMainLooper()).idleFor(CallLifecycle.IDLE_DEBOUNCE_MS, TimeUnit.MILLISECONDS)

            assertEquals(listOf("call"), ended)
        } finally {
            callObserver.stop()
            calls.clear()
        }
    }

    @Suppress("DEPRECATION")
    private fun registeredCallback(): (Int) -> Unit =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (shadowOf(telephony).lastTelephonyCallback as TelephonyCallback.CallStateListener).let { callback ->
                { state: Int -> callback.onCallStateChanged(state) }
            }
        } else {
            shadowOf(telephony).listener.let { listener: PhoneStateListener ->
                { state: Int -> listener.onCallStateChanged(state, null) }
            }
        }
}
