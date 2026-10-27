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
                "android.permission.ACCESS_NOTIFICATION_POLICY",
                "android.permission.CAMERA",
            ),
            declared,
        )
    }

    /** No backup and, on Android 12+, no device-to-device transfer of the device ID, trust or keys. */
    @Test
    fun noDataLeavesInBackupsOrDeviceTransfers() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        org.junit.Assert.assertTrue(manifest.contains("""android:allowBackup="false""""))
        org.junit.Assert.assertTrue(manifest.contains("""android:dataExtractionRules="@xml/data_extraction_rules""""))
        org.junit.Assert.assertTrue(manifest.contains("""android:fullBackupContent="@xml/backup_rules""""))
        val rules = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/xml/data_extraction_rules.xml")).documentElement
        val domains = listOf("root", "file", "database", "sharedpref", "external", "device_root", "device_file", "device_database", "device_sharedpref")
        listOf("cloud-backup", "device-transfer").forEach { section ->
            val element = rules.getElementsByTagName(section).item(0) as org.w3c.dom.Element
            assertEquals("$section includes nothing", 0, element.getElementsByTagName("include").length)
            val excludes = element.getElementsByTagName("exclude")
            val excluded = (0 until excludes.length).map { excludes.item(it) as org.w3c.dom.Element }
                .filter { it.getAttribute("path") == "." }.map { it.getAttribute("domain") }.toSet()
            assertEquals("$section excludes every domain", domains.toSet(), excluded)
        }
    }

    /** Glance's WorkManager would add RECEIVE_BOOT_COMPLETED to the APK; the main manifest removes it. */
    @Test
    fun widgetLibraryDoesNotAddBootPermission() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        org.junit.Assert.assertTrue(
            manifest.contains("""<uses-permission tools:node="remove" android:name="android.permission.RECEIVE_BOOT_COMPLETED" />"""),
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
