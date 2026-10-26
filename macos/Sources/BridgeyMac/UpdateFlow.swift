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
    /// The release page (Sparkle's full release notes link), HTTPS only.
    var notesURL: URL? = nil
}

/// An update the user put off in this session, so Settings does not claim "Up to date".
struct UpdateDeferral: Equatable {
    enum Kind: Equatable {
        /// Later before the download: Sparkle reminds at its next scheduled check.
        case later
        /// Later after the download: Sparkle installs it when Bridgey quits.
        case onQuit
        case skipped
    }

    let version: String
    let kind: Kind

    /// What Later or Skip leaves behind for `flow`, or nil when nothing was on offer.
    static func putOff(_ flow: UpdateFlow, skipped: Bool) -> UpdateDeferral? {
        switch flow {
        case let .available(offer):
            UpdateDeferral(version: offer.version, kind: skipped ? .skipped : offer.downloaded ? .onQuit : .later)
        case let .ready(version) where !skipped:
            UpdateDeferral(version: version, kind: .onQuit)
        default:
            nil
        }
    }

    /// A new offer, an install or a clean check replaces the old note; other steps keep it.
    static func after(_ flow: UpdateFlow, keeping current: UpdateDeferral?) -> UpdateDeferral? {
        switch flow {
        case .available, .downloading, .extracting, .ready, .installing, .upToDate: nil
        case .idle, .checking, .failed: current
        }
    }
}

/// User-visible words for each state. The Stream panel's card is short ("beta.10 ready"); Settings
/// names the full version once, in the status card.
enum UpdateFlowText {
    // MARK: Stream panel card

    static func title(_ flow: UpdateFlow, currentVersion: String) -> String {
        switch flow {
        case .idle: ""
        case .checking: L10n.text("update.checking", fallback: "Checking for updates…")
        case let .available(offer):
            String(format: L10n.text("update.ready.short", fallback: "%@ ready"), shortVersion(offer.version, comparedTo: currentVersion))
        case let .downloading(version, _, _):
            String(format: L10n.text("update.downloading", fallback: "Downloading %@"), shortVersion(version, comparedTo: currentVersion))
        case let .extracting(version, _):
            String(format: L10n.text("update.preparing", fallback: "Preparing %@"), shortVersion(version, comparedTo: currentVersion))
        case let .ready(version):
            String(format: L10n.text("update.ready.short", fallback: "%@ ready"), shortVersion(version, comparedTo: currentVersion))
        case let .installing(version):
            String(format: L10n.text("update.installing", fallback: "Installing %@"), shortVersion(version, comparedTo: currentVersion))
        case .upToDate: L10n.text("update.upToDate", fallback: "You're up to date")
        case .failed: L10n.text("update.failed", fallback: "Update didn't finish")
        }
    }

    /// The panel card's second line. Ready states have none: the button says what happens.
    static func detail(_ flow: UpdateFlow) -> String? {
        switch flow {
        case .idle, .checking, .available, .ready, .upToDate: nil
        case let .downloading(_, received, expected): progressText(received: received, expected: expected)
        case .extracting: L10n.text("update.preparing.detail", fallback: "Checking the download and unpacking it")
        case .installing: L10n.text("update.installing.detail", fallback: "Bridgey restarts in a moment")
        case let .failed(message): message
        }
    }

    /// The main action of a ready update: Install, or Restart to update once it is on disk.
    static func primaryAction(_ flow: UpdateFlow) -> String? {
        switch flow {
        case let .available(offer):
            offer.downloaded ? L10n.text("update.restart", fallback: "Restart to update") : L10n.text("update.install", fallback: "Install")
        case .ready: L10n.text("update.restart", fallback: "Restart to update")
        default: nil
        }
    }

