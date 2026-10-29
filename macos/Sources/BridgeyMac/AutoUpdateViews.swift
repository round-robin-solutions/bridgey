import AppKit
import Combine
import SwiftUI

/*
 * Update all devices automatically, on screen: the words (Settings, the notice, the activity stream),
 * the switch and its status lines in Settings > Updates, and the short notice that appears when an
 * automatic run starts (non-activating, top right, with Later and a 60 second countdown before this
 * Mac restarts). Direction B "Stream".
 */

enum AutoUpdateText {
    static var title: String { L10n.text("autoUpdate.title", fallback: "Update all devices automatically") }

    static var subtitle: String {
        L10n.text("autoUpdate.subtitle", fallback: "New versions install on your connected phones first, then on this Mac. Waits while you\u{2019}re on a call or sending files.")
    }

    /// "call in progress", for "Waiting: call in progress".
    static func busy(_ busy: UpdateBusy) -> String {
        switch busy {
        case .call: L10n.text("autoUpdate.busy.call", fallback: "call in progress")
        case .screenShare: L10n.text("autoUpdate.busy.screen", fallback: "screen sharing")
        case .remoteControl: L10n.text("autoUpdate.busy.remote", fallback: "remote control in use")
        case .transfer: L10n.text("autoUpdate.busy.transfer", fallback: "files transferring")
        case .phoneFiles: L10n.text("autoUpdate.busy.phoneFiles", fallback: "Phone files download")
        case .setup: L10n.text("autoUpdate.busy.setup", fallback: "setup or pairing")
        case .other: L10n.text("autoUpdate.busy.other", fallback: "busy")
        }
    }

    /// "Waiting: call in progress", or "Waiting: call in progress on OnePlus 11".
    static func waiting(_ kind: UpdateBusy, device: String?) -> String {
        guard let device, !device.isEmpty else {
            return String(format: L10n.text("autoUpdate.waiting", fallback: "Waiting: %@"), busy(kind))
        }
        return String(format: L10n.text("autoUpdate.waitingOn", fallback: "Waiting: %1$@ on %2$@"), busy(kind), device)
    }

    /// Why a device was left out, as the activity stream says it after "Skipped OnePlus 11:".
    static func skipped(_ reason: UpdateSkipReason) -> String {
        switch reason {
        case .offline: L10n.text("autoUpdate.skip.offline", fallback: "not connected")
        case .byHand: L10n.text("autoUpdate.skip.byHand", fallback: "update it by hand")
        case .noStatus: L10n.text("autoUpdate.skip.noStatus", fallback: "hasn\u{2019}t sent its version yet")
        case .notApplied: L10n.text("autoUpdate.skip.notApplied", fallback: "last update didn\u{2019}t apply")
        case .remoteOff: L10n.text("autoUpdate.skip.remoteOff", fallback: "updates from other devices are off")
        }
    }

    static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    // MARK: Activity stream

    static func activityTitle(_ item: ActivityItem) -> String {
        let device = item.deviceName.isEmpty ? nil : item.deviceName
        switch item.kind {
        case .updateAutoDone:
            return String(format: L10n.text("autoUpdate.activity.done", fallback: "Updated automatically to %@"), item.content ?? "")
        case .updateAutoWaiting:
            return waiting(UpdateBusy(rawValue: item.content ?? "") ?? .other, device: device)
        case .updateAutoSkipped:
            let reason = (item.content.flatMap(UpdateSkipReason.init(wireKey:))).map(skipped) ?? skipped(.byHand)
            return String(format: L10n.text("autoUpdate.activity.skipped", fallback: "Skipped %1$@: %2$@"), device ?? UpdateAllText.thisMac, reason)
        case .updateAutoStartedBy:
            return String(format: L10n.text("autoUpdate.activity.startedBy", fallback: "Update started automatically by %@"), device ?? "")
        case .updateAutoFailed:
            if item.content == "not_applied" {
                return String(format: L10n.text("autoUpdate.activity.notApplied", fallback: "Automatic update didn\u{2019}t apply on %@"),
                              device ?? UpdateAllText.thisMac)
            }
            let reason = (item.content.flatMap(UpdateRunFailure.init(wireKey:))).map(UpdateAllText.failure) ?? UpdateAllText.failure(.other)
            return String(format: L10n.text("autoUpdate.activity.failed", fallback: "Automatic update didn\u{2019}t finish on %1$@: %2$@"),
                          device ?? UpdateAllText.thisMac, reason)
        default:
            return ""
        }
    }

