import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// The Transfers window's views: header, filter chips, the live card, history by day (a media grid, then rows) and
// the footer. Pure over `TransfersWindowState`, so ImageRenderer screenshots draw the same views as the window.

struct TransferDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// What the window shows apart from the live card's rows and speeds (TransfersLiveFeed), worked out by
/// TransfersWindowModel (or a screenshot fixture). Published only when it changes, so progress does not redraw it.
struct TransfersWindowState: Equatable {
    /// Something is moving or waiting: the live card shows.
    var hasLive = false
    /// Route chips, by device.
    var routes: [String: TransferRouteChip] = [:]
    var items: [TransferItem] = []
    /// Paired devices and devices in the history, for the device menu.
    var devices: [TransferDevice] = []
    /// Connected devices: Send Files and Send to.
    var connected: [TransferDevice] = []
    /// History items whose file is no longer where it was.
    var missing: Set<String> = []
    var today: String?
    /// When the history was last worked out; it decides Today and Yesterday.
    var now = Date()
    /// Screenshot fixtures: thumbnails and video lengths by item, and an item drawn as hovered.
    var previews: [String: NSImage] = [:]
    var durations: [String: String] = [:]
    var hoveredID: String?
}

struct TransfersWindowActions {
    /// Send Files…: the open panel, then the device picker when more than one device is connected.
    var chooseFiles: () -> Void = {}
    var send: ([URL], String) -> Void = { _, _ in }
    var cancel: (String) -> Void = { _ in }
    var retry: (TransferItem) -> Void = { _ in }
    var resume: (String) -> Void = { _ in }
    var open: (URL) -> Void = { _ in }
    var quickLook: (URL) -> Void = { _ in }
    var showInFinder: (URL) -> Void = { _ in }
    var copy: (URL) -> Void = { _ in }
    var remove: (TransferItem) -> Void = { _ in }
    var clear: () -> Void = {}
    var openFolder: () -> Void = {}
}

struct TransfersWindowView: View {
    let state: TransfersWindowState
    /// The live card's rows and speeds. Only the card observes them.
    let live: TransfersLiveFeed
    @Binding var filter: TransfersFilter
    @Binding var selection: String?
    /// Files waiting for the device picker (Send Files… or a drop with more than one device connected).
    @Binding var pendingSend: [URL]?
    var scrollToken = 0
    var actions = TransfersWindowActions()

