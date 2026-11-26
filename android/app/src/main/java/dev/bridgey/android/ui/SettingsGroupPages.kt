package dev.bridgey.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import dev.bridgey.android.BridgeyFeature
import dev.bridgey.android.BuildGates
import dev.bridgey.android.R
import dev.bridgey.android.sync.SyncKey
import dev.bridgey.android.ui.search.settingsSearchHighlight
import dev.bridgey.android.ui.theme.BridgeyTheme
import dev.bridgey.android.ui.theme.BridgeyType

/*
 * The six group pages. Each card follows SettingsCards.kt: header switch, the rows people use most, the Devices chips,
 * then More options. What sits where is the 26 Nov 2026 plan (outputs/bridgey/settings-redesign/spec.md); the Mac's
 * groups hold the same cards.
 */

/** The cards a group's page shows in this state and build, in page order. */
internal fun cardsOn(group: SettingsGroup, state: SettingsState): List<SettingsCard> = SettingsCard.entries.filter { card ->
    card.group == group && when (card) {
        // Codes from messages reads notifications: it shows while forwarding is on.
        SettingsCard.CODES -> state.featureOn(BridgeyFeature.NOTIFICATIONS)
        SettingsCard.MESSAGES -> BuildGates.sms
        SettingsCard.UPDATES -> BuildGates.selfUpdate
        SettingsCard.PHONE_CONTROL -> state.phoneControl.built
        SettingsCard.DEVELOPER -> state.developerMenu
        else -> true
    }
}

/**
 * One group's page: its title on the page bar, then its cards. [focus] starts the page at that card with its More
 * options open (tests and screenshots; the app scrolls through search, which also highlights).
 */
@Composable
internal fun SettingsGroupPage(group: SettingsGroup, state: SettingsState, actions: SettingsActions, listState: LazyListState, focus: SettingsCard? = null) {
    val cards = cardsOn(group, state)
    if (focus != null) {
        androidx.compose.runtime.LaunchedEffect(focus) {
            val index = cards.indexOf(focus)
            if (index > 0) listState.scrollToItem(index + 1)
        }
    }
    androidx.compose.runtime.CompositionLocalProvider(LocalOpenCard provides focus?.key) {
        SettingsPage(stringResource(group.titleRes), actions.back, listState) {
            item(key = "${group.name}.top") { Spacer(Modifier.height(8.dp)) }
            cards.forEach { card -> item(key = card.key) { CardView(card, state, actions) } }
        }
    }
}

@Composable
private fun CardView(card: SettingsCard, state: SettingsState, actions: SettingsActions) {
    // Rows answer to search inside their card, so two cards may share a row title (Contacts in Text messages and the
    // Calls window).
    androidx.compose.runtime.CompositionLocalProvider(dev.bridgey.android.ui.search.LocalSearchScope provides card.key) { CardContent(card, state, actions) }
}

