import AppKit
import SwiftUI

/*
 * The permission explainer (shown before macOS asks) and Settings > Privacy > Permissions.
 */

/// "Allow Local Network?": why, what breaks without it, Continue or Not now.
struct PermissionExplainerView: View {
    let permission: SetupPermission
    var onContinue: () -> Void = {}
    var onNotNow: () -> Void = {}
    @Environment(\.brand) private var c

    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconTile(symbol: permission.symbol, tint: permission.tint, size: 48, corner: 14)
            Text(permission.explainerTitle)
                .font(BrandFont.heading(20))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) {
                ExplainerLine(label: L10n.setup("permission.why", fallback: "Why:"), text: permission.why)
                ExplainerLine(label: L10n.setup("permission.without", fallback: "Without it:"), text: permission.without)
            }
            Text(L10n.setup("permission.explainer.next", fallback: "Continue opens the macOS prompt or System Settings. You can change it there at any time."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.setup("action.notNow", fallback: "Not now"), action: onNotNow)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.setup("action.continue", fallback: "Continue"), action: onContinue)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 32))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(c.s1)
    }
}

private struct ExplainerLine: View {
    let label: String
    let text: String
    @Environment(\.brand) private var c

    var body: some View {
        (Text(label + " ").font(BrandFont.body(13, .semibold)).foregroundColor(c.on)
            + Text(text).font(BrandFont.body(13)).foregroundColor(c.on))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The state chip: Allowed, Not allowed, Not needed yet, Not on this device.
struct PermissionChipView: View {
    let chip: PermissionChip
    @Environment(\.brand) private var c

    var body: some View {
        Text(chip.title)
            .font(BrandFont.body(11, .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch chip {
        case .allowed: c.tgi
        case .notAllowed: c.warn
        case .notNeededYet, .notOnThisDevice: c.on2
        }
    }

    private var background: Color {
        switch chip {
        case .allowed: c.tg
        case .notAllowed: c.warn.opacity(c.isDark ? 0.16 : 0.1)
        case .notNeededYet, .notOnThisDevice: c.s3
        }
    }
}

/// Settings > Privacy > Permissions.
struct PermissionsPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        SettingsCard(footnote: L10n.setup("permissions.note", fallback: "Bridgey asks for each permission only when a feature needs it. Manage opens the exact page in System Settings.")) {
            ForEach(Array(model.setup.permissions.enumerated()), id: \.element.id) { index, status in
                PermissionRow(status: status, divider: index > 0,
                              manage: { actions.setup.managePermission(status.permission) },
                              explain: { actions.setup.explainPermission(status.permission) })
            }
        }
        .onAppear(perform: actions.setup.refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            actions.setup.refreshPermissions()
        }
    }
}

struct PermissionRow: View {
    let status: PermissionStatus
    var divider = true
    let manage: () -> Void
    let explain: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: status.permission.symbol, tint: status.permission.tint, size: 30, corner: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.permission.name)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                Text(status.permission.why)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PermissionChipView(chip: status.chip)
            Button(action: explain) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(c.on2)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.setup("permissions.why.help", fallback: "Why Bridgey asks"))
            .accessibilityLabel(String(format: L10n.setup("permissions.why.label", fallback: "Why Bridgey asks for %@"), status.permission.name))
            Button(L10n.setup("permissions.manage", fallback: "Manage"), action: manage)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                .disabled(status.manage == .none)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
    }
}

// MARK: - Entry rows on the Privacy and General pages

/// Hides rows that make no sense inside setup (Reset, Run setup again).
private struct SetupModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var setupMode: Bool {
        get { self[SetupModeKey.self] }
        set { self[SetupModeKey.self] = newValue }
    }
}

