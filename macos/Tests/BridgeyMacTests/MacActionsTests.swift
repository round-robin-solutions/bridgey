import XCTest
@testable import BridgeyMac

/// A fake operating system: records calls, never locks, sleeps or touches the volume.
@MainActor
private final class FakeSystem: MacSystemActing {
    var accessibilityTrusted = true
    var calls: [String] = []
    var volumeState: MacVolumeState? = MacVolumeState(level: 40, muted: false)
    var installed: Set<String> = ["com.apple.Safari"]
    var shortcutCompletion: ((ShortcutRunOutcome) -> Void)?

    func lockScreen() -> Bool { calls.append("lock"); return true }
    func sleepSystem() -> Bool { calls.append("sleep"); return true }
    func startScreenSaver() -> Bool { calls.append("screensaver"); return true }
    func volume() -> MacVolumeState? { volumeState }
    func stepVolume(up: Bool) -> MacVolumeState? {
        calls.append(up ? "volume_up" : "volume_down")
        guard var state = volumeState else { return nil }
        state.level = min(max(state.level + (up ? 6 : -6), 0), 100)
        volumeState = state
        return state
    }
    func toggleMute() -> MacVolumeState? {
        calls.append("mute")
        volumeState?.muted.toggle()
        return volumeState
    }
    func setVolume(_ level: Int) -> MacVolumeState? {
        calls.append("set_\(level)")
        volumeState?.level = level
        return volumeState
    }
    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
    func openApp(bundleID: String, completion: @escaping (Bool) -> Void) { calls.append("open_\(bundleID)"); completion(true) }
    func runShortcut(named name: String, completion: @escaping (ShortcutRunOutcome) -> Void) {
        calls.append("shortcut_\(name)")
        shortcutCompletion = completion
    }
}

@MainActor
final class MacActionsTests: XCTestCase {
    private let phone = "11111111-1111-1111-1111-111111111111"
    private var system: FakeSystem!
    private var host: MacActionsHost!
    private var replies: [[String: Any]] = []
    private var allowed = true
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var sequence = 0

    override func setUp() async throws {
        system = FakeSystem()
        replies = []
        allowed = true
        sequence = 0
        host = MacActionsHost(system: system, store: nil, audit: MacActionsAuditLog(store: nil), clock: { [unowned self] in self.now }, sleepDelay: 0)
        host.isAllowed = { [unowned self] _ in self.allowed }
        host.send = { [unowned self] _, kind, payload in
            XCTAssertEqual(kind, "actions.result")
            self.replies.append(payload)
            return true
        }
        for item in MacActionSwitch.allCases { host.setSwitch(item, enabled: true) }
        host.addApps([AllowedApp(bundleID: "com.apple.Safari", name: "Safari")])
        XCTAssertTrue(host.addShortcut(named: "Focus on"))
    }

    @discardableResult
    private func run(_ action: String, value: Any? = nil, sequence explicit: Int? = nil) -> [String: Any]? {
        sequence += 1
        var payload: [String: Any] = ["version": 1, "requestId": UUID().uuidString.lowercased(), "action": action, "sequence": explicit ?? sequence]
        if let value { payload["value"] = value }
        let before = replies.count
        host.receive(kind: "actions.run", payload: payload, deviceID: phone, deviceName: "OnePlus 11")
        return replies.count > before ? replies.last : nil
    }

    private func reason(_ reply: [String: Any]?) -> String? { reply?["reason"] as? String }

    // MARK: Allowlist

    func testUnknownActionsAppsAndShortcutsAreRefused() {
        for action in ["", "shell", "do shell script", "lock;rm", "app:com.apple.Terminal", "app:../../bin/sh",
                       "shortcut:Focus on", "shortcut:\(UUID().uuidString.lowercased())", "shortcut:\(UUID().uuidString)",
                       "volume", "LOCK"] {
            let reply = run(action)
            XCTAssertEqual(reply?["status"] as? String, "refused", action)
            XCTAssertEqual(reason(reply), "not_allowed", action)
        }
        XCTAssertTrue(system.calls.isEmpty, "nothing ran: \(system.calls)")
    }

