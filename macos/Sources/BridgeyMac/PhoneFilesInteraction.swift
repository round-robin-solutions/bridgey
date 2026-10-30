import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

// Files 2.0: the AppKit pieces under the Phone files window's SwiftUI cells: clicks with Command and Shift,
// double clicks, hover (for prefetch), real file promises when dragging to Finder (each item downloads into
// the folder Finder names, with progress), the context menu, and Quick Look.

/// Everything a cell can do, set by the view that draws it.
struct PhoneItemActions {
    var click: (_ command: Bool, _ shift: Bool) -> Void = { _, _ in }
    var activate: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
    /// The entries a drag carries (the selection when this item is in it).
    var dragEntries: () -> [PhoneFileEntry] = { [] }
    var menu: () -> NSMenu? = { nil }
}

/// A transparent AppKit layer over a cell. Left out while screenshots render (ImageRenderer cannot draw it).
struct PhoneItemInteraction: NSViewRepresentable {
    let actions: PhoneItemActions
    let promises: PhoneFilePromises

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.actions = actions
        view.promises = promises
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.actions = actions
        view.promises = promises
    }

    final class InteractionView: NSView, NSDraggingSource {
        var actions = PhoneItemActions()
        var promises: PhoneFilePromises?
        private var downEvent: NSEvent?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { actions.hover(true) }
        override func mouseExited(with event: NSEvent) { actions.hover(false) }

        override func mouseDown(with event: NSEvent) {
            downEvent = event
            if event.clickCount >= 2 {
                actions.activate()
                downEvent = nil
                return
            }
            let flags = event.modifierFlags
            actions.click(flags.contains(.command), flags.contains(.shift))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, let promises else { return }
            let start = down.locationInWindow, now = event.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
            downEvent = nil
            let entries = actions.dragEntries()
            guard !entries.isEmpty else { return }
            let items: [NSDraggingItem] = entries.enumerated().map { offset, entry in
                let provider = promises.provider(for: entry)
                let item = NSDraggingItem(pasteboardWriter: provider)
                let image = NSWorkspace.shared.icon(for: PhoneFilesText.uniformType(entry))
                image.size = NSSize(width: 48, height: 48)
                let origin = convert(event.locationInWindow, from: nil)
                item.setDraggingFrame(NSRect(x: origin.x - 24 + CGFloat(offset * 6), y: origin.y - 24 - CGFloat(offset * 6), width: 48, height: 48), contents: image)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) { downEvent = nil }

        override func menu(for event: NSEvent) -> NSMenu? {
            actions.click(false, false)
            return actions.menu()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// File promises for drags to Finder: Finder names the folder, Bridgey downloads into it (purpose dragOut).
@MainActor
final class PhoneFilePromises: NSObject, NSFilePromiseProviderDelegate {
    weak var model: PhoneFilesModel?
    private var live: [ObjectIdentifier: (provider: NSFilePromiseProvider, entry: PhoneFileEntry)] = [:]
    /// File names by provider, readable from any thread: AppKit asks for the name wherever the drag runs.
    nonisolated private let names = PhoneLockedMap<ObjectIdentifier, String>()

    init(model: PhoneFilesModel?) {
        self.model = model
    }

    func provider(for entry: PhoneFileEntry) -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: PhoneFilesText.uniformType(entry).identifier, delegate: self)
        provider.userInfo = entry.id
        live[ObjectIdentifier(provider)] = (provider, entry)
        names[ObjectIdentifier(provider)] = entry.name
        return provider
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        names[ObjectIdentifier(provider)] ?? "Bridgey item"
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        // The operation queue above is the main queue.
        MainActor.assumeIsolated {
            guard let entry = live[ObjectIdentifier(provider)]?.entry, let model else {
                completionHandler(CocoaError(.fileWriteUnknown))
                return
            }
            model.download([entry], into: url.deletingLastPathComponent(), purpose: .dragOut) { [weak self] result in
                self?.live.removeValue(forKey: ObjectIdentifier(provider))
                self?.names[ObjectIdentifier(provider)] = nil
                switch result {
                case .success: completionHandler(nil)
                case let .failure(error): completionHandler(error == .cancelled ? CocoaError(.userCancelled) : CocoaError(.fileWriteUnknown))
                }
            }
        }
    }
}

/// A small dictionary behind a lock, for values AppKit reads off the main thread.
final class PhoneLockedMap<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { lock.withLock { values[key] } }
        set { lock.withLock { values[key] = newValue } }
    }
}

/// Quick Look's data source: a fixed list of local files. The panel holds its data source without retaining it
/// (`assign`), so the window controller keeps this object alive, and the panel may ask from any thread, so the
/// list is a snapshot behind a lock rather than main-actor state.
final class PhoneQuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var items: [URL] {
        get { lock.withLock { urls } }
        set { lock.withLock { urls = newValue } }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let list = items
        return list.indices.contains(index) ? list[index] as NSURL : nil
    }
}

/// The Phone files window: its own class so it can drive Quick Look and the keys of the viewer.
@MainActor
final class PhoneFilesNSWindow: NSWindow {
    let quickLookSource = PhoneQuickLookSource()
    var onSpace: (() -> Void)?
    var onEscape: (() -> Bool)?
    /// Left and right while the viewer is open; true when handled.
    var onArrow: ((Int) -> Bool)?
    /// Command-Y when the grid does not have the keyboard (the file lists, the viewer's buttons).
    var onQuickLook: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 16, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, let onQuickLook {
            onQuickLook()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !(firstResponder is NSTextView) {
            switch event.keyCode {
            case 49:
                if let onSpace {
                    onSpace()
                    return
                }
            case 53:
                if onEscape?() == true { return }
            case 123:
                if onArrow?(-1) == true { return }
            case 124:
                if onArrow?(1) == true { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

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

    /// Closes the panel when it shows this window's files; true when it did.
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
        // The panel keeps a pointer to the data source; let it go before the window does.
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.dataSource === quickLookSource {
            panel.orderOut(nil)
            panel.dataSource = nil
            panel.delegate = nil
        }
        super.close()
    }
}

/// Builds a cell's context menu.
@MainActor
enum PhoneItemMenu {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func make(_ items: [(String, Bool, () -> Void)]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, enabled, action) in items {
            let target = Target(action)
            let item = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }
}