    @State private var confirmClear = false
    @State private var dropTargeted = false
    @Namespace private var chipSpace
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    static let size = CGSize(width: 820, height: 640)
    static let minimumSize = CGSize(width: 560, height: 420)
    static let headerHeight: CGFloat = 58
    static let inset: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: 0) {
                TransfersHeader(canSend: !state.connected.isEmpty, query: $filter.query, compact: width < 640, choose: actions.chooseFiles)
                if !state.items.isEmpty { filters(width: width) }
                if state.hasLive {
                    // A short window keeps one detailed row, so the history still shows.
                    TransfersLiveCard(feed: live, routes: state.routes, previews: state.previews, durations: state.durations,
                                      limit: proxy.size.height < 520 ? 1 : 2, cancel: actions.cancel)
                        .padding(.horizontal, Self.inset)
                        .transition(liveTransition)
                }
                TransfersHistoryList(items: state.items, filter: filter, selection: selection, missing: state.missing,
                                     connected: state.connected, day: Calendar.current.startOfDay(for: state.now),
                                     width: width - Self.inset * 2, previews: state.previews, durations: state.durations,
                                     hoveredID: state.hoveredID, scrollToken: scrollToken, actions: actions,
                                     select: { selection = $0 }, confirmClear: { confirmClear = true })
                    .equatable()
                footer
            }
            .animation(BrandMotion.animation(BrandMotion.page, reduce: reduce), value: state.hasLive)
        }
        .background(c.bg)
        .overlay { if dropTargeted { dropHighlight.transition(.opacity) } }
        .overlay { overlays }
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: dropTargeted)
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: pendingSend != nil)
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: confirmClear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !state.connected.isEmpty else { return false }
            TransfersDrop.urls(from: providers) { urls in
                guard !urls.isEmpty else { return }
                if state.connected.count == 1 { actions.send(urls, state.connected[0].id) } else { pendingSend = urls }
            }
            return true
        }
    }

    private var liveTransition: AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.98, anchor: .top))
    }

    // MARK: Filters

    private var failedCount: Int { state.items.filter(\.failed).count }

    /// Narrow windows keep every chip and fold the device menu's label into an icon.
    private func filters(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            ForEach(TransfersFilter.Category.allCases, id: \.self) { category in
                if category != .failed || failedCount > 0 || filter.category == .failed {
                    chip(category)
                }
            }
            Spacer(minLength: 12)
            deviceMenu(compact: width < 700)
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 12)
    }

    private func chip(_ category: TransfersFilter.Category) -> some View {
        let selected = filter.category == category
        return Button {
            // Reduce Motion: the indicator jumps instead of sliding.
            withAnimation(reduce ? nil : BrandMotion.small) { filter.category = category }
        } label: {
            HStack(spacing: 6) {
                Text(TransfersText.category(category)).fixedSize()
                if category == .failed {
                    Text(FolderText.number(failedCount)).monospacedDigit().opacity(0.8)
                }
            }
            .font(BrandFont.body(12.5, .medium))
            .foregroundStyle(selected ? c.bg : c.on2)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                if selected {
                    Capsule().fill(c.on).matchedGeometryEffect(id: "chip", in: chipSpace)
                } else {
                    Capsule().strokeBorder(c.ol, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(TransfersPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func deviceMenu(compact: Bool) -> some View {
        PopUpMenuButton(items: deviceItems) {
            HStack(spacing: 6) {
                if compact {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13, weight: .medium))
                } else {
                    Text(deviceTitle).font(BrandFont.body(13, .medium)).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(filter.deviceID != nil || filter.direction != nil ? c.on : c.on2)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .help(deviceTitle)
        .accessibilityLabel(deviceTitle)
    }

    private var deviceTitle: String {
        let device = filter.deviceID.flatMap { id in state.devices.first { $0.id == id }?.name }
        let direction = filter.direction.map { $0 == .received ? L10n.text("history.filter.received", fallback: "Received")
            : L10n.text("history.filter.sent", fallback: "Sent") }
        let parts = [device, direction].compactMap { $0 }
        return parts.isEmpty ? L10n.text("history.filter.devices", fallback: "All devices") : parts.joined(separator: " \u{00B7} ")
    }

    private func deviceItems() -> [PopUpMenuItem] {
        var items = [PopUpMenuItem(title: L10n.text("history.filter.devices", fallback: "All devices"), checked: filter.deviceID == nil) {
            filter.deviceID = nil
        }]
        items += state.devices.map { device in
            PopUpMenuItem(title: device.name, checked: filter.deviceID == device.id) { filter.deviceID = device.id }
        }
        items.append(.separator)
        items.append(PopUpMenuItem(title: L10n.text("transfers.window.receivedOnly", fallback: "Received only"), checked: filter.direction == .received) {
            filter.direction = filter.direction == .received ? nil : .received
        })
        items.append(PopUpMenuItem(title: L10n.text("transfers.window.sentOnly", fallback: "Sent only"), checked: filter.direction == .sent) {
            filter.direction = filter.direction == .sent ? nil : .sent
        })
        return items
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: actions.openFolder) {
                HStack(spacing: 7) {
                    Image(systemName: "folder").font(.system(size: 13, weight: .medium))
                    Text(L10n.text("transfers.window.folder", fallback: "Bridgey Folder")).font(BrandFont.body(13, .medium))
                }
                .foregroundStyle(c.on2)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(TransfersPressStyle(hover: true))
            Spacer(minLength: 8)
            if let today = state.today {
                Text(today)
                    .font(BrandFont.body(12).monospacedDigit())
                    .foregroundStyle(c.on2)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 46)
        .overlay(alignment: .top) { Rectangle().fill(c.panelBorder).frame(height: 1) }
    }

    // MARK: Overlays

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(c.pri.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.pri, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
            .overlay {
                Label(L10n.text("transfers.window.drop", fallback: "Drop to send"), systemImage: "arrow.down.doc")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(c.pri)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Capsule().fill(c.s1))
            }
            .padding(10)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var overlays: some View {
        if let urls = pendingSend {
            TransfersDialog(dismiss: { pendingSend = nil }) {
                TransfersDevicePicker(devices: state.connected, routes: state.routes,
                                      pick: { id in pendingSend = nil; actions.send(urls, id) },
                                      cancel: { pendingSend = nil })
            }
            .transition(.opacity)
        } else if confirmClear {
            TransfersDialog(dismiss: { confirmClear = false }) {
                TransfersClearConfirm(clear: { confirmClear = false; actions.clear() }, cancel: { confirmClear = false })
            }
            .transition(.opacity)
        }
    }
}

// MARK: - History

/// The history by day: a media grid, then rows. Lazy, so only the lines on screen are built, and equatable on what it
/// draws, so the rest of the window redrawing (a transfer starting or ending, today's totals) leaves it alone.
private struct TransfersHistoryList: View, Equatable {
    let items: [TransferItem]
    let filter: TransfersFilter
    let selection: String?
    let missing: Set<String>
    let connected: [TransferDevice]
    /// The start of the day the history was worked out on (Today and Yesterday).
    let day: Date
    let width: CGFloat
    let previews: [String: NSImage]
    let durations: [String: String]
    let hoveredID: String?
    let scrollToken: Int
    let actions: TransfersWindowActions
    let select: (String) -> Void
    let confirmClear: () -> Void
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.locale) private var locale

    /// What it draws. The closures stay out: they call the same coordinator and window model whichever copy runs them.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.filter == rhs.filter && lhs.selection == rhs.selection && lhs.missing == rhs.missing
            && lhs.connected == rhs.connected && lhs.day == rhs.day && lhs.width == rhs.width && lhs.previews == rhs.previews
            && lhs.durations == rhs.durations && lhs.hoveredID == rhs.hoveredID && lhs.scrollToken == rhs.scrollToken
    }

    var body: some View {
        let shown = items.filter(filter.matches)
        if items.isEmpty {
            TransfersEmpty(connected: !connected.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            Text(L10n.text("history.noMatch", fallback: "Nothing matches"))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let columns = TransfersGrid.columns(width: width)
            let lines = TransferHistoryLine.lines(TransferDays.group(shown, now: day, locale: locale), columns: columns)
            TransfersScroll(token: scrollToken) {
                Color.clear.frame(height: 0).id(TransfersScrollAnchor.history)
                ForEach(lines) { line in
                    self.line(line, cardWidth: TransfersGrid.cardWidth(width: width, columns: columns))
                }
            }
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 28)
                }
            }
        }
    }

    @ViewBuilder private func line(_ line: TransferHistoryLine, cardWidth: CGFloat) -> some View {
        switch line {
        case let .title(_, text):
            Text(text)
                .font(BrandFont.body(12, .medium))
                .foregroundStyle(c.on2)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
        case let .grid(_, row, last):
            HStack(spacing: TransfersGrid.gap) {
                ForEach(row) { item in
                    TransferCard(item: item, width: cardWidth, missing: missing.contains(item.id), selected: selection == item.id,
                                 hoveredFixture: hoveredID == item.id, preview: previews[item.id], duration: durations[item.id],
                                 connected: connected, menu: { menuItems(item) }, actions: actions, select: { select(item.id) })
                        .equatable()
                }
            }
            .padding(.bottom, last ? 6 : TransfersGrid.gap)
        case let .row(item):
            TransferHistoryRow(item: item, missing: missing.contains(item.id), selected: selection == item.id,
                               hoveredFixture: hoveredID == item.id, preview: previews[item.id], duration: durations[item.id],
                               connected: connected, menu: { menuItems(item) }, actions: actions, select: { select(item.id) })
                .equatable()
                .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: 6)))
        }
    }

    /// More and the context menu: Open, Quick Look, Show in Finder, Copy, Send to, Retry or Resume, Remove from History,
    /// Clear History.
    private func menuItems(_ item: TransferItem) -> [PopUpMenuItem] {
        let url = item.localURL
        let available = url != nil && !missing.contains(item.id)
        var items: [PopUpMenuItem] = [
            PopUpMenuItem(title: L10n.text("action.open", fallback: "Open"), enabled: available) { if let url { actions.open(url) } },
            PopUpMenuItem(title: L10n.text("phonefiles.quickLook.short", fallback: "Quick Look"), enabled: available) { if let url { actions.quickLook(url) } },
            PopUpMenuItem(title: L10n.text("phonefiles.showInFinder", fallback: "Show in Finder"), enabled: available) { if let url { actions.showInFinder(url) } },
            PopUpMenuItem(title: L10n.text("phonefiles.copy", fallback: "Copy"), enabled: available) { if let url { actions.copy(url) } },
            PopUpMenuItem(title: L10n.text("transfers.window.sendTo", fallback: "Send to"), enabled: available,
                          submenu: connected.map { device in PopUpMenuItem(title: device.name) { if let url { actions.send([url], device.id) } } }) {},
        ]
        if item.canResume {
            items.append(PopUpMenuItem(title: L10n.text("folders.action.resume", fallback: "Resume")) { actions.resume(item.id) })
        } else if item.canRetry {
            items.append(PopUpMenuItem(title: L10n.text("action.retry", fallback: "Retry")) { actions.retry(item) })
        }
        items.append(.separator)
        items.append(PopUpMenuItem(title: L10n.text("history.remove", fallback: "Remove from History")) { actions.remove(item) })
        items.append(PopUpMenuItem(title: L10n.text("transfers.window.clear", fallback: "Clear History…")) { confirmClear() })
        return items
    }
}