    func testListedEntriesRun() {
        XCTAssertEqual(run("app:com.apple.Safari")?["status"] as? String, "done")
        let handle = host.config.shortcuts[0].id
        _ = run("shortcut:\(handle)")
        system.shortcutCompletion?(.done)
        XCTAssertEqual(replies.last?["status"] as? String, "done")
        XCTAssertEqual(system.calls, ["open_com.apple.Safari", "shortcut_Focus on"])
    }

    func testRemovedAppAndSwitchedOffActionAreRefused() {
        host.removeApp(bundleID: "com.apple.Safari")
        XCTAssertEqual(reason(run("app:com.apple.Safari")), "not_allowed")
        host.setSwitch(.sleep, enabled: false)
        XCTAssertEqual(reason(run("sleep")), "not_allowed")
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testNotGrantedPhoneIsRefused() {
        allowed = false
        XCTAssertEqual(reason(run("screensaver")), "not_allowed")
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testUninstalledAppIsUnavailable() {
        host.addApps([AllowedApp(bundleID: "com.example.Gone", name: "Gone")])
        XCTAssertEqual(reason(run("app:com.example.Gone")), "unavailable")
    }

    // MARK: Values

    func testOnlyVolumeSetTakesAnIntegerValue() {
        XCTAssertEqual(reason(run("volume_set")), "invalid")
        XCTAssertEqual(reason(run("volume_set", value: 101)), "invalid")
        XCTAssertEqual(reason(run("volume_set", value: -1)), "invalid")
        XCTAssertEqual(reason(run("volume_set", value: true)), "invalid")
        XCTAssertEqual(reason(run("volume_set", value: "50")), "invalid")
        XCTAssertEqual(reason(run("volume_set", value: 12.5)), "invalid")
        XCTAssertEqual(reason(run("lock", value: 1)), "invalid")
        XCTAssertEqual(reason(run("app:com.apple.Safari", value: "--args")), "invalid")
        let done = run("volume_set", value: 0)
        XCTAssertEqual(done?["status"] as? String, "done")
        XCTAssertEqual((done?["volume"] as? [String: Any])?["level"] as? Int, 0)
        XCTAssertEqual(system.calls, ["set_0"])
    }

    func testVolumeWithoutOutputIsUnavailable() {
        system.volumeState = nil
        XCTAssertEqual(reason(run("volume_up")), "unavailable")
    }

    // MARK: Replay, rate limits, permissions, busy

    func testReplayedOrStaleSequenceIsDroppedSilently() {
        XCTAssertNotNil(run("screensaver", sequence: 5))
        XCTAssertNil(run("screensaver", sequence: 5))
        XCTAssertNil(run("screensaver", sequence: 4))
        XCTAssertEqual(system.calls, ["screensaver"])
        host.disconnected(deviceID: phone)
        XCTAssertNotNil(run("screensaver", sequence: 1), "a new session starts again")
    }

    func testMalformedRequestsGetNoReply() {
        host.receive(kind: "actions.run", payload: ["version": 2, "requestId": UUID().uuidString, "action": "lock", "sequence": 1], deviceID: phone, deviceName: "P")
        host.receive(kind: "actions.run", payload: ["version": 1, "requestId": "nope", "action": "lock", "sequence": 2], deviceID: phone, deviceName: "P")
        host.receive(kind: "actions.run", payload: ["version": 1, "requestId": UUID().uuidString, "action": "lock", "sequence": true], deviceID: phone, deviceName: "P")
        host.receive(kind: "actions.catalog", payload: ["version": 1, "requestId": UUID().uuidString, "action": "lock", "sequence": 3], deviceID: phone, deviceName: "P")
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testOtherActionsAreLimitedToThreeThenOneEveryTwoSeconds() {
        for _ in 0..<3 { XCTAssertEqual(run("screensaver")?["status"] as? String, "done") }
        XCTAssertEqual(reason(run("screensaver")), "rate_limited")
        now = now.addingTimeInterval(2)
        XCTAssertEqual(run("screensaver")?["status"] as? String, "done")
        XCTAssertEqual(reason(run("screensaver")), "rate_limited")
        XCTAssertEqual(system.calls.count, 4)
    }

    func testVolumeHasItsOwnLargerBucket() {
        for _ in 0..<3 { _ = run("screensaver") }
        for index in 0..<10 { XCTAssertEqual(run("volume_down")?["status"] as? String, "done", "\(index)") }
        XCTAssertEqual(reason(run("volume_down")), "rate_limited")
        now = now.addingTimeInterval(1)
        XCTAssertEqual(run("volume_down")?["status"] as? String, "done")
    }

    func testRefusalsAreAlwaysAnsweredButLoggedAtARateLimit() {
        let logged = { self.host.audit.entries.reduce(0) { $0 + $1.times } }
        allowed = false
        for _ in 0..<25 { XCTAssertEqual(reason(run("screensaver")), "not_allowed") }
        XCTAssertEqual(replies.count, 25)
        XCTAssertEqual(logged(), 10, "a flood of refusals does not rewrite the log each time")
        now = now.addingTimeInterval(2)
        _ = run("screensaver")
        XCTAssertEqual(logged(), 11)
        allowed = true
        XCTAssertEqual(run("screensaver")?["status"] as? String, "done")
        XCTAssertEqual(logged(), 12, "what ran is always logged")
    }

    func testLockNeedsAccessibility() {
        system.accessibilityTrusted = false
        XCTAssertEqual(reason(run("lock")), "permission_required")
        XCTAssertTrue(system.calls.isEmpty)
        system.accessibilityTrusted = true
        XCTAssertEqual(run("lock")?["status"] as? String, "done")
        XCTAssertEqual(system.calls, ["lock"])
    }

    func testOneShortcutAtATime() {
        let handle = host.config.shortcuts[0].id
        XCTAssertNil(run("shortcut:\(handle)"), "the result waits for the Shortcut")
        XCTAssertEqual(reason(run("shortcut:\(handle)")), "busy")
        system.shortcutCompletion?(.timedOut)
        XCTAssertEqual(reason(replies.last), "failed")
        now = now.addingTimeInterval(10)
        _ = run("shortcut:\(handle)")
        system.shortcutCompletion?(.notFound)
        XCTAssertEqual(reason(replies.last), "unavailable")
    }

    func testSleepAnswersBeforeSleeping() {
        let reply = run("sleep")
        XCTAssertEqual(reply?["status"] as? String, "done")
        XCTAssertTrue(system.calls.isEmpty, "sleep waits until the answer went out")
        let slept = expectation(description: "sleep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { slept.fulfill() }
        wait(for: [slept], timeout: 2)
        XCTAssertEqual(system.calls, ["sleep"])
    }

    // MARK: Catalog and audit

    func testCatalogListsOnlyAllowedEntriesAndMarksLockWithoutAccessibility() throws {
        system.accessibilityTrusted = false
        host.setSwitch(.screensaver, enabled: false)
        let payload = host.catalogPayload()
        let entries = try XCTUnwrap(payload["actions"] as? [[String: Any]])
        let ids = entries.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.prefix(6), ["lock", "sleep", "volume_down", "volume_mute", "volume_up", "volume_set"])
        XCTAssertFalse(ids.contains("screensaver"))
        XCTAssertTrue(ids.contains("app:com.apple.Safari"))
        XCTAssertTrue(ids.contains("shortcut:\(host.config.shortcuts[0].id)"))
        XCTAssertFalse(ids.contains { $0.contains("Focus") }, "a Shortcut name never becomes an identifier")
        XCTAssertEqual(entries.first?["blocked"] as? String, "permission_required")
        XCTAssertEqual((payload["volume"] as? [String: Any])?["level"] as? Int, 40)
        for entry in entries { XCTAssertLessThanOrEqual((entry["title"] as? String)?.count ?? 99, 64) }
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertLessThanOrEqual(data.count, 8192)
    }

    func testEmptyConfigPublishesNothing() {
        let empty = MacActionsHost(system: system, store: nil, audit: MacActionsAuditLog(store: nil))
        XCTAssertEqual((empty.catalogPayload()["actions"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(empty.catalogPayload()["volume"])
    }

    func testListsAreBoundedAndTitlesCleaned() {
        var config = MacActionsConfig()
        XCTAssertFalse(config.addApp(AllowedApp(bundleID: "bad id", name: "x")))
        XCTAssertTrue(config.addApp(AllowedApp(bundleID: "com.example.a", name: "Line\none\u{7}" + String(repeating: "x", count: 100))))
        XCTAssertFalse(config.addApp(AllowedApp(bundleID: "com.example.a", name: "dup")))
        XCTAssertEqual(config.apps[0].name.count, 64)
        XCTAssertFalse(config.apps[0].name.contains("\n"))
        for index in 0..<40 { _ = config.addShortcut(named: "S\(index)") }
        XCTAssertEqual(config.shortcuts.count, MacActionsConfig.maximumShortcuts)
        XCTAssertFalse(config.addShortcut(named: "   "))
    }

    func testIdentifiersParseStrictly() {
        XCTAssertEqual(MacActionID(wire: "lock"), .system(.lock))
        XCTAssertEqual(MacActionID(wire: "app:com.apple.Safari"), .app(bundleID: "com.apple.Safari"))
        XCTAssertNil(MacActionID(wire: "app:"))
        XCTAssertNil(MacActionID(wire: "app:com.apple.Safari --args"))
        XCTAssertNil(MacActionID(wire: "app:" + String(repeating: "a", count: 156)))
        XCTAssertNil(MacActionID(wire: "shortcut:ABCDEF00-0000-0000-0000-000000000000"))
        XCTAssertNotNil(MacActionID(wire: "shortcut:abcdef00-0000-0000-0000-000000000000"))
    }

    func testAuditRecordsEveryRunAndRefusalWithoutValues() {
        _ = run("volume_set", value: 73)
        _ = run("app:com.apple.Terminal")
        let entries = host.audit.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.outcome).sorted(), ["done", "not_allowed"])
        let encoded = String(data: try! JSONEncoder().encode(entries), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("value") || encoded.contains("level"), "the volume level is never kept: \(encoded)")
        XCTAssertEqual(Set(entries.map(\.action)), ["volume_set", "app:com.apple.Terminal"])
    }

    func testRepeatsMergeIntoOneLogEntry() {
        let log = MacActionsAuditLog(store: nil, clock: { [unowned self] in self.now })
        func entry(_ id: String, _ action: String, _ seconds: TimeInterval, outcome: String = "done", device: String = "phone") -> MacActionAuditEntry {
            MacActionAuditEntry(id: id, deviceID: device, deviceName: "OnePlus 11", action: action, title: action,
                                outcome: outcome, at: now.addingTimeInterval(seconds))
        }
        for i in 0..<12 { log.record(entry("up\(i)", "volume_up", TimeInterval(i))) }
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].times, 12)
        XCTAssertEqual(log.entries[0].id, "up11")
        XCTAssertEqual(log.entries[0].firstAt, now)
        XCTAssertEqual(log.entries[0].at, now.addingTimeInterval(11))

        log.record(entry("down", "volume_down", 20))
        log.record(entry("up-refused", "volume_up", 21, outcome: "rate_limited"))
        log.record(entry("up-other", "volume_up", 22, device: "tablet"))
        log.record(entry("up-later", "volume_up", 23 + MacActionsAuditStore.mergeWindow + 1, device: "tablet"))
        XCTAssertEqual(log.entries.map(\.id), ["up-later", "up-other", "up-refused", "down", "up11"])
        XCTAssertEqual(log.entries.map(\.times), [1, 1, 1, 1, 12])
    }

    func testOldLogsWithoutCountsDecodeAndMerge() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let at = Int(now.timeIntervalSince1970 * 1000)
        let old = (0..<3).map { #"{"action":"volume_up","at":\#(at - $0 * 1000),"deviceID":"phone","deviceName":"OnePlus 11","id":"\#($0)","outcome":"done","title":"Volume up"}"# }
        try Data("[\(old.joined(separator: ","))]".utf8).write(to: url)
        let entries = MacActionsAuditStore(fileURL: url).load(now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].times, 3)
        XCTAssertEqual(entries[0].id, "0")
    }

    func testConfigSurvivesARestart() {
        let defaults = UserDefaults(suiteName: "bridgey.tests.macactions.\(UUID().uuidString)")!
        let store = MacActionsConfigStore(defaults: defaults)
        let first = MacActionsHost(system: system, store: store, audit: MacActionsAuditLog(store: nil))
        first.setSwitch(.lock, enabled: true)
        first.addApps([AllowedApp(bundleID: "com.apple.Safari", name: "Safari")])
        let second = MacActionsHost(system: system, store: store, audit: MacActionsAuditLog(store: nil))
        XCTAssertTrue(second.config.isOn(.lock))
        XCTAssertFalse(second.config.isOn(.sleep))
        XCTAssertEqual(second.config.apps.map(\.bundleID), ["com.apple.Safari"])
    }

    func testFeatureIsOffByDefaultAndNeedsAGrant() {
        XCTAssertTrue(BridgeyFeature.macActions.needsDeviceGrant)
        XCTAssertFalse(featureEnabledByLegacyPeer(.macActions))
        XCTAssertFalse(effectiveGrantEnabled(globalEnabled: true, deviceGranted: nil))
    }

    func testVolumeStepsLikeTheKeys() {
        XCTAssertEqual(steppedVolume(0.5, up: true), 9.0 / 16)
        XCTAssertEqual(steppedVolume(0.5, up: false), 7.0 / 16)
        XCTAssertEqual(steppedVolume(1, up: true), 1)
        XCTAssertEqual(steppedVolume(0, up: false), 0)
    }
}

@MainActor
final class OpenLinksRightAwayTests: XCTestCase {
    private func request(_ action: String, _ link: String = "https://example.com/a") -> [String: Any] {
        ["version": 1, "requestId": UUID().uuidString, "feature": "links", "action": action, "value": link, "sequence": 1]
    }