    /// The panel card in one line, for example "beta.10 ready · Install" or "beta.10 ready · Restart to update".
    static func line(_ flow: UpdateFlow, currentVersion: String) -> String {
        [title(flow, currentVersion: currentVersion), primaryAction(flow) ?? detail(flow)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Settings status card

    static func settingsTitle(_ flow: UpdateFlow, currentVersion: String) -> String {
        switch flow {
        case .idle, .upToDate:
            String(format: L10n.text("updates.current", fallback: "Bridgey %@"), currentVersion)
        case .checking: L10n.text("update.checking", fallback: "Checking for updates…")
        case let .available(offer):
            String(format: L10n.text("updates.isReady", fallback: "%@ is ready"), offer.version)
        case let .downloading(version, _, _):
            String(format: L10n.text("update.downloading", fallback: "Downloading %@"), version)
        case let .extracting(version, _):
            String(format: L10n.text("update.preparing", fallback: "Preparing %@"), version)
        case let .ready(version):
            String(format: L10n.text("updates.isReady", fallback: "%@ is ready"), version)
        case let .installing(version):
            String(format: L10n.text("update.installing", fallback: "Installing %@"), version)
        case .failed: L10n.text("update.failed", fallback: "Update didn't finish")
        }
    }

    /// The status card's second line. Idle and up-to-date states use `idleDetail`.
    static func settingsDetail(_ flow: UpdateFlow, currentVersion: String) -> String? {
        switch flow {
        case .idle, .upToDate, .checking: nil
        case let .available(offer):
            offer.downloaded
                ? L10n.text("updates.downloaded", fallback: "Downloaded. Restart Bridgey to finish.")
                : String(format: L10n.text("updates.youHave", fallback: "You have %@"), shortVersion(currentVersion, comparedTo: offer.version))
        case .ready: L10n.text("updates.downloaded", fallback: "Downloaded. Restart Bridgey to finish.")
        default: detail(flow)
        }
    }

    /// "Up to date · checked 3:58 PM", or what is waiting when the user put an update off.
    static func idleDetail(
        updatesAvailable: Bool,
        lastCheck: Date?,
        deferral: UpdateDeferral?,
        currentVersion: String,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        guard updatesAvailable else {
            return L10n.text("updates.unavailable", fallback: "Updates work only in the installed app.")
        }
        if let deferral {
            let version = shortVersion(deferral.version, comparedTo: currentVersion)
            return switch deferral.kind {
            case .later: String(format: L10n.text("updates.waiting", fallback: "%@ is available"), version)
            case .onQuit: String(format: L10n.text("updates.onQuit", fallback: "%@ installs when Bridgey quits"), version)
            case .skipped: String(format: L10n.text("updates.skipped", fallback: "You skipped %@"), version)
            }
        }
        guard let lastCheck else { return L10n.text("updates.notChecked", fallback: "Not checked yet") }
        let when = calendar.isDate(lastCheck, inSameDayAs: now)
            ? lastCheck.formatted(date: .omitted, time: .shortened)
            : lastCheck.formatted(.dateTime.day().month(.abbreviated))
        return String(format: L10n.text("updates.upToDate.checked", fallback: "Up to date · checked %@"), when)
    }

    /// The part of `version` that differs from `other`: "beta.10" when both are pre-releases of
    /// the same release, otherwise the whole version.
    static func shortVersion(_ version: String, comparedTo other: String) -> String {
        func split(_ value: String) -> (base: String, pre: String?) {
            for marker in ["-beta.", "-nightly."] {
                if let range = value.range(of: marker) {
                    return (String(value[..<range.lowerBound]), String(value[value.index(after: range.lowerBound)...]))
                }
            }
            return (value, nil)
        }
        let mine = split(version)
        guard let pre = mine.pre, mine.base == split(other).base else { return version }
        return pre
    }

    private static func progressText(received: UInt64, expected: UInt64?) -> String {
        if let expected, expected > 0 {
            return String(format: L10n.text("update.downloading.detail", fallback: "%@ of %@"), byteText(received), byteText(expected))
        }
        return byteText(received)
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

/// One piece of release notes as Settings draws it.
enum ReleaseNoteBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)

    var text: String {
        switch self {
        case let .heading(text), let .bullet(text), let .paragraph(text): text
        }
    }
}

/// Turns release notes (plain text or Markdown, one item per line) into headings, bullets and
/// paragraphs, so Settings can draw a real list. The Android app has the same rules.
enum ReleaseNotes {
    private static let bulletPattern = #"^(?:[-*+•–]|\d{1,3}[.)])\s+"#
    private static let headingPattern = #"^#{1,6}\s*"#

    /// - Parameter version: dropped where the notes repeat it as a line or heading (the card names it already).
    static func blocks(_ notes: String, version: String? = nil) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        var open = false  // the last block may take a wrapped continuation line
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.allSatisfy({ "-*_=".contains($0) }) {
                open = false
                continue
            }
            if let range = line.range(of: headingPattern, options: .regularExpression), line.hasPrefix("#") {
                let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, !isVersion(text, version) { blocks.append(.heading(text)) }
                open = false
                continue
            }
            if isVersion(line, version) {
                open = false
                continue
            }
            if let range = line.range(of: bulletPattern, options: .regularExpression) {
                let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    blocks.append(.bullet(text))
                    open = true
                }
                continue
            }
            if open, let last = blocks.last, continues(last.text, with: line) {
                blocks[blocks.count - 1] = joined(last, line)
                continue
            }
            blocks.append(.paragraph(line))
            open = true
        }
        return blocks
    }

    /// The first blocks that fit about `lines` lines of `charsPerLine` characters; always at least one.
    /// A heading is never left as the last block of the preview.
    static func preview(_ blocks: [ReleaseNoteBlock], lines: Int = 4, charsPerLine: Int = 72) -> [ReleaseNoteBlock] {
        var used = 0
        var result: [ReleaseNoteBlock] = []
        for block in blocks {
            let cost = max(1, Int((Double(block.text.count) / Double(max(1, charsPerLine))).rounded(.up)))
            if !result.isEmpty, used + cost > lines { break }
            result.append(block)
            used += cost
        }
        while result.count > 1, let last = result.last, case .heading = last { result.removeLast() }
        return result
    }

    private static func isVersion(_ text: String, _ version: String?) -> Bool {
        guard let version, !version.isEmpty else { return false }
        let lowered = text.lowercased()
        return [version, "v\(version)", "bridgey \(version)", "bridgey v\(version)"].contains { lowered == $0.lowercased() }
    }

    /// A wrapped line continues the item above unless that item already ended a sentence.
    private static func continues(_ previous: String, with line: String) -> Bool {
        guard let end = previous.last else { return false }
        if let first = line.first, first.isLowercase { return true }
        return !".!?:".contains(end)
    }

    private static func joined(_ block: ReleaseNoteBlock, _ line: String) -> ReleaseNoteBlock {
        switch block {
        case let .bullet(text): .bullet("\(text) \(line)")
        case let .paragraph(text): .paragraph("\(text) \(line)")
        case .heading: block
        }
    }
}
