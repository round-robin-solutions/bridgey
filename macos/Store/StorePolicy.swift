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

#if DEBUG
/// The same boundary cases as StoreBoundaryTests, for Apple's CLT-only fleet hosts without XCTest.
enum StoreBoundaryChecks {
    static func run() -> Bool {
        let excluded = ["remote_input.event", "media.command", "handoff.takeover", "updates.start", "sms.send", "actions.run", "screen.start", "settings.update", "camera.request", "agent.ask"]
        let capabilities = excluded.allSatisfy { !StorePolicy.permits($0) }
            && Set(StorePolicy.features.filter(\.value).keys) == Set(["files", "clipboard", "notifications"])
        let filenames = ["../escape", "/etc/passwd", "..", "folder/file", "a\\b", "a:b", "bad\0name"].allSatisfy { StorePolicy.fileName($0) == nil }
            && StorePolicy.fileName("Report.pdf") == "Report.pdf"
        let key = Data(repeating: 7, count: 32)
        var message = PairingMessage(kind: "clipboard.update", sessionId: "session", messageId: "message")
        message.tag = SessionSecurity.tag(envelopeKey: key, senderDeviceID: "phone", message: message)
        let integrity = SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: "phone", message: message)
            && !SessionSecurity.tagMatches(envelopeKey: key, senderDeviceID: "other", message: message)
        print("Store boundary checks: capabilities=\(capabilities), filenames=\(filenames), envelope=\(integrity)")
        return capabilities && filenames && integrity
    }
}
#endif
