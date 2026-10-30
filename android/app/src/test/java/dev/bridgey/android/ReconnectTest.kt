package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A clock the test moves by hand. */
internal class ManualClock(var now: Long = 1_000_000L, var wall: Long = 1_700_000_000_000L) : ReconnectClock {
    private class Task(val at: Long, val action: () -> Unit) {
        var cancelled = false
    }

    private val tasks = mutableListOf<Task>()

    override fun elapsedMillis(): Long = now

    override fun wallMillis(): Long = wall

    override fun schedule(delayMillis: Long, action: () -> Unit): ScheduledTask {
        val task = Task(now + delayMillis.coerceAtLeast(0), action)
        tasks += task
        return ScheduledTask { task.cancelled = true }
    }

    fun advance(millis: Long) {
        val target = now + millis
        while (true) {
            val next = tasks.filter { !it.cancelled && it.at <= target }.minByOrNull { it.at } ?: break
            wall += next.at - now
            now = next.at
            tasks.remove(next)
            next.action()
        }
        wall += target - now
        now = target
        tasks.removeAll { it.cancelled }
    }
}

internal class MemoryAddressBookStore : AddressBookStore {
    var value: String? = null
    override fun load(): String? = value
    override fun save(value: String) {
        this.value = value
    }
}

class ReconnectTest {
    private val mac = "f00dfeed-0000-4000-8000-000000000001"
    private val homeLan = listOf(LocalIPv4Network(parseIPv4("192.168.29.40")!!, 24))

    // region Address book

    @Test fun learnsTheInboundAddressPersistsItAndPrefersTheMostRecent() {
        val store = MemoryAddressBookStore()
        val book = KnownAddressBook(store)
        // The Mac dialled in from 192.168.29.148:51234; it listens on 42458.
        assertTrue(book.learn(mac, "192.168.29.148", ReconnectPolicy.LISTENING_PORT, AddressSource.INBOUND, 1_000))
        book.learn(mac, "192.168.29.150", 42_458, AddressSource.DISCOVERY, 2_000)
        assertEquals(listOf("192.168.29.150", "192.168.29.148"), book.addresses(mac).map { it.host })
        book.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, 3_000)
        assertEquals(listOf("192.168.29.148", "192.168.29.150"), book.addresses(mac).map { it.host })

