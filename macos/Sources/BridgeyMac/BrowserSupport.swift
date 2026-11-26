import AppKit
import Darwin
import Foundation

/*
 * Browser support (docs/browser-extensions.md). Bridgey's extension for Chrome, Edge, Firefox, Brave, Arc and other
 * Chromium browsers reaches this app through native messaging: the browser starts the helper this app ships
 * (Contents/Helpers/bridgey-browser-host, rust/browser-host) for each message, and the helper asks this app over a
 * private Unix socket. Settings > Media and actions > Browsers installs the browsers' host manifests (per user, never
 * system-wide) and turns the socket on; Remove deletes both. Only two requests exist: the device list, and one
 * address (http, https, mailto or tel) to one device. Nothing is stored and nothing goes to the network.
 */

// MARK: - Addresses

/// A checked address from the browser, as Bridgey sends it.
enum BrowserAddress: Equatable, Sendable {
    /// An http or https link, under the rules every device applies to links.
    case web(String)
    /// The email addresses of a mailto: link, joined with ", " (they go to the device's clipboard).
    case mailto(String)
    /// The number of a tel: link, normalised (the phone calls it).
    case tel(String)
}

func browserAddress(_ value: String) -> BrowserAddress? {
    guard value.utf8.count <= 4096 else { return nil }
    let lower = value.lowercased()
    if lower.hasPrefix("http:") || lower.hasPrefix("https:") { return validatedWebLink(value).map(BrowserAddress.web) }
    if lower.hasPrefix("tel:") {
        let number = String(value.dropFirst(4)).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return phoneNumberFromTelURL("tel:" + number).map(BrowserAddress.tel)
    }
    if lower.hasPrefix("mailto:") {
        let rest = String(value.dropFirst(7))
        let part = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let decoded = part.removingPercentEncoding, !decoded.isEmpty else { return nil }
        let addresses = decoded.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard addresses.allSatisfy(isPlainEmailAddress) else { return nil }
        return .mailto(addresses.joined(separator: ", "))
    }
    return nil
}

private func isPlainEmailAddress(_ value: String) -> Bool {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, value.utf8.count <= 254 else { return false }
    let refused = Set("<>\"(),;:[]\\".unicodeScalars)
    return value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && !refused.contains($0) }
}

// MARK: - The helper's requests and this app's answers

/// One request line from bridgey-browser-host. Strict: exact keys, version 1, a short device ID and a checked address.
enum BrowserHostRequest: Equatable, Sendable {
    case devices
    case send(device: String, address: BrowserAddress)

    static let maxBytes = 8192

    static func decode(_ data: Data) -> BrowserHostRequest? {
        guard data.count <= maxBytes, isStrictJSONObject(data, maxDepth: 1),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              topLevelKeyCount(data) == object.count,
              jsonInteger(object["version"]) == 1, let type = object["type"] as? String else { return nil }
        switch type {
        case "devices":
            return Set(object.keys) == ["version", "type"] ? .devices : nil
        case "send":
            guard Set(object.keys) == ["version", "type", "device", "url"],
                  let device = object["device"] as? String, isBrowserDeviceID(device),
                  let url = object["url"] as? String, let address = browserAddress(url) else { return nil }
            return .send(device: device, address: address)
        default:
            return nil
        }
    }
}

/// How many keys a flat JSON object spells out. JSONSerialization keeps one of two equal keys; a request with a
/// repeated key is refused instead.
func topLevelKeyCount(_ data: Data) -> Int {
    var count = 0, inString = false, escaped = false, stringEnded = false
    for byte in data {
        if inString {
            if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false; stringEnded = true }
            continue
        }
        switch byte {
        case 0x22: inString = true
        case 0x3A: if stringEnded { count += 1 }; stringEnded = false
        case 0x20, 0x09, 0x0A, 0x0D: break
        default: stringEnded = false
        }
    }
    return count
}

func isBrowserDeviceID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 64 && id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
}

/// A device as the extension sees it.
struct BrowserDevice: Equatable {
    let id: String
    let name: String
    /// android, macos, windows, ios, linux, or empty.
    let platform: String
    let connected: Bool
    /// Links is on here and on the device.
    let links: Bool
    /// The device places calls for this Mac.
    let calls: Bool
}

enum BrowserHostReply {
    static func devices(_ devices: [BrowserDevice]) -> Data {
        line(["version": 1, "ok": true, "devices": devices.prefix(32).map { device in
            ["id": device.id, "name": String(device.name.prefix(64)), "platform": device.platform,
             "connected": device.connected, "links": device.links, "calls": device.calls] as [String: Any]
        }])
    }

