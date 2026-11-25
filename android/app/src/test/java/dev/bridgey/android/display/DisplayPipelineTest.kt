package dev.bridgey.android.display

import dev.bridgey.android.screen.ScreenFrameHeader
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Reassembly, parameter sets and the decoding rules with a fake codec: what the emulator cannot show piece by piece. */
class DisplayPipelineTest {
    private val stream = "6c1b2a39-4857-4f6e-8d7c-0b1a29384756"
    private val sps = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0, 0x1F)
    private val pps = byteArrayOf(0, 0, 0, 1, 0x68, 0xCE.toByte())
    private val idr = byteArrayOf(0, 0, 0, 1, 0x65, 0x88.toByte(), 0x84.toByte())
    private val slice = byteArrayOf(0, 0, 0, 1, 0x41, 0x9A.toByte())

    private fun header(frame: Long, part: Int, last: Boolean, key: Boolean = false) =
        ScreenFrameHeader(stream, frame * 10 + part, frame, part, key, key, last, 0)

    @Test fun aWholeFrameInOnePartAndInSeveral() {
        val assembler = DisplayFrameAssembler()
        val one = assembler.add(header(1, 0, last = true, key = true), sps + pps + idr) as DisplayFrameAssembler.Event.Complete
        assertArrayEquals(sps + pps + idr, one.frame.data)
        assertTrue(one.frame.key)
        assertEquals(DisplayFrameAssembler.Event.Pending, assembler.add(header(2, 0, last = false), slice))
        assertEquals(DisplayFrameAssembler.Event.Pending, assembler.add(header(2, 1, last = false), byteArrayOf(1, 2)))
        val two = assembler.add(header(2, 2, last = true), byteArrayOf(3)) as DisplayFrameAssembler.Event.Complete
        assertArrayEquals(slice + byteArrayOf(1, 2, 3), two.frame.data)
        assertEquals(2L, assembler.newestFrame)
    }

    @Test fun aMissingOrOutOfOrderPartLosesTheFrame() {
        val assembler = DisplayFrameAssembler()
        assertEquals(DisplayFrameAssembler.Event.Lost(1), assembler.add(header(1, 1, last = true), byteArrayOf(1)))
        assertEquals(DisplayFrameAssembler.Event.Pending, assembler.add(header(2, 0, last = false), slice))
        assertEquals(DisplayFrameAssembler.Event.Lost(2), assembler.add(header(2, 2, last = true), byteArrayOf(1)))
        // A part of a frame already given up is ignored.
        assertEquals(DisplayFrameAssembler.Event.Ignored, assembler.add(header(2, 1, last = false), byteArrayOf(1)))
    }

    @Test fun aLaterFrameBeforeTheEndLosesTheEarlierOneUnlessItIsAKeyFrame() {
        val assembler = DisplayFrameAssembler()
        assembler.add(header(1, 0, last = false), slice)
        assertEquals(DisplayFrameAssembler.Event.Lost(2), assembler.add(header(2, 0, last = true), slice))
        assembler.add(header(3, 0, last = false), slice)
        val key = assembler.add(header(4, 0, last = true, key = true), sps + pps + idr)
        assertTrue(key is DisplayFrameAssembler.Event.Complete)
        assertEquals(DisplayFrameAssembler.Event.Ignored, assembler.add(header(3, 1, last = true), byteArrayOf(1)))
    }

    @Test fun parameterSetsAreFoundWithTheirStartCodes() {
        val sets = H264ParameterSets.find(byteArrayOf(0, 0, 1, 9, 0x10) + sps + pps + idr)!!
        assertArrayEquals(sps, sets.sps)
        assertArrayEquals(pps, sets.pps)
        assertNull(H264ParameterSets.find(idr))
        assertNull(H264ParameterSets.find(sps + idr))
        assertEquals(sets, H264ParameterSets.find(sps + pps))
    }

    private class FakeCodec(private val results: ArrayDeque<VideoCodec.Decoded>) : VideoCodec {
        var configured: H264ParameterSets.Sets? = null
        var released = false
        val decoded = mutableListOf<Long>()
        override val name = "fake.avc"
        override fun configure(width: Int, height: Int, sets: H264ParameterSets.Sets, surface: Any): Boolean {
            configured = sets
            return true
        }
        override fun decode(accessUnit: ByteArray, presentationUs: Long, timeoutMs: Long): VideoCodec.Decoded {
            decoded += presentationUs
            return results.removeFirstOrNull() ?: VideoCodec.Decoded.RENDERED
        }
        override fun release() { released = true }
    }

    private fun frame(n: Long, key: Boolean, data: ByteArray) = AssembledFrame(n, key, key, 0, data)

    @Test fun decodingWaitsForASurfaceAndAKeyFrameWithItsParameterSets() {
        val made = mutableListOf<FakeCodec>()
        var now = 0L
        val logic = DisplayDecodeLogic({ FakeCodec(ArrayDeque()).also(made::add) }, { now })
        assertEquals(DisplayDecodeLogic.Outcome.NoSurface, logic.decode(frame(1, true, sps + pps + idr), 1920, 1080))
        logic.attach("surface")
        assertEquals(DisplayDecodeLogic.Outcome.NeedsKeyFrame, logic.decode(frame(2, false, slice), 1920, 1080))
        now = 5
        val outcome = logic.decode(frame(3, true, sps + pps + idr), 1920, 1080)
        assertTrue(outcome is DisplayDecodeLogic.Outcome.Decoded)
        assertEquals(1, made.size)
        assertEquals(H264ParameterSets.Sets(sps, pps), made.single().configured)
        assertTrue(logic.decode(frame(4, false, slice), 1920, 1080) is DisplayDecodeLogic.Outcome.Decoded)
        // The same parameter sets again: the codec stays.
        assertTrue(logic.decode(frame(5, true, sps + pps + idr), 1920, 1080) is DisplayDecodeLogic.Outcome.Decoded)
        assertEquals(1, made.size)
        assertEquals("fake.avc", logic.codecName)
    }

    @Test fun aNewSizeRebuildsTheCodecFromItsKeyFrame() {
        val made = mutableListOf<FakeCodec>()
        val logic = DisplayDecodeLogic({ FakeCodec(ArrayDeque()).also(made::add) }, { 0 })
        logic.attach("surface")
        logic.decode(frame(1, true, sps + pps + idr), 1920, 1080)
        val rotatedSps = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0, 0x20)
        assertTrue(logic.decode(frame(2, true, rotatedSps + pps + idr), 1080, 1920) is DisplayDecodeLogic.Outcome.Decoded)
        assertEquals(2, made.size)
        assertTrue(made.first().released)
    }

    @Test fun aFailureOrANewSurfaceWaitsForTheNextKeyFrame() {
        val made = mutableListOf<FakeCodec>()
        val logic = DisplayDecodeLogic({ FakeCodec(ArrayDeque(listOf(VideoCodec.Decoded.RENDERED, VideoCodec.Decoded.FAILED))).also(made::add) }, { 0 })
        logic.attach("surface")
        logic.decode(frame(1, true, sps + pps + idr), 1920, 1080)
        assertEquals(DisplayDecodeLogic.Outcome.NeedsKeyFrame, logic.decode(frame(2, false, slice), 1920, 1080))
        assertEquals(DisplayDecodeLogic.Outcome.NeedsKeyFrame, logic.decode(frame(3, false, slice), 1920, 1080))
        assertTrue(logic.decode(frame(4, true, sps + pps + idr), 1920, 1080) is DisplayDecodeLogic.Outcome.Decoded)
        logic.attach("another surface")
        assertTrue(made.last().released)
        assertEquals(DisplayDecodeLogic.Outcome.NeedsKeyFrame, logic.decode(frame(5, false, slice), 1920, 1080))
        assertTrue(logic.decode(frame(6, true, sps + pps + idr), 1920, 1080) is DisplayDecodeLogic.Outcome.Decoded)
        logic.lost()
        assertEquals(DisplayDecodeLogic.Outcome.NeedsKeyFrame, logic.decode(frame(7, false, slice), 1920, 1080))
    }

    @Test fun captureSizesFollowTheProtocolRule() {
        assertEquals(1920 to 1246, displayCaptureSize(3024, 1964))
        assertEquals(1080 to 1920, displayCaptureSize(1440, 2560))
        assertEquals(1280 to 800, displayCaptureSize(1280, 800))
    }
}
