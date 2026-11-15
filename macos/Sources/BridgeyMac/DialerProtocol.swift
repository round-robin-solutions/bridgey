import Foundation

/*
 * Calls window (draft dialer_draft1, docs/protocol.md "Draft: Calls window"): the wire. What the phone
 * sends, decoded as strictly as protocol/test-vectors/dialer-v1.json pins it (status, contacts,
 * recents, callResult), and the requests this Mac writes, which the phone's decoders accept (request).
 * Also the pure parts of the window: the SIM choice, search rows and relative times, so they are tested
 * without a phone. Names and numbers are never logged, whatever Logging says.
 */

/// The draft key both devices advertise while the Calls window is on and allowed for each other.
let dialerFeatureKey = "dialer_draft1"

enum DialerKinds {
    static let status = "dialer.status"
    static let contacts = "dialer.contacts"
    static let contactsResult = "dialer.contacts_result"
    static let recents = "dialer.recents"
    static let recentsResult = "dialer.recents_result"
    static let call = "dialer.call"
    static let callResult = "dialer.call_result"
}

enum DialerLimits {
    static let status = 2_048
    static let contactsResult = 16_384
    static let recentsResult = 40_960
    static let small = 1_024
    static let query = 64
    static let contacts = 20
    static let numbers = 8
    static let whatsApp = 4
    static let recents = 50
    static let name = 128
    static let address = 64
    static let label = 32

    /// The largest plaintext a phone may send for `kind`; nil for kinds the phone never sends.
    static func incoming(_ kind: String) -> Int? {
        switch kind {
        case DialerKinds.status: status
        case DialerKinds.contactsResult: contactsResult
        case DialerKinds.recentsResult: recentsResult
        case DialerKinds.callResult: small
        default: nil
        }
    }
}

// MARK: - Model

enum DialerAccess: String, Equatable {
    case on, off, unavailable
}

/// The phone's last dialer.status: what it allows and its SIMs.
struct DialerPhoneStatus: Equatable {
    /// CALL_PHONE: a call starts without a tap on the phone.
    var place: Bool
    /// The phone's Ask on this phone first is on.
    var confirm: Bool
    var contacts: DialerAccess
    var recents: DialerAccess
    var whatsApp: Bool
    var sims: [SmsSim]

    /// Every call waits for a tap on the phone.
    var callsWaitForTap: Bool { confirm || !place }
}

struct DialerNumber: Equatable, Hashable {
    let address: String
    var label: String?
}

struct DialerWhatsApp: Equatable, Hashable {
    let address: String
    var voice: Int?
    var video: Int?
}

struct DialerContact: Equatable, Identifiable, Hashable {
    let id: Int
    let name: String
    var starred = false
    var numbers: [DialerNumber] = []
    var whatsApp: [DialerWhatsApp] = []
}

struct DialerContactsResult: Equatable {
    let requestID: String
    let contacts: [DialerContact]
    let error: String?
}

enum RecentCallType: String, Equatable {
    case incoming, outgoing, missed, rejected, blocked, voicemail
}

struct RecentCall: Equatable, Identifiable, Hashable {
    let id: Int
    let address: String
    var name: String?
    let type: RecentCallType
    let date: Int
    let duration: Int
    var subId: Int?

    var at: Date { Date(timeIntervalSince1970: TimeInterval(date) / 1000) }
    var title: String { name ?? (address.isEmpty ? L10n.text("calls.private", fallback: "Private number") : address) }
}

struct DialerRecentsResult: Equatable {
    let requestID: String
    let calls: [RecentCall]
    let error: String?
}

enum DialerCallOutcome: String, Equatable {
    case started, confirm, refused
}

enum DialerRefuseReason: String, Equatable {
    case disabled, permission, invalid, emergency
    case noSim = "no_sim"
    case rateLimited = "rate_limited"
    case notFound = "not_found"
    case unavailable, failed
}

struct DialerCallResult: Equatable {
    let requestID: String
    let outcome: DialerCallOutcome
    let reason: DialerRefuseReason?
}

/// How a call goes: through the phone's dialer, or its WhatsApp (voice or video).
enum DialerVia: String, Equatable {
    case phone
    case whatsAppVoice = "whatsapp_voice"
    case whatsAppVideo = "whatsapp_video"
}

// MARK: - Decoding (phone to Mac)

private func dialerObject(_ data: Data, limit: Int) -> [String: Any]? {
    guard data.count <= limit, isStrictJSONObject(data),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          jsonInteger(object["version"]) == 1 else { return nil }
    return object
}

private func units(_ text: String) -> Int { text.utf16.count }

private func nonNegative(_ value: Any?) -> Int? {
    guard let number = jsonInteger(value), number >= 0 else { return nil }
    return number
}

