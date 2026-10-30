package dev.bridgey.android.setup

import androidx.annotation.StringRes
import dev.bridgey.android.R

/*
 * Advanced setup, the short path: the start (what brought you here, or type it), a follow-up only
 * for the features picked or typed, one page of plain switches for every other feature, one page
 * for the permissions the chosen features need, then the summary. Pure data and rules (no Android
 * types beyond string ids), so the state machine, the coverage table and the answers-to-settings
 * mapping are tested in plain JUnit. The Mac has the same feature ids, question ids, answer keys
 * and keywords (macos/Sources/BridgeyMac/SetupQuestions.swift).
 */

/** The sections, in the agreed order. */
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
 * test fails when one of these is not reachable through a follow-up, the feature switches page,
 * the permissions page or a Settings page (More options). Values are strings: "true"/"false", or
 * an enum name. [default] is the value on an install from before the off-until-chosen defaults.
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
    /** Share screen with Macs: off by default on every install, even those from before 0.10. */
    FEATURE_SCREEN("false"),
    FEATURE_LINKS("true"),
    FEATURE_FIND_DEVICE("true"),
    FEATURE_PING("true"),
    FEATURE_BATTERY("true"),
    /** Text messages: off by default on every install. */
    FEATURE_SMS("false"),
    /** Text messages > Send replies as SMS. */
    SMS_REPLY_AS_SMS("false"),
    SHOW_PREVIEWS("true"),
    /** Privacy > Logging > Connection. */
    LOGGING_CONNECTION("true"),
    /** The other Logging switches (calls, numbers, notification text, clipboard, file names, remote). */
    LOGGING_DETAIL(""),
    UPDATE_CHANNEL("STABLE"),
    /** Updates > Update all devices automatically: off on Stable unless the person chose it (on for Beta and Nightly). */
    AUTO_UPDATES("false"),
    BATTERY_EXEMPTION("false"),
    OEM_CHECKLIST(""),
    KEEP_WIFI_AWAKE("false"),
    REDUCE_MOTION("false"),
    /** v0.10 settings sync: "Settings stay the same on your devices", on the summary (on by default). */
    SETTINGS_SYNC("true"),
    /** Connect away from home (Connect anywhere). Off until chosen. */
    CONNECT_AWAY("false"),
}

/** One setting set to a value by an answer or a switch. */
data class SettingChange(val setting: SetupSetting, val value: String) {
    companion object {
        fun on(setting: SetupSetting) = SettingChange(setting, "true")
        fun off(setting: SetupSetting) = SettingChange(setting, "false")
    }
}

/** One answer button on a follow-up. */
data class SetupAnswer(
    val key: String,
    @StringRes val label: Int,
    @StringRes val detail: Int? = null,
    val changes: List<SettingChange> = emptyList(),
)

/**
 * How a setting is reached: a follow-up's answers, the feature switches page, the permissions
 * page, or its Settings page (More options on the card, Change details in Settings).
 */
enum class Coverage { ANSWER, SWITCH, PERMISSION, MORE_OPTIONS, SUMMARY }

/** What the path depends on besides the answers. [current]: the settings now. */
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
    /** Two SIM slots: Text messages asks to list the SIMs (Phone and calls). */
    val dualSim: Boolean = false,
) {
    fun value(setting: SetupSetting): String = current[setting] ?: setting.default
}

/** The settings as they are after the answers and switches so far (they are applied as given). */
class Effective(val facts: SetupFacts, private val overlay: Map<SetupSetting, String> = emptyMap()) {
    operator fun get(setting: SetupSetting): String = overlay[setting] ?: facts.value(setting)
    fun on(setting: SetupSetting): Boolean = get(setting) == "true"
    val paired: Boolean get() = facts.paired
}

/**
 * A feature with an on/off switch. [title] is exactly the name Settings uses for it (its page
 * title, or its switch on the Media and quick actions page).
 */
