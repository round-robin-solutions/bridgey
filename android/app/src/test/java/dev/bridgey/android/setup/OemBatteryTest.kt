package dev.bridgey.android.setup

import android.app.Application
import android.provider.Settings
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], application = Application::class)
class OemBatteryTest {
    private fun vendor(manufacturer: String?, brand: String? = null) = OemBattery.checklist(manufacturer, brand)?.vendor

    @Test
    fun manufacturerOrBrandNamesTheVendor() {
        assertEquals(OemVendor.ONEPLUS, vendor("OnePlus"))
        assertEquals(OemVendor.COLOROS, vendor("OPPO"))
        assertEquals(OemVendor.COLOROS, vendor("realme"))
        assertEquals(OemVendor.XIAOMI, vendor("Xiaomi"))
        assertEquals(OemVendor.XIAOMI, vendor("Xiaomi", "Redmi"))
        assertEquals(OemVendor.XIAOMI, vendor("unknown", "POCO"))
        assertEquals(OemVendor.SAMSUNG, vendor("samsung"))
        assertEquals(OemVendor.VIVO, vendor("vivo"))
        assertEquals(OemVendor.VIVO, vendor("unknown", "iQOO"))
        assertEquals(OemVendor.PIXEL, vendor("Google"))
        assertEquals(OemVendor.PIXEL, vendor("Google", "google"))
        assertNull(vendor(null, null))
        assertNull(vendor("motorola", "motorola"))
    }

    @Test
    fun stepsPerVendor() {
        fun kinds(manufacturer: String) = OemBattery.checklist(manufacturer, null)!!.steps.map { it.kind }
        val usual = listOf(OemStepKind.AUTO_START, OemStepKind.BACKGROUND_ACTIVITY, OemStepKind.BATTERY_OPTIMISATION)
        assertEquals(usual, kinds("OnePlus"))
        assertEquals(usual, kinds("oppo"))
        assertEquals(usual, kinds("xiaomi"))
        assertEquals(usual, kinds("vivo"))
        assertEquals(listOf(OemStepKind.BACKGROUND_ACTIVITY, OemStepKind.BATTERY_OPTIMISATION, OemStepKind.NEVER_SLEEPING), kinds("samsung"))
        assertEquals(listOf(OemStepKind.APP_BATTERY_USAGE, OemStepKind.ADAPTIVE_BATTERY, OemStepKind.PAUSE_IF_UNUSED), kinds("Google"))
    }

    @Test
    fun deepLinksComeFromDontKillMyApp() {
        val xiaomi = OemBattery.checklist("xiaomi", null)!!.steps.first { it.kind == OemStepKind.AUTO_START }
        assertEquals(listOf("com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity"), xiaomi.components)
        val samsung = OemBattery.checklist("samsung", null)!!.steps.first { it.kind == OemStepKind.NEVER_SLEEPING }
        assertTrue(samsung.components.first().startsWith("com.samsung.android.lool/"))
        OemVendor.entries.forEach { vendorEntry ->
            val name = when (vendorEntry) {
                OemVendor.ONEPLUS -> "oneplus"
                OemVendor.COLOROS -> "oppo"
                OemVendor.XIAOMI -> "xiaomi"
                OemVendor.SAMSUNG -> "samsung"
                OemVendor.VIVO -> "vivo"
                OemVendor.PIXEL -> "google"
            }
            OemBattery.checklist(name, null)!!.steps.flatMap { it.components }.forEach { component ->
                assertTrue(component, Regex("""^[a-z0-9.]+/[A-Za-z0-9.]+$""").matches(component))
            }
        }
    }

    @Test
    fun pixelStepsOpenAppInfoOrBatterySaver() {
        val steps = OemBattery.checklist("Google", "google")!!.steps.associateBy { it.kind }
        // App battery usage and Unused app settings live in App info: no vendor screen to try first.
        listOf(OemStepKind.APP_BATTERY_USAGE, OemStepKind.PAUSE_IF_UNUSED).forEach { kind ->
            val intents = OemBattery.intents(steps.getValue(kind), "in.roundrobin.bridgey", "Bridgey")
            assertEquals(listOf(Settings.ACTION_APPLICATION_DETAILS_SETTINGS), intents.map { it.action })
        }
        // Adaptive Battery sits under Battery Saver (Pixel Phone Help); App info is the fallback.
        val adaptive = OemBattery.intents(steps.getValue(OemStepKind.ADAPTIVE_BATTERY), "in.roundrobin.bridgey", "Bridgey")
        assertEquals(listOf(Settings.ACTION_BATTERY_SAVER_SETTINGS, Settings.ACTION_APPLICATION_DETAILS_SETTINGS), adaptive.map { it.action })
        assertEquals("https://support.google.com/pixelphone/answer/7015477", OemBattery.sourceUrl(OemVendor.PIXEL))
        assertEquals("https://dontkillmyapp.com", OemBattery.sourceUrl(OemVendor.SAMSUNG))
    }

    @Test
    fun everyStepFallsBackToAppInfo() {
        OemBattery.checklist("oneplus", null)!!.steps.forEach { step ->
            val intents = OemBattery.intents(step, "in.roundrobin.bridgey", "Bridgey")
            assertEquals(step.components.size + 1, intents.size)
            val last = intents.last()
            assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, last.action)
            assertEquals("package:in.roundrobin.bridgey", last.data.toString())
            intents.dropLast(1).forEachIndexed { index, intent -> assertEquals(step.components[index], intent.component!!.flattenToString()) }
        }
    }

    private fun strings(folder: String): Map<String, String> {
        val res = File(System.getProperty("bridgey.repoRoot"), "android/app/src/main/res")
        return Regex("""<string name="([a-z0-9_]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
            .findAll(File(res, "$folder/strings_setup.xml").readText()).associate { it.groupValues[1] to it.groupValues[2] }
    }

    @Test
    fun theNewPixelCopyExistsInBothLanguages() {
        val keys = listOf(
            "oem_vendor_pixel", "oem_intro_pixel", "oem_source_pixel", "oem_step_app_battery_usage", "oem_step_adaptive_battery",
            "oem_step_pause_if_unused", "oem_pixel_app_battery_usage", "oem_pixel_adaptive_battery", "oem_pixel_pause_if_unused",
        )
        listOf("values", "values-ru").forEach { folder ->
            val all = strings(folder)
            keys.forEach { key ->
                assertTrue("$folder $key", !all[key].isNullOrBlank())
                assertFalse("$folder $key has an em dash", all.getValue(key).contains('\u2014'))
            }
        }
        val english = strings("values")
        assertTrue(english.getValue("oem_pixel_app_battery_usage").contains("Unrestricted"))
        assertTrue(english.getValue("oem_pixel_pause_if_unused").contains("Pause app activity if unused"))
        assertTrue(english.getValue("oem_pixel_adaptive_battery").contains("Adaptive Battery"))
    }
}