    static var activityDetail: String { L10n.text("autoUpdate.activity.detail", fallback: "Update all devices automatically") }

    // MARK: Settings

    /// The lines under the switch: what it does now, then the last automatic run.
    static func statusLines(_ display: AutoUpdateDisplay) -> [String] {
        guard display.available else { return [] }
        guard display.enabled else {
            return display.checksOff && display.choice == true
                ? [L10n.text("autoUpdate.needsChecks", fallback: "Turn on Check automatically to use it.")]
                : []
        }
        var lines: [String] = []
        switch display.decision {
        case let .wait(kind, device, _):
            lines.append(waiting(kind, device: device))
        case let .later(until):
            lines.append(String(format: L10n.text("autoUpdate.later", fallback: "Put off until %@"), clock(until, now: display.now)))
        case .waitForIdle:
            lines.append(L10n.text("autoUpdate.waitForIdle", fallback: "Put off 3 times: waits until this Mac is idle or locked"))
        case let .yield(name, _):
            lines.append(String(format: L10n.text("autoUpdate.yield", fallback: "%@ starts these updates"), name))
        case .running:
            lines.append(L10n.text("autoUpdate.running", fallback: "Updating now"))
        case let .retry(until):
            lines.append(String(format: L10n.text("autoUpdate.retry", fallback: "Tries again at %@"), clock(until, now: display.now)))
        case .notApplied:
            lines.append(L10n.text("autoUpdate.notApplied", fallback: "The last update didn\u{2019}t apply here, so it isn\u{2019}t tried again on its own."))
        case .off, .nothingToDo, .start:
            lines.append(display.channel == .stable
                ? L10n.text("autoUpdate.checks.stable", fallback: "Checks every 6 hours")
                : L10n.text("autoUpdate.checks.fast", fallback: "Checks every 30 minutes"))
        }
        if let last = display.lastRun { lines.append(lastRun(last, now: display.now)) }
        return lines
    }

    /// "Last automatic update: 14:02, 3 of 3 updated to 0.10.0-rr.1-beta.11".
    static func lastRun(_ run: AutoRunRecord, now: Date) -> String {
        let when = clock(run.at, now: now)
        let result: String
        if !run.finished {
            result = L10n.text("autoUpdate.last.running", fallback: "in progress")
        } else if run.later {
            result = L10n.text("autoUpdate.last.later", fallback: "this Mac put off with Later")
        } else if run.failed > 0 {
            result = String(format: L10n.text("autoUpdate.last.failed", fallback: "%1$d of %2$d updated, %3$d didn\u{2019}t finish"), run.updated, run.total, run.failed)
        } else if let version = run.version {
            result = String(format: L10n.text("autoUpdate.last.done", fallback: "%1$d of %2$d updated to %3$@"), run.updated, run.total, version)
        } else {
            result = String(format: L10n.text("autoUpdate.last.count", fallback: "%1$d of %2$d updated"), run.updated, run.total)
        }
        return String(format: L10n.text("autoUpdate.last", fallback: "Last automatic update: %1$@, %2$@"), when, result)
    }

    // MARK: The notice

    static func noticeTitle(_ run: UpdateRun, currentVersion: String) -> String {
        let target = run.items.compactMap(\.targetApp).max { $0.compare($1, options: .numeric) == .orderedAscending }
        guard let target else { return L10n.text("autoUpdate.notice.title", fallback: "Updating your devices") }
        return String(format: L10n.text("autoUpdate.notice.titleTo", fallback: "Updating your devices to %@"),
                      UpdateFlowText.shortVersion(target, comparedTo: currentVersion))
    }

