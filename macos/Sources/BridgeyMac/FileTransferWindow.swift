import AppKit
import Combine
import Quartz
import SwiftUI

// The Transfers window: what is moving now and the history, in one window (it replaced the File Transfer list and
// the separate History window). Views: TransfersWindowView.swift; pure parts: TransfersModel.swift.

@MainActor
final class FileTransferWindowController: NSWindowController {
    static let autosaveName = "BridgeyTransfersWindow"
    private let model: TransfersWindowModel
    private var autoShow = TransfersAutoShow()
    private var subscriptions: Set<AnyCancellable> = []

    init(pairing: PairingCoordinator) {
        let model = TransfersWindowModel()
        self.model = model
        let window = TransfersNSWindow(contentRect: NSRect(origin: .zero, size: TransfersWindowView.size),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        let actions = TransfersLiveView.actions(pairing: pairing, history: pairing.transferHistory, model: model)
        let hosting = NSHostingController(rootView: TransfersLiveView(model: model, actions: actions))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.title = L10n.text("transfers.window.title", fallback: "Transfers")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: TransfersWindowView.minimumSize.width, height: TransfersWindowView.minimumSize.height)
        window.setContentSize(TransfersWindowView.size)
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        window.onSpace = { [weak model, weak window] in
            if window?.toggleQuickLook() == true { return }
            guard let url = model?.selectedURL else { return }
            window?.showQuickLook([url])
        }
        window.onEscape = { [weak model] in model?.escape() ?? false }
        window.onArrow = { [weak model] step in model?.moveSelection(by: step) ?? false }
        window.onReturn = { [weak model] in model?.openSelection() ?? false }
        model.window = window
        super.init(window: window)
        model.connect(pairing)
        pairing.$fileTransferActive
            .sink { [weak self] active in self?.autoShow.activeChanged(active, at: ProcessInfo.processInfo.systemUptime) }
            .store(in: &subscriptions)
        // A closed window is not worked out while files move; showing it again catches up at once.
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak model] _ in model?.visible = false }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() { show(history: false) }

    /// Brings the window forward; `history` scrolls to the history (the History entry points).
    func show(history: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.visible = true
        model.refreshMissing()
        if history { model.scrollToken += 1 }
    }

    /// A transfer starts. The first of a run of transfers brings the window (and Bridgey) forward, as before; the rest
    /// of the run leave it where it is, closed included. True when it came forward.
    @discardableResult
    func transferStarted() -> Bool {
        guard autoShow.transferStarted(at: ProcessInfo.processInfo.systemUptime) else { return false }
        show()
        return true
    }
}

/// The window's own state (filters, selection, the device picker) and what it shows, worked out from the coordinator
/// at most five times a second. The live card's rows and speeds go to `feed`, which only the card observes, so
/// progress redraws the card alone; `state` (history, devices, routes, totals) is published only when it changes, and
/// the history is rebuilt only when its entries, the finished rows or the device names change.
@MainActor
final class TransfersWindowModel: ObservableObject {
    @Published var filter = TransfersFilter()
    @Published var selection: String?
    @Published var pendingSend: [URL]?
    @Published var scrollToken = 0
    @Published private(set) var state = TransfersWindowState()
    let feed = TransfersLiveFeed()
    let meter = TransferRollingSpeed()
    weak var window: TransfersNSWindow?
    /// On screen. A closed window is not worked out; showing it again refreshes at once.
    var visible = false {
        didSet {
            guard visible != oldValue else { return }
            if visible { refreshNow() } else { stopTicker() }
        }
    }

    private weak var pairing: PairingCoordinator?
    private weak var history: TransferHistoryStore?
    private lazy var coalescer = TransfersCoalescer { [weak self] in self?.refreshNow() }
    private var subscriptions: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var tickerInterval: TimeInterval = 0
    /// What the history was last built from.
    private var built: (entries: [TransferHistoryEntry], finished: [FileTransferRow], names: [TransferDevice])?
    private var missingCheck = 0

