package dev.bridgey.android.setup

import androidx.annotation.StringRes
import dev.bridgey.android.R

/*
 * Advanced setup as questions. One question per card, in plain words; each answer
 * turns on or configures the settings behind it, and later questions adapt to earlier answers.
 * Pure data and rules (no Android types beyond string ids), so the state machine, the coverage
 * table and the answers-to-settings mapping are tested in plain JUnit. The Mac has the same
 * question ids, order and keywords (macos/Sources/BridgeyMac/SetupQuestions.swift).
 */

/** The sections, in the agreed order. Mac control questions need a paired Mac. */
enum class SetupSection(@StringRes val title: Int) {
    DEVICES(R.string.setup_group_devices),
    CLIPBOARD(R.string.setup_group_clipboard),
    NOTIFICATIONS(R.string.setup_group_notifications),
    CALLS(R.string.setup_group_calls),
    FILES(R.string.setup_group_files),
    MAC_CONTROL(R.string.setup_section_mac_control),
    CAMERA_FOCUS(R.string.setup_section_camera_focus),
    QUICK_ACTIONS(R.string.setup_section_quick_actions),
    PRIVACY(R.string.setup_group_privacy),
    UPDATES(R.string.setup_group_updates),
    GENERAL(R.string.setup_group_general),
}

/**
 * Every setting the 0.10 beta 1 Advanced setup showed on this phone (its ten pages). The coverage
 * test fails when one of these is not reachable through a question, a follow-up or a question's
 * More options. Values are strings: "true"/"false", or an enum name.
 */
enum class SetupSetting(val default: String) {
    PAIRING("false"),
    FEATURE_CLIPBOARD("true"),
    AUTO_CLIPBOARD("true"),
    CLIPBOARD_FILES("true"),
    SCREENSHOT_SEND("true"),
    CLIPBOARD_EAGER_LIMIT(""),
    BACKGROUND_CLIPBOARD("false"),
    FEATURE_NOTIFICATIONS("true"),
    NOTIFICATION_ACCESS("false"),
    /** Apps whose notifications stay on the phone (they have a Mac app). A comma list of packages. */
    HIDDEN_NOTIFICATION_APPS(""),
    CODES_LINK("false"),
    APP_NOTIFICATIONS("false"),
    FOCUS_SHARE("false"),
    FOCUS_FOLLOW("false"),
    FEATURE_CALLS("true"),
    DIRECT_CALLS("false"),
    FEATURE_FILES("true"),
    FOLDER_MODE("SENDER_PICKS"),
    FOLDER_DEFAULT_PLACE(""),
    FOLDER_CONFLICT("ASK"),
    ALLOW_BROWSE("true"),
    ALLOW_REPLACE("false"),
    PLACES(""),
    FEATURE_REMOTE_INPUT("false"),
    REMOTE_POINTER_SPEED("3"),
    REMOTE_VOLUME_KEYS("false"),
    FEATURE_MAC_ACTIONS("true"),
    FEATURE_MEDIA("true"),
    FEATURE_CAMERA("true"),
    FEATURE_LINKS("true"),
    FEATURE_FIND_DEVICE("true"),
    FEATURE_PING("true"),
    FEATURE_BATTERY("true"),
    SHOW_PREVIEWS("true"),
    /** Privacy > Logging > Connection: the connection stats question. */
    LOGGING_CONNECTION("true"),
    /** The other Logging switches (calls, numbers, notification text, clipboard, file names, remote). */
    LOGGING_DETAIL(""),
    UPDATE_CHANNEL("STABLE"),
    BATTERY_EXEMPTION("false"),
    OEM_CHECKLIST(""),
    KEEP_WIFI_AWAKE("false"),
    REDUCE_MOTION("false"),
}

/** One setting set to a value by an answer. */
data class SettingChange(val setting: SetupSetting, val value: String) {
    companion object {
        fun on(setting: SetupSetting) = SettingChange(setting, "true")
        fun off(setting: SetupSetting) = SettingChange(setting, "false")
    }
}

