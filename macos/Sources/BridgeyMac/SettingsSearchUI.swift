import AppKit
import Combine
import SwiftUI

/*
 * Settings search on the Mac, as in System Settings: a field at the top of the sidebar (Command-F), results
 * grouped by pane in place of the pane list (Up, Down, Return, Escape), and the chosen row scrolled to the
 * middle of its pane and briefly highlighted. Rows find themselves by title: SettingsRow and SettingsToggle
 * carry a search anchor, so any row a pane draws can be the target. The matching is SettingsSearch.swift; the
 * rows it knows are SettingsSearchRegistry.swift.
 */

/// What a chosen result points at: a pane, and the row in it to show (by title, inside a device's or an
/// agent's card when `scope` is set). `token` makes choosing the same row again highlight it again.
struct SettingsSearchTarget: Equatable {
    var pane: SettingsPane
    var scope: String?
    var title: String?
    var token = UUID()
}

/// A row's place in a pane, for scrolling to it.
struct SearchAnchorID: Hashable {
    let scope: String?
    let title: String
}

/// Collects the rows a pane draws, for the registry's drift test. Nil in the app.
final class SettingsSearchRecorder {
    private(set) var rows: [SearchAnchorID] = []
    private var seen = Set<SearchAnchorID>()

    func record(_ id: SearchAnchorID) {
        if seen.insert(id).inserted { rows.append(id) }
    }
}

private struct SearchScopeKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct SearchHighlightKey: EnvironmentKey { static let defaultValue: SettingsSearchTarget? = nil }
private struct SearchRecorderKey: EnvironmentKey { static let defaultValue: SettingsSearchRecorder? = nil }
private struct SearchSkipKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The device or agent card a row sits in ("<device id>", "agent:<id>"), so rows with the same title in
    /// different cards stay apart.
    var settingsSearchScope: String? {
        get { self[SearchScopeKey.self] }
        set { self[SearchScopeKey.self] = newValue }
    }

    /// The row to highlight, set while a search result is being shown.
    var settingsSearchHighlight: SettingsSearchTarget? {
        get { self[SearchHighlightKey.self] }
        set { self[SearchHighlightKey.self] = newValue }
    }

    var settingsSearchRecorder: SettingsSearchRecorder? {
        get { self[SearchRecorderKey.self] }
        set { self[SearchRecorderKey.self] = newValue }
    }

    /// Rows that are a status or a list item, not a setting (an empty list, a log line): not offered by search.
    var settingsSearchSkip: Bool {
        get { self[SearchSkipKey.self] }
        set { self[SearchSkipKey.self] = newValue }
    }
}

extension View {
    /// Makes this view a row search can scroll to and highlight, found by `title`.
    func settingsSearchAnchor(_ title: String) -> some View { modifier(SettingsSearchAnchor(title: title)) }

    /// Rows inside are a status or a list item, not settings: search neither offers nor records them.
    func settingsSearchSkip(_ skip: Bool = true) -> some View { environment(\.settingsSearchSkip, skip) }

    /// Rows inside belong to this device's or agent's card.
    func settingsSearchScope(_ scope: String) -> some View { environment(\.settingsSearchScope, scope) }
}

struct SettingsSearchAnchor: ViewModifier {
    let title: String
    @Environment(\.settingsSearchScope) private var scope
    @Environment(\.settingsSearchHighlight) private var highlight
    @Environment(\.settingsSearchRecorder) private var recorder
    @Environment(\.settingsSearchSkip) private var skip

    func body(content: Content) -> some View {
        if skip || title.isEmpty {
            content
        } else {
            let id = SearchAnchorID(scope: scope, title: title)
            let _ = recorder?.record(id)
            let target = highlight.flatMap { $0.title == title && $0.scope == scope ? $0 : nil }
            content
                .background(alignment: .center) {
                    if let target { SearchPulse(token: target.token).padding(.horizontal, -10) }
                }
                .id(id)
        }
    }
}

