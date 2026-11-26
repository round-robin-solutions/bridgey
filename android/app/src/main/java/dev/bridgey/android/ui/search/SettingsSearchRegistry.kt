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
import dev.bridgey.android.ui.DeviceChoices
import dev.bridgey.android.ui.Route
import dev.bridgey.android.ui.SettingsCard
import dev.bridgey.android.ui.SettingsGroup
import dev.bridgey.android.ui.cardTitle
import dev.bridgey.android.ui.Tint
import dev.bridgey.android.ui.settingsRoute
import dev.bridgey.android.ui.syncKeyFor
import dev.bridgey.android.ui.syncKeyName

/**
 * The pages Settings search can open: the six group pages, and the Permissions and Reset pages reached from Privacy.
 * [parent] is the page above it in the breadcrumb ("Privacy › Permissions").
 */
enum class SearchPage(@StringRes val titleRes: Int, val icon: () -> ImageVector, val tint: Tint, val parent: SearchPage? = null) {
    DEVICES(R.string.settings_group_devices, { BridgeyIcons.Devices }, Tint.BLUE),
    SHARING(R.string.settings_group_sharing, { BridgeyIcons.IosShare }, Tint.BLUE),
    PHONE(R.string.settings_group_phone, { BridgeyIcons.Notifications }, Tint.PURPLE),
    CONTROL(R.string.settings_group_control, { BridgeyIcons.AdsClick }, Tint.GREEN),
    PRIVACY(R.string.settings_group_privacy, { BridgeyIcons.Shield }, Tint.BLUE),
    APP(R.string.settings_group_app, { BridgeyIcons.Settings }, Tint.NEUTRAL),
    PERMISSIONS(R.string.perm_page_title, { BridgeyIcons.Shield }, Tint.BLUE, PRIVACY),
    RESET(R.string.reset_title, { BridgeyIcons.Delete }, Tint.NEUTRAL, PRIVACY),
    ;

    /** The page's screen. */
    val route: Route
        get() = when (this) {
            PERMISSIONS -> Route.Permissions
            RESET -> Route.Reset
            else -> settingsRoute(group!!)
        }

    /** The Settings group this page is, for the six group pages. */
    val group: SettingsGroup?
        get() = when (this) {
            DEVICES -> SettingsGroup.DEVICES
            SHARING -> SettingsGroup.SHARING
            PHONE -> SettingsGroup.PHONE
            CONTROL -> SettingsGroup.CONTROL
            PRIVACY -> SettingsGroup.PRIVACY
            APP -> SettingsGroup.APP
            PERMISSIONS, RESET -> null
        }

    val place: SearchPlace get() = SearchPlace(this)

    companion object {
        fun of(group: SettingsGroup): SearchPage = entries.first { it.group == group }
    }
}

/** Where a row is: a card on a group page (inside its More options when [more]), or a sub-page. */
data class SearchPlace(val page: SearchPage, val card: SettingsCard? = null, val more: Boolean = false)

/** A row in this card's main part. */
val SettingsCard.place: SearchPlace get() = SearchPlace(SearchPage.of(group), this)

/** A row in this card's More options: a result opens them first. */
val SettingsCard.more: SearchPlace get() = SearchPlace(SearchPage.of(group), this, more = true)

/**
 * One settings row as search knows it, kept beside the settings it names. [title] is the row's own title (the
 * text it shows, or its searchTitle when the shown title changes with state); [keywords] are hand-written
 * synonyms in English and Russian, matched whatever the app's language. A row whose value syncs names its
 * [syncKey], so it is found as synced and by its sync status ("waiting for permission").
 */
