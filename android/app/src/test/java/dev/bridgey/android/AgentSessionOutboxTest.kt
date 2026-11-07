package dev.bridgey.android

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Synthetic buffers and writers only: no sockets, devices, private content, or accounts. */
class AgentSessionOutboxTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @After fun stop() { scope.cancel() }
    private fun await(latch: CountDownLatch) = assertTrue(latch.await(5, TimeUnit.SECONDS))
    private fun joinWorkers() = runBlocking { scope.coroutineContext[Job]!!.children.toList().forEach { it.join() } }

    @Test fun boundedCountIncludesStalledInFlightReplyAndKeepsFifo() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val drained = CountDownLatch(2)
        val written = CopyOnWriteArrayList<String>()
        val queue = AgentSessionOutbox(scope, maxCount = 2, maxBytes = 8, maxReplyBytes = 4, write = {
            if (it.kind == "first") { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
            written += it.kind
            drained.countDown()
            true
        })
        assertEquals(0, scope.coroutineContext[Job]!!.children.count { it.isActive })
        assertTrue(queue.enqueue("first", ByteArray(4)))
        await(entered)
        assertTrue(queue.enqueue("second", ByteArray(4)))
        assertEquals(2, queue.pendingCount()); assertEquals(8, queue.pendingBytes())
        assertFalse(queue.enqueue("overflow", ByteArray(1)))
        assertEquals(1, scope.coroutineContext[Job]!!.children.count { it.isActive })
        release.countDown(); await(drained)
        queue.close(); joinWorkers()
        assertEquals(listOf("first", "second"), written.toList())
        assertEquals(0, queue.pendingCount()); assertEquals(0, queue.pendingBytes())
    }

    @Test fun byteLimitAndPerReplyLimitAreIndependentOfCount() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val queue = AgentSessionOutbox(scope, maxCount = 4, maxBytes = 8, maxReplyBytes = 6, write = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); true
        })
        try {
            assertFalse(queue.enqueue("oversized", ByteArray(7)))
            assertTrue(queue.enqueue("first", ByteArray(6)))
            await(entered)
            assertFalse(queue.enqueue("byte-overflow", ByteArray(3)))
            assertTrue(queue.enqueue("fits", ByteArray(2)))
            assertEquals(8, queue.pendingBytes())
        } finally {
            queue.close(); release.countDown(); joinWorkers()
        }
    }

    @Test fun closeDropsQueuedContentAndNeverRetriesIt() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val written = CopyOnWriteArrayList<String>()
        val queue = AgentSessionOutbox(scope, write = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); written += it.kind; true
        })
        assertTrue(queue.enqueue("in-flight", ByteArray(4))); await(entered)
        assertTrue(queue.enqueue("discard-me", ByteArray(6)))
        queue.close()
        assertEquals(1, queue.pendingCount()); assertEquals(4, queue.pendingBytes())
        assertFalse(queue.enqueue("after-close", ByteArray(1)))
        release.countDown(); joinWorkers()
        assertEquals(listOf("in-flight"), written.toList())
        assertEquals(0, queue.pendingCount()); assertEquals(0, queue.pendingBytes())
    }

    @Test fun writerFailureClosesQueueWithoutRetry() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val failed = CountDownLatch(1)
        val written = CopyOnWriteArrayList<String>()
        val queue = AgentSessionOutbox(scope, write = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); written += it.kind; false
        }, onFailure = { failed.countDown() })
        assertTrue(queue.enqueue("failed", ByteArray(1))); await(entered)
        assertTrue(queue.enqueue("never-retry", ByteArray(1)))
        release.countDown(); await(failed); joinWorkers()
        assertFalse(queue.enqueue("closed", ByteArray(1)))
        assertEquals(listOf("failed"), written.toList())
        assertEquals(0, queue.pendingBytes())
    }

    @Test fun stalledWriterCannotHoldRegistryAndCapturedQueueCannotMigrate() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val mutated = CountDownLatch(1)
        val queue = AgentSessionOutbox(scope, write = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS)); true
        })
        val registry = SessionRegistry<AgentSessionOutbox>("phone")
        registry.addPending(queue, initiatedLocally = true)
        registry.authenticate(queue, "server", "Synthetic server")
        assertTrue(registry.withSession("server") { it?.enqueue("reply", ByteArray(1)) == true })
        await(entered)
        val replacement = AgentSessionOutbox(scope, write = { error("old reply migrated to a replacement") })
        val mutation = thread {
            registry.addPending(replacement, initiatedLocally = true)
            registry.authenticate(replacement, "server", "Replacement")
            queue.close()
            mutated.countDown()
        }
        try {
            await(mutated)
            assertSame(replacement, registry.session("server"))
            assertFalse(queue.enqueue("stale", ByteArray(1)))
            assertEquals(0, replacement.pendingCount())
        } finally {
            release.countDown(); mutation.join(5_000)
            queue.close(); replacement.close(); joinWorkers()
        }
    }

    @Test fun canceledOwnerScopeRejectsNewWorkWithoutRetainingPayload() {
        val queue = AgentSessionOutbox(scope, write = { error("canceled scope must not write") })
        scope.cancel()
        assertFalse(queue.enqueue("after-scope-end", ByteArray(16)))
        assertEquals(0, queue.pendingCount()); assertEquals(0, queue.pendingBytes())
        queue.close()
    }

    @Test fun queueOwnsPayloadCopyInsteadOfCallersMutableBuffer() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val written = CountDownLatch(1)
        var observed = 0
        val queue = AgentSessionOutbox(scope, write = {
            entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
            observed = it.payload[0].toInt(); written.countDown(); true
        })
        val source = byteArrayOf(7)
        assertTrue(queue.enqueue("copy", source)); await(entered)
        source[0] = 9
        release.countDown(); await(written)
        queue.close(); joinWorkers()
        assertEquals(7, observed)
    }
}
