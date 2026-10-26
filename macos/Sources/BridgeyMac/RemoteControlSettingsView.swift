import SwiftUI

/*
 * Settings > Remote control: the switch for this Mac, Accessibility (why and where), how to stop,
 * which phones may control this Mac, and the private session log. Drawn from `SettingsModel`, so
 * the screenshots render it from sample state.
 */

struct RemoteControlPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @State private var confirmClear = false
    @Environment(\.brand) private var c

    var body: some View {
        let on = model.globalFeatures[.remoteInput] == true
        if let session = model.remoteSession {
            SettingsCard {
                SettingsRow(title: String(format: L10n.text("remote.pill.title", fallback: "%@ is controlling this Mac"), session.deviceName),
                            subtitle: String(format: L10n.text("remote.active.detail", fallback: "%@, since %@"),
                                             modeTitle(session.mode), session.startedAt.formatted(date: .omitted, time: .shortened)),
                            divider: false) {
                    Button(L10n.text("action.stop", fallback: "Stop"), action: actions.stopRemoteControl)
                        .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                }
            }
        }
        SettingsCard(footnote: L10n.text("remote.footnote", fallback: "Each phone needs its own permission, below, and Remote control turned on in Bridgey on the phone. Typing, keys and slides use a short list of keys; shortcuts such as Quit or Lock are never sent.")) {
            SettingsToggle(title: BridgeyFeature.remoteInput.title, subtitle: BridgeyFeature.remoteInput.subtitle, divider: false,
                           isOn: on, set: { actions.setGlobal(.remoteInput, $0) })
            AccessibilityRow(trusted: model.accessibilityTrusted, open: actions.openAccessibilitySettings)
            SettingsRow(title: L10n.text("remote.stop.title", fallback: "Stop at any time"),
                        subtitle: L10n.text("remote.stop.detail", fallback: "Press Control-Option-Escape, or Stop in the pill at the top of the screen. The pill shows for the whole session.")) {
                KeyCap(text: "\u{2303}\u{2325}\u{238B}")
            }
        }
        SettingsCard(title: L10n.text("remote.devices", fallback: "Phones allowed to control this Mac")) {
            if model.trustedDevices.isEmpty {
                SettingsRow(title: L10n.text("devices.none", fallback: "No paired devices yet"), divider: false) { EmptyView() }
            }
            ForEach(Array(model.trustedDevices.enumerated()), id: \.element.id) { index, device in
                RemoteControlGrantToggle(device: device, model: model, actions: actions, title: device.name, divider: index > 0)
            }
        }
        SettingsCard(title: L10n.text("remote.log", fallback: "Session log"),
                     footnote: L10n.text("remote.log.detail", fallback: "Kept only on this Mac, for 30 days. It records which phone controlled this Mac, when, for how long and how many moves, clicks and keys, never what was typed.")) {
            if model.remoteAudit.isEmpty {
                SettingsRow(title: L10n.text("remote.log.empty", fallback: "No remote control yet"), divider: false) { EmptyView() }
            } else {
                ForEach(Array(model.remoteAudit.prefix(8).enumerated()), id: \.element.id) { index, entry in
                    AuditRow(entry: entry, divider: index > 0)
                }
                SettingsRow(title: model.remoteAudit.count > 8
                                ? String(format: L10n.text("remote.log.more", fallback: "%d more in the last 30 days"), model.remoteAudit.count - 8)
                                : "") {
                    Button(L10n.text("remote.log.clear", fallback: "Clear log")) { confirmClear = true }
                        .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                }
            }
        }
        .confirmationDialog(L10n.text("remote.log.clear.title", fallback: "Clear the session log?"), isPresented: $confirmClear) {
            Button(L10n.text("action.clear", fallback: "Clear"), role: .destructive, action: actions.clearRemoteAudit)
        } message: {
            Text(L10n.text("remote.log.clear.body", fallback: "This removes the record of past remote control sessions from this Mac."))
        }
    }
}

/// Settings > Devices > [phone] and the Remote control pane: the per-device grant, off by default.
struct RemoteControlGrantToggle: View {
    let device: TrustedDeviceInfo
    let model: SettingsModel
    let actions: SettingsActions
    var title: String?
    var divider = true

    var body: some View {
        let granted = model.remoteGrant(for: device.id)
        let warning = note
        SettingsToggle(
            title: title ?? L10n.text("remote.grant", fallback: "Allow remote control"),
            subtitle: warning ?? (granted
                ? L10n.text("remote.grant.on", fallback: "Can use this Mac\u{2019}s pointer, keyboard and slides")
                : L10n.text("remote.grant.off", fallback: "Off until you allow it")),
            subtitleIsWarning: warning != nil,
            divider: divider,
            isOn: granted,
            set: { actions.setForDevice(device.id, .remoteInput, $0) }
        )
    }

