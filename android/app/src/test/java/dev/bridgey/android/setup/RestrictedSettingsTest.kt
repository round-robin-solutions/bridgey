package dev.bridgey.android.setup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android 13 restricted settings: when the hint can show, and that its copy is complete in both languages. */
class RestrictedSettingsTest {
    private val res = File(System.getProperty("bridgey.repoRoot"), "android/app/src/main/res")

    @Test
    fun onlyAndroid13AndLaterCanBlockNotificationAccess() {
        assertFalse(RestrictedSettings.canBeBlocked(PermissionKind.NOTIFICATION_ACCESS, 32))
        assertTrue(RestrictedSettings.canBeBlocked(PermissionKind.NOTIFICATION_ACCESS, 33))
        assertTrue(RestrictedSettings.canBeBlocked(PermissionKind.NOTIFICATION_ACCESS, 36))
        assertEquals(33, RestrictedSettings.FIRST_SDK)
    }

    @Test
    fun otherPermissionsAreNeverRestricted() {
        PermissionKind.entries.filter { it != PermissionKind.NOTIFICATION_ACCESS }.forEach { kind ->
            assertFalse(kind.name, RestrictedSettings.canBeBlocked(kind, 36))
            assertFalse(kind.name, RestrictedSettings.mayBeBlocked(kind, 36, asked = true, granted = false))
        }
    }

    @Test
    fun theHintShowsOnlyAfterAskingWhileNothingIsGranted() {
        val kind = PermissionKind.NOTIFICATION_ACCESS
        assertTrue(RestrictedSettings.mayBeBlocked(kind, 34, asked = true, granted = false))
        // Not asked yet: Allow has not been tried, so there is nothing to explain.
        assertFalse(RestrictedSettings.mayBeBlocked(kind, 34, asked = false, granted = false))
        // Granted: it worked.
        assertFalse(RestrictedSettings.mayBeBlocked(kind, 34, asked = true, granted = true))
        // Android 12 and older have no restricted settings.
        assertFalse(RestrictedSettings.mayBeBlocked(kind, 32, asked = true, granted = false))
    }

    private fun strings(folder: String, file: String): Map<String, String> {
        val text = File(res, "$folder/$file").readText()
        return Regex("""<string name="([a-z0-9_]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
            .findAll(text).associate { it.groupValues[1] to it.groupValues[2] }
    }

    @Test
    fun theCopyExistsInEnglishAndRussianWithoutEmDashes() {
        val keys = listOf(
            "perm_notification_access_why_restricted", "restricted_hint_title", "restricted_hint_body",
            "restricted_hint_steps", "restricted_hint_open",
        )
        listOf("values", "values-ru").forEach { folder ->
            val all = strings(folder, "strings_setup.xml")
            keys.forEach { key ->
                val value = all[key]
                assertTrue("$folder $key", !value.isNullOrBlank())
                assertFalse("$folder $key has an em dash", value!!.contains('\u2014'))
            }
            // Three numbered steps, the body names the setting it is about.
            assertEquals("$folder steps", 3, Regex("""\d\. """).findAll(all.getValue("restricted_hint_steps")).count())
            assertTrue("$folder body", all.getValue("restricted_hint_body").contains("%1\$s"))
        }
        val english = strings("values", "strings_setup.xml")
        assertTrue(english.getValue("restricted_hint_steps").contains("Allow restricted settings"))
        assertTrue(english.getValue("perm_notification_access_why_restricted").contains("Allow restricted settings"))
        // The plain reason stays as it was for Android 12 and older.
        assertFalse(english.getValue("perm_notification_access_why").contains("restricted"))
    }
}
