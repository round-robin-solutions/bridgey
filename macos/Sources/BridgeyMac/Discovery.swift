import Foundation
import os

enum LegacyPreferences {
    static func migrateIfNeeded() {
        let current = UserDefaults.standard
        guard !current.bool(forKey: "legacyPreferencesMigrated"),
              let suiteName = Edition.legacyPreferencesSuite,
              let legacy = UserDefaults(suiteName: suiteName) else { return }
        if let deviceID = legacy.string(forKey: "deviceID"), UUID(uuidString: deviceID) != nil {
            current.set(deviceID, forKey: "deviceID")
        }
        let trustedIDs = legacy.stringArray(forKey: "trustedDeviceIDs") ?? []
        if !trustedIDs.isEmpty {
            _ = MacTrustRegistry(migrating: [legacy])
        }
        current.set(true, forKey: "legacyPreferencesMigrated")
    }
}

struct DiscoveredPeer: Identifiable, Equatable {
    let serviceName: String
    let deviceIDHint: String?
    let deviceNameHint: String
    let platformHint: String?
    let protocolVersionHint: Int?
    var host: String?
    var port: Int?
    /// Resolved IP addresses (IPv4 first; link-local IPv6 left out). Dialling an IP works even
    /// when mDNS name lookups do not.
    var addresses: [String] = []

    var id: String { serviceName }
}

enum DiscoveryTXTRecord {
    static func parse(serviceName: String, attributes: [String: Data]) -> DiscoveredPeer {
        let id = decode(attributes["id"], limit: 36).flatMap {
            UUID(uuidString: $0) == nil ? nil : $0.lowercased()
        }
        let decodedName = decode(attributes["name"], limit: 64)
        let name = decodedName?.isEmpty == false ? decodedName! : String(serviceName.prefix(64))
        let platform = decode(attributes["platform"], limit: 16).flatMap {
            $0.range(of: "^[a-z][a-z0-9-]{0,15}$", options: .regularExpression) == nil ? nil : $0
        }
        let version = decode(attributes["version"], limit: 8)
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
        return DiscoveredPeer(
            serviceName: serviceName,
            deviceIDHint: id,
            deviceNameHint: name,
            platformHint: platform,
            protocolVersionHint: version,
            host: nil,
            port: nil
        )
    }

    private static func decode(_ data: Data?, limit: Int) -> String? {
        guard let data, !data.isEmpty, data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
final class BonjourDiscovery: NSObject, ObservableObject {
    static let serviceType = "_bridgey._tcp."
    static let defaultPort = Int32(TestInstance.listeningPort)

    @Published private(set) var peers: [DiscoveredPeer] = []
    /// Connection health: browsing, stopped, or refused (Local Network access off, or mDNS failed).
    @Published private(set) var health: DiscoveryHealth = .stopped

    /// A fresh browser per run: a restarted NetServiceBrowser sends new queries straight away,
    /// where a long-running one backs off to about one query an hour (RFC 6762, section 5.2).
    private var browser: NetServiceBrowser?
    private var publishedService: NetService?
    private var services: [String: NetService] = [:]
    private var isRunning = false
    private var restartWorkItem: DispatchWorkItem?
    private var pruneWorkItem: DispatchWorkItem?
    /// Services resolved since the last restart; peers not among them are dropped after a grace
    /// period, so a restart never makes devices blink out of the panel.
    private var refreshed = Set<String>()
    private let deviceID: String
    private var deviceName: String
    var localDeviceID: String { deviceID }
    var localDeviceName: String { deviceName }
    private lazy var ownServiceName = "Bridgey-\(deviceID.prefix(8))"
    /// Called after each restart, with the reason (for diagnostics).
    var onRestart: ((String) -> Void)?

    init(deviceName preferredName: String? = nil) {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: "deviceID"), UUID(uuidString: stored) != nil {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: "deviceID")
        }
        deviceName = preferredName ?? Host.current().localizedName ?? "Mac"
        super.init()
        start()
    }

    func updateDeviceName(_ value: String) {
        let name = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty, name != deviceName else { return }
        deviceName = name
        if isRunning { restart(reason: "rename") }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        begin()
        BridgeyLog.discovery.notice("browsing started")
    }

