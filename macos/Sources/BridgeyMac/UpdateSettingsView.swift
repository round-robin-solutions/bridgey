import SwiftUI

/// Settings > Updates (Round Robin edition): one status card that shows one state at a time,
/// then the channel and automatic checks as compact rows. The sidebar footer carries the version.
struct UpdatesPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        UpdateStatusCard(model: model, actions: actions)
        UpdateAllDevicesCard(display: model.updateAll, actions: actions.updateAll)
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(L10n.text("updates.channel", fallback: "Release channel"))
                        .font(BrandFont.body(13, .medium))
                        .foregroundStyle(c.on)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChannelPicker(selected: model.channel, onSelect: actions.setChannel)
                        .frame(width: 282)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.channel.detail)
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on)
                    Text(L10n.text("updates.channel.note", fallback: "Switching to a steadier channel waits for its next release; nothing is downgraded."))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
            SettingsToggle(
                title: L10n.text("updates.automatic", fallback: "Check automatically"),
                isOn: model.automaticallyChecks,
                set: actions.setAutomaticallyChecks
            )
            .disabled(!model.updatesAvailable)
            SettingsToggle(
                title: L10n.text("updates.remoteStart", fallback: "Let paired devices start updates on this Mac"),
                subtitle: L10n.text("updates.remoteStart.detail", fallback: "Only starts Bridgey\u{2019}s own signed update from this Mac\u{2019}s channel."),
                isOn: model.remoteStartUpdates && model.updatesAvailable,
                set: actions.setRemoteStartUpdates
            )
            .disabled(!model.updatesAvailable)
        }
    }
}

/// The one card at the top of Settings > Updates.
private struct UpdateStatusCard: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    private var flow: UpdateFlow { model.updateFlow }
    private var update: UpdateFlowActions { actions.update }

    var body: some View {
        UpdatesCard {
            HStack(alignment: .center, spacing: 12) {
                let visual = statusSymbol
                IconTile(symbol: visual.symbol, tint: visual.tint, size: 36, corner: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(UpdateFlowText.settingsTitle(flow, currentVersion: model.shortVersion))
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(c.on)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(BrandFont.body(12))
                            .foregroundStyle(failed ? c.tpi : c.on2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailingButton
            }
            if flow.isBusy {
                UpdateProgressBar(progress: flow.progress)
                    .padding(.top, 12)
                    .padding(.leading, 48)
            }
            if case let .available(offer) = flow, let notes = offer.notes {
                let blocks = ReleaseNotes.blocks(notes, version: offer.version)
                if !blocks.isEmpty {
                    ReleaseNotesList(blocks: blocks)
                        .id(offer.version)
                        .padding(.top, 12)
                        .padding(.leading, 48)
                }
            }
            if hasFooter {
                HStack(spacing: 8) {
                    if case let .available(offer) = flow {
                        Button {
                            actions.openURL(offer.notesURL ?? SettingsLinks.releases)
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.text("updates.fullNotes", fallback: "Full release notes"))
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                            }
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(c.pri)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 48)
                    }
                    Spacer(minLength: 0)
                    footerButtons
                }
                .padding(.top, 14)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private var failed: Bool {
        if case .failed = flow { return true }
        return false
    }

    private var detail: String? {
        switch flow {
        case .idle, .upToDate:
            UpdateFlowText.idleDetail(
                updatesAvailable: model.updatesAvailable,
                lastCheck: model.lastCheck,
                deferral: model.updateDeferral,
                currentVersion: model.shortVersion,
                now: model.now
            )
        default:
            UpdateFlowText.settingsDetail(flow, currentVersion: model.shortVersion)
        }
    }

    private var statusSymbol: (symbol: String, tint: TileTint) {
        switch flow {
        case .idle, .upToDate:
            if !model.updatesAvailable { return ("arrow.triangle.2.circlepath", .neutral) }
            if model.updateDeferral != nil { return ("arrow.down.circle", .purple) }
            return model.lastCheck == nil ? ("arrow.triangle.2.circlepath", .neutral) : ("checkmark.circle", .green)
        case .checking: return ("arrow.triangle.2.circlepath", .neutral)
        default: return updateFlowSymbol(flow)
        }
    }

    private var hasFooter: Bool {
        switch flow {
        case .available, .ready, .failed: true
        default: false
        }
    }

    /// Single-action states keep their button beside the title.
    @ViewBuilder private var trailingButton: some View {
        switch flow {
        case .idle, .upToDate:
            if let deferral = model.updateDeferral, deferral.kind == .later {
                Button(L10n.text("updates.showUpdate", fallback: "Show update"), action: actions.checkForUpdates)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 32))
                    .disabled(!model.canCheckForUpdates)
            } else {
                Button(action: actions.checkForUpdates) {
                    Label(L10n.text("updates.checkNow", fallback: "Check now"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                .disabled(!model.updatesAvailable || !model.canCheckForUpdates)
            }
        case .checking, .downloading:
            Button(L10n.text("action.cancel", fallback: "Cancel"), action: update.cancel)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 32))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var footerButtons: some View {
        switch flow {
        case let .available(offer):
            if !offer.downloaded {
                PopUpMenuButton(items: {
                    [PopUpMenuItem(title: L10n.text("update.skip", fallback: "Skip this version"), action: update.skip)]
                }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(c.on2)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(c.s3))
                        .contentShape(Circle())
                }
                .help(L10n.text("action.more", fallback: "More"))
                .accessibilityLabel(L10n.text("action.more", fallback: "More"))
            }
            Button(L10n.text("update.later", fallback: "Later"), action: update.later)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 32))
            Button(UpdateFlowText.primaryAction(flow) ?? "", action: update.install)
                .buttonStyle(PillButtonStyle(kind: .gradient, height: 32))
        case .ready:
            Button(L10n.text("update.later", fallback: "Later"), action: update.later)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 32))
            Button(L10n.text("update.restart", fallback: "Restart to update"), action: update.install)
                .buttonStyle(PillButtonStyle(kind: .gradient, height: 32))
        case .failed:
            Button(L10n.text("action.dismiss", fallback: "Dismiss"), action: update.dismiss)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 32))
            Button(L10n.text("action.retry", fallback: "Retry"), action: update.checkAgain)
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 32))
        default:
            EmptyView()
        }
    }
}

