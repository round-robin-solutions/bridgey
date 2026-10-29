import Foundation

/*
 * Advanced setup, the short path: the start (what brought you here, or type it), a follow-up only
 * for the features picked or typed, one page of plain switches for every other feature, one page
 * for the permissions the chosen features need, then the summary. Pure data and rules, so the
 * state machine, the coverage table and the answers-to-settings mapping are tested in XCTest.
 * Android has the same feature ids, follow-up ids, answer keys and keywords
 * (android/.../setup/SetupQuestions.kt, SetupTyped.kt); what only one device has is left out on
 * the other.
 */

/// The sections, in the agreed order.
enum SetupSection: String, CaseIterable {
    case devices, clipboard, notifications, calls, files, macControl, quickActions

    var title: String {
        switch self {
        case .devices: L10n.setup("setup.section.devices", fallback: "Devices")
        case .clipboard: L10n.setup("setup.section.clipboard", fallback: "Clipboard")
        case .notifications: L10n.setup("setup.section.notifications", fallback: "Notifications")
        case .calls: L10n.setup("setup.section.calls", fallback: "Calls")
        case .files: L10n.setup("setup.section.files", fallback: "Files")
        case .macControl: L10n.setup("setup.section.macControl", fallback: "Mac control")
        case .quickActions: L10n.setup("setup.section.quickActions", fallback: "Quick actions")
        }
    }
}

/// Every setting the 0.10 beta 1 Advanced setup showed on this Mac (its ten live Settings panes).
/// The coverage test fails when one of these is not reachable through a follow-up, the feature
/// switches, the permissions page or its Settings page. Values are strings: "true"/"false", or a
/// raw value.
enum SetupSetting: String, CaseIterable {
    // Devices
    case pairing, deviceFeatures, deviceAutoClipboard, batteryAlerts
    // Clipboard
    case featureClipboard, autoClipboard, clipboardFiles, clipboardEagerLimit, shortcutClipboard
    // Notifications
    case featureNotifications, macNotifications, codesEnabled, codesEngine, codesAutoCopy, codesModel, codesPhoneLink
    case notificationHistory, focusShare, focusFollow, focusShortcuts
    // Settings > Text messages (sms_draft1)
    case featureMessages, smsKeepOnMac
    // Calls
    case featureCalls, phoneLinks, ringForCalls, pauseForCalls, shortcutCall
    // Files
    case featureFiles, receiveFolder, folderIncludeHidden, folderIncludeSystem, folderReceiveMode, folderConflict
    case tagReceivedFiles, cameraCopyToClipboard, sendImageMode, sendOptionsDetail, menuBarDropMode
    // Media and actions
    case featureMedia, mediaPlayer, featureLinks, openLinksRightAway, featurePing, featureFindDevice, featureBattery
    case featureMacActions, macActionSwitches, macActionsGrant, macActionApps, macActionShortcuts, macActionsLog
    case shortcutLink, shortcutPing
    // Remote control
    case featureRemoteInput, remoteGrant, accessibility, remoteLog
    // Phone screen (Remote control page)
    case featureScreen
    // Privacy
    case showPreviews, loggingConnection, loggingDetail
    // Updates
    case updateChannel, updatesAutomatic
    // General
    case launchAtLogin, reduceMotion, shortcutShift
    // Settings sync: the summary's own switch (v0.10)
    case settingsSync

    /// The value on an install from before the off-until-chosen defaults (BridgeySettings' old defaults).
    var defaultValue: String {
        switch self {
        case .featureClipboard, .autoClipboard, .clipboardFiles, .featureNotifications, .featureCalls, .ringForCalls,
             .featureFiles, .featureLinks, .featurePing, .featureFindDevice, .featureBattery, .showPreviews,
             .loggingConnection, .updatesAutomatic, .smsKeepOnMac, .settingsSync:
            "true"
        case .codesEngine: "local"
        case .folderReceiveMode: "fixed"
        case .sendImageMode: "original"
        case .mediaPlayer: "off"
        case .updateChannel: "stable"
        default: "false"
        }
    }
}

/// How a setting is reached: a follow-up's answers, the feature switches, the permissions page,
/// or its Settings page (More options on a card, Change details in Settings).
enum SetupCoverage: Equatable {
    /// `summary`: a switch on the summary itself (Settings stay the same on your devices).
    case answer, featureSwitch, permission, moreOptions, summary
}

/// One setting set to a value by an answer or a switch.
struct SettingChange: Equatable, Hashable {
    let setting: SetupSetting
    let value: String

    static func on(_ setting: SetupSetting) -> SettingChange { SettingChange(setting: setting, value: "true") }
    static func off(_ setting: SetupSetting) -> SettingChange { SettingChange(setting: setting, value: "false") }
    static func set(_ setting: SetupSetting, _ value: String) -> SettingChange { SettingChange(setting: setting, value: value) }
}

/// One answer button on a follow-up.
struct SetupAnswer {
    let key: String
    let label: String
    var detail: String?
    var changes: [SettingChange] = []
    /// Hidden on this Mac (Cloud codes when the build has no relay).
    var shown: (SetupFacts) -> Bool = { _ in true }
}

