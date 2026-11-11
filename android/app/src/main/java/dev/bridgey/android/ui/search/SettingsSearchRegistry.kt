package dev.bridgey.android.ui.search

import android.content.Context
import androidx.annotation.StringRes
import androidx.compose.ui.graphics.vector.ImageVector
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.R
import dev.bridgey.android.agents.AgentGrant
import dev.bridgey.android.agents.grantTitle
import dev.bridgey.android.setup.PermissionKind
import dev.bridgey.android.setup.ResetChoice
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.sync.SyncUiState
import dev.bridgey.android.ui.BridgeyIcons
import dev.bridgey.android.ui.Route
import dev.bridgey.android.ui.SettingsSection
import dev.bridgey.android.ui.Tint
import dev.bridgey.android.ui.settingsRoute
import dev.bridgey.android.ui.syncKeyFor
import dev.bridgey.android.ui.syncKeyName

/**
 * The pages Settings search can open: every Settings section plus the sub-pages reached from it. [parent] is
 * the page above it in the breadcrumb ("Privacy › Permissions").
 */
enum class SearchPage(@StringRes val titleRes: Int, val icon: () -> ImageVector, val tint: Tint, val parent: SearchPage? = null) {
    HOME(R.string.settings_title, { BridgeyIcons.Smartphone }, Tint.BLUE),
    DEVICES(R.string.settings_search_devices, { BridgeyIcons.Devices }, Tint.BLUE),
    AWAY(R.string.settings_connect_away, { BridgeyIcons.Public }, Tint.BLUE, DEVICES),
    CLIPBOARD(R.string.feature_clipboard, { BridgeyIcons.ContentPaste }, Tint.BLUE),
    NOTIFICATIONS(R.string.settings_notifications, { BridgeyIcons.Notifications }, Tint.PURPLE),
    MESSAGES(R.string.feature_sms, { BridgeyIcons.Sms }, Tint.GREEN),
    CALLS(R.string.feature_calls, { BridgeyIcons.Call }, Tint.GREEN),
    FILES(R.string.feature_files, { BridgeyIcons.Folder }, Tint.GREEN),
    MEDIA(R.string.settings_media, { BridgeyIcons.MusicNote }, Tint.BLUE),
    REMOTE_CONTROL(R.string.settings_remote_control, { BridgeyIcons.Mouse }, Tint.PURPLE),
    PRIVACY(R.string.settings_privacy, { BridgeyIcons.Shield }, Tint.BLUE),
    PERMISSIONS(R.string.perm_page_title, { BridgeyIcons.Shield }, Tint.BLUE, PRIVACY),
    RESET(R.string.reset_title, { BridgeyIcons.Delete }, Tint.NEUTRAL, PRIVACY),
    UPDATES(R.string.settings_updates, { BridgeyIcons.SystemUpdate }, Tint.PURPLE),
    GENERAL(R.string.settings_general, { BridgeyIcons.Settings }, Tint.NEUTRAL),
    ABOUT(R.string.settings_about, { BridgeyIcons.Info }, Tint.NEUTRAL),
    DEVELOPER(R.string.settings_developer, { BridgeyIcons.DeveloperMode }, Tint.PURPLE),
    ;

    /** The page's screen. */
    val route: Route
        get() = when (this) {
            HOME -> Route.Settings
            DEVICES -> Route.Devices
            PERMISSIONS -> Route.Permissions
            RESET -> Route.Reset
            AWAY -> settingsRoute(SettingsSection.AWAY)
            CLIPBOARD -> settingsRoute(SettingsSection.CLIPBOARD)
            NOTIFICATIONS -> settingsRoute(SettingsSection.NOTIFICATIONS)
            MESSAGES -> settingsRoute(SettingsSection.MESSAGES)
            CALLS -> settingsRoute(SettingsSection.CALLS)
            FILES -> settingsRoute(SettingsSection.FILES)
            MEDIA -> settingsRoute(SettingsSection.MEDIA)
            REMOTE_CONTROL -> settingsRoute(SettingsSection.REMOTE_CONTROL)
            PRIVACY -> settingsRoute(SettingsSection.PRIVACY)
            UPDATES -> settingsRoute(SettingsSection.UPDATES)
            GENERAL -> settingsRoute(SettingsSection.GENERAL)
            ABOUT -> settingsRoute(SettingsSection.ABOUT)
            DEVELOPER -> settingsRoute(SettingsSection.DEVELOPER)
        }
}

/**
 * One settings row as search knows it, kept beside the settings it names. [title] is the row's own title (the
 * text it shows, or its searchTitle when the shown title changes with state); [keywords] are hand-written
 * synonyms in English and Russian, matched whatever the app's language. A row whose value syncs names its
 * [syncKey], so it is found as synced and by its sync status ("waiting for permission").
 */
