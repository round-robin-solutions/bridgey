import AppKit
import XCTest
@testable import BridgeyMac

final class SendSheetTests: XCTestCase {
    private let home = "/Users/rahul"

    func testRecentFilterKeepsOrdinaryFiles() {
        XCTAssertTrue(RecentFileFilter.include(path: "\(home)/Downloads/invoice.pdf", name: "invoice.pdf", size: 1_200, isDirectory: false, home: home))
        XCTAssertTrue(RecentFileFilter.include(path: "\(home)/Desktop/Trip/IMG_0001.HEIC", name: "IMG_0001.HEIC", size: 9, isDirectory: false, home: home))
    }

    func testRecentFilterDropsWhatNobodyMeansToSend() {
        let cases: [(String, String, Int64, Bool)] = [
            ("\(home)/Downloads/.DS_Store", ".DS_Store", 10, false),
            ("\(home)/Downloads/movie.mp4.crdownload", "movie.mp4.crdownload", 10, false),
            ("\(home)/Downloads/file.bridgey-part", "file.bridgey-part", 10, false),
            ("\(home)/Documents/~$report.docx", "~$report.docx", 10, false),
            ("\(home)/Documents/Notes", "Notes", 10, true),
            ("\(home)/Documents/empty.txt", "empty.txt", 0, false),
            ("\(home)/Documents/huge.iso", "huge.iso", FolderLimits.maxFileSize + 1, false),
            ("\(home)/Documents/My.app/Contents/Info.plist", "Info.plist", 10, false),
            ("\(home)/Documents/repo/.git/config", "config", 10, false),
            ("\(home)/Documents/web/node_modules/x/index.js", "index.js", 10, false),
            ("\(home)/Pictures/Photos Library.photoslibrary/originals/a.jpg", "a.jpg", 10, false),
            ("/Volumes/USB/file.txt", "file.txt", 10, false),
        ]
        for (path, name, size, directory) in cases {
            XCTAssertFalse(RecentFileFilter.include(path: path, name: name, size: size, isDirectory: directory, home: home), path)
        }
    }

    func testRecentOrderingIsNewestFirstWithoutRepeats() {
        let now = Date()
        let a = SendCandidate(url: URL(fileURLWithPath: "/a"), name: "a", size: 1, date: now.addingTimeInterval(-60), isDirectory: false)
        let b = SendCandidate(url: URL(fileURLWithPath: "/b"), name: "b", size: 1, date: now, isDirectory: false)
        let ordered = RecentFileFilter.ordered([a, b, a], limit: 10)
        XCTAssertEqual(ordered.map(\.name), ["b", "a"])
        XCTAssertEqual(RecentFileFilter.ordered([a, b], limit: 1).map(\.name), ["b"])
    }

    func testSelectionKeepsPickOrderForBadges() {
        var state = SendSheetState()
        let one = SendCandidate(url: URL(fileURLWithPath: "/1"), name: "1", size: 10, date: Date(), isDirectory: false)
        let two = SendCandidate(url: URL(fileURLWithPath: "/2"), name: "2", size: 20, date: Date(), isDirectory: false)
        state.recent = [one, two]
        state.selection = [two.url, one.url]
        XCTAssertEqual(state.position(of: two.url), 1)
        XCTAssertEqual(state.position(of: one.url), 2)
        XCTAssertEqual(state.selectedBytes, 30)
        XCTAssertFalse(state.canSend)
        state.targetID = "phone"
        XCTAssertTrue(state.canSend)
    }

    private func selectionState(_ count: Int = 10) -> SendSheetState {
        var state = SendSheetState()
        state.recent = (0..<count).map { index in
            SendCandidate(url: URL(fileURLWithPath: "/selection/\(index)"), name: "File \(index)", size: 10,
                          date: .distantPast, isDirectory: false)
        }
        return state
    }

    func testShiftHeldFromFirstClickSelectsAnInclusiveRangeAndCanShrinkOrReverse() {
        var state = selectionState()
        let urls = state.orderedURLs
        state.select(urls[3], shift: true)
        state.select(urls[8], shift: true)
        XCTAssertEqual(state.selection, Array(urls[3...8]))
        state.select(urls[5], shift: true)
        XCTAssertEqual(state.selection, Array(urls[3...5]))
        state.select(urls[1], shift: true)
        XCTAssertEqual(state.selection, Array(urls[1...3]))
        XCTAssertEqual(state.selectionAnchor, urls[3])
    }

    func testCommandShiftAddsAnAdjustableRangeWithoutLosingSeparatePicks() {
        var state = selectionState()
        let urls = state.orderedURLs
        state.select(urls[9], command: true)
        state.select(urls[2], command: true)
        state.select(urls[6], command: true, shift: true)
        XCTAssertEqual(state.selection, [urls[9]] + Array(urls[2...6]))
        state.select(urls[4], command: true, shift: true)
        XCTAssertEqual(state.selection, [urls[9]] + Array(urls[2...4]))
        state.select(urls[3], command: true)
        XCTAssertEqual(state.selection, [urls[9], urls[2], urls[4]])
        state.select(urls[5], shift: true)
        XCTAssertEqual(state.selection, Array(urls[3...5]))
    }

    func testOrdinarySendPickerClickStillTogglesInPickOrder() {
        var state = selectionState()
        let urls = state.orderedURLs
        state.select(urls[5]); state.select(urls[1]); state.select(urls[8])
        state.select(urls[1])
        XCTAssertEqual(state.selection, [urls[5], urls[8]])
        XCTAssertEqual(state.position(of: urls[8]), 2)
    }