// MARK: - Header

private struct TransfersHeader: View {
    /// A device is connected: Send Files works.
    let canSend: Bool
    @Binding var query: String
    let compact: Bool
    let choose: () -> Void
    @FocusState private var searching: Bool
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 14) {
            // The window's own close, minimise and zoom buttons sit here (TransfersNSWindow places them).
            Color.clear.frame(width: 58, height: 1)
            Text(L10n.text("transfers.window.title", fallback: "Transfers"))
                .font(BrandFont.heading(18))
                .tracking(-0.18)
                .foregroundStyle(c.on)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            search
            send
        }
        .padding(.horizontal, TransfersWindowView.inset)
        .frame(height: TransfersWindowView.headerHeight)
        .background { if !snapshot { WindowDragArea() } }
        .background {
            // Command-F goes to search.
            Button("") { searching = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(c.on2)
            if snapshot {
                Text(query.isEmpty ? L10n.text("transfers.window.search", fallback: "Search") : query)
                    .foregroundStyle(query.isEmpty ? c.on2 : c.on)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(L10n.text("transfers.window.search", fallback: "Search"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onExitCommand { query = ""; searching = false }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(c.on2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("action.clear", fallback: "Clear"))
                }
            }
        }
        .font(BrandFont.body(13))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minWidth: compact ? 110 : 150, maxWidth: 190)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.s2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searching ? c.pri : c.ol, lineWidth: searching ? 1.5 : 1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(c.pri.opacity(searching ? 0.25 : 0), lineWidth: 3).padding(-2))
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: searching)
    }

    private var send: some View {
        Button(action: choose) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                Text(L10n.text("transfers.window.send", fallback: "Send Files…")).font(BrandFont.body(13, .semibold))
            }
            .foregroundStyle(c.onpri)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.pri))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(TransfersPressStyle())
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.45)
        .help(canSend ? "" : L10n.text("transfers.window.noDevice", fallback: "Connect a device to send files"))
        .keyboardShortcut("o", modifiers: .command)
    }
}

