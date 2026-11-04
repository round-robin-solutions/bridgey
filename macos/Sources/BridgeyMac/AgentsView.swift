import SwiftUI

/*
 * Settings > Devices > "Agents on <phone>": the agents paired with that phone, mirrored from its agents.state.
 * The same permission matrix as the phone (rows in the wording table's order), an Activity tab merging the phone's
 * audit with this Mac's codes.read log, and switches that send agents.grant_set. Words: docs/agent-cli-wording.md.
 */

extension L10n {
    /// Agent devices (ru.lproj/Agents.strings too), kept apart from Localizable.strings like Setup's table.
    static func agents(_ key: String, fallback: String) -> String {
        NSLocalizedString(key, tableName: "Agents", bundle: .main, value: fallback, comment: "")
    }
}

/// What Settings shows for agents: each phone's last agents.state, the changes waiting, the codes.read log, and the
/// phones whose session carries the mirror now (the others are read-only).
struct AgentsDisplay {
    var phones: [String: AgentsMirrorPhoneState] = [:]
    var pending: [String: AgentGrantPending] = [:]
    var codeReads: [AgentCodesReadEntry] = []
    var live: Set<String> = []
}

// MARK: - Words

enum AgentsText {
    static func grantTitle(_ key: AgentGrantKey) -> String {
        switch key {
        case .files: L10n.agents("grant.files", fallback: "Send you files")
        case .clipboard: L10n.agents("grant.clipboard", fallback: "Set your clipboard")
        case .clipboardRequest: L10n.agents("grant.clipboard_request", fallback: "Ask for your clipboard")
        case .notify: L10n.agents("grant.notify", fallback: "Send you notifications")
        case .ask: L10n.agents("grant.ask", fallback: "Ask you questions")
        case .ring: L10n.agents("grant.ring", fallback: "Ring this phone")
        case .battery: L10n.agents("grant.battery", fallback: "See battery")
        case .codes: L10n.agents("grant.codes", fallback: "Read codes")
        case .codesDetect: L10n.agents("grant.codes_detect", fallback: "Detect codes")
        case .notifications: L10n.agents("grant.notifications", fallback: "Read your notifications")
        }
    }

    /// The detail line. Files names its folder: the grant's scope, or the agent's folder under Download/Bridgey.
    static func grantDetail(_ key: AgentGrantKey, agent: AgentDevice) -> String {
        switch key {
        case .files:
            if let scope = agent.grant(.files)?.scope, !scope.isEmpty {
                let prefix = "Download/Bridgey/"
                let name = scope.hasPrefix(prefix) ? String(scope.dropFirst(prefix.count)) : scope
                return String(format: L10n.agents("grant.files.detail", fallback: "To Download/Bridgey/%1$@"), name)
            }
            return String(format: L10n.agents("grant.files.detail", fallback: "To Download/Bridgey/%1$@"), agent.name)
        case .clipboard: return L10n.agents("grant.clipboard.detail", fallback: "Text it copies lands on this phone")
        case .clipboardRequest: return L10n.agents("grant.clipboard_request.detail", fallback: "You tap Send each time")
        case .notify: return L10n.agents("grant.notify.detail", fallback: "In Agent messages")
        case .ask: return L10n.agents("grant.ask.detail", fallback: "In Agent questions, with answer buttons")
        case .ring: return L10n.agents("grant.ring.detail", fallback: "Stops by itself after 60 seconds")
        case .battery: return L10n.agents("grant.battery.detail", fallback: "Level and charging")
        case .codes: return L10n.agents("grant.codes.detail", fallback: "One-time codes your Mac finds in messages and mail")
        case .codesDetect: return L10n.agents("grant.codes_detect.detail", fallback: "Reads your code messages when no Mac is reading")
        case .notifications: return L10n.agents("grant.notifications.detail", fallback: "Not available yet")
        }
    }

    static func window(_ window: AgentGrantWindow) -> String {
        switch window {
        case .oneHour: L10n.agents("window.1h", fallback: "For 1 hour")
        case .today: L10n.agents("window.today", fallback: "Today")
        case .sevenDays: L10n.agents("window.7d", fallback: "7 days")
        case .forever: L10n.agents("window.forever", fallback: "Until I turn it off")
        }
    }

    /// "On until 15:40", "On until you turn it off", "Waiting for you" or "Off".
    static func state(_ grant: AgentGrant?, now: Date, calendar: Calendar = .current) -> String {
        guard let grant else { return L10n.agents("state.off", fallback: "Off") }
        if grant.state == .waiting { return L10n.agents("state.waiting", fallback: "Waiting for you") }
        guard grant.isOn(at: now) else { return L10n.agents("state.off", fallback: "Off") }
        guard let expires = grant.expiresAt, grant.window != .forever else {
            return L10n.agents("until.forever", fallback: "On until you turn it off")
        }
        let end = Date(timeIntervalSince1970: TimeInterval(expires) / 1000)
        return String(format: L10n.agents("until.time", fallback: "On until %1$@"), time(end, now: now, calendar: calendar))
    }