@Composable
private fun CardContent(card: SettingsCard, state: SettingsState, actions: SettingsActions) {
    when (card) {
        SettingsCard.THIS_PHONE -> ThisPhone(state, actions)
        SettingsCard.PAIRED -> PairedCard(state, actions)
        SettingsCard.AWAY -> AwayCard(state, actions)
        SettingsCard.FIND_PING -> FindPingCard(state, actions)
        SettingsCard.BATTERY -> ChoiceCard(card, BridgeyFeature.BATTERY, R.string.feature_battery, state, actions, detail = false)
        SettingsCard.CLIPBOARD -> ClipboardCard(state, actions)
        SettingsCard.FILES -> FilesCard(state, actions)
        SettingsCard.MEDIA -> ChoiceCard(card, BridgeyFeature.MEDIA, R.string.feature_media, state, actions)
        SettingsCard.LINKS -> ChoiceCard(card, BridgeyFeature.LINKS, R.string.feature_links, state, actions, detail = false)
        SettingsCard.CAMERA -> ChoiceCard(card, BridgeyFeature.CAMERA, R.string.feature_camera, state, actions)
        SettingsCard.NOTIFICATIONS -> NotificationsCard(state, actions)
        SettingsCard.CODES -> FeatureCard(
            SettingsCard.CODES, null, CardGap,
            rows = { codesMainRows(state.codes, actions.codes, state.sync, actions.sync) },
            more = { codesMoreRows(state.codes, actions.codes) },
            footer = { CodesFootnote(state.codes, actions.codes) },
        )
        SettingsCard.FOCUS -> FeatureCard(
            SettingsCard.FOCUS, titleHeader(R.string.focus_section, BridgeyIcons.Bedtime, Tint.PURPLE), CardGap,
            rows = { focusRows(state.focus, actions.focus, state.sync, actions.sync) },
            footer = { Note(stringResource(R.string.focus_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) },
        )
        SettingsCard.MESSAGES -> MessagesCard(state, actions)
        SettingsCard.CALLS -> CallsCard(state, actions)
        SettingsCard.CALLS_WINDOW -> CallsWindowCard(state, actions)
        SettingsCard.CALL_QUIET -> CallQuietCard(state, actions)
        SettingsCard.REMOTE -> RemoteCard(state, actions)
        SettingsCard.SEE_MAC_SCREEN -> ChoiceCard(card, BridgeyFeature.SCREEN_CONTROL, R.string.feature_screen_control, state, actions)
        SettingsCard.SHARE_SCREEN -> ChoiceCard(card, BridgeyFeature.SCREEN, R.string.feature_screen, state, actions)
        SettingsCard.PHONE_CONTROL -> PhoneControlCard(state.phoneControl, actions.phoneControl, CardGap)
        SettingsCard.MAC_ACTIONS -> ChoiceCard(card, BridgeyFeature.MAC_ACTIONS, R.string.feature_mac_actions, state, actions)
        SettingsCard.ACTIVITY -> ActivityCard(state, actions)
        SettingsCard.PERMISSIONS -> FeatureCard(SettingsCard.PERMISSIONS, null, CardGap, rows = { privacySetupRows(actions.setup) })
        SettingsCard.LOGGING -> LoggingCard(state.logging, actions.setLogging, actions.exportDiagnostics, actions.clearLogs, CardGap)
        SettingsCard.UPDATES -> UpdatesCard(state, actions)
        SettingsCard.GENERAL -> GeneralCard(state, actions)
        SettingsCard.SYNC -> SyncCard(state, actions, CardGap)
        SettingsCard.ABOUT -> AboutCard(state, actions)
        SettingsCard.DEVELOPER -> DeveloperCard(state, actions)
    }
}

/** A feature that is its switch and its Devices chips (Battery, Media, Links, Camera, the screens, Mac actions). */
@Composable
private fun ChoiceCard(card: SettingsCard, feature: BridgeyFeature, @StringRes choice: Int, state: SettingsState, actions: SettingsActions, detail: Boolean = true) {
    FeatureCard(
        card, featureHeader(feature, state, actions, detail), CardGap,
        rows = {
            featureSync(feature, state, actions)
            choiceChips(choice, state, actions)
        },
    )
}

/** Space between cards. */
private val CardGap = Modifier.padding(top = 16.dp)

/** The header of a feature's card: the feature's switch, with its sync mark. [detail] adds the switch's description. */
@Composable
private fun featureHeader(feature: BridgeyFeature, state: SettingsState, actions: SettingsActions, detail: Boolean = false): CardHeader {
    val (icon, tint) = permissionVisual(feature)
    return CardHeader(
        title = featureSettingTitle(feature),
        icon = icon,
        tint = tint,
        detail = if (detail) globalFeatureDetail(feature) else null,
        switch = CardSwitch(state.featureOn(feature), { actions.setGlobal(feature, it) }, synced = syncKeyFor(feature)?.let(state.sync::syncs) == true),
    )
}

/** A title-only header, for cards that hold settings but are not one feature. */
@Composable
private fun titleHeader(@StringRes title: Int, icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Tint) =
    CardHeader(stringResource(title), icon, tint)

private fun GroupScope.featureSync(feature: BridgeyFeature, state: SettingsState, actions: SettingsActions) =
    syncRows(syncKeyFor(feature), state.sync, actions.sync)

/** The Devices chips for a per-device feature choice (the device page's switch, as it read and wrote it). */
private fun GroupScope.choiceChips(@StringRes choice: Int, state: SettingsState, actions: SettingsActions, @StringRes title: Int = R.string.settings_card_devices) {
    val features = DeviceChoices.first { it.titleRes == choice }.features
    deviceChips(choice, featureChips(state, features, actions.setDeviceFeature), remotelyOffNames(state, features), title)
}

// region Devices

@Composable
private fun ThisPhone(state: SettingsState, actions: SettingsActions) {
    var renaming by rememberSaveable { mutableStateOf(false) }
    ThisPhoneCard(state, onRename = { renaming = true })
    if (renaming) RenameDialog(state.deviceName, onDismiss = { renaming = false }, onSave = { renaming = false; actions.rename(it) })
}

@Composable
private fun PairedCard(state: SettingsState, actions: SettingsActions) {
    val paired = state.rings.filter { it.trusted && it.deviceId != null }
    FeatureCard(
        SettingsCard.PAIRED, titleHeader(R.string.devices_paired, BridgeyIcons.Devices, Tint.BLUE), CardGap,
        rows = {
            paired.forEach { ring ->
                row { shape ->
                    ListRow(
                        shape, ring.name, ringStatusLabel(ring), null, Tint.NEUTRAL,
                        onClick = { actions.openDevice(ring) },
                        leading = { DeviceGlyph(ring.state.style(), deviceIcon(ring.platform), 40.dp, iconSize = 18.dp) },
                        // A way to the device's page; search offers the page itself for its name.
                        searchable = false,
                    ) { Chevron() }
                }
            }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.look_again), stringResource(R.string.look_again_detail),
                    BridgeyIcons.Refresh, Tint.NEUTRAL,
                    onClick = if (state.rediscovering) null else actions.lookForDevices,
                )
            }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.devices_pair_new), stringResource(R.string.devices_pair_new_detail),
                    BridgeyIcons.Add, Tint.BLUE, onClick = actions.addDevice,
                ) { Chevron() }
            }
        },
        footer = {
            Note(
                stringResource(if (paired.isEmpty()) R.string.devices_none else R.string.devices_per_device_note),
                Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp),
            )
        },
    )
}

