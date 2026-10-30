import CryptoKit
import Foundation

/// A learned address of a paired device (connect.addresses), with when it was last reported.
struct LearnedAddress: Codable, Equatable {
    let a: String
    let p: Int
    let kind: String
    var vpn: String?
    var seen: Date
}

/*
 * Connect anywhere's private state on this Mac: the node key (P-256, only for the control service,
 * never the identity key), each paired device's pair secret, and the addresses each device reported.
 *
 * Stored in `connect-v1.json` next to the pairing file (folder 0700, file 0600, excluded from
 * backups), for the same reason the pairing file is: an app without an Apple-issued certificate gets
 * a new Keychain partition with every build, so Keychain items would ask for the login password
 * after each update (docs/rr-mac-signing.md).
 */
final class ConnectStore {
    static let fileName = "connect-v1.json"
    static let maximumAddresses = 16
    static let addressLifetime: TimeInterval = 30 * 24 * 3_600

    private struct File: Codable {
        var version = 1
        var nodeKey: String?
        var pairSecrets: [String: String] = [:]
        var addresses: [String: [LearnedAddress]] = [:]
    }

    private let directory: URL
    private var file = File()

    init(directory: URL = MacPairingStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private func load() {
        do {
            try PairingFile.prepareDirectory(directory)
            PairingFile.removeStaleTemporaryFiles(in: directory, for: Self.fileName)
            guard let data = try PairingFile.readIfPresent(fileURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            file = try decoder.decode(File.self, from: data)
        } catch {
            BridgeyLog.transport.error("connect store unreadable error=\(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try PairingFile.prepareDirectory(directory)
            try PairingFile.writeAtomically(try encoder.encode(file), to: fileURL)
        } catch {
            BridgeyLog.transport.error("connect store not saved error=\(String(describing: error), privacy: .public)")
        }
    }

    /// The node key, made on first use.
    func nodeKey() -> P256.Signing.PrivateKey {
        if let text = file.nodeKey, let raw = Data(base64Encoded: text), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        return resetNodeKey()
    }

    /// "Reset away-from-home identity": a new node key.
    @discardableResult
    func resetNodeKey() -> P256.Signing.PrivateKey {
        let key = P256.Signing.PrivateKey()
        file.nodeKey = key.rawRepresentation.base64EncodedString()
        save()
        return key
    }

    func pairSecret(_ deviceID: String) -> Data? {
        file.pairSecrets[deviceID].flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? $0 : nil }
    }

    func setPairSecret(_ secret: Data, for deviceID: String) {
        file.pairSecrets[deviceID] = secret.base64EncodedString()
        save()
    }

    /// Newest first, unexpired, at most 16.
    func addresses(_ deviceID: String, now: Date = Date()) -> [LearnedAddress] {
        (file.addresses[deviceID] ?? []).filter { now.timeIntervalSince($0.seen) < Self.addressLifetime }
    }

    /// The device reported these addresses: they replace the old ones (T3's rule), newest first.
    func learn(_ deviceID: String, port: Int, addresses: [ConnectAddress], now: Date = Date()) {
        let fresh = addresses.prefix(Self.maximumAddresses).map { LearnedAddress(a: $0.a, p: port, kind: $0.kind, vpn: $0.vpn, seen: now) }
        file.addresses[deviceID] = Array(fresh)
        save()
    }

    /// Forget device: the pair secret and the learned addresses go.
    func forget(_ deviceID: String) {
        file.pairSecrets.removeValue(forKey: deviceID)
        file.addresses.removeValue(forKey: deviceID)
        save()
    }

    /// Local data reset.
    func deleteAll() {
        file = File()
        unlink(fileURL.path)
    }
}
