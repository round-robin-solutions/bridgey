import XCTest
@testable import BridgeyMac

/// About > Version: five quick clicks turn on the Developer and experimental pane, which stays until hidden.
final class DeveloperMenuTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var clock: TimeInterval = 1_000

    override func setUp() {
        suite = "developer-menu-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func menu() -> DeveloperMenu { DeveloperMenu(defaults: defaults, now: { [unowned self] in clock }) }

    func testFiveQuickClicksTurnItOnWithACountdownForTheLastThree() {
        let menu = menu()
        let taps = (1...5).map { _ -> DeveloperMenu.Tap in clock += 0.4; return menu.tap() }
        XCTAssertEqual(taps, [.counting, .remaining(3), .remaining(2), .remaining(1), .unlocked])
        XCTAssertTrue(menu.enabled)
        clock += 0.4
        XCTAssertEqual(menu.tap(), .open, "once on, a click opens it")
    }

    func testAPauseStartsTheCountAgain() {
        let menu = menu()
        for _ in 0..<4 { clock += 0.4; _ = menu.tap() }
        clock += DeveloperMenu.window + 0.1
        XCTAssertEqual(menu.tap(), .counting)
        XCTAssertFalse(menu.enabled)
    }

    func testItStaysOnAcrossRestartsUntilHidden() {
        let first = menu()
        for _ in 0..<5 { clock += 0.1; _ = first.tap() }
        XCTAssertTrue(menu().enabled, "a new instance (the app restarted) reads it back")
        menu().turnOff()
        let after = menu()
        XCTAssertFalse(after.enabled)
        clock += 0.1
        XCTAssertEqual(after.tap(), .counting, "hidden: counting starts again")
    }

    func testTheSidebarShowsThePaneOnlyWhileOnAndItNeverSyncs() {
        XCTAssertFalse(SettingsPane.sidebarItems.contains(.developer))
        XCTAssertEqual(SettingsPane.sidebar(developer: true).last, .developer)
        XCTAssertFalse(SettingsPane.sidebar(developer: false).contains(.developer))
        XCTAssertFalse(SyncKey.allCases.contains { "\($0.rawValue)".contains("developer") })
    }

    func testThePathLineSaysHowFilesTravel() {
        XCTAssertEqual(DeveloperPane.describe(TransferPathRow(id: "a", name: "Pixel", fast: true, tunnelRoute: nil)),
                       "Fast transfers: 256 KiB binary frames. Local network")
        XCTAssertEqual(DeveloperPane.describe(TransferPathRow(id: "a", name: "Pixel", fast: false, tunnelRoute: "relay")),
                       "24 KiB chunks inside messages, as before fast transfers. Away from home, through a relay")
    }
}