/** One answer button. [turnsOn]: the summary lists it under what was turned on. */
data class SetupAnswer(
    val key: String,
    @StringRes val label: Int,
    @StringRes val detail: Int? = null,
    val changes: List<SettingChange> = emptyList(),
    /** Asked right after this answer, with the permission's own explanation. */
    val permission: PermissionKind? = null,
    /** What goes back off when [permission] is not allowed. */
    val onDenied: List<SettingChange> = emptyList(),
    val turnsOn: Boolean = false,
)

/** How a question covers a setting: its answers set it, or its More options page holds it. */
enum class Coverage { ANSWER, MORE_OPTIONS }

/** What the questions depend on besides earlier answers. [current]: the settings now. */
data class SetupFacts(
    val paired: Boolean = false,
    val current: Map<SetupSetting, String> = emptyMap(),
    val granted: Set<PermissionKind> = emptySet(),
    val sdkInt: Int = 35,
    /** Folders sent to this phone need Android 10 or newer. */
    val foldersSupported: Boolean = true,
    /** Keep Wi-Fi awake: Android 13 and older. */
    val wifiAwakeSupported: Boolean = false,
    /** Android 15 hides codes from apps that are not linked to a nearby device. */
    val codesLinkApplies: Boolean = false,
    /** Installed apps that also have a Mac app (package to name), for the duplicates question. */
    val duplicateApps: List<Pair<String, String>> = emptyList(),
) {
    fun value(setting: SetupSetting): String = current[setting] ?: setting.default
}

/** The settings as they are after the answers so far (answers are applied as they are given). */
class Effective(val facts: SetupFacts, private val overlay: Map<SetupSetting, String> = emptyMap()) {
    operator fun get(setting: SetupSetting): String = overlay[setting] ?: facts.value(setting)
    fun on(setting: SetupSetting): Boolean = get(setting) == "true"
    val paired: Boolean get() = facts.paired
}

/** A question card. [asks] decides whether it is shown; false means its answer is implied. */
data class SetupQuestion(
    val id: String,
    val section: SetupSection,
    @StringRes val title: Int,
    @StringRes val context: Int,
    /** The plain words in the summary ("Copy and paste between devices"). */
    @StringRes val summary: Int,
    val answers: List<SetupAnswer>,
    /** The answer that turns this off, for the summary's switch. */
    val offKey: String? = "no",
    /** Settings > this page: More options on the card, Change in Settings in the summary. */
    val settingsPage: String? = null,
    val covers: Map<SetupSetting, Coverage> = emptyMap(),
    /** Several answers at once (the duplicate apps question). */
    val multiPick: Boolean = false,
    val asks: (Effective) -> Boolean = { true },
) {
    fun answer(key: String): SetupAnswer? = answers.firstOrNull { it.key == key }
}

/** Answer keys, the same on the Mac. */
object Answers {
    const val YES = "yes"
    const val NO = "no"
    const val AUTO = "auto"
    const val TAP = "tap"
    const val TEXT = "text"
    const val SEE = "see"
    const val BROWSE = "browse"
    const val CHANGE = "change"
    const val SENDER = "sender"
    const val ASK = "ask"
    const val FIXED = "fixed"
    const val BOTH = "both"
    const val FOLLOW = "follow"
    const val SHARE = "share"
    const val STEADY = "steady"
    const val EARLY = "early"
    const val NEWEST = "newest"
    const val NONE = "none"
    /** The duplicates question: "picked:" then the packages, comma separated. */
    const val PICKED = "picked:"
}

object SetupQuestions {
    private fun yes(@StringRes label: Int, vararg changes: SettingChange, @StringRes detail: Int? = null, permission: PermissionKind? = null, onDenied: List<SettingChange> = emptyList()) =
        SetupAnswer(Answers.YES, label, detail, changes.toList(), permission, onDenied, turnsOn = true)

    private fun no(@StringRes label: Int, vararg changes: SettingChange) = SetupAnswer(Answers.NO, label, changes = changes.toList())

    private val on = SettingChange.Companion::on
    private val off = SettingChange.Companion::off

