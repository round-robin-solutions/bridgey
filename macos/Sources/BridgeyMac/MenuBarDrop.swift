import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// Drops on the menu-bar icon (Files 2.0). Settings > Files > When I drop on the menu-bar icon:
// - Spring-open (default): hovering about half a second opens the panel with a tile per connected device plus
//   Tray; a quick drop straight on the icon sends to the last-used device, with a 5 s Undo and Send to...
// - Always collect in the Tray.
// - Always send at once to the default device (same toast).
// Sends start immediately (no waiting); Undo cancels the transfers they started.

/// Where a drop landed.
enum DropTarget: Equatable {
    case icon
    case device(String)
    case tray
}

enum DropDecision: Equatable {
    case send(deviceID: String, undoToast: Bool)
    case collect(notConnected: Bool)
}

/// Pure routing for every mode, unit tested.
enum DropRouter {
    static let springDelay: TimeInterval = 0.5
    static let undoSeconds: TimeInterval = 5

    static func springOpens(_ mode: MenuBarDropMode) -> Bool { mode == .springOpen }

    static func decide(_ target: DropTarget, mode: MenuBarDropMode, connected: [String], defaultDevice: String?) -> DropDecision {
        switch target {
        case let .device(id):
            return connected.contains(id) ? .send(deviceID: id, undoToast: false) : .collect(notConnected: true)
        case .tray:
            return .collect(notConnected: false)
        case .icon:
            if mode == .tray { return .collect(notConnected: false) }
            guard let device = defaultDevice, connected.contains(device) else { return .collect(notConnected: true) }
            return .send(deviceID: device, undoToast: true)
        }
    }
}

/// A connected device as a drop tile.
struct DropTileDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let battery: RemoteBatteryStatus?
    /// The free-space line for what is being dragged.
    var freeSpace: FreeSpaceGate = .send
}

@MainActor
final class MenuBarDropController: NSObject, ObservableObject, StatusItemDropHandler {
    static let shared = MenuBarDropController()

    @Published private(set) var tilesVisible = false
    /// Bytes of what is being dragged (files and folders), for the free-space line on each tile.
    @Published private(set) var dragBytes: Int64 = 0

    private weak var pairing: PairingCoordinator?
    private weak var status: MenuBarStatusController?
    private var springTimer: Timer?
    private var dragEndTimer: Timer?
    private let preferences = SendPreferences.shared
    private lazy var toast = DropToastController()

    private var freeSpaceSubscription: AnyCancellable?

