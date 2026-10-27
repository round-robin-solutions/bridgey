import Foundation

/*
 * Advanced setup as questions. One question per card, in plain words; each answer
 * turns on or configures the settings behind it, and later questions adapt to earlier answers.
 * Pure data and rules, so the state machine, the coverage table and the answers-to-settings
 * mapping are tested in XCTest. Android has the same question ids, order, answer keys and
 * keywords (android/.../setup/SetupQuestions.kt, SetupTyped.kt); questions only one device can
 * answer are left out on the other.
 */

/// The sections, in the agreed order. Mac control questions need a paired phone.
enum SetupSection: String, CaseIterable {
    case devices, clipboard, notifications, calls, files, macControl, cameraFocus, quickActions, privacy, updates, general

    var title: String {
        switch self {
        case .devices: L10n.setup("setup.section.devices", fallback: "Devices")
        case .clipboard: L10n.setup("setup.section.clipboard", fallback: "Clipboard")
        case .notifications: L10n.setup("setup.section.notifications", fallback: "Notifications")
        case .calls: L10n.setup("setup.section.calls", fallback: "Calls")
        case .files: L10n.setup("setup.section.files", fallback: "Files")
        case .macControl: L10n.setup("setup.section.macControl", fallback: "Mac control")
        case .cameraFocus: L10n.setup("setup.section.cameraFocus", fallback: "Camera and Focus")
        case .quickActions: L10n.setup("setup.section.quickActions", fallback: "Quick actions")
        case .privacy: L10n.setup("setup.section.privacy", fallback: "Privacy")
        case .updates: L10n.setup("setup.section.updates", fallback: "Updates")
        case .general: L10n.setup("setup.section.general", fallback: "General")
        }
    }
}

/// Every setting the 0.10 beta 1 Advanced setup showed on this Mac (its ten live Settings panes).
/// The coverage test fails when one of these is not reachable through a question, a follow-up or a
/// question's More options. Values are strings: "true"/"false", or a raw value.
enum SetupSetting: String, CaseIterable {
    // Devices
    case pairing, deviceFeatures, deviceAutoClipboard, batteryAlerts
    // Clipboard
    case featureClipboard, autoClipboard, clipboardFiles, clipboardEagerLimit, shortcutClipboard
    // Notifications
    case featureNotifications, macNotifications, codesEnabled, codesEngine, codesAutoCopy, codesModel, codesPhoneLink
    case notificationHistory, focusShare, focusFollow, focusShortcuts
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
    // Privacy
    case showPreviews, loggingConnection, loggingDetail
    // Updates
    case updateChannel, updatesAutomatic
    // General
    case launchAtLogin, reduceMotion, shortcutShift

