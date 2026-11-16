import dnssd
import Foundation
import Network

/// A Bridgey device Bonjour found and resolved to an IPv4 address.
struct FoundDevice: Equatable, Sendable {
    /// The Bonjour service ("name._bridgey._tcp.local.").
    let service: String
    /// TXT `id`: a hint until the device authenticates.
    var deviceID: String?
    var name: String
    var platform: String?
    var host: String
    var port: UInt16
}

/// How browsing is going. `denied` means Local Network access is off for Bridgey.
enum DiscoveryHealth: Equatable, Sendable {
    case idle, browsing, denied, failed
}

/// Finds Bridgey devices with Network.framework and advertises this one with DNS-SD, using only what iOS allows
/// without the multicast entitlement: NSBonjourServices lists `_bridgey._tcp`, and the system asks the person for
/// Local Network access the first time. bridgey_core then dials the addresses it is given.
@MainActor
final class BonjourDiscovery {
    static let serviceType = "_bridgey._tcp"

    var onFound: (FoundDevice) -> Void = { _ in }
    var onLost: (FoundDevice) -> Void = { _ in }
    var onHealth: (DiscoveryHealth) -> Void = { _ in }

    private let ownDeviceID: String
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    private var found: [String: FoundDevice] = [:]
    private var registration: DNSServiceRef?

    init(ownDeviceID: String) {
        self.ownDeviceID = ownDeviceID
    }

    func start() {
        stopBrowsing()
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.browserState(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            Task { @MainActor in self?.changed(changes) }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    /// A fresh browser asks the network again at once (a long-running one backs off).
    func restart() {
        start()
    }

    func stop() {
        stopBrowsing()
        stopAdvertising()
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving.removeAll()
        for device in found.values { onLost(device) }
        found.removeAll()
    }

    private func browserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            onHealth(.browsing)
        case let .waiting(error), let .failed(error):
            if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                onHealth(.denied)
            } else {
                onHealth(.failed)
            }
        default:
            break
        }
    }

    private func changed(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case let .added(result): resolve(result)
            case let .changed(old: _, new: result, flags: _): resolve(result)
            case let .removed(result):
                guard let key = Self.key(result.endpoint) else { continue }
                resolving.removeValue(forKey: key)?.cancel()
                if let device = found.removeValue(forKey: key) { onLost(device) }
            default:
                break
            }
        }
    }

    private static func key(_ endpoint: NWEndpoint) -> String? {
        guard case let .service(name, type, domain, _) = endpoint else { return nil }
        return "\(name).\(type).\(domain)"
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case let .service(serviceName, _, _, _) = result.endpoint, let key = Self.key(result.endpoint) else { return }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata { txt = record.dictionary }
        let deviceID = txt["id"].flatMap { UUID(uuidString: $0) == nil ? nil : $0.lowercased() }
        if deviceID == ownDeviceID { return }
        let name = txt["name"].flatMap { $0.isEmpty ? nil : String($0.prefix(64)) } ?? String(serviceName.prefix(64))
        let platform = txt["platform"].flatMap { $0.range(of: "^[a-z][a-z0-9-]{0,15}$", options: .regularExpression) == nil ? nil : $0 }
        // A UDP "connection" resolves the service to an address without sending anything to the device.
        let parameters = NWParameters.udp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: result.endpoint, using: parameters)
        resolving.removeValue(forKey: key)?.cancel()
        resolving[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                let endpoint = connection.currentPath?.remoteEndpoint
                connection.cancel()
                guard case let .hostPort(host, port)? = endpoint, case let .ipv4(address) = host else { return }
                let text = address.rawValue.map(String.init).joined(separator: ".")
                let device = FoundDevice(service: key, deviceID: deviceID, name: name, platform: platform, host: text, port: port.rawValue)
                Task { @MainActor in self?.resolved(device, by: connection) }
            case .failed, .cancelled:
                Task { @MainActor in self?.finished(key, connection) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        // Resolution that never finishes is given up quietly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak connection] in connection?.cancel() }
    }

    private func resolved(_ device: FoundDevice, by connection: NWConnection) {
        guard resolving[device.service] === connection else { return }
        resolving[device.service] = nil
        if let old = found[device.service], old.host != device.host || old.port != device.port { onLost(old) }
        found[device.service] = device
        onFound(device)
    }

    private func finished(_ key: String, _ connection: NWConnection) {
        if resolving[key] === connection { resolving[key] = nil }
    }

    // MARK: Advertising

    /// Publishes this device so phones and computers on the network can find and pair with it.
    func advertise(name: String, port: UInt16) {
        stopAdvertising()
        let instance = String(decoding: Array(name.utf8.prefix(63)), as: UTF8.self)
        var txt = Data()
        for (key, value) in [("id", ownDeviceID), ("name", String(decoding: Array(name.utf8.prefix(64)), as: UTF8.self)), ("version", "1"), ("platform", "ios")] {
            let entry = Array("\(key)=\(value)".utf8.prefix(255))
            txt.append(UInt8(entry.count))
            txt.append(contentsOf: entry)
        }
        var ref: DNSServiceRef?
        let error = txt.withUnsafeBytes { raw in
            DNSServiceRegister(&ref, 0, 0, instance, Self.serviceType, nil, nil, port.bigEndian, UInt16(raw.count), raw.baseAddress, nil, nil)
        }
        guard error == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, .main)
        registration = ref
    }

    func stopAdvertising() {
        if let registration { DNSServiceRefDeallocate(registration) }
        registration = nil
    }
}
