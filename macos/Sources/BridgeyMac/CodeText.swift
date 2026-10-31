import Foundation

/*
 * Code text rules shared by every code message, SMS and email alike (Rahul, 2026-10-31: one pipeline, the
 * same model, prompt and guard for both). They came out of the Phase 0 email eval and are source-neutral;
 * on the SMS sets they changed no outcome (outputs/bridgey/research/otp-tiny-model/email/sms_shared_rescore.py):
 *
 * - `codeReadText` joins codes flattened from HTML digit boxes ("4 8 2 9 1 3", "6-0-2-7-3-1"); the model and the
 *   guard read the joined text.
 * - `looksLikeCodeText` is the gate before the model: the relay's pre-check after that join, or a split
 *   letters-and-digits code ("7Q3-9XT"). The phone's preview gate is the same rule (CodeCore.kt).
 * - `codeGuardText` blanks links and copyright years, so a code found only in a link ("/verify/482913") or
 *   "(c) 2026" is refused by the guard.
 *
 * Refusing codes whose sentence says "expired" was measured too and is NOT shared: it lost 17 SMS codes ("Use
 * 683392 (NOT 679014, that one has EXPIRED)"). It stays in the email pre-check (EmailCodeRules.swift), with the
 * code words and marketing checks that decide whether a mail is worth reading.
 */

private let codeTextEdgeLeft = "(?<![0-9A-Za-z])"
private let codeTextEdgeRight = "(?![0-9A-Za-z])"

private func codeTextRegex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
}

func codeTextMatches(_ pattern: NSRegularExpression, _ text: String) -> [NSRange] {
    pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
}

/// Replaces each match of `pattern` with what `transform` returns for it (nil keeps the match).
func codeTextReplacing(_ pattern: NSRegularExpression, in text: String, _ transform: (String) -> String?) -> String {
    let source = text as NSString
    var result = ""
    var last = 0
    for range in codeTextMatches(pattern, text) {
        result += source.substring(with: NSRange(location: last, length: range.location - last))
        let match = source.substring(with: range)
        result += transform(match) ?? match
        last = NSMaxRange(range)
    }
    return result + source.substring(from: last)
}

private let codeURLPattern = codeTextRegex(
    "(?:https?://|www\\.)[^\\s<>\"]+|(?<![0-9A-Za-z@.])[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*\\.[A-Za-z]{2,}/[^\\s<>\"]*",
    caseInsensitive: false
)
private let codeCopyrightPattern = codeTextRegex("(?:\u{00A9}|\\(c\\)|copyright)\\s*(?:[0-9]{4}\\s*[-,]\\s*)?[0-9]{4}", caseInsensitive: true)
/// 3 to 8 groups of 1 or 2 digits split by single spaces: "4 8 2 9 1 3", "48 29 13".
private let codeSpacedDigits = codeTextRegex(codeTextEdgeLeft + "[0-9]{1,2}(?: [0-9]{1,2}){2,7}" + codeTextEdgeRight, caseInsensitive: false)
/// 4 to 8 single digits joined by hyphens: "6-0-2-7-3-1" (dates have two-digit parts and stay).
private let codeHyphenDigits = codeTextRegex("(?<![0-9A-Za-z\\-])[0-9](?:-[0-9]){3,7}(?![0-9A-Za-z\\-])", caseInsensitive: false)
/// A split letters-and-digits code, each half with a digit: "7Q3-9XT", "AB12-CD34".
let codeAlnumSplitPattern = codeTextRegex(
    codeTextEdgeLeft + "(?=[A-Za-z]*[0-9])[0-9A-Za-z]{3,4}-(?=[A-Za-z]*[0-9])[0-9A-Za-z]{3,4}" + codeTextEdgeRight,
    caseInsensitive: false
)

/// Joins codes flattened from HTML digit boxes. The phone's preview gate does the same join.
func codeReadText(_ text: String) -> String {
    let spaced = codeTextReplacing(codeSpacedDigits, in: text) { match in
        let digits = match.replacingOccurrences(of: " ", with: "")
        return (4...8).contains(digits.count) ? digits : nil
    }
    return codeTextReplacing(codeHyphenDigits, in: spaced) { $0.replacingOccurrences(of: "-", with: "") }
}

/// Links and copyright years replaced by spaces of the same length (UTF-16), so offsets stay.
func codeGuardText(_ text: String) -> String {
    let blank: (String) -> String? = { String(repeating: " ", count: ($0 as NSString).length) }
    return codeTextReplacing(codeCopyrightPattern, in: codeTextReplacing(codeURLPattern, in: text, blank), blank)
}

/// The gate before the model, for SMS and mail alike (on joined text).
func looksLikeCodeText(_ text: String) -> Bool {
    looksLikeOtpTraffic(text) || codeAlnumSplitPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
}
