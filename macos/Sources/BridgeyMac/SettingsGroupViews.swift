import SwiftUI

/*
 * The six groups' cards. Each card is built from the rows the old panes drew (SettingsWindow.swift and the files
 * named per card), so every setting keeps its control, its stored value and its search anchor; only where it sits
 * changed. Default rows are the ones people use and ask about most; the rest are in More options.
 */

/// A group's cards, top to bottom. `startCard` (screenshots only) starts the list at a card, as a link scrolled to it.
struct SettingsGroupView: View {
    let group: SettingsGroup
    let model: SettingsModel
    let actions: SettingsActions
    var startCard: SettingsCardID?

    var body: some View {
        SettingsCardsView(cards: cards, model: model, actions: actions)
    }

    private var cards: [SettingsCardID] {
        let all = group.cards(developer: model.developerMenu)
        guard let startCard, let index = all.firstIndex(of: startCard) else { return all }
        return Array(all[index...])
    }
}

struct SettingsCardsView: View {
    let cards: [SettingsCardID]
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        ForEach(cards) { card in
            SettingsCardView(card: card, model: model, actions: actions)
        }
    }
}

/// One card by its id.
struct SettingsCardView: View {
    let card: SettingsCardID
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        switch card {
        case .thisMac: ThisMacCard(model: model, actions: actions)
        case .pairedDevices: PairedDevicesSection(model: model, actions: actions)
        case .pair: PairNewCard(model: model, actions: actions)
        case .tailscale: TailscaleSetupCard(display: model.tailscaleSetup, actions: actions)
        case .away: ConnectAwayCard(model: model, actions: actions)
        case .battery: BatteryCard(model: model, actions: actions)
        case .find: SimpleFeatureCard(card: .find, feature: .findDevice, model: model, actions: actions)
        case .ping: PingCard(model: model, actions: actions)
        case .clipboard: ClipboardCard(model: model, actions: actions)
        case .files: FilesCard(model: model, actions: actions)
        case .media: MediaCard(model: model, actions: actions)
        case .links: LinksCard(model: model, actions: actions)
        case .notifications: NotificationsCard(model: model, actions: actions)
        case .codes: CodesCard(model: model, actions: actions)
        case .focus: FocusSyncCard(model: model, actions: actions)
        case .messages: TextMessagesCard(model: model, actions: actions)
        case .calls: CallsCard(model: model, actions: actions)
        case .callsWindow: CallsWindowCard(model: model, actions: actions)
        case .callQuiet: CallMediaSettingsCard(model: model, actions: actions)
        case .remoteControl: RemoteControlCard(model: model, actions: actions)
        case .macScreen: MacScreenSettingsCard(model: model, actions: actions)
        case .phoneScreen: PhoneScreenCard(model: model, actions: actions)
        case .macActions: MacActionsCards(model: model, actions: actions)
        case .activity: ActivityCard(model: model, actions: actions)
        case .permissions: PermissionsPane(model: model, actions: actions)
        case .logging: LoggingCard(model: model, actions: actions)
        case .reset: ResetPane(model: model, actions: actions)
        case .updates: UpdatesPane(model: model, actions: actions)
        case .general: GeneralCard(model: model, actions: actions)
        case .sync: SettingsSyncCard(model: model, actions: actions)
        case .about: AboutPane(model: model, actions: actions)
        case .developer: DeveloperPane(model: model, actions: actions)
        }
    }
}

// MARK: - Shared pieces

/// A feature's switch for its card's header. Granted features (Remote control, Mac actions) are off until chosen.
func featureToggle(_ feature: BridgeyFeature, _ model: SettingsModel, _ actions: SettingsActions) -> CardToggle {
    CardToggle(title: feature.title,
               isOn: feature.needsDeviceGrant ? model.globalFeatures[feature] == true : model.globalFeatures[feature] != false,
               synced: model.syncs(SyncKey.key(for: feature)),
               set: { actions.setGlobal(feature, $0) })
}

