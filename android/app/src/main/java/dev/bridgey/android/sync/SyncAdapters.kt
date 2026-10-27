package dev.bridgey.android.sync

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BridgeySettings
import dev.bridgey.android.NotificationAccess
import dev.bridgey.android.folders.ConflictPolicy
import dev.bridgey.android.folders.DestinationMode
import dev.bridgey.android.ui.UiPreferences

/** The feature switch behind each `feature.*` key. */
internal val SyncFeatureKeys: Map<SyncKey, BridgeyFeature> = mapOf(
    SyncKey.CLIPBOARD to BridgeyFeature.CLIPBOARD,
    SyncKey.FILES to BridgeyFeature.FILES,
    SyncKey.NOTIFICATIONS to BridgeyFeature.NOTIFICATIONS,
    SyncKey.BATTERY to BridgeyFeature.BATTERY,
    SyncKey.FIND_DEVICE to BridgeyFeature.FIND_DEVICE,
    SyncKey.PING to BridgeyFeature.PING,
    SyncKey.LINKS to BridgeyFeature.LINKS,
    SyncKey.MEDIA to BridgeyFeature.MEDIA,
    SyncKey.CALLS to BridgeyFeature.CALLS,
    SyncKey.REMOTE_INPUT to BridgeyFeature.REMOTE_INPUT,
    SyncKey.MAC_ACTIONS to BridgeyFeature.MAC_ACTIONS,
    SyncKey.CAMERA to BridgeyFeature.CAMERA,
)

/** What only this phone can allow, per key. Read fresh each time; never synced. */
interface SyncPermissions {
    fun notificationAccess(): Boolean
    fun phoneCalls(): Boolean
    fun camera(): Boolean
    fun doNotDisturb(): Boolean
}

class AndroidSyncPermissions(private val context: Context) : SyncPermissions {
    private fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun notificationAccess(): Boolean = NotificationAccess.isEnabled(context)

    // The same three the Permissions page counts as "Phone calls".
    override fun phoneCalls(): Boolean =
        listOf(Manifest.permission.CALL_PHONE, Manifest.permission.READ_PHONE_STATE, Manifest.permission.ANSWER_PHONE_CALLS).all(::granted)

    override fun camera(): Boolean = granted(Manifest.permission.CAMERA)

    override fun doNotDisturb(): Boolean = context.getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted
}

/**
 * The phone's settings behind the 21 keys. `codes.enabled` has no setting on the phone: it is stored and relayed
 * so two Macs share it. Per-device overrides, grants, paths and the file access guards are not here, so they never
 * sync.
 */
fun phoneSyncedSettings(settings: BridgeySettings, ui: UiPreferences, permissions: SyncPermissions): Map<SyncKey, SyncedSetting> {
    val state = { settings.state.value }
    fun switch(key: String, get: () -> Boolean, set: (Boolean) -> Unit, waiting: () -> Boolean = { false }, stored: () -> Boolean) = object : SyncedSetting {
        override fun read(): Any = get()
        override fun write(value: Any) { if (value is Boolean) set(value) }
        override fun stored(): Boolean = stored.invoke()
        override fun waitingForPermission(): Boolean = get() && waiting()
        override fun toString(): String = key
    }
    val result = LinkedHashMap<SyncKey, SyncedSetting>()
    result[SyncKey.FOLDER_DESTINATION] = object : SyncedSetting {
        override fun read(): Any = state().folderMode.wire
        override fun write(value: Any) { DestinationMode.fromWire(value as? String)?.let(settings::setFolderMode) }
        override fun stored(): Boolean = settings.hasStored(BridgeySettings.KEY_FOLDER_MODE)
    }
    result[SyncKey.FOLDER_CONFLICT] = object : SyncedSetting {
        override fun read(): Any = state().folderConflict.wire
        override fun write(value: Any) { ConflictPolicy.fromWire(value as? String)?.let(settings::setFolderConflict) }
        override fun stored(): Boolean = settings.hasStored(BridgeySettings.KEY_FOLDER_CONFLICT)
    }
    result[SyncKey.ACTIVITY_PREVIEWS] = switch(
        "previews", { ui.showPreviews.value }, ui::setShowPreviews, stored = { ui.hasStored(UiPreferences.KEY_SHOW_PREVIEWS) },
    )
    result[SyncKey.REDUCE_MOTION] = switch(
        "reduce_motion", { ui.reduceMotion.value }, ui::setReduceMotion, stored = { ui.hasStored(UiPreferences.KEY_REDUCE_MOTION) },
    )
    SyncFeatureKeys.forEach { (key, feature) ->
        val waiting: () -> Boolean = when (key) {
            SyncKey.NOTIFICATIONS -> { { !permissions.notificationAccess() } }
            SyncKey.CALLS -> { { !permissions.phoneCalls() } }
            SyncKey.CAMERA -> { { !permissions.camera() } }
            else -> { { false } }
        }
        result[key] = switch(
            key.token, { state().globalFeatures[feature] != false }, { settings.setGlobal(feature, it) }, waiting,
            stored = { settings.hasStored("global.${feature.key}") },
        )
    }
    result[SyncKey.AUTO_CLIPBOARD] = switch(
        "auto_clipboard", { state().autoClipboardGlobal }, settings::setAutoClipboardGlobal,
        stored = { settings.hasStored(BridgeySettings.KEY_AUTO_CLIPBOARD_GLOBAL) },
    )
    result[SyncKey.CLIPBOARD_FILES] = switch(
        "clipboard_files", { state().clipboardFilesEnabled }, settings::setClipboardFilesEnabled,
        stored = { settings.hasStored(BridgeySettings.KEY_CLIPBOARD_FILES) },
    )
    result[SyncKey.FOCUS_SHARE] = switch(
        "focus_share", { state().focusShare }, settings::setFocusShare, stored = { settings.hasStored(BridgeySettings.KEY_FOCUS_SHARE) },
    )
    result[SyncKey.FOCUS_FOLLOW] = switch(
        "focus_follow", { state().focusFollow }, settings::setFocusFollow, { !permissions.doNotDisturb() },
        stored = { settings.hasStored(BridgeySettings.KEY_FOCUS_FOLLOW) },
    )
    return result
}
