package dev.bridgey.android.browse

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailFitTest {
    @Test
    fun anEmbeddedExifThumbnailIsTooSmallForEverySizeTheMacAsksFor() {
        // A camera's 160 x 120 EXIF thumbnail, which MediaStore returned for a 5712 x 4284 photo at every size.
        for (size in listOf(256, 288, 384, 512)) assertTrue("160 px at $size", ThumbnailFit.tooSmall(160, size))
    }

    @Test
    fun aThumbnailMadeAtTheSizeOrShrunkToFitTheBudgetIsKept() {
        assertFalse(ThumbnailFit.tooSmall(512, 512))
        assertFalse(ThumbnailFit.tooSmall(384, 512))
        assertFalse(ThumbnailFit.tooSmall(288, 288))
        assertTrue(ThumbnailFit.tooSmall(383, 512))
    }
}
