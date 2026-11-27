import SwiftUI

/*
 * Settings, direction A (26 Nov 2026): six groups in the sidebar, and one card per feature. A card has the
 * feature's switch in its header, the two or three rows people use most, one Devices row of chips for the
 * per-device choice, and More options for the rest. Every setting has one home. The old panes live on as
 * `SettingsPane`, the id deep links, notifications and setup still use: each maps to a group and a card.
 */

/// The sidebar: what people come to change.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case devices, sharing, phone, control, privacy, app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: L10n.text("settings.group.devices", fallback: "Devices")
        case .sharing: L10n.text("settings.group.sharing", fallback: "Sharing")
        case .phone: L10n.text("settings.group.phone", fallback: "Phone")
        case .control: L10n.text("settings.group.control", fallback: "Control")
        case .privacy: L10n.text("settings.group.privacy", fallback: "Privacy")
        case .app: L10n.text("settings.group.app", fallback: "App")
        }
    }

    var symbol: String {
        switch self {
        case .devices: "laptopcomputer.and.iphone"
        case .sharing: "arrow.right.square"
        case .phone: "iphone"
        case .control: "cursorarrow"
        case .privacy: "shield"
        case .app: "gearshape"
        }
    }

    var tint: TileTint {
        switch self {
        case .devices, .sharing: .blue
        case .phone: .purple
        case .control: .green
        case .privacy, .app: .neutral
        }
    }

    /// The cards, top to bottom. Developer shows only while it is on.
    func cards(developer: Bool) -> [SettingsCardID] {
        SettingsCardID.allCases.filter { $0.group == self && ($0 != .developer || developer) }
    }
}

/// One card: a feature, or a part of the app (This Mac, Permissions, About).
enum SettingsCardID: String, CaseIterable, Identifiable {
    // Devices
    case thisMac, pairedDevices, pair, tailscale, away, battery, find, ping
    // Sharing
    case clipboard, files, media, links
    // Phone
    case notifications, codes, focus, messages, calls, callsWindow, callQuiet
    // Control
    case remoteControl, macScreen, phoneScreen, macActions
    // Privacy
    case activity, permissions, logging, reset
    // App
    case updates, general, sync, about, developer

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .thisMac, .pairedDevices, .pair, .tailscale, .away, .battery, .find, .ping: .devices
        case .clipboard, .files, .media, .links: .sharing
        case .notifications, .codes, .focus, .messages, .calls, .callsWindow, .callQuiet: .phone
        case .remoteControl, .macScreen, .phoneScreen, .macActions: .control
        case .activity, .permissions, .logging, .reset: .privacy
        case .updates, .general, .sync, .about, .developer: .app
        }
    }

    /// The card's heading: the feature's name.
    var title: String {
        switch self {
        case .thisMac: L10n.text("settings.thisMac", fallback: "This Mac")
        case .pairedDevices: L10n.text("settings.card.paired", fallback: "Paired devices")
        case .pair: L10n.text("devices.pair", fallback: "Pair a new device")
        case .tailscale: "Tailscale"
        case .away: L10n.text("settings.away", fallback: "Connect away from home")
        case .battery: L10n.text("settings.card.battery", fallback: "Battery")
        case .find: L10n.text("settings.card.find", fallback: "Find device")
        case .ping: L10n.text("settings.card.ping", fallback: "Ping")
        case .clipboard: L10n.text("settings.clipboard", fallback: "Clipboard")
        case .files: L10n.text("settings.files", fallback: "Files")
        case .media: L10n.text("settings.card.media", fallback: "Media")
        case .links: L10n.text("settings.card.links", fallback: "Links")
        case .notifications: L10n.text("settings.notifications", fallback: "Notifications")
        case .codes: L10n.text("codes.title", fallback: "Codes from messages")
        case .focus: L10n.text("focus.title", fallback: "Focus")
        case .messages: L10n.text("sms.title", fallback: "Text messages")
        case .calls: L10n.text("settings.calls", fallback: "Calls")
        case .callsWindow: L10n.text("calls.window.title", fallback: "Calls window")
        case .callQuiet: L10n.text("callMedia.title", fallback: "Quiet media during calls")
        case .remoteControl: L10n.text("settings.remoteControl", fallback: "Remote control")
        case .macScreen: MacScreenSettings.cardTitle
        case .phoneScreen: PhoneScreenSettings.cardTitle
        case .macActions: L10n.text("settings.macActions", fallback: "Mac actions")
        case .activity: L10n.text("settings.activity", fallback: "Activity")
        case .permissions: L10n.setup("permissions.title", fallback: "Permissions")
        case .logging: L10n.text("settings.logging", fallback: "Logging")
        case .reset: L10n.setup("reset.title", fallback: "Reset Bridgey on this device")
        case .updates: L10n.text("settings.updates", fallback: "Updates")
        case .general: L10n.text("settings.general", fallback: "General")
        case .sync: L10n.text("settings.card.sync", fallback: "Sync settings")
        case .about: L10n.text("settings.about", fallback: "About")
        case .developer: L10n.text("settings.developer", fallback: "Developer and experimental")
        }
    }

    var symbol: String {
        switch self {
        case .thisMac: "laptopcomputer"
        case .pairedDevices: "laptopcomputer.and.iphone"
        case .pair: "plus"
        case .tailscale: "network"
        case .away: "globe"
        case .battery: "battery.75"
        case .find: "dot.radiowaves.left.and.right"
        case .ping: "bell.badge"
        case .clipboard: "doc.on.clipboard"
        case .files: "folder"
        case .media: "music.note"
        case .links: "link"
        case .notifications: "bell"
        case .codes: "number"
        case .focus: "moon"
        case .messages: "message"
        case .calls: "phone"
        case .callsWindow: "circle.grid.3x3"
        case .callQuiet: "speaker.slash"
        case .remoteControl: "cursorarrow.rays"
        case .macScreen: "display"
        case .phoneScreen: "iphone"
        case .macActions: "lock"
        case .activity: "clock.arrow.circlepath"
        case .permissions: "lock.shield"
        case .logging: "doc.text"
        case .reset: "arrow.counterclockwise"
        case .updates: "arrow.triangle.2.circlepath"
        case .general: "gearshape"
        case .sync: "arrow.triangle.2.circlepath.circle"
        case .about: "info.circle"
        case .developer: "hammer"
        }
    }

    var tint: TileTint {
        switch self {
        case .thisMac, .pairedDevices, .pair, .tailscale, .away, .clipboard, .media, .links, .find, .ping: .blue
        case .battery, .files, .messages, .calls, .callsWindow, .phoneScreen: .green
        case .notifications, .codes, .focus, .callQuiet, .remoteControl, .macScreen, .macActions, .updates: .purple
        case .activity, .permissions, .logging, .reset, .general, .sync, .about, .developer: .neutral
        }
    }
}