/// What the path depends on besides the answers. `current`: the settings now.
struct SetupFacts {
    var paired = false
    var current: [SetupSetting: String] = [:]
    /// Not refused: what a feature may stay on with (Local Network and Automation count until macOS says no,
    /// because macOS only asks when they are first used).
    var granted: Set<SetupPermission> = []
    /// Allowed now (the permissions page shows while something needed is not).
    var allowed: Set<SetupPermission> = []
    /// The build has a relay for Cloud codes.
    var codesAvailable = true

    func value(_ setting: SetupSetting) -> String { current[setting] ?? setting.defaultValue }
}

/// The settings as they are after this run's answers and switches (they are applied as given).
struct SetupEffective {
    let facts: SetupFacts
    var overlay: [SetupSetting: String] = [:]

    subscript(_ setting: SetupSetting) -> String { overlay[setting] ?? facts.value(setting) }
    func on(_ setting: SetupSetting) -> Bool { self[setting] == "true" }
    var paired: Bool { facts.paired }
}

/// A feature with an on/off switch, named exactly as Settings names it (its page title, or its
/// switch on the Media and quick actions page).
struct SetupFeature: Identifiable {
    let id: String
    let title: String
    let detail: String
    let on: [SettingChange]
    let off: [SettingChange]
    /// The setting that says whether it is on.
    let main: SetupSetting
    /// The Settings page with its details.
    let pane: SettingsPane

    var settings: [SetupSetting] { Array(Set((on + off).map(\.setting))).sorted { $0.rawValue < $1.rawValue } }
}

enum SetupFeatures {
    static let all: [SetupFeature] = [
        SetupFeature(id: "clipboard", title: SettingsPane.clipboard.title, detail: BridgeyFeature.clipboard.subtitle,
                     on: [.on(.featureClipboard)], off: [.off(.featureClipboard)], main: .featureClipboard, pane: .clipboard),
        SetupFeature(id: "notifications", title: SettingsPane.notifications.title, detail: BridgeyFeature.notifications.subtitle,
                     on: [.on(.featureNotifications)], off: [.off(.featureNotifications)], main: .featureNotifications, pane: .notifications),
        SetupFeature(id: "messages", title: textMessagesTitle,
                     detail: L10n.setup("setup.feature.messages.detail", fallback: "Your phone\u{2019}s texts in a Messages window, and Reply on text notifications"),
                     on: [.on(.featureMessages)], off: [.off(.featureMessages)], main: .featureMessages, pane: .messages),
        SetupFeature(id: "calls", title: SettingsPane.calls.title, detail: BridgeyFeature.calls.subtitle,
                     on: [.on(.featureCalls)], off: [.off(.featureCalls)], main: .featureCalls, pane: .calls),
        SetupFeature(id: "files", title: SettingsPane.files.title, detail: BridgeyFeature.files.subtitle,
                     on: [.on(.featureFiles)], off: [.off(.featureFiles)], main: .featureFiles, pane: .files),
        SetupFeature(id: "remote", title: SettingsPane.remoteControl.title, detail: BridgeyFeature.remoteInput.subtitle,
                     on: [.on(.featureRemoteInput), .on(.remoteGrant)], off: [.off(.featureRemoteInput), .off(.remoteGrant)],
                     main: .featureRemoteInput, pane: .remoteControl),
        SetupFeature(id: "screen", title: PhoneScreenSettings.switchTitle, detail: PhoneScreenSettings.switchDetail,
                     on: [.on(.featureScreen)], off: [.off(.featureScreen)], main: .featureScreen, pane: .remoteControl),
        SetupFeature(id: "media", title: BridgeyFeature.media.title, detail: BridgeyFeature.media.subtitle,
                     on: [.on(.featureMedia)], off: [.off(.featureMedia)], main: .featureMedia, pane: .media),
        SetupFeature(id: "mac_actions", title: BridgeyFeature.macActions.title, detail: BridgeyFeature.macActions.subtitle,
                     on: [.on(.featureMacActions), .on(.macActionsGrant), .set(.macActionSwitches, "lock,sleep,volume")],
                     off: [.off(.featureMacActions)], main: .featureMacActions, pane: .media),
        SetupFeature(id: "links", title: BridgeyFeature.links.title, detail: BridgeyFeature.links.subtitle,
                     on: [.on(.featureLinks)], off: [.off(.featureLinks)], main: .featureLinks, pane: .media),
        SetupFeature(id: "find", title: BridgeyFeature.findDevice.title, detail: BridgeyFeature.findDevice.subtitle,
                     on: [.on(.featureFindDevice)], off: [.off(.featureFindDevice)], main: .featureFindDevice, pane: .media),
        SetupFeature(id: "ping", title: BridgeyFeature.ping.title, detail: BridgeyFeature.ping.subtitle,
                     on: [.on(.featurePing)], off: [.off(.featurePing)], main: .featurePing, pane: .media),
        SetupFeature(id: "battery", title: BridgeyFeature.battery.title, detail: BridgeyFeature.battery.subtitle,
                     on: [.on(.featureBattery)], off: [.off(.featureBattery)], main: .featureBattery, pane: .media),
    ]