data class SettingsSearchEntry(
    val id: String,
    val page: SearchPage,
    @StringRes val section: Int?,
    @StringRes val title: Int,
    @StringRes val subtitle: Int?,
    val keywords: List<String> = emptyList(),
    val developerOnly: Boolean = false,
    val syncKey: SyncKey? = null,
)

/** A paired device, for the per-device pages search can open. */
data class SearchDevice(val id: String, val name: String, val isAgent: Boolean)

/** One row search can offer, resolved in the current language from an entry or a paired device. */
data class SearchResultEntry(
    val id: String,
    /** The page heading results are grouped under: the page, or a device's name. */
    val group: String,
    val icon: ImageVector,
    val tint: Tint,
    val title: String,
    val subtitle: String?,
    /** "Notifications › Codes from messages", "Devices › OnePlus 11 › Permissions". */
    val breadcrumb: String,
    val doc: SearchDoc,
    val route: Route,
    /** The row to scroll to and highlight; null opens the page only. */
    val rowTitle: String?,
)

/** The separator in breadcrumbs: a single right-pointing angle quotation mark with spaces. */
const val CRUMB = " › "

/** Settings search's registry: every row on every Settings page. The drift test keeps it in step with the pages. */
object SettingsSearchRegistry {
    // Synonyms, matched in either language. Keep them in step with the Mac (SettingsSearchRegistry.swift).
    private val CODES = listOf(
        "otp", "one-time code", "one time password", "2fa", "verification code", "sms code", "login code",
        "код", "одноразовый код", "код подтверждения", "смс-код",
    )
    private val CODES_EMAIL = listOf("email", "gmail", "mail", "почта")
    private val AWAY_WORDS = listOf(
        "hotspot", "relay", "tailscale", "tailnet", "vpn", "internet", "mobile data", "cellular", "4g", "5g", "away", "outside",
        "точка доступа", "ретранслятор", "удалённо", "мобильный интернет", "sign in", "login", "войти", "private network", "частная сеть",
    )
    private val UPDATE_WORDS = listOf("update", "upgrade", "version", "beta", "channel", "release", "обновление", "версия", "бета")
    private val CLIPBOARD_WORDS = listOf("copy", "paste", "universal clipboard", "копировать", "вставить", "буфер обмена")
    private val NOTIFICATION_WORDS = listOf("alerts", "mirror", "уведомления", "оповещения")
    private val SMS_WORDS = listOf("sms", "texts", "mms", "смс", "сообщения")
    private val CALL_WORDS = listOf("phone", "dial", "звонок", "вызов")
    private val FILE_WORDS = listOf("send file", "airdrop", "share", "transfer", "folder", "файлы", "передача")
    private val MEDIA_WORDS = listOf("music", "spotify", "play", "pause", "volume", "музыка", "громкость")
    private val FIND_WORDS = listOf("ring", "lost", "locate", "найти")
    private val PING_WORDS = listOf("alert", "пинг")
    private val BATTERY_WORDS = listOf("charge", "power", "low battery", "батарея", "заряд")
    private val REMOTE_WORDS = listOf("mouse", "trackpad", "touchpad", "keyboard", "slides", "presentation", "мышь", "клавиатура", "презентация")
    private val PREVIEW_WORDS = listOf("privacy", "preview", "превью")
    private val ACTIVITY_WORDS = listOf("history", "история")
    private val LOG_WORDS = listOf("logs", "debug", "diagnostics", "логи", "журнал")
    private val MOTION_WORDS = listOf("animation", "motion", "accessibility", "анимация")
    private val NAME_WORDS = listOf("rename", "name", "имя", "переименовать")
    private val SYNC_WORDS = listOf("sync", "same settings", "синхронизация")
    private val PAIR_WORDS = listOf("pair", "add device", "connect", "qr", "сопряжение", "добавить устройство")
    private val FORGET_WORDS = listOf("unpair", "remove device", "забыть")
    private val BACKGROUND_WORDS = listOf("battery saver", "doze", "background", "sleep", "фон", "энергосбережение")
    private val FOCUS_WORDS = listOf("do not disturb", "dnd", "не беспокоить")
    private val RESET_WORDS = listOf("erase", "factory", "clear data", "сброс")
    private val DEVELOPER_WORDS = listOf("debug", "speed test", "perf")
    private val TURN_OFF_WORDS = listOf("quit", "stop", "disable", "выключить")

    /** Synced rows also answer to these, plus the setting's sync name. */
    private val SYNCED_WORDS = listOf("sync", "synced", "синхронизация")