/// The sync line of a feature's switch ("Different on OnePlus 11"), first in its card.
struct FeatureSyncLine: View {
    let feature: BridgeyFeature
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        if let key = SyncKey.key(for: feature) { SyncStatusLine(key: key, model: model, actions: actions) }
    }
}

/// A feature with nothing but its switch and its devices (Find device).
struct SimpleFeatureCard: View {
    let card: SettingsCardID
    let feature: BridgeyFeature
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: card, toggle: featureToggle(feature, model, actions)) {
            FeatureSyncLine(feature: feature, model: model, actions: actions)
            DeviceChoicesRow(feature: card.title, chips: DeviceChoices.feature(feature, model, actions))
        }
    }
}

// MARK: - Devices

struct ThisMacCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .thisMac) {
            DeviceNameRow(name: model.deviceName, onSave: actions.setDeviceName, divider: true)
            SettingsRow(title: L10n.text("thisMac.connection", fallback: "Connection"), subtitle: connectionText(model)) {
                if model.connectedDeviceID != nil {
                    Button(L10n.text("thisMac.disconnect", fallback: "Disconnect"), action: actions.disconnect)
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
            }
        }
    }
}

/// Each paired device: who it is, how it is connected, Phone files, Forget, and its agents.
struct PairedDevicesSection: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.trustedDevices.isEmpty {
                SettingsCard {
                    SettingsRow(title: L10n.text("devices.none", fallback: "No paired devices yet"),
                                subtitle: L10n.text("devices.none.detail", fallback: "Pair a device below. Both screens show a code; confirm it only if they match."),
                                divider: false) { EmptyView() }
                }
                .settingsSearchSkip()
            }
            ForEach(model.trustedDevices) { device in
                DeviceCard(device: device, model: model, actions: actions)
                AgentsOnPhoneCard(phoneID: device.id, phoneName: device.name, model: model, actions: actions)
            }
        }
        .id(SettingsCardScrollID(card: .pairedDevices))
    }
}

struct BatteryCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .battery, toggle: featureToggle(.battery, model, actions),
                    footnote: L10n.text("battery.alerts.detail", fallback: "A notification when the phone runs low, and when it has charged. Once per charge.")) {
            FeatureSyncLine(feature: .battery, model: model, actions: actions)
            DeviceChoicesRow(feature: SettingsCardID.battery.title, chips: DeviceChoices.feature(.battery, model, actions))
        } more: {
            ForEach(model.trustedDevices) { device in
                BatteryAlertsRow(thresholds: model.batteryAlerts[device.id] ?? .default, enabled: model.isEnabled(.battery, for: device.id),
                                 device: device.name) { actions.setBatteryAlerts(device.id, $0) }
                    .settingsSearchScope(device.id)
            }
        }
    }
}

struct PingCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .ping, toggle: featureToggle(.ping, model, actions)) {
            FeatureSyncLine(feature: .ping, model: model, actions: actions)
            DeviceChoicesRow(feature: SettingsCardID.ping.title, chips: DeviceChoices.feature(.ping, model, actions))
        } more: {
            ShortcutsCard(model: model, actions: actions, only: [.ping])
        }
    }
}

// MARK: - Sharing

