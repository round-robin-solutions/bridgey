import Foundation
import XCTest
@testable import BridgeyMac

/// Agent devices on the Mac (AgentsMirror.swift): protocol/test-vectors/agent-v1.json (the grants inside agents.state,
/// codes.found and agents.grant_set as this Mac writes them) and agents-mirror-v1.json (agents.state and codes.read).
@MainActor
final class AgentsMirrorTests: XCTestCase {
    private static let vectorsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../protocol/test-vectors")

    private func vectors(_ file: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.vectorsRoot.appendingPathComponent(file))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func each(_ file: String, _ group: String, _ check: ([String: Any]) throws -> Bool) throws {
        let list = try XCTUnwrap(try vectors(file)[group] as? [[String: Any]], group)
        XCTAssertFalse(list.isEmpty)
        for vector in list {
            XCTAssertTrue(try check(vector), "\(group): \(vector["name"] as? String ?? "?")")
        }
    }

    private static func data(_ object: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(object))
    }

    private static func same(_ a: Any, _ b: Any?) -> Bool {
        guard let b else { return false }
        return NSArray(array: [a]).isEqual(to: [b])
    }

    // MARK: Vectors

    func testGrantsDecodeLikeTheAgentGrantsVectors() throws {
        try each("agent-v1.json", "agentGrants") { vector in
            let decoded = AgentsMirrorWire.grantsPayload(try Self.data(vector["plaintext"]))
            if vector["expect"] as? String == "reject" { return decoded == nil }
            guard let decoded, let expect = vector["expect"] as? [String: Any] else { return false }
            return Self.same(decoded.map(\.wireObject), expect["grants"])
        }
    }

    func testAgentsStateFixture() throws {
        let file = try vectors("agents-mirror-v1.json")
        let now = Date(timeIntervalSince1970: TimeInterval(try XCTUnwrap(file["now"] as? Int)) / 1000)
        try each("agents-mirror-v1.json", "agentsState") { vector in
            let decoded = AgentsMirrorWire.agentsState(try Self.data(vector["plaintext"]))
            if vector["expect"] as? String == "reject" { return decoded == nil }
            guard let decoded, let expect = vector["expect"] as? [String: Any] else { return false }
            let objects: [[String: Any]] = decoded.map { agent in
                var object: [String: Any] = [
                    "deviceId": agent.deviceId, "name": agent.name, "platform": agent.platform, "app": agent.app, "os": agent.os,
                    "pairedAt": agent.pairedAt, "online": agent.online, "grants": agent.grants.map(\.wireObject),
                    "activity": agent.activity.map { entry -> [String: Any] in
                        var row: [String: Any] = ["at": entry.at, "action": entry.action, "outcome": entry.outcome]
                        if let detail = entry.detail { row["detail"] = detail }
                        return row
                    },
                    "codesOn": agent.grant(.codes)?.isOn(at: now) == true,
                ]
                if let seen = agent.lastSeenAt { object["lastSeenAt"] = seen }
                if let route = agent.route { object["route"] = route }
                return object
            }
            let sends = AgentsMirrorRules.sendsCodesFound(peerSupports: true, stateThisSession: true, agents: decoded, now: now)
            return Self.same(objects, expect["agents"]) && sends == (vector["sendsCodesFound"] as? Bool)
        }
    }

    func testCodesReadFixture() throws {
        try each("agents-mirror-v1.json", "codesRead") { vector in
            let decoded = AgentsMirrorWire.codesRead(try Self.data(vector["plaintext"]))
            if vector["expect"] as? String == "reject" { return decoded == nil }
            guard let decoded else { return false }
            let object: [String: Any] = ["deviceId": decoded.deviceId, "deviceName": decoded.deviceName, "service": decoded.service,
                                         "source": decoded.source.rawValue, "app": decoded.app, "at": decoded.at, "count": decoded.count]
            return Self.same(object, vector["expect"])
        }
    }

    /// What this Mac writes for codes.found is exactly the vector's plaintext; a vector it must not send gives nil.
    func testCodesFoundEncodingMatchesTheVectors() throws {
        try each("agent-v1.json", "codesFound") { vector in
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let source = try XCTUnwrap((p["source"] as? String).flatMap(CodeChannel.init(rawValue:)))
            let written = AgentsMirrorWire.codesFound(
                foundId: p["foundId"] as! String, code: p["code"] as! String, service: p["service"] as! String,
                serviceKey: p["serviceKey"] as! String, source: source, app: p["app"] as! String,
                notificationId: p["notificationId"] as! String, postedAt: Int64(p["postedAt"] as! Int))
            if vector["expect"] as? String == "reject" { return written == nil }
            guard let written, let object = try JSONSerialization.jsonObject(with: written) as? [String: Any] else { return false }
            return NSDictionary(dictionary: object).isEqual(to: p)
        }
    }

    func testGrantSetEncodingMatchesTheVectors() throws {
        try each("agent-v1.json", "agentsGrantSet") { vector in
            let p = try XCTUnwrap(vector["plaintext"] as? [String: Any])
            let key = try XCTUnwrap((p["key"] as? String).flatMap(AgentGrantKey.init(rawValue:)))
            let written = AgentsMirrorWire.grantSet(requestId: p["requestId"] as! String, deviceId: p["deviceId"] as! String, key: key,
                                                    on: p["on"] as! Bool, window: (p["window"] as? String).flatMap(AgentGrantWindow.init(rawValue:)))
            if vector["expect"] as? String == "reject" { return written == nil }
            guard let written else { return false }
            return NSDictionary(dictionary: written).isEqual(to: p)
        }
    }

    func testCodesFoundAppNamesTheMailApp() {
        XCTAssertEqual(AgentsMirrorWire.app(packageName: "com.google.android.apps.messaging", channel: .sms), "messages")
        XCTAssertEqual(AgentsMirrorWire.app(packageName: "com.google.android.gm", channel: .email), "gmail")
        XCTAssertEqual(AgentsMirrorWire.app(packageName: "com.microsoft.office.outlook", channel: .email), "outlook")
        XCTAssertEqual(AgentsMirrorWire.app(packageName: "ch.protonmail.android", channel: .email), "proton")
        XCTAssertEqual(AgentsMirrorWire.app(packageName: "com.readdle.spark", channel: .email), "spark")
        XCTAssertNil(AgentsMirrorWire.app(packageName: "com.yahoo.mobile.client.android.mail", channel: .email))
    }

    func testCodesFoundCutsLongServicesAndSkipsLongNotificationIDs() throws {
        let long = String(repeating: "s", count: 80)
        let data = try XCTUnwrap(AgentsMirrorWire.codesFound(foundId: UUID().uuidString.lowercased(), code: "482913", service: long, serviceKey: long,
                                                              source: .sms, app: "messages", notificationId: "n", postedAt: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["service"] as? String)?.count, 64)
        XCTAssertEqual((object["serviceKey"] as? String)?.count, 64)
        XCTAssertLessThanOrEqual(data.count, 1_024)
        XCTAssertNil(AgentsMirrorWire.codesFound(foundId: "f", code: "482913", service: "x", serviceKey: "x", source: .sms, app: "messages",
                                                 notificationId: String(repeating: "n", count: 513), postedAt: 1))
        // A text message never says it came from a mail app, nor the other way round.
        XCTAssertNil(AgentsMirrorWire.codesFound(foundId: "f", code: "482913", service: "x", serviceKey: "x", source: .sms, app: "gmail",
                                                 notificationId: "n", postedAt: 1))
    }

    func testCodesFoundFromABareNumberUsesTheSenderAsItsKey() throws {
        // A number-only sender has no service key on the Mac; the phone needs one (1 to 64 characters).
        let data = try XCTUnwrap(AgentsMirrorWire.codesFound(foundId: UUID().uuidString.lowercased(), code: "573104", service: "5551234", serviceKey: "",
                                                              source: .sms, app: "messages", notificationId: "n", postedAt: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["serviceKey"] as? String, "5551234")
        XCTAssertNil(AgentsMirrorWire.codesFound(foundId: "f", code: "573104", service: " ", serviceKey: "", source: .sms, app: "messages",
                                                 notificationId: "n", postedAt: 1))
    }

    // MARK: The rule: codes.found only while an agent has Codes on

    private func agent(_ codes: AgentGrant?, id: String = "a") -> AgentDevice {
        AgentDevice(deviceId: id, name: id, platform: "cli", app: "bridgey 0.1.0", os: "linux x86_64", pairedAt: 1, online: true,
                    grants: codes.map { [$0] } ?? [], activity: [])
    }

    func testCodesFoundOnlyWhileAnAgentHasCodesOn() {
        let now = Date(timeIntervalSince1970: 1_798_001_000)
        let ms = unixMillis(now)
        let on = AgentGrant(key: .codes, state: .on, window: .oneHour, grantedAt: ms - 1_000, expiresAt: ms + 60_000)
        let forever = AgentGrant(key: .codes, state: .on, window: .forever)
        let ended = AgentGrant(key: .codes, state: .on, window: .oneHour, expiresAt: ms)
        let waiting = AgentGrant(key: .codes, state: .waiting)
        let off = AgentGrant(key: .codes, state: .off)
        let notify = AgentGrant(key: .notify, state: .on, window: .forever)
        func sends(_ agents: [AgentDevice]?, supports: Bool = true, thisSession: Bool = true) -> Bool {
            AgentsMirrorRules.sendsCodesFound(peerSupports: supports, stateThisSession: thisSession, agents: agents, now: now)
        }
        XCTAssertTrue(sends([agent(on)]))
        XCTAssertTrue(sends([agent(forever)]))
        XCTAssertTrue(sends([agent(off, id: "x"), agent(on, id: "y")]), "any agent with Codes on")
        XCTAssertFalse(sends([agent(ended)]), "a window that ended reads as off")
        XCTAssertFalse(sends([agent(waiting)]))
        XCTAssertFalse(sends([agent(off)]))
        XCTAssertFalse(sends([agent(notify)]), "another grant is not Codes")
        XCTAssertFalse(sends([agent(nil)]))
        XCTAssertFalse(sends([]))
        XCTAssertFalse(sends(nil), "no agents.state from that phone")
        XCTAssertFalse(sends([agent(on)], supports: false), "the phone does not advertise agents_mirror_draft1")
        XCTAssertFalse(sends([agent(on)], thisSession: false), "the last known state from an earlier session is not enough")
    }

    func testAPendingSwitchShowsUntilTheStateArrivesOrFiveSecondsPass() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mirror = AgentsMirror(stateStore: AgentsMirrorStateStore(fileURL: directory.appendingPathComponent("state.json")),
                                  logStore: AgentCodesReadStore(fileURL: directory.appendingPathComponent("log.json")))
        let now = Date()
        let off = AgentGrant(key: .codes, state: .off)
        mirror.received([agent(off)], from: "phone")
        mirror.setPending(phone: "phone", agent: "a", key: .codes, on: true, requestId: "r1")
        let slot = AgentsMirror.pendingKey(phone: "phone", agent: "a", key: .codes)
        XCTAssertTrue(AgentsMirrorRules.shownOn(off, pending: mirror.pending[slot], now: now))
        mirror.expirePending(slot, requestId: "older")
        XCTAssertNotNil(mirror.pending[slot], "only its own timer clears a change")
        mirror.expirePending(slot, requestId: "r1")
        XCTAssertFalse(AgentsMirrorRules.shownOn(off, pending: mirror.pending[slot], now: now), "back to the last state")
        mirror.setPending(phone: "phone", agent: "a", key: .codes, on: true, requestId: "r2")
        mirror.setPending(phone: "other", agent: "a", key: .codes, on: true, requestId: "r3")
        mirror.received([agent(AgentGrant(key: .codes, state: .on, window: .forever))], from: "phone")
        XCTAssertNil(mirror.pending[slot], "the phone's agents.state settles it")
        XCTAssertNotNil(mirror.pending[AgentsMirror.pendingKey(phone: "other", agent: "a", key: .codes)], "another phone's change waits")
        let pendingTimeout = AgentGrantPending.timeout
        XCTAssertEqual(pendingTimeout, 5)
    }

    // MARK: The codes.read log

    private func read(_ at: Date, phone: String = "phone", agent: String = "a") -> AgentCodesReadEntry {
        AgentCodesReadEntry(id: UUID().uuidString, phoneID: phone, agentID: agent, agentName: agent, service: "HDFC Bank",
                            source: .sms, app: "messages", at: at, count: 1)
    }

    func testTheLogKeepsAtMost2000EntriesAnd90Days() {
        let now = Date(timeIntervalSince1970: 1_798_000_000)
        let many = (0..<2_100).map { read(now.addingTimeInterval(-Double($0) * 60)) }
        let kept = AgentCodesReadStore.bounded(many.shuffled(), now: now)
        XCTAssertEqual(kept.count, 2_000)
        XCTAssertEqual(kept.first?.at, now, "newest first")
        XCTAssertEqual(kept, Array(many.prefix(2_000)))
        let old = [read(now.addingTimeInterval(-90 * 86_400 - 1)), read(now.addingTimeInterval(-90 * 86_400 + 1))]
        XCTAssertEqual(AgentCodesReadStore.bounded(old, now: now).count, 1, "older than 90 days goes")
    }

    func testTheLogFileIsOwnerOnlyAndNeverHoldsTheCode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent(AgentCodesReadStore.fileName)
        let stateURL = directory.appendingPathComponent(AgentsMirrorStateStore.fileName)
        let mirror = AgentsMirror(stateStore: AgentsMirrorStateStore(fileURL: stateURL), logStore: AgentCodesReadStore(fileURL: logURL))
        let payload = #"{"version":1,"deviceId":"a","deviceName":"Contabo Europe","service":"HDFC Bank","source":"sms","app":"messages","at":1798000400000,"count":2,"code":"482913"}"#
        mirror.record(try XCTUnwrap(AgentsMirrorWire.codesRead(Data(payload.utf8))), phoneID: "phone")
        mirror.received([agent(AgentGrant(key: .codes, state: .on, window: .forever))], from: "phone")
        for url in [logURL, stateURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, url.lastPathComponent)
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("482913"), url.lastPathComponent)
        }
        let reloaded = AgentsMirror(stateStore: AgentsMirrorStateStore(fileURL: stateURL), logStore: AgentCodesReadStore(fileURL: logURL))
        XCTAssertEqual(reloaded.codeReads.map(\.count), [2])
        XCTAssertEqual(reloaded.codeReads.first?.service, "HDFC Bank")
        XCTAssertEqual(reloaded.agents(on: "phone")?.map(\.deviceId), ["a"], "the last known state survives a restart")
        reloaded.forget("phone")
        XCTAssertEqual(reloaded.codeReads, [])
        XCTAssertNil(reloaded.agents(on: "phone"))
    }

    func testTheLogIsNotPartOfDiagnosticsAndGoesWithTheActivityReset() {
        let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
        let locations = LocalDataLocations(support: support, caches: URL(fileURLWithPath: "/tmp/caches", isDirectory: true))
        let files = locations.files(.activityStream).map(\.lastPathComponent)
        XCTAssertTrue(files.contains(AgentCodesReadStore.fileName))
        XCTAssertTrue(files.contains(AgentsMirrorStateStore.fileName))
        XCTAssertFalse(locations.files(.diagnostics).map(\.lastPathComponent).contains(AgentCodesReadStore.fileName))
    }

    // MARK: Activity and words

    func testActivityMergesThePhonesAuditWithThisMacsLogOnce() {
        let at: Int64 = 1_798_000_400_000
        let phoneAgent = AgentDevice(deviceId: "a", name: "a", platform: "cli", app: "", os: "", pairedAt: 1, online: true, grants: [], activity: [
            AgentActivityEntry(at: at + 500, action: "codes.read", outcome: "ok", detail: "HDFC Bank, 1"),
            AgentActivityEntry(at: at - 100_000, action: "notify", outcome: "delivered", detail: "Nightly passed"),
            AgentActivityEntry(at: at - 200_000, action: "ask", outcome: "declined", detail: "Deploy?"),
        ])
        let mine = [read(Date(timeIntervalSince1970: TimeInterval(at) / 1000)), read(Date(), phone: "other"), read(Date(), agent: "b")]
        let rows = AgentActivity.rows(agent: phoneAgent, phoneID: "phone", reads: mine)
        XCTAssertEqual(rows.map(\.title), ["Read the code from HDFC Bank", "Sent a notification", "Asked a question"])
        XCTAssertEqual(rows.map(\.detail), [nil, "Nightly passed", "Deploy? \u{00B7} Declined"])
    }

    func testNotificationReadGrantUsesExistingOwnerWindow() {
        XCTAssertTrue(AgentGrantKey.notifications.grantable)
        XCTAssertTrue(AgentGrantKey.notifications.changeableFromMac)
        XCTAssertNil(AgentsMirrorWire.grantSet(requestId: UUID().uuidString, deviceId: "server", key: .notifications, on: true, window: nil))
        XCTAssertNotNil(AgentsMirrorWire.grantSet(requestId: UUID().uuidString, deviceId: "server", key: .notifications, on: true, window: .oneHour))
        XCTAssertTrue(AgentActivityEntry.actions.contains("notifications.read"))
    }

    func testGrantStateWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_798_000_000)
        let ms = unixMillis(now)
        XCTAssertEqual(AgentsText.state(nil, now: now), "Off")
        XCTAssertEqual(AgentsText.state(AgentGrant(key: .codes, state: .waiting), now: now), "Waiting for you")
        XCTAssertEqual(AgentsText.state(AgentGrant(key: .codes, state: .on, window: .forever), now: now), "On until you turn it off")
        XCTAssertEqual(AgentsText.state(AgentGrant(key: .codes, state: .on, window: .oneHour, expiresAt: ms + 3_600_000), now: now, calendar: calendar),
                       "On until " + AgentsText.time(Date(timeIntervalSince1970: 1_798_003_600), now: now, calendar: calendar))
        XCTAssertEqual(AgentsText.time(Date(timeIntervalSince1970: 1_798_003_600), now: now, calendar: calendar), "05:26")
        XCTAssertEqual(AgentsText.state(AgentGrant(key: .codes, state: .on, window: .oneHour, expiresAt: ms - 1), now: now), "Off")
        XCTAssertEqual(AgentGrantKey.allCases.map(AgentsText.grantTitle), [
            "Send you files", "Set your clipboard", "Ask for your clipboard", "Send you notifications", "Ask you questions",
            "Ring this phone", "See battery", "Read codes", "Detect codes", "Read your notifications",
        ], "rows in the wording table's order")
    }

    /// Detect codes is shown, never changed from the Mac; a current Mac keeps the grant and its activity rows.
    func testDetectCodesIsReadOnlyHereAndDecoded() throws {
        XCTAssertNil(AgentsMirrorWire.grantSet(requestId: UUID().uuidString.lowercased(), deviceId: "agent-id", key: .codesDetect, on: true, window: .oneHour))
        XCTAssertNil(AgentsMirrorWire.grantSet(requestId: UUID().uuidString.lowercased(), deviceId: "agent-id", key: .codesDetect, on: false, window: nil))
        XCTAssertNotNil(AgentsMirrorWire.grantSet(requestId: UUID().uuidString.lowercased(), deviceId: "agent-id", key: .codes, on: false, window: nil))
        let state: [String: Any] = ["version": 1, "agents": [[
            "deviceId": "agent-id", "name": "Contabo Europe", "platform": "cli", "app": "bridgey 0.1.0", "os": "linux x86_64",
            "pairedAt": 1_797_990_000_000, "online": true,
            "grants": [["key": "codes_detect", "state": "on", "window": "today", "grantedAt": 1_798_000_000_000]],
            "activity": [["at": 1_798_000_400_000, "action": "codes.detect", "outcome": "delivered", "detail": "Messages"]],
        ]]]
        let agents = try XCTUnwrap(AgentsMirrorWire.agentsState(try JSONSerialization.data(withJSONObject: state)))
        XCTAssertEqual(agents.first?.grant(.codesDetect)?.state, .on)
        XCTAssertEqual(agents.first?.activity.first?.action, "codes.detect")
    }

    func testDraftKeysEndWithTheSixAgentKeysInOrder() {
        XCTAssertEqual(Array(knownDraftFeatureKeys.suffix(8)), [
            "email_codes_draft1", "agent_draft1", "notify_draft1", "ask_draft1", "clipboard_request_draft1", "agent_codes_draft1", "agents_mirror_draft1",
            "codes_detect_draft1",
        ])
    }
}

