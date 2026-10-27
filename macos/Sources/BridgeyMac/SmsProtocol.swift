import Foundation

/*
 * Text messages (draft sms_draft1, docs/protocol.md "Text messages"): the phone's SMS conversations
 * on this Mac. This file is the wire: the payloads the phone sends, decoded as strictly as the golden
 * vectors pin them (protocol/test-vectors/protocol-v1.json: smsStatus, smsMessage, smsSendStatus), and
 * the requests this Mac writes, which the phone's decoders accept (smsRequest, smsSend).
 *
 * Message bodies, numbers, contact names and SIM labels are never logged, whatever Logging says.
 */

/// The draft key both devices advertise while Text messages is on for each other.
let smsFeatureKey = "sms_draft1"

enum SmsKinds {
    static let status = "sms.status"
    static let changed = "sms.changed"
    static let threads = "sms.threads"
    static let threadsPage = "sms.threads_page"
    static let messages = "sms.messages"
    static let messagesPage = "sms.messages_page"
    static let sync = "sms.sync"
    static let syncPage = "sms.sync_page"
    static let send = "sms.send"
    static let sendStatus = "sms.send_status"
    static let attachment = "sms.attachment"
    static let attachmentData = "sms.attachment_data"
    static let contacts = "sms.contacts"
    static let contactsResult = "sms.contacts_result"
}

/// Plaintext limits per kind (protocol/messages.json maxPlaintextBytes).
enum SmsLimits {
    static let page = 40_960
    static let status = 2_048
    static let changed = 256
    static let contactsResult = 16_384
    static let small = 1_024
    static let sendRequest = 8_192
    /// Body of one send, in UTF-16 units.
    static let body = 2_000
    /// A message body on the wire, in UTF-16 units.
    static let messageBody = 4_000
    static let attachmentBytes = 28_672
    static let threadsPerPage = 50
    static let messagesPerPage = 100
    static let syncPerPage = 200

    /// The largest plaintext a phone may send for `kind`; nil for kinds the phone never sends.
    static func incoming(_ kind: String) -> Int? {
        switch kind {
        case SmsKinds.status: status
        case SmsKinds.changed: changed
        case SmsKinds.threadsPage, SmsKinds.messagesPage, SmsKinds.syncPage, SmsKinds.attachmentData: page
        case SmsKinds.contactsResult: contactsResult
        case SmsKinds.sendStatus: small
        default: nil
        }
    }
}

// MARK: - Model

/// The newest `_id` of the phone's SMS and MMS tables.
struct SmsCursor: Codable, Equatable {
    var sms: Int
    var mms: Int

    static let zero = SmsCursor(sms: 0, mms: 0)

    /// True when `other` has something this cursor has not seen.
    func isBehind(_ other: SmsCursor) -> Bool { other.sms > sms || other.mms > mms }

    var payload: [String: Any] { ["sms": sms, "mms": mms] }
}

struct SmsSim: Codable, Equatable, Identifiable, Hashable {
    let subId: Int
    let slot: Int
    let label: String
    var id: Int { subId }
}

/// The phone's last sms.status: its permissions, SIMs and cursor.
struct SmsPhoneStatus: Equatable {
    var read: Bool
    var send: Bool
    var contacts: Bool
    var sims: [SmsSim]
    var cursor: SmsCursor
}

struct SmsPart: Codable, Equatable, Hashable {
    let partId: String
    let mimeType: String
    var size: Int?
}

struct SmsMessage: Codable, Equatable, Identifiable, Hashable {
    enum Direction: String, Codable { case incoming = "in", outgoing = "out" }
    enum Status: String, Codable { case received, pending, sent, delivered, failed }

    let id: String
    let threadId: Int
    let direction: Direction
    var status: Status
    let date: Int
    let address: String
    let body: String
    var truncated = false
    var subId: Int?
    var read = true
    var parts: [SmsPart] = []

    var sentAt: Date { Date(timeIntervalSince1970: TimeInterval(date) / 1000) }

    /// Newest first: by date, then by id, as the phone orders pages.
    static func newerFirst(_ a: SmsMessage, _ b: SmsMessage) -> Bool {
        a.date != b.date ? a.date > b.date : a.id > b.id
    }
}

struct SmsParticipant: Codable, Equatable, Hashable {
    let address: String
    var name: String?

    var display: String { name?.isEmpty == false ? name! : address }
}

struct SmsThread: Codable, Equatable, Identifiable, Hashable {
    let threadId: Int
    var participants: [SmsParticipant]
    var snippet: String
    var date: Int
    var unread: Int
    var subId: Int?

    var id: Int { threadId }
    var isGroup: Bool { participants.count > 1 }
    var title: String { participants.map(\.display).joined(separator: ", ") }
    var lastAt: Date { Date(timeIntervalSince1970: TimeInterval(date) / 1000) }
}

