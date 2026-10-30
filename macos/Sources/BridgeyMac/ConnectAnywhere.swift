import AppKit
import CryptoKit
import Foundation

/// A tunnel the core brought up: the app connects to its loopback bridge and runs the session on it.
struct ConnectTunnel: Equatable {
    let id: String
    let port: UInt16
    let token: String
    /// Base64 TLS exporter, signed into the bridgey-auth-v2 transcript.
    let exporter: String
    var route: String
    var relay: String?
    /// The private network's name (`tailscale`) when the route is a VPN address.
    var vpn: String? = nil
    /// This side is the QUIC client: it sends pairing.offer.
    let quicClient: Bool
    /// The paired device the core dialled; nil for an inbound direct dial (the handshake says who).
    let peer: String?
}

/// A paired device as the core needs it.
struct ConnectPeer: Equatable {
    let id: String
    let side: Int
    let pairSecret: Data
    let addresses: [LearnedAddress]
    let connected: Bool

    var command: [String: Any] {
        ["id": id, "side": side, "pairSecret": pairSecret.base64EncodedString(), "connected": connected,
         "addresses": addresses.map { address -> [String: Any] in
             var entry: [String: Any] = ["a": address.a, "p": address.p, "kind": address.kind]
             if let vpn = address.vpn { entry["vpn"] = vpn }
             return entry
         }]
    }
}

/*
 * Connect anywhere on this Mac (docs/connect-anywhere.md): starts and stops the core with the setting,
 * signs the control service's challenge with the node key, keeps the core's list of paired devices
 * current and hands each tunnel to the pairing coordinator. On until chosen (Rahul, 2026-10-30, an exception to "off until chosen").
 */
@MainActor
final class ConnectAnywhere: ObservableObject {
    enum Presence: String {
        /// Not running (setting off, or no core in this build).
        case off
        /// Running without a control service: learned LAN and private network addresses only.
        case disabled
        case connecting
        /// The control service cannot be reached (no internet, or it is down); LAN and VPN still work.
        case unreachable
        case online
    }

    @Published private(set) var running = false
    @Published private(set) var presence: Presence = .off
    /// Paired devices the control service says are online.
    @Published private(set) var onlinePeers: Set<String> = []
    @Published private(set) var lastError: String?

    /// A tunnel is up; the coordinator runs a session on it.
    var onTunnel: ((ConnectTunnel) -> Void)?
    /// A tunnel moved to another route (ICE), or ended.
    var onRoute: ((String, String, String?) -> Void)?
    var onTunnelClosed: ((String) -> Void)?

    let store: ConnectStore
    private let library: ConnectLibrary?
    private var handle: UInt64?
    private(set) var udpPort: Int?
    private var pollFlag: PollFlag?
    private var activationObserver: NSObjectProtocol?
    private var lastPeers: [[String: Any]] = []

    init(store: ConnectStore = ConnectStore(), library: ConnectLibrary? = ConnectLibrary.shared()) {
        self.store = store
        self.library = library
    }

    /// This build has the core.
    var available: Bool { library != nil }

    /// The edition's control service (rr-edition.properties CONNECT_CONTROL_URL, through Info.plist),
    /// or the debug override (`defaults write in.roundrobin.bridgey BridgeyConnectControlURL <url>`).
    static var controlURL: String? {
        if let override = UserDefaults.standard.string(forKey: "BridgeyConnectControlURL"), !override.isEmpty { return override }
        let value = (Bundle.main.object(forInfoDictionaryKey: "BridgeyConnectControlURL") as? String)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    /// Debug: every route but the relay is blocked (`defaults write ... BridgeyConnectRelayOnly -bool true`).
    static var relayOnly: Bool { UserDefaults.standard.bool(forKey: "BridgeyConnectRelayOnly") }

    /// Shows the debug rows in Settings (`defaults write ... BridgeyConnectDebug -bool true`).
    static var debugEnabled: Bool { UserDefaults.standard.bool(forKey: "BridgeyConnectDebug") }

    /// Starts the core when the setting is on, stops it when off.
    func apply(enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    func start() {
        guard handle == nil, let library else { return }
        let key = store.nodeKey()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var config: [String: Any] = [
            "port": ReconnectPolicy.listeningPort,
            "app": "bridgey-rr/\(version) macos",
            "nodeKey": ConnectCrypto.base64URL(key.publicKey.x963Representation),
            "relayOnly": Self.relayOnly,
        ]
        if let url = Self.controlURL { config["controlUrl"] = url }
        let reply = library.start(config)
        guard reply["ok"] as? Bool == true, let started = (reply["handle"] as? NSNumber)?.uint64Value else {
            lastError = reply["error"] as? String ?? "start failed"
            BridgeyLog.transport.error("connect start failed error=\(self.lastError ?? "", privacy: .public)")
            return
        }
        handle = started
        udpPort = (reply["udpPort"] as? NSNumber)?.intValue
        running = true
        lastError = nil
        presence = Self.controlURL == nil ? .disabled : .connecting
        BridgeyLog.transport.notice("connect started udp=\(self.udpPort ?? 0, privacy: .public) control=\(Self.controlURL != nil, privacy: .public) relayOnly=\(Self.relayOnly, privacy: .public)")
        startPolling(library: library, handle: started)
        if !lastPeers.isEmpty { _ = library.command(started, ["c": "peers", "peers": lastPeers]) }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.command(["c": "foreground"]) }
        }
    }

    func stop() {
        guard let handle, let library else { return }
        self.handle = nil
        pollFlag?.stop()
        pollFlag = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        library.stop(handle)
        running = false
        presence = .off
        onlinePeers = []
        udpPort = nil
        BridgeyLog.transport.notice("connect stopped")
    }