    /// The value before anything is chosen (BridgeySettings' defaults).
    var defaultValue: String {
        switch self {
        case .featureClipboard, .autoClipboard, .clipboardFiles, .featureNotifications, .featureCalls, .ringForCalls,
             .featureFiles, .featureLinks, .featurePing, .featureFindDevice, .featureBattery, .showPreviews,
             .loggingConnection, .updatesAutomatic:
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

/// How a question covers a setting: its answers set it, or its More options page holds it.
enum SetupCoverage: Equatable {
    case answer, moreOptions
}

/// One setting set to a value by an answer.
struct SettingChange: Equatable, Hashable {
    let setting: SetupSetting
    let value: String

    static func on(_ setting: SetupSetting) -> SettingChange { SettingChange(setting: setting, value: "true") }
    static func off(_ setting: SetupSetting) -> SettingChange { SettingChange(setting: setting, value: "false") }
    static func set(_ setting: SetupSetting, _ value: String) -> SettingChange { SettingChange(setting: setting, value: value) }
}

/// One answer button. `turnsOn`: the summary lists it under what was turned on.
struct SetupAnswer {
    let key: String
    let label: String
    var detail: String?
    var changes: [SettingChange] = []
    /// Asked right after this answer, with the permission's own explanation.
    var permission: SetupPermission?
    /// What goes back off when `permission` is not allowed.
    var onDenied: [SettingChange] = []
    /// The line on the next card when the permission was not allowed; nil uses the generic line.
    var deniedNote: String?
    var turnsOn = false
    /// Hidden on this Mac (Cloud codes when the build has no relay).
    var shown: (SetupFacts) -> Bool = { _ in true }
}

/// What the questions depend on besides earlier answers. `current`: the settings now.
struct SetupFacts {
    var paired = false
    var current: [SetupSetting: String] = [:]
    var granted: Set<SetupPermission> = []
    /// The build has a relay for Cloud codes.
    var codesAvailable = true

    func value(_ setting: SetupSetting) -> String { current[setting] ?? setting.defaultValue }
}

/// The settings as they are after the answers so far (answers are applied as they are given).
struct SetupEffective {
    let facts: SetupFacts
    var overlay: [SetupSetting: String] = [:]

    subscript(_ setting: SetupSetting) -> String { overlay[setting] ?? facts.value(setting) }
    func on(_ setting: SetupSetting) -> Bool { self[setting] == "true" }
    var paired: Bool { facts.paired }
}

/// A question card. `asks` decides whether it is shown; false means its answer is implied.
struct SetupQuestion {
    let id: String
    let section: SetupSection
    let title: String
    let context: String
    /// The plain words in the summary ("Copy and paste between devices").
    let summary: String
    var answers: [SetupAnswer]
    /// The answer that turns this off, for the summary's switch.
    var offKey: String? = SetupAnswerKey.no
    /// The Settings page behind More options and Change in Settings.
    var pane: SettingsPane?
    var covers: [SetupSetting: SetupCoverage] = [:]
    var asks: (SetupEffective) -> Bool = { _ in true }

    func answer(_ key: String) -> SetupAnswer? { answers.first { $0.key == key } }
    func visibleAnswers(_ facts: SetupFacts) -> [SetupAnswer] { answers.filter { $0.shown(facts) } }
}

/// Answer keys, the same on Android.
enum SetupAnswerKey {
    static let yes = "yes", no = "no", auto = "auto", tap = "tap", text = "text"
    static let onMac = "on_mac", cloud = "cloud"
    static let fixed = "fixed", ask = "ask"
    static let music = "music", spotify = "spotify"
    static let copy = "copy", save = "save"
    static let both = "both", follow = "follow", share = "share"
    static let rightAway = "right_away", wait = "wait"
    static let steady = "steady", early = "early", newest = "newest"
}

enum SetupQuestions {
    private static func yes(_ changes: [SettingChange], permission: SetupPermission? = nil, onDenied: [SettingChange] = [], deniedNote: String? = nil) -> SetupAnswer {
        SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.yes", fallback: "Yes"), changes: changes,
                    permission: permission, onDenied: onDenied, deniedNote: deniedNote, turnsOn: true)
    }

    private static func no(_ changes: [SettingChange]) -> SetupAnswer {
        SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.no", fallback: "No"), changes: changes)
    }

    private static func yesNo(_ setting: SetupSetting) -> [SetupAnswer] { [yes([.on(setting)]), no([.off(setting)])] }

    /// The Mac questions, in order. The pairing card is first and is not an answer card.
    static let all: [SetupQuestion] = [
        SetupQuestion(
            id: "pair", section: .devices,
            title: L10n.setup("setup.q.pair.title", fallback: "Let\u{2019}s connect your phone"),
            context: L10n.setup("setup.q.pair.context", fallback: "Pairing happens once, so your phone and this Mac can trust each other."),
            summary: L10n.setup("setup.q.pair.summary", fallback: "Paired with your phone"),
            answers: [], offKey: nil, pane: .devices,
            covers: [.pairing: .answer],
            asks: { !$0.paired }
        ),
        // Clipboard
        SetupQuestion(
            id: "clipboard", section: .clipboard,
            title: L10n.setup("setup.q.clipboard.title", fallback: "Do you want to copy on one device and paste on the other?"),
            context: L10n.setup("setup.q.clipboard.context", fallback: "Text and links you copy move between your phone and this Mac."),
            summary: L10n.setup("setup.q.clipboard.summary", fallback: "Copy and paste between devices"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.auto, label: L10n.setup("setup.a.clipboard.auto", fallback: "Yes, automatically"),
                            detail: L10n.setup("setup.a.clipboard.auto.detail", fallback: "Copy here, paste there. Nothing to click."),
                            changes: [.on(.featureClipboard), .on(.autoClipboard)], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.tap, label: L10n.setup("setup.a.clipboard.tap", fallback: "Only when I click Send"),
                            detail: L10n.setup("setup.a.clipboard.tap.detail", fallback: "Send what you copied from the menu bar or a shortcut."),
                            changes: [.on(.featureClipboard), .off(.autoClipboard)], turnsOn: true),
                no([.off(.featureClipboard)]),
            ],
            pane: .clipboard,
            covers: [.featureClipboard: .answer, .autoClipboard: .answer, .shortcutClipboard: .moreOptions]
        ),
        SetupQuestion(
            id: "clipboard_files", section: .clipboard,
            title: L10n.setup("setup.q.clipboardFiles.title", fallback: "Should images and files copy too?"),
            context: L10n.setup("setup.q.clipboardFiles.context", fallback: "Big items move only when you paste, so copying stays quick."),
            summary: L10n.setup("setup.q.clipboardFiles.summary", fallback: "Images and files on the clipboard"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.clipboardFiles.yes", fallback: "Yes, images and files too"),
                            changes: [.on(.clipboardFiles)], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.text, label: L10n.setup("setup.a.clipboardFiles.text", fallback: "Only text"),
                            changes: [.off(.clipboardFiles)]),
            ],
            offKey: SetupAnswerKey.text, pane: .clipboard,
            covers: [.clipboardFiles: .answer, .clipboardEagerLimit: .moreOptions],
            asks: { $0.on(.featureClipboard) }
        ),
        // Notifications
        SetupQuestion(
            id: "notifications", section: .notifications,
            title: L10n.setup("setup.q.notifications.title", fallback: "Do you want your phone\u{2019}s notifications on this Mac?"),
            context: L10n.setup("setup.q.notifications.context", fallback: "Messages and alerts from your phone show up here too."),
            summary: L10n.setup("setup.q.notifications.summary", fallback: "Phone notifications on this Mac"),
            answers: [
                yes([.on(.featureNotifications), .on(.macNotifications)], permission: .notifications,
                    onDenied: [.off(.featureNotifications), .off(.macNotifications)]),
                no([.off(.featureNotifications)]),
            ],
            pane: .notifications,
            covers: [.featureNotifications: .answer, .macNotifications: .answer]
        ),
        SetupQuestion(
            id: "codes", section: .notifications,
            title: L10n.setup("setup.q.codes.title", fallback: "Do you want codes from text messages shown on this Mac?"),
            context: L10n.setup("setup.q.codes.context", fallback: "One-time codes show up ready to copy. You can download the code model later."),
            summary: L10n.setup("setup.q.codes.summary", fallback: "Codes from messages"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.onMac, label: L10n.setup("setup.a.codes.onMac", fallback: "Yes, read them on this Mac"),
                            detail: L10n.setup("setup.a.codes.onMac.detail", fallback: "Private: a small model finds the code here. Download it from Settings."),
                            changes: [.on(.codesEnabled), .set(.codesEngine, "local")], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.cloud, label: L10n.setup("setup.a.codes.cloud", fallback: "Yes, using the cloud"),
                            detail: L10n.setup("setup.a.codes.cloud.detail", fallback: "Message text with a code goes through Round Robin\u{2019}s relay to Cloudflare, which finds the code. Nothing is kept there."),
                            changes: [.on(.codesEnabled), .set(.codesEngine, "cloud")], turnsOn: true,
                            shown: { $0.codesAvailable }),
                no([.off(.codesEnabled)]),
            ],
            pane: .notifications,
            covers: [.codesEnabled: .answer, .codesEngine: .answer, .codesAutoCopy: .moreOptions, .codesModel: .moreOptions, .codesPhoneLink: .moreOptions],
            asks: { $0.on(.featureNotifications) }
        ),
        SetupQuestion(
            id: "notification_history", section: .notifications,
            title: L10n.setup("setup.q.notificationHistory.title", fallback: "Keep a list of your phone\u{2019}s notifications on this Mac?"),
            context: L10n.setup("setup.q.notificationHistory.context", fallback: "So you can look back at what came in. It stays on this Mac for 7 days."),
            summary: L10n.setup("setup.q.notificationHistory.summary", fallback: "Notification history on this Mac"),
            answers: yesNo(.notificationHistory),
            pane: .notifications,
            covers: [.notificationHistory: .answer],
            asks: { $0.on(.featureNotifications) }
        ),
        // Calls
        SetupQuestion(
            id: "calls", section: .calls,
            title: L10n.setup("setup.q.calls.title", fallback: "Do you take calls on your Mac?"),
            context: L10n.setup("setup.q.calls.context", fallback: "See who\u{2019}s calling here, and answer, decline or start calls from this Mac."),
            summary: L10n.setup("setup.q.calls.summary", fallback: "Phone calls on this Mac"),
            answers: yesNo(.featureCalls),
            pane: .calls,
            covers: [.featureCalls: .answer, .shortcutCall: .moreOptions]
        ),
        SetupQuestion(
            id: "calls_ring", section: .calls,
            title: L10n.setup("setup.q.callsRing.title", fallback: "Ring on this Mac when your phone rings?"),
            context: L10n.setup("setup.q.callsRing.context", fallback: "A soft ring repeats until you answer, decline or hide the call."),
            summary: L10n.setup("setup.q.callsRing.summary", fallback: "Ring for incoming calls"),
            answers: yesNo(.ringForCalls),
            pane: .calls,
            covers: [.ringForCalls: .answer],
            asks: { $0.on(.featureCalls) }
        ),
        SetupQuestion(
            id: "calls_pause", section: .calls,
            title: L10n.setup("setup.q.callsPause.title", fallback: "Pause music on this Mac during a call?"),
            context: L10n.setup("setup.q.callsPause.context", fallback: "It stays paused after the call, until you play it again."),
            summary: L10n.setup("setup.q.callsPause.summary", fallback: "Pause music during calls"),
            answers: yesNo(.pauseForCalls),
            pane: .calls,
            covers: [.pauseForCalls: .answer],
            asks: { $0.on(.featureCalls) }
        ),
        SetupQuestion(
            id: "calls_links", section: .calls,
            title: L10n.setup("setup.q.callsLinks.title", fallback: "Call numbers you click on this Mac with your phone?"),
            context: L10n.setup("setup.q.callsLinks.context", fallback: "Phone links in browsers and other apps open in Bridgey. The browser still asks first."),
            summary: L10n.setup("setup.q.callsLinks.summary", fallback: "Phone links open in Bridgey"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.yes", fallback: "Yes"), changes: [.on(.phoneLinks)], turnsOn: true),
                no([]),
            ],
            offKey: nil, pane: .calls,
            covers: [.phoneLinks: .answer],
            asks: { $0.on(.featureCalls) && !$0.on(.phoneLinks) }
        ),
        // Files
        SetupQuestion(
            id: "files", section: .files,
            title: L10n.setup("setup.q.files.title", fallback: "Do you want to send files and photos between your phone and Mac?"),
            context: L10n.setup("setup.q.files.context", fallback: "Drop or share them, and they land on the other device."),
            summary: L10n.setup("setup.q.files.summary", fallback: "Sending files and photos"),
            answers: yesNo(.featureFiles),
            pane: .files,
            covers: [.featureFiles: .answer, .receiveFolder: .moreOptions, .tagReceivedFiles: .moreOptions]
        ),
        SetupQuestion(
            id: "files_folder", section: .files,
            title: L10n.setup("setup.q.filesFolder.title", fallback: "When your phone sends a folder, where should it go?"),
            context: L10n.setup("setup.q.filesFolder.context", fallback: "Folders keep their structure either way."),
            summary: L10n.setup("setup.q.filesFolder.summary", fallback: "Folders from your phone"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.fixed, label: L10n.setup("setup.a.filesFolder.fixed", fallback: "Always to Received files"),
                            changes: [.set(.folderReceiveMode, "fixed")]),
                SetupAnswer(key: SetupAnswerKey.ask, label: L10n.setup("setup.a.filesFolder.ask", fallback: "Ask me on this Mac each time"),
                            changes: [.set(.folderReceiveMode, "ask")]),
            ],
            offKey: nil, pane: .files,
            covers: [.folderReceiveMode: .answer, .folderConflict: .moreOptions, .folderIncludeHidden: .moreOptions, .folderIncludeSystem: .moreOptions],
            asks: { $0.on(.featureFiles) }
        ),
        SetupQuestion(
            id: "files_photos", section: .files,
            title: L10n.setup("setup.q.filesPhotos.title", fallback: "Should photos be made smaller before sending?"),
            context: L10n.setup("setup.q.filesPhotos.context", fallback: "Smaller photos send faster and take less space on your phone."),
            summary: L10n.setup("setup.q.filesPhotos.summary", fallback: "Smaller photos when sending"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.filesPhotos.yes", fallback: "Yes, make them smaller"),
                            changes: [.set(.sendImageMode, "optimize")], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.filesPhotos.no", fallback: "No, send the originals"),
                            changes: [.set(.sendImageMode, "original")]),
            ],
            pane: .files,
            covers: [.sendImageMode: .answer, .sendOptionsDetail: .moreOptions, .menuBarDropMode: .moreOptions],
            asks: { $0.on(.featureFiles) }
        ),
        // Mac control: only with a phone paired.
        SetupQuestion(
            id: "remote", section: .macControl,
            title: L10n.setup("setup.q.remote.title", fallback: "Do you want to control this Mac from your phone, like a touchpad or a slide clicker?"),
            context: L10n.setup("setup.q.remote.context", fallback: "Your paired phone may move the pointer, type and change slides. Stop at any time."),
            summary: L10n.setup("setup.q.remote.summary", fallback: "Control this Mac from your phone"),
            answers: [
                yes([.on(.featureRemoteInput), .on(.remoteGrant), .on(.accessibility)], permission: .accessibility,
                    onDenied: [.off(.featureRemoteInput), .off(.remoteGrant), .off(.accessibility)]),
                no([.off(.featureRemoteInput), .off(.remoteGrant)]),
            ],
            pane: .remoteControl,
            covers: [.featureRemoteInput: .answer, .remoteGrant: .answer, .accessibility: .answer, .remoteLog: .moreOptions],
            asks: { $0.paired }
        ),
        SetupQuestion(
            id: "mac_actions", section: .macControl,
            title: L10n.setup("setup.q.macActions.title", fallback: "Lock, sleep and volume from your phone?"),
            context: L10n.setup("setup.q.macActions.context", fallback: "Quick buttons on your phone for this Mac. Apps and Shortcuts can be added in Settings."),
            summary: L10n.setup("setup.q.macActions.summary", fallback: "Lock, sleep and volume from your phone"),
            answers: [
                yes([.on(.featureMacActions), .set(.macActionSwitches, "lock,sleep,volume"), .on(.macActionsGrant)], permission: .accessibility,
                    onDenied: [.set(.macActionSwitches, "sleep,volume")],
                    deniedNote: L10n.setup("setup.q.macActions.denied", fallback: "Accessibility not allowed, so Lock stays off. Sleep and volume work.")),
                no([.off(.featureMacActions)]),
            ],
            pane: .media,
            covers: [.featureMacActions: .answer, .macActionSwitches: .answer, .macActionsGrant: .answer,
                     .macActionApps: .moreOptions, .macActionShortcuts: .moreOptions, .macActionsLog: .moreOptions],
            asks: { $0.paired }
        ),
        SetupQuestion(
            id: "media", section: .macControl,
            title: L10n.setup("setup.q.media.title", fallback: "Control music on this Mac from your phone?"),
            context: L10n.setup("setup.q.media.context", fallback: "Play, pause and skip from your phone. macOS asks once to let Bridgey control the player."),
            summary: L10n.setup("setup.q.media.summary", fallback: "Music controls from your phone"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.music, label: L10n.setup("setup.a.media.music", fallback: "Yes, Apple Music"),
                            changes: [.on(.featureMedia), .set(.mediaPlayer, "music")], permission: .automation, turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.spotify, label: L10n.setup("setup.a.media.spotify", fallback: "Yes, Spotify"),
                            changes: [.on(.featureMedia), .set(.mediaPlayer, "spotify")], permission: .automation, turnsOn: true),
                no([.off(.featureMedia), .set(.mediaPlayer, "off")]),
            ],
            pane: .media,
            covers: [.featureMedia: .answer, .mediaPlayer: .answer],
            asks: { $0.paired }
        ),
        // Phone camera and Focus
        SetupQuestion(
            id: "camera", section: .cameraFocus,
            title: L10n.setup("setup.q.camera.title", fallback: "Take photos for this Mac with your phone?"),
            context: L10n.setup("setup.q.camera.context", fallback: "Choose Take Photo in the menu bar, take it on your phone, and it lands here."),
            summary: L10n.setup("setup.q.camera.summary", fallback: "Phone photos"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.copy, label: L10n.setup("setup.a.camera.copy", fallback: "Yes, and put them on the clipboard"),
                            changes: [.on(.cameraCopyToClipboard)]),
                SetupAnswer(key: SetupAnswerKey.save, label: L10n.setup("setup.a.camera.save", fallback: "Yes, just save them to Received files"),
                            changes: [.off(.cameraCopyToClipboard)]),
            ],
            offKey: nil, pane: .files,
            covers: [.cameraCopyToClipboard: .answer]
        ),
        SetupQuestion(
            id: "focus", section: .cameraFocus,
            title: L10n.setup("setup.q.focus.title", fallback: "Keep Do Not Disturb in step on both devices?"),
            context: L10n.setup("setup.q.focus.context", fallback: "When one goes quiet, the other follows. Give the same answer on your phone."),
            summary: L10n.setup("setup.q.focus.summary", fallback: "Do Not Disturb in step"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.both, label: L10n.setup("setup.a.focus.both", fallback: "Yes, both ways"),
                            changes: [.on(.focusShare), .on(.focusFollow)], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.follow, label: L10n.setup("setup.a.focus.follow", fallback: "Only this Mac follows my phone"),
                            changes: [.off(.focusShare), .on(.focusFollow)], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.share, label: L10n.setup("setup.a.focus.share", fallback: "Only my phone follows this Mac"),
                            changes: [.on(.focusShare), .off(.focusFollow)], turnsOn: true),
                no([.off(.focusShare), .off(.focusFollow)]),
            ],
            pane: .notifications,
            covers: [.focusShare: .answer, .focusFollow: .answer, .focusShortcuts: .moreOptions]
        ),
        // Quick actions
        SetupQuestion(
            id: "links", section: .quickActions,
            title: L10n.setup("setup.q.links.title", fallback: "Open links from one device on the other?"),
            context: L10n.setup("setup.q.links.context", fallback: "Share a link from your phone and it opens in your browser here."),
            summary: L10n.setup("setup.q.links.summary", fallback: "Open links on the other device"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.rightAway, label: L10n.setup("setup.a.links.rightAway", fallback: "Yes, open them right away"),
                            changes: [.on(.featureLinks), .on(.openLinksRightAway)], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.wait, label: L10n.setup("setup.a.links.wait", fallback: "Yes, but let me open them"),
                            changes: [.on(.featureLinks), .off(.openLinksRightAway)], turnsOn: true),
                no([.off(.featureLinks)]),
            ],
            pane: .media,
            covers: [.featureLinks: .answer, .openLinksRightAway: .answer, .shortcutLink: .moreOptions]
        ),
        SetupQuestion(
            id: "find", section: .quickActions,
            title: L10n.setup("setup.q.find.title", fallback: "Ring a device when you can\u{2019}t find it?"),
            context: L10n.setup("setup.q.find.context", fallback: "Ring your phone from here, or this Mac from your phone. A short ping works too."),
            summary: L10n.setup("setup.q.find.summary", fallback: "Find and ping your devices"),
            answers: [yes([.on(.featureFindDevice), .on(.featurePing)]), no([.off(.featureFindDevice), .off(.featurePing)])],
            pane: .media,
            covers: [.featureFindDevice: .answer, .featurePing: .answer, .shortcutPing: .moreOptions]
        ),
        SetupQuestion(
            id: "battery", section: .quickActions,
            title: L10n.setup("setup.q.battery.title", fallback: "Show your phone\u{2019}s battery on this Mac?"),
            context: L10n.setup("setup.q.battery.context", fallback: "Both devices share their battery level. Battery alerts are in Settings."),
            summary: L10n.setup("setup.q.battery.summary", fallback: "Battery level on both devices"),
            answers: yesNo(.featureBattery),
            pane: .devices,
            covers: [.featureBattery: .answer, .batteryAlerts: .moreOptions, .deviceFeatures: .moreOptions, .deviceAutoClipboard: .moreOptions]
        ),
        // Privacy
        SetupQuestion(
            id: "stats", section: .privacy,
            title: L10n.setup("setup.q.stats.title", fallback: "Can Bridgey keep connection stats to help fix problems?"),
            context: L10n.setup("setup.q.stats.context", fallback: "They stay on this Mac, without message or file contents, and leave only if you export them."),
            summary: L10n.setup("setup.q.stats.summary", fallback: "Connection stats on this Mac"),
            answers: yesNo(.loggingConnection),
            pane: .privacy,
            covers: [.loggingConnection: .answer, .loggingDetail: .moreOptions]
        ),
        SetupQuestion(
            id: "previews", section: .privacy,
            title: L10n.setup("setup.q.previews.title", fallback: "Show previews of what you copied in the activity list?"),
            context: L10n.setup("setup.q.previews.context", fallback: "Off shows only what happened, like Text copied."),
            summary: L10n.setup("setup.q.previews.summary", fallback: "Previews in activity"),
            answers: yesNo(.showPreviews),
            pane: .privacy,
            covers: [.showPreviews: .answer]
        ),
        // Updates
        SetupQuestion(
            id: "updates", section: .updates,
            title: L10n.setup("setup.q.updates.title", fallback: "How new do you want updates?"),
            context: L10n.setup("setup.q.updates.context", fallback: "Newer builds get features sooner, with more rough edges."),
            summary: L10n.setup("setup.q.updates.summary", fallback: "Updates"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.steady, label: L10n.setup("setup.a.updates.steady", fallback: "Steady"),
                            detail: L10n.setup("setup.a.updates.steady.detail", fallback: "Stable: tested releases. Best for most people."),
                            changes: [.set(.updateChannel, "stable")]),
                SetupAnswer(key: SetupAnswerKey.early, label: L10n.setup("setup.a.updates.early", fallback: "Early"),
                            detail: L10n.setup("setup.a.updates.early.detail", fallback: "Beta: new features before they reach Stable."),
                            changes: [.set(.updateChannel, "beta")]),
                SetupAnswer(key: SetupAnswerKey.newest, label: L10n.setup("setup.a.updates.newest", fallback: "Newest every day"),
                            detail: L10n.setup("setup.a.updates.newest.detail", fallback: "Nightly: built from every change. Expect rough edges."),
                            changes: [.set(.updateChannel, "nightly")]),
            ],
            offKey: nil, pane: .updates,
            covers: [.updateChannel: .answer]
        ),
        SetupQuestion(
            id: "updates_auto", section: .updates,
            title: L10n.setup("setup.q.updatesAuto.title", fallback: "Check for updates by itself?"),
            context: L10n.setup("setup.q.updatesAuto.context", fallback: "Bridgey looks once a day and asks before it installs anything."),
            summary: L10n.setup("setup.q.updatesAuto.summary", fallback: "Checks for updates by itself"),
            answers: yesNo(.updatesAutomatic),
            pane: .updates,
            covers: [.updatesAutomatic: .answer]
        ),
        // General
        SetupQuestion(
            id: "login", section: .general,
            title: L10n.setup("setup.q.login.title", fallback: "Start Bridgey when you log in?"),
            context: L10n.setup("setup.q.login.context", fallback: "So your phone connects without you opening it."),
            summary: L10n.setup("setup.q.login.summary", fallback: "Starts at login"),
            answers: yesNo(.launchAtLogin),
            pane: .general,
            covers: [.launchAtLogin: .answer]
        ),
        SetupQuestion(
            id: "motion", section: .general,
            title: L10n.setup("setup.q.motion.title", fallback: "Do you prefer less motion on screen?"),
            context: L10n.setup("setup.q.motion.context", fallback: "Screens fade instead of sliding, and nothing bounces."),
            summary: L10n.setup("setup.q.motion.summary", fallback: "Less motion"),
            answers: [
                SetupAnswer(key: SetupAnswerKey.yes, label: L10n.setup("setup.a.motion.yes", fallback: "Yes, less motion"),
                            changes: [.on(.reduceMotion)], turnsOn: true),
                SetupAnswer(key: SetupAnswerKey.no, label: L10n.setup("setup.a.motion.no", fallback: "No, keep it"),
                            changes: [.off(.reduceMotion)]),
            ],
            pane: .general,
            covers: [.reduceMotion: .answer, .shortcutShift: .moreOptions]
        ),
    ]

    static func question(_ id: String) -> SetupQuestion? { all.first { $0.id == id } }

    static func index(_ id: String) -> Int? { all.firstIndex { $0.id == id } }

    static func changes(_ question: SetupQuestion, _ key: String) -> [SettingChange] { question.answer(key)?.changes ?? [] }

    /// Which question covers each setting, and how (the first question that names it).
    static var coverage: [SetupSetting: (question: String, how: SetupCoverage)] {
        var table: [SetupSetting: (question: String, how: SetupCoverage)] = [:]
        for question in all {
            for (setting, how) in question.covers.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where table[setting] == nil {
                table[setting] = (question.id, how)
            }
        }
        return table
    }

    /// The generic line on the next card when a permission was not allowed.
    static func deniedLine(_ question: SetupQuestion, answer key: String?, _ permission: SetupPermission) -> String {
        if let key, let note = question.answer(key)?.deniedNote { return note }
        return String(format: L10n.setup("setup.denied", fallback: "%1$@ not allowed. Turned off: %2$@."), permission.name, question.summary)
    }

    /// The summary's shorter line under the feature's name.
    static func deniedShort(_ question: SetupQuestion, answer key: String?, _ permission: SetupPermission) -> String {
        if let key, let note = question.answer(key)?.deniedNote { return note }
        return String(format: L10n.setup("setup.denied.short", fallback: "%@ not allowed, so it stays off."), permission.name)
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
        let question: String
        let answer: String
        let stems: [String]
        var negatable = true
    }

    static let rules: [Rule] = [
        Rule(question: "clipboard", answer: SetupAnswerKey.auto, stems: ["copy", "copi", "paste", "clipboard", "копир", "скопир", "встав", "буфер"]),
        Rule(question: "notifications", answer: SetupAnswerKey.yes, stems: ["notif", "alert", "whatsapp", "telegram", "уведомл", "оповещ"]),
        Rule(question: "codes", answer: SetupAnswerKey.onMac, stems: ["code", "otp", "код"]),
        Rule(question: "calls", answer: SetupAnswerKey.yes, stems: ["call", "звон", "вызов"]),
        Rule(question: "files", answer: SetupAnswerKey.yes, stems: ["file", "photo", "picture", "folder", "файл", "фото", "папк", "снимк"]),
        Rule(question: "remote", answer: SetupAnswerKey.yes, stems: ["touchpad", "trackpad", "mouse", "slide", "presentation", "тачпад", "мыш", "слайд", "презентац", "пульт"]),
        Rule(question: "mac_actions", answer: SetupAnswerKey.yes, stems: ["lock", "sleep", "volume", "блокир", "сон", "громк"]),
        Rule(question: "media", answer: SetupAnswerKey.music, stems: ["music", "spotify", "song", "музык", "песн"]),
        Rule(question: "camera", answer: SetupAnswerKey.save, stems: ["camera", "камер"]),
        Rule(question: "focus", answer: SetupAnswerKey.both, stems: ["dnd", "focus", "фокус"]),
        Rule(question: "links", answer: SetupAnswerKey.wait, stems: ["link", "url", "browser", "ссылк", "браузер"]),
        Rule(question: "find", answer: SetupAnswerKey.yes, stems: ["find my", "lost", "ring", "найти", "потерял"]),
        Rule(question: "battery", answer: SetupAnswerKey.yes, stems: ["battery", "батаре", "заряд"]),
        Rule(question: "updates", answer: SetupAnswerKey.newest, stems: ["nightly", "newest", "every day", "ночн", "каждый день"], negatable: false),
        Rule(question: "updates", answer: SetupAnswerKey.early, stems: ["beta", "early", "бета", "раньше"], negatable: false),
        Rule(question: "updates", answer: SetupAnswerKey.steady, stems: ["stable", "steady", "стабил"], negatable: false),
    ]

    private static let negations: Set<String> = ["no", "not", "don't", "dont", "without", "never", "нет", "не", "без", "никаких"]

    /// Names that contain a negation word; read as one word, so they negate nothing.
    private static let names: [(String, String)] = [("do not disturb", "dnd"), ("не беспокоить", "dnd")]

    static func words(_ text: String) -> [String] {
        var lower = text.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "\u{2019}", with: "'")
        for (name, token) in names { lower = lower.replacingOccurrences(of: name, with: token) }
        let separators = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted
        return lower.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// The answers `text` asks for, by question id, for the questions this device has. The first
    /// matching rule per question wins. A negated mention of a question without a No is ignored.
    static func match(_ text: String, available: [SetupQuestion] = SetupQuestions.all) -> [String: String] {
        let tokens = words(text)
        guard !tokens.isEmpty else { return [:] }
        var found: [String: String] = [:]
        var seen: Set<String> = []
        for rule in rules {
            guard let question = available.first(where: { $0.id == rule.question }), !seen.contains(rule.question) else { continue }
            guard let hit = rule.stems.lazy.compactMap({ find(tokens, $0) }).first else { continue }
            seen.insert(rule.question)
            let negated = rule.negatable && tokens[max(0, hit - 3)..<hit].contains { negations.contains($0) }
            if negated {
                if question.answer(SetupAnswerKey.no) != nil { found[rule.question] = SetupAnswerKey.no }
            } else {
                found[rule.question] = rule.answer
            }
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

/// One-click starts on the Intro ("What brought you here?"). Each is named exactly as the Settings
/// page it turns on, and fills the same answers a question would; the result is shown for
/// confirmation with the typed matches before anything changes.
struct SetupBundle: Identifiable {
    let id: String
    let pane: SettingsPane
    let detail: String
    let answers: [String: String]

    var title: String { pane.title }
}

enum SetupBundles {
    static let all: [SetupBundle] = [
        SetupBundle(id: "clipboard", pane: .clipboard,
                    detail: L10n.setup("setup.bundle.clipboard", fallback: "Copy on one device, paste on the other."),
                    answers: ["clipboard": SetupAnswerKey.auto, "clipboard_files": SetupAnswerKey.yes]),
        SetupBundle(id: "notifications", pane: .notifications,
                    detail: L10n.setup("setup.bundle.notifications", fallback: "Your phone\u{2019}s notifications on this Mac."),
                    answers: ["notifications": SetupAnswerKey.yes]),
        SetupBundle(id: "calls", pane: .calls,
                    detail: L10n.setup("setup.bundle.calls", fallback: "See who\u{2019}s calling, and answer here."),
                    answers: ["calls": SetupAnswerKey.yes, "calls_ring": SetupAnswerKey.yes]),
        SetupBundle(id: "files", pane: .files,
                    detail: L10n.setup("setup.bundle.files", fallback: "Send files and photos both ways."),
                    answers: ["files": SetupAnswerKey.yes]),
        SetupBundle(id: "remote", pane: .remoteControl,
                    detail: L10n.setup("setup.bundle.remote", fallback: "Your phone as a touchpad and slide clicker."),
                    answers: ["remote": SetupAnswerKey.yes, "mac_actions": SetupAnswerKey.yes]),
    ]

    /// The answers for the picked bundles, then the typed ones (typing wins where both answer).
    static func answers(picked: Set<String>, typed: [String: String]) -> [String: String] {
        var answers: [String: String] = [:]
        for bundle in all where picked.contains(bundle.id) { answers.merge(bundle.answers) { _, new in new } }
        return answers.merging(typed) { _, typed in typed }
    }
}

// MARK: - Facts from the live settings

extension SetupFacts {
    /// What the questions read from Settings now. `sendImageMode`: SendPreferences' image mode.
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
        ]
        var granted = Set(model.setup.permissions.filter { $0.system == .allowed }.map(\.permission))
        if model.accessibilityTrusted { granted.insert(.accessibility) }
        return SetupFacts(paired: !model.trustedDevices.isEmpty, current: current, granted: granted, codesAvailable: model.codesAvailable)
    }
}
