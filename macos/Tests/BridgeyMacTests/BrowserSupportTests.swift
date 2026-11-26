import XCTest
@testable import BridgeyMac

/// Browser support (BrowserSupport.swift, docs/browser-extensions.md): addresses, the helper's requests, the host
/// manifests, the socket and the link path to one device.
final class BrowserSupportTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func temporaryFolder() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/bridgey-bs-\(UUID().uuidString.prefix(10))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var config: BrowserHostConfig {
        BrowserHostConfig(name: "in.roundrobin.bridgey", chromiumExtensionIDs: ["aajelmcjgfjbhemgofnompobgbcdfcin"],
                          firefoxExtensionIDs: ["bridgey@roundrobin.in"])
    }

    // MARK: Addresses and requests

    func testAddresses() {
        XCTAssertEqual(browserAddress("https://example.com/a?b#c"), .web("https://example.com/a?b#c"))
        XCTAssertEqual(browserAddress("tel:+442079460958"), .tel("+442079460958"))
        XCTAssertEqual(browserAddress("tel:+1%20555%20123%204567;ext=2"), .tel("+15551234567"))
        XCTAssertEqual(browserAddress("mailto:hello@roundrobin.in?subject=Hi"), .mailto("hello@roundrobin.in"))
        XCTAssertEqual(browserAddress("MAILTO:a@b.c,d%40e.f"), .mailto("a@b.c, d@e.f"))
        for bad in ["", "file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.com/", "tel:12", "tel:abc",
                    "mailto:", "mailto:nobody", "mailto:a@b,", "mailto:<a@b>", "mailto:a@b%0Ac", "ftp://example.com/",
                    "https://example.com/" + String(repeating: "a", count: 4096)] {
            XCTAssertNil(browserAddress(bad), bad)
        }
    }

    func testRequestsAreStrict() {
        func decode(_ text: String) -> BrowserHostRequest? { BrowserHostRequest.decode(Data(text.utf8)) }
        XCTAssertEqual(decode(#"{"version":1,"type":"devices"}"#), .devices)
        XCTAssertEqual(decode(#"{"version":1,"type":"send","device":"d-1","url":"https://example.com/"}"#),
                       .send(device: "d-1", address: .web("https://example.com/")))
        for bad in [#"{"version":2,"type":"devices"}"#, #"{"version":"1","type":"devices"}"#, #"{"version":true,"type":"devices"}"#,
                    #"{"version":1,"type":"devices","extra":1}"#, #"{"version":1,"type":"send","device":"d","url":"file:///x"}"#,
                    #"{"version":1,"type":"send","device":"a b","url":"https://a.b/"}"#, #"{"version":1,"type":"send","device":"d"}"#,
                    #"{"version":1,"type":"send","device":"d","url":"https://a.b/","url":"https://c.d/"}"#,
                    #"{"version":1,"type":"open","device":"d","url":"https://a.b/"}"#, "[]", "not json"] {
            XCTAssertNil(decode(bad), bad)
        }
        XCTAssertNil(BrowserHostRequest.decode(Data(repeating: 0x20, count: BrowserHostRequest.maxBytes + 1)))
        XCTAssertNil(decode(#"{"version":1,"type":"devices","type":"devices"}"#))
        XCTAssertNil(decode(#"{"version":1,"type":"devices","x":{"y":1}}"#))
        XCTAssertEqual(topLevelKeyCount(Data(#"{"a":"x:\"y\":z", "b" : 1}"#.utf8)), 2)
    }

    func testRepliesCarryOnlyTheListedFields() throws {
        let data = BrowserHostReply.devices([BrowserDevice(id: "d1", name: "Pixel 8", platform: "android", connected: true, links: true, calls: true)])
        XCTAssertEqual(data.last, 0x0A)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        let devices = try XCTUnwrap(object["devices"] as? [[String: Any]])
        XCTAssertEqual(Set(devices[0].keys), ["id", "name", "platform", "connected", "links", "calls"])
        XCTAssertEqual(String(decoding: BrowserHostReply.sent(.waiting), as: UTF8.self), "{\"ok\":true,\"result\":\"waiting\",\"version\":1}\n")
        XCTAssertEqual(String(decoding: BrowserHostReply.sent(.failed("links_off")), as: UTF8.self), "{\"error\":\"links_off\",\"ok\":false,\"version\":1}\n")
    }

    func testTheRepositoryAllowListLoads() throws {
        let loaded = try XCTUnwrap(BrowserHostConfig.load(repo.appendingPathComponent("extensions/browser/native-host.json")))
        XCTAssertEqual(loaded, config)
    }

    // MARK: Host manifests

    func testManifestsGoOnlyToBrowsersPresentAndRemoveLeavesOthers() throws {
        let root = try temporaryFolder()
        for folder in ["Google/Chrome", "Mozilla", "Arc/User Data"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let helper = "/Applications/Bridgey by Round Robin.app/Contents/Helpers/bridgey-browser-host"
        let installer = BrowserHostInstaller(root: root, helperPath: helper, config: config)
        XCTAssertEqual(installer.install().map(\.name), ["Google Chrome", "Arc", "Firefox"])
        XCTAssertEqual(installer.installed.map(\.name), ["Google Chrome", "Arc", "Firefox"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Microsoft Edge").path))

        let chrome = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Google/Chrome/NativeMessagingHosts/in.roundrobin.bridgey.json"))) as? [String: Any])
        XCTAssertEqual(chrome["path"] as? String, helper)
        XCTAssertEqual(chrome["type"] as? String, "stdio")
        XCTAssertEqual(chrome["allowed_origins"] as? [String], ["chrome-extension://aajelmcjgfjbhemgofnompobgbcdfcin/"])
        XCTAssertNil(chrome["allowed_extensions"])
        let firefox = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Mozilla/NativeMessagingHosts/in.roundrobin.bridgey.json"))) as? [String: Any])
        XCTAssertEqual(firefox["allowed_extensions"] as? [String], ["bridgey@roundrobin.in"])
        XCTAssertNil(firefox["allowed_origins"])

        // Another app's file with the same name stays; an older Bridgey's goes.
        let arc = root.appendingPathComponent("Arc/User Data/NativeMessagingHosts/in.roundrobin.bridgey.json")
        try Data(#"{"name":"in.roundrobin.bridgey","path":"/opt/other/tool","type":"stdio"}"#.utf8).write(to: arc)
        let old = BrowserHostInstaller(root: root, helperPath: "/Users/a/Downloads/Bridgey.app/Contents/Helpers/bridgey-browser-host", config: config)
        XCTAssertEqual(installer.installed.map(\.name), ["Google Chrome", "Firefox"])
        old.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: arc.path))
        XCTAssertTrue(installer.installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Mozilla/NativeMessagingHosts/in.roundrobin.bridgey.json").path))
    }

    // MARK: The socket

    /// One exchange off the main thread (the handler runs on the main actor).
    private final class Answer: @unchecked Sendable { var text: String? }

    private func exchange(_ path: String, _ request: String) -> String? {
        let done = expectation(description: "answer")
        let answer = Answer()
        DispatchQueue.global().async {
            if case let .success(fd) = UpdateControlSocket.connect(path) {
                LocalAgentCodesSocket.write(Data((request + "\n").utf8), to: fd)
                answer.text = UpdateControlSocket.readLine(fd, limit: 64 * 1024).map { String(decoding: $0, as: UTF8.self) }
                close(fd)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return answer.text
    }

    @MainActor func testServerAnswersCheckedRequestsOnAPrivateSocket() throws {
        let path = try temporaryFolder().appendingPathComponent("browser.sock").path
        var seen: [BrowserHostRequest] = []
        let server = BrowserHostServer(path: path) { request, reply in
            seen.append(request)
            reply(BrowserHostReply.sent(.opened))
        }
        try server.start()
        defer { server.stop() }
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(exchange(path, #"{"version":1,"type":"send","device":"d1","url":"https://example.com/"}"#),
                       #"{"ok":true,"result":"opened","version":1}"#)
        XCTAssertEqual(exchange(path, #"{"version":1,"type":"send","device":"d1","url":"file:///etc/passwd"}"#),
                       #"{"error":"bad_request","ok":false,"version":1}"#)
        XCTAssertEqual(seen, [.send(device: "d1", address: .web("https://example.com/"))])
        XCTAssertThrowsError(try BrowserHostServer(path: path) { _, reply in reply(Data()) }.start(), "a second server never takes the socket")
    }

    @MainActor func testOtherUsersAreRefusedAndSlowAnswersTimeOut() throws {
        let path = try temporaryFolder().appendingPathComponent("browser.sock").path
        let stranger = BrowserHostServer(path: path, peerUID: { _ in getuid() + 1 }) { _, reply in reply(BrowserHostReply.sent(.opened)) }
        try stranger.start()
        XCTAssertNil(exchange(path, #"{"version":1,"type":"devices"}"#))
        stranger.stop()

        let slow = BrowserHostServer(path: path) { _, _ in }
        slow.answerTimeout = 0.3
        try slow.start()
        defer { slow.stop() }
        XCTAssertEqual(exchange(path, #"{"version":1,"type":"devices"}"#), #"{"error":"no_answer","ok":false,"version":1}"#)
    }

    // MARK: Settings and the running part

    @MainActor private final class FakeHost: BrowserSupportHost {
        var sent: [(BrowserAddress, String)] = []
        func browserDevices() -> [BrowserDevice] {
            [BrowserDevice(id: "d1", name: "Pixel 8", platform: "android", connected: true, links: true, calls: true)]
        }
        func browserSend(_ address: BrowserAddress, to deviceID: String, completion: @escaping (BrowserSendOutcome) -> Void) {
            sent.append((address, deviceID))
            completion(.waiting)
        }
    }

    @MainActor func testInstallStartsTheSocketAndRemoveUndoesBoth() throws {
        let folder = try temporaryFolder()
        let root = folder.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bridgey-browser-\(UUID().uuidString)"))
        let installer = BrowserHostInstaller(root: root, helperPath: "/x/Bridgey.app/Contents/Helpers/bridgey-browser-host", config: config)
        let socket = folder.appendingPathComponent("support/browser.sock").path
        let support = BrowserSupport(defaults: defaults, installer: installer, socketPath: socket, translocated: false)
        let host = FakeHost()
        support.host = host
        XCTAssertEqual(support.display, BrowserSupportDisplay(enabled: false, browsers: [], problem: nil))
        XCTAssertEqual(BrowserSupportText.subtitle(support.display), BrowserSupportText.detail)

        support.install()
        XCTAssertEqual(support.display, BrowserSupportDisplay(enabled: true, browsers: ["Google Chrome"], problem: nil))
        XCTAssertTrue(defaults.bool(forKey: BrowserSupport.enabledKey))
        let devices = try XCTUnwrap(exchange(socket, #"{"version":1,"type":"devices"}"#))
        XCTAssertTrue(devices.contains(#""name":"Pixel 8""#), devices)
        XCTAssertEqual(exchange(socket, #"{"version":1,"type":"send","device":"d1","url":"tel:+442079460958"}"#),
                       #"{"ok":true,"result":"waiting","version":1}"#)
        XCTAssertEqual(host.sent.first?.0, .tel("+442079460958"))

        support.remove()
        XCTAssertEqual(support.display, BrowserSupportDisplay(enabled: false, browsers: [], problem: nil))
        XCTAssertTrue(installer.installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }

    @MainActor func testProblemsShowInTheRow() throws {
        let folder = try temporaryFolder()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bridgey-browser-\(UUID().uuidString)"))
        XCTAssertEqual(BrowserSupport(defaults: defaults, installer: nil, socketPath: folder.appendingPathComponent("a.sock").path).display.problem, .unavailable)
        let installer = BrowserHostInstaller(root: folder.appendingPathComponent("empty"), helperPath: "/x/Contents/Helpers/bridgey-browser-host", config: config)
        let moved = BrowserSupport(defaults: defaults, installer: installer, socketPath: folder.appendingPathComponent("b.sock").path, translocated: true)
        moved.install()
        XCTAssertEqual(moved.display.problem, .translocated)
        XCTAssertFalse(defaults.bool(forKey: BrowserSupport.enabledKey))
        let none = BrowserSupport(defaults: defaults, installer: installer, socketPath: folder.appendingPathComponent("c.sock").path, translocated: false)
        none.install()
        XCTAssertEqual(none.display.problem, .noBrowser)
        none.remove()
    }

    // MARK: Links to one device

    @MainActor func testBrowserLinksGoToOneDeviceAndOnlyItAnswers() {
        let actions = QuickActions()
        var sent: [[String: Any]] = []
        var outcomes: [BrowserSendOutcome] = []
        actions.sendBrowserLink("https://example.com/", to: "mac", open: true, send: { sent.append($0); return true }) { outcomes.append($0) }
        XCTAssertEqual(sent.first?["action"] as? String, "open")
        XCTAssertEqual(sent.first?["feature"] as? String, "links")
        let id = sent[0]["requestId"] as! String
        // A second link to the same device waits for the first.
        actions.sendBrowserLink("https://example.org/", to: "mac", open: true, send: { sent.append($0); return true }) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.failed("busy")])
        // Another device's answer with the same request ID changes nothing.
        actions.receive("quick.result", payload: ["version": 1, "requestId": id, "feature": "links", "accepted": true, "opened": true], from: "phone")
        XCTAssertEqual(outcomes, [.failed("busy")])
        actions.receive("quick.result", payload: ["version": 1, "requestId": id, "feature": "links", "accepted": true, "opened": true], from: "mac")
        XCTAssertEqual(outcomes, [.failed("busy"), .opened])

        actions.sendBrowserLink("https://example.com/", to: "phone", open: false, send: { sent.append($0); return true }) { outcomes.append($0) }
        XCTAssertEqual(sent.last?["action"] as? String, "offer")
        let offer = sent.last?["requestId"] as! String
        actions.receive("quick.result", payload: ["version": 1, "requestId": offer, "feature": "links", "accepted": true], from: "phone")
        XCTAssertEqual(outcomes.last, .waiting)

        actions.sendBrowserLink("https://example.com/", to: "phone", open: false, send: { sent.append($0); return true }) { outcomes.append($0) }
        let declined = sent.last?["requestId"] as! String
        actions.receive("quick.result", payload: ["version": 1, "requestId": declined, "feature": "links", "accepted": false, "reason": "rate_limited"], from: "phone")
        XCTAssertEqual(outcomes.last, .failed("rate_limited"))

        actions.sendBrowserLink("https://example.com/", to: "phone", open: false, send: { sent.append($0); return true }) { outcomes.append($0) }
        actions.reset()
        XCTAssertEqual(outcomes.last, .failed("not_connected"))
        actions.sendBrowserLink("https://example.com/", to: "phone", open: false, send: { _ in false }) { outcomes.append($0) }
        XCTAssertEqual(outcomes.last, .failed("not_connected"))
        actions.sendBrowserLink("file:///etc/passwd", to: "phone", open: false, send: { _ in true }) { outcomes.append($0) }
        XCTAssertEqual(outcomes.last, .failed("bad_url"))
        // Sequences keep increasing across devices, as every receiver expects.
        let sequences = sent.compactMap { $0["sequence"] as? Int }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count)
    }
}