    func attach(pairing: PairingCoordinator, status: MenuBarStatusController) {
        self.pairing = pairing
        self.status = status
        status.dropHandler = self
        // Tiles redraw when a phone reports its free space.
        freeSpaceSubscription = pairing.$phoneFreeSpace.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Icon

    func statusDragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        status?.highlightIcon(true)
        measureDrag(info.draggingPasteboard)
        if DropRouter.springOpens(preferences.menuBarDropMode), status?.isOpen != true {
            springTimer?.invalidate()
            springTimer = Timer.scheduledTimer(withTimeInterval: DropRouter.springDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.springOpen() }
            }
        } else if status?.isOpen == true, DropRouter.springOpens(preferences.menuBarDropMode) {
            showTiles()
        }
        return .copy
    }

    func statusDragExited() {
        springTimer?.invalidate()
        springTimer = nil
        status?.highlightIcon(false)
    }

    func statusPerformDrop(_ info: NSDraggingInfo) -> Bool {
        springTimer?.invalidate()
        springTimer = nil
        status?.highlightIcon(false)
        let payloads = DropPayload.from(pasteboard: info.draggingPasteboard)
        guard !payloads.isEmpty else { return false }
        hideTiles()
        if status?.openedByDrag == true { status?.close() }
        route(payloads, target: .icon)
        return true
    }

    private func springOpen() {
        springTimer = nil
        status?.open(byDrag: true)
        showTiles()
    }

    // MARK: Tiles

    private var measuredChangeCount = -1

    /// Sizes the dragged items once per drag, off the main thread (folders can be large).
    private func measureDrag(_ pasteboard: NSPasteboard) {
        guard pasteboard.changeCount != measuredChangeCount else { return }
        measuredChangeCount = pasteboard.changeCount
        dragBytes = 0
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let bytes = SendSizing.bytes(urls)
            await MainActor.run { [weak self] in self?.dragBytes = bytes }
        }
    }

    /// The free-space line for one tile while dragging.
    func tileGate(_ deviceID: String) -> FreeSpaceGate {
        guard let pairing, dragBytes > 0 else { return .send }
        return pairing.freeSpaceGate(needed: dragBytes, deviceID: deviceID)
    }

    func showTiles() {
        tilesVisible = true
        if let pairing { sendTargets(pairing).forEach { pairing.refreshPhoneFreeSpace($0.id) } }
        dragEndTimer?.invalidate()
        // A drag ends when the button comes up; nothing reliable tells this app otherwise.
        dragEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self?.dragEnded()
            }
        }
    }

    func hideTiles() {
        tilesVisible = false
        dragEndTimer?.invalidate()
        dragEndTimer = nil
    }

    private func dragEnded() {
        hideTiles()
        if status?.openedByDrag == true { status?.close() }
    }

    /// A drop on a device or Tray tile in the panel.
    func tileDrop(_ payloads: [DropPayload], target: DropTarget) {
        hideTiles()
        status?.keepOpen()
        guard !payloads.isEmpty else { return }
        route(payloads, target: target)
    }

    var tileDevices: [DropTileDevice] {
        guard let pairing else { return [] }
        return sendTargets(pairing).map { DropTileDevice(id: $0.id, name: $0.name, battery: $0.battery) }
    }

    // MARK: Routing

    func route(_ payloads: [DropPayload], target: DropTarget) {
        guard let pairing else { return }
        let connected = sendTargets(pairing).map(\.id)
        let decision = DropRouter.decide(target, mode: preferences.menuBarDropMode, connected: connected,
                                         defaultDevice: preferences.defaultDevice(connected: connected, selected: pairing.selectedDeviceID))
        switch decision {
        case let .send(deviceID, undoToast):
            let gate = pairing.freeSpaceGate(needed: SendSizing.bytes(payloads), deviceID: deviceID)
            if case let .refuse(line) = gate {
                showRefusedToast(line, payloads: payloads)
                return
            }
            guard let handle = SendDispatcher.send(payloads, to: deviceID, pairing: pairing) else {
                collect(payloads, notConnected: true)
                return
            }
            preferences.rememberDevice(deviceID)
            if undoToast || gate.message != nil { showSentToast(handle, warning: gate.message) }
        case let .collect(notConnected):
            collect(payloads, notConnected: notConnected)
        }
    }

    private func collect(_ payloads: [DropPayload], notConnected: Bool) {
        let added = TrayStore.shared.add(payloads)
        guard !added.isEmpty else { return }
        let text = notConnected
            ? String(format: L10n.text("drop.toast.trayOffline", fallback: "Not connected. %d added to the Tray"), added.count)
            : String(format: L10n.text("drop.toast.tray", fallback: "%d added to the Tray"), added.count)
        toast.show(DropToastModel(text: text, actions: [
            DropToastAction(title: L10n.text("drop.toast.openTray", fallback: "Open Tray")) { [weak self] in
                guard let pairing = self?.pairing else { return }
                TrayController.show(pairing: pairing)
            },
        ]), near: status?.iconFrame)
    }

    /// A send that would not fit: nothing is sent; the toast says why and offers the Tray.
    private func showRefusedToast(_ line: String, payloads: [DropPayload]) {
        toast.show(DropToastModel(text: line, actions: [
            DropToastAction(title: L10n.text("drop.toast.keepInTray", fallback: "Keep in Tray")) { [weak self] in
                self?.collect(payloads, notConnected: false)
            },
        ], warning: true), near: status?.iconFrame)
    }

    func showSentToast(_ handle: SendHandle, warning: String? = nil) {
        guard let pairing else { return }
        let name = sendTargets(pairing).first { $0.id == handle.deviceID }?.name ?? handle.deviceID
        let text = warning ?? (handle.itemCount == 1
            ? String(format: L10n.text("drop.toast.sentOne", fallback: "Sending 1 item to %@"), name)
            : String(format: L10n.text("drop.toast.sent", fallback: "Sending %d items to %@"), handle.itemCount, name))
        var actions = [DropToastAction(title: L10n.text("drop.toast.undo", fallback: "Undo")) { [weak self] in
            guard let self, let pairing = self.pairing else { return }
            let stopped = handle.cancel(in: pairing)
            self.toast.show(DropToastModel(text: stopped
                ? L10n.text("drop.toast.undone", fallback: "Cancelled")
                : L10n.text("drop.toast.tooLate", fallback: "Already delivered"), actions: []), near: self.status?.iconFrame, seconds: 1.5)
        }]
        let others = sendTargets(pairing).filter { $0.id != handle.deviceID }
        if !others.isEmpty {
            actions.append(DropToastAction(title: L10n.text("drop.toast.sendTo", fallback: "Send to\u{2026}")) { [weak self] in
                self?.retarget(handle, to: others)
            })
        }
        toast.show(DropToastModel(text: text, actions: actions, warning: warning != nil), near: status?.iconFrame, seconds: DropRouter.undoSeconds)
    }

    private func retarget(_ handle: SendHandle, to devices: [SendTarget]) {
        let items = devices.map { device in
            PopUpMenuItem(title: device.name) { [weak self] in
                guard let self, let pairing = self.pairing else { return }
                handle.cancel(in: pairing)
                if let next = SendDispatcher.send(handle.payloads, to: device.id, pairing: pairing) {
                    self.preferences.rememberDevice(device.id)
                    self.showSentToast(next, warning: pairing.freeSpaceGate(needed: SendSizing.bytes(handle.payloads), deviceID: device.id).message)
                }
            }
        }
        DropMenu.show(items)
    }
}