    /// Why a granted phone still cannot control this Mac.
    private var note: String? {
        guard model.remoteGrant(for: device.id) else { return nil }
        if model.globalFeatures[.remoteInput] != true {
            return L10n.text("remote.grant.globalOff", fallback: "Remote control is off on this Mac. Turn it on in Remote control.")
        }
        if model.phoneFeatures[device.id]?[.remoteInput] == false {
            return String(format: L10n.text("remote.grant.phoneOff", fallback: "Turn on Remote control in Bridgey on %@"), device.name)
        }
        return nil
    }
}

private struct AccessibilityRow: View {
    let trusted: Bool
    let open: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        SettingsRow(title: L10n.text("remote.accessibility", fallback: "Accessibility access"),
                    subtitle: trusted
                        ? L10n.text("remote.accessibility.on", fallback: "Allowed. macOS requires it for any app that moves the pointer or types; Bridgey uses it only during a session you can see.")
                        : L10n.text("remote.accessibility.off", fallback: "Needed to move the pointer and type. macOS asks when you first allow a phone. If you said no, turn on Bridgey in Privacy & Security > Accessibility."),
                    subtitleIsWarning: !trusted) {
            if trusted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text(L10n.text("remote.accessibility.allowed", fallback: "Allowed"))
                }
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(c.tgi)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(c.tg))
            } else {
                Button(L10n.text("remote.accessibility.open", fallback: "Open System Settings"), action: open)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            }
        }
    }
}

private struct AuditRow: View {
    let entry: RemoteControlAuditEntry
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
            Text(entry.startedAt, format: .dateTime.day().month().hour().minute())
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let reason = auditReasonText(entry)
        guard entry.accepted else { return reason }
        var parts = [remoteDurationText(entry.duration)]
        let counts = auditCountsText(entry.counts)
        if !counts.isEmpty { parts.append(counts) }
        parts.append(reason)
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct KeyCap: View {
    let text: String
    @Environment(\.brand) private var c

    var body: some View {
        Text(text)
            .font(BrandFont.body(13, .medium))
            .foregroundStyle(c.on)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.s3))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(c.ol, lineWidth: 1))
            .accessibilityLabel(L10n.text("remote.stop.shortcut", fallback: "Control-Option-Escape"))
    }
}

func modeTitle(_ mode: RemoteInputMode) -> String {
    switch mode {
    case .touchpad: L10n.text("remote.mode.touchpad", fallback: "Touchpad")
    case .presentation: L10n.text("remote.mode.presentation", fallback: "Presentation")
    }
}

/// How a session ended, or why a start was refused, in plain words.
func auditReasonText(_ entry: RemoteControlAuditEntry) -> String {
    switch entry.reason {
    case .user: L10n.text("remote.reason.user", fallback: "Stopped on the phone")
    case .leftScreen: L10n.text("remote.reason.leftScreen", fallback: "Closed on the phone")
    case .screenOff: L10n.text("remote.reason.screenOff", fallback: "Phone screen turned off")
    case .localStop: L10n.text("remote.reason.localStop", fallback: "Stopped on this Mac")
    case .timeout: L10n.text("remote.reason.timeout", fallback: "Ended after 6 seconds without input")
    case .disabled: entry.accepted
        ? L10n.text("remote.reason.disabled", fallback: "Ended: permission turned off")
        : L10n.text("remote.reason.refusedDisabled", fallback: "Refused: not allowed for this phone")
    case .permissionRequired: entry.accepted
        ? L10n.text("remote.reason.permissionLost", fallback: "Ended: Accessibility access was removed")
        : L10n.text("remote.reason.refusedPermission", fallback: "Refused: Accessibility access needed")
    case .busy: L10n.text("remote.reason.busy", fallback: "Refused: another phone was in control")
    case .invalid: L10n.text("remote.reason.invalid", fallback: "Refused: the request was not valid")
    case .unsupported: L10n.text("remote.reason.unsupported", fallback: "Refused: not supported")
    case .disconnected: L10n.text("remote.reason.disconnected", fallback: "Connection lost")
    case .replaced: L10n.text("remote.reason.replaced", fallback: "Restarted from the phone")
    case nil: entry.endReason
    }
}

/// "Moves: 2140 · Clicks: 36": only types that happened, in a fixed order.
func auditCountsText(_ counts: [String: Int]) -> String {
    let labels: [(RemoteInputEventType, String)] = [
        (.pointer, L10n.text("remote.count.pointer", fallback: "Moves: %d")),
        (.button, L10n.text("remote.count.button", fallback: "Clicks: %d")),
        (.scroll, L10n.text("remote.count.scroll", fallback: "Scrolls: %d")),
        (.drag, L10n.text("remote.count.drag", fallback: "Drags: %d")),
        (.key, L10n.text("remote.count.key", fallback: "Keys: %d")),
        (.text, L10n.text("remote.count.text", fallback: "Texts: %d")),
        (.present, L10n.text("remote.count.present", fallback: "Slide actions: %d")),
    ]
    return labels.compactMap { type, format in
        counts[type.rawValue].flatMap { $0 > 0 ? String(format: format, $0) : nil }
    }.joined(separator: " \u{00B7} ")
}

func remoteDurationText(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
    formatter.maximumUnitCount = 2
    return formatter.string(from: max(1, seconds.rounded())) ?? ""
}
