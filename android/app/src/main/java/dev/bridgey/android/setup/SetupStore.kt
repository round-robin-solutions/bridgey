package dev.bridgey.android.setup

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Setup's own state on this phone: whether setup ran, which permissions were explained, which quick
 * steps were skipped (`bridgey.setup`), and the last version that showed What's new
 * (`bridgey.whats_new`, kept by Reset > Settings so What's new does not come back).
 */
class SetupStore(context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val whatsNew = context.getSharedPreferences(WHATS_NEW_PREFERENCES, Context.MODE_PRIVATE)
    private val legacyOnboarding = context.getSharedPreferences(LEGACY_ONBOARDING_PREFERENCES, Context.MODE_PRIVATE)
    private val settings = context.getSharedPreferences(SETTINGS_PREFERENCES, Context.MODE_PRIVATE)

    private val mutableBanner = MutableStateFlow(preferences.getBoolean(KEY_BANNER, false))

    /** The Home banner "See what's new and review your setup" is waiting to be seen. */
    val bannerPending: StateFlow<Boolean> = mutableBanner.asStateFlow()

    /** Decides once per launch, and stores the status so later launches agree. */
    fun launch(): SetupLaunch {
        val stored = preferences.getString(KEY_STATUS, null)?.let { runCatching { SetupStatus.valueOf(it) }.getOrNull() }
        val launch = SetupLaunchLogic.decide(stored, legacyOnboarding.getBoolean(KEY_LEGACY_COMPLETED, false), settings.all.isNotEmpty())
        if (stored == null) {
            preferences.edit().putString(KEY_STATUS, launch.status.name).apply()
        }
        return launch
    }

    fun complete() {
        preferences.edit().putString(KEY_STATUS, SetupStatus.DONE.name).apply()
        // Older builds read this flag; keep it in step for a downgrade.
        legacyOnboarding.edit().putBoolean(KEY_LEGACY_COMPLETED, true).apply()
    }

    fun explained(kind: PermissionKind): Boolean = preferences.getBoolean("$KEY_EXPLAINED${kind.key}", false)

    fun markExplained(kind: PermissionKind) {
        preferences.edit().putBoolean("$KEY_EXPLAINED${kind.key}", true).apply()
    }

    fun recordSkipped(steps: Set<QuickStep>) {
        preferences.edit().apply { QuickStep.entries.forEach { putBoolean("$KEY_SKIPPED${it.name.lowercase()}", it in steps) } }.apply()
    }

    fun skipped(): Set<QuickStep> = QuickStep.entries.filterTo(LinkedHashSet()) { preferences.getBoolean("$KEY_SKIPPED${it.name.lowercase()}", false) }

    fun lastWhatsNew(): AppVersion? {
        val name = whatsNew.getString(KEY_VERSION_NAME, null) ?: return null
        return AppVersion(name, whatsNew.getLong(KEY_VERSION_CODE, 0L))
    }

    fun recordWhatsNew(version: AppVersion) {
        whatsNew.edit().putString(KEY_VERSION_NAME, version.name).putLong(KEY_VERSION_CODE, version.code).apply()
    }

    fun setBannerPending(pending: Boolean) {
        preferences.edit().putBoolean(KEY_BANNER, pending).apply()
        mutableBanner.value = pending
    }

    companion object {
        const val PREFERENCES = "bridgey.setup"
        const val WHATS_NEW_PREFERENCES = "bridgey.whats_new"
        const val LEGACY_ONBOARDING_PREFERENCES = "bridgey_onboarding"
        const val SETTINGS_PREFERENCES = "bridgey.settings"
        private const val KEY_STATUS = "status"
        private const val KEY_BANNER = "review_banner_pending"
        private const val KEY_EXPLAINED = "explained."
        private const val KEY_SKIPPED = "skipped."
        private const val KEY_LEGACY_COMPLETED = "completed"
        private const val KEY_VERSION_NAME = "version_name"
        private const val KEY_VERSION_CODE = "version_code"
    }
}
