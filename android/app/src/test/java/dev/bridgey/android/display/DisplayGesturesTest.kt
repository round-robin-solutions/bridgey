package dev.bridgey.android.display

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Touches on the letterboxed picture as absolute positions on the shared display, in portrait and rotated. */
class DisplayGesturesTest {
    // A 1920x1246 stream in a 1080x2340 portrait view: picture 1080x700.875 centred, letterbox above and below.
    private val portrait = letterboxRect(1080.0, 2340.0, 1920, 1246)

    private fun gestures(rect: ContentRect = portrait) = DisplayGestures(slopPx = 16f).apply {
        this.rect = rect
        streamWidth = 1920
        streamHeight = 1246
    }

    private fun close(expected: Double, actual: Double) = assertEquals(expected, actual, 1e-6)

    @Test fun theLetterboxIsExcludedAndRotationOnlyMovesThePicture() {
        assertEquals(0.0, portrait.left, 1e-9)
        close((2340 - 1080 * 1246 / 1920.0) / 2, portrait.top)
        assertNull(letterboxFraction(portrait, 540.0, 100.0))
        val centre = letterboxFraction(portrait, 540.0, 1170.0)!!
        close(0.5, centre.first)
        close(0.5, centre.second)
        val landscape = letterboxRect(2340.0, 1080.0, 1920, 1246)
        assertNull(letterboxFraction(landscape, 10.0, 540.0))
        val rotated = letterboxFraction(landscape, 1170.0, 540.0)!!
        close(0.5, rotated.first)
        close(0.5, rotated.second)
        // A drag that leaves the picture stays on its edge.
        assertEquals(0.0 to 1.0, letterboxFractionClamped(portrait, -50.0, 5000.0))
    }

    @Test fun aTapClicksWhereTheFingerIs() {
        val g = gestures()
        assertTrue(g.onDown(1, 270f, 1170f, 0).isEmpty())
        val actions = g.onUp(1, 80)
        assertEquals(2, actions.size)
        val (down, up) = actions.map { it as DisplayAction.Button }
        assertEquals(ControlButton.PRIMARY, down.button)
        assertTrue(down.down && !up.down)
        close(0.25, down.x)
        close(0.5, down.y)
    }

    @Test fun aGestureThatStartsOnTheLetterboxSendsNothing() {
        val g = gestures()
        assertTrue(g.onDown(1, 540f, 50f, 0).isEmpty())
        assertTrue(g.onMove(mapOf(1L to (540f to 1200f))).isEmpty())
        assertTrue(g.onTimer(1_000).isEmpty())
        assertTrue(g.onUp(1, 1_100).isEmpty())
        // The next gesture on the picture works again.
        g.onDown(2, 540f, 1170f, 2_000)
        assertEquals(2, g.onUp(2, 2_050).size)
    }

    @Test fun oneFingerMovesThePointerToIt() {
        val g = gestures()
        g.onDown(1, 100f, 1170f, 0)
        val moved = g.onMove(mapOf(1L to (540f to 1170f)))
        val pointer = moved.single() as DisplayAction.Pointer
        close(0.5, pointer.x)
        assertTrue(g.onUp(1, 200).isEmpty())
    }

    @Test fun touchAndHoldThenMoveDrags() {
        val g = gestures()
        g.onDown(1, 108f, 1170f, 0)
        val press = g.onTimer(400).single() as DisplayAction.Button
        assertTrue(press.down)
        close(0.1, press.x)
        val move = g.onMove(mapOf(1L to (540f to 1170f))).single() as DisplayAction.Pointer
        close(0.5, move.x)
        val release = g.onUp(1, 900).single() as DisplayAction.Button
        assertTrue(!release.down)
        close(0.5, release.x)
    }

    @Test fun twoFingersTapRightClickAndScrollAtTheirCentre() {
        val g = gestures()
        g.onDown(1, 400f, 1100f, 0)
        g.onDown(2, 680f, 1240f, 20)
        val actions = g.onUp(1, 120) + g.onUp(2, 130)
        val (down, up) = actions.map { it as DisplayAction.Button }
        assertEquals(ControlButton.SECONDARY, down.button)
        assertTrue(down.down && !up.down)
        close(0.5, down.x)
        val s = gestures()
        s.onDown(1, 400f, 1100f, 0)
        s.onDown(2, 680f, 1100f, 10)
        val scroll = s.onMove(mapOf(1L to (400f to 1200f), 2L to (680f to 1200f))).single() as DisplayAction.Scroll
        // 100 view pixels down on a picture 700.875 pixels tall is 178 stream pixels: the content follows the fingers.
        assertEquals((100 / portrait.height * 1246).toInt(), scroll.dy)
        assertEquals(0, scroll.dx)
        close(0.5, scroll.x)
    }

    @Test fun slowScrollingKeepsItsFractions() {
        val s = gestures()
        s.onDown(1, 400f, 1100f, 0)
        s.onDown(2, 680f, 1100f, 10)
        var y = 1100f
        // Past the slop first, then many small steps that are each under one stream pixel.
        s.onMove(mapOf(1L to (400f to 1130f), 2L to (680f to 1130f)))
        y = 1130f
        var total = 0
        repeat(100) {
            y += 0.3f
            total += s.onMove(mapOf(1L to (400f to y), 2L to (680f to y))).sumOf { (it as DisplayAction.Scroll).dy }
        }
        assertTrue("scrolled $total", total >= 50)
    }

    @Test fun resetForgetsTheGestureInProgress() {
        val g = gestures()
        g.onDown(1, 540f, 1170f, 0)
        g.onTimer(400)
        g.reset()
        assertTrue(g.onUp(1, 900).isEmpty())
    }
}