@Composable
private fun FindPingCard(state: SettingsState, actions: SettingsActions) {
    FeatureCard(
        SettingsCard.FIND_PING, featureHeader(BridgeyFeature.FIND_DEVICE, state, actions), CardGap,
        rows = {
            featureSync(BridgeyFeature.FIND_DEVICE, state, actions)
            row { shape ->
                val on = state.featureOn(BridgeyFeature.PING)
                SwitchRow(
                    shape, featureSettingTitle(BridgeyFeature.PING), globalFeatureDetail(BridgeyFeature.PING),
                    BridgeyIcons.Sensors, if (on) Tint.BLUE else Tint.NEUTRAL, on, { actions.setGlobal(BridgeyFeature.PING, it) },
                    synced = syncKeyFor(BridgeyFeature.PING)?.let(state.sync::syncs) == true,
                )
            }
            featureSync(BridgeyFeature.PING, state, actions)
            choiceChips(R.string.feature_find_ping, state, actions)
        },
    )
}

/** Connect away from home: the switch, where it stands; Tailscale and the identity reset under More options. */
@Composable
private fun AwayCard(state: SettingsState, actions: SettingsActions) {
    var confirmReset by rememberSaveable { mutableStateOf(false) }
    val connect = state.connect
    val available = connect.state != ConnectState.UNAVAILABLE
    FeatureCard(
        SettingsCard.AWAY,
        CardHeader(
            stringResource(R.string.settings_connect_away), BridgeyIcons.Public, Tint.BLUE,
            detail = stringResource(R.string.connect_away_detail),
            switch = CardSwitch(connect.on && available, actions.connect.setOn, enabled = available),
        ),
        CardGap,
        rows = {
            if (connect.on) {
                row { shape ->
                    val (text, tint) = connectStatusText(connect)
                    ListRow(shape, stringResource(R.string.connect_status), text, BridgeyIcons.Cloud, tint, compact = true)
                }
            }
        },
        more = {
            row { shape ->
                Box(Modifier.fillMaxWidth().clip(shape).background(BridgeyTheme.colors.surface1).padding(horizontal = 20.dp, vertical = 16.dp)) {
                    TailscaleSetupGuidance(state.tailscale, actions.tailscale, forPairing = false)
                }
            }
            if (connect.on && available) {
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.connect_reset), stringResource(R.string.connect_reset_detail),
                        BridgeyIcons.Refresh, Tint.NEUTRAL, onClick = { confirmReset = true },
                    )
                }
            }
        },
        footer = { Note(stringResource(R.string.connect_how), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) },
    )
    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text(stringResource(R.string.connect_reset_confirm_title)) },
            text = { Text(stringResource(R.string.connect_reset_confirm_body)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmReset = false
                    actions.connect.resetIdentity()
                }) { Text(stringResource(R.string.connect_reset_confirm)) }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

