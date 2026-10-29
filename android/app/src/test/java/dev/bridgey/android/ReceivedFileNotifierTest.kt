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

    @Test fun anAndroidPackageOrUnknownTypeIsNeverOpenedDirectly() {
        assertNull(typeOf("update.apk"))
        assertNull(typeOf("update.APK"))
        assertNull("a mapping to the installer type is refused too", typeOf("file.weird"))
        assertNull(typeOf("no-extension"))
        assertNull(typeOf("file.unknownext"))
    }
}