extension SettingsPane {
    /// The group an old pane's settings live in now. Every pane has one (SettingsGroupTests).
    var group: SettingsGroup { card.group }

    /// The card a link to this pane scrolls to.
    var card: SettingsCardID { cards[0] }

    /// The cards that hold what this pane held, in order: what setup's More options shows for it.
    var cards: [SettingsCardID] {
        switch self {
        case .thisMac: [.thisMac]
        case .devices: [.pairedDevices, .pair, .tailscale]
        case .away: [.away, .tailscale]
        case .clipboard: [.clipboard]
        case .notifications: [.notifications, .codes, .focus]
        case .messages: [.messages]
        case .calls: [.calls, .callsWindow, .callQuiet]
        case .files: [.files]
        case .media: [.media, .links, .battery, .find, .ping, .macActions]
        case .remoteControl: [.remoteControl, .macScreen, .phoneScreen]
        case .privacy: [.activity, .permissions, .logging, .reset]
        case .permissions: [.permissions]
        case .reset: [.reset]
        case .updates: [.updates]
        case .general: [.general, .sync]
        case .about: [.about]
        case .developer: [.developer]
        }
    }
}

/// Where a card sits, for scrolling to it.
struct SettingsCardScrollID: Hashable {
    let card: SettingsCardID
}

// MARK: - Environment

private struct CardFlatKey: EnvironmentKey { static let defaultValue = false }
private struct ExpandAllKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Inside a feature card: a SettingsCard draws as a section of the card, not a box of its own.
    var settingsCardFlat: Bool {
        get { self[CardFlatKey.self] }
        set { self[CardFlatKey.self] = newValue }
    }

    /// Every card's More options open (setup's More options, screenshots, the registry tests).
    var settingsExpandAll: Bool {
        get { self[ExpandAllKey.self] }
        set { self[ExpandAllKey.self] = newValue }
    }
}

// MARK: - The card

/// A feature's switch, drawn in its card's header.
struct CardToggle {
    /// The switch's own name: the row search finds it by, and what VoiceOver adds when it differs from the card's title.
    let title: String
    let isOn: Bool
    var synced = false
    var enabled = true
    let set: (Bool) -> Void
}

