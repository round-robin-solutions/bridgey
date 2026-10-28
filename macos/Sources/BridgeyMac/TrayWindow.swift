import AppKit
import Combine
import SwiftUI

// The Tray window (Files 2.0): a small floating shelf. Drop files, folders, images, text and links on it,
// see them with thumbnails and a total size, remove what you do not want, pick the device and the
// optimisation chip, then Send. After sending the Tray clears, with an Undo that puts the items back.

struct TrayViewState {
    var items: [TrayItem] = []
    var targets: [SendTarget] = []
    var targetID: String?
    var optimization: SendOptimization?
    var defaults = SendOptimization.default
    var saving: Double?
    /// "Sent 4 items to OnePlus 11", with Undo, for a few seconds after a send.
    var banner: String?
    var dropTargeted = false
    var status: String?
    var freeSpace: FreeSpaceGate = .send

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var canSend: Bool { targetID != nil && !items.isEmpty && !freeSpace.refuses }
    /// Bytes that land as files on the phone (text and links go to the clipboard), optimised when known.
    var neededBytes: Int64 {
        SendSizing.needed(original: items.filter { $0.kind != .text && $0.kind != .link }.reduce(0) { $0 + $1.size },
                          saving: optimization?.isOriginal == true ? nil : saving)
    }
}

struct TrayActions {
    var remove: (String) -> Void = { _ in }
    var selectTarget: (String) -> Void = { _ in }
    var send: () -> Void = {}
    var undo: () -> Void = {}
    var clear: () -> Void = {}
    var changeOptimization: (SendOptimization) -> Void = { _ in }
}

struct TrayView: View {
    let state: TrayViewState
    let actions: TrayActions
    var thumbnail: ((TrayItem) -> NSImage?)?
    var url: ((TrayItem) -> URL?)?
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    static let width: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.items.isEmpty {
                empty
            } else {
                BoundedScroll {
                    VStack(spacing: 4) {
                        ForEach(state.items) { item in
                            TrayRow(item: item, thumbnail: thumbnail?(item), url: url?(item)) { actions.remove(item.id) }
                        }
                    }
                    .padding(8)
                }
            }
            if let banner = state.banner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(c.tgi)
                    Text(banner)
                        .font(BrandFont.body(12, .medium))
                        .foregroundStyle(c.on)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(L10n.text("drop.toast.undo", fallback: "Undo"), action: actions.undo)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 24))
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(c.tg.opacity(0.6))
                .transition(.opacity)
            }
            footer
        }
        .frame(width: Self.width)
        .frame(minHeight: 300)
        .background(c.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(c.pri, lineWidth: 2)
                .opacity(state.dropTargeted ? 1 : 0)
                .padding(3)
                .allowsHitTesting(false)
        )
        .animation(BrandMotion.animation(BrandMotion.fade, reduce: reduce), value: state.banner)
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconTile(symbol: "tray.full", tint: .purple, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("tray.title", fallback: "Tray"))
                    .font(BrandFont.heading(15))
                    .foregroundStyle(c.on)
                Text(state.items.isEmpty
                     ? L10n.text("tray.subtitle.empty", fallback: "Collect now, send together")
                     : String(format: L10n.text("tray.subtitle", fallback: "%d items, %@"), state.items.count,
                              ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file)))
                    .font(BrandFont.body(11))
                    .foregroundStyle(c.on2)
            }
            Spacer()
            if !state.items.isEmpty {
                Button(L10n.text("tray.clear", fallback: "Clear"), action: actions.clear)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 24))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(c.olv).frame(height: 1) }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(c.tpi)
            Text(L10n.text("tray.empty", fallback: "Drop files, folders, images, text or links here. They wait until you send them."))
                .font(BrandFont.body(12))
                .foregroundStyle(c.on2)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if !state.targets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(state.targets) { target in
                        SendTargetChip(target: target, selected: target.id == state.targetID) { actions.selectTarget(target.id) }
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 8) {
                if let options = state.optimization {
                    OptimizationChipButton(options: options, defaults: state.defaults, saving: state.saving, change: actions.changeOptimization)
                }
                Spacer(minLength: 0)
                if let status = state.status ?? state.freeSpace.message {
                    Text(status).font(BrandFont.body(11, .medium)).foregroundStyle(c.warn).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.text("sendsheet.send", fallback: "Send"), action: actions.send)
                    .buttonStyle(PillButtonStyle(kind: .gradient, height: 30))
                    .disabled(!state.canSend)
            }
        }
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }
}