    var selectedURL: URL? {
        guard let selection, !state.missing.contains(selection), let item = state.items.first(where: { $0.id == selection }) else { return nil }
        return item.localURL
    }

    /// The arrow keys move the selection through the items shown (the filter applied), as in Finder; nothing selected
    /// starts at the first. False when nothing is shown.
    func moveSelection(by step: Int) -> Bool {
        let shown = state.items.filter { filter.matches($0) }.map(\.id)
        guard !shown.isEmpty else { return false }
        let current = selection.flatMap { shown.firstIndex(of: $0) }
        let next = current.map { min(shown.count - 1, max(0, $0 + step)) } ?? 0
        selection = shown[next]
        return true
    }

    /// Return opens the selected item, as a double-click does.
    func openSelection() -> Bool {
        guard let url = selectedURL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Escape closes the picker, then clears the selection.
    func escape() -> Bool {
        if pendingSend != nil { pendingSend = nil; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    /// Follows the coordinator and the history. Any change asks for a refresh; refreshes are coalesced.
    func connect(_ pairing: PairingCoordinator) {
        self.pairing = pairing
        history = pairing.transferHistory
        pairing.objectWillChange.sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
        pairing.transferHistory.objectWillChange.sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
    }

    func pruneHistory() { history?.prune() }

    private func changed() {
        guard visible else { return }
        coalescer.signal()
    }

    /// Works the window out from the coordinator now.
    func refreshNow() {
        guard visible, let pairing, let history else { return }
        let connected = pairing.connectedPhones.map { TransferDevice(id: $0.id, name: $0.name) }
        let trusted = pairing.trustedDevices.map { TransferDevice(id: $0.id, name: $0.name) }
        refresh(TransfersSource(rows: Array(pairing.fileTransfers.values), entries: history.entries, connected: connected, trusted: trusted,
                                route: { pairing.transferRouteChip(for: $0) }, fallbackName: { pairing.phoneName($0) }),
                now: Date())
        updateTicker()
    }

    /// Works the window out from `source`: the live card every time, the rest only when it changed.
    func refresh(_ source: TransfersSource, now: Date) {
        let ordered = TransferLiveList.ordered(source.rows)
        record(ordered, now: now)
        let live = ordered.map { TransferLive.make($0, deviceName: source.deviceName) }
        var speeds: [String: Double] = [:]
        for row in ordered { speeds[row.id] = meter.speed(row.id, now: now) }
        feed.update(live: live, speeds: speeds)

        var next = state
        // The rows history items read: finished ones (a failure's reason, Retry, Resume, or a failure history never saw).
        let finished = source.rows.filter { !$0.active }.sorted { $0.id < $1.id }
        let names = source.connected + source.trusted
        var rebuilt = false
        // A new day: Today and Yesterday move on, and today's totals start again.
        let newDay = built == nil || !Calendar.current.isDate(next.now, inSameDayAs: now)
        if newDay { next.now = now }
        if let built, built.entries == source.entries, built.finished == finished, built.names == names {
            if newDay { next.today = TransferTotals.text(source.entries, now: now) }
        } else {
            built = (source.entries, finished, names)
            next.items = TransferItems.make(entries: source.entries, rows: finished, deviceName: source.deviceName)
            next.today = TransferTotals.text(source.entries, now: now)
            var seen = Set<String>()
            next.devices = (source.trusted + next.items.map { TransferDevice(id: $0.deviceID, name: $0.deviceName) })
                .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            rebuilt = next.items.map(\.id) != state.items.map(\.id)
        }
        next.hasLive = !live.isEmpty
        next.connected = source.connected
        var routes: [String: TransferRouteChip] = [:]
        for id in Set(live.compactMap(\.deviceID)).union(source.connected.map(\.id)) { routes[id] = source.route(id) }
        next.routes = routes
        if next != state { state = next }
        if rebuilt { refreshMissing() }
    }

    /// Records each transfer's bytes for the rolling speed.
    private func record(_ live: [FileTransferRow], now: Date) {
        var ids = Set<String>()
        for row in live {
            guard let bytes = row.bytesDone ?? (row.folder.map { $0.progress.bytesDone }) else { continue }
            meter.record(row.id, bytes: bytes, at: now)
            ids.insert(row.id)
        }
        meter.keep(ids)
    }

    /// Speeds and time left move on while nothing reports progress (every second), and Today becomes Yesterday at
    /// midnight (checked every minute while idle).
    private func updateTicker() {
        let interval: TimeInterval = state.hasLive ? 1 : 60
        guard ticker == nil || tickerInterval != interval else { return }
        ticker?.invalidate()
        tickerInterval = interval
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Which history files are no longer where they were (moved or deleted in Finder), checked off the main thread.
    func refreshMissing() {
        let paths = state.items.compactMap { item in item.localURL.map { (item.id, $0.path) } }
        missingCheck += 1
        let check = missingCheck
        Task.detached(priority: .utility) {
            let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0.1) }.map(\.0))
            await MainActor.run { [weak self] in
                // A later check (the history changed meanwhile) has the last word.
                guard let self, check == self.missingCheck, self.state.missing != gone else { return }
                self.state.missing = gone
            }
        }
    }
}

/// What the window is worked out from, read from the coordinator at each refresh (tests build their own).
struct TransfersSource {
    var rows: [FileTransferRow]
    var entries: [TransferHistoryEntry]
    var connected: [TransferDevice] = []
    var trusted: [TransferDevice] = []
    var route: (String) -> TransferRouteChip? = { _ in nil }
    var fallbackName: (String) -> String = { _ in "" }

