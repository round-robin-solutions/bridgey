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
        val manifest = File("src/main/AndroidManifest.xml").readText()
        listOf(
            "android.provider.Telephony.SMS_DELIVER", "android.provider.Telephony.WAP_PUSH_DELIVER",
            "android.intent.action.RESPOND_VIA_MESSAGE", "android.intent.action.SENDTO", "android.permission.BROADCAST_SMS",
            "android:scheme=\"sms\"", "android:scheme=\"smsto\"", "android.permission.WRITE_SMS", "android.permission.RECEIVE_SMS",
        ).forEach { org.junit.Assert.assertFalse(it, manifest.contains(it)) }
        // The send results receiver only takes Bridgey's own PendingIntents.
        org.junit.Assert.assertTrue(manifest.contains("""<receiver android:name=".sms.SmsResultReceiver" android:exported="false" />"""))
    }
}
