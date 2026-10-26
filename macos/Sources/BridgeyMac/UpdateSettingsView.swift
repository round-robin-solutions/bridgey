import SwiftUI

/// Settings > Updates (Round Robin edition), wired to the Sparkle updater through `SettingsModel`.
struct UpdatesPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        if model.updateFlow != .idle {
            UpdateFlowCard(flow: model.updateFlow, currentVersion: model.shortVersion, actions: actions.update)
        }
        versionCard
        HStack(alignment: .top, spacing: 16) {
            channelCard
            whatsNewCard
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var versionCard: some View {
        UpdatesCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: L10n.text("updates.version", fallback: "Version %@"), model.shortVersion))
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(c.on)
                    HStack(spacing: 6) {
                        if model.lastCheck != nil && model.updatesAvailable {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(c.good)
                        }
                        Text(checkedText)
                            .font(BrandFont.body(12))
                            .foregroundStyle(c.on2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: actions.checkForUpdates) {
                    Label(L10n.text("updates.checkNow", fallback: "Check now"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PillButtonStyle(kind: .outline, height: 34))
                .disabled(!model.updatesAvailable || !model.canCheckForUpdates)
            }
        }
    }

    private var checkedText: String {
        guard model.updatesAvailable else {
            return L10n.text("updates.unavailable", fallback: "Updates work only in the installed app.")
        }
        guard let lastCheck = model.lastCheck else { return L10n.text("updates.notChecked", fallback: "Not checked yet.") }
        let calendar = Calendar.current
        let time = lastCheck.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(lastCheck, inSameDayAs: model.now) {
            return String(format: L10n.text("updates.checkedToday", fallback: "Checked today at %@."), time)
        }
        return String(format: L10n.text("updates.checked", fallback: "Checked %@."), lastCheck.formatted(date: .abbreviated, time: .shortened))
    }

    private var channelCard: some View {
        UpdatesCard {
            Text(L10n.text("updates.channel", fallback: "Release channel"))
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on2)
                .padding(.bottom, 10)
            ChannelPicker(selected: model.channel, onSelect: actions.setChannel)
            Text(model.channel.detail)
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
                .padding(.top, 10)
            Text(L10n.text("updates.channel.note", fallback: "Switching to a steadier channel waits for its next release; nothing is downgraded."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Toggle(isOn: Binding(get: { model.automaticallyChecks }, set: actions.setAutomaticallyChecks)) {
                Text(L10n.text("updates.automatic", fallback: "Check for updates automatically"))
                    .font(BrandFont.body(13))
                    .foregroundStyle(c.on)
            }
            .toggleStyle(BrandSwitchStyle())
            .disabled(!model.updatesAvailable)
            .frame(height: 40)
            .padding(.top, 8)
        }
    }

    private var whatsNewCard: some View {
        UpdatesCard {
            HStack {
                Text(L10n.text("updates.whatsNew", fallback: "What's new"))
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on2)
                Spacer()
                Button {
                    actions.openURL(SettingsLinks.releases)
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.text("updates.releaseNotes", fallback: "Release notes"))
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11, weight: .semibold))
                    }
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.pri)
                }
                .buttonStyle(.plain)
            }
            WhatsNewRow(version: model.shortVersion, line: L10n.text("updates.installedHere", fallback: "Installed on this Mac"))
                .padding(.top, 8)
        }
    }
}

struct UpdatesCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
    }
}

/// Stable, Beta, Nightly as one segmented control drawn in SwiftUI.
private struct ChannelPicker: View {
    let selected: UpdateChannel
    let onSelect: (UpdateChannel) -> Void
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UpdateChannel.allCases) { channel in
                let on = channel == selected
                Button {
                    withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { onSelect(channel) }
                } label: {
                    HStack(spacing: 6) {
                        if on {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        }
                        Text(channel.title)
                    }
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(on ? c.on : c.on2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(c.isDark ? Color(hex: 0x2A3242) : c.s1)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s3))
    }
}

private struct WhatsNewRow: View {
    let version: String
    let line: String
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(LinearGradient(colors: [BrandPalette.auroraPurple, BrandPalette.auroraGreen], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 10, height: 10)
            Text(version)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on)
                .frame(minWidth: 40, alignment: .leading)
            Text(line)
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
                .lineLimit(1)
        }
        .frame(height: 40)
    }
}