/// ru.lproj and en.lproj Agents.strings: every key used is in both, the shared ones match docs/agent-cli-wording.md word
/// for word, and nothing has a dash.
final class AgentsStringsTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func table(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: repo.appendingPathComponent("macos/Resources/\(language).lproj/Agents.strings"))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// The wording table, by the Mac's keys: grants are `grant.<key>` and `grant.<key>.detail`; `%1$s` reads `%1$@`.
    private func wording() throws -> (english: [String: String], russian: [String: String]) {
        let text = try String(contentsOf: repo.appendingPathComponent("docs/agent-cli-wording.md"), encoding: .utf8)
        var english: [String: String] = [:]
        var russian: [String: String] = [:]
        for line in text.components(separatedBy: "\n") where line.hasPrefix("| ") && !line.hasPrefix("| ---") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%1$s", with: "%1$@").replacingOccurrences(of: "%2$s", with: "%2$@") }
            if cells.count == 3, cells[0] != "Key" {
                english[cells[0]] = cells[1]
                russian[cells[0]] = cells[2]
            } else if cells.count == 5, cells[0] != "Grant" {
                let key = "grant." + cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                english[key] = cells[1]
                english[key + ".detail"] = cells[2]
                russian[key] = cells[3]
                russian[key + ".detail"] = cells[4]
            }
        }
        return (english, russian)
    }

    private func usedKeys() throws -> Set<String> {
        let sources = repo.appendingPathComponent("macos/Sources/BridgeyMac")
        let pattern = try NSRegularExpression(pattern: #"L10n\.agents\(\s*"([^"]+)""#)
        var keys = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return keys
    }

    func testEveryKeyIsInBothLanguagesAndMatchesTheWordingTable() throws {
        let used = try usedKeys()
        XCTAssertGreaterThan(used.count, 40)
        let english = try table("en")
        let russian = try table("ru")
        XCTAssertEqual(Set(english.keys), used)
        XCTAssertEqual(Set(russian.keys), used)
        let shared = try wording()
        XCTAssertGreaterThan(shared.english.count, 40, "the wording table did not parse")
        for key in used {
            if let words = shared.english[key] {
                XCTAssertEqual(english[key], words, "en \(key)")
                XCTAssertEqual(russian[key], shared.russian[key], "ru \(key)")
            } else {
                XCTAssertTrue(key.hasPrefix("mac.") || key.hasPrefix("activity."), "\(key) is not in docs/agent-cli-wording.md")
            }
            XCTAssertEqual(russian[key]?.components(separatedBy: "%").count, english[key]?.components(separatedBy: "%").count, "placeholders in \(key)")
        }
    }

    func testNoDashes() throws {
        for language in ["en", "ru"] {
            for (key, value) in try table(language) {
                XCTAssertFalse(value.contains("\u{2014}") || value.contains("\u{2013}"), "\(language) \(key)")
            }
        }
    }
}
