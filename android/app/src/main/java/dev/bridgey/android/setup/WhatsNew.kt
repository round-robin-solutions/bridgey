package dev.bridgey.android.setup

/** An installed build: its name (0.6.0-rr.1-beta.9) and build number, which grows with every build. */
data class AppVersion(val name: String, val code: Long)

/** Notes that ship inside the APK, for builds whose name starts with [forVersion] (the stable they build towards). */
data class BundledNotes(val forVersion: String, val notes: String) {
    fun appliesTo(version: AppVersion): Boolean = forVersion.isNotBlank() && version.name.startsWith(forVersion) && notes.isNotBlank()
}

sealed interface WhatsNewDecision {
    /** Nothing to show. [record] is the version to store as seen (fresh install, downgrade), or null. */
    data class None(val record: AppVersion?) : WhatsNewDecision

    /**
     * Show What's new for [version] once. [reviewSetup]: the person updated from a version before
     * setup existed, so it offers Review setup, and appears first as the Home banner. [notes] null:
     * no notes for this build (the screen links to the release page instead).
     */
    data class Show(val version: AppVersion, val notes: String?, val reviewSetup: Boolean) : WhatsNewDecision
}

/** What's new, once after an update. Pure; the caller stores the version when it is dismissed. */
object WhatsNewLogic {
    /**
     * [lastShown]: the version that last showed (or recorded) What's new, null if none ever did.
     * [freshInstall]: nothing was stored before this launch. [legacyUser]: settings or the old
     * onboarding flag were already there when this version first ran.
     */
    fun decide(
        installed: AppVersion,
        lastShown: AppVersion?,
        freshInstall: Boolean,
        legacyUser: Boolean,
        feedNotes: String?,
        bundled: BundledNotes?,
    ): WhatsNewDecision {
        if (lastShown == null) {
            return if (freshInstall || !legacyUser) {
                WhatsNewDecision.None(record = installed)
            } else {
                WhatsNewDecision.Show(installed, notesFor(installed, feedNotes, bundled), reviewSetup = true)
            }
        }
        return when {
            installed.code == lastShown.code -> WhatsNewDecision.None(record = if (installed.name != lastShown.name) installed else null)
            installed.code < lastShown.code -> WhatsNewDecision.None(record = installed)
            else -> WhatsNewDecision.Show(installed, notesFor(installed, feedNotes, bundled), reviewSetup = false)
        }
    }

    /** The feed's notes for this exact build, else the notes bundled for it, else none. */
    fun notesFor(installed: AppVersion, feedNotes: String?, bundled: BundledNotes?): String? =
        feedNotes?.takeIf { it.isNotBlank() } ?: bundled?.takeIf { it.appliesTo(installed) }?.notes
}

/** What the app does at launch about setup. */
data class SetupLaunch(
    val status: SetupStatus,
    /** Show first-run setup now. */
    val showSetup: Boolean,
    /** Nothing was stored before: no banner, no What's new. */
    val freshInstall: Boolean,
    /** Updated from a version before this setup: offer What's new with Review setup once. */
    val legacyUser: Boolean,
)

enum class SetupStatus { NEEDED, DONE, LEGACY }

object SetupLaunchLogic {
    /**
     * [stored]: the status saved by an earlier launch of a setup-era build. [oldOnboardingCompleted]:
     * the pre-v0.10 `bridgey_onboarding.completed` flag. [settingsStored]: any value in the settings
     * file. Existing users are never forced through setup.
     */
    fun decide(stored: SetupStatus?, oldOnboardingCompleted: Boolean, settingsStored: Boolean): SetupLaunch = when (stored) {
        SetupStatus.DONE -> SetupLaunch(SetupStatus.DONE, showSetup = false, freshInstall = false, legacyUser = false)
        SetupStatus.LEGACY -> SetupLaunch(SetupStatus.LEGACY, showSetup = false, freshInstall = false, legacyUser = true)
        SetupStatus.NEEDED -> SetupLaunch(SetupStatus.NEEDED, showSetup = true, freshInstall = false, legacyUser = false)
        null -> if (oldOnboardingCompleted || settingsStored) {
            SetupLaunch(SetupStatus.LEGACY, showSetup = false, freshInstall = false, legacyUser = true)
        } else {
            SetupLaunch(SetupStatus.NEEDED, showSetup = true, freshInstall = true, legacyUser = false)
        }
    }
}
