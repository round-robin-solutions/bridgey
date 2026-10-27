import SwiftUI

/*
 * Update all in the menu-bar panel and in Settings > Updates (direction B "Stream"). One card: what it
 * will update (hover the button for the list), a preview before it runs (each device from > to with its
 * channel, then what is skipped and why), and while it runs one line for the whole run plus a row per
 * device, with Retry for a phone that failed and Later during this Mac's countdown.
 */

/// The panel's live card.
struct UpdateAllPanelCard: View {
    let display: UpdateAllDisplay
    let actions: UpdateAllActions
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let run = display.activeRun {
                UpdateAllRunHeader(run: run, now: display.now, compact: true)
                UpdateAllRunRows(run: run, now: display.now, retry: actions.retry, compact: true)
                    .padding(.leading, 38)
                UpdateAllRunButtons(run: run, now: display.now, actions: actions, height: 28)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    IconTile(symbol: "arrow.down.circle", tint: .purple, size: 28, corner: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UpdateAllText.title(display.plan))
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(c.on)
                            .lineLimit(1)
                        Text(UpdateAllText.summary(display.plan))
                            .font(BrandFont.body(12))
                            .foregroundStyle(c.on2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if display.previewOpen {
                    UpdateAllPreview(plan: display.plan, compact: true)
                        .padding(.leading, 38)
                }
                UpdateAllStartButtons(display: display, actions: actions, height: 28)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.tb, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Settings > Updates: every device, its version and channel, and Update all.
struct UpdateAllDevicesCard: View {
    let display: UpdateAllDisplay
    let actions: UpdateAllActions
    @Environment(\.brand) private var c

    var body: some View {
        UpdatesCard {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("updateAll.devices", fallback: "Your devices"))
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(c.on)
                    Text(L10n.text("updateAll.devices.detail", fallback: "This Mac and the phones connected to it. Macs are not connected to each other."))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let run = display.activeRun {
                UpdateAllRunHeader(run: run, now: display.now, compact: false)
                    .padding(.top, 14)
                UpdateAllRunRows(run: run, now: display.now, retry: actions.retry, compact: false)
                    .padding(.top, 10)
                UpdateAllRunButtons(run: run, now: display.now, actions: actions, height: 32)
                    .padding(.top, 12)
            } else if display.previewOpen {
                UpdateAllPreview(plan: display.plan, compact: false)
                    .padding(.top, 14)
                UpdateAllStartButtons(display: display, actions: actions, height: 32)
                    .padding(.top, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(display.plan.entries) { entry in
                        UpdateAllDeviceRow(name: entry.isLocal ? UpdateAllText.thisMac : entry.name, isLocal: entry.isLocal,
                                           version: entry.app, channel: entry.channel, detail: overviewDetail(entry),
                                           detailTone: overviewTone(entry), compact: false)
                    }
                }
                .padding(.top, 10)
                if display.offersUpdateAll {
                    UpdateAllStartButtons(display: display, actions: actions, height: 32)
                        .padding(.top, 12)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private func overviewDetail(_ entry: UpdatePlanEntry) -> String {
        switch entry.kind {
        case let .update(to, _):
            guard let to else { return UpdateAllText.change(entry) }
            return String(format: L10n.text("updateAll.available", fallback: "%@ available"), UpdateFlowText.shortVersion(to, comparedTo: entry.app ?? ""))
        case .upToDate: return L10n.text("updateAll.upToDate", fallback: "Up to date")
        case let .skipped(reason): return UpdateAllText.skipReason(reason)
        }
    }

    private func overviewTone(_ entry: UpdatePlanEntry) -> UpdateAllDeviceRow.Tone {
        switch entry.kind {
        case let .update(to, _): to == nil ? .muted : .accent
        case .upToDate: .good
        case .skipped: .muted
        }
    }
}

// MARK: - Pieces

/// One device: a glyph, the name, the version and channel, and what happens to it.
struct UpdateAllDeviceRow: View {
    enum Tone { case normal, muted, accent, good, warning }

    let name: String
    let isLocal: Bool
    let version: String?
    let channel: UpdateChannel?
    let detail: String
    var detailTone: Tone = .normal
    var progress: Double?? = nil
    let compact: Bool
    var subtitle: String? = nil
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isLocal ? "laptopcomputer" : "candybarphone")
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
                    .foregroundStyle(c.on2)
                    .frame(width: compact ? 16 : 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(BrandFont.body(compact ? 12 : 13, .semibold))
                            .foregroundStyle(c.on)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let channel, !compact {
                            ChannelChip(channel: channel)
                        }
                    }
                    if !compact, let version {
                        Text(version)
                            .font(BrandFont.body(11).monospacedDigit())
                            .foregroundStyle(c.on2)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(BrandFont.body(compact ? 11 : 12, detailTone == .accent ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(color)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let subtitle {
                Text(subtitle)
                    .font(BrandFont.body(11))
                    .foregroundStyle(c.on2)
                    .padding(.leading, compact ? 24 : 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress {
                UpdateProgressBar(progress: progress)
                    .padding(.leading, compact ? 24 : 28)
            }
        }
        .padding(.vertical, compact ? 3 : 7)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch detailTone {
        case .normal: c.on
        case .muted: c.on2
        case .accent: c.tpi
        case .good: c.good
        case .warning: c.warn
        }
    }
}

private struct ChannelChip: View {
    let channel: UpdateChannel
    @Environment(\.brand) private var c

    var body: some View {
        Text(channel.title)
            .font(BrandFont.body(10, .semibold))
            .foregroundStyle(channel == .stable ? c.on2 : c.tpi)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(channel == .stable ? c.s3 : c.tp))
    }
}

/// Before it runs: each device from > to (this Mac last, "restarts last"), then what is skipped and why.
struct UpdateAllPreview: View {
    let plan: UpdatePlan
    let compact: Bool
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(UpdateAllText.summary(plan))
                .font(BrandFont.body(compact ? 11 : 12, .semibold))
                .foregroundStyle(c.on2)
            VStack(spacing: 0) {
                ForEach(plan.targets) { entry in
                    UpdateAllDeviceRow(name: entry.isLocal ? UpdateAllText.thisMac : entry.name, isLocal: entry.isLocal,
                                       version: entry.app, channel: entry.channel, detail: UpdateAllText.change(entry),
                                       detailTone: entry.knownTarget == nil ? .muted : .accent, compact: compact,
                                       subtitle: subtitle(entry))
                }
            }
            if !plan.skipped.isEmpty {
                Text(L10n.text("updateAll.skipped", fallback: "Skipped"))
                    .font(BrandFont.body(compact ? 11 : 12, .semibold))
                    .foregroundStyle(c.on2)
                    .padding(.top, 2)
                VStack(spacing: 0) {
                    ForEach(plan.skipped) { entry in
                        if case let .skipped(reason) = entry.kind {
                            UpdateAllDeviceRow(name: entry.isLocal ? UpdateAllText.thisMac : entry.name, isLocal: entry.isLocal,
                                               version: entry.app, channel: nil, detail: UpdateAllText.skipReason(reason),
                                               detailTone: .muted, compact: compact)
                        }
                    }
                }
            }
            if let note = UpdateAllText.channelNote(plan) {
                Text(note)
                    .font(BrandFont.body(11))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subtitle(_ entry: UpdatePlanEntry) -> String? {
        if entry.isLocal { return L10n.text("updateAll.restartsLast.detail", fallback: "Restarts last, after a 10 second countdown") }
        return compact ? nil : L10n.text("updateAll.phone.detail", fallback: "Installs and restarts on its own")
    }
}

/// Update all (with the hover list), or Cancel and Update all while the preview is open.
struct UpdateAllStartButtons: View {
    let display: UpdateAllDisplay
    let actions: UpdateAllActions
    let height: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if display.previewOpen {
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.closePreview)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
                Button(L10n.text("updateAll.action", fallback: "Update all"), action: actions.start)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: height))
                    .help(UpdateAllText.help(display.plan))
                    .disabled(display.plan.targets.isEmpty)
            } else {
                Button(L10n.text("updateAll.action", fallback: "Update all"), action: actions.openPreview)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: height))
                    .help(UpdateAllText.help(display.plan))
                    .accessibilityHint(UpdateAllText.help(display.plan))
            }
        }
    }
}

/// The whole run in one line (T3 Code's capsule): countdown, "1 of 3 updated", a slow or waiting device.
struct UpdateAllRunHeader: View {
    let run: UpdateRun
    let now: Date
    let compact: Bool
    @Environment(\.brand) private var c

