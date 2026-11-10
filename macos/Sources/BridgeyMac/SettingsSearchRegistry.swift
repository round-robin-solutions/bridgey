import Foundation

/// One row search can offer, its text already in the app's language. `title` is the row's own title, the one the
/// row draws, so the pane can find it to scroll to and highlight (`anchor` when the row is found by another
/// name). `scope` is the device or agent card the row sits in; `group` names that card in the breadcrumb.
struct SettingsSearchEntry: Identifiable {
    let id: String
    let pane: SettingsPane
    var section: String?
    let title: String
    var subtitle: String?
    var keywords: [String] = []
    /// The row's value syncs: found as synced and by its sync status ("waiting for permission").
    var syncKey: SyncKey?
    var scope: String?
    var group: String?
    /// The anchor to show when it differs from the title; "" opens the pane without a row.
    var anchor: String?
    /// Only offered while this holds (the Developer pane, rows that only show in some states).
    var visible: (SettingsModel) -> Bool = { _ in true }

    /// The title search scrolls to, or nil to open the pane only.
    var anchorTitle: String? {
        guard let anchor else { return title }
        return anchor.isEmpty ? nil : anchor
    }

    /// "Notifications › Codes from messages", "Devices › OnePlus 11".
    var breadcrumb: String {
        var parts: [String] = []
        if let parent = pane.parentPane { parts.append(parent.sidebarTitle) }
        parts.append(pane.sidebarTitle)
        if let group { parts.append(group) }
        if let section, section != title { parts.append(section) }
        return parts.joined(separator: SettingsSearchRegistry.crumb)
    }

    var doc: SearchDoc {
        var pages = [pane.title, pane.sidebarTitle]
        if let parent = pane.parentPane { pages.append(parent.title) }
        if let group { pages.append(group) }
        return SearchDoc(title: title, subtitle: subtitle, section: section, page: pages.joined(separator: " "), keywords: keywords)
    }
}

/// Settings search's registry: every row on every Settings pane, kept beside the panes. The drift test
/// (SettingsSearchTests) renders each pane and fails when a row has no entry here or an entry no longer draws.
/// Android keeps the same list (SettingsSearchRegistry.kt); keep the synonyms in step.
enum SettingsSearchRegistry {
    /// The breadcrumb separator: a single right-pointing angle quotation mark with spaces.
    static let crumb = " \u{203A} "

    // Synonyms, matched in either language. Keep them in step with Android (SettingsSearchRegistry.kt).
    static let codes = ["otp", "one-time code", "one time password", "2fa", "verification code", "sms code", "login code",
                        "код", "одноразовый код", "код подтверждения", "смс-код"]
    static let codesEmail = ["email", "gmail", "mail", "почта"]
    static let away = ["hotspot", "relay", "tailscale", "tailnet", "vpn", "internet", "mobile data", "cellular", "4g", "5g", "away",
                       "outside", "точка доступа", "ретранслятор", "удалённо", "мобильный интернет"]
    static let tailscaleSetup = ["tailscale", "tailnet", "vpn", "private network", "sign in", "login", "войти", "частная сеть"]
    static let updates = ["update", "upgrade", "version", "beta", "channel", "release", "обновление", "версия", "бета"]
    static let clipboard = ["copy", "paste", "universal clipboard", "копировать", "вставить", "буфер обмена"]
    static let notifications = ["alerts", "mirror", "уведомления", "оповещения"]
    static let sms = ["sms", "texts", "mms", "смс", "сообщения"]
    static let calls = ["phone", "dial", "звонок", "вызов"]
    static let files = ["send file", "airdrop", "share", "transfer", "folder", "файлы", "передача"]
    static let media = ["music", "spotify", "play", "pause", "volume", "музыка", "громкость"]
    static let find = ["ring", "lost", "locate", "найти"]
    static let ping = ["alert", "пинг"]
    static let battery = ["charge", "power", "low battery", "батарея", "заряд"]
    static let remote = ["mouse", "trackpad", "touchpad", "keyboard", "slides", "presentation", "мышь", "клавиатура", "презентация"]
    static let previews = ["privacy", "preview", "превью"]
    static let activity = ["history", "история"]
    static let logs = ["logs", "debug", "diagnostics", "логи", "журнал"]
    static let motion = ["animation", "motion", "accessibility", "анимация"]
    static let name = ["rename", "name", "имя", "переименовать"]
    static let sync = ["sync", "same settings", "синхронизация"]
    static let pair = ["pair", "add device", "connect", "qr", "сопряжение", "добавить устройство"]
    static let forget = ["unpair", "remove device", "забыть"]
    static let focus = ["do not disturb", "dnd", "не беспокоить"]
    static let reset = ["erase", "factory", "clear data", "сброс"]
    static let developer = ["debug", "speed test", "perf"]
    static let shortcut = ["hotkey", "keyboard shortcut", "shortcut", "сочетание клавиш"]
    static let login = ["startup", "autostart", "open at login", "автозапуск"]
    static let synced = ["sync", "synced", "синхронизация"]

