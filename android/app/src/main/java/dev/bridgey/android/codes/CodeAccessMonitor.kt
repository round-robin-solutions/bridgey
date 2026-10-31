package dev.bridgey.android.codes

import android.app.AppOpsManager
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.res.Resources
import android.os.Build
import android.os.Process
import android.provider.Telephony
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether Android shows Bridgey the text of code messages. Fed by the notification listener (every
 * SMS notification from the default SMS app) and refreshed when the app returns to the front.
 * Stores one flag only: whether the last telling SMS was hidden. Never any text.
 */
class CodeAccessMonitor(private val context: Context) {
    private val preferences = context.getSharedPreferences("bridgey_codes", Context.MODE_PRIVATE)
    private val mutableStatus = MutableStateFlow(compute())
    val status: StateFlow<CodeAccessStatus> = mutableStatus.asStateFlow()

    /** SMS notifications seen since the app started, and how many Android hid (Code reader test). */
    val smsSeen = AtomicInteger()
    val smsHidden = AtomicInteger()

    /** Mail-app notifications seen since the app started, and how many Android hid (codes from email). */
    val emailSeen = AtomicInteger()
    val emailHidden = AtomicInteger()

    /** Android's own placeholder in the phone's language, read once. */
    val redactedPlaceholder: String? by lazy { systemRedactedPlaceholder() }

    /** A system string has no R id to use, so it is looked up by name. */
    @android.annotation.SuppressLint("DiscouragedApi")
    private fun systemRedactedPlaceholder(): String? = runCatching {
        val system = Resources.getSystem()
        val id = system.getIdentifier("redacted_notification_message", "string", "android")
        if (id != 0) system.getString(id) else null
    }.getOrNull()

    fun defaultSmsPackage(): String? = runCatching { Telephony.Sms.getDefaultSmsPackage(context) }.getOrNull()

    /**
     * An SMS notification reached the listener. Hidden text proves Android hides codes; full text that
     * the pattern says holds a code proves Bridgey can see them. Anything else tells nothing.
     */
    fun observeSms(redacted: Boolean, text: String) {
        smsSeen.incrementAndGet()
        if (redacted) smsHidden.incrementAndGet()
        val evidence = when {
            redacted -> true
            PatternBaseline.extract(text) != null -> false
            else -> return
        }
        recordEvidence(evidence)
    }

    /**
     * A notification from a supported mail app reached the listener. Hidden text counts like a hidden SMS (the
     * companion link lifts both). A visible mail is no proof either way: Android may simply not have seen a code
     * in it, and mail is noisier than SMS, so only the hidden case is recorded.
     */
    fun observeEmail(redacted: Boolean) {
        emailSeen.incrementAndGet()
        if (!redacted) return
        emailHidden.incrementAndGet()
        recordEvidence(hidden = true)
    }

    private fun recordEvidence(hidden: Boolean) {
        if (preferences.getInt(KEY_LAST, UNKNOWN) != (if (hidden) HIDDEN else VISIBLE)) {
            preferences.edit().putInt(KEY_LAST, if (hidden) HIDDEN else VISIBLE).apply()
        }
        refresh()
    }

    /** A new companion link: earlier evidence no longer says anything. */
    fun linkChanged() {
        preferences.edit().remove(KEY_LAST).apply()
        refresh()
    }

    fun refresh() {
        val next = compute()
        if (mutableStatus.value != next) mutableStatus.value = next
    }

    fun isLinked(): Boolean = runCatching {
        val manager = context.getSystemService(CompanionDeviceManager::class.java) ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.myAssociations.isNotEmpty()
        } else {
            @Suppress("DEPRECATION")
            manager.associations.isNotEmpty()
        }
    }.getOrDefault(false)

    /** The one-time ADB command's app-op (Android 15 and later). */
    fun appOpAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return false
        return runCatching {
            @Suppress("DEPRECATION")
            context.getSystemService(AppOpsManager::class.java)
                .unsafeCheckOpNoThrow(OP_RECEIVE_SENSITIVE_NOTIFICATIONS, Process.myUid(), context.packageName) == AppOpsManager.MODE_ALLOWED
        }.getOrDefault(false)
    }

    private fun compute(): CodeAccessStatus {
        val last = when (preferences.getInt(KEY_LAST, UNKNOWN)) {
            HIDDEN -> true
            VISIBLE -> false
            else -> null
        }
        return codeAccessStatus(Build.VERSION.SDK_INT, isLinked(), appOpAllowed(), last)
    }

    private companion object {
        const val KEY_LAST = "last_sms_hidden"
        const val UNKNOWN = -1
        const val VISIBLE = 0
        const val HIDDEN = 1
        const val OP_RECEIVE_SENSITIVE_NOTIFICATIONS = "android:receive_sensitive_notifications"
    }
}