    /** The Android questions, in order. The pairing card is first and is not an answer card. */
    val all: List<SetupQuestion> = listOf(
        SetupQuestion(
            id = "pair", section = SetupSection.DEVICES,
            title = R.string.setup_q_pair_title, context = R.string.setup_q_pair_context, summary = R.string.setup_q_pair_summary,
            answers = emptyList(), offKey = null,
            covers = mapOf(SetupSetting.PAIRING to Coverage.ANSWER),
            asks = { !it.paired },
        ),
        // Clipboard
        SetupQuestion(
            id = "clipboard", section = SetupSection.CLIPBOARD,
            title = R.string.setup_q_clipboard_title, context = R.string.setup_q_clipboard_context, summary = R.string.setup_q_clipboard_summary,
            answers = listOf(
                SetupAnswer(Answers.AUTO, R.string.setup_a_clipboard_auto, R.string.setup_a_clipboard_auto_detail,
                    listOf(on(SetupSetting.FEATURE_CLIPBOARD), on(SetupSetting.AUTO_CLIPBOARD)), turnsOn = true),
                SetupAnswer(Answers.TAP, R.string.setup_a_clipboard_tap, R.string.setup_a_clipboard_tap_detail,
                    listOf(on(SetupSetting.FEATURE_CLIPBOARD), off(SetupSetting.AUTO_CLIPBOARD)), turnsOn = true),
                no(R.string.setup_a_no, off(SetupSetting.FEATURE_CLIPBOARD)),
            ),
            settingsPage = "CLIPBOARD",
            covers = mapOf(
                SetupSetting.FEATURE_CLIPBOARD to Coverage.ANSWER,
                SetupSetting.AUTO_CLIPBOARD to Coverage.ANSWER,
                SetupSetting.BACKGROUND_CLIPBOARD to Coverage.MORE_OPTIONS,
            ),
        ),
        SetupQuestion(
            id = "clipboard_files", section = SetupSection.CLIPBOARD,
            title = R.string.setup_q_clipboard_files_title, context = R.string.setup_q_clipboard_files_context, summary = R.string.setup_q_clipboard_files_summary,
            answers = listOf(
                yes(R.string.setup_a_clipboard_files_yes, on(SetupSetting.CLIPBOARD_FILES)),
                SetupAnswer(Answers.TEXT, R.string.setup_a_clipboard_files_text, changes = listOf(off(SetupSetting.CLIPBOARD_FILES))),
            ),
            offKey = Answers.TEXT,
            settingsPage = "CLIPBOARD",
            covers = mapOf(SetupSetting.CLIPBOARD_FILES to Coverage.ANSWER, SetupSetting.CLIPBOARD_EAGER_LIMIT to Coverage.MORE_OPTIONS),
            asks = { it.on(SetupSetting.FEATURE_CLIPBOARD) },
        ),
        SetupQuestion(
            id = "clipboard_screenshot", section = SetupSection.CLIPBOARD,
            title = R.string.setup_q_clipboard_screenshot_title, context = R.string.setup_q_clipboard_screenshot_context, summary = R.string.setup_q_clipboard_screenshot_summary,
            answers = listOf(
                yes(R.string.setup_a_yes, on(SetupSetting.SCREENSHOT_SEND), permission = PermissionKind.PHOTOS, onDenied = listOf(off(SetupSetting.SCREENSHOT_SEND))),
                no(R.string.setup_a_no, off(SetupSetting.SCREENSHOT_SEND)),
            ),
            settingsPage = "CLIPBOARD",
            covers = mapOf(SetupSetting.SCREENSHOT_SEND to Coverage.ANSWER),
            asks = { it.on(SetupSetting.FEATURE_CLIPBOARD) && it.on(SetupSetting.CLIPBOARD_FILES) },
        ),
        // Notifications
        SetupQuestion(
            id = "notifications", section = SetupSection.NOTIFICATIONS,
            title = R.string.setup_q_notifications_title, context = R.string.setup_q_notifications_context, summary = R.string.setup_q_notifications_summary,
            answers = listOf(
                yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_NOTIFICATIONS), permission = PermissionKind.NOTIFICATION_ACCESS,
                    onDenied = listOf(off(SetupSetting.FEATURE_NOTIFICATIONS))),
                no(R.string.setup_a_no, off(SetupSetting.FEATURE_NOTIFICATIONS)),
            ),
            settingsPage = "NOTIFICATIONS",
            covers = mapOf(SetupSetting.FEATURE_NOTIFICATIONS to Coverage.ANSWER, SetupSetting.NOTIFICATION_ACCESS to Coverage.ANSWER),
        ),
        SetupQuestion(
            id = "notification_apps", section = SetupSection.NOTIFICATIONS,
            title = R.string.setup_q_notification_apps_title, context = R.string.setup_q_notification_apps_context, summary = R.string.setup_q_notification_apps_summary,
            answers = listOf(SetupAnswer(Answers.NONE, R.string.setup_a_notification_apps_none, changes = listOf(SettingChange(SetupSetting.HIDDEN_NOTIFICATION_APPS, "")))),
            offKey = null, multiPick = true,
            settingsPage = "NOTIFICATIONS",
            covers = mapOf(SetupSetting.HIDDEN_NOTIFICATION_APPS to Coverage.ANSWER),
            asks = { it.on(SetupSetting.FEATURE_NOTIFICATIONS) && it.facts.duplicateApps.isNotEmpty() },
        ),
        SetupQuestion(
            id = "codes", section = SetupSection.NOTIFICATIONS,
            title = R.string.setup_q_codes_title, context = R.string.setup_q_codes_context, summary = R.string.setup_q_codes_summary,
            answers = listOf(
                yes(R.string.setup_a_codes_yes, on(SetupSetting.CODES_LINK), permission = PermissionKind.COMPANION_LINK,
                    onDenied = listOf(off(SetupSetting.CODES_LINK))),
                no(R.string.setup_a_no),
            ),
            offKey = null,
            settingsPage = "NOTIFICATIONS",
            covers = mapOf(SetupSetting.CODES_LINK to Coverage.ANSWER),
            asks = { it.on(SetupSetting.FEATURE_NOTIFICATIONS) && it.paired && it.facts.codesLinkApplies && !it.on(SetupSetting.CODES_LINK) },
        ),
        SetupQuestion(
            id = "app_notifications", section = SetupSection.NOTIFICATIONS,
            title = R.string.setup_q_app_notifications_title, context = R.string.setup_q_app_notifications_context, summary = R.string.setup_q_app_notifications_summary,
            answers = listOf(
                yes(R.string.setup_a_yes, on(SetupSetting.APP_NOTIFICATIONS), permission = PermissionKind.POST_NOTIFICATIONS,
                    onDenied = listOf(off(SetupSetting.APP_NOTIFICATIONS))),
                no(R.string.setup_a_no),
            ),
            offKey = null,
            covers = mapOf(SetupSetting.APP_NOTIFICATIONS to Coverage.ANSWER),
            asks = { it.facts.sdkInt >= 33 && !it.on(SetupSetting.APP_NOTIFICATIONS) },
        ),
        // Calls
        SetupQuestion(
            id = "calls", section = SetupSection.CALLS,
            title = R.string.setup_q_calls_title, context = R.string.setup_q_calls_context, summary = R.string.setup_q_calls_summary,
            answers = listOf(
                SetupAnswer(Answers.YES, R.string.setup_a_calls_yes, R.string.setup_a_calls_yes_detail,
                    listOf(on(SetupSetting.FEATURE_CALLS), on(SetupSetting.DIRECT_CALLS)), PermissionKind.PHONE_CALLS,
                    listOf(off(SetupSetting.DIRECT_CALLS)), turnsOn = true),
                SetupAnswer(Answers.SEE, R.string.setup_a_calls_see, R.string.setup_a_calls_see_detail,
                    listOf(on(SetupSetting.FEATURE_CALLS), off(SetupSetting.DIRECT_CALLS)), turnsOn = true),
                no(R.string.setup_a_no, off(SetupSetting.FEATURE_CALLS), off(SetupSetting.DIRECT_CALLS)),
            ),
            settingsPage = "CALLS",
            covers = mapOf(SetupSetting.FEATURE_CALLS to Coverage.ANSWER, SetupSetting.DIRECT_CALLS to Coverage.ANSWER),
        ),
        // Files
        SetupQuestion(
            id = "files", section = SetupSection.FILES,
            title = R.string.setup_q_files_title, context = R.string.setup_q_files_context, summary = R.string.setup_q_files_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_FILES)), no(R.string.setup_a_no, off(SetupSetting.FEATURE_FILES))),
            settingsPage = "FILES",
            covers = mapOf(SetupSetting.FEATURE_FILES to Coverage.ANSWER, SetupSetting.PLACES to Coverage.MORE_OPTIONS),
        ),
        SetupQuestion(
            id = "files_browse", section = SetupSection.FILES,
            title = R.string.setup_q_files_browse_title, context = R.string.setup_q_files_browse_context, summary = R.string.setup_q_files_browse_summary,
            answers = listOf(
                SetupAnswer(Answers.BROWSE, R.string.setup_a_files_browse_look, R.string.setup_a_files_browse_look_detail,
                    listOf(on(SetupSetting.ALLOW_BROWSE), off(SetupSetting.ALLOW_REPLACE)), PermissionKind.PHOTOS, turnsOn = true),
                SetupAnswer(Answers.CHANGE, R.string.setup_a_files_browse_change, R.string.setup_a_files_browse_change_detail,
                    listOf(on(SetupSetting.ALLOW_BROWSE), on(SetupSetting.ALLOW_REPLACE)), PermissionKind.PHOTOS, turnsOn = true),
                no(R.string.setup_a_no, off(SetupSetting.ALLOW_BROWSE), off(SetupSetting.ALLOW_REPLACE)),
            ),
            settingsPage = "FILES",
            covers = mapOf(SetupSetting.ALLOW_BROWSE to Coverage.ANSWER, SetupSetting.ALLOW_REPLACE to Coverage.ANSWER),
            asks = { it.on(SetupSetting.FEATURE_FILES) },
        ),
        SetupQuestion(
            id = "files_folder", section = SetupSection.FILES,
            title = R.string.setup_q_files_folder_title, context = R.string.setup_q_files_folder_context, summary = R.string.setup_q_files_folder_summary,
            answers = listOf(
                SetupAnswer(Answers.SENDER, R.string.setup_a_files_folder_sender, changes = listOf(SettingChange(SetupSetting.FOLDER_MODE, "SENDER_PICKS"))),
                SetupAnswer(Answers.ASK, R.string.setup_a_files_folder_ask, changes = listOf(SettingChange(SetupSetting.FOLDER_MODE, "RECEIVER_ASKS"))),
                SetupAnswer(Answers.FIXED, R.string.setup_a_files_folder_fixed, changes = listOf(SettingChange(SetupSetting.FOLDER_MODE, "FIXED"))),
            ),
            offKey = null,
            settingsPage = "FILES",
            covers = mapOf(
                SetupSetting.FOLDER_MODE to Coverage.ANSWER,
                SetupSetting.FOLDER_DEFAULT_PLACE to Coverage.MORE_OPTIONS,
                SetupSetting.FOLDER_CONFLICT to Coverage.MORE_OPTIONS,
            ),
            asks = { it.on(SetupSetting.FEATURE_FILES) && it.facts.foldersSupported },
        ),
        // Mac control: only with a Mac paired.
        SetupQuestion(
            id = "remote", section = SetupSection.MAC_CONTROL,
            title = R.string.setup_q_remote_title, context = R.string.setup_q_remote_context, summary = R.string.setup_q_remote_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_REMOTE_INPUT)), no(R.string.setup_a_no, off(SetupSetting.FEATURE_REMOTE_INPUT))),
            settingsPage = "REMOTE_CONTROL",
            covers = mapOf(SetupSetting.FEATURE_REMOTE_INPUT to Coverage.ANSWER, SetupSetting.REMOTE_POINTER_SPEED to Coverage.MORE_OPTIONS),
            asks = { it.paired },
        ),
        SetupQuestion(
            id = "remote_volume_keys", section = SetupSection.MAC_CONTROL,
            title = R.string.setup_q_remote_volume_keys_title, context = R.string.setup_q_remote_volume_keys_context, summary = R.string.setup_q_remote_volume_keys_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.REMOTE_VOLUME_KEYS)), no(R.string.setup_a_no, off(SetupSetting.REMOTE_VOLUME_KEYS))),
            settingsPage = "REMOTE_CONTROL",
            covers = mapOf(SetupSetting.REMOTE_VOLUME_KEYS to Coverage.ANSWER),
            asks = { it.paired && it.on(SetupSetting.FEATURE_REMOTE_INPUT) },
        ),
        SetupQuestion(
            id = "mac_actions", section = SetupSection.MAC_CONTROL,
            title = R.string.setup_q_mac_actions_title, context = R.string.setup_q_mac_actions_context, summary = R.string.setup_q_mac_actions_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_MAC_ACTIONS)), no(R.string.setup_a_no, off(SetupSetting.FEATURE_MAC_ACTIONS))),
            settingsPage = "MEDIA",
            covers = mapOf(SetupSetting.FEATURE_MAC_ACTIONS to Coverage.ANSWER),
            asks = { it.paired },
        ),
        SetupQuestion(
            id = "media", section = SetupSection.MAC_CONTROL,
            title = R.string.setup_q_media_title, context = R.string.setup_q_media_context, summary = R.string.setup_q_media_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_MEDIA)), no(R.string.setup_a_no, off(SetupSetting.FEATURE_MEDIA))),
            settingsPage = "MEDIA",
            covers = mapOf(SetupSetting.FEATURE_MEDIA to Coverage.ANSWER),
            asks = { it.paired },
        ),
        // Phone camera and Focus
        SetupQuestion(
            id = "camera", section = SetupSection.CAMERA_FOCUS,
            title = R.string.setup_q_camera_title, context = R.string.setup_q_camera_context, summary = R.string.setup_q_camera_summary,
            answers = listOf(
                yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_CAMERA), permission = PermissionKind.CAMERA, onDenied = listOf(off(SetupSetting.FEATURE_CAMERA))),
                no(R.string.setup_a_no, off(SetupSetting.FEATURE_CAMERA)),
            ),
            settingsPage = "MEDIA",
            covers = mapOf(SetupSetting.FEATURE_CAMERA to Coverage.ANSWER),
        ),
        SetupQuestion(
            id = "focus", section = SetupSection.CAMERA_FOCUS,
            title = R.string.setup_q_focus_title, context = R.string.setup_q_focus_context, summary = R.string.setup_q_focus_summary,
            answers = listOf(
                SetupAnswer(Answers.BOTH, R.string.setup_a_focus_both, changes = listOf(on(SetupSetting.FOCUS_SHARE), on(SetupSetting.FOCUS_FOLLOW)),
                    permission = PermissionKind.DO_NOT_DISTURB, onDenied = listOf(off(SetupSetting.FOCUS_FOLLOW)), turnsOn = true),
                SetupAnswer(Answers.FOLLOW, R.string.setup_a_focus_follow, changes = listOf(off(SetupSetting.FOCUS_SHARE), on(SetupSetting.FOCUS_FOLLOW)),
                    permission = PermissionKind.DO_NOT_DISTURB, onDenied = listOf(off(SetupSetting.FOCUS_FOLLOW)), turnsOn = true),
                SetupAnswer(Answers.SHARE, R.string.setup_a_focus_share, changes = listOf(on(SetupSetting.FOCUS_SHARE), off(SetupSetting.FOCUS_FOLLOW)), turnsOn = true),
                no(R.string.setup_a_no, off(SetupSetting.FOCUS_SHARE), off(SetupSetting.FOCUS_FOLLOW)),
            ),
            settingsPage = "NOTIFICATIONS",
            covers = mapOf(SetupSetting.FOCUS_SHARE to Coverage.ANSWER, SetupSetting.FOCUS_FOLLOW to Coverage.ANSWER),
        ),
        // Quick actions
        SetupQuestion(
            id = "links", section = SetupSection.QUICK_ACTIONS,
            title = R.string.setup_q_links_title, context = R.string.setup_q_links_context, summary = R.string.setup_q_links_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_LINKS)), no(R.string.setup_a_no, off(SetupSetting.FEATURE_LINKS))),
            settingsPage = "MEDIA",
            covers = mapOf(SetupSetting.FEATURE_LINKS to Coverage.ANSWER),
        ),
        SetupQuestion(
            id = "find", section = SetupSection.QUICK_ACTIONS,
            title = R.string.setup_q_find_title, context = R.string.setup_q_find_context, summary = R.string.setup_q_find_summary,
            answers = listOf(
                yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_FIND_DEVICE), on(SetupSetting.FEATURE_PING)),
                no(R.string.setup_a_no, off(SetupSetting.FEATURE_FIND_DEVICE), off(SetupSetting.FEATURE_PING)),
            ),
            settingsPage = "MEDIA",
            covers = mapOf(SetupSetting.FEATURE_FIND_DEVICE to Coverage.ANSWER, SetupSetting.FEATURE_PING to Coverage.ANSWER),
        ),
        SetupQuestion(
            id = "battery", section = SetupSection.QUICK_ACTIONS,
            title = R.string.setup_q_battery_title, context = R.string.setup_q_battery_context, summary = R.string.setup_q_battery_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.FEATURE_BATTERY)), no(R.string.setup_a_no, off(SetupSetting.FEATURE_BATTERY))),
            settingsPage = "MEDIA",
            covers = mapOf(SetupSetting.FEATURE_BATTERY to Coverage.ANSWER),
        ),
        // Privacy
        SetupQuestion(
            id = "stats", section = SetupSection.PRIVACY,
            title = R.string.setup_q_stats_title, context = R.string.setup_q_stats_context, summary = R.string.setup_q_stats_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.LOGGING_CONNECTION)), no(R.string.setup_a_no, off(SetupSetting.LOGGING_CONNECTION))),
            settingsPage = "PRIVACY",
            covers = mapOf(SetupSetting.LOGGING_CONNECTION to Coverage.ANSWER, SetupSetting.LOGGING_DETAIL to Coverage.MORE_OPTIONS),
        ),
        SetupQuestion(
            id = "previews", section = SetupSection.PRIVACY,
            title = R.string.setup_q_previews_title, context = R.string.setup_q_previews_context, summary = R.string.setup_q_previews_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.SHOW_PREVIEWS)), no(R.string.setup_a_no, off(SetupSetting.SHOW_PREVIEWS))),
            settingsPage = "PRIVACY",
            covers = mapOf(SetupSetting.SHOW_PREVIEWS to Coverage.ANSWER),
        ),
        // Updates
        SetupQuestion(
            id = "updates", section = SetupSection.UPDATES,
            title = R.string.setup_q_updates_title, context = R.string.setup_q_updates_context, summary = R.string.setup_q_updates_summary,
            answers = listOf(
                SetupAnswer(Answers.STEADY, R.string.setup_a_updates_steady, R.string.setup_a_updates_steady_detail, listOf(SettingChange(SetupSetting.UPDATE_CHANNEL, "STABLE"))),
                SetupAnswer(Answers.EARLY, R.string.setup_a_updates_early, R.string.setup_a_updates_early_detail, listOf(SettingChange(SetupSetting.UPDATE_CHANNEL, "BETA"))),
                SetupAnswer(Answers.NEWEST, R.string.setup_a_updates_newest, R.string.setup_a_updates_newest_detail, listOf(SettingChange(SetupSetting.UPDATE_CHANNEL, "NIGHTLY"))),
            ),
            offKey = null,
            settingsPage = "UPDATES",
            covers = mapOf(SetupSetting.UPDATE_CHANNEL to Coverage.ANSWER),
        ),
        // General
        SetupQuestion(
            id = "background", section = SetupSection.GENERAL,
            title = R.string.setup_q_background_title, context = R.string.setup_q_background_context, summary = R.string.setup_q_background_summary,
            answers = listOf(
                yes(R.string.setup_a_yes, on(SetupSetting.BATTERY_EXEMPTION), permission = PermissionKind.BATTERY, onDenied = listOf(off(SetupSetting.BATTERY_EXEMPTION))),
                no(R.string.setup_a_no),
            ),
            offKey = null,
            settingsPage = "GENERAL",
            covers = mapOf(SetupSetting.BATTERY_EXEMPTION to Coverage.ANSWER, SetupSetting.OEM_CHECKLIST to Coverage.ANSWER),
            asks = { !it.on(SetupSetting.BATTERY_EXEMPTION) },
        ),
        SetupQuestion(
            id = "wifi_awake", section = SetupSection.GENERAL,
            title = R.string.setup_q_wifi_awake_title, context = R.string.setup_q_wifi_awake_context, summary = R.string.setup_q_wifi_awake_summary,
            answers = listOf(yes(R.string.setup_a_yes, on(SetupSetting.KEEP_WIFI_AWAKE)), no(R.string.setup_a_no, off(SetupSetting.KEEP_WIFI_AWAKE))),
            settingsPage = "GENERAL",
            covers = mapOf(SetupSetting.KEEP_WIFI_AWAKE to Coverage.ANSWER),
            asks = { it.facts.wifiAwakeSupported },
        ),
        SetupQuestion(
            id = "motion", section = SetupSection.GENERAL,
            title = R.string.setup_q_motion_title, context = R.string.setup_q_motion_context, summary = R.string.setup_q_motion_summary,
            answers = listOf(
                yes(R.string.setup_a_motion_yes, on(SetupSetting.REDUCE_MOTION)),
                no(R.string.setup_a_motion_no, off(SetupSetting.REDUCE_MOTION)),
            ),
            settingsPage = "GENERAL",
            covers = mapOf(SetupSetting.REDUCE_MOTION to Coverage.ANSWER),
        ),
    )

    private val byId = all.associateBy { it.id }

    fun question(id: String): SetupQuestion? = byId[id]

    /** The setting changes an answer key stands for (the duplicates question builds its own). */
    fun changes(question: SetupQuestion, key: String): List<SettingChange> = when {
        question.multiPick && key.startsWith(Answers.PICKED) ->
            listOf(SettingChange(SetupSetting.HIDDEN_NOTIFICATION_APPS, key.removePrefix(Answers.PICKED)))
        else -> question.answer(key)?.changes.orEmpty()
    }

    fun answer(question: SetupQuestion, key: String): SetupAnswer? = when {
        question.multiPick && key.startsWith(Answers.PICKED) ->
            SetupAnswer(key, R.string.setup_a_done, changes = changes(question, key), turnsOn = key.length > Answers.PICKED.length)
        else -> question.answer(key)
    }

    /** Which question covers each setting, and how. */
    val coverage: Map<SetupSetting, Pair<String, Coverage>>
        get() = buildMap {
            all.forEach { question -> question.covers.forEach { (setting, how) -> putIfAbsent(setting, question.id to how) } }
        }
}

