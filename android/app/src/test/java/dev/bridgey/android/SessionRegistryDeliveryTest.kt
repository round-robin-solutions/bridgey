package dev.bridgey.android

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.junit.Assert.*
import org.junit.Test

/** Exact-session delivery must serialize with the registry's replacement and disconnect mutations. */
class SessionRegistryDeliveryTest {
    @Test fun capturedSessionDeliveryFinishesBeforeReplacementCanBecomeCurrent() {
        val registry = SessionRegistry<Any>("phone")
        val original = Any(); val replacement = Any()
        registry.addPending(original, initiatedLocally = true)
        registry.authenticate(original, "server", "Synthetic server")
        registry.addPending(replacement, initiatedLocally = true)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val mutationStarted = CountDownLatch(1); val mutationFinished = CountDownLatch(1)
        val order = CopyOnWriteArrayList<String>()
        val sender = thread {
            registry.withSession("server") { captured ->
                assertSame(original, captured)
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                order += "send"
            }
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val mutator = thread {
            mutationStarted.countDown()
            registry.authenticate(replacement, "server", "Replacement")
            order += "replace"; mutationFinished.countDown()
        }
        assertTrue(mutationStarted.await(5, TimeUnit.SECONDS))
        try {
            assertFalse("replacement waits for the captured delivery", mutationFinished.await(100, TimeUnit.MILLISECONDS))
        } finally { release.countDown() }
        sender.join(5_000); mutator.join(5_000)
        assertFalse(sender.isAlive); assertFalse(mutator.isAlive)
        assertEquals(listOf("send", "replace"), order.toList())
        assertSame(replacement, registry.session("server"))
        assertFalse(registry.withSession("server") { it === original })
        registry.remove(replacement)
        assertNull(registry.withSession("server") { it })
    }
}