struct SmsContact: Equatable, Hashable, Identifiable {
    let name: String
    let address: String
    var label: String?
    var id: String { name + "\u{0}" + address }
}

enum SmsSendState: String, Equatable {
    case sending, sent, delivered, failed, refused
}

enum SmsSendReason: String, Equatable {
    case disabled, permission, invalid, group, noSim = "no_sim", rateLimited = "rate_limited", notFound = "not_found"
    case radioOff = "radio_off", noService = "no_service", failed
}

struct SmsSendStatus: Equatable {
    let requestID: String
    let status: SmsSendState
    let reason: SmsSendReason?
    let via: String?
}

struct SmsThreadsPage: Equatable {
    let requestID: String
    let threads: [SmsThread]
    let more: Bool
    let error: String?
}

struct SmsMessagesPage: Equatable {
    let requestID: String
    let threadId: Int
    let messages: [SmsMessage]
    let more: Bool
    let error: String?
}

struct SmsSyncPage: Equatable {
    let requestID: String
    let messages: [SmsMessage]
    let cursor: SmsCursor
    let more: Bool
    let reset: Bool
    let error: String?
}

struct SmsAttachment: Equatable {
    let requestID: String
    let partID: String
    let data: Data?
    let width: Int
    let height: Int
    let error: String?
}

struct SmsContactsResult: Equatable {
    let requestID: String
    let contacts: [SmsContact]
    let error: String?
}

// MARK: - Decoding (phone to Mac)

private func smsObject(_ data: Data, limit: Int) -> [String: Any]? {
    guard data.count <= limit, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          jsonInteger(object["version"]) == 1 else { return nil }
    return object
}

/// A request ID the Mac wrote (any letter case), lowercased.
func smsRequestID(_ value: Any?) -> String? {
    guard let text = value as? String, UUID(uuidString: text) != nil, text.count == 36 else { return nil }
    return text.lowercased()
}

private func nonNegative(_ value: Any?) -> Int? {
    guard let number = jsonInteger(value), number >= 0 else { return nil }
    return number
}

private func utf16Count(_ text: String) -> Int { text.utf16.count }

private let smsMessageIDPattern = try! NSRegularExpression(pattern: "^[sm][0-9]{1,19}$")
private let smsPartIDPattern = try! NSRegularExpression(pattern: "^p[0-9]{1,19}$")

private func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

func isSmsMessageID(_ text: String) -> Bool { matches(smsMessageIDPattern, text) }
func isSmsPartID(_ text: String) -> Bool { matches(smsPartIDPattern, text) }

func decodeSmsCursor(_ value: Any?) -> SmsCursor? {
    guard let object = value as? [String: Any], let sms = nonNegative(object["sms"]), let mms = nonNegative(object["mms"]) else { return nil }
    return SmsCursor(sms: sms, mms: mms)
}

/// sms.status: permissions and cursor are required; more than 4 SIMs is malformed; an invalid SIM is dropped.
func decodeSmsStatus(_ data: Data) -> SmsPhoneStatus? {
    guard let object = smsObject(data, limit: SmsLimits.status),
          let read = jsonBool(object["read"]), let send = jsonBool(object["send"]), let contacts = jsonBool(object["contacts"]),
          let cursor = decodeSmsCursor(object["cursor"]) else { return nil }
    var sims: [SmsSim] = []
    switch object["sims"] {
    case nil, is NSNull: break
    case let list as [Any]:
        guard list.count <= 4 else { return nil }
        for entry in list {
            guard let sim = entry as? [String: Any],
                  let subId = nonNegative(sim["subId"]), subId <= Int(Int32.max),
                  let slot = jsonInteger(sim["slot"]), (0...3).contains(slot),
                  let label = sim["label"] as? String, utf16Count(label) <= 64 else { continue }
            sims.append(SmsSim(subId: subId, slot: slot, label: label))
        }
    default: return nil
    }
    return SmsPhoneStatus(read: read, send: send, contacts: contacts, sims: sims, cursor: cursor)
}

/// sms.changed: the phone's cursor.
func decodeSmsChanged(_ data: Data) -> SmsCursor? {
    guard let object = smsObject(data, limit: SmsLimits.changed) else { return nil }
    return decodeSmsCursor(object["cursor"])
}