    func deviceName(_ id: String) -> String {
        connected.first { $0.id == id }?.name ?? trusted.first { $0.id == id }?.name ?? fallbackName(id)
    }
}

/// The live card's rows and speeds. They change several times a second while files move, so only the live card
/// observes this; the rest of the window, the history above all, is not redrawn for them.
@MainActor
final class TransfersLiveFeed: ObservableObject {
    @Published private(set) var live: [TransferLive]
    @Published private(set) var speeds: [String: Double]

    init(live: [TransferLive] = [], speeds: [String: Double] = [:]) {
        self.live = live
        self.speeds = speeds
    }

    /// Publishes only what changed.
    func update(live: [TransferLive], speeds: [String: Double]) {
        if live != self.live { self.live = live }
        if speeds != self.speeds { self.speeds = speeds }
    }
}

private struct TransfersLiveView: View {
    @ObservedObject var model: TransfersWindowModel
    let actions: TransfersWindowActions
    @AppStorage("settings.reduceMotion") private var reduceMotion = false

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            TransfersWindowView(state: model.state, live: model.feed, filter: $model.filter, selection: $model.selection,
                                pendingSend: $model.pendingSend, scrollToken: model.scrollToken, actions: actions)
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object as AnyObject? === model.window { model.refreshMissing() }
        }
        .onAppear { model.pruneHistory() }
    }

    static func actions(pairing: PairingCoordinator, history: TransferHistoryStore, model: TransfersWindowModel) -> TransfersWindowActions {
        var actions = TransfersWindowActions()
        actions.chooseFiles = { [weak pairing, weak model] in
            guard let pairing, let model else { return }
            TransfersSend.choose(pairing: pairing, model: model)
        }
        actions.send = { [weak pairing] urls, id in
            guard let pairing else { return }
            _ = SendDispatcher.send(urls: urls, to: id, pairing: pairing)
        }
        actions.cancel = { [weak pairing] in pairing?.cancelFileTransfer(id: $0) }
        actions.retry = { [weak pairing] in pairing?.retryFileTransfer(id: $0.id) }
        actions.resume = { [weak pairing] in pairing?.resumeFolderTransfer(id: $0) }
        actions.open = { NSWorkspace.shared.open($0) }
        actions.quickLook = { [weak model] url in model?.window?.showQuickLook([url]) }
        actions.showInFinder = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        actions.copy = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
        actions.remove = { [weak pairing, weak history, weak model] item in
            if !item.sessionOnly { history?.remove(item.id) }
            pairing?.removeFinishedTransfer(id: item.id)
            if model?.selection == item.id { model?.selection = nil }
        }
        actions.clear = { [weak pairing, weak history, weak model] in
            history?.clear()
            pairing?.clearTransferHistory()
            model?.selection = nil
        }
        actions.openFolder = {
            let folder = PhoneFilesPaths.receivedFolder()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
        return actions
    }
}

