import XCTest
@testable import BridgeyMac

final class ReleaseNotesTests: XCTestCase {
    func testDashLinesBecomeBullets() {
        let notes = "- Faster pairing\n* Calmer reconnects\n• One Keychain question\n+ Fixes\n1. Numbered too"
        XCTAssertEqual(ReleaseNotes.blocks(notes), [
            .bullet("Faster pairing"), .bullet("Calmer reconnects"), .bullet("One Keychain question"),
            .bullet("Fixes"), .bullet("Numbered too"),
        ])
    }

    func testHeadingsParagraphsAndRulesAreKept() {
        let notes = "## Changes\nShorter Settings.\n\n---\n- Item"
        XCTAssertEqual(ReleaseNotes.blocks(notes), [.heading("Changes"), .paragraph("Shorter Settings."), .bullet("Item")])
    }

    func testWrappedLinesJoinTheirItem() {
        let notes = "- Constrain the macOS menu-bar panel to its content's ideal height when the\n  connection state changes.\n- Next item"
        XCTAssertEqual(ReleaseNotes.blocks(notes), [
            .bullet("Constrain the macOS menu-bar panel to its content's ideal height when the connection state changes."),
            .bullet("Next item"),
        ])
    }

    func testAFinishedSentenceStartsANewParagraph() {
        XCTAssertEqual(ReleaseNotes.blocks("- Done.\nThanks for testing"), [.bullet("Done."), .paragraph("Thanks for testing")])
        XCTAssertEqual(ReleaseNotes.blocks("- Done.\nlowercase goes on"), [.bullet("Done. lowercase goes on")])
    }

    func testTheVersionHeadingIsDropped() {
        // rrrelease.py writes <h2>version</h2><p>line</p>…; plainNotes turns that into lines.
        let html = "<h2>0.6.0-rr.1-beta.10</h2><p>- Updates pane redesign</p><p>- Notes as a list</p>"
        let plain = UpdateFlowText.plainNotes(html) ?? ""
        XCTAssertEqual(ReleaseNotes.blocks(plain, version: "0.6.0-rr.1-beta.10"), [.bullet("Updates pane redesign"), .bullet("Notes as a list")])
        XCTAssertEqual(ReleaseNotes.blocks("# v0.6.0-rr.1-beta.10\n- a", version: "0.6.0-rr.1-beta.10"), [.bullet("a")])
    }

    func testListItemsFromHTMLStayBullets() {
        let plain = UpdateFlowText.plainNotes("<ul><li>One</li><li>Two</li></ul>") ?? ""
        XCTAssertEqual(ReleaseNotes.blocks(plain), [.bullet("One"), .bullet("Two")])
    }

    func testEmptyNotesHaveNoBlocks() {
        XCTAssertEqual(ReleaseNotes.blocks(""), [])
        XCTAssertEqual(ReleaseNotes.blocks("\n- \n\n"), [])
    }

    func testPreviewFitsAboutFourLines() {
        let short = (1...9).map { ReleaseNoteBlock.bullet("Item \($0)") }
        XCTAssertEqual(ReleaseNotes.preview(short), Array(short.prefix(4)))
        let long = String(repeating: "x", count: 100)  // two lines each at 72 characters
        let blocks = [ReleaseNoteBlock.bullet(long), .bullet(long), .bullet("short")]
        XCTAssertEqual(ReleaseNotes.preview(blocks), Array(blocks.prefix(2)))
        let huge = [ReleaseNoteBlock.paragraph(String(repeating: "y", count: 500)), .bullet("b")]
        XCTAssertEqual(ReleaseNotes.preview(huge), [huge[0]], "always shows at least one block")
    }

    func testPreviewNeverEndsOnAHeading() {
        let blocks: [ReleaseNoteBlock] = [.bullet("a"), .bullet("b"), .bullet("c"), .heading("Fixes"), .bullet("d")]
        XCTAssertEqual(ReleaseNotes.preview(blocks), [.bullet("a"), .bullet("b"), .bullet("c")])
    }
}