/// The highlight behind a found row: a tint that pulses twice and fades, about 1.6 s, opacity only. With
/// Reduce motion it holds still, then fades once. Screenshots show it at full strength.
struct SearchPulse: View {
    let token: UUID
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot
    @State private var strength: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(c.tb)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(c.pri.opacity(0.55), lineWidth: 1.5))
            .opacity(snapshot ? 1 : strength)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: token) { await run() }
    }

    @MainActor private func run() async {
        guard !snapshot else { return }
        strength = 0
        let steps: [(Double, Double, UInt64)] = reduce
            ? [(1, 0.0, 1_300), (0, 0.3, 300)]
            : [(1, 0.2, 260), (0.35, 0.3, 300), (1, 0.3, 360), (0, 0.6, 600)]
        for (value, duration, wait) in steps {
            if duration == 0 {
                strength = value
            } else {
                withAnimation(.easeInOut(duration: duration)) { strength = value }
            }
            try? await Task.sleep(nanoseconds: wait * 1_000_000)
            if Task.isCancelled { return }
        }
    }
}

// MARK: - Results

/// One result row: the entry it came from and what to mark in it.
struct SettingsSearchRow: Identifiable, Equatable {
    let entry: SettingsSearchEntry
    let titleRanges: [Range<Int>]
    /// The subtitle to show under the breadcrumb when only it matched.
    let subtitle: String?
    let subtitleRanges: [Range<Int>]
    var id: String { entry.id }

    static func == (lhs: SettingsSearchRow, rhs: SettingsSearchRow) -> Bool { lhs.id == rhs.id && lhs.titleRanges == rhs.titleRanges }
}

/// Results grouped by sidebar item, in the order of each item's best row.
struct SettingsSearchGroup: Identifiable, Equatable {
    let pane: SettingsPane
    let rows: [SettingsSearchRow]
    var id: String { pane.rawValue }
}

struct SettingsSearchOutcome: Equatable {
    var groups: [SettingsSearchGroup] = []
    /// "No results": the closest rows instead.
    var closest: [SettingsSearchRow] = []

    var rows: [SettingsSearchRow] { groups.flatMap(\.rows) }
    var isEmpty: Bool { groups.isEmpty }
    /// What Up, Down and Return move through: the results, or the closest rows.
    var choosable: [SettingsSearchRow] { isEmpty ? closest : rows }

    static func run(_ query: String, entries: [SettingsSearchEntry]) -> SettingsSearchOutcome {
        let docs = entries.map(\.doc)
        let hits = SettingsSearch.search(query, in: docs)
        if hits.isEmpty {
            let closest = SettingsSearch.closest(query, in: docs).map {
                SettingsSearchRow(entry: entries[$0], titleRanges: [], subtitle: nil, subtitleRanges: [])
            }
            return SettingsSearchOutcome(groups: [], closest: closest)
        }
        var order: [SettingsPane] = []
        var byPane: [SettingsPane: [SettingsSearchRow]] = [:]
        for hit in hits {
            let entry = entries[hit.index]
            let showsSubtitle = hit.titleRanges.isEmpty && !hit.subtitleRanges.isEmpty
            let row = SettingsSearchRow(entry: entry, titleRanges: hit.titleRanges,
                                        subtitle: showsSubtitle ? entry.subtitle : nil,
                                        subtitleRanges: showsSubtitle ? hit.subtitleRanges : [])
            // Sub-pages (Connect away from home, Permissions, Reset) join the sidebar item they open from.
            let group = entry.pane.sidebarPane
            if byPane[group] == nil { order.append(group) }
            byPane[group, default: []].append(row)
        }
        return SettingsSearchOutcome(groups: order.map { SettingsSearchGroup(pane: $0, rows: byPane[$0] ?? []) })
    }
}

/// Text with the matched characters in bold and the accent colour.
func searchHighlighted(_ text: String, _ ranges: [Range<Int>], accent: Color) -> Text {
    guard !ranges.isEmpty else { return Text(text) }
    let characters = Array(text)
    var result = Text("")
    var cursor = 0
    for range in ranges where range.lowerBound >= cursor && range.upperBound <= characters.count {
        if range.lowerBound > cursor { result = result + Text(String(characters[cursor..<range.lowerBound])) }
        result = result + Text(String(characters[range])).bold().foregroundColor(accent)
        cursor = range.upperBound
    }
    if cursor < characters.count { result = result + Text(String(characters[cursor...])) }
    return result
}

// MARK: - Sidebar pieces