data class SetupFeature(
    val id: String,
    @StringRes val title: Int,
    @StringRes val detail: Int,
    val settings: List<SetupSetting>,
    /** The Settings page with its details. */
    val page: String,
) {
    val on: List<SettingChange> get() = settings.map(SettingChange::on)
    val off: List<SettingChange> get() = settings.map(SettingChange::off)
}

object SetupFeatures {
    val all: List<SetupFeature> = listOf(
        SetupFeature("clipboard", R.string.feature_clipboard, R.string.feature_clipboard_detail, listOf(SetupSetting.FEATURE_CLIPBOARD), "CLIPBOARD"),
        SetupFeature("notifications", R.string.settings_notifications, R.string.settings_notifications_detail, listOf(SetupSetting.FEATURE_NOTIFICATIONS), "NOTIFICATIONS"),
        SetupFeature("messages", R.string.feature_sms, R.string.feature_sms_detail, listOf(SetupSetting.FEATURE_SMS), "MESSAGES"),
        SetupFeature("calls", R.string.feature_calls, R.string.settings_calls_detail, listOf(SetupSetting.FEATURE_CALLS), "CALLS"),
        SetupFeature("files", R.string.feature_files, R.string.feature_files_detail, listOf(SetupSetting.FEATURE_FILES), "FILES"),
        SetupFeature("remote", R.string.settings_remote_control, R.string.settings_remote_detail, listOf(SetupSetting.FEATURE_REMOTE_INPUT), "REMOTE_CONTROL"),
        SetupFeature("media", R.string.feature_media, R.string.settings_media_detail, listOf(SetupSetting.FEATURE_MEDIA), "MEDIA"),
        SetupFeature("mac_actions", R.string.feature_mac_actions, R.string.settings_mac_actions_detail, listOf(SetupSetting.FEATURE_MAC_ACTIONS), "MEDIA"),
        SetupFeature("camera", R.string.feature_camera, R.string.settings_camera_detail, listOf(SetupSetting.FEATURE_CAMERA), "MEDIA"),
        SetupFeature("screen", R.string.feature_screen, R.string.settings_screen_detail, listOf(SetupSetting.FEATURE_SCREEN), "MEDIA"),
        SetupFeature("links", R.string.feature_links, R.string.feature_links_detail, listOf(SetupSetting.FEATURE_LINKS), "MEDIA"),
        SetupFeature("find", R.string.feature_find, R.string.settings_find_detail, listOf(SetupSetting.FEATURE_FIND_DEVICE), "MEDIA"),
        SetupFeature("ping", R.string.feature_ping, R.string.settings_ping_detail, listOf(SetupSetting.FEATURE_PING), "MEDIA"),
        SetupFeature("battery", R.string.feature_battery, R.string.settings_battery_detail, listOf(SetupSetting.FEATURE_BATTERY), "MEDIA"),
        SetupFeature("away", R.string.settings_connect_away, R.string.setup_feature_away_detail, listOf(SetupSetting.CONNECT_AWAY), "AWAY"),
    )

    private val byId = all.associateBy { it.id }

    fun feature(id: String): SetupFeature? = byId[id]

    fun isOn(feature: SetupFeature, effective: Effective): Boolean = feature.settings.all(effective::on)
}

/** A follow-up card: asked only when its [feature] was picked or typed (the pairing card: no feature). */
data class SetupQuestion(
    val id: String,
    val section: SetupSection,
    /** The feature this follows up; null for the pairing card. */
    val feature: String?,
    @StringRes val title: Int,
    @StringRes val context: Int,
    @StringRes val summary: Int,
    val answers: List<SetupAnswer>,
    /** Settings > this page: More options on the card. */
    val settingsPage: String? = null,
    val covers: Set<SetupSetting> = emptySet(),
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
    /** A feature picked (a bundle, or typed) without answering its follow-up. */
    const val PICK = "pick"
    const val AUTO = "auto"
    const val TAP = "tap"
    const val SEE = "see"
    const val BROWSE = "browse"
    const val CHANGE = "change"
    const val BOTH = "both"
    const val STEADY = "steady"
    const val EARLY = "early"
    const val NEWEST = "newest"
    const val NONE = "none"
    /** The duplicates question: "picked:" then the packages, comma separated. */
    const val PICKED = "picked:"
    /** Text messages: replies through the messaging app, or as plain SMS (Android only). */
    const val APP = "app"
    const val SMS = "sms"
}

