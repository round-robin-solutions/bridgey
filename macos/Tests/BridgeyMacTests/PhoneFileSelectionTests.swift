import AppKit
import XCTest
@testable import BridgeyMac

@MainActor
final class PhoneFileSelectionTests: XCTestCase {
    private var suites: [String] = []

    override func tearDownWithError() throws {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func model(_ entries: [PhoneFileEntry] = UIFakeImages.media(12)) -> PhoneFilesModel {
        let fake = UIFakePhoneFiles()
        let suite = "phone-file-selection-\(UUID().uuidString)"
        suites.append(suite)
        let model = PhoneFilesModel(service: fake, cache: PhoneThumbnailCache(directory: nil),
                                   defaults: UserDefaults(suiteName: suite)!, listingCache: PhoneListingCache(directory: nil))
        model.setForTesting(phones: fake.phones, phoneID: UIFakeImages.phoneID, info: fake.info, section: .media,
                            listings: [.media: PhoneListing(entries: entries, loaded: true)])
        return model
    }

    private func key(_ code: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func mouse(window: NSWindow, type: NSEvent.EventType = .leftMouseDown, count: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: flags,
                           timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: count, pressure: 1)!
    }

    private func window() -> PhoneFilesNSWindow {
        let window = PhoneFilesNSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testShiftHeldForFirstClickThenRangeShrinksAndReversesFromTheSameAnchor() {
        let model = model()
        let entries = model.currentEntries
        model.click(entries[3], command: false, shift: true)
        model.click(entries[8], command: false, shift: true)
        XCTAssertEqual(model.selection, Set(entries[3...8].map(\.id)))
        model.click(entries[5], command: false, shift: true)
        XCTAssertEqual(model.selection, Set(entries[3...5].map(\.id)))
        model.click(entries[1], command: false, shift: true)
        XCTAssertEqual(model.selection, Set(entries[1...3].map(\.id)))
    }

    func testCommandShiftRangePreservesOtherPicksAndShrinksItsOwnExtension() {
        let model = model()
        let entries = model.currentEntries
        model.click(entries[0], command: false, shift: false)
        model.click(entries[8], command: true, shift: false)
        model.click(entries[5], command: true, shift: true)
        XCTAssertEqual(model.selection, Set([entries[0].id] + entries[5...8].map(\.id)))
        model.click(entries[7], command: true, shift: true)
        XCTAssertEqual(model.selection, Set([entries[0].id, entries[7].id, entries[8].id]))
    }

    func testPreviewNavigationRetiresThePreviousAdditiveRangeBase() {
        let model = model()
        let entries = model.currentEntries
        model.click(entries[0], command: false, shift: false)
        model.click(entries[2], command: true, shift: false)
        model.click(entries[4], command: true, shift: true)
        model.setPreviewForTesting(PhonePreviewState(entry: entries[0], openedAt: Date()), image: nil)
        model.showAdjacent(1)
        model.closePreview()
        model.click(entries[3], command: true, shift: true)
        XCTAssertEqual(model.selection, Set(entries[1...3].map(\.id)))
    }

    func testShiftArrowsAndEndpointsKeepTheirAnchorAndExposeTheKeyboardFocus() {
        let model = model()
        let entries = model.currentEntries
        model.click(entries[3], command: false, shift: false)
        XCTAssertTrue(model.selectionKey(key(125, flags: .shift)))
        XCTAssertTrue(model.selectionKey(key(125, flags: .shift)))
        XCTAssertEqual(model.selection, Set(entries[3...5].map(\.id)))
        XCTAssertTrue(model.selectionKey(key(126, flags: .shift)))
        XCTAssertEqual(model.selection, Set(entries[3...4].map(\.id)))
        XCTAssertTrue(model.selectionKey(key(115, flags: .shift)))
        XCTAssertEqual(model.selection, Set(entries[0...3].map(\.id)))
        XCTAssertTrue(model.selectionKey(key(119, flags: .shift)))
        XCTAssertEqual(model.selection, Set(entries[3...11].map(\.id)))
        XCTAssertEqual(model.selectionFocus, entries[11].id)
        XCTAssertTrue(model.keyboardSelection)
        XCTAssertFalse(model.selectionKey(key(125, flags: .option)), "unrelated modified navigation stays with AppKit")
    }

    func testAppendingAPageRetainsTheAnchorButRemovingItsItemRetiresIt() {
        let entries = UIFakeImages.media(12)
        let model = model(Array(entries.prefix(4)))
        model.click(entries[1], command: false, shift: false)
        model.setForTesting(phones: model.phones, phoneID: model.phoneID, info: model.info, section: .media,
                            listings: [.media: PhoneListing(entries: entries, loaded: true)])
        model.click(entries[8], command: false, shift: true)
        XCTAssertEqual(model.selection, Set(entries[1...8].map(\.id)))
        let remaining = Array(entries.dropFirst(3))
        model.setForTesting(phones: model.phones, phoneID: model.phoneID, info: model.info, section: .media,
                            listings: [.media: PhoneListing(entries: remaining, loaded: true)])
        let surviving = model.selection
        model.click(entries[1], command: false, shift: false)
        XCTAssertEqual(model.selection, surviving, "an old row cannot reinsert a hidden item")
        model.click(entries[5], command: false, shift: true)
        XCTAssertEqual(model.selection, [entries[5].id], "a removed anchor must not select an unrelated range")
    }

    func testChangingSectionClearsSelectionAndAnchorEvenWhenIDsRepeat() {
        let model = model()
        let entries = model.currentEntries
        model.click(entries[1], command: false, shift: false)
        model.setForTesting(phones: model.phones, phoneID: model.phoneID, info: model.info, section: .files,
                            listings: [.media: model.currentListing, .files: PhoneListing(entries: entries, loaded: true)])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.selectionFocus)
        model.click(entries[5], command: false, shift: true)
        XCTAssertEqual(model.selection, [entries[5].id])
    }

    func testSelectAllIsLoadedOnlyAndEscapeClearsBeforeAnyFurtherAction() {
        let model = model()
        let entries = model.currentEntries
        XCTAssertTrue(model.selectionKey(key(0, characters: "a", flags: .command)))
        XCTAssertEqual(model.selection, Set(entries.map(\.id)))
        XCTAssertEqual(model.selectionFocus, entries.first?.id, "Select All must not scroll into the paging trigger")
        XCTAssertTrue(model.selectionKey(key(53)))
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.selectionFocus)
        XCTAssertFalse(model.selectionKey(key(53)))
    }

