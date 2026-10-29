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
                "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
                "android.permission.WAKE_LOCK",
                "android.permission.CALL_PHONE",
                "android.permission.READ_PHONE_STATE",
                "android.permission.ANSWER_PHONE_CALLS",
                "android.permission.REQUEST_INSTALL_PACKAGES",
                "android.permission.UPDATE_PACKAGES_WITHOUT_USER_ACTION",
                "android.permission.READ_LOGS",
                "android.permission.SYSTEM_ALERT_WINDOW",
                "android.permission.READ_MEDIA_IMAGES",
                "android.permission.READ_MEDIA_VIDEO",
                "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
                "android.permission.READ_EXTERNAL_STORAGE",
                "android.permission.ACCESS_NOTIFICATION_POLICY",
                "android.permission.CAMERA",
                // Text messages (off by default, asked for when it is turned on).
                "android.permission.READ_SMS",
                "android.permission.SEND_SMS",
                "android.permission.READ_CONTACTS",
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

    /** Since Text messages, SMS access is in every build and the lab overlay is gone. */
    @Test
    fun noLabManifestOverlay() {
        org.junit.Assert.assertTrue(!File("src/lab/AndroidManifest.xml").exists())
        org.junit.Assert.assertTrue(!File("build.gradle.kts").readText().contains("src/lab/AndroidManifest.xml"))
    }

    /**
     * Bridgey never becomes the default SMS app: it declares none of the components Android requires of
     * one (SMS_DELIVER, WAP_PUSH_DELIVER, RESPOND_VIA_MESSAGE, a SENDTO handler for sms: or smsto:).
     */
    @Test
    fun neverADefaultSmsHandler() {
        val full = File("src/main/AndroidManifest.xml").readText()
        // <queries> may name these intents to see the default SMS app (lookups only, no components); the rest of
        // the manifest may not.
        val queries = Regex("<queries>[\\s\\S]*?</queries>").find(full)?.value.orEmpty()
        listOf("<activity", "<receiver", "<service", "<provider", "<intent-filter").forEach { org.junit.Assert.assertFalse(it, queries.contains(it)) }
        val manifest = full.replace(queries, "")
        listOf(
            "android.provider.Telephony.SMS_DELIVER", "android.provider.Telephony.WAP_PUSH_DELIVER",
            "android.intent.action.RESPOND_VIA_MESSAGE", "android.intent.action.SENDTO", "android.permission.BROADCAST_SMS",
            "android:scheme=\"sms\"", "android:scheme=\"smsto\"", "android.permission.WRITE_SMS", "android.permission.RECEIVE_SMS",
        ).forEach { org.junit.Assert.assertFalse(it, manifest.contains(it)) }
        // The send results receiver only takes Bridgey's own PendingIntents.
        org.junit.Assert.assertTrue(manifest.contains("""<receiver android:name=".sms.SmsResultReceiver" android:exported="false" />"""))
    }
}