/// A feature card: header (icon, name, switch), the common rows, then More options.
struct FeatureCard<Content: View, More: View>: View {
    let card: SettingsCardID
    var title: String?
    /// A line under the title, only where the name alone does not say what turning it on means.
    var detail: String?
    var toggle: CardToggle?
    /// The header's search anchor when it has no switch (Pair a new device, Permissions).
    var headerAnchor: String?
    /// Under the card, or at the end of More options when there is one.
    var footnote: String?
    private let hasMore: Bool
    private let content: Content
    private let more: More
    @State private var expanded = false
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.settingsExpandAll) private var expandAll
    @Environment(\.settingsSearchHighlight) private var highlight

    init(card: SettingsCardID, title: String? = nil, detail: String? = nil, toggle: CardToggle? = nil, headerAnchor: String? = nil,
         footnote: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder more: () -> More) {
        self.card = card
        self.title = title
        self.detail = detail
        self.toggle = toggle
        self.headerAnchor = headerAnchor
        self.footnote = footnote
        self.content = content()
        self.more = more()
        hasMore = true
    }

    private var open: Bool { expanded || expandAll || highlight?.expand == card }
    private var name: String { title ?? card.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
                if hasMore {
                    // Opened everywhere (setup's More options): no disclosure to show.
                    if !expandAll { disclosure }
                    if open {
                        VStack(alignment: .leading, spacing: 0) {
                            more
                            if let footnote { note(footnote) }
                        }
                        .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: -6)))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, hasMore ? 0 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.olv, lineWidth: 1))
            .environment(\.settingsCardFlat, true)
            if !hasMore, let footnote {
                Text(footnote)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)
            }
        }
        .id(SettingsCardScrollID(card: card))
        .onAppear { if highlight?.expand == card { expanded = true } }
        .onChange(of: highlight?.token) { _ in if highlight?.expand == card { expanded = true } }
    }

    @ViewBuilder private var header: some View {
        if let toggle {
            Button {
                withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { toggle.set(!toggle.isOn) }
            } label: {
                HStack(spacing: 12) {
                    headerText(synced: toggle.synced)
                    CardSwitchTrack(isOn: toggle.isOn)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!toggle.enabled)
            .opacity(toggle.enabled ? 1 : 0.45)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(name))
            .modifier(OptionalHint(text: toggle.title == name ? nil : toggle.title))
            .switchAccessibility(isOn: toggle.isOn)
            .settingsSearchAnchor(toggle.title)
        } else {
            HStack(spacing: 12) { headerText(synced: false) }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .modifier(OptionalAnchor(title: headerAnchor))
        }
    }

    private func headerText(synced: Bool) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: card.symbol, tint: card.tint, size: 30, corner: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(c.on)
                    if synced { SyncedMark() }
                }
                if let detail {
                    Text(detail)
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var disclosure: some View {
        Button {
            withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(L10n.text("settings.more", fallback: "More options"))
                    .font(BrandFont.body(13, .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(c.on2)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
        .accessibilityLabel(String(format: L10n.text("settings.more.label", fallback: "More options for %@"), name))
        .accessibilityValue(open ? L10n.text("settings.more.open", fallback: "Expanded") : L10n.text("settings.more.closed", fallback: "Collapsed"))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(12))
            .foregroundStyle(c.on2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }
}

extension FeatureCard where More == EmptyView {
    /// A card with nothing more to show.
    init(card: SettingsCardID, title: String? = nil, detail: String? = nil, toggle: CardToggle? = nil, headerAnchor: String? = nil,
         footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.card = card
        self.title = title
        self.detail = detail
        self.toggle = toggle
        self.headerAnchor = headerAnchor
        self.footnote = footnote
        self.content = content()
        more = EmptyView()
        hasMore = false
    }
}

/// A hint only when there is something to add: an empty hint still makes VoiceOver pause.
private struct OptionalHint: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty { content.accessibilityHint(Text(text)) } else { content }
    }
}

private struct OptionalAnchor: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title { content.settingsSearchAnchor(title) } else { content }
    }
}

/// The header switch's track: BrandSwitchStyle's look, drawn without a label so the header button holds it.
struct CardSwitchTrack: View {
    let isOn: Bool
    private let scale: CGFloat = 0.75
    @Environment(\.brand) private var c

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? c.switchOn : c.switchOff)
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : c.ol, lineWidth: 2))
            Circle()
                .fill(isOn ? c.switchThumb : c.on2)
                .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                .offset(x: isOn ? 24 : 8)
        }
        .frame(width: 52, height: 32)
        .scaleEffect(scale)
        .frame(width: 52 * scale, height: 32 * scale)
        .accessibilityHidden(true)
    }
}

