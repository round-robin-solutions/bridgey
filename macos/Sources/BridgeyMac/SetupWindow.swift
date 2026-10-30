import AppKit
import SwiftUI

/*
 * The setup window: Welcome, the quick path (Local Network, Notifications, Pair a phone, Done:
 * the Essentials) and the short question path (Intro with bundles and Type what you want, a
 * follow-up only for what was picked, one page of feature switches, one permissions page, the
 * summary). The view draws from a `SetupFlow`, a `SettingsModel` and plain closures, so
 * screenshots render it from sample state. Escape does what Android's back does.
 */

struct SetupActions {
    /// An event, with the facts the questions read now (SetupCenter applies the answer, then moves on).
    var dispatch: (SetupEvent, SetupFacts) -> Void = { _, _ in }
    /// Quick path: the explainer (first time), then the macOS prompt or the System Settings page.
    var allow: (SetupPermission) -> Void = { _ in }
    /// A row on the permissions page: the macOS prompt or the System Settings page (the row explains it).
    var requestFromPage: (SetupPermission) -> Void = { _ in }
    /// Allow all: each permission in turn, coming back to the page after each.
    var allowAll: ([SetupPermission]) -> Void = { _ in }
    /// The pair step: Codes match and Don't match for the prompt with this token, Cancel or Close, Try again, and
    /// whether the step is on screen (it keeps pairing from the phone allowed while it is).
    var confirmPairing: (String) -> Void = { _ in }
    var rejectPairing: (String) -> Void = { _ in }
    var cancelPairing: () -> Void = {}
    var retryPairing: () -> Void = {}
    var holdPairingArmed: (Bool) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var start: () -> Void = {}
    /// Leave setup without finishing (Leave in "Leave setup?", or Escape on the first screen).
    var leave: () -> Void = {}

    /// Quick path and Welcome events, which read no facts.
    func send(_ event: SetupEvent) { dispatch(event, SetupFacts()) }
}

struct SetupWindowView: View {
    let flow: SetupFlow
    let model: SettingsModel
    let actions: SettingsActions
    let setup: SetupActions
    /// Permissions asked for during this setup (their step then offers Next or Continue).
    var requested: Set<SetupPermission> = []
    /// SendPreferences' image mode (Should photos be made smaller?).
    var sendImageMode = "original"
    /// Screenshots: text already typed on the Intro, bundles already picked, a More options page open.
    var typedText = ""
    var pickedBundles: Set<String> = []
    /// More options (or Change in Settings): the live Settings page, over the setup.
    @State private var morePane: SettingsPane?
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot

    static let size = CGSize(width: 760, height: 640)

    private var facts: SetupFacts { SetupFacts.make(model: model, sendImageMode: sendImageMode) }

    init(flow: SetupFlow, model: SettingsModel, actions: SettingsActions, setup: SetupActions, requested: Set<SetupPermission> = [],
         sendImageMode: String = "original", typedText: String = "", pickedBundles: Set<String> = [], openPane: SettingsPane? = nil) {
        self.flow = flow
        self.model = model
        self.actions = actions
        self.setup = setup
        self.requested = requested
        self.sendImageMode = sendImageMode
        self.typedText = typedText
        self.pickedBundles = pickedBundles
        _morePane = State(initialValue: openPane)
    }

