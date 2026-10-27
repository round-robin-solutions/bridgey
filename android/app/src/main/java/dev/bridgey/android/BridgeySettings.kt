package dev.bridgey.android

import android.content.Context
import dev.bridgey.android.folders.ConflictPolicy
import dev.bridgey.android.folders.DEFAULT_PLACE_ID
import dev.bridgey.android.folders.DestinationMode
import dev.bridgey.android.folders.FolderDestination
import dev.bridgey.android.folders.FolderReceiveSettings
import dev.bridgey.android.folders.isPlaceId
import dev.bridgey.android.folders.recentDestinations
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class BridgeyFeature(val key: String, val title: String) {
    CLIPBOARD("clipboard", "Clipboard"),
    FILES("files", "File transfer"),
    NOTIFICATIONS("notifications", "Notification forwarding"),
    BATTERY("battery", "Battery status"),
    FIND_DEVICE("find_device", "Find Device"),
    PING("ping", "Ping"),
    LINKS("links", "Web links"),
    MEDIA("media", "Mac media controls"),
    CALLS("calls", "Calls from Mac"),

    /** Draft, edition only until accepted upstream: this phone may control the Mac. Off by default. */
    REMOTE_INPUT("remote_input_draft1", "Remote control"),

    /**
     * Draft, edition only: this phone may run the actions a Mac allows it (lock, sleep, volume, apps,
     * Shortcuts). On by default here; the Mac is the gate (off by default and granted per phone).
     */
    MAC_ACTIONS("mac_actions_draft1", "Mac actions"),

    /** Draft, edition only: a Mac may ask this phone for a photo; the person takes it. On by default. */
    CAMERA("camera_draft1", "Take photos for the Mac"),

    /**
     * Draft, edition only: the Mac shows this phone's SMS conversations, sends texts and answers SMS
     * notifications. Off by default on every install, including ones from before off-until-chosen.
     */
    SMS("sms_draft1", "Text messages"),
}

internal fun featureEnabledByLegacyPeer(feature: BridgeyFeature): Boolean =
    feature !in setOf(
        BridgeyFeature.CALLS, BridgeyFeature.PING, BridgeyFeature.LINKS, BridgeyFeature.MEDIA,
        BridgeyFeature.REMOTE_INPUT, BridgeyFeature.MAC_ACTIONS, BridgeyFeature.CAMERA, BridgeyFeature.SMS,
    )

/** Features that start off until the person turns them on. */
internal fun featureOnByDefault(feature: BridgeyFeature): Boolean = feature != BridgeyFeature.REMOTE_INPUT && feature != BridgeyFeature.SMS

