import Foundation
import Sparkle
import XCTest
@testable import BridgeyMac

final class UpdateFlowTests: XCTestCase {
    func testProgressNeedsAKnownLength() {
        XCTAssertNil(UpdateFlow.downloading(version: "1", received: 10, expected: nil).progress)
        XCTAssertEqual(UpdateFlow.downloading(version: "1", received: 25, expected: 100).progress, 0.25)
        XCTAssertEqual(UpdateFlow.downloading(version: "1", received: 200, expected: 100).progress, 1)
        XCTAssertEqual(UpdateFlow.extracting(version: "1", progress: 1.5).progress, 1)
        XCTAssertNil(UpdateFlow.ready(version: "1").progress)
    }

    func testPanelShowsUpdateStepsButNotManualCheckResults() {
        XCTAssertTrue(UpdateFlow.ready(version: "1").showsInPanel)
        XCTAssertTrue(UpdateFlow.failed(message: "x").showsInPanel)
        XCTAssertFalse(UpdateFlow.checking.showsInPanel)
        XCTAssertFalse(UpdateFlow.upToDate.showsInPanel)
        XCTAssertFalse(UpdateFlow.idle.showsInPanel)
    }

    func testReadyLineMatchesTheDesign() {
        XCTAssertEqual(
            UpdateFlowText.line(.ready(version: "0.6.0-rr.1-beta.8"), currentVersion: "0.6.0-rr.1-beta.7"),
            "Update 0.6.0-rr.1-beta.8 ready · Restart to update"
        )
    }

    func testReleaseNotesBecomePlainLines() {
        let html = "<h2>What&#39;s new</h2><ul><li>Faster &amp; calmer</li><li>Fixes</li></ul><p>Thanks</p>"
        XCTAssertEqual(UpdateFlowText.plainNotes(html), "What's new\n• Faster & calmer\n• Fixes\n\nThanks")
        XCTAssertEqual(UpdateFlowText.plainNotes("Plain text\n\n\nsecond"), "Plain text\n\nsecond")
        XCTAssertNil(UpdateFlowText.plainNotes("  <p> </p> "))
    }

    func testErrorsUsePlainWords() {
        XCTAssertTrue(UpdateFlowText.errorMessage(domain: NSURLErrorDomain, code: -1009).contains("connection"))
        XCTAssertTrue(UpdateFlowText.errorMessage(domain: SUSparkleErrorDomain, code: 3001).contains("safety check"))
        XCTAssertTrue(UpdateFlowText.errorMessage(domain: SUSparkleErrorDomain, code: 1005).contains("Applications"))
        XCTAssertEqual(
            UpdateFlowText.errorMessage(domain: "Other", code: 1),
            UpdateFlowText.errorMessage(domain: SUSparkleErrorDomain, code: 9999)
        )
    }

    @MainActor
    func testDriverWalksDownloadToRestart() {
        let driver = InAppUpdateDriver()
        var seen: [UpdateFlow] = []
        driver.onChange = { seen.append($0) }
        var cancelled = false
        driver.showUserInitiatedUpdateCheck { cancelled = true }
        XCTAssertEqual(driver.flow, .checking)
        driver.cancel()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(driver.flow, .idle)

        driver.showDownloadInitiated {}
        driver.showDownloadDidReceiveExpectedContentLength(1_000)
        driver.showDownloadDidReceiveData(ofLength: 250)
        XCTAssertEqual(driver.flow.progress, 0.25)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.5)
        XCTAssertEqual(driver.flow.progress, 0.5)

        var choice: SPUUserUpdateChoice?
        driver.showReady { choice = $0 }
        if case .ready = driver.flow {} else { XCTFail("expected ready, got \(driver.flow)") }
        driver.install()
        XCTAssertEqual(choice, .install)
        if case .installing = driver.flow {} else { XCTFail("expected installing") }
        XCTAssertGreaterThan(seen.count, 5)
    }

    @MainActor
    func testLaterAtReadyDismissesAndManualCheckResultsStay() {
        let driver = InAppUpdateDriver()
        var choice: SPUUserUpdateChoice?
        driver.showReady { choice = $0 }
        driver.later()
        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(driver.flow, .idle)

        var acknowledged = false
        driver.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001)) { acknowledged = true }
        XCTAssertTrue(acknowledged)
        driver.dismissUpdateInstallation()
        XCTAssertEqual(driver.flow, .upToDate)
        driver.dismissMessage()
        XCTAssertEqual(driver.flow, .idle)

        driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: -1009)) {}
        if case let .failed(message) = driver.flow { XCTAssertTrue(message.contains("connection")) } else { XCTFail() }
    }
}
