import CryptoKit
import Foundation

func remoteNotificationRequestIdentifier(deviceID: String, notificationID: String) -> String {
    let digest = SHA256.hash(data: Data("\(deviceID)\u{0}\(notificationID)".utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return "bridgey.android.\(digest)"
}

func remoteNotificationCategoryIdentifier(deviceID: String, notificationID: String, actionTokens: [String]) -> String {
    let value = ([deviceID, notificationID] + actionTokens).joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return "bridgey.android.actions.\(digest)"
}

let maximumRemoteNotificationIconBytes = 20 * 1024

func remoteNotificationIconData(_ encoded: String?) -> Data? {
    guard let encoded,
          encoded.count <= 28 * 1024,
          let data = Data(base64Encoded: encoded),
          !data.isEmpty,
          data.count <= maximumRemoteNotificationIconBytes,
          data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { return nil }
    return data
}

func remoteNotificationIconFileName(packageName: String, data: Data) -> String {
    var input = Data(packageName.utf8)
    input.append(0)
    input.append(data)
    let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    return "\(digest).png"
}

struct AlertedNotificationIdentifiers {
    private let capacity: Int
    private var order: [String] = []
    private var members = Set<String>()
    private var events: [String: String] = [:]
    private var devices: [String: String] = [:]

    init(capacity: Int = 512) {
        self.capacity = capacity
    }

    /// Last-alerted message identity has the sound cache's lifetime, independent of session tickets.
    mutating func insert(_ identifier: String, eventID: String? = nil, deviceID: String? = nil) -> Bool {
        if let deviceID { devices[identifier] = deviceID }
        guard members.insert(identifier).inserted else {
            guard let eventID else { return false }
            let previous = events.updateValue(eventID, forKey: identifier)
            // Adopting the first event identity for a legacy alert cannot replay that old alert.
            return previous.map { $0 != eventID } ?? false
        }
        if let eventID { events[identifier] = eventID }
        order.append(identifier)
        if order.count > capacity {
            let evicted = order.removeFirst()
            members.remove(evicted); events.removeValue(forKey: evicted); devices.removeValue(forKey: evicted)
        }
        return true
    }

    mutating func remove(_ identifier: String) {
        guard members.remove(identifier) != nil else { return }
        order.removeAll { $0 == identifier }
        events.removeValue(forKey: identifier)
        devices.removeValue(forKey: identifier)
    }

    mutating func remove(deviceID: String) {
        let identifiers = devices.filter { $0.value == deviceID }.map(\.key)
        for identifier in identifiers { remove(identifier) }
    }
}
