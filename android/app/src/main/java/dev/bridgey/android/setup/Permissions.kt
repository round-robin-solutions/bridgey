package dev.bridgey.android.setup

/**
 * Every optional permission Bridgey may ask for on Android, in the Settings > Privacy > Permissions
 * order. The copy (name, why, without it) lives in strings_setup.xml under `perm_<key>_*`.
 */
enum class PermissionKind(val key: String) {
    NOTIFICATION_ACCESS("notification_access"),
    POST_NOTIFICATIONS("post_notifications"),
    PHONE_CALLS("phone_calls"),
    PHOTOS("photos"),
    /** v0.9 automation: Take photos for the Mac. */
    CAMERA("camera"),
    COMPANION_LINK("companion_link"),
    /** v0.9 automation: Do Not Disturb access, for Follow the Mac's Focus. */
    DO_NOT_DISTURB("do_not_disturb"),
    BATTERY("battery"),
    INSTALL_PACKAGES("install_packages"),
    SMS("sms"),
    LOGS("logs"),
}

/** The chip on a Permissions row. */
enum class PermissionState { ALLOWED, NOT_ALLOWED, NOT_NEEDED_YET, NOT_ON_THIS_DEVICE }

/** What the phone says right now, read when the app comes to the front. */
data class PermissionFacts(
    val sdkInt: Int,
    /** Betas, nightlies and local builds carry the Code reader test (and its SMS permission). */
    val labBuild: Boolean,
    val granted: Set<PermissionKind>,
    val notificationsOn: Boolean = true,
    val callsOn: Boolean = true,
    val screenshotOn: Boolean = true,
    val backgroundClipboardOn: Boolean = false,
    /** Files 2.0: the attach sheet's Photos and videos tab and Macs browsing this phone's media (Files on). */
    val mediaOn: Boolean = false,
    /** Take photos for the Mac (on by default; Android asks the first time a Mac asks for a photo). */
    val cameraOn: Boolean = true,
    /** Notifications > Focus > Follow the Mac's Focus (off by default). */
    val focusFollowOn: Boolean = false,
)

data class PermissionEntry(val kind: PermissionKind, val state: PermissionState) {
    /** Manage opens the system screen or, when not allowed, the explainer then the request. */
    val offersRequest: Boolean get() = state == PermissionState.NOT_ALLOWED || state == PermissionState.NOT_NEEDED_YET
}

object PermissionCatalog {
    /** Android 15: one-time codes are hidden from apps that are not linked to a nearby device. */
    const val COMPANION_LINK_SDK = 35

    fun entries(facts: PermissionFacts): List<PermissionEntry> =
        PermissionKind.entries
            .filter { it != PermissionKind.SMS || facts.labBuild }
            .map { PermissionEntry(it, state(it, facts)) }

    fun state(kind: PermissionKind, facts: PermissionFacts): PermissionState {
        if (kind == PermissionKind.COMPANION_LINK && facts.sdkInt < COMPANION_LINK_SDK) return PermissionState.NOT_ON_THIS_DEVICE
        if (kind in facts.granted) return PermissionState.ALLOWED
        val needed = when (kind) {
            PermissionKind.NOTIFICATION_ACCESS, PermissionKind.COMPANION_LINK -> facts.notificationsOn
            PermissionKind.PHONE_CALLS -> facts.callsOn
            PermissionKind.PHOTOS -> facts.screenshotOn || facts.mediaOn
            PermissionKind.CAMERA -> facts.cameraOn
            PermissionKind.DO_NOT_DISTURB -> facts.focusFollowOn
            PermissionKind.LOGS -> facts.backgroundClipboardOn
            // Only the Code reader test asks, when it starts.
            PermissionKind.SMS -> false
            PermissionKind.POST_NOTIFICATIONS, PermissionKind.BATTERY, PermissionKind.INSTALL_PACKAGES -> true
        }
        return if (needed) PermissionState.NOT_ALLOWED else PermissionState.NOT_NEEDED_YET
    }

    /** The permission a quick step asks for, so a skipped step shows up on the Permissions page. */
    fun forStep(step: QuickStep): PermissionKind? = when (step) {
        QuickStep.PAIR -> null
        QuickStep.NOTIFICATION_ACCESS -> PermissionKind.NOTIFICATION_ACCESS
        QuickStep.BATTERY -> PermissionKind.BATTERY
    }
}
