package dev.bridgey.android.display

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The controller side of input fencing: numbering, coalescing, budgets, geometry acknowledgement and Stop. */
class DisplayControllerTest {
    private var now = 10_000L
    private val controller = DisplayController({ now })
    private val connection = ByteArray(16) { 9 }
    private val binding = DisplayController.Binding(transport = 2, connection = connection, stream = 3)
    private val all = InputCapabilities(pointer = true, keys = true, text = true)

    private fun begin(input: InputCapabilities = all, generation: Long = 1): List<ControlPacket> = controller.begin(5, input, binding, generation)

    @Test fun nothingGoesWithoutASessionAndTheFirstPacketAcknowledgesTheGeometry() {
        assertFalse(controller.submit(DisplayAction.Pointer(0.5, 0.5)))
        assertTrue(controller.flush().isEmpty())
        assertNull(controller.stop())
        val first = begin(generation = 4)
        assertEquals(1, first.size)
        val ack = first.single()
        assertEquals(ControlInput.GeometryAck, ack.input)
        assertEquals(1L, ack.seq)
        assertEquals(4L, ack.geometry)
        assertEquals(5L, ack.session)
        assertEquals(2L, ack.transport)
        assertEquals(3L, ack.stream)
        assertTrue(ack.connection.contentEquals(connection))
        // What goes on the wire is the contract's packet.
        assertEquals(ack, ControlPacket.decode(ack.encode()))
    }

    @Test fun anInvalidBindingStartsNothing() {
        assertTrue(controller.begin(5, all, DisplayController.Binding(2, ByteArray(16), 3), 1).isEmpty())
        assertFalse(controller.active)
        assertTrue(controller.begin(0, all, binding, 1).isEmpty())
        assertTrue(controller.begin(5, all, binding, 0).isEmpty())
    }

    @Test fun pointerMotionIsCoalescedBeforeNumbering() {
        begin()
        controller.submit(DisplayAction.Pointer(0.1, 0.1))
        controller.submit(DisplayAction.Pointer(0.2, 0.2))
        controller.submit(DisplayAction.Pointer(0.3, 0.4))
        val packets = controller.flush()
        assertEquals(listOf(ControlInput.Pointer(0.3, 0.4)), packets.map { it.input })
        assertEquals(2L, packets.single().seq)
    }

    @Test fun orderIsKeptAroundTransitionsAndSequenceNumbersHaveNoGaps() {
        begin()
        controller.submit(DisplayAction.Pointer(0.1, 0.1))
        controller.submit(DisplayAction.Button(ControlButton.PRIMARY, true, 0.1, 0.1))
        controller.submit(DisplayAction.Pointer(0.2, 0.2))
        controller.submit(DisplayAction.Pointer(0.3, 0.3))
        controller.submit(DisplayAction.Button(ControlButton.PRIMARY, false, 0.3, 0.3))
        val packets = controller.flush()
        assertEquals(
            listOf(
                ControlInput.Pointer(0.1, 0.1), ControlInput.Button(ControlButton.PRIMARY, true, 0.1, 0.1),
                ControlInput.Pointer(0.3, 0.3), ControlInput.Button(ControlButton.PRIMARY, false, 0.3, 0.3),
            ),
            packets.map { it.input },
        )
        assertEquals(listOf(2L, 3L, 4L, 5L), packets.map { it.seq })
    }

    @Test fun keyAndButtonTransitionsWaitForTheirBudgetAndAreNeverDropped() {
        begin()
        repeat(20) { controller.press(ControlKey.TAB) }
        val sent = mutableListOf<ControlPacket>()
        var guard = 0
        while (controller.pending > 0 && guard++ < 100) {
            sent += controller.flush()
            now += 100
        }
        val keys = sent.map { it.input }.filterIsInstance<ControlInput.Key>()
        // 20 presses are 40 transitions, every one numbered and sent, in order, down then up.
        assertEquals(40, keys.size)
        assertTrue(keys.chunked(2).all { (down, up) -> down.down && !up.down })
        val seqs = sent.map { it.seq }
        assertEquals((seqs.first()..seqs.last()).toList(), seqs)
        assertTrue(DisplayController.Rates().discrete <= ScreenControl.DISCRETE_PER_SECOND)
    }

    /** The host's token bucket (rust/proto/src/screen_control.rs Bucket): one second's worth, refilled per millisecond. */
    private class HostBucket(private val rate: Long, start: Long) {
        private var tokens = rate * 1_000
        private var updated = start
        fun take(now: Long): Boolean {
            tokens = minOf(rate * 1_000, tokens + (now - updated).coerceAtMost(1_000) * rate)
            updated = now
            if (tokens < 1_000) return false
            tokens -= 1_000
            return true
        }
    }

    @Test fun theHostsBudgetsNeverRefuseWhatThePhoneSends() {
        val started = now
        begin()
        val motion = HostBucket(ScreenControl.MOTION_PER_SECOND.toLong(), started)
        val discrete = HostBucket(ScreenControl.DISCRETE_PER_SECOND.toLong(), started)
        val control = HostBucket(ScreenControl.CONTROL_PER_SECOND.toLong(), started)
        fun admit(packets: List<ControlPacket>) = packets.forEach { packet ->
            val bucket = when {
                packet.input.isMotion -> motion
                packet.input.isDiscrete -> discrete
                else -> control
            }
            assertTrue("refused ${packet.input} at $now", bucket.take(now))
        }
        for (step in 0 until 600) {
            controller.submit(DisplayAction.Pointer(step / 600.0, 0.5))
            controller.submit(DisplayAction.Scroll(0, 7, 0.5, 0.5))
            if (step % 2 == 0) controller.press(ControlKey.RIGHT)
            admit(controller.flush())
            // Overload never grows the queue past its bound (releases of held keys may go over it).
            assertTrue(controller.pending <= DisplayController.MAX_QUEUE + ControlKey.entries.size)
            now += 4
        }
        repeat(800) {
            admit(controller.flush())
            now += 10
        }
        assertEquals(0, controller.pending)
    }

