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
    /// Grows a few points down out of the menu bar while it fades in.
    case move
    /// The fade only.
    case fade
    /// Appears and disappears at once.
    case off

    static let defaultsKey = "settings.panelMotion"
    static var stored: () -> MenuBarPanelMotion = {
        MenuBarPanelMotion(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .move
    }
}

/// Moves the content layer on the render server, so a busy main thread cannot stall it; layout never changes.
@MainActor
enum MenuBarPanelMover {
    static let key = "bridgey.panelMotion"
    static let hiddenScale: CGFloat = 0.97
    static let hiddenRise: CGFloat = 6
    static let entrance = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    static let exit = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    /// Scaled about the top edge at `pivotX` and raised toward the menu bar.
    static func hiddenTransform(for layer: CALayer, pivotX: CGFloat) -> CATransform3D {
        let bounds = layer.bounds
        // Layer space is y-down when an ancestor flips geometry, y-up otherwise.
        let flipped = layer.superlayer.map(isFlipped) ?? false
        let pivot = CGPoint(x: min(max(pivotX, 0), bounds.width), y: flipped ? bounds.minY : bounds.maxY)
        let anchor = CGPoint(x: bounds.minX + layer.anchorPoint.x * bounds.width, y: bounds.minY + layer.anchorPoint.y * bounds.height)
        let dx = pivot.x - anchor.x, dy = pivot.y - anchor.y
        var transform = CATransform3DMakeTranslation(-dx, -dy, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(hiddenScale, hiddenScale, 1))
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(dx, dy + (flipped ? -hiddenRise : hiddenRise), 0))
    }

    private static func isFlipped(_ layer: CALayer) -> Bool {
        var flips = false
        var current: CALayer? = layer
        while let next = current {
            if next.isGeometryFlipped { flips.toggle() }
            current = next.superlayer
        }
        return flips
    }

    /// Moves from wherever the content is drawn now, so a reversal mid-way never jumps.
    static func move(_ layer: CALayer, to target: CATransform3D, from start: CATransform3D? = nil, duration: TimeInterval,
                     curve: CAMediaTimingFunction) {
        let from = start ?? layer.presentation()?.transform ?? layer.transform
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = duration
        animation.timingFunction = curve
        // Holds the end state, so a closed panel stays shrunk until it is ordered out.
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    static func reset(_ layer: CALayer?) { layer?.removeAnimation(forKey: key) }
}

/// One press, in screen coordinates on NSEvent's clock.
///
/// macOS 27 draws status items in MenuBarAgent, so one press on the icon reaches Bridgey twice: the real press
/// goes to the menu bar (the outside-click monitor sees it, or the panel loses key with no mouse event), then
/// MenuBarAgent sends the button a new mouse-down, at the icon's centre and with a later timestamp.
struct MenuBarPress {
    let location: NSPoint
    let timestamp: TimeInterval
    /// nil when only the pointer is known (the panel lost key without a mouse event).
    let button: Int?

    /// The forwarded mouse-down came 21 to 79 ms after the press in real clicks on macOS 27.2.
    static let sameClickWindow: TimeInterval = 0.5
    /// A press just beside the icon still reaches it (seen 2 pt outside its frame); the next item is further.
    static let sameClickSlack: CGFloat = 8

    init(location: NSPoint, timestamp: TimeInterval, button: Int?) {
        self.location = location
        self.timestamp = timestamp
        self.button = button
    }

    init?(mouseDown event: NSEvent?) {
        guard let event, event.type == .leftMouseDown || event.type == .rightMouseDown else { return nil }
        // A monitor event has no window: its location is already on screen.
        location = event.window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? event.locationInWindow
        timestamp = event.timestamp
        button = event.buttonNumber
    }

