package dev.bridgey.android.folders

import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** A pending timer. */
fun interface Cancellable {
    fun cancel()
}

/** Timers for the folder session; tests advance a fake clock instead. */
fun interface FolderScheduler {
    fun schedule(delayMillis: Long, task: () -> Unit): Cancellable
}

class ExecutorFolderScheduler(private val executor: ScheduledExecutorService) : FolderScheduler {
    override fun schedule(delayMillis: Long, task: () -> Unit): Cancellable {
        val future = executor.schedule({ runCatching(task) }, delayMillis, TimeUnit.MILLISECONDS)
        return Cancellable { future.cancel(false) }
    }
}

/**
 * The folder session's storage thread (6.3). Every event of one folder transfer runs here, one after another,
 * so the session needs no locks and the order of the socket is kept: a file is created before its chunks are
 * written, and files.offer, chunks and files.complete are handled in the order they arrived.
 *
 * [post] is for socket messages: it blocks while [capacity] of them wait (64 chunks, about 1.5 MiB), which
 * stops the socket reader and pushes back on TCP while storage catches up. [postControl] is for timers, the
 * user's answers, cancels and disconnects: it never blocks and runs before waiting socket messages.
 */
interface FolderWorker {
    fun post(task: () -> Unit)
    fun postControl(task: () -> Unit)

    /** No more tasks run after the current one; later posts are dropped without blocking. */
    fun shutdown()
}

class ThreadFolderWorker(name: String, private val capacity: Int = 64) : FolderWorker {
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()
    private val data = ArrayDeque<() -> Unit>()
    private val control = ArrayDeque<() -> Unit>()
    @Volatile private var stopped = false
    private val thread = Thread({ loop() }, name).apply {
        isDaemon = true
        start()
    }

    override fun post(task: () -> Unit) {
        if (Thread.currentThread() === thread) {
            // A task posting more work for itself: never wait on our own queue.
            lock.withLock { if (!stopped) data.addLast(task) }
            return
        }
        lock.withLock {
            while (!stopped && data.size >= capacity) changed.await()
            if (stopped) return
            data.addLast(task)
            changed.signalAll()
        }
    }

    override fun postControl(task: () -> Unit) {
        lock.withLock {
            if (stopped) return
            control.addLast(task)
            changed.signalAll()
        }
    }

    override fun shutdown() {
        lock.withLock {
            stopped = true
            data.clear()
            control.clear()
            changed.signalAll()
        }
    }

    private fun loop() {
        while (true) {
            val task = lock.withLock {
                while (!stopped && data.isEmpty() && control.isEmpty()) changed.await()
                if (stopped) return
                (control.removeFirstOrNull() ?: data.removeFirst()).also { changed.signalAll() }
            }
            runCatching(task).exceptionOrNull()?.let {
                android.util.Log.w("Bridgey", "FOLDER worker task failed: ${it.javaClass.simpleName}")
            }
        }
    }
}

/** Runs tasks on the calling thread, in order; a task posted by a running task waits for it. For tests. */
class InlineFolderWorker : FolderWorker {
    private val queue = ArrayDeque<() -> Unit>()
    private var running = false
    private var stopped = false

    @Synchronized override fun post(task: () -> Unit) = enqueue(task)

    @Synchronized override fun postControl(task: () -> Unit) = enqueue(task)

    @Synchronized override fun shutdown() {
        stopped = true
        queue.clear()
    }

    private fun enqueue(task: () -> Unit) {
        if (stopped) return
        queue.addLast(task)
        if (running) return
        running = true
        try {
            while (!stopped) task0()?.invoke() ?: break
        } finally {
            running = false
        }
    }

    private fun task0(): (() -> Unit)? = queue.removeFirstOrNull()
}
