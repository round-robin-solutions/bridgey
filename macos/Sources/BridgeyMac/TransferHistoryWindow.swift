import AppKit
import SwiftUI

// Files 2.0: the History window. Every finished send, receive, download and upload of the last 30 days from
// TransferHistoryStore, grouped by day, with search, filters and Show in Finder.

@MainActor
enum TransferHistoryWindowController {
    private static var window: NSWindow?

    static func show(pairing: PairingCoordinator) {
        if window == nil {
            let root = TransferHistoryLiveView(store: pairing.transferHistory)
            let created = NSWindow(contentViewController: NSHostingController(rootView: root))
            created.title = L10n.text("history.window", fallback: "Transfer History")
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            created.setContentSize(TransferHistoryView.size)
            created.minSize = NSSize(width: 560, height: 360)
            created.setFrameAutosaveName("BridgeyTransferHistoryWindow")
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct TransferHistoryLiveView: View {
    @ObservedObject var store: TransferHistoryStore
    @State private var filter = TransferHistoryFilter()
    @AppStorage("settings.reduceMotion") private var reduceMotion = false

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            TransferHistoryView(entries: store.entries, filter: $filter,
                                showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                                exists: { FileManager.default.fileExists(atPath: $0.path) },
                                remove: { store.remove($0) },
                                clear: { store.clear() })
        }
        .ignoresSafeArea()
        .onAppear { store.prune() }
    }
}

struct TransferHistoryView: View {
    let entries: [TransferHistoryEntry]
    @Binding var filter: TransferHistoryFilter
    var showInFinder: (URL) -> Void = { _ in }
    var exists: (URL) -> Bool = { _ in true }
    var remove: (String) -> Void = { _ in }
    var clear: () -> Void = {}
    var now = Date()
    @State private var confirmClear = false
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    static let size = CGSize(width: 760, height: 560)

    var body: some View {
        let shown = entries.filter(filter.matches)
        VStack(spacing: 0) {
            header
            filters
            Rectangle().fill(c.olv).frame(height: 1)
            if entries.isEmpty {
                PhoneFilesMessage(symbol: "clock.arrow.circlepath", title: L10n.text("history.empty", fallback: "No transfers yet"),
                                  detail: L10n.text("history.empty.detail", fallback: "Files and folders you send or receive show here for 30 days."))
            } else if shown.isEmpty {
                PhoneFilesMessage(symbol: "magnifyingglass", title: L10n.text("history.noMatch", fallback: "Nothing matches"), detail: nil)
            } else {
                list(shown)
            }
        }
        .background(c.bg)
        .confirmationDialog(L10n.text("history.clear.title", fallback: "Clear transfer history?"), isPresented: $confirmClear) {
            Button(L10n.text("history.clear", fallback: "Clear History"), role: .destructive, action: clear)
        } message: {
            Text(L10n.text("history.clear.body", fallback: "Files stay where they are; only this list is cleared."))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.text("history.window", fallback: "Transfer History"))
                .font(BrandFont.heading(20))
                .foregroundStyle(c.on)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(c.on2)
                if snapshot {
                    Text(filter.query.isEmpty ? L10n.text("history.search", fallback: "Search names and devices") : filter.query)
                        .foregroundStyle(filter.query.isEmpty ? c.on2 : c.on)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(L10n.text("history.search", fallback: "Search names and devices"), text: $filter.query)
                        .textFieldStyle(.plain)
                }
            }
            .font(BrandFont.body(13))
            .padding(.horizontal, 12)
            .frame(width: 260, height: 30)
            .background(Capsule().fill(c.s2))
            Button(L10n.text("history.clear", fallback: "Clear History")) { confirmClear = true }
                .buttonStyle(PillButtonStyle(kind: .neutral, height: 30))
                .disabled(entries.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
        .padding(.bottom, 10)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            chip(directionTitle, active: filter.direction != nil) {
                [PopUpMenuItem(title: L10n.text("history.filter.all", fallback: "Sent and received"), checked: filter.direction == nil) { filter.direction = nil }]
                    + TransferHistoryEntry.Direction.allCases.map { direction in
                        PopUpMenuItem(title: Self.title(direction), checked: filter.direction == direction) { filter.direction = direction }
                    }
            }
            chip(deviceTitle, active: filter.deviceID != nil) {
                [PopUpMenuItem(title: L10n.text("history.filter.devices", fallback: "All devices"), checked: filter.deviceID == nil) { filter.deviceID = nil }]
                    + devices.map { device in
                        PopUpMenuItem(title: device.name, checked: filter.deviceID == device.id) { filter.deviceID = device.id }
                    }
            }
            chip(outcomeTitle, active: filter.outcome != nil) {
                [PopUpMenuItem(title: L10n.text("history.filter.outcomes", fallback: "Any result"), checked: filter.outcome == nil) { filter.outcome = nil }]
                    + TransferHistoryEntry.Outcome.allCases.map { outcome in
                        PopUpMenuItem(title: Self.title(outcome), checked: filter.outcome == outcome) { filter.outcome = outcome }
                    }
            }
            Button { filter.foldersOnly.toggle() } label: {
                chipLabel(L10n.text("history.filter.folders", fallback: "Folders only"), active: filter.foldersOnly, menu: false)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func chip(_ title: String, active: Bool, items: @escaping () -> [PopUpMenuItem]) -> some View {
        PopUpMenuButton(items: items) { chipLabel(title, active: active, menu: true) }
    }

    private func chipLabel(_ title: String, active: Bool, menu: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title).font(BrandFont.body(12, .medium))
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .foregroundStyle(active ? c.tbi : c.on)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(active ? c.tb : c.s2))
        .contentShape(Capsule())
    }