    static func sent(_ outcome: BrowserSendOutcome) -> Data {
        switch outcome {
        case .opened: return line(["version": 1, "ok": true, "result": "opened"])
        case .waiting: return line(["version": 1, "ok": true, "result": "waiting"])
        case .calling: return line(["version": 1, "ok": true, "result": "calling"])
        case .asking: return line(["version": 1, "ok": true, "result": "asking"])
        case .copied: return line(["version": 1, "ok": true, "result": "copied"])
        case let .failed(code): return error(code)
        }
    }

    static func error(_ code: String) -> Data { line(["version": 1, "ok": false, "error": code]) }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"version\":1,\"ok\":false,\"error\":\"failed\"}".utf8)
        data.append(0x0A)
        return data
    }
}

// MARK: - Host manifests

/// The extension IDs and the host name, from extensions/browser/native-host.json (copied into Resources by
/// build-app.sh, the same file the helper is built with).
struct BrowserHostConfig: Equatable {
    let name: String
    let chromiumExtensionIDs: [String]
    let firefoxExtensionIDs: [String]

    static func load(_ url: URL?) -> BrowserHostConfig? {
        guard let url, let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["name"] as? String, name == "in.roundrobin.bridgey",
              let chromium = object["chromiumExtensionIds"] as? [String], let firefox = object["firefoxExtensionIds"] as? [String],
              chromium.allSatisfy({ $0.count == 32 && $0.unicodeScalars.allSatisfy { ("a"..."p").contains($0) } }) else { return nil }
        return BrowserHostConfig(name: name, chromiumExtensionIDs: chromium, firefoxExtensionIDs: firefox)
    }
}

/// A browser that reads per-user native messaging host manifests from `<Application Support>/<folder>/NativeMessagingHosts`.
struct BrowserHostLocation: Equatable {
    let name: String
    let folder: String
    var firefox = false

    /// Chrome's layout (Chrome, its channels, Chromium, Edge, Brave, Arc, Vivaldi) and Firefox's.
    static let all: [BrowserHostLocation] = [
        .init(name: "Google Chrome", folder: "Google/Chrome"),
        .init(name: "Google Chrome Beta", folder: "Google/Chrome Beta"),
        .init(name: "Google Chrome Dev", folder: "Google/Chrome Dev"),
        .init(name: "Google Chrome Canary", folder: "Google/Chrome Canary"),
        .init(name: "Chromium", folder: "Chromium"),
        .init(name: "Microsoft Edge", folder: "Microsoft Edge"),
        .init(name: "Microsoft Edge Beta", folder: "Microsoft Edge Beta"),
        .init(name: "Microsoft Edge Dev", folder: "Microsoft Edge Dev"),
        .init(name: "Microsoft Edge Canary", folder: "Microsoft Edge Canary"),
        .init(name: "Brave", folder: "BraveSoftware/Brave-Browser"),
        .init(name: "Arc", folder: "Arc/User Data"),
        .init(name: "Vivaldi", folder: "Vivaldi"),
        .init(name: "Firefox", folder: "Mozilla", firefox: true),
    ]
}

/// Writes, finds and removes the host manifests. `root` is the user's Application Support folder; a test instance
/// uses a folder of its own so it never touches the browsers on the Mac.
struct BrowserHostInstaller {
    let root: URL
    let helperPath: String
    let config: BrowserHostConfig
    var locations = BrowserHostLocation.all

    func manifestURL(_ location: BrowserHostLocation) -> URL {
        root.appendingPathComponent(location.folder, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(config.name).json")
    }

    func manifest(_ location: BrowserHostLocation) -> Data {
        var object: [String: Any] = [
            "name": config.name,
            "description": "Bridgey by Round Robin: sends links from this browser to your devices",
            "path": helperPath,
            "type": "stdio",
        ]
        if location.firefox {
            object["allowed_extensions"] = config.firefoxExtensionIDs
        } else {
            object["allowed_origins"] = config.chromiumExtensionIDs.map { "chrome-extension://\($0)/" }
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Browsers whose profile folder exists on this Mac.
    var present: [BrowserHostLocation] {
        locations.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.folder, isDirectory: true).path) }
    }