/// Release notes as a list: about four lines, then Show all. Never scrolls on its own, so
/// nothing is clipped.
private struct ReleaseNotesList: View {
    let blocks: [ReleaseNoteBlock]
    @State private var expanded = false
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        let preview = ReleaseNotes.preview(blocks)
        let shown = expanded ? blocks : preview
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, block in
                row(block)
            }
            if preview.count < blocks.count {
                Button {
                    withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { expanded.toggle() }
                } label: {
                    Text(expanded
                         ? L10n.text("updates.showLess", fallback: "Show less")
                         : String(format: L10n.text("updates.showAll", fallback: "Show all (%d)"), blocks.count))
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(c.pri)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ block: ReleaseNoteBlock) -> some View {
        switch block {
        case let .heading(text):
            Text(inline(text))
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(c.on2).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                Text(inline(text))
                    .font(BrandFont.body(13))
                    .foregroundStyle(c.on)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .paragraph(text):
            Text(inline(text))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline Markdown (bold, code, links) as styled text; anything unparsable stays plain.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct UpdatesCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

// MARK: - In-app update flow (shared pieces)

struct UpdateFlowActions {
    var install: () -> Void = {}
    var later: () -> Void = {}
    var skip: () -> Void = {}
    var cancel: () -> Void = {}
    var dismiss: () -> Void = {}
    var checkAgain: () -> Void = {}
}

/// The Stream panel card's buttons. Skip lives in Settings, behind the ⋯ menu.
struct UpdateFlowButtons: View {
    let flow: UpdateFlow
    let actions: UpdateFlowActions
    var height: CGFloat = 28

    var body: some View {
        switch flow {
        case .available, .ready:
            Button(L10n.text("update.later", fallback: "Later"), action: actions.later)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
            Button(UpdateFlowText.primaryAction(flow) ?? "", action: actions.install)
                .buttonStyle(PillButtonStyle(kind: .gradient, height: height))
        case .checking, .downloading:
            Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
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