    /// "OnePlus 11 updates first. This Mac restarts last." or "2 phones update first. ..."
    static func noticeOrder(_ run: UpdateRun) -> String {
        let phones = run.phones
        let first: String? = switch phones.count {
        case 0: nil
        case 1: String(format: L10n.text("autoUpdate.notice.oneFirst", fallback: "%@ updates first."), phones[0].name)
        default: String.localizedStringWithFormat(L10n.text("autoUpdate.notice.manyFirst", fallback: "%d phones update first."), phones.count)
        }
        let last: String? = run.local == nil ? nil : L10n.text("autoUpdate.notice.macLast", fallback: "This Mac restarts last.")
        return [first, last].compactMap { $0 }.joined(separator: " ")
    }

    static func countdown(_ until: Date, now: Date) -> String {
        let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        return String(format: L10n.text("autoUpdate.notice.countdown", fallback: "This Mac restarts in %d s"), seconds)
    }

    static func startedBy(_ name: String) -> String {
        String(format: L10n.text("autoUpdate.notice.startedBy", fallback: "Started automatically by %@"), name)
    }
}

/// What Settings > Updates draws for the automatic setting. Plain data, so screenshots render it.
struct AutoUpdateDisplay: Equatable {
    /// The effective setting.
    var enabled = false
    /// The person's own choice, nil when the channel's default applies.
    var choice: Bool?
    /// The installed app can update itself.
    var available = false
    /// Sparkle's automatic checks are off (the setting needs them).
    var checksOff = false
    var channel: UpdateChannel = .stable
    var decision: AutoDecision = .nothingToDo
    var lastRun: AutoRunRecord?
    var now = Date()
}

/// The switch and its status lines, inside the Updates settings card.
struct AutoUpdateSettingsRows: View {
    let display: AutoUpdateDisplay
    let set: (Bool) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        SettingsToggle(title: AutoUpdateText.title, subtitle: AutoUpdateText.subtitle, isOn: display.enabled, set: set)
            .disabled(!display.available)
        let lines = AutoUpdateText.statusLines(display)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol(index))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint(index))
                            .frame(width: 12)
                        Text(line)
                            .font(BrandFont.body(12).monospacedDigit())
                            .foregroundStyle(c.on2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
        }
    }

    private func symbol(_ index: Int) -> String {
        if index > 0 { return "clock.arrow.circlepath" }
        switch display.decision {
        case .wait, .later, .waitForIdle, .yield, .retry: return "hourglass"
        case .running: return "arrow.down.circle"
        case .notApplied: return "exclamationmark.circle"
        default: return "checkmark.circle"
        }
    }

    private func tint(_ index: Int) -> Color {
        if index > 0 { return c.on2 }
        switch display.decision {
        case .wait, .later, .waitForIdle, .yield, .retry, .notApplied: return c.on2
        default: return c.good
        }
    }
}

// MARK: - The notice

/// What the notice shows now.
enum AutoNoticeState: Equatable {
    case hidden
    /// An automatic run started: who goes first; Later puts off this Mac's restart.
    case starting(title: String, detail: String, canLater: Bool)
    /// This Mac restarts at `until`.
    case countdown(title: String, until: Date)
    /// Another device started this Mac's update.
    case startedBy(String)

    /// The notice for a run at `now`: shown for the first seconds of the run and during this Mac's
    /// countdown; never while someone is busy (the run holds), after Later, or once installing.
    static func make(run: UpdateRun?, now: Date, currentVersion: String, closedRunID: String?) -> AutoNoticeState {
        guard let run, run.isAuto, !run.dismissed, run.hold == nil else { return .hidden }
        let title = AutoUpdateText.noticeTitle(run, currentVersion: currentVersion)
        if let until = run.countdownUntil { return .countdown(title: title, until: until) }
        guard run.id != closedRunID, now.timeIntervalSince(run.startedAt) < AutoUpdateRules.noticeSeconds, !run.finished else { return .hidden }
        // Later works once this Mac's update is downloaded (it then waits for Install or quitting).
        return .starting(title: title, detail: AutoUpdateText.noticeOrder(run), canLater: run.local?.step == .ready)
    }
}