    static func feature(_ id: String) -> SetupFeature? { all.first { $0.id == id } }

    /// Text messages has its own Settings page; its switch, bundle and page share this name.
    static var textMessagesTitle: String { L10n.text("sms.title", fallback: "Text messages") }

    static func isOn(_ feature: SetupFeature, _ effective: SetupEffective) -> Bool { effective.on(feature.main) }
}

/// A follow-up card: asked only when its `feature` was picked or typed (the pairing card: none).
struct SetupQuestion {
    let id: String
    let section: SetupSection
    /// The feature this follows up; nil for the pairing card.
    let feature: String?
    let title: String
    let context: String
    /// The plain words in the summary.
    let summary: String
    var answers: [SetupAnswer]
    /// The Settings page behind More options.
    var pane: SettingsPane?
    var covers: Set<SetupSetting> = []
    var asks: (SetupEffective) -> Bool = { _ in true }

    func answer(_ key: String) -> SetupAnswer? { answers.first { $0.key == key } }
    func visibleAnswers(_ facts: SetupFacts) -> [SetupAnswer] { answers.filter { $0.shown(facts) } }
}

/// Answer keys, the same on Android.
enum SetupAnswerKey {
    static let yes = "yes", no = "no", auto = "auto", tap = "tap"
    /// A feature picked (a bundle, or typed) without answering its follow-up.
    static let pick = "pick"
    static let onMac = "on_mac", cloud = "cloud"
    static let music = "music", spotify = "spotify"
    static let both = "both"
    static let rightAway = "right_away", wait = "wait"
    static let steady = "steady", early = "early", newest = "newest"
}

/// A permission a chosen feature needs; refused or skipped, `offWhenRefused` goes back off.
struct SetupPermissionNeed {
    let permission: SetupPermission
    /// The features that need it, for the "Needed for" line (empty: every feature).
    let features: [String]
    let needed: (SetupEffective) -> Bool
    var offWhenRefused: [SettingChange] = []

    /// "Needed for: Notifications, Calls".
    var neededFor: String {
        let names = features.compactMap { SetupFeatures.feature($0)?.title }
        let list = names.isEmpty ? L10n.setup("setup.permissions.everything", fallback: "every feature") : ListFormatter.localizedString(byJoining: names)
        return String(format: L10n.setup("setup.permissions.neededFor", fallback: "Needed for: %@"), list)
    }
}

