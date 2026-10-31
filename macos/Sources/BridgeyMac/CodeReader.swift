import Foundation

/*
 * Codes from messages (edition): finds a one-time code in an SMS the phone forwarded, so the Mac can
 * show "Code 482913 from HDFC Bank" with a Copy button. Off by default. Two engines read the message,
 * chosen in Settings > Notifications > Codes from messages:
 *   - On this Mac (the default): a small fine-tuned model (CodeModel.swift) runs here through
 *     llama.cpp; the message never leaves the Mac.
 *   - Cloud: the text goes to Round Robin's relay (services/otp-proxy), which asks Cloudflare
 *     Workers AI.
 * Either way the model decides; the guard here only refuses an answer that is not literally in the
 * message or does not look like a code. Any refusal, error or timeout shows the plain notification.
 *
 * Message text and codes are never logged, whatever Settings > Privacy > Logging says.
 */

/// Accepts the model's code only if it appears in the message as a whole token and looks like a code.
/// Can only refuse; it never finds a code itself. Same rule as `strict_guard` in the model research
/// (outputs/bridgey/research/otp-tiny-model/common.py) and Android's CodeGuard.
enum CodeGuard {
    /// The code to show and copy (separators and a short prefix such as "G-" removed, letter case as in
    /// the message), or nil to fall back to the plain notification.
    ///
    /// Rules:
    /// - a leading prefix of one or two letters ("G-482913") is dropped; every remaining part (split on
    ///   spaces and hyphens) contains a digit, and when there are several parts each has at least three
    ///   characters ("482 913", not "30-10-26");
    /// - the code is 4 to 8 letters or digits in all;
    /// - the answer is in the message literally, as a whole token (any letter case), or the message
    ///   has a split token ("482 913", "PP-301842") whose groups each have 3 or more characters and a
    ///   digit, and which equals the answer once its separators are removed. A space or hyphen is never
    ///   allowed between any two characters, so "5minMe" does not match "5 min me".
    static func accept(_ answer: String?, in text: String) -> String? {
        guard var raw = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 24 else { return nil }
        var parts = raw.split(whereSeparator: isSeparator).map(String.init)
        if parts.count > 1, isShortPrefix(parts[0]) {
            parts.removeFirst()
            raw = String(raw.drop(while: { !isSeparator($0) }).drop(while: isSeparator))
        }
        guard !parts.isEmpty, parts.allSatisfy({ $0.contains(where: \.isASCIIDigit) }) else { return nil }
        guard parts.count == 1 || parts.allSatisfy({ $0.count >= 3 }) else { return nil }
        let core = parts.joined()
        guard (4...8).contains(core.count), core.allSatisfy(\.isASCIIAlphanumeric) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)

        // 1. Literally in the message, as a whole token.
        if let literal = try? NSRegularExpression(pattern: tokenEdgeLeft + NSRegularExpression.escapedPattern(for: raw) + tokenEdgeRight, options: [.caseInsensitive]),
           let match = literal.firstMatch(in: text, range: whole), let range = Range(match.range, in: text) {
            return String(text[range].filter(\.isASCIIAlphanumeric))
        }

        // 2. A split token in the message whose groups, joined, are the answer.
        let wanted = core.uppercased()
        for match in splitToken.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[range])
            guard token.contains(where: isSeparator) else { continue }
            var groups = token.split(whereSeparator: isSeparator).map(String.init)
            var prefix = ""
            if isShortPrefix(groups[0]) { prefix = groups.removeFirst().uppercased() }
            guard !groups.isEmpty, groups.allSatisfy({ $0.contains(where: \.isASCIIDigit) }) else { continue }
            let joined = groups.joined()
            if wanted == joined.uppercased() || wanted == prefix + joined.uppercased() {
                return joined
            }
        }
        return nil
    }

    private static func isSeparator(_ character: Character) -> Bool { character == " " || character == "-" || character.isWhitespace }

    private static func isShortPrefix(_ part: String) -> Bool { (1...2).contains(part.count) && part.allSatisfy(\.isASCIILetter) }

    private static let tokenEdgeLeft = "(?<![0-9A-Za-z])"
    private static let tokenEdgeRight = "(?![0-9A-Za-z])"
    /// 3 or more letters or digits with at least one digit.
    private static let digitGroup = "(?=[0-9A-Za-z]*[0-9])[0-9A-Za-z]{3,}"
    /// A lookahead, so overlapping candidates are all tried: an optional 1 or 2 letter prefix, then
    /// digit groups joined by one space or hyphen each.
    private static let splitToken = try! NSRegularExpression(
        pattern: "(?=" + tokenEdgeLeft + "((?:[A-Za-z]{1,2}[ \\-])?" + digitGroup + "(?:[ \\-]" + digitGroup + ")*)" + tokenEdgeRight + ")"
    )
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
    var isASCIIAlphanumeric: Bool { isASCIIDigit || isASCIILetter }
}

