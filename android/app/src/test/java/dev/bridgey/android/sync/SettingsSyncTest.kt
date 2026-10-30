package dev.bridgey.android.sync

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Settings sync between devices over a fake network (docs/folders-and-settings-sync.md 8.2 and 8.4). Each device
 * is a real [SettingsSyncController] with its own preferences; messages queue and are delivered in order, as on
 * one TCP session. The Mac runs the same cases in SettingsSyncTests.swift.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class SettingsSyncTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext<Application>()
    private var now = 1_792_900_000_000L

    /** One setting held in memory. */
    private class Fake(var value: Any, var stored: Boolean = false, var waiting: Boolean = false) : SyncedSetting {
        var writes = 0
        override fun read(): Any = value
        override fun write(value: Any) { this.value = value; writes++ }
        override fun stored(): Boolean = stored
        override fun waitingForPermission(): Boolean = value == true && waiting
    }

    private data class Sent(val from: String, val to: String, val kind: String, val messageId: String, val payload: JSONObject)

    private inner class Net {
        val devices = LinkedHashMap<String, Device>()
        val queue = ArrayDeque<Sent>()
        val log = ArrayList<Sent>()
        val links = HashSet<Pair<String, String>>()

        fun link(a: Device, b: Device) {
            links += a.id to b.id
            links += b.id to a.id
            a.sync.peerChanged(b.id)
            b.sync.peerChanged(a.id)
        }

        fun unlink(a: Device, b: Device) {
            links -= a.id to b.id
            links -= b.id to a.id
            a.sync.sessionEnded(b.id)
            b.sync.sessionEnded(a.id)
        }

        fun pump(limit: Int = 200) {
            var n = 0
            while (queue.isNotEmpty()) {
                check(++n <= limit) { "messages keep flowing: ${log.takeLast(6).map { "${it.from.take(1)}>${it.to.take(1)} ${it.kind}" }}" }
                val message = queue.removeFirst()
                if (message.from to message.to !in links) continue
                devices.getValue(message.to).sync.receive(message.from, message.kind, message.messageId, message.payload.toString().toByteArray())
            }
        }

        fun kinds(): List<String> = log.map { it.kind }
    }

    /**
     * One device. [veteran]: it synced with another device before (it has a first-connect answer), so a first connect
     * with it asks nobody unless the other device is new (8.4).
     */
    private inner class Device(
        val id: String,
        val name: String,
        val net: Net,
        settings: Map<SyncKey, Fake> = fakes(),
        prefs: String = id,
        veteran: Boolean = true,
    ) {
        val settings = settings
        val answers = context.getSharedPreferences("sync-test-answers-$prefs", Context.MODE_PRIVATE)
        val sync: SettingsSyncController
        val synced = ArrayList<List<SyncChange>>()
        val turnedOn = ArrayList<SyncKey>()

        init {
            if (veteran && answers.all.isEmpty()) answers.edit().putString("an-older-device", SyncAnswers.AUTO).commit()
            sync = SettingsSyncController(
                context.getSharedPreferences("sync-test-$prefs", Context.MODE_PRIVATE), answers, id,
                CoroutineScope(Dispatchers.Unconfined), { now }, debounceMillis = 0, isPhone = id == "phone",
            )
            net.devices[id] = this
            sync.transport = object : SettingsSyncController.Transport {
                override fun send(deviceId: String, kind: String, payload: JSONObject, messageId: String): Boolean {
                    val message = Sent(this@Device.id, deviceId, kind, messageId, payload)
                    net.queue.addLast(message)
                    net.log += message
                    return true
                }
                override fun peerName(deviceId: String): String? = net.devices[deviceId]?.name
                override fun connected(): Collection<String> = net.links.filter { it.first == this@Device.id }.map { it.second }
                override fun remoteOn(deviceId: String): Boolean = net.devices[deviceId]?.sync?.advertised(this@Device.id) == true
            }
            sync.attach(settings)
            sync.onSynced = { _, _, changes -> synced += changes }
            sync.onNeedsPermission = { _, _, key -> turnedOn += key }
        }

        operator fun get(key: SyncKey): Any = settings.getValue(key).value

        /** The person changes [key] here; the observer stamps it. */
        fun edit(key: SyncKey, value: Any) {
            settings.getValue(key).value = value
            sync.localChanged()
        }
    }

    /** The phone's settings: everything but the Mac-only codes and the not-yet-built Update all devices automatically. */
    private fun fakes(): Map<SyncKey, Fake> =
        SyncKey.entries.filter { it != SyncKey.CODES && it != SyncKey.AUTO_UPDATE_ALL }.associateWith { Fake(it.default) }

    private fun clear(vararg names: String) = names.forEach {
        context.getSharedPreferences("sync-test-$it", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("sync-test-answers-$it", Context.MODE_PRIVATE).edit().clear().commit()
    }

    private fun pair(): Triple<Net, Device, Device> {
        clear("phone", "mac")
        val net = Net()
        return Triple(net, Device("phone", "OnePlus 11", net), Device("mac", "Work Mac", net))
    }

    @Test fun connectingSendsOneSnapshotEachWayAndNothingMore() {
        val (net, phone, mac) = pair()
        net.link(phone, mac)
        net.pump()
        assertEquals(listOf(SettingsSyncKinds.SNAPSHOT, SettingsSyncKinds.SNAPSHOT, SettingsSyncKinds.ACK, SettingsSyncKinds.ACK), net.kinds())
        assertTrue(phone.synced.isEmpty() && mac.synced.isEmpty())
    }

    @Test fun theSpecExampleEndsWithTheLaterEditAfterOneUpdateAndOneAckEachWay() {
        val (net, phone, mac) = pair()
        net.link(phone, mac)
        net.pump()
        net.log.clear()
        // The phone picks Merge at 1000; the Mac picks Replace at 1200, before hearing of it.
        now = 1_000
        phone.edit(SyncKey.FOLDER_CONFLICT, "merge")
        now = 1_200
        mac.edit(SyncKey.FOLDER_CONFLICT, "replace")
        net.pump()
        assertEquals("replace", phone[SyncKey.FOLDER_CONFLICT])
        assertEquals("replace", mac[SyncKey.FOLDER_CONFLICT])
        assertEquals(phone.sync.record(SyncKey.FOLDER_CONFLICT), mac.sync.record(SyncKey.FOLDER_CONFLICT))
        assertEquals(2, net.kinds().count { it == SettingsSyncKinds.UPDATE })
        assertEquals(2, net.kinds().count { it == SettingsSyncKinds.ACK })
        assertEquals(4, net.kinds().size)
    }

    @Test fun aLiveChangeAppliesOnTheOtherDeviceAndIsNeverSentBack() {
        val (net, phone, mac) = pair()
        net.link(phone, mac)
        net.pump()
        net.log.clear()
        mac.edit(SyncKey.ACTIVITY_PREVIEWS, false)
        net.pump()
        assertEquals(false, phone[SyncKey.ACTIVITY_PREVIEWS])
        assertEquals(listOf(listOf(SyncChange(SyncKey.ACTIVITY_PREVIEWS, false))), phone.synced)
        // The apply is not a local edit: the observer sees a match and nothing goes back.
        phone.sync.localChanged()
        net.pump()
        assertEquals(listOf(SettingsSyncKinds.UPDATE, SettingsSyncKinds.ACK), net.kinds())
    }

    @Test fun aRemoteEnableTurnsTheFeatureOnAndSaysSo() {
        val (net, phone, mac) = pair()
        net.link(phone, mac)
        net.pump()
        mac.edit(SyncKey.CALLS, true)
        net.pump()
        assertEquals(true, phone[SyncKey.CALLS])
        // An activity item only: no notification, since the phone needs no permission for it.
        assertTrue(phone.turnedOn.isEmpty())
        assertEquals("calls=1", SyncDetail.encode(phone.synced.single()))
    }

    @Test fun aFeatureWaitingForPermissionShowsOnBothAndClearsOnceAllowed() {
        val (net, phone, mac) = pair()
        phone.settings.getValue(SyncKey.NOTIFICATIONS).waiting = true
        net.link(phone, mac)
        net.pump()
        mac.edit(SyncKey.NOTIFICATIONS, true)
        net.pump()
        assertEquals(true, phone[SyncKey.NOTIFICATIONS])
        assertEquals(listOf(SyncKey.NOTIFICATIONS), phone.turnedOn)
        assertTrue(phone.sync.ui.value.row(SyncKey.NOTIFICATIONS)!!.waitingHere)
        // The phone's update (here its ack's follow-up) carries the waiting list.
        phone.sync.permissionsChanged()
        net.pump()
        assertEquals(listOf("OnePlus 11"), mac.sync.ui.value.row(SyncKey.NOTIFICATIONS)!!.waitingOn)
        // Notification access granted on the phone: an update with no records and an empty list.
        phone.settings.getValue(SyncKey.NOTIFICATIONS).waiting = false
        net.log.clear()
        phone.sync.permissionsChanged()
        net.pump()
        val update = net.log.first { it.kind == SettingsSyncKinds.UPDATE }
        assertEquals(0, update.payload.getJSONObject("records").length())
        assertEquals(0, update.payload.getJSONArray("waiting").length())
        assertNull(mac.sync.ui.value.row(SyncKey.NOTIFICATIONS))
    }

    @Test fun aNeverChosenSettingTakesTheOtherDevicesChoiceOnConnect() {
        clear("phone", "mac")
        val net = Net()
        val phone = Device("phone", "OnePlus 11", net)
        val mac = Device("mac", "Work Mac", net)
        mac.edit(SyncKey.FILES, true)
        net.link(phone, mac)
        net.pump()
        assertEquals(true, phone[SyncKey.FILES])
        assertEquals(mac.sync.record(SyncKey.FILES), phone.sync.record(SyncKey.FILES))
        // The snapshot's ack tells the Mac the phone adopted it: no "Different on" either side.
        assertNull(phone.sync.ui.value.row(SyncKey.FILES))
        assertNull(mac.sync.ui.value.row(SyncKey.FILES))
    }

    @Test fun twoChosenValuesStayDifferentUntilApplyToAll() {
        val (net, phone, mac) = pair()
        // While apart: both chose, the Mac later and with a clock far ahead.
        phone.edit(SyncKey.CALLS, true)
        now += 3_600_000
        mac.edit(SyncKey.CALLS, true)
        mac.edit(SyncKey.CALLS, false)
        now -= 3_600_000
        net.link(phone, mac)
        net.pump()
        assertEquals(true, phone[SyncKey.CALLS])
        assertEquals(false, mac[SyncKey.CALLS])
        assertEquals(listOf("Work Mac"), phone.sync.ui.value.row(SyncKey.CALLS)!!.differentOn)
        assertEquals(listOf("OnePlus 11"), mac.sync.ui.value.row(SyncKey.CALLS)!!.differentOn)
        // Apply to all on the phone wins on the Mac even though the Mac's clock is ahead.
        phone.sync.applyToAll(SyncKey.CALLS)
        net.pump()
        assertEquals(true, mac[SyncKey.CALLS])
        assertNull(phone.sync.ui.value.row(SyncKey.CALLS))
        assertNull(mac.sync.ui.value.row(SyncKey.CALLS))
    }

    @Test fun aDeviceThatWasOfflineIsMarkedDifferentNotOverwritten() {
        clear("phone", "a", "b")
        val net = Net()
        val phone = Device("phone", "OnePlus 11", net)
        val a = Device("a", "Work Mac", net)
        val b = Device("b", "Home Mac", net)
        net.link(phone, a)
        net.link(phone, b)
        net.pump()
        net.unlink(phone, b)
        a.edit(SyncKey.REDUCE_MOTION, true)
        net.pump()
        b.edit(SyncKey.REDUCE_MOTION, true)
        b.edit(SyncKey.REDUCE_MOTION, false)
        net.link(phone, b)
        net.pump()
        assertEquals(true, phone[SyncKey.REDUCE_MOTION])
        assertEquals(false, b[SyncKey.REDUCE_MOTION])
        assertEquals(listOf("Home Mac"), phone.sync.ui.value.row(SyncKey.REDUCE_MOTION)!!.differentOn)
        // Apply to all on the Mac that was away: its value reaches the phone and, relayed, the other Mac.
        b.sync.applyToAll(SyncKey.REDUCE_MOTION)
        net.pump()
        assertEquals(false, phone[SyncKey.REDUCE_MOTION])
        assertEquals(false, a[SyncKey.REDUCE_MOTION])
    }

    @Test fun thePhoneRelaysOneMacsChangeToTheOther() {
        clear("phone", "a", "b")
        val net = Net()
        val phone = Device("phone", "OnePlus 11", net)
        val a = Device("a", "Work Mac", net)
        val b = Device("b", "Home Mac", net)
        net.link(phone, a)
        net.link(phone, b)
        net.pump()
        a.edit(SyncKey.FOLDER_CONFLICT, "merge")
        net.pump()
        assertEquals("merge", phone[SyncKey.FOLDER_CONFLICT])
        assertEquals("merge", b[SyncKey.FOLDER_CONFLICT])
        assertEquals(a.sync.record(SyncKey.FOLDER_CONFLICT), b.sync.record(SyncKey.FOLDER_CONFLICT))
    }

    @Test fun anAdoptionNeverOverwritesAChoiceOnAMacWhoseSnapshotHasNotArrived() {
        clear("phone", "a", "b")
        val net = Net()
        val phone = Device("phone", "OnePlus 11", net)
        val a = Device("a", "Work Mac", net)
        val b = Device("b", "Home Mac", net)
        a.edit(SyncKey.MEDIA, true)
        b.edit(SyncKey.MEDIA, true)
        b.edit(SyncKey.MEDIA, false)
        // Both Macs connect at once; the phone (never chose) hears Work Mac first.
        net.link(phone, b)
        net.link(phone, a)
        val fromB = net.queue.filter { it.from == "b" }
        net.queue.removeAll(fromB)
        net.pump()
        fromB.forEach(net.queue::addLast)
        net.pump()
        assertEquals(true, phone[SyncKey.MEDIA])
        assertEquals(false, b[SyncKey.MEDIA])
        assertEquals(listOf("Home Mac"), phone.sync.ui.value.row(SyncKey.MEDIA)!!.differentOn)
    }

    @Test fun anUncheckedSettingIsNeitherSentNorApplied() {
        val (net, phone, mac) = pair()
        phone.sync.setSyncs(SyncKey.LINKS, false)
        net.link(phone, mac)
        net.pump()
        assertFalse(net.log.first { it.from == "phone" && it.kind == SettingsSyncKinds.SNAPSHOT }.payload.getJSONObject("records").has("feature.links"))
        mac.edit(SyncKey.LINKS, true)
        net.pump()
        assertEquals(false, phone[SyncKey.LINKS])
        // Turning it back on sends the phone's own value; the Mac decides by the stamps.
        phone.sync.setSyncs(SyncKey.LINKS, true)
        net.pump()
        assertTrue(net.log.any { it.from == "phone" && it.kind == SettingsSyncKinds.UPDATE && it.payload.getJSONObject("records").has("feature.links") })
    }

    @Test fun syncOffKeepsValuesAndOnAgainSendsAFreshSnapshot() {
        val (net, phone, mac) = pair()
        net.link(phone, mac)
        net.pump()
        mac.edit(SyncKey.PING, true)
        net.pump()
        phone.sync.setEnabled(false)
        mac.sync.peerChanged("phone")
        assertEquals(true, phone[SyncKey.PING])
        mac.edit(SyncKey.PING, false)
        now += 1
        net.pump()
        assertEquals(true, phone[SyncKey.PING])
        net.log.clear()
        phone.sync.setEnabled(true)
        mac.sync.peerChanged("phone")
        net.pump()
        assertEquals(2, net.kinds().count { it == SettingsSyncKinds.SNAPSHOT })
        // Both chose differently while sync was off: shown, not overwritten.
        assertEquals(true, phone[SyncKey.PING])
        assertEquals(listOf("Work Mac"), phone.sync.ui.value.row(SyncKey.PING)!!.differentOn)
    }

    @Test fun messagesAreIgnoredUnlessBothSidesSync() {
        val (net, phone, mac) = pair()
        mac.sync.setDeviceEnabled("phone", false)
        net.link(phone, mac)
        net.pump()
        assertTrue(net.log.isEmpty())
        val update = settingsPayload(mapOf(SyncKey.CALLS to SyncRecord(true, now, 1, "mac")), emptyList(), snapshot = false)
        assertEquals(SettingsSyncController.Receipt.IGNORED, phone.sync.receive("mac", SettingsSyncKinds.UPDATE, "m1", update.toString().toByteArray()))
        assertEquals(false, phone[SyncKey.CALLS])
    }

    @Test fun malformedAndFutureSchemasAreAnsweredWithAnError() {
        val (net, phone, mac) = pair()
        net.link(phone, mac)
        net.pump()
        net.log.clear()
        phone.sync.receive("mac", SettingsSyncKinds.UPDATE, "m1", "{schema:1}".toByteArray())
        phone.sync.receive("mac", SettingsSyncKinds.UPDATE, "m2", """{"schema":2,"records":{}}""".toByteArray())
        val errors = net.log.filter { it.kind == SettingsSyncKinds.ERROR }.map { it.payload.getString("code") }
        assertEquals(listOf(SettingsErrorCodes.INVALID_MESSAGE, SettingsErrorCodes.UNSUPPORTED_SCHEMA), errors)
        // invalid_message is only logged; unsupported_schema stops sync with that device for the session.
        net.queue.clear()
        mac.sync.receive("phone", SettingsSyncKinds.ERROR, "e1", settingsErrorPayload(SettingsErrorCodes.INVALID_MESSAGE).toString().toByteArray())
        mac.edit(SyncKey.BATTERY, true)
        net.pump()
        assertEquals(true, phone[SyncKey.BATTERY])
        mac.sync.receive("phone", SettingsSyncKinds.ERROR, "e2", settingsErrorPayload(SettingsErrorCodes.UNSUPPORTED_SCHEMA).toString().toByteArray())
        mac.edit(SyncKey.BATTERY, false)
        net.pump()
        assertEquals(true, phone[SyncKey.BATTERY])
    }

    @Test fun moreThanTwentyMessagesInTenSecondsAreDroppedAndAnsweredOnce() {
        val (net, phone, mac) = pair()
        net.link(phone, mac)
        net.pump()
        net.log.clear()
        // The snapshot and the ack already used 2 of the 20.
        repeat(25) { n ->
            val update = settingsPayload(mapOf(SyncKey.REDUCE_MOTION to SyncRecord(n % 2 == 0, now + n, 10L + n, "mac")), emptyList(), snapshot = false)
            phone.sync.receive("mac", SettingsSyncKinds.UPDATE, "r$n", update.toString().toByteArray())
        }
        assertEquals(1, net.log.count { it.kind == SettingsSyncKinds.ERROR && it.payload.getString("code") == SettingsErrorCodes.RATE_LIMITED })
        assertEquals(18, net.log.count { it.kind == SettingsSyncKinds.ACK })
        now += SETTINGS_RATE_WINDOW_MILLIS
        val late = settingsPayload(mapOf(SyncKey.REDUCE_MOTION to SyncRecord(true, now, 99, "mac")), emptyList(), snapshot = false)
        assertEquals(SettingsSyncController.Receipt.HANDLED, phone.sync.receive("mac", SettingsSyncKinds.UPDATE, "late", late.toString().toByteArray()))
    }

    @Test fun forgetRemovesTheDeviceSwitch() {
        val (_, phone, _) = pair()
        phone.sync.setDeviceEnabled("mac", false)
        assertFalse(phone.sync.advertised("mac"))
        phone.sync.forget("mac")
        assertTrue(phone.sync.advertised("mac"))
        assertTrue("mac" !in phone.sync.switches.value.devices)
    }

    @Test fun theFirstSyncBuildStampsStoredValuesAsChosen() {
        clear("upgrade")
        val net = Net()
        val settings = fakes().toMutableMap()
        settings[SyncKey.REDUCE_MOTION] = Fake(true, stored = true)
        settings[SyncKey.FOLDER_CONFLICT] = Fake("ask", stored = true)
        val phone = Device("phone", "OnePlus 11", net, settings, prefs = "upgrade")
        assertEquals(SyncRecord(true, 1, 1, "phone"), phone.sync.record(SyncKey.REDUCE_MOTION))
        assertEquals(SyncRecord("ask", 1, 1, "phone"), phone.sync.record(SyncKey.FOLDER_CONFLICT))
        assertEquals(SyncRecord(false, 0, 0, ""), phone.sync.record(SyncKey.CALLS))
        // Store-and-relay only: codes from messages has no setting on the phone.
        assertEquals(SyncRecord(false, 0, 0, ""), phone.sync.record(SyncKey.CODES))
        // A second start keeps the stamps (no new upgrade stamp).
        settings.getValue(SyncKey.CALLS).stored = true
        val again = Device("phone", "OnePlus 11", Net(), settings, prefs = "upgrade")
        assertEquals(SyncRecord(false, 0, 0, ""), again.sync.record(SyncKey.CALLS))
    }

    @Test fun aStoreAndRelayKeyReachesTheOtherMacThroughThePhone() {
        clear("phone", "a", "b")
        val net = Net()
        val phone = Device("phone", "OnePlus 11", net)
        val macSettings = { fakes() + (SyncKey.CODES to Fake(false)) }
        val a = Device("a", "Work Mac", net, macSettings())
        val b = Device("b", "Home Mac", net, macSettings())
        net.link(phone, a)
        net.link(phone, b)
        net.pump()
        a.edit(SyncKey.CODES, true)
        net.pump()
        assertEquals(true, b[SyncKey.CODES])
        assertEquals(true, phone.sync.record(SyncKey.CODES)!!.value)
        // Nothing to show on the phone for a setting it does not have.
        assertTrue(phone.synced.isEmpty())
    }

    // MARK: First connect, ask once (Rahul, 2026-10-27)

    private fun newPhoneAndMac(): Triple<Net, Device, Device> {
        clear("phone", "mac")
        val net = Net()
        return Triple(net, Device("phone", "OnePlus 11", net, veteran = false), Device("mac", "Work Mac", net))
    }

    @Test fun aNewPhoneAsksAndUseTheseTakesTheMacsFeatures() {
        val (net, phone, mac) = newPhoneAndMac()
        mac.edit(SyncKey.CALLS, true)
        mac.edit(SyncKey.FOLDER_CONFLICT, "merge")
        net.link(phone, mac)
        net.pump()
        assertEquals(listOf(SyncQuestion("mac", "Work Mac")), phone.sync.ui.value.questions)
        assertTrue(mac.sync.ui.value.questions.isEmpty())
        // Nothing moved yet, either way.
        assertEquals(false, phone[SyncKey.CALLS])
        assertEquals("merge", mac[SyncKey.FOLDER_CONFLICT])
        phone.sync.answer("mac", use = true)
        net.pump()
        assertEquals(true, phone[SyncKey.CALLS])
        assertEquals("merge", phone[SyncKey.FOLDER_CONFLICT])
        assertTrue(phone.sync.ui.value.questions.isEmpty())
        assertEquals(SyncAnswers.USE, phone.answers.getString("mac", null))
        assertEquals(SyncAnswers.PEER, mac.answers.getString("phone", null))
        assertNull(phone.sync.ui.value.row(SyncKey.CALLS))
        assertNull(mac.sync.ui.value.row(SyncKey.CALLS))
        // From now on sync runs silently.
        mac.edit(SyncKey.REDUCE_MOTION, true)
        net.pump()
        assertEquals(true, phone[SyncKey.REDUCE_MOTION])
        net.unlink(phone, mac)
        net.link(phone, mac)
        net.pump()
        assertTrue(phone.sync.ui.value.questions.isEmpty())
    }

    @Test fun keepMineKeepsBothSidesAndShowsWhereTheyDiffer() {
        val (net, phone, mac) = newPhoneAndMac()
        phone.edit(SyncKey.FILES, true)
        mac.edit(SyncKey.CALLS, true)
        net.link(phone, mac)
        net.pump()
        phone.sync.answer("mac", use = false)
        net.pump()
        assertEquals(false, phone[SyncKey.CALLS])
        assertEquals(true, phone[SyncKey.FILES])
        // The Mac never took the phone's values either.
        assertEquals(false, mac[SyncKey.FILES])
        assertEquals(listOf("Work Mac"), phone.sync.ui.value.row(SyncKey.CALLS)!!.differentOn)
        assertEquals(listOf("OnePlus 11"), mac.sync.ui.value.row(SyncKey.FILES)!!.differentOn)
        assertEquals(SyncAnswers.KEEP, phone.answers.getString("mac", null))
        // The kept values nobody had chosen are pinned, so the next connect does not quietly take the other's.
        assertEquals(SyncRecord(false, 1, 1, "phone"), phone.sync.record(SyncKey.CALLS))
        assertEquals(SyncRecord(false, 1, 1, "mac"), mac.sync.record(SyncKey.FILES))
        net.unlink(phone, mac)
        net.link(phone, mac)
        net.pump()
        assertEquals(false, phone[SyncKey.CALLS])
        assertEquals(false, mac[SyncKey.FILES])
        assertEquals(listOf("Work Mac"), phone.sync.ui.value.row(SyncKey.CALLS)!!.differentOn)
        phone.sync.applyToAll(SyncKey.CALLS)
        net.pump()
        assertEquals(false, mac[SyncKey.CALLS])
        assertNull(phone.sync.ui.value.row(SyncKey.CALLS))
        // Live edits sync as usual after the answer.
        phone.edit(SyncKey.PING, true)
        net.pump()
        assertEquals(true, mac[SyncKey.PING])
    }

    @Test fun nothingToAskWhenNothingDiffers() {
        val (net, phone, mac) = newPhoneAndMac()
        net.link(phone, mac)
        net.pump()
        assertTrue(phone.sync.ui.value.questions.isEmpty())
        assertEquals(SyncAnswers.USE, phone.answers.getString("mac", null))
        mac.edit(SyncKey.MEDIA, true)
        net.pump()
        assertEquals(true, phone[SyncKey.MEDIA])
    }

    @Test fun whenBothAreNewThePhoneAsks() {
        clear("phone", "mac")
        val net = Net()
        val phone = Device("phone", "OnePlus 11", net, veteran = false)
        val mac = Device("mac", "Work Mac", net, veteran = false)
        mac.edit(SyncKey.LINKS, true)
        net.link(phone, mac)
        net.pump()
        assertEquals(listOf("mac"), phone.sync.ui.value.questions.map { it.deviceId })
        assertTrue(mac.sync.ui.value.questions.isEmpty())
    }

    @Test fun aQuestionLeftOpenIsAskedAgainNextTime() {
        val (net, phone, mac) = newPhoneAndMac()
        mac.edit(SyncKey.CALLS, true)
        net.link(phone, mac)
        net.pump()
        net.unlink(phone, mac)
        assertTrue(phone.sync.ui.value.questions.isEmpty())
        net.link(phone, mac)
        net.pump()
        assertEquals(listOf("mac"), phone.sync.ui.value.questions.map { it.deviceId })
    }

    @Test fun resetSettingsKeepsTheAnswerSoTheOthersChoicesComeBackSilently() {
        val (net, phone, mac) = newPhoneAndMac()
        mac.edit(SyncKey.CALLS, true)
        net.link(phone, mac)
        net.pump()
        phone.sync.answer("mac", use = false)
        net.pump()
        net.unlink(phone, mac)
        // Reset > Settings clears bridgey.sync and the settings, not the answers.
        context.getSharedPreferences("sync-test-phone", Context.MODE_PRIVATE).edit().clear().commit()
        val reset = Device("phone", "OnePlus 11", net, veteran = false)
        net.link(reset, mac)
        net.pump()
        assertTrue(reset.sync.ui.value.questions.isEmpty())
        assertEquals(true, reset[SyncKey.CALLS])
        // Nothing was pushed to the Mac.
        assertEquals(true, mac[SyncKey.CALLS])
    }

    @Test fun forgetClearsTheAnswer() {
        val (net, phone, mac) = newPhoneAndMac()
        net.link(phone, mac)
        net.pump()
        assertEquals(SyncAnswers.USE, phone.answers.getString("mac", null))
        net.unlink(phone, mac)
        phone.sync.forget("mac")
        assertNull(phone.answers.getString("mac", null))
    }

    @Test fun textMessagesTurnedOnByAMacWaitForTheSmsPermissionHere() {
        val (net, phone, mac) = pair()
        phone.settings.getValue(SyncKey.SMS).waiting = true
        net.link(phone, mac)
        net.pump()
        mac.edit(SyncKey.SMS, true)
        net.pump()
        assertEquals(true, phone[SyncKey.SMS])
        // The permission is this phone's to give: the one case that notifies.
        assertEquals(listOf(SyncKey.SMS), phone.turnedOn)
        assertEquals(listOf("OnePlus 11"), mac.sync.ui.value.row(SyncKey.SMS)!!.waitingOn)
        // Screen sharing asks on the phone each time, so turning it on never waits.
        mac.edit(SyncKey.SCREEN, true)
        net.pump()
        assertEquals(true, phone[SyncKey.SCREEN])
        assertEquals(listOf(SyncKey.SMS), phone.turnedOn)
    }

    @Test fun updateAllDevicesAutomaticallyIsRelayedBeforeAnyDeviceHasIt() {
        clear("phone", "a", "b")
        val net = Net()
        val phone = Device("phone", "OnePlus 11", net)
        val macSettings = { fakes() + (SyncKey.AUTO_UPDATE_ALL to Fake(false)) }
        val a = Device("a", "Work Mac", net, macSettings())
        val b = Device("b", "Home Mac", net, macSettings())
        net.link(phone, a)
        net.link(phone, b)
        net.pump()
        a.edit(SyncKey.AUTO_UPDATE_ALL, true)
        net.pump()
        assertEquals(true, b[SyncKey.AUTO_UPDATE_ALL])
        assertEquals(true, phone.sync.record(SyncKey.AUTO_UPDATE_ALL)!!.value)
    }

    @Test fun activityDetailRoundTrips() {
        val changes = listOf(SyncChange(SyncKey.REDUCE_MOTION, false), SyncChange(SyncKey.FOLDER_DESTINATION, "fixed"), SyncChange(SyncKey.CALLS, true))
        val detail = SyncDetail.encode(changes)
        assertEquals("folder_destination=2,reduce_motion=0,calls=1", detail)
        assertEquals(listOf(changes[1], changes[0], changes[2]), SyncDetail.decode(detail))
        assertEquals(25, SyncDetail.decode(SyncDetail.encode(SyncKey.entries.map { SyncChange(it, it.default) })).size)
        assertTrue(SyncDetail.decode("calls=1,evil text").isEmpty())
    }
}
