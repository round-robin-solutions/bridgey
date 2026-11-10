import Foundation

let maximumProtocolFrameBytes = 65_536

struct PairingMessage: Codable {
    let kind: String
    let sessionId: String
    var deviceId: String? = nil
    var deviceName: String? = nil
    var publicKey: String? = nil
    var identityKey: String? = nil
    var proof: String? = nil
    var signature: String? = nil
    var messageId: String? = nil
    var nonce: String? = nil
    var ciphertext: String? = nil
    var transferId: String? = nil
    var sequence: Int64? = nil
    /// On a reconnect offer: the trusted device it is meant for. Any other device declines quietly.
    var targetDeviceId: String? = nil
    /// Protocol 2 first pairing: SHA-256 commitment to the offer's ephemeral key, revealed in pairing.reveal.
    var commitment: String? = nil
    /// In pairing.offer and pairing.answer: the highest protocol version the sender speaks (absent means 1).
    var protocolVersion: Int64? = nil
    /// Protocol 2: HMAC over the envelope, see SessionSecurity.tag.
    var tag: String? = nil
    /// In pairing.cancel: why, one of PairingCancelReason (absent from older peers).
    var reason: String? = nil
}

enum PairingError: Error { case invalidMessage, cancelled }