/// The relay's cheap pre-check, applied here first so plain messages never leave the Mac: a whole
/// token of 4 to 10 letters or digits with a digit in it, or two digit groups split by one space or
/// hyphen. Same rule as services/otp-proxy and the Android test screen.
func looksLikeOtpTraffic(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return otpTokenPattern.firstMatch(in: text, range: range) != nil || otpSplitPattern.firstMatch(in: text, range: range) != nil
}

private let otpTokenPattern = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z])(?=[0-9A-Za-z]*[0-9])[0-9A-Za-z]{4,10}(?![0-9A-Za-z])")
private let otpSplitPattern = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z])[0-9]{2,5}[ -][0-9]{2,5}(?![0-9A-Za-z])")

/// Android packages that are SMS apps, for phones that do not yet say which app is the default.
let knownSmsPackages: Set<String> = [
    "com.google.android.apps.messaging",
    "com.android.mms",
    "com.android.messaging",
    "com.samsung.android.messaging",
    "com.oneplus.mms",
    "com.oplus.mms",
    "com.coloros.mms",
    "com.miui.mms",
    "com.motorola.messaging",
    "com.truecaller",
]

/// The four mail apps whose notifications may carry a code (email_codes_draft1, docs/codes-from-email.md):
/// Gmail, Outlook, Proton Mail and Spark. Only these, never other apps in the email category.
let knownMailPackages: Set<String> = [
    "com.google.android.gm",
    "com.microsoft.office.outlook",
    "ch.protonmail.android",
    "com.readdle.spark",
]

/// What the code reader may look at in one forwarded notification, and which text it reads.
enum CodeCandidate: Equatable {
    /// A text message: the notification text.
    case sms(String)
    /// A mail-app notification: the phone's `preview` if present, else the notification text.
    case email(String)

    var text: String {
        switch self {
        case let .sms(text), let .email(text): text
        }
    }

    var isEmail: Bool {
        if case .email = self { return true }
        return false
    }
}

/// Whether a forwarded notification is a message the code reader may look at.
func isCodeCandidate(packageName: String, smsDefaultApp: Bool?, redacted: Bool?, text: String,
                     emailApp: Bool? = nil, preview: String? = nil, emailCodes: Bool = false) -> Bool {
    codeCandidate(packageName: packageName, smsDefaultApp: smsDefaultApp, redacted: redacted, text: text,
                  emailApp: emailApp, preview: preview, emailCodes: emailCodes) != nil
}

/// The text to read, or nil when the notification is not a code candidate. Codes from messages being on is
/// checked by the caller; `emailCodes` is its "Also read codes in email" switch.
///
/// A mail notification counts only when the phone marked it `emailApp` (it does so only for the four mail
/// apps and never for a group summary) and, as a second check, its package is one of `knownMailPackages`.
func codeCandidate(packageName: String, smsDefaultApp: Bool?, redacted: Bool?, text: String,
                   emailApp: Bool? = nil, preview: String? = nil, emailCodes: Bool = false) -> CodeCandidate? {
    guard redacted != true else { return nil }
    let fromSmsApp = smsDefaultApp ?? knownSmsPackages.contains(packageName)
    if fromSmsApp {
        guard let trimmed = readableCodeText(text) else { return nil }
        return looksLikeOtpTraffic(trimmed) ? .sms(trimmed) : nil
    }
    guard emailCodes, emailApp == true, knownMailPackages.contains(packageName) else { return nil }
    let source = preview.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? text
    guard let trimmed = readableCodeText(source) else { return nil }
    return emailCodePrecheck(trimmed) ? .email(trimmed) : nil
}

