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

    override func cancelOperation(_ sender: Any?) { BridgeyWindows.orderOut(self) }
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
    private let panel: StatusPanel
    private let hosting: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClickMonitor: Any?
    private let dropView = StatusDropView()
    /// Opened by a hovering drag: it closes again when the drag ends without a drop inside.
    private(set) var openedByDrag = false
    var reduceMotion: () -> Bool = { false }
    /// Runs before the panel shows (the host renews the panel content).
    var onWillOpen: () -> Void = {}
    weak var dropHandler: StatusItemDropHandler? {
        didSet { dropView.handler = dropHandler }
    }

    var isOpen: Bool { panel.isVisible }

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
        if isOpen { close() } else { open(byDrag: false) }
    }

    func open(byDrag: Bool) {
        openedByDrag = byDrag
        guard !isOpen else { return }
        onWillOpen()
        hosting.view.layoutSubtreeIfNeeded()
        fitToContent()
        let animate = !reduceMotion()
        panel.alphaValue = animate ? 0 : 1
        panel.orderFrontRegardless()
        if !byDrag { panel.makeKey() }
        if animate { BridgeyWindows.fadeIn(panel, duration: 0.12) } else { BridgeyWindows.cancelFade(panel) }
        statusItem.button?.highlight(true)
        installOutsideClickMonitor()
    }

    func close() {
        guard isOpen else { return }
        openedByDrag = false
        BridgeyWindows.orderOut(panel)
        statusItem.button?.highlight(false)
        removeOutsideClickMonitor()
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
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: NSWindowDelegate (the panel) and the status window's drag route

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, !openedByDrag else { return }
        // Another window of this app (Settings, the send sheet) took the keyboard: like a menu, close.
        close()
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler?.statusDragEntered(sender) ?? [] }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    @objc func draggingExited(_ sender: NSDraggingInfo?) { dropHandler?.statusDragExited() }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropHandler?.statusPerformDrop(sender) ?? false }
}