/// The sidebar's search field, styled as the sidebar's own rows.
struct SettingsSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    /// Drawn as focused (the field has the keyboard, or a screenshot shows it typing).
    var showsFocus = false
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(c.on2)
            if snapshot {
                // ImageRenderer cannot draw an AppKit text field: screenshots show its text and caret instead.
                HStack(spacing: 1) {
                    Text(query.isEmpty ? L10n.text("settings.search", fallback: "Search") : query)
                        .font(BrandFont.body(13))
                        .foregroundStyle(query.isEmpty ? c.on2 : c.on)
                    if showsFocus { Rectangle().fill(c.pri).frame(width: 1.5, height: 15) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $query, prompt: Text(L10n.text("settings.search", fallback: "Search")).foregroundColor(c.on2))
                    .textFieldStyle(.plain)
                    .font(BrandFont.body(13))
                    .foregroundStyle(c.on)
                    .focused(focused)
                    .accessibilityLabel(L10n.text("settings.search.label", fallback: "Search settings"))
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(c.on2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("settings.search.clear", fallback: "Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(showsFocus ? c.pri.opacity(0.7) : c.ol.opacity(0.6), lineWidth: 1))
    }
}

/// The results in place of the pane list: a heading per pane, then its rows.
struct SettingsSearchResultsList: View {
    let query: String
    let outcome: SettingsSearchOutcome
    let selected: Int
    let open: (SettingsSearchRow) -> Void
    let hover: (Int) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        ScrollViewReader { proxy in
            BoundedScroll {
                VStack(alignment: .leading, spacing: 2) {
                    if outcome.isEmpty {
                        noResults
                    } else {
                        let flat = outcome.rows
                        ForEach(outcome.groups) { group in
                            heading(group.pane)
                            ForEach(group.rows) { row in
                                let index = flat.firstIndex(where: { $0.id == row.id }) ?? 0
                                resultRow(row, index: index, selected: index == selected)
                                    .id(row.id)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selected) { index in
                let flat = outcome.choosable
                if flat.indices.contains(index) { proxy.scrollTo(flat[index].id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("settings.search.results", fallback: "Search results"))
    }

    private func heading(_ pane: SettingsPane) -> some View {
        HStack(spacing: 6) {
            Image(systemName: pane.sidebarPane.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(pane.sidebarPane.sidebarTitle.uppercased())
                .font(BrandFont.body(10, .semibold))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(c.on2)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: L10n.text("settings.search.none", fallback: "No results for \u{201C}%@\u{201D}"), query.trimmingCharacters(in: .whitespaces)))
                .font(BrandFont.body(13, .medium))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            if !outcome.closest.isEmpty {
                Text(L10n.text("settings.search.closest", fallback: "Closest matches").uppercased())
                    .font(BrandFont.body(10, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(c.on2)
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                ForEach(Array(outcome.closest.enumerated()), id: \.element.id) { index, row in
                    resultRow(row, index: index, selected: index == selected)
                        .id(row.id)
                }
            }
        }
    }

    private func resultRow(_ row: SettingsSearchRow, index: Int, selected: Bool) -> some View {
        Button {
            open(row)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                searchHighlighted(row.entry.title, row.titleRanges, accent: c.tbi)
                    .font(BrandFont.body(13, .medium))
                    .foregroundColor(c.on)
                    .lineLimit(2)
                Text(row.entry.breadcrumb)
                    .font(BrandFont.body(11))
                    .foregroundStyle(c.on2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = row.subtitle {
                    searchHighlighted(subtitle, row.subtitleRanges, accent: c.tbi)
                        .font(BrandFont.body(11))
                        .foregroundColor(c.on2)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? c.tb : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { hover(index) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Keys

/// Command-F, and Up, Down, Return and Escape while the search field has the keyboard. A local monitor, as in
/// the Messages window, so the field keeps its normal editing keys; the window acts on `commands`.
@MainActor
final class SettingsSearchKeys: ObservableObject {
    static let windowID = NSUserInterfaceItemIdentifier("bridgey.settings")

    enum Command { case focus, move(Int), submit, clear }

    let commands = PassthroughSubject<Command, Never>()
    var fieldFocused = false
    var hasQuery = false
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window?.identifier == Self.windowID else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            commands.send(.focus)
            return true
        }
        guard flags.isEmpty, fieldFocused, hasQuery else { return false }
        switch event.keyCode {
        case 125: commands.send(.move(1))
        case 126: commands.send(.move(-1))
        case 36, 76: commands.send(.submit)
        case 53: commands.send(.clear)
        default: return false
        }
        return true
    }
}