// endregion

// region Sharing

@Composable
private fun ClipboardCard(state: SettingsState, actions: SettingsActions) {
    FeatureCard(
        SettingsCard.CLIPBOARD, featureHeader(BridgeyFeature.CLIPBOARD, state, actions), CardGap,
        rows = {
            featureSync(BridgeyFeature.CLIPBOARD, state, actions)
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.auto_clipboard_title), stringResource(R.string.auto_clipboard_detail),
                    BridgeyIcons.Sync, if (state.autoClipboardEnabled) Tint.BLUE else Tint.NEUTRAL,
                    state.autoClipboardEnabled, actions.setAutoClipboard,
                    synced = state.sync.syncs(SyncKey.AUTO_CLIPBOARD),
                )
            }
            syncRows(SyncKey.AUTO_CLIPBOARD, state.sync, actions.sync)
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.clipboard_files_title), stringResource(R.string.clipboard_files_detail),
                    BridgeyIcons.Image, if (state.clipboardFilesEnabled) Tint.BLUE else Tint.NEUTRAL,
                    state.clipboardFilesEnabled, actions.setClipboardFiles,
                    synced = state.sync.syncs(SyncKey.CLIPBOARD_FILES),
                )
            }
            syncRows(SyncKey.CLIPBOARD_FILES, state.sync, actions.sync)
            choiceChips(R.string.feature_clipboard, state, actions)
        },
        more = {
            row { shape -> EagerLimitRow(shape, state, actions) }
            row { shape ->
                // A screenshot goes as an image offer, so it follows Copy images and files.
                val on = state.screenshotSendEnabled && state.clipboardFilesEnabled
                SwitchRow(
                    shape, stringResource(R.string.screenshot_send_title), stringResource(R.string.screenshot_send_detail),
                    BridgeyIcons.Smartphone, if (on) Tint.BLUE else Tint.NEUTRAL,
                    on, actions.setScreenshotSend, enabled = state.clipboardFilesEnabled,
                )
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.bg_clipboard_title), stringResource(R.string.bg_clipboard_detail),
                    BridgeyIcons.DeveloperMode, if (state.backgroundClipboardEnabled) Tint.BLUE else Tint.NEUTRAL,
                    state.backgroundClipboardEnabled, actions.setBackgroundClipboard,
                )
            }
            row { shape ->
                when {
                    state.tileAddSupported && !state.tileAdded -> ListRow(
                        shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_one_tap),
                        BridgeyIcons.AddToHomeScreen, Tint.BLUE,
                    ) { OutlinePillButton(stringResource(R.string.settings_tile_add), null, actions.addTile) }
                    state.tileAddSupported -> ListRow(
                        shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_added),
                        BridgeyIcons.AddToHomeScreen, Tint.GREEN,
                    )
                    else -> ListRow(
                        shape, stringResource(R.string.settings_tile), stringResource(R.string.settings_tile_detail),
                        BridgeyIcons.AddToHomeScreen, Tint.BLUE,
                    )
                }
            }
            // Automatic clipboard for each device: only while Clipboard and Automatic clipboard are on for it.
            deviceChips(R.string.auto_clipboard_title, autoClipboardChips(state, actions.setDeviceAutoClipboard), title = R.string.auto_clipboard_title)
        },
        footer = {
            Note(stringResource(R.string.auto_clipboard_explain), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
            if (state.backgroundClipboardEnabled) BackgroundClipboardCard(state, actions)
        },
    )
}