struct ClipboardCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        let on = model.globalFeatures[.clipboard] != false
        FeatureCard(card: .clipboard, toggle: featureToggle(.clipboard, model, actions),
                    footnote: L10n.text("settings.autoClipboard.note", fallback: "Works while both devices are connected and Clipboard is on for both. Passwords and other concealed clips are never sent. With an older Bridgey on the other device, or with Copy images and files off, only text up to 32 KiB moves.")) {
            FeatureSyncLine(feature: .clipboard, model: model, actions: actions)
            AutoClipboardToggle(isOn: model.autoClipboard, synced: model.syncs(.autoClipboard), set: actions.setAutoClipboard)
                .disabled(!on)
            SyncStatusLine(key: .autoClipboard, model: model, actions: actions)
            SettingsToggle(title: L10n.text("settings.clipboardFiles", fallback: "Copy images and files"),
                           subtitle: L10n.text("settings.clipboardFiles.detail", fallback: "Images, videos, files and long text. Big items move when you paste."),
                           synced: model.syncs(.clipboardFiles), isOn: model.clipboardFiles, set: actions.setClipboardFiles)
                .disabled(!on)
            SyncStatusLine(key: .clipboardFiles, model: model, actions: actions)
            DeviceChoicesRow(feature: SettingsCardID.clipboard.title, chips: DeviceChoices.feature(.clipboard, model, actions))
        } more: {
            HandoffTakeoverRows(model: model, actions: actions)
            SettingsRow(title: L10n.text("settings.clipboardEager", fallback: "Send right away up to"),
                        subtitle: L10n.text("settings.clipboardEager.detail", fallback: "Smaller copies move as soon as you copy, so pasting is instant.")) {
                ChoiceButton(value: eagerLimitTitle(model.clipboardEagerLimit)) {
                    ClipboardEagerLimit.allCases.map { limit in
                        PopUpMenuItem(title: eagerLimitTitle(limit), checked: limit == model.clipboardEagerLimit) {
                            actions.setClipboardEagerLimit(limit)
                        }
                    }
                }
            }
            .disabled(!on || !model.clipboardFiles)
            .opacity(on && model.clipboardFiles ? 1 : 0.5)
            DeviceChoicesRow(feature: L10n.text("settings.autoClipboard", fallback: "Automatic clipboard"),
                           chips: DeviceChoices.autoClipboard(model, actions),
                           title: L10n.text("settings.autoClipboard.perDevice", fallback: "Automatic clipboard on"),
                           subtitle: model.autoClipboard ? nil : L10n.text("settings.autoClipboard.offEverywhere", fallback: "Off for every device, in Clipboard"))
            ShortcutsCard(model: model, actions: actions, only: [.clipboard])
        }
    }
}

struct FilesCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .files, toggle: featureToggle(.files, model, actions)) {
            FeatureSyncLine(feature: .files, model: model, actions: actions)
            ReceiveFolderRow(path: model.receiveFolderPath, choose: actions.chooseReceiveFolder)
            SettingsToggle(title: L10n.text("settings.files.autoResume", fallback: "Resume interrupted files automatically"),
                           isOn: model.autoResumeFiles, set: actions.setAutoResumeFiles)
            DeviceChoicesRow(feature: SettingsCardID.files.title, chips: DeviceChoices.feature(.files, model, actions))
        } more: {
            SettingsCard(footnote: L10n.text("settings.folders.note", fallback: "These are the defaults; the send sheet can change them for one folder. Links and Finder aliases are never sent.")) {
                SettingsToggle(title: L10n.text("settings.folders.hidden", fallback: "Include hidden files when sending folders"),
                               subtitle: L10n.text("settings.folders.hidden.detail", fallback: "Files and folders whose names start with a dot, such as .gitignore or .config."),
                               divider: false, synced: model.syncs(.folderIncludeHidden), isOn: model.folderIncludeHidden, set: actions.setFolderIncludeHidden)
                SyncStatusLine(key: .folderIncludeHidden, model: model, actions: actions)
                SettingsToggle(title: L10n.text("settings.folders.system", fallback: "Include system files when sending folders"),
                               subtitle: L10n.text("settings.folders.system.detail", fallback: "Clutter the system makes, such as .DS_Store, ._ files and Thumbs.db."),
                               synced: model.syncs(.folderIncludeSystem), isOn: model.folderIncludeSystem, set: actions.setFolderIncludeSystem)
                SyncStatusLine(key: .folderIncludeSystem, model: model, actions: actions)
            }
            SettingsCard(footnote: L10n.text("settings.folders.receive.note", fallback: "Folders from other devices keep their structure. Received files get a Where from line in Finder.")) {
                SettingsRow(title: L10n.text("settings.folders.receive", fallback: "Folders sent to this Mac"),
                            subtitle: nil, divider: false, synced: model.syncs(.folderDestination)) {
                    ChoiceButton(value: folderReceiveModeTitle(model.folderReceiveMode)) {
                        MacFolderReceiveMode.allCases.map { mode in
                            PopUpMenuItem(title: folderReceiveModeTitle(mode), checked: mode == model.folderReceiveMode) { actions.setFolderReceiveMode(mode) }
                        }
                    }
                }
                SyncStatusLine(key: .folderDestination, model: model, actions: actions)
                SettingsRow(title: L10n.text("settings.folders.conflict", fallback: "When a folder already exists"), subtitle: nil,
                            synced: model.syncs(.folderConflict)) {
                    ChoiceButton(value: folderConflictTitle(model.folderConflictPolicy)) {
                        MacFolderConflictPolicy.allCases.map { policy in
                            PopUpMenuItem(title: folderConflictTitle(policy), checked: policy == model.folderConflictPolicy) { actions.setFolderConflictPolicy(policy) }
                        }
                    }
                }
                SyncStatusLine(key: .folderConflict, model: model, actions: actions)
                SettingsToggle(title: L10n.text("settings.files.tag", fallback: "Tag received files in Finder"),
                               subtitle: L10n.text("settings.files.tag.detail", fallback: "Adds the Bridgey tag, so Finder can list everything received from other devices."),
                               isOn: model.tagReceivedFiles, set: actions.setTagReceivedFiles)
            }
            SettingsCard(footnote: L10n.text("camera.settings.note", fallback: "In the menu bar panel, File > Take Photo with your phone. The phone opens its camera once it is unlocked; the photo lands in Received files.")) {
                SettingsToggle(title: L10n.text("camera.settings.clipboard", fallback: "Copy photos from the phone camera to the clipboard"),
                               subtitle: L10n.text("camera.settings.clipboard.detail", fallback: "Ready to paste as soon as the photo arrives"),
                               divider: false, isOn: model.cameraCopyToClipboard, set: actions.setCameraCopyToClipboard)
            }
            PhoneFilesQualitySettingsCard()
            // Send options (Before sending, menu-bar drops): SendOptionsSettings.swift.
            SendOptionsSettingsSection()
        }
    }
}

