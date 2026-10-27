import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Files 2.0: the Send to phone sheet. Recent files (Downloads, Desktop, Documents, recently opened) and recent
// screenshots as a Telegram-style grid with numbered selection, drag and drop anywhere on the sheet, and
// Browse... (the system panel) only as a fallback. Opened from the panel's File menu and the send bar.

// MARK: - Targets

/// A connected phone a send can go to.
struct SendTarget: Identifiable, Equatable {
    let id: String
    let name: String
    var battery: RemoteBatteryStatus?
}

@MainActor
func sendTargets(_ pairing: PairingCoordinator) -> [SendTarget] {
    pairing.connectedPhones
        .filter { pairing.isFeatureAvailable(.files, for: $0.id) }
        .map { SendTarget(id: $0.id, name: $0.name, battery: $0.state.battery) }
}

// MARK: - Candidates

/// A file or folder the sheet offers.
struct SendCandidate: Identifiable, Equatable, Hashable {
    let url: URL
    let name: String
    let size: Int64
    let date: Date
    let isDirectory: Bool
    var isScreenshot = false

    var id: String { url.path }
}

/// Which Spotlight results the sheet shows. Pure, so it is unit tested.
enum RecentFileFilter {
    /// Matches the folder names Spotlight indexes but people never mean to send.
    private static let skippedComponents: Set<String> = [".Trash", "Library", "node_modules", ".git", "DerivedData"]

    static func include(path: String, name: String, size: Int64, isDirectory: Bool, home: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }
        let lower = name.lowercased()
        if lower.hasSuffix(".bridgey-part") || lower.hasSuffix(".download") || lower.hasSuffix(".crdownload") || lower.hasSuffix(".part") {
            return false
        }
        if isDirectory { return false }
        guard size > 0, size <= FolderLimits.maxFileSize else { return false }
        guard path.hasPrefix(home + "/") else { return false }
        let components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        // Inside a package (an app, a photo library) or a hidden or skipped folder.
        for component in components.dropLast() {
            if component.hasPrefix(".") || skippedComponents.contains(component) { return false }
            let ext = (component as NSString).pathExtension.lowercased()
            if ["app", "photoslibrary", "bundle", "framework", "xcodeproj", "xcworkspace", "rtfd", "pages", "key", "numbers"].contains(ext) {
                return false
            }
        }
        return true
    }

    /// Newest first, one row per path, at most `limit`.
    static func ordered(_ items: [SendCandidate], limit: Int) -> [SendCandidate] {
        var seen = Set<String>()
        return Array(items.sorted { $0.date == $1.date ? $0.name < $1.name : $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit))
    }
}

/// Spotlight queries behind the sheet: recent files in Downloads, Desktop and Documents (opened or added in
/// the last 30 days), and screen captures anywhere in the home folder. Results arrive in a few hundred
/// milliseconds; nothing is read until the sheet opens, and the queries stop when it closes.
@MainActor
final class RecentFilesQuery: ObservableObject {
    @Published private(set) var recent: [SendCandidate] = []
    @Published private(set) var screenshots: [SendCandidate] = []
    @Published private(set) var gathered = false

    static let recentLimit = 40
    static let screenshotLimit = 20