/** The permission a chosen feature needs; refused or skipped, [offWhenRefused] goes back off. */
data class SetupPermission(
    val kind: PermissionKind,
    /** The features that need it, for the "Needed for" line. */
    val features: List<String>,
    val needed: (Effective) -> Boolean,
    val offWhenRefused: List<SettingChange> = emptyList(),
    /** A runtime permission (one system dialog for all of them); otherwise a system screen of its own. */
    val runtime: Boolean,
)

object SetupQuestions {
    private val on = SettingChange.Companion::on
    private val off = SettingChange.Companion::off

    /** The follow-ups, in order. The pairing card is first and is not tied to a feature. */
    val all: List<SetupQuestion> = listOf(
        SetupQuestion(
            id = "pair", section = SetupSection.DEVICES, feature = null,
            title = R.string.setup_q_pair_title, context = R.string.setup_q_pair_context, summary = R.string.setup_q_pair_summary,
            answers = emptyList(), covers = setOf(SetupSetting.PAIRING),
            asks = { !it.paired },
        ),
        SetupQuestion(
            id = "away", section = SetupSection.DEVICES, feature = "away",
            title = R.string.setup_q_away_title, context = R.string.setup_q_away_context, summary = R.string.setup_q_away_summary,
            answers = listOf(
                SetupAnswer(Answers.YES, R.string.setup_a_yes, changes = listOf(on(SetupSetting.CONNECT_AWAY))),
                SetupAnswer(Answers.NO, R.string.setup_a_not_now, changes = listOf(off(SetupSetting.CONNECT_AWAY))),
            ),
            settingsPage = "AWAY", covers = setOf(SetupSetting.CONNECT_AWAY),
        ),
        SetupQuestion(
            id = "clipboard", section = SetupSection.CLIPBOARD, feature = "clipboard",
            title = R.string.setup_q_clipboard_title, context = R.string.setup_q_clipboard_context, summary = R.string.setup_q_clipboard_summary,
            answers = listOf(
                SetupAnswer(Answers.AUTO, R.string.setup_a_clipboard_auto, R.string.setup_a_clipboard_auto_detail, listOf(on(SetupSetting.FEATURE_CLIPBOARD), on(SetupSetting.AUTO_CLIPBOARD))),
                SetupAnswer(Answers.TAP, R.string.setup_a_clipboard_tap, R.string.setup_a_clipboard_tap_detail, listOf(on(SetupSetting.FEATURE_CLIPBOARD), off(SetupSetting.AUTO_CLIPBOARD))),
            ),
            settingsPage = "CLIPBOARD", covers = setOf(SetupSetting.FEATURE_CLIPBOARD, SetupSetting.AUTO_CLIPBOARD),
        ),
        SetupQuestion(
            id = "notification_apps", section = SetupSection.NOTIFICATIONS, feature = "notifications",
            title = R.string.setup_q_notification_apps_title, context = R.string.setup_q_notification_apps_context, summary = R.string.setup_q_notification_apps_summary,
            answers = listOf(SetupAnswer(Answers.NONE, R.string.setup_a_notification_apps_none, changes = listOf(SettingChange(SetupSetting.HIDDEN_NOTIFICATION_APPS, "")))),
            multiPick = true, settingsPage = "NOTIFICATIONS", covers = setOf(SetupSetting.HIDDEN_NOTIFICATION_APPS),
            asks = { it.facts.duplicateApps.isNotEmpty() },
        ),
        SetupQuestion(
            id = "codes", section = SetupSection.NOTIFICATIONS, feature = "notifications",
            title = R.string.setup_q_codes_title, context = R.string.setup_q_codes_context, summary = R.string.setup_q_codes_summary,
            answers = listOf(
                SetupAnswer(Answers.YES, R.string.setup_a_codes_yes, changes = listOf(on(SetupSetting.CODES_LINK))),
                SetupAnswer(Answers.NO, R.string.setup_a_no, changes = listOf(off(SetupSetting.CODES_LINK))),
            ),
            settingsPage = "NOTIFICATIONS", covers = setOf(SetupSetting.CODES_LINK),
            asks = { it.paired && it.facts.codesLinkApplies && !it.facts.granted.contains(PermissionKind.COMPANION_LINK) },
        ),
        SetupQuestion(
            id = "messages", section = SetupSection.NOTIFICATIONS, feature = "messages",
            title = R.string.setup_q_messages_title, context = R.string.setup_q_messages_context, summary = R.string.setup_q_messages_summary,
            answers = listOf(
                SetupAnswer(Answers.APP, R.string.setup_a_messages_app, R.string.setup_a_messages_app_detail, listOf(on(SetupSetting.FEATURE_SMS), off(SetupSetting.SMS_REPLY_AS_SMS))),
                SetupAnswer(Answers.SMS, R.string.setup_a_messages_sms, R.string.setup_a_messages_sms_detail, listOf(on(SetupSetting.FEATURE_SMS), on(SetupSetting.SMS_REPLY_AS_SMS))),
            ),
            settingsPage = "MESSAGES", covers = setOf(SetupSetting.FEATURE_SMS, SetupSetting.SMS_REPLY_AS_SMS),
        ),
        SetupQuestion(
            id = "calls", section = SetupSection.CALLS, feature = "calls",
            title = R.string.setup_q_calls_title, context = R.string.setup_q_calls_context, summary = R.string.setup_q_calls_summary,
            answers = listOf(
                SetupAnswer(Answers.YES, R.string.setup_a_calls_yes, R.string.setup_a_calls_yes_detail, listOf(on(SetupSetting.FEATURE_CALLS), on(SetupSetting.DIRECT_CALLS))),
                SetupAnswer(Answers.SEE, R.string.setup_a_calls_see, R.string.setup_a_calls_see_detail, listOf(on(SetupSetting.FEATURE_CALLS), off(SetupSetting.DIRECT_CALLS))),
            ),
            settingsPage = "CALLS", covers = setOf(SetupSetting.FEATURE_CALLS, SetupSetting.DIRECT_CALLS),
        ),
        SetupQuestion(
            id = "files_browse", section = SetupSection.FILES, feature = "files",
            title = R.string.setup_q_files_browse_title, context = R.string.setup_q_files_browse_context, summary = R.string.setup_q_files_browse_summary,
            answers = listOf(
                SetupAnswer(Answers.BROWSE, R.string.setup_a_files_browse_look, R.string.setup_a_files_browse_look_detail, listOf(on(SetupSetting.ALLOW_BROWSE), off(SetupSetting.ALLOW_REPLACE))),
                SetupAnswer(Answers.CHANGE, R.string.setup_a_files_browse_change, R.string.setup_a_files_browse_change_detail, listOf(on(SetupSetting.ALLOW_BROWSE), on(SetupSetting.ALLOW_REPLACE))),
                SetupAnswer(Answers.NO, R.string.setup_a_no, changes = listOf(off(SetupSetting.ALLOW_BROWSE), off(SetupSetting.ALLOW_REPLACE))),
            ),
            settingsPage = "FILES", covers = setOf(SetupSetting.ALLOW_BROWSE, SetupSetting.ALLOW_REPLACE),
        ),
        SetupQuestion(
            id = "remote_volume_keys", section = SetupSection.MAC_CONTROL, feature = "remote",
            title = R.string.setup_q_remote_volume_keys_title, context = R.string.setup_q_remote_volume_keys_context, summary = R.string.setup_q_remote_volume_keys_summary,
            answers = listOf(
                SetupAnswer(Answers.YES, R.string.setup_a_yes, changes = listOf(on(SetupSetting.REMOTE_VOLUME_KEYS))),
                SetupAnswer(Answers.NO, R.string.setup_a_no, changes = listOf(off(SetupSetting.REMOTE_VOLUME_KEYS))),
            ),
            settingsPage = "REMOTE_CONTROL", covers = setOf(SetupSetting.REMOTE_VOLUME_KEYS),
        ),
        SetupQuestion(
            id = "screen", section = SetupSection.CAMERA_FOCUS, feature = "screen",
            title = R.string.setup_q_screen_title, context = R.string.setup_q_screen_context, summary = R.string.setup_q_screen_summary,
            answers = listOf(
                SetupAnswer(Answers.YES, R.string.setup_a_screen_yes, R.string.setup_a_screen_yes_detail, listOf(on(SetupSetting.FEATURE_SCREEN))),
                SetupAnswer(Answers.NO, R.string.setup_a_no, changes = listOf(off(SetupSetting.FEATURE_SCREEN))),
            ),
            settingsPage = "MEDIA", covers = setOf(SetupSetting.FEATURE_SCREEN),
        ),
    )