enum SetupQuestions {
    private static func yesNo(_ setting: SetupSetting) -> [SetupAnswer] {
        [SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.yes", fallback: "Yes"), changes: [.on(setting)]),
         SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.no", fallback: "No"), changes: [.off(setting)])]
    }

    /// The follow-ups, in order: at most one per feature. The pairing card is first and has no feature.
    static let all: [SetupQuestion] = [
        SetupQuestion(
            id: "pair", section: .devices, feature: nil,
            title: L10n.setup("setup.q.pair.title", fallback: "Let\u{2019}s connect your phone"),
            context: L10n.setup("setup.q.pair.context", fallback: "Pairing happens once, so your phone and this Mac can trust each other."),
            summary: L10n.setup("setup.q.pair.summary", fallback: "Paired with your phone"),
            answers: [], pane: .devices, covers: [.pairing],
            asks: { !$0.paired }
        ),
        SetupQuestion(
            id: "clipboard", section: .clipboard, feature: "clipboard",
            title: L10n.setup("setup.q.clipboard.title", fallback: "How should copying work?"),
            context: L10n.setup("setup.q.clipboard.context", fallback: "Text and links you copy move between your phone and this Mac."),
            summary: L10n.setup("setup.q.clipboard.summary", fallback: "Copy and paste between devices"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.auto, label: L10n.setup("setup.a.clipboard.auto", fallback: "Automatically"),
                            detail: L10n.setup("setup.a.clipboard.auto.detail", fallback: "Copy here, paste there. Nothing to click."),
                            changes: [.on(.featureClipboard), .on(.autoClipboard)]),
                SetupAnswer(key: SetupAnswerKey.tap, label: L10n.setup("setup.a.clipboard.tap", fallback: "Only when I click Send"),
                            detail: L10n.setup("setup.a.clipboard.tap.detail", fallback: "Send what you copied from the menu bar or a shortcut."),
                            changes: [.on(.featureClipboard), .off(.autoClipboard)]),
            ],
            pane: .clipboard, covers: [.featureClipboard, .autoClipboard]
        ),
        SetupQuestion(
            id: "codes", section: .notifications, feature: "notifications",
            title: L10n.setup("setup.q.codes.title", fallback: "Do you want codes from text messages shown on this Mac?"),
            context: L10n.setup("setup.q.codes.context", fallback: "One-time codes show up ready to copy. You can download the code model later."),
            summary: L10n.setup("setup.q.codes.summary", fallback: "Codes from messages"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.onMac, label: L10n.setup("setup.a.codes.onMac", fallback: "Yes, read them on this Mac"),
                            detail: L10n.setup("setup.a.codes.onMac.detail", fallback: "Private: a small model finds the code here. Download it from Settings."),
                            changes: [.on(.codesEnabled), .set(.codesEngine, "local")]),
                SetupAnswer(key: SetupAnswerKey.cloud, label: L10n.setup("setup.a.codes.cloud", fallback: "Yes, using the cloud"),
                            detail: L10n.setup("setup.a.codes.cloud.detail", fallback: "Message text with a code goes through Round Robin\u{2019}s relay to Cloudflare, which finds the code. Nothing is kept there."),
                            changes: [.on(.codesEnabled), .set(.codesEngine, "cloud")],
                            shown: { $0.codesAvailable }),
                SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.no", fallback: "No"), changes: [.off(.codesEnabled)]),
            ],
            pane: .notifications, covers: [.codesEnabled, .codesEngine]
        ),
        SetupQuestion(
            id: "messages", section: .notifications, feature: "messages",
            title: L10n.setup("setup.q.messages.title", fallback: "Keep your conversations on this Mac?"),
            context: L10n.setup("setup.q.messages.context", fallback: "Your texts stay on the phone either way. Kept here, they open instantly and only your account can read them."),
            summary: L10n.setup("setup.q.messages.summary", fallback: "Text messages"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.messages.yes", fallback: "Yes, so they open instantly"),
                            changes: [.on(.featureMessages), .on(.smsKeepOnMac)]),
                SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.messages.no", fallback: "No, load them from the phone each time"),
                            changes: [.on(.featureMessages), .off(.smsKeepOnMac)]),
            ],
            pane: .messages, covers: [.featureMessages, .smsKeepOnMac]
        ),
        SetupQuestion(
            id: "calls_ring", section: .calls, feature: "calls",
            title: L10n.setup("setup.q.callsRing.title", fallback: "Ring on this Mac when your phone rings?"),
            context: L10n.setup("setup.q.callsRing.context", fallback: "A soft ring repeats until you answer, decline or hide the call."),
            summary: L10n.setup("setup.q.callsRing.summary", fallback: "Ring for incoming calls"),
            answers: yesNo(.ringForCalls),
            pane: .calls, covers: [.ringForCalls]
        ),
        SetupQuestion(
            id: "files_photos", section: .files, feature: "files",
            title: L10n.setup("setup.q.filesPhotos.title", fallback: "Should photos be made smaller before sending?"),
            context: L10n.setup("setup.q.filesPhotos.context", fallback: "Smaller photos send faster and take less space on your phone."),
            summary: L10n.setup("setup.q.filesPhotos.summary", fallback: "Smaller photos when sending"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.filesPhotos.yes", fallback: "Yes, make them smaller"),
                            changes: [.set(.sendImageMode, "optimize")]),
                SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.filesPhotos.no", fallback: "No, send the originals"),
                            changes: [.set(.sendImageMode, "original")]),
            ],
            pane: .files, covers: [.sendImageMode]
        ),
        SetupQuestion(
            id: "media", section: .macControl, feature: "media",
            title: L10n.setup("setup.q.media.title", fallback: "Which player do you use on this Mac?"),
            context: L10n.setup("setup.q.media.context", fallback: "Play, pause and skip from your phone. macOS asks once to let Bridgey control the player."),
            summary: L10n.setup("setup.q.media.summary", fallback: "Music controls from your phone"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.music, label: L10n.setup("setup.a.media.music", fallback: "Apple Music"),
                            changes: [.on(.featureMedia), .set(.mediaPlayer, "music")]),
                SetupAnswer(key: SetupAnswerKey.spotify, label: L10n.setup("setup.a.media.spotify", fallback: "Spotify"),
                            changes: [.on(.featureMedia), .set(.mediaPlayer, "spotify")]),
            ],
            pane: .media, covers: [.featureMedia, .mediaPlayer]
        ),
        SetupQuestion(
            id: "screen", section: .macControl, feature: "screen",
            title: L10n.setup("setup.q.screen.title", fallback: "See your phone\u{2019}s screen on this Mac?"),
            context: L10n.setup("setup.q.screen.context", fallback: "View only, in a window. Your phone asks you every time and shows a notification while it shares."),
            summary: L10n.setup("setup.q.screen.summary", fallback: "Phone screen on this Mac"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.screen.yes", fallback: "Yes, when I ask for it"),
                            changes: [.on(.featureScreen)]),
                SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.no", fallback: "No"), changes: [.off(.featureScreen)]),
            ],
            pane: .remoteControl, covers: [.featureScreen]
        ),
        SetupQuestion(
            id: "links", section: .quickActions, feature: "links",
            title: L10n.setup("setup.q.links.title", fallback: "Open links from your phone right away?"),
            context: L10n.setup("setup.q.links.context", fallback: "Share a link from your phone and it opens in your browser here."),
            summary: L10n.setup("setup.q.links.summary", fallback: "Open links on the other device"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.rightAway, label: L10n.setup("setup.a.links.rightAway", fallback: "Yes, open them right away"),
                            changes: [.on(.featureLinks), .on(.openLinksRightAway)]),
                SetupAnswer(key: SetupAnswerKey.wait, label: L10n.setup("setup.a.links.wait", fallback: "No, let me open them"),
                            changes: [.on(.featureLinks), .off(.openLinksRightAway)]),
            ],
            pane: .media, covers: [.featureLinks, .openLinksRightAway]
        ),
    ]

    /// Answers only typing gives (no card): Do Not Disturb in step, and the update channel. Their
    /// settings are on their Settings pages too.
    static let typedOnly: [String: [String: [SettingChange]]] = [
        "focus": [SetupAnswerKey.both: [.on(.focusShare), .on(.focusFollow)], SetupAnswerKey.no: [.off(.focusShare), .off(.focusFollow)]],
        "updates": [SetupAnswerKey.steady: [.set(.updateChannel, "stable")],
                    SetupAnswerKey.early: [.set(.updateChannel, "beta")],
                    SetupAnswerKey.newest: [.set(.updateChannel, "nightly")]],
    ]

    /// The typed-only answers as they read in the preview and the summary.
    static func typedOnlyLabel(_ id: String, _ key: String) -> (title: String, value: String, pane: SettingsPane)? {
        switch (id, key) {
        case ("focus", SetupAnswerKey.both):
            (L10n.setup("setup.q.focus.summary", fallback: "Do Not Disturb in step"), L10n.setup("setup.a.focus.both", fallback: "Yes, both ways"), .notifications)
        case ("focus", SetupAnswerKey.no):
            (L10n.setup("setup.q.focus.summary", fallback: "Do Not Disturb in step"), L10n.setup("setup.a.no", fallback: "No"), .notifications)
        case ("updates", SetupAnswerKey.steady):
            (L10n.setup("setup.q.updates.summary", fallback: "Updates"), L10n.setup("setup.a.updates.steady", fallback: "Steady"), .updates)
        case ("updates", SetupAnswerKey.early):
            (L10n.setup("setup.q.updates.summary", fallback: "Updates"), L10n.setup("setup.a.updates.early", fallback: "Early"), .updates)
        case ("updates", SetupAnswerKey.newest):
            (L10n.setup("setup.q.updates.summary", fallback: "Updates"), L10n.setup("setup.a.updates.newest", fallback: "Newest every day"), .updates)
        default: nil
        }
    }

    /// The permissions page: what the chosen features need, in this order.
    static let permissions: [SetupPermissionNeed] = [
        SetupPermissionNeed(permission: .localNetwork, features: [],
                            needed: { effective in SetupFeatures.all.contains { SetupFeatures.isOn($0, effective) } }),
        SetupPermissionNeed(permission: .notifications, features: ["notifications", "messages", "calls"],
                            needed: { $0.on(.featureNotifications) || $0.on(.featureMessages) || $0.on(.featureCalls) },
                            offWhenRefused: [.off(.featureNotifications)]),
        SetupPermissionNeed(permission: .accessibility, features: ["remote", "mac_actions"],
                            needed: { $0.on(.featureRemoteInput) || ($0.on(.featureMacActions) && $0[.macActionSwitches].split(separator: ",").contains("lock")) },
                            offWhenRefused: [.off(.featureRemoteInput), .off(.remoteGrant), .set(.macActionSwitches, "sleep,volume")]),
        SetupPermissionNeed(permission: .automation, features: ["media"],
                            needed: { $0.on(.featureMedia) },
                            offWhenRefused: [.off(.featureMedia)]),
        // The phone-to-Mac link (Android 15+) serves codes and Text messages: the Mac advertises over Bluetooth once.
        SetupPermissionNeed(permission: .bluetooth, features: ["notifications", "messages"],
                            needed: { $0.on(.featureNotifications) && ($0.on(.codesEnabled) || $0.on(.featureMessages)) }),
    ]

    static func need(_ permission: SetupPermission) -> SetupPermissionNeed? { permissions.first { $0.permission == permission } }

    /// Settings that are not set by a follow-up, a switch or a permission: reached from their Settings page.
    static let moreOptions: [SetupSetting: SettingsPane] = [
        .deviceFeatures: .devices, .deviceAutoClipboard: .devices, .batteryAlerts: .devices,
        .clipboardFiles: .clipboard, .clipboardEagerLimit: .clipboard, .shortcutClipboard: .clipboard,
        .codesAutoCopy: .notifications, .codesModel: .notifications, .codesPhoneLink: .notifications,
        .notificationHistory: .notifications, .focusShare: .notifications, .focusFollow: .notifications, .focusShortcuts: .notifications,
        .phoneLinks: .calls, .pauseForCalls: .calls, .shortcutCall: .calls,
        .receiveFolder: .files, .folderIncludeHidden: .files, .folderIncludeSystem: .files, .folderReceiveMode: .files,
        .folderConflict: .files, .tagReceivedFiles: .files, .cameraCopyToClipboard: .files, .sendOptionsDetail: .files, .menuBarDropMode: .files,
        .macActionApps: .media, .macActionShortcuts: .media, .macActionsLog: .media, .shortcutLink: .media, .shortcutPing: .media,
        .remoteLog: .remoteControl,
        .showPreviews: .privacy, .loggingConnection: .privacy, .loggingDetail: .privacy,
        .updateChannel: .updates, .updatesAutomatic: .updates,
        .launchAtLogin: .general, .reduceMotion: .general, .shortcutShift: .general,
    ]

    /// Settings with their own switch on the summary.
    static let bySummary: [SetupSetting] = [.settingsSync]

    /// Settings the permissions page turns on by asking.
    static let byPermission: [SetupSetting: SetupPermission] = [.macNotifications: .notifications, .accessibility: .accessibility]

    static func question(_ id: String) -> SetupQuestion? { all.first { $0.id == id } }

    static func index(_ id: String) -> Int? { all.firstIndex { $0.id == id } }

    static func changes(_ question: SetupQuestion, _ key: String) -> [SettingChange] { question.answer(key)?.changes ?? [] }

    /// How every setting is reached, and from where: a follow-up, the switches, a permission or a Settings page.
    static var coverage: [SetupSetting: (place: String, how: SetupCoverage)] {
        var table: [SetupSetting: (place: String, how: SetupCoverage)] = [:]
        for question in all {
            for setting in question.covers.sorted(by: { $0.rawValue < $1.rawValue }) where table[setting] == nil { table[setting] = (question.id, .answer) }
        }
        for feature in SetupFeatures.all {
            for setting in feature.settings where table[setting] == nil { table[setting] = ("switches", .featureSwitch) }
        }
        for (setting, permission) in byPermission where table[setting] == nil { table[setting] = (permission.rawValue, .permission) }
        for setting in bySummary where table[setting] == nil { table[setting] = ("summary", .summary) }
        for (setting, pane) in moreOptions where table[setting] == nil { table[setting] = (pane.rawValue, .moreOptions) }
        return table
    }
}