    private func makeActions(openRightAway: Bool, opened: @escaping (URL) -> Void) -> (QuickActions, () -> [[String: Any]]) {
        let actions = QuickActions()
        var sent: [[String: Any]] = []
        actions.available = { $0 == .links }
        actions.availableFor = { feature, _ in feature == .links }
        actions.send = { _, payload in sent.append(payload); return true }
        actions.openRightAway = { openRightAway }
        actions.openURL = { opened($0); return true }
        return (actions, { sent })
    }

    func testOpenRightAwayOpensAndAnswersOpened() {
        var opened: [URL] = []
        let (actions, sent) = makeActions(openRightAway: true) { opened.append($0) }
        actions.receive("quick.request", payload: request("open"), from: "phone")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a"])
        XCTAssertEqual(sent().last?["opened"] as? Bool, true)
        XCTAssertNil(actions.receivedLink)
    }

    func testOpenRightAwayIsLimitedToOneLinkEveryThreeSecondsPerPhone() {
        var opened = 0
        var now = Date(timeIntervalSince1970: 1_000)
        let (actions, sent) = makeActions(openRightAway: true) { _ in opened += 1 }
        actions.clock = { now }
        actions.receive("quick.request", payload: request("open"), from: "phone")
        actions.receive("quick.request", payload: request("open"), from: "phone")
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(sent().last?["accepted"] as? Bool, false)
        actions.receive("quick.request", payload: request("open"), from: "tablet")
        XCTAssertEqual(opened, 2, "another phone has its own limit")
        now = now.addingTimeInterval(3)
        actions.receive("quick.request", payload: request("open"), from: "phone")
        XCTAssertEqual(opened, 3)
    }