    /**
     * Answers only typing gives (no card): Do Not Disturb in step, the update channel (which also sets
     * Update all devices automatically: off for Steady, on for Early and Newest), and that setting on
     * its own. Applied in this order (sorted by id, as on the Mac), so "beta, but no automatic
     * updates" ends with automatic updates off. Their settings are on their Settings pages too.
     */
    val typedOnly: Map<String, Map<String, List<SettingChange>>> = mapOf(
        "focus" to mapOf(Answers.BOTH to listOf(on(SetupSetting.FOCUS_SHARE), on(SetupSetting.FOCUS_FOLLOW)), Answers.NO to listOf(off(SetupSetting.FOCUS_SHARE), off(SetupSetting.FOCUS_FOLLOW))),
        "updates" to mapOf(
            Answers.STEADY to listOf(SettingChange(SetupSetting.UPDATE_CHANNEL, "STABLE"), off(SetupSetting.AUTO_UPDATES)),
            Answers.EARLY to listOf(SettingChange(SetupSetting.UPDATE_CHANNEL, "BETA"), on(SetupSetting.AUTO_UPDATES)),
            Answers.NEWEST to listOf(SettingChange(SetupSetting.UPDATE_CHANNEL, "NIGHTLY"), on(SetupSetting.AUTO_UPDATES)),
        ),
        "updates_auto" to mapOf(Answers.YES to listOf(on(SetupSetting.AUTO_UPDATES)), Answers.NO to listOf(off(SetupSetting.AUTO_UPDATES))),
    )