    private var recentQuery: NSMetadataQuery?
    private var screenshotQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    func start() {
        guard recentQuery == nil else { return }
        let manager = FileManager.default
        let scopes = [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { manager.urls(for: $0, in: .userDomainMask).first }
        let since = Date().addingTimeInterval(-30 * 24 * 60 * 60) as NSDate
        let recent = NSMetadataQuery()
        recent.searchScopes = scopes
        recent.predicate = NSPredicate(format: "(kMDItemLastUsedDate >= %@ || kMDItemDateAdded >= %@) && kMDItemContentTypeTree != 'public.folder'", since, since)
        recent.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        let shots = NSMetadataQuery()
        shots.searchScopes = [NSMetadataQueryUserHomeScope]
        shots.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        shots.sortDescriptors = [NSSortDescriptor(key: "kMDItemContentCreationDate", ascending: false)]
        recentQuery = recent
        screenshotQuery = shots
        let center = NotificationCenter.default
        for query in [recent, shots] {
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                })
            }
            query.start()
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        recentQuery?.stop()
        screenshotQuery?.stop()
        recentQuery = nil
        screenshotQuery = nil
    }

    private func refresh() {
        if let recentQuery {
            recentQuery.disableUpdates()
            recent = RecentFileFilter.ordered(candidates(recentQuery, screenshot: false), limit: Self.recentLimit)
            recentQuery.enableUpdates()
        }
        if let screenshotQuery {
            screenshotQuery.disableUpdates()
            screenshots = RecentFileFilter.ordered(candidates(screenshotQuery, screenshot: true), limit: Self.screenshotLimit)
            screenshotQuery.enableUpdates()
        }
        gathered = !(recentQuery?.isGathering ?? false) && !(screenshotQuery?.isGathering ?? false)
    }

    private func candidates(_ query: NSMetadataQuery, screenshot: Bool) -> [SendCandidate] {
        // Only the newest few hundred: the query is sorted, so the rest would be cut anyway.
        let count = min(query.resultCount, 400)
        var result: [SendCandidate] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? (path as NSString).lastPathComponent
            let size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0
            guard RecentFileFilter.include(path: path, name: name, size: size, isDirectory: false, home: home) else { continue }
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let added = item.value(forAttribute: "kMDItemDateAdded") as? Date
            let created = item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date
            let date = [used, added, created].compactMap { $0 }.max() ?? .distantPast
            result.append(SendCandidate(url: URL(fileURLWithPath: path), name: name, size: size, date: date, isDirectory: false,
                                        isScreenshot: screenshot))
        }
        return result
    }
}

/// Quick Look thumbnails for the sheet and the Tray, cached in memory.
@MainActor
final class SendThumbnails {
    static let shared = SendThumbnails()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 400 }

    func cached(_ url: URL, size: CGFloat) -> NSImage? { cache.object(forKey: key(url, size)) }

    func image(for url: URL, size: CGFloat) async -> NSImage? {
        if let hit = cached(url, size: size) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image { cache.setObject(image, forKey: key(url, size)) }
        return image ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString { "\(Int(size))|\(url.path)" as NSString }
}

// MARK: - State and actions (pure, for the view and screenshots)

struct SendSheetState {
    var targets: [SendTarget] = []
    var targetID: String?
    var recent: [SendCandidate] = []
    var screenshots: [SendCandidate] = []
    /// Dropped on the sheet or picked with Browse, newest first.
    var added: [SendCandidate] = []
    /// Selected items in the order they were picked (the badge shows the position).
    var selection: [URL] = []
    var gathered = true
    var dropTargeted = false
    var status: String?
    /// This send's optimisation (the Settings default until the chip changes it) and its measured saving.
    var optimization: SendOptimization?
    var defaults = SendOptimization.default
    var saving: Double?

    var selectedItems: [SendCandidate] {
        let all = added + recent + screenshots
        return selection.compactMap { url in all.first { $0.url == url } }
    }

    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func position(of url: URL) -> Int? { selection.firstIndex(of: url).map { $0 + 1 } }

    var canSend: Bool { targetID != nil && !selection.isEmpty }
}

struct SendSheetActions {
    var selectTarget: (String) -> Void = { _ in }
    var toggle: (SendCandidate) -> Void = { _ in }
    var browse: () -> Void = {}
    var send: () -> Void = {}
    var close: () -> Void = {}
    var drop: ([URL]) -> Bool = { _ in false }
    var targeted: (Bool) -> Void = { _ in }
    var changeOptimization: (SendOptimization) -> Void = { _ in }
}

// MARK: - View

struct SendSheetView: View {
    let state: SendSheetState
    let actions: SendSheetActions
    /// Thumbnails come from Quick Look in the app and from fixtures in screenshots.
    var thumbnail: ((SendCandidate) -> NSImage?)?
    @Environment(\.brand) private var c

