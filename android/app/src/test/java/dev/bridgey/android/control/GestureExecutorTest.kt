package dev.bridgey.android.control

import dev.bridgey.android.display.ControlKey
import dev.bridgey.android.display.ControlNavigation
import dev.bridgey.android.display.TouchPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A clock and timers the test moves by hand. */
class FakeTimers(var now: Long = 1_000L) : ControlTimers {
    private class Task(val at: Long, val run: () -> Unit) { var cancelled = false }
    private val tasks = mutableListOf<Task>()

    override fun schedule(delayMillis: Long, task: () -> Unit): () -> Unit {
        val created = Task(now + delayMillis, task)
        tasks += created
        return { created.cancelled = true }
    }

    /** Moves the clock forward, running every task that comes due, in order. */
    fun advance(millis: Long) {
        val end = now + millis
        while (true) {
            val next = tasks.filter { !it.cancelled && it.at <= end }.minByOrNull { it.at } ?: break
            tasks.remove(next)
            now = maxOf(now, next.at)
            next.run()
        }
        now = end
    }

    val pending: Int get() = tasks.count { !it.cancelled }
}

/** Android as the executor sees it: every dispatched part waits until the test completes or cancels it. */
class FakeSink : GestureSink {
    val dispatched = mutableListOf<PlannedGesture>()
    private val callbacks = mutableListOf<(Boolean) -> Unit>()
    val navigated = mutableListOf<ControlNavigation>()
    val typed = mutableListOf<String>()
    val keys = mutableListOf<Triple<ControlKey, Boolean, Boolean>>()
    var refuse = false
    var editor = true

    override fun dispatch(gesture: PlannedGesture, done: (Boolean) -> Unit): Boolean {
        if (refuse) return false
        dispatched += gesture
        callbacks += done
        return true
    }

    override fun navigate(action: ControlNavigation): Boolean = navigated.add(action)

    override fun text(text: String): Typed = if (editor) Typed.TYPED.also { typed += text } else Typed.NO_EDITOR

    override fun key(key: ControlKey, down: Boolean, shift: Boolean): Typed = if (editor) Typed.TYPED.also { keys += Triple(key, down, shift) } else Typed.NO_EDITOR

    val waiting: Int get() = callbacks.size

    /** Android finishes the oldest part in flight. */
    fun complete(ok: Boolean = true) = callbacks.removeAt(0)(ok)

    /** Calls the callback of part [index] (a late one, after the executor has moved on). */
    fun callback(index: Int): (Boolean) -> Unit = callbacks[index]
}

class GestureExecutorTest {
    private val timers = FakeTimers()
    private val sink = FakeSink()
    private val executor = GestureExecutor(sink, timers, { timers.now }, GestureExecutor.Config(touchSlop = 0.0))

    private fun p(x: Double, y: Double) = DisplayPoint(x, y)
    private fun finger(id: Int, phase: TouchPhase, x: Double, y: Double) = ControlItem.Finger(id, phase, p(x, y))
    private val last: PlannedGesture get() = sink.dispatched.last()

    @Test fun aTapIsADownThenALiftInPlace() {
        executor.submit(finger(0, TouchPhase.DOWN, 100.0, 200.0))
        // The down went at once; the up waits for it, then lifts in place.
        assertEquals(1, sink.dispatched.size)
        assertEquals(PlannedStroke(0, listOf(p(100.0, 200.0)), continuing = false, willContinue = true), last.strokes.single())
        executor.submit(finger(0, TouchPhase.UP, 100.0, 200.0))
        assertEquals("one part at a time", 1, sink.dispatched.size)
        sink.complete()
        assertEquals(2, sink.dispatched.size)
        assertEquals(PlannedStroke(0, listOf(p(100.0, 200.0)), continuing = true, willContinue = false), last.strokes.single())
        sink.complete()
        assertTrue(executor.fingersDown.isEmpty())
        assertFalse(executor.busy)
    }