struct MediaCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .media, toggle: featureToggle(.media, model, actions),
                    footnote: model.mediaDetail.isEmpty
                        ? L10n.text("settings.media.detail", fallback: "Music and Spotify: macOS asks once to let Bridgey control them. Other apps work while they show in Now Playing on this Mac.")
                        : model.mediaDetail) {
            FeatureSyncLine(feature: .media, model: model, actions: actions)
            MediaPlayerRow(model: model, actions: actions)
            DeviceChoicesRow(feature: SettingsCardID.media.title, chips: DeviceChoices.feature(.media, model, actions))
        }
    }
}

struct LinksCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .links, toggle: featureToggle(.links, model, actions)) {
            FeatureSyncLine(feature: .links, model: model, actions: actions)
            SettingsToggle(title: L10n.text("settings.links.openRightAway", fallback: "Open links from other devices right away"),
                           subtitle: L10n.text("settings.links.openRightAway.detail", fallback: "Links shared from other devices open in the browser. Turn this off to keep them in Bridgey's menu bar."),
                           isOn: model.openLinksRightAway, set: actions.setOpenLinksRightAway)
                .disabled(model.globalFeatures[.links] == false)
            BrowserSupportCard(display: model.browserSupport, actions: actions)
            DeviceChoicesRow(feature: SettingsCardID.links.title, chips: DeviceChoices.feature(.links, model, actions))
        } more: {
            ShortcutsCard(model: model, actions: actions, only: [.link])
        }
    }
}

// MARK: - Phone

struct NotificationsCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .notifications, toggle: featureToggle(.notifications, model, actions)) {
            FeatureSyncLine(feature: .notifications, model: model, actions: actions)
            NotificationPermissionRow(model: model, actions: actions)
            DeviceChoicesRow(feature: SettingsCardID.notifications.title, chips: DeviceChoices.feature(.notifications, model, actions))
            NotificationHistoryCard(model: model, actions: actions)
        } more: {
            SettingsToggle(title: L10n.text("settings.presence.share", fallback: "Share when I'm using this device"),
                           subtitle: L10n.text("settings.presence.detail", fallback: "Helps other devices send here. Only activity status and time since input are shared."),
                           isOn: model.shareActivityStatus, set: actions.setShareActivityStatus)
        }
    }
}