// MARK: - Live card

/// The live card. It alone observes the feed, so progress redraws it and nothing else.
private struct TransfersLiveCard: View {
    @ObservedObject var feed: TransfersLiveFeed
    let routes: [String: TransferRouteChip]
    let previews: [String: NSImage]
    let durations: [String: String]
    let limit: Int
    let cancel: (String) -> Void
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        let split = TransferLiveList.split(feed.live, limit: limit)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(split.shown.enumerated()), id: \.element.id) { index, live in
                if index > 0 { Rectangle().fill(c.panelBorder).frame(height: 1) }
                TransferLiveRow(live: live, speed: feed.speeds[live.id],
                                route: showsRoute(index, in: split.shown) ? live.deviceID.flatMap { routes[$0] } : nil,
                                preview: previews[live.id], duration: durations[live.id], cancel: { cancel(live.id) })
                    .transition(reduce ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
            if split.waiting > 0 {
                Text(TransfersText.waiting(split.waiting))
                    .font(BrandFont.body(12).monospacedDigit())
                    .foregroundStyle(c.on2)
                    .padding(.leading, 52)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.s1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.panelBorder, lineWidth: 1))
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: feed.live.map(\.id))
    }

    /// The route belongs to the connection, so it shows once per device.
    private func showsRoute(_ index: Int, in shown: [TransferLive]) -> Bool {
        let device = shown[index].deviceID
        return device != nil && !shown.prefix(index).contains { $0.deviceID == device }
    }
}

private struct TransferLiveRow: View {
    let live: TransferLive
    /// The rolling 3 s speed.
    let speed: Double?
    /// The route chip, on the first row of each device.
    let route: TransferRouteChip?
    let preview: NSImage?
    let duration: String?
    let cancel: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TransferThumb(url: live.localURL, name: live.name, kind: live.kind, side: 40, corner: 8, preview: preview,
                              fixedDuration: duration, badge: .bottomTrailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.name)
                        .font(BrandFont.body(13.5, .medium))
                        .foregroundStyle(c.on)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(c.on2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransfersPressStyle(hover: true))
                .help(L10n.text("action.cancel", fallback: "Cancel"))
                .accessibilityLabel(L10n.text("action.cancel", fallback: "Cancel"))
            }
            VStack(alignment: .leading, spacing: 7) {
                if let fraction = live.fraction {
                    AuroraBar(fraction: fraction).padding(.top, 10)
                    stats
                } else {
                    Text(StatusText.localized(live.status))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                        .lineLimit(1)
                        .padding(.top, 8)
                }
            }
            .padding(.leading, 52)
        }
        .accessibilityElement(children: .combine)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if !live.deviceName.isEmpty {
                TransferDirectionIcon(incoming: live.incoming)
                Text(TransfersText.device(live.deviceName, incoming: live.incoming)).lineLimit(1)
            }
            if let route {
                TransferRouteChipView(chip: route)
            }
            if let files = live.fileProgress {
                if !live.deviceName.isEmpty { TransferDot() }
                Text(files).monospacedDigit().lineLimit(1)
            }
        }
        .font(BrandFont.body(12))
        .foregroundStyle(c.on2)
    }

    private var stats: some View {
        let left = TransfersText.timeLeft(remaining: (live.bytesTotal ?? 0) - (live.bytesDone ?? 0), bytesPerSecond: speed)
        return HStack(spacing: 0) {
            TransfersEmphasis.text(L10n.text("transfers.window.bytes", fallback: "%1$@ of %2$@"),
                                   TransfersText.bytes(live.bytesDone ?? 0), TransfersText.bytes(live.bytesTotal ?? 0),
                                   strong: c.on, weak: c.on2)
            Spacer(minLength: 8)
            if let speed, speed > 0 {
                Text(TransfersText.speed(speed)).font(BrandFont.body(12, .medium)).foregroundStyle(c.on)
                if let left {
                    TransferDot().padding(.horizontal, 7)
                    Text(left).foregroundStyle(c.on2)
                }
            }
        }
        .font(BrandFont.body(12).monospacedDigit())
        .lineLimit(1)
    }
}