    func testWithoutTheSettingAnOpenWaitsLikeAnOffer() {
        var opened = 0
        let (actions, sent) = makeActions(openRightAway: false) { _ in opened += 1 }
        actions.receive("quick.request", payload: request("open"), from: "phone")
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(actions.receivedLink, "https://example.com/a")
        XCTAssertEqual(sent().last?["accepted"] as? Bool, true)
        XCTAssertEqual(sent().last?["opened"] as? Bool, false)
    }

    func testUnsafeLinksAreNeverOpened() {
        var opened = 0
        let (actions, _) = makeActions(openRightAway: true) { _ in opened += 1 }
        for link in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.com", "bridgey://x"] {
            actions.receive("quick.request", payload: request("open", link), from: "phone")
        }
        actions.receive("quick.request", payload: request("run", "https://example.com"), from: "phone")
        XCTAssertEqual(opened, 0)
        XCTAssertNil(actions.receivedLink)
    }
}

final class IntentFileStagingTests: XCTestCase {
    func testFileNamesCannotEscapeTheStagingFolder() {
        XCTAssertEqual(IntentFileStaging.safeFileName("../../etc/passwd", fallback: "f"), "_.._etc_passwd")
        XCTAssertEqual(IntentFileStaging.safeFileName(".hidden", fallback: "f"), "hidden")
        XCTAssertEqual(IntentFileStaging.safeFileName("   ", fallback: "file-1"), "file-1")
        XCTAssertEqual(IntentFileStaging.safeFileName("a:b.txt", fallback: "f"), "a_b.txt")
    }

