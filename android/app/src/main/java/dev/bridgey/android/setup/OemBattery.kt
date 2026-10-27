package dev.bridgey.android.setup

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings

/**
 * Phone makers that stop background apps beyond Android's own battery optimisation. The steps and
 * the screens they open come from dontkillmyapp.com; the copy lives in strings_setup.xml under
 * `oem_<vendor>_<step>`.
 */
enum class OemVendor(val key: String) {
    ONEPLUS("oneplus"),
    COLOROS("coloros"),
    XIAOMI("xiaomi"),
    SAMSUNG("samsung"),
    VIVO("vivo"),
}

enum class OemStepKind(val key: String) {
    AUTO_START("auto_start"),
    BACKGROUND_ACTIVITY("background"),
    BATTERY_OPTIMISATION("battery"),
    NEVER_SLEEPING("never_sleeping"),
}

/**
 * One step: what to change ([kind]) and the screens that may show it, best first. An empty list (or
 * none resolvable) opens Bridgey's App info, where every phone shows its battery settings.
 */
data class OemStep(val kind: OemStepKind, val components: List<String>)

data class OemChecklist(val vendor: OemVendor, val steps: List<OemStep>)

object OemBattery {
    const val SOURCE_URL = "https://dontkillmyapp.com"

    /** [manufacturer] and [brand] are `Build.MANUFACTURER` and `Build.BRAND`; either may name the maker. */
    fun checklist(manufacturer: String?, brand: String?): OemChecklist? {
        val names = listOfNotNull(manufacturer, brand).map { it.trim().lowercase() }
        val vendor = names.firstNotNullOfOrNull(::vendorFor) ?: return null
        return OemChecklist(vendor, stepsFor(vendor))
    }

    private fun vendorFor(name: String): OemVendor? = when (name) {
        "oneplus" -> OemVendor.ONEPLUS
        "oppo", "realme" -> OemVendor.COLOROS
        "xiaomi", "redmi", "poco" -> OemVendor.XIAOMI
        "samsung" -> OemVendor.SAMSUNG
        "vivo", "iqoo" -> OemVendor.VIVO
        else -> null
    }

    private val colorOsAutoStart = listOf(
        "com.coloros.safecenter/com.coloros.safecenter.startupapp.StartupAppListActivity",
        "com.coloros.safecenter/com.coloros.safecenter.permission.startup.StartupAppListActivity",
        "com.oppo.safe/com.oppo.safe.permission.startup.StartupAppListActivity",
    )
    private val colorOsBattery = listOf(
        "com.coloros.oppoguardelf/com.coloros.powermanager.fuelgaue.PowerUsageModelActivity",
        "com.coloros.oppoguardelf/com.coloros.powermanager.fuelgaue.PowerSaverModeActivity",
        "com.coloros.oppoguardelf/com.coloros.powermanager.fuelgaue.PowerConsumptionActivity",
    )

    private fun stepsFor(vendor: OemVendor): List<OemStep> = when (vendor) {
        OemVendor.ONEPLUS -> listOf(
            OemStep(OemStepKind.AUTO_START, listOf("com.oneplus.security/com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity") + colorOsAutoStart),
            OemStep(OemStepKind.BACKGROUND_ACTIVITY, emptyList()),
            OemStep(OemStepKind.BATTERY_OPTIMISATION, colorOsBattery),
        )
        OemVendor.COLOROS -> listOf(
            OemStep(OemStepKind.AUTO_START, colorOsAutoStart),
            OemStep(OemStepKind.BACKGROUND_ACTIVITY, emptyList()),
            OemStep(OemStepKind.BATTERY_OPTIMISATION, colorOsBattery),
        )
        OemVendor.XIAOMI -> listOf(
            OemStep(OemStepKind.AUTO_START, listOf("com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity")),
            OemStep(OemStepKind.BACKGROUND_ACTIVITY, listOf("com.miui.powerkeeper/com.miui.powerkeeper.ui.HiddenAppsConfigActivity")),
            OemStep(OemStepKind.BATTERY_OPTIMISATION, emptyList()),
        )
        OemVendor.SAMSUNG -> listOf(
            OemStep(OemStepKind.BACKGROUND_ACTIVITY, emptyList()),
            OemStep(OemStepKind.BATTERY_OPTIMISATION, emptyList()),
            OemStep(
                OemStepKind.NEVER_SLEEPING,
                listOf(
                    "com.samsung.android.lool/com.samsung.android.sm.battery.ui.BatteryActivity",
                    "com.samsung.android.lool/com.samsung.android.sm.ui.battery.BatteryActivity",
                    "com.samsung.android.sm/com.samsung.android.sm.ui.battery.BatteryActivity",
                ),
            ),
        )
        OemVendor.VIVO -> listOf(
            OemStep(
                OemStepKind.AUTO_START,
                listOf(
                    "com.iqoo.secure/com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
                    "com.vivo.permissionmanager/com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                    "com.iqoo.secure/com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                ),
            ),
            OemStep(OemStepKind.BACKGROUND_ACTIVITY, listOf("com.vivo.abe/com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity")),
            OemStep(OemStepKind.BATTERY_OPTIMISATION, emptyList()),
        )
    }

    /** Explicit intents for [step], best first, then App info for [packageName] as the fallback. */
    fun intents(step: OemStep, packageName: String, label: String): List<Intent> =
        step.components.mapNotNull(ComponentName::unflattenFromString).map { component ->
            Intent().setComponent(component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                // Xiaomi's battery saver page opens on the app it is given.
                .putExtra("package_name", packageName)
                .putExtra("package_label", label)
        } + appDetails(packageName)

    fun appDetails(packageName: String): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /**
     * Opens the first screen that starts. Other apps' activities are not visible to Bridgey's package
     * queries on Android 11 and later, so each is tried in turn instead of resolved first.
     */
    fun open(context: Context, step: OemStep) {
        val label = context.applicationInfo.loadLabel(context.packageManager).toString()
        for (intent in intents(step, context.packageName, label)) {
            val started = try {
                context.startActivity(intent)
                true
            } catch (_: ActivityNotFoundException) {
                false
            } catch (_: SecurityException) {
                false
            }
            if (started) return
        }
    }
}