// MARK: - Toast

struct DropToastAction: Identifiable {
    let id = UUID()
    let title: String
    let perform: () -> Void
}

struct DropToastModel {
    let text: String
    let actions: [DropToastAction]
    /// Shown in the warning colour (free space).
    var warning = false
}

struct DropToastView: View {
    let model: DropToastModel
    var dismiss: () -> Void = {}
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            if model.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(c.warn)
            } else {
                AuroraMark(size: 18)
            }
            Text(model.text)
                .font(BrandFont.body(13, .medium))
                .foregroundStyle(model.warning ? c.warn : c.on)
                .lineLimit(1)
            Spacer(minLength: 4)
            ForEach(model.actions) { action in
                Button(action.title) {
                    dismiss()
                    action.perform()
                }
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 26))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .frame(minWidth: 300)
        .background(Capsule().fill(c.s1))
        .overlay(Capsule().strokeBorder(c.panelBorder, lineWidth: 1))
        .fixedSize()
    }
}

@MainActor
final class DropToastController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ model: DropToastModel, near icon: NSRect?, seconds: TimeInterval = DropRouter.undoSeconds) {
        hideWork?.cancel()
        let reduce = UserDefaults.standard.bool(forKey: "settings.reduceMotion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingView(rootView: BrandRoot(reduceMotion: reduce) {
            DropToastView(model: model) { [weak self] in self?.hide() }
        })
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        let screen = NSScreen.screens.first { icon.map($0.frame.intersects) ?? false } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let anchorX = icon?.midX ?? visible.maxX - size.width / 2 - 16
        let x = min(max(anchorX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: visible.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        panel.alphaValue = reduce ? 1 : 0
        panel.orderFrontRegardless()
        if !reduce { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 } }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let panel = StatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

// MARK: - Drop tiles

/// The tiles themselves (pure, for screenshots): one per device, plus Tray.
struct DropTilesView: View {
    let devices: [DropTileDevice]
    let trayCount: Int
    /// What drops are sent as (Settings > Files > Before sending), shown under the tiles.
    var chip: String?
    /// Screenshots: which tile looks hovered.
    var highlighted: DropTarget?
    var onDrop: ((DropTarget, [NSItemProvider]) -> Bool)?
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 14) {
            Text(L10n.text("drop.tiles.title", fallback: "Drop to send"))
                .font(BrandFont.heading(15))
                .foregroundStyle(c.on)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(devices) { device in
                    DropTile(target: .device(device.id), highlighted: highlighted == .device(device.id), warning: device.freeSpace.message != nil,
                             onDrop: onDrop) {
                        DeviceRingView(state: .connected, platform: "android", size: 44)
                        Text(device.name)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(c.on)
                            .lineLimit(1)
                        if let line = device.freeSpace.message {
                            Text(line)
                                .font(BrandFont.body(11, .medium))
                                .foregroundStyle(c.warn)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 6)
                        } else {
                            Text(device.battery.map { String(format: L10n.text("panel.battery", fallback: "Battery %d%%"), $0.level) }
                                 ?? L10n.text("drop.tiles.connected", fallback: "Connected"))
                                .font(BrandFont.body(11))
                                .foregroundStyle(c.on2)
                        }
                    }
                }
                DropTile(target: .tray, highlighted: highlighted == .tray, warning: false, onDrop: onDrop) {
                    IconTile(symbol: "tray.full", tint: .purple, size: 44, corner: 22)
                    Text(L10n.text("tray.title", fallback: "Tray"))
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(c.on)
                    Text(trayCount == 0
                         ? L10n.text("drop.tiles.collect", fallback: "Collect, send later")
                         : String(format: L10n.text("drop.tiles.trayCount", fallback: "%d waiting"), trayCount))
                        .font(BrandFont.body(11))
                        .foregroundStyle(c.on2)
                }
            }
            if let chip {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                    Text(String(format: L10n.text("drop.tiles.chip", fallback: "Sent as: %@"), chip))
                        .font(BrandFont.body(12, .semibold))
                }
                .foregroundStyle(c.tpi)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(c.tp))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(c.panel)
    }
}