/// Trimmed, non-empty and at most 600 UTF-16 units (as the relay counts them). A longer message is never
/// cut (that could drop the code).
private func readableCodeText(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf16.count <= CodeRelay.maximumTextLength else { return nil }
    return trimmed
}

// MARK: - Email pre-check

/*
 * The stricter pre-check for mail previews (docs/codes-from-email.md section 6). This is the one place
 * the rule lives: the Phase 0 email eval (outputs/bridgey/research/otp-tiny-model, email sets) may tune
 * the word lists and the window here.
 *
 * A preview passes when it passes `looksLikeOtpTraffic`, some code-shaped token (the same two patterns)
 * has a code word within `emailCodeWordWindow` characters before or after it, and that code word is not
 * part of a marketing phrase ("promo code", "use code", "20% off"). A mail that says "unsubscribe" and
 * has a marketing phrase anywhere is refused outright.
 */

/// Characters (UTF-16 units) before and after a token that are searched for a code word.
let emailCodeWordWindow = 60

/// Code words, case-insensitive, whole words. Russian stems take their usual endings.
private let emailCodeWords = try! NSRegularExpression(
    pattern: wordEdgeLeft + "(?:"
        + "codes?|otp|one[- ]time|passcodes?|verification|verify|pin|2fa|two[- ]factor|two[- ]step|security code"
        + "|sign[- ]in|log[- ]?in|authentication|confirm|confirmation"
        + "|код(?:а|у|ом|ы|е)?|парол(?:ь|я|ю|ем|и)|подтвержд[\\p{L}]*"
        + "|ओटीपी|कोड"
        + ")" + wordEdgeRight,
    options: [.caseInsensitive]
)

/// Marketing phrases: a code word inside one of these does not count.
private let emailMarketingPhrases = try! NSRegularExpression(
    pattern: wordEdgeLeft + "(?:promo(?:tional)? codes?|coupon(?: codes?)?|discount codes?|vouchers?(?: codes?)?|gift codes?"
        + "|referral codes?|offer codes?|use (?:the )?code)" + wordEdgeRight
        + "|\\d+ ?% ?off" + wordEdgeRight,
    options: [.caseInsensitive]
)

private let emailUnsubscribe = try! NSRegularExpression(pattern: "unsubscribe", options: [.caseInsensitive])

private let wordEdgeLeft = "(?<![\\p{L}\\p{M}\\p{N}])"
private let wordEdgeRight = "(?![\\p{L}\\p{M}\\p{N}])"

/// Whether a mail preview may hold a one-time code, before the model reads it. Pure, so it is tested.
func emailCodePrecheck(_ text: String) -> Bool {
    guard looksLikeOtpTraffic(text) else { return false }
    let whole = NSRange(location: 0, length: (text as NSString).length)
    let marketing = emailMarketingPhrases.matches(in: text, range: whole).map(\.range)
    if !marketing.isEmpty, emailUnsubscribe.firstMatch(in: text, range: whole) != nil { return false }
    let words = emailCodeWords.matches(in: text, range: whole).map(\.range)
        .filter { word in !marketing.contains { NSIntersectionRange($0, word).length > 0 } }
    guard !words.isEmpty else { return false }
    let tokens = (otpTokenPattern.matches(in: text, range: whole) + otpSplitPattern.matches(in: text, range: whole)).map(\.range)
    return tokens.contains { token in
        let start = max(0, token.location - emailCodeWordWindow)
        let end = min(whole.length, NSMaxRange(token) + emailCodeWordWindow)
        let window = NSRange(location: start, length: end - start)
        return words.contains { NSIntersectionRange($0, window).length > 0 && NSIntersectionRange($0, token).length == 0 }
    }
}

// MARK: - Relay

