package dev.bridgey.android.control

import dev.bridgey.android.display.ControlKey
import dev.bridgey.android.display.ControlNavigation
import dev.bridgey.android.display.TouchPhase

/*
 * Turns accepted control input into Android gestures, one at a time (docs/protocol.md "Mac controls the phone"). Android
 * cancels a gesture in progress when another starts, so every part of a gesture is dispatched only after the previous one
 * completed, continues every finger that is still down from exactly where it ended, and merges the motion that arrived
 * meanwhile. Parts are short and the queue is bounded. release() drops everything pending and lifts held fingers where
 * they are; a callback from before it can only finish its own bookkeeping, never start the next part of a stopped
 * gesture. Pure and single threaded: the adapter calls it on one thread and supplies the clock, timers and Android.
 */

/** One finger's path in one dispatched part. Points are display pixels; [continuing] continues that finger's last stroke. */
data class PlannedStroke(val finger: Int, val points: List<DisplayPoint>, val continuing: Boolean, val willContinue: Boolean)

/** One dispatched part: every stroke shares the duration. */
data class PlannedGesture(val strokes: List<PlannedStroke>, val durationMillis: Long)

enum class Typed { TYPED, NO_EDITOR, FAILED }

/** What the executor needs from Android (the accessibility service), or a fake in tests. */
interface GestureSink {
    /** Starts [gesture]; false when it could not start. [done] comes later, once, on the executor's thread: true when completed. */
    fun dispatch(gesture: PlannedGesture, done: (Boolean) -> Unit): Boolean
    fun navigate(action: ControlNavigation): Boolean
    fun text(text: String): Typed
    fun key(key: ControlKey, down: Boolean, shift: Boolean): Typed
}

/** Delayed work on the executor's thread. */
fun interface ControlTimers {
    fun schedule(delayMillis: Long, task: () -> Unit): () -> Unit
}

/** What arrives, in packet order. Display pixels in the current rotation. */
sealed interface ControlItem {
    data class Finger(val finger: Int, val phase: TouchPhase, val point: DisplayPoint) : ControlItem

    /** Content moves by ([dx], [dy]) display pixels from [anchor]; [width] by [height] is the display. */
    data class Scroll(val anchor: DisplayPoint, val dx: Double, val dy: Double, val width: Int, val height: Int) : ControlItem
    data class Navigate(val action: ControlNavigation) : ControlItem
    data class Text(val text: String) : ControlItem
    data class Key(val key: ControlKey, val down: Boolean, val shift: Boolean) : ControlItem
}