/// One message object of a page, or nil (the message is dropped). See the smsMessage vectors.
func decodeSmsMessage(_ value: Any?) -> SmsMessage? {
    guard let object = value as? [String: Any],
          let id = object["id"] as? String, isSmsMessageID(id),
          let threadId = jsonInteger(object["threadId"]), threadId >= 1,
          let rawDirection = object["direction"] as? String, let direction = SmsMessage.Direction(rawValue: rawDirection),
          let date = nonNegative(object["date"]),
          let address = object["address"] as? String, utf16Count(address) <= 64,
          let body = object["body"] as? String, utf16Count(body) <= SmsLimits.messageBody else { return nil }
    let fallback: SmsMessage.Status = direction == .incoming ? .received : .sent
    let status = (object["status"] as? String).flatMap(SmsMessage.Status.init(rawValue:)) ?? fallback
    var parts: [SmsPart] = []
    if let list = object["parts"] as? [Any] {
        for entry in list {
            guard parts.count < 8 else { break }
            guard let part = entry as? [String: Any],
                  let partId = part["partId"] as? String, isSmsPartID(partId),
                  let mime = part["mimeType"] as? String, mime.hasPrefix("image/"), utf16Count(mime) <= 64 else { continue }
            parts.append(SmsPart(partId: partId, mimeType: mime, size: nonNegative(part["size"])))
        }
    }
    return SmsMessage(
        id: id, threadId: threadId, direction: direction, status: status, date: date, address: address, body: body,
        truncated: jsonBool(object["truncated"]) == true,
        subId: nonNegative(object["subId"]),
        read: jsonBool(object["read"]) != false,
        parts: parts
    )
}

private func decodeMessages(_ value: Any?) -> [SmsMessage]? {
    guard let list = value as? [Any] else { return nil }
    return list.compactMap(decodeSmsMessage)
}

private func pageError(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty, text.count <= 32 else { return nil }
    return text
}

func decodeSmsThread(_ value: Any?) -> SmsThread? {
    guard let object = value as? [String: Any],
          let threadId = jsonInteger(object["threadId"]), threadId >= 1,
          let list = object["participants"] as? [Any], (1...10).contains(list.count),
          let date = nonNegative(object["date"]) else { return nil }
    var participants: [SmsParticipant] = []
    for entry in list {
        guard let participant = entry as? [String: Any],
              let address = participant["address"] as? String, utf16Count(address) <= 64 else { return nil }
        let name = (participant["name"] as? String).flatMap { utf16Count($0) <= 128 && !$0.isEmpty ? $0 : nil }
        participants.append(SmsParticipant(address: address, name: name))
    }
    let snippet = (object["snippet"] as? String).map { String($0.prefix(160)) } ?? ""
    return SmsThread(threadId: threadId, participants: participants, snippet: snippet, date: date,
                     unread: nonNegative(object["unread"]) ?? 0, subId: nonNegative(object["subId"]))
}

func decodeSmsThreadsPage(_ data: Data) -> SmsThreadsPage? {
    guard let object = smsObject(data, limit: SmsLimits.page), let requestID = smsRequestID(object["requestId"]),
          let list = object["threads"] as? [Any] else { return nil }
    return SmsThreadsPage(requestID: requestID, threads: list.compactMap(decodeSmsThread),
                          more: jsonBool(object["more"]) == true, error: pageError(object["error"]))
}

func decodeSmsMessagesPage(_ data: Data) -> SmsMessagesPage? {
    guard let object = smsObject(data, limit: SmsLimits.page), let requestID = smsRequestID(object["requestId"]),
          let threadId = jsonInteger(object["threadId"]), let messages = decodeMessages(object["messages"]) else { return nil }
    // A message of another conversation is not this page's.
    return SmsMessagesPage(requestID: requestID, threadId: threadId, messages: messages.filter { $0.threadId == threadId },
                           more: jsonBool(object["more"]) == true, error: pageError(object["error"]))
}

func decodeSmsSyncPage(_ data: Data) -> SmsSyncPage? {
    guard let object = smsObject(data, limit: SmsLimits.page), let requestID = smsRequestID(object["requestId"]),
          let cursor = decodeSmsCursor(object["cursor"]) else { return nil }
    let messages = decodeMessages(object["messages"]) ?? []
    return SmsSyncPage(requestID: requestID, messages: messages, cursor: cursor, more: jsonBool(object["more"]) == true,
                       reset: jsonBool(object["reset"]) == true, error: pageError(object["error"]))
}

/// sms.send_status: an unknown status is dropped; a failed or refused status without a known reason reads as failed.
func decodeSmsSendStatus(_ data: Data) -> SmsSendStatus? {
    guard let object = smsObject(data, limit: SmsLimits.small), let requestID = smsRequestID(object["requestId"]),
          let raw = object["status"] as? String, let status = SmsSendState(rawValue: raw) else { return nil }
    var reason: SmsSendReason?
    if status == .failed || status == .refused {
        reason = (object["reason"] as? String).flatMap(SmsSendReason.init(rawValue:)) ?? .failed
    }
    let via = (object["via"] as? String).flatMap { $0 == "sms" || $0 == "app" ? $0 : nil }
    return SmsSendStatus(requestID: requestID, status: status, reason: reason, via: via)
}