// MARK: - Type what you want

/// "Type what you want": plain keyword rules, on this Mac, in English and Russian. No model is
/// used here, even when codes from messages use one. Every match is shown for confirmation
/// before anything changes. A keyword matches the start of a word ("notif" matches
/// "notifications"); a no, not, without (нет, не, без) up to three words before it turns the
/// answer into No. Android has the same rules and the same test sentences.
enum SetupTyped {
    struct Rule {
        let id: String
        let answer: String
        let stems: [String]
        var negatable = true
    }

    static let rules: [Rule] = [
        Rule(id: "clipboard", answer: SetupAnswerKey.pick, stems: ["copy", "copi", "paste", "clipboard", "копир", "скопир", "встав", "буфер"]),
        Rule(id: "notifications", answer: SetupAnswerKey.pick, stems: ["notif", "alert", "whatsapp", "telegram", "уведомл", "оповещ"]),
        Rule(id: "codes", answer: SetupAnswerKey.onMac, stems: ["code", "otp", "код"]),
        Rule(id: "messages", answer: SetupAnswerKey.pick, stems: ["sms", "texts", "texting", "смс", "эсэмэс"]),
        Rule(id: "calls", answer: SetupAnswerKey.pick, stems: ["call", "звон", "вызов"]),
        Rule(id: "files", answer: SetupAnswerKey.pick, stems: ["file", "photo", "picture", "folder", "файл", "фото", "папк", "снимк"]),
        Rule(id: "remote", answer: SetupAnswerKey.pick, stems: ["touchpad", "trackpad", "mouse", "slide", "presentation", "тачпад", "мыш", "слайд", "презентац", "пульт"]),
        Rule(id: "mac_actions", answer: SetupAnswerKey.pick, stems: ["lock", "sleep", "volume", "блокир", "сон", "громк"]),
        Rule(id: "media", answer: SetupAnswerKey.pick, stems: ["music", "spotify", "song", "музык", "песн"]),
        Rule(id: "camera", answer: SetupAnswerKey.pick, stems: ["camera", "камер"]),
        Rule(id: "screen", answer: SetupAnswerKey.pick, stems: ["mirror", "screen shar", "share screen", "share my screen", "share the screen",
                                                               "see my screen", "phone screen", "phone's screen", "трансляц",
                                                               "показ экран", "показать экран", "демонстрац", "экран телефона"]),
        Rule(id: "focus", answer: SetupAnswerKey.both, stems: ["dnd", "focus", "фокус"]),
        Rule(id: "links", answer: SetupAnswerKey.pick, stems: ["link", "url", "browser", "ссылк", "браузер"]),
        Rule(id: "find", answer: SetupAnswerKey.pick, stems: ["find my", "lost", "ring", "найти", "потерял"]),
        Rule(id: "battery", answer: SetupAnswerKey.pick, stems: ["battery", "батаре", "заряд"]),
        Rule(id: "updates", answer: SetupAnswerKey.newest, stems: ["nightly", "newest", "every day", "ночн", "каждый день"], negatable: false),
        Rule(id: "updates", answer: SetupAnswerKey.early, stems: ["beta", "early", "бета", "раньше"], negatable: false),
        Rule(id: "updates", answer: SetupAnswerKey.steady, stems: ["stable", "steady", "стабил"], negatable: false),
    ]