@Composable
private fun FilesCard(state: SettingsState, actions: SettingsActions) {
    val filesOn = state.featureOn(BridgeyFeature.FILES)
    val folders = filesOn && state.folders.supported
    FeatureCard(
        SettingsCard.FILES, featureHeader(BridgeyFeature.FILES, state, actions), CardGap,
        rows = {
            featureSync(BridgeyFeature.FILES, state, actions)
            if (folders) folderModeRows(state.folders, actions.folders, state.sync, actions.sync)
            if (filesOn) autoResumeRow(state.folders, actions.folders)
            choiceChips(R.string.feature_files, state, actions)
        },
        more = {
            if (folders) folderMoreRows(state.folders, actions.folders, state.sync, actions.sync)
            row { shape -> ShareWhenRow(shape, state, actions) }
        },
        footer = {
            if (folders) {
                Note(stringResource(if (state.folders.allowBrowse) R.string.settings_folders_note_browse else R.string.settings_folders_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
                Note(stringResource(R.string.settings_folder_send_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
            }
        },
    )
}

/** When I share to Bridgey: send to the active device, or always ask. */
@Composable
private fun ShareWhenRow(shape: Shape, state: SettingsState, actions: SettingsActions) {
    val colors = BridgeyTheme.colors
    Column(
        Modifier.fillMaxWidth().clip(shape).background(colors.surface1)
            .settingsSearchHighlight(stringResource(R.string.share_when), shape)
            .padding(bottom = 6.dp).selectableGroup(),
    ) {
        ListRow(androidx.compose.ui.graphics.RectangleShape, stringResource(R.string.share_when), null, BridgeyIcons.IosShare, Tint.BLUE, searchable = false)
        listOf(false to R.string.share_auto, true to R.string.share_ask).forEach { (ask, label) ->
            val selected = state.shareAlwaysAsk == ask
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .selectable(selected = selected, role = Role.RadioButton) { actions.setShareAlwaysAsk(ask) }
                    .padding(start = 60.dp, end = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = selected, onClick = null,
                    colors = RadioButtonDefaults.colors(selectedColor = colors.primary, unselectedColor = colors.outline),
                )
                Text(stringResource(label), style = BridgeyType.bodyText, color = colors.onSurface, modifier = Modifier.padding(start = 12.dp))
            }
        }
    }
}

// endregion

// region Notifications and calls

@Composable
private fun NotificationsCard(state: SettingsState, actions: SettingsActions) {
    val notificationsOn = state.featureOn(BridgeyFeature.NOTIFICATIONS)
    FeatureCard(
        SettingsCard.NOTIFICATIONS,
        CardHeader(
            stringResource(R.string.settings_forwarding_title), BridgeyIcons.Notifications, Tint.PURPLE,
            switch = CardSwitch(notificationsOn, { actions.setGlobal(BridgeyFeature.NOTIFICATIONS, it) }, synced = state.sync.syncs(SyncKey.NOTIFICATIONS)),
        ),
        CardGap,
        rows = {
            syncRows(SyncKey.NOTIFICATIONS, state.sync, actions.sync)
            if (notificationsOn) {
                row { shape ->
                    ListRow(
                        // Named by what it opens: the card's header already says Notification forwarding.
                        shape, stringResource(R.string.perm_notification_access_name),
                        stringResource(if (state.notificationAccessEnabled) R.string.settings_forwarding_on else R.string.settings_forwarding_off),
                        BridgeyIcons.Notifications, if (state.notificationAccessEnabled) Tint.GREEN else Tint.NEUTRAL,
                        detailWarning = !state.notificationAccessEnabled,
                        onClick = actions.notificationAccess,
                    ) { ManageLabel(state.notificationAccessEnabled) }
                }
                row { shape ->
                    ListRow(
                        shape, stringResource(R.string.settings_notification_apps),
                        pluralStringResource(R.plurals.settings_notification_apps_count, state.notificationAppsTotal, state.notificationAppsEnabled, state.notificationAppsTotal),
                        BridgeyIcons.Notifications, Tint.PURPLE, onClick = actions.openNotificationApps,
                    ) { Chevron() }
                }
            }
            choiceChips(R.string.feature_notifications, state, actions)
        },
        more = {
            smartRoutingRows(state.smartRouting, actions.smartRouting)
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.settings_app_notifications),
                    stringResource(if (state.appNotificationsEnabled) R.string.settings_app_notifications_on else R.string.settings_app_notifications_off),
                    BridgeyIcons.Notifications, if (state.appNotificationsEnabled) Tint.GREEN else Tint.NEUTRAL,
                    onClick = actions.appNotifications,
                ) { ManageLabel(state.appNotificationsEnabled) }
            }
        },
        footer = { Note(stringResource(R.string.smart_routing_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) },
    )
}

@Composable
private fun MessagesCard(state: SettingsState, actions: SettingsActions) {
    val on = state.featureOn(BridgeyFeature.SMS)
    FeatureCard(
        SettingsCard.MESSAGES, featureHeader(BridgeyFeature.SMS, state, actions, detail = true), CardGap,
        rows = {
            featureSync(BridgeyFeature.SMS, state, actions)
            if (on) messagesMainRows(state.messages, actions.messages)
            choiceChips(R.string.feature_sms, state, actions)
        },
        more = { if (on) messagesMoreRows(state.messages, actions.messages) },
        footer = { Note(stringResource(R.string.messages_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) },
    )
}

@Composable
private fun CallsCard(state: SettingsState, actions: SettingsActions) {
    val callsOn = state.featureOn(BridgeyFeature.CALLS)
    FeatureCard(
        SettingsCard.CALLS, featureHeader(BridgeyFeature.CALLS, state, actions, detail = true), CardGap,
        rows = {
            featureSync(BridgeyFeature.CALLS, state, actions)
            if (callsOn) {
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.devices_direct_calls), stringResource(R.string.devices_direct_calls_detail),
                        BridgeyIcons.Call, if (state.directCallsEnabled) Tint.GREEN else Tint.NEUTRAL, state.directCallsEnabled, actions.setDirectCalls,
                    )
                }
            }
            choiceChips(R.string.feature_calls, state, actions)
        },
    )
}

