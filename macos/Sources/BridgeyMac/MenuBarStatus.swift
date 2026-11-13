import AppKit
import SwiftUI

// The menu-bar icon and its panel, in AppKit (Files 2.0). SwiftUI's MenuBarExtra cannot be opened from code
// and gives no access to drags on its icon, so Bridgey owns the NSStatusItem: a click toggles a borderless,
// non-activating panel under the icon (it never steals a drag in progress), and the icon accepts dropped
// files, images, text and links (MenuBarDrop.swift decides what happens).

/// Drag events on the menu-bar icon.
@MainActor
protocol StatusItemDropHandler: AnyObject {
    func statusDragEntered(_ info: NSDraggingInfo) -> NSDragOperation
    func statusDragExited()
    func statusPerformDrop(_ info: NSDraggingInfo) -> Bool
}

/// A panel that can become key without activating the app (like a menu), so a drag in another app goes on.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { BridgeyWindows.orderOut(self) }
    }
}

/// One mounted panel: refresh transient data after ordering in, and stop polling while hidden.
@MainActor
final class MenuBarPanelPresentation: ObservableObject {
    @Published private(set) var isPresented = false
    /// How the panel content moves as it opens and closes; set by the controller before each change.
    @Published var motion: MenuBarPanelMotion = .spring
    @Published private(set) var clipboard = PasteboardPreview()
    var readClipboard: (PasteboardPreview) -> PasteboardPreview = { PasteboardPreview.current(previous: $0) }

    func prepareToOpen() { clipboard = PasteboardPreview() }
    func setPresented(_ presented: Bool) { isPresented = presented }
    func refreshClipboard() {
        guard isPresented else { return }
        let latest = readClipboard(clipboard)
        if latest != clipboard { clipboard = latest }
    }
}

/// The panel's entrance. Saved as `settings.panelMotion`; Reduce Motion always means no movement.
enum MenuBarPanelMotion: String, CaseIterable {
    /// Drops out of the menu bar: a short spring on scale and position plus the fade.
    case spring
    /// The fade only.
    case fade
    /// Appears and disappears at once.
    case off

    static let defaultsKey = "settings.panelMotion"
    static var stored: () -> MenuBarPanelMotion = {
        MenuBarPanelMotion(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .spring
    }
}

/// Spring entrance from the menu bar. Visual only: scale and offset leave the panel's size alone.
struct MenuBarPanelEntrance: ViewModifier {
    let presented: Bool
    let motion: MenuBarPanelMotion
    static let hiddenScale: CGFloat = 0.94
    static let hiddenOffset: CGFloat = -8

    func body(content: Content) -> some View {
        let moves = motion == .spring
        content
            .scaleEffect(moves && !presented ? Self.hiddenScale : 1, anchor: .top)
            .offset(y: moves && !presented ? Self.hiddenOffset : 0)
            .animation(moves ? (presented ? BrandMotion.spring(0.78, 420) : .easeIn(duration: 0.12)) : nil, value: presented)
    }
}

private struct MenuBarIconClick: Equatable {
    let number: Int
    let timestamp: TimeInterval
    let button: Int
    init?(_ event: NSEvent?) {
        guard let event, event.type == .leftMouseDown || event.type == .rightMouseDown else { return nil }
        number = event.eventNumber
        timestamp = event.timestamp
        button = event.buttonNumber
    }
}

/// Sits over the status button: takes drags, lets every click through to the button.
final class StatusDropView: NSView {
    weak var handler: StatusItemDropHandler?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        handler?.statusDragEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        handler?.statusDragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handler?.statusPerformDrop(sender) ?? false
    }
}

