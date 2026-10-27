package dev.bridgey.android.codes

import android.content.Context

/** A connected Mac that reads codes, as the link picker lists it. */
data class CodeLinkMac(val deviceId: String, val name: String)

/**
 * Which Mac "Link this phone to the Mac" uses. The picked Mac wins while it is still connected and
 * reads codes, then the selected Mac, then the first one (what the coordinator picked before).
 */
object CodeLinkTargets {
    fun current(macs: List<CodeLinkMac>, picked: String?, selected: String?): CodeLinkMac? =
        macs.firstOrNull { it.deviceId == picked }
            ?: macs.firstOrNull { it.deviceId == selected }
            ?: macs.firstOrNull()

    /** Two or more Macs read codes: ask which one before linking. */
    fun needsPicker(macs: List<CodeLinkMac>): Boolean = macs.size >= 2
}

/**
 * The Mac this phone was last linked to, recorded when a link succeeds (Android's companion
 * association does not say which Bridgey Mac it was). In `bridgey_codes`, next to the code access flag.
 */
class CodeLinkRecord(context: Context) {
    private val preferences = context.getSharedPreferences("bridgey_codes", Context.MODE_PRIVATE)

    fun linked(): CodeLinkMac? {
        val id = preferences.getString(KEY_ID, null) ?: return null
        return CodeLinkMac(id, preferences.getString(KEY_NAME, null).orEmpty())
    }

    fun save(mac: CodeLinkMac) {
        preferences.edit().putString(KEY_ID, mac.deviceId).putString(KEY_NAME, mac.name.take(64)).apply()
    }

    private companion object {
        const val KEY_ID = "linked_mac_id"
        const val KEY_NAME = "linked_mac_name"
    }
}