    var body: some View {
        ZStack {
            SetupBackdrop()
            screen
                .id(screenKey)
                .transition(reduce ? .opacity : .asymmetric(insertion: .offset(x: 24).combined(with: .opacity), removal: .opacity))
            if let pane = morePane {
                SetupMorePanel(pane: pane, model: model, actions: actions) { close() }
                    .transition(reduce ? .opacity : .offset(y: 16).combined(with: .opacity))
                    .zIndex(1)
            }
            if flow.confirmLeave {
                SetupLeaveDialog(keepGoing: { send(.keepGoing) }, leave: setup.leave)
                    .transition(.opacity)
                    .zIndex(2)
            }
            // Escape: the same as Android's system back.
            Button("", action: escape)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(alignment: .topLeading) {
            // The window's own buttons, drawn only in screenshots.
            if snapshot {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                }
                .padding(.leading, 16)
                .padding(.top, 14)
            }
        }
        .animation(BrandMotion.animation(BrandMotion.page, reduce: reduce), value: flow.screen)
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: flow.confirmLeave)
        .animation(BrandMotion.animation(BrandMotion.page, reduce: reduce), value: morePane)
    }

    @ViewBuilder private var screen: some View {
        switch flow.screen {
        case .welcome: SetupWelcomeView(send: send)
        case let .quick(step):
            SetupQuickStepView(step: step, flow: flow, model: model, actions: actions, setup: setup, requested: requested)
        case .intro:
            SetupIntroView(flow: flow, facts: facts, typedText: typedText, picked: pickedBundles, send: send)
        case let .question(id):
            if let question = SetupQuestions.question(id) {
                SetupQuestionView(question: question, flow: flow, facts: facts, model: model, actions: actions, setup: setup,
                                  send: send, more: { morePane = $0 })
            }
        case .switches:
            SetupSwitchesView(flow: flow, facts: facts, send: send, more: { morePane = $0 })
        case .permissions:
            SetupPermissionsView(flow: flow, facts: facts, model: model, setup: setup, send: send)
        case .summary:
            SetupSummaryView(flow: flow, facts: facts, model: model, actions: actions, setup: setup, send: send, change: { morePane = $0 })
        case .done: SetupDoneView(flow: flow, setup: setup)
        }
    }

    private var screenKey: String {
        switch flow.screen {
        case .welcome: "welcome"
        case let .quick(step): "quick.\(step.rawValue)"
        case .intro: "intro"
        case let .question(id): "question.\(id)"
        case .switches: "switches"
        case .permissions: "permissions"
        case .summary: "summary"
        case .done: "done"
        }
    }

    private func send(_ event: SetupEvent) { setup.dispatch(event, facts) }

    private func close() { morePane = nil }

    private func escape() {
        if morePane != nil { return close() }
        if flow.confirmLeave { return send(.keepGoing) }
        switch SetupBack.decide(flow) {
        case .step: send(.back)
        case .askLeave: send(.askLeave)
        case .leave: setup.leave()
        }
    }
}

private struct SetupBackdrop: View {
    @Environment(\.brand) private var c

    var body: some View {
        ZStack {
            c.isDark ? Color(hex: 0x0A101D) : c.bg
            RadialGradient(colors: [BrandPalette.auroraPurple.opacity(c.isDark ? 0.22 : 0.12), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [BrandPalette.auroraBlue.opacity(c.isDark ? 0.14 : 0.10), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }
    }
}

// MARK: - Welcome

private struct SetupWelcomeView: View {
    let send: (SetupEvent) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AuroraMark(size: 64)
                .padding(.bottom, 20)
            Text(L10n.setup("setup.welcome.title", fallback: "Welcome to Bridgey"))
                .font(BrandFont.heading(30))
                .foregroundStyle(c.on)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            Text(L10n.setup("setup.welcome.body", fallback: "Your phone and your Mac, working together on your own network: clipboard, files, notifications, calls and more."))
                .font(BrandFont.body(14))
                .foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
                .padding(.bottom, 32)
            HStack(alignment: .top, spacing: 16) {
                SetupChoiceCard(
                    symbol: "bolt.fill", tint: .blue,
                    title: L10n.setup("setup.quick.title", fallback: "Get started quickly"),
                    badge: L10n.setup("setup.quick.badge", fallback: "Recommended"),
                    detail: L10n.setup("setup.quick.detail", fallback: "Turns on the Essentials: pair your phone, clipboard when you click Send, and your phone\u{2019}s notifications. Everything else stays off."),
                    highlighted: true
                ) { send(.chooseQuick) }
                SetupChoiceCard(
                    symbol: "slider.horizontal.3", tint: .purple,
                    title: L10n.setup("setup.advanced.title", fallback: "Advanced setup"),
                    badge: nil,
                    detail: L10n.setup("setup.advanced.detail", fallback: "Pick what you want, answer a few short questions, and switch on anything else."),
                    highlighted: false
                ) { send(.chooseAdvanced) }
            }
            Spacer(minLength: 0)
            Text(L10n.setup("setup.welcome.later", fallback: "You can run setup again from Settings > General."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 48)
    }
}

private struct SetupChoiceCard: View {
    let symbol: String
    let tint: TileTint
    let title: String
    let badge: String?
    let detail: String
    let highlighted: Bool
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    IconTile(symbol: symbol, tint: tint, size: 36, corner: 10)
                    Spacer(minLength: 8)
                    if let badge {
                        Text(badge)
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(c.tgi)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(c.tg))
                    }
                }
                Text(title)
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(c.on)
                Text(detail)
                    .font(BrandFont.body(13))
                    .foregroundStyle(c.on2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(L10n.setup("action.choose", fallback: "Choose"))
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                }
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.pri)
            }
            .padding(20)
            .frame(width: 300, height: 244, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(highlighted ? c.pri : c.ol, lineWidth: highlighted ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Shared chrome

/// Top line: the path's name and "2 of 3".
private struct SetupTopBar: View {
    let title: String
    let position: (index: Int, count: Int)?
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on2)
            Spacer()
            if let position {
                Text(String(format: L10n.setup("setup.position", fallback: "%1$d of %2$d"), position.index, position.count))
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on2)
                    .monospacedDigit()
            }
        }
        .frame(height: 20)
    }
}

