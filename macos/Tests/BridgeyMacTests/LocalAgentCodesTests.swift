import Darwin
import Foundation
import XCTest
@testable import BridgeyMac

final class LocalAgentCodesTests: XCTestCase {
    private let posted = Date(timeIntervalSince1970: 1_800_000_000)

    private func enabled(minutes: Int = 10, blocked: [String]? = nil) -> LocalAgentCodeOptions {
        var options = LocalAgentCodeOptions()
        options.enabled = true
        options.minutes = minutes
        if let blocked { options.blockedSenders = blocked }
        return options
    }
    private func put(_ store: LocalAgentCodeStore, sender: String = "Example", code: String = "123456", offset: TimeInterval = 0, age: TimeInterval = 0) {
        store.retain(code: code, sender: sender, identities: [], posted: posted.addingTimeInterval(offset), age: age)
    }
    private func defaults() throws -> (UserDefaults, String) {
        let name = "LocalAgentCodesTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testOffByDefaultAndNoPreferencesWrittenAtLaunch() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let before = defaults.dictionaryRepresentation()
        let options = LocalAgentCodeOptions(defaults: defaults)
        XCTAssertFalse(options.enabled)
        XCTAssertEqual(options.minutes, 10)
        XCTAssertEqual(before as NSDictionary, defaults.dictionaryRepresentation() as NSDictionary)
        let store = LocalAgentCodeStore()
        put(store)
        XCTAssertTrue(store.read().isEmpty)
        XCTAssertEqual(store.retainedCount, 0)
    }

    func testExpiryAtDeadlineAndReadsDoNotConsumeOrExtendIt() {
        var time: TimeInterval = 0
        let store = LocalAgentCodeStore(now: { time })
        store.configure(enabled())
        put(store)
        XCTAssertEqual(store.read().count, 1)
        time = 599
        XCTAssertEqual(store.read().first?.expiresInSeconds, 1)
        XCTAssertEqual(store.read().first?.expiresInSeconds, 1)
        time = 600
        XCTAssertTrue(store.read().isEmpty)
        XCTAssertEqual(store.retainedCount, 0)
    }

    func testIdleExpiryErasesWithoutARead() {
        let store = LocalAgentCodeStore()
        store.configure(enabled(minutes: 1))
        put(store, age: 59.95)
        XCTAssertEqual(store.retainedCount, 1)
        let erased = expectation(description: "Expiry timer fired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(store.retainedCount, 0)
            erased.fulfill()
        }
        wait(for: [erased], timeout: 2)
    }

    func testConfigurableExpiryOffAndAnyPolicyChangeClearImmediately() {
        var time: TimeInterval = 0
        let store = LocalAgentCodeStore(now: { time })
        store.configure(enabled(minutes: 2))
        put(store)
        time = 119
        XCTAssertEqual(store.read().count, 1)
        time = 120
        XCTAssertTrue(store.read().isEmpty)
        put(store, offset: 1)
        store.configure(enabled(minutes: 1))
        XCTAssertEqual(store.retainedCount, 0)
        put(store, offset: 2)
        store.configure(enabled(minutes: 1, blocked: ["example"]))
        XCTAssertEqual(store.retainedCount, 0)
        store.configure(enabled())
        put(store)
        store.configure(LocalAgentCodeOptions())
        XCTAssertTrue(store.read().isEmpty)
    }