    /// The Updates status card, found by this name whatever it says now.
    static var checkForUpdates: String { L10n.text("settings.search.checkUpdates", fallback: "Check for updates") }
    /// About's version line.
    static var version: String { L10n.text("settings.search.version", fallback: "Version") }

    private static func feature(_ feature: BridgeyFeature, _ pane: SettingsPane, section: String? = nil, _ keywords: [String]) -> SettingsSearchEntry {
        SettingsSearchEntry(id: "\(pane.rawValue).\(feature.rawValue)", pane: pane, section: section, title: feature.title,
                            subtitle: feature.subtitle, keywords: keywords, syncKey: SyncKey.key(for: feature))
    }

    private static func row(_ id: String, _ pane: SettingsPane, section: String? = nil, _ title: String, _ subtitle: String? = nil,
                            _ keywords: [String] = [], sync: SyncKey? = nil, anchor: String? = nil,
                            visible: @escaping (SettingsModel) -> Bool = { _ in true }) -> SettingsSearchEntry {
        SettingsSearchEntry(id: id, pane: pane, section: section, title: title, subtitle: subtitle, keywords: keywords,
                            syncKey: sync, anchor: anchor, visible: visible)
    }

    private static func featureWords(_ feature: BridgeyFeature) -> [String] {
        switch feature {
        case .clipboard: clipboard
        case .files: files
        case .notifications: notifications
        case .battery: battery
        case .findDevice: find
        case .ping: ping
        case .links: ["url", "browser", "ссылки"]
        case .media: media
        case .calls: calls
        case .remoteInput: remote
        case .macActions: ["lock", "sleep", "shortcuts", "заблокировать"]
        }
    }