/// An optional field: absent or null is nil; present with the wrong type fails.
private enum Field<T> {
    case absent, value(T), invalid
}

private func optionalString(_ value: Any?, max: Int) -> Field<String> {
    switch value {
    case nil, is NSNull: return .absent
    case let text as String: return units(text) <= max ? .value(text) : .invalid
    default: return .invalid
    }
}

private func optionalID(_ value: Any?) -> Field<Int> {
    switch value {
    case nil, is NSNull: return .absent
    default:
        guard let number = jsonInteger(value), number >= 1, jsonBool(value) == nil else { return .invalid }
        return .value(number)
    }
}

private func dialerError(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    return ["disabled", "permission", "unavailable", "rate_limited"].contains(text) ? text : "unavailable"
}

private func access(_ value: Any?) -> DialerAccess? {
    guard let text = value as? String else { return nil }
    return DialerAccess(rawValue: text) ?? .off
}

/// dialer.status: every flag is required; more than 4 SIMs is malformed; an invalid SIM is dropped.
func decodeDialerStatus(_ data: Data) -> DialerPhoneStatus? {
    guard let object = dialerObject(data, limit: DialerLimits.status),
          let place = jsonBool(object["place"]), let confirm = jsonBool(object["confirm"]),
          let contacts = access(object["contacts"]), let recents = access(object["recents"]),
          let whatsApp = jsonBool(object["whatsapp"]) else { return nil }
    var sims: [SmsSim] = []
    switch object["sims"] {
    case nil, is NSNull: break
    case let list as [Any]:
        guard list.count <= 4 else { return nil }
        for entry in list {
            guard let sim = entry as? [String: Any],
                  let subId = nonNegative(sim["subId"]), subId <= Int(Int32.max),
                  let slot = jsonInteger(sim["slot"]), (0...3).contains(slot),
                  let label = sim["label"] as? String, units(label) <= 64 else { continue }
            sims.append(SmsSim(subId: subId, slot: slot, label: label))
        }
    default: return nil
    }
    return DialerPhoneStatus(place: place, confirm: confirm, contacts: contacts, recents: recents, whatsApp: whatsApp, sims: sims)
}

func decodeDialerContact(_ value: Any?) -> DialerContact? {
    guard let object = value as? [String: Any],
          let id = jsonInteger(object["id"]), id >= 1, jsonBool(object["id"]) == nil,
          let name = object["name"] as? String, (1...DialerLimits.name).contains(units(name)) else { return nil }
    var starred = false
    switch object["starred"] {
    case nil, is NSNull: break
    default:
        guard let flag = jsonBool(object["starred"]) else { return nil }
        starred = flag
    }
    var numbers: [DialerNumber] = []
    switch object["numbers"] {
    case nil, is NSNull: break
    case let list as [Any]:
        guard list.count <= DialerLimits.numbers else { return nil }
        for entry in list {
            guard let number = entry as? [String: Any], let address = number["address"] as? String,
                  (1...DialerLimits.address).contains(units(address)) else { return nil }
            switch optionalString(number["label"], max: DialerLimits.label) {
            case .invalid: return nil
            case .absent: numbers.append(DialerNumber(address: address))
            case let .value(label): numbers.append(DialerNumber(address: address, label: label.isEmpty ? nil : label))
            }
        }
    default: return nil
    }
    var whatsApp: [DialerWhatsApp] = []
    switch object["whatsapp"] {
    case nil, is NSNull: break
    case let list as [Any]:
        guard list.count <= DialerLimits.whatsApp else { return nil }
        for entry in list {
            guard let row = entry as? [String: Any], let address = row["address"] as? String,
                  units(address) <= DialerLimits.address else { return nil }
            var voice: Int?
            var video: Int?
            switch optionalID(row["voice"]) {
            case .invalid: return nil
            case let .value(id): voice = id
            case .absent: break
            }
            switch optionalID(row["video"]) {
            case .invalid: return nil
            case let .value(id): video = id
            case .absent: break
            }
            guard voice != nil || video != nil else { return nil }
            whatsApp.append(DialerWhatsApp(address: address, voice: voice, video: video))
        }
    default: return nil
    }
    guard !numbers.isEmpty || !whatsApp.isEmpty else { return nil }
    return DialerContact(id: id, name: name, starred: starred, numbers: numbers, whatsApp: whatsApp)
}

/// dialer.contacts_result: more than 20 is malformed; an invalid contact is dropped; an error empties the list.
func decodeDialerContactsResult(_ data: Data) -> DialerContactsResult? {
    guard let object = dialerObject(data, limit: DialerLimits.contactsResult),
          let requestID = smsRequestID(object["requestId"]),
          let list = object["contacts"] as? [Any], list.count <= DialerLimits.contacts else { return nil }
    if let error = dialerError(object["error"]) { return DialerContactsResult(requestID: requestID, contacts: [], error: error) }
    return DialerContactsResult(requestID: requestID, contacts: list.compactMap(decodeDialerContact), error: nil)
}