/// The aurora progress bar. The fill scales from the leading edge (a transform, so only it animates).
private struct AuroraBar: View {
    let fraction: Double
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        Capsule()
            .fill(c.s4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(stops: c.isDark ? BrandPalette.auroraStops : Self.lightStops, startPoint: .leading, endPoint: .trailing))
                    .scaleEffect(x: max(0.001, fraction), anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: 6)
            .animation(reduce ? nil : BrandMotion.small, value: fraction)
            .accessibilityValue(Text("\(Int((fraction * 100).rounded())) %"))
    }

    /// The light theme's deeper aurora, for contrast on white.
    static let lightStops: [Gradient.Stop] = [
        .init(color: Color(hex: 0x6B4FD8), location: 0),
        .init(color: Color(hex: 0x0089B3), location: 0.55),
        .init(color: Color(hex: 0x00915F), location: 1),
    ]
}

// MARK: - Grid and rows

/// The media grid's measures: cards at least 130 pt wide, 10 pt apart, filling the width.
private enum TransfersGrid {
    static let minimum: CGFloat = 130
    static let gap: CGFloat = 10

    static func columns(width: CGFloat) -> Int { max(1, Int((width + gap) / (minimum + gap))) }

    static func cardWidth(width: CGFloat, columns: Int) -> CGFloat {
        max(1, (width - gap * CGFloat(columns - 1)) / CGFloat(columns))
    }
}

private struct TransferCard: View, Equatable {
    let item: TransferItem
    let width: CGFloat
    /// The file is no longer where history saw it.
    let missing: Bool
    let selected: Bool
    /// Screenshot fixtures: drawn as hovered.
    let hoveredFixture: Bool
    let preview: NSImage?
    let duration: String?
    /// What Send to in its menu lists, compared so the menu is never stale.
    let connected: [TransferDevice]
    let menu: () -> [PopUpMenuItem]
    let actions: TransfersWindowActions
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.locale) private var locale

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.width == rhs.width && lhs.missing == rhs.missing && lhs.selected == rhs.selected
            && lhs.hoveredFixture == rhs.hoveredFixture && lhs.preview == rhs.preview && lhs.duration == rhs.duration
            && lhs.connected == rhs.connected
    }

    private var hovered: Bool { hovering || hoveredFixture }
    private var available: Bool { item.localURL != nil && !missing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                TransferThumb(url: available ? item.localURL : nil, name: item.name, kind: item.kind,
                              side: width, height: 92, corner: 0, preview: preview, fixedDuration: duration, badge: .topLeading)
                if hovered && available {
                    LinearGradient(colors: [Color(hex: 0x050B18).opacity(0), Color(hex: 0x050B18).opacity(0.72)],
                                   startPoint: UnitPoint(x: 0.5, y: 0.35), endPoint: .bottom)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    HStack(spacing: 5) {
                        TransferOverlayButton(symbol: "eye", help: L10n.text("phonefiles.quickLook.short", fallback: "Quick Look")) {
                            if let url = item.localURL { actions.quickLook(url) }
                        }
                        TransferOverlayButton(symbol: "folder", help: L10n.text("phonefiles.showInFinder", fallback: "Show in Finder")) {
                            if let url = item.localURL { actions.showInFinder(url) }
                        }
                        PopUpMenuButton(items: menu) { TransferOverlayIcon(symbol: "ellipsis") }
                            .help(L10n.text("action.more", fallback: "More"))
                            .accessibilityLabel(L10n.text("action.more", fallback: "More"))
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .frame(width: width, height: 92)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(BrandFont.body(12, .medium))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    TransferDirectionIcon(incoming: item.direction == .received, size: 12)
                    if missing {
                        Text(L10n.text("transfers.window.gone", fallback: "Moved or deleted")).lineLimit(1)
                    } else {
                        Text(TransfersText.bytes(item.bytes))
                    }
                    TransferDot()
                    Text(TransfersText.time(item.date, locale: locale))
                }
                .font(BrandFont.body(11).monospacedDigit())
                .foregroundStyle(c.on2)
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 7)
        }
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? c.pri : c.panelBorder, lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .scaleEffect(hovering && !reduce ? 1.01 : 1)
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: hovered)
        .animation(BrandMotion.animation(BrandMotion.small, reduce: reduce), value: selected)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if available, let url = item.localURL { actions.open(url) } }
        .simultaneousGesture(TapGesture().onEnded { select() })
        .contextMenu { TransfersContextMenu(items: menu()) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
    }
}