    static let width: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            header
            BoundedScroll {
                VStack(alignment: .leading, spacing: 18) {
                    if !state.added.isEmpty {
                        section(L10n.text("sendsheet.added", fallback: "Added"), items: state.added)
                    }
                    if !state.recent.isEmpty {
                        section(L10n.text("sendsheet.recent", fallback: "Recent"), items: state.recent)
                    }
                    if !state.screenshots.isEmpty {
                        section(L10n.text("sendsheet.screenshots", fallback: "Screenshots"), items: state.screenshots)
                    }
                    if state.added.isEmpty && state.recent.isEmpty && state.screenshots.isEmpty {
                        emptyCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            footer
        }
        .frame(width: Self.width)
        .frame(minHeight: 420)
        .background(c.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(c.pri, lineWidth: 2)
                .opacity(state.dropTargeted ? 1 : 0)
                .padding(4)
                .allowsHitTesting(false)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("sendsheet.title", fallback: "Send to"))
                .font(BrandFont.heading(17))
                .foregroundStyle(c.on)
            if state.targets.isEmpty {
                Text(L10n.text("sendsheet.noDevice", fallback: "Connect a device to send. You can still pick files now."))
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
            } else {
                HStack(spacing: 8) {
                    ForEach(state.targets) { target in
                        SendTargetChip(target: target, selected: target.id == state.targetID) { actions.selectTarget(target.id) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    private func section(_ title: String, items: [SendCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(c.on2)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 12), count: 5), alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    SendCandidateTile(item: item, position: state.position(of: item.url), thumbnail: thumbnail) { actions.toggle(item) }
                }
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            IconTile(symbol: "tray.and.arrow.down", tint: .blue, size: 40, corner: 12)
            Text(state.gathered
                 ? L10n.text("sendsheet.empty", fallback: "Nothing recent yet. Drop files or folders anywhere on this window, or Browse.")
                 : L10n.text("sendsheet.loading", fallback: "Looking for recent files\u{2026}"))
                .font(BrandFont.body(13))
                .foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L10n.text("sendsheet.browse", fallback: "Browse\u{2026}"), action: actions.browse)
                .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
            if let options = state.optimization {
                OptimizationChipButton(options: options, defaults: state.defaults, saving: state.saving, change: actions.changeOptimization)
            }
            Spacer(minLength: 8)
            Text(summary)
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .lineLimit(1)
            Button(action: actions.send) {
                Text(L10n.text("sendsheet.send", fallback: "Send"))
            }
            .buttonStyle(PillButtonStyle(kind: .gradient, height: 32))
            .keyboardShortcut(.defaultAction)
            .disabled(!state.canSend)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    private var summary: String {
        if let status = state.status { return status }
        guard !state.selection.isEmpty else { return L10n.text("sendsheet.pick", fallback: "Pick files, or drop them here") }
        let size = ByteCountFormatter.string(fromByteCount: state.selectedBytes, countStyle: .file)
        let count = state.selection.count
        return count == 1
            ? String(format: L10n.text("sendsheet.summary.one", fallback: "1 item, %@"), size)
            : String(format: L10n.text("sendsheet.summary", fallback: "%d items, %@"), count, size)
    }
}

struct SendTargetChip: View {
    let target: SendTarget
    let selected: Bool
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                DeviceRingView(state: .connected, platform: "android", size: 24)
                Text(target.name)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                if let battery = target.battery {
                    Text("\(battery.level)%")
                        .font(BrandFont.body(11, .medium))
                        .foregroundStyle(c.on2)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background(Capsule().fill(selected ? c.tb : c.s2))
            .overlay(Capsule().strokeBorder(selected ? c.pri : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tile: thumbnail, name and size; selected tiles carry their position, like Telegram's picker.
struct SendCandidateTile: View {
    let item: SendCandidate
    let position: Int?
    var thumbnail: ((SendCandidate) -> NSImage?)?
    let toggle: () -> Void
    @State private var loaded: NSImage?
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(c.s2)
                        .frame(width: 100, height: 80)
                        .overlay(image)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(c.pri, lineWidth: 2)
                                .opacity(position == nil ? 0 : 1)
                        )
                    badge
                        .padding(5)
                }
                Text(item.name)
                    .font(BrandFont.body(11, .medium))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(BrandFont.body(10))
                    .foregroundStyle(c.on2)
                    .lineLimit(1)
            }
            .frame(width: 100, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(item.name)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(position == nil ? [] : .isSelected)
        .task(id: item.url) {
            guard !snapshot, thumbnail == nil else { return }
            loaded = await SendThumbnails.shared.image(for: item.url, size: 160)
        }
    }

    @ViewBuilder private var image: some View {
        if let picture = thumbnail?(item) ?? loaded ?? (snapshot ? nil : SendThumbnails.shared.cached(item.url, size: 160)) {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 100, height: 80)
                .transition(.opacity)
        } else {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(c.on2)
        }
    }

    private var badge: some View {
        ZStack {
            Circle().fill(position == nil ? Color.black.opacity(0.25) : c.pri)
            Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            if let position {
                Text("\(position)")
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(c.onpri)
            }
        }
        .frame(width: 20, height: 20)
        .scaleEffect(position == nil || reduce ? 1 : 1.05)
        .animation(reduce ? nil : BrandMotion.pop, value: position)
    }
}

/// "Original" or "Optimised · −68%"; opens the per-send popover.
struct OptimizationChip: View {
    let label: String
    let action: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(BrandFont.body(12, .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(c.tpi)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(c.tp))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(String(format: L10n.text("chip.accessibility", fallback: "Before sending: %@"), label))
    }
}

// MARK: - Live model and window

@MainActor
final class SendSheetModel: ObservableObject {
    @Published var state = SendSheetState()
    let query = RecentFilesQuery()
    let estimator = SendEstimator()
    private let pairing: PairingCoordinator
    /// Set by the chip for this send only; nil follows Settings.
    private var override: SendOptimization?
    private let preferences: SendPreferences
    private var observations: [AnyCancellable] = []
    var onClose: () -> Void = {}

    init(pairing: PairingCoordinator, preferences: SendPreferences? = nil) {
        self.pairing = pairing
        self.preferences = preferences ?? .shared
        observations.append(query.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        observations.append(pairing.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTargets() }
        })
        observations.append(estimator.$saving.sink { [weak self] value in self?.state.saving = value })
        observations.append(self.preferences.$optimization.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshOptimization() }
        })
        refreshTargets()
        refreshOptimization()
    }

    private func refreshOptimization() {
        state.defaults = preferences.optimization
        state.optimization = override ?? preferences.optimization
        estimator.update(urls: state.selection, options: state.optimization ?? preferences.optimization)
    }

    func open() {
        state.status = nil
        query.start()
        refresh()
    }

    func closed() {
        query.stop()
    }

    func refresh() {
        state.recent = query.recent
        state.screenshots = query.screenshots
        state.gathered = query.gathered
        let known = Set((state.added + state.recent + state.screenshots).map(\.url))
        state.selection.removeAll { !known.contains($0) }
        refreshOptimization()
    }

    private func refreshTargets() {
        let targets = sendTargets(pairing)
        state.targets = targets
        if state.targetID == nil || !targets.contains(where: { $0.id == state.targetID }) {
            state.targetID = preferences.defaultDevice(connected: targets.map(\.id), selected: pairing.selectedDeviceID)
        }
    }

    var actions: SendSheetActions {
        var actions = SendSheetActions()
        actions.selectTarget = { [weak self] id in self?.state.targetID = id }
        actions.toggle = { [weak self] item in
            guard let self else { return }
            if let index = state.selection.firstIndex(of: item.url) {
                state.selection.remove(at: index)
            } else {
                state.selection.append(item.url)
            }
            state.status = nil
            refreshOptimization()
        }
        actions.browse = { [weak self] in self?.browse() }
        actions.send = { [weak self] in self?.send() }
        actions.close = { [weak self] in self?.onClose() }
        actions.drop = { [weak self] urls in self?.add(urls) ?? false }
        actions.targeted = { [weak self] value in self?.state.dropTargeted = value }
        actions.changeOptimization = { [weak self] options in
            self?.override = options
            self?.refreshOptimization()
        }
        return actions
    }

    /// Dropped or browsed items go to the top and are selected.
    @discardableResult
    func add(_ urls: [URL]) -> Bool {
        let candidates = urls.filter(\.isFileURL).compactMap(Self.candidate)
        guard !candidates.isEmpty else { return false }
        for candidate in candidates.reversed() where !state.added.contains(where: { $0.url == candidate.url }) {
            state.added.insert(candidate, at: 0)
        }
        for candidate in candidates where !state.selection.contains(candidate.url) { state.selection.append(candidate.url) }
        state.status = nil
        refreshOptimization()
        return true
    }

    static func candidate(_ url: URL) -> SendCandidate? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey])
        guard let values else { return nil }
        let directory = values.isDirectory ?? false
        return SendCandidate(url: url, name: values.name ?? url.lastPathComponent, size: Int64(values.fileSize ?? 0),
                             date: values.contentModificationDate ?? Date(), isDirectory: directory)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("files.panel.title", fallback: "Send Files or Folders")
        panel.prompt = L10n.text("sendsheet.add", fallback: "Add")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func send() {
        guard let target = state.targetID else { return }
        let urls = state.selection
        guard !urls.isEmpty else { return }
        if SendDispatcher.send(urls: urls, to: target, pairing: pairing, optimization: state.optimization) != nil {
            preferences.rememberDevice(target)
            state.selection = []
            state.added = []
            override = nil
            refreshOptimization()
            onClose()
        } else {
            state.status = pairing.fileTransferStatus ?? L10n.text("sendsheet.failed", fallback: "Could not send. Check the connection.")
        }
    }
}