func decodeSmsAttachment(_ data: Data) -> SmsAttachment? {
    guard let object = smsObject(data, limit: SmsLimits.page), let requestID = smsRequestID(object["requestId"]),
          let partID = object["partId"] as? String, isSmsPartID(partID) else { return nil }
    if let error = pageError(object["error"]) {
        return SmsAttachment(requestID: requestID, partID: partID, data: nil, width: 0, height: 0, error: error)
    }
    guard let encoded = object["data"] as? String, let bytes = Data(base64Encoded: encoded),
          !bytes.isEmpty, bytes.count <= SmsLimits.attachmentBytes else { return nil }
    return SmsAttachment(requestID: requestID, partID: partID, data: bytes,
                         width: nonNegative(object["width"]) ?? 0, height: nonNegative(object["height"]) ?? 0, error: nil)
}

func decodeSmsContactsResult(_ data: Data) -> SmsContactsResult? {
    guard let object = smsObject(data, limit: SmsLimits.contactsResult), let requestID = smsRequestID(object["requestId"]) else { return nil }
    var contacts: [SmsContact] = []
    for entry in object["contacts"] as? [Any] ?? [] {
        guard contacts.count < 20, let contact = entry as? [String: Any],
              let name = contact["name"] as? String, utf16Count(name) <= 128,
              let address = contact["address"] as? String, !address.isEmpty, utf16Count(address) <= 64 else { continue }
        let label = (contact["label"] as? String).flatMap { utf16Count($0) <= 32 && !$0.isEmpty ? $0 : nil }
        contacts.append(SmsContact(name: name, address: address, label: label))
    }
    return SmsContactsResult(requestID: requestID, contacts: contacts, error: pageError(object["error"]))
}

// MARK: - Requests (Mac to phone)

enum SmsRequests {
    static func threads(_ requestID: String, before: Int? = nil, limit: Int = 30) -> [String: Any] {
        var payload: [String: Any] = ["version": 1, "requestId": requestID, "limit": min(max(limit, 1), SmsLimits.threadsPerPage)]
        if let before { payload["before"] = before }
        return payload
    }

    static func messages(_ requestID: String, threadId: Int, before: SmsMessage? = nil, limit: Int = 50) -> [String: Any] {
        var payload: [String: Any] = ["version": 1, "requestId": requestID, "threadId": threadId,
                                      "limit": min(max(limit, 1), SmsLimits.messagesPerPage)]
        if let before { payload["before"] = ["date": before.date, "id": before.id] }
        return payload
    }

    static func sync(_ requestID: String, since: SmsCursor, limit: Int = 100) -> [String: Any] {
        ["version": 1, "requestId": requestID, "since": since.payload, "limit": min(max(limit, 1), SmsLimits.syncPerPage)]
    }

    static func attachment(_ requestID: String, partID: String) -> [String: Any] {
        ["version": 1, "requestId": requestID, "partId": partID]
    }

    static func contacts(_ requestID: String, query: String) -> [String: Any]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, utf16Count(trimmed) <= 64 else { return nil }
        return ["version": 1, "requestId": requestID, "query": trimmed]
    }

    /// Where a send goes: a conversation, a new number, or the SMS notification it answers.
    enum Target: Equatable, Hashable {
        case thread(Int)
        case address(String)
        case notification(String)
    }

    /// sms.send, or nil when the phone would refuse it as malformed (empty or too long, a bad number).
    static func send(_ requestID: String, body: String, to target: Target, subId: Int? = nil) -> [String: Any]? {
        guard isSendableBody(body) else { return nil }
        var payload: [String: Any] = ["version": 1, "requestId": requestID, "body": body]
        switch target {
        case let .thread(id):
            guard id >= 1 else { return nil }
            payload["threadId"] = id
        case let .address(raw):
            guard let address = normalizedSmsAddress(raw) else { return nil }
            payload["address"] = address
        case let .notification(id):
            guard !id.isEmpty, id.count <= 512 else { return nil }
            payload["notificationId"] = id
        }
        if let subId, subId >= 0 { payload["subId"] = subId }
        return payload
    }

    static func isSendableBody(_ body: String) -> Bool {
        let count = utf16Count(body)
        return count >= 1 && count <= SmsLimits.body && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A phone number as the phone accepts it: spaces, dashes, dots and brackets removed, then + and 2 to 20 digits.
func normalizedSmsAddress(_ raw: String) -> String? {
    let stripped = raw.filter { !" -.()".contains($0) }
    guard let regex = try? NSRegularExpression(pattern: "^\\+?[0-9]{2,20}$"),
          regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil else { return nil }
    return stripped
}