// MARK: - Devices row

/// One device's chip: its name, and whether this feature is on for it.
struct DeviceChoiceChip: Identifiable {
    let id: String
    let name: String
    let isOn: Bool
    var enabled = true
    /// The row title the old per-device switch had: search finds the chip by it, in the device's scope.
    let anchor: String
    /// Why it does not work although chosen ("Off on OnePlus 11"); the Devices row lists these.
    var note: String?
    let set: (Bool) -> Void
}

/// "Devices" and a chip per paired device, wrapping to the right.
struct DeviceChoicesRow: View {
    /// What the chips turn on, for VoiceOver ("OnePlus 11, Clipboard").
    let feature: String
    let chips: [DeviceChoiceChip]
    /// The row's title: "Devices", or what a second row of chips chooses.
    var title: String?
    /// The row's own search anchor, where an old list became this row ("Phones allowed to control this Mac").
    var anchor: String?
    /// A line under the title: the chips' notes, or why every chip is off.
    var subtitle: String?
    @Environment(\.brand) private var c

    var body: some View {
        let notes = chips.compactMap(\.note)
        let line = subtitle ?? (notes.isEmpty ? nil : notes.joined(separator: "\n"))
        HStack(alignment: .center, spacing: 12) {
            RowText(title: title ?? L10n.text("settings.devicesRow", fallback: "Devices"), subtitle: line, warning: subtitle == nil && !notes.isEmpty)
                .frame(minWidth: 140, alignment: .leading)
            if chips.isEmpty {
                Text(L10n.text("devices.none", fallback: "No paired devices yet"))
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
            } else {
                TrailingWrap(spacing: 8, lineSpacing: 8) {
                    ForEach(chips) { chip in
                        DeviceChoiceChipView(chip: chip, feature: feature)
                            .settingsSearchAnchor(chip.anchor, inset: -3)
                            .settingsSearchScope(chip.id)
                    }
                }
                // The chips take the room they need first; the title and notes wrap in what is left.
                .layoutPriority(1)
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .modifier(OptionalAnchor(title: anchor))
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }
}

struct DeviceChoiceChipView: View {
    let chip: DeviceChoiceChip
    let feature: String
    @Environment(\.brand) private var c
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        let on = chip.isOn
        Button {
            withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { chip.set(!on) }
        } label: {
            HStack(spacing: 5) {
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .transition(.opacity)
                }
                Text(chip.name)
                    .font(BrandFont.body(12, .semibold))
                    .lineLimit(1)
                if chip.note != nil {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(c.tpi)
                }
            }
            .foregroundStyle(on ? c.tbi : c.on2)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(on ? c.tb : Color.clear))
            .overlay(Capsule().strokeBorder(on ? Color.clear : c.ol, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!chip.enabled)
        .opacity(chip.enabled && isEnabled ? 1 : 0.45)
        .help(chip.note ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L10n.text("settings.chip.label", fallback: "%1$@, %2$@"), chip.name, feature))
        .modifier(OptionalHint(text: chip.note))
        .switchAccessibility(isOn: on)
    }
}

