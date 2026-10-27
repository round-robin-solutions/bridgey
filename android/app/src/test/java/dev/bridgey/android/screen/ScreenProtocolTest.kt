package dev.bridgey.android.screen

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenProtocolTest {
    private val stream = "6c2e9a14-3b5d-4e7f-8a90-1b2c3d4e5f60"

    @Test fun featureKeyMatchesTheSwitch() {
        assertEquals(SCREEN_FEATURE_KEY, dev.bridgey.android.BridgeyFeature.SCREEN.key)
        assertFalse(dev.bridgey.android.featureOnByDefault(dev.bridgey.android.BridgeyFeature.SCREEN))
        assertFalse(dev.bridgey.android.featureEnabledByLegacyPeer(dev.bridgey.android.BridgeyFeature.SCREEN))
        assertTrue(SCREEN_FEATURE_KEY in dev.bridgey.android.KNOWN_DRAFT_FEATURE_KEYS)
    }

    @Test fun headerIsFortyBytesBigEndian() {
        val header = ScreenFrameHeader(stream, sequence = 0x0102030405L, frame = 0xFFFF_FFFFL, part = 3, key = true, parameterSets = false, last = true, captureMicros = 7)
        val bytes = ScreenFrameCodec.encode(header, byteArrayOf(9, 8))
        assertEquals(42, bytes.size)
        assertEquals(1, bytes[0].toInt())
        assertEquals(5, bytes[1].toInt())
        assertEquals(listOf(0, 3), listOf(bytes[2].toInt(), bytes[3].toInt()))
        assertEquals(0x6c.toByte(), bytes[4])
        assertEquals(0x60.toByte(), bytes[19])
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 2, 3, 4, 5), bytes.copyOfRange(20, 28))
        assertArrayEquals(byteArrayOf(-1, -1, -1, -1), bytes.copyOfRange(28, 32))
        assertArrayEquals(byteArrayOf(0, 0, 0, 0, 0, 0, 0, 7), bytes.copyOfRange(32, 40))
        assertArrayEquals(byteArrayOf(9, 8), bytes.copyOfRange(40, 42))
    }

    @Test fun anAccessUnitSplitsIntoNumberedParts() {
        val unit = ByteArray(32_768 * 2 + 5).also { it[2] = 0; it[3] = 1; it[0] = 0; it[1] = 0 }
        val parts = ScreenFrameCodec.parts(stream, firstSequence = 10, frame = 4, key = true, parameterSets = true, captureMicros = 99, accessUnit = unit)
        assertEquals(3, parts.size)
        val decoded = parts.map { ScreenFrameCodec.decode(it)!!.first }
        assertEquals(listOf(10L, 11L, 12L), decoded.map { it.sequence })
        assertEquals(listOf(0, 1, 2), decoded.map { it.part })
        assertEquals(listOf(false, false, true), decoded.map { it.last })
        assertTrue(decoded.all { it.key && it.parameterSets && it.frame == 4L && it.streamId == stream })
        assertEquals(listOf(32_808, 32_808, 45), parts.map { it.size })
    }

    @Test fun aFrameOverSixtyFourPartsIsRefused() {
        val result = runCatching { ScreenFrameCodec.parts(stream, 1, 1, true, true, 0, ByteArray(32_768 * 64 + 1)) }
        assertTrue(result.isFailure)
        assertEquals(64, ScreenFrameCodec.parts(stream, 1, 1, true, true, 0, ByteArray(32_768 * 64)).size)
    }

    @Test fun annexBTypes() {
        val unit = byteArrayOf(0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 1, 0x65, 3)
        assertEquals(listOf(7, 8, 5), AnnexB.nalTypes(unit))
        assertTrue(AnnexB.startsWithSps(unit))
        assertTrue(AnnexB.hasIdr(unit))
        assertFalse(AnnexB.startsWithSps(byteArrayOf(0, 0, 1, 0x41)))
    }

    @Test fun macMessagesMustBeStrict() {
        val ack = """{"version":1,"streamId":"$stream","sequence":2,"frame":3,"decodeMs":4}""".toByteArray()
        assertEquals(ScreenMacMessage.Ack(stream, 2, 3, 4, false), decodeScreenMacMessage(ScreenKinds.ACK, ack))
        assertNull(decodeScreenMacMessage(ScreenKinds.ACK, """{version:1,streamId:"$stream",sequence:2,frame:3,decodeMs:4}""".toByteArray()))
        assertNull(decodeScreenMacMessage(ScreenKinds.FRAME, ack))
        assertEquals(ScreenStopReason.FAILED, ScreenStopReason.fromWire("later"))
    }
}