/**
 * "What brought you here?": one tap picks a bundle of answers. Each is named exactly as its
 * Settings page, so setup and Settings use the same words; the Mac has the same five.
 */
data class SetupBundle(val id: String, @StringRes val title: Int, @StringRes val detail: Int, val answers: Map<String, String>)

object SetupBundles {
    val all: List<SetupBundle> = listOf(
        SetupBundle("clipboard", R.string.feature_clipboard, R.string.setup_bundle_clipboard, mapOf("clipboard" to Answers.AUTO, "clipboard_files" to Answers.YES)),
        SetupBundle("notifications", R.string.settings_notifications, R.string.setup_bundle_notifications, mapOf("notifications" to Answers.YES)),
        SetupBundle("calls", R.string.feature_calls, R.string.setup_bundle_calls, mapOf("calls" to Answers.YES)),
        SetupBundle("files", R.string.feature_files, R.string.setup_bundle_files, mapOf("files" to Answers.YES)),
        SetupBundle("remote", R.string.settings_remote_control, R.string.setup_bundle_remote, mapOf("remote" to Answers.YES, "mac_actions" to Answers.YES)),
    )

    /** The picked bundles' answers, then the typed ones (typing wins where both answer), in question order. */
    fun answers(picked: Set<String>, typed: Map<String, String>): Map<String, String> {
        val merged = HashMap<String, String>()
        all.filter { it.id in picked }.forEach { merged.putAll(it.answers) }
        merged.putAll(typed)
        return SetupQuestions.all.mapNotNull { question -> merged[question.id]?.let { question.id to it } }.toMap()
    }
}

/**
 * Apps people often also have on the Mac, for "Which apps already have a Mac app you use?". Only
 * the installed ones are offered (the manifest's queries name them); a pick keeps that app's
 * notifications on the phone, as Settings > Notifications > Apps does.
 */
object MacTwinApps {
    val known: List<Pair<String, String>> = listOf(
        "com.whatsapp" to "WhatsApp",
        "com.whatsapp.w4b" to "WhatsApp Business",
        "org.telegram.messenger" to "Telegram",
        "org.thoughtcrime.securesms" to "Signal",
        "com.Slack" to "Slack",
        "com.microsoft.teams" to "Microsoft Teams",
        "com.discord" to "Discord",
        "com.facebook.orca" to "Messenger",
        "com.microsoft.office.outlook" to "Outlook",
        "us.zoom.videomeetings" to "Zoom",
    )
}