        // A new instance (an app restart) reads the same book.
        val reloaded = KnownAddressBook(store)
        assertEquals(book.addresses(mac), reloaded.addresses(mac))
        assertEquals(AddressSource.INBOUND, reloaded.addresses(mac).first().source)
        assertEquals(42_458, reloaded.addresses(mac).first().port)
    }

    @Test fun discoveryNeverDowngradesAnAuthenticatedAddress() {
        val book = KnownAddressBook(MemoryAddressBookStore())
        book.learn(mac, "192.168.29.148", 42_458, AddressSource.OUTBOUND, 1_000)
        book.learn(mac, "192.168.29.148", 42_458, AddressSource.DISCOVERY, 5_000)
        assertEquals(AddressSource.OUTBOUND, book.addresses(mac).single().source)
        assertEquals(5_000L, book.addresses(mac).single().lastSeenMillis)
    }

    @Test fun spoofedDiscoveryCannotPushOutTheRealAddress() {
        val book = KnownAddressBook(MemoryAddressBookStore(), limit = 3)
        book.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, 1_000)
        (1..6).forEach { book.learn(mac, "192.168.29.${100 + it}", 42_458, AddressSource.DISCOVERY, 1_000L + it) }
        val hosts = book.addresses(mac).map { it.host }
        assertEquals(3, hosts.size)
        assertTrue("192.168.29.148" in hosts)
    }

    @Test fun onlyAddressesAreLearned() {
        val book = KnownAddressBook(MemoryAddressBookStore())
        assertTrue(book.learn(mac, "::ffff:192.168.29.148", 42_458, AddressSource.INBOUND, 1))
        assertEquals("192.168.29.148", book.addresses(mac).single().host)
        assertFalse(book.learn(mac, "fe80::1%wlan0", 42_458, AddressSource.DISCOVERY, 1))
        assertFalse(book.learn(mac, "evil.example.com", 42_458, AddressSource.DISCOVERY, 1))
        assertFalse(book.learn(mac, "192.168.29.148", 0, AddressSource.DISCOVERY, 1))
        assertFalse(book.learn(mac, "300.1.1.1", 42_458, AddressSource.DISCOVERY, 1))
        assertEquals("Rahuls-Mac.local", normalizedHost("Rahuls-Mac.local."))
        book.forget(mac)
        assertTrue(book.addresses(mac).isEmpty())
    }

    @Test fun lastSeenSurvivesARestartButHeartbeatsWriteRarely() {
        val store = MemoryAddressBookStore()
        val book = KnownAddressBook(store)
        book.markSeen(mac, 10_000)
        val written = store.value
        book.markSeen(mac, 20_000, persistAfterMillis = 60_000)
        assertEquals(written, store.value)
        assertEquals(20_000L, book.lastConnected(mac))
        book.markSeen(mac, 80_000, persistAfterMillis = 60_000)
        assertEquals(80_000L, KnownAddressBook(store).lastConnected(mac))
    }

    @Test fun addressTagsNeverHoldTheFullAddress() {
        assertEquals("v4.148", addressTag("192.168.29.148"))
        assertEquals("v6", addressTag("fd00::1"))
        assertEquals("name", addressTag("Rahuls-Mac.local"))
    }

    @Test fun onlyAddressesOnThisNetworkAreDialled() {
        assertTrue(isDialable("192.168.29.148", homeLan))
        assertFalse(isDialable("192.168.1.148", homeLan))
        // Mobile data only: nothing is on a local network, so nothing wakes the radio.
        assertFalse(isDialable("192.168.29.148", emptyList()))
        assertTrue(isDialable("Rahuls-Mac.local", homeLan))
    }

    // endregion

    // region Schedule and debounce

    @Test fun scheduleBacksOffThenStretchesAfterTheFirstHour() {
        val schedule = ReconnectSchedule()
        schedule.disconnected(mac, 0)
        assertEquals(2_000L, schedule.entry(mac)!!.nextAtMillis)
        var now = 2_000L
        val gaps = (0 until 6).map {
            schedule.attemptStarted(mac, now)
            val next = schedule.entry(mac)!!.nextAtMillis
            (next - now).also { now = next }
        }
        assertEquals(listOf(5_000L, 15_000L, 30_000L, 60_000L, 60_000L, 60_000L), gaps)
        schedule.attemptStarted(mac, 3_700_000)
        assertEquals(3_700_000L + 600_000L, schedule.entry(mac)!!.nextAtMillis)
        schedule.connected(mac)
        assertNull(schedule.entry(mac))
    }

    @Test fun networkChangeDozeExitOrScreenOnResetsTheBackoff() {
        val schedule = ReconnectSchedule()
        schedule.disconnected(mac, 0)
        listOf(2_000L, 7_000L, 22_000L, 52_000L, 112_000L).forEach { schedule.attemptStarted(mac, it) }
        schedule.resetAll(5_000_000)
        assertEquals(listOf(mac), schedule.due(5_000_000))
        assertEquals(0, schedule.entry(mac)!!.attempts)
        schedule.attemptStarted(mac, 5_000_000)
        assertEquals(5_005_000L, schedule.entry(mac)!!.nextAtMillis)
    }

    @Test fun burstOfEventsBecomesOneRecovery() {
        val clock = ManualClock()
        val fired = mutableListOf<List<String>>()
        val debouncer = EventDebouncer(clock, quietMillis = 2_000, maxWaitMillis = 10_000) { fired += it }
        debouncer.note("network_available")
        clock.advance(500)
        debouncer.note("link_change")
        clock.advance(1_000)
        debouncer.note("doze_exit")
        debouncer.note("link_change")
        clock.advance(1_900)
        assertTrue(fired.isEmpty())
        clock.advance(200)
        assertEquals(listOf(listOf("network_available", "link_change", "doze_exit")), fired)
        clock.advance(60_000)
        assertEquals(1, fired.size)
    }

    @Test fun endlessEventsStillRecoverAtMaxWait() {
        val clock = ManualClock(now = 0)
        val fired = mutableListOf<Long>()
        val debouncer = EventDebouncer(clock, quietMillis = 2_000, maxWaitMillis = 10_000) { fired += clock.now }
        repeat(15) {
            debouncer.note("link_change")
            clock.advance(1_000)
        }
        assertEquals(10_000L, fired.first())
    }

    // endregion

    // region Engine

    private class Harness(trusted: Set<String>, networks: List<LocalIPv4Network>) {
        val clock = ManualClock()
        val engine = ReconnectEngine(KnownAddressBook(MemoryAddressBookStore()), clock)
        val connected = HashSet<String>()
        val dials = mutableListOf<Pair<String, String>>()
        val events = mutableListOf<ReconnectEvent>()

        init {
            engine.isTrusted = { it in trusted }
            engine.isConnected = { it in connected }
            engine.networks = { networks }
            engine.dial = { id, address -> dials += id to address.host }
            engine.onEvent = { events += it }
        }

        /** The dials failed (refused, timed out, never authenticated). */
        fun failDials() {
            val ids = dials.map { it.first }
            dials.clear()
            ids.forEach(engine::dialEnded)
        }
    }

    /**
     * The overnight bug, phone side: the link reset and NSD lost the Mac. The phone must still
     * redial the Mac where it last was, and keep trying on the schedule rather than once.
     */
    @Test fun redialsTheKnownAddressAfterAResetWithNothingInDiscovery() {
        val harness = Harness(setOf(mac), homeLan)
        harness.connected += mac
        harness.engine.connected(mac, "192.168.29.148", 42_458, AddressSource.OUTBOUND)
        harness.engine.discoveryChanged(emptyList())

        harness.connected -= mac
        harness.engine.disconnected(mac)
        harness.clock.advance(1_900)
        assertTrue(harness.dials.isEmpty())
        harness.clock.advance(200)
        assertEquals(listOf(mac to "192.168.29.148"), harness.dials)

        harness.failDials()
        harness.clock.advance(5_000)
        assertEquals(1, harness.dials.size)
        harness.failDials()
        harness.clock.advance(15_000)
        assertEquals(1, harness.dials.size)

        harness.dials.clear()
        harness.connected += mac
        harness.engine.dialEnded(mac)
        harness.engine.connected(mac, "192.168.29.148", 42_458, AddressSource.OUTBOUND)
        harness.clock.advance(3_600_000)
        assertTrue(harness.dials.isEmpty())
        assertNull(harness.engine.display(mac))
    }

    /**
     * 27 October: a paired Mac was reset and came back under a new id at the same address. Dialling the
     * old id there only reached a Bridgey that closed the connection, every minute. An address NSD now
     * shows for another id is skipped; one shown by a peer that advertises no id is not.
     */
    @Test fun aRememberedAddressNowAdvertisedByAnotherDeviceIsNotDialled() {
        val newMac = "033327d6-0000-4000-8000-000000000002"
        val harness = Harness(setOf(mac), homeLan)
        harness.engine.addressBook.learn(mac, "192.168.29.192", 42_458, AddressSource.OUTBOUND, harness.clock.wall - 600_000)
        harness.engine.discoveryChanged(listOf(LivePeer(newMac, listOf("192.168.29.192"), 42_458)))
        assertTrue(harness.engine.candidates(mac).isEmpty())
        harness.engine.disconnected(mac)
        harness.clock.advance(600_000)
        assertTrue(harness.dials.isEmpty())
        assertEquals(ReconnectEvent.NoAddress(mac, 1, "backoff"), harness.events.first())
    }

    /** Away for twelve hours: a launch tries it once, then every 10 minutes, not every minute for an hour. */
    @Test fun anAwayDeviceIsTriedOnceAtLaunchThenEveryTenMinutes() {
        val harness = Harness(setOf(mac), homeLan)
        val lastSeen = harness.clock.wall - 12 * 3_600_000L
        harness.engine.addressBook.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, lastSeen)
        harness.engine.addressBook.markSeen(mac, lastSeen)
        assertTrue(harness.engine.isAway(mac))
        harness.engine.disconnected(mac, seenNow = false)
        harness.engine.resetAll(listOf(mac))
        var count = 0
        repeat(60) {
            harness.clock.advance(60_000)
            count += harness.dials.size
            harness.failDials()
        }
        assertEquals("at launch, then at 10, 20, ..., 60 minutes", 7, count)
        assertEquals(ReconnectDisplay(lastSeen, struggling = true), harness.engine.display(mac))

        // NSD seeing it: a fresh fast phase.
        harness.engine.discoveryChanged(listOf(LivePeer(mac, listOf("192.168.29.52"), 42_458)))
        harness.clock.advance(0)
        assertEquals(listOf(mac to "192.168.29.52"), harness.dials)
        harness.failDials()
        harness.clock.advance(5_000)
        assertEquals(1, harness.dials.size)
        assertEquals(false, harness.engine.display(mac)?.struggling)
    }

    /** Dropped ten minutes ago: a launch still gives it the fast delays. */
    @Test fun aRecentlyDroppedDeviceKeepsTheFastPhase() {
        val harness = Harness(setOf(mac), homeLan)
        harness.engine.addressBook.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, harness.clock.wall - 600_000)
        harness.engine.addressBook.markSeen(mac, harness.clock.wall - 600_000)
        assertFalse(harness.engine.isAway(mac))
        harness.engine.disconnected(mac, seenNow = false)
        harness.engine.resetAll(listOf(mac))
        var count = 0
        repeat(10) {
            harness.clock.advance(60_000)
            count += harness.dials.size
            harness.failDials()
        }
        assertTrue(count >= 10)
    }

    @Test fun recoveryEventsDialAtOnceAndAttemptsRotateThroughAddresses() {
        val harness = Harness(setOf(mac), homeLan)
        harness.engine.addressBook.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, harness.clock.wall)
        harness.engine.addressBook.learn(mac, "192.168.29.149", 42_458, AddressSource.DISCOVERY, harness.clock.wall - 60_000)
        harness.engine.disconnected(mac)
        harness.clock.advance(2_000)
        harness.failDials()
        harness.clock.advance(5_000)
        assertEquals(listOf(mac to "192.168.29.149"), harness.dials)
        harness.failDials()

        // Doze exit: try now rather than in 15 s.
        harness.engine.resetAll(listOf(mac))
        harness.clock.advance(0)
        assertEquals(listOf(mac to "192.168.29.148"), harness.dials)
    }

    @Test fun nothingIsDialledOnMobileData() {
        val harness = Harness(setOf(mac), emptyList())
        harness.engine.addressBook.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, harness.clock.wall)
        harness.engine.disconnected(mac)
        harness.clock.advance(600_000)
        assertTrue(harness.dials.isEmpty())
        assertEquals(ReconnectEvent.NoAddress(mac, 1, "backoff"), harness.events.first())
    }

    @Test fun nsdFindingTheMacTriesItNowEvenOffTheKnownNetworks() {
        val harness = Harness(setOf(mac), emptyList())
        harness.engine.disconnected(mac)
        repeat(5) {
            harness.clock.advance(60_000)
            harness.failDials()
        }
        harness.engine.discoveryChanged(listOf(LivePeer(mac, listOf("192.168.29.152"), 42_458)))
        harness.clock.advance(0)
        assertEquals(listOf(mac to "192.168.29.152"), harness.dials)
        assertEquals(AddressSource.DISCOVERY, harness.engine.addressBook.addresses(mac).first().source)
    }

    @Test fun retryNowDialsEveryKnownAddressAndUntrustedDevicesAreLeftAlone() {
        val stranger = "ffffffff-0000-4000-8000-000000000009"
        val harness = Harness(setOf(mac), homeLan)
        harness.engine.addressBook.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, harness.clock.wall)
        harness.engine.addressBook.learn(mac, "192.168.29.149", 42_458, AddressSource.OUTBOUND, harness.clock.wall - 5)
        harness.engine.dialEverywhere(mac, "retry_now")
        assertEquals(setOf("192.168.29.148", "192.168.29.149"), harness.dials.map { it.second }.toSet())
        harness.engine.dialEverywhere(stranger, "retry_now")
        assertEquals(2, harness.dials.size)
        harness.engine.disconnected(stranger)
        assertNull(harness.engine.entry(stranger))
    }

    @Test fun displayTurnsToCantReachAfterSeveralMisses() {
        val harness = Harness(setOf(mac), homeLan)
        harness.engine.addressBook.learn(mac, "192.168.29.148", 42_458, AddressSource.INBOUND, harness.clock.wall)
        harness.engine.disconnected(mac)
        assertEquals(ReconnectDisplay(harness.clock.wall, struggling = false), harness.engine.display(mac))
        repeat(4) {
            harness.clock.advance(60_000)
            harness.failDials()
        }
        assertEquals(true, harness.engine.display(mac)?.struggling)
        harness.engine.resetAll(listOf(mac))
        assertEquals(false, harness.engine.display(mac)?.struggling)
    }

    // endregion
}
