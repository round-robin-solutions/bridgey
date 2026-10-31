import Foundation
import XCTest
@testable import BridgeyMac

/// Settings sync (docs/folders-and-settings-sync.md 8.2, 8.4 and 8.5): merge and snapshot rules, stamping, the
/// session rules, permissions, Apply to all, relaying, Choose what syncs and the rate limit. Android runs the
/// same cases in SettingsSyncTest.kt.
@MainActor
final class SettingsSyncTests: XCTestCase {
    private let phone = "7e57d00d-0000-4000-8000-00000000000a"
    private let macA = "7e57d00d-0000-4000-8000-00000000000b"
    private let macB = "7e57d00d-0000-4000-8000-00000000000c"
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
    }

    // MARK: Pure rules

    func testCompareTimestampThenVersionThenDeviceBytes() {
        let a = SyncRecord(value: .bool(true), changedAt: 1000, version: 3, changedBy: "a")
        XCTAssertGreaterThan(compareSyncRecords(SyncRecord(value: .bool(false), changedAt: 1200, version: 1, changedBy: "a"), a), 0)
        XCTAssertGreaterThan(compareSyncRecords(SyncRecord(value: .bool(false), changedAt: 1000, version: 4, changedBy: "a"), a), 0)
        XCTAssertGreaterThan(compareSyncRecords(SyncRecord(value: .bool(false), changedAt: 1000, version: 3, changedBy: "b"), a), 0)
        XCTAssertEqual(compareSyncRecords(a, a), 0)
        XCTAssertGreaterThan(compareUTF8("a", "B"), 0)
        XCTAssertGreaterThan(compareUTF8("\u{1F600}", "\u{FFFD}"), 0)
        XCTAssertLessThan(compareUTF8("ab", "abc"), 0)
    }

    func testStampingNeverGoesBackwards() {
        let current = SyncRecord(value: .bool(true), changedAt: 9000, version: 3, changedBy: macB)
        XCTAssertEqual(stampLocalEdit(current, value: .bool(false), now: 5000, device: macA),
                       SyncRecord(value: .bool(false), changedAt: 9001, version: 4, changedBy: macA))
        XCTAssertEqual(stampLocalEdit(current, value: .bool(false), now: 20_000, device: macA).stamp, SyncStamp(changedAt: 20_000, version: 4, changedBy: macA))
        let capped = stampLocalEdit(SyncRecord(value: .bool(true), changedAt: SettingsSyncLimits.maximumInteger, version: 3, changedBy: ""),
                                    value: .bool(false), now: 1, device: macA)
        XCTAssertEqual(capped.stamp, SyncStamp(changedAt: SettingsSyncLimits.maximumInteger, version: 4, changedBy: macA))
    }

    func testSnapshotOutcomes() {
        let never = SyncRecord.neverChosen(.bool(false))
        let chosenOn = SyncRecord(value: .bool(true), changedAt: 10, version: 1, changedBy: macB)
        let chosenOff = SyncRecord(value: .bool(false), changedAt: 20, version: 2, changedBy: macA)
        XCTAssertEqual(snapshotOutcome(local: never, remote: chosenOn), .adopt)
        XCTAssertEqual(snapshotOutcome(local: chosenOff, remote: chosenOn), .different)
        XCTAssertEqual(snapshotOutcome(local: chosenOn, remote: never), .same)
        // The Mac already does what "sending device chooses" means: not different.
        let fixed = SyncRecord(value: .string("fixed"), changedAt: 1, version: 1, changedBy: macA)
        let senderPicks = SyncRecord(value: .string("sender_picks"), changedAt: 5, version: 2, changedBy: phone)
        XCTAssertEqual(snapshotOutcome(local: fixed, remote: senderPicks, alreadyMeans: { macFolderReceiveMode(for: $0) == .fixed }), .same)
    }

    func testUpgradeStampsEveryStoredValue() {
        let stored = settingsSyncStoredValues([
            "settings.reduceMotion": false, "settings.activity.previews": true,
            "settings.folders.receiveMode": "fixed", "settings.folders.conflict": 5,
            "settings.global.calls": false, "settings.global.remote_input_draft1": true,
            "settings.autoClipboard.enabled": true, "settings.codes.enabled": "yes",
            "settings.focusSync": try! JSONEncoder().encode(FocusSyncSettings(share: true, follow: false)),
        ])
        XCTAssertEqual(stored, [.reduceMotion: .bool(false), .activityPreviews: .bool(true), .folderDestination: .string("fixed"),
                                .featureCalls: .bool(false), .featureRemoteInput: .bool(true), .autoClipboard: .bool(true),
                                .focusShare: .bool(true), .focusFollow: .bool(false)])
        let records = upgradeSyncRecords(stored: stored, current: [.featureFiles: .bool(true), .reduceMotion: .bool(true)], device: macA)
        // Any stored value counts as chosen, defaults too.
        XCTAssertEqual(records[.reduceMotion], SyncRecord(value: .bool(false), changedAt: 1, version: 1, changedBy: macA))
        XCTAssertEqual(records[.activityPreviews], SyncRecord(value: .bool(true), changedAt: 1, version: 1, changedBy: macA))
        XCTAssertEqual(records[.featureCalls], SyncRecord(value: .bool(false), changedAt: 1, version: 1, changedBy: macA))
        // Never stored: the current value, never chosen; a key with no setting here keeps its default.
        XCTAssertEqual(records[.featureFiles], .neverChosen(.bool(true)))
        XCTAssertEqual(records[.featureCamera], .defaultRecord(.featureCamera))
        XCTAssertEqual(records[.folderConflict], .defaultRecord(.folderConflict))
        XCTAssertEqual(records[.codesEnabled], .defaultRecord(.codesEnabled))
        XCTAssertEqual(settingsSyncStoredValues(["settings.folders.receiveMode": "ask"])[.folderDestination], .string("receiver_asks"))
    }

    func testMacFolderDestinationReadsSenderPicksAsFixed() {
        XCTAssertEqual(macFolderReceiveMode(for: .string("sender_picks")), .fixed)
        XCTAssertEqual(macFolderReceiveMode(for: .string("receiver_asks")), .ask)
        var mode = MacFolderReceiveMode.fixed
        let setting = SyncedSetting(read: { .string(mode == .ask ? "receiver_asks" : "fixed") },
                                    matches: { macFolderReceiveMode(for: $0) == mode },
                                    write: { mode = macFolderReceiveMode(for: $0) })
        let engine = SettingsSyncEngine(localDeviceID: macA, records: [:], settings: [.folderDestination: setting], clock: { 50 })
        XCTAssertEqual(engine.observeLocal(), [])
        mode = .ask
        XCTAssertEqual(engine.observeLocal(), [.folderDestination])
        XCTAssertEqual(engine.record(.folderDestination).value, .string("receiver_asks"))
    }

    func testActivityDetailTokens() {
        let content = SettingsSyncDetail.encode([.featureCalls: .bool(true), .reduceMotion: .bool(false), .folderConflict: .string("new_folder")])
        XCTAssertEqual(content, "folder_conflict=3,reduce_motion=0,calls=1")
        XCTAssertEqual(SettingsSyncDetail.title(device: "OnePlus 11"), "Settings synced with OnePlus 11")
        XCTAssertEqual(SettingsSyncDetail.detail("reduce_motion=0,calls=1"), "Reduce motion turned off, Calls turned on")
        XCTAssertEqual(SettingsSyncDetail.detail("folder_destination=1,auto_clipboard=1"), "Folders: ask where to save, Automatic clipboard turned on")
        let all = SettingsSyncDetail.encode(Dictionary(uniqueKeysWithValues: SyncKey.allCases.map { ($0, $0.defaultValue) }))
        XCTAssertNotNil(SettingsSyncDetail.clean(all))
        XCTAssertEqual(SettingsSyncDetail.decode(all).count, 28)
        XCTAssertEqual(SyncKey.allCases.count, 28)
        XCTAssertEqual(SyncKey.allCases.suffix(7).map(\.token),
                       ["screen", "sms", "auto_update_all", "connect_away", "folder_include_hidden", "folder_include_system", "codes_email"])
        // Update all devices automatically is a setting on the Mac too; Photos for the Mac is only stored and relayed.
        XCTAssertEqual(SyncKey.listedOnMac.count, 27)
        XCTAssertTrue(SyncKey.allCases.allSatisfy { $0.token.count <= 24 })
        XCTAssertNil(SettingsSyncDetail.clean("reduce motion on"))
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let items = ActivityHistory.add([], kind: .settingsSynced, deviceID: phone, deviceName: "OnePlus 11", content: "calls=1", now: now, nextID: 1)
        XCTAssertEqual(items.first?.content, "calls=1")
        XCTAssertEqual(items.first?.kind.category, .other)
        XCTAssertEqual(ActivityHistory.decode(try! ActivityHistory.encode(items), now: now), items)
        XCTAssertEqual(ActivityText.title(items[0], showPreviews: true), "Settings synced with OnePlus 11")
        XCTAssertEqual(ActivityText.detail(items[0], showPreviews: true), "Calls turned on")
    }

    // MARK: Sessions

    func testSnapshotOnConnectThenNothingWhenEqual() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.log.map(\.kind).sorted(), [SettingsSyncKinds.ack, SettingsSyncKinds.ack, SettingsSyncKinds.snapshot, SettingsSyncKinds.snapshot])
        XCTAssertEqual(net.activity, [])
        XCTAssertEqual(net.controllers[macA]!.status(.featureCalls), SyncRowStatus())
    }

    func testFirstConnectAdoptsWhatTheOtherDeviceChose() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.edit(phone, .reduceMotion, .bool(true))
        net.edit(phone, .featureFiles, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.reduceMotion], .bool(true))
        XCTAssertEqual(net.values[macA]![.featureFiles], .bool(true))
        XCTAssertEqual(net.activity, ["\(macA)<-\(phone): reduce_motion=1,files=1"])
        // Turned on from the phone, needing nothing here: an activity entry, no notification.
        XCTAssertEqual(net.turnedOn, [])
        // Applying never stamps again, and nothing is different afterwards (the ack updated what the phone holds).
        XCTAssertEqual(net.controllers[macA]!.engine.observeLocal(), [])
        XCTAssertEqual(net.controllers[phone]!.engine.differentOn(.reduceMotion), [])
        XCTAssertEqual(net.controllers[macA]!.engine.differentOn(.reduceMotion), [])
    }

    /// The Mac chose, the phone never did: the phone adopts on connect, and its ack of the Mac's snapshot (recorded in
    /// flight under the snapshot's message ID) clears "Different" on the Mac.
    func testAdoptedSnapshotLeavesNothingDifferent() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.edit(macA, .featureLinks, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureLinks], .bool(true))
        XCTAssertEqual(net.controllers[macA]!.status(.featureLinks).differentOn, [])
        XCTAssertEqual(net.controllers[phone]!.status(.featureLinks).differentOn, [])
    }

    /// Both chose while apart: nothing changes on connect, both show "Different on", Apply to all settles it.
    func testDifferentAfterOfflineThenApplyToAll() {
        let net = Net(self)
        net.add(phone, clock: 5000); net.add(macA, clock: 7000)
        net.edit(phone, .featureCalls, .bool(true))
        // Chosen off on the Mac: turned on, then off again.
        net.edit(macA, .featureCalls, .bool(true))
        net.edit(macA, .featureCalls, .bool(false))
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureCalls], .bool(true))
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(false))
        XCTAssertEqual(net.controllers[macA]!.status(.featureCalls).differentOn, ["Device a"])
        XCTAssertEqual(net.controllers[phone]!.status(.featureCalls).differentOn, ["Device b"])
        XCTAssertEqual(net.sentLog(kind: SettingsSyncKinds.update), 0)
        // Apply to all on the phone: its value wins even though the Mac's clock runs ahead.
        net.controllers[phone]!.applyToAll(.featureCalls)
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(true))
        XCTAssertEqual(net.controllers[macA]!.status(.featureCalls).differentOn, [])
        XCTAssertEqual(net.controllers[phone]!.status(.featureCalls).differentOn, [])
    }

    /// "Include hidden files" and "Include system files" are the phone's two switches under the documented keys,
    /// and the Mac-only call policy has no key.
    func testHiddenAndSystemFileChoicesSyncUnderTheDocumentedKeys() {
        XCTAssertEqual(SyncKey.folderIncludeHidden.rawValue, "files.folder_include_hidden")
        XCTAssertEqual(SyncKey.folderIncludeSystem.rawValue, "files.folder_include_system")
        XCTAssertEqual(SyncKey.folderIncludeHidden.defaultValue, .bool(false))
        XCTAssertEqual(SyncKey.folderIncludeSystem.defaultValue, .bool(false))
        XCTAssertFalse(SyncKey.folderIncludeHidden.sharesWhenOn || SyncKey.folderIncludeSystem.sharesWhenOn)
        XCTAssertNil(SyncKey.folderIncludeHidden.feature)
        XCTAssertTrue(SyncKey.allCases.allSatisfy { !$0.rawValue.lowercased().contains("otherapps") && !$0.rawValue.contains("other_apps") })
        XCTAssertEqual(SyncKey.folderIncludeHidden.name, "Hidden files in folders")
        XCTAssertEqual(SettingsSyncDetail.detail("folder_include_hidden=1,folder_include_system=0"),
                       "Hidden files in folders turned on, System files in folders turned off")
        // A Mac that stored the switches before sync stamps them as chosen; one that never did keeps the default.
        let stored = settingsSyncStoredValues(["settings.folders.includeHidden": true, "settings.folders.includeSystem": false])
        XCTAssertEqual(stored[.folderIncludeHidden], .bool(true))
        XCTAssertEqual(stored[.folderIncludeSystem], .bool(false))
        XCTAssertNil(settingsSyncStoredValues(["settings.calls.otherApps": "allow"])[.folderIncludeHidden])

        let net = Net(self)
        net.add(phone, clock: 1000); net.add(macA, clock: 1200)
        net.connect(phone, macA)
        net.deliverAll()
        net.values[phone]![.folderIncludeHidden] = .bool(true)
        net.values[macA]![.folderIncludeSystem] = .bool(true)
        net.controllers[phone]!.localChanged(); net.controllers[phone]!.flush()
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.folderIncludeHidden], .bool(true))
        XCTAssertEqual(net.values[phone]![.folderIncludeSystem], .bool(true))
    }

    /// Also read codes in email is codes.email, appended last, on until chosen: nobody chose, so nothing is sent or
    /// shown as different; an explicit off syncs and becomes the other device's choice.
    func testCodesFromEmailSyncsUnderCodesEmailAndOnlyAsAChoice() {
        XCTAssertEqual(SyncKey.codesEmail.rawValue, "codes.email")
        XCTAssertEqual(SyncKey.allCases.last, .codesEmail)
        XCTAssertEqual(SyncKey.codesEmail.defaultValue, .bool(true))
        XCTAssertTrue(SyncKey.codesEmail.sharesWhenOn)
        XCTAssertNil(SyncKey.codesEmail.feature)
        XCTAssertTrue(SyncKey.listedOnMac.contains(.codesEmail))
        XCTAssertEqual(SyncKey.codesEmail.name, "Codes from email")
        XCTAssertEqual(SettingsSyncDetail.detail("codes_email=0"), "Codes from email turned off")
        // A Mac that stored a choice before sync stamps it as chosen; one that never did keeps following the default.
        XCTAssertEqual(settingsSyncStoredValues(["settings.codes.email": false])[.codesEmail], .bool(false))
        XCTAssertNil(settingsSyncStoredValues([:])[.codesEmail])

        let net = Net(self)
        let phoneEmail = Following(defaultOn: true)
        let macEmail = Following(defaultOn: true)
        net.add(phone, override: [.codesEmail: phoneEmail.setting], isPhone: true)
        net.add(macA, override: [.codesEmail: macEmail.setting])
        net.connect(phone, macA)
        net.deliverAll()
        net.log.removeAll()
        net.controllers[macA]!.localChanged()
        net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.log.count, 0)
        XCTAssertFalse(net.controllers[macA]!.engine.record(.codesEmail).chosen)
        XCTAssertEqual(net.controllers[macA]!.status(.codesEmail).differentOn, [])
        // The phone's person turns it off: the Mac takes it as its own choice.
        phoneEmail.choice = false
        net.controllers[phone]!.localChanged()
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertEqual(macEmail.choice, false)
        XCTAssertEqual(macEmail.writes, 1)
    }

    /// Section 8.2 with live updates: the later of two edits made at the same moment wins on both, after one
    /// update and one acknowledgement each way.
    func testConcurrentUpdatesConvergeWithoutPingPong() {
        let net = Net(self)
        net.add(phone, clock: 1000); net.add(macA, clock: 1200)
        net.connect(phone, macA)
        net.deliverAll()
        net.log.removeAll()
        net.values[phone]![.folderConflict] = .string("merge")
        net.values[macA]![.folderConflict] = .string("replace")
        net.controllers[phone]!.localChanged(); net.controllers[phone]!.flush()
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.folderConflict], .string("replace"))
        XCTAssertEqual(net.values[macA]![.folderConflict], .string("replace"))
        XCTAssertEqual(net.log.map(\.kind).sorted(), [SettingsSyncKinds.ack, SettingsSyncKinds.ack, SettingsSyncKinds.update, SettingsSyncKinds.update])
        XCTAssertEqual(net.log.first { $0.kind == SettingsSyncKinds.ack && $0.from == phone }?.payload["applied"] as? [String], ["files.folder_conflict"])
        XCTAssertEqual(net.log.first { $0.kind == SettingsSyncKinds.ack && $0.from == macA }?.payload["kept"] as? [String], ["files.folder_conflict"])
    }

    func testRemoteEnableIsAppliedRecordedAndAnnounced() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.connect(phone, macA)
        net.deliverAll()
        net.values[macA]![.featureCalls] = .bool(true)
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureCalls], .bool(true))
        XCTAssertEqual(net.activity, ["\(phone)<-\(macA): calls=1"])
        // Needs nothing here: recorded, never announced (only a change that waits for a permission notifies).
        XCTAssertEqual(net.turnedOn, [])
        net.values[macA]![.featureCalls] = .bool(false)
        net.values[macA]![.reduceMotion] = .bool(true)
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.turnedOn.count, 0)
        XCTAssertEqual(net.activity.last, "\(phone)<-\(macA): reduce_motion=1,calls=0")
    }

    func testPermissionPendingIsSentAndClearedWhenGranted() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.missing[phone] = [.featureNotifications]
        net.connect(phone, macA)
        net.deliverAll()
        net.log.removeAll()
        net.values[macA]![.featureNotifications] = .bool(true)
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureNotifications], .bool(true))
        XCTAssertEqual(net.turnedOn, ["\(phone): feature.notifications waiting=true"])
        XCTAssertTrue(net.controllers[phone]!.status(.featureNotifications).localWaiting)
        XCTAssertEqual(net.controllers[macA]!.status(.featureNotifications).peerWaiting, ["Device a"])
        let listUpdate = net.log.first { $0.from == phone && $0.kind == SettingsSyncKinds.update }
        XCTAssertEqual((listUpdate?.payload["records"] as? [String: Any])?.count, 0)
        XCTAssertEqual(listUpdate?.payload["waiting"] as? [String], ["feature.notifications"])
        // Granted on the phone: an update with no records and the new list.
        net.log.removeAll()
        net.missing[phone] = []
        net.controllers[phone]!.permissionsChanged()
        net.deliverAll()
        let cleared = net.log.first { $0.from == phone && $0.kind == SettingsSyncKinds.update }
        XCTAssertEqual((cleared?.payload["records"] as? [String: Any])?.count, 0)
        XCTAssertEqual(cleared?.payload["waiting"] as? [String], [])
        XCTAssertEqual(net.controllers[macA]!.status(.featureNotifications).peerWaiting, [])
        XCTAssertFalse(net.controllers[phone]!.status(.featureNotifications).localWaiting)
    }

    /// A remote change never gives this Mac's own consent: codes stays off and waits, nothing sends an "off" back,
    /// and once the person allows it here codes turns on and the wait clears.
    func testRemoteCodesWaitForThisMacsConsent() {
        let net = Net(self)
        var codesOn = false
        var consent = false
        let gate = CodesSyncGate(defaults: suite().0, isOn: { codesOn }, setOn: { codesOn = $0 }, canEnable: { consent })
        net.add(phone)
        net.add(macA, override: [.codesEnabled: gate.setting], lacks: { $0 == .codesEnabled && gate.pending })
        let mac = macA
        gate.onChange = { net.controllers[mac]!.permissionsChanged() }
        net.connect(phone, macA)
        net.deliverAll()
        net.log.removeAll()
        net.edit(phone, .codesEnabled, .bool(true))
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertFalse(codesOn)
        XCTAssertTrue(gate.pending)
        XCTAssertTrue(net.controllers[macA]!.status(.codesEnabled).localWaiting)
        XCTAssertEqual(net.turnedOn, ["\(macA): codes.enabled waiting=true"])
        XCTAssertEqual(net.controllers[phone]!.status(.codesEnabled).peerWaiting, ["Device b"])
        // Reads as on: no local edit, and no record for codes ever leaves the Mac.
        XCTAssertEqual(net.controllers[macA]!.engine.observeLocal(), [])
        let macRecords = net.log.filter { $0.from == macA }.compactMap { $0.payload["records"] as? [String: Any] }
        XCTAssertTrue(macRecords.allSatisfy { $0["codes.enabled"] == nil })
        // Allowed here (the card's consent step turns codes on): the wait clears and nothing is re-stamped.
        consent = true
        codesOn = true
        gate.codesChanged(on: true)
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertFalse(gate.pending)
        XCTAssertEqual(net.controllers[phone]!.status(.codesEnabled).peerWaiting, [])
        XCTAssertEqual(net.controllers[macA]!.engine.record(.codesEnabled).changedBy, phone)
        XCTAssertEqual(net.values[phone]![.codesEnabled], .bool(true))
    }

    /// Turning codes off on the Mac while it waits ends the wait and syncs the off as a normal edit.
    func testDecliningWaitingCodesSyncsOff() {
        let net = Net(self)
        var codesOn = false
        let gate = CodesSyncGate(defaults: suite().0, isOn: { codesOn }, setOn: { codesOn = $0 }, canEnable: { false })
        net.add(phone, clock: 1000)
        net.add(macA, clock: 2000, override: [.codesEnabled: gate.setting], lacks: { $0 == .codesEnabled && gate.pending })
        let mac = macA
        gate.onChange = { net.controllers[mac]!.permissionsChanged() }
        net.connect(phone, macA)
        net.deliverAll()
        net.edit(phone, .codesEnabled, .bool(true))
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertTrue(gate.pending)
        gate.turnedOffLocally()
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertFalse(gate.pending)
        XCTAssertEqual(net.values[phone]![.codesEnabled], .bool(false))
    }

    /// Text messages turned on from the phone: applied, an activity entry, no notification (it needs nothing here).
    func testRemoteTextMessagesTurnOnIsActivityOnly() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.connect(phone, macA)
        net.deliverAll()
        net.edit(phone, .featureSms, .bool(true))
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.featureSms], .bool(true))
        XCTAssertEqual(net.activity, ["\(macA)<-\(phone): sms=1"])
        XCTAssertEqual(net.turnedOn, [])
        XCTAssertEqual(SettingsSyncDetail.detail("sms=1"), "Text messages turned on")
    }

    /// Show phone screens turned on from the phone goes through PhoneScreen.setEnabled, like the Settings switch.
    func testRemoteScreenEnableAppliesThroughPhoneScreen() {
        let (defaults, _) = suite()
        let screen = PhoneScreen(defaults: defaults)
        var settingsChanges = 0
        screen.onSettingsChange = { settingsChanges += 1 }
        let net = Net(self)
        net.add(phone)
        net.add(macA, override: [.featureScreen: SettingsSyncController.screenSetting(screen)])
        net.connect(phone, macA)
        net.deliverAll()
        net.edit(phone, .featureScreen, .bool(true))
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertTrue(screen.enabled)
        XCTAssertTrue(defaults.bool(forKey: PhoneScreen.defaultsKey))
        XCTAssertEqual(settingsChanges, 1)
        XCTAssertEqual(net.activity, ["\(macA)<-\(phone): screen=1"])
        XCTAssertEqual(net.turnedOn, [])
        // Applied, so the Mac's own observer stamps nothing.
        XCTAssertEqual(net.controllers[macA]!.engine.observeLocal(), [])
    }

    /// Update all devices automatically: follows the channel's default until the person chooses.
    final class Following {
        var defaultOn: Bool
        var choice: Bool?
        var writes = 0
        init(defaultOn: Bool) { self.defaultOn = defaultOn }
        /// Holds this fake strongly (the fake never holds the setting, so there is no cycle).
        var setting: SyncedSetting {
            SyncedSetting(read: { .bool(self.choice ?? self.defaultOn) },
                          write: { value in if case let .bool(on) = value { self.choice = on; self.writes += 1 } },
                          followsDefault: { self.choice == nil })
        }
    }

    /// The channel's default is not a choice and never syncs; a choice does, even one equal to the default, and a
    /// synced value becomes the other device's own choice (it no longer follows its channel).
    func testUpdateAllDevicesAutomaticallyFollowsTheChannelUntilAChoiceSyncs() {
        let net = Net(self)
        let phoneAuto = Following(defaultOn: true)
        let macAuto = Following(defaultOn: false)
        net.add(phone, override: [.updatesAutoAll: phoneAuto.setting], isPhone: true)
        net.add(macA, override: [.updatesAutoAll: macAuto.setting])
        net.connect(phone, macA)
        net.deliverAll()
        net.log.removeAll()
        // The Mac moves to Beta: its default turns on, which sends nothing and chooses nothing.
        macAuto.defaultOn = true
        net.controllers[macA]!.localChanged()
        net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.log.count, 0)
        XCTAssertNil(macAuto.choice)
        XCTAssertNil(phoneAuto.choice)
        XCTAssertFalse(net.controllers[macA]!.engine.record(.updatesAutoAll).chosen)
        // The phone's person turns it on, the same as its default: a choice, and it reaches the Mac as one.
        phoneAuto.choice = true
        net.controllers[phone]!.localChanged()
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertEqual(macAuto.choice, true)
        XCTAssertEqual(macAuto.writes, 1)
        // The Mac's channel can no longer change it.
        macAuto.defaultOn = false
        XCTAssertEqual(net.controllers[macA]!.engine.settings[.updatesAutoAll]!.read(), .bool(true))
        // An unchosen value never applies as a choice.
        let fresh = Following(defaultOn: false)
        net.add(macB, override: [.updatesAutoAll: fresh.setting])
        net.connect(phone, macB)
        net.deliverAll()
        XCTAssertEqual(fresh.choice, true, "the phone's choice reaches a newly connected Mac")
    }

    /// Connect away from home on by default on both: nobody chose, so nothing is sent, asked or shown as different,
    /// and a phone from before (its old default off, never chosen) is not different either. An explicit off syncs.
    func testConnectAwayOnByDefaultIsNeitherSentNorShownAsDifferent() {
        let net = Net(self)
        let phoneAway = Following(defaultOn: true)
        let macAway = Following(defaultOn: true)
        net.add(phone, override: [.connectAway: phoneAway.setting], isPhone: true)
        net.add(macA, override: [.connectAway: macAway.setting], fresh: true)
        net.connect(phone, macA)
        net.deliverAll()
        net.log.removeAll()
        net.controllers[macA]!.localChanged()
        net.controllers[macA]!.flush()
        net.controllers[phone]!.localChanged()
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.log.count, 0)
        XCTAssertEqual(net.controllers[macA]!.questions, [])
        XCTAssertEqual(net.controllers[macA]!.status(.connectAway).differentOn, [])
        XCTAssertEqual(net.controllers[phone]!.status(.connectAway).differentOn, [])
        XCTAssertFalse(net.controllers[macA]!.engine.record(.connectAway).chosen)
        XCTAssertEqual(phoneAway.writes + macAway.writes, 0)
        // The Mac's person turns it off: a choice, and the phone takes it as its own.
        macAway.choice = false
        net.controllers[macA]!.localChanged()
        net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(phoneAway.choice, false)
        // A phone from before: the old default (off), never chosen. Not a difference on this Mac either.
        let older = Net(self)
        let newMac = Following(defaultOn: true)
        var olderWrites = 0
        older.add(phone, override: [.connectAway: SyncedSetting(read: { .bool(false) }, write: { _ in olderWrites += 1 })], isPhone: true)
        older.add(macB, override: [.connectAway: newMac.setting])
        older.connect(phone, macB)
        older.deliverAll()
        XCTAssertEqual(older.controllers[macB]!.status(.connectAway).differentOn, [])
        XCTAssertNil(newMac.choice)
        XCTAssertEqual(olderWrites, 0)
    }

    /// A new Mac on Beta (on by default) meets a phone on Stable (off by default); `phoneChoice` nil: the phone
    /// follows its channel too.
    private func autoUpdatePair(phoneChoice: Bool?) -> (Net, Following, Following) {
        let net = Net(self)
        let phoneAuto = Following(defaultOn: false)
        let macAuto = Following(defaultOn: true)
        net.add(phone, clock: 1000, override: [.updatesAutoAll: phoneAuto.setting], isPhone: true)
        net.add(macA, clock: 2000, override: [.updatesAutoAll: macAuto.setting], fresh: true)
        if let phoneChoice {
            phoneAuto.choice = phoneChoice
            net.controllers[phone]!.localChanged()
        }
        net.connect(phone, macA)
        net.deliverAll()
        return (net, phoneAuto, macAuto)
    }

    /// Off there and on here, but nobody chose: each follows its own channel, so nothing is asked or shown.
    func testFirstConnectNeverAsksAboutUpdateAllWhenEachFollowsItsChannel() {
        let (net, phoneAuto, macAuto) = autoUpdatePair(phoneChoice: nil)
        XCTAssertEqual(net.controllers[macA]!.questions, [])
        XCTAssertEqual(net.controllers[macA]!.status(.updatesAutoAll).differentOn, [])
        XCTAssertEqual(net.controllers[phone]!.status(.updatesAutoAll).differentOn, [])
        XCTAssertNil(phoneAuto.choice)
        XCTAssertNil(macAuto.choice)
    }

    /// Use these takes the phone's choice, which is this Mac's choice from then on.
    func testUseTheseTakesThePhonesUpdateAllChoice() {
        let (net, _, macAuto) = autoUpdatePair(phoneChoice: false)
        XCTAssertEqual(net.controllers[macA]!.questions, [phone])
        net.controllers[macA]!.answer(phone, use: true)
        net.deliverAll()
        XCTAssertEqual(macAuto.choice, false)
        XCTAssertEqual(net.controllers[macA]!.status(.updatesAutoAll).differentOn, [])
    }

    /// Keep mine makes what this Mac did (on, from Beta) its choice; Apply to all then sends that choice.
    func testKeepMineAndApplyToAllMakeAFollowedUpdateAllSettingAChoice() {
        let (net, phoneAuto, macAuto) = autoUpdatePair(phoneChoice: false)
        net.controllers[macA]!.answer(phone, use: false)
        net.deliverAll()
        XCTAssertEqual(macAuto.choice, true)
        XCTAssertTrue(net.controllers[macA]!.engine.record(.updatesAutoAll).chosen)
        XCTAssertEqual(phoneAuto.choice, false)
        XCTAssertEqual(net.controllers[macA]!.status(.updatesAutoAll).differentOn, ["Device a"])
        net.controllers[macA]!.applyToAll(.updatesAutoAll)
        net.deliverAll()
        XCTAssertEqual(phoneAuto.choice, true)
        XCTAssertEqual(net.controllers[macA]!.status(.updatesAutoAll).differentOn, [])
    }

    /// Apply to all from a setting that follows its channel sends what it does now (not its record's older
    /// value) and makes that this Mac's choice.
    func testApplyToAllFromAFollowedUpdateAllSettingSendsWhatItDoesNow() {
        let net = Net(self)
        let phoneAuto = Following(defaultOn: false)
        let macAuto = Following(defaultOn: false)
        net.add(phone, override: [.updatesAutoAll: phoneAuto.setting], isPhone: true)
        net.add(macA, override: [.updatesAutoAll: macAuto.setting])
        net.connect(phone, macA)
        net.deliverAll()
        // The Mac moves to Nightly after its record was made.
        macAuto.defaultOn = true
        net.controllers[macA]!.applyToAll(.updatesAutoAll)
        net.deliverAll()
        XCTAssertEqual(macAuto.choice, true)
        XCTAssertEqual(phoneAuto.choice, true)
    }

    /// A Mac with no setting for Update all devices automatically (tests, older builds) stores and relays it,
    /// with no activity entry of its own.
    func testStoreOnlyKeyIsRelayedByAMacHub() {
        let net = Net(self)
        let phoneB = "7e57d00d-0000-4000-8000-00000000000e"
        net.add(phone, isPhone: true); net.add(phoneB, isPhone: true)
        net.add(macA, without: [.updatesAutoAll, .featureCamera])
        net.connect(phone, macA); net.connect(phoneB, macA)
        net.deliverAll()
        net.log.removeAll()
        net.edit(phone, .updatesAutoAll, .bool(true))
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[phoneB]![.updatesAutoAll], .bool(true))
        XCTAssertEqual(net.values[macA]![.updatesAutoAll], .bool(false), "the Mac has no such setting")
        XCTAssertEqual(net.controllers[macA]!.engine.record(.updatesAutoAll).value, .bool(true))
        XCTAssertEqual(net.activity, ["\(phoneB)<-\(macA): auto_update_all=1"])
        XCTAssertEqual(net.log.count, 4)
        XCTAssertEqual(net.controllers[macA]!.status(.updatesAutoAll).differentOn, [])
    }

    /// A phone with two Macs carries one Mac's change to the other; nothing loops.
    func testHubRelaysToTheOtherPeer() {
        let net = Net(self)
        net.add(phone, clock: 100); net.add(macA, clock: 200); net.add(macB, clock: 300)
        net.connect(phone, macA); net.connect(phone, macB)
        net.deliverAll()
        net.log.removeAll()
        net.values[macA]![.reduceMotion] = .bool(true)
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.reduceMotion], .bool(true))
        XCTAssertEqual(net.values[macB]![.reduceMotion], .bool(true))
        XCTAssertEqual(net.log.count, 4)
        XCTAssertEqual(Set(net.activity), ["\(macB)<-\(phone): reduce_motion=1", "\(phone)<-\(macA): reduce_motion=1"])
    }

    /// The hub never chose: Mac A's snapshot arrives first and is adopted; Mac B, connected at the same time with
    /// a different chosen value, keeps it, and the hub shows it as different.
    func testHubRaceKeepsEachChosenValue() {
        let net = Net(self)
        net.add(phone, clock: 100); net.add(macA, clock: 200); net.add(macB, clock: 300)
        net.edit(macA, .featureMedia, .bool(true))
        net.edit(macB, .featureMedia, .bool(true))
        net.edit(macB, .featureMedia, .bool(false))
        net.connect(phone, macA); net.connect(phone, macB)
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureMedia], .bool(true))
        XCTAssertEqual(net.values[macA]![.featureMedia], .bool(true))
        XCTAssertEqual(net.values[macB]![.featureMedia], .bool(false))
        XCTAssertEqual(net.controllers[phone]!.status(.featureMedia).differentOn, ["Device c"])
        XCTAssertEqual(net.sentLog(kind: SettingsSyncKinds.update), 0)
    }

    func testExcludedKeyIsNeitherSentNorApplied() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.controllers[macA]!.setSyncs(.reduceMotion, false)
        net.edit(phone, .reduceMotion, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.reduceMotion], .bool(false))
        let macSnapshot = net.log.first { $0.from == macA && $0.kind == SettingsSyncKinds.snapshot }
        XCTAssertNil((macSnapshot?.payload["records"] as? [String: Any])?["display.reduce_motion"])
        net.log.removeAll()
        net.values[macA]![.reduceMotion] = .bool(true)
        net.controllers[macA]!.localChanged(); net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertTrue(net.log.isEmpty)
        // Stamped anyway, so it goes out with its own stamp once checked again.
        XCTAssertEqual(net.controllers[macA]!.engine.record(.reduceMotion).changedBy, macA)
        XCTAssertEqual(net.controllers[macA]!.status(.reduceMotion), SyncRowStatus())
    }

    func testRateLimitDropsTheExtrasWithOneError() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.connect(phone, macA)
        net.deliverAll()
        net.queue.removeAll()
        let mac = net.controllers[macA]!
        for n in 0..<25 {
            mac.receive(kind: SettingsSyncKinds.update, messageID: "m\(n)", plaintext: Data(#"{"schema":1,"records":{}}"#.utf8), from: phone)
        }
        // Two messages of this window were the snapshot and its ack; then 18 updates got through.
        XCTAssertEqual(net.queue.filter { $0.kind == SettingsSyncKinds.ack }.count, 18)
        XCTAssertEqual(net.queue.filter { $0.payload["code"] as? String == "rate_limited" }.count, 1)
    }

    func testSyncOffKeepsValuesAndStopsTheExchange() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.connect(phone, macA)
        net.deliverAll()
        net.controllers[macA]!.setEnabled(false)
        XCTAssertFalse(net.controllers[macA]!.engine.isActive(phone))
        net.edit(phone, .reduceMotion, .bool(true))
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.reduceMotion], .bool(false))
        net.log.removeAll()
        net.controllers[macA]!.setEnabled(true)
        net.deliverAll()
        XCTAssertEqual(net.sentLog(kind: SettingsSyncKinds.snapshot), 2)
        XCTAssertEqual(net.values[macA]![.reduceMotion], .bool(true))
    }

    func testPerDeviceSwitchAndForget() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.connect(phone, macA)
        net.deliverAll()
        let mac = net.controllers[macA]!
        mac.setEnabled(false, for: phone)
        XCTAssertFalse(mac.advertised(for: phone))
        XCTAssertTrue(mac.advertised(for: macB))
        mac.setEnabled(true, for: phone)
        net.deliverAll()
        XCTAssertTrue(mac.engine.isReady(phone))
        mac.setEnabled(false, for: phone)
        mac.forget(phone)
        XCTAssertNil(mac.devices[phone])
        XCTAssertFalse(mac.engine.isActive(phone))
    }

    func testInvalidAndUnsupportedPayloadsAreAnsweredWithErrors() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.connect(phone, macA)
        net.deliverAll()
        net.queue.removeAll()
        let mac = net.controllers[macA]!
        mac.receive(kind: SettingsSyncKinds.update, messageID: "m1", plaintext: Data(#"{"schema":2,"records":{}}"#.utf8), from: phone)
        mac.receive(kind: SettingsSyncKinds.update, messageID: "m2", plaintext: Data(#"{"schema":1}"#.utf8), from: phone)
        mac.receive(kind: SettingsSyncKinds.update, messageID: "m3",
                    plaintext: Data(#"{"schema":1,"records":{"display.theme":{"value":"dark","changedAt":9,"version":1,"changedBy":"x"},"display.reduce_motion":{"value":"true","changedAt":9,"version":1,"changedBy":"x"}}}"#.utf8),
                    from: phone)
        XCTAssertEqual(net.queue.map { $0.payload["code"] as? String }, ["unsupported_schema", "invalid_message", nil])
        XCTAssertEqual(net.values[macA]![.reduceMotion], .bool(false))
        // unsupported_schema from the phone stops syncing with it until the next session; other codes do not.
        net.queue.removeAll()
        mac.receive(kind: SettingsSyncKinds.error, messageID: "m4", plaintext: Data(#"{"schema":1,"code":"rate_limited","maxSchema":1}"#.utf8), from: phone)
        XCTAssertTrue(mac.isAvailable(phone))
        mac.receive(kind: SettingsSyncKinds.error, messageID: "m5", plaintext: Data(#"{"schema":1,"code":"unsupported_schema","maxSchema":1}"#.utf8), from: phone)
        XCTAssertFalse(mac.isAvailable(phone))
        mac.sessionEnded(phone)
        mac.refresh(phone)
        XCTAssertEqual(net.queue.map(\.kind), [SettingsSyncKinds.snapshot])
    }

    func testMessagesAreIgnoredUnlessBothSidesAdvertise() {
        let net = Net(self)
        net.add(phone); net.add(macA)
        net.controllers[macA]!.receive(kind: SettingsSyncKinds.update, messageID: "m1",
                                       plaintext: Data(#"{"schema":1,"records":{"display.reduce_motion":{"value":true,"changedAt":9,"version":1,"changedBy":"x"}}}"#.utf8),
                                       from: phone)
        XCTAssertEqual(net.values[macA]![.reduceMotion], .bool(false))
        XCTAssertTrue(net.queue.isEmpty)
    }

    func testRecordsAndChoicesPersistUnderTheSettingsPrefix() throws {
        let (defaults, name) = suite()
        defaults.set(true, forKey: "settings.reduceMotion")
        var values: [SyncKey: SyncValue] = Dictionary(uniqueKeysWithValues: SyncKey.allCases.map { ($0, $0.defaultValue) })
        values[.reduceMotion] = .bool(true)
        let settings = Self.fakeSettings(except: []) { values[$0]! } set: { values[$0] = $1 }
        let first = SettingsSyncController(localDeviceID: macA, defaults: defaults, settings: settings, clock: { 10 })
        XCTAssertEqual(first.engine.record(.reduceMotion), SyncRecord(value: .bool(true), changedAt: 1, version: 1, changedBy: macA))
        XCTAssertEqual(first.engine.record(.featureCalls), .neverChosen(.bool(false)))
        first.setEnabled(false, for: phone)
        first.setSyncs(.featureCamera, false)
        values[.activityPreviews] = .bool(false)
        first.localChanged()
        let second = SettingsSyncController(localDeviceID: macA, defaults: defaults, settings: settings, clock: { 20 })
        XCTAssertEqual(second.engine.record(.activityPreviews), SyncRecord(value: .bool(false), changedAt: 10, version: 1, changedBy: macA))
        XCTAssertEqual(second.devices, [phone: false])
        XCTAssertEqual(second.excluded, [.featureCamera])
        let keys = defaults.persistentDomain(forName: name)?.keys.filter { $0.hasPrefix("settings.sync.") }.sorted()
        XCTAssertEqual(keys, ["settings.sync.devices", "settings.sync.excluded", "settings.sync.records", "settings.sync.stamped"])
        XCTAssertTrue(keys!.allSatisfy { key in LocalDataReset.settingsPrefixes.contains { key.hasPrefix($0) } })
    }

    // MARK: First connect: ask once

    /// A new Mac meets a phone that synced before: the Mac asks. Use these takes the phone's settings and features.
    func testUseTheseAdoptsThePhonesSettings() {
        let net = Net(self)
        net.add(phone, clock: 1000, isPhone: true)
        net.add(macA, clock: 2000, fresh: true)
        net.edit(phone, .featureCalls, .bool(true))
        net.edit(phone, .reduceMotion, .bool(true))
        net.edit(macA, .featureFiles, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        let mac = net.controllers[macA]!
        XCTAssertEqual(mac.questions, [phone])
        XCTAssertEqual(net.controllers[phone]!.questions, [])
        // Nothing moved yet, either way.
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(false))
        XCTAssertEqual(net.values[phone]![.featureFiles], .bool(false))
        XCTAssertEqual(net.activity, [])
        mac.answer(phone, use: true)
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(true))
        XCTAssertEqual(net.values[macA]![.reduceMotion], .bool(true))
        XCTAssertEqual(net.values[macA]![.featureFiles], .bool(false))
        XCTAssertEqual(net.values[phone]![.featureFiles], .bool(false))
        XCTAssertEqual(net.activity, ["\(macA)<-\(phone): reduce_motion=1,files=0,calls=1"])
        XCTAssertEqual(net.turnedOn, [])
        XCTAssertEqual(mac.answers[phone], "use")
        XCTAssertEqual(net.controllers[phone]!.answers[macA], "peer")
        for key in SyncKey.allCases {
            XCTAssertEqual(mac.engine.differentOn(key), [], key.rawValue)
            XCTAssertEqual(net.controllers[phone]!.engine.differentOn(key), [], key.rawValue)
        }
        // From then on sync runs as usual.
        net.edit(phone, .featurePing, .bool(true))
        net.controllers[phone]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.featurePing], .bool(true))
    }

    /// Keep mine keeps this Mac's values; both sides show "Different on", and Apply to all settles it.
    func testKeepMineKeepsValuesAndShowsDifferent() {
        let net = Net(self)
        net.add(phone, clock: 1000, isPhone: true)
        net.add(macA, clock: 2000, fresh: true)
        net.edit(phone, .featureCalls, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        net.controllers[macA]!.answer(phone, use: false)
        net.deliverAll()
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(false))
        XCTAssertEqual(net.values[phone]![.featureCalls], .bool(true))
        XCTAssertEqual(net.controllers[macA]!.status(.featureCalls).differentOn, ["Device a"])
        XCTAssertEqual(net.controllers[phone]!.status(.featureCalls).differentOn, ["Device b"])
        XCTAssertEqual(net.controllers[macA]!.answers[phone], "keep")
        net.controllers[macA]!.applyToAll(.featureCalls)
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureCalls], .bool(false))
        XCTAssertEqual(net.controllers[macA]!.status(.featureCalls).differentOn, [])
    }

    /// The phone asks: this Mac applies nothing until the answer, then never pushes its value over it.
    func testThePassiveSideWaitsForTheAnswer() {
        let net = Net(self)
        net.add(phone, clock: 1000, fresh: true, isPhone: true)
        net.add(macA, clock: 2000)
        net.edit(phone, .featureCalls, .bool(true))
        net.edit(macA, .reduceMotion, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        let mac = net.controllers[macA]!
        XCTAssertEqual(net.controllers[phone]!.questions, [macA])
        XCTAssertEqual(mac.questions, [])
        XCTAssertTrue(mac.engine.isAwaitingAnswer(phone))
        // An edit on the Mac meanwhile goes nowhere.
        net.log.removeAll()
        net.edit(macA, .featurePing, .bool(true))
        mac.flush()
        net.deliverAll()
        XCTAssertTrue(net.log.isEmpty)
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(false))
        net.controllers[phone]!.answer(macA, use: false)
        net.deliverAll()
        XCTAssertEqual(mac.answers[phone], "peer")
        // Keep mine there: nothing is pushed over it, and both sides show the differences.
        XCTAssertEqual(net.values[phone]![.reduceMotion], .bool(false))
        XCTAssertEqual(net.values[phone]![.featurePing], .bool(false))
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(false))
        XCTAssertEqual(Set(mac.status(.reduceMotion).differentOn + mac.status(.featurePing).differentOn + mac.status(.featureCalls).differentOn), ["Device a"])
        // New edits sync again.
        net.edit(macA, .featureLinks, .bool(true))
        mac.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureLinks], .bool(true))
    }

    func testNoQuestionWhenNothingDiffers() {
        let net = Net(self)
        net.add(phone, fresh: true, isPhone: true)
        net.add(macA, fresh: true)
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.controllers[phone]!.questions, [])
        XCTAssertEqual(net.controllers[phone]!.answers[macA], "use")
        XCTAssertEqual(net.controllers[macA]!.answers[phone], "peer")
        net.edit(macA, .featureMedia, .bool(true))
        net.controllers[macA]!.flush()
        net.deliverAll()
        XCTAssertEqual(net.values[phone]![.featureMedia], .bool(true))
    }

    /// Both new: the phone asks and the Mac waits. Neither new: nobody asks and a chosen value is adopted at once.
    func testWhoAsks() {
        let both = Net(self)
        both.add(phone, fresh: true, isPhone: true)
        both.add(macA, fresh: true)
        both.edit(macA, .featureCalls, .bool(true))
        both.connect(phone, macA)
        both.deliverAll()
        XCTAssertEqual(both.controllers[phone]!.questions, [macA])
        XCTAssertEqual(both.controllers[macA]!.questions, [])
        let neither = Net(self)
        neither.add(phone, isPhone: true)
        neither.add(macA)
        neither.edit(macA, .featureCalls, .bool(true))
        neither.connect(phone, macA)
        neither.deliverAll()
        XCTAssertEqual(neither.controllers[phone]!.questions, [])
        XCTAssertEqual(neither.values[phone]![.featureCalls], .bool(true))
        XCTAssertEqual(neither.controllers[phone]!.answers[macA], "auto")
        XCTAssertEqual(neither.controllers[macA]!.answers[phone], "auto")
    }

    /// The answer is kept: the next session asks nothing. A question left open goes with its session.
    func testAnswerIsKeptAndAnOpenQuestionEndsWithTheSession() {
        let net = Net(self)
        net.add(phone, clock: 1000, isPhone: true)
        net.add(macA, clock: 2000, fresh: true)
        net.edit(phone, .featureCalls, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.controllers[macA]!.questions, [phone])
        net.disconnect(phone, macA)
        XCTAssertEqual(net.controllers[macA]!.questions, [])
        XCTAssertNil(net.controllers[macA]!.answers[phone])
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.controllers[macA]!.questions, [phone])
        net.controllers[macA]!.answer(phone, use: false)
        net.deliverAll()
        net.disconnect(phone, macA)
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.controllers[macA]!.questions, [])
        XCTAssertEqual(net.controllers[macA]!.status(.featureCalls).differentOn, ["Device a"])
    }

    /// Reset > Settings keeps the answers: the next connect takes the other device's chosen values silently and
    /// pushes nothing.
    func testResetSettingsKeepsAnswers() {
        let net = Net(self)
        net.add(phone, clock: 1000, isPhone: true)
        net.add(macA, clock: 2000, fresh: true)
        net.edit(phone, .featureCalls, .bool(true))
        net.connect(phone, macA)
        net.deliverAll()
        net.controllers[macA]!.answer(phone, use: true)
        net.deliverAll()
        net.disconnect(phone, macA)
        net.resetSettings(macA)
        XCTAssertEqual(net.controllers[macA]!.answers[phone], "use")
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(false))
        net.log.removeAll()
        net.connect(phone, macA)
        net.deliverAll()
        XCTAssertEqual(net.controllers[macA]!.questions, [])
        XCTAssertEqual(net.values[macA]![.featureCalls], .bool(true))
        XCTAssertEqual(net.values[phone]![.featureCalls], .bool(true))
        XCTAssertEqual(net.sentLog(kind: SettingsSyncKinds.update), 0)
    }

    // MARK: Helpers

    fileprivate func suite() -> (UserDefaults, String) {
        let name = "in.roundrobin.bridgey.settings-sync-tests.\(UUID().uuidString)"
        suites.append(name)
        return (UserDefaults(suiteName: name)!, name)
    }

    fileprivate static func fakeSettings(except: Set<SyncKey>, _ get: @escaping (SyncKey) -> SyncValue,
                                         set: @escaping (SyncKey, SyncValue) -> Void) -> [SyncKey: SyncedSetting] {
        Dictionary(uniqueKeysWithValues: SyncKey.allCases.filter { !except.contains($0) }.map { key in
            (key, SyncedSetting(read: { get(key) }, write: { set(key, $0) }))
        })
    }

    /// Devices that sync with each other over in-memory links; messages wait in `queue` until delivered.
    @MainActor
    final class Net {
        struct Sent {
            let from: String
            let to: String
            let kind: String
            let payload: [String: Any]
            let id: String
        }

        let test: SettingsSyncTests
        var controllers: [String: SettingsSyncController] = [:]
        var values: [String: [SyncKey: SyncValue]] = [:]
        var missing: [String: Set<SyncKey>] = [:]
        var links: [String: Set<String>] = [:]
        var queue: [Sent] = []
        var log: [Sent] = []
        var activity: [String] = []
        var turnedOn: [String] = []

        init(_ test: SettingsSyncTests) { self.test = test }

        /// Every device starts with every key at its default, never chosen. "Device a" for an ID ending in a.
        var defaults: [String: UserDefaults] = [:]

        /// `fresh`: the device never synced with anyone (first connects ask). Otherwise it synced before with a device
        /// not in this test, so a first connect between two such devices asks nobody. `isPhone`: it asks when both are new.
        /// `without`: keys this device has no setting for (stored and relayed only).
        func add(_ id: String, clock: Int64 = 1000, override: [SyncKey: SyncedSetting] = [:], lacks: ((SyncKey) -> Bool)? = nil,
                 fresh: Bool = false, isPhone: Bool = false, keep store: UserDefaults? = nil, without: Set<SyncKey> = []) {
            let store = store ?? test.suite().0
            if !fresh && store.dictionary(forKey: SettingsSyncController.answersKey) == nil {
                store.set(["0e0e0e0e-0000-4000-8000-000000000000": "auto"], forKey: SettingsSyncController.answersKey)
            }
            defaults[id] = store
            if values[id] == nil { values[id] = Dictionary(uniqueKeysWithValues: SyncKey.allCases.map { ($0, $0.defaultValue) }) }
            var settings = SettingsSyncTests.fakeSettings(except: without) { [unowned self] in self.values[id]![$0]! } set: { [unowned self] in self.values[id]![$0] = $1 }
            settings.merge(override) { $1 }
            let controller = SettingsSyncController(localDeviceID: id, defaults: store, settings: settings, clock: { clock }, debounce: 3600)
            controller.isPhone = isPhone
            controller.send = { [unowned self] to, kind, payload, messageID in
                let data = try! JSONSerialization.data(withJSONObject: payload)
                let echoed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                self.queue.append(Sent(from: id, to: to, kind: kind, payload: echoed, id: messageID))
                return true
            }
            controller.remoteEnabled = { [unowned self] peer in
                self.links[id, default: []].contains(peer) && self.controllers[peer]!.advertised(for: id)
            }
            controller.connectedPhones = { [unowned self] in self.links[id, default: []].sorted() }
            controller.peerName = { "Device \($0.suffix(1))" }
            controller.lacksPermission = { [unowned self] key in self.missing[id, default: []].contains(key) || lacks?(key) == true }
            controller.onSwitchChange = { [unowned self] in
                for peer in self.links[id, default: []] { self.controllers[peer]!.refresh(id) }
            }
            controller.onApplied = { [unowned self] from, content in self.activity.append("\(id)<-\(from): \(content)") }
            controller.onTurnedOn = { [unowned self] _, key, waiting in self.turnedOn.append("\(id): \(key.rawValue) waiting=\(waiting)") }
            controllers[id] = controller
        }

        /// A local edit made in Settings.
        func edit(_ id: String, _ key: SyncKey, _ value: SyncValue) {
            values[id]![key] = value
            controllers[id]!.localChanged()
        }

        /// The session ends on both sides.
        func disconnect(_ a: String, _ b: String) {
            links[a]?.remove(b)
            links[b]?.remove(a)
            queue.removeAll { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
            controllers[a]!.sessionEnded(b)
            controllers[b]!.sessionEnded(a)
        }

        /// Reset > Settings on `id`: every `settings.` key goes (records, switches, choices), the answers stay; the
        /// values go back to their defaults and the app starts again.
        func resetSettings(_ id: String, isPhone: Bool = false) {
            let store = defaults[id]!
            for key in store.dictionaryRepresentation().keys where key.hasPrefix("settings.") { store.removeObject(forKey: key) }
            values[id] = Dictionary(uniqueKeysWithValues: SyncKey.allCases.map { ($0, $0.defaultValue) })
            add(id, isPhone: isPhone, keep: store)
        }

        /// Both sides see the other's features.update.
        func connect(_ a: String, _ b: String) {
            links[a, default: []].insert(b)
            links[b, default: []].insert(a)
            controllers[a]!.refresh(b)
            controllers[b]!.refresh(a)
        }

        func deliverAll() {
            var steps = 0
            while !queue.isEmpty {
                steps += 1
                XCTAssertLessThan(steps, 200, "messages keep coming: ping-pong")
                if steps >= 200 { return }
                let message = queue.removeFirst()
                log.append(message)
                guard links[message.to, default: []].contains(message.from) else { continue }
                let data = try! JSONSerialization.data(withJSONObject: message.payload)
                controllers[message.to]!.receive(kind: message.kind, messageID: message.id, plaintext: data, from: message.from)
            }
        }

        func sentLog(kind: String) -> Int { log.filter { $0.kind == kind }.count }
    }
}