data class BridgeySettingsState(
    val deviceName: String,
    val globalFeatures: Map<BridgeyFeature, Boolean>,
    val deviceFeatures: Map<String, Map<BridgeyFeature, Boolean>>,
    val notificationApplications: Map<String, String>,
    val disabledNotificationPackages: Set<String>,
    val directCallsEnabled: Boolean,
    /** Automatic clipboard: send on copy, paste on the other device. On by default. */
    val autoClipboardGlobal: Boolean,
    /** Per-device automatic clipboard; absent means it follows [autoClipboardGlobal]. */
    val autoClipboardDevices: Map<String, Boolean>,
    /** Optional background clipboard via READ_LOGS (off by default; advanced, needs ADB setup). */
    val backgroundClipboardEnabled: Boolean,
    /** Clipboard > Copy images and files: offers for images, files and long text. On by default. */
    val clipboardFilesEnabled: Boolean = true,
    /** Clipboard > Send right away up to, in bytes; 0 is "Always ask when pasting". */
    val clipboardEagerLimit: Long = ClipLimits.DEFAULT_EAGER_LIMIT,
    /** Clipboard > Send a fresh screenshot: Send copied item sends a screenshot from the last minute. On by default. */
    val screenshotSendEnabled: Boolean = true,
    /** This phone > Keep Wi-Fi awake: a Wi-Fi lock while connected (Android 13 and older; off by default). */
    val keepWifiAwake: Boolean = false,
    /** Files > Folders sent to this phone (3.2). Synced later with settings sync; per phone for now. */
    val folderMode: DestinationMode = DestinationMode.SENDER_PICKS,
    /** Files > When a folder already exists (3.3). */
    val folderConflict: ConflictPolicy = ConflictPolicy.ASK,
    /** Files > Default folder: a place ID, `default` for Download/Bridgey. Never synced. */
    val folderDefaultPlace: String = DEFAULT_PLACE_ID,
    /**
     * Files > Allow other devices to change files here: phone only, off by default (Rahul, 2026-10-25; widened
     * from "replace" in Files 2.0). Off: a Replace chosen on the other device asks here first, and uploads into
     * places from the Mac's Phone files window are refused (`read_only`). Browsing and downloading need only
     * [allowBrowseFromOtherDevices].
     */
    val allowReplaceFromOtherDevices: Boolean = false,
    /**
     * Files > Let other devices browse this phone: paired devices with File transfer on can list granted
     * places, recent documents and (with photo access) photos and videos, see thumbnails and download.
     * On by default (Rahul, 2026-10-27: "browsing allowed, writing needs the switch"). Advertised as
     * files_browse_draft1.
     */
    val allowBrowseFromOtherDevices: Boolean = true,
    /** The Save to… sheet's recent destinations, newest first. On this phone only. */
    val recentFolderDestinations: List<FolderDestination> = emptyList(),
    /** Privacy > Logging: what reaches Logcat and exported diagnostics. On this phone only. */
    val logging: LoggingPolicy = LoggingPolicy(),
    /** Notifications > Share Do Not Disturb with Macs (focus_sync_draft1). Off by default. */
    val focusShare: Boolean = false,
    /** Notifications > Follow the Mac's Focus: Do Not Disturb follows the Macs. Off by default. */
    val focusFollow: Boolean = false,
    /** Text messages > Send replies as SMS: answers to SMS notifications skip the messaging app's own reply. Off by default. */
    val smsReplyAsSms: Boolean = false,
) {
    /** What a folder transfer to this phone reads when it decides. */
    val folderReceiveSettings: FolderReceiveSettings
        get() = FolderReceiveSettings(folderMode, folderConflict, folderDefaultPlace, allowReplaceFromOtherDevices)
}

/** Automatic clipboard is on for a device when global and the per-device switch both allow it. */
internal fun effectiveAutoClipboardEnabled(
    globalEnabled: Boolean,
    deviceEnabled: Boolean?,
): Boolean = globalEnabled && deviceEnabled != false

internal fun effectiveFeatureEnabled(
    globalEnabled: Boolean,
    deviceEnabled: Boolean?,
): Boolean = globalEnabled && deviceEnabled != false

internal fun effectiveFeatureAvailable(localEnabled: Boolean, remoteEnabled: Boolean): Boolean =
    localEnabled && remoteEnabled

/**
 * [defaultsGeneration]: which defaults a feature without a stored value takes
 * ([dev.bridgey.android.setup.DefaultsGeneration]); stored values always win.
 */
class BridgeySettings(context: Context, defaultDeviceName: String, private val defaultsGeneration: Int = dev.bridgey.android.setup.DefaultsGeneration.FEATURES_ON) {
    private val preferences = context.getSharedPreferences("bridgey.settings", Context.MODE_PRIVATE)
    private val mutableState = MutableStateFlow(load(defaultDeviceName))
    val state: StateFlow<BridgeySettingsState> = mutableState.asStateFlow()

    init {
        BridgeyLogging.policy = mutableState.value.logging
    }

    fun setLogging(policy: LoggingPolicy) {
        preferences.edit().apply {
            loggingPreferenceValues(policy).forEach { (key, value) -> putBoolean(key, value) }
        }.apply()
        BridgeyLogging.policy = policy
        mutableState.value = mutableState.value.copy(logging = policy)
    }