    var body: some View {
        let capsule = UpdateAllText.capsule(run, now: now)
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: symbol(capsule.tone), tint: tint(capsule.tone), size: compact ? 28 : 36, corner: compact ? 8 : 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(capsule.label)
                    .font(BrandFont.body(compact ? 13 : 15, .semibold).monospacedDigit())
                    .foregroundStyle(capsule.tone == .failed || capsule.tone == .slow ? c.warn : c.on)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(UpdateAllText.progressLine(run.updatedCount, run.items.count))
                    .font(BrandFont.body(compact ? 11 : 12).monospacedDigit())
                    .foregroundStyle(c.on2)
                    .opacity(showsCount(capsule) ? 1 : 0)
                    .accessibilityHidden(!showsCount(capsule))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The second line repeats the count only when the first line says something else.
    private func showsCount(_ capsule: UpdateAllText.Capsule) -> Bool {
        capsule.label != UpdateAllText.progressLine(run.updatedCount, run.items.count) && capsule.tone != .done
    }

    private func symbol(_ tone: UpdateAllText.CapsuleTone) -> String {
        switch tone {
        case .normal: "arrow.down.circle"
        case .slow: "hourglass"
        case .needsYou: "hand.tap"
        case .failed: "exclamationmark.triangle"
        case .done: "checkmark.circle"
        }
    }

    private func tint(_ tone: UpdateAllText.CapsuleTone) -> TileTint {
        switch tone {
        case .normal, .needsYou: .purple
        case .slow, .failed: .neutral
        case .done: .green
        }
    }
}

/// A row per device while the run lasts, phones first and this Mac last.
struct UpdateAllRunRows: View {
    let run: UpdateRun
    let now: Date
    let retry: (String) -> Void
    let compact: Bool
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 0) {
            ForEach(run.items) { item in
                HStack(alignment: .center, spacing: 8) {
                    UpdateAllDeviceRow(name: item.isLocal ? UpdateAllText.thisMac : item.name, isLocal: item.isLocal,
                                       version: version(item), channel: item.channel, detail: detail(item),
                                       detailTone: tone(item), progress: progress(item), compact: compact,
                                       subtitle: UpdateAllText.needsUserDetail(item))
                    if item.canRetry {
                        Button(L10n.text("action.retry", fallback: "Retry")) { retry(item.id) }
                            .buttonStyle(PillButtonStyle(kind: .tonal, height: compact ? 24 : 28))
                    }
                }
            }
        }
    }

