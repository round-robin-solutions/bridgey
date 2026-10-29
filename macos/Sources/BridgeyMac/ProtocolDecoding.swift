import Foundation

/// Bridgey Protocol v1 decoding shared by the session and the tests: framing, nesting, replay and the
/// payload decoders that `protocol/test-vectors/protocol-v1.json` pins for both platforms. The rules
/// are in docs/protocol-contract.md.

/// The deepest JSON nesting a frame may have (the outer object counts as 1).
let maximumProtocolJSONDepth = 32

/// True when `data` is one strict RFC 8259 JSON object nested at most `maxDepth` deep. JSONSerialization
/// alone also takes a trailing comma, which Android's decoder rejects; both platforms check this first so
/// they accept exactly the same frames (Android: isStrictJsonObject in ProtocolDecoding.kt).
func isStrictJSONObject(_ data: Data, maxDepth: Int = maximumProtocolJSONDepth) -> Bool {
    var parser = StrictJSON(bytes: [UInt8](data), maxDepth: maxDepth)
    return parser.objectDocument()
}

private struct StrictJSON {
    let bytes: [UInt8]
    let maxDepth: Int
    var index = 0
    var depth = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    mutating func objectDocument() -> Bool {
        skipSpace()
        guard peek == 0x7B, value() else { return false }
        skipSpace()
        return index == bytes.count
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipSpace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    private mutating func value() -> Bool {
        skipSpace()
        switch peek {
        case 0x7B: return container(close: 0x7D, object: true)
        case 0x5B: return container(close: 0x5D, object: false)
        case 0x22: return string()
        case 0x74: return literal("true")
        case 0x66: return literal("false")
        case 0x6E: return literal("null")
        default: return number()
        }
    }

    private mutating func container(close: UInt8, object: Bool) -> Bool {
        depth += 1
        guard depth <= maxDepth else { return false }
        index += 1
        skipSpace()
        if peek == close {
            index += 1
            depth -= 1
            return true
        }
        while true {
            skipSpace()
            if object {
                guard string() else { return false }
                skipSpace()
                guard peek == 0x3A else { return false }
                index += 1
            }
            guard value() else { return false }
            skipSpace()
            switch peek {
            case 0x2C: index += 1
            case close:
                index += 1
                depth -= 1
                return true
            default: return false
            }
        }
    }

    private mutating func literal(_ word: String) -> Bool {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { return false }
        index += expected.count
        return true
    }

    private func isDigit(_ byte: UInt8?) -> Bool { byte.map { (0x30...0x39).contains($0) } ?? false }

    private mutating func number() -> Bool {
        let start = index
        if peek == 0x2D { index += 1 }
        if peek == 0x30 {
            index += 1
        } else if let byte = peek, (0x31...0x39).contains(byte) {
            while isDigit(peek) { index += 1 }
        } else {
            return false
        }
        if peek == 0x2E {
            index += 1
            guard isDigit(peek) else { return false }
            while isDigit(peek) { index += 1 }
        }
        if peek == 0x65 || peek == 0x45 {
            index += 1
            if peek == 0x2B || peek == 0x2D { index += 1 }
            guard isDigit(peek) else { return false }
            while isDigit(peek) { index += 1 }
        }
        return index > start
    }

    private mutating func string() -> Bool {
        guard peek == 0x22 else { return false }
        index += 1
        while let byte = peek {
            index += 1
            switch byte {
            case 0x22: return true
            case 0x00..<0x20: return false
            case 0x5C:
                switch peek {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: index += 1
                case 0x75:
                    guard let unit = hex() else { return false }
                    if (0xDC00...0xDFFF).contains(unit) { return false }
                    if (0xD800...0xDBFF).contains(unit) {
                        guard peek == 0x5C else { return false }
                        index += 1
                        guard let low = hex(), (0xDC00...0xDFFF).contains(low) else { return false }
                    }
                default: return false
                }
            default: break
            }
        }
        return false
    }

    /// After a backslash: `uXXXX`, returning the code unit.
    private mutating func hex() -> Int? {
        guard peek == 0x75, index + 5 <= bytes.count,
              let unit = Int(String(decoding: bytes[index + 1..<index + 5], as: UTF8.self), radix: 16),
              bytes[index + 1..<index + 5].allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        index += 5
        return unit
    }
}

/// Decodes one frame (without its LF) into a message, or throws when the frame must close the session:
/// empty or over 65,536 bytes, nested deeper than 32, not a JSON object, `kind` missing or over 64 bytes,
/// `sessionId` missing, over 128 bytes or empty (except in `pairing.cancel`), or an envelope field of the
/// wrong type. Unknown fields are ignored; an empty optional string counts as absent.
func decodeProtocolMessage(_ data: Data) throws -> PairingMessage {
    guard !data.isEmpty, data.count <= maximumProtocolFrameBytes, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw PairingError.invalidMessage
    }
    func string(_ key: String) throws -> String? {
        switch object[key] {
        case nil, is NSNull: return nil
        case let value as String: return value
        default: throw PairingError.invalidMessage
        }
    }
    func optional(_ key: String) throws -> String? { try string(key).flatMap { $0.isEmpty ? nil : $0 } }
    guard let kind = try string("kind"), !kind.isEmpty, kind.utf8.count <= 64,
          let sessionId = try string("sessionId"), sessionId.utf8.count <= 128,
          !sessionId.isEmpty || kind == "pairing.cancel" else {
        throw PairingError.invalidMessage
    }
    var sequence: Int64?
    switch object["sequence"] {
    case nil, is NSNull: sequence = nil
    case let value:
        guard let integer = jsonInteger(value) else { throw PairingError.invalidMessage }
        sequence = Int64(integer)
    }
    var protocolVersion: Int64?
    switch object["protocolVersion"] {
    case nil, is NSNull: protocolVersion = nil
    case let value:
        guard let integer = jsonInteger(value) else { throw PairingError.invalidMessage }
        protocolVersion = Int64(integer)
    }
    return PairingMessage(
        kind: kind,
        sessionId: sessionId,
        deviceId: try optional("deviceId"),
        deviceName: try optional("deviceName"),
        publicKey: try optional("publicKey"),
        identityKey: try optional("identityKey"),
        proof: try optional("proof"),
        signature: try optional("signature"),
        messageId: try optional("messageId"),
        nonce: try optional("nonce"),
        ciphertext: try optional("ciphertext"),
        transferId: try optional("transferId"),
        sequence: sequence,
        targetDeviceId: try optional("targetDeviceId"),
        commitment: try optional("commitment"),
        protocolVersion: protocolVersion,
        tag: try optional("tag"),
        reason: try boundedReason(optional("reason"))
    )
}