class GestureExecutor(
    private val sink: GestureSink,
    private val timers: ControlTimers,
    private val clock: () -> Long,
    private val config: Config = Config(),
    private val log: (String) -> Unit = {},
) {
    data class Config(
        /** A part never lasts longer, so input queued behind it waits at most this long. */
        val maxPartMillis: Long = 50,
        val minMotionMillis: Long = 8,
        /** The scroll finger lifts after this long without scrolling... */
        val scrollIdleMillis: Long = 150,
        /** ...staying still this long first, so the list does not fling. */
        val stillMillis: Long = 50,
        /** Text and keys wait this long after the last finger lifts, so focus reaches the field that was tapped. */
        val settleMillis: Long = 100,
        val maxQueue: Int = 64,
        val maxPointsPerStroke: Int = 32,
        /** A callback that never comes: the part is treated as cancelled after its duration plus this. */
        val callbackTimeoutMillis: Long = 1_000,
        /** Android's touch slop in display pixels: added to the first move of a scroll so the content moves the whole way. */
        val touchSlop: Double = 0.0,
        /** Kept from the display's edges when scrolling. */
        val edgeInset: Double = 2.0,
        /** The part that crosses the touch slop at the start of a scroll: two samples of Android's 16 ms. */
        val slopMillis: Long = 32,
    )

    companion object {
        /** Fingers for the contract's contacts are 0 to 9; the primary button and the scroll finger have their own. */
        const val BUTTON_FINGER = 10
        const val SCROLL_FINGER = 11
        private const val SAMPLES = 256
    }

    private object Lift : ControlItem

    private class Entry(val item: ControlItem, val arrived: Long)

    private class Flight(
        val gesture: PlannedGesture,
        val after: Map<Int, DisplayPoint>,
        val lifted: Boolean,
        val arrived: Long,
        val dispatchedAt: Long,
    ) {
        var cancelTimeout: () -> Unit = {}
    }

    private val queue = ArrayDeque<Entry>()
    private val down = LinkedHashMap<Int, DisplayPoint>()
    private var flight: Flight? = null
    private var settleUntil = Long.MIN_VALUE
    private var lastPartArrival: Long? = null
    private var lastScrollAt = 0L
    private var wake: (() -> Unit)? = null
    /** A scroll drag is down but has not crossed the touch slop yet: where its next part goes. */
    private var scrollSlop: DisplayPoint? = null
    private var wakeAt = Long.MAX_VALUE

    /** Arrival to dispatch, and arrival to completion, in milliseconds (the last 256 parts). */
    val dispatchLatency = ArrayDeque<Long>()
    val completeLatency = ArrayDeque<Long>()

    /** Counters for the log and tests. */
    var gestures = 0; private set
    var cancelled = 0; private set
    var droppedText = 0; private set

    val fingersDown: Set<Int> get() = down.keys.toSet()
    val busy: Boolean get() = flight != null
    val pending: Int get() = queue.size

    /** Queues one accepted input; false when the queue is full (the caller ends control rather than drop a transition). */
    fun submit(item: ControlItem): Boolean {
        if (queue.size >= config.maxQueue) return false
        queue.addLast(Entry(item, clock()))
        pump()
        return true
    }

    /** Stop, geometry change, lock, permission or grant loss: pending input goes and held fingers lift where they are. */
    fun release() {
        queue.clear()
        cancelWake()
        if (down.isNotEmpty() || flight != null) queue.addLast(Entry(Lift, clock()))
        pump()
    }

    /** The service went away: Android has already cancelled its gestures, so everything is forgotten. */
    fun reset() {
        queue.clear()
        cancelWake()
        scrollSlop = null
        flight?.cancelTimeout?.invoke()
        flight = null
        down.clear()
        lastPartArrival = null
    }

    private fun pump() {
        if (flight != null) return
        while (queue.isNotEmpty()) {
            val head = queue.first()
            when (val item = head.item) {
                is ControlItem.Navigate -> {
                    queue.removeFirst()
                    if (!sink.navigate(item.action)) log("CONTROL navigate ${item.action.wire} refused")
                    sample(dispatchLatency, clock() - head.arrived)
                }
                is ControlItem.Text, is ControlItem.Key -> {
                    val now = clock()
                    if (now < settleUntil) {
                        scheduleWake(settleUntil - now)
                        return
                    }
                    queue.removeFirst()
                    val typed = if (item is ControlItem.Text) sink.text(item.text) else (item as ControlItem.Key).let { sink.key(it.key, it.down, it.shift) }
                    if (typed != Typed.TYPED) {
                        droppedText++
                        log("CONTROL typing ${if (typed == Typed.NO_EDITOR) "no_editor" else "failed"}")
                    }
                    sample(dispatchLatency, clock() - head.arrived)
                }
                Lift -> {
                    queue.removeFirst()
                    if (down.isEmpty()) continue
                    val still = SCROLL_FINGER in down
                    val strokes = down.map { (finger, point) -> PlannedStroke(finger, listOf(point), continuing = true, willContinue = false) }
                    start(PlannedGesture(strokes, if (still) config.stillMillis else 1), emptyMap(), lifted = true, arrived = head.arrived)
                    return
                }
                is ControlItem.Finger, is ControlItem.Scroll -> {
                    if (build()) return
                }
            }
        }
        scheduleScrollLift()
    }

    /** Builds and dispatches the next part from the head of the queue. False when the head was consumed with nothing to send. */
    private fun build(): Boolean {
        val paths = LinkedHashMap<Int, MutableList<DisplayPoint>>()
        down.forEach { (finger, point) -> paths[finger] = mutableListOf(point) }
        val starting = mutableSetOf<Int>()
        val ending = mutableSetOf<Int>()
        var consumed = 0
        var firstArrival = Long.MAX_VALUE
        var lastArrival = Long.MIN_VALUE
        fun take(entry: Entry) {
            queue.removeFirst()
            consumed++
            firstArrival = minOf(firstArrival, entry.arrived)
            lastArrival = maxOf(lastArrival, entry.arrived)
        }
        loop@ while (queue.isNotEmpty()) {
            val entry = queue.first()
            when (val item = entry.item) {
                is ControlItem.Finger -> when (item.phase) {
                    TouchPhase.DOWN -> {
                        if (item.finger in paths) break@loop
                        if (SCROLL_FINGER in down && SCROLL_FINGER !in ending) {
                            // A touch while the scroll finger is down: it lifts first, still, so nothing flings.
                            if (consumed > 0) break@loop
                            stillLift(entry.arrived)
                            return true
                        }
                        take(entry)
                        starting += item.finger
                        paths[item.finger] = mutableListOf(item.point)
                    }
                    TouchPhase.MOVE -> {
                        take(entry)
                        val path = paths[item.finger]
                        if (path != null && item.finger !in ending) path += item.point
                    }
                    TouchPhase.UP -> {
                        take(entry)
                        val path = paths[item.finger]
                        if (path != null && item.finger !in ending) {
                            if (path.last() != item.point) path += item.point
                            ending += item.finger
                        }
                    }
                }
                is ControlItem.Scroll -> {
                    if (SCROLL_FINGER in ending) break@loop
                    val others = paths.keys.any { it != SCROLL_FINGER && it !in ending }
                    if (others) {
                        // Scrolling while a finger is down would turn it into a second finger: dropped.
                        take(entry)
                        continue@loop
                    }
                    val path = paths[SCROLL_FINGER]
                    val minX = config.edgeInset
                    val minY = config.edgeInset
                    val maxX = item.width - 1 - config.edgeInset
                    val maxY = item.height - 1 - config.edgeInset
                    fun inside(p: DisplayPoint) = p.x in minX..maxX && p.y in minY..maxY
                    fun clamp(p: DisplayPoint) = DisplayPoint(p.x.coerceIn(minX, maxOf(minX, maxX)), p.y.coerceIn(minY, maxOf(minY, maxY)))
                    if (path == null) {
                        // A new drag: the finger goes down alone first. A list starts dragging on the move that
                        // crosses the touch slop and scrolls only on the moves after it, so the slop gets a part of
                        // its own next and the scroll's whole distance follows; the scroll stays queued meanwhile.
                        if (consumed > 0) break@loop
                        val anchor = clamp(item.anchor)
                        lastScrollAt = entry.arrived
                        val extra = slop(item.dx, item.dy)
                        scrollSlop = clamp(DisplayPoint(anchor.x + extra.x, anchor.y + extra.y))
                        start(PlannedGesture(listOf(PlannedStroke(SCROLL_FINGER, listOf(anchor), continuing = false, willContinue = true)), 1),
                            LinkedHashMap(down).apply { put(SCROLL_FINGER, anchor) }, lifted = false, arrived = entry.arrived)
                        return true
                    } else if (scrollSlop != null) {
                        if (consumed > 0) break@loop
                        val crossing = scrollSlop!!
                        scrollSlop = null
                        val strokes = down.map { (finger, point) ->
                            PlannedStroke(finger, if (finger == SCROLL_FINGER) listOf(point, crossing) else listOf(point), continuing = true, willContinue = true)
                        }
                        start(PlannedGesture(strokes, config.slopMillis), LinkedHashMap(down).apply { put(SCROLL_FINGER, crossing) }, lifted = false, arrived = entry.arrived)
                        return true
                    } else {
                        val last = path.last()
                        val target = DisplayPoint(last.x + item.dx, last.y + item.dy)
                        if (!inside(target)) {
                            if (consumed > 0) break@loop
                            // At an edge: lift still and start again from the anchor with this scroll.
                            stillLift(entry.arrived)
                            return true
                        }
                        take(entry)
                        path += target
                    }
                    lastScrollAt = entry.arrived
                }
                else -> break@loop
            }
            if (paths.values.any { it.size >= config.maxPointsPerStroke }) break@loop
        }
        if (consumed == 0 || paths.isEmpty()) return false
        if (starting.isEmpty() && ending.isEmpty() && paths.values.all { it.size == 1 }) return false
        val moved = paths.values.any { path -> path.size > 1 }
        val previous = lastPartArrival
        val duration = when {
            !moved -> 1L
            previous == null -> config.minMotionMillis
            else -> (lastArrival - previous).coerceIn(config.minMotionMillis, config.maxPartMillis)
        }
        val strokes = paths.map { (finger, points) ->
            PlannedStroke(finger, cap(points), continuing = finger in down, willContinue = finger !in ending)
        }
        val after = LinkedHashMap<Int, DisplayPoint>()
        paths.forEach { (finger, points) -> if (finger !in ending) after[finger] = points.last() }
        lastPartArrival = lastArrival
        start(PlannedGesture(strokes, duration), after, lifted = ending.isNotEmpty(), arrived = firstArrival)
        return true
    }

    /** The scroll finger stays still, then lifts where it is. */
    private fun stillLift(arrived: Long) {
        val strokes = down.map { (finger, point) ->
            PlannedStroke(finger, listOf(point), continuing = true, willContinue = finger != SCROLL_FINGER)
        }
        val after = LinkedHashMap(down).apply { remove(SCROLL_FINGER) }
        start(PlannedGesture(strokes, config.stillMillis), after, lifted = true, arrived = arrived)
    }

    /** Just past the touch slop in the scroll's direction (one pixel more, so the crossing is certain). */
    private fun slop(dx: Double, dy: Double): DisplayPoint {
        if (dx == 0.0 && dy == 0.0) return DisplayPoint(0.0, 0.0)
        val length = Math.hypot(dx, dy)
        val distance = config.touchSlop + 1
        return DisplayPoint(dx / length * distance, dy / length * distance)
    }

    private fun cap(points: List<DisplayPoint>): List<DisplayPoint> {
        if (points.size <= config.maxPointsPerStroke) return points
        return listOf(points.first()) + points.takeLast(config.maxPointsPerStroke - 1)
    }

    private fun start(gesture: PlannedGesture, after: Map<Int, DisplayPoint>, lifted: Boolean, arrived: Long) {
        cancelWake()
        val now = clock()
        val current = Flight(gesture, after, lifted, arrived, now)
        flight = current
        gestures++
        val started = sink.dispatch(gesture) { completed -> finished(current, completed) }
        if (!started) {
            log("CONTROL gesture did not start")
            if (flight === current) {
                flight = null
                down.clear()
                pump()
            }
            return
        }
        sample(dispatchLatency, now - arrived)
        current.cancelTimeout = timers.schedule(gesture.durationMillis + config.callbackTimeoutMillis) {
            if (flight === current) {
                log("CONTROL gesture callback missing")
                finished(current, false)
            }
        }
    }

    private fun finished(current: Flight, completed: Boolean) {
        // Only the part in flight counts: a callback after reset() or a timeout changes nothing.
        if (flight !== current) return
        flight = null
        current.cancelTimeout()
        down.clear()
        if (completed) {
            down.putAll(current.after)
            sample(completeLatency, clock() - current.arrived)
        } else {
            scrollSlop = null
            // Android cancelled it (a real touch, another gesture): every injected finger is up.
            cancelled++
            lastPartArrival = null
        }
        if (SCROLL_FINGER !in down) scrollSlop = null
        if (down.isEmpty()) lastPartArrival = null
        if (current.lifted && down.isEmpty()) settleUntil = clock() + config.settleMillis
        pump()
    }

    private fun scheduleScrollLift() {
        if (SCROLL_FINGER !in down || flight != null || queue.isNotEmpty()) return
        val due = lastScrollAt + config.scrollIdleMillis - clock()
        if (due > 0) {
            scheduleWake(due)
            return
        }
        stillLift(clock())
    }

    private fun scheduleWake(delay: Long) {
        val at = clock() + delay
        if (wake != null && wakeAt <= at) return
        cancelWake()
        wakeAt = at
        wake = timers.schedule(delay) {
            wake = null
            wakeAt = Long.MAX_VALUE
            pump()
        }
    }

    private fun cancelWake() {
        wake?.invoke()
        wake = null
        wakeAt = Long.MAX_VALUE
    }

    private fun sample(into: ArrayDeque<Long>, value: Long) {
        into.addLast(value)
        while (into.size > SAMPLES) into.removeFirst()
    }
}