    /// The fixed rows, pane by pane in sidebar order, then the sub-pages (on equal scores the main pane's row is
    /// offered first).
    static var staticEntries: [SettingsSearchEntry] {
        let shortcutCard = L10n.text("settings.shortcut", fallback: "Keyboard shortcut")
        let codesCard = L10n.text("codes.title", fallback: "Codes from messages")
        let focusCard = L10n.text("focus.title", fallback: "Focus")
        let historyCard = L10n.text("settings.history", fallback: "Notification history")
        let smsCard = L10n.text("sms.onThisMac", fallback: "On this Mac")
        let beforeSending = L10n.text("optimize.title", fallback: "Before sending")
        let quickActions = L10n.text("settings.quickActions", fallback: "Quick actions")
        let macActionsCard = L10n.text("settings.macActions", fallback: "Mac actions")
        let remoteDevices = L10n.text("remote.devices", fallback: "Phones allowed to control this Mac")
        let activityCard = L10n.text("settings.activity", fallback: "Activity")
        let loggingCard = L10n.text("settings.logging", fallback: "Logging")
        let licencesCard = L10n.text("licences.title", fallback: "Licences")
        let pairCard = L10n.text("devices.pair", fallback: "Pair a new device")
        let developerOn: (SettingsModel) -> Bool = { $0.developerMenu }
        let optimizing: (SettingsModel) -> Bool = { _ in
            MainActor.assumeIsolated { SendPreferences.shared.optimization.imageMode == .optimize }
        }

        var entries: [SettingsSearchEntry] = [
            // This Mac
            row("thisMac.name", .thisMac, L10n.text("settings.deviceName", fallback: "Device name"), nil, name + ["device name", "this mac"]),
            row("thisMac.connection", .thisMac, L10n.text("thisMac.connection", fallback: "Connection"), nil, ["disconnect", "connected", "отключить"]),

            // Devices and permissions
            row("devices.lookAgain", .devices, L10n.text("panel.lookAgain", fallback: "Look for devices again"),
                L10n.text("devices.lookAgain.detail", fallback: "Announces this Mac again and retries every paired device now"),
                ["refresh", "discover", "retry", "найти устройства"]),
            row("devices.away", .devices, SettingsPane.away.title,
                L10n.text("connect.detail", fallback: "Reach your paired devices from any network. They connect directly when they can, or through a Round Robin relay that only sees encrypted data. No account needed."),
                ["away"]),
            row("devices.pair", .devices, pairCard, L10n.text("devices.pair.detail", fallback: "Open Bridgey on the phone, on the same Wi-Fi as this Mac. Both screens then show the same code."), pair),
            row("devices.pairAddress", .devices, section: pairCard, L10n.text("devices.pair.address", fallback: "Pair by tailnet name or address"),
                L10n.text("devices.pair.address.detail", fallback: "For a device on your tailnet. Tap Allow pairing there first."), pair + ["tailnet", "ip address"]),
            row("devices.tailscaleSetup", .devices, L10n.text("tailscale.status.notInstalled", fallback: "Set up Tailscale"),
                nil, tailscaleSetup, anchor: "Tailscale"),

            // Clipboard
            feature(.clipboard, .clipboard, clipboard),
            row("clipboard.auto", .clipboard, L10n.text("settings.autoClipboard", fallback: "Automatic clipboard"),
                L10n.text("settings.autoClipboard.detail", fallback: "Copy on one device, paste on the other."), clipboard, sync: .autoClipboard),
            row("clipboard.files", .clipboard, L10n.text("settings.clipboardFiles", fallback: "Copy images and files"),
                L10n.text("settings.clipboardFiles.detail", fallback: "Images, videos, files and long text. Big items move when you paste."),
                ["images", "photos", "картинки"], sync: .clipboardFiles),
            row("clipboard.handoff", .clipboard, HandoffText.title, HandoffText.detail, ["handoff", "universal clipboard", "apple"], sync: .handoffTakeover),
            row("clipboard.eager", .clipboard, L10n.text("settings.clipboardEager", fallback: "Send right away up to"),
                L10n.text("settings.clipboardEager.detail", fallback: "Smaller copies move as soon as you copy, so pasting is instant."), ["size", "limit", "mb", "размер"]),
            row("clipboard.shortcut", .clipboard, section: shortcutCard, ShortcutAction.clipboard.displayTitle, nil, shortcut + clipboard),

            // Notifications
            feature(.notifications, .notifications, notifications),
            row("notifications.mac", .notifications, L10n.text("settings.macNotifications", fallback: "Mac notifications"), nil,
                notifications + ["permission", "banner", "разрешение"]),
            row("notifications.codes", .notifications, section: codesCard, L10n.text("codes.toggle", fallback: "Show codes from text messages"),
                L10n.text("codes.toggle.detail", fallback: "\u{201C}Code 482913 from HDFC Bank\u{201D} with a Copy button. Off by default."), codes, sync: .codesEnabled),
            row("notifications.codesEmail", .notifications, section: codesCard, L10n.text("codes.email", fallback: "Also read codes in email"),
                L10n.text("codes.email.detail", fallback: "Gmail, Outlook, Proton Mail and Spark on your phone. Read on this Mac only, even when Cloud reads texts."),
                codes + codesEmail, sync: .codesEmail),
            row("notifications.codesEngine", .notifications, section: codesCard, L10n.text("codes.engine", fallback: "Read codes"), nil,
                codes + ["cloud", "on this mac", "model", "download", "gemma", "облако", "модель"]),
            row("notifications.codesAutoCopy", .notifications, section: codesCard, L10n.text("codes.autoCopy", fallback: "Copy automatically"),
                L10n.text("codes.autoCopy.detail", fallback: "Only while you are using this Mac. Any app can read the clipboard, so this is off by default."), codes + clipboard),
            row("notifications.codesFloat", .notifications, section: codesCard, L10n.text("codes.float.title", fallback: "Keep the copy button on screen for"),
                L10n.text("codes.float.detail", fallback: "A small card at the top right with the code and a Copy button."), codes),
            row("notifications.localCodes", .notifications, section: "Local agent codes", "Let local agents read codes", nil,
                codes + ["agent", "local", "socket", "otp"]),
            row("notifications.localCodesLifetime", .notifications, section: "Local agent codes", "Keep codes for", nil,
                codes + ["expiry", "minutes", "duration"]),
            row("notifications.localCodesBlocked", .notifications, section: "Local agent codes", "Blocked senders", nil,
                codes + ["bank", "payment", "blocklist"]),
            row("notifications.codesAccess", .notifications, section: codesCard, L10n.text("codes.access", fallback: "Code access"), nil,
                codes + ["bluetooth", "link this phone", "companion"]),
            row("notifications.focusShare", .notifications, section: focusCard, L10n.text("focus.share", fallback: "Share Focus with phones"),
                L10n.text("focus.share.detail", fallback: "Phones that follow this Mac turn on Do Not Disturb with your Focus"), focus, sync: .focusShare),
            row("notifications.focusFollow", .notifications, section: focusCard, L10n.text("focus.follow", fallback: "Follow the phone\u{2019}s Do Not Disturb"),
                L10n.text("focus.follow.detail", fallback: "Runs your Shortcut when Do Not Disturb turns on or off on a phone that shares it"), focus, sync: .focusFollow),
            row("notifications.focusOn", .notifications, section: focusCard, L10n.text("focus.follow.on", fallback: "When it turns on, run"), nil,
                focus + shortcut, visible: { $0.focusSync.follow }),
            row("notifications.focusOff", .notifications, section: focusCard, L10n.text("focus.follow.off", fallback: "When it turns off, run"), nil,
                focus + shortcut, visible: { $0.focusSync.follow }),
            row("notifications.history", .notifications, section: historyCard, L10n.text("settings.history.toggle", fallback: "Keep a private local history"),
                L10n.text("settings.history.detail", fallback: "Off by default. Keeps at most 200 notifications, with their text, for 7 days on this Mac. Turning it off deletes the history."),
                activity + notifications),

            // Text messages
            row("messages.switch", .messages, L10n.text("sms.toggle", fallback: "Your phone\u{2019}s texts on this Mac"),
                L10n.text("sms.toggle.detail", fallback: "Read and answer conversations in the Messages window, and reply from text notifications. Off by default. Messages travel only between your phone and this Mac, encrypted; Bridgey never becomes the phone\u{2019}s default SMS app."),
                sms, sync: .featureSms),
            row("messages.limits", .messages, L10n.text("sms.limits", fallback: "Group conversations and pictures"),
                L10n.text("sms.limits.detail", fallback: "You can read them here. Reply to groups and send pictures from your phone."), sms + ["group", "pictures", "группа"],
                visible: { $0.smsEnabled }),
            row("messages.keep", .messages, section: smsCard, L10n.text("sms.keep", fallback: "Keep conversations on this Mac"),
                L10n.text("sms.keep.detail", fallback: "Up to 200 conversations, readable only by your account, so they open instantly. Off: they load from the phone each time. Images are never kept."), sms),
            row("messages.delete", .messages, section: smsCard, L10n.text("sms.delete", fallback: "Delete messages on this Mac"),
                L10n.text("sms.delete.detail", fallback: "Your phone keeps every message."), sms + ["clear", "удалить"]),

            // Calls
            feature(.calls, .calls, calls),
            row("calls.phoneLinks", .calls, L10n.text("settings.phoneLinks", fallback: "Phone links"),
                L10n.text("settings.phoneLinks.detail", fallback: "Open tel: links from browsers and other apps with Bridgey, to call from the phone. The browser still asks first."),
                calls + ["tel", "browser", "default app"]),
            row("calls.otherApps", .calls, L10n.text("settings.calls.otherApps", fallback: "When another app asks to call"), nil, calls),
            row("calls.ring", .calls, L10n.text("settings.calls.ring", fallback: "Ring for incoming calls"), nil, calls + ["ringtone", "sound", "звук"]),
            row("calls.pause", .calls, L10n.text("settings.media.pauseForCalls", fallback: "Pause media during phone calls"), nil, calls + media),
            row("calls.shortcut", .calls, section: shortcutCard, ShortcutAction.call.displayTitle, nil, shortcut + calls),

            // Files
            feature(.files, .files, files),
            row("files.received", .files, L10n.text("settings.receivedFiles", fallback: "Received files"), nil, files + ["download", "save", "папка"]),
            row("files.hidden", .files, L10n.text("settings.folders.hidden", fallback: "Include hidden files when sending folders"),
                L10n.text("settings.folders.hidden.detail", fallback: "Files and folders whose names start with a dot, such as .gitignore or .config."),
                ["dotfiles", "hidden", "скрытые"], sync: .folderIncludeHidden),
            row("files.system", .files, L10n.text("settings.folders.system", fallback: "Include system files when sending folders"),
                L10n.text("settings.folders.system.detail", fallback: "Clutter the system makes, such as .DS_Store, ._ files and Thumbs.db."),
                ["ds_store", "thumbs.db", "системные"], sync: .folderIncludeSystem),
            row("files.foldersMode", .files, L10n.text("settings.folders.receive", fallback: "Folders sent to this Mac"), nil,
                files + ["save", "where", "сохранять"], sync: .folderDestination),
            row("files.conflict", .files, L10n.text("settings.folders.conflict", fallback: "When a folder already exists"), nil,
                ["merge", "replace", "conflict", "заменить"], sync: .folderConflict),
            row("files.tag", .files, L10n.text("settings.files.tag", fallback: "Tag received files in Finder"),
                L10n.text("settings.files.tag.detail", fallback: "Adds the Bridgey tag, so Finder can list everything that came from your phone."), ["finder", "tag", "метка"]),
            row("files.camera", .files, L10n.text("camera.settings.clipboard", fallback: "Copy photos from the phone camera to the clipboard"),
                L10n.text("camera.settings.clipboard.detail", fallback: "Ready to paste as soon as the photo arrives"), ["camera", "photo", "take photo", "камера", "фото"]),
            row("files.photos", .files, section: beforeSending, L10n.text("optimize.images", fallback: "Photos"), nil, ["resize", "compress", "optimise", "optimize", "сжать"]),
            row("files.format", .files, section: beforeSending, L10n.text("optimize.format", fallback: "Format"), nil, ["webp", "jpeg", "heic"], visible: optimizing),
            row("files.quality", .files, section: beforeSending, L10n.text("optimize.quality", fallback: "Quality"), nil, ["compress", "качество"], visible: optimizing),
            row("files.stripLocation", .files, section: beforeSending, L10n.text("optimize.strip.location", fallback: "Remove location"),
                L10n.text("optimize.strip.location.detail", fallback: "Where a photo was taken. On by default."), ["gps", "exif", "metadata", "privacy", "геолокация"]),
            row("files.stripCamera", .files, section: beforeSending, L10n.text("optimize.strip.camera", fallback: "Remove camera details"),
                L10n.text("optimize.strip.camera.detail", fallback: "Make, model, lens and serial numbers."), ["exif", "metadata"]),
            row("files.stripDates", .files, section: beforeSending, L10n.text("optimize.strip.dates", fallback: "Remove dates"),
                L10n.text("optimize.strip.dates.detail", fallback: "When it was taken. The phone's gallery sorts by this."), ["exif", "metadata", "date"]),
            row("files.videos", .files, section: beforeSending, L10n.text("optimize.videos", fallback: "Videos"),
                L10n.text("optimize.videos.detail", fallback: "HEVC with this Mac's hardware encoder"), ["hevc", "compress", "video", "видео"]),
            row("files.folders", .files, section: beforeSending, L10n.text("optimize.folders", fallback: "Folders"), nil, ["zip", "folder", "папки"]),
            row("files.drop", .files, L10n.text("settings.drop", fallback: "When I drop on the menu-bar icon"), nil, ["drag", "drop", "tray", "menu bar", "перетащить"]),

            // Media and quick actions
            feature(.media, .media, media),
            row("media.player", .media, L10n.text("settings.media.player", fallback: "Player"),
                L10n.text("settings.media.player.detail", fallback: "Automatic follows whatever is playing on this Mac. Or pick one app."), media),
            feature(.links, .media, section: quickActions, featureWords(.links)),
            row("media.openLinks", .media, section: quickActions, L10n.text("settings.links.openRightAway", fallback: "Open links from phones right away"),
                L10n.text("settings.links.openRightAway.detail", fallback: "Open on Mac from the phone\u{2019}s share sheet opens the link in your browser. Off: it waits for you to open it here."),
                ["url", "browser", "ссылки"]),
            feature(.ping, .media, section: quickActions, ping),
            feature(.findDevice, .media, section: quickActions, find),
            feature(.battery, .media, section: quickActions, battery),
        ]
        entries.append(feature(.macActions, .media, section: macActionsCard, featureWords(.macActions)))
        entries += MacActionSwitch.allCases.map { item in
            row("media.macAction.\(item.rawValue)", .media, section: macActionsCard, macActionSwitchTitle(item), nil, featureWords(.macActions))
        }
        entries += [
            row("media.macActionsAccessibility", .media, section: macActionsCard, L10n.text("remote.accessibility", fallback: "Accessibility access"), nil,
                ["lock", "permission", "разрешение"],
                visible: { $0.globalFeatures[.macActions] == true && $0.macActions.isOn(.lock) && !$0.accessibilityTrusted }),
            row("media.apps", .media, L10n.text("actions.apps", fallback: "Apps a phone can open"), nil, ["open app", "launch", "приложения"]),
            row("media.shortcuts", .media, L10n.text("actions.shortcuts", fallback: "Shortcuts a phone can run"), nil, ["shortcuts", "automation", "быстрые команды"]),
            row("media.devices", .media, L10n.text("actions.devices", fallback: "Phones allowed to use Mac actions"), nil, ["allow", "permission", "разрешить"]),
            row("media.log", .media, L10n.text("actions.log", fallback: "Action log"), nil, logs + activity),
            row("media.shortcutLink", .media, section: shortcutCard, ShortcutAction.link.displayTitle, nil, shortcut + ["url", "link"]),
            row("media.shortcutPing", .media, section: shortcutCard, ShortcutAction.ping.displayTitle, nil, shortcut + ping),

            // Remote control
            feature(.remoteInput, .remoteControl, remote),
            row("remote.accessibility", .remoteControl, L10n.text("remote.accessibility", fallback: "Accessibility access"), nil, remote + ["permission", "разрешение"]),
            row("remote.stop", .remoteControl, L10n.text("remote.stop.title", fallback: "Stop at any time"), nil, ["escape", "stop", "остановить"]),
            row("remote.devices", .remoteControl, remoteDevices, nil, remote + ["allow", "разрешить"]),
            row("remote.screen", .remoteControl, section: PhoneScreenSettings.cardTitle, PhoneScreenSettings.switchTitle, PhoneScreenSettings.switchDetail,
                ["screen sharing", "mirror", "экран"], sync: .featureScreen),
            row("remote.log", .remoteControl, L10n.text("remote.log", fallback: "Session log"), nil, logs + activity),

            // Privacy
            row("privacy.permissions", .privacy, L10n.setup("permissions.title", fallback: "Permissions"), nil, ["permissions", "access", "разрешения"]),
            row("privacy.previews", .privacy, section: activityCard, L10n.text("settings.previews", fallback: "Show previews in activity"),
                L10n.text("settings.previews.detail", fallback: "Clipboard text, app names and callers. Off keeps only what happened."), previews, sync: .activityPreviews),
            row("privacy.activity", .privacy, section: activityCard, L10n.text("settings.activity.clear", fallback: "Clear activity"),
                L10n.text("settings.activity.detail", fallback: "Kept only on this Mac, for 7 days. Never in diagnostics."), activity + ["clear", "delete", "очистить"]),
            row("privacy.logConnection", .privacy, section: loggingCard, L10n.text("settings.logging.connection", fallback: "Connection events"),
                L10n.text("settings.logging.connection.detail", fallback: "Discovery, pairing, connects and reconnects"), logs),
            row("privacy.logCalls", .privacy, section: loggingCard, L10n.text("settings.logging.calls", fallback: "Call events"),
                L10n.text("settings.logging.calls.detail", fallback: "Call states and the caller\u{2019}s name, so call problems can be traced"), logs),
            row("privacy.logCallNumbers", .privacy, section: loggingCard, L10n.text("settings.logging.callNumbers", fallback: "Include phone numbers"),
                L10n.text("settings.logging.callNumbers.detail", fallback: "Off masks numbers in call events"), logs),
            row("privacy.logNotifications", .privacy, section: loggingCard, L10n.text("settings.logging.notifications", fallback: "Notification events"),
                L10n.text("settings.logging.notifications.detail", fallback: "Which app posted and what happened to it"), logs),
            row("privacy.logNotificationContent", .privacy, section: loggingCard, L10n.text("settings.logging.notificationContent", fallback: "Notification titles and text"),
                L10n.text("settings.logging.notificationContent.detail", fallback: "Adds what the notification says"), logs),
            row("privacy.logClipboard", .privacy, section: loggingCard, L10n.text("settings.logging.clipboard", fallback: "Clipboard events"),
                L10n.text("settings.logging.clipboard.detail", fallback: "Sends and receipts, without the content"), logs),
            row("privacy.logClipboardPreviews", .privacy, section: loggingCard, L10n.text("settings.logging.clipboardPreviews", fallback: "Clipboard previews"),
                L10n.text("settings.logging.clipboardPreviews.detail", fallback: "Adds the first 40 characters"), logs),
            row("privacy.logFileNames", .privacy, section: loggingCard, L10n.text("settings.logging.fileNames", fallback: "File names"),
                L10n.text("settings.logging.fileNames.detail", fallback: "Adds file and folder names to transfer events"), logs),
            row("privacy.logRemote", .privacy, section: loggingCard, L10n.text("settings.logging.remote", fallback: "Remote control sessions"),
                L10n.text("settings.logging.remote.detail", fallback: "When a session ends and why; the remote control audit keeps its own record"), logs),
            row("privacy.diagnostics", .privacy, section: loggingCard, L10n.text("settings.diagnostics.export", fallback: "Export diagnostics"),
                L10n.text("settings.diagnostics.detail", fallback: "A bounded event log without clipboard text, notification content, file names, addresses or device identifiers."),
                logs + ["export", "report", "bug"]),
            row("privacy.clearLogs", .privacy, section: loggingCard, L10n.text("settings.logging.clear", fallback: "Clear logs"),
                L10n.text("settings.logging.clear.detail", fallback: "Deletes the diagnostics log on this Mac"), logs),
            row("privacy.reset", .privacy, L10n.setup("reset.title", fallback: "Reset Bridgey on this device"),
                L10n.setup("reset.row.detail", fallback: "Delete activity, caches, settings or everything"), reset),

            // Updates
            row("updates.status", .updates, checkForUpdates, nil, updates + ["install", "check now", "установить"]),
            row("updates.devices", .updates, L10n.text("updateAll.devices", fallback: "Your devices"),
                L10n.text("updateAll.devices.detail", fallback: "This Mac and the phones connected to it. Macs are not connected to each other."), updates + ["update all", "phone"]),
            row("updates.channel", .updates, L10n.text("updates.channel", fallback: "Release channel"),
                L10n.text("updates.channel.note", fallback: "Switching to a steadier channel waits for its next release; nothing is downgraded."),
                updates + ["stable", "nightly", "стабильный"]),
            row("updates.automatic", .updates, L10n.text("updates.automatic", fallback: "Check automatically"), nil, updates + ["automatic", "автоматически"]),
            row("updates.auto", .updates, AutoUpdateText.title, AutoUpdateText.subtitle, updates + ["automatic", "автоматически"], sync: .updatesAutoAll),
            row("updates.remoteStart", .updates, L10n.text("updates.remoteStart", fallback: "Let paired devices start updates on this Mac"),
                L10n.text("updates.remoteStart.detail", fallback: "Only starts Bridgey\u{2019}s own signed update from this Mac\u{2019}s channel."), updates),

            // General
            row("general.login", .general, L10n.text("settings.launchAtLogin", fallback: "Launch at login"), nil, login),
            row("general.reduceMotion", .general, L10n.text("settings.reduceMotion", fallback: "Reduce motion"),
                L10n.text("settings.reduceMotion.detail", fallback: "Fade between screens; nothing moves or bounces"), motion, sync: .reduceMotion),
            row("general.shift", .general, L10n.text("settings.shortcuts.shift", fallback: "Also require Shift for shortcuts"), nil, shortcut),
            row("general.sync", .general, L10n.text("settings.sync", fallback: "Sync settings with paired devices"),
                L10n.text("settings.sync.detail", fallback: "Keeps settings and features the same on your devices. Permissions, pairing and folders stay on each device."), sync),
            row("general.syncChoose", .general, L10n.text("sync.choose.title", fallback: "What syncs"), nil, sync + ["choose what syncs"]),
            row("general.setup", .general, L10n.setup("setup.again", fallback: "Run setup again"),
                L10n.setup("setup.again.detail", fallback: "Go through setup from the start. Pairings and settings are kept."), ["setup", "onboarding", "настройка"]),

            // About
            row("about.version", .about, version, nil, updates + ["build", "сборка"]),
            row("about.credit", .about, L10n.text("about.credit", fallback: "Built on Bridgey by Semyon Mikhailov (MIT)"),
                L10n.text("about.license", fallback: "Open source under the MIT License."), ["credit", "upstream", "open source", "github"]),
            row("about.fonts", .about, L10n.text("about.fonts", fallback: "Fonts"),
                L10n.text("about.fonts.detail", fallback: "Space Grotesk and Inter, under the SIL Open Font License 1.1."), ["font", "шрифты"]),
            row("about.data", .about, L10n.text("about.network", fallback: "Your data"),
                L10n.text("about.network.detail", fallback: "Bridgey talks directly over your local network. Clipboard, files and notification content are encrypted in transit."),
                ["privacy", "encryption", "шифрование"]),
        ]
        entries += LicenceDocument.allCases.map { document in
            row("about.licence.\(document.rawValue)", .about, section: licencesCard, document.title, nil, ["license", "licence", "open source", "лицензии"])
        }
        entries += [
            // Developer and experimental (only while it is on)
            row("developer.speed", .developer, section: L10n.text("speed.title", fallback: "Transfer speed"),
                L10n.text("speed.run", fallback: "Test transfer speed"), nil, developer, visible: developerOn),
            row("developer.perf", .developer, section: L10n.text("perf.title", fallback: "Performance test"),
                L10n.text("perf.intro.title", fallback: "File check cost"), nil, developer, visible: developerOn),
            row("developer.hide", .developer, L10n.text("developer.hide", fallback: "Hide this pane"),
                L10n.text("developer.hide.detail", fallback: "Click the version in About five times to bring it back"), developer, visible: developerOn),

            // Devices › Connect away from home
            row("away.tailscaleSetup", .away, "Tailscale", nil, tailscaleSetup),
            row("away.switch", .away, SettingsPane.away.title,
                L10n.text("connect.detail", fallback: "Reach your paired devices from any network. They connect directly when they can, or through a Round Robin relay that only sees encrypted data. No account needed."),
                away, sync: .connectAway),
            row("away.status", .away, L10n.text("connect.status", fallback: "Status"), nil, ["online", "relay", "в сети"]),
            row("away.reset", .away, L10n.text("connect.reset", fallback: "Reset away-from-home identity"),
                L10n.text("connect.reset.detail", fallback: "A new key for the Round Robin service, and new secrets with your devices. Pairings stay."), ["identity", "relay", "key"]),
            row("away.serviceAddress", .away, section: L10n.text("connect.debug", fallback: "Testing"), L10n.text("connect.debug.url", fallback: "Service address"), nil,
                ["url", "server"], visible: { $0.connect.debug }),
            row("away.relayOnly", .away, section: L10n.text("connect.debug", fallback: "Testing"), L10n.text("connect.debug.relayOnly", fallback: "Relay only"),
                L10n.text("connect.debug.relayOnly.detail", fallback: "Blocks every other route, to test the relay"), away, visible: { $0.connect.debug }),
        ]
        // Privacy › Permissions and Privacy › Reset
        entries += SetupPermission.allCases.map { permission in
            row("permissions.\(permission.rawValue)", .permissions, permission.name, permission.why, ["permission", "allow", "разрешение"])
        }
        entries += ResetChoice.allCases.map { choice in
            row("reset.\(choice.rawValue)", .reset, choice.title, choice.summary, reset)
        }
        return entries
    }