    func testRangesFollowDisplayedGroupsAndFilesAreNotRepeated() {
        var state = selectionState(7)
        let items = state.recent
        state.added = Array(items[0...1])
        state.screenshots = [items[6], items[1]]
        XCTAssertEqual(state.displayedGroups.map(\.count), [2, 5, 0])
        state.select(items[1].url)
        state.select(items[5].url, shift: true)
        XCTAssertEqual(state.selection, items[1...5].map(\.url))
        state.selectAll()
        XCTAssertEqual(state.selection, items.map(\.url))
        XCTAssertEqual(state.selectedItems.count, 7)
    }

    func testVerticalMovementUsesTheActualShortRowsAtSectionBoundaries() {
        var state = selectionState(10)
        let items = state.recent
        state.added = Array(items[0..<3])
        state.select(items[2].url)
        state.moveSelection(.down, extending: false)
        XCTAssertEqual(state.focusedURL, items[5].url, "same column in the next section")
        state.moveSelection(.down, extending: true)
        XCTAssertEqual(state.focusedURL, items[9].url, "clamp to the final short row")
        XCTAssertEqual(state.selection, items[5...9].map(\.url))
        state.moveSelection(.up, extending: true)
        XCTAssertEqual(state.selection, items[4...5].map(\.url))
    }

    func testRefreshingRemovedFilesRetiresTheirAnchorAndCannotSelectHiddenItems() {
        var state = selectionState()
        let urls = state.orderedURLs
        state.select(urls[2]); state.select(urls[7], command: true)
        state.recent.removeAll { $0.url == urls[7] }
        state.reconcileSelection()
        XCTAssertNil(state.focusedURL)
        XCTAssertNil(state.selectionAnchor)
        XCTAssertEqual(state.selection, [urls[2]])
        state.select(urls[8], shift: true)
        XCTAssertEqual(state.selection, [urls[8]])
        state.select(urls[7], command: true)
        XCTAssertEqual(state.selection, [urls[8]])
    }

    @MainActor private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @MainActor func testSelectionKeysExtendToggleSelectAllAndClearBeforeDismissal() {
        var state = selectionState()
        let urls = state.orderedURLs
        XCTAssertTrue(state.handleSelectionKey(key(124)))
        XCTAssertEqual(state.selection, [urls[0]])
        XCTAssertTrue(state.handleSelectionKey(key(119, .shift)))
        XCTAssertEqual(state.selection, urls)
        XCTAssertTrue(state.handleSelectionKey(key(115, .shift)))
        XCTAssertEqual(state.selection, [urls[0]])
        XCTAssertTrue(state.handleSelectionKey(key(49)))
        XCTAssertTrue(state.selection.isEmpty)
        XCTAssertTrue(state.handleSelectionKey(key(0, .command, characters: "a")))
        XCTAssertEqual(state.selection, urls)
        XCTAssertTrue(state.handleSelectionKey(key(53)))
        XCTAssertTrue(state.selection.isEmpty)
        XCTAssertFalse(state.handleSelectionKey(key(53)), "an empty selection lets normal Escape dismissal proceed")
    }

    @MainActor func testSelectionKeysLeaveOtherModifiersAndDefaultReturnAlone() {
        var state = selectionState()
        XCTAssertFalse(state.handleSelectionKey(key(0, .control, characters: "a")))
        XCTAssertFalse(state.handleSelectionKey(key(124, .option)))
        XCTAssertFalse(state.handleSelectionKey(key(49, .shift)))
        XCTAssertFalse(state.handleSelectionKey(key(36)))
        XCTAssertTrue(state.selection.isEmpty)
    }

    @MainActor func testCommandSelectionKeyIsScopedToTheFileResponder() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let picker = SendSelectionKeyView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let text = NSTextField(frame: NSRect(x: 0, y: 110, width: 150, height: 24))
        window.contentView?.addSubview(picker)
        window.contentView?.addSubview(text)
        var calls = 0
        picker.handle = { _ in calls += 1; return true }
        XCTAssertTrue(window.makeFirstResponder(picker))
        XCTAssertTrue(picker.performKeyEquivalent(with: key(0, .command, characters: "a")))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(window.makeFirstResponder(text))
        _ = picker.performKeyEquivalent(with: key(0, .command, characters: "a"))
        XCTAssertEqual(calls, 1, "text selection must not change file picks")
    }

    @MainActor func testDefaultDevicePrefersLastConnected() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bridgey.tests.send.\(UUID().uuidString)"))
        let preferences = SendPreferences(defaults: defaults)
        XCTAssertEqual(preferences.defaultDevice(connected: ["a", "b"], selected: "b"), "b")
        preferences.rememberDevice("a")
        XCTAssertEqual(preferences.defaultDevice(connected: ["a", "b"], selected: "b"), "a")
        XCTAssertEqual(preferences.defaultDevice(connected: ["b"], selected: nil), "b")
        XCTAssertNil(preferences.defaultDevice(connected: [], selected: "a"))
        XCTAssertEqual(SendPreferences(defaults: defaults).lastDeviceID, "a")
        XCTAssertEqual(preferences.menuBarDropMode, .springOpen)
        XCTAssertEqual(preferences.optimization, .default)
    }

    func testFolderListingFallbackKeepsRecentFilesOnly() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let (items, _) = RecentFilesQuery.listFolders(home: home)
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60 - 60)
        for item in items {
            XCTAssertGreaterThanOrEqual(item.date, cutoff)
            XCTAssertFalse(item.name.hasPrefix("."))
            XCTAssertFalse(item.isDirectory)
        }
    }
}
