package dev.bridgey.android.browse

import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Transparent stickers came out black in the Mac's grid (MediaStore thumbnails are JPEGs): which files may be transparent. */
class ImageAlphaTest {
    private fun png(type: Int): ByteArray {
        val image = BufferedImage(40, 30, type)
        val out = ByteArrayOutputStream()
        ImageIO.write(image, "png", out)
        return out.toByteArray().copyOf(ImageAlpha.HEADER_BYTES)
    }

    private fun chunk(name: String, data: ByteArray): ByteArray {
        val length = byteArrayOf((data.size ushr 24).toByte(), (data.size ushr 16).toByte(), (data.size ushr 8).toByte(), data.size.toByte())
        return length + name.toByteArray(Charsets.ISO_8859_1) + data + ByteArray(4)
    }

    private fun handPng(colourType: Int, vararg chunks: Pair<String, ByteArray>): ByteArray {
        val ihdr = byteArrayOf(0, 0, 0, 40, 0, 0, 0, 30, 8, colourType.toByte(), 0, 0, 0)
        var bytes = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10) + chunk("IHDR", ihdr)
        for ((name, data) in chunks) bytes += chunk(name, data)
        return bytes
    }

    private fun webp(kind: String, flagsAt20or24: Int): ByteArray {
        val bytes = ByteArray(40)
        "RIFF".toByteArray().copyInto(bytes, 0)
        "WEBP".toByteArray().copyInto(bytes, 8)
        kind.toByteArray().copyInto(bytes, 12)
        if (kind == "VP8X") bytes[20] = flagsAt20or24.toByte() else bytes[24] = flagsAt20or24.toByte()
        return bytes
    }

    @Test
    fun pngsFromARealEncoderAreToldApartByColourType() {
        assertTrue(ImageAlpha.mayHaveAlpha(png(BufferedImage.TYPE_INT_ARGB), "image/png"))
        assertFalse(ImageAlpha.mayHaveAlpha(png(BufferedImage.TYPE_INT_RGB), "image/png"))
    }

    @Test
    fun aTransparencyChunkBeforeTheImageDataCounts() {
        assertTrue(ImageAlpha.mayHaveAlpha(handPng(3, "PLTE" to ByteArray(6), "tRNS" to ByteArray(2), "IDAT" to ByteArray(4)), "image/png"))
        assertTrue(ImageAlpha.mayHaveAlpha(handPng(2, "tRNS" to ByteArray(6), "IDAT" to ByteArray(4)), "image/png"))
        assertFalse(ImageAlpha.mayHaveAlpha(handPng(2, "IDAT" to ByteArray(4), "tRNS" to ByteArray(6)), "image/png"), "only before IDAT")
        assertFalse(ImageAlpha.mayHaveAlpha(handPng(3, "PLTE" to ByteArray(6), "IDAT" to ByteArray(4)), "image/png"))
        // A damaged length (here 0x7fffffff) never loops, overflows or reads past the header.
        val damaged = handPng(2, "zzzz" to ByteArray(0), "tRNS" to ByteArray(2))
        damaged[33] = 0x7f; damaged[34] = 0xff.toByte(); damaged[35] = 0xff.toByte(); damaged[36] = 0xff.toByte()
        assertFalse(ImageAlpha.mayHaveAlpha(damaged, "image/png"), "damaged length")
    }

    @Test
    fun webpAlphaFlagsAndOtherFormats() {
        assertTrue(ImageAlpha.mayHaveAlpha(webp("VP8X", 0x10), "image/webp"))
        assertFalse(ImageAlpha.mayHaveAlpha(webp("VP8X", 0x00), "image/webp"))
        assertTrue(ImageAlpha.mayHaveAlpha(webp("VP8L", 0x10), "image/webp"))
        assertFalse(ImageAlpha.mayHaveAlpha(webp("VP8 ", 0x10), "image/webp"))
        assertTrue(ImageAlpha.mayHaveAlpha("GIF89a".toByteArray(), "image/gif"))
        assertFalse(ImageAlpha.mayHaveAlpha(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xe0.toByte()), "image/jpeg"))
        assertFalse(ImageAlpha.mayHaveAlpha(ByteArray(0), "image/png"))
    }

    private fun assertFalse(value: Boolean, message: String) = org.junit.Assert.assertFalse(message, value)
}