    /** The permissions page: what the chosen features need, in the Permissions order. */
    val permissions: List<SetupPermission> = listOf(
        SetupPermission(PermissionKind.NOTIFICATION_ACCESS, listOf("notifications"), { it.on(SetupSetting.FEATURE_NOTIFICATIONS) },
            listOf(off(SetupSetting.FEATURE_NOTIFICATIONS)), runtime = false),
        // Screen sharing needs it for the ongoing "being shared" notification with Stop; Android shows its own
        // consent dialog for every share, which is not a permission and is never asked here.
        SetupPermission(PermissionKind.POST_NOTIFICATIONS, listOf("files", "calls", "find", "screen"),
            { e -> e.facts.sdkInt >= 33 && listOf(SetupSetting.FEATURE_FILES, SetupSetting.FEATURE_CALLS, SetupSetting.FEATURE_FIND_DEVICE, SetupSetting.FEATURE_SCREEN).any(e::on) },
            listOf(off(SetupSetting.FEATURE_SCREEN)), runtime = true),
        SetupPermission(PermissionKind.PHONE_CALLS, listOf("calls", "messages"),
            { (it.on(SetupSetting.FEATURE_CALLS) && it.on(SetupSetting.DIRECT_CALLS)) || (it.on(SetupSetting.FEATURE_SMS) && it.facts.dualSim) },
            listOf(off(SetupSetting.DIRECT_CALLS)), runtime = true),
        SetupPermission(PermissionKind.PHOTOS, listOf("files"), { it.on(SetupSetting.FEATURE_FILES) && it.on(SetupSetting.ALLOW_BROWSE) }, runtime = true),
        SetupPermission(PermissionKind.CAMERA, listOf("camera"), { it.on(SetupSetting.FEATURE_CAMERA) }, listOf(off(SetupSetting.FEATURE_CAMERA)), runtime = true),
        // The same link serves codes and Text messages: Android 15 shows a linked listener who sent an SMS,
        // so a reply from a notification finds its conversation. One link for both; never a second.
        SetupPermission(PermissionKind.COMPANION_LINK, listOf("notifications", "messages"),
            { e -> e.on(SetupSetting.FEATURE_NOTIFICATIONS) && (e.on(SetupSetting.CODES_LINK) || (e.on(SetupSetting.FEATURE_SMS) && e.facts.codesLinkApplies)) },
            listOf(off(SetupSetting.CODES_LINK)), runtime = false),
        SetupPermission(PermissionKind.DO_NOT_DISTURB, listOf("notifications"), { it.on(SetupSetting.FOCUS_FOLLOW) }, listOf(off(SetupSetting.FOCUS_FOLLOW)), runtime = false),
        // Text messages stays off without SMS access; without contacts it shows numbers instead of names.
        SetupPermission(PermissionKind.SMS, listOf("messages"), { it.on(SetupSetting.FEATURE_SMS) }, listOf(off(SetupSetting.FEATURE_SMS)), runtime = true),
        SetupPermission(PermissionKind.CONTACTS, listOf("messages"), { it.on(SetupSetting.FEATURE_SMS) }, runtime = true),
        SetupPermission(PermissionKind.BATTERY, emptyList(), { e -> SetupFeatures.all.any { SetupFeatures.isOn(it, e) } },
            runtime = false),
    )