@Composable
private fun CallsWindowCard(state: SettingsState, actions: SettingsActions) {
    val dialerOn = state.featureOn(BridgeyFeature.DIALER)
    FeatureCard(
        SettingsCard.CALLS_WINDOW, featureHeader(BridgeyFeature.DIALER, state, actions, detail = true), CardGap,
        rows = {
            featureSync(BridgeyFeature.DIALER, state, actions)
            if (dialerOn) dialerMainRows(state.dialer, actions.dialer)
            choiceChips(R.string.dialer_title, state, actions)
        },
        more = { if (dialerOn) dialerMoreRows(state.dialer, actions.dialer) },
        footer = { Note(stringResource(R.string.dialer_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) },
    )
}

@Composable
private fun CallQuietCard(state: SettingsState, actions: SettingsActions) {
    val quietOn = state.featureOn(BridgeyFeature.CALL_QUIET)
    FeatureCard(
        SettingsCard.CALL_QUIET, featureHeader(BridgeyFeature.CALL_QUIET, state, actions, detail = true), CardGap,
        rows = {
            featureSync(BridgeyFeature.CALL_QUIET, state, actions)
            if (quietOn) callQuietMainRows(state.callQuiet, actions.callQuiet)
            choiceChips(R.string.call_quiet_title, state, actions)
        },
        more = { if (quietOn) callQuietMoreRows(state.callQuiet, actions.callQuiet) },
    )
}

// endregion

// region Control

@Composable
private fun RemoteCard(state: SettingsState, actions: SettingsActions) {
    val remoteOn = state.featureOn(BridgeyFeature.REMOTE_INPUT)
    FeatureCard(
        SettingsCard.REMOTE, featureHeader(BridgeyFeature.REMOTE_INPUT, state, actions, detail = true), CardGap,
        rows = {
            featureSync(BridgeyFeature.REMOTE_INPUT, state, actions)
            if (remoteOn) {
                row { shape -> PointerSpeedRow(shape, state, actions) }
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.remote_volume_keys_title), stringResource(R.string.remote_volume_keys_detail),
                        BridgeyIcons.VolumeUp, if (state.remoteVolumeKeys) Tint.PURPLE else Tint.NEUTRAL,
                        state.remoteVolumeKeys, actions.setRemoteVolumeKeys,
                    )
                }
            }
            choiceChips(R.string.feature_remote_input, state, actions)
        },
        footer = { Note(stringResource(R.string.remote_settings_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp)) },
    )
}

// endregion

// region Privacy

