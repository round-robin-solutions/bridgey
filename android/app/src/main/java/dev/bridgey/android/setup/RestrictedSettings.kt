package dev.bridgey.android.setup

/**
 * Android 13 "restricted settings": an app installed from a file or a browser cannot turn on Notification
 * access (or Accessibility) until the person opens App info, taps the three dots and chooses Allow
 * restricted settings. Android does not tell the app it was blocked, so the block is guessed from what
 * can be seen: the special access screen was opened and Bridgey is back with nothing granted.
 */
object RestrictedSettings {
    /** Android 13 (API 33), where restricted settings start. */
    const val FIRST_SDK = 33

    /**
     * The permissions Android can block this way. Accessibility joins when phone control ships
     * (docs/screen-control-decision.md); it has no row on the Permissions page yet.
     */
    private val kinds = setOf(PermissionKind.NOTIFICATION_ACCESS)

    fun canBeBlocked(kind: PermissionKind, sdkInt: Int): Boolean = sdkInt >= FIRST_SDK && kind in kinds

    /** [asked]: its system screen was opened; [granted]: it is allowed now. Asked and still not allowed may be a block. */
    fun mayBeBlocked(kind: PermissionKind, sdkInt: Int, asked: Boolean, granted: Boolean): Boolean =
        canBeBlocked(kind, sdkInt) && asked && !granted
}