struct CallsCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .calls, toggle: featureToggle(.calls, model, actions)) {
            FeatureSyncLine(feature: .calls, model: model, actions: actions)
            RingForCallsToggle(model: model, actions: actions)
            OtherAppCallsRow(model: model, actions: actions)
            DeviceChoicesRow(feature: SettingsCardID.calls.title, chips: DeviceChoices.feature(.calls, model, actions))
        } more: {
            PhoneLinksRow(status: model.phoneLinkStatus, use: actions.usePhoneLinks)
            PauseForCallsToggle(model: model, actions: actions)
            ShortcutsCard(model: model, actions: actions, only: [.call])
        }
    }
}

// MARK: - Control

struct PhoneScreenCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .phoneScreen, detail: PhoneScreenSettings.switchDetail,
                    toggle: CardToggle(title: PhoneScreenSettings.switchTitle, isOn: model.phoneScreenEnabled,
                                       synced: model.syncs(.featureScreen), set: actions.setPhoneScreen),
                    footnote: PhoneScreenSettings.footnote) {
            SyncStatusLine(key: .featureScreen, model: model, actions: actions)
        }
    }
}

// MARK: - Privacy

struct ActivityCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmClear = false

    var body: some View {
        FeatureCard(card: .activity) {
            SettingsToggle(title: L10n.text("settings.previews", fallback: "Show previews in activity"),
                           subtitle: L10n.text("settings.previews.detail", fallback: "Clipboard text, app names and callers. Off keeps only what happened."),
                           synced: model.syncs(.activityPreviews), isOn: model.showPreviews, set: actions.setShowPreviews)
            SyncStatusLine(key: .activityPreviews, model: model, actions: actions)
            SettingsRow(title: L10n.text("settings.activity.clear", fallback: "Clear activity"),
                        subtitle: L10n.text("settings.activity.detail", fallback: "Kept only on this Mac, for 7 days. Never in diagnostics.")) {
                Button(L10n.text("action.clear", fallback: "Clear")) { confirmClear = true }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                    .disabled(model.activityCount == 0)
            }
        }
        .confirmationDialog(L10n.text("settings.activity.clear.title", fallback: "Clear activity?"), isPresented: $confirmClear) {
            Button(L10n.text("action.clear", fallback: "Clear"), role: .destructive, action: actions.clearActivity)
        } message: {
            Text(L10n.text("settings.activity.clear.body", fallback: "This removes the stream from this Mac. Your other devices keep their own history."))
        }
    }
}

// MARK: - App

struct GeneralCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        FeatureCard(card: .general, footnote: L10n.text("settings.shortcuts.detail", fallback: "Shortcuts use Control + Option and the key you choose.")) {
            SettingsToggle(title: L10n.text("settings.launchAtLogin", fallback: "Launch at login"),
                           subtitle: model.loginItemMessage, subtitleIsWarning: model.loginItemMessage != nil,
                           isOn: model.launchAtLogin, set: actions.setLaunchAtLogin)
            SettingsToggle(title: L10n.text("settings.reduceMotion", fallback: "Reduce motion"),
                           subtitle: L10n.text("settings.reduceMotion.detail", fallback: "Fade between screens; nothing moves or bounces"),
                           synced: model.syncs(.reduceMotion), isOn: model.reduceMotion, set: actions.setReduceMotion)
            SyncStatusLine(key: .reduceMotion, model: model, actions: actions)
        } more: {
            SettingsToggle(title: L10n.text("settings.panelMotion", fallback: "Animate the menu bar panel"),
                           isOn: model.panelMoves, set: actions.setPanelMoves)
            SettingsToggle(title: L10n.text("settings.shortcuts.shift", fallback: "Also require Shift for shortcuts"),
                           isOn: model.shortcutShift, set: actions.setShortcutShift)
            RunSetupAgainCard(actions: actions)
        }
    }
}