    fun setDeviceName(value: String) {
        val name = value.trim().take(64).ifBlank { "Android device" }
        preferences.edit().putString(KEY_DEVICE_NAME, name).apply()
        mutableState.value = mutableState.value.copy(deviceName = name)
    }

    fun setGlobal(feature: BridgeyFeature, enabled: Boolean) {
        preferences.edit().putBoolean("global.${feature.key}", enabled).apply()
        mutableState.value = mutableState.value.copy(
            globalFeatures = mutableState.value.globalFeatures + (feature to enabled),
        )
    }

    fun setForDevice(deviceId: String, feature: BridgeyFeature, enabled: Boolean) {
        preferences.edit().putBoolean("device.$deviceId.${feature.key}", enabled).apply()
        val current = mutableState.value.deviceFeatures[deviceId].orEmpty() + (feature to enabled)
        mutableState.value = mutableState.value.copy(
            deviceFeatures = mutableState.value.deviceFeatures + (deviceId to current),
        )
    }

    fun isEnabled(feature: BridgeyFeature, deviceId: String?): Boolean {
        val snapshot = mutableState.value
        return effectiveFeatureEnabled(
            globalEnabled = snapshot.globalFeatures[feature] != false,
            deviceEnabled = deviceId?.let { snapshot.deviceFeatures[it]?.get(feature) },
        )
    }

    @Synchronized
    fun observeNotificationApplication(packageName: String, applicationName: String) {
        val safePackage = packageName.take(256)
        val safeName = applicationName.take(128)
        if (safePackage.isBlank() || safeName.isBlank() || mutableState.value.notificationApplications[safePackage] == safeName) return
        preferences.edit().putString("$KEY_NOTIFICATION_APPLICATION_PREFIX$safePackage", safeName).apply()
        mutableState.value = mutableState.value.copy(
            notificationApplications = mutableState.value.notificationApplications + (safePackage to safeName),
        )
    }

    @Synchronized
    fun setNotificationApplicationEnabled(packageName: String, enabled: Boolean) {
        if (!mutableState.value.notificationApplications.containsKey(packageName)) return
        val disabled = if (enabled) {
            mutableState.value.disabledNotificationPackages - packageName
        } else {
            mutableState.value.disabledNotificationPackages + packageName
        }
        preferences.edit().putStringSet(KEY_DISABLED_NOTIFICATION_PACKAGES, disabled).apply()
        mutableState.value = mutableState.value.copy(disabledNotificationPackages = disabled)
    }

    @Synchronized
    fun isNotificationApplicationEnabled(packageName: String): Boolean =
        packageName !in mutableState.value.disabledNotificationPackages