    private func version(_ item: UpdateRunItem) -> String {
        guard let target = item.targetApp else { return item.fromApp }
        return "\(item.fromApp) > \(UpdateFlowText.shortVersion(target, comparedTo: item.fromApp))"
    }

    private func detail(_ item: UpdateRunItem) -> String {
        var text = UpdateAllText.step(item, countdownUntil: item.isLocal ? run.countdownUntil : nil, now: now)
        if let slow = run.slowItem(now: now), slow.id == item.id {
            text += " \u{00B7} " + UpdateAllText.elapsed(now.timeIntervalSince(item.startedAt))
        }
        return text
    }

    private func tone(_ item: UpdateRunItem) -> UpdateAllDeviceRow.Tone {
        switch item.step {
        case .done, .upToDate: .good
        case .failed, .notApplied: .warning
        case .needsUser: .accent
        case .waiting, .later: .muted
        default: run.slowItem(now: now)?.id == item.id ? .warning : .normal
        }
    }

    private func progress(_ item: UpdateRunItem) -> Double?? {
        switch item.step {
        case let .downloading(percent): .some(percent.map { Double($0) / 100 })
        case .checking, .installing, .restarting, .starting: .some(nil)
        default: nil
        }
    }
}

/// The run's buttons: Later during the countdown, Restart now after Later, Retry, Done.
struct UpdateAllRunButtons: View {
    let run: UpdateRun
    let now: Date
    let actions: UpdateAllActions
    let height: CGFloat

    var body: some View {
        let capsule = UpdateAllText.capsule(run, now: now)
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            switch capsule.action {
            case .later:
                Button(L10n.text("update.later", fallback: "Later"), action: actions.later)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
                Button(L10n.text("updateAll.restartNow", fallback: "Restart now"), action: actions.restartNow)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: height))
            case .restartNow:
                Button(L10n.text("action.done", fallback: "Done"), action: actions.dismiss)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
                Button(L10n.text("updateAll.restartNow", fallback: "Restart now"), action: actions.restartNow)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: height))
            case .retry:
                // The failed phone's row has its own Retry.
                Button(L10n.text("action.done", fallback: "Done"), action: actions.dismiss)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
            case .retryAll:
                Button(L10n.text("action.done", fallback: "Done"), action: actions.dismiss)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
                Button(L10n.text("updateAll.retryAll", fallback: "Retry all"), action: actions.retryAll)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: height))
            case .dismiss:
                Button(L10n.text("action.done", fallback: "Done"), action: actions.dismiss)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: height))
            case nil:
                EmptyView()
            }
        }
    }
}