@MainActor
final class MenuBarStatusController: NSObject, NSWindowDelegate {
    /// Pasteboard types the icon accepts.
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg"),
                                                           NSPasteboard.PasteboardType("public.heic")]

    let statusItem: NSStatusItem
    let panel: StatusPanel
    let presentation = MenuBarPanelPresentation()
    private let hosting: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?
    private var monitorGeneration = 0
    private var visibilityGeneration = 0
    private var wantsOpen = false
    private let dropView = StatusDropView()
    /// Opened by a hovering drag: it closes again when the drag ends without a drop inside.
    private(set) var openedByDrag = false
    var reduceMotion: () -> Bool = { false }
    /// Suppress only the very same icon event that already dismissed the panel, never a later click.
    private var dismissedIconClick: MenuBarIconClick?
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    static let openingDuration: TimeInterval = 0.18
    static let closingDuration: TimeInterval = 0.12
    /// The saved entrance style (spring by default).
    var panelMotion: () -> MenuBarPanelMotion = { MenuBarPanelMotion.stored() }
    /// Lightweight state cleanup before layout; provider refreshes belong in onDidOpen.
    var onWillOpen: () -> Void = {}
    /// Refresh after entrance completion; reduced motion uses the next main turn.
    var onDidOpen: () -> Void = {}
    var scheduleOpenRefresh: (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        DispatchQueue.main.async(execute: work)
    }
    weak var dropHandler: StatusItemDropHandler? {
        didSet { dropView.handler = dropHandler }
    }

    var isOpen: Bool { wantsOpen && panel.isVisible }

    init(content: NSHostingController<AnyView>) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        hosting = content
        panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: StreamPanelView.width, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentViewController = hosting
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        hosting.sizingOptions = [.preferredContentSize]
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.fitToContent() }
        }
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Bridgey")
            dropView.frame = button.bounds
            dropView.autoresizingMask = [.width, .height]
            dropView.registerForDraggedTypes(Self.dropTypes)
            button.addSubview(dropView)
            // The status window as a second route, in case AppKit picks the window over the overlay.
            button.window?.registerForDraggedTypes(Self.dropTypes)
            if button.window?.delegate == nil { button.window?.delegate = self }
        }
    }

    func setSymbol(_ name: String) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Bridgey")
        image?.isTemplate = true
        button.image = image
    }

    @objc func togglePanel() {
        if isOpen { close(); return }
        // The icon click that closed the panel (the outside-click monitor or the panel losing key
        // runs first) must not open it again: it toggles closed.
        let suppressed = dismissedIconClick != nil && dismissedIconClick == MenuBarIconClick(currentEvent())
        dismissedIconClick = nil
        if suppressed { return }
        open(byDrag: false)
    }

    /// Closes on outside interaction, remembering only a matching icon mouse-down event.
    func dismissFromOutside(event: NSEvent? = nil) {
        guard isOpen else { return }
        let event = event ?? currentEvent()
        if let event, let icon = iconFrame {
            let point = event.window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? event.locationInWindow
            dismissedIconClick = icon.contains(point) ? MenuBarIconClick(event) : nil
        } else { dismissedIconClick = nil }
        close()
    }

    /// Prepare the retained hierarchy once while hidden, without provider reads or showing a window.
    func prepareContent() {
        guard !panel.isVisible else { return }
        hosting.view.layoutSubtreeIfNeeded()
        fitToContent()
    }

    func open(byDrag: Bool) {
        guard !isOpen else { return }
        dismissedIconClick = nil
        openedByDrag = byDrag
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let alreadyVisible = panel.isVisible
        BridgeyWindows.cancelFade(panel)
        presentation.prepareToOpen()
        onWillOpen()
        hosting.view.layoutSubtreeIfNeeded()
        fitToContent()
        let motion: MenuBarPanelMotion = reduceMotion() ? .off : panelMotion()
        let animate = motion != .off
        presentation.motion = motion
        if !alreadyVisible { panel.alphaValue = animate ? 0 : 1 }
        else if !animate { panel.alphaValue = 1 }
        panel.ignoresMouseEvents = false
        panel.setAccessibilityHidden(false)
        wantsOpen = true
        panel.orderFrontRegardless()
        if !byDrag { panel.makeKey() }
        presentation.setPresented(true)
        statusItem.button?.highlight(true)
        installOutsideClickMonitor()
        if animate {
            BridgeyWindows.fadeIn(panel, duration: Self.openingDuration) { [weak self] in
                self?.refreshAfterOpening(generation)
            }
        } else {
            refreshAfterOpening(generation)
        }
    }

    private func refreshAfterOpening(_ generation: Int) {
        // A slow pasteboard provider must not block the entrance animation itself.
        scheduleOpenRefresh { [weak self] in
            guard let self, self.visibilityGeneration == generation, self.isOpen else { return }
            self.onDidOpen()
        }
        // The window shadow follows the content's settled shape once the spring has come to rest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation, self.isOpen else { return }
                self.panel.invalidateShadow()
            }
        }
    }

    func close(animated: Bool = true) {
        guard wantsOpen || panel.isVisible else { return }
        let wasDrag = openedByDrag
        let animate = animated && !wasDrag && !reduceMotion() && panelMotion() != .off
        presentation.motion = animate ? panelMotion() : .off
        wantsOpen = false
        visibilityGeneration += 1
        presentation.setPresented(false)
        openedByDrag = false
        // The outgoing panel is immediately inert, even if the window server is still fading it.
        panel.ignoresMouseEvents = true
        panel.setAccessibilityHidden(true)
        panel.resignKey()
        statusItem.button?.highlight(false)
        removeOutsideClickMonitor()
        if animate {
            BridgeyWindows.fadeOut(panel, duration: Self.closingDuration)
        } else { BridgeyWindows.orderOut(panel) }
    }

    /// The panel stays open after an interaction that happened inside it during a drag.
    func keepOpen() { openedByDrag = false }

    func highlightIcon(_ on: Bool) {
        guard !isOpen else { return }
        statusItem.button?.highlight(on)
    }

    /// The icon's frame on screen, for the toast.
    var iconFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func fitToContent() {
        var size = hosting.preferredContentSize
        if size.width < 10 || size.height < 10 { size = hosting.view.fittingSize }
        guard size.width > 10, size.height > 10, let icon = iconFrame,
              let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var x = icon.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(icon.minY - 4, visible.maxY)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        let generation = monitorGeneration
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.monitorGeneration == generation else { return }
                self.dismissFromOutside(event: event)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        monitorGeneration += 1
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: NSWindowDelegate (the panel) and the status window's drag route

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, !openedByDrag else { return }
        // Another window of this app (Settings, the send sheet) took the keyboard, or the icon was
        // clicked: like a menu, close.
        dismissFromOutside()
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler?.statusDragEntered(sender) ?? [] }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    @objc func draggingExited(_ sender: NSDraggingInfo?) { dropHandler?.statusDragExited() }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropHandler?.statusPerformDrop(sender) ?? false }
}