    /// A new node key and a fresh start; the coordinator re-runs connect.setup with every peer.
    func resetIdentity() {
        let wasRunning = running
        stop()
        store.resetNodeKey()
        if wasRunning { start() }
    }

    @discardableResult
    func command(_ command: [String: Any]) -> [String: Any] {
        guard let handle, let library else { return ["ok": false, "error": "not running"] }
        return library.command(handle, command)
    }

    func network(_ reason: String) { command(["c": "network", "reason": reason]) }

    /// The paired devices the core may reach (those with a pair secret).
    func setPeers(_ peers: [ConnectPeer]) {
        let list = peers.map(\.command)
        lastPeers = list
        guard handle != nil else { return }
        let reply = command(["c": "peers", "peers": list])
        if reply["ok"] as? Bool != true { BridgeyLog.transport.error("connect peers refused error=\(reply["error"] as? String ?? "", privacy: .public)") }
    }

    /// This Mac's addresses for connect.addresses, and its UDP port.
    func localAddresses() -> (port: Int, addrs: [ConnectAddress])? {
        let reply = command(["c": "addresses"])
        guard reply["ok"] as? Bool == true, let port = (reply["port"] as? NSNumber)?.intValue,
              let list = reply["addrs"] as? [[String: Any]] else { return nil }
        let addrs = list.compactMap { entry -> ConnectAddress? in
            guard let a = entry["a"] as? String, let kind = entry["kind"] as? String, ConnectAddress.kinds.contains(kind) else { return nil }
            return ConnectAddress(a: a, kind: kind, vpn: entry["vpn"] as? String)
        }
        return (port, Array(addrs.prefix(ConnectAddresses.maximumEntries)))
    }

    func setRelayOnly(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "BridgeyConnectRelayOnly")
        command(["c": "debug", "relayOnly": on])
    }

    func status() -> [String: Any] { command(["c": "status"]) }

    // MARK: Events

    /// A thread blocks on the core's event queue and hands each event, in order, to the main actor.
    private func startPolling(library: ConnectLibrary, handle: UInt64) {
        let flag = PollFlag()
        pollFlag = flag
        let thread = Thread { [weak self] in
            while flag.running {
                guard let event = library.nextEvent(handle, timeoutMs: 500) else { continue }
                let box = EventBox(event)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard flag.running else { return }
                        self?.receive(box.event)
                    }
                }
            }
        }
        thread.name = "bridgey-connect-events"
        thread.start()
    }

    private func receive(_ event: [String: Any]) {
        // Core event names, dots read as underscores (they are not session message kinds).
        switch (event["e"] as? String)?.replacingOccurrences(of: ".", with: "_") {
        case "sign":
            let id = (event["id"] as? NSNumber)?.uint64Value ?? 0
            guard let data = (event["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let signature = try? store.nodeKey().signature(for: data) else {
                command(["c": "sign.result", "id": id])
                return
            }
            command(["c": "sign.result", "id": id, "sig": signature.derRepresentation.base64EncodedString()])
        case "presence":
            presence = Presence(rawValue: event["state"] as? String ?? "") ?? .connecting
            onlinePeers = Set(event["peers"] as? [String] ?? [])
        case "tunnel":
            guard let id = event["tunnel"] as? String, let port = (event["port"] as? NSNumber)?.uint16Value,
                  let token = event["token"] as? String, token.utf8.count == 64,
                  let exporter = event["exporter"] as? String, let route = event["route"] as? String else { return }
            let tunnel = ConnectTunnel(id: id, port: port, token: token, exporter: exporter, route: route,
                                       relay: event["relay"] as? String, vpn: event["vpn"] as? String,
                                       quicClient: event["quicClient"] as? Bool ?? false, peer: event["peer"] as? String)
            BridgeyLog.transport.notice("connect tunnel id=\(id, privacy: .public) route=\(route, privacy: .public) relay=\(tunnel.relay ?? "none", privacy: .public) client=\(tunnel.quicClient, privacy: .public) peer=\(tunnel.peer.map(shortDeviceID) ?? "unknown", privacy: .public) rttMs=\((event["rttMs"] as? NSNumber)?.intValue ?? -1, privacy: .public)")
            onTunnel?(tunnel)
        case "route":
            guard let id = event["tunnel"] as? String, let route = event["route"] as? String else { return }
            BridgeyLog.transport.notice("connect route id=\(id, privacy: .public) route=\(route, privacy: .public) relay=\(event["relay"] as? String ?? "none", privacy: .public)")
            onRoute?(id, route, event["relay"] as? String)
        case "tunnel_closed":
            guard let id = event["tunnel"] as? String else { return }
            BridgeyLog.transport.notice("connect tunnel closed id=\(id, privacy: .public) reason=\(event["reason"] as? String ?? "", privacy: .public)")
            onTunnelClosed?(id)
        case "connect_failed":
            BridgeyLog.transport.notice("connect failed peer=\((event["peer"] as? String).map(shortDeviceID) ?? "", privacy: .public) reason=\(event["reason"] as? String ?? "", privacy: .public)")
        case "log":
            BridgeyLog.transport.notice("connect core \(event["msg"] as? String ?? "", privacy: .public)")
        default:
            break
        }
    }
}

/// Tells the polling thread to end; read from that thread, set on the main actor.
private final class PollFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func stop() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

/// Moves one event dictionary from the polling thread to the main actor.
private final class EventBox: @unchecked Sendable {
    let event: [String: Any]
    init(_ event: [String: Any]) { self.event = event }
}