@Composable
private fun ActivityCard(state: SettingsState, actions: SettingsActions) {
    var confirmClear by rememberSaveable { mutableStateOf(false) }
    FeatureCard(
        SettingsCard.ACTIVITY, null, CardGap,
        rows = {
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.settings_show_previews), stringResource(R.string.settings_show_previews_detail),
                    BridgeyIcons.ContentPaste, if (state.showPreviews) Tint.BLUE else Tint.NEUTRAL, state.showPreviews, actions.setShowPreviews,
                    synced = state.sync.syncs(SyncKey.ACTIVITY_PREVIEWS),
                )
            }
            syncRows(SyncKey.ACTIVITY_PREVIEWS, state.sync, actions.sync)
            row { shape ->
                ListRow(shape, stringResource(R.string.settings_activity), stringResource(R.string.settings_activity_detail), BridgeyIcons.Update, Tint.PURPLE) {
                    OutlinePillButton(stringResource(R.string.action_clear), null, { confirmClear = true }, enabled = state.activityCount > 0)
                }
            }
        },
    )
    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(stringResource(R.string.clear_activity_title)) },
            text = { Text(stringResource(R.string.clear_activity_body)) },
            confirmButton = { TextButton(onClick = { confirmClear = false; actions.clearActivity() }) { Text(stringResource(R.string.action_clear)) } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

// endregion

// region App

@Composable
private fun UpdatesCard(state: SettingsState, actions: SettingsActions) {
    FeatureCard(
        SettingsCard.UPDATES, titleHeader(R.string.settings_updates, BridgeyIcons.SystemUpdate, Tint.PURPLE), CardGap,
        rows = { updatesRows(state.update, state.installedVersion, state.now, actions, state.updateAll.auto) },
        more = {
            row { shape ->
                YourDevicesCard(
                    state.updateAll, actions.updateAll,
                    Modifier.fillMaxWidth().clip(shape).background(BridgeyTheme.colors.surface1).padding(bottom = 4.dp),
                )
            }
        },
    )
}

@Composable
private fun GeneralCard(state: SettingsState, actions: SettingsActions) {
    FeatureCard(
        SettingsCard.GENERAL, titleHeader(R.string.settings_general, BridgeyIcons.Settings, Tint.NEUTRAL), CardGap,
        rows = {
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.settings_background_title),
                    stringResource(if (state.batteryExempt) R.string.settings_background_on else R.string.settings_background_off),
                    BridgeyIcons.Bolt, if (state.batteryExempt) Tint.GREEN else Tint.NEUTRAL,
                    detailWarning = !state.batteryExempt,
                    onClick = actions.openBatterySettings, onClickLabel = stringResource(R.string.settings_background_open),
                ) {
                    if (state.batteryExempt) {
                        Icon(BridgeyIcons.Check, null, tint = BridgeyTheme.colors.onTintGreen)
                    } else {
                        OutlinePillButton(stringResource(R.string.action_allow), null, actions.requestBatteryExemption)
                    }
                }
            }
            row { shape ->
                SwitchRow(
                    shape, stringResource(R.string.settings_reduce_motion), stringResource(R.string.settings_reduce_motion_detail),
                    BridgeyIcons.Animation, Tint.NEUTRAL, state.reduceMotion, actions.setReduceMotion,
                    synced = state.sync.syncs(SyncKey.REDUCE_MOTION),
                )
            }
            syncRows(SyncKey.REDUCE_MOTION, state.sync, actions.sync)
        },
        more = {
            if (state.keepWifiAwakeSupported) {
                row { shape ->
                    SwitchRow(
                        shape, stringResource(R.string.settings_wifi_awake_title), stringResource(R.string.settings_wifi_awake_detail),
                        BridgeyIcons.Wifi, if (state.keepWifiAwake) Tint.BLUE else Tint.NEUTRAL,
                        state.keepWifiAwake, actions.setKeepWifiAwake,
                    )
                }
            }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.settings_turn_off), stringResource(R.string.settings_turn_off_detail),
                    BridgeyIcons.PowerSettingsNew, Tint.NEUTRAL, onClick = actions.turnOff,
                ) { Icon(BridgeyIcons.ChevronRight, null, tint = BridgeyTheme.colors.warn) }
            }
            generalSetupRows(actions.setup)
        },
        footer = {
            Note(stringResource(R.string.settings_background_note), Modifier.padding(start = 32.dp, end = 32.dp, top = 8.dp))
            GeneralOemChecklist(state.setup, actions.setup, actions.openUrl)
        },
    )
}

@Composable
private fun AboutCard(state: SettingsState, actions: SettingsActions) {
    var licences by rememberSaveable { mutableStateOf(false) }
    FeatureCard(
        SettingsCard.ABOUT, titleHeader(R.string.settings_about, BridgeyIcons.Info, Tint.NEUTRAL), CardGap,
        rows = {
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.settings_version), dev.bridgey.android.VersionNames.full(state.installedVersion, state.installedBuild),
                    BridgeyIcons.Info, Tint.BLUE,
                    // Five taps turn on the Developer and experimental card; once on, a tap opens it.
                    onClick = actions.versionTapped,
                )
            }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.settings_licences), stringResource(R.string.settings_licences_detail),
                    BridgeyIcons.Gavel, Tint.NEUTRAL, onClick = { licences = true },
                ) { Chevron() }
            }
        },
        more = { obtainiumRow(state.update.channel, actions.setup) },
        footer = { Credit(actions) },
    )
    if (licences) {
        AlertDialog(
            onDismissRequest = { licences = false },
            title = { Text(stringResource(R.string.settings_licences)) },
            text = { Text(stringResource(R.string.licences_body)) },
            confirmButton = { TextButton(onClick = { licences = false }) { Text(stringResource(R.string.action_close)) } },
        )
    }
}