private struct TrayRow: View {
    let item: TrayItem
    let thumbnail: NSImage?
    let url: URL?
    let remove: () -> Void
    @State private var loaded: NSImage?
    @Environment(\.brand) private var c
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(BrandFont.body(12, .medium))
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(BrandFont.body(10))
                    .foregroundStyle(c.on2)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(c.on2)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(c.s3))
            }
            .buttonStyle(PressScaleStyle())
            .help(L10n.text("tray.remove", fallback: "Remove from the Tray"))
            .accessibilityLabel(L10n.text("tray.remove", fallback: "Remove from the Tray"))
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
        .task(id: url) {
            guard !snapshot, thumbnail == nil, let url else { return }
            loaded = await SendThumbnails.shared.image(for: url, size: 72)
        }
    }

    @ViewBuilder private var preview: some View {
        if let picture = thumbnail ?? loaded {
            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
        } else {
            IconTile(symbol: symbol, tint: item.kind == .link ? .blue : (item.kind == .text ? .green : .neutral), size: 36, corner: 8)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .file, .data: "doc"
        case .folder: "folder.fill"
        case .text: "text.alignleft"
        case .link: "link"
        }
    }

    private var detail: String {
        switch item.kind {
        case .file, .data: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        case .folder: String(format: L10n.text("tray.folder", fallback: "Folder, %@"), ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        case .text: L10n.text("tray.text", fallback: "Text, sent to the clipboard")
        case .link: item.text ?? ""
        }
    }
}

// MARK: - Live model and window

@MainActor
final class TrayModel: ObservableObject {
    @Published var state = TrayViewState()
    let store: TrayStore
    private let pairing: PairingCoordinator
    private let preferences = SendPreferences.shared
    private var subscriptions: [AnyCancellable] = []
    private var undoItems: [TrayItem] = []
    private let estimator = SendEstimator()
    private var override: SendOptimization?
    private var bannerWork: DispatchWorkItem?

    init(pairing: PairingCoordinator, store: TrayStore? = nil) {
        self.pairing = pairing
        let store = store ?? .shared
        self.store = store
        store.$items.sink { [weak self] items in
            self?.state.items = items
            DispatchQueue.main.async { self?.refreshOptimization() }
        }.store(in: &subscriptions)
        estimator.$saving.sink { [weak self] value in
            self?.state.saving = value
            DispatchQueue.main.async { self?.refreshFreeSpace() }
        }.store(in: &subscriptions)
        preferences.$optimization.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshOptimization() } }.store(in: &subscriptions)
        pairing.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTargets() }
        }.store(in: &subscriptions)
        refreshTargets()
    }

    private func refreshOptimization() {
        state.defaults = preferences.optimization
        let options = override ?? preferences.optimization
        state.optimization = options
        estimator.update(urls: store.items.filter { $0.kind != .text && $0.kind != .link }.compactMap { store.url(for: $0) }, options: options)
        refreshFreeSpace()
    }

    private func refreshFreeSpace() {
        guard let target = state.targetID else {
            state.freeSpace = .send
            return
        }
        let gate = pairing.freeSpaceGate(needed: state.neededBytes, deviceID: target)
        if gate != state.freeSpace { state.freeSpace = gate }
    }

    /// The window opened: ask the phone for fresh numbers.
    func opened() {
        if let target = state.targetID { pairing.refreshPhoneFreeSpace(target) }
        refreshFreeSpace()
    }

    private func refreshTargets() {
        let targets = sendTargets(pairing)
        state.targets = targets
        if state.targetID == nil || !targets.contains(where: { $0.id == state.targetID }) {
            state.targetID = preferences.defaultDevice(connected: targets.map(\.id), selected: pairing.selectedDeviceID)
            if let target = state.targetID { pairing.refreshPhoneFreeSpace(target) }
        }
        refreshFreeSpace()
    }

    var actions: TrayActions {
        var actions = TrayActions()
        actions.remove = { [weak self] id in self?.store.remove(id) }
        actions.selectTarget = { [weak self] id in
            guard let self else { return }
            state.targetID = id
            pairing.refreshPhoneFreeSpace(id)
            refreshFreeSpace()
        }
        actions.send = { [weak self] in self?.send() }
        actions.undo = { [weak self] in self?.undo() }
        actions.changeOptimization = { [weak self] options in
            self?.override = options
            self?.refreshOptimization()
        }
        actions.clear = { [weak self] in
            guard let self else { return }
            self.showBanner(L10n.text("tray.cleared", fallback: "Tray cleared"), removed: self.store.clear())
        }
        return actions
    }

    func drop(_ payloads: [DropPayload]) {
        store.add(payloads)
        state.status = nil
    }

    private func send() {
        guard let target = state.targetID, !store.isEmpty, !state.freeSpace.refuses else { return }
        let (urls, texts) = store.sendables(forSending: true)
        let payloads: [DropPayload] = (urls.isEmpty ? [] : [.files(urls)]) + texts.map { DropPayload.text($0) }
        guard let handle = SendDispatcher.send(payloads, to: target, pairing: pairing, optimization: state.optimization) else {
            state.status = pairing.fileTransferStatus ?? L10n.text("sendsheet.failed", fallback: "Could not send. Check the connection.")
            return
        }
        preferences.rememberDevice(target)
        let name = state.targets.first { $0.id == target }?.name ?? ""
        let count = store.items.count
        let removed = store.clear()
        override = nil
        showBanner(count == 1
                   ? String(format: L10n.text("tray.sentOne", fallback: "Sent 1 item to %@"), name)
                   : String(format: L10n.text("tray.sent", fallback: "Sent %d items to %@"), count, name), removed: removed)
        _ = handle
    }

    private func showBanner(_ text: String, removed: [TrayItem]) {
        undoItems = removed
        state.banner = text
        state.status = nil
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.state.banner = nil
            self?.undoItems = []
            self?.store.purge()
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func undo() {
        bannerWork?.cancel()
        store.restore(undoItems)
        undoItems = []
        state.banner = nil
    }
}

