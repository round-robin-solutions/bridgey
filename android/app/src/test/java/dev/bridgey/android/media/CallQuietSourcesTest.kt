package dev.bridgey.android.media

import android.Manifest
import android.app.Application
import android.app.Notification
import android.os.Looper
import android.os.Process
import android.service.notification.StatusBarNotification
import android.telephony.TelephonyManager
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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
    private val app = RuntimeEnvironment.getApplication()
    private val telephony = app.getSystemService(TelephonyManager::class.java)
    private val states = mutableListOf<Pair<Set<String>, Boolean>>()
    private var onState: (Set<String>, Boolean) -> Unit = { _, _ -> }
    private val sources = CallQuietSources(app, { ids, uncertain ->
        states += ids to uncertain
        onState(ids, uncertain)
    })

    @Before fun grantedPhoneStateOnly() {
        shadowOf(app).grantPermissions(Manifest.permission.READ_PHONE_STATE)
        shadowOf(app).denyPermissions(Manifest.permission.ANSWER_PHONE_CALLS)
    }
    @After fun stop() { sources.update(false) }

    @Suppress("DEPRECATION")
    private fun call(id: Int = 7, category: String? = Notification.CATEGORY_CALL): StatusBarNotification {
        val value = Notification.Builder(app, "test").setCategory(category).setOngoing(true).build()
        value.extras.putInt("android.callType", 2)
        return StatusBarNotification("voip.test", "voip.test", id, null, 1, 0, 0, value, Process.myUserHandle(), 1L)
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

    @Test fun notificationRemovalBecomesUncertainOnlyAfterTheExistingRekeyGrace() {
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        val call = call()
        sources.notificationPosted(call, false)
        sources.notificationRemoved(call)
        assertTrue(states.last().first.isNotEmpty())
        assertFalse(states.last().second)
        shadowOf(Looper.getMainLooper()).idleFor(1_500, TimeUnit.MILLISECONDS)
        assertTrue(states.last().first.isEmpty())
        assertTrue(states.last().second)
        sources.notificationsConnected(emptyList())
        assertFalse(states.last().second)
    }

    @Test fun notificationRemovalUncertaintySurvivesAnOverlappingCellularEnd() {
        sources.update(true)
        val call = call()
        sources.notificationPosted(call, cellularSource = false)
        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_OFFHOOK)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(2, states.last().first.size)

        sources.notificationRemoved(call)
        shadowOf(Looper.getMainLooper()).idleFor(1_500, TimeUnit.MILLISECONDS)
        assertTrue(states.last().first.single().startsWith("cell_"))
        assertTrue(states.last().second)

        shadowOf(telephony).setCallState(TelephonyManager.CALL_STATE_IDLE)
        shadowOf(Looper.getMainLooper()).idleFor(1_500, TimeUnit.MILLISECONDS)
        assertTrue(states.last().first.isEmpty())
        assertTrue(states.last().second)
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

    @Test fun continuingCallRebindPreservesManualPlaybackAndLaterDistinctCallQuietsAgain() {
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        val scheduler = AndroidCallMediaScheduler()
        var session = CallMediaSession("player", CallMediaPlayback.PLAYING, true, true, true, 1, contentId = "content")
        var pauses = 0
        var plays = 0
        val platform = object : CallMediaPlatform {
            override fun observe(changed: () -> Unit): () -> Unit = {}
            override fun snapshot() = CallMediaSnapshot(CallMediaAvailability.AVAILABLE, listOf(session))
            override fun pause(sessionId: String): Boolean {
                pauses += 1
                session = session.copy(playback = CallMediaPlayback.PAUSED, revision = session.revision + 1)
                return true
            }
            override fun play(sessionId: String): Boolean { plays += 1; return true }
            override fun muteMusic(expected: CallMediaMusicState): CallMediaMusicState? = null
            override fun restoreMusic(owned: CallMediaMusicState, previous: CallMediaMusicState) = false
        }
        val effects = CallMediaController(platform, scheduler)
        val hub = CallQuietHub(effects, scheduler, { android.os.SystemClock.elapsedRealtime() }, { true },
            { CallMediaPolicy() }, { emptyList() }, { _, _, _ -> false })
        onState = hub::localCallsChanged
        sources.update(true)
        val call = call()
        sources.notificationPosted(call, false)
        val identity = states.last().first
        assertEquals(1, pauses)
        sources.notificationsDisconnected()
        assertTrue(states.last().first.isEmpty())
        assertTrue(states.last().second)
        session = session.copy(playback = CallMediaPlayback.PLAYING, revision = session.revision + 1)

        sources.notificationsConnected(listOf(call to false))
        assertEquals(identity, states.last().first)
        assertFalse(states.last().second)
        assertEquals(CallMediaPlayback.PLAYING, session.playback)
        assertEquals(1, pauses)
        assertEquals(0, plays)

        sources.notificationRemoved(call)
        shadowOf(Looper.getMainLooper()).idleFor(1_500, TimeUnit.MILLISECONDS)
        sources.notificationPosted(call, false)
        assertNotEquals(identity, states.last().first)
        assertEquals(2, pauses)
        hub.stop()
    }

    @Test fun verifiedEmptySnapshotRetiresSuspendedCallIdentity() {
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        val call = call()
        sources.notificationPosted(call, false)
        val identity = states.last().first
        sources.notificationsDisconnected()
        // Repeated disconnects keep identity evidence but do not advertise an active call.
        sources.notificationsDisconnected()
        assertTrue(states.last().first.isEmpty())
        sources.notificationsConnected(emptyList())
        sources.notificationPosted(call, false)
        assertNotEquals(identity, states.last().first)
    }

    @Test fun continuingOngoingUpdateWithoutCategoryKeepsIdentityAcrossRebind() {
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        sources.notificationPosted(call(), false)
        val identity = states.last().first
        sources.notificationsDisconnected()
        sources.notificationsConnected(listOf(call(category = null) to false))
        assertEquals(identity, states.last().first)
        assertFalse(states.last().second)
    }

    @Test fun rekeyRetiresOldKeyBeforeSuspendingIdentity() {
        shadowOf(app).denyPermissions(Manifest.permission.READ_PHONE_STATE)
        sources.update(true)
        val old = call(7)
        val replacement = call(8)
        sources.notificationPosted(old, false)
        val identity = states.last().first
        sources.notificationRemoved(old)
        sources.notificationPosted(replacement, false)
        assertEquals(identity, states.last().first)
        sources.notificationsDisconnected()
        // The old key is a separate call now, rather than another alias for the continued call.
        sources.notificationsConnected(listOf(old to false, replacement to false))
        assertEquals(2, states.last().first.size)
        assertTrue(states.last().first.containsAll(identity))
    }
}