/// Bottom line: Back on the left, the page's buttons on the right.
private struct SetupBottomBar<Trailing: View>: View {
    /// nil on the first screen of a run (Escape there leaves setup).
    let back: (() -> Void)?
    @ViewBuilder let trailing: Trailing
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            if let back {
                Button {
                    back()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text(L10n.setup("action.back", fallback: "Back"))
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .outline, height: 34))
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 32)
        .frame(height: 70)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }
}

// MARK: - Quick path

private struct SetupQuickStepView: View {
    let step: SetupQuickStep
    let flow: SetupFlow
    let model: SettingsModel
    let actions: SettingsActions
    let setup: SetupActions
    let requested: Set<SetupPermission>
    @Environment(\.brand) private var c

    private var status: PermissionStatus? {
        step.permission.flatMap { permission in model.setup.permissions.first { $0.permission == permission } }
    }

    private var paired: Bool { !model.trustedDevices.isEmpty }

    private var isDone: Bool {
        if step == .pairPhone { return paired }
        return status?.system == .allowed
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupTopBar(title: L10n.setup("setup.quick.title", fallback: "Get started quickly"), position: flow.position)
                .padding(.horizontal, 32)
                .padding(.top, 36)
            SetupProgressDots(count: SetupFlow.quickSteps.count, index: (flow.position?.index ?? 1) - 1)
                .padding(.top, 10)
            BoundedScroll {
                VStack(alignment: .leading, spacing: 18) {
                    IconTile(symbol: symbol, tint: step == .pairPhone ? .green : .blue, size: 56, corner: 16)
                    Text(title)
                        .font(BrandFont.heading(26))
                        .foregroundStyle(c.on)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 8) {
                        SetupWhyLine(label: L10n.setup("permission.why", fallback: "Why:"), text: why)
                        SetupWhyLine(label: L10n.setup("permission.without", fallback: "Without it:"), text: without)
                    }
                    if isDone, step == .pairPhone, let device = model.trustedDevices.first {
                        SetupPairedBadge(name: device.name)
                    } else if isDone {
                        SetupDoneBadge(text: doneText)
                    } else if let status, status.system == .denied {
                        Text(L10n.setup("setup.step.denied", fallback: "Not allowed. Open System Settings to allow it."))
                            .font(BrandFont.body(13, .medium))
                            .foregroundStyle(c.warn)
                    } else if let permission = step.permission, requested.contains(permission) {
                        Text(L10n.setup("setup.step.asked", fallback: "If macOS asked, choose Allow. Then continue."))
                            .font(BrandFont.body(13))
                            .foregroundStyle(c.on2)
                    }
                    if step == .pairPhone && !paired {
                        SetupPairing(model: model, actions: actions, setup: setup)
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)
            }
            SetupBottomBar(back: { setup.send(.back) }) {
                if !isDone {
                    Button(step == .pairPhone
                           ? L10n.setup("setup.pair.later", fallback: "Pair later")
                           : L10n.setup("action.skip", fallback: "Skip")) { setup.send(.skip) }
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 34))
                }
                primary
            }
        }
    }

    @ViewBuilder private var primary: some View {
        if isDone || (step.permission.map { requested.contains($0) } ?? false) {
            Button(L10n.setup("action.next", fallback: "Next")) { setup.send(.next) }
                .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                .keyboardShortcut(.defaultAction)
        } else if let permission = step.permission {
            Button(status?.system == .denied
                   ? L10n.setup("setup.step.openSettings", fallback: "Open System Settings")
                   : L10n.setup("setup.step.allow", fallback: "Allow")) { setup.allow(permission) }
                .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var symbol: String { step.permission?.symbol ?? "iphone.radiowaves.left.and.right" }

    private var title: String {
        switch step {
        case .localNetwork: L10n.setup("setup.step.localNetwork", fallback: "Allow Local Network")
        case .notifications: L10n.setup("setup.step.notifications", fallback: "Allow notifications")
        case .pairPhone: L10n.setup("setup.step.pair", fallback: "Pair a phone")
        }
    }

    private var why: String {
        step.permission?.why ?? L10n.setup("setup.pair.why", fallback: "Pairing lets this Mac and your phone trust each other, once.")
    }

    private var without: String {
        step.permission?.without ?? L10n.setup("setup.pair.without", fallback: "Nothing moves between them until you pair.")
    }

    private var doneText: String {
        if step == .pairPhone, let device = model.trustedDevices.first {
            return String(format: L10n.setup("setup.pair.done", fallback: "Paired with %@"), device.name)
        }
        return L10n.setup("setup.step.done", fallback: "Done")
    }
}

private struct SetupWhyLine: View {
    let label: String
    let text: String
    @Environment(\.brand) private var c

    var body: some View {
        (Text(label + " ").font(BrandFont.body(14, .semibold)).foregroundColor(c.on)
            + Text(text).font(BrandFont.body(14)).foregroundColor(c.on2))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SetupDoneBadge: View {
    let text: String
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
            Text(text).font(BrandFont.body(13, .semibold))
        }
        .foregroundStyle(c.tgi)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(c.tg))
        .accessibilityElement(children: .combine)
    }
}