    @Test fun aGeometryChangeDropsPendingInputAndIsAcknowledgedFirst() {
        begin()
        controller.submit(DisplayAction.Button(ControlButton.PRIMARY, true, 0.5, 0.5))
        controller.flush()
        repeat(30) { controller.press(ControlKey.DOWN) }
        controller.submit(DisplayAction.Pointer(0.6, 0.6))
        assertTrue(controller.pending > 0)
        val ack = controller.geometryChanged(2)
        assertEquals(0, controller.pending)
        assertEquals(ControlInput.GeometryAck, ack.single().input)
        assertEquals(2L, ack.single().geometry)
        // The host released the held button: an up for it is not sent, and later input carries the new generation.
        assertFalse(controller.submit(DisplayAction.Button(ControlButton.PRIMARY, false, 0.5, 0.5)))
        controller.submit(DisplayAction.Pointer(0.7, 0.7))
        val next = controller.flush().single()
        assertEquals(2L, next.geometry)
        assertEquals(ack.single().seq + 1, next.seq)
        // An older or equal generation changes nothing.
        assertTrue(controller.geometryChanged(2).isEmpty())
        assertTrue(controller.geometryChanged(1).isEmpty())
    }

    @Test fun stopBypassesTheBudgetAndEndsTheSession() {
        begin()
        repeat(40) { controller.press(ControlKey.TAB) }
        controller.flush()
        assertTrue(controller.pending > 0)
        val stop = controller.stop()
        assertNotNull(stop)
        assertEquals(ControlInput.Stop, stop!!.input)
        assertFalse(controller.active)
        assertEquals(0, controller.pending)
        assertTrue(controller.flush().isEmpty())
        assertFalse(controller.submit(DisplayAction.Pointer(0.5, 0.5)))
    }

    @Test fun endingElsewhereDropsPendingInputWithoutSending() {
        begin()
        controller.submit(DisplayAction.Text("hello"))
        repeat(30) { controller.press(ControlKey.TAB) }
        controller.end()
        assertFalse(controller.active)
        assertTrue(controller.flush().isEmpty())
        assertNull(controller.stop())
    }

    @Test fun aHeartbeatEveryTwoSeconds() {
        begin()
        assertTrue(controller.flush().isEmpty())
        now += 1_999
        assertTrue(controller.flush().isEmpty())
        now += 1
        assertEquals(listOf(ControlInput.Heartbeat), controller.flush().map { it.input })
        now += 500
        assertTrue(controller.flush().isEmpty())
        now += 1_500
        assertEquals(listOf(ControlInput.Heartbeat), controller.flush().map { it.input })
    }

    @Test fun onlyNegotiatedAndValidInputIsTaken() {
        begin(InputCapabilities(pointer = true))
        assertFalse(controller.submit(DisplayAction.Text("hi")))
        assertFalse(controller.press(ControlKey.TAB))
        assertTrue(controller.submit(DisplayAction.Pointer(0.0, 1.0)))
        assertFalse(controller.submit(DisplayAction.Pointer(1.01, 0.5)))
        assertFalse(controller.submit(DisplayAction.Pointer(Double.NaN, 0.5)))
        assertFalse(controller.submit(DisplayAction.Button(ControlButton.PRIMARY, false, 0.5, 0.5)))
        controller.end()
        begin()
        assertFalse(controller.submit(DisplayAction.Key(ControlKey.META, true)))
        assertFalse(controller.submit(DisplayAction.Key(ControlKey.CONTROL, true)))
        assertFalse(controller.submit(DisplayAction.Key(ControlKey.ALT, true)))
        assertFalse(controller.submit(DisplayAction.Text("line\nbreak")))
        assertFalse(controller.submit(DisplayAction.Text("x".repeat(257))))
        assertTrue(controller.submit(DisplayAction.Text("Привет 👋")))
        assertTrue(controller.press(ControlKey.TAB, shift = true))
        val keys = controller.flush().map { it.input }.filterIsInstance<ControlInput.Key>()
        assertEquals(
            listOf(ControlKey.SHIFT to true, ControlKey.TAB to true, ControlKey.TAB to false, ControlKey.SHIFT to false),
            keys.map { it.key to it.down },
        )
    }

    @Test fun scrollIsCoalescedAndSplitWithinTheContractBounds() {
        begin()
        repeat(5) { controller.submit(DisplayAction.Scroll(0, 500, 0.5, 0.5)) }
        val scrolls = controller.flush().map { it.input }.filterIsInstance<ControlInput.Scroll>()
        assertEquals(listOf(1000, 1000, 500), scrolls.map { it.dy })
        assertTrue(scrolls.all { it.dx == 0 && it.x == 0.5 })
        assertFalse(controller.submit(DisplayAction.Scroll(0, 0, 0.5, 0.5)))
    }
}