/// Chips in rows, right-aligned; a row wraps when the next chip does not fit.
struct TrailingWrap: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: min(proposal.width ?? used, max(used, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
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

// MARK: - Chips for each per-device choice

/// The chips each feature card draws. They read and write exactly what the per-device switches on the old Devices
/// page did (DeviceChipsTests).
enum DeviceChoices {
    /// A feature every device gets unless turned off for it (Clipboard, Files, Notifications...).
    static func feature(_ feature: BridgeyFeature, _ model: SettingsModel, _ actions: SettingsActions) -> [DeviceChoiceChip] {
        model.trustedDevices.map { device in
            let remote = model.phoneFeatures[device.id] ?? (model.connectedDeviceID == device.id ? model.remoteFeatures : [:])
            let on = model.isEnabled(feature, for: device.id)
            return DeviceChoiceChip(id: device.id, name: device.name, isOn: on,
                              enabled: model.globalFeatures[feature] != false, anchor: feature.title,
                              note: on && remote[feature] == false ? String(format: L10n.text("permission.offRemote", fallback: "Off on %@"), device.name) : nil,
                              set: { actions.setForDevice(device.id, feature, $0) })
        }
    }

    /// Automatic clipboard for each device (Clipboard > More options).
    static func autoClipboard(_ model: SettingsModel, _ actions: SettingsActions) -> [DeviceChoiceChip] {
        model.trustedDevices.map { device in
            DeviceChoiceChip(id: device.id, name: device.name, isOn: model.isAutoClipboardEnabled(for: device.id),
                       enabled: model.autoClipboard && model.isEnabled(.clipboard, for: device.id),
                       anchor: L10n.text("settings.autoClipboard", fallback: "Automatic clipboard"),
                       set: { actions.setAutoClipboardForDevice(device.id, $0) })
        }
    }

    /// Remote control: granted to each device on its own, off by default.
    static func remoteControl(_ model: SettingsModel, _ actions: SettingsActions) -> [DeviceChoiceChip] {
        model.trustedDevices.map { device in
            let granted = model.remoteGrant(for: device.id)
            var note: String?
            if granted, model.globalFeatures[.remoteInput] == true, model.phoneFeatures[device.id]?[.remoteInput] == false {
                note = String(format: L10n.text("remote.grant.phoneOff", fallback: "Turn on Remote control in Bridgey on %@"), device.name)
            }
            return DeviceChoiceChip(id: device.id, name: device.name, isOn: granted, anchor: L10n.text("remote.grant", fallback: "Allow remote control"),
                              note: note, set: { actions.setForDevice(device.id, .remoteInput, $0) })
        }
    }

    /// Mac actions: granted to each device on its own, off by default.
    static func macActions(_ model: SettingsModel, _ actions: SettingsActions) -> [DeviceChoiceChip] {
        model.trustedDevices.map { device in
            let granted = model.deviceFeatures[device.id]?[.macActions] == true
            var note: String?
            if granted, model.globalFeatures[.macActions] == true, model.phoneFeatures[device.id]?[.macActions] == false {
                note = String(format: L10n.text("actions.grant.phoneOff", fallback: "Turn on Mac actions in Bridgey on %@"), device.name)
            }
            return DeviceChoiceChip(id: device.id, name: device.name, isOn: granted, anchor: L10n.text("actions.grant", fallback: "Allow Mac actions"),
                              note: note, set: { actions.setForDevice(device.id, .macActions, $0) })
        }
    }

    /// The phones the Calls window may call through. Macs and servers cannot place calls.
    static func callsWindow(_ model: SettingsModel, _ actions: SettingsActions) -> [DeviceChoiceChip] {
        model.trustedDevices.filter { !model.restrictedDevices.contains($0.id) && !model.macDevices.contains($0.id) }.map { device in
            let granted = model.deviceFeatures[device.id]?[.dialer] == true
            let phoneOff = granted && model.phoneFeatures[device.id]?[.dialer] == false
            return DeviceChoiceChip(id: device.id, name: device.name, isOn: granted, anchor: BridgeyFeature.dialer.title,
                              note: phoneOff ? String(format: L10n.text("calls.window.phone.off", fallback: "Allow this Mac in Bridgey on %@: Settings > Calls"), device.name) : nil,
                              set: { actions.setForDevice(device.id, .dialer, $0) })
        }
    }

    /// Call status and media quieting: each device on its own, never a server or agent.
    static func callQuiet(_ model: SettingsModel, _ actions: SettingsActions) -> [DeviceChoiceChip] {
        model.trustedDevices.map { device in
            DeviceChoiceChip(id: device.id, name: device.name,
                       isOn: model.globalFeatures[.callQuiet] == true && model.deviceFeatures[device.id]?[.callQuiet] == true,
                       enabled: model.globalFeatures[.callQuiet] == true && !model.restrictedDevices.contains(device.id),
                       anchor: L10n.text("callMedia.grant", fallback: "Allow call status and media quieting"),
                       set: { actions.setForDevice(device.id, .callQuiet, $0) })
        }
    }

    /// Settings sync with each device.
    static func settingsSync(_ model: SettingsModel, _ actions: SettingsActions) -> [DeviceChoiceChip] {
        model.trustedDevices.map { device in
            let on = model.isSettingsSyncEnabled(for: device.id)
            return DeviceChoiceChip(id: device.id, name: device.name, isOn: on, enabled: model.settingsSyncEnabled,
                              anchor: L10n.text("settings.sync.device", fallback: "Sync settings with this device"),
                              note: on && model.phoneSettingsSync[device.id] == false
                                  ? String(format: L10n.text("permission.offRemote", fallback: "Off on %@"), device.name) : nil,
                              set: { actions.setSettingsSyncForDevice(device.id, $0) })
        }
    }
}
