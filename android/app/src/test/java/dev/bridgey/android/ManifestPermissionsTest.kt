package dev.bridgey.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ManifestPermissionsTest {
    @Test
    fun manifestDeclaresOnlyRequiredPermissions() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val declared = Regex("""<uses-permission android:name="([^"]+)"""")
            .findAll(manifest)
            .map { it.groupValues[1] }
            .toSet()

        assertEquals(
            setOf(
                "android.permission.INTERNET",
                "android.permission.ACCESS_NETWORK_STATE",
                "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
                "android.permission.CHANGE_WIFI_MULTICAST_STATE",
                "android.permission.POST_NOTIFICATIONS",
                "android.permission.FOREGROUND_SERVICE",
                "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE",
                "android.permission.WAKE_LOCK",
                "android.permission.CALL_PHONE",
                "android.permission.READ_PHONE_STATE",
                "android.permission.ANSWER_PHONE_CALLS",
                "android.permission.REQUEST_INSTALL_PACKAGES",
                "android.permission.READ_LOGS",
                "android.permission.SYSTEM_ALERT_WINDOW",
                "android.permission.READ_MEDIA_IMAGES",
                "android.permission.READ_MEDIA_VIDEO",
                "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
                "android.permission.READ_EXTERNAL_STORAGE",
            ),
            declared,
        )
    }

    /** READ_SMS is in lab builds only (beta, nightly, local), for the Code reader test; stable never has it. */
    @Test
    fun labManifestAddsOnlyReadSmsAndOnlyOutsideStable() {
        val lab = File("src/lab/AndroidManifest.xml").readText()
        val declared = Regex("""<uses-permission android:name="([^"]+)"""").findAll(lab).map { it.groupValues[1] }.toSet()
        assertEquals(setOf("android.permission.READ_SMS"), declared)
        val gradle = File("build.gradle.kts").readText()
        org.junit.Assert.assertTrue(gradle.contains("if (!isStableBuild) {"))
        org.junit.Assert.assertTrue(gradle.contains("src/lab/AndroidManifest.xml"))
        org.junit.Assert.assertTrue(!File("src/main/AndroidManifest.xml").readText().contains("READ_SMS"))
    }
}
