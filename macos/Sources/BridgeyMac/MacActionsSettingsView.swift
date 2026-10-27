import AppKit
import SwiftUI
import UniformTypeIdentifiers

/*
 * Settings > Media and actions, Mac actions part: the switch for this Mac, which actions phones
 * may use, the apps and Shortcuts they may open, which phones are allowed, and the private action
 * log. Drawn from `SettingsModel`, so the screenshots render it from sample state.
 */

struct MacActionsCards: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmClear = false
    @Environment(\.brand) private var c

    var body: some View {
        let on = model.globalFeatures[.macActions] == true
        SettingsCard(title: L10n.text("settings.macActions", fallback: "Mac actions"),
                     footnote: L10n.text("actions.footnote", fallback: "A phone can only pick from this list, and only if you allow that phone below. It never sends commands, and Bridgey never runs anything else.")) {
            SettingsToggle(title: BridgeyFeature.macActions.title, subtitle: BridgeyFeature.macActions.subtitle, divider: false,
                           isOn: on, set: { actions.setGlobal(.macActions, $0) })
            ForEach(MacActionSwitch.allCases) { item in
                SettingsToggle(title: macActionSwitchTitle(item), subtitle: switchNote(item), subtitleIsWarning: switchWarning(item),
                               isOn: model.macActions.isOn(item), set: { actions.setMacActionSwitch(item, $0) })
                    .disabled(!on)
            }
            if on && model.macActions.isOn(.lock) && !model.accessibilityTrusted {
                SettingsRow(title: L10n.text("remote.accessibility", fallback: "Accessibility access"),
                            subtitle: L10n.text("actions.lock.accessibility", fallback: "Lock screen presses the macOS Lock Screen shortcut, which needs Accessibility. Turn on Bridgey in Privacy & Security > Accessibility."),
                            subtitleIsWarning: true) {
                    Button(L10n.text("remote.accessibility.open", fallback: "Open System Settings"), action: actions.openAccessibilitySettings)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
            }
        }
        SettingsCard(title: L10n.text("actions.apps", fallback: "Apps a phone can open"),
                     footnote: String(format: L10n.text("actions.apps.detail", fallback: "Up to %d apps. The phone sees their names; it can only open them."), MacActionsConfig.maximumApps)) {
            ForEach(Array(model.macActions.apps.enumerated()), id: \.element.id) { index, app in
                SettingsRow(title: app.name, subtitle: app.bundleID, divider: index > 0) {
                    Button(L10n.text("action.remove", fallback: "Remove")) { actions.removeMacActionApp(app.bundleID) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
            }
            SettingsRow(title: model.macActions.apps.isEmpty ? L10n.text("actions.apps.empty", fallback: "No apps yet") : "",
                        divider: !model.macActions.apps.isEmpty) {
                Button(L10n.text("actions.apps.add", fallback: "Add app\u{2026}"), action: actions.addMacActionApps)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                    .disabled(!on || model.macActions.apps.count >= MacActionsConfig.maximumApps)
            }
        }
        SettingsCard(title: L10n.text("actions.shortcuts", fallback: "Shortcuts a phone can run"),
                     footnote: L10n.text("actions.shortcuts.detail", fallback: "From the Shortcuts app on this Mac. They run with no input from the phone, one at a time, for up to a minute.")) {
            ForEach(Array(model.macActions.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                SettingsRow(title: shortcut.name, divider: index > 0) {
                    Button(L10n.text("action.remove", fallback: "Remove")) { actions.removeMacActionShortcut(shortcut.id) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
            }
            SettingsRow(title: shortcutsRowTitle, subtitle: model.availableShortcuts == nil ? nil : shortcutsRowSubtitle,
                        divider: !model.macActions.shortcuts.isEmpty) {
                PopUpMenuButton(items: shortcutMenu) {
                    Text(L10n.text("actions.shortcuts.add", fallback: "Add Shortcut"))
                        .font(BrandFont.body(13, .medium))
                        .foregroundStyle(c.on)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(c.s3))
                        .contentShape(Capsule())
                }
                .disabled(!on || model.macActions.shortcuts.count >= MacActionsConfig.maximumShortcuts)
            }
        }
        SettingsCard(title: L10n.text("actions.devices", fallback: "Phones allowed to use Mac actions")) {
            if model.trustedDevices.isEmpty {
                SettingsRow(title: L10n.text("devices.none", fallback: "No paired devices yet"), divider: false) { EmptyView() }
            }
            ForEach(Array(model.trustedDevices.enumerated()), id: \.element.id) { index, device in
                MacActionsGrantToggle(device: device, model: model, actions: actions, title: device.name, divider: index > 0)
            }
        }
        SettingsCard(title: L10n.text("actions.log", fallback: "Action log"),
                     footnote: L10n.text("actions.log.detail", fallback: "Kept only on this Mac, for 30 days: which phone asked for what, when, and whether it ran.")) {
            if model.macActionsAudit.isEmpty {
                SettingsRow(title: L10n.text("actions.log.empty", fallback: "No actions yet"), divider: false) { EmptyView() }
            } else {
                ForEach(Array(model.macActionsAudit.prefix(8).enumerated()), id: \.element.id) { index, entry in
                    MacActionAuditRow(entry: entry, divider: index > 0)
                }
                SettingsRow(title: model.macActionsAudit.count > 8
                                ? String(format: L10n.text("remote.log.more", fallback: "%d more in the last 30 days"), model.macActionsAudit.count - 8)
                                : "") {
                    Button(L10n.text("remote.log.clear", fallback: "Clear log")) { confirmClear = true }
                        .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                }
            }
        }
        .confirmationDialog(L10n.text("actions.log.clear.title", fallback: "Clear the action log?"), isPresented: $confirmClear) {
            Button(L10n.text("action.clear", fallback: "Clear"), role: .destructive, action: actions.clearMacActionsAudit)
        } message: {
            Text(L10n.text("actions.log.clear.body", fallback: "This removes the record of past Mac actions from this Mac."))
        }
    }

    private var shortcutsRowTitle: String {
        model.macActions.shortcuts.isEmpty ? L10n.text("actions.shortcuts.empty", fallback: "No Shortcuts yet") : ""
    }

    private var shortcutsRowSubtitle: String? {
        guard let names = model.availableShortcuts else { return nil }
        return names.isEmpty ? L10n.text("actions.shortcuts.none", fallback: "No Shortcuts found on this Mac") : nil
    }

    private func shortcutMenu() -> [PopUpMenuItem] {
        guard let names = model.availableShortcuts else {
            return [PopUpMenuItem(title: L10n.text("actions.shortcuts.loading", fallback: "Loading Shortcuts\u{2026}"), enabled: false) {}]
        }
        let added = Set(model.macActions.shortcuts.map(\.name))
        let choices = names.filter { !added.contains($0) }
        guard !choices.isEmpty else {
            return [PopUpMenuItem(title: L10n.text("actions.shortcuts.allAdded", fallback: "No other Shortcuts"), enabled: false) {}]
        }
        return choices.prefix(200).map { name in PopUpMenuItem(title: name) { actions.addMacActionShortcut(name) } }
    }

    private func switchNote(_ item: MacActionSwitch) -> String? {
        switch item {
        case .lock: L10n.text("actions.lock.detail", fallback: "Locks this Mac like Control-Command-Q")
        case .sleep: L10n.text("actions.sleep.detail", fallback: "Puts this Mac to sleep; the phone reconnects when it wakes")
        case .screensaver: nil
        case .volume: L10n.text("actions.volume.detail", fallback: "Up, down, mute and a level, for the current output")
        }
    }

    private func switchWarning(_ item: MacActionSwitch) -> Bool { false }
}

func macActionSwitchTitle(_ item: MacActionSwitch) -> String {
    switch item {
    case .lock: macSystemActionTitle(.lock)
    case .sleep: macSystemActionTitle(.sleep)
    case .screensaver: macSystemActionTitle(.screensaver)
    case .volume: L10n.text("actions.volume", fallback: "Volume")
    }
}

/// Settings > Devices > [phone] and the Mac actions card: the per-device grant, off by default.
struct MacActionsGrantToggle: View {
    let device: TrustedDeviceInfo
    let model: SettingsModel
    let actions: SettingsActions
    var title: String?
    var divider = true

    var body: some View {
        let granted = model.deviceFeatures[device.id]?[.macActions] == true
        let warning = note(granted: granted)
        SettingsToggle(
            title: title ?? L10n.text("actions.grant", fallback: "Allow Mac actions"),
            subtitle: warning ?? (granted
                ? L10n.text("actions.grant.on", fallback: "Can use the actions, apps and Shortcuts you listed")
                : L10n.text("remote.grant.off", fallback: "Off until you allow it")),
            subtitleIsWarning: warning != nil,
            divider: divider,
            isOn: granted,
            set: { actions.setForDevice(device.id, .macActions, $0) }
        )
    }

    private func note(granted: Bool) -> String? {
        guard granted else { return nil }
        if model.globalFeatures[.macActions] != true {
            return L10n.text("actions.grant.globalOff", fallback: "Mac actions is off on this Mac. Turn it on in Media and actions.")
        }
        if model.phoneFeatures[device.id]?[.macActions] == false {
            return String(format: L10n.text("actions.grant.phoneOff", fallback: "Turn on Mac actions in Bridgey on %@"), device.name)
        }
        return nil
    }
}

private struct MacActionAuditRow: View {
    let entry: MacActionAuditEntry
    let divider: Bool
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.deviceName)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                Text(detail)
                    .font(BrandFont.body(12))
                    .foregroundStyle(entry.accepted ? c.on2 : c.tpi)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.at, format: .dateTime.day().month().hour().minute())
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let title = entry.title.isEmpty ? L10n.text("actions.unknown", fallback: "Unknown action") : entry.title
        return "\(title) \u{00B7} \(macActionOutcomeText(entry.outcome))"
    }
}

func macActionOutcomeText(_ outcome: String) -> String {
    switch outcome {
    case "done": L10n.text("actions.outcome.done", fallback: "Done")
    case MacActionRefusal.notAllowed.rawValue: L10n.text("actions.outcome.notAllowed", fallback: "Refused: not allowed")
    case MacActionRefusal.invalid.rawValue: L10n.text("actions.outcome.invalid", fallback: "Refused: not a valid request")
    case MacActionRefusal.rateLimited.rawValue: L10n.text("actions.outcome.rateLimited", fallback: "Refused: too many at once")
    case MacActionRefusal.busy.rawValue: L10n.text("actions.outcome.busy", fallback: "Refused: a Shortcut was still running")
    case MacActionRefusal.permissionRequired.rawValue: L10n.text("actions.outcome.permission", fallback: "Refused: Accessibility access needed")
    case MacActionRefusal.unavailable.rawValue: L10n.text("actions.outcome.unavailable", fallback: "Not available on this Mac")
    default: L10n.text("actions.outcome.failed", fallback: "Failed")
    }
}

/// Settings > Devices > [phone]: how the connection is doing. No addresses.
struct ConnectionHealthRow: View {
    let health: ConnectionHealthSnapshot?
    let now: Date

    var body: some View {
        SettingsRow(title: L10n.text("health.title", fallback: "Connection health"), subtitle: lines.joined(separator: "\n")) { EmptyView() }
    }

    private var lines: [String] {
        guard let health else { return [L10n.text("health.none", fallback: "Nothing measured yet")] }
        var lines: [String] = []
        if health.connected {
            var first = [routeText(health.route)]
            if let outbound = health.outbound {
                first.append(outbound ? L10n.text("health.dialled.mac", fallback: "this Mac connected") : L10n.text("health.dialled.phone", fallback: "the phone connected"))
            }
            if let since = health.connectedSince {
                first.append(String(format: L10n.text("health.since", fallback: "since %@"), since.formatted(date: .omitted, time: .shortened)))
            }
            lines.append(first.joined(separator: " \u{00B7} "))
            if let last = health.roundTripLast {
                var rtt = String(format: L10n.text("health.rtt", fallback: "Round trip %@"), roundTripText(last))
                if let median = health.roundTripMedian, health.roundTripMedian != health.roundTripLast {
                    rtt += " " + String(format: L10n.text("health.rtt.median", fallback: "(typical %@)"), roundTripText(median))
                }
                lines.append(rtt)
            } else {
                lines.append(L10n.text("health.rtt.waiting", fallback: "Measuring the round trip\u{2026}"))
            }
        } else {
            lines.append(L10n.text("health.offline", fallback: "Not connected"))
        }
        var second: [String] = []
        if let reason = health.lastDropReason {
            var text = String(format: L10n.text("health.lastDrop", fallback: "Last disconnect: %@"), dropReasonText(reason))
            if let at = health.lastDropAt { text += ", " + at.formatted(date: Calendar.current.isDate(at, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened) }
            second.append(text)
        }
        second.append(String(format: L10n.text("health.reconnects", fallback: "Reconnects today: %d"), health.reconnectsToday))
        lines.append(second.joined(separator: " \u{00B7} "))
        switch health.discovery {
        case .denied: lines.append(L10n.text("health.discovery.denied", fallback: "Discovery is not working: check Local Network access"))
        case .stopped: lines.append(L10n.text("health.discovery.stopped", fallback: "Discovery is stopped"))
        case .browsing:
            lines.append(health.discoveryVisible
                ? L10n.text("health.discovery.visible", fallback: "Seen on this network now")
                : L10n.text("health.discovery.notVisible", fallback: "Not seen on this network now"))
        }
        return lines
    }
}

/// Add app...: an open panel limited to applications. Only the bundle identifier and the name are kept.
@MainActor
func chooseAllowedApps() -> [AllowedApp] {
    let panel = NSOpenPanel()
    panel.title = L10n.text("actions.apps.choose", fallback: "Choose apps a phone can open")
    panel.prompt = L10n.text("actions.apps.choose.prompt", fallback: "Allow")
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else { return [] }
    return panel.urls.compactMap { url in
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AllowedApp(bundleID: id, name: name)
    }
}

/// Settings > Devices > [phone]: when to say the phone's battery is low or charged.
struct BatteryAlertsRow: View {
    let thresholds: BatteryAlertThresholds
    let enabled: Bool
    let set: (BatteryAlertThresholds) -> Void

    var body: some View {
        SettingsRow(title: L10n.text("battery.alerts", fallback: "Battery alerts"),
                    subtitle: L10n.text("battery.alerts.detail", fallback: "A notification when the phone runs low, and when it has charged. Once per charge.")) {
            ChoiceButton(value: label(L10n.text("battery.alerts.low", fallback: "Low"), thresholds.low)) {
                BatteryAlertThresholds.lowChoices.map { value in
                    PopUpMenuItem(title: choiceTitle(value), checked: value == thresholds.low) {
                        set(BatteryAlertThresholds(low: value, full: thresholds.full))
                    }
                }
            }
            ChoiceButton(value: label(L10n.text("battery.alerts.full", fallback: "Charged"), thresholds.full)) {
                BatteryAlertThresholds.fullChoices.map { value in
                    PopUpMenuItem(title: choiceTitle(value), checked: value == thresholds.full) {
                        set(BatteryAlertThresholds(low: thresholds.low, full: value))
                    }
                }
            }
        }
        .disabled(!enabled)
    }

    private func label(_ name: String, _ value: Int) -> String { "\(name): \(choiceTitle(value))" }

    private func choiceTitle(_ value: Int) -> String {
        value == 0 ? L10n.text("battery.alerts.off", fallback: "Off") : "\(value)%"
    }
}
