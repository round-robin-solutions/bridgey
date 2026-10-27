import AppKit
import SwiftUI

/*
 * The setup window: Welcome, the quick path (Local Network, Notifications, Pair a phone, Done)
 * and the advanced path (the real Settings pages, one group at a time). The view draws from a
 * `SetupFlow`, a `SettingsModel` and plain closures, so screenshots render it from sample state.
 */

struct SetupActions {
    var send: (SetupEvent) -> Void = { _ in }
    /// The explainer (first time), then the macOS prompt or the System Settings page.
    var allow: (SetupPermission) -> Void = { _ in }
    var confirmPairing: () -> Void = {}
    var cancelPairing: () -> Void = {}
    var openSettings: () -> Void = {}
    var start: () -> Void = {}
}

struct SetupWindowView: View {
    let flow: SetupFlow
    let model: SettingsModel
    let actions: SettingsActions
    let setup: SetupActions
    /// Permissions asked for during this setup (their step then offers Next).
    var requested: Set<SetupPermission> = []
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot

    static let size = CGSize(width: 760, height: 640)

    var body: some View {
        ZStack {
            SetupBackdrop()
            switch flow.screen {
            case .welcome: SetupWelcomeView(send: setup.send)
            case let .quick(step):
                SetupQuickStepView(step: step, flow: flow, model: model, actions: actions, setup: setup, requested: requested)
            case let .advanced(group):
                SetupAdvancedView(group: group, flow: flow, model: model, actions: actions, send: setup.send)
            case .done: SetupDoneView(flow: flow, setup: setup)
            }
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
                    detail: L10n.setup("setup.quick.detail", fallback: "Sensible defaults and only the permissions you need now. Change anything later in Settings."),
                    highlighted: true
                ) { send(.chooseQuick) }
                SetupChoiceCard(
                    symbol: "slider.horizontal.3", tint: .purple,
                    title: L10n.setup("setup.advanced.title", fallback: "Advanced setup"),
                    badge: nil,
                    detail: L10n.setup("setup.advanced.detail", fallback: "Go through every feature and choose how it works. Defaults are already selected."),
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
            .frame(width: 300, height: 210, alignment: .topLeading)
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
    let back: () -> Void
    @ViewBuilder let trailing: Trailing
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            Button {
                back()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text(L10n.setup("action.back", fallback: "Back"))
                }
            }
            .buttonStyle(PillButtonStyle(kind: .outline, height: 34))
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
                    if isDone {
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

/// Pair a phone: the nearby list from Settings > Devices, and the code check while pairing.
private struct SetupPairing: View {
    let model: SettingsModel
    let actions: SettingsActions
    let setup: SetupActions
    @Environment(\.brand) private var c

    var body: some View {
        if case let .verification(name, code) = model.state {
            SettingsCard(footnote: L10n.text("panel.verify.detail", fallback: "Confirm only if both devices show the same code.")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: L10n.text("panel.verify", fallback: "Verify %@"), name))
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(c.on)
                    Text(code)
                        .font(BrandFont.heading(30))
                        .foregroundStyle(c.on)
                        .monospacedDigit()
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button(L10n.text("action.cancel", fallback: "Cancel"), action: setup.cancelPairing)
                            .buttonStyle(PillButtonStyle(kind: .outline, height: 30))
                        Button(L10n.text("panel.verify.match", fallback: "Codes Match"), action: setup.confirmPairing)
                            .buttonStyle(PillButtonStyle(kind: .gradient, height: 30))
                    }
                }
                .padding(.vertical, 12)
            }
        } else {
            PairNewCard(model: model, actions: actions)
        }
    }
}

// MARK: - Advanced path

private struct SetupAdvancedView: View {
    let group: SetupGroup
    let flow: SetupFlow
    let model: SettingsModel
    let actions: SettingsActions
    let send: (SetupEvent) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SetupTopBar(title: L10n.setup("setup.advanced.title", fallback: "Advanced setup"), position: flow.position)
                SetupGroupChips(current: group, visited: flow.visited, send: send)
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(c.olv).frame(height: 1) }
            BoundedScroll {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(BrandFont.heading(22))
                            .foregroundStyle(c.on)
                            .accessibilityAddTraits(.isHeader)
                        Text(group.intro)
                            .font(BrandFont.body(13))
                            .foregroundStyle(c.on2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsPaneView(pane: group.pane, model: model, actions: actions)
                        .environment(\.setupMode, true)
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SetupBottomBar(back: { send(.back) }) {
                if !flow.isLastPage {
                    Button(L10n.setup("setup.finishNow", fallback: "Finish now")) { send(.finish) }
                        .buttonStyle(PillButtonStyle(kind: .neutral, height: 34))
                }
                Button(flow.isLastPage ? L10n.setup("action.finish", fallback: "Finish") : L10n.setup("action.next", fallback: "Next")) { send(.next) }
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 34))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Every group as a chip; tap one to jump there.
private struct SetupGroupChips: View {
    let current: SetupGroup
    let visited: [SetupGroup]
    let send: (SetupEvent) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        SetupFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(SetupGroup.allCases) { group in
                let isCurrent = group == current
                let seen = visited.contains(group)
                Button {
                    send(.jump(group))
                } label: {
                    HStack(spacing: 5) {
                        if seen && !isCurrent {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        }
                        Text(group.title).lineLimit(1)
                    }
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(isCurrent ? c.tbi : (seen ? c.on : c.on2))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(isCurrent ? c.tb : (seen ? c.s3 : Color.clear)))
                    .overlay(Capsule().strokeBorder(isCurrent || seen ? Color.clear : c.ol, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }
}

/// Lays chips out left to right, wrapping to new lines.
struct SetupFlowLayout: Layout {
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
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
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
            Text(L10n.setup("setup.done.body", fallback: "Bridgey is ready in the menu bar. Change anything later in Settings."))
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