    /// Every id typing can answer on this Mac: the features, their follow-ups, Focus and updates.
    static var targets: [String] {
        var ids: [String] = []
        for id in SetupFeatures.all.map(\.id) + SetupQuestions.all.map(\.id) + SetupQuestions.typedOnly.keys.sorted() where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private static let negations: Set<String> = ["no", "not", "don't", "dont", "without", "never", "нет", "не", "без", "никаких"]

    /// Names that contain a negation word; read as one word, so they negate nothing.
    private static let names: [(String, String)] = [("do not disturb", "dnd"), ("не беспокоить", "dnd")]

    static func words(_ text: String) -> [String] {
        var lower = text.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "\u{2019}", with: "'")
        for (name, token) in names { lower = lower.replacingOccurrences(of: name, with: token) }
        let separators = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted
        return lower.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// Whether `key` is an answer `id` takes on this Mac (a feature takes pick and no).
    private static func takes(_ id: String, _ key: String) -> Bool {
        if SetupFeatures.feature(id) != nil, key == SetupAnswerKey.pick || key == SetupAnswerKey.no { return true }
        if SetupQuestions.question(id)?.answer(key) != nil { return true }
        return SetupQuestions.typedOnly[id]?[key] != nil
    }

    /// The answers `text` asks for, by feature or follow-up id, in rule order, for the ids this Mac
    /// has. The first matching rule per id wins. A negated mention without a No is ignored.
    static func match(_ text: String, available: [String] = targets) -> [(id: String, key: String)] {
        let tokens = words(text)
        guard !tokens.isEmpty else { return [] }
        var found: [(id: String, key: String)] = []
        var seen: Set<String> = []
        for rule in rules where available.contains(rule.id) && !seen.contains(rule.id) {
            guard let hit = rule.stems.lazy.compactMap({ find(tokens, $0) }).first else { continue }
            seen.insert(rule.id)
            let negated = rule.negatable && tokens[max(0, hit - 3)..<hit].contains { negations.contains($0) }
            let key = negated ? SetupAnswerKey.no : rule.answer
            if takes(rule.id, key) { found.append((rule.id, key)) }
        }
        return found
    }

    /// Where `stem` starts in `tokens`: each of its words must match, the last one as a prefix.
    private static func find(_ tokens: [String], _ stem: String) -> Int? {
        let parts = words(stem)
        guard !parts.isEmpty, parts.count <= tokens.count else { return nil }
        return (0...(tokens.count - parts.count)).first { start in
            parts.indices.allSatisfy { index in
                index == parts.count - 1 ? tokens[start + index].hasPrefix(parts[index]) : tokens[start + index] == parts[index]
            }
        }
    }
}

// MARK: - What brought you here

/// One-click starts on the Intro ("What brought you here?"). Each is named exactly as its Settings
/// page; `answers` are keyed by feature or follow-up id, and `pick` still asks the follow-up.
struct SetupBundle: Identifiable {
    let id: String
    let pane: SettingsPane
    let detail: String
    let answers: [(id: String, key: String)]

