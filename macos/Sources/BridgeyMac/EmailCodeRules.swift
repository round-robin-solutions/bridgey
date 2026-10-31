import Foundation

/*
 * Codes from email (email_codes_draft1): the thin email-only layer in front of the shared code reader. A
 * port of `email_precheck` (the final rule) in outputs/bridgey/research/otp-tiny-model/email/email_guard.py,
 * measured on synthetic Gmail, Outlook, Proton Mail and Spark previews (docs/codes-from-email.md, "Phase 0
 * eval"); protocol/test-vectors/email-codes-v1.json holds that file's answers and EmailCodeRulesTests checks
 * this port against every one.
 *
 * Everything else (the digit-box join, the gate, the guard with links blanked, the model, its prompt, the
 * card, duplicates and order) is the same path text messages take (CodeText.swift, CodeReader.swift).
 *
 * 1. `emailCodePrecheck` decides whether a mail is worth reading: a code-shaped token with a code word within
 *    100 characters, where tokens in links and copyright years do not count; a token whose own sentence says
 *    the code expired or was used does not count; in a meeting invite or a mail with a marketing phrase
 *    ("promo code", "20% off") only strong words count (OTP, one-time, verification, 2FA, security code ...),
 *    and a marketing mail that says "unsubscribe" is refused outright; "login", "sign in" and "confirmation"
 *    alone are not code words (customer IDs and booking numbers sit next to them).
 * 2. `emailModelSnippets`: when the first read of a mail finds nothing, the shared reader reads up to two
 *    short pieces around the best tokens (within the same 2 s budget). Text messages are short, so they get
 *    one read.
 *
 * Mail text and codes are never logged.
 */

private let latinEdgeLeft = "(?<![0-9A-Za-z])"
private let latinEdgeRight = "(?![0-9A-Za-z])"
private let cyrillicEdgeLeft = "(?<![\\u0400-\\u04FF])"

private func emailRegex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
}

private let emailCodeWordPattern = emailRegex(
    latinEdgeLeft + "(?:code|otp|passcode|pin)s?" + latinEdgeRight
        + "|" + latinEdgeLeft + "(?:one-time|one[ \\-]?time|verification|verify|2fa|two-factor|two-step|security[ \\-]?code|authentication|confirm)" + latinEdgeRight
        + "|" + cyrillicEdgeLeft + "(?:код|пароль|подтвержд)|ओटीपी|कोड"
)
/// Inside a meeting invite or a marketing mail only these count.
private let emailStrongWordPattern = emailRegex(
    latinEdgeLeft + "(?:otp|one-time|one[ \\-]?time|verification|verify|2fa|two-factor|two-step|security[ \\-]?code|authentication)s?" + latinEdgeRight
        + "|" + cyrillicEdgeLeft + "(?:код|подтвержд)|ओटीपी"
)
private let emailDeadPattern = emailRegex(
    latinEdgeLeft + "(?:expired|no longer valid|no longer works|already (?:been )?used|(?:was|has been|been) used)" + latinEdgeRight
        + "|" + cyrillicEdgeLeft + "(?:истёк|истек|больше не действует|уже использован)|समाप्त|अमान्य"
)
private let emailSentenceEnd = emailRegex("[.!?\\n\u{0964}]", caseInsensitive: false)
private let emailMarketingPattern = emailRegex(
    "(?<![0-9A-Za-z\\-])(?:promo ?code|coupon|discount code|voucher|gift code|referral code|offer code)" + latinEdgeRight
        + "|\\d+ ?% ?off" + latinEdgeRight
        + "|" + cyrillicEdgeLeft + "(?:промокод|купон|скидк)|प्रोमो|कूपन|छूट"
)
private let emailUnsubscribePattern = emailRegex("unsubscribe")
private let emailMeetingPattern = emailRegex(
    "meeting id|meeting number|conference id|join zoom|zoom meeting|teams meeting|microsoft teams|webex|google meet|join by phone|webinar"
)

/// Characters (UTF-16 units) between a token and the nearest code word.
let emailCodeWordWindow = 100


/// A qualifying token, its distance to the nearest code word, and that word.
private struct EmailToken {
    let distance: Int
    let token: NSRange
    let word: NSRange
}