private struct TransferHistoryRow: View, Equatable {
    let item: TransferItem
    /// The file is no longer where history saw it.
    let missing: Bool
    let selected: Bool
    /// Screenshot fixtures: drawn as hovered.
    let hoveredFixture: Bool
    let preview: NSImage?
    let duration: String?
    /// What Send to in its menu lists, compared so the menu is never stale.
    let connected: [TransferDevice]
    let menu: () -> [PopUpMenuItem]
    let actions: TransfersWindowActions
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.locale) private var locale

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.missing == rhs.missing && lhs.selected == rhs.selected && lhs.hoveredFixture == rhs.hoveredFixture
            && lhs.preview == rhs.preview && lhs.duration == rhs.duration && lhs.connected == rhs.connected
    }

    private var hovered: Bool { hovering || hoveredFixture }
    /// Open, Quick Look and Show in Finder need the file where history saw it.
    private var available: Bool { item.localURL != nil && !missing }

    var body: some View {
        HStack(spacing: 12) {
            TransferThumb(url: available ? item.localURL : nil, name: item.name, kind: item.kind, side: 40, corner: 8,
                          preview: preview, fixedDuration: duration, badge: .bottomTrailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(BrandFont.body(13.5, .medium))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .truncationMode(.middle)
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? c.tb : (hovered ? c.s2 : Color.clear)))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: hovered)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if available, let url = item.localURL { actions.open(url) } }
        .simultaneousGesture(TapGesture().onEnded { select() })
        .contextMenu { TransfersContextMenu(items: menu()) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
    }

    @ViewBuilder private var meta: some View {
        HStack(spacing: 6) {
            if item.failed {
                TransferFailureChip(chip: TransferFailure.chip(item))
                Text(item.reason ?? "").lineLimit(1).truncationMode(.tail)
            } else {
                TransferDirectionIcon(incoming: item.direction == .received)
                Text(TransfersText.device(item.deviceName, incoming: item.direction == .received)).lineLimit(1)
                if missing {
                    TransferDot()
                    Text(L10n.text("transfers.window.gone", fallback: "Moved or deleted"))
                } else {
                    if item.kind == .folder, item.fileCount > 1 {
                        TransferDot()
                        Text(String(format: L10n.text("history.files", fallback: "%d files"), item.fileCount))
                    }
                    TransferDot()
                    Text(TransfersText.bytes(item.bytes))
                }
            }
            TransferDot()
            Text(TransfersText.time(item.date, locale: locale))
        }
        .font(BrandFont.body(12).monospacedDigit())
        .foregroundStyle(c.on2)
        .lineLimit(1)
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 4) {
            if hovered {
                Group {
                    if available {
                        TransferIconButton(symbol: "eye", help: L10n.text("phonefiles.quickLook.short", fallback: "Quick Look")) {
                            if let url = item.localURL { actions.quickLook(url) }
                        }
                        TransferIconButton(symbol: "folder", help: L10n.text("phonefiles.showInFinder", fallback: "Show in Finder")) {
                            if let url = item.localURL { actions.showInFinder(url) }
                        }
                    }
                    PopUpMenuButton(items: menu) { TransferIconLabel(symbol: "ellipsis") }
                        .help(L10n.text("action.more", fallback: "More"))
                        .accessibilityLabel(L10n.text("action.more", fallback: "More"))
                }
                .transition(.opacity)
            }
            if item.canResume || item.canRetry {
                Button {
                    if item.canResume { actions.resume(item.id) } else { actions.retry(item) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .medium))
                        Text(item.canResume ? L10n.text("folders.action.resume", fallback: "Resume") : L10n.text("action.retry", fallback: "Retry"))
                            .font(BrandFont.body(13, .medium))
                    }
                    .foregroundStyle(c.on)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.s2))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(c.ol, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(TransfersPressStyle())
            }
        }
    }
}

// MARK: - Small parts

private struct TransferDirectionIcon: View {
    let incoming: Bool
    var size: CGFloat = 13
    @Environment(\.brand) private var c

    var body: some View {
        Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
            .font(.system(size: size - 2, weight: .medium))
            .foregroundStyle(c.on2)
            .frame(width: size, height: size)
            .accessibilityLabel(incoming ? L10n.text("history.filter.received", fallback: "Received") : L10n.text("history.filter.sent", fallback: "Sent"))
    }
}

private struct TransferDot: View {
    @Environment(\.brand) private var c

    var body: some View {
        Circle().fill(c.on2).opacity(0.7).frame(width: 3, height: 3).accessibilityHidden(true)
    }
}

private struct TransferRouteChipView: View {
    let chip: TransferRouteChip
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
            Text(chip.text).font(BrandFont.body(11.5, .medium)).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(background))
    }

    private var symbol: String {
        switch chip.style {
        case .lan: "wifi"
        case .privateNetwork: "lock.shield"
        case .direct: "arrow.left.arrow.right"
        case .relay: "cloud"
        }
    }

    private var foreground: Color {
        switch chip.style {
        case .lan: c.tgi
        case .privateNetwork, .direct: c.tbi
        case .relay: c.tpi
        }
    }

    private var background: Color {
        switch chip.style {
        case .lan: c.tg
        case .privateNetwork, .direct: c.tb
        case .relay: c.tp
        }
    }
}

private struct TransferFailureChip: View {
    let chip: TransferFailure.Chip
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 10.5, weight: .semibold))
            Text(chip == .stopped ? L10n.text("transfers.window.stopped", fallback: "Stopped") : L10n.text("transfers.window.failed", fallback: "Failed"))
                .font(BrandFont.body(11.5, .medium))
        }
        .foregroundStyle(c.warn)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(c.warn.opacity(c.isDark ? 0.12 : 0.1)))
    }
}