    /// Writes the manifest for every browser present. Returns the browsers it was written for.
    @discardableResult
    func install() -> [BrowserHostLocation] {
        present.filter { location in
            let url = manifestURL(location)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manifest(location).write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    /// The browsers whose manifest is ours and names this helper.
    var installed: [BrowserHostLocation] {
        locations.filter { location in
            guard let object = readManifest(location) else { return false }
            return object["path"] as? String == helperPath
        }
    }

    /// Removes every Bridgey host manifest (this helper's or an older copy's); other apps' files stay.
    func remove() {
        for location in locations where isBridgeyManifest(readManifest(location)) {
            try? FileManager.default.removeItem(at: manifestURL(location))
        }
    }

    private func readManifest(_ location: BrowserHostLocation) -> [String: Any]? {
        guard let data = try? Data(contentsOf: manifestURL(location)), data.count <= 64 * 1024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func isBridgeyManifest(_ object: [String: Any]?) -> Bool {
        guard let object, object["name"] as? String == config.name, let path = object["path"] as? String else { return false }
        return path.hasSuffix("/Contents/Helpers/bridgey-browser-host")
    }
}

// MARK: - The socket

/// `~/Library/Application Support/<bundle ID>/browser.sock`, where the helper looks for the app it sits in. ~/Library
/// is private to the user; the socket is 0600 and both ends check the other's user ID.
enum BrowserHostSocket {
    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(Edition.supportFolderName, isDirectory: true).appendingPathComponent("browser.sock").path
    }
}

/// Answers the helper: one request per connection, from this user only, at most eight at a time.
final class BrowserHostServer: @unchecked Sendable {
    /// Called on the main actor with a checked request; `reply` takes one answer line.
    typealias Handler = @MainActor (BrowserHostRequest, @escaping @Sendable (Data) -> Void) -> Void

    private let path: String
    private let handler: Handler
    private let peerUID: (Int32) -> uid_t?
    private let queue = DispatchQueue(label: "in.roundrobin.bridgey.browser-host", attributes: .concurrent)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var stopped: DispatchSemaphore?
    private var open = 0
    /// How long the app may take to answer (a link waits up to 8 seconds for the device).
    var answerTimeout: TimeInterval = 12

    init(path: String = BrowserHostSocket.defaultPath, peerUID: @escaping (Int32) -> uid_t? = UpdateControlSocket.peerUID, handler: @escaping Handler) {
        self.path = path
        self.peerUID = peerUID
        self.handler = handler
    }

    func start() throws {
        guard source == nil else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw UpdateControlError.system("exists", EEXIST) }
            if case let .success(fd) = UpdateControlSocket.connect(path) { close(fd); throw UpdateControlError.alreadyServed }
            guard unlink(path) == 0 || errno == ENOENT else { throw UpdateControlError.system("unlink", errno) }
        }
        var address = try UpdateControlSocket.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UpdateControlError.system("socket", errno) }
        // Created owner-only: no moment where another user could connect.
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0 else { let code = errno; close(fd); throw UpdateControlError.system("bind", code) }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno; close(fd); unlink(path); throw UpdateControlError.system("listen", code)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(fd) }
        let path = self.path
        let stopped = DispatchSemaphore(value: 0)
        source.setCancelHandler { close(fd); unlink(path); stopped.signal() }
        self.source = source
        self.stopped = stopped
        source.resume()
    }

    /// Stops listening and removes the socket before returning. Connections already open still get their answer.
    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        stopped?.wait()
        stopped = nil
    }

    private func acceptOne(_ listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        let tooMany: Bool = lock.withLock { if open >= 8 { return true }; open += 1; return false }
        guard !tooMany, setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              peerUID(client) == getuid() else {
            if !tooMany { lock.withLock { open -= 1 } }
            close(client)
            return
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        queue.async { [weak self] in self?.serve(client) }
    }

    /// The first answer for a connection wins: the app's, or the timeout's.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    private func closed() { lock.withLock { open -= 1 } }

    private func serve(_ client: Int32) {
        let once = Once()
        let finish: @Sendable (Data) -> Void = { [weak self] reply in
            guard once.take() else { return }
            LocalAgentCodesSocket.write(reply, to: client)
            close(client)
            self?.closed()
        }
        guard let line = LocalAgentCodesSocket.readLine(client, limit: BrowserHostRequest.maxBytes, seconds: 2),
              let request = BrowserHostRequest.decode(line) else {
            finish(BrowserHostReply.error("bad_request"))
            return
        }
        queue.asyncAfter(deadline: .now() + answerTimeout) { finish(BrowserHostReply.error("no_answer")) }
        let handler = self.handler
        Task { @MainActor in handler(request, finish) }
    }
}

// MARK: - Settings and the running part

/// What answers the extension: the pairing coordinator (Pairing.swift), or a fake in tests.
@MainActor
protocol BrowserSupportHost: AnyObject {
    func browserDevices() -> [BrowserDevice]
    func browserSend(_ address: BrowserAddress, to deviceID: String, completion: @escaping (BrowserSendOutcome) -> Void)
}

/// Settings > Media and actions > Browsers: the row's state.
struct BrowserSupportDisplay: Equatable {
    enum Problem: Equatable {
        /// No helper in this build (a `swift run` build, or cargo was missing).
        case unavailable
        /// The app runs from a temporary copy macOS made (App Translocation); the manifests would point at it.
        case translocated
        /// Installed, but no supported browser has a profile on this Mac.
        case noBrowser
        /// The socket could not start.
        case notListening
    }