private func emailSentence(_ text: String, around token: NSRange) -> String {
    let source = text as NSString
    let ends = codeTextMatches(emailSentenceEnd, text)
    let start = ends.last(where: { NSMaxRange($0) <= token.location }).map(NSMaxRange) ?? 0
    let end = ends.first(where: { $0.location >= NSMaxRange(token) })?.location ?? source.length
    return source.substring(with: NSRange(location: start, length: max(0, end - start)))
}

/// Every token that passes, closest to a code word first (then by position). Empty: not a code mail.
private func emailQualifyingTokens(_ text: String) -> [EmailToken] {
    let scan = codeGuardText(text)
    let whole = NSRange(location: 0, length: (scan as NSString).length)
    guard looksLikeOtpTraffic(scan) || codeAlnumSplitPattern.firstMatch(in: scan, range: whole) != nil else { return [] }
    let marketing = codeTextMatches(emailMarketingPattern, scan)
    if !marketing.isEmpty, emailUnsubscribePattern.firstMatch(in: scan, range: whole) != nil { return [] }
    let strongOnly = !marketing.isEmpty || emailMeetingPattern.firstMatch(in: scan, range: whole) != nil
    let words = codeTextMatches(strongOnly ? emailStrongWordPattern : emailCodeWordPattern, scan)
        .filter { word in !marketing.contains { $0.location <= word.location && NSMaxRange(word) <= NSMaxRange($0) } }
    guard !words.isEmpty else { return [] }
    var tokens: [NSRange] = []
    for range in codeTextMatches(otpTokenPattern, scan) + codeTextMatches(otpSplitPattern, scan) + codeTextMatches(codeAlnumSplitPattern, scan)
    where !tokens.contains(where: { NSEqualRanges($0, range) }) {
        tokens.append(range)
    }
    var found: [EmailToken] = []
    for token in tokens {
        let sentence = emailSentence(scan, around: token)
        if emailDeadPattern.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)) != nil { continue }
        let gaps = words.map { (gap: max(max($0.location - NSMaxRange(token), token.location - NSMaxRange($0)), 0), word: $0) }
        guard let nearest = gaps.min(by: { $0.gap < $1.gap }), nearest.gap <= emailCodeWordWindow else { continue }
        found.append(EmailToken(distance: nearest.gap, token: token, word: nearest.word))
    }
    return found.sorted { ($0.distance, $0.token.location, $0.token.length) < ($1.distance, $1.token.location, $1.token.length) }
}

/// Whether a (normalised) mail preview may hold a one-time code, before the model reads it.
func emailCodePrecheck(_ text: String) -> Bool {
    !emailQualifyingTokens(text).isEmpty
}

/// The second read's texts: for the two best tokens, the whitespace-flattened text from 100 characters
/// before the token to 60 after it, trimmed to whole words. Empty when the pre-check fails.
func emailModelSnippets(_ text: String) -> [String] {
    let flat = emailFlattened(text)
    let source = flat as NSString
    var snippets: [String] = []
    for found in emailQualifyingTokens(flat).prefix(2) {
        var start = max(0, found.token.location - 100)
        var end = min(source.length, NSMaxRange(found.token) + 60)
        while start > 0, start < source.length, !isEmailSpace(source.character(at: start - 1)) { start += 1 }
        while end < source.length, end > 0, !isEmailSpace(source.character(at: end)) { end -= 1 }
        guard end > start else { continue }
        let piece = source.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty, !snippets.contains(piece) { snippets.append(piece) }
    }
    return snippets
}

private func isEmailSpace(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
}

private let emailEntitySpace = emailRegex("&nbsp;|&#160;", caseInsensitive: false)
private let emailInvisible = emailRegex("&#8203;|&zwnj;|\u{200B}|\u{200C}", caseInsensitive: false)
private let emailImagePlaceholder = emailRegex("\\[(?:image|cid):[^\\]]*\\]")

/// HTML leftovers removed and every run of whitespace made one space.
func emailFlattened(_ text: String) -> String {
    var value = codeTextReplacing(emailEntitySpace, in: text) { _ in " " }
    value = codeTextReplacing(emailInvisible, in: value) { _ in "" }
    value = codeTextReplacing(emailImagePlaceholder, in: value) { _ in " " }
    return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