private struct SetupProgressDots: View {
    let count: Int
    let index: Int
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(dot <= index ? c.pri : c.s4)
                    .frame(width: dot == index ? 28 : 14, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Pair a phone: the nearby list from Settings > Devices, then the pairing flow in its place (PairingViews.swift).
/// While the step is open the phone may start pairing too (the coordinator holds Allow pairing on).
private struct SetupPairing: View {
    let model: SettingsModel
    let actions: SettingsActions
    let setup: SetupActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.pairingFlow {
            case .idle, .connected:
                PairNewCard(model: model, actions: actions)
                SetupPairFromPhoneLine()
            default:
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        PairingFlowContent(state: model.pairingFlow, actions: PairingFlowActions(
                            confirm: setup.confirmPairing, reject: setup.rejectPairing, cancel: setup.cancelPairing,
                            retry: setup.retryPairing, openLocalNetworkSettings: { setup.allow(.localNetwork) }
                        ), codeSize: 40)
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .onAppear { setup.holdPairingArmed(true) }
        .onDisappear { setup.holdPairingArmed(false) }
    }
}

private struct SetupPairFromPhoneLine: View {
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(c.tgi)
                .accessibilityHidden(true)
            Text(L10n.setup("setup.pair.fromPhone", fallback: "You can also start pairing on the phone while this page is open."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// Paired: the badge and the next step.
private struct SetupPairedBadge: View {
    let name: String
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupDoneBadge(text: String(format: L10n.setup("setup.pair.done", fallback: "Paired with %@"), name))
            Text(L10n.setup("setup.pair.next", fallback: "Click Next to continue."))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
        }
    }
}

// MARK: - Done

private struct SetupDoneView: View {
    let flow: SetupFlow
    let setup: SetupActions
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(c.tg).frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(c.tgi)
            }
            .padding(.bottom, 22)
            Text(L10n.setup("setup.done.title", fallback: "You\u{2019}re set"))
                .font(BrandFont.heading(30))
                .foregroundStyle(c.on)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            Text(L10n.setup("setup.done.body", fallback: "The Essentials are on: clipboard when you click Send, and your phone\u{2019}s notifications. Everything else stays off until you turn it on in Settings."))
                .font(BrandFont.body(14))
                .foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            if !flow.skipped.isEmpty {
                let names = SetupPermission.allCases.filter { flow.skipped.contains($0) }.map(\.name)
                Text(String(format: L10n.setup("setup.done.skipped", fallback: "Skipped: %@. Allow it any time in Settings > Privacy > Permissions."),
                            ListFormatter.localizedString(byJoining: names)))
                    .font(BrandFont.body(13))
                    .foregroundStyle(c.on2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                    .padding(.top, 14)
            }
            HStack(spacing: 12) {
                Button(L10n.setup("setup.done.openSettings", fallback: "Open Settings"), action: setup.openSettings)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 36))
                Button(L10n.setup("setup.done.start", fallback: "Start"), action: setup.start)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 36))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 30)
            Spacer(minLength: 0)
            Button {
                setup.send(.back)
            } label: {
                Text(L10n.setup("action.back", fallback: "Back"))
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 48)
    }
}

// MARK: - Question path chrome

/// The top of a question page: its section, the steps left (from the path as it is now) and a bar.
private struct SetupQuestionHeader: View {
    let eyebrow: String
    let done: Int
    let left: Int
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        let fraction = CGFloat(done) / CGFloat(max(done + left, 1))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(eyebrow)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.tbi)
                Spacer()
                Text(Self.stepsLeft(left))
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.on2)
                    .monospacedDigit()
            }
            Capsule()
                .fill(c.s4)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(c.pri)
                            .frame(width: proxy.size.width)
                            .scaleEffect(x: max(fraction, 0.02), y: 1, anchor: .leading)
                            .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: fraction)
                    }
                }
                .clipShape(Capsule())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 32)
        .padding(.top, 38)
        .accessibilityElement(children: .combine)
    }

    init(eyebrow: String, flow: SetupFlow, facts: SetupFacts, left: Int? = nil) {
        self.eyebrow = eyebrow
        done = flow.trail.count
        self.left = left ?? flow.stepsLeft(facts)
    }

    static func stepsLeft(_ count: Int) -> String {
        switch count {
        case 0: L10n.setup("setup.left.last", fallback: "Last step")
        case 1: L10n.setup("setup.left.one", fallback: "1 step left")
        default: String(format: L10n.setup("setup.left.other", fallback: "%d steps left"), count)
        }
    }
}