    var title: String { pane.title }
}

enum SetupBundles {
    static let all: [SetupBundle] = [
        SetupBundle(id: "clipboard", pane: .clipboard,
                    detail: L10n.setup("setup.bundle.clipboard", fallback: "Copy on one device, paste on the other."),
                    answers: [("clipboard", SetupAnswerKey.pick)]),
        SetupBundle(id: "notifications", pane: .notifications,
                    detail: L10n.setup("setup.bundle.notifications", fallback: "Your phone\u{2019}s notifications on this Mac."),
                    answers: [("notifications", SetupAnswerKey.pick)]),
        SetupBundle(id: "messages", pane: .messages,
                    detail: L10n.setup("setup.bundle.messages", fallback: "Read and answer your phone\u{2019}s texts here."),
                    answers: [("messages", SetupAnswerKey.pick)]),
        SetupBundle(id: "calls", pane: .calls,
                    detail: L10n.setup("setup.bundle.calls", fallback: "See who\u{2019}s calling, and answer here."),
                    answers: [("calls", SetupAnswerKey.pick)]),
        SetupBundle(id: "files", pane: .files,
                    detail: L10n.setup("setup.bundle.files", fallback: "Send files and photos both ways."),
                    answers: [("files", SetupAnswerKey.pick)]),
        SetupBundle(id: "remote", pane: .remoteControl,
                    detail: L10n.setup("setup.bundle.remote", fallback: "Your phone as a touchpad and slide clicker, and its screen on this Mac."),
                    answers: [("remote", SetupAnswerKey.pick), ("mac_actions", SetupAnswerKey.pick), ("screen", SetupAnswerKey.pick)]),
    ]