/// Privacy: the row that opens Permissions.
struct PrivacyPermissionsCard: View {
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        SettingsCard {
            SettingsRow(title: L10n.setup("permissions.title", fallback: "Permissions"),
                        subtitle: permissionsSummary(model.setup.permissions), divider: false) {
                Button(L10n.setup("action.open", fallback: "Open")) { actions.setup.showPane(.permissions) }
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
            }
        }
    }
}

/// "4 allowed, 1 not allowed" for the Privacy row.
func permissionsSummary(_ statuses: [PermissionStatus]) -> String {
    let missing = statuses.filter { $0.chip == .notAllowed }.count
    if missing == 0 { return L10n.setup("permissions.summary.ok", fallback: "What Bridgey can use on this Mac, and why") }
    return String(format: L10n.setup("permissions.summary.missing", fallback: "%d needed but not allowed"), missing)
}

/// Privacy: the row that opens Reset Bridgey on this device (not inside setup).
struct PrivacyResetCard: View {
    let actions: SettingsActions
    @Environment(\.setupMode) private var setupMode

    var body: some View {
        if !setupMode {
            SettingsCard {
                SettingsRow(title: L10n.setup("reset.title", fallback: "Reset Bridgey on this device"),
                            subtitle: L10n.setup("reset.row.detail", fallback: "Delete activity, caches, settings or everything"), divider: false) {
                    Button(L10n.setup("action.open", fallback: "Open")) { actions.setup.showPane(.reset) }
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
            }
        }
    }
}

/// General: Run setup again (not inside setup).
struct RunSetupAgainCard: View {
    let actions: SettingsActions
    @Environment(\.setupMode) private var setupMode

    var body: some View {
        if !setupMode {
            SettingsCard {
                SettingsRow(title: L10n.setup("setup.again", fallback: "Run setup again"),
                            subtitle: L10n.setup("setup.again.detail", fallback: "Go through setup from the start. Pairings and settings are kept."), divider: false) {
                    Button(L10n.setup("setup.again.action", fallback: "Run setup"), action: actions.setup.runSetupAgain)
                        .buttonStyle(PillButtonStyle(kind: .outline, height: 28))
                }
            }
        }
    }
}

// MARK: - Sub-pages of Privacy

extension SettingsPane {
    /// Permissions and Reset open from Privacy and are not in the sidebar.
    var parentPane: SettingsPane? {
        switch self {
        case .permissions, .reset: .privacy
        default: nil
        }
    }

    /// The sidebar item that shows as selected.
    var sidebarPane: SettingsPane { parentPane ?? self }

    /// The heading of Permissions or Reset (SettingsPane.title uses it for both).
    var subpageTitle: String {
        self == .reset
            ? L10n.setup("reset.title", fallback: "Reset Bridgey on this device")
            : L10n.setup("permissions.title", fallback: "Permissions")
    }
}

/// "< Privacy" above a sub-page's heading.
struct SettingsBackButton: View {
    @Binding var pane: SettingsPane
    @Environment(\.brand) private var c

    var body: some View {
        if let parent = pane.parentPane {
            Button {
                pane = parent
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text(parent.title).font(BrandFont.body(13, .semibold))
                }
                .foregroundStyle(c.pri)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, -8)
        }
    }
}

// MARK: - Model and actions the Settings panes use

struct SetupSettingsModel {
    var permissions: [PermissionStatus] = SetupPermission.allCases.map {
        PermissionStatus(permission: $0, system: .notDetermined, needed: PermissionNeeds().needed($0))
    }
    /// "Activity and logs deleted", after a reset.
    var resetMessage: String?
}

struct SetupSettingsActions {
    var showPane: (SettingsPane) -> Void = { _ in }
    var managePermission: (SetupPermission) -> Void = { _ in }
    var explainPermission: (SetupPermission) -> Void = { _ in }
    var refreshPermissions: () -> Void = {}
    /// Opens the confirm dialog for a choice.
    var confirmReset: (ResetChoice) -> Void = { _ in }
    var runSetupAgain: () -> Void = {}
}
