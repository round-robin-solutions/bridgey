import Foundation
import os

/// Settings > Privacy > Logging: what Bridgey writes to the unified log and to exported
/// diagnostics. Per Mac; privacy-leaning defaults except call events, which stay on so call
/// problems can be traced. Content fields (numbers, notification text, clipboard previews, file
/// names) are off by default and only ever reach the local log, never exported diagnostics.
struct LoggingPolicy: Equatable {
    /// Discovery, pairing, transport and reconnects.
    var connection = true
    /// Call state changes and the caller's name.
    var calls = true
    /// Phone numbers in call events; off masks them.
    var callNumbers = false
    /// Which app posted a notification and what happened to it.
    var notifications = true
    /// Notification titles and text.
    var notificationContent = false
    /// Clipboard sends and receipts.
    var clipboard = true
    /// The first characters of clipboard text.
    var clipboardPreviews = false
    /// File and folder names in transfer events (the events themselves are always logged).
    var fileNames = false
    /// Remote control session start and end. The remote control audit is separate.
    var remoteControl = true

    func allows(_ category: LogCategory) -> Bool {
        switch category {
        case .connection: return connection
        case .calls: return calls
        case .notifications: return notifications
        case .clipboard: return clipboard
        case .remoteControl: return remoteControl
        case .files, .general: return true
        }
    }
}

enum LogCategory {
    case connection, calls, notifications, clipboard, files, remoteControl, general
}

/// The logging category of a diagnostics event category.
func diagnosticLogCategory(_ category: String) -> LogCategory {
    switch category {
    case "discovery", "pairing", "reconnect", "transport", "protocol", "power", "link": return .connection
    case "call", "calls": return .calls
    case "notification": return .notifications
    case "clipboard": return .clipboard
    case "transfer", "folder": return .files
    case "remote": return .remoteControl
    default: return .general
    }
}

private let phoneNumberPattern = try! NSRegularExpression(pattern: #"[+(]?\d[\d\s().-]{4,}\d"#)

/// Masks anything that looks like a phone number (6 or more digits with separators).
func maskPhoneNumbers(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    var result = text
    for match in phoneNumberPattern.matches(in: text, range: range).reversed() {
        guard let swiftRange = Range(match.range, in: text) else { continue }
        if text[swiftRange].filter(\.isNumber).count >= 6 {
            result.replaceSubrange(Range(match.range, in: result)!, with: "[number]")
        }
    }
    return result
}

/// Builds log lines from only the fields the policy allows; nil when the category is off, so
/// nothing is written. Pure, so tests pin what can reach the log. Lines are logged as public:
/// they hold only what the person chose to log.
enum LogLines {
    static func call(_ policy: LoggingPolicy, event: String, id: String, peer: String, reason: String, caller: String? = nil) -> String? {
        guard policy.calls else { return nil }
        var line = "call \(event) id=\(shortCallID(id)) peer=\(shortDeviceID(peer)) reason=\(reason)"
        if let caller = caller?.trimmingCharacters(in: .whitespacesAndNewlines), !caller.isEmpty {
            line += " caller=\"\((policy.callNumbers ? caller : maskPhoneNumbers(caller)).prefix(80))\""
        }
        return line
    }

    static func notification(_ policy: LoggingPolicy, event: String, appName: String, title: String? = nil, text: String? = nil) -> String? {
        guard policy.notifications else { return nil }
        var line = "notification \(event) app=\"\(appName.prefix(64))\""
        if policy.notificationContent {
            if let title, !title.isEmpty { line += " title=\"\(title.prefix(80))\"" }
            if let text, !text.isEmpty { line += " text=\"\(text.prefix(160))\"" }
        }
        return line
    }

    static func clipboard(_ policy: LoggingPolicy, event: String, preview: String? = nil) -> String? {
        guard policy.clipboard else { return nil }
        var line = "clipboard \(event)"
        if policy.clipboardPreviews, let preview = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            line += " preview=\"\(preview.replacingOccurrences(of: "\n", with: " ").prefix(40))\""
        }
        return line
    }

    static func file(_ policy: LoggingPolicy, event: String, transfer: String, name: String? = nil, extra: String = "") -> String {
        var line = "file \(event) transfer=\(transfer.prefix(8))"
        if !extra.isEmpty { line += " \(extra)" }
        if policy.fileNames, let name, !name.isEmpty { line += " name=\"\(name.prefix(120))\"" }
        return line
    }
}