    func testChangingPhoneRetiresSelectionAndRangeAnchor() {
        let model = model()
        let entries = model.currentEntries
        let phones = model.phones
        let info = model.info
        model.click(entries[1], command: false, shift: false)
        model.select(phone: nil)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.selectionFocus)
        model.setForTesting(phones: phones, phoneID: UIFakeImages.phoneID, info: info, section: .media,
                            listings: [.media: PhoneListing(entries: entries, loaded: true)])
        model.click(entries[5], command: false, shift: true)
        XCTAssertEqual(model.selection, [entries[5].id])
    }

    func testListWindowDispatchesShortcutsOnlyFromItsFileResponder() {
        let model = model()
        let window = window()
        defer { window.close() }
        let root = NSView(frame: window.contentView!.bounds)
        let scope = PhoneFileListKeyboardScope.KeyView(frame: root.bounds)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(scope)
        root.addSubview(editor)
        window.contentView = root
        var dispatched = 0
        window.onSelectionKey = { event in dispatched += 1; return model.selectionKey(event) }
        XCTAssertTrue(window.makeFirstResponder(scope))
        XCTAssertTrue(window.performKeyEquivalent(with: key(0, characters: "a", flags: .command, window: window)))
        XCTAssertEqual(model.selection.count, 12)
        let before = dispatched
        XCTAssertTrue(window.makeFirstResponder(editor))
        _ = window.performKeyEquivalent(with: key(0, characters: "a", flags: .command, window: window))
        XCTAssertEqual(dispatched, before)
        XCTAssertEqual(model.selection.count, 12)
        XCTAssertTrue(window.makeFirstResponder(scope))
        window.keyDown(with: key(53, window: window))
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testContextClickAndDragPreparationKeepAnExistingMultiSelection() {
        let model = model()
        let entries = model.currentEntries
        model.click(entries[1], command: false, shift: false)
        model.click(entries[5], command: false, shift: true)
        let window = window()
        defer { window.close() }
        let view = PhoneItemInteraction.InteractionView(frame: NSRect(x: 0, y: 0, width: 100, height: 48))
        window.contentView = view
        view.actions.click = { command, shift in model.click(entries[3], command: command, shift: shift) }
        view.actions.isSelected = { model.selection.contains(entries[3].id) }
        view.actions.dragEntries = { model.targets(for: entries[3]) }
        _ = view.menu(for: mouse(window: window, type: .rightMouseDown))
        XCTAssertEqual(model.selection.count, 5)
        view.mouseDown(with: mouse(window: window))
        XCTAssertEqual(view.actions.dragEntries().count, 5, "drag setup sees the intact selection before mouse-up")
        view.mouseUp(with: mouse(window: window, type: .leftMouseUp))
        XCTAssertEqual(model.selection, [entries[3].id], "an ordinary completed click still selects one item")
    }

    func testEscapeClosesPreviewBeforeClearingTheFileSelection() {
        let model = model()
        let entry = model.currentEntries[1]
        model.click(entry, command: false, shift: false)
        model.setPreviewForTesting(PhonePreviewState(entry: entry, openedAt: Date()), image: nil)
        let window = window()
        defer { window.close() }
        let scope = PhoneFileListKeyboardScope.KeyView(frame: window.contentView!.bounds)
        window.contentView = scope
        window.onSelectionKey = { model.selectionKey($0) }
        window.previewActive = { model.preview != nil }
        window.onEscape = {
            if model.preview != nil { model.closePreview(); return true }
            return model.clearSelection()
        }
        XCTAssertTrue(window.makeFirstResponder(scope))
        window.keyDown(with: key(53, window: window))
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.selection, [entry.id])
        window.keyDown(with: key(53, window: window))
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testModifiedDoubleClickExtendsSelectionInsteadOfOpeningTheFile() {
        let window = window()
        defer { window.close() }
        let view = PhoneItemInteraction.InteractionView(frame: NSRect(x: 0, y: 0, width: 100, height: 48))
        window.contentView = view
        var activated = false
        var shift = false
        view.actions.activate = { activated = true }
        view.actions.click = { _, value in shift = value }
        view.mouseDown(with: mouse(window: window, count: 2, flags: .shift))
        XCTAssertFalse(activated)
        XCTAssertTrue(shift)
    }

    func testNativeMediaGridSelectAllAndEscapeStayScopedToTheGrid() {
        let model = model()
        let window = window()
        let controller = PhoneMediaGridController()
        defer { controller.tearDown(); window.close() }
        controller.scrollView.frame = window.contentView!.bounds
        let root = NSView(frame: window.contentView!.bounds)
        root.addSubview(controller.scrollView)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(editor)
        window.contentView = root
        controller.update(model: model, palette: .dark, reduceMotion: true)
        window.layoutIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(controller.collectionView))
        XCTAssertTrue(controller.collectionView.performKeyEquivalent(with: key(0, characters: "a", flags: .command, window: window)))
        XCTAssertEqual(model.selection.count, 12)
        XCTAssertEqual(controller.collectionView.selectionIndexPaths.count, 12)
        controller.collectionView.keyDown(with: key(53, window: window))
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(controller.collectionView.selectionIndexPaths.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(controller.collectionView.performKeyEquivalent(with: key(0, characters: "a", flags: .command, window: window)))
        XCTAssertTrue(model.selection.isEmpty)
    }
}