/// The page body under the header: one column, centred, at most 540 wide.
private struct SetupColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        BoundedScroll {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 20)
        }
    }
}

/// The title and its one line of context.
private struct SetupHeading: View {
    let title: String
    let context: String
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(BrandFont.heading(26))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(context)
                .font(BrandFont.body(14))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A big answer button: its label, an optional line, the chosen check, or "Current".
private struct SetupAnswerButton: View {
    let answer: SetupAnswer
    let selected: Bool
    let current: Bool
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(answer.label)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(c.on)
                    if let detail = answer.detail {
                        Text(detail)
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(c.on2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(c.pri)
                } else if current {
                    Text(L10n.setup("setup.answer.current", fallback: "Current"))
                        .font(BrandFont.body(11, .semibold))
                        .foregroundStyle(c.on2)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(c.s3))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? c.pri : c.ol, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A plain link: More options, Change details in Settings, Change in Settings.
private struct SetupLink: View {
    let title: String
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
            }
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(c.pri)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Intro

/// The question path's start: one-click bundles, Type what you want (keyword rules, shown for
/// confirmation before anything changes), or straight on.
private struct SetupIntroView: View {
    let flow: SetupFlow
    let facts: SetupFacts
    let send: (SetupEvent) -> Void
    @State private var text: String
    @State private var picked: Set<String>
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    init(flow: SetupFlow, facts: SetupFacts, typedText: String, picked: Set<String>, send: @escaping (SetupEvent) -> Void) {
        self.flow = flow
        self.facts = facts
        self.send = send
        _text = State(initialValue: typedText)
        _picked = State(initialValue: picked)
    }

    private var chosen: [(id: String, key: String)] { SetupBundles.answers(picked: picked, typed: SetupTyped.match(text)) }

    private var chosenMap: [String: String] { Dictionary(chosen.map { ($0.id, $0.key) }, uniquingKeysWith: { _, last in last }) }

    var body: some View {
        VStack(spacing: 0) {
            SetupQuestionHeader(eyebrow: L10n.setup("setup.advanced.title", fallback: "Advanced setup"), flow: flow, facts: facts,
                                left: flow.stepsLeft(ifStarted: chosenMap, facts: facts))
            SetupColumn {
                SetupHeading(title: L10n.setup("setup.intro.title", fallback: "What do you want Bridgey for?"),
                             context: L10n.setup("setup.intro.body", fallback: "Pick what brought you here or type it in your own words. Everything else stays off until you turn it on."))
                bundles.padding(.top, 22)
                input.padding(.top, 18)
                preview.padding(.top, 14)
            }
            SetupBottomBar(back: flow.entry == .intro ? nil : { send(.back) }) {
                Button(chosen.isEmpty
                       ? L10n.setup("setup.intro.start", fallback: "Continue")
                       : L10n.setup("setup.intro.apply", fallback: "Turn these on and continue")) {
                    send(.startQuestions(chosenMap))
                }
                .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var bundles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.setup("setup.intro.bundles", fallback: "What brought you here?"))
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on2)
            SetupWrap(spacing: 8, lineSpacing: 8) {
                ForEach(SetupBundles.all) { bundle in
                    let on = picked.contains(bundle.id)
                    Button {
                        if on { picked.remove(bundle.id) } else { picked.insert(bundle.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: on ? "checkmark" : "plus").font(.system(size: 10, weight: .bold))
                            Text(bundle.title)
                        }
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(on ? c.tbi : c.on)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(on ? c.tb : c.s1))
                        .overlay(Capsule().strokeBorder(on ? Color.clear : c.ol, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .help(bundle.detail)
                    .accessibilityHint(bundle.detail)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.setup("setup.intro.type", fallback: "Or type what you want"))
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on2)
            ZStack(alignment: .topLeading) {
                if snapshot {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? c.on2 : c.on)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...3)
                        .foregroundStyle(c.on)
                }
            }
            .font(BrandFont.body(14))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.ol, lineWidth: 1))
        }
    }

    private var placeholder: String {
        L10n.setup("setup.intro.placeholder", fallback: "For example: my WhatsApp notifications, and sending photos to my Mac")
    }

