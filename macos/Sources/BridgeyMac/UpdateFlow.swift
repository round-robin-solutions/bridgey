import Foundation

/// Where an in-app update stands. Drawn by Settings > Updates and the Stream panel's live card;
/// Sparkle's own windows are never shown (see `InAppUpdateDriver`).
enum UpdateFlow: Equatable {
    case idle
    /// A check the user started.
    case checking
    case available(UpdateOffer)
    case downloading(version: String, received: UInt64, expected: UInt64?)
    case extracting(version: String, progress: Double)
    case ready(version: String)
    case installing(version: String)
    /// Only after a check the user started.
    case upToDate
    case failed(message: String)

    /// 0...1 when the step has a known size, nil for an indeterminate step.
    var progress: Double? {
        switch self {
        case let .downloading(_, received, expected):
            guard let expected, expected > 0 else { return nil }
            return min(1, Double(received) / Double(expected))
        case let .extracting(_, progress):
            return min(1, max(0, progress))
        default:
            return nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .installing: true
        default: false
        }
    }

    /// Whether the Stream panel shows a live card. Manual check results stay in Settings.
    var showsInPanel: Bool {
        switch self {
        case .idle, .checking, .upToDate: false
        default: true
        }
    }
}

struct UpdateOffer: Equatable {
    let version: String
    /// Plain text, already stripped of markup. Nil until the notes arrive (or if there are none).
    var notes: String?
    /// The archive is already on disk, so Install goes straight to the restart.
    var downloaded: Bool
    var userInitiated: Bool
}

/// User-visible words for each state, shared by the panel card and Settings.
enum UpdateFlowText {
    static func title(_ flow: UpdateFlow) -> String {
        switch flow {
        case .idle: ""
        case .checking: L10n.text("update.checking", fallback: "Checking for updates…")
        case let .available(offer):
            String(format: L10n.text("update.available", fallback: "Update %@ available"), offer.version)
        case let .downloading(version, _, _):
            String(format: L10n.text("update.downloading", fallback: "Downloading %@"), version)
        case let .extracting(version, _):
            String(format: L10n.text("update.preparing", fallback: "Preparing %@"), version)
        case let .ready(version):
            String(format: L10n.text("update.ready", fallback: "Update %@ ready"), version)
        case let .installing(version):
            String(format: L10n.text("update.installing", fallback: "Installing %@"), version)
        case .upToDate: L10n.text("update.upToDate", fallback: "You're up to date")
        case .failed: L10n.text("update.failed", fallback: "Update didn't finish")
        }
    }

    static func detail(_ flow: UpdateFlow, currentVersion: String) -> String? {
        switch flow {
        case .idle, .checking: nil
        case let .available(offer):
            offer.downloaded
                ? L10n.text("update.available.downloaded", fallback: "Downloaded and ready. Restart Bridgey to update.")
                : L10n.text("update.available.detail", fallback: "Install now, or later from Settings.")
        case let .downloading(_, received, expected):
            if let expected, expected > 0 {
                String(format: L10n.text("update.downloading.detail", fallback: "%@ of %@"),
                       byteText(received), byteText(expected))
            } else {
                byteText(received)
            }
        case .extracting: L10n.text("update.preparing.detail", fallback: "Checking the download and unpacking it")
        case .ready: L10n.text("update.ready.detail", fallback: "Restart to update")
        case .installing: L10n.text("update.installing.detail", fallback: "Bridgey restarts in a moment")
        case .upToDate:
            String(format: L10n.text("update.upToDate.detail", fallback: "Version %@ is the newest on your channel."), currentVersion)
        case let .failed(message): message
        }
    }

    /// The panel card's one-line summary, for example "Update 0.6.0 ready · Restart to update".
    static func line(_ flow: UpdateFlow, currentVersion: String) -> String {
        [title(flow), detail(flow, currentVersion: currentVersion)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// Sparkle and network errors in plain words. Codes are Sparkle's `SUError` values.
    static func errorMessage(domain: String, code: Int) -> String {
        if domain == NSURLErrorDomain {
            return L10n.text("update.error.network", fallback: "Couldn't reach the update server. Check the connection and try again.")
        }
        guard domain == "SUSparkleErrorDomain" else {
            return L10n.text("update.error.generic", fallback: "Something went wrong. Try again later.")
        }
        switch code {
        case 1000, 1002, 1004:
            return L10n.text("update.error.feed", fallback: "The update list couldn't be read. Try again later.")
        case 1003, 1005, 4012:
            return L10n.text("update.error.location", fallback: "Bridgey can't replace itself where it is. Move it to Applications and try again.")
        case 2000, 2001:
            return L10n.text("update.error.download", fallback: "The download didn't finish. Check the connection and try again.")
        case 3000:
            return L10n.text("update.error.unpack", fallback: "The download couldn't be unpacked. Try again later.")
        case 3001, 3002, 4009:
            return L10n.text("update.error.signature", fallback: "The download failed its safety check, so nothing was installed.")
        case 4001, 4007, 4008:
            return L10n.text("update.error.canceled", fallback: "The update was cancelled. Nothing changed.")
        default:
            return L10n.text("update.error.generic", fallback: "Something went wrong. Try again later.")
        }
    }

    /// Release notes as plain text: drops tags, keeps paragraphs and list items as lines.
    static func plainNotes(_ raw: String) -> String? {
        var text = raw
        let blockBreaks = ["<br", "</p>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</div>", "</ul>", "</ol>"]
        for tag in blockBreaks {
            text = text.replacingOccurrences(of: tag, with: "\n\(tag)", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&amp;": "&"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        let joined = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