/** Sync settings with paired devices: the switch, What syncs, and which devices it syncs with. */
@Composable
private fun SyncCard(state: SettingsState, actions: SettingsActions, modifier: Modifier) {
    var choosing by rememberSaveable { mutableStateOf(false) }
    val sync = state.sync
    val enabled = sync.switches.enabled
    FeatureCard(
        SettingsCard.SYNC,
        CardHeader(
            stringResource(R.string.settings_sync_title), BridgeyIcons.Sync, Tint.BLUE,
            detail = stringResource(R.string.settings_sync_detail),
            switch = CardSwitch(enabled, actions.sync.setEnabled),
        ),
        modifier,
        rows = {
            if (enabled) {
                row { shape ->
                    val total = ChoosableSyncKeys.size
                    ListRow(
                        shape, stringResource(R.string.settings_sync_choose),
                        stringResource(R.string.settings_sync_choose_detail, ChoosableSyncKeys.count { it !in sync.switches.excluded }, total),
                        BridgeyIcons.Settings, Tint.NEUTRAL, onClick = { choosing = true },
                    ) { Chevron() }
                }
            }
            deviceChips(R.string.devices_sync_title, syncChips(state, actions.setDeviceSync), state.devices.filter { it.sync && it.syncOffRemote }.map { it.name })
        },
    )
    if (choosing) ChooseWhatSyncsDialog(sync, actions.sync) { choosing = false }
}

/**
 * Developer and experimental (hidden, DeveloperMenu.kt): tests and facts for people chasing a problem, the experiments
 * Rahul turns on before they are ready for everyone, then the way to hide the card again.
 */
@Composable
private fun DeveloperCard(state: SettingsState, actions: SettingsActions) {
    FeatureCard(
        SettingsCard.DEVELOPER, titleHeader(R.string.settings_developer, BridgeyIcons.DeveloperMode, Tint.PURPLE), CardGap,
        rows = {
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.settings_speed_test), stringResource(R.string.settings_speed_test_detail),
                    BridgeyIcons.Wifi, Tint.BLUE, onClick = actions.openSpeedTest,
                ) { Chevron() }
            }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.perf_title), stringResource(R.string.developer_perf_detail),
                    BridgeyIcons.Bolt, Tint.PURPLE, onClick = actions.openPerfTest,
                ) { Chevron() }
            }
            if (state.transferPaths.isEmpty()) {
                row { shape -> ListRow(shape, stringResource(R.string.developer_no_devices), stringResource(R.string.developer_transfers), BridgeyIcons.Devices, Tint.NEUTRAL, searchable = false) }
            }
            state.transferPaths.forEach { path ->
                row { shape ->
                    val route = when (path.tunnelRoute) {
                        null -> stringResource(R.string.developer_route_local)
                        "relay" -> stringResource(R.string.developer_route_relay)
                        else -> stringResource(R.string.developer_route_direct)
                    }
                    val how = stringResource(if (path.fast) R.string.developer_path_fast else R.string.developer_path_json)
                    ListRow(
                        shape, path.deviceName, "$how. $route", if (path.tunnelRoute == null) BridgeyIcons.Lan else BridgeyIcons.Public,
                        if (path.fast) Tint.GREEN else Tint.NEUTRAL, searchable = false,
                    )
                }
            }
            row { shape -> ListRow(shape, stringResource(R.string.developer_experimental_empty), null, BridgeyIcons.Sensors, Tint.NEUTRAL, searchable = false) }
            row { shape ->
                ListRow(
                    shape, stringResource(R.string.developer_turn_off), stringResource(R.string.developer_turn_off_detail),
                    BridgeyIcons.PowerSettingsNew, Tint.NEUTRAL,
                ) { OutlinePillButton(stringResource(R.string.developer_turn_off_action), null, actions.turnOffDeveloper) }
            }
        },
    )
}

// endregion