    var enabled = false
    /// The browsers whose manifest names this app's helper.
    var browsers: [String] = []
    var problem: Problem?
}

@MainActor
final class BrowserSupport: ObservableObject {
    static let enabledKey = "settings.browser.support"
    static let guideURL = URL(string: "https://github.com/round-robin-solutions/bridgey/blob/rr/main/docs/browser-extensions.md#install-by-hand")!

    @Published private(set) var display = BrowserSupportDisplay()
    weak var host: BrowserSupportHost?
    private let defaults: UserDefaults
    private let installer: BrowserHostInstaller?
    private let socketPath: String
    private let translocated: Bool
    private var server: BrowserHostServer?

    init(defaults: UserDefaults = .standard, installer: BrowserHostInstaller? = BrowserSupport.liveInstaller(),
         socketPath: String = BrowserHostSocket.defaultPath, translocated: Bool = Bundle.main.bundlePath.contains("/AppTranslocation/")) {
        self.defaults = defaults
        self.installer = installer
        self.socketPath = socketPath
        self.translocated = translocated
        refresh()
    }

    /// This app's helper and manifest list; nil when the build has no helper. A test instance writes its manifests
    /// into /tmp/<bundle ID>-browsers instead of the real browsers' folders.
    nonisolated static func liveInstaller() -> BrowserHostInstaller? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bridgey-browser-host").path
        guard FileManager.default.isExecutableFile(atPath: helper),
              let config = BrowserHostConfig.load(Bundle.main.url(forResource: "native-host", withExtension: "json")) else { return nil }
        let root = TestInstance.enabled
            ? URL(fileURLWithPath: "/tmp/\(Edition.identifier)-browsers", isDirectory: true)
            : (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true))
        return BrowserHostInstaller(root: root, helperPath: helper, config: config)
    }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// At launch: when browser support is on, the manifests are written again (the app may have moved or been
    /// updated) and the socket starts.
    func start() {
        guard enabled, installer != nil, !translocated else { refresh(); return }
        installer?.install()
        startServer()
        refresh()
    }

    /// Install: writes the manifests for every browser present and starts the socket.
    func install() {
        guard let installer, !translocated else { refresh(); return }
        defaults.set(true, forKey: Self.enabledKey)
        installer.install()
        startServer()
        refresh()
    }

    /// Remove: deletes every Bridgey host manifest and stops the socket.
    func remove() {
        defaults.set(false, forKey: Self.enabledKey)
        installer?.remove()
        server?.stop()
        server = nil
        refresh()
    }

    private func startServer() {
        guard server == nil else { return }
        let server = BrowserHostServer(path: socketPath) { [weak self] request, reply in
            guard let self else { reply(BrowserHostReply.error("failed")); return }
            self.handle(request, reply: reply)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            self.server = nil
        }
    }

    func handle(_ request: BrowserHostRequest, reply: @escaping @Sendable (Data) -> Void) {
        guard let host else { reply(BrowserHostReply.error("failed")); return }
        switch request {
        case .devices:
            reply(BrowserHostReply.devices(host.browserDevices()))
        case let .send(device, address):
            host.browserSend(address, to: device) { reply(BrowserHostReply.sent($0)) }
        }
    }

    private func refresh() {
        var next = BrowserSupportDisplay(enabled: enabled)
        guard let installer else {
            next.problem = .unavailable
            display = next
            return
        }
        if translocated {
            next.problem = .translocated
        } else if enabled {
            next.browsers = installer.installed.map(\.name)
            if next.browsers.isEmpty { next.problem = .noBrowser } else if server == nil { next.problem = .notListening }
        }
        display = next
    }
}

// MARK: - Settings row

enum BrowserSupportText {
    static var title: String { L10n.text("browser.support", fallback: "Browser extensions") }
    static var detail: String {
        L10n.text("browser.support.detail", fallback: "Send pages and links to your devices from Chrome, Edge, Firefox, Brave and Arc")
    }

    static func subtitle(_ display: BrowserSupportDisplay) -> String {
        switch display.problem {
        case .unavailable: return L10n.text("browser.support.unavailable", fallback: "Not available in this build")
        case .translocated: return L10n.text("browser.support.translocated", fallback: "Move Bridgey to Applications, open it again, then install")
        case .noBrowser: return L10n.text("browser.support.noBrowser", fallback: "No supported browser found. Install one, then choose Install again.")
        case .notListening: return L10n.text("browser.support.notListening", fallback: "Could not start. Quit and reopen Bridgey.")
        case nil:
            guard display.enabled, !display.browsers.isEmpty else { return detail }
            return String(format: L10n.text("browser.support.installed", fallback: "Installed for %@. Add the extension in each browser."),
                          ListFormatter.localizedString(byJoining: display.browsers))
        }
    }
}
