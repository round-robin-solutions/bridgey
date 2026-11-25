package dev.bridgey.android.display

import dev.bridgey.android.remote.PointerButton
import dev.bridgey.android.remote.TouchpadGesture
import dev.bridgey.android.remote.TouchpadGestureRecognizer

/**
 * Touches on the picture as absolute positions on the shared display, with the touchpad's own recogniser: one finger
 * moves the pointer to it, a tap clicks there, a two-finger tap right-clicks, two fingers scroll at their centre,
 * touch and hold then move drags. A gesture that starts on the letterbox sends nothing; a drag or scroll that started
 * on the picture stays on its edge. Coordinates are view pixels. Pure, so every rule is tested.
 */
class DisplayGestures(slopPx: Float, holdMillis: Long = 400) {
    private val recognizer = TouchpadGestureRecognizer(slopPx, holdMillis)
    private val positions = LinkedHashMap<Long, Pair<Float, Float>>()
    private var primaryId = -1L
    private var ignored = false
    private var dragging = false
    private var lastDrag: Pair<Double, Double>? = null
    private var scrollX = 0.0
    private var scrollY = 0.0

    /** Where the picture is in the view, and the stream's size (for scroll distances). */
    var rect: ContentRect = ContentRect(0.0, 0.0, 0.0, 0.0)
    var streamWidth: Int = 0
    var streamHeight: Int = 0

    val holdDeadline: Long? get() = if (ignored) null else recognizer.holdDeadline

    fun onDown(id: Long, x: Float, y: Float, timeMillis: Long): List<DisplayAction> {
        if (positions.isEmpty()) {
            primaryId = id
            // A gesture that starts on the letterbox is not a touch on the Mac's screen.
            ignored = letterboxFraction(rect, x.toDouble(), y.toDouble()) == null
        }
        positions[id] = x to y
        if (ignored) return emptyList()
        return map(recognizer.onDown(id, x, y, timeMillis))
    }

    fun onMove(moves: Map<Long, Pair<Float, Float>>): List<DisplayAction> {
        moves.forEach { (id, point) -> if (id in positions) positions[id] = point }
        if (ignored) return emptyList()
        return map(recognizer.onMove(moves))
    }

    fun onUp(id: Long, timeMillis: Long): List<DisplayAction> {
        val result = if (ignored) emptyList() else map(recognizer.onUp(id, timeMillis))
        positions.remove(id)
        if (positions.isEmpty()) {
            ignored = false
            primaryId = -1
        }
        return result
    }

    fun onTimer(timeMillis: Long): List<DisplayAction> = if (ignored) emptyList() else map(recognizer.onTimer(timeMillis))

    /** The system took the touches: a drag ends where it was. */
    fun onCancel(): List<DisplayAction> {
        val result = if (ignored) emptyList() else map(recognizer.onCancel())
        reset()
        return result
    }

    /**
     * The geometry changed, control ended or the stream stopped: the host already released everything, so the
     * gesture in progress ends here without sending anything more.
     */
    fun reset() {
        recognizer.onCancel()
        positions.clear()
        primaryId = -1
        ignored = false
        dragging = false
        lastDrag = null
        scrollX = 0.0
        scrollY = 0.0
    }

    private fun map(gestures: List<TouchpadGesture>): List<DisplayAction> = gestures.flatMap { gesture ->
        when (gesture) {
            is TouchpadGesture.Move -> listOfNotNull(primary()?.let { (x, y) -> DisplayAction.Pointer(x, y) })
            is TouchpadGesture.Click -> {
                val button = if (gesture.button == PointerButton.RIGHT) ControlButton.SECONDARY else ControlButton.PRIMARY
                val at = (if (button == ControlButton.SECONDARY) centre() else primary(clamp = true)) ?: return@flatMap emptyList()
                listOf(DisplayAction.Button(button, true, at.first, at.second), DisplayAction.Button(button, false, at.first, at.second))
            }
            TouchpadGesture.DragStart -> {
                val at = primary(clamp = true) ?: return@flatMap emptyList()
                dragging = true
                lastDrag = at
                listOf(DisplayAction.Button(ControlButton.PRIMARY, true, at.first, at.second))
            }
            is TouchpadGesture.DragMove -> {
                val at = primary(clamp = true) ?: return@flatMap emptyList()
                lastDrag = at
                listOf(DisplayAction.Pointer(at.first, at.second))
            }
            TouchpadGesture.DragEnd -> {
                if (!dragging) return@flatMap emptyList()
                dragging = false
                val at = primary(clamp = true) ?: lastDrag ?: return@flatMap emptyList()
                lastDrag = null
                listOf(DisplayAction.Button(ControlButton.PRIMARY, false, at.first, at.second))
            }
            is TouchpadGesture.Scroll -> {
                val at = centre() ?: return@flatMap emptyList()
                // Fractions of a stream pixel are kept for the next move, so slow scrolling still scrolls.
                scrollX += scrollPixels(gesture.dx, rect.width, streamWidth)
                scrollY += scrollPixels(gesture.dy, rect.height, streamHeight)
                val dx = scrollX.toInt()
                val dy = scrollY.toInt()
                scrollX -= dx
                scrollY -= dy
                if (dx == 0 && dy == 0) emptyList() else listOf(DisplayAction.Scroll(dx, dy, at.first, at.second))
            }
        }
    }

    /** The finger that started the gesture, as fractions; null on the letterbox unless clamped. */
    private fun primary(clamp: Boolean = false): Pair<Double, Double>? {
        val (x, y) = positions[primaryId] ?: positions.values.firstOrNull() ?: return null
        return if (clamp) letterboxFractionClamped(rect, x.toDouble(), y.toDouble()) else letterboxFraction(rect, x.toDouble(), y.toDouble())
    }

    /** The centre of the first two fingers, kept on the picture. */
    private fun centre(): Pair<Double, Double>? {
        val points = positions.values.take(2).ifEmpty { return null }
        return letterboxFractionClamped(rect, points.map { it.first.toDouble() }.average(), points.map { it.second.toDouble() }.average())
    }

    companion object {
        /** A finger distance on the picture as stream pixels: the content moves with the fingers. */
        fun scrollPixels(viewDelta: Float, viewSide: Double, streamSide: Int): Double {
            if (viewSide <= 0 || streamSide <= 0) return 0.0
            return viewDelta / viewSide * streamSide
        }
    }
}