func decodeRecentCall(_ value: Any?) -> RecentCall? {
    guard let object = value as? [String: Any],
          let id = jsonInteger(object["id"]), id >= 1, jsonBool(object["id"]) == nil,
          let address = object["address"] as? String, units(address) <= DialerLimits.address,
          let rawType = object["type"] as? String,
          let date = nonNegative(object["date"]), let duration = nonNegative(object["duration"]) else { return nil }
    var name: String?
    switch optionalString(object["name"], max: DialerLimits.name) {
    case .invalid: return nil
    case let .value(text): name = text.isEmpty ? nil : text
    case .absent: break
    }
    var subId: Int?
    switch object["subId"] {
    case nil, is NSNull: break
    default:
        guard let sub = nonNegative(object["subId"]), sub <= Int(Int32.max) else { return nil }
        subId = sub
    }
    return RecentCall(id: id, address: address, name: name, type: RecentCallType(rawValue: rawType) ?? .incoming,
                      date: date, duration: duration, subId: subId)
}

/// dialer.recents_result: more than 50 is malformed; an invalid call is dropped; an error empties the list.
func decodeDialerRecentsResult(_ data: Data) -> DialerRecentsResult? {
    guard let object = dialerObject(data, limit: DialerLimits.recentsResult),
          let requestID = smsRequestID(object["requestId"]),
          let list = object["calls"] as? [Any], list.count <= DialerLimits.recents else { return nil }
    if let error = dialerError(object["error"]) { return DialerRecentsResult(requestID: requestID, calls: [], error: error) }
    return DialerRecentsResult(requestID: requestID, calls: list.compactMap(decodeRecentCall), error: nil)
}

/// dialer.call_result: an unknown result reads as refused, an unknown or missing reason as failed.
func decodeDialerCallResult(_ data: Data) -> DialerCallResult? {
    guard let object = dialerObject(data, limit: DialerLimits.small),
          let requestID = smsRequestID(object["requestId"]),
          let raw = object["result"] as? String else { return nil }
    let outcome = DialerCallOutcome(rawValue: raw) ?? .refused
    let reason: DialerRefuseReason? = outcome == .refused ? ((object["reason"] as? String).flatMap(DialerRefuseReason.init(rawValue:)) ?? .failed) : nil
    return DialerCallResult(requestID: requestID, outcome: outcome, reason: reason)
}

// MARK: - Requests (Mac to phone)

enum DialerRequests {
    static func contacts(requestID: String, query: String) -> [String: Any] {
        ["version": 1, "requestId": requestID, "query": String(query.trimmingCharacters(in: .whitespacesAndNewlines).utf16.prefix(DialerLimits.query)) ?? query]
    }

    static func recents(requestID: String, limit: Int) -> [String: Any] {
        ["version": 1, "requestId": requestID, "limit": min(max(limit, 1), DialerLimits.recents)]
    }

    /// A call through the phone: the number as typed (the phone normalises it) and the SIM, when chosen.
    static func call(requestID: String, number: String, subId: Int?) -> [String: Any] {
        var payload: [String: Any] = ["version": 1, "requestId": requestID, "via": DialerVia.phone.rawValue, "address": number]
        if let subId { payload["subId"] = subId }
        return payload
    }

    static func whatsApp(requestID: String, dataID: Int, video: Bool) -> [String: Any] {
        ["version": 1, "requestId": requestID, "via": (video ? DialerVia.whatsAppVideo : .whatsAppVoice).rawValue, "dataId": dataID]
    }
}

// MARK: - SIM choice

/// Settings > Calls > Calls window > Call from. Stored as `settings.calls.window.sim`.
enum CallsSimPreference: String, CaseIterable, Identifiable {
    /// Pick each time on a phone with two SIMs (default).
    case ask
    /// The SIM in the first slot, or the second.
    case sim1, sim2

    var id: String { rawValue }

    var slot: Int? {
        switch self {
        case .ask: nil
        case .sim1: 0
        case .sim2: 1
        }
    }
}

/// What a call does about the SIM.
enum CallsSimDecision: Equatable {
    /// One SIM, or a phone that cannot list them: the phone's default.
    case phoneDefault
    case use(subId: Int)
    /// Two or more SIMs and nothing picked: ask on this Mac.
    case ask
}