/// Send Files…: the open panel as a sheet, then straight to the one connected device, or the picker.
@MainActor
enum TransfersSend {
    static func choose(pairing: PairingCoordinator, model: TransfersWindowModel) {
        let panel = NSOpenPanel()
        panel.title = L10n.text("files.panel.title", fallback: "Send Files or Folders")
        panel.prompt = L10n.text("folders.sheet.send", fallback: "Send")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            route(panel.urls, pairing: pairing, model: model)
        }
        if let window = model.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            finish(panel.runModal())
        }
    }

    static func route(_ urls: [URL], pairing: PairingCoordinator, model: TransfersWindowModel) {
        let phones = pairing.connectedPhones
        if phones.count == 1 {
            SendDispatcher.send(urls: urls, to: phones[0].id, pairing: pairing)
        } else if phones.count > 1 {
            model.pendingSend = urls
        }
    }
}

/// The Transfers window: Quick Look for its files, Space and Escape, and the close, minimise and zoom buttons
/// centred in its 58 pt header.
@MainActor
final class TransfersNSWindow: NSWindow {
    let quickLookSource = PhoneQuickLookSource()
    var onSpace: (() -> Void)?
    var onEscape: (() -> Bool)?
    /// Left and Up are -1, Right and Down +1.
    var onArrow: ((Int) -> Bool)?
    var onReturn: (() -> Bool)?
    private var placingButtons = false

    private var textEditing: Bool { firstResponder is NSTextView || firstResponder is NSTextField }

    override func keyDown(with event: NSEvent) {
        if !textEditing {
            switch event.keyCode {
            case 49:
                if let onSpace { onSpace(); return }
            case 53:
                if onEscape?() == true { return }
            case 123, 126:
                if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, onArrow?(-1) == true { return }
            case 124, 125:
                if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, onArrow?(1) == true { return }
            case 36, 76:
                if onReturn?() == true { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }

    // MARK: Window buttons

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        placeWindowButtons()
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeWindowButtons()
    }

    override func becomeKey() {
        super.becomeKey()
        placeWindowButtons()
    }

    override func resignKey() {
        super.resignKey()
        placeWindowButtons()
    }

    /// Makes the title bar as tall as the header and centres the buttons in it, 18 pt from the edge. Skipped in
    /// full screen, where the system shows its own title bar.
    func placeWindowButtons() {
        guard !placingButtons, !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton), let titlebar = close.superview, let container = titlebar.superview else { return }
        placingButtons = true
        defer { placingButtons = false }
        let height = TransfersWindowView.headerHeight
        let target = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        if container.frame != target { container.frame = target }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        guard let first = buttons.first else { return }
        let step = buttons.count > 1 ? buttons[1].frame.minX - first.frame.minX : 20
        for (index, button) in buttons.enumerated() {
            let origin = NSPoint(x: 18 + CGFloat(index) * max(step, 20), y: ((titlebar.frame.height - button.frame.height) / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    // MARK: Quick Look

    func showQuickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        quickLookSource.items = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible, panel.dataSource === quickLookSource {
            panel.reloadData()
        } else {
            makeKeyAndOrderFront(nil)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes the panel when it is open; true when it did.
    @discardableResult
    func toggleQuickLook() -> Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return false }
        panel.orderOut(nil)
        return true
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !quickLookSource.items.isEmpty }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookSource
        panel.delegate = quickLookSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === quickLookSource { panel.dataSource = nil }
        if panel.delegate === quickLookSource { panel.delegate = nil }
    }

    override func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === quickLookSource {
            panel.orderOut(nil)
            panel.dataSource = nil
            panel.delegate = nil
        }
        super.close()
    }
}