/// `reason` in pairing.cancel is at most 32 bytes; a longer one closes the session like any bad envelope field.
private func boundedReason(_ value: String?) throws -> String? {
    guard let value else { return nil }
    guard value.utf8.count <= 32 else { throw PairingError.invalidMessage }
    return value
}

/// Splits the byte stream of one connection into frames. A frame ends at LF; one CR before the LF is
/// dropped. A partial frame over the frame limit is an error, so memory stays bounded.
struct ProtocolFrameReader {
    private(set) var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// The next complete frame, or nil when no complete frame is buffered. Throws for a malformed frame.
    mutating func next() throws -> PairingMessage? {
        guard let newline = buffer.firstIndex(of: 0x0A) else {
            guard !overLimit else { throw PairingError.invalidMessage }
            return nil
        }
        var line = Data(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        if line.last == 0x0D { line.removeLast() }
        return try decodeProtocolMessage(line)
    }

    /// The buffered partial frame is already over the limit.
    /// One byte over is allowed only for the CR that may end the frame.
    var overLimit: Bool {
        buffer.firstIndex(of: 0x0A) == nil && buffer.count > maximumProtocolFrameBytes + (buffer.last == 0x0D ? 1 : 0)
    }
}

/// The last `capacity` accepted message IDs of one session, oldest evicted first.
struct ReplayWindow {
    let capacity: Int
    private var ids = Set<String>()
    private var order: [String] = []
    private var head = 0