    /// "15:40" today, "4 Nov, 15:40" on another day, in this Mac's locale.
    static func time(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "jmm" : "dMMMjmm")
        return formatter.string(from: date)
    }

    static func subtitle(_ agent: AgentDevice) -> String {
        let os = agent.os.isEmpty ? agent.platform : agent.os
        return String(format: L10n.agents("agent.subtitle", fallback: "Command-line agent on %1$@"), os)
    }

    /// "Online", or the route the phone reaches it by ("Relay", "Same Wi-Fi"); "Offline".
    static func presence(_ agent: AgentDevice) -> String {
        guard agent.online else { return L10n.agents("mac.offline", fallback: "Offline") }
        return connectRouteChipText(tunnelRoute: agent.route, relay: nil, legacy: .unknown) ?? L10n.agents("mac.online", fallback: "Online")
    }

    /// An audit action's words. A lookup, not a switch: the actions look like message kinds, and the protocol
    /// contract scan reads every `case "a.b":` line as one.
    static func action(_ action: String) -> String {
        let words: [String: String] = [
            "pair": L10n.agents("activity.pair", fallback: "Paired"),
            "grant.change": L10n.agents("activity.grant.change", fallback: "Permission changed"),
            "grant.request": L10n.agents("activity.grant.request", fallback: "Asked for permission"),
            "grant.expired": L10n.agents("activity.grant.expired", fallback: "Permission ended"),
            "notify": L10n.agents("activity.notify", fallback: "Sent a notification"),
            "ask": L10n.agents("activity.ask", fallback: "Asked a question"),
            "answer": L10n.agents("activity.answer", fallback: "Got your answer"),
            "ring": L10n.agents("activity.ring", fallback: "Rang this phone"),
            "ping": L10n.agents("activity.ping", fallback: "Checked the connection"),
            "battery": L10n.agents("activity.battery", fallback: "Saw battery"),
            "clipboard.set": L10n.agents("activity.clipboard.set", fallback: "Set your clipboard"),
            "clipboard.request": L10n.agents("activity.clipboard.request", fallback: "Asked for your clipboard"),
            "files.receive": L10n.agents("activity.files.receive", fallback: "Sent you files"),
            "codes.read": L10n.agents("activity.codes.read.any", fallback: "Read a code"),
            "codes.detect": L10n.agents("activity.codes.detect", fallback: "Read a code message"),
            "forget": L10n.agents("activity.forget", fallback: "Forgotten"),
        ]
        return words[action] ?? action
    }

    /// The outcome when it is worth a word; ok and delivered say nothing.
    static func outcome(_ outcome: String) -> String? {
        if outcome.hasPrefix("answered:") {
            return String(format: L10n.agents("activity.outcome.answered", fallback: "Answered: %1$@"), String(outcome.dropFirst("answered:".count)))
        }
        switch outcome {
        case "declined": return L10n.agents("activity.outcome.declined", fallback: "Declined")
        case "dismissed": return L10n.agents("activity.outcome.dismissed", fallback: "Dismissed")
        case "expired": return L10n.agents("activity.outcome.expired", fallback: "Expired")
        case "rate_limited": return L10n.agents("activity.outcome.rate_limited", fallback: "Too many requests")
        case "not_granted": return L10n.agents("activity.outcome.not_granted", fallback: "Not allowed")
        case "invalid": return L10n.agents("activity.outcome.invalid", fallback: "Refused, not a valid request")
        default: return nil
        }
    }

    static func codesRead(_ service: String) -> String {
        service.isEmpty ? L10n.agents("activity.codes.read.any", fallback: "Read a code")
            : String(format: L10n.agents("activity.codes.read", fallback: "Read the code from %1$@"), service)
    }

    static func count(_ count: Int) -> String {
        String(format: L10n.agents("activity.count", fallback: "×%1$d"), count)
    }
}

// MARK: - Activity

/// One row of an agent's Activity tab.
struct AgentActivityRow: Equatable, Identifiable {
    let id: String
    let at: Date
    let title: String
    var detail: String?
    var count: Int?
}

enum AgentActivity {
    /// A phone codes.read entry this close to one in this Mac's log is the same read.
    static let sameReadWindow: TimeInterval = 2

