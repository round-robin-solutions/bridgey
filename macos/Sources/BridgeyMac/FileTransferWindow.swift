import AppKit
import Quartz
import SwiftUI

// The Transfers window: what is moving now and the history, in one window (it replaced the File Transfer list and
// the separate History window). Views: TransfersWindowView.swift; pure parts: TransfersModel.swift.

@MainActor
final class FileTransferWindowController: NSWindowController {
    static let autosaveName = "BridgeyTransfersWindow"
    private let model: TransfersWindowModel

    init(pairing: PairingCoordinator) {
        let model = TransfersWindowModel()
        self.model = model
        let window = TransfersNSWindow(contentRect: NSRect(origin: .zero, size: TransfersWindowView.size),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: TransfersLiveView(pairing: pairing, history: pairing.transferHistory, model: model))
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
        model.window = window
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() { show(history: false) }

    /// Brings the window forward; `history` scrolls to the history (the History entry points).
    func show(history: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refreshMissing()
        if history { model.scrollToken += 1 }
    }
}

/// The window's own state: filters, selection, the device picker, and which files went missing.
@MainActor
final class TransfersWindowModel: ObservableObject {
    @Published var filter = TransfersFilter()
    @Published var selection: String?
    @Published var pendingSend: [URL]?
    @Published var scrollToken = 0
    @Published private(set) var missing: Set<String> = []
    let meter = TransferRollingSpeed()
    weak var window: TransfersNSWindow?
    /// The items as last shown, for Space (Quick Look) and the missing-file check.
    var items: [TransferItem] = [] {
        didSet { if items.map(\.id) != oldValue.map(\.id) { refreshMissing() } }
    }

    var selectedURL: URL? {
        guard let selection, !missing.contains(selection), let item = items.first(where: { $0.id == selection }) else { return nil }
        return item.localURL
    }

    /// Escape closes the picker, then clears the selection.
    func escape() -> Bool {
        if pendingSend != nil { pendingSend = nil; return true }
        if selection != nil { selection = nil; return true }
        return false
    }

    /// Records each transfer's bytes for the rolling speed.
    func record(_ rows: [String: FileTransferRow], now: Date = Date()) {
        var ids = Set<String>()
        for row in rows.values where row.active {
            guard let bytes = row.bytesDone ?? (row.folder.map { $0.progress.bytesDone }) else { continue }
            meter.record(row.id, bytes: bytes, at: now)
            ids.insert(row.id)
        }
        meter.keep(ids)
    }

    /// Which history files are no longer where they were (moved or deleted in Finder), checked off the main thread.
    func refreshMissing() {
        let paths = items.compactMap { item in item.localURL.map { (item.id, $0.path) } }
        Task.detached(priority: .utility) {
            let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0.1) }.map(\.0))
            await MainActor.run { [weak self] in
                if self?.missing != gone { self?.missing = gone }
            }
        }
    }
}

private struct TransfersLiveView: View {
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var history: TransferHistoryStore
    @ObservedObject var model: TransfersWindowModel
    @AppStorage("settings.reduceMotion") private var reduceMotion = false

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            TimelineView(.periodic(from: .now, by: pairing.fileTransferActive ? 1 : 3_600)) { context in
                TransfersWindowView(state: state(now: context.date), filter: $model.filter, selection: $model.selection,
                                    pendingSend: $model.pendingSend, scrollToken: model.scrollToken, actions: actions)
            }
        }
        .ignoresSafeArea()
        .onReceive(pairing.$fileTransfers) { model.record($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object as AnyObject? === model.window { model.refreshMissing() }
        }
        .onAppear { history.prune() }
    }

    private func state(now: Date) -> TransfersWindowState {
        let rows = Array(pairing.fileTransfers.values)
        let names = Dictionary(pairing.trustedDevices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let deviceName: (String) -> String = { id in pairing.connectedPhones.first { $0.id == id }?.name ?? names[id] ?? pairing.phoneName(id) }
        let items = TransferItems.make(entries: history.entries, rows: rows, deviceName: deviceName)
        if model.items != items { DispatchQueue.main.async { model.items = items } }
        let live = TransferLiveList.ordered(rows)
        var state = TransfersWindowState()
        state.live = live.map { TransferLive.make($0, deviceName: deviceName) }
        for row in live { state.speeds[row.id] = model.meter.speed(row.id, now: now) }
        for id in Set(state.live.compactMap(\.deviceID)) { state.routes[id] = pairing.transferRouteChip(for: id) }
        state.connected = pairing.connectedPhones.map { TransferDevice(id: $0.id, name: $0.name) }
        for device in state.connected where state.routes[device.id] == nil { state.routes[device.id] = pairing.transferRouteChip(for: device.id) }
        var seen = Set<String>()
        state.devices = (pairing.trustedDevices.map { TransferDevice(id: $0.id, name: $0.name) }
            + items.map { TransferDevice(id: $0.deviceID, name: $0.deviceName) })
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        state.items = items
        state.missing = model.missing
        state.today = TransferTotals.text(history.entries, now: now)
        state.now = now
        return state
    }

    private var actions: TransfersWindowActions {
        var actions = TransfersWindowActions()
        let pairing = pairing, history = history, model = model
        actions.chooseFiles = { TransfersSend.choose(pairing: pairing, model: model) }
        actions.send = { urls, id in _ = SendDispatcher.send(urls: urls, to: id, pairing: pairing) }
        actions.cancel = { pairing.cancelFileTransfer(id: $0) }
        actions.retry = { pairing.retryFileTransfer(id: $0.id) }
        actions.resume = { pairing.resumeFolderTransfer(id: $0) }
        actions.open = { NSWorkspace.shared.open($0) }
        actions.quickLook = { url in model.window?.showQuickLook([url]) }
        actions.showInFinder = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        actions.copy = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
        actions.remove = { item in
            if !item.sessionOnly { history.remove(item.id) }
            pairing.removeFinishedTransfer(id: item.id)
            if model.selection == item.id { model.selection = nil }
        }
        actions.clear = {
            history.clear()
            pairing.clearTransferHistory()
            model.selection = nil
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
    private var placingButtons = false

    private var textEditing: Bool { firstResponder is NSTextView || firstResponder is NSTextField }

    override func keyDown(with event: NSEvent) {
        if !textEditing {
            switch event.keyCode {
            case 49:
                if let onSpace { onSpace(); return }
            case 53:
                if onEscape?() == true { return }
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