    @Test fun aWholeTapQueuedBehindAPartGoesAsOneStroke() {
        executor.submit(finger(1, TouchPhase.DOWN, 10.0, 10.0))
        executor.submit(finger(0, TouchPhase.DOWN, 100.0, 200.0))
        executor.submit(finger(0, TouchPhase.UP, 100.0, 200.0))
        sink.complete()
        val tap = last.strokes.associateBy { it.finger }.getValue(0)
        assertFalse(tap.continuing)
        assertFalse(tap.willContinue)
        assertEquals(listOf(p(100.0, 200.0)), tap.points)
    }

    @Test fun motionArrivingDuringAPartIsMergedIntoTheNextOneFromWhereItEnded() {
        executor.submit(finger(0, TouchPhase.DOWN, 10.0, 10.0))
        timers.advance(16)
        executor.submit(finger(0, TouchPhase.MOVE, 20.0, 10.0))
        timers.advance(16)
        executor.submit(finger(0, TouchPhase.MOVE, 30.0, 10.0))
        timers.advance(16)
        executor.submit(finger(0, TouchPhase.MOVE, 40.0, 10.0))
        assertEquals(1, sink.dispatched.size)
        sink.complete()
        val part = last.strokes.single()
        assertEquals(listOf(p(10.0, 10.0), p(20.0, 10.0), p(30.0, 10.0), p(40.0, 10.0)), part.points)
        assertTrue(part.continuing)
        assertTrue(part.willContinue)
        assertTrue("a part never lasts longer than 50 ms", last.durationMillis in 8..50)
        sink.complete()
        executor.submit(finger(0, TouchPhase.UP, 40.0, 10.0))
        assertEquals(listOf(p(40.0, 10.0)), last.strokes.single().points)
        assertFalse(last.strokes.single().willContinue)
    }

    @Test fun aLongPauseStillBoundsThePartDuration() {
        executor.submit(finger(0, TouchPhase.DOWN, 10.0, 10.0))
        sink.complete()
        timers.advance(5_000)
        executor.submit(finger(0, TouchPhase.MOVE, 300.0, 10.0))
        assertEquals(50L, last.durationMillis)
    }

    @Test fun everyFingerStillDownIsContinuedInEveryPart() {
        executor.submit(finger(0, TouchPhase.DOWN, 100.0, 100.0))
        executor.submit(finger(1, TouchPhase.DOWN, 200.0, 100.0))
        sink.complete()
        // Contact 1 waited behind contact 0's down: the second part continues 0 and starts 1.
        val second = last.strokes.associateBy { it.finger }
        assertTrue(second.getValue(0).continuing)
        assertEquals(listOf(p(100.0, 100.0)), second.getValue(0).points)
        assertFalse(second.getValue(1).continuing)
        sink.complete()
        executor.submit(finger(1, TouchPhase.MOVE, 260.0, 100.0))
        val pinch = last.strokes.associateBy { it.finger }
        assertEquals("finger 0 is still down and is continued where it is", listOf(p(100.0, 100.0)), pinch.getValue(0).points)
        assertEquals(listOf(p(200.0, 100.0), p(260.0, 100.0)), pinch.getValue(1).points)
        assertEquals(setOf(0, 1), executor.fingersDown)
    }

