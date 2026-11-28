import XCTest

/// Light and dark screenshots of the phone's notifications with a code, its call, and ringing both ways, with sample
/// data (BRIDGEY_DEMO=alerts, call, ringing; DemoClient+Alerts.swift).
extension ScreenshotTests {
    func testAlertsLight() { captureAlerts("light") }

    func testAlertsDark() { captureAlerts("dark") }

    private func captureAlerts(_ appearance: String) {
        for (demo, waitFor) in [("alerts", "alert.copyCode"), ("call", "call.card"), ("ringing", "ring.stop")] {
            let app = launch(appearance, demo: demo)
            XCTAssertTrue(app.descendants(matching: .any)[waitFor].firstMatch.waitForExistence(timeout: 10), "\(demo) shows")
            shot(app, appearance, demo)
            app.terminate()
        }
    }
}