@MainActor
final class AutoNoticeContent: ObservableObject {
    @Published var state: AutoNoticeState = .hidden
    @Published var now = Date()
}

/// The short notice in the top-right corner: non-activating (typing elsewhere goes on), on every
/// Space, below the call card's level so a call always shows above it.
@MainActor
final class AutoUpdateNoticeController {
    let content = AutoNoticeContent()
    private var panel: NSPanel?
    private weak var updateAll: UpdateAllCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var closedRunID: String?
    private var startedBy: (name: String, until: Date)?
    private var timer: Timer?

    func attach(updateAll: UpdateAllCoordinator, auto: AutoUpdateCoordinator) {
        self.updateAll = updateAll
        updateAll.$run.combineLatest(updateAll.$now)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func showStartedBy(_ name: String) {
        startedBy = (name, Date().addingTimeInterval(AutoUpdateRules.startedBySeconds))
        refresh()
        // Nothing else ticks on this Mac while it only follows another device's run.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: AutoUpdateRules.startedBySeconds + 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let now = Date()
        var state = AutoNoticeState.make(run: updateAll?.run, now: now, currentVersion: updateAll?.localStatus?.app ?? "", closedRunID: closedRunID)
        if state == .hidden, let startedBy, now < startedBy.until { state = .startedBy(startedBy.name) }
        content.now = now
        if content.state != state { content.state = state }
        state == .hidden ? hide() : show()
    }

    private func close() {
        closedRunID = updateAll?.run?.id
        startedBy = nil
        refresh()
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        guard !panel.isVisible else { return }
        panel.setContentSize(panel.contentViewController?.view.fittingSize ?? NSSize(width: 360, height: 120))
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        BridgeyWindows.fadeIn(panel)
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        BridgeyWindows.fadeOut(panel)
    }

    private func makePanel() -> NSPanel {
        let root = AutoUpdateNoticeView(
            content: content,
            later: { [weak self] in self?.updateAll?.actions.later() },
            restartNow: { [weak self] in self?.updateAll?.actions.restartNow() },
            close: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: BrandRoot(reduceMotion: false) { root })
        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func position(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width - 18, y: visible.maxY - window.frame.height - 18))
    }
}

struct AutoUpdateNoticeView: View {
    @ObservedObject var content: AutoNoticeContent
    let later: () -> Void
    let restartNow: () -> Void
    let close: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "arrow.down.circle", tint: .purple, size: 32, corner: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(c.on)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(BrandFont.body(12).monospacedDigit())
                            .foregroundStyle(c.on2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(c.on2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(c.s3))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("action.close", fallback: "Close"))
                .accessibilityLabel(L10n.text("action.close", fallback: "Close"))
            }
            if hasButtons {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L10n.text("update.later", fallback: "Later"), action: later)
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                    if case .countdown = content.state {
                        Button(L10n.text("updateAll.restartNow", fallback: "Restart now"), action: restartNow)
                            .buttonStyle(PillButtonStyle(kind: .gradient, height: 28))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch content.state {
        case let .starting(title, _, _), let .countdown(title, _): title
        case .startedBy: L10n.text("autoUpdate.notice.updating", fallback: "Updating Bridgey")
        case .hidden: ""
        }
    }

    private var detail: String? {
        switch content.state {
        case let .starting(_, detail, _): detail.isEmpty ? nil : detail
        case let .countdown(_, until): AutoUpdateText.countdown(until, now: content.now)
        case let .startedBy(name): AutoUpdateText.startedBy(name)
        case .hidden: nil
        }
    }

    private var hasButtons: Bool {
        switch content.state {
        case let .starting(_, _, canLater): canLater
        case .countdown: true
        default: false
        }
    }
}