/// The current policy, readable from any thread.
final class LoggingPolicyStore: @unchecked Sendable {
    static let shared = LoggingPolicyStore()
    private let lock = NSLock()
    private var value = LoggingPolicy()

    var policy: LoggingPolicy {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Bridgey's unified-log categories, all under the subsystem `in.roundrobin.bridgey`.
///
/// Read them on the Mac with:
/// `/usr/bin/log show --last 12h --predicate 'subsystem == "in.roundrobin.bridgey"'`
///
/// Connection lifecycle events use `notice`, which macOS keeps on disk, so they are still there
/// the next morning; `info` stays in memory only. A category turned off in Settings > Privacy >
/// Logging gets a disabled logger, so nothing is written. Privacy: states, reasons, counts, error
/// codes and 8-character id prefixes are public. Names and text are public only when their
/// Logging switch is on (`LogLines`); otherwise they are never logged.
enum BridgeyLog {
    static let subsystem = "in.roundrobin.bridgey"
    static let disabled = Logger(OSLog.disabled)

    static var policy: LoggingPolicy {
        get { LoggingPolicyStore.shared.policy }
        set { LoggingPolicyStore.shared.policy = newValue }
    }

    private static let discoveryLogger = Logger(subsystem: subsystem, category: "discovery")
    private static let transportLogger = Logger(subsystem: subsystem, category: "transport")
    private static let reconnectLogger = Logger(subsystem: subsystem, category: "reconnect")
    private static let pairingLogger = Logger(subsystem: subsystem, category: "pairing")
    private static let callsLogger = Logger(subsystem: subsystem, category: "calls")
    private static let notificationsLogger = Logger(subsystem: subsystem, category: "notifications")
    private static let clipboardLogger = Logger(subsystem: subsystem, category: "clipboard")
    private static let remoteLogger = Logger(subsystem: subsystem, category: "remote")

    static var discovery: Logger { policy.connection ? discoveryLogger : disabled }
    static var transport: Logger { policy.connection ? transportLogger : disabled }
    static var reconnect: Logger { policy.connection ? reconnectLogger : disabled }
    static var pairing: Logger { policy.connection ? pairingLogger : disabled }
    /// Phone call cards: state changes, removals and reasons with 8-character ids.
    static var calls: Logger { policy.calls ? callsLogger : disabled }
    static var notifications: Logger { policy.notifications ? notificationsLogger : disabled }
    static var clipboard: Logger { policy.clipboard ? clipboardLogger : disabled }
    static var remote: Logger { policy.remoteControl ? remoteLogger : disabled }
    /// File and folder transfers (names only through `LogLines.file`).
    static let files = Logger(subsystem: subsystem, category: "files")
    /// Battery, ping, find device and other events with no personal content.
    static let plugin = Logger(subsystem: subsystem, category: "plugin")
    /// Phone screen streams: stream id prefixes, sizes, rates, latency and counts; never pixels or names.
    static let screen = Logger(subsystem: subsystem, category: "screen")

    /// Writes a line built by `LogLines`; nil (category off) writes nothing.
    static func line(_ logger: Logger, _ line: String?) {
        guard let line else { return }
        logger.notice("\(line, privacy: .public)")
    }
}

/// The first eight characters of a device id: enough to tell devices apart in logs.
func shortDeviceID(_ id: String) -> String { String(id.prefix(8)) }
