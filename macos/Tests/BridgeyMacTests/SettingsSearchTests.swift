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

/// The registry against the groups: every row a group draws has an entry, every entry still draws, and an entry is in
/// More options exactly when its row is. Groups are rendered with ImageRenderer from sample states that between them
/// show every conditional row, once with every card's More options shut and once with them open.
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

    /// Everything on: two phones, an agent, the developer card, Mac actions with an app and a Shortcut, Focus
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

    /// Anchors drawn twice in one render, by the last `recorded` call.
    private var duplicates: [SearchAnchorID] = []

    /// The anchors a view draws, with every card's More options shut, open, or open for one card (a search jump).
    private func recorded<V: View>(_ view: V, expanded: Bool, jump: SettingsSearchTarget? = nil) -> [SearchAnchorID] {
        let recorder = SettingsSearchRecorder()
        let content = BrandRoot(reduceMotion: true) {
            VStack(alignment: .leading, spacing: 16) { view }
                .frame(width: 640)
        }
        .environment(\.settingsSearchRecorder, recorder)
        .environment(\.settingsExpandAll, expanded)
        .environment(\.settingsSearchHighlight, jump)
        .environment(\.snapshotRendering, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        _ = renderer.cgImage
        duplicates = recorder.duplicates
        return recorder.rows
    }

    private func recorded(_ group: SettingsGroup, _ model: SettingsModel, expanded: Bool, jump: SettingsSearchTarget? = nil) -> [SearchAnchorID] {
        var rows = recorded(SettingsGroupView(group: group, model: model, actions: SettingsActions()), expanded: expanded, jump: jump)
        // Format and Quality only show while photos are optimised, a choice kept outside the model (Files > More options).
        if group == .sharing, expanded || jump?.expand == .files {
            var options = SendOptimization.default
            options.imageMode = .optimize
            rows += recorded(SendOptimizationSettings(options: options, change: { _ in }, preview: SendPreviewState()), expanded: expanded)
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
        var drawn: [SettingsGroup: Set<SearchAnchorID>] = [:]
        for model in models {
            let registered = SettingsSearchRegistry.staticEntries + SettingsSearchRegistry.dynamicEntries(model)
            for group in SettingsGroup.allCases {
                let rows = recorded(group, model, expanded: true)
                drawn[group, default: []].formUnion(rows)
                let known = Set(registered.filter { $0.group == group }.compactMap(Self.anchor))
                for row in rows where !known.contains(row) {
                    XCTFail("Settings > \(group.rawValue): the row \u{201C}\(Self.describe(row))\u{201D} has no entry in SettingsSearchRegistry")
                }
                // Rows found by device or agent name exist only in the model that has them.
                for entry in SettingsSearchRegistry.dynamicEntries(model) where entry.group == group {
                    if let id = Self.anchor(entry), !rows.contains(id) {
                        XCTFail("Settings > \(group.rawValue): the entry \(entry.id) points at \u{201C}\(Self.describe(id))\u{201D}, which is not drawn")
                    }
                }
            }
        }
        for entry in SettingsSearchRegistry.staticEntries {
            guard let id = Self.anchor(entry) else { continue }
            if drawn[entry.group]?.contains(id) != true {
                XCTFail("SettingsSearchRegistry entry \(entry.id) points at \u{201C}\(Self.describe(id))\u{201D}, which no sample state draws in \(entry.group.rawValue)")
            }
        }
    }

    /// Every entry lands on a row people can see: drawn with More options shut when it is not in them, and drawn once its
    /// own card's More options open (what a jump does) when it is. A row in More options never shows while they are shut.
    func testEveryEntryResolvesToAVisibleOrDisclosedRow() {
        var checked = 0
        for model in models {
            let entries = SettingsSearchRegistry.entries(model)
            for group in SettingsGroup.allCases {
                let shut = Set(recorded(group, model, expanded: false))
                let open = Set(recorded(group, model, expanded: true))
                var jumps: [SettingsCardID: Set<SearchAnchorID>] = [:]
                for entry in entries where entry.group == group {
                    guard let row = Self.anchor(entry), open.contains(row) else { continue }
                    checked += 1
                    if entry.more {
                        XCTAssertFalse(shut.contains(row), "\(entry.id) is marked as in More options of \(entry.card.rawValue), but \u{201C}\(Self.describe(row))\u{201D} shows while they are shut")
                        if jumps[entry.card] == nil {
                            let jump = SettingsSearchTarget(group: group, card: entry.card, expand: entry.card)
                            jumps[entry.card] = Set(recorded(group, model, expanded: false, jump: jump))
                        }
                        XCTAssertTrue(jumps[entry.card]?.contains(row) == true,
                                      "\(entry.id): opening More options of \(entry.card.rawValue) does not show \u{201C}\(Self.describe(row))\u{201D}")
                    } else {
                        XCTAssertTrue(shut.contains(row), "\(entry.id) (\u{201C}\(Self.describe(row))\u{201D}) only shows in More options; mark it more: true or move the row")
                    }
                    // The breadcrumb names the group the row is in.
                    XCTAssertTrue(entry.breadcrumb.hasPrefix(group.title), "\(entry.id): \(entry.breadcrumb)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 200)
    }

    /// With every feature off, a row the group hides must name the switch that shows it (the jump highlights that
    /// switch instead), and that switch must be drawn; a row that names one must be drawn whenever it says it is shown.
    func testHiddenRowsNameTheSwitchThatShowsThem() {
        var revealed = 0
        for model in models {
            for group in SettingsGroup.allCases {
                let rows = Set(recorded(group, model, expanded: true))
                let shut = Set(recorded(group, model, expanded: false))
                for entry in SettingsSearchRegistry.staticEntries where entry.group == group && entry.visible(model) {
                    guard let row = Self.anchor(entry) else { continue }
                    guard let reveal = entry.revealedBy else {
                        if model.globalFeatures.values.allSatisfy({ !$0 }), !rows.contains(row) {
                            XCTFail("Settings > \(group.rawValue): \(entry.id) (\u{201C}\(row.title)\u{201D}) is hidden with its feature off and names no revealedBy switch")
                        }
                        continue
                    }
                    let target = SearchAnchorID(scope: entry.scope, title: entry.anchorTitle(in: model) ?? "")
                    if reveal.shown(model) {
                        XCTAssertTrue(rows.contains(row), "\(entry.id) says it is shown, but \u{201C}\(row.title)\u{201D} is not drawn in \(group.rawValue)")
                    } else {
                        revealed += 1
                        XCTAssertFalse(rows.contains(row), "\(entry.id) says it is hidden, but \u{201C}\(row.title)\u{201D} is drawn in \(group.rawValue)")
                        XCTAssertNil(entry.expands(in: model), "\(entry.id) falls back to its switch, which is not in More options")
                        XCTAssertTrue(shut.contains(target), "\(entry.id) falls back to \u{201C}\(target.title)\u{201D}, which is not drawn with More options shut in \(group.rawValue)")
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(revealed, 6, "the off state hides the Calls window and text message options")
    }

    /// One anchor per row: a card that repeats its switch's anchor is highlighted twice, and the scroll picks either.
    func testNoGroupDrawsAnAnchorTwice() {
        for model in models {
            for group in SettingsGroup.allCases {
                _ = recorded(SettingsGroupView(group: group, model: model, actions: SettingsActions()), expanded: true)
                for id in Set(duplicates) {
                    XCTFail("Settings > \(group.rawValue) draws the anchor \u{201C}\(Self.describe(id))\u{201D} more than once")
                }
            }
        }
    }

    func testIdsAreUnique() {
        let ids = (SettingsSearchRegistry.staticEntries + SettingsSearchRegistry.dynamicEntries(fullModel)).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    /// The ids people's searches and the Android registry share did not change with the six groups.
    func testRegistryKeysAreTheOnesBeforeTheGroups() {
        let ids = Set(SettingsSearchRegistry.staticEntries.map(\.id))
        for id in ["thisMac.name", "devices.lookAgain", "devices.away", "devices.pair", "clipboard.clipboard", "clipboard.auto", "clipboard.eager",
                   "notifications.notifications", "notifications.codes", "notifications.focusShare", "messages.switch", "calls.calls", "calls.call_quiet_draft1",
                   "calls.dialer_draft1", "files.files", "files.received", "media.media", "media.links", "media.ping", "media.find_device", "media.battery",
                   "media.mac_actions_draft1", "media.browsers", "remoteControl.remote_input_draft1", "remote.displayShare.unattended", "remote.screen",
                   "privacy.previews", "privacy.reset", "updates.status", "general.sync", "about.version", "away.switch", "developer.hide"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let dynamic = Set(SettingsSearchRegistry.dynamicEntries(fullModel).map(\.id))
        for id in ["device.\(phoneID)", "device.\(phoneID).1", "remote.device.\(phoneID)", "display.device.\(phoneID)", "calls.device.\(phoneID)",
                   "media.device.\(phoneID)", "media.app.com.apple.Safari", "agent.\(phoneID).agent-1"] {
            XCTAssertTrue(dynamic.contains(id), id)
        }
    }

    func testDeveloperRowsOnlyWhileTheMenuIsOn() {
        var model = fullModel
        model.developerMenu = false
        XCTAssertFalse(SettingsSearchRegistry.entries(model).contains { $0.card == .developer })
        model.developerMenu = true
        XCTAssertTrue(SettingsSearchRegistry.entries(model).contains { $0.card == .developer })
    }

    private func top(_ query: String, _ model: SettingsModel? = nil) -> SettingsSearchEntry? {
        SettingsSearchOutcome.run(query, entries: SettingsSearchRegistry.entries(model ?? fullModel)).rows.first?.entry
    }

    func testSynonymsReachTheirRows() {
        XCTAssertEqual(top("otp")?.id, "notifications.codes")
        XCTAssertEqual(top("2fa")?.card, .codes)
        XCTAssertEqual(top("relay")?.card, .away)
        XCTAssertEqual(top("hotspot")?.card, .away)
        XCTAssertEqual(top("tailscale")?.card, .tailscale)
        XCTAssertEqual(top("update")?.group, .app)
        XCTAssertEqual(top("одноразовый код")?.id, "notifications.codes")
        XCTAssertEqual(top("обновление")?.card, .updates)
        XCTAssertEqual(top("сброс")?.group, .privacy)
    }

    func testOldSubPagesJoinTheirGroup() {
        let relay = SettingsSearchOutcome.run("relay", entries: SettingsSearchRegistry.entries(fullModel))
        let groups = relay.groups.map(\.group)
        XCTAssertEqual(groups.first, .devices, "Connect away from home is listed under Devices")
        XCTAssertEqual(groups.count, Set(groups).count, "one heading per group")
    }

    /// Two entries naming one row (a phone's remote control chip, found by the phone and by the feature) give one result.
    func testOneResultPerRow() {
        let outcome = SettingsSearchOutcome.run("oneplus remote", entries: SettingsSearchRegistry.entries(fullModel))
        let rows = outcome.rows.filter { $0.entry.card == .remoteControl && $0.entry.scope == phoneID }
        XCTAssertEqual(rows.count, 1, rows.map(\.entry.id).joined(separator: ", "))
        let away = SettingsSearchOutcome.run("connect away from home", entries: SettingsSearchRegistry.entries(fullModel))
        XCTAssertEqual(away.rows.filter { $0.entry.anchorTitle == SettingsPane.away.title }.count, 1)
    }

    func testDevicesAndAgentsAreFoundByName() {
        let phone = SettingsSearchOutcome.run("oneplus", entries: SettingsSearchRegistry.entries(fullModel))
        XCTAssertEqual(phone.rows.first?.entry.id, "device.\(phoneID)")
        XCTAssertEqual(phone.rows.first?.entry.scope, phoneID)
        let battery = SettingsSearchOutcome.run("pixel battery alerts", entries: SettingsSearchRegistry.entries(fullModel))
        XCTAssertEqual(battery.rows.first?.entry.scope, tabletID)
        XCTAssertEqual(battery.rows.first?.entry.breadcrumb, "Devices \u{203A} Battery \u{203A} Pixel Tablet")
        XCTAssertEqual(battery.rows.first?.entry.expands(in: fullModel), .battery)
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
        XCTAssertEqual(codes?.breadcrumb, "Phone \u{203A} Codes from messages")
        let permission = SettingsSearchRegistry.staticEntries.first { $0.id == "permissions.bluetooth" }
        XCTAssertEqual(permission?.breadcrumb, "Privacy \u{203A} Permissions")
        let eager = SettingsSearchRegistry.staticEntries.first { $0.id == "clipboard.eager" }
        XCTAssertEqual(eager?.breadcrumb, "Sharing \u{203A} Clipboard")
    }

    /// A result inside More options opens them; one whose row hides behind its switch (Files off) goes to the switch.
    func testJumpsOpenMoreOptionsOnlyWhenTheRowIsThere() {
        let eager = SettingsSearchRegistry.staticEntries.first { $0.id == "clipboard.eager" }!
        XCTAssertEqual(eager.expands(in: fullModel), .clipboard)
        let keep = SettingsSearchRegistry.staticEntries.first { $0.id == "messages.keep" }!
        XCTAssertEqual(keep.expands(in: fullModel), .messages)
        XCTAssertNil(keep.expands(in: emptyModel), "with Text messages off the jump lands on its switch")
        XCTAssertEqual(keep.anchorTitle(in: emptyModel), L10n.text("sms.toggle", fallback: "Your phone\u{2019}s texts on this Mac"))
        let ring = SettingsSearchRegistry.staticEntries.first { $0.id == "calls.ring" }!
        XCTAssertNil(ring.expands(in: fullModel))
    }
}

/// The six groups replace the old panes: every pane, and every place that opens one, still has a home.
final class SettingsGroupTests: XCTestCase {
    func testEveryOldPaneMapsToAGroupAndCards() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.cards.isEmpty, pane.rawValue)
            XCTAssertEqual(pane.card, pane.cards.first, pane.rawValue)
            XCTAssertEqual(pane.group, pane.card.group, pane.rawValue)
            XCTAssertTrue(SettingsGroup.allCases.contains(pane.group), pane.rawValue)
        }
        XCTAssertEqual(SettingsPane.thisMac.group, .devices)
        XCTAssertEqual(SettingsPane.devices.group, .devices)
        XCTAssertEqual(SettingsPane.away.group, .devices)
        XCTAssertEqual(SettingsPane.clipboard.group, .sharing)
        XCTAssertEqual(SettingsPane.files.group, .sharing)
        XCTAssertEqual(SettingsPane.media.group, .sharing)
        XCTAssertEqual(SettingsPane.notifications.group, .phone)
        XCTAssertEqual(SettingsPane.messages.group, .phone)
        XCTAssertEqual(SettingsPane.calls.group, .phone)
        XCTAssertEqual(SettingsPane.remoteControl.group, .control)
        XCTAssertEqual(SettingsPane.privacy.group, .privacy)
        XCTAssertEqual(SettingsPane.permissions.group, .privacy)
        XCTAssertEqual(SettingsPane.reset.group, .privacy)
        XCTAssertEqual(SettingsPane.updates.group, .app)
        XCTAssertEqual(SettingsPane.general.group, .app)
        XCTAssertEqual(SettingsPane.about.group, .app)
        XCTAssertEqual(SettingsPane.developer.group, .app)
    }

    /// Every card is in exactly one group and reachable from an old pane (so setup's More options can show it).
    func testEveryCardHasOneGroupAndAPane() {
        let fromPanes = Set(SettingsPane.allCases.flatMap(\.cards))
        XCTAssertEqual(fromPanes, Set(SettingsCardID.allCases))
        let listed = SettingsGroup.allCases.flatMap { $0.cards(developer: true) }
        XCTAssertEqual(listed.count, SettingsCardID.allCases.count)
        XCTAssertEqual(Set(listed), Set(SettingsCardID.allCases))
        XCTAssertEqual(SettingsGroup.allCases.map(\.rawValue), ["devices", "sharing", "phone", "control", "privacy", "app"])
        XCTAssertEqual(SettingsGroup.allCases.map(\.title), ["Devices", "Sharing", "Phone", "Control", "Privacy", "App"])
    }

    /// The notification that opens Settings (email code model) and the test hooks name panes by raw value: they still parse.
    func testPaneRawValuesStillParse() {
        for name in ["thisMac", "devices", "clipboard", "notifications", "messages", "calls", "files", "media", "remoteControl", "privacy",
                     "updates", "general", "about", "permissions", "reset", "away", "developer"] {
            XCTAssertNotNil(SettingsPane(rawValue: name), name)
        }
    }
}

/// The Devices row's chips read and write exactly what the per-device switches on the old Devices page did.
@MainActor
final class DeviceChoicesTests: XCTestCase {
    private let phoneID = "11111111-1111-1111-1111-111111111111"
    private let macID = "33333333-3333-3333-3333-333333333333"

    private struct Call: Equatable { let device: String; let what: String; let on: Bool }

    private final class Recorder {
        var calls: [Call] = []
    }

    private func model() -> SettingsModel {
        var model = SettingsModel()
        model.trustedDevices = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11"), TrustedDeviceInfo(id: macID, name: "Work Mac")]
        model.globalFeatures = Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0, true) })
        model.deviceFeatures = [phoneID: [.files: false, .remoteInput: true, .dialer: true, .callQuiet: true],
                                macID: [.macActions: true]]
        model.autoClipboardDevices = [macID: false]
        model.settingsSyncDevices = [phoneID: false]
        model.macDevices = [macID]
        model.phoneFeatures = [phoneID: [.clipboard: false]]
        return model
    }

    private func recording(_ recorder: Recorder) -> SettingsActions {
        var actions = SettingsActions()
        actions.setForDevice = { id, feature, on in recorder.calls.append(Call(device: id, what: feature.rawValue, on: on)) }
        actions.setAutoClipboardForDevice = { id, on in recorder.calls.append(Call(device: id, what: "autoClipboard", on: on)) }
        actions.setSettingsSyncForDevice = { id, on in recorder.calls.append(Call(device: id, what: "sync", on: on)) }
        return actions
    }

    func testFeatureChipsMatchTheOldPerDeviceSwitches() {
        let recorder = Recorder()
        let model = model()
        do {
            let actions = recording(recorder)
            for feature in BridgeyFeature.allCases where !feature.needsDeviceGrant {
                let chips = DeviceChoices.feature(feature, model, actions)
                XCTAssertEqual(chips.map(\.id), [phoneID, macID])
                for chip in chips {
                    // The old switch: isOn model.isEnabled(feature, for:), disabled while the feature is off everywhere.
                    XCTAssertEqual(chip.isOn, model.isEnabled(feature, for: chip.id), "\(feature) \(chip.name)")
                    XCTAssertEqual(chip.enabled, model.globalFeatures[feature] != false)
                    XCTAssertEqual(chip.anchor, feature.title, "search lands on the chip by the old row's title")
                    chip.set(!chip.isOn)
                }
            }
        }
        XCTAssertTrue(recorder.calls.contains(Call(device: phoneID, what: BridgeyFeature.files.rawValue, on: true)), "Files was off for the phone")
        XCTAssertTrue(recorder.calls.contains(Call(device: macID, what: BridgeyFeature.files.rawValue, on: false)))
        XCTAssertEqual(recorder.calls.count, BridgeyFeature.allCases.filter { !$0.needsDeviceGrant }.count * 2)
        // The phone turned Clipboard off on its side: its chip says so.
        let clipboard = DeviceChoices.feature(.clipboard, model, SettingsActions())
        XCTAssertEqual(clipboard.first?.note, "Off on OnePlus 11")
        XCTAssertNil(clipboard.last?.note)
    }

    func testGrantAndSyncChipsMatchTheOldSwitches() {
        let recorder = Recorder()
        var model = model()
        model.restrictedDevices = []
        do {
            let actions = recording(recorder)
            let auto = DeviceChoices.autoClipboard(model, actions)
            XCTAssertEqual(auto.map(\.isOn), [model.isAutoClipboardEnabled(for: phoneID), model.isAutoClipboardEnabled(for: macID)])
            XCTAssertEqual(auto.map(\.isOn), [true, false])
            auto[1].set(true)
            let remote = DeviceChoices.remoteControl(model, actions)
            XCTAssertEqual(remote.map(\.isOn), [model.remoteGrant(for: phoneID), model.remoteGrant(for: macID)])
            XCTAssertEqual(remote.map(\.isOn), [true, false])
            remote[0].set(false)
            let mac = DeviceChoices.macActions(model, actions)
            XCTAssertEqual(mac.map(\.isOn), [false, true])
            mac[0].set(true)
            let window = DeviceChoices.callsWindow(model, actions)
            XCTAssertEqual(window.map(\.id), [phoneID], "a Mac cannot place calls")
            XCTAssertEqual(window.first?.isOn, true)
            window[0].set(false)
            let quiet = DeviceChoices.callQuiet(model, actions)
            XCTAssertEqual(quiet.map(\.isOn), [true, false])
            quiet[1].set(true)
            let sync = DeviceChoices.settingsSync(model, actions)
            XCTAssertEqual(sync.map(\.isOn), [model.isSettingsSyncEnabled(for: phoneID), model.isSettingsSyncEnabled(for: macID)])
            XCTAssertEqual(sync.map(\.isOn), [false, true])
            sync[0].set(true)
        }
        XCTAssertEqual(recorder.calls, [
            Call(device: macID, what: "autoClipboard", on: true),
            Call(device: phoneID, what: BridgeyFeature.remoteInput.rawValue, on: false),
            Call(device: phoneID, what: BridgeyFeature.macActions.rawValue, on: true),
            Call(device: phoneID, what: BridgeyFeature.dialer.rawValue, on: false),
            Call(device: macID, what: BridgeyFeature.callQuiet.rawValue, on: true),
            Call(device: phoneID, what: "sync", on: true),
        ])
    }

    /// Through the real store: a chip changes the same defaults key the old switch did, and reads it back.
    func testChipsWriteTheStoredValues() throws {
        let suite = "bridgey.tests.chips.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BridgeySettings(defaults: defaults)
        var actions = SettingsActions()
        actions.setForDevice = { id, feature, on in settings.setForDevice(id, feature: feature, enabled: on) }
        actions.setAutoClipboardForDevice = { id, on in settings.setAutoClipboard(on, for: id) }
        func current() -> SettingsModel {
            var model = SettingsModel()
            model.trustedDevices = [TrustedDeviceInfo(id: phoneID, name: "OnePlus 11")]
            model.globalFeatures = settings.globalFeatures
            model.deviceFeatures = settings.deviceFeatures
            model.autoClipboard = settings.autoClipboardEnabled
            model.autoClipboardDevices = settings.autoClipboardDevices
            return model
        }
        let files = try XCTUnwrap(DeviceChoices.feature(.files, current(), actions).first)
        XCTAssertTrue(files.isOn)
        files.set(false)
        XCTAssertEqual(defaults.object(forKey: "settings.device.\(phoneID).files") as? Bool, false)
        XCTAssertEqual(DeviceChoices.feature(.files, current(), actions).first?.isOn, false)
        let auto = try XCTUnwrap(DeviceChoices.autoClipboard(current(), actions).first)
        auto.set(!auto.isOn)
        XCTAssertEqual(settings.autoClipboardDevices[phoneID], !auto.isOn)
        XCTAssertEqual(DeviceChoices.autoClipboard(current(), actions).first?.isOn, !auto.isOn)
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
            for file in ["SettingsSearchRegistry.swift", "SettingsSearchUI.swift", "SettingsCards.swift", "SettingsGroupViews.swift"] {
                for key in try keys(in: file, call: call) {
                    XCTAssertNotNil(english[key], "\(file): \(key) is missing from en.lproj/\(tableName).strings")
                    XCTAssertNotNil(russian[key], "\(file): \(key) is missing from ru.lproj/\(tableName).strings")
                }
            }
        }
    }

    func testNoEmDashes() throws {
        for file in ["SettingsSearch.swift", "SettingsSearchRegistry.swift", "SettingsSearchUI.swift", "SettingsCards.swift", "SettingsGroupViews.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/BridgeyMac/\(file)"), encoding: .utf8)
            XCTAssertFalse(source.contains("\u{2014}"), "\(file) has an em dash")
        }
        for language in ["en", "ru"] {
            let strings = try table(language, "Localizable")
            for (key, value) in strings where key.hasPrefix("settings.search") || key.hasPrefix("settings.group") || key.hasPrefix("settings.card")
                || key.hasPrefix("settings.more") {
                XCTAssertFalse(value.contains("\u{2014}"), "\(language) \(key) has an em dash")
            }
        }
    }
}
