import CryptoKit
import Foundation

/*
 * Mac screen to phone: who may see this Mac's screen (docs/protocol.md, "Negotiation and grants";
 * docs/screen-control-decision.md, 26 Nov). One switch, Unattended access, on by default: a paired device with no
 * choice of its own may see this screen without asking while it is on, and not at all while it is off. Each device
 * can still be set to Off, Ask each time or Allow without asking, and that choice wins over the switch. Servers and
 * agents never get anything, whatever the switch or a stored choice says. Each choice is bound to the device's pinned
 * identity key: a device that pairs again with another key has no choice of its own and follows the switch, like a
 * newly paired device. The switch and the choices live in their own private file next to the pairing file (folder
 * 0700, file 0600, excluded from backups), never in settings sync, never sent to a device; forgetting a device removes
 * its choice.
 */

enum MacScreenGrantMode: String, Codable, CaseIterable, Equatable {
    case off
    /// Every request shows a prompt on this Mac.
    case ask
    /// A persistent unattended grant: requests start without a prompt (the indicator and Stop still show).
    case always

    /// Off, then Ask each time, then Allow without asking.
    var rank: Int {
        switch self {
        case .off: 0
        case .ask: 1
        case .always: 2
        }
    }
}

/// SHA-256 of a pinned identity key (the base64 text as stored by the trust registry, decoded when it is base64).
func screenIdentityDigest(_ identityKey: String) -> [UInt8] {
    let bytes = Data(base64Encoded: identityKey) ?? Data(identityKey.utf8)
    return Array(SHA256.hash(data: bytes))
}

final class MacScreenGrants {
    static let fileName = "screen-grants-v1.json"
    /// Unattended access while nobody chose (Rahul, 26 Nov: on by default).
    static let unattendedDefault = true

    private struct Grant: Codable, Equatable {
        var mode: MacScreenGrantMode
        /// Hex SHA-256 of the identity key the choice was made for.
        var key: String
    }

    /// One stored entry: a grant that does not decode (an unknown mode, a bad key) is dropped on its own.
    private struct StoredGrant: Decodable {
        let grant: Grant?

        init(from decoder: Decoder) throws {
            let decoded = try? Grant(from: decoder)
            grant = decoded.flatMap { MacScreenGrants.validDigest($0.key) ? $0 : nil }
        }
    }

    private struct StoredFile: Decodable {
        var version: Int
        /// Missing in files written before unattended access (1.0 Beta 5 to Beta 9): on.
        var unattended: Bool?
        var grants: [String: StoredGrant]?
    }

    private struct File: Encodable {
        var version: Int
        var unattended: Bool
        var grants: [String: Grant]
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    private var grants: [String: Grant] = [:]
    /// Unattended access: what a device with no choice of its own gets (Allow without asking when on, Off when off).
    private(set) var unattended = MacScreenGrants.unattendedDefault

    init(directory: URL = MacPairingStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    /// What a device gets. A server or agent (restricted) never gets anything, nor does a device without a pinned key;
    /// an explicit choice for the current key wins; otherwise the switch decides.
    static func resolve(explicit: MacScreenGrantMode?, unattended: Bool, restricted: Bool, keyKnown: Bool) -> MacScreenGrantMode {
        if restricted || !keyKnown { return .off }
        if let explicit { return explicit }
        return unattended ? .always : .off
    }

    /// The device's own choice for this identity key; nil when it has none (it follows Unattended access).
    func explicitMode(for deviceID: String, identityKey: String?) -> MacScreenGrantMode? {
        guard let identityKey, let grant = grants[deviceID], grant.key == Self.hex(screenIdentityDigest(identityKey)) else { return nil }
        return grant.mode
    }

    /// What the device gets, ignoring whether it is restricted (MacScreenShare checks that).
    func mode(for deviceID: String, identityKey: String?, restricted: Bool = false) -> MacScreenGrantMode {
        Self.resolve(explicit: explicitMode(for: deviceID, identityKey: identityKey), unattended: unattended, restricted: restricted,
                     keyKnown: identityKey != nil)
    }

    /// Sets a device's choice for its current identity key. Nil removes it: the device follows Unattended access again.
    @discardableResult
    func set(_ mode: MacScreenGrantMode?, for deviceID: String, identityKey: String) -> Bool {
        var next = grants
        if let mode {
            next[deviceID] = Grant(mode: mode, key: Self.hex(screenIdentityDigest(identityKey)))
        } else {
            next.removeValue(forKey: deviceID)
        }
        return save(next, unattended: unattended)
    }

    /// Turns Unattended access on or off. Explicit choices stay as they are.
    @discardableResult
    func setUnattended(_ on: Bool) -> Bool {
        save(grants, unattended: on)
    }

    /// Forget: the choice goes with the device.
    @discardableResult
    func remove(_ deviceID: String) -> Bool {
        guard grants[deviceID] != nil else { return true }
        var next = grants
        next.removeValue(forKey: deviceID)
        return save(next, unattended: unattended)
    }

    /// Choices for devices no longer trusted go.
    func prune(keeping trusted: Set<String>) {
        let next = grants.filter { trusted.contains($0.key) }
        if next != grants { save(next, unattended: unattended) }
    }

    private func load() {
        do {
            try PairingFile.prepareDirectory(directory)
            PairingFile.removeStaleTemporaryFiles(in: directory, for: Self.fileName)
            // No file yet: the defaults (Unattended access on, no choices).
            guard let data = try PairingFile.readIfPresent(fileURL) else { return }
            let file = try JSONDecoder().decode(StoredFile.self, from: data)
            guard file.version == 1 else { return failClosed("version \(file.version)") }
            grants = (file.grants ?? [:]).compactMapValues(\.grant)
            unattended = file.unattended ?? Self.unattendedDefault
        } catch {
            failClosed(String(describing: error))
        }
    }

    /// A file that exists but cannot be read grants nothing: Unattended access off and no choices, until the next save
    /// writes a good file again.
    private func failClosed(_ why: String) {
        NSLog("SCREEN_GRANTS unreadable: %@", why)
        grants = [:]
        unattended = false
    }

    @discardableResult
    private func save(_ next: [String: Grant], unattended on: Bool) -> Bool {
        do {
            try PairingFile.prepareDirectory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PairingFile.writeAtomically(try encoder.encode(File(version: 1, unattended: on, grants: next)), to: fileURL)
            grants = next
            unattended = on
            return true
        } catch {
            NSLog("SCREEN_GRANTS save failed: %@", String(describing: error))
            return false
        }
    }

    private static func validDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