    private var directionTitle: String { filter.direction.map(Self.title) ?? L10n.text("history.filter.all", fallback: "Sent and received") }
    private var outcomeTitle: String { filter.outcome.map(Self.title) ?? L10n.text("history.filter.outcomes", fallback: "Any result") }
    private var deviceTitle: String {
        filter.deviceID.flatMap { id in devices.first { $0.id == id }?.name } ?? L10n.text("history.filter.devices", fallback: "All devices")
    }

    private var devices: [(id: String, name: String)] {
        var seen = Set<String>()
        return entries.compactMap { entry in seen.insert(entry.deviceID).inserted ? (entry.deviceID, entry.deviceName) : nil }
    }

    @ViewBuilder private func list(_ shown: [TransferHistoryEntry]) -> some View {
        let groups = Self.groups(shown, now: now)
        let content = LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.title) { group in
                Text(group.title)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.on2)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 12)
                ForEach(group.entries) { entry in
                    HistoryRow(entry: entry, now: now, available: entry.localURL.map(exists) ?? false,
                               showInFinder: showInFinder, remove: remove)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 16)
        if snapshot {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { content }
        }
    }

    struct Group {
        let title: String
        let entries: [TransferHistoryEntry]
    }

    static func groups(_ entries: [TransferHistoryEntry], now: Date) -> [Group] {
        let calendar = Calendar.current
        var groups: [Group] = []
        for entry in entries {
            let title = PhoneFilesText.day(entry.date, now: now)
            if let last = groups.last, calendar.isDate(last.entries[0].date, inSameDayAs: entry.date) {
                groups[groups.count - 1] = Group(title: last.title, entries: last.entries + [entry])
            } else {
                groups.append(Group(title: groups.contains { $0.title == title } ? title + " " : title, entries: [entry]))
            }
        }
        return groups
    }

    static func title(_ direction: TransferHistoryEntry.Direction) -> String {
        switch direction {
        case .sent: L10n.text("history.filter.sent", fallback: "Sent")
        case .received: L10n.text("history.filter.received", fallback: "Received")
        }
    }

    static func title(_ outcome: TransferHistoryEntry.Outcome) -> String {
        switch outcome {
        case .completed: L10n.text("history.outcome.completed", fallback: "Completed")
        case .incomplete: L10n.text("history.outcome.incomplete", fallback: "Incomplete")
        case .failed: L10n.text("history.outcome.failed", fallback: "Failed")
        case .cancelled: L10n.text("history.outcome.cancelled", fallback: "Cancelled")
        }
    }
}

private struct HistoryRow: View {
    let entry: TransferHistoryEntry
    let now: Date
    let available: Bool
    let showInFinder: (URL) -> Void
    let remove: (String) -> Void
    @State private var hovering = false
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 34, corner: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(BrandFont.body(11))
                    .foregroundStyle(entry.outcome == .completed ? c.on2 : c.warn)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(DateFormatter.localizedString(from: entry.date, dateStyle: .none, timeStyle: .short))
                .font(BrandFont.body(11).monospacedDigit())
                .foregroundStyle(c.on2)
            Button(L10n.text("phonefiles.showInFinder", fallback: "Show in Finder")) {
                if let url = entry.localURL { showInFinder(url) }
            }
            .buttonStyle(PillButtonStyle(kind: .neutral, height: 26))
            .disabled(!available)
            .help(available ? "" : L10n.text("history.gone", fallback: "This item is no longer on this Mac"))
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? c.s2 : Color.clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L10n.text("history.remove", fallback: "Remove from History")) { remove(entry.id) }
        }
    }

    private var symbol: String {
        if entry.outcome != .completed { return "exclamationmark.arrow.triangle.2.circlepath" }
        if entry.isFolder { return entry.direction == .sent ? "folder.badge.plus" : "folder" }
        return entry.direction == .sent ? "arrow.up.right" : "arrow.down.left"
    }

    private var tint: TileTint {
        if entry.outcome != .completed { return .neutral }
        return entry.direction == .sent ? .blue : .green
    }

    private var detail: String {
        var parts: [String] = []
        let device = entry.direction == .sent
            ? String(format: L10n.text("history.to", fallback: "To %@"), entry.deviceName)
            : String(format: L10n.text("history.from", fallback: "From %@"), entry.deviceName)
        parts.append(entry.destination.map { "\(device) › \($0)" } ?? device)
        if entry.isFolder { parts.append(String(format: L10n.text("history.files", fallback: "%d files"), entry.fileCount)) }
        parts.append(PhoneFilesText.size(entry.bytes))
        if entry.outcome != .completed { parts.append(TransferHistoryView.title(entry.outcome)) }
        if entry.download { parts.append(L10n.text("history.download", fallback: "Downloaded")) }
        return parts.joined(separator: " · ")
    }
}