    @Test fun releaseLiftsHeldFingersWhereTheyAreAndDropsEverythingPending() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        sink.complete()
        executor.submit(finger(0, TouchPhase.MOVE, 70.0, 60.0))
        executor.submit(finger(0, TouchPhase.MOVE, 90.0, 60.0))
        executor.submit(ControlItem.Navigate(ControlNavigation.HOME))
        // The move part is in flight when Stop comes.
        executor.release()
        assertEquals(1, sink.waiting)
        sink.complete()
        // The finger lifts where the part in flight left it; the queued move to 90 was dropped.
        val lift = last.strokes.single()
        assertEquals(listOf(p(70.0, 60.0)), lift.points)
        assertTrue(lift.continuing)
        assertFalse(lift.willContinue)
        sink.complete()
        assertTrue(executor.fingersDown.isEmpty())
        assertTrue("queued navigation was dropped", sink.navigated.isEmpty())
        assertEquals(0, executor.pending)
    }

    @Test fun aLateCompletionAfterReleaseNeverStartsTheNextPart() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        executor.submit(finger(0, TouchPhase.MOVE, 80.0, 60.0))
        executor.submit(finger(0, TouchPhase.UP, 80.0, 60.0))
        executor.release()
        sink.complete()
        // Only the lift went: the queued move and up belonged to the stopped gesture.
        assertEquals(2, sink.dispatched.size)
        assertEquals(listOf(p(50.0, 60.0)), last.strokes.single().points)
        assertFalse(last.strokes.single().willContinue)
    }

    @Test fun aCallbackAfterResetChangesNothing() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        val stale = sink.callback(0)
        executor.reset()
        executor.submit(finger(2, TouchPhase.DOWN, 10.0, 10.0))
        stale(true)
        assertEquals("the new gesture is still in flight", true, executor.busy)
        assertEquals(setOf<Int>(), executor.fingersDown)
        assertFalse(last.strokes.single().continuing)
    }

    @Test fun aCancelledPartMeansEveryFingerIsUp() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        sink.complete()
        executor.submit(finger(0, TouchPhase.MOVE, 60.0, 60.0))
        sink.complete(ok = false)
        assertTrue(executor.fingersDown.isEmpty())
        assertEquals(1, executor.cancelled)
        // A move for a finger Android already lifted sends nothing; the next down starts fresh.
        executor.submit(finger(0, TouchPhase.MOVE, 70.0, 60.0))
        assertEquals(2, sink.dispatched.size)
        executor.submit(finger(0, TouchPhase.DOWN, 70.0, 60.0))
        assertFalse(last.strokes.single().continuing)
    }

    @Test fun aMissingCallbackCountsAsCancelled() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        timers.advance(1_100)
        assertFalse(executor.busy)
        assertTrue(executor.fingersDown.isEmpty())
    }

    @Test fun aGestureThatCannotStartForgetsItsFingers() {
        sink.refuse = true
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        assertFalse(executor.busy)
        assertTrue(executor.fingersDown.isEmpty())
    }

    @Test fun textWaitsUntilFocusHadTimeToMoveAfterATap() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        executor.submit(finger(0, TouchPhase.UP, 50.0, 60.0))
        executor.submit(ControlItem.Text("hello"))
        sink.complete()
        sink.complete()
        assertTrue(sink.typed.isEmpty())
        timers.advance(99)
        assertTrue(sink.typed.isEmpty())
        timers.advance(2)
        assertEquals(listOf("hello"), sink.typed)
    }

    @Test fun typingWithoutAnEditorIsDroppedAndCounted() {
        sink.editor = false
        executor.submit(ControlItem.Text("lost"))
        executor.submit(ControlItem.Key(ControlKey.ENTER, true, false))
        assertEquals(2, executor.droppedText)
    }

    @Test fun inputsRunInPacketOrder() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        executor.submit(finger(0, TouchPhase.UP, 50.0, 60.0))
        executor.submit(ControlItem.Navigate(ControlNavigation.BACK))
        assertTrue("Back waits for the tap", sink.navigated.isEmpty())
        sink.complete()
        sink.complete()
        assertEquals(listOf(ControlNavigation.BACK), sink.navigated)
    }

    @Test fun theQueueIsBounded() {
        executor.submit(finger(0, TouchPhase.DOWN, 50.0, 60.0))
        repeat(64) { assertTrue(executor.submit(ControlItem.Navigate(ControlNavigation.BACK))) }
        assertFalse(executor.submit(ControlItem.Navigate(ControlNavigation.BACK)))
    }

    /** Runs a scroll's start: the finger down alone, then the part that crosses the slop. */
    private fun startScroll(anchor: DisplayPoint, dx: Double, dy: Double) {
        executor.submit(ControlItem.Scroll(anchor, dx, dy, 1080, 2400))
        sink.complete()
        sink.complete()
    }

    @Test fun scrollIsADragOfItsOwnFingerThatCrossesTheSlopFirstAndLiftsStillAfterAPause() {
        executor.submit(ControlItem.Scroll(p(500.0, 1000.0), 0.0, 60.0, 1080, 2400))
        val down = last.strokes.single()
        assertEquals(GestureExecutor.SCROLL_FINGER, down.finger)
        assertEquals("the finger goes down alone", listOf(p(500.0, 1000.0)), down.points)
        assertTrue(down.willContinue)
        sink.complete()
        // A list starts dragging on the move that crosses the slop, and scrolls only on the moves after it.
        val slop = last.strokes.single()
        assertEquals(listOf(p(500.0, 1000.0), p(500.0, 1001.0)), slop.points)
        assertEquals("at least two of Android's 16 ms samples", 32L, last.durationMillis)
        sink.complete()
        val first = last.strokes.single()
        assertEquals("the scroll's whole distance follows", listOf(p(500.0, 1001.0), p(500.0, 1061.0)), first.points)
        assertTrue(first.continuing && first.willContinue)
        sink.complete()
        timers.advance(20)
        executor.submit(ControlItem.Scroll(p(500.0, 1000.0), 0.0, 60.0, 1080, 2400))
        assertEquals(listOf(p(500.0, 1061.0), p(500.0, 1121.0)), last.strokes.single().points)
        sink.complete()
        val parts = sink.dispatched.size
        timers.advance(149)
        assertEquals(parts, sink.dispatched.size)
        timers.advance(2)
        val lift = last.strokes.single()
        assertEquals(listOf(p(500.0, 1121.0)), lift.points)
        assertFalse(lift.willContinue)
        assertEquals("still before lifting, so the list does not fling", 50L, last.durationMillis)
    }

    @Test fun scrollAtAnEdgeLiftsAndStartsAgainFromTheAnchor() {
        startScroll(p(500.0, 2300.0), 0.0, 60.0)
        sink.complete()
        executor.submit(ControlItem.Scroll(p(500.0, 2300.0), 0.0, 60.0, 1080, 2400))
        // 2361 + 60 would leave the display: the finger lifts still first.
        assertFalse(last.strokes.single().willContinue)
        assertEquals(50L, last.durationMillis)
        sink.complete()
        val again = last.strokes.single()
        assertFalse(again.continuing)
        assertEquals(listOf(p(500.0, 2300.0)), again.points)
        sink.complete()
        sink.complete()
        assertEquals(listOf(p(500.0, 2301.0), p(500.0, 2361.0)), last.strokes.single().points)
    }

    @Test fun theSlopPartUsesAndroidsTouchSlop() {
        val slop = GestureExecutor(sink, timers, { timers.now }, GestureExecutor.Config(touchSlop = 24.0))
        slop.submit(ControlItem.Scroll(p(500.0, 1000.0), 0.0, -40.0, 1080, 2400))
        sink.complete()
        assertEquals(listOf(p(500.0, 1000.0), p(500.0, 975.0)), last.strokes.single().points)
        sink.complete()
        assertEquals(listOf(p(500.0, 975.0), p(500.0, 935.0)), last.strokes.single().points)
    }

    @Test fun aTouchWhileScrollingLiftsTheScrollFingerFirst() {
        startScroll(p(500.0, 1000.0), 0.0, 60.0)
        sink.complete()
        executor.submit(finger(0, TouchPhase.DOWN, 100.0, 100.0))
        assertEquals(GestureExecutor.SCROLL_FINGER, last.strokes.single().finger)
        assertFalse(last.strokes.single().willContinue)
        sink.complete()
        assertEquals(0, last.strokes.single().finger)
        sink.complete()
        assertEquals(setOf(0), executor.fingersDown)
    }

    @Test fun pointsPerStrokeAreCapped() {
        executor.submit(finger(0, TouchPhase.DOWN, 0.0, 0.0))
        for (i in 1..60) executor.submit(finger(0, TouchPhase.MOVE, i.toDouble(), 0.0))
        sink.complete()
        assertTrue(last.strokes.single().points.size <= 32)
        // The part ends where the latest motion is, or the rest follows in the next part.
        while (sink.waiting > 0) sink.complete()
        assertEquals(setOf(0), executor.fingersDown)
    }
}