    func testOldStagingFoldersAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-intents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: old.path)
        _ = try IntentFileStaging.stage([], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }
}

@MainActor
final class BatteryAlertTests: XCTestCase {
    func testLowAlertsOncePerChargeCycle() {
        var tracker = BatteryAlertTracker()
        let t = BatteryAlertThresholds.default
        XCTAssertNil(tracker.update(level: 40, charging: false, thresholds: t))
        XCTAssertEqual(tracker.update(level: 20, charging: false, thresholds: t), .low)
        XCTAssertNil(tracker.update(level: 15, charging: false, thresholds: t), "no repeat while it keeps draining")
        XCTAssertNil(tracker.update(level: 21, charging: false, thresholds: t), "a small bounce does not count")
        XCTAssertNil(tracker.update(level: 19, charging: false, thresholds: t))
        XCTAssertNil(tracker.update(level: 19, charging: true, thresholds: t), "plugged in: a new cycle")
        XCTAssertEqual(tracker.update(level: 18, charging: false, thresholds: t), .low)
    }

    func testFullAlertsOnceUntilItDrainsBelowTheThreshold() {
        var tracker = BatteryAlertTracker()
        let t = BatteryAlertThresholds.default
        XCTAssertNil(tracker.update(level: 99, charging: true, thresholds: t))
        XCTAssertEqual(tracker.update(level: 100, charging: true, thresholds: t), .full)
        XCTAssertNil(tracker.update(level: 100, charging: false, thresholds: t), "unplugging at 100% is not a second alert")
        XCTAssertNil(tracker.update(level: 100, charging: true, thresholds: t))
        XCTAssertNil(tracker.update(level: 96, charging: false, thresholds: t))
        XCTAssertNil(tracker.update(level: 94, charging: false, thresholds: t))
        XCTAssertEqual(tracker.update(level: 100, charging: true, thresholds: t), .full)
    }

