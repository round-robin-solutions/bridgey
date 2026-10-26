package dev.bridgey.android

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Real time on a background thread, as on the phone (without android.os.SystemClock). */
private class ThreadClock : ReconnectClock {
    val executor = Executors.newSingleThreadScheduledExecutor()
    override fun elapsedMillis(): Long = System.nanoTime() / 1_000_000
    override fun wallMillis(): Long = System.currentTimeMillis()
    override fun schedule(delayMillis: Long, action: () -> Unit): ScheduledTask {
        val future = executor.schedule(action, delayMillis.coerceAtLeast(0), TimeUnit.MILLISECONDS)
        return ScheduledTask { future.cancel(false) }
    }
}

class ReconnectIntegrationTest {
    private val mac = "f00dfeed-0000-4000-8000-000000000001"

    /**
     * Over real TCP: the link is reset by the peer (RST, as at 02:56), NSD shows nothing, and
     * the phone must still redial the address the Mac last connected from, and reconnect.
     */
    @Test(timeout = 30_000)
    fun redialsTheKnownAddressAfterAResetWhileNsdShowsNothing() {
        val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        val accepted = LinkedBlockingQueue<Socket>()
        thread(isDaemon = true) {
            while (!server.isClosed) accepted += runCatching { server.accept() }.getOrNull() ?: break
        }
        val clock = ThreadClock()
        val engine = ReconnectEngine(KnownAddressBook(MemoryAddressBookStore()), clock) { _, _ -> 50L }
        val connected = ConcurrentHashMap.newKeySet<String>()
        val dropReasons = CopyOnWriteArrayList<String>()
        val readyCount = AtomicInteger()
        val reconnected = CountDownLatch(1)
        val clients = CopyOnWriteArrayList<Socket>()
        val trusted = java.util.concurrent.atomic.AtomicBoolean(true)
        engine.isTrusted = { trusted.get() && it == mac }
        engine.isConnected = { it in connected }
        engine.networks = { listOf(LocalIPv4Network(parseIPv4("127.0.0.1")!!, 8)) }
        engine.dial = { id, address ->
            thread(isDaemon = true) {
                val socket = runCatching { Socket().apply { connect(InetSocketAddress(address.host, address.port), 2_000) } }.getOrNull()
                if (socket == null) {
                    engine.dialEnded(id)
                    return@thread
                }
                clients += socket
                connected += id
                engine.dialEnded(id)
                engine.connected(id, address.host, address.port, AddressSource.OUTBOUND)
                if (readyCount.incrementAndGet() == 2) reconnected.countDown()
                val reason = runCatching {
                    val input = socket.getInputStream()
                    while (input.read() >= 0) Unit
                    "closed_by_peer"
                }.getOrElse(::socketDropReason)
                dropReasons += reason
                connected -= id
                engine.disconnected(id)
            }
        }

        try {
            // The Mac dialled this phone earlier: that is the only place the phone knows it from.
            engine.addressBook.learn(mac, "127.0.0.1", server.localPort, AddressSource.INBOUND, clock.wallMillis())
            engine.discoveryChanged(emptyList())
            engine.disconnected(mac)

            val first = accepted.poll(5, TimeUnit.SECONDS)
            assertNotNull("the phone should dial the known address", first)
            Thread.sleep(200)
            // Reset it, like the link at 02:56.
            first!!.setSoLinger(true, 0)
            first.close()

            val second = accepted.poll(10, TimeUnit.SECONDS)
            assertNotNull("the phone should redial after the reset", second)
            assertTrue(reconnected.await(5, TimeUnit.SECONDS))
            assertEquals("reset_by_peer", dropReasons.first())
            assertTrue(mac in connected)
            assertNull(engine.entry(mac))
            second!!.close()
        } finally {
            trusted.set(false)
            clients.forEach { runCatching { it.close() } }
            server.close()
            clock.executor.shutdownNow()
        }
    }
}
