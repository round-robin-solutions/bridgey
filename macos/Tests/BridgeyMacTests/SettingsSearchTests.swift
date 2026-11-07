import SwiftUI
import XCTest
@testable import BridgeyMac

/// The matching and ranking rules, shared with Android (SettingsSearchTest.kt).
final class SettingsSearchMatchTests: XCTestCase {
    private let docs = [
        SearchDoc(title: "Codes from messages", page: "Notifications", keywords: ["otp", "one-time code", "код"]),
        SearchDoc(title: "Connect away from home", subtitle: "Reach your devices over the internet", page: "Devices", keywords: ["relay", "tailscale", "удалённо"]),
        SearchDoc(title: "Notification forwarding", subtitle: "Show this phone's notifications on your Macs", page: "Notifications"),
        SearchDoc(title: "Clipboard", subtitle: "Copy here, paste there", page: "Clipboard", keywords: ["copy", "paste"]),
        SearchDoc(title: "Reset settings", page: "Reset"),
        SearchDoc(title: "Release channel", page: "Updates", keywords: ["update", "обновление", "версия"]),
        SearchDoc(title: "Reduce motion", subtitle: "Fade between screens", page: "General", keywords: ["animation"]),
    ]

    private func top(_ query: String) -> String? {
        SettingsSearch.search(query, in: docs).first.map { docs[$0.index].title }
    }

    func testFoldsCaseAccentsYoAndPunctuation() {
        XCTAssertEqual(SettingsSearch.fold("  Ёлка Café, OTP! "), "елка cafe otp")
        XCTAssertEqual(SettingsSearch.fold("удалённо"), "удаленно")
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(SettingsSearch.search("   ", in: docs).isEmpty)
    }

    func testSynonymsLead() {
        XCTAssertEqual(top("otp"), "Codes from messages")
        XCTAssertEqual(top("relay"), "Connect away from home")
        XCTAssertEqual(top("tailscale"), "Connect away from home")
        XCTAssertEqual(top("update"), "Release channel")
    }

    func testRussianSynonymsAndYoFolding() {
        XCTAssertEqual(top("обновлен"), "Release channel")
        XCTAssertEqual(top("удаленно"), "Connect away from home")
        XCTAssertEqual(top("КОД"), "Codes from messages")
    }

    func testTitlePrefixBeatsOtherFields() {
        let hits = SettingsSearch.search("notif", in: docs).map { docs[$0.index].title }
        XCTAssertEqual(hits.first, "Notification forwarding")
        XCTAssertTrue(hits.contains("Codes from messages"))
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(top("away home"), "Connect away from home")
        XCTAssertTrue(SettingsSearch.search("away clipboard", in: docs).isEmpty)
    }

    func testOneTypoIsForgiven() {
        XCTAssertEqual(top("clipbaord"), "Clipboard")
        XCTAssertEqual(top("clipbard"), "Clipboard")
        XCTAssertEqual(top("relya"), "Connect away from home")
        XCTAssertTrue(SettingsSearch.search("xlipboard", in: docs).isEmpty, "a changed first letter is not a typo people make")
        XCTAssertTrue(SettingsSearch.search("otq", in: docs).isEmpty, "short words get no typo pass")
    }

    func testTypoRulesDirectly() {
        XCTAssertTrue(SettingsSearch.isTypo("relya", "relay"))
        XCTAssertTrue(SettingsSearch.isTypo("lcipboard", "clipboard"))
        XCTAssertFalse(SettingsSearch.isTypo("xlipboard", "clipboard"))
        XCTAssertEqual(SettingsSearch.osaDistance("ab", "ba"), 1)
        XCTAssertEqual(SettingsSearch.osaDistance("kitten", "sitting"), 3)
    }

    func testExactTitleWins() {
        XCTAssertEqual(top("clipboard"), "Clipboard")
        XCTAssertGreaterThanOrEqual(SettingsSearch.search("clipboard", in: docs).first?.score ?? 0, 1200)
    }

    func testHighlightPrefersWordStarts() {
        XCTAssertEqual(SettingsSearch.highlight("Reset settings", query: "set"), [6..<9])
        XCTAssertEqual(SettingsSearch.highlight("Ёлка зелёная", query: "елка"), [0..<4])
        XCTAssertEqual(SettingsSearch.highlight("Copy and copy", query: "copy and"), [0..<4, 5..<8])
    }

