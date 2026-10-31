import Foundation

/*
 * Codes from messages and from email: the rules for the code cards, kept pure so they are tested without
 * the coordinator (docs/codes-from-email.md, "Duplicates, chronology").
 *
 * - Order: newest first by the phone's post time (clamped near this Mac's receipt time, so a wrong phone
 *   clock cannot reorder wildly), then by arrival here.
 * - Same service: the sender reduced to a key (`codeServiceKey`), matched loosely (`codeServicesMatch`).
 * - Duplicate: the same code from a matching service while a card is live (10 minutes), by text, by email,
 *   from any mail app or any paired phone. It shows nothing new; the card lists the extra way it came.
 * - Latest and Older: among live cards of one service with different codes, the newest is "Latest, use
 *   this one" and the others "Older, replaced". An older code that arrives late is never copied by itself
 *   and never floats.
 *
 * Codes are never logged here or anywhere.
 */

/// How a code reached the phone.
enum CodeChannel: String, Equatable {
    case sms
    case email
}

/// One way a code came: the channel and, for email, the mail app's name ("Gmail", "Spark").
struct CodeSource: Equatable {
    let channel: CodeChannel
    let app: String

    init(channel: CodeChannel, app: String) {
        self.channel = channel
        self.app = app.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func == (lhs: CodeSource, rhs: CodeSource) -> Bool {
        lhs.channel == rhs.channel && (lhs.channel == .sms || lhs.app.lowercased() == rhs.app.lowercased())
    }
}

/// A card's mark among the live cards of its service.
enum CodeCardMark: Equatable {
    /// The newest of its service while an older, different code from that service is still live.
    case latest
    /// A newer, different code from the same service is live.
    case older

    var text: String {
        switch self {
        case .latest: L10n.text("codes.mark.latest", fallback: "Latest, use this one")
        case .older: L10n.text("codes.mark.older", fallback: "Older, replaced")
        }
    }
}

/// What a newly accepted code is, against the cards still live.
enum CodeArrival: Equatable {
    /// The same code from a matching service is live: history only, the card gains the source.
    case duplicate(cardID: String)
    /// A new card. `late`: a newer, different code from the same service is already live, so this one is
    /// marked older at once, gets the banner, and is never copied by itself or floated. `replaces`: the
    /// newest older live card of the same service with a different code, for "Replaces the code from 1 min ago".
    case fresh(late: Bool, replaces: String?)
}

enum CodeCards {
    /// A card's life in the panel, and the window for duplicates.
    static let lifetime: TimeInterval = 10 * 60
    /// Cards kept (and listed in the panel) at once; the oldest goes first.
    static let maximumLive = 5
    /// A phone post time is trusted from this long before this Mac got the code ...
    static let postedEarliest: TimeInterval = 15 * 60
    /// ... to this long after (a phone clock a little ahead).
    static let postedLatest: TimeInterval = 60

    /// The phone's post time (Unix ms), or `receivedAt` when it is missing or too far off.
    static func postedAt(phoneMillis: Int64, receivedAt: Date) -> Date {
        guard phoneMillis > 0 else { return receivedAt }
        let posted = Date(timeIntervalSince1970: TimeInterval(phoneMillis) / 1000)
        let offset = posted.timeIntervalSince(receivedAt)
        return offset >= -postedEarliest && offset <= postedLatest ? posted : receivedAt
    }

    /// Whether `a` sorts above `b`: posted later, or posted at the same moment and arrived later.
    static func isNewer(_ a: LiveCodeCard, than b: LiveCodeCard) -> Bool {
        a.postedAt != b.postedAt ? a.postedAt > b.postedAt : a.arrival > b.arrival
    }

    /// Newest first. A newer code never sits below an older one.
    static func ordered(_ cards: [LiveCodeCard]) -> [LiveCodeCard] {
        cards.sorted { isNewer($0, than: $1) }
    }

    /// Cards still inside their life at `now`.
    static func live(_ cards: [LiveCodeCard], now: Date) -> [LiveCodeCard] {
        cards.filter { now.timeIntervalSince($0.receivedAt) < lifetime }
    }

    /// The live cards to keep: newest first, at most `maximumLive`.
    static func kept(_ cards: [LiveCodeCard], now: Date) -> [LiveCodeCard] {
        Array(ordered(live(cards, now: now)).prefix(maximumLive))
    }

