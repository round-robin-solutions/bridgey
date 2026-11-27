package dev.bridgey.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReceivedFileNotifierTest {
    private val types = mapOf(
        "pdf" to "application/pdf",
        "jpg" to "image/jpeg",
        "apk" to "application/vnd.android.package-archive",
        "weird" to "application/vnd.android.package-archive",
    )
    private fun typeOf(name: String) = receivedFileOpenType(name) { types[it] }

    @Test fun theTypeComesFromTheStoredNameNotTheSender() {
        assertEquals("application/pdf", typeOf("Invoice.PDF"))
        assertEquals("image/jpeg", typeOf("photo.final.jpg"))
    }

    @Test fun aLargeBatchKeepsOnlyTheNewestNotifications() {
        // 60 files: Android would refuse Bridgey's notifications past 50; the oldest are cancelled instead.
        val shown = (1..60).map { it to 1_000L + it }.shuffled()
        val retired = receivedToRetire(shown, keep = 8)
        assertEquals((1..53).toList(), retired.sorted())
        assertEquals("seven stay, with room for the new one", 7, shown.size - retired.size)
        assertEquals(emptyList<Int>(), receivedToRetire(listOf(1 to 1L, 2 to 2L), keep = 8))
    }

    @Test fun anAndroidPackageOrUnknownTypeIsNeverOpenedDirectly() {
        assertNull(typeOf("update.apk"))
        assertNull(typeOf("update.APK"))
        assertNull("a mapping to the installer type is refused too", typeOf("file.weird"))
        assertNull(typeOf("no-extension"))
        assertNull(typeOf("file.unknownext"))
    }
}