    fun setDirectCallsEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_DIRECT_CALLS_ENABLED, enabled).apply()
        mutableState.value = mutableState.value.copy(directCallsEnabled = enabled)
    }

    fun setAutoClipboardGlobal(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_AUTO_CLIPBOARD_GLOBAL, enabled).apply()
        mutableState.value = mutableState.value.copy(autoClipboardGlobal = enabled)
    }

    fun setAutoClipboardForDevice(deviceId: String, enabled: Boolean) {
        preferences.edit().putBoolean("$KEY_AUTO_CLIPBOARD_DEVICE_PREFIX$deviceId", enabled).apply()
        mutableState.value = mutableState.value.copy(
            autoClipboardDevices = mutableState.value.autoClipboardDevices + (deviceId to enabled),
        )
    }

    fun setBackgroundClipboardEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_BACKGROUND_CLIPBOARD, enabled).apply()
        mutableState.value = mutableState.value.copy(backgroundClipboardEnabled = enabled)
    }

    fun setClipboardFilesEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_CLIPBOARD_FILES, enabled).apply()
        mutableState.value = mutableState.value.copy(clipboardFilesEnabled = enabled)
    }

    fun setClipboardEagerLimit(bytes: Long) {
        val value = bytes.takeIf { it in ClipLimits.EAGER_LIMIT_CHOICES } ?: ClipLimits.DEFAULT_EAGER_LIMIT
        preferences.edit().putLong(KEY_CLIPBOARD_EAGER_LIMIT, value).apply()
        mutableState.value = mutableState.value.copy(clipboardEagerLimit = value)
    }

    fun setScreenshotSendEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_SCREENSHOT_SEND, enabled).apply()
        mutableState.value = mutableState.value.copy(screenshotSendEnabled = enabled)
    }

    fun setKeepWifiAwake(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_KEEP_WIFI_AWAKE, enabled).apply()
        mutableState.value = mutableState.value.copy(keepWifiAwake = enabled)
    }

    fun setFocusShare(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_FOCUS_SHARE, enabled).apply()
        mutableState.value = mutableState.value.copy(focusShare = enabled)
    }

    fun setFocusFollow(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_FOCUS_FOLLOW, enabled).apply()
        mutableState.value = mutableState.value.copy(focusFollow = enabled)
    }

    fun setSmsReplyAsSms(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_SMS_REPLY_AS_SMS, enabled).apply()
        mutableState.value = mutableState.value.copy(smsReplyAsSms = enabled)
    }

    /** Text messages is on for at least one Mac (its global switch). */
    fun smsOn(): Boolean = mutableState.value.globalFeatures[BridgeyFeature.SMS] == true

    fun setFolderMode(mode: DestinationMode) {
        preferences.edit().putString(KEY_FOLDER_MODE, mode.wire).apply()
        mutableState.value = mutableState.value.copy(folderMode = mode)
    }

    fun setFolderConflict(policy: ConflictPolicy) {
        preferences.edit().putString(KEY_FOLDER_CONFLICT, policy.wire).apply()
        mutableState.value = mutableState.value.copy(folderConflict = policy)
    }

    fun setFolderDefaultPlace(placeId: String) {
        val value = placeId.takeIf(::isPlaceId) ?: DEFAULT_PLACE_ID
        preferences.edit().putString(KEY_FOLDER_DEFAULT_PLACE, value).apply()
        mutableState.value = mutableState.value.copy(folderDefaultPlace = value)
    }

    fun setAllowReplaceFromOtherDevices(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_FOLDER_ALLOW_REPLACE, enabled).apply()
        mutableState.value = mutableState.value.copy(allowReplaceFromOtherDevices = enabled)
    }

    fun setAllowBrowseFromOtherDevices(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_FILES_ALLOW_BROWSE, enabled).apply()
        mutableState.value = mutableState.value.copy(allowBrowseFromOtherDevices = enabled)
    }

    @Synchronized
    fun addRecentFolderDestination(destination: FolderDestination) {
        val list = recentDestinations(mutableState.value.recentFolderDestinations, destination)
        preferences.edit().putString(KEY_FOLDER_RECENT, encodeDestinations(list)).apply()
        mutableState.value = mutableState.value.copy(recentFolderDestinations = list)
    }

    /** A removed place leaves the recent list. */
    @Synchronized
    fun forgetPlace(placeId: String) {
        val list = mutableState.value.recentFolderDestinations.filterNot { it.placeId == placeId }
        preferences.edit().putString(KEY_FOLDER_RECENT, encodeDestinations(list)).apply()
        mutableState.value = mutableState.value.copy(recentFolderDestinations = list)
    }

    /** Automatic clipboard for [deviceId], falling back to the global switch when unset. */
    fun isAutoClipboardEnabled(deviceId: String?): Boolean {
        val snapshot = mutableState.value
        return effectiveAutoClipboardEnabled(
            globalEnabled = snapshot.autoClipboardGlobal,
            deviceEnabled = deviceId?.let { snapshot.autoClipboardDevices[it] },
        )
    }

    fun removeDevice(deviceId: String) {
        val editor = preferences.edit()
        BridgeyFeature.entries.forEach { editor.remove("device.$deviceId.${it.key}") }
        editor.remove("$KEY_AUTO_CLIPBOARD_DEVICE_PREFIX$deviceId")
        editor.apply()
        mutableState.value = mutableState.value.copy(
            deviceFeatures = mutableState.value.deviceFeatures - deviceId,
            autoClipboardDevices = mutableState.value.autoClipboardDevices - deviceId,
        )
    }

    private fun load(defaultDeviceName: String): BridgeySettingsState {
        val globals = BridgeyFeature.entries.associateWith {
            preferences.getBoolean("global.${it.key}", dev.bridgey.android.setup.DefaultsGeneration.featureDefault(it, defaultsGeneration))
        }
        val perDevice = mutableMapOf<String, MutableMap<BridgeyFeature, Boolean>>()
        preferences.all.forEach { (key, value) ->
            if (!key.startsWith("device.") || value !is Boolean) return@forEach
            BridgeyFeature.entries.firstOrNull { key.endsWith(".${it.key}") }?.let { feature ->
                val deviceId = key.removePrefix("device.").removeSuffix(".${feature.key}")
                if (deviceId.isNotBlank()) perDevice.getOrPut(deviceId, ::mutableMapOf)[feature] = value
            }
        }
        val notificationApplications = preferences.all.mapNotNull { (key, value) ->
            if (!key.startsWith(KEY_NOTIFICATION_APPLICATION_PREFIX) || value !is String) return@mapNotNull null
            val packageName = key.removePrefix(KEY_NOTIFICATION_APPLICATION_PREFIX)
            if (packageName.isBlank() || value.isBlank()) null else packageName to value
        }.toMap()
        val autoClipboardDevices = preferences.all.mapNotNull { (key, value) ->
            if (!key.startsWith(KEY_AUTO_CLIPBOARD_DEVICE_PREFIX) || value !is Boolean) return@mapNotNull null
            val deviceId = key.removePrefix(KEY_AUTO_CLIPBOARD_DEVICE_PREFIX)
            if (deviceId.isBlank()) null else deviceId to value
        }.toMap()
        return BridgeySettingsState(
            deviceName = preferences.getString(KEY_DEVICE_NAME, null) ?: defaultDeviceName,
            globalFeatures = globals,
            deviceFeatures = perDevice,
            notificationApplications = notificationApplications,
            disabledNotificationPackages = preferences.getStringSet(KEY_DISABLED_NOTIFICATION_PACKAGES, emptySet()).orEmpty(),
            directCallsEnabled = preferences.getBoolean(KEY_DIRECT_CALLS_ENABLED, false),
            autoClipboardGlobal = preferences.getBoolean(KEY_AUTO_CLIPBOARD_GLOBAL, true),
            autoClipboardDevices = autoClipboardDevices,
            backgroundClipboardEnabled = preferences.getBoolean(KEY_BACKGROUND_CLIPBOARD, false),
            clipboardFilesEnabled = preferences.getBoolean(KEY_CLIPBOARD_FILES, true),
            clipboardEagerLimit = preferences.getLong(KEY_CLIPBOARD_EAGER_LIMIT, ClipLimits.DEFAULT_EAGER_LIMIT)
                .takeIf { it in ClipLimits.EAGER_LIMIT_CHOICES } ?: ClipLimits.DEFAULT_EAGER_LIMIT,
            screenshotSendEnabled = preferences.getBoolean(KEY_SCREENSHOT_SEND, true),
            keepWifiAwake = preferences.getBoolean(KEY_KEEP_WIFI_AWAKE, false),
            folderMode = DestinationMode.fromWire(preferences.getString(KEY_FOLDER_MODE, null)) ?: DestinationMode.SENDER_PICKS,
            folderConflict = ConflictPolicy.fromWire(preferences.getString(KEY_FOLDER_CONFLICT, null)) ?: ConflictPolicy.ASK,
            folderDefaultPlace = preferences.getString(KEY_FOLDER_DEFAULT_PLACE, null)?.takeIf(::isPlaceId) ?: DEFAULT_PLACE_ID,
            allowReplaceFromOtherDevices = preferences.getBoolean(KEY_FOLDER_ALLOW_REPLACE, false),
            allowBrowseFromOtherDevices = preferences.getBoolean(KEY_FILES_ALLOW_BROWSE, true),
            recentFolderDestinations = decodeDestinations(preferences.getString(KEY_FOLDER_RECENT, null)),
            logging = loggingPolicyFrom { key, default -> preferences.getBoolean(key, default) },
            focusShare = preferences.getBoolean(KEY_FOCUS_SHARE, false),
            focusFollow = preferences.getBoolean(KEY_FOCUS_FOLLOW, false),
            smsReplyAsSms = preferences.getBoolean(KEY_SMS_REPLY_AS_SMS, false),
        )
    }

    companion object {
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_NOTIFICATION_APPLICATION_PREFIX = "notification.application."
        private const val KEY_DISABLED_NOTIFICATION_PACKAGES = "notification.disabled_packages"
        private const val KEY_DIRECT_CALLS_ENABLED = "calls.direct_enabled"
        private const val KEY_AUTO_CLIPBOARD_GLOBAL = "clipboard.auto.global"
        private const val KEY_AUTO_CLIPBOARD_DEVICE_PREFIX = "clipboard.auto.device."
        private const val KEY_BACKGROUND_CLIPBOARD = "clipboard.background.enabled"
        private const val KEY_CLIPBOARD_FILES = "clipboard.files.enabled"
        private const val KEY_CLIPBOARD_EAGER_LIMIT = "clipboard.files.eager_limit"
        private const val KEY_SCREENSHOT_SEND = "clipboard.screenshot.enabled"
        private const val KEY_KEEP_WIFI_AWAKE = "connection.keep_wifi_awake"
        private const val KEY_FOLDER_MODE = "files.folder_destination"
        private const val KEY_FOLDER_CONFLICT = "files.folder_conflict"
        private const val KEY_FOLDER_DEFAULT_PLACE = "files.folder_default_place"
        private const val KEY_FOLDER_ALLOW_REPLACE = "files.folder_allow_replace"
        private const val KEY_FILES_ALLOW_BROWSE = "files.allow_browse"
        private const val KEY_FOLDER_RECENT = "files.folder_recent"
        private const val KEY_FOCUS_SHARE = "focus.share"
        private const val KEY_FOCUS_FOLLOW = "focus.follow"
        private const val KEY_SMS_REPLY_AS_SMS = "sms.reply_as_sms"
    }
}

