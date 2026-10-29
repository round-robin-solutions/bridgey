import AppKit
import Combine
import QuartzCore
import SwiftUI

// Files 2.0: the Photos and Videos grid as an AppKit collection view. The SwiftUI LazyVGrid it replaces kept
// every cell it had shown (1.5 GB after one scroll through 2,000 photos, 2026-10-28), rebuilt the day headers
// of the whole library on every redraw (about 100 ms each with 2,000 items, so a download's progress froze the
// window), and reported visibility through onAppear, which also fires for cells laid out ahead. The collection
// view reuses about two screens of cells, lays out 10,000 items without making views for them, and says exactly
// which items are on screen, which is what the thumbnail scheduler needs. Screenshots still draw the SwiftUI
// grid (PhoneMediaGrid), since ImageRenderer cannot draw AppKit views.

/// The grid's day sections, built once per listing change.
struct PhoneMediaSections: Equatable {
    struct Section: Equatable {
        let title: String
        let start: Int
        let count: Int
    }

    let entries: [PhoneFileEntry]
    let sections: [Section]

    static let empty = PhoneMediaSections(entries: [], sections: [])

    /// Consecutive items of the same day share a header (the phone sends them newest first by the day they were
    /// taken, so the header uses that day too when the phone sends it).
    static func make(_ entries: [PhoneFileEntry], now: Date) -> PhoneMediaSections {
        let calendar = Calendar.current
        var sections: [Section] = []
        var start = 0
        var currentDay: Date?
        var title = ""
        for (index, entry) in entries.enumerated() {
            let day = entry.dayDate.map { calendar.startOfDay(for: $0) }
            if index == 0 || day != currentDay {
                if index > 0 { sections.append(Section(title: title, start: start, count: index - start)) }
                start = index
                currentDay = day
                title = day.map { PhoneFilesText.day($0, now: now) } ?? L10n.text("phonefiles.day.unknown", fallback: "Earlier")
            }
        }
        if !entries.isEmpty { sections.append(Section(title: title, start: start, count: entries.count - start)) }
        return PhoneMediaSections(entries: entries, sections: sections)
    }

    func entry(at indexPath: IndexPath) -> PhoneFileEntry? {
        flatIndex(indexPath).map { entries[$0] }
    }

    func flatIndex(_ indexPath: IndexPath) -> Int? {
        guard indexPath.count == 2, sections.indices.contains(indexPath.section) else { return nil }
        let section = sections[indexPath.section]
        guard indexPath.item >= 0, indexPath.item < section.count else { return nil }
        return section.start + indexPath.item
    }

    func indexPath(ofFlat index: Int) -> IndexPath? {
        guard entries.indices.contains(index) else { return nil }
        var low = 0
        var high = sections.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if sections[middle].start <= index { low = middle } else { high = middle - 1 }
        }
        return IndexPath(item: index - sections[low].start, section: low)
    }
}

/// The grid in the Phone files window.
struct PhoneMediaCollection: NSViewRepresentable {
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    @Environment(\.brand) private var palette
    @Environment(\.brandReduceMotion) private var reduceMotion

    func makeCoordinator() -> PhoneMediaGridController { PhoneMediaGridController() }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        controller.promises = promises
        controller.quickLook = quickLook
        controller.showInFinder = showInFinder
        controller.update(model: model, palette: palette, reduceMotion: reduceMotion)
        return controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.quickLook = quickLook
        context.coordinator.showInFinder = showInFinder
        context.coordinator.update(model: model, palette: palette, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: PhoneMediaGridController) {
        coordinator.tearDown()
    }
}

