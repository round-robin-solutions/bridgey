import Foundation

/*
 * Codes from messages (edition): finds a one-time code in an SMS the phone forwarded, so the Mac can
 * show "Code 482913 from HDFC Bank" with a Copy button. Off by default; when on, the message text is
 * sent to Round Robin's relay (services/otp-proxy), which asks Cloudflare Workers AI. The model
 * decides; the guard here only refuses an answer that is not literally in the message or does not
 * look like a code. Any refusal, error or timeout shows the plain notification instead.
 *
 * Message text and codes are never logged, whatever Settings > Privacy > Logging says.
 */

/// Accepts the model's code only if it appears verbatim in the message and looks like a code.
enum CodeGuard {
    /// The code to show and copy (separators and a short prefix such as "G-" removed, letter case as in
    /// the message), or nil to fall back to the plain notification.
    ///
    /// Rules: every part (split on spaces and hyphens) contains a digit, except one leading prefix of
    /// one or two letters; 4 to 10 letters or digits in all; and the code is in the message as a whole
    /// token, with an optional space or hyphen between characters ("591-047", "441 902").
    static func accept(_ answer: String?, in text: String) -> String? {
        guard let raw = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 24 else { return nil }
        var parts = raw.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        if parts.count > 1, (1...2).contains(parts[0].count), parts[0].allSatisfy(\.isASCIILetter) {
            parts.removeFirst()
        }
        guard !parts.isEmpty, parts.allSatisfy({ $0.contains(where: \.isASCIIDigit) }) else { return nil }
        let core = parts.joined()
        guard (4...10).contains(core.count), core.allSatisfy(\.isASCIIAlphanumeric) else { return nil }
        let body = core.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s-]?")
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![0-9A-Za-z])" + body + "(?![0-9A-Za-z])",
            options: [.caseInsensitive]
        ),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text) else { return nil }
        return String(text[range].filter(\.isASCIIAlphanumeric))
    }
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

/// Whether a forwarded notification is a message the code reader may look at.
func isCodeCandidate(packageName: String, smsDefaultApp: Bool?, redacted: Bool?, text: String) -> Bool {
    guard redacted != true else { return false }
    let fromSmsApp = smsDefaultApp ?? knownSmsPackages.contains(packageName)
    guard fromSmsApp else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // UTF-16 units, as the relay counts them. A longer message is never cut (that could drop the code).
    guard !trimmed.isEmpty, trimmed.utf16.count <= CodeRelay.maximumTextLength else { return false }
    return looksLikeOtpTraffic(trimmed)
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

/// One message in, one outcome out, within `budget` seconds.
struct CodeReader: Sendable {
    let baseURL: URL?
    let installID: String
    var transport: CodeRelayTransport = URLSessionCodeRelayTransport()
    var budget: TimeInterval = CodeRelay.budget

    func read(text: String, sender: String?) async -> CodeReadOutcome {
        guard let baseURL, let request = CodeRelay.request(baseURL: baseURL, installID: installID, text: text, sender: sender) else {
            return .fallback(.notConfigured)
        }
        let transport = transport
        let budget = budget
        let answer: CodeRelayAnswer = await withTaskGroup(of: CodeRelayAnswer?.self) { group in
            group.addTask {
                do {
                    let (status, data) = try await transport.send(request)
                    return CodeRelay.parse(status: status, data: data)
                } catch {
                    return Task.isCancelled ? nil : .failed((error as? URLError)?.code == .timedOut ? .timeout : .unavailable)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return Task.isCancelled ? nil : .failed(.timeout)
            }
            var first: CodeRelayAnswer = .failed(.timeout)
            for await value in group {
                if let value {
                    first = value
                    break
                }
            }
            group.cancelAll()
            return first
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