    /** Settings that left the path: reached from their Settings page (More options, Change details in Settings). */
    val moreOptions: Map<SetupSetting, String> = mapOf(
        SetupSetting.CLIPBOARD_FILES to "CLIPBOARD",
        SetupSetting.SCREENSHOT_SEND to "CLIPBOARD",
        SetupSetting.CLIPBOARD_EAGER_LIMIT to "CLIPBOARD",
        SetupSetting.BACKGROUND_CLIPBOARD to "CLIPBOARD",
        SetupSetting.FOCUS_SHARE to "NOTIFICATIONS",
        SetupSetting.FOCUS_FOLLOW to "NOTIFICATIONS",
        SetupSetting.FOLDER_MODE to "FILES",
        SetupSetting.FOLDER_DEFAULT_PLACE to "FILES",
        SetupSetting.FOLDER_CONFLICT to "FILES",
        SetupSetting.PLACES to "FILES",
        SetupSetting.REMOTE_POINTER_SPEED to "REMOTE_CONTROL",
        SetupSetting.SHOW_PREVIEWS to "PRIVACY",
        SetupSetting.LOGGING_CONNECTION to "PRIVACY",
        SetupSetting.LOGGING_DETAIL to "PRIVACY",
        SetupSetting.UPDATE_CHANNEL to "UPDATES",
        SetupSetting.AUTO_UPDATES to "UPDATES",
        SetupSetting.OEM_CHECKLIST to "GENERAL",
        SetupSetting.KEEP_WIFI_AWAKE to "GENERAL",
        SetupSetting.REDUCE_MOTION to "GENERAL",
    )

    /** Settings the permissions page turns on by asking. */
    private val byPermission: Map<SetupSetting, PermissionKind> = mapOf(
        SetupSetting.NOTIFICATION_ACCESS to PermissionKind.NOTIFICATION_ACCESS,
        SetupSetting.APP_NOTIFICATIONS to PermissionKind.POST_NOTIFICATIONS,
        SetupSetting.BATTERY_EXEMPTION to PermissionKind.BATTERY,
    )

    private val byId = all.associateBy { it.id }

    fun question(id: String): SetupQuestion? = byId[id]

    fun permission(kind: PermissionKind): SetupPermission? = permissions.firstOrNull { it.kind == kind }