    /// The rows in a paired device's card on the Devices pane, in the card's order.
    static func deviceRows(_ device: TrustedDeviceInfo) -> [(title: String, keywords: [String])] {
        var rows: [(String, [String])] = []
        rows.append((L10n.text("health.title", fallback: "Connection health"), ["route", "latency", "relay", "соединение"]))
        for feature in BridgeyFeature.allCases where !feature.needsDeviceGrant {
            rows.append((feature.title, featureWords(feature)))
            if feature == .battery { rows.append((L10n.text("battery.alerts", fallback: "Battery alerts"), battery)) }
            if feature == .clipboard { rows.append((L10n.text("settings.autoClipboard", fallback: "Automatic clipboard"), clipboard)) }
        }
        rows.append((L10n.text("remote.grant", fallback: "Allow remote control"), remote))
        rows.append((L10n.text("actions.grant", fallback: "Allow Mac actions"), featureWords(.macActions)))
        rows.append((L10n.text("settings.sync.device", fallback: "Sync settings with this device"), sync))
        return rows
    }

    /// Everything search can offer now: the fixed rows that show in this state, with synced rows marked and
    /// their sync status, then each paired device and agent, found by name, and the lists people fill in.
    static func entries(_ model: SettingsModel) -> [SettingsSearchEntry] {
        var out: [SettingsSearchEntry] = []
        for var entry in staticEntries where entry.visible(model) {
            if let key = entry.syncKey, model.syncs(key) {
                entry.keywords += synced
                let status = model.syncStatus[key] ?? SyncRowStatus()
                var lines: [String] = []
                if status.localWaiting { lines.append(L10n.text("sync.status.waiting", fallback: "On, waiting for permission")) }
                if !status.differentOn.isEmpty {
                    lines.append(String(format: L10n.text("sync.status.different", fallback: "Different on %@"), names(status.differentOn)))
                }
                if !status.peerWaiting.isEmpty {
                    lines.append(String(format: L10n.text("sync.status.peerWaiting", fallback: "Turned on, needs permission on %@"), names(status.peerWaiting)))
                }
                if !lines.isEmpty {
                    // The status replaces the description in the result; the description still matches.
                    if let subtitle = entry.subtitle { entry.keywords.append(subtitle) }
                    entry.keywords += ["waiting", "permission", "different", "ожидает", "разрешение"]
                    entry.subtitle = lines.joined(separator: ". ")
                }
            }
            out.append(entry)
        }
        out += dynamicEntries(model)
        return out
    }

