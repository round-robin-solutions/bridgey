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