@MainActor
enum SendSheetController {
    private static var window: SendSheetWindowController?

    static func show(pairing: PairingCoordinator) {
        let controller = window ?? SendSheetWindowController(pairing: pairing)
        window = controller
        controller.show()
    }
}

@MainActor
final class SendSheetWindowController: NSWindowController, NSWindowDelegate {
    private let model: SendSheetModel

    init(pairing: PairingCoordinator) {
        model = SendSheetModel(pairing: pairing)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: SendSheetView.width, height: 560),
                            styleMask: [.titled, .closable, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = L10n.text("sendsheet.window", fallback: "Send to phone")
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior.insert(.canJoinAllSpaces)
        panel.minSize = NSSize(width: SendSheetView.width, height: 420)
        panel.setFrameAutosaveName("BridgeySendSheet")
        super.init(window: panel)
        panel.contentViewController = NSHostingController(rootView: SendSheetRoot(model: model))
        panel.delegate = self
        model.onClose = { [weak self] in self?.close() }
        if panel.frame.origin == .zero { panel.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        model.open()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.closed() }
}

private struct SendSheetRoot: View {
    @ObservedObject var model: SendSheetModel

    var body: some View {
        BrandRoot(reduceMotion: UserDefaults.standard.bool(forKey: "settings.reduceMotion")) {
            SendSheetView(state: model.state, actions: model.actions)
                .onDrop(of: [.fileURL], isTargeted: Binding(get: { model.state.dropTargeted }, set: { model.state.dropTargeted = $0 })) { providers in
                    loadFileURLs(providers) { urls in model.add(urls) }
                    return true
                }
                .onExitCommand { model.actions.close() }
        }
    }
}

/// File URLs from drag providers, delivered on the main thread in drop order.
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls = [URL?](repeating: nil, count: providers.count)
    let lock = NSLock()
    for (index, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            lock.lock(); urls[index] = url; lock.unlock()
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let found = urls.compactMap { $0 }
        Task { @MainActor in completion(found) }
    }
}