@MainActor
final class PhoneMediaGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let scrollView = NSScrollView()
    let collectionView = PhoneGridCollectionView()
    let layout = PhoneGridLayout()
    private(set) weak var model: PhoneFilesModel?
    var promises: PhoneFilePromises?
    var quickLook: ([PhoneFileEntry]) -> Void = { _ in }
    var showInFinder: (URL) -> Void = { _ in }
    private(set) var sections = PhoneMediaSections.empty
    private var revision = -1
    private var palette = BrandPalette.dark
    private var reduceMotion = false
    private var lastOrigin: CGFloat = 0
    private var scrollingUp = false
    private var applyingSelection = false
    private var observers: [NSObjectProtocol] = []
    private var reportScheduled = false

    override init() {
        super.init()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(PhoneMediaItem.self, forItemWithIdentifier: PhoneMediaItem.identifier)
        collectionView.register(PhoneGridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                withIdentifier: PhoneGridHeader.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([], forLocal: true)
        collectionView.setAccessibilityLabel(PhoneFilesText.sectionTitle(.media))
        collectionView.autoresizingMask = [.width]
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        collectionView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: collectionView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReport() }
        })
        collectionView.onActivate = { [weak self] indexPath in
            guard let self, let entry = self.sections.entry(at: indexPath) else { return }
            self.model?.activate(entry)
        }
        collectionView.onMenu = { [weak self] indexPath in
            guard let self, let model = self.model, let entry = self.sections.entry(at: indexPath) else { return nil }
            return PhoneItemMenus.menu(for: entry, model: model, quickLook: self.quickLook, showInFinder: self.showInFinder)
        }
        collectionView.onKey = { [weak self] event in self?.key(event) ?? false }
    }

    func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    // MARK: Model

    func update(model: PhoneFilesModel, palette: BrandPalette, reduceMotion: Bool) {
        let firstModel = self.model !== model
        self.model = model
        let restyle = palette != self.palette || reduceMotion != self.reduceMotion
        self.palette = palette
        self.reduceMotion = reduceMotion
        if firstModel || model.mediaRevision != revision {
            revision = model.mediaRevision
            sections = PhoneMediaSections.make(model.listing(.media).entries, now: model.displayNow ?? Date())
            collectionView.reloadData()
            scheduleReport()
            if firstModel {
                // Space, Return and the arrows work at once, without clicking into the grid first.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let view = self?.collectionView, let window = view.window, !(window.firstResponder is NSTextView) else { return }
                        window.makeFirstResponder(view)
                    }
                }
            }
        } else if restyle {
            restyleVisible()
        }
        applySelection(model.selection)
    }

    private func restyleVisible() {
        for case let item as PhoneMediaItem in collectionView.visibleItems() {
            item.cell.restyle(palette: palette, reduceMotion: reduceMotion)
        }
        for case let header as PhoneGridHeader in collectionView.visibleSupplementaryViews(ofKind: NSCollectionView.elementKindSectionHeader) {
            header.restyle(palette: palette)
        }
    }

    private func applySelection(_ ids: Set<String>) {
        let current = Set(collectionView.selectionIndexPaths.compactMap { sections.entry(at: $0)?.id })
        guard current != ids else { return }
        var paths = Set<IndexPath>()
        if !ids.isEmpty {
            for (index, entry) in sections.entries.enumerated() where ids.contains(entry.id) {
                if let path = sections.indexPath(ofFlat: index) { paths.insert(path) }
            }
        }
        applyingSelection = true
        collectionView.selectionIndexPaths = paths
        applyingSelection = false
    }

    private func pushSelection() {
        guard !applyingSelection, let model else { return }
        let ids = Set(collectionView.selectionIndexPaths.compactMap { sections.entry(at: $0)?.id })
        if ids != model.selection { model.selection = ids }
    }

    // MARK: What is on screen

    private func scrolled() {
        let origin = scrollView.contentView.bounds.origin.y
        if origin != lastOrigin {
            scrollingUp = origin < lastOrigin
            lastOrigin = origin
        }
        reportVisible()
    }

    private func scheduleReport() {
        guard !reportScheduled else { return }
        reportScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.reportScheduled = false
                self?.reportVisible()
            }
        }
    }

    /// Tells the scheduler which items are on screen (in order) and which come next in the scroll direction
    /// (two screens ahead, half a screen behind), and loads the next page well before the end.
    func reportVisible() {
        guard let model else { return }
        let rect = collectionView.visibleRect
        guard rect.width > 0, rect.height > 0 else { return }
        let paths = layout.layoutAttributesForElements(in: rect)
            .filter { $0.representedElementCategory == .item }
            .compactMap(\.indexPath)
            .sorted()
        let visible = paths.compactMap { sections.entry(at: $0) }
        let flats = paths.compactMap { sections.flatIndex($0) }
        var ahead: [PhoneFileEntry] = []
        if let low = flats.min(), let high = flats.max() {
            let entries = sections.entries
            let screen = high - low + 1
            let forward = max(PhoneThumbnailScheduler.prefetchAhead, screen * 2)
            let backward = max(12, screen / 2)
            let after = Array(entries[min(entries.count, high + 1)..<min(entries.count, high + 1 + (scrollingUp ? backward : forward))])
            let before = Array(entries[max(0, low - (scrollingUp ? forward : backward))..<low].reversed())
            ahead = scrollingUp ? before + after : after + before
            if high >= entries.count - 60 { model.loadMore() }
        }
        model.thumbnails.setVisible(visible, ahead: ahead)
    }

    // MARK: Keys

    private func key(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        // Command-Y (Quick Look) is the window's key equivalent.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if model.preview != nil {
            switch event.keyCode {
            case 49, 53: model.closePreview()
            case 123: model.showAdjacent(-1)
            case 124: model.showAdjacent(1)
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 49 where flags.isEmpty:
            model.togglePreview()
            return true
        case 36, 76:
            if let first = collectionView.selectionIndexPaths.sorted().first, let entry = sections.entry(at: first) { model.activate(entry) }
            return true
        default:
            return false
        }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.sections.indices.contains(section) ? sections.sections[section].count : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhoneMediaItem.identifier, for: indexPath) as? PhoneMediaItem ?? PhoneMediaItem()
        if let model, let entry = sections.entry(at: indexPath) {
            item.cell.bind(entry: entry, box: model.thumbnails.box(for: entry), palette: palette, reduceMotion: reduceMotion)
            item.cell.onHover = { [weak model] inside in
                if inside { model?.prefetch.hoverBegan(entry) } else { model?.prefetch.hoverEnded(entry) }
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PhoneGridHeader.identifier, for: indexPath) as? PhoneGridHeader
            ?? PhoneGridHeader()
        view.configure(title: sections.sections.indices.contains(indexPath.section) ? sections.sections[indexPath.section].title : "", palette: palette)
        return view
    }

    // MARK: Delegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        promises != nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let promises, let entry = sections.entry(at: indexPath) else { return nil }
        return promises.provider(for: entry)
    }
}

