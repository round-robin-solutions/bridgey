import SwiftUI

extension CallMediaMode {
    var title: String {
        switch self {
        case .pauseThenMute: L10n.text("callMedia.mode.pauseMute", fallback: "Pause, then mute what cannot pause")
        case .pauseOnly: L10n.text("callMedia.mode.pause", fallback: "Pause only")
        case .muteOnly: L10n.text("callMedia.mode.mute", fallback: "Mute only")
        }
    }
}

extension CallMediaRestoration {
    /// Temporary Mac mutes always release at call end. Keep the old stored key readable,
    /// but do not offer two choices with the same sound-only behavior.
    static let macChoices: [CallMediaRestoration] = [.restoreAndResume, .restoreSound]
    var title: String {
        switch self {
        case .restoreAndResume: L10n.text("callMedia.restore.resume", fallback: "Restore sound and resume playback")
        case .restoreSound: L10n.text("callMedia.restore.sound", fallback: "Restore sound, leave playback paused")
        case .leaveAsIs: L10n.text("callMedia.restore.macManual", fallback: "Restore sound, resume playback manually")
        }
    }
}

struct CallMediaSettingsCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    private var enabled: Bool { model.globalFeatures[.callQuiet] == true }
    private var devices: [TrustedDeviceInfo] { model.trustedDevices.filter { !model.restrictedDevices.contains($0.id) } }

    var body: some View {
        SettingsCard(footnote: L10n.text("callMedia.limits", fallback: "Allow each device in Devices. Music and Spotify have independent controls; other apps may be limited. Call audio is protected. Mac calls without an integration use the manual mark below.")) {
            SettingsToggle(title: BridgeyFeature.callQuiet.title, subtitle: BridgeyFeature.callQuiet.subtitle,
                           divider: false, isOn: enabled, set: { actions.setGlobal(.callQuiet, $0) })
            SettingsRow(title: L10n.text("callMedia.mode", fallback: "During a call")) {
                Picker("", selection: Binding(get: { model.callMediaMode }, set: actions.setCallMediaMode)) {
                    ForEach(CallMediaMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: 270)
            }.disabled(!enabled)
            SettingsRow(title: L10n.text("callMedia.restore", fallback: "After the last call"),
                        subtitle: L10n.text("callMedia.ownership", fallback: "Only changes made by Bridgey are restored. Later playback, volume and output choices stay yours.")) {
                Picker("", selection: Binding(get: { model.callMediaRestoration == .leaveAsIs ? .restoreSound : model.callMediaRestoration }, set: actions.setCallMediaRestoration)) {
                    ForEach(CallMediaRestoration.macChoices, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: 270)
            }.disabled(!enabled)
            SettingsRow(title: L10n.text("callMedia.manual", fallback: "This Mac's call status"),
                        subtitle: L10n.text("callMedia.manual.detail", fallback: "A manual mark for FaceTime, Zoom or browser calls. It never answers or ends an actual call.")) {
                Button(model.callMediaManual ? L10n.text("callMedia.offCall", fallback: "I'm off the call") : L10n.text("callMedia.onCall", fallback: "I'm on a call")) {
                    actions.setManualCall(!model.callMediaManual)
                }.buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
            }.disabled(!enabled)
            if !devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(devices) { device in
                        Text(device.name + ": " + (model.callMediaStatuses[device.id] ?? L10n.text("callMedia.waiting", fallback: "Waiting for this device's playback result")))
                            .font(BrandFont.body(12))
                    }
                }.padding(.vertical, 6).settingsSearchSkip()
            }
            if !model.callMediaRecovery.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.callMediaRecovery) { item in
                        Label(item.temporaryMute ? String(format: L10n.text("callMedia.recovery.temporary",
                            fallback: "Bridgey could not release %@'s temporary mute. Try Restore sound."), item.appName) :
                            String(format: L10n.text("callMedia.recovery", fallback: "Open %@, restore its volume (previously %d%%), then check sound recovery or retry Reset Everything."),
                                     item.appName, item.originalVolume), systemImage: "exclamationmark.triangle")
                            .font(BrandFont.body(12)).foregroundStyle(c.warn)
                    }
                    Button(L10n.text("callMedia.recovery.check", fallback: "Check sound recovery"), action: actions.checkCallMediaRecovery)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }.padding(.vertical, 6).settingsSearchSkip()
            }
            if model.callMediaCanRestoreSound {
                SettingsRow(title: L10n.text("callMedia.restore.backup", fallback: "Restore sound"),
                    subtitle: L10n.text("callMedia.restore.backup.detail", fallback: "Remove Bridgey's temporary mute without starting playback. This also works during a call.")) {
                    Button(L10n.text("callMedia.restore.backup", fallback: "Restore sound"), action: actions.restoreCallMediaSound)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                }
            }
        }
    }
}

struct CallMediaGrantToggle: View {
    let device: TrustedDeviceInfo
    let model: SettingsModel
    let actions: SettingsActions
    var body: some View {
        SettingsToggle(title: L10n.text("callMedia.grant", fallback: "Allow call status and media quieting"),
                       subtitle: model.callMediaStatuses[device.id],
                       isOn: model.globalFeatures[.callQuiet] == true && model.deviceFeatures[device.id]?[.callQuiet] == true,
                       set: { actions.setForDevice(device.id, .callQuiet, $0) })
            .disabled(model.globalFeatures[.callQuiet] != true || model.restrictedDevices.contains(device.id))
    }
}

/// Uses the existing panel/PillButton treatments and remains reachable without selecting a phone.
struct CallMediaManualPanelRow: View {
    let active: Bool
    let toggle: () -> Void
    @Environment(\.brand) private var c
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: active ? "phone.fill" : "phone").foregroundStyle(c.on2)
            Text(L10n.text("callMedia.manual.short", fallback: "This Mac's call"))
                .font(BrandFont.body(12)).foregroundStyle(c.on2)
            Spacer(minLength: 6)
            Button(active ? L10n.text("callMedia.offCall", fallback: "I'm off the call") : L10n.text("callMedia.onCall", fallback: "I'm on a call"), action: toggle)
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                .frame(minWidth: 140)
        }
        .frame(minHeight: 38)
        .help(L10n.text("callMedia.manual.detail", fallback: "A manual mark for FaceTime, Zoom or browser calls. It never answers or ends an actual call."))
    }
}