/// A thumbnail: the type tile first, the Quick Look thumbnail fading in over it once it is ready.
private struct TransferThumb: View {
    enum Badge { case topLeading, bottomTrailing }

    let url: URL?
    let name: String
    let kind: TransferKind
    let side: CGFloat
    var height: CGFloat?
    let corner: CGFloat
    /// Screenshot fixtures: the thumbnail and video length to draw instead of loading them.
    let preview: NSImage?
    let fixedDuration: String?
    let badge: Badge
    @State private var image: NSImage?
    @State private var duration: String?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        let tile = TransferTile.of(name: name, kind: kind)
        let shown = preview ?? image
        ZStack {
            Rectangle().fill(background(tile.style))
            if let symbol = tile.symbol {
                Image(systemName: symbol).font(.system(size: min(side, height ?? side) >= 60 ? 22 : 17, weight: .medium))
                    .foregroundStyle(foreground(tile.style))
            } else if let label = tile.label {
                Text(label).font(BrandFont.body(10, .semibold)).tracking(0.2).foregroundStyle(foreground(tile.style))
            }
            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: height ?? side)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: height ?? side)
        .overlay(alignment: badge == .topLeading ? .topLeading : .bottomTrailing) {
            if kind == .video, let length = fixedDuration ?? duration {
                Text(length)
                    .font(BrandFont.body(badge == .topLeading ? 10 : 9, .semibold).monospacedDigit())
                    .foregroundStyle(Color(hex: 0xF4F7FA))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: 0x050B18).opacity(0.72)))
                    .padding(badge == .topLeading ? 5 : 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            guard !snapshot, kind.isMedia, preview == nil, let url else { return }
            let side = max(self.side, height ?? self.side)
            if let loaded = await TransferThumbnails.shared.image(for: url, side: side) {
                withAnimation(BrandMotion.animation(BrandMotion.effects, reduce: reduce)) { image = loaded }
            }
            if kind == .video { duration = await TransferThumbnails.shared.duration(for: url) }
        }
    }

    private func background(_ style: TransferTileStyle) -> Color {
        switch style {
        case .blue: c.tb
        case .green: c.tg
        case .purple: c.tp
        case .warn: c.warn.opacity(c.isDark ? 0.12 : 0.1)
        case .neutral: c.s3
        }
    }

    private func foreground(_ style: TransferTileStyle) -> Color {
        switch style {
        case .blue: c.tbi
        case .green: c.tgi
        case .purple: c.tpi
        case .warn: c.warn
        case .neutral: c.on2
        }
    }
}

private struct TransferOverlayIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(hex: 0xF4F7FA))
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: 0x0D1321).opacity(0.85)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct TransferOverlayButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { TransferOverlayIcon(symbol: symbol) }
            .buttonStyle(TransfersPressStyle())
            .help(help)
            .accessibilityLabel(help)
    }
}

private struct TransferIconLabel: View {
    let symbol: String
    @Environment(\.brand) private var c

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(c.on2)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

private struct TransferIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { TransferIconLabel(symbol: symbol) }
            .buttonStyle(TransfersPressStyle(hover: true))
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The same entries as More, as a SwiftUI context menu.
private struct TransfersContextMenu: View {
    let items: [PopUpMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.isSeparator {
                Divider()
            } else if let children = item.submenu {
                Menu(item.title) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in Button(child.title, action: child.action) }
                }
                .disabled(!item.enabled || children.isEmpty)
            } else {
                Button(item.title, action: item.action).disabled(!item.enabled)
            }
        }
    }
}

/// Presses to 0.97; hover tints the background for borderless buttons. Reduce Motion keeps the size.
struct TransfersPressStyle: ButtonStyle {
    var hover = false

    func makeBody(configuration: Configuration) -> some View {
        TransfersPressBody(configuration: configuration, hover: hover)
    }
}

private struct TransfersPressBody: View {
    let configuration: ButtonStyleConfiguration
    let hover: Bool
    @State private var hovering = false
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && hovering && enabled ? c.s3 : Color.clear))
            .scaleEffect(configuration.isPressed && !reduce ? 0.97 : 1)
            .opacity(configuration.isPressed && reduce ? 0.8 : 1)
            .animation(reduce ? nil : BrandMotion.small, value: configuration.isPressed)
            .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Words in a format with two values, the first drawn strong: "**139 MB** of 193 MB".
enum TransfersEmphasis {
    static func text(_ format: String, _ first: String, _ second: String, strong: Color, weak: Color) -> Text {
        let parts = format.components(separatedBy: "%1$@")
        guard parts.count == 2 else { return Text(String(format: format, first, second)).foregroundColor(weak) }
        let rest = parts[1].components(separatedBy: "%2$@")
        guard rest.count == 2 else { return Text(String(format: format, first, second)).foregroundColor(weak) }
        return Text(parts[0]).foregroundColor(weak)
            + Text(first).font(BrandFont.body(12, .medium)).foregroundColor(strong)
            + Text(rest[0]).foregroundColor(weak)
            + Text(second).foregroundColor(weak)
            + Text(rest[1]).foregroundColor(weak)
    }
}