/// [picked]: the SIM chosen in the window for this call, if any. A pick that is no longer on the phone
/// is ignored; a preferred slot that is empty falls back to asking.
func callsSimDecision(preference: CallsSimPreference, sims: [SmsSim], picked: Int?) -> CallsSimDecision {
    guard sims.count >= 2 else { return .phoneDefault }
    if let picked, sims.contains(where: { $0.subId == picked }) { return .use(subId: picked) }
    if let slot = preference.slot, let sim = sims.first(where: { $0.slot == slot }) { return .use(subId: sim.subId) }
    return .ask
}

/// The SIM the window shows as chosen before any pick: the preferred slot's, else none.
func callsInitialSim(preference: CallsSimPreference, sims: [SmsSim]) -> Int? {
    guard sims.count >= 2, let slot = preference.slot else { return nil }
    return sims.first { $0.slot == slot }?.subId
}

// MARK: - Search

/// One row of the window's list.
enum CallsRow: Equatable, Identifiable {
    /// Call what was typed.
    case number(String)
    case contact(DialerContact)
    case recent(RecentCall)

    var id: String {
        switch self {
        case let .number(number): "n:\(number)"
        case let .contact(contact): "c:\(contact.id)"
        case let .recent(call): "r:\(call.id)"
        }
    }

    /// The number a plain Call on this row dials.
    var number: String? {
        switch self {
        case let .number(number): number
        case let .contact(contact): contact.numbers.first?.address
        case let .recent(call): call.address.isEmpty ? nil : call.address
        }
    }
}

/// The digits of a number, for matching "98765" against "+91 98765 43210".
func dialerDigits(_ text: String) -> String { text.filter(\.isNumber) }

/// Whether what was typed looks like a number (digits and the usual separators only).
func callsQueryIsNumber(_ query: String) -> Bool { normalizedPhoneNumber(query) != nil }

/// A recent call matches a name word that starts with the query, or a number that contains its digits.
func recentMatches(_ call: RecentCall, query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    let digits = dialerDigits(trimmed)
    if digits.count >= 2, digits.count == trimmed.filter({ !$0.isWhitespace && !"+-().".contains($0) }).count,
       dialerDigits(call.address).contains(digits) { return true }
    guard let name = call.name else { return false }
    let words = name.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" })
    let needle = trimmed.lowercased()
    return name.lowercased().hasPrefix(needle) || words.contains { $0.hasPrefix(needle) }
}

/// The list for [query]: recent calls when nothing is typed; otherwise a row to call a typed number,
/// the phone's matching contacts, then matching recent calls that are not those contacts' numbers.
/// Recent calls keep only the newest per number.
func callsRows(query: String, contacts: [DialerContact], recents: [RecentCall], limit: Int) -> [CallsRow] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen = Set<String>()
    let newestRecents = recents.filter { call in
        let key = call.address.isEmpty ? "id:\(call.id)" : dialerDigits(call.address)
        return seen.insert(key).inserted
    }
    if trimmed.isEmpty { return Array(newestRecents.prefix(limit)).map(CallsRow.recent) }
    var rows: [CallsRow] = []
    // The number as typed (the phone normalises it); a recent call to exactly that number is the same row.
    var shown = Set(contacts.flatMap { $0.numbers.map { dialerDigits($0.address) } })
    if normalizedPhoneNumber(trimmed) != nil {
        rows.append(.number(trimmed))
        shown.insert(dialerDigits(trimmed))
    }
    rows += contacts.map(CallsRow.contact)
    rows += newestRecents.filter { recentMatches($0, query: trimmed) && !shown.contains(dialerDigits($0.address)) }
        .prefix(limit).map(CallsRow.recent)
    return rows
}

// MARK: - Words

/// "Just now", "5 min ago", "Yesterday", "Mon", "12 Nov": how long ago a call was.
func callsRelativeTime(_ date: Date, now: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return L10n.text("calls.time.now", fallback: "Just now") }
    if seconds < 3_600 {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(fromTimeInterval: -max(60, (seconds / 60).rounded(.down) * 60))
    }
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
        return L10n.text("calls.time.yesterday", fallback: "Yesterday")
    }
    if seconds < 6 * 86_400 { return date.formatted(Date.FormatStyle().weekday(.abbreviated).locale(locale)) }
    return date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(locale))
}

/// "3 min 4 s", "45 s": a call's length; nil when it did not connect.
func callsDuration(_ seconds: Int) -> String? {
    guard seconds > 0 else { return nil }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
    return formatter.string(from: TimeInterval(seconds))
}

/// Initials for a contact's circle: "AK" for Anna Kapoor, "#" for a number.
func callsInitials(_ name: String) -> String {
    let words = name.split(whereSeparator: \.isWhitespace).filter { $0.first?.isLetter == true }
    guard let first = words.first?.first else { return "#" }
    let second = words.count > 1 ? words.last?.first : nil
    return String([first, second].compactMap { $0 }).uppercased()
}