private struct DropTile<Content: View>: View {
    let target: DropTarget
    let highlighted: Bool
    let warning: Bool
    let onDrop: ((DropTarget, [NSItemProvider]) -> Bool)?
    @ViewBuilder let content: Content
    @State private var targeted = false
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot

    private var lit: Bool { targeted || highlighted }

    var body: some View {
        let tile = VStack(spacing: 6) { content }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(lit ? c.tb : c.s2))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(warning ? c.warn : (lit ? c.pri : c.olv), lineWidth: lit || warning ? 2 : 1))
            .scaleEffect(lit && !reduce ? 1.04 : 1)
            .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: lit)
        if snapshot || onDrop == nil {
            tile
        } else {
            tile.onDrop(of: [.fileURL, .url, .image, .utf8PlainText], isTargeted: $targeted) { providers in
                onDrop?(target, providers) ?? false
            }
        }
    }
}

/// Over the panel while a drag hovers the menu-bar icon.
struct DropTilesOverlay: View {
    let model: PanelModel
    let actions: PanelActions
    @ObservedObject private var controller = MenuBarDropController.shared
    @ObservedObject private var tray = TrayStore.shared

    var body: some View {
        if controller.tilesVisible {
            DropTilesView(devices: controller.tileDevices.map { device in
                var tile = device
                tile.freeSpace = controller.tileGate(device.id)
                return tile
            }, trayCount: tray.items.count,
                          chip: OptimizationLabel.chip(SendPreferences.shared.optimization, saving: nil)) { target, providers in
                DropPayload.load(providers) { payloads in controller.tileDrop(payloads, target: target) }
                return true
            }
            .transition(.opacity)
        }
    }
}

/// A native menu under the pointer (BrandTheme's presenter is private to its file).
@MainActor
enum DropMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func show(_ items: [PopUpMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let target = Target(item.action)
            let menuItem = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            menuItem.target = target
            menuItem.state = item.checked ? .on : .off
            menuItem.isEnabled = item.enabled
            menuItem.representedObject = target
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