// MARK: - Empty, scroll, dialogs

private struct TransfersEmpty: View {
    let connected: Bool
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc").font(.system(size: 24, weight: .medium)).foregroundStyle(c.on2)
            Text(connected ? L10n.text("transfers.window.empty", fallback: "Drop files here to send") : L10n.text("history.empty", fallback: "No transfers yet"))
                .font(BrandFont.body(13, .medium))
                .foregroundStyle(c.on2)
        }
        .frame(maxWidth: 340, maxHeight: 180)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.ol, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .padding(.horizontal, TransfersWindowView.inset)
        .padding(.vertical, 24)
    }
}

/// The history scroll view, or a clipped stack while ImageRenderer draws. A new token scrolls to the top of
/// the history (History entry points).
private enum TransfersScrollAnchor {
    static let history = "transfers.history"
}

/// The history's lines, in a lazy stack (a plain one while ImageRenderer draws, which has no scrolling).
private struct TransfersScroll<Content: View>: View {
    let token: Int
    @ViewBuilder let content: Content
    @Environment(\.snapshotRendering) private var snapshot
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        if snapshot {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, TransfersWindowView.inset)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, TransfersWindowView.inset)
                        .padding(.top, 4)
                        .padding(.bottom, 28)
                }
                .onChange(of: token) { _ in
                    withAnimation(BrandMotion.animation(BrandMotion.page, reduce: reduce)) { proxy.scrollTo(TransfersScrollAnchor.history, anchor: .top) }
                }
            }
        }
    }
}

private struct TransfersDialog<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.brand) private var c

    var body: some View {
        ZStack {
            Color.black.opacity(c.isDark ? 0.45 : 0.22)
                .onTapGesture(perform: dismiss)
            content
                .padding(18)
                .frame(width: 360, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s1)
                    .shadow(color: .black.opacity(c.isDark ? 0.5 : 0.18), radius: 24, y: 12))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.panelBorder, lineWidth: 1))
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }
}

private struct TransfersDevicePicker: View {
    let devices: [TransferDevice]
    let routes: [String: TransferRouteChip]
    let pick: (String) -> Void
    let cancel: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("transfers.window.sendTo", fallback: "Send to"))
                .font(BrandFont.heading(16))
                .foregroundStyle(c.on)
            VStack(spacing: 4) {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    pickButton(device, index: index)
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 30))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder private func pickButton(_ device: TransferDevice, index: Int) -> some View {
        let button = Button { pick(device.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "smartphone").font(.system(size: 15, weight: .medium)).foregroundStyle(c.on2).frame(width: 22)
                Text(device.name).font(BrandFont.body(13, .medium)).foregroundStyle(c.on).lineLimit(1)
                Spacer(minLength: 8)
                if let route = routes[device.id] { TransferRouteChipView(chip: route).fixedSize() }
                if index < 9 {
                    Text("\(index + 1)").font(BrandFont.body(11, .medium).monospacedDigit()).foregroundStyle(c.on2)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(TransfersPressStyle(hover: true))
        if index == 0 {
            button.keyboardShortcut(.defaultAction)
        } else if index < 9 {
            button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
        } else {
            button
        }
    }
}

private struct TransfersClearConfirm: View {
    let clear: () -> Void
    let cancel: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("history.clear.title", fallback: "Clear transfer history?"))
                .font(BrandFont.heading(16))
                .foregroundStyle(c.on)
            Text(L10n.text("history.clear.body", fallback: "Files stay where they are; only this list is cleared."))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 30))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("history.clear", fallback: "Clear History"), action: clear)
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 30))
            }
            .padding(.top, 4)
        }
    }
}

/// Lets the empty parts of the header move the window, and a double-click zoom or minimise it as the system
/// setting says.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

// MARK: - Thumbnails and drops

/// Quick Look thumbnails and video lengths, made off the main thread and kept in memory, and the files that have
/// none, so a row scrolled back into view does not ask again.
@MainActor
final class TransferThumbnails {
    static let shared = TransferThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var durations: [String: String] = [:]
    private var unavailable = Set<String>()

    init() { cache.countLimit = 600 }

    func image(for url: URL, side: CGFloat) async -> NSImage? {
        let key = "\(Int(side))|\(url.path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if unavailable.contains(key as String) { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image {
            cache.setObject(image, forKey: key)
        } else {
            if unavailable.count >= 2_000 { unavailable.removeAll() }
            unavailable.insert(key as String)
        }
        return image
    }

    /// "2:41", read from the file's header (cheap for a local file); nil when it cannot be read.
    func duration(for url: URL) async -> String? {
        if let known = durations[url.path] { return known }
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        let text = PhoneFilesText.duration(Int64((CMTimeGetSeconds(time) * 1000).rounded()))
        if let text { durations[url.path] = text }
        return text
    }
}

enum TransfersDrop {
    /// File URLs from a drop, on the main thread.
    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.withLock { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(urls) } }
    }
}