    /// What each pick means, in plain words: a feature on or off, a follow-up's answer, Focus, updates.
    private var items: [(String, String)] {
        chosen.compactMap { id, key in
            if let feature = SetupFeatures.feature(id) {
                return (feature.title, key == SetupAnswerKey.no ? L10n.setup("setup.intro.off", fallback: "Stays off") : L10n.setup("setup.intro.on", fallback: "On"))
            }
            if let question = SetupQuestions.question(id), let answer = question.answer(key) { return (question.summary, answer.label) }
            if let label = SetupQuestions.typedOnlyLabel(id, key) { return (label.title, label.value) }
            return nil
        }
    }

    @ViewBuilder private var preview: some View {
        let items = items
        if !items.isEmpty {
            SettingsCard(title: L10n.setup("setup.intro.matched", fallback: "Bridgey will set these. Nothing changes until you continue.")) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(c.tgi)
                            (Text(item.0).foregroundColor(c.on) + Text("  " + item.1).foregroundColor(c.on2))
                                .font(BrandFont.body(13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(L10n.setup("setup.intro.nothing", fallback: "Nothing matched. Try words like notifications, photos, calls or clipboard."))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
        }
    }
}

/// Lays chips out left to right, wrapping to new lines.
struct SetupWrap: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + lineSpacing)
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Follow-up

private struct SetupQuestionView: View {
    let question: SetupQuestion
    let flow: SetupFlow
    let facts: SetupFacts
    let model: SettingsModel
    let actions: SettingsActions
    let setup: SetupActions
    let send: (SetupEvent) -> Void
    let more: (SettingsPane) -> Void

    private var paired: Bool { !model.trustedDevices.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SetupQuestionHeader(eyebrow: question.section.title, flow: flow, facts: facts)
            SetupColumn {
                VStack(alignment: .leading, spacing: 0) {
                    SetupHeading(title: question.title, context: question.context)
                    if question.id == "pair" {
                        pairing.padding(.top, 22)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(question.visibleAnswers(facts), id: \.key) { answer in
                                SetupAnswerButton(answer: answer, selected: flow.answers[question.id] == answer.key, current: isCurrent(answer)) {
                                    send(.answer(question.id, answer.key))
                                }
                            }
                        }
                        .padding(.top, 22)
                    }
                    if let pane = question.pane, question.id != "pair" {
                        SetupLink(title: L10n.setup("setup.more", fallback: "More options")) { more(pane) }
                            .padding(.top, 16)
                    }
                }
            }
            SetupBottomBar(back: { send(.back) }) {
                if question.id == "pair" && paired {
                    Button(L10n.setup("action.next", fallback: "Next")) { send(.notNow) }
                        .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.setup("action.notNow", fallback: "Not now")) { send(.notNow) }
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 34))
                }
            }
        }
    }

    /// The settings already match this answer (before anything is chosen).
    private func isCurrent(_ answer: SetupAnswer) -> Bool {
        flow.answers[question.id] == nil && !answer.changes.isEmpty && answer.changes.allSatisfy { facts.value($0.setting) == $0.value }
    }

    @ViewBuilder private var pairing: some View {
        if let device = model.trustedDevices.first {
            SetupPairedBadge(name: device.name)
        } else {
            SetupPairing(model: model, actions: actions, setup: setup)
        }
    }
}

// MARK: - Switches

/// Every feature that was not picked: one line each, off until switched on, with the details on
/// its Settings page.
private struct SetupSwitchesView: View {
    let flow: SetupFlow
    let facts: SetupFacts
    let send: (SetupEvent) -> Void
    let more: (SettingsPane) -> Void

    private var features: [SetupFeature] { SetupFeatures.all.filter { !flow.picked.contains($0.id) } }