    /** The setting changes an answer key stands for (the duplicates question builds its own). */
    fun changes(question: SetupQuestion, key: String): List<SettingChange> = when {
        question.multiPick && key.startsWith(Answers.PICKED) ->
            listOf(SettingChange(SetupSetting.HIDDEN_NOTIFICATION_APPS, key.removePrefix(Answers.PICKED)))
        else -> question.answer(key)?.changes.orEmpty()
    }

    fun answer(question: SetupQuestion, key: String): SetupAnswer? = when {
        question.multiPick && key.startsWith(Answers.PICKED) -> SetupAnswer(key, R.string.setup_a_done, changes = changes(question, key))
        else -> question.answer(key)
    }

    /** How every setting is reached, and from where (a question, the switches, the permissions, or a Settings page). */
    val coverage: Map<SetupSetting, Pair<String, Coverage>>
        get() = buildMap {
            all.forEach { question -> question.covers.forEach { putIfAbsent(it, question.id to Coverage.ANSWER) } }
            SetupFeatures.all.forEach { feature -> feature.settings.forEach { putIfAbsent(it, "switches" to Coverage.SWITCH) } }
            byPermission.forEach { (setting, kind) -> putIfAbsent(setting, kind.name to Coverage.PERMISSION) }
            moreOptions.forEach { (setting, page) -> putIfAbsent(setting, page to Coverage.MORE_OPTIONS) }
            SetupSummary.settings.forEach { putIfAbsent(it, "summary" to Coverage.SUMMARY) }
        }
}

/**
 * "What brought you here?": one tap picks a bundle. Each is named exactly as its Settings page, so
 * setup and Settings use the same words; the Mac has the same six. [answers] are keyed by feature
 * or follow-up id; [Answers.PICK] picks a feature and still asks its follow-up.
 */
data class SetupBundle(val id: String, @StringRes val title: Int, @StringRes val detail: Int, val answers: Map<String, String>)

object SetupBundles {
    val all: List<SetupBundle> = listOf(
        SetupBundle("clipboard", R.string.feature_clipboard, R.string.setup_bundle_clipboard, mapOf("clipboard" to Answers.PICK)),
        SetupBundle("notifications", R.string.settings_notifications, R.string.setup_bundle_notifications, mapOf("notifications" to Answers.PICK)),
        SetupBundle("messages", R.string.feature_sms, R.string.setup_bundle_messages, mapOf("messages" to Answers.PICK)),
        SetupBundle("calls", R.string.feature_calls, R.string.setup_bundle_calls, mapOf("calls" to Answers.PICK)),
        SetupBundle("files", R.string.feature_files, R.string.setup_bundle_files, mapOf("files" to Answers.PICK)),
        SetupBundle("remote", R.string.settings_remote_control, R.string.setup_bundle_remote_screen, mapOf("remote" to Answers.PICK, "mac_actions" to Answers.PICK, "screen" to Answers.PICK)),
        SetupBundle("away", R.string.settings_connect_away, R.string.setup_bundle_away, mapOf("away" to Answers.PICK)),
    )

    /**
     * "Get started quickly": pair, then clipboard when you tap Send, and phone notifications. Only
     * features that are off are changed, so running it again keeps a clipboard set to automatic.
     */
    val essentials: List<Pair<SetupFeature, List<SettingChange>>> = listOf(
        SetupFeatures.feature("clipboard")!! to listOf(SettingChange.on(SetupSetting.FEATURE_CLIPBOARD), SettingChange.off(SetupSetting.AUTO_CLIPBOARD)),
        SetupFeatures.feature("notifications")!! to listOf(SettingChange.on(SetupSetting.FEATURE_NOTIFICATIONS)),
    )

    fun essentialChanges(effective: Effective): List<SettingChange> =
        essentials.filterNot { (feature, _) -> SetupFeatures.isOn(feature, effective) }.flatMap { it.second }

    /** The picked bundles' answers, then the typed ones (typing wins where both answer). */
    fun answers(picked: Set<String>, typed: Map<String, String>): Map<String, String> {
        val merged = LinkedHashMap<String, String>()
        all.filter { it.id in picked }.forEach { merged.putAll(it.answers) }
        merged.putAll(typed)
        return merged
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