    func testFuzzyMatchesHighlightNothing() {
        XCTAssertEqual(SettingsSearch.search("clipbaord", in: docs).first?.titleRanges, [])
    }

    func testSubtitleHighlightWhenTitleHasNone() throws {
        let hit = try XCTUnwrap(SettingsSearch.search("internet", in: docs).first)
        XCTAssertEqual(docs[hit.index].title, "Connect away from home")
        XCTAssertEqual(hit.titleRanges, [])
        XCTAssertEqual(hit.subtitleRanges, [28..<36])
    }

    func testClosestAlwaysOffersThree() {
        XCTAssertTrue(SettingsSearch.search("dark", in: docs).isEmpty)
        let closest = SettingsSearch.closest("dark", in: docs)
        XCTAssertEqual(closest.count, 3)
        XCTAssertEqual(Set(closest).count, 3)
        XCTAssertEqual(SettingsSearch.closest("otpx", in: docs).first.map { docs[$0].title }, "Codes from messages")
    }

    func testTiesKeepRegistryOrder() {
        let same = [SearchDoc(title: "Alpha", keywords: ["shared"]), SearchDoc(title: "Beta", keywords: ["shared"])]
        XCTAssertEqual(SettingsSearch.search("shared", in: same).map(\.index), [0, 1])
    }
}

/// The registry against the panes: every row a pane draws has an entry, and every entry still draws. Panes are
/// rendered with ImageRenderer from sample states that between them show every conditional row.
@MainActor
final class SettingsSearchRegistryTests: XCTestCase {
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let tabletID = "22222222-2222-2222-2222-222222222222"

    func testTailscaleLoginSearchFindsBothSetupCards() {
        let entries = SettingsSearchRegistry.staticEntries
        let ids = SettingsSearch.search("tailscale login", in: entries.map(\.doc)).map { entries[$0.index].id }
        XCTAssertTrue(ids.contains("devices.tailscaleSetup"))
        XCTAssertTrue(ids.contains("away.tailscaleSetup"))
        let primary = SettingsSearchOutcome.run("tailscale", entries: entries).rows.first?.entry
        XCTAssertEqual(primary?.id, "away.tailscaleSetup")
    }

    /// Everything on: two phones, an agent, the developer pane, Mac actions with an app and a Shortcut, Focus
    /// following, text messages, Connect away from home in testing mode.
    private var fullModel: SettingsModel {
        var model = SettingsModel()
        model.deviceName = "Rahul\u{2019}s MacBook Pro"
        let trusted = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"), TrustedDeviceInfo(id: tabletID, name: "Pixel Tablet")]
        model.trustedDevices = trusted
        model.state = .connected(deviceID: phoneID, peerName: "OnePlus 11")
        model.rings = deviceRings(trusted: trusted, peers: [], state: model.state)
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.developerMenu = true
        model.macActions = MacActionsConfig(switches: Dictionary(uniqueKeysWithValues: MacActionSwitch.allCases.map { ($0, true) }),
                                            apps: [AllowedApp(bundleID: "com.apple.Safari", name: "Safari")],
                                            shortcuts: [AllowedShortcut(id: "s1", name: "Morning routine")])
        model.accessibilityTrusted = false
        model.focusSync = FocusSyncSettings(share: true, follow: true, onShortcut: nil, offShortcut: nil)
        model.smsEnabled = true
        model.historyEnabled = true
        model.codesEnabled = true
        model.connect = ConnectDisplay(available: true, controlConfigured: true)
        model.connect.debug = true
        model.agents = AgentsDisplay(phones: [phoneID: AgentsMirrorPhoneState(agents: [
            AgentDevice(deviceId: "agent-1", name: "Contabo Europe", platform: "cli", app: "bridgey 0.2.0", os: "linux x86_64",
                        pairedAt: 1, online: true, grants: [], activity: []),
        ], receivedAt: Date())], live: [phoneID])
        return model
    }

