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

    func testPanelLinesMatchTheDesign() {
        let offer = UpdateOffer(version: "0.6.0-rr.1-beta.10", notes: nil, downloaded: false, userInitiated: false)
        XCTAssertEqual(UpdateFlowText.line(.available(offer), currentVersion: "0.6.0-rr.1-beta.9"), "beta.10 ready · Install")
        XCTAssertEqual(
            UpdateFlowText.line(.ready(version: "0.6.0-rr.1-beta.10"), currentVersion: "0.6.0-rr.1-beta.9"),
            "beta.10 ready · Restart to update"
        )
        var downloaded = offer
        downloaded.downloaded = true
        XCTAssertEqual(UpdateFlowText.line(.available(downloaded), currentVersion: "0.6.0-rr.1-beta.9"), "beta.10 ready · Restart to update")
        XCTAssertNil(UpdateFlowText.detail(.available(offer)), "the panel card no longer says Install now, or later from Settings")
    }

    func testSettingsNamesTheFullVersionOnce() {
        let offer = UpdateOffer(version: "0.6.0-rr.1-beta.10", notes: nil, downloaded: false, userInitiated: true)
        XCTAssertEqual(UpdateFlowText.settingsTitle(.available(offer), currentVersion: "0.6.0-rr.1-beta.9"), "0.6.0-rr.1-beta.10 is ready")
        XCTAssertEqual(UpdateFlowText.settingsDetail(.available(offer), currentVersion: "0.6.0-rr.1-beta.9"), "You have beta.9")
        XCTAssertEqual(UpdateFlowText.settingsTitle(.idle, currentVersion: "0.6.0-rr.1-beta.9"), "Bridgey 0.6.0-rr.1-beta.9")
        XCTAssertEqual(UpdateFlowText.settingsDetail(.ready(version: "0.6.0-rr.1-beta.10"), currentVersion: "0.6.0-rr.1-beta.9"),
                       "Downloaded. Restart Bridgey to finish.")
    }

    func testShortVersionKeepsOnlyWhatDiffers() {
        XCTAssertEqual(UpdateFlowText.shortVersion("0.6.0-rr.1-beta.10", comparedTo: "0.6.0-rr.1-beta.9"), "beta.10")
        XCTAssertEqual(UpdateFlowText.shortVersion("0.6.0-rr.1-nightly.20261026", comparedTo: "0.6.0-rr.1-beta.9"), "nightly.20261026")
        XCTAssertEqual(UpdateFlowText.shortVersion("0.7.0-rr.1-beta.1", comparedTo: "0.6.0-rr.1-beta.9"), "0.7.0-rr.1-beta.1")
        XCTAssertEqual(UpdateFlowText.shortVersion("0.6.0-rr.1", comparedTo: "0.6.0-rr.1-beta.9"), "0.6.0-rr.1")
    }

    func testIdleDetailSaysWhenAndWhatWaits() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let current = "0.6.0-rr.1-beta.9"
        func detail(_ check: Date?, _ deferral: UpdateDeferral? = nil, available: Bool = true) -> String {
            UpdateFlowText.idleDetail(updatesAvailable: available, lastCheck: check, deferral: deferral,
                                      currentVersion: current, now: now, calendar: calendar)
        }
        XCTAssertTrue(detail(now.addingTimeInterval(-60)).hasPrefix("Up to date · checked "))
        XCTAssertEqual(detail(nil), "Not checked yet")
        XCTAssertEqual(detail(now, available: false), "Updates work only in the installed app.")
        XCTAssertEqual(detail(now, UpdateDeferral(version: "0.6.0-rr.1-beta.10", kind: .later)), "beta.10 is available")
        XCTAssertEqual(detail(now, UpdateDeferral(version: "0.6.0-rr.1-beta.10", kind: .skipped)), "You skipped beta.10")
        XCTAssertEqual(detail(now, UpdateDeferral(version: "0.6.0-rr.1-beta.10", kind: .onQuit)), "beta.10 installs when Bridgey quits")
    }

    func testDeferralFollowsTheFlow() {
        let offer = UpdateOffer(version: "2", notes: nil, downloaded: false, userInitiated: false)
        XCTAssertEqual(UpdateDeferral.putOff(.available(offer), skipped: false), UpdateDeferral(version: "2", kind: .later))
        XCTAssertEqual(UpdateDeferral.putOff(.available(offer), skipped: true), UpdateDeferral(version: "2", kind: .skipped))
        XCTAssertEqual(UpdateDeferral.putOff(.ready(version: "2"), skipped: false), UpdateDeferral(version: "2", kind: .onQuit))
        XCTAssertNil(UpdateDeferral.putOff(.idle, skipped: false))
        let kept = UpdateDeferral(version: "2", kind: .later)
        XCTAssertEqual(UpdateDeferral.after(.idle, keeping: kept), kept)
        XCTAssertEqual(UpdateDeferral.after(.checking, keeping: kept), kept)
        XCTAssertNil(UpdateDeferral.after(.upToDate, keeping: kept))
        XCTAssertNil(UpdateDeferral.after(.available(offer), keeping: kept))
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