    /// The phone's audit for the agent merged with this Mac's codes.read log, newest first. A read both sides logged
    /// shows once, from this Mac's log (it names the service).
    static func rows(agent: AgentDevice, phoneID: String, reads: [AgentCodesReadEntry]) -> [AgentActivityRow] {
        let mine = reads.filter { $0.phoneID == phoneID && $0.agentID == agent.deviceId }
        var rows = mine.map {
            AgentActivityRow(id: "mac-\($0.id)", at: $0.at, title: AgentsText.codesRead($0.service), count: $0.count > 1 ? $0.count : nil)
        }
        for (index, entry) in agent.activity.enumerated() {
            let at = Date(timeIntervalSince1970: TimeInterval(entry.at) / 1000)
            if entry.action == "codes.read", mine.contains(where: { abs($0.at.timeIntervalSince(at)) <= sameReadWindow }) { continue }
            let detail = [entry.detail.flatMap { $0.isEmpty ? nil : $0 }, AgentsText.outcome(entry.outcome)].compactMap { $0 }
            rows.append(AgentActivityRow(id: "phone-\(index)-\(entry.at)", at: at, title: AgentsText.action(entry.action),
                                         detail: detail.isEmpty ? nil : detail.joined(separator: " \u{00B7} ")))
        }
        return rows.sorted { $0.at > $1.at }
    }
}

// MARK: - Views

/// "Agents on <phone>" under that phone's card. Hidden while the phone has no agents.
struct AgentsOnPhoneCard: View {
    let phoneID: String
    let phoneName: String
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        if let state = model.agents.phones[phoneID], !state.agents.isEmpty {
            let live = model.agents.live.contains(phoneID)
            SettingsCard(title: String(format: L10n.agents("mac.section", fallback: "Agents on %1$@"), phoneName),
                         footnote: live ? note : String(format: L10n.agents("mac.lastKnown", fallback: "%1$@ is not connected. This is the last state it sent."), phoneName) + " " + note) {
                ForEach(Array(state.agents.enumerated()), id: \.element.id) { index, agent in
                    AgentBlock(agent: agent, phoneID: phoneID, phoneName: phoneName, live: live, divider: index > 0,
                               startsOpen: index == 0, model: model, actions: actions)
                        .settingsSearchScope("agent:\(phoneID):\(agent.deviceId)")
                }
            }
        }
    }

    private var note: String { L10n.agents("mac.note", fallback: "Permissions live on the phone. Changes here apply there.") }
}

private enum AgentTab: CaseIterable {
    case permissions, activity

    var title: String {
        switch self {
        case .permissions: L10n.agents("tab.permissions", fallback: "Permissions")
        case .activity: L10n.agents("tab.activity", fallback: "Activity")
        }
    }
}

/// One agent: its header (opens and closes the rest) and the Permissions and Activity tabs.
private struct AgentBlock: View {
    let agent: AgentDevice
    let phoneID: String
    let phoneName: String
    let live: Bool
    let divider: Bool
    let model: SettingsModel
    let actions: SettingsActions
    @State private var open: Bool
    @State private var tab: AgentTab = .permissions
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.settingsSearchHighlight) private var highlight
    @Environment(\.settingsSearchScope) private var scope

    init(agent: AgentDevice, phoneID: String, phoneName: String, live: Bool, divider: Bool, startsOpen: Bool,
         model: SettingsModel, actions: SettingsActions) {
        self.agent = agent
        self.phoneID = phoneID
        self.phoneName = phoneName
        self.live = live
        self.divider = divider
        self.model = model
        self.actions = actions
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    AgentTabs(tab: $tab)
                    Group {
                        switch tab {
                        case .permissions: permissions
                        case .activity: activity
                        }
                    }
                    .id(tab)
                    .transition(.opacity)
                }
                .padding(.bottom, 10)
                .transition(reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            }
        }
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
        .onAppear { openForSearch(highlight) }
        .onChange(of: highlight) { openForSearch($0) }
    }

    /// A search result in this agent: open it on Permissions, so the row is there to scroll to.
    private func openForSearch(_ target: SettingsSearchTarget?) {
        guard let target, target.scope == scope else { return }
        tab = .permissions
        if !open { withAnimation(BrandMotion.animation(BrandMotion.page, reduce: reduce)) { open = true } }
    }

    private var header: some View {
        Button {
            withAnimation(BrandMotion.animation(BrandMotion.page, reduce: reduce)) { open.toggle() }
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "terminal", tint: .purple, size: 32, corner: 9)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(BrandFont.body(13, .medium))
                            .foregroundStyle(c.on)
                            .lineLimit(1)
                        AgentBadge()
                    }
                    Text(AgentsText.subtitle(agent))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AgentPresence(agent: agent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(c.on2)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(AgentHeaderPressStyle())
        .settingsSearchAnchor(agent.name)
        .accessibilityLabel(agent.name)
        .accessibilityHint(open ? L10n.agents("mac.hide", fallback: "Hide permissions and activity")
                                : L10n.agents("mac.show", fallback: "Show permissions and activity"))
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.agents("section", fallback: "What this agent can do"))
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(c.on2)
                .padding(.bottom, 2)
            ForEach(AgentGrantKey.allCases, id: \.self) { key in
                AgentGrantRow(agent: agent, key: key, phoneID: phoneID, phoneName: phoneName, live: live,
                              pending: model.agents.pending[AgentsMirror.pendingKey(phone: phoneID, agent: agent.deviceId, key: key)],
                              now: model.now, actions: actions)
            }
        }
    }

    @ViewBuilder private var activity: some View {
        let rows = AgentActivity.rows(agent: agent, phoneID: phoneID, reads: model.agents.codeReads)
        if rows.isEmpty {
            Text(L10n.agents("empty", fallback: "Nothing yet"))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.prefix(100).enumerated()), id: \.element.id) { index, row in
                    AgentActivityRowView(row: row, now: model.now, divider: index > 0)
                }
            }
        }
    }
}