enum CodeRelay {
    static let maximumTextLength = 600
    static let maximumSenderLength = 64
    /// The whole read, from receipt to banner, never waits longer than this.
    static let budget: TimeInterval = 2
    /// Edition setting: rr-edition.properties OTP_PROXY_URL, copied into Info.plist by build-app.sh.
    static var baseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BridgeyCodeRelayURL") as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// A random per-install id, only ever used as the relay's rate-limit key.
    static func newInstallID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    static func isInstallID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The JSON body for POST /v1/extract; nil when the text is empty or over the relay's limit.
    static func requestBody(text: String, sender: String?) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maximumTextLength else { return nil }
        var body: [String: Any] = ["v": 1, "text": trimmed]
        if let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            body["sender"] = prefix(sender, utf16Limit: maximumSenderLength)
        }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Whole characters only, at most `utf16Limit` UTF-16 units (how the relay measures length).
    static func prefix(_ value: String, utf16Limit: Int) -> String {
        var result = ""
        for character in value {
            guard result.utf16.count + character.utf16.count <= utf16Limit else { break }
            result.append(character)
        }
        return result
    }

    static func request(baseURL: URL, installID: String, text: String, sender: String?) -> URLRequest? {
        guard isInstallID(installID), let body = requestBody(text: text, sender: sender) else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/extract"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: budget)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(installID, forHTTPHeaderField: "X-Bridgey-Install")
        // Cloudflare's browser check turns away some default agents; this one is plain and stable.
        request.setValue("BridgeyRR/1 (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Reads the relay's answer. Only a 200 with `is_otp` true and a string code yields a candidate.
    static func parse(status: Int, data: Data) -> CodeRelayAnswer {
        switch status {
        case 200:
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let isOTP = object["is_otp"] as? Bool else { return .failed(.invalidResponse) }
            guard isOTP, let code = object["code"] as? String, !code.isEmpty else { return .noCode }
            return .candidate(code)
        case 422: return .noCode
        case 429: return .failed(.rateLimited)
        case 504: return .failed(.timeout)
        default: return .failed(.unavailable)
        }
    }
}

enum CodeReadFailure: String, Equatable {
    case timeout, rateLimited = "rate_limited", unavailable, invalidResponse = "invalid_response", notConfigured = "not_configured"
    /// On this Mac was chosen but the model is not downloaded (or was removed).
    case modelMissing = "model_missing"
}

enum CodeRelayAnswer: Equatable {
    case candidate(String)
    case noCode
    case failed(CodeReadFailure)
}

/// What the Mac shows for one message.
enum CodeReadOutcome: Equatable {
    /// A code that passed the guard.
    case code(String)
    /// The model found no code, or the guard refused its answer.
    case noCode
    case fallback(CodeReadFailure)

    /// For diagnostics: an outcome word, never the code.
    var diagnosticName: String {
        switch self {
        case .code: "found"
        case .noCode: "none"
        case let .fallback(reason): reason.rawValue
        }
    }
}

/// Sends one request to the relay. A protocol so tests can stand in for the network.
protocol CodeRelayTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Int, Data)
}

struct URLSessionCodeRelayTransport: CodeRelayTransport {
    /// No cache, no cookies, no stored credentials: the request carries a live code.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = CodeRelay.budget
        configuration.timeoutIntervalForResource = CodeRelay.budget
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await Self.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Where the answer comes from: the relay (cloud) or the model on this Mac. Either returns the same
/// `CodeRelayAnswer`, so the budget, the guard and the fallback are shared.
protocol CodeAnswerSource: Sendable {
    func answer(text: String, sender: String?) async -> CodeRelayAnswer
}

/// The cloud engine: Round Robin's relay to Cloudflare Workers AI.
struct CloudCodeSource: CodeAnswerSource {
    let baseURL: URL
    let installID: String
    var transport: CodeRelayTransport = URLSessionCodeRelayTransport()

