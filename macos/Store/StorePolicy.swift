import AppKit
import CryptoKit
import Foundation

/// Store scope is enforced on the wire as well as in the interface.
enum StorePolicy {
    static let identifier = "in.roundrobin.bridgey.store"
    static let features: [String: Bool] = [
        "clipboard": true, "files": true, "notifications": true,
        "battery": false, "find_device": false, "ping": false,
        "links": false, "media": false, "calls": false,
    ]
    static func permits(_ kind: String) -> Bool {
        ["features.update", "clipboard.update", "clipboard.rich", "clipboard.ack", "clipboard.rejected",
         "notifications.post", "notifications.remove", "files.offer", "files.accept", "files.rejected",
         "files.chunk", "files.chunk.ack", "files.complete", "files.complete.ack", "files.cancel", "files.cancel.ack",
         "heartbeat.ping", "heartbeat.pong"].contains(kind)
    }
    static func fileName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 240,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}

/// The store has its own container and identity. It never imports direct-download trust or preferences.
struct StoreIdentity: Codable {
    var deviceID: String
    var key: Data
    var trusted: [String: String]
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(StorePolicy.identifier, isDirectory: true).appendingPathComponent("identity.json")
    }
    static func load() throws -> Self {
        if FileManager.default.fileExists(atPath: file.path) {
            let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            _ = try P256.Signing.PrivateKey(rawRepresentation: value.key)
            guard UUID(uuidString: value.deviceID) != nil else { throw PairingError.invalidMessage }
            return value
        }
        let value = Self(deviceID: UUID().uuidString.lowercased(), key: P256.Signing.PrivateKey().rawRepresentation, trusted: [:])
        try value.save()
        return value
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}
