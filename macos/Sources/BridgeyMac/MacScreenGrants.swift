import CryptoKit
import Foundation

/*
 * Mac screen to phone: who may see this Mac's screen (docs/protocol.md, "Negotiation and grants"). Off for every
 * phone until the person chooses Ask each time or Allow without asking for it here. Each grant is bound to the
 * phone's pinned identity key: a phone that pairs again with another key reads as Off. Kept in its own private
 * file next to the pairing file (folder 0700, file 0600, excluded from backups), never in settings sync, never sent
 * to a device; forgetting a phone removes its grant.
 */

enum MacScreenGrantMode: String, Codable, CaseIterable, Equatable {
    case off
    /// Every request shows a prompt on this Mac.
    case ask
    /// A persistent unattended grant, only for a phone picked explicitly.
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

    private struct Grant: Codable, Equatable {
        var mode: MacScreenGrantMode
        /// Hex SHA-256 of the identity key the grant was made for.
        var key: String
    }

    private struct File: Codable {
        var version: Int
        var grants: [String: Grant]
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    private var grants: [String: Grant] = [:]

    init(directory: URL = MacPairingStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    /// Off unless a grant exists for this device and was made for this identity key.
    func mode(for deviceID: String, identityKey: String?) -> MacScreenGrantMode {
        guard let identityKey, let grant = grants[deviceID], grant.key == Self.hex(screenIdentityDigest(identityKey)) else { return .off }
        return grant.mode
    }

    /// Every device with a grant other than Off, whatever its key (Settings shows a mismatch as Off).
    var deviceIDs: [String] { grants.filter { $0.value.mode != .off }.map(\.key).sorted() }

    /// Sets a device's choice for its current identity key. Off removes the grant.
    @discardableResult
    func set(_ mode: MacScreenGrantMode, for deviceID: String, identityKey: String) -> Bool {
        var next = grants
        if mode == .off {
            next.removeValue(forKey: deviceID)
        } else {
            next[deviceID] = Grant(mode: mode, key: Self.hex(screenIdentityDigest(identityKey)))
        }
        return save(next)
    }

    /// Forget: the grant goes with the device.
    @discardableResult
    func remove(_ deviceID: String) -> Bool {
        guard grants[deviceID] != nil else { return true }
        var next = grants
        next.removeValue(forKey: deviceID)
        return save(next)
    }

    /// Grants for devices no longer trusted go.
    func prune(keeping trusted: Set<String>) {
        let next = grants.filter { trusted.contains($0.key) }
        if next != grants { save(next) }
    }

    private func load() {
        do {
            try PairingFile.prepareDirectory(directory)
            PairingFile.removeStaleTemporaryFiles(in: directory, for: Self.fileName)
            guard let data = try PairingFile.readIfPresent(fileURL) else { return }
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.version == 1 else { return }
            grants = file.grants.filter { $0.value.mode != .off }
        } catch {
            // Unreadable means no grants: every phone is Off until chosen again.
            NSLog("SCREEN_GRANTS unreadable: %@", String(describing: error))
            grants = [:]
        }
    }

    @discardableResult
    private func save(_ next: [String: Grant]) -> Bool {
        do {
            try PairingFile.prepareDirectory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try PairingFile.writeAtomically(try encoder.encode(File(version: 1, grants: next)), to: fileURL)
            grants = next
            return true
        } catch {
            NSLog("SCREEN_GRANTS save failed: %@", String(describing: error))
            return false
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