    /// `click` is the icon's own mouse-down, so this press was on the icon if it lies within the icon around it.
    func isSameClick(as click: MenuBarPress, iconSize: CGSize) -> Bool {
        (button == nil || button == click.button)
            && abs(click.timestamp - timestamp) <= Self.sameClickWindow
            && abs(click.location.x - location.x) <= iconSize.width / 2 + Self.sameClickSlack
            && abs(click.location.y - location.y) <= iconSize.height / 2 + Self.sameClickSlack
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
    /// The press that closed the panel from outside: the icon's mouse-down for that same press must not reopen it.
    private var dismissingPress: MenuBarPress?
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    static let openingDuration: TimeInterval = 0.18
    static let closingDuration: TimeInterval = 0.12
    /// The saved entrance style (movement by default).
    var panelMotion: () -> MenuBarPanelMotion = { MenuBarPanelMotion.stored() }
    /// The layer that moves: the whole panel content, as one surface.
    var contentLayer: CALayer? { hosting.view.layer }
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
        hosting.view.wantsLayer = true
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
        // The icon press that closed the panel (the outside-click monitor or the panel losing key
        // runs first) must not open it again: it toggles closed. Each press is paired at most once.
        let press = dismissingPress
        dismissingPress = nil
        if let press, let click = MenuBarPress(mouseDown: currentEvent()) {
            let thickness = NSStatusBar.system.thickness
            let sameClick = press.isSameClick(as: click, iconSize: iconFrame?.size ?? NSSize(width: thickness, height: thickness))
            BridgeyLog.line(BridgeyLog.windows, "menu panel icon press after outside close same_click=\(sameClick)")
            if sameClick { return }
        }
        open(byDrag: false)
    }

    /// Closes on outside interaction, remembering the press so the icon's own mouse-down for it is ignored.
    func dismissFromOutside(event: NSEvent? = nil) {
        guard isOpen else { return }
        let event = event ?? currentEvent()
        // Not limited to the icon frame: the icon is also drawn in the other display's menu bar, where
        // iconFrame is stale until that press moves it. A press elsewhere never matches an icon click.
        dismissingPress = MenuBarPress(mouseDown: event)
            ?? MenuBarPress(location: pointerLocation(), timestamp: event?.timestamp ?? now(), button: nil)
        close()
    }

    /// Prepare the retained hierarchy once while hidden, without provider reads or showing anything.
    func prepareContent() {
        guard !panel.isVisible else { return }
        hosting.view.layoutSubtreeIfNeeded()
        fitToContent()
        guard panel.windowNumber <= 0 else { return }
        // Create and draw the window once, transparent, so the first entrance is not spent on that.
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        CATransaction.flush()
        BridgeyWindows.orderOut(panel)
    }

    func open(byDrag: Bool) {
        guard !isOpen else { return }
        dismissingPress = nil
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
        moveContent(opening: true, moves: motion == .move, fromHidden: !alreadyVisible)
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
            BridgeyWindows.fadeIn(panel, duration: Self.openingDuration, timing: MenuBarPanelMover.entrance) { [weak self] in
                self?.refreshAfterOpening(generation)
            }
        } else {
            refreshAfterOpening(generation)
        }
    }

    private func refreshAfterOpening(_ generation: Int) {
        // The shadow already follows the moving content on macOS 27; this guards compositors that cache it.
        panel.invalidateShadow()
        // A slow pasteboard provider must not block the entrance animation itself.
        scheduleOpenRefresh { [weak self] in
            guard let self, self.visibilityGeneration == generation, self.isOpen else { return }
            self.onDidOpen()
        }
    }

    /// Where the panel grows from: the icon's x, which is off centre when the panel is pushed in from a screen edge.
    private var pivotX: CGFloat {
        (iconFrame?.midX ?? panel.frame.midX) - panel.frame.minX
    }

    private func moveContent(opening: Bool, moves: Bool, fromHidden: Bool = false) {
        guard let layer = contentLayer else { return }
        guard moves else { MenuBarPanelMover.reset(layer); return }
        let hidden = MenuBarPanelMover.hiddenTransform(for: layer, pivotX: pivotX)
        if opening {
            MenuBarPanelMover.move(layer, to: CATransform3DIdentity, from: fromHidden ? hidden : nil,
                                   duration: Self.openingDuration, curve: MenuBarPanelMover.entrance)
        } else {
            MenuBarPanelMover.move(layer, to: hidden, duration: Self.closingDuration, curve: MenuBarPanelMover.exit)
        }
    }

    func close(animated: Bool = true) {
        guard wantsOpen || panel.isVisible else { return }
        let wasDrag = openedByDrag
        let animate = animated && !wasDrag && !reduceMotion() && panelMotion() != .off
        moveContent(opening: false, moves: animate && panelMotion() == .move)
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
            BridgeyWindows.fadeOut(panel, duration: Self.closingDuration, timing: MenuBarPanelMover.exit)
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