internal fun encodeDestinations(list: List<FolderDestination>): String =
    org.json.JSONArray().apply { list.forEach { put(it.toJson()) } }.toString()

internal fun decodeDestinations(json: String?): List<FolderDestination> = runCatching {
    val array = org.json.JSONArray(json ?: return emptyList())
    (0 until minOf(array.length(), 5)).mapNotNull { array.optJSONObject(it)?.let(FolderDestination::parse) }
}.getOrDefault(emptyList())

/** Preference keys of [LoggingPolicy], with their values. */
internal fun loggingPreferenceValues(policy: LoggingPolicy): Map<String, Boolean> = mapOf(
    "logging.connection" to policy.connection,
    "logging.calls" to policy.calls,
    "logging.calls.numbers" to policy.callNumbers,
    "logging.notifications" to policy.notifications,
    "logging.notifications.content" to policy.notificationContent,
    "logging.clipboard" to policy.clipboard,
    "logging.clipboard.previews" to policy.clipboardPreviews,
    "logging.files.names" to policy.fileNames,
    "logging.remote_control" to policy.remoteControl,
)

internal fun loggingPolicyFrom(read: (key: String, default: Boolean) -> Boolean): LoggingPolicy {
    val defaults = loggingPreferenceValues(LoggingPolicy())
    fun value(key: String) = read(key, defaults.getValue(key))
    return LoggingPolicy(
        connection = value("logging.connection"),
        calls = value("logging.calls"),
        callNumbers = value("logging.calls.numbers"),
        notifications = value("logging.notifications"),
        notificationContent = value("logging.notifications.content"),
        clipboard = value("logging.clipboard"),
        clipboardPreviews = value("logging.clipboard.previews"),
        fileNames = value("logging.files.names"),
        remoteControl = value("logging.remote_control"),
    )
}