    init(capacity: Int = 256) { self.capacity = capacity }

    var count: Int { ids.count }

    /// False for an ID already in the window; otherwise remembers it.
    mutating func accept(_ id: String) -> Bool {
        guard ids.insert(id).inserted else { return false }
        order.append(id)
        if ids.count > capacity {
            ids.remove(order[head])
            head += 1
            // Compact now and then so the order list stays bounded too.
            if head >= capacity {
                order.removeFirst(head)
                head = 0
            }
        }
        return true
    }
}

// MARK: Payloads

/// What a received features.update means for the session.
enum FeatureStateDecoding: Equatable {
    /// Close the session: not JSON, no `features` map, a missing original key or a non-boolean known key.
    case invalid
    /// A version this client does not know: keep the session and the previous state.
    case ignored
    /// The peer's feature map. `drafts` holds the boolean draft keys this client knows.
    case state(features: [BridgeyFeature: Bool], drafts: [String: Bool])
}

/// Draft feature keys this client reads from features.update.
/// Files 2.0 (BrowseMessages.swift): the Mac reads files_browse_draft1 (the phone serves browsing); it reads
/// folders_receive_draft1 too, so both platforms decode the golden vectors alike, though only phones act on it.
/// Update all (UpdateAllProtocol.swift) adds updates_draft1, then screen sharing screen_draft1. Android has the same
/// list in the same order.
let knownDraftFeatureKeys = [clipboardFilesFeatureKey, foldersFeatureKey, placesFeatureKey, smsCodesFeatureKey,
                             foldersReceiveFeatureKey, filesBrowseFeatureKey,
                             // Automation (v0.9). Connection health has no key (no wire change).
                             macActionsFeatureKey, linksOpenFeatureKey, focusSyncFeatureKey, cameraFeatureKey,
                             updatesFeatureKey,
                             // Screen sharing (v0.9), view only.
                             screenFeatureKey,
                             // Text messages (SmsProtocol.swift).
                             smsFeatureKey]

func decodeFeatureState(_ plaintext: Data) -> FeatureStateDecoding {
    guard isStrictJSONObject(plaintext),
          let object = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
          let values = object["features"] as? [String: Any] else { return .invalid }
    guard jsonInteger(object["version"]) == 1 else { return .ignored }
    var features: [BridgeyFeature: Bool] = [:]
    for feature in BridgeyFeature.allCases {
        // A draft key that is also a switch here (Mac actions) reads like every draft key: true only when
        // it is JSON true. Android keeps camera_draft1 as a switch too; both decode it alike.
        if knownDraftFeatureKeys.contains(feature.rawValue) {
            features[feature] = jsonBool(values[feature.rawValue]) == true
            continue
        }
        guard let value = values[feature.rawValue] else {
            if featureEnabledByLegacyPeer(feature) { return .invalid }
            features[feature] = false
            continue
        }
        guard let flag = jsonBool(value) else { return .invalid }
        features[feature] = flag
    }
    var drafts: [String: Bool] = [:]
    for key in knownDraftFeatureKeys { drafts[key] = jsonBool(values[key]) == true }
    return .state(features: features, drafts: drafts)
}

/// A battery.update payload, or nil when malformed or out of range.
func decodeBatteryStatus(_ plaintext: Data) -> RemoteBatteryStatus? {
    guard isStrictJSONObject(plaintext),
          let object = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
          let level = jsonInteger(object["level"]), (0...100).contains(level),
          let charging = jsonBool(object["isCharging"]) else { return nil }
    return RemoteBatteryStatus(level: level, isCharging: charging)
}

/// A clipboard.rich payload, or nil when malformed, empty or over 32 KiB.
func decodeRichClipboard(_ plaintext: Data) -> RichClipboardContent? {
    guard isStrictJSONObject(plaintext),
          let object = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
          jsonInteger(object["version"]) == 1,
          let text = object["text"] as? String, let html = object["html"] as? String else { return nil }
    return RichClipboardContent(text: text, html: html)
}

/// A JSON boolean. Numbers (which bridge to NSNumber too) are not booleans.
func jsonBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}