    /// Paired devices and their cards, agents on each phone, per-phone grants, and the apps and Shortcuts listed
    /// for Mac actions.
    static func dynamicEntries(_ model: SettingsModel) -> [SettingsSearchEntry] {
        var out: [SettingsSearchEntry] = []
        let permissions = L10n.agents("tab.permissions", fallback: "Permissions")
        for device in model.trustedDevices {
            out.append(SettingsSearchEntry(id: "device.\(device.id)", pane: .devices, title: device.name, subtitle: permissions,
                                           keywords: ["device", "permissions", "устройство", "разрешения"] + forget, scope: device.id))
            for (index, row) in deviceRows(device).enumerated() {
                out.append(SettingsSearchEntry(id: "device.\(device.id).\(index)", pane: .devices, section: permissions, title: row.title,
                                               keywords: row.keywords + [device.name], scope: device.id, group: device.name))
            }
            if let state = model.agents.phones[device.id] {
                let section = String(format: L10n.agents("mac.section", fallback: "Agents on %1$@"), device.name)
                for agent in state.agents {
                    let scope = "agent:\(device.id):\(agent.deviceId)"
                    out.append(SettingsSearchEntry(id: "agent.\(device.id).\(agent.deviceId)", pane: .devices, section: section, title: agent.name,
                                                   subtitle: AgentsText.subtitle(agent),
                                                   keywords: ["agent", "server", "cli", "агент", "сервер"], scope: scope, group: device.name))
                    for key in AgentGrantKey.allCases {
                        out.append(SettingsSearchEntry(id: "agent.\(device.id).\(agent.deviceId).\(key.rawValue)", pane: .devices, section: section,
                                                       title: AgentsText.grantTitle(key), subtitle: AgentsText.grantDetail(key, agent: agent),
                                                       keywords: ["agent", "агент", agent.name], scope: scope, group: agent.name))
                    }
                }
            }
            out.append(SettingsSearchEntry(id: "remote.device.\(device.id)", pane: .remoteControl,
                                           section: L10n.text("remote.devices", fallback: "Phones allowed to control this Mac"),
                                           title: device.name, keywords: remote + ["allow", "разрешить"]))
            out.append(SettingsSearchEntry(id: "media.device.\(device.id)", pane: .media,
                                           section: L10n.text("actions.devices", fallback: "Phones allowed to use Mac actions"),
                                           title: device.name, keywords: featureWords(.macActions) + ["allow", "разрешить"]))
        }
        for app in model.macActions.apps {
            out.append(SettingsSearchEntry(id: "media.app.\(app.bundleID)", pane: .media, section: L10n.text("actions.apps", fallback: "Apps a phone can open"),
                                           title: app.name, subtitle: app.bundleID, keywords: ["app", "приложение"]))
        }
        for shortcut in model.macActions.shortcuts {
            out.append(SettingsSearchEntry(id: "media.shortcut.\(shortcut.id)", pane: .media, section: L10n.text("actions.shortcuts", fallback: "Shortcuts a phone can run"),
                                           title: shortcut.name, keywords: ["shortcut", "быстрая команда"]))
        }
        return out
    }

    /// "OnePlus 11", or "OnePlus 11 and 2 more", as the sync status lines say it.
    private static func names(_ list: [String]) -> String {
        guard let first = list.first else { return "" }
        if list.count == 1 { return first }
        return String(format: L10n.text("sync.status.andMore", fallback: "%1$@ and %2$d more"), first, list.count - 1)
    }
}