/// The grid's collection view: double click and Return open, a right click selects and shows the menu, Space
/// previews; everything else (arrows, Command and Shift clicks, rubber band, drags) is NSCollectionView's own.
final class PhoneGridCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?
    var onMenu: ((IndexPath) -> NSMenu?)?
    var onKey: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onActivate?(indexPath)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            delegate?.collectionView?(self, didSelectItemsAt: [indexPath])
        }
        return onMenu?(indexPath)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// Square cells as wide as the columns allow: 118 to 142 points, 4 points apart, 16 points from the edges,
/// a day header above each section. Recomputed whenever the width changes.
final class PhoneGridLayout: NSCollectionViewFlowLayout {
    static let minCell: CGFloat = PhoneMediaGrid.cell
    static let maxCell: CGFloat = PhoneMediaGrid.cell + 24
    static let spacing: CGFloat = 4
    static let inset: CGFloat = 16
    static let header: CGFloat = 38

    override init() {
        super.init()
        minimumInteritemSpacing = Self.spacing
        minimumLineSpacing = Self.spacing
        scrollDirection = .vertical
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func prepare() {
        if let width = collectionView?.bounds.width, width > 0 { apply(width: width) }
        super.prepare()
    }

    func apply(width: CGFloat) {
        let side = Self.side(for: width)
        itemSize = NSSize(width: side, height: side)
        sectionInset = NSEdgeInsets(top: 0, left: Self.inset, bottom: 6, right: Self.inset)
        headerReferenceSize = NSSize(width: width, height: Self.header)
    }

    /// The cell side for a width: as many 118 pt columns as fit, then stretched up to 142 pt.
    static func side(for width: CGFloat) -> CGFloat {
        let available = max(minCell, width - 2 * inset)
        let columns = max(1, Int((available + spacing) / (minCell + spacing)))
        return min(maxCell, floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns)))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

final class PhoneMediaItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhoneMediaItem")
    let cell = PhoneMediaCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))

    override func loadView() { view = cell }

    override var isSelected: Bool {
        didSet { cell.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cell.unbind()
    }
}