    /// Nothing paired and most things off, for the rows that only show then.
    private var emptyModel: SettingsModel {
        var model = SettingsModel()
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, false) })
        return model
    }

    private var models: [SettingsModel] { [fullModel, emptyModel] }

    /// The anchors a view draws.
    private func recorded<V: View>(_ view: V) -> [SearchAnchorID] {
        let recorder = SettingsSearchRecorder()
        let content = BrandRoot(reduceMotion: true) {
            VStack(alignment: .leading, spacing: 16) { view }
                .frame(width: 640)
        }
        .environment(\.settingsSearchRecorder, recorder)
        .environment(\.snapshotRendering, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        _ = renderer.cgImage
        return recorder.rows
    }

    private func recorded(_ pane: SettingsPane, _ model: SettingsModel) -> [SearchAnchorID] {
        var rows = recorded(SettingsPaneView(pane: pane, model: model, actions: SettingsActions()))
        // Format and Quality only show while photos are optimised, a choice kept outside the model.
        if pane == .files {
            var options = SendOptimization.default
            options.imageMode = .optimize
            rows += recorded(SendOptimizationSettings(options: options, change: { _ in }, preview: SendPreviewState()))
        }
        return rows
    }

    private static func anchor(_ entry: SettingsSearchEntry) -> SearchAnchorID? {
        entry.anchorTitle.map { SearchAnchorID(scope: entry.scope, title: $0) }
    }

    private static func describe(_ id: SearchAnchorID) -> String {
        id.scope.map { "\(id.title) [\($0)]" } ?? id.title
    }

    func testEveryRowHasAnEntryAndEveryEntryDraws() {
        let panes = SettingsPane.allCases
        var drawn: [SettingsPane: Set<SearchAnchorID>] = [:]
        for model in models {
            let registered = SettingsSearchRegistry.staticEntries + SettingsSearchRegistry.dynamicEntries(model)
            for pane in panes {
                let rows = recorded(pane, model)
                drawn[pane, default: []].formUnion(rows)
                let known = Set(registered.filter { $0.pane == pane }.compactMap(Self.anchor))
                for row in rows where !known.contains(row) {
                    XCTFail("Settings > \(pane.rawValue): the row \u{201C}\(Self.describe(row))\u{201D} has no entry in SettingsSearchRegistry")
                }
                // Rows found by device or agent name exist only in the model that has them.
                for entry in SettingsSearchRegistry.dynamicEntries(model) where entry.pane == pane {
                    if let id = Self.anchor(entry), !rows.contains(id) {
                        XCTFail("Settings > \(pane.rawValue): the entry \(entry.id) points at \u{201C}\(Self.describe(id))\u{201D}, which is not drawn")
                    }
                }
            }
        }
        for entry in SettingsSearchRegistry.staticEntries {
            guard let id = Self.anchor(entry) else { continue }
            if drawn[entry.pane]?.contains(id) != true {
                XCTFail("SettingsSearchRegistry entry \(entry.id) points at \u{201C}\(Self.describe(id))\u{201D}, which no sample state draws on \(entry.pane.rawValue)")
            }
        }
    }

    func testIdsAreUnique() {
        let ids = (SettingsSearchRegistry.staticEntries + SettingsSearchRegistry.dynamicEntries(fullModel)).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    func testDeveloperRowsOnlyWhileTheMenuIsOn() {
        var model = fullModel
        model.developerMenu = false
        XCTAssertFalse(SettingsSearchRegistry.entries(model).contains { $0.pane == .developer })
        model.developerMenu = true
        XCTAssertTrue(SettingsSearchRegistry.entries(model).contains { $0.pane == .developer })
    }

    private func top(_ query: String, _ model: SettingsModel? = nil) -> SettingsSearchEntry? {
        SettingsSearchOutcome.run(query, entries: SettingsSearchRegistry.entries(model ?? fullModel)).rows.first?.entry
    }

    func testSynonymsReachTheirRows() {
        XCTAssertEqual(top("otp")?.id, "notifications.codes")
        XCTAssertEqual(top("2fa")?.pane, .notifications)
        XCTAssertEqual(top("relay")?.pane, .away)
        XCTAssertEqual(top("hotspot")?.pane, .away)
        XCTAssertEqual(top("tailscale")?.pane, .away)
        XCTAssertEqual(top("update")?.pane, .updates)
        XCTAssertEqual(top("одноразовый код")?.id, "notifications.codes")
        XCTAssertEqual(top("обновление")?.pane, .updates)
        XCTAssertEqual(top("сброс")?.pane, .privacy)
    }

    func testSubPagesJoinTheirSidebarGroup() {
        let relay = SettingsSearchOutcome.run("relay", entries: SettingsSearchRegistry.entries(fullModel))
        let groups = relay.groups.map(\.pane)
        XCTAssertEqual(groups.first, .devices, "Connect away from home is listed under Devices")
        XCTAssertEqual(groups.count, Set(groups).count, "one heading per sidebar item")
    }

    func testDevicesAndAgentsAreFoundByName() {
        let phone = SettingsSearchOutcome.run("oneplus", entries: SettingsSearchRegistry.entries(fullModel))
        XCTAssertEqual(phone.rows.first?.entry.id, "device.\(phoneID)")
        XCTAssertEqual(phone.rows.first?.entry.scope, phoneID)
        let battery = SettingsSearchOutcome.run("pixel battery alerts", entries: SettingsSearchRegistry.entries(fullModel))
        XCTAssertEqual(battery.rows.first?.entry.scope, tabletID)
        XCTAssertEqual(battery.rows.first?.entry.breadcrumb, "Devices \u{203A} Pixel Tablet \u{203A} Permissions")
        let agent = SettingsSearchOutcome.run("contabo", entries: SettingsSearchRegistry.entries(fullModel))
        XCTAssertEqual(agent.rows.first?.entry.scope, "agent:\(phoneID):agent-1")
    }

    func testSyncedRowsAndTheirStatus() {
        var model = fullModel
        model.settingsSyncEnabled = true
        model.syncStatus = [.reduceMotion: SyncRowStatus(localWaiting: true, differentOn: [], peerWaiting: [])]
        let entries = SettingsSearchRegistry.entries(model)
        let reduceMotion = entries.first { $0.id == "general.reduceMotion" }
        XCTAssertEqual(reduceMotion?.subtitle, "On, waiting for permission")
        let waiting = SettingsSearchOutcome.run("waiting permission", entries: entries)
        XCTAssertTrue(waiting.rows.contains { $0.entry.id == "general.reduceMotion" })
        XCTAssertTrue(SettingsSearchOutcome.run("synced", entries: entries).rows.contains { $0.entry.id == "clipboard.auto" })
    }

    func testNoResultsOffersTheClosest() {
        let outcome = SettingsSearchOutcome.run("dark mode", entries: SettingsSearchRegistry.entries(fullModel))
        XCTAssertTrue(outcome.isEmpty, "Bridgey has no appearance setting")
        XCTAssertEqual(outcome.closest.count, 3)
    }

    func testBreadcrumbs() {
        let codes = SettingsSearchRegistry.staticEntries.first { $0.id == "notifications.codes" }
        XCTAssertEqual(codes?.breadcrumb, "Notifications \u{203A} Codes from messages")
        let permission = SettingsSearchRegistry.staticEntries.first { $0.id == "permissions.bluetooth" }
        XCTAssertEqual(permission?.breadcrumb, "Privacy \u{203A} Permissions")
    }
}

/// Every string the registry and the search UI read exists in English and Russian, and none has an em dash.
final class SettingsSearchStringsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ language: String, _ name: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/\(name).strings")
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(url.path) did not parse")
        return dictionary
    }

    private func keys(in file: String, call: String) throws -> Set<String> {
        let source = try String(contentsOf: root.appendingPathComponent("Sources/BridgeyMac/\(file)"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: call) + #"\("([^"]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } })
    }

    func testRegistryAndUIKeysAreTranslated() throws {
        for (call, tableName) in [("L10n.text", "Localizable"), ("L10n.setup", "Setup"), ("L10n.agents", "Agents")] {
            let english = try table("en", tableName)
            let russian = try table("ru", tableName)
            for file in ["SettingsSearchRegistry.swift", "SettingsSearchUI.swift"] {
                for key in try keys(in: file, call: call) {
                    XCTAssertNotNil(english[key], "\(file): \(key) is missing from en.lproj/\(tableName).strings")
                    XCTAssertNotNil(russian[key], "\(file): \(key) is missing from ru.lproj/\(tableName).strings")
                }
            }
        }
    }

    func testNoEmDashes() throws {
        for file in ["SettingsSearch.swift", "SettingsSearchRegistry.swift", "SettingsSearchUI.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/BridgeyMac/\(file)"), encoding: .utf8)
            XCTAssertFalse(source.contains("\u{2014}"), "\(file) has an em dash")
        }
        for language in ["en", "ru"] {
            let strings = try table(language, "Localizable")
            for (key, value) in strings where key.hasPrefix("settings.search") {
                XCTAssertFalse(value.contains("\u{2014}"), "\(language) \(key) has an em dash")
            }
        }
    }
}