    func testNewestPerSenderIgnoresReplaysAndLateMessages() {
        var time: TimeInterval = 0
        let store = LocalAgentCodeStore(now: { time })
        store.configure(enabled())
        put(store)
        time = 10
        put(store, code: "654321", offset: 10)
        put(store, sender: "Another service", code: "112233", offset: 11)
        put(store, code: "999999", offset: 5)
        time = 15
        put(store, code: "654321", offset: 15) // Same code from a second notification.
        let values = store.read()
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains { $0.sender == "Example" && $0.code == "654321" && $0.expiresInSeconds == 595 })
        time = 610
        XCTAssertTrue(store.read().isEmpty)
        put(store, age: 600)
        XCTAssertTrue(store.read().isEmpty)
    }

    func testDefaultBankPaymentAndSmsSendersAreBlockedBeforeRetention() {
        let options = enabled()
        for sender in ["HDFC Bank", "AX-HDFCBK-S", "VM-ICICIB-S", "AD-SBIOTP-S", "JK-AXISBK-T", "AD-KOTAKB-S",
                       "PhonePe", "Google Pay", "Paytm", "BHIM", "AD-cshFRE-S", "Visa", "Mastercard", "Amex"] {
            let store = LocalAgentCodeStore()
            store.configure(options)
            put(store, sender: sender)
            XCTAssertEqual(store.retainedCount, 0, sender)
        }
        let store = LocalAgentCodeStore()
        store.configure(options)
        store.retain(code: "123456", sender: "Sign in", identities: ["com.google.android.apps.nbu.paisa.user"], posted: posted)
        XCTAssertEqual(store.retainedCount, 0, "The package is checked even when the title is generic")
        store.configure(enabled(blocked: ["my-service"]))
        put(store, sender: "My Service")
        XCTAssertEqual(store.retainedCount, 0)
        put(store, sender: "Example")
        XCTAssertEqual(store.retainedCount, 1)
    }

    func testCodesAreNotPersistedAndARestartRestoresOnlyPreferences() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("pairing-sentinel", forKey: "pairing.test")
        let options = enabled()
        options.save(to: defaults)
        let before = defaults.dictionaryRepresentation()
        let store = LocalAgentCodeStore()
        store.configure(options)
        put(store)
        XCTAssertEqual(store.read().count, 1)
        XCTAssertEqual(before as NSDictionary, defaults.dictionaryRepresentation() as NSDictionary)
        let restored = LocalAgentCodeStore()
        restored.configure(LocalAgentCodeOptions(defaults: defaults))
        XCTAssertTrue(restored.read().isEmpty)
        XCTAssertEqual(defaults.string(forKey: "pairing.test"), "pairing-sentinel")
        XCTAssertFalse(SyncKey.allCases.contains { $0.rawValue.contains("localAgentCodes") })
        XCTAssertEqual(settingsSyncStoredValues(before), settingsSyncStoredValues(defaults.dictionaryRepresentation()))
        XCTAssertTrue(settingsSyncStoredValues([LocalAgentCodeOptions.prefix + "enabled": true,
                                               LocalAgentCodeOptions.prefix + "minutes": 3,
                                               LocalAgentCodeOptions.prefix + "blockedSenders": ["Example"]]).isEmpty)
    }

    private func socketPath() -> String { "/tmp/bridgey-lc-\(UUID().uuidString.prefix(12))/codes.sock" }
    private func exchange(path: String, request: Data = LocalAgentCodesSocket.request) throws -> Data? {
        let result = LocalAgentCodesSocket.connect(path)
        guard case let .success(fd) = result else { XCTFail("Could not connect to fixture"); return nil }
        defer { close(fd) }
        LocalAgentCodesSocket.write(request, to: fd)
        return UpdateControlSocket.readLine(fd, limit: 64 * 1024)
    }

    func testSocketPermissionsReadOnlyProtocolAndEveryReadAuditWithoutCodes() throws {
        let path = socketPath(), directory = (path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = LocalAgentCodeStore()
        store.configure(enabled())
        put(store)
        let lock = NSLock()
        var events: [String] = []
        let server = LocalAgentCodesServer(path: path, store: store, audit: { uid, outcome, count in
            lock.lock(); defer { lock.unlock() }
            events.append("\(uid ?? 0):\(outcome):\(count)")
        })
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(LocalAgentCodesSocket.isPrivate(directory, kind: S_IFDIR, mode: 0o700))
        XCTAssertTrue(LocalAgentCodesSocket.isPrivate(path, kind: S_IFSOCK, mode: 0o600))
        for _ in 0..<2 {
            let data = try XCTUnwrap(exchange(path: path))
            XCTAssertEqual(try JSONDecoder().decode([LocalAgentCode].self, from: data).count, 1)
        }
        XCTAssertNil(try exchange(path: path, request: Data("{\"version\":1,\"command\":\"enable\"}\n".utf8)))
        store.configure(LocalAgentCodeOptions())
        XCTAssertEqual(try exchange(path: path), Data("[]".utf8))
        lock.lock(); let recorded = events; lock.unlock()
        XCTAssertEqual(recorded.count, 4)
        XCTAssertEqual(recorded.filter { $0.hasSuffix(":read:1") }.count, 2)
        XCTAssertTrue(recorded.contains { $0.hasSuffix(":bad_request:0") })
        XCTAssertTrue(recorded.contains { $0.hasSuffix(":read:0") })
        XCTAssertFalse(recorded.joined().contains("123456"))
        XCTAssertFalse(recorded.joined().contains("Example"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        XCTAssertEqual(files, ["codes.sock"], "No data or history file is created by storing or reading codes")
    }

    func testSocketRefusesOtherUserAndUnknownCredentials() throws {
        for peer: uid_t? in [getuid() + 1, nil] {
            let path = socketPath(), directory = (path as NSString).deletingLastPathComponent
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let store = LocalAgentCodeStore()
            store.configure(enabled()); put(store)
            let audited = expectation(description: "Denied access logged")
            let server = LocalAgentCodesServer(path: path, store: store, peerUID: { _ in peer }, audit: { _, result, count in
                XCTAssertEqual(result, "denied"); XCTAssertEqual(count, 0); audited.fulfill()
            })
            try server.start()
            XCTAssertNil(try exchange(path: path))
            wait(for: [audited], timeout: 2)
            server.stop()
        }
    }

    func testUnsafeDirectorySymlinkAndSocketModeAreRefused() throws {
        let path = socketPath(), directory = (path as NSString).deletingLastPathComponent
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let server = LocalAgentCodesServer(path: path, store: LocalAgentCodeStore(), audit: { _, _, _ in })
        XCTAssertThrowsError(try server.start())
        chmod(directory, 0o700)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try server.start())
        unlink(path)
        try server.start()
        defer { server.stop() }
        chmod(path, 0o666)
        if case .success = LocalAgentCodesSocket.connect(path) { XCTFail("Unsafe socket accepted") }
        chmod(path, 0o600)
    }

    func testCLIRequiresRunningAppAndCannotChangeSettings() {
        var output: [String] = []
        XCTAssertEqual(LocalAgentCodesCLI.run(arguments: ["BridgeyMac", "--local-codes", "--enable"], output: { output.append($0) }), 2)
        XCTAssertEqual(LocalAgentCodesCLI.run(arguments: ["BridgeyMac", "--local-codes"], path: socketPath(), output: { output.append($0) }), 1)
        XCTAssertEqual(output.count, 2)
    }
}