    func stop() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        pruneWorkItem?.cancel()
        pruneWorkItem = nil
        guard isRunning else { return }
        isRunning = false
        tearDown()
        peers.removeAll()
        health = .stopped
        BridgeyLog.discovery.notice("browsing stopped")
    }

    /// Stops browsing and publishing, then starts both again: this Mac announces itself afresh
    /// and asks the network again, instead of waiting for a long-running browse to re-query.
    /// Peers stay listed meanwhile; any not seen again within a few seconds are dropped.
    /// Repeated calls while a restart is pending collapse into one.
    func restart(reason: String) {
        guard isRunning else {
            start()
            return
        }
        guard restartWorkItem == nil else { return }
        BridgeyLog.discovery.notice("restart reason=\(reason, privacy: .public)")
        tearDown()
        pruneWorkItem?.cancel()
        refreshed.removeAll()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.restartWorkItem = nil
            self.begin()
            self.onRestart?(reason)
            let prune = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pruneWorkItem = nil
                let gone = self.peers.filter { !self.refreshed.contains($0.serviceName) }
                guard !gone.isEmpty else { return }
                self.peers.removeAll { !self.refreshed.contains($0.serviceName) }
                BridgeyLog.discovery.notice("restart dropped peers=\(gone.count, privacy: .public)")
            }
            self.pruneWorkItem = prune
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: prune)
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func begin() {
        health = .browsing
        publish()
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        self.browser = browser
    }

    private func tearDown() {
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        publishedService?.delegate = nil
        publishedService?.stop()
        publishedService = nil
        services.values.forEach { $0.delegate = nil; $0.stop() }
        services.removeAll()
    }

    private func publish() {
        let service = NetService(
            domain: "local.",
            type: Self.serviceType,
            name: ownServiceName,
            port: Self.defaultPort
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "id": Data(deviceID.utf8),
            "name": Data(String(deviceName.prefix(64)).utf8),
            "version": Data("1".utf8),
            "platform": Data("macos".utf8),
        ]))
        service.publish()
        publishedService = service
    }

    private func isOwn(_ service: NetService) -> Bool {
        service === publishedService || service.name == ownServiceName
    }

    private func accept(_ service: NetService) {
        guard isRunning, !isOwn(service) else { return }
        let attributes = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        var peer = DiscoveryTXTRecord.parse(serviceName: service.name, attributes: attributes)
        // A renamed copy of this Mac's own service (name conflict after a restart) is not a peer.
        guard peer.deviceIDHint != deviceID else { return }
        peer.host = service.hostName
        peer.port = service.port > 0 ? service.port : nil
        peer.addresses = Self.ipAddresses(service.addresses ?? [])
        refreshed.insert(service.name)
        let otherPeers = peers.filter { $0.id != peer.id }
        peers = (otherPeers + [peer]).sorted { $0.deviceNameHint.localizedCaseInsensitiveCompare($1.deviceNameHint) == .orderedAscending }
        BridgeyLog.discovery.notice("peer discovered service=\(service.name, privacy: .public) addresses=\(peer.addresses.count, privacy: .public)")
    }

    /// IP literals from resolved socket addresses: IPv4 first, then IPv6 that is not link-local.
    nonisolated static func ipAddresses(_ data: [Data]) -> [String] {
        var v4: [String] = []
        var v6: [String] = []
        for item in data {
            item.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr>.size else { return }
                let family = raw.loadUnaligned(as: sockaddr.self).sa_family
                if family == sa_family_t(AF_INET), raw.count >= MemoryLayout<sockaddr_in>.size {
                    var address = raw.loadUnaligned(as: sockaddr_in.self).sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        v4.append(String(cString: buffer))
                    }
                } else if family == sa_family_t(AF_INET6), raw.count >= MemoryLayout<sockaddr_in6>.size {
                    var address = raw.loadUnaligned(as: sockaddr_in6.self).sin6_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        let text = String(cString: buffer)
                        if !text.lowercased().hasPrefix("fe80") { v6.append(text) }
                    }
                }
            }
        }
        var seen = Set<String>()
        return (v4 + v6).filter { seen.insert($0).inserted }
    }
}

extension BonjourDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            guard browser === self.browser, !isOwn(service) else { return }
            services[service.name]?.stop()
            services[service.name] = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            guard browser === self.browser else { return }
            services.removeValue(forKey: service.name)
            peers.removeAll { $0.serviceName == service.name }
            BridgeyLog.discovery.notice("peer lost service=\(service.name, privacy: .public)")
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        BridgeyLog.discovery.error("browse failed code=\(code, privacy: .public)")
        Task { @MainActor in
            guard browser === self.browser else { return }
            health = .denied
        }
    }
}

extension BonjourDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in accept(sender) }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        BridgeyLog.discovery.notice("resolve failed service=\(sender.name, privacy: .public) code=\(code, privacy: .public)")
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        BridgeyLog.discovery.notice("service published name=\(sender.name, privacy: .public)")
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        BridgeyLog.discovery.error("publish failed code=\(code, privacy: .public)")
    }
}