    func answer(text: String, sender: String?) async -> CodeRelayAnswer {
        guard let request = CodeRelay.request(baseURL: baseURL, installID: installID, text: text, sender: sender) else {
            return .failed(.notConfigured)
        }
        do {
            let (status, data) = try await transport.send(request)
            return CodeRelay.parse(status: status, data: data)
        } catch {
            return .failed((error as? URLError)?.code == .timedOut ? .timeout : .unavailable)
        }
    }
}

/// One message in, one outcome out, within `budget` seconds.
struct CodeReader: Sendable {
    /// Nil when the chosen engine cannot run (no relay address in this build).
    let source: CodeAnswerSource?
    var budget: TimeInterval = CodeRelay.budget

    init(source: CodeAnswerSource?, budget: TimeInterval = CodeRelay.budget) {
        self.source = source
        self.budget = budget
    }

    /// The cloud engine.
    init(baseURL: URL?, installID: String, transport: CodeRelayTransport = URLSessionCodeRelayTransport(), budget: TimeInterval = CodeRelay.budget) {
        self.init(source: baseURL.map { CloudCodeSource(baseURL: $0, installID: installID, transport: transport) }, budget: budget)
    }

    func read(text: String, sender: String?) async -> CodeReadOutcome {
        guard let source else { return .fallback(.notConfigured) }
        // Whichever comes first, the answer or the budget. The engine is not waited for after the
        // budget: the model on this Mac cannot be stopped mid-answer, and the plain notification
        // must not wait for it.
        let race = CodeAnswerRace()
        let budget = budget
        let answer: CodeRelayAnswer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.start(continuation, budget: budget) { await source.answer(text: text, sender: sender) }
            }
        } onCancel: {
            race.finish(.failed(.timeout))
        }
        switch answer {
        case let .candidate(code):
            return CodeGuard.accept(code, in: text).map(CodeReadOutcome.code) ?? .noCode
        case .noCode:
            return .noCode
        case let .failed(reason):
            return .fallback(reason)
        }
    }
}

/// Resumes once, with the first of the answer and the budget, and cancels the other.
private final class CodeAnswerRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CodeRelayAnswer, Never>?
    private var early: CodeRelayAnswer?
    private var done = false
    private var tasks: [Task<Void, Never>] = []

    func start(_ continuation: CheckedContinuation<CodeRelayAnswer, Never>, budget: TimeInterval,
               operation: @escaping @Sendable () async -> CodeRelayAnswer) {
        lock.lock()
        if done {
            let value = early ?? .failed(.timeout)
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        tasks = [
            Task { self.finish(await operation()) },
            Task {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                self.finish(.failed(.timeout))
            },
        ]
        lock.unlock()
    }

    func finish(_ value: CodeRelayAnswer) {
        lock.lock()
        guard !done else { return lock.unlock() }
        done = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { early = value }
        let running = tasks
        tasks = []
        lock.unlock()
        waiting?.resume(returning: value)
        running.forEach { $0.cancel() }
    }
}

// MARK: - Presentation

/// "Code 482913 from HDFC Bank": the sender is the SMS notification's title (the contact or the
/// sender ID), else the app's name.
func codeNotificationTitle(code: String, sender: String, applicationName: String) -> String {
    let from = sender.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(
        format: L10n.text("codes.notification.title", fallback: "Code %1$@ from %2$@"),
        code,
        from.isEmpty ? applicationName : String(from.prefix(64))
    )
}

/// Auto-copy runs only when someone is at this Mac: unlocked, and input in the last two minutes.
func shouldAutoCopyCode(enabled: Bool, screenLocked: Bool, idleSeconds: TimeInterval) -> Bool {
    enabled && !screenLocked && idleSeconds < 120
}

/// The phone's own report of whether Android shows message text to Bridgey.
enum CodeAccessStatus: String, Equatable {
    /// Android shows Bridgey the full text (companion link, the ADB permission, or Android 14 and older).
    case allowed
    /// Android replaced message text with "Sensitive notification content hidden".
    case hidden
    /// Android 15 or newer and no companion link yet.
    case notLinked = "not_linked"

    /// A phone sends one of these words in `codes.status`; anything else is ignored.
    init?(wire: String) {
        self.init(rawValue: wire)
    }
}