/// A wide row dims a little while pressed (a full-width scale would jump); reduced motion keeps it still.
private struct AgentHeaderPressStyle: ButtonStyle {
    @Environment(\.brandReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduce ? 0.99 : 1)
            .animation(reduce ? nil : BrandMotion.small, value: configuration.isPressed)
    }
}

/// "Agent", next to the name.
private struct AgentBadge: View {
    @Environment(\.brand) private var c

    var body: some View {
        Text(L10n.agents("agent.badge", fallback: "Agent"))
            .font(BrandFont.body(10, .semibold))
            .foregroundStyle(c.tpi)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(c.tp))
            .fixedSize()
    }
}

/// Online with its route, or Offline.
private struct AgentPresence: View {
    let agent: AgentDevice
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(agent.online ? c.good : c.ol)
                .frame(width: 7, height: 7)
            Text(AgentsText.presence(agent))
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(agent.online ? c.on : c.on2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(c.s3))
        .fixedSize()
    }
}

/// Permissions and Activity, a capsule whose selection slides between them.
private struct AgentTabs: View {
    @Binding var tab: AgentTab
    @Namespace private var selection
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { tab = item }
                } label: {
                    Text(item.title)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(tab == item ? c.on : c.on2)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background {
                            if tab == item {
                                Capsule().fill(c.s1).matchedGeometryEffect(id: "tab", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(c.s3))
    }
}

/// One permission: title, detail, state and a switch. Turning it on asks how long first.
private struct AgentGrantRow: View {
    let agent: AgentDevice
    let key: AgentGrantKey
    let phoneID: String
    let phoneName: String
    let live: Bool
    let pending: AgentGrantPending?
    let now: Date
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        let grant = agent.grant(key)
        let isOn = AgentsMirrorRules.shownOn(grant, pending: pending, now: now)
        Toggle(isOn: Binding(get: { isOn }, set: { change($0) })) {
            HStack(spacing: 10) {
                RowText(title: AgentsText.grantTitle(key), subtitle: AgentsText.grantDetail(key, agent: agent))
                Text(pending == nil ? AgentsText.state(grant, now: now)
                                    : String(format: L10n.agents("mac.pending", fallback: "Changing on %1$@"), phoneName))
                    .font(BrandFont.body(12, .medium))
                    .foregroundStyle(grant?.state == .waiting && pending == nil ? c.tpi : c.on2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 200, alignment: .trailing)
                    .animation(nil, value: pending)
            }
        }
        .toggleStyle(BrandSwitchStyle())
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .settingsSearchAnchor(AgentsText.grantTitle(key))
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
        .opacity(pending == nil ? 1 : 0.7)
        .disabled(!live || !key.changeableFromMac || pending != nil)
    }

    private func change(_ on: Bool) {
        guard on else {
            actions.setAgentGrant(phoneID, agent.deviceId, key, false, nil)
            return
        }
        var items = [PopUpMenuItem(title: L10n.agents("window.ask", fallback: "How long?"), enabled: false, action: {})]
        for window in AgentGrantWindow.allCases {
            items.append(PopUpMenuItem(title: AgentsText.window(window)) {
                actions.setAgentGrant(phoneID, agent.deviceId, key, true, window)
            })
        }
        PopUpMenuPresenter.show(items)
    }
}

private struct AgentActivityRowView: View {
    let row: AgentActivityRow
    let now: Date
    let divider: Bool
    @Environment(\.brand) private var c

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RowText(title: row.title, subtitle: row.detail)
            if let count = row.count {
                Text(AgentsText.count(count))
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.tbi)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(c.tb))
            }
            Text(AgentsText.time(row.at, now: now))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .overlay(alignment: .top) { if divider { Rectangle().fill(c.olv).frame(height: 1) } }
    }
}