// MARK: - In-app update flow (shared by Settings and the Stream panel)

struct UpdateFlowActions {
    var install: () -> Void = {}
    var later: () -> Void = {}
    var skip: () -> Void = {}
    var cancel: () -> Void = {}
    var dismiss: () -> Void = {}
    var checkAgain: () -> Void = {}
}

/// The buttons each step offers. `compact` drops Skip for the narrow panel card.
struct UpdateFlowButtons: View {
    let flow: UpdateFlow
    let actions: UpdateFlowActions
    var compact = false
    var height: CGFloat = 28

    var body: some View {
        switch flow {
        case let .available(offer):
            if !compact {
                Button(L10n.text("update.skip", fallback: "Skip this version"), action: actions.skip)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
            }
            Button(L10n.text("update.later", fallback: "Later"), action: actions.later)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
            Button(offer.downloaded
                   ? L10n.text("update.restart", fallback: "Restart to update")
                   : L10n.text("update.install", fallback: "Install"), action: actions.install)
                .buttonStyle(PillButtonStyle(kind: .gradient, height: height))
        case .checking, .downloading:
            Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
        case .ready:
            Button(L10n.text("update.later", fallback: "Later"), action: actions.later)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
            Button(L10n.text("update.restart", fallback: "Restart to update"), action: actions.install)
                .buttonStyle(PillButtonStyle(kind: .gradient, height: height))
        case .upToDate:
            Button(L10n.text("action.dismiss", fallback: "Dismiss"), action: actions.dismiss)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
        case .failed:
            Button(L10n.text("action.dismiss", fallback: "Dismiss"), action: actions.dismiss)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
            Button(L10n.text("action.retry", fallback: "Retry"), action: actions.checkAgain)
                .buttonStyle(PillButtonStyle(kind: .tonal, height: height))
        case .idle, .extracting, .installing:
            EmptyView()
        }
    }
}

/// Thin progress track in brand colours. Nil progress draws a short static segment.
struct UpdateProgressBar: View {
    let progress: Double?
    @Environment(\.brand) private var c

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(c.s3)
                Capsule()
                    .fill(LinearGradient(colors: [BrandPalette.auroraPurple, BrandPalette.auroraGreen], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, proxy.size.width * (progress ?? 0.3)))
                    .opacity(progress == nil ? 0.6 : 1)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) %" } ?? "")
    }
}

func updateFlowSymbol(_ flow: UpdateFlow) -> (symbol: String, tint: TileTint) {
    switch flow {
    case .failed: ("exclamationmark.triangle", .neutral)
    case .upToDate: ("checkmark.circle", .green)
    case .ready, .installing: ("arrow.clockwise.circle", .green)
    default: ("arrow.down.circle", .purple)
    }
}

/// Settings > Updates: the current step, its notes and its buttons. Hidden when idle.
struct UpdateFlowCard: View {
    let flow: UpdateFlow
    let currentVersion: String
    let actions: UpdateFlowActions
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    private func notesText(_ notes: String) -> some View {
        Text(notes)
            .font(BrandFont.body(13))
            .foregroundStyle(c.on)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        UpdatesCard {
            HStack(alignment: .top, spacing: 12) {
                let visual = updateFlowSymbol(flow)
                IconTile(symbol: visual.symbol, tint: visual.tint, size: 32, corner: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(UpdateFlowText.title(flow))
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(c.on)
                    if let detail = UpdateFlowText.detail(flow, currentVersion: currentVersion) {
                        Text(detail)
                            .font(BrandFont.body(12))
                            .foregroundStyle(c.on2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if flow.isBusy {
                UpdateProgressBar(progress: flow.progress)
                    .padding(.top, 12)
            }
            if case let .available(offer) = flow, let notes = offer.notes {
                Group {
                    if snapshot {
                        notesText(notes)  // ImageRenderer does not draw ScrollView content
                    } else {
                        ScrollView { notesText(notes).textSelection(.enabled) }
                            .frame(maxHeight: 160)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s3.opacity(0.5)))
                .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                UpdateFlowButtons(flow: flow, actions: actions, height: 32)
            }
            .padding(.top, 12)
        }
    }
}