    /// Uppercased, spaces and hyphens removed: "482 913" and "482913" are one code.
    static func normalizedCode(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Decides what an accepted code is. `posted` and `arrival` are the new card's order keys.
    static func arrival(code: String, serviceKey: String, posted: Date, arrival: Int,
                        live cards: [LiveCodeCard], now: Date) -> CodeArrival {
        let current = live(cards, now: now)
        let normalized = normalizedCode(code)
        let sameService = current.filter { codeServicesMatch($0.serviceKey, serviceKey) }
        if let duplicate = ordered(sameService.filter { normalizedCode($0.code) == normalized }).first {
            return .duplicate(cardID: duplicate.id)
        }
        let probe = LiveCodeCard(id: "", code: code, sender: "", deviceName: "", receivedAt: now, postedAt: posted, arrival: arrival)
        // Latest and Older need a named service on both sides: a code from a phone number replaces nothing.
        let rivals = sameService.filter { codeServicesKnownMatch($0.serviceKey, serviceKey) }
        let late = rivals.contains { isNewer($0, than: probe) }
        let replaces = ordered(rivals.filter { isNewer(probe, than: $0) }).first?.id
        return .fresh(late: late, replaces: replaces)
    }

    /// Latest or Older for each card that has one (cards of a service with a single code, or a single card, have none).
    static func marks(_ cards: [LiveCodeCard]) -> [String: CodeCardMark] {
        var marks: [String: CodeCardMark] = [:]
        for card in cards {
            let rivals = cards.filter {
                $0.id != card.id && codeServicesKnownMatch($0.serviceKey, card.serviceKey)
                    && normalizedCode($0.code) != normalizedCode(card.code)
            }
            if rivals.contains(where: { isNewer($0, than: card) }) {
                marks[card.id] = .older
            } else if !rivals.isEmpty {
                marks[card.id] = .latest
            }
        }
        return marks
    }

    /// The card's two or three lines in the panel: its mark, who sent it (or the copied countdown), and how
    /// and when it came.
    static func detail(_ card: LiveCodeCard, mark: CodeCardMark?, now: Date) -> String {
        var lines: [String] = []
        if let mark { lines.append(mark.text) }
        lines.append(card.copiedLine(now: now)
            ?? String(format: L10n.text("codes.card.detail", fallback: "From %1$@ on %2$@"), card.sender, card.deviceName))
        lines.append(codeSourceLine(card.sources) + " \u{00B7} " + codeRelativeTime(card.postedAt, now: now))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Service

/// Words that say nothing about which service sent a code.
private let codeServiceNoise = [
    "do not reply", "no-reply", "noreply", "notifications", "notification", "verification", "accounts", "account",
    "security", "support", "alerts", "alert", "team", "info", "mail", "the", "via",
]

/// The sender reduced to a key for "same service": lowercase, an Indian DLT SMS header ("AX-HDFCBK-S") cut to
/// its sender part, noise words removed, then letters and digits only. "" for a sender that is only a phone
/// number (or empty), which matches any service.
func codeServiceKey(_ sender: String) -> String {
    var value = sender.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = value.range(of: "^[a-z]{2}-", options: .regularExpression) { value.removeSubrange(range) }
    if let range = value.range(of: "-[a-z]$", options: .regularExpression) { value.removeSubrange(range) }
    for word in codeServiceNoise {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    let key = String(value.filter { $0.isLetter || $0.isNumber })
    // Only digits: a phone number or short code, not a name.
    return key.allSatisfy(\.isNumber) ? "" : key
}

/// Two service keys match when equal, when one starts with the other, or when both have at least four
/// characters and share the first four. An unknown service ("") matches any.
func codeServicesMatch(_ a: String, _ b: String) -> Bool {
    if a.isEmpty || b.isEmpty || a == b || a.hasPrefix(b) || b.hasPrefix(a) { return true }
    return a.count >= 4 && b.count >= 4 && a.prefix(4) == b.prefix(4)
}

/// The same named service: unlike `codeServicesMatch`, an unknown service matches nothing. Latest and Older use
/// this, so a code from a phone number never marks another service's code replaced.
func codeServicesKnownMatch(_ a: String, _ b: String) -> Bool {
    !a.isEmpty && !b.isEmpty && codeServicesMatch(a, b)
}

/// The name a code card and banner show: the notification title (an SMS contact or sender ID, a mail's
/// sender), else the app's name. A title like "2 new emails" is a summary, not a sender.
func codeSender(title: String, applicationName: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.range(of: "^\\d+ new", options: [.regularExpression, .caseInsensitive]) != nil {
        return applicationName
    }
    return trimmed
}

// MARK: - Text

/// "by text", "by email, Gmail", "by email, Gmail and Spark", "by text, also by email", "by email, also by text".
func codeSourceLine(_ sources: [CodeSource]) -> String {
    guard let first = sources.first else { return L10n.text("codes.source.text", fallback: "by text") }
    let hasText = sources.contains { $0.channel == .sms }
    let hasEmail = sources.contains { $0.channel == .email }
    switch first.channel {
    case .sms:
        return hasEmail
            ? L10n.text("codes.source.textAlsoEmail", fallback: "by text, also by email")
            : L10n.text("codes.source.text", fallback: "by text")
    case .email:
        if hasText { return L10n.text("codes.source.emailAlsoText", fallback: "by email, also by text") }
        var apps: [String] = []
        for source in sources where source.channel == .email && !source.app.isEmpty {
            if !apps.contains(where: { $0.lowercased() == source.app.lowercased() }) { apps.append(source.app) }
        }
        guard !apps.isEmpty else { return L10n.text("codes.source.email", fallback: "by email") }
        return String(format: L10n.text("codes.source.emailApps", fallback: "by email, %@"), codeListText(apps))
    }
}

/// "Gmail", "Gmail and Spark", "Gmail, Outlook and Spark".
func codeListText(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    let and = L10n.text("codes.list.and", fallback: "%1$@ and %2$@")
    return String(format: and, items.dropLast().joined(separator: ", "), items.last!)
}

/// "now" under 10 s, "40 s ago" under a minute, "2 min ago" under an hour, then "3 h ago".
func codeRelativeTime(_ date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date).rounded(.down))
    if seconds < 10 { return L10n.text("codes.time.now", fallback: "now") }
    if seconds < 60 { return String(format: L10n.text("codes.time.seconds", fallback: "%d s ago"), seconds) }
    if seconds < 3600 { return String(format: L10n.text("codes.time.minutes", fallback: "%d min ago"), seconds / 60) }
    return String(format: L10n.text("codes.time.hours", fallback: "%d h ago"), seconds / 3600)
}

/// The floating panel's line when the newest code replaces a live, older one from the same service.
func codeReplacesLine(_ older: LiveCodeCard, now: Date) -> String {
    let seconds = now.timeIntervalSince(older.postedAt)
    if seconds < 10 { return L10n.text("codes.replaces.now", fallback: "Replaces the code from a moment ago") }
    return String(format: L10n.text("codes.replaces", fallback: "Replaces the code from %@"), codeRelativeTime(older.postedAt, now: now))
}