    private fun feature(id: String, page: SearchPage, title: Int, subtitle: Int, feature: BridgeyFeature, keywords: List<String>) =
        SettingsSearchEntry(id, page, null, title, subtitle, keywords, syncKey = syncKeyFor(feature))

    val entries: List<SettingsSearchEntry> = listOf(
        // Settings home
        SettingsSearchEntry("home.thisPhone", SearchPage.HOME, null, R.string.settings_this_phone, null, NAME_WORDS + listOf("device name")),

        // Devices and permissions
        SettingsSearchEntry("devices.away", SearchPage.DEVICES, null, R.string.settings_connect_away, R.string.connect_away_detail),
        SettingsSearchEntry("devices.lookAgain", SearchPage.DEVICES, null, R.string.look_again, R.string.look_again_detail, listOf("refresh", "discover", "найти устройства")),
        SettingsSearchEntry("devices.pair", SearchPage.DEVICES, null, R.string.devices_pair_new, R.string.devices_pair_new_detail, PAIR_WORDS),

        // Connect away from home
        SettingsSearchEntry("away.switch", SearchPage.AWAY, null, R.string.settings_connect_away, R.string.connect_away_detail, AWAY_WORDS, syncKey = SyncKey.CONNECT_AWAY),
        SettingsSearchEntry("away.status", SearchPage.AWAY, null, R.string.connect_status, null, listOf("online", "relay", "в сети")),
        SettingsSearchEntry("away.reset", SearchPage.AWAY, null, R.string.connect_reset, R.string.connect_reset_detail, listOf("identity", "relay")),

        // Clipboard
        feature("clipboard.switch", SearchPage.CLIPBOARD, R.string.feature_clipboard, R.string.feature_clipboard_detail, BridgeyFeature.CLIPBOARD, CLIPBOARD_WORDS),
        SettingsSearchEntry("clipboard.auto", SearchPage.CLIPBOARD, null, R.string.auto_clipboard_title, R.string.auto_clipboard_detail, CLIPBOARD_WORDS, syncKey = SyncKey.AUTO_CLIPBOARD),
        SettingsSearchEntry("clipboard.files", SearchPage.CLIPBOARD, null, R.string.clipboard_files_title, R.string.clipboard_files_detail, listOf("images", "photos", "картинки"), syncKey = SyncKey.CLIPBOARD_FILES),
        SettingsSearchEntry("clipboard.eager", SearchPage.CLIPBOARD, null, R.string.clipboard_eager_title, R.string.clipboard_eager_detail, listOf("size", "limit", "mb", "размер")),
        SettingsSearchEntry("clipboard.screenshot", SearchPage.CLIPBOARD, null, R.string.screenshot_send_title, R.string.screenshot_send_detail, listOf("screenshot", "скриншот")),
        SettingsSearchEntry("clipboard.background", SearchPage.CLIPBOARD, null, R.string.bg_clipboard_title, R.string.bg_clipboard_detail, listOf("adb", "background", "фон")),
        SettingsSearchEntry("clipboard.tile", SearchPage.CLIPBOARD, null, R.string.settings_tile, R.string.settings_tile_detail, listOf("quick settings", "tile", "плитка")),

        // Notifications
        SettingsSearchEntry("notifications.switch", SearchPage.NOTIFICATIONS, null, R.string.settings_forwarding_title, R.string.settings_notifications_detail, NOTIFICATION_WORDS, syncKey = SyncKey.NOTIFICATIONS),
        SettingsSearchEntry("notifications.access", SearchPage.NOTIFICATIONS, null, R.string.perm_notification_access_name, R.string.perm_notification_access_why, NOTIFICATION_WORDS),
        SettingsSearchEntry("notifications.apps", SearchPage.NOTIFICATIONS, null, R.string.settings_notification_apps, null, listOf("apps", "mute", "приложения")),
        SettingsSearchEntry("notifications.codes", SearchPage.NOTIFICATIONS, R.string.codes_title, R.string.codes_title, null, CODES),
        SettingsSearchEntry("notifications.codesLink", SearchPage.NOTIFICATIONS, R.string.codes_title, R.string.codes_link, R.string.codes_link_detail, CODES + listOf("bluetooth", "companion")),
        SettingsSearchEntry("notifications.codesEmail", SearchPage.NOTIFICATIONS, R.string.codes_title, R.string.codes_email, R.string.codes_email_detail, CODES + CODES_EMAIL, syncKey = SyncKey.EMAIL_CODES),
        SettingsSearchEntry("notifications.codesCloud", SearchPage.NOTIFICATIONS, R.string.codes_title, R.string.codes_cloud, R.string.codes_cloud_detail, CODES + listOf("cloud", "облако")),
        SettingsSearchEntry("notifications.bridgey", SearchPage.NOTIFICATIONS, null, R.string.settings_app_notifications, null, NOTIFICATION_WORDS),
        SettingsSearchEntry("notifications.focusShare", SearchPage.NOTIFICATIONS, R.string.focus_section, R.string.focus_share_title, R.string.focus_share_detail, FOCUS_WORDS, syncKey = SyncKey.FOCUS_SHARE),
        SettingsSearchEntry("notifications.focusFollow", SearchPage.NOTIFICATIONS, R.string.focus_section, R.string.focus_follow_title, R.string.focus_follow_detail, FOCUS_WORDS, syncKey = SyncKey.FOCUS_FOLLOW),
        SettingsSearchEntry("notifications.focusAccess", SearchPage.NOTIFICATIONS, R.string.focus_section, R.string.focus_access_title, null, FOCUS_WORDS),

        // Text messages
        feature("messages.switch", SearchPage.MESSAGES, R.string.feature_sms, R.string.feature_sms_detail, BridgeyFeature.SMS, SMS_WORDS),
        SettingsSearchEntry("messages.smsAccess", SearchPage.MESSAGES, null, R.string.messages_sms_access, null, SMS_WORDS),
        SettingsSearchEntry("messages.contacts", SearchPage.MESSAGES, null, R.string.messages_contacts_access, null, listOf("names", "контакты")),
        SettingsSearchEntry("messages.sims", SearchPage.MESSAGES, null, R.string.messages_sims_access, null, listOf("dual sim", "sim", "сим")),
        SettingsSearchEntry("messages.replyAsSms", SearchPage.MESSAGES, null, R.string.messages_reply_as_sms, R.string.messages_reply_as_sms_detail, SMS_WORDS),

        // Calls
        feature("calls.switch", SearchPage.CALLS, R.string.feature_calls, R.string.settings_calls_detail, BridgeyFeature.CALLS, CALL_WORDS),
        SettingsSearchEntry("calls.direct", SearchPage.CALLS, null, R.string.devices_direct_calls, R.string.devices_direct_calls_detail, CALL_WORDS + listOf("answer", "decline", "ответить")),

        // Files
        feature("files.switch", SearchPage.FILES, R.string.feature_files, R.string.feature_files_detail, BridgeyFeature.FILES, FILE_WORDS),
        SettingsSearchEntry("files.foldersMode", SearchPage.FILES, null, R.string.settings_folders_mode, null, FILE_WORDS + listOf("save", "where", "сохранять"), syncKey = SyncKey.FOLDER_DESTINATION),
        SettingsSearchEntry("files.defaultFolder", SearchPage.FILES, null, R.string.settings_default_folder, null, listOf("download", "save", "папка")),
        SettingsSearchEntry("files.conflict", SearchPage.FILES, null, R.string.settings_folder_conflict, null, listOf("merge", "replace", "conflict", "заменить"), syncKey = SyncKey.FOLDER_CONFLICT),
        SettingsSearchEntry("files.browse", SearchPage.FILES, null, R.string.settings_allow_browse, R.string.settings_allow_browse_detail, listOf("browse", "phone files", "просмотр")),
        SettingsSearchEntry("files.replace", SearchPage.FILES, null, R.string.settings_allow_replace, R.string.settings_allow_replace_detail, listOf("overwrite", "replace")),
        SettingsSearchEntry("files.hidden", SearchPage.FILES, null, R.string.settings_folder_hidden, R.string.settings_folder_hidden_detail, listOf("dotfiles", "hidden", "скрытые"), syncKey = SyncKey.FOLDER_INCLUDE_HIDDEN),
        SettingsSearchEntry("files.system", SearchPage.FILES, null, R.string.settings_folder_system, R.string.settings_folder_system_detail, listOf("ds_store", "thumbs.db", "системные"), syncKey = SyncKey.FOLDER_INCLUDE_SYSTEM),
        SettingsSearchEntry("files.places", SearchPage.FILES, null, R.string.settings_places, null, listOf("storage", "sd card", "folders", "места")),

        // Media and quick actions
        feature("media.media", SearchPage.MEDIA, R.string.feature_media, R.string.settings_media_detail, BridgeyFeature.MEDIA, MEDIA_WORDS),
        feature("media.macActions", SearchPage.MEDIA, R.string.feature_mac_actions, R.string.settings_mac_actions_detail, BridgeyFeature.MAC_ACTIONS, listOf("lock", "sleep", "shortcuts", "заблокировать")),
        feature("media.camera", SearchPage.MEDIA, R.string.feature_camera, R.string.settings_camera_detail, BridgeyFeature.CAMERA, listOf("camera", "photo", "камера", "фото")),
        feature("media.screen", SearchPage.MEDIA, R.string.feature_screen, R.string.settings_screen_detail, BridgeyFeature.SCREEN, listOf("screen sharing", "mirror", "экран")),
        feature("media.links", SearchPage.MEDIA, R.string.feature_links, R.string.feature_links_detail, BridgeyFeature.LINKS, listOf("url", "browser", "ссылки")),
        feature("media.ping", SearchPage.MEDIA, R.string.feature_ping, R.string.settings_ping_detail, BridgeyFeature.PING, PING_WORDS),
        feature("media.find", SearchPage.MEDIA, R.string.feature_find, R.string.settings_find_detail, BridgeyFeature.FIND_DEVICE, FIND_WORDS),
        feature("media.battery", SearchPage.MEDIA, R.string.feature_battery, R.string.settings_battery_detail, BridgeyFeature.BATTERY, BATTERY_WORDS),

        SettingsSearchEntry("share.when", SearchPage.MEDIA, null, R.string.share_when, R.string.share_auto,
            listOf("share", "send", "mac", "always ask", "отправить")),

        // Remote control
        feature("remote.switch", SearchPage.REMOTE_CONTROL, R.string.feature_remote_input, R.string.settings_remote_detail, BridgeyFeature.REMOTE_INPUT, REMOTE_WORDS),
        SettingsSearchEntry("remote.speed", SearchPage.REMOTE_CONTROL, null, R.string.remote_speed_title, null, REMOTE_WORDS + listOf("pointer", "cursor", "скорость")),
        SettingsSearchEntry("remote.volumeKeys", SearchPage.REMOTE_CONTROL, null, R.string.remote_volume_keys_title, R.string.remote_volume_keys_detail, listOf("volume", "slides", "громкость")),

        // Privacy
        SettingsSearchEntry("privacy.previews", SearchPage.PRIVACY, null, R.string.settings_show_previews, R.string.settings_show_previews_detail, PREVIEW_WORDS, syncKey = SyncKey.ACTIVITY_PREVIEWS),
        SettingsSearchEntry("privacy.activity", SearchPage.PRIVACY, null, R.string.settings_activity, R.string.settings_activity_detail, ACTIVITY_WORDS),
        SettingsSearchEntry("privacy.permissions", SearchPage.PRIVACY, null, R.string.perm_page_title, R.string.perm_page_detail, listOf("permissions", "access", "разрешения")),
        SettingsSearchEntry("privacy.reset", SearchPage.PRIVACY, null, R.string.reset_title, R.string.reset_detail, RESET_WORDS),
        SettingsSearchEntry("privacy.logConnection", SearchPage.PRIVACY, null, R.string.logging_connection, R.string.logging_connection_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logCalls", SearchPage.PRIVACY, null, R.string.logging_calls, R.string.logging_calls_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logCallNumbers", SearchPage.PRIVACY, null, R.string.logging_call_numbers, R.string.logging_call_numbers_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logNotifications", SearchPage.PRIVACY, null, R.string.logging_notifications, R.string.logging_notifications_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logNotificationContent", SearchPage.PRIVACY, null, R.string.logging_notification_content, R.string.logging_notification_content_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logClipboard", SearchPage.PRIVACY, null, R.string.logging_clipboard, R.string.logging_clipboard_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logClipboardPreviews", SearchPage.PRIVACY, null, R.string.logging_clipboard_previews, R.string.logging_clipboard_previews_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logFileNames", SearchPage.PRIVACY, null, R.string.logging_file_names, R.string.logging_file_names_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logRemote", SearchPage.PRIVACY, null, R.string.logging_remote, R.string.logging_remote_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.diagnostics", SearchPage.PRIVACY, null, R.string.settings_diagnostics, R.string.settings_diagnostics_detail, LOG_WORDS + listOf("export", "report", "bug")),
        SettingsSearchEntry("privacy.clearLogs", SearchPage.PRIVACY, null, R.string.logging_clear, R.string.logging_clear_detail, LOG_WORDS),

        // Updates
        SettingsSearchEntry("updates.status", SearchPage.UPDATES, null, R.string.settings_search_check_updates, null, UPDATE_WORDS),
        SettingsSearchEntry("updates.channel", SearchPage.UPDATES, null, R.string.updates_channel, R.string.updates_channel_note, UPDATE_WORDS + listOf("stable", "nightly", "стабильный")),
        SettingsSearchEntry("updates.auto", SearchPage.UPDATES, null, R.string.update_auto_title, R.string.update_auto_detail, UPDATE_WORDS + listOf("automatic", "автоматически"), syncKey = SyncKey.AUTO_UPDATE_ALL),
        SettingsSearchEntry("updates.devices", SearchPage.UPDATES, null, R.string.update_all_devices_title, null, UPDATE_WORDS + listOf("update all", "mac")),
        SettingsSearchEntry("updates.remoteStart", SearchPage.UPDATES, null, R.string.update_all_remote_start_title, R.string.update_all_remote_start_detail, UPDATE_WORDS),

        // General
        SettingsSearchEntry("general.background", SearchPage.GENERAL, null, R.string.settings_background_title, null, BACKGROUND_WORDS),
        SettingsSearchEntry("general.wifiAwake", SearchPage.GENERAL, null, R.string.settings_wifi_awake_title, R.string.settings_wifi_awake_detail, listOf("wifi", "wi-fi", "sleep", "вайфай")),
        SettingsSearchEntry("general.oem", SearchPage.GENERAL, null, R.string.settings_search_oem, null, BACKGROUND_WORDS + listOf("autostart", "oneplus", "xiaomi", "samsung", "автозапуск")),
        SettingsSearchEntry("general.sync", SearchPage.GENERAL, null, R.string.settings_sync_title, R.string.settings_sync_detail, SYNC_WORDS),
        SettingsSearchEntry("general.syncChoose", SearchPage.GENERAL, null, R.string.settings_sync_choose, null, SYNC_WORDS),
        SettingsSearchEntry("general.reduceMotion", SearchPage.GENERAL, null, R.string.settings_reduce_motion, R.string.settings_reduce_motion_detail, MOTION_WORDS, syncKey = SyncKey.REDUCE_MOTION),
        SettingsSearchEntry("general.turnOff", SearchPage.GENERAL, null, R.string.settings_turn_off, R.string.settings_turn_off_detail, TURN_OFF_WORDS),
        SettingsSearchEntry("general.runSetup", SearchPage.GENERAL, null, R.string.setup_run_again, R.string.setup_run_again_detail, listOf("setup", "onboarding", "настройка")),

        // About
        SettingsSearchEntry("about.version", SearchPage.ABOUT, null, R.string.settings_version, null, UPDATE_WORDS),
        SettingsSearchEntry("about.licences", SearchPage.ABOUT, null, R.string.settings_licences, R.string.settings_licences_detail, listOf("license", "open source", "лицензии")),
        SettingsSearchEntry("about.obtainium", SearchPage.ABOUT, null, R.string.obtainium_title, null, UPDATE_WORDS + listOf("obtainium")),

        // Privacy › Permissions (one row per permission). Sub-pages come after the main pages, so on equal scores
        // the main page's row is offered first.
        SettingsSearchEntry("permissions.notificationAccess", SearchPage.PERMISSIONS, null, R.string.perm_notification_access_name, R.string.perm_notification_access_why, NOTIFICATION_WORDS),
        SettingsSearchEntry("permissions.postNotifications", SearchPage.PERMISSIONS, null, R.string.perm_post_notifications_name, R.string.perm_post_notifications_why),
        SettingsSearchEntry("permissions.phoneCalls", SearchPage.PERMISSIONS, null, R.string.perm_phone_calls_name, R.string.perm_phone_calls_why, CALL_WORDS),
        SettingsSearchEntry("permissions.photos", SearchPage.PERMISSIONS, null, R.string.perm_photos_name, R.string.perm_photos_why, listOf("gallery", "галерея")),
        SettingsSearchEntry("permissions.camera", SearchPage.PERMISSIONS, null, R.string.perm_camera_name, R.string.perm_camera_why),
        SettingsSearchEntry("permissions.companionLink", SearchPage.PERMISSIONS, null, R.string.perm_companion_link_name, R.string.perm_companion_link_why, CODES + listOf("bluetooth")),
        SettingsSearchEntry("permissions.dnd", SearchPage.PERMISSIONS, null, R.string.perm_do_not_disturb_name, R.string.perm_do_not_disturb_why, FOCUS_WORDS),
        SettingsSearchEntry("permissions.battery", SearchPage.PERMISSIONS, null, R.string.perm_battery_name, R.string.perm_battery_why, BACKGROUND_WORDS),
        SettingsSearchEntry("permissions.install", SearchPage.PERMISSIONS, null, R.string.perm_install_packages_name, R.string.perm_install_packages_why, UPDATE_WORDS),
        SettingsSearchEntry("permissions.sms", SearchPage.PERMISSIONS, null, R.string.perm_sms_name, R.string.perm_sms_why, SMS_WORDS),
        SettingsSearchEntry("permissions.contacts", SearchPage.PERMISSIONS, null, R.string.perm_contacts_name, R.string.perm_contacts_why),
        SettingsSearchEntry("permissions.logs", SearchPage.PERMISSIONS, null, R.string.perm_logs_name, R.string.perm_logs_why, listOf("adb")),

        // Privacy › Reset Bridgey on this device
        SettingsSearchEntry("reset.activity", SearchPage.RESET, null, R.string.reset_choice_activity, R.string.reset_choice_activity_summary, RESET_WORDS),
        SettingsSearchEntry("reset.caches", SearchPage.RESET, null, R.string.reset_choice_caches, R.string.reset_choice_caches_summary, RESET_WORDS + listOf("cache", "storage", "кэш")),
        SettingsSearchEntry("reset.settings", SearchPage.RESET, null, R.string.reset_choice_settings, R.string.reset_choice_settings_summary, RESET_WORDS),
        SettingsSearchEntry("reset.everything", SearchPage.RESET, null, R.string.reset_choice_everything, R.string.reset_choice_everything_summary, RESET_WORDS),

        // Developer and experimental (only while the menu is on)
        SettingsSearchEntry("developer.speed", SearchPage.DEVELOPER, R.string.developer_tools, R.string.settings_speed_test, R.string.settings_speed_test_detail, DEVELOPER_WORDS, developerOnly = true),
        SettingsSearchEntry("developer.perf", SearchPage.DEVELOPER, R.string.developer_tools, R.string.perf_title, R.string.developer_perf_detail, DEVELOPER_WORDS, developerOnly = true),
        SettingsSearchEntry("developer.hide", SearchPage.DEVELOPER, null, R.string.developer_turn_off, R.string.developer_turn_off_detail, DEVELOPER_WORDS, developerOnly = true),
    )

    /** Per-device pages: the permission rows in their page's order, with the features behind each. */
    val devicePermissionRows: List<Pair<Int, List<BridgeyFeature>>> = listOf(
        R.string.feature_clipboard to listOf(BridgeyFeature.CLIPBOARD),
        R.string.auto_clipboard_title to listOf(BridgeyFeature.CLIPBOARD),
        R.string.feature_files to listOf(BridgeyFeature.FILES),
        R.string.feature_notifications to listOf(BridgeyFeature.NOTIFICATIONS),
        R.string.feature_sms to listOf(BridgeyFeature.SMS),
        R.string.feature_calls to listOf(BridgeyFeature.CALLS),
        R.string.feature_media to listOf(BridgeyFeature.MEDIA),
        R.string.feature_remote_input to listOf(BridgeyFeature.REMOTE_INPUT),
        R.string.feature_mac_actions to listOf(BridgeyFeature.MAC_ACTIONS),
        R.string.feature_camera to listOf(BridgeyFeature.CAMERA),
        R.string.feature_screen to listOf(BridgeyFeature.SCREEN),
        R.string.feature_find_ping to listOf(BridgeyFeature.FIND_DEVICE, BridgeyFeature.PING),
        R.string.feature_links to listOf(BridgeyFeature.LINKS),
        R.string.feature_battery to listOf(BridgeyFeature.BATTERY),
        R.string.devices_sync_title to emptyList(),
    )

    private fun featureWords(features: List<BridgeyFeature>): List<String> = features.flatMap {
        when (it) {
            BridgeyFeature.CLIPBOARD -> CLIPBOARD_WORDS
            BridgeyFeature.NOTIFICATIONS -> NOTIFICATION_WORDS
            BridgeyFeature.SMS -> SMS_WORDS
            BridgeyFeature.CALLS -> CALL_WORDS
            BridgeyFeature.FILES -> FILE_WORDS
            BridgeyFeature.MEDIA -> MEDIA_WORDS
            BridgeyFeature.FIND_DEVICE -> FIND_WORDS
            BridgeyFeature.PING -> PING_WORDS
            BridgeyFeature.BATTERY -> BATTERY_WORDS
            BridgeyFeature.REMOTE_INPUT -> REMOTE_WORDS
            else -> emptyList()
        }
    }

    private fun Context.crumb(page: SearchPage): List<String> = (page.parent?.let { crumb(it) } ?: emptyList()) + getString(page.titleRes)

    /** Names for "Different on Work Mac", "Different on Work Mac +1". */
    private fun Context.deviceList(names: List<String>): String =
        if (names.size == 1) names.first() else getString(R.string.settings_sync_devices_more, names.first(), names.size - 1)

    /**
     * Everything search can offer now, in the current language: the registry (developer rows only while
     * [developerMenu] is on), with synced rows marked and their sync status, then each paired device's page.
     */
    fun resolve(context: Context, developerMenu: Boolean, sync: SyncUiState, devices: List<SearchDevice>): List<SearchResultEntry> {
        val out = mutableListOf<SearchResultEntry>()
        for (entry in entries) {
            if (entry.developerOnly && !developerMenu) continue
            if (entry.page == SearchPage.MESSAGES && !dev.bridgey.android.BuildGates.sms) continue
            if (entry.page == SearchPage.UPDATES && !dev.bridgey.android.BuildGates.selfUpdate) continue
            if (entry.id in setOf("permissions.sms", "permissions.contacts") && !dev.bridgey.android.BuildGates.sms) continue
            if (entry.id == "permissions.install" && !dev.bridgey.android.BuildGates.selfUpdate) continue
            val page = context.getString(entry.page.titleRes)
            val section = entry.section?.let(context::getString)
            val title = context.getString(entry.title)
            val description = entry.subtitle?.let(context::getString)
            var subtitle = description
            val keywords = entry.keywords.toMutableList()
            entry.syncKey?.takeIf(sync::syncs)?.let { key ->
                keywords += SYNCED_WORDS
                keywords += syncKeyName(context, key)
                sync.row(key)?.let { status ->
                    val lines = buildList {
                        if (status.waitingHere) add(context.getString(R.string.settings_sync_waiting_here))
                        if (status.differentOn.isNotEmpty()) add(context.getString(R.string.settings_sync_different, context.deviceList(status.differentOn)))
                        if (status.waitingOn.isNotEmpty()) add(context.getString(R.string.settings_sync_needs_permission_on, context.deviceList(status.waitingOn)))
                    }
                    if (lines.isNotEmpty()) {
                        // The status replaces the description in the result; the description still matches.
                        description?.let { keywords += it }
                        subtitle = lines.joinToString(". ")
                    }
                }
            }
            val crumbs = context.crumb(entry.page) + listOfNotNull(section?.takeIf { it != title })
            out += SearchResultEntry(
                id = entry.id,
                group = page,
                icon = entry.page.icon(),
                tint = entry.page.tint,
                title = title,
                subtitle = subtitle,
                breadcrumb = crumbs.joinToString(CRUMB),
                doc = SearchDoc(title, subtitle, section, context.crumb(entry.page).joinToString(" "), keywords),
                route = entry.page.route,
                rowTitle = title,
            )
        }
        out += devices.flatMap { deviceEntries(context, it) }
        return out
    }

    /**
     * A paired device's page, found by its name: the page itself, then its permission rows ("Devices › OnePlus 11 ›
     * Permissions"). An agent (the bridgey command on a server) lists its grants instead.
     */
    fun deviceEntries(context: Context, device: SearchDevice): List<SearchResultEntry> {
        val devicesTitle = context.getString(SearchPage.DEVICES.titleRes)
        val permissions = context.getString(R.string.device_tab_permissions)
        val route = Route.Device(device.id)
        val icon = if (device.isAgent) BridgeyIcons.Terminal else BridgeyIcons.Devices
        val page = SearchResultEntry(
            id = "device.${device.id}",
            group = device.name,
            icon = icon,
            tint = Tint.BLUE,
            title = device.name,
            subtitle = permissions,
            breadcrumb = devicesTitle,
            doc = SearchDoc(device.name, null, null, devicesTitle, listOf("device", "permissions", "устройство", "разрешения") + FORGET_WORDS),
            route = route,
            rowTitle = null,
        )
        val rows: List<Pair<String, List<String>>> = if (device.isAgent) {
            AgentGrant.entries.map { grantTitle(context, it) to listOf("agent", "server", "агент", "сервер") } +
                (context.getString(R.string.agent_trust_row) to listOf("trust", "доверять"))
        } else {
            devicePermissionRows.filter { (_, features) -> features.all(dev.bridgey.android.BuildGates::featureBuilt) }.map { (res, features) ->
                context.getString(res) to (featureWords(features) + if (features.isEmpty()) SYNC_WORDS else emptyList())
            }
        }
        val crumb = listOf(devicesTitle, device.name, permissions).joinToString(CRUMB)
        return listOf(page) + rows.mapIndexed { index, (title, words) ->
            SearchResultEntry(
                id = "device.${device.id}.$index",
                group = device.name,
                icon = icon,
                tint = Tint.BLUE,
                title = title,
                subtitle = null,
                breadcrumb = crumb,
                doc = SearchDoc(title, null, permissions, "$devicesTitle ${device.name}", words + device.name),
                route = route,
                rowTitle = title,
            )
        }
    }

    /** The permission kinds the Permissions page can list, for the drift test. */
    val permissionKinds: List<PermissionKind> = PermissionKind.entries

    /** The reset choices, for the drift test. */
    val resetChoices: List<ResetChoice> = ResetChoice.entries
}