    func testCustomAndOffThresholds() {
        var tracker = BatteryAlertTracker()
        let limit = BatteryAlertThresholds(low: 0, full: 80)
        XCTAssertNil(tracker.update(level: 5, charging: false, thresholds: limit), "low is off")
        XCTAssertNil(tracker.update(level: 80, charging: false, thresholds: limit), "a charge limit alert needs charging")
        XCTAssertEqual(tracker.update(level: 80, charging: true, thresholds: limit), .full)
        XCTAssertEqual(batteryAlertText(.full, phone: "OnePlus 11", level: 80).title, "OnePlus 11 at 80%")
        XCTAssertEqual(batteryAlertText(.full, phone: "OnePlus 11", level: 100).title, "OnePlus 11 fully charged")
        XCTAssertEqual(batteryAlertText(.low, phone: "OnePlus 11", level: 15).title, "OnePlus 11 at 15%")
    }

    func testAlertsArePerPhoneAndUseTheirOwnThresholds() {
        let defaults = UserDefaults(suiteName: "bridgey.tests.battery.\(UUID().uuidString)")!
        let alerts = BatteryAlerts(settings: BatteryAlertSettings(defaults: defaults))
        var posted: [String] = []
        alerts.post = { _, title, _ in posted.append(title) }
        alerts.setThresholds(BatteryAlertThresholds(low: 30, full: 100), for: "b")
        alerts.received(level: 25, charging: false, deviceID: "a", phone: "OnePlus 11")
        alerts.received(level: 25, charging: false, deviceID: "b", phone: "Pixel")
        alerts.received(level: 24, charging: false, deviceID: "b", phone: "Pixel")
        XCTAssertEqual(posted, ["Pixel at 25%"])
        XCTAssertEqual(alerts.thresholds(for: "a"), .default)
        alerts.forget("b")
        XCTAssertEqual(alerts.thresholds(for: "b"), .default)
    }
}