/// One cell, drawn with layers: the tinted placeholder (or a clear "no preview" mark once the phone has no
/// picture, or "couldn't load" after the retries), the thumbnail cropped to a square, the duration of a video,
/// and the selection ring with its check mark.
final class PhoneMediaCellView: NSView {
    private let imageLayer = CALayer()
    private let symbolView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var subscription: AnyCancellable?
    private var entry: PhoneFileEntry?
    private weak var box: ThumbnailBox?
    private var palette = BrandPalette.dark
    private var reduceMotion = false
    private var tracking: NSTrackingArea?
    private var hovering = false
    /// The appearance the check mark was drawn for.
    private var checkDark: Bool?
    var onHover: ((Bool) -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { updateRing() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        caption.font = BrandFont.nsBody(10, .medium)
        caption.alignment = .center
        caption.isHidden = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 9
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = true
        check.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)
        for view in [symbolView, caption, badge, check] { addSubview(view) }
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            caption.topAnchor.constraint(equalTo: symbolView.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badgeLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            badgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            check.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateRing()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateRing()
        onHover?(false)
    }

    func bind(entry: PhoneFileEntry, box: ThumbnailBox, palette: BrandPalette, reduceMotion: Bool) {
        self.entry = entry
        self.box = box
        self.palette = palette
        self.reduceMotion = reduceMotion
        if let duration = PhoneFilesText.duration(entry.durationMs) {
            badgeLabel.stringValue = "\u{25B6}\u{FE0E} " + duration
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }
        setAccessibilityLabel(entry.name)
        imageLayer.contents = nil
        render(animated: false)
        subscription = box.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value changes: draw on the next turn.
            DispatchQueue.main.async { self?.render(animated: true) }
        }
        updateRing()
    }

    func unbind() {
        subscription = nil
        entry = nil
        box = nil
        onHover = nil
        hovering = false
        imageLayer.contents = nil
        imageLayer.isHidden = true
    }

    func restyle(palette: BrandPalette, reduceMotion: Bool) {
        self.palette = palette
        self.reduceMotion = reduceMotion
        render(animated: false)
        updateRing()
    }

    /// What the cell shows for its box right now.
    private(set) var shownState: ThumbnailState = .waiting

    private func render(animated: Bool) {
        guard let entry else { return }
        let image = box?.image
        let state = box?.state ?? .waiting
        shownState = image == nil ? (state == .loaded ? .waiting : state) : .loaded
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image {
            if animated, box?.arrived == true, !reduceMotion, imageLayer.contents == nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                imageLayer.add(fade, forKey: "fade")
            }
            imageLayer.contents = image.image
            imageLayer.isHidden = false
            layer?.backgroundColor = NSColor(palette.s3).cgColor
            symbolView.isHidden = true
            caption.isHidden = true
            setAccessibilityValue(nil)
        } else {
            imageLayer.contents = nil
            imageLayer.isHidden = true
            let symbol = PhoneFilesText.symbol(entry)
            switch shownState {
            case .unavailable:
                layer?.backgroundColor = NSColor(palette.s2).cgColor
                show(symbol: symbol, size: 22, color: NSColor(palette.on2))
                caption.stringValue = L10n.text("phonefiles.thumb.none", fallback: "No preview")
                caption.textColor = NSColor(palette.on2)
                caption.isHidden = false
                setAccessibilityValue(caption.stringValue)
            case .failed:
                layer?.backgroundColor = NSColor(palette.s2).cgColor
                show(symbol: "exclamationmark.triangle", size: 20, color: NSColor(palette.warn))
                caption.stringValue = L10n.text("phonefiles.thumb.failed", fallback: "Couldn't load")
                caption.textColor = NSColor(palette.on2)
                caption.isHidden = false
                setAccessibilityValue(caption.stringValue)
            case .waiting, .loaded:
                if let tint = box?.tint {
                    layer?.backgroundColor = NSColor(Color(hex: tint)).cgColor
                    symbolView.isHidden = true
                } else {
                    layer?.backgroundColor = NSColor(palette.s3).cgColor
                    show(symbol: symbol, size: 18, color: NSColor(palette.on2).withAlphaComponent(0.6))
                }
                caption.isHidden = true
                setAccessibilityValue(nil)
            }
        }
        CATransaction.commit()
    }

    private func show(symbol: String, size: CGFloat, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbolView.contentTintColor = color
        symbolView.isHidden = false
    }

    private func updateRing() {
        let selected = isSelected
        layer?.borderWidth = selected ? 3 : (hovering ? 1 : 0)
        layer?.borderColor = (selected ? NSColor(palette.pri) : NSColor(palette.ol)).cgColor
        check.isHidden = !selected
        if selected, checkDark != palette.isDark {
            checkDark = palette.isDark
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(palette.onpri), NSColor(palette.pri)]))
            check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        setAccessibilitySelected(selected)
    }
}

/// A day's header ("Today", "12 October").
final class PhoneGridHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PhoneGridHeader")
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = BrandFont.nsBody(13, .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PhoneGridLayout.inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PhoneGridLayout.inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title: String, palette: BrandPalette) {
        label.stringValue = title
        label.textColor = NSColor(palette.on)
        setAccessibilityLabel(title)
    }

    func restyle(palette: BrandPalette) {
        label.textColor = NSColor(palette.on)
    }
}