    var body: some View {
        let effective = flow.effective(facts)
        VStack(spacing: 0) {
            SetupQuestionHeader(eyebrow: L10n.setup("setup.switches.eyebrow", fallback: "Everything else"), flow: flow, facts: facts)
            SetupColumn {
                SetupHeading(title: L10n.setup("setup.switches.title", fallback: "Anything else you want on?"),
                             context: L10n.setup("setup.switches.body", fallback: "Turn on what you need. The rest stays off until you want it."))
                SettingsCard {
                    ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                        SettingsToggle(title: feature.title, subtitle: feature.detail, divider: index > 0,
                                       isOn: SetupFeatures.isOn(feature, effective)) { send(.setSwitch(feature.id, $0)) }
                    }
                }
                .padding(.top, 20)
                SetupLink(title: L10n.setup("setup.switches.details", fallback: "Change details in Settings")) {
                    more(features.first?.pane ?? .clipboard)
                }
                .padding(.top, 14)
            }
            SetupBottomBar(back: { send(.back) }) {
                Button(L10n.setup("action.continue", fallback: "Continue")) { send(.proceed) }
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Permissions

/// The live status of one permission on the page.
enum SetupPermissionRowStatus: Equatable {
    case allowed, notYet, refused

    var title: String {
        switch self {
        case .allowed: L10n.setup("setup.permissions.allowed", fallback: "Allowed")
        case .notYet: L10n.setup("setup.permissions.notYet", fallback: "Not yet")
        case .refused: L10n.setup("setup.permissions.refused", fallback: "Refused")
        }
    }

    static func of(_ permission: SetupPermission, model: SettingsModel) -> SetupPermissionRowStatus {
        if permission == .accessibility && model.accessibilityTrusted { return .allowed }
        switch model.setup.permissions.first(where: { $0.permission == permission })?.system {
        case .allowed: return .allowed
        case .denied: return .refused
        default: return .notYet
        }
    }
}

/// Every permission the chosen features need, on one page: why, which features need it, the live
/// status and Allow; Allow all walks through them in order; Continue always works.
private struct SetupPermissionsView: View {
    let flow: SetupFlow
    let facts: SetupFacts
    let model: SettingsModel
    let setup: SetupActions
    let send: (SetupEvent) -> Void
    @Environment(\.brand) private var c

    private var needs: [SetupPermissionNeed] { flow.neededPermissions(facts) }

    var body: some View {
        let waiting = needs.filter { SetupPermissionRowStatus.of($0.permission, model: model) != .allowed }.map(\.permission)
        VStack(spacing: 0) {
            SetupQuestionHeader(eyebrow: L10n.setup("setup.permissions.eyebrow", fallback: "Permissions"), flow: flow, facts: facts)
            SetupColumn {
                SetupHeading(title: L10n.setup("setup.permissions.title", fallback: "Allow what these features need"),
                             context: L10n.setup("setup.permissions.body", fallback: "macOS asks once for each. Anything you skip stays off, and you can allow it later in Settings."))
                SettingsCard {
                    ForEach(Array(needs.enumerated()), id: \.element.permission) { index, need in
                        row(need, divider: index > 0)
                    }
                }
                .padding(.top, 20)
            }
            SetupBottomBar(back: { send(.back) }) {
                Button(L10n.setup("action.continue", fallback: "Continue")) { send(.proceed) }
                    .buttonStyle(PillButtonStyle(kind: waiting.isEmpty ? .gradient : .neutral, height: 34))
                if !waiting.isEmpty {
                    Button(L10n.setup("setup.permissions.allowAll", fallback: "Allow all")) { setup.allowAll(waiting) }
                        .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder private func row(_ need: SetupPermissionNeed, divider: Bool) -> some View {
        let status = SetupPermissionRowStatus.of(need.permission, model: model)
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: need.permission.symbol, tint: need.permission.tint, size: 30, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(need.permission.name)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(c.on)
                Text(need.permission.why)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(need.neededFor)
                    .font(BrandFont.body(11.5, .medium))
                    .foregroundStyle(c.on2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            chip(status)
            if status != .allowed {
                Button(status == .refused
                       ? L10n.setup("setup.step.openSettings", fallback: "Open System Settings")
                       : L10n.setup("setup.step.allow", fallback: "Allow")) { setup.requestFromPage(need.permission) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                    .fixedSize()
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ status: SetupPermissionRowStatus) -> some View {
        Text(status.title)
            .font(BrandFont.body(11, .semibold))
            .foregroundStyle(status == .allowed ? c.tgi : status == .refused ? c.warn : c.on2)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(status == .allowed ? c.tg : status == .refused ? c.warn.opacity(c.isDark ? 0.16 : 0.1) : c.s3))
            .fixedSize()
    }
}

// MARK: - Summary

/// What is on, each with a switch and Change in Settings; the typed choices; and what stayed off
/// because a permission was not allowed.
private struct SetupSummaryView: View {
    let flow: SetupFlow
    let facts: SetupFacts
    let model: SettingsModel
    let actions: SettingsActions
    let setup: SetupActions
    let send: (SetupEvent) -> Void
    let change: (SettingsPane) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        let items = SetupSummary.items(flow, facts: facts)
        VStack(spacing: 0) {
            SetupColumn {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(c.tg).frame(width: 48, height: 48)
                            Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(c.tgi)
                        }
                        SetupHeading(title: L10n.setup("setup.summary.title", fallback: "Here\u{2019}s what\u{2019}s on"),
                                     context: L10n.setup("setup.summary.body", fallback: "Turn anything off here, or change it later in Settings."))
                    }
                    .padding(.top, 12)
                    if items.isEmpty {
                        Text(L10n.setup("setup.summary.empty", fallback: "Nothing is on yet. Turn features on any time in Settings."))
                            .font(BrandFont.body(14))
                            .foregroundStyle(c.on2)
                    }
                    section(L10n.setup("setup.summary.on", fallback: "Turned on"), items.filter { if case .featureOn = $0 { true } else { false } })
                    section(L10n.setup("setup.summary.choices", fallback: "Your choices"), items.filter { if case .chosen = $0 { true } else { false } })
                    section(L10n.setup("setup.summary.notAllowed", fallback: "Not allowed"), items.filter { if case .notAllowed = $0 { true } else { false } })
                    // Settings sync (v0.10): one switch, the same as Settings > General.
                    SettingsCard {
                        SettingsToggle(title: L10n.setup("setup.summary.sync", fallback: "Settings stay the same on your devices"),
                                       subtitle: L10n.setup("setup.summary.sync.detail", fallback: "Change what syncs any time in Settings > General."),
                                       divider: false, isOn: model.settingsSyncEnabled, set: actions.setSettingsSync)
                    }
                }
            }
            SetupBottomBar(back: { send(.back) }) {
                Button(L10n.setup("setup.done.openSettings", fallback: "Open Settings"), action: setup.openSettings)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 34))
                Button(L10n.setup("setup.done.start", fallback: "Start"), action: setup.start)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [SetupSummaryItem]) -> some View {
        if !items.isEmpty {
            SettingsCard(title: title) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    row(item, divider: index > 0)
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: SetupSummaryItem, divider: Bool) -> some View {
        HStack(spacing: 12) {
            switch item {
            case let .featureOn(feature, on, detail):
                RowText(title: feature.title, subtitle: hint(feature) ?? detail ?? feature.detail)
                changeLink(feature.pane)
                Toggle(isOn: Binding(get: { on }, set: { send(.summarySwitch(feature.id, $0)) })) { EmptyView() }
                    .toggleStyle(BrandSwitchStyle())
                    .fixedSize()
                    .accessibilityLabel(feature.title)
            case let .chosen(title, value, pane):
                RowText(title: title, subtitle: value)
                changeLink(pane)
            case let .notAllowed(need):
                RowText(title: need.permission.name,
                        subtitle: String(format: L10n.setup("setup.summary.refused", fallback: "Not allowed, so it stays off: %@"),
                                         ListFormatter.localizedString(byJoining: need.features.compactMap { SetupFeatures.feature($0)?.title })),
                        warning: true)
                changeLink(.permissions)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
    }

    /// Codes read on this Mac need the model: offered here, downloaded from Settings.
    private func hint(_ feature: SetupFeature) -> String? {
        guard feature.id == "notifications", flow.answers["codes"] == SetupAnswerKey.onMac, model.codeModel.installed == nil else { return nil }
        return L10n.setup("setup.summary.codesModel", fallback: "Download the code model in Settings to start reading codes.")
    }

    private func changeLink(_ pane: SettingsPane) -> some View {
        Button(L10n.setup("setup.summary.change", fallback: "Change in Settings")) { change(pane) }
            .buttonStyle(.plain)
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(c.pri)
            .fixedSize()
    }
}

// MARK: - Leave setup? and More options

/// "Leave setup?" over the window: the close button or Escape mid-way.
private struct SetupLeaveDialog: View {
    let keepGoing: () -> Void
    let leave: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        ZStack {
            Color.black.opacity(c.isDark ? 0.45 : 0.25)
                .contentShape(Rectangle())
                .onTapGesture(perform: keepGoing)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.setup("setup.leave.title", fallback: "Leave setup?"))
                    .font(BrandFont.heading(20))
                    .foregroundStyle(c.on)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.setup("setup.leave.body", fallback: "Your choices so far are kept."))
                    .font(BrandFont.body(14))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    Button(L10n.setup("setup.leave.leave", fallback: "Leave"), action: leave)
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 34))
                    Button(L10n.setup("setup.leave.stay", fallback: "Keep going"), action: keepGoing)
                        .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 10)
            }
            .padding(24)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.ol, lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        }
    }
}

/// More options and Change in Settings: the live Settings page, over setup. Done (or Escape) returns.
private struct SetupMorePanel: View {
    let pane: SettingsPane
    let model: SettingsModel
    let actions: SettingsActions
    let done: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.setup("setup.more.eyebrow", fallback: "Settings"))
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(c.tbi)
                    Text(pane.title)
                        .font(BrandFont.heading(22))
                        .foregroundStyle(c.on)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                Button(L10n.setup("setup.more.done", fallback: "Done"), action: done)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(c.olv).frame(height: 1) }
            BoundedScroll {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsPaneView(pane: pane, model: model, actions: actions)
                        .environment(\.setupMode, true)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.isDark ? Color(hex: 0x0A101D) : c.bg)
    }
}