@MainActor
final class FocusSyncTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)
    private var sent: [Bool] = []
    private var ran: [String] = []
    /// When false, a Shortcut keeps running until the test calls its completion.
    private var runsFinishAtOnce = true
    private var running: [() -> Void] = []
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

    private func make(_ settings: FocusSyncSettings) -> FocusSync {
        let sync = FocusSync(defaults: nil, clock: { [unowned self] in self.now })
        sync.broadcast = { [unowned self] in self.sent.append($0) }
        sync.runShortcut = { [unowned self] name, done in
            self.ran.append(name)
            if self.runsFinishAtOnce { done() } else { self.running.append(done) }
        }
        sync.schedule = { [unowned self] delay, work in self.scheduled.append((delay, work)) }
        sync.update { $0 = settings }
        sent = []
        ran = []
        return sync
    }

    func testNothingHappensWhileBothDirectionsAreOff() {
        let sync = make(FocusSyncSettings())
        XCTAssertFalse(sync.advertised)
        sync.localFocusChanged(true)
        sync.received(active: true, from: "phone")
        XCTAssertEqual(sent, [])
        XCTAssertEqual(ran, [])
    }

    func testShareSendsChangesOnly() {
        let sync = make(FocusSyncSettings(share: true))
        sync.localFocusChanged(true)
        sync.localFocusChanged(true)
        sync.localFocusChanged(false)
        XCTAssertEqual(sent, [true, false])
        XCTAssertEqual(sync.stateForNewPhone, false)
    }

    func testFollowRunsTheChosenShortcutsAndDoesNotEchoBack() {
        let sync = make(FocusSyncSettings(share: true, follow: true, onShortcut: "Focus on", offShortcut: "Focus off"))
        sync.received(active: true, from: "phone")
        XCTAssertEqual(ran, ["Focus on"])
        // The Focus filter fires for the change Bridgey made: not sent back within 10 seconds.
        sync.localFocusChanged(true)
        XCTAssertEqual(sent, [])
        sync.received(active: true, from: "phone")
        XCTAssertEqual(ran, ["Focus on"], "the same state runs nothing")
        now = now.addingTimeInterval(11)
        sync.received(active: false, from: "phone")
        XCTAssertEqual(ran, ["Focus on", "Focus off"])
    }

    func testAnyQuietPhoneKeepsTheFocusOn() {
        let sync = make(FocusSyncSettings(follow: true, onShortcut: "On", offShortcut: "Off"))
        sync.received(active: true, from: "a")
        sync.received(active: true, from: "b")
        sync.received(active: false, from: "a")
        XCTAssertEqual(ran, ["On"])
        now = now.addingTimeInterval(2)
        sync.received(active: false, from: "b")
        XCTAssertEqual(ran, ["On", "Off"])
    }

    func testOneShortcutAtATimeAtMostEveryTwoSecondsThenTheLatestState() {
        runsFinishAtOnce = false
        let sync = make(FocusSyncSettings(follow: true, onShortcut: "On", offShortcut: "Off"))
        sync.received(active: true, from: "a")
        for active in [false, true, false, true, false] { sync.received(active: active, from: "a") }
        XCTAssertEqual(ran, ["On"], "nothing else starts while a Shortcut runs")
        running.removeFirst()()
        XCTAssertEqual(ran, ["On"], "the next run waits for the two seconds")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled.first?.delay ?? 0, 2, accuracy: 0.001)
        sync.received(active: true, from: "a")
        sync.received(active: false, from: "a")
        XCTAssertEqual(scheduled.count, 1, "flips while waiting are coalesced")
        now = now.addingTimeInterval(2)
        scheduled.removeFirst().work()
        XCTAssertEqual(ran, ["On", "Off"], "only the latest state runs")
        running.removeFirst()()
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertEqual(sync.applied, false)
    }

    func testTurningFollowOffHandsTheFocusBack() {
        let sync = make(FocusSyncSettings(follow: true, onShortcut: "On", offShortcut: "Off"))
        sync.received(active: true, from: "a")
        sync.update { $0.follow = false }
        XCTAssertEqual(ran, ["On", "Off"])
        sync.received(active: true, from: "a")
        XCTAssertEqual(ran, ["On", "Off"])
    }

    func testWithoutAShortcutNothingRuns() {
        let sync = make(FocusSyncSettings(follow: true))
        sync.received(active: true, from: "a")
        XCTAssertEqual(ran, [])
        XCTAssertNil(sync.applied)
    }
}