data class SettingsSearchEntry(
    val id: String,
    val place: SearchPlace,
    @StringRes val section: Int?,
    @StringRes val title: Int,
    @StringRes val subtitle: Int?,
    val keywords: List<String> = emptyList(),
    val developerOnly: Boolean = false,
    val syncKey: SyncKey? = null,
    /**
     * The switch that shows this row when it is hidden (Files for the folder options): a result whose row is not on
     * the page now highlights that switch instead, so the jump never lands on nothing.
     */
    @StringRes val revealedBy: Int? = null,
    /** The card [revealedBy] sits in, when not this row's own (Codes from messages shows while Notification forwarding is on). */
    val revealedIn: SettingsCard? = null,
) {
    val page: SearchPage get() = place.page
}

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
    /** "Notifications and calls › Codes from messages", "Sharing › Clipboard › OnePlus 11". */
    val breadcrumb: String,
    val doc: SearchDoc,
    val route: Route,
    /** The row to scroll to and highlight; null opens the page only. */
    val rowTitle: String?,
    /** The row to highlight when [rowTitle] is hidden in the page's current state (its feature is off). */
    val fallbackTitle: String? = null,
    /** The device whose chip or row it is, on a page that repeats a title per device. */
    val scope: String? = null,
    /** The card (SettingsCard.key) whose More options hold the row. */
    val expand: String? = null,
    /** The card the fallback switch sits in, when not the row's own. */
    val fallbackScope: String? = scope,
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
    private val DIALER_WORDS = CALL_WORDS + listOf("dialer", "keypad", "whatsapp", "contacts", "sim", "клавиатура", "контакты", "набор")
    private val FILE_WORDS = listOf("send file", "airdrop", "share", "transfer", "transfers", "folder", "файлы", "передача", "передачи")
    private val MEDIA_WORDS = listOf("music", "spotify", "play", "pause", "volume", "музыка", "громкость")
    private val MAC_ACTION_WORDS = listOf("lock", "sleep", "shortcuts", "заблокировать")
    private val CAMERA_WORDS = listOf("camera", "photo", "камера", "фото")
    private val SHARE_SCREEN_WORDS = listOf("screen sharing", "mirror", "экран")
    private val LINK_WORDS = listOf("url", "browser", "ссылки")
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
    private val PHONE_CONTROL_WORDS = listOf(
        "control phone", "Bridgey control", "accessibility", "tap from Mac", "type from Mac", "unattended", "remote control phone",
        "управление телефоном", "специальные возможности", "печатать с Mac",
    )
    private val SCREEN_CONTROL_WORDS = listOf("Mac screen", "screen sharing", "view Mac", "remote desktop", "экран Mac", "удалённый рабочий стол")

    /** Synced rows also answer to these, plus the setting's sync name. */
    private val SYNCED_WORDS = listOf("sync", "synced", "синхронизация")

    private fun feature(id: String, place: SearchPlace, title: Int, subtitle: Int, feature: BridgeyFeature, keywords: List<String>) =
        SettingsSearchEntry(id, place, null, title, subtitle, keywords, syncKey = syncKeyFor(feature))

    val entries: List<SettingsSearchEntry> = listOf(
        // Settings home
        SettingsSearchEntry("home.thisPhone", SettingsCard.THIS_PHONE.place, null, R.string.settings_this_phone, null, NAME_WORDS + listOf("device name")),

        // Devices and permissions
        SettingsSearchEntry("devices.lookAgain", SettingsCard.PAIRED.place, null, R.string.look_again, R.string.look_again_detail, listOf("refresh", "discover", "найти устройства")),
        SettingsSearchEntry("devices.pair", SettingsCard.PAIRED.place, null, R.string.devices_pair_new, R.string.devices_pair_new_detail, PAIR_WORDS),

        // Connect away from home
        SettingsSearchEntry("away.switch", SettingsCard.AWAY.place, null, R.string.settings_connect_away, R.string.connect_away_detail, AWAY_WORDS, syncKey = SyncKey.CONNECT_AWAY),
        SettingsSearchEntry("away.status", SettingsCard.AWAY.place, null, R.string.connect_status, null, listOf("online", "relay", "в сети"), revealedBy = R.string.settings_connect_away),
        SettingsSearchEntry("away.reset", SettingsCard.AWAY.more, null, R.string.connect_reset, R.string.connect_reset_detail, listOf("identity", "relay"), revealedBy = R.string.settings_connect_away),
        // Was the Devices page's row to Connect away from home: now the same card, so one result with the switch's words.
        SettingsSearchEntry("devices.away", SettingsCard.AWAY.place, null, R.string.settings_connect_away, R.string.connect_away_detail),

        // Clipboard
        feature("clipboard.switch", SettingsCard.CLIPBOARD.place, R.string.feature_clipboard, R.string.feature_clipboard_detail, BridgeyFeature.CLIPBOARD, CLIPBOARD_WORDS),
        SettingsSearchEntry("clipboard.auto", SettingsCard.CLIPBOARD.place, null, R.string.auto_clipboard_title, R.string.auto_clipboard_detail, CLIPBOARD_WORDS, syncKey = SyncKey.AUTO_CLIPBOARD),
        SettingsSearchEntry("clipboard.files", SettingsCard.CLIPBOARD.place, null, R.string.clipboard_files_title, R.string.clipboard_files_detail, listOf("images", "photos", "картинки"), syncKey = SyncKey.CLIPBOARD_FILES),
        SettingsSearchEntry("clipboard.eager", SettingsCard.CLIPBOARD.more, null, R.string.clipboard_eager_title, R.string.clipboard_eager_detail, listOf("size", "limit", "mb", "размер")),
        SettingsSearchEntry("clipboard.screenshot", SettingsCard.CLIPBOARD.more, null, R.string.screenshot_send_title, R.string.screenshot_send_detail, listOf("screenshot", "скриншот")),
        SettingsSearchEntry("clipboard.background", SettingsCard.CLIPBOARD.more, null, R.string.bg_clipboard_title, R.string.bg_clipboard_detail, listOf("adb", "background", "фон")),
        SettingsSearchEntry("clipboard.tile", SettingsCard.CLIPBOARD.more, null, R.string.settings_tile, R.string.settings_tile_detail, listOf("quick settings", "tile", "плитка")),

        // Notifications
        SettingsSearchEntry("notifications.switch", SettingsCard.NOTIFICATIONS.place, null, R.string.settings_forwarding_title, R.string.settings_notifications_detail, NOTIFICATION_WORDS, syncKey = SyncKey.NOTIFICATIONS),
        SettingsSearchEntry("notifications.access", SettingsCard.NOTIFICATIONS.place, null, R.string.perm_notification_access_name, R.string.perm_notification_access_why, NOTIFICATION_WORDS, revealedBy = R.string.settings_forwarding_title),
        SettingsSearchEntry("notifications.apps", SettingsCard.NOTIFICATIONS.place, null, R.string.settings_notification_apps, null, listOf("apps", "mute", "приложения"), revealedBy = R.string.settings_forwarding_title),
        SettingsSearchEntry("notifications.codes", SettingsCard.CODES.place, R.string.codes_title, R.string.codes_title, null, CODES, revealedBy = R.string.settings_forwarding_title, revealedIn = SettingsCard.NOTIFICATIONS),
        SettingsSearchEntry("notifications.codesLink", SettingsCard.CODES.place, R.string.codes_title, R.string.codes_link, R.string.codes_link_detail, CODES + listOf("bluetooth", "companion"), revealedBy = R.string.settings_forwarding_title, revealedIn = SettingsCard.NOTIFICATIONS),
        SettingsSearchEntry("notifications.codesEmail", SettingsCard.CODES.place, R.string.codes_title, R.string.codes_email, R.string.codes_email_detail, CODES + CODES_EMAIL, syncKey = SyncKey.EMAIL_CODES, revealedBy = R.string.settings_forwarding_title, revealedIn = SettingsCard.NOTIFICATIONS),
        SettingsSearchEntry("notifications.codesCloud", SettingsCard.CODES.more, R.string.codes_title, R.string.codes_cloud, R.string.codes_cloud_detail, CODES + listOf("cloud", "облако"), revealedBy = R.string.settings_forwarding_title, revealedIn = SettingsCard.NOTIFICATIONS),
        SettingsSearchEntry("notifications.bridgey", SettingsCard.NOTIFICATIONS.more, null, R.string.settings_app_notifications, null, NOTIFICATION_WORDS),
        SettingsSearchEntry("notifications.focusShare", SettingsCard.FOCUS.place, R.string.focus_section, R.string.focus_share_title, R.string.focus_share_detail, FOCUS_WORDS, syncKey = SyncKey.FOCUS_SHARE),
        SettingsSearchEntry("notifications.focusFollow", SettingsCard.FOCUS.place, R.string.focus_section, R.string.focus_follow_title, R.string.focus_follow_detail, FOCUS_WORDS, syncKey = SyncKey.FOCUS_FOLLOW),
        SettingsSearchEntry("notifications.focusAccess", SettingsCard.FOCUS.place, R.string.focus_section, R.string.focus_access_title, null, FOCUS_WORDS, revealedBy = R.string.focus_share_title),

        // Text messages
        feature("messages.switch", SettingsCard.MESSAGES.place, R.string.feature_sms, R.string.feature_sms_detail, BridgeyFeature.SMS, SMS_WORDS),
        SettingsSearchEntry("messages.smsAccess", SettingsCard.MESSAGES.place, null, R.string.messages_sms_access, null, SMS_WORDS, revealedBy = R.string.feature_sms),
        SettingsSearchEntry("messages.contacts", SettingsCard.MESSAGES.more, null, R.string.messages_contacts_access, null, listOf("names", "контакты"), revealedBy = R.string.feature_sms),
        SettingsSearchEntry("messages.sims", SettingsCard.MESSAGES.more, null, R.string.messages_sims_access, null, listOf("dual sim", "sim", "сим"), revealedBy = R.string.feature_sms),
        SettingsSearchEntry("messages.replyAsSms", SettingsCard.MESSAGES.place, null, R.string.messages_reply_as_sms, R.string.messages_reply_as_sms_detail, SMS_WORDS, revealedBy = R.string.feature_sms),

        // Calls
        feature("calls.switch", SettingsCard.CALLS.place, R.string.feature_calls, R.string.settings_calls_detail, BridgeyFeature.CALLS, CALL_WORDS),
        SettingsSearchEntry("calls.direct", SettingsCard.CALLS.place, null, R.string.devices_direct_calls, R.string.devices_direct_calls_detail, CALL_WORDS + listOf("answer", "decline", "ответить"), revealedBy = R.string.feature_calls),
        feature("calls.quiet", SettingsCard.CALL_QUIET.place, R.string.call_quiet_title, R.string.call_quiet_detail, BridgeyFeature.CALL_QUIET, CALL_WORDS + MEDIA_WORDS + listOf("mute", "pause", "без звука")),
        SettingsSearchEntry("calls.quiet.mode", SettingsCard.CALL_QUIET.place, null, R.string.call_quiet_mode, null, CALL_WORDS + MEDIA_WORDS, revealedBy = R.string.call_quiet_title),
        SettingsSearchEntry("calls.quiet.after", SettingsCard.CALL_QUIET.place, null, R.string.call_quiet_after, null, CALL_WORDS + listOf("resume", "restore", "возобновить"), revealedBy = R.string.call_quiet_title),
        SettingsSearchEntry("calls.quiet.phone", SettingsCard.CALL_QUIET.more, null, R.string.call_quiet_phone_state, null, CALL_WORDS, revealedBy = R.string.call_quiet_title),
        SettingsSearchEntry("calls.quiet.access", SettingsCard.CALL_QUIET.more, null, R.string.call_quiet_access, null, MEDIA_WORDS, revealedBy = R.string.call_quiet_title),
        SettingsSearchEntry("calls.quiet.status", SettingsCard.CALL_QUIET.more, null, R.string.call_quiet_status, null, CALL_WORDS + MEDIA_WORDS, revealedBy = R.string.call_quiet_title),
        SettingsSearchEntry("calls.quiet.peers", SettingsCard.CALL_QUIET.more, null, R.string.call_quiet_peers, null, CALL_WORDS + MEDIA_WORDS, revealedBy = R.string.call_quiet_title),
        feature("calls.window", SettingsCard.CALLS_WINDOW.place, R.string.dialer_title, R.string.dialer_detail, BridgeyFeature.DIALER, DIALER_WORDS),
        SettingsSearchEntry("calls.window.place", SettingsCard.CALLS_WINDOW.place, R.string.dialer_title, R.string.dialer_place_access, null, DIALER_WORDS, revealedBy = R.string.dialer_title),
        SettingsSearchEntry("calls.window.callLog", SettingsCard.CALLS_WINDOW.more, R.string.dialer_title, R.string.perm_call_log_name, null, DIALER_WORDS + listOf("recent", "history", "недавние"), revealedBy = R.string.dialer_title),
        SettingsSearchEntry("calls.window.askFirst", SettingsCard.CALLS_WINDOW.place, R.string.dialer_title, R.string.dialer_ask_first, R.string.dialer_ask_first_detail, DIALER_WORDS + listOf("confirm", "tap", "подтвердить"), revealedBy = R.string.dialer_title),
        SettingsSearchEntry("calls.window.contacts", SettingsCard.CALLS_WINDOW.more, R.string.dialer_title, R.string.perm_contacts_name, null, DIALER_WORDS + listOf("names", "имена"), revealedBy = R.string.dialer_title),

        // Files
        feature("files.switch", SettingsCard.FILES.place, R.string.feature_files, R.string.feature_files_detail, BridgeyFeature.FILES, FILE_WORDS),
        SettingsSearchEntry("files.autoResume", SettingsCard.FILES.place, null, R.string.settings_auto_resume, null, FILE_WORDS + listOf("resume", "interrupted", "retry", "продолжать", "прерванные"), revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.foldersMode", SettingsCard.FILES.place, null, R.string.settings_folders_mode, null, FILE_WORDS + listOf("save", "where", "сохранять"), syncKey = SyncKey.FOLDER_DESTINATION, revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.defaultFolder", SettingsCard.FILES.more, null, R.string.settings_default_folder, null, listOf("download", "save", "папка"), revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.conflict", SettingsCard.FILES.more, null, R.string.settings_folder_conflict, null, listOf("merge", "replace", "conflict", "заменить"), syncKey = SyncKey.FOLDER_CONFLICT, revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.browse", SettingsCard.FILES.more, null, R.string.settings_allow_browse, R.string.settings_allow_browse_detail, listOf("browse", "phone files", "просмотр"), revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.replace", SettingsCard.FILES.more, null, R.string.settings_allow_replace, R.string.settings_allow_replace_detail, listOf("overwrite", "replace"), revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.hidden", SettingsCard.FILES.more, null, R.string.settings_folder_hidden, R.string.settings_folder_hidden_detail, listOf("dotfiles", "hidden", "скрытые"), syncKey = SyncKey.FOLDER_INCLUDE_HIDDEN, revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.system", SettingsCard.FILES.more, null, R.string.settings_folder_system, R.string.settings_folder_system_detail, listOf("ds_store", "thumbs.db", "системные"), syncKey = SyncKey.FOLDER_INCLUDE_SYSTEM, revealedBy = R.string.feature_files),
        SettingsSearchEntry("files.places", SettingsCard.FILES.more, null, R.string.settings_places, null, listOf("storage", "sd card", "folders", "места"), revealedBy = R.string.feature_files),

        SettingsSearchEntry("notifications.smartRouting", SettingsCard.NOTIFICATIONS.more, null, R.string.smart_routing_title, R.string.smart_routing_detail, listOf("active Mac", "situational awareness", "duplicate alerts", "notification routing")),
        SettingsSearchEntry("notifications.preferredMac", SettingsCard.NOTIFICATIONS.more, null, R.string.smart_routing_preferred, null, listOf("default Mac", "preferred device", "fallback", "destination")),

        // Media and quick actions
        feature("media.media", SettingsCard.MEDIA.place, R.string.feature_media, R.string.settings_media_detail, BridgeyFeature.MEDIA, MEDIA_WORDS),
        feature("media.macActions", SettingsCard.MAC_ACTIONS.place, R.string.feature_mac_actions, R.string.settings_mac_actions_detail, BridgeyFeature.MAC_ACTIONS, MAC_ACTION_WORDS),
        feature("media.camera", SettingsCard.CAMERA.place, R.string.feature_camera, R.string.settings_camera_detail, BridgeyFeature.CAMERA, CAMERA_WORDS),
        feature("media.screen", SettingsCard.SHARE_SCREEN.place, R.string.feature_screen, R.string.settings_screen_detail, BridgeyFeature.SCREEN, SHARE_SCREEN_WORDS),
        feature("media.links", SettingsCard.LINKS.place, R.string.feature_links, R.string.feature_links_detail, BridgeyFeature.LINKS, LINK_WORDS),
        feature("media.ping", SettingsCard.FIND_PING.place, R.string.feature_ping, R.string.settings_ping_detail, BridgeyFeature.PING, PING_WORDS),
        feature("media.find", SettingsCard.FIND_PING.place, R.string.feature_find, R.string.settings_find_detail, BridgeyFeature.FIND_DEVICE, FIND_WORDS),
        feature("media.battery", SettingsCard.BATTERY.place, R.string.feature_battery, R.string.settings_battery_detail, BridgeyFeature.BATTERY, BATTERY_WORDS),

        SettingsSearchEntry("share.when", SettingsCard.FILES.more, null, R.string.share_when, R.string.share_auto,
            listOf("share", "send", "device", "always ask", "отправить", "устройство")),

        // Remote control
        feature("remote.switch", SettingsCard.REMOTE.place, R.string.feature_remote_input, R.string.settings_remote_detail, BridgeyFeature.REMOTE_INPUT, REMOTE_WORDS),
        SettingsSearchEntry("remote.speed", SettingsCard.REMOTE.place, null, R.string.remote_speed_title, null, REMOTE_WORDS + listOf("pointer", "cursor", "скорость"), revealedBy = R.string.feature_remote_input),
        SettingsSearchEntry("remote.volumeKeys", SettingsCard.REMOTE.place, null, R.string.remote_volume_keys_title, R.string.remote_volume_keys_detail, listOf("volume", "slides", "громкость"), revealedBy = R.string.feature_remote_input),
        feature("remote.screenControl", SettingsCard.SEE_MAC_SCREEN.place, R.string.feature_screen_control, R.string.settings_screen_control_detail, BridgeyFeature.SCREEN_CONTROL, SCREEN_CONTROL_WORDS),
        SettingsSearchEntry("remote.unattended", SettingsCard.PHONE_CONTROL.place, null, R.string.unattended_title, R.string.unattended_search_detail,
            PHONE_CONTROL_WORDS + listOf("without asking", "always allow", "неконтролируемый", "без вопросов")),
        SettingsSearchEntry("remote.phoneControl", SettingsCard.PHONE_CONTROL.place, null, R.string.control_settings_title, R.string.control_settings_search_detail, PHONE_CONTROL_WORDS),

        // Privacy
        SettingsSearchEntry("privacy.previews", SettingsCard.ACTIVITY.place, null, R.string.settings_show_previews, R.string.settings_show_previews_detail, PREVIEW_WORDS, syncKey = SyncKey.ACTIVITY_PREVIEWS),
        SettingsSearchEntry("privacy.activity", SettingsCard.ACTIVITY.place, null, R.string.settings_activity, R.string.settings_activity_detail, ACTIVITY_WORDS),
        SettingsSearchEntry("privacy.permissions", SettingsCard.PERMISSIONS.place, null, R.string.perm_page_title, R.string.perm_page_detail, listOf("permissions", "access", "разрешения")),
        SettingsSearchEntry("privacy.reset", SettingsCard.PERMISSIONS.place, null, R.string.reset_title, R.string.reset_detail, RESET_WORDS),
        SettingsSearchEntry("privacy.logConnection", SettingsCard.LOGGING.more, null, R.string.logging_connection, R.string.logging_connection_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logCalls", SettingsCard.LOGGING.more, null, R.string.logging_calls, R.string.logging_calls_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logCallNumbers", SettingsCard.LOGGING.more, null, R.string.logging_call_numbers, R.string.logging_call_numbers_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logNotifications", SettingsCard.LOGGING.more, null, R.string.logging_notifications, R.string.logging_notifications_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logNotificationContent", SettingsCard.LOGGING.more, null, R.string.logging_notification_content, R.string.logging_notification_content_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logClipboard", SettingsCard.LOGGING.more, null, R.string.logging_clipboard, R.string.logging_clipboard_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logClipboardPreviews", SettingsCard.LOGGING.more, null, R.string.logging_clipboard_previews, R.string.logging_clipboard_previews_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logFileNames", SettingsCard.LOGGING.more, null, R.string.logging_file_names, R.string.logging_file_names_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.logRemote", SettingsCard.LOGGING.more, null, R.string.logging_remote, R.string.logging_remote_detail, LOG_WORDS),
        SettingsSearchEntry("privacy.diagnostics", SettingsCard.LOGGING.place, null, R.string.settings_diagnostics, R.string.settings_diagnostics_detail, LOG_WORDS + listOf("export", "report", "bug")),
        SettingsSearchEntry("privacy.clearLogs", SettingsCard.LOGGING.place, null, R.string.logging_clear, R.string.logging_clear_detail, LOG_WORDS),

        // Updates
        SettingsSearchEntry("updates.status", SettingsCard.UPDATES.place, null, R.string.settings_search_check_updates, null, UPDATE_WORDS),
        SettingsSearchEntry("updates.channel", SettingsCard.UPDATES.place, null, R.string.updates_channel, R.string.updates_channel_note, UPDATE_WORDS + listOf("stable", "nightly", "стабильный")),
        SettingsSearchEntry("updates.auto", SettingsCard.UPDATES.place, null, R.string.update_auto_title, R.string.update_auto_detail, UPDATE_WORDS + listOf("automatic", "автоматически"), syncKey = SyncKey.AUTO_UPDATE_ALL),
        SettingsSearchEntry("updates.devices", SettingsCard.UPDATES.more, null, R.string.update_all_devices_title, null, UPDATE_WORDS + listOf("update all", "mac")),
        SettingsSearchEntry("updates.remoteStart", SettingsCard.UPDATES.more, null, R.string.update_all_remote_start_title, R.string.update_all_remote_start_detail, UPDATE_WORDS),

        // General
        SettingsSearchEntry("general.background", SettingsCard.GENERAL.place, null, R.string.settings_background_title, null, BACKGROUND_WORDS),
        SettingsSearchEntry("general.wifiAwake", SettingsCard.GENERAL.more, null, R.string.settings_wifi_awake_title, R.string.settings_wifi_awake_detail, listOf("wifi", "wi-fi", "sleep", "вайфай")),
        SettingsSearchEntry("general.oem", SettingsCard.GENERAL.place, null, R.string.settings_search_oem, null, BACKGROUND_WORDS + listOf("autostart", "oneplus", "xiaomi", "samsung", "автозапуск"), revealedBy = R.string.settings_background_title),
        SettingsSearchEntry("general.sync", SettingsCard.SYNC.place, null, R.string.settings_sync_title, R.string.settings_sync_detail, SYNC_WORDS),
        SettingsSearchEntry("general.syncChoose", SettingsCard.SYNC.place, null, R.string.settings_sync_choose, null, SYNC_WORDS),
        SettingsSearchEntry("general.reduceMotion", SettingsCard.GENERAL.place, null, R.string.settings_reduce_motion, R.string.settings_reduce_motion_detail, MOTION_WORDS, syncKey = SyncKey.REDUCE_MOTION),
        SettingsSearchEntry("general.turnOff", SettingsCard.GENERAL.more, null, R.string.settings_turn_off, R.string.settings_turn_off_detail, TURN_OFF_WORDS),
        SettingsSearchEntry("general.runSetup", SettingsCard.GENERAL.more, null, R.string.setup_run_again, R.string.setup_run_again_detail, listOf("setup", "onboarding", "настройка")),

        // About
        SettingsSearchEntry("about.version", SettingsCard.ABOUT.place, null, R.string.settings_version, null, UPDATE_WORDS),
        SettingsSearchEntry("about.licences", SettingsCard.ABOUT.place, null, R.string.settings_licences, R.string.settings_licences_detail, listOf("license", "open source", "лицензии")),
        SettingsSearchEntry("about.obtainium", SettingsCard.ABOUT.more, null, R.string.obtainium_title, null, UPDATE_WORDS + listOf("obtainium")),

        // Privacy › Permissions (one row per permission). Sub-pages come after the main pages, so on equal scores
        // the main page's row is offered first.
        SettingsSearchEntry("permissions.notificationAccess", SearchPage.PERMISSIONS.place, null, R.string.perm_notification_access_name, R.string.perm_notification_access_why, NOTIFICATION_WORDS),
        SettingsSearchEntry("permissions.postNotifications", SearchPage.PERMISSIONS.place, null, R.string.perm_post_notifications_name, R.string.perm_post_notifications_why),
        SettingsSearchEntry("permissions.phoneCalls", SearchPage.PERMISSIONS.place, null, R.string.perm_phone_calls_name, R.string.perm_phone_calls_why, CALL_WORDS),
        SettingsSearchEntry("permissions.photos", SearchPage.PERMISSIONS.place, null, R.string.perm_photos_name, R.string.perm_photos_why, listOf("gallery", "галерея")),
        SettingsSearchEntry("permissions.camera", SearchPage.PERMISSIONS.place, null, R.string.perm_camera_name, R.string.perm_camera_why),
        SettingsSearchEntry("permissions.companionLink", SearchPage.PERMISSIONS.place, null, R.string.perm_companion_link_name, R.string.perm_companion_link_why, CODES + listOf("bluetooth")),
        SettingsSearchEntry("permissions.dnd", SearchPage.PERMISSIONS.place, null, R.string.perm_do_not_disturb_name, R.string.perm_do_not_disturb_why, FOCUS_WORDS),
        SettingsSearchEntry("permissions.battery", SearchPage.PERMISSIONS.place, null, R.string.perm_battery_name, R.string.perm_battery_why, BACKGROUND_WORDS),
        SettingsSearchEntry("permissions.install", SearchPage.PERMISSIONS.place, null, R.string.perm_install_packages_name, R.string.perm_install_packages_why, UPDATE_WORDS),
        SettingsSearchEntry("permissions.sms", SearchPage.PERMISSIONS.place, null, R.string.perm_sms_name, R.string.perm_sms_why, SMS_WORDS),
        SettingsSearchEntry("permissions.contacts", SearchPage.PERMISSIONS.place, null, R.string.perm_contacts_name, R.string.perm_contacts_why),
        SettingsSearchEntry("permissions.callLog", SearchPage.PERMISSIONS.place, null, R.string.perm_call_log_name, R.string.perm_call_log_why, DIALER_WORDS + listOf("recent", "history", "недавние")),
        SettingsSearchEntry("permissions.logs", SearchPage.PERMISSIONS.place, null, R.string.perm_logs_name, R.string.perm_logs_why, listOf("adb")),

        // Privacy › Reset Bridgey on this device
        SettingsSearchEntry("reset.activity", SearchPage.RESET.place, null, R.string.reset_choice_activity, R.string.reset_choice_activity_summary, RESET_WORDS),
        SettingsSearchEntry("reset.caches", SearchPage.RESET.place, null, R.string.reset_choice_caches, R.string.reset_choice_caches_summary, RESET_WORDS + listOf("cache", "storage", "кэш")),
        SettingsSearchEntry("reset.settings", SearchPage.RESET.place, null, R.string.reset_choice_settings, R.string.reset_choice_settings_summary, RESET_WORDS),
        SettingsSearchEntry("reset.everything", SearchPage.RESET.place, null, R.string.reset_choice_everything, R.string.reset_choice_everything_summary, RESET_WORDS),

        // Developer and experimental (only while the menu is on)
        SettingsSearchEntry("developer.speed", SettingsCard.DEVELOPER.place, R.string.developer_tools, R.string.settings_speed_test, R.string.settings_speed_test_detail, DEVELOPER_WORDS, developerOnly = true),
        SettingsSearchEntry("developer.perf", SettingsCard.DEVELOPER.place, R.string.developer_tools, R.string.perf_title, R.string.developer_perf_detail, DEVELOPER_WORDS, developerOnly = true),
        SettingsSearchEntry("developer.hide", SettingsCard.DEVELOPER.place, null, R.string.developer_turn_off, R.string.developer_turn_off_detail, DEVELOPER_WORDS, developerOnly = true),
    )

    /** The per-device choices, in the order their "device.<id>.<n>" ids count them (SettingsCards.kt DeviceChoices). */
    val devicePermissionRows: List<Pair<Int, List<BridgeyFeature>>> get() = DeviceChoices.map { it.titleRes to it.features }

    private fun featureWords(features: List<BridgeyFeature>): List<String> = features.flatMap {
        when (it) {
            BridgeyFeature.CLIPBOARD -> CLIPBOARD_WORDS
            BridgeyFeature.NOTIFICATIONS -> NOTIFICATION_WORDS
            BridgeyFeature.SMS -> SMS_WORDS
            BridgeyFeature.CALLS -> CALL_WORDS
            BridgeyFeature.CALL_QUIET -> CALL_WORDS + MEDIA_WORDS
            BridgeyFeature.DIALER -> DIALER_WORDS
            BridgeyFeature.FILES -> FILE_WORDS
            BridgeyFeature.MEDIA -> MEDIA_WORDS
            BridgeyFeature.FIND_DEVICE -> FIND_WORDS
            BridgeyFeature.PING -> PING_WORDS
            BridgeyFeature.BATTERY -> BATTERY_WORDS
            BridgeyFeature.REMOTE_INPUT -> REMOTE_WORDS
            BridgeyFeature.SCREEN_CONTROL -> SCREEN_CONTROL_WORDS
            BridgeyFeature.SCREEN -> SHARE_SCREEN_WORDS
            BridgeyFeature.CAMERA -> CAMERA_WORDS
            BridgeyFeature.LINKS -> LINK_WORDS
            BridgeyFeature.MAC_ACTIONS -> MAC_ACTION_WORDS
        }
    }

    private fun Context.crumb(page: SearchPage): List<String> = (page.parent?.let { crumb(it) } ?: emptyList()) + getString(page.titleRes)

    /** The breadcrumb above a row: its page, its card (unless the row is the card's own title), then its section. */
    private fun Context.crumbs(place: SearchPlace, title: String, section: String?): List<String> {
        val card = place.card?.let { cardTitle(this, it) }?.takeIf { it != title }
        return crumb(place.page) + listOfNotNull(card, section?.takeIf { it != title && it != card })
    }

    /** Names for "Different on Work Mac", "Different on Work Mac +1". */
    private fun Context.deviceList(names: List<String>): String =
        if (names.size == 1) names.first() else getString(R.string.settings_sync_devices_more, names.first(), names.size - 1)

    /** The entries this build offers. */
    private fun built(entry: SettingsSearchEntry, developerMenu: Boolean): Boolean = when {
        entry.developerOnly && !developerMenu -> false
        entry.place.card == SettingsCard.MESSAGES && !dev.bridgey.android.BuildGates.sms -> false
        entry.place.card == SettingsCard.UPDATES && !dev.bridgey.android.BuildGates.selfUpdate -> false
        entry.id in setOf("permissions.sms", "permissions.contacts") && !dev.bridgey.android.BuildGates.sms -> false
        entry.id == "permissions.install" && !dev.bridgey.android.BuildGates.selfUpdate -> false
        entry.id in setOf("remote.phoneControl", "remote.unattended") && !dev.bridgey.android.BuildGates.phoneControl -> false
        else -> true
    }

    /**
     * Everything search can offer now, in the current language: the registry (developer rows only while
     * [developerMenu] is on), with synced rows marked and their sync status, then each paired device's page and its
     * chips. Two entries for one row (Connect away from home was a row on Devices and its own page's switch) give one
     * result, the first, which takes the other's words.
     */
    fun resolve(context: Context, developerMenu: Boolean, sync: SyncUiState, devices: List<SearchDevice>): List<SearchResultEntry> {
        val out = mutableListOf<SearchResultEntry>()
        for (entry in entries) {
            if (!built(entry, developerMenu)) continue
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
            val crumbs = context.crumbs(entry.place, title, section)
            val cardName = entry.place.card?.let { cardTitle(context, it) }
            out += SearchResultEntry(
                id = entry.id,
                group = page,
                icon = entry.page.icon(),
                tint = entry.page.tint,
                title = title,
                subtitle = subtitle,
                breadcrumb = crumbs.joinToString(CRUMB),
                doc = SearchDoc(title, subtitle, section, (context.crumb(entry.page) + listOfNotNull(cardName)).joinToString(" "), keywords),
                route = entry.page.route,
                rowTitle = title,
                fallbackTitle = entry.revealedBy?.let(context::getString),
                scope = entry.place.card?.key,
                expand = entry.place.card?.takeIf { entry.place.more }?.key,
                fallbackScope = (entry.revealedIn ?: entry.place.card)?.key,
            )
        }
        // A device's own page first: on equal scores its name leads to it, then to its chips.
        out += devices.flatMap { deviceEntries(context, it) }
        out += devices.filterNot { it.isAgent }.flatMap { macRows(context, it) }
        return merged(out)
    }

    /** One result per row: a later entry for the same row adds its words to the first. */
    private fun merged(entries: List<SearchResultEntry>): List<SearchResultEntry> {
        val first = LinkedHashMap<Triple<String, String?, String?>, SearchResultEntry>()
        for (entry in entries) {
            val key = Triple(entry.route.key, entry.scope, entry.rowTitle)
            val kept = first[key]
            first[key] = if (kept == null || entry.rowTitle == null) {
                entry
            } else {
                kept.copy(doc = kept.doc.copy(keywords = (kept.doc.keywords + entry.doc.keywords + listOfNotNull(entry.subtitle)).distinct()))
            }
        }
        return first.values.toList()
    }

    /**
     * A paired Mac's rows elsewhere, found by its name: may it start calls (its chip on the Calls window card, the same
     * row as its "device.<id>" chip, so the two give one result) and may it control this phone (Let Macs control this
     * phone).
     */
    private fun macRows(context: Context, device: SearchDevice): List<SearchResultEntry> {
        fun row(id: String, card: SettingsCard, @StringRes section: Int, title: String, scope: String?, words: List<String>, @StringRes fallback: Int?): SearchResultEntry {
            val page = SearchPage.of(card.group)
            val sectionTitle = context.getString(section)
            return SearchResultEntry(
                id = id,
                group = context.getString(page.titleRes),
                icon = page.icon(),
                tint = page.tint,
                title = device.name,
                subtitle = null,
                breadcrumb = (context.crumb(page) + sectionTitle).joinToString(CRUMB),
                doc = SearchDoc(device.name, null, sectionTitle, context.crumb(page).joinToString(" "), words + listOf("allow", "разрешить")),
                route = page.route,
                rowTitle = title,
                fallbackTitle = fallback?.let(context::getString),
                scope = scope,
            )
        }
        return listOfNotNull(
            row("calls.mac.${device.id}", SettingsCard.CALLS_WINDOW, R.string.dialer_title, context.getString(R.string.dialer_title), device.id, DIALER_WORDS, null)
                .takeIf { dev.bridgey.android.BuildGates.featureBuilt(BridgeyFeature.DIALER) },
            row("remote.mac.${device.id}", SettingsCard.PHONE_CONTROL, R.string.control_settings_title, device.name, SettingsCard.PHONE_CONTROL.key, PHONE_CONTROL_WORDS, R.string.control_settings_title)
                .takeIf { dev.bridgey.android.BuildGates.phoneControl },
        )
    }

    /**
     * A paired device's page, found by its name; then its chips on the cards ("Sharing › Clipboard › OnePlus 11"). An
     * agent (the bridgey command on a server) lists its grants, on its page, instead.
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
        if (device.isAgent) {
            val crumb = listOf(devicesTitle, device.name, permissions).joinToString(CRUMB)
            val rows = AgentGrant.entries.map { grantTitle(context, it) to listOf("agent", "server", "агент", "сервер") } +
                (context.getString(R.string.agent_trust_row) to listOf("trust", "доверять"))
            return listOf(page) + rows.mapIndexed { index, (title, words) ->
                SearchResultEntry(
                    id = "device.${device.id}.$index",
                    group = device.name, icon = icon, tint = Tint.BLUE, title = title, subtitle = null, breadcrumb = crumb,
                    doc = SearchDoc(title, null, permissions, "$devicesTitle ${device.name}", words + device.name),
                    route = route, rowTitle = title,
                )
            }
        }
        return listOf(page) + DeviceChoices.mapIndexedNotNull { index, choice ->
            if (!choice.features.all(dev.bridgey.android.BuildGates::featureBuilt)) return@mapIndexedNotNull null
            if (choice.card == SettingsCard.MESSAGES && !dev.bridgey.android.BuildGates.sms) return@mapIndexedNotNull null
            val title = context.getString(choice.titleRes)
            val cardPage = SearchPage.of(choice.card.group)
            val cardName = cardTitle(context, choice.card)
            SearchResultEntry(
                id = "device.${device.id}.$index",
                group = device.name,
                icon = icon,
                tint = Tint.BLUE,
                title = title,
                subtitle = null,
                breadcrumb = (context.crumb(cardPage) + listOfNotNull(cardName?.takeIf { it != title }, device.name)).joinToString(CRUMB),
                doc = SearchDoc(
                    title, null, cardName, (context.crumb(cardPage) + devicesTitle).joinToString(" "),
                    featureWords(choice.features) + (if (choice.features.isEmpty()) SYNC_WORDS else emptyList()) + device.name,
                ),
                route = cardPage.route,
                rowTitle = title,
                scope = device.id,
                expand = choice.card.takeIf { choice.more }?.key,
            )
        }
    }

    /** The permission kinds the Permissions page can list, for the drift test. */
    val permissionKinds: List<PermissionKind> = PermissionKind.entries

    /** The reset choices, for the drift test. */
    val resetChoices: List<ResetChoice> = ResetChoice.entries
}