@MainActor
enum TrayController {
    private static var window: TrayWindowController?

    static func show(pairing: PairingCoordinator) {
        let controller = window ?? TrayWindowController(pairing: pairing)
        window = controller
        controller.show()
    }
}

@MainActor
final class TrayWindowController: NSWindowController {
    private let model: TrayModel

    init(pairing: PairingCoordinator) {
        model = TrayModel(pairing: pairing)
        let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: TrayView.width, height: 420),
                                styleMask: [.titled, .closable, .fullSizeContentView, .resizable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = L10n.text("tray.title", fallback: "Tray")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.canJoinAllSpaces)
        // No AppKit ordering animation: a close that never finishes it left the panel on screen.
        panel.animationBehavior = .none
        panel.minSize = NSSize(width: TrayView.width, height: 300)
        panel.setFrameAutosaveName("BridgeyTray")
        super.init(window: panel)
        panel.contentViewController = NSHostingController(rootView: TrayRoot(model: model))
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - TrayView.width - 24, y: screen.visibleFrame.maxY - 460))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        model.opened()
        showWindow(nil)
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}

private struct TrayRoot: View {
    @ObservedObject var model: TrayModel

    var body: some View {
        BrandRoot(reduceMotion: UserDefaults.standard.bool(forKey: "settings.reduceMotion")) {
            TrayView(state: model.state, actions: model.actions, url: { model.store.url(for: $0) })
                .onDrop(of: [.fileURL, .url, .image, .utf8PlainText],
                        isTargeted: Binding(get: { model.state.dropTargeted }, set: { model.state.dropTargeted = $0 })) { providers in
                    DropPayload.load(providers) { payloads in model.drop(payloads) }
                    return true
                }
        }
    }
}

// MARK: - Panel entry

/// The panel's entry to the send sheet and the Tray, above the send bar.
struct SendPanelEntry: View {
    let model: PanelModel
    let actions: PanelActions
    @ObservedObject private var tray = TrayStore.shared
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 8) {
            Button(action: actions.chooseFile) {
                Label(L10n.text("panel.sendFiles", fallback: "Send files"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
            .disabled(!model.isConnected || !model.available.contains(.files))
            Button(action: actions.openTray) {
                Label(tray.items.isEmpty
                      ? L10n.text("tray.title", fallback: "Tray")
                      : String(format: L10n.text("panel.trayCount", fallback: "Tray \u{00B7} %d"), tray.items.count),
                      systemImage: "tray.full")
            }
            .buttonStyle(PillButtonStyle(kind: tray.items.isEmpty ? .neutral : .tonal, height: 28))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}