@MainActor
final class PhoneCameraTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 5_000)
    private var sent: [[String: Any]] = []
    private var copied: [URL] = []

    private func make() -> PhoneCamera {
        let camera = PhoneCamera(defaults: nil, clock: { [unowned self] in self.now })
        camera.send = { [unowned self] _, payload in self.sent.append(payload); return true }
        camera.copyImage = { [unowned self] in self.copied.append($0) }
        return camera
    }

    func testOneOpenRequestPerPhoneAndSpacing() throws {
        let camera = make()
        let id = try XCTUnwrap(camera.request(from: "a", phoneName: "OnePlus 11"))
        XCTAssertEqual(sent.last?["mode"] as? String, "photo")
        XCTAssertEqual(sent.last?["requestId"] as? String, id)
        XCTAssertNil(camera.request(from: "a", phoneName: "OnePlus 11"), "one open request")
        XCTAssertNotNil(camera.request(from: "b", phoneName: "Pixel"), "another phone has its own")
        camera.received(status: "cancelled", requestID: id, from: "a", phoneName: "OnePlus 11")
        XCTAssertNil(camera.request(from: "a", phoneName: "OnePlus 11"), "at most one every 3 seconds")
        now = now.addingTimeInterval(3)
        XCTAssertNotNil(camera.request(from: "a", phoneName: "OnePlus 11"))
    }

    func testRequestsExpireAfterTwoMinutes() throws {
        let camera = make()
        let id = try XCTUnwrap(camera.request(from: "a", phoneName: "P"))
        now = now.addingTimeInterval(PhoneCamera.lifetime)
        XCTAssertFalse(camera.matches(id, from: "a"))
        XCTAssertEqual(camera.outcomes[id], .cancelled)
    }

    func testOnlyThePhoneThatWasAskedCanAnswer() throws {
        let camera = make()
        let id = try XCTUnwrap(camera.request(from: "a", phoneName: "P"))
        XCTAssertFalse(camera.matches(id, from: "b"))
        XCTAssertFalse(camera.matches(UUID().uuidString.lowercased(), from: "a"))
        XCTAssertFalse(camera.matches(nil, from: "a"))
        camera.received(status: "locked", requestID: id, from: "b", phoneName: "Q")
        XCTAssertNil(camera.status.flatMap { $0.contains("Unlock") ? $0 : nil })
        camera.received(status: "locked", requestID: id, from: "a", phoneName: "OnePlus 11")
        XCTAssertEqual(camera.status, "Unlock OnePlus 11 to take the photo")
        XCTAssertTrue(camera.matches(id, from: "a"), "locked keeps the request open")
    }

    func testPhotoIsCopiedOnlyWhenChosen() throws {
        let camera = make()
        let first = try XCTUnwrap(camera.request(from: "a", phoneName: "P"))
        camera.photoArrived(URL(fileURLWithPath: "/tmp/one.jpg"), requestID: first, from: "a", phoneName: "P")
        XCTAssertEqual(copied, [])
        XCTAssertEqual(camera.photos[first]?.lastPathComponent, "one.jpg")
        camera.setCopyToClipboard(true)
        now = now.addingTimeInterval(5)
        let second = try XCTUnwrap(camera.request(from: "a", phoneName: "P"))
        camera.photoArrived(URL(fileURLWithPath: "/tmp/two.jpg"), requestID: second, from: "a", phoneName: "P")
        XCTAssertEqual(copied.map(\.lastPathComponent), ["two.jpg"])
        camera.photoArrived(URL(fileURLWithPath: "/tmp/three.jpg"), requestID: second, from: "a", phoneName: "P")
        XCTAssertEqual(copied.count, 1, "a request takes one photo")
    }
}