    /// "Get started quickly": pair, then clipboard when you click Send, and your phone's
    /// notifications. Only features that are off change, so a rerun keeps an automatic clipboard.
    static let essentials: [(feature: String, changes: [SettingChange])] = [
        ("clipboard", [.on(.featureClipboard), .off(.autoClipboard)]),
        ("notifications", [.on(.featureNotifications)]),
    ]

    static func essentialChanges(_ effective: SetupEffective) -> [SettingChange] {
        essentials.filter { item in SetupFeatures.feature(item.feature).map { !SetupFeatures.isOn($0, effective) } ?? false }.flatMap(\.changes)
    }

    /// The picked bundles' answers, then the typed ones (typing wins where both answer), in order.
    static func answers(picked: Set<String>, typed: [(id: String, key: String)]) -> [(id: String, key: String)] {
        var merged: [(id: String, key: String)] = []
        func put(_ id: String, _ key: String) {
            if let index = merged.firstIndex(where: { $0.id == id }) { merged[index].key = key } else { merged.append((id, key)) }
        }
        for bundle in all where picked.contains(bundle.id) { for (id, key) in bundle.answers { put(id, key) } }
        for (id, key) in typed { put(id, key) }
        return merged
    }
}

// MARK: - Facts from the live settings

extension SetupFacts {
    /// What the path reads from Settings now. `sendImageMode`: SendPreferences' image mode.
    static func make(model: SettingsModel, sendImageMode: String = "original") -> SetupFacts {
        func bool(_ value: Bool) -> String { value ? "true" : "false" }
        func feature(_ feature: BridgeyFeature) -> String {
            bool(feature == .media || feature.needsDeviceGrant ? model.globalFeatures[feature] == true : model.globalFeatures[feature] != false)
        }
        let switches = [MacActionSwitch.lock, .sleep, .volume].filter { model.macActions.isOn($0) }.map(\.rawValue)
        let current: [SetupSetting: String] = [
            .pairing: bool(!model.trustedDevices.isEmpty),
            .featureClipboard: feature(.clipboard),
            .autoClipboard: bool(model.autoClipboard),
            .clipboardFiles: bool(model.clipboardFiles),
            .featureNotifications: feature(.notifications),
            .macNotifications: bool(model.notificationsAuthorized),
            .codesEnabled: bool(model.codesEnabled),
            .codesEngine: model.codesEngine.rawValue,
            .featureMessages: bool(model.smsEnabled),
            .smsKeepOnMac: bool(model.smsKeepOnMac),
            .notificationHistory: bool(model.historyEnabled),
            .focusShare: bool(model.focusSync.share),
            .focusFollow: bool(model.focusSync.follow),
            .featureCalls: feature(.calls),
            .ringForCalls: bool(model.ringForCalls),
            .pauseForCalls: bool(model.pauseForCalls),
            .featureFiles: feature(.files),
            .folderReceiveMode: model.folderReceiveMode.rawValue,
            .cameraCopyToClipboard: bool(model.cameraCopyToClipboard),
            .sendImageMode: sendImageMode,
            .featureRemoteInput: feature(.remoteInput),
            .featureScreen: bool(model.phoneScreenEnabled),
            .remoteGrant: bool(model.trustedDevices.contains { model.remoteGrant(for: $0.id) }),
            .accessibility: bool(model.accessibilityTrusted),
            .featureMacActions: feature(.macActions),
            .macActionSwitches: switches.joined(separator: ","),
            .macActionsGrant: bool(model.trustedDevices.contains { model.deviceFeatures[$0.id]?[.macActions] == true }),
            .featureMedia: feature(.media),
            .mediaPlayer: model.mediaPlayer.rawValue,
            .featureLinks: feature(.links),
            .openLinksRightAway: bool(model.openLinksRightAway),
            .featureFindDevice: feature(.findDevice),
            .featurePing: feature(.ping),
            .featureBattery: feature(.battery),
            .showPreviews: bool(model.showPreviews),
            .loggingConnection: bool(model.logging.connection),
            .updateChannel: model.channel.rawValue,
            .updatesAutomatic: bool(model.automaticallyChecks),
            .launchAtLogin: bool(model.launchAtLogin),
            .reduceMotion: bool(model.reduceMotion),
            .settingsSync: bool(model.settingsSyncEnabled),
        ]
        var allowed = Set(model.setup.permissions.filter { $0.system == .allowed }.map(\.permission))
        if model.accessibilityTrusted { allowed.insert(.accessibility) }
        var granted = allowed
        // Local Network and Music or Spotify: macOS asks the first time they are used, so only a refusal blocks.
        for permission in [SetupPermission.localNetwork, .automation]
            where model.setup.permissions.first(where: { $0.permission == permission })?.system != .denied {
            granted.insert(permission)
        }
        return SetupFacts(paired: !model.trustedDevices.isEmpty, current: current, granted: granted, allowed: allowed, codesAvailable: model.codesAvailable)
    }
}
