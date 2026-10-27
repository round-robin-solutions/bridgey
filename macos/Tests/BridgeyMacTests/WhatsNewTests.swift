import Foundation
import XCTest
@testable import BridgeyMac

final class WhatsNewTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "bridgey-whatsnew-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFreshInstallNeverShowsButRecordsTheBuild() {
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 90, lastBuild: nil, freshInstall: true, hasNotes: true, reviewSetup: false),
                       .skip(record: true))
    }

    func testSameBuildIsNotShownAgain() {
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 90, lastBuild: 90, freshInstall: false, hasNotes: true, reviewSetup: false),
                       .skip(record: false))
    }

    func testNewerBuildShowsOnce() {
        let store = WhatsNewStore(defaults: defaults)
        store.record(build: 89, version: "0.10.0-rr.1-beta.1")
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 90, lastBuild: store.lastBuild, freshInstall: false, hasNotes: true, reviewSetup: false),
                       .show(reviewSetup: false))
        store.record(build: 90, version: "0.10.0-rr.1-beta.2")
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 90, lastBuild: store.lastBuild, freshInstall: false, hasNotes: true, reviewSetup: false),
                       .skip(record: false))
        XCTAssertEqual(defaults.string(forKey: WhatsNewStore.lastVersionKey), "0.10.0-rr.1-beta.2")
    }

    func testDowngradeShowsNothingAndKeepsTheNewerRecord() {
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 88, lastBuild: 90, freshInstall: false, hasNotes: true, reviewSetup: false),
                       .skip(record: false))
    }

    func testNotesMissingSkipsUnlessSetupNeedsReviewing() {
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 90, lastBuild: 80, freshInstall: false, hasNotes: false, reviewSetup: false),
                       .skip(record: true))
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 90, lastBuild: nil, freshInstall: false, hasNotes: false, reviewSetup: true),
                       .show(reviewSetup: true))
    }

    func testUpdateFromBeforeWhatsNewExistedShowsWithReviewSetup() {
        XCTAssertEqual(WhatsNewLogic.decide(currentBuild: 90, lastBuild: nil, freshInstall: false, hasNotes: true, reviewSetup: true),
                       .show(reviewSetup: true))
    }

    func testOfferedNotesWinOverBundledNotesAndBlankNotesCountAsMissing() {
        let store = WhatsNewStore(defaults: defaults)
        XCTAssertNil(store.notes(version: "0.10.0-rr.1", bundled: nil))
        XCTAssertNil(store.notes(version: "0.10.0-rr.1", bundled: "  \n"))
        XCTAssertEqual(store.notes(version: "0.10.0-rr.1", bundled: "Bundled"), "Bundled")
        store.rememberOffered(version: "0.10.0-rr.1", notes: "- From the feed")
        XCTAssertEqual(store.notes(version: "0.10.0-rr.1", bundled: "Bundled"), "- From the feed")
        XCTAssertEqual(store.notes(version: "0.10.0-rr.2", bundled: "Bundled"), "Bundled")
    }

    func testOfferedNotesKeepOnlyTheNewestFew() {
        let store = WhatsNewStore(defaults: defaults)
        for minor in 1...6 { store.rememberOffered(version: "0.10.\(minor)-rr.1", notes: "notes \(minor)") }
        let kept = defaults.dictionary(forKey: WhatsNewStore.offeredNotesKey) ?? [:]
        XCTAssertEqual(kept.count, WhatsNewStore.maximumOffered)
        XCTAssertEqual(store.offeredNotes(version: "0.10.6-rr.1"), "notes 6")
        XCTAssertNil(store.offeredNotes(version: "0.10.1-rr.1"))
    }

    func testContentUsesTheUpdatesCardParser() {
        let content = WhatsNewContent.make(version: "0.10.0-rr.1", notes: "## 0.10.0-rr.1\n- Setup on first run\n- Reset Bridgey", reviewSetup: true)
        XCTAssertEqual(content.blocks, [.bullet("Setup on first run"), .bullet("Reset Bridgey")])
        XCTAssertTrue(content.reviewSetup)
        XCTAssertEqual(WhatsNewContent.make(version: "1", notes: nil, reviewSetup: false).blocks, [])
    }
}
