import Foundation
import UniformTypeIdentifiers

// The Transfers window (live transfers and history in one window): pure types and functions, so tests and
// screenshots use them without a running transfer. The views are in TransfersWindowView.swift.

/// What an item is, for the filter chips, the media grid and the type tile.
enum TransferKind: Equatable {
    case photo, video, document, folder

    static func of(name: String, isFolder: Bool) -> TransferKind {
        if isFolder { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .document }
        kindsLock.lock()
        defer { kindsLock.unlock() }
        if let known = kinds[ext] { return known }
        let kind: TransferKind
        if let type = UTType(filenameExtension: ext) {
            kind = type.conforms(to: .image) ? .photo : (type.conforms(to: .movie) || type.conforms(to: .video)) ? .video : .document
        } else {
            kind = .document
        }
        // A history of 2,000 entries asks for the same few extensions each time it is rebuilt.
        if kinds.count >= 512 { kinds.removeAll() }
        kinds[ext] = kind
        return kind
    }

    private static var kinds: [String: TransferKind] = [:]
    private static let kindsLock = NSLock()

    var isMedia: Bool { self == .photo || self == .video }
}

/// The type tile's colour.
enum TransferTileStyle: Equatable { case blue, green, purple, warn, neutral }

/// The type tile: a short extension label ("PDF", "JSON") or a symbol, and its colour.
struct TransferTile: Equatable {
    let label: String?
    let symbol: String?
    let style: TransferTileStyle

    static func of(name: String, kind: TransferKind) -> TransferTile {
        switch kind {
        case .folder: return TransferTile(label: nil, symbol: "folder", style: .green)
        case .photo: return TransferTile(label: nil, symbol: "photo", style: .blue)
        case .video: return TransferTile(label: nil, symbol: "film", style: .purple)
        case .document: break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, ext.count <= 4 else { return TransferTile(label: nil, symbol: "doc", style: .blue) }
        let style: TransferTileStyle
        switch ext {
        case "pdf", "key", "ppt", "pptx": style = .warn
        case "zip", "rar", "7z", "tar", "gz", "tgz", "xz", "dmg", "apk", "pkg": style = .purple
        case "xls", "xlsx", "csv", "numbers": style = .green
        default: style = .blue
        }
        return TransferTile(label: ext.uppercased(), symbol: nil, style: style)
    }
}

/// One finished or failed transfer in the history list: a history entry, joined with its row while this Mac
/// still has one (for Retry, Resume and the reason a transfer stopped), or a failed row history never saw.
struct TransferItem: Identifiable, Equatable {
    let id: String
    let date: Date
    let name: String
    let kind: TransferKind
    let direction: TransferHistoryEntry.Direction
    let deviceID: String
    let deviceName: String
    let bytes: Int64
    let fileCount: Int
    let outcome: TransferHistoryEntry.Outcome
    let localURL: URL?
    /// Why it stopped, in plain words, and whether it reads Stopped or Failed. Nil for a completed transfer.
    let reason: String?
    let chip: TransferFailure.Chip?
    let canRetry: Bool
    let canResume: Bool
    /// Only in this session's rows, not in the saved history.
    let sessionOnly: Bool

    var failed: Bool { outcome != .completed }
    /// Shown in the media grid: photos and videos that arrived or went out whole.
    var inGrid: Bool { kind.isMedia && !failed }
}

enum TransferItems {
    /// History entries, newest first, joined with this session's rows; failed rows the history never recorded
    /// (a queued file stopped by a disconnect) are added from the rows.
    static func make(entries: [TransferHistoryEntry], rows: [FileTransferRow], deviceName: (String) -> String) -> [TransferItem] {
        let rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [TransferItem] = entries.map { entry in
            let row = rowsByID[entry.id].flatMap { $0.active ? nil : $0 }
            let outcome = entry.outcome
            return TransferItem(
                id: entry.id, date: entry.date, name: entry.name, kind: TransferKind.of(name: entry.name, isFolder: entry.isFolder),
                direction: entry.direction, deviceID: entry.deviceID, deviceName: entry.deviceName, bytes: entry.bytes,
                fileCount: entry.fileCount, outcome: outcome, localURL: entry.localURL,
                reason: outcome == .completed ? nil : TransferFailure.reason(row: row, outcome: outcome, deviceName: entry.deviceName, isFolder: entry.isFolder),
                chip: outcome == .completed ? nil : TransferFailure.chip(row: row, outcome: outcome),
                canRetry: outcome != .completed && (row.map(canRetry) ?? false),
                canResume: outcome != .completed && row?.folder?.canResume == true,
                sessionOnly: false
            )
        }
        let known = Set(entries.map(\.id))
        for row in rows where !row.active && !known.contains(row.id) && TransferFailure.isFailure(row) {
            let device = row.deviceID.map(deviceName) ?? row.folder?.phoneName ?? ""
            let chip = TransferFailure.chip(row: row, outcome: .failed)
            let outcome: TransferHistoryEntry.Outcome = chip == .stopped ? .incomplete : .failed
            items.append(TransferItem(
                id: row.id, date: row.startedAt, name: row.name, kind: TransferKind.of(name: row.name, isFolder: row.folder != nil),
                direction: row.incoming || row.folder?.incoming == true ? .received : .sent, deviceID: row.deviceID ?? "",
                deviceName: device, bytes: row.bytesDone ?? row.folder?.progress.bytesDone ?? 0,
                fileCount: max(1, row.folder?.progress.filesTotal ?? 1), outcome: outcome, localURL: row.localURL,
                reason: TransferFailure.reason(row: row, outcome: outcome, deviceName: device, isFolder: row.folder != nil), chip: chip,
                canRetry: canRetry(row), canResume: row.folder?.canResume == true, sessionOnly: true
            ))
        }
        return items.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
    }

    private static func canRetry(_ row: FileTransferRow) -> Bool {
        if let folder = row.folder { return folder.canSendAgain }
        return row.retryable
    }
}

/// "Stopped" or "Failed", and why, in plain words.
enum TransferFailure {
    enum Chip: Equatable { case stopped, failed }

    /// A finished row that did not get there (the words come from Pairing.swift's row statuses).
    static func isFailure(_ row: FileTransferRow) -> Bool {
        guard !row.active else { return false }
        if let folder = row.folder { return folder.state == .interrupted || folder.state == .incomplete }
        return row.retryable || failureStatus(row.status)
    }

    private static func failureStatus(_ status: String) -> Bool {
        let lower = status.lowercased()
        return ["interrupted", "cancelled", "stalled", "failed", "turned off", "could not", "reconnect", "not enough"].contains { lower.contains($0) }
    }

    static func chip(row: FileTransferRow?, outcome: TransferHistoryEntry.Outcome) -> Chip {
        if let folder = row?.folder, folder.state == .interrupted || folder.state == .incomplete { return .stopped }
        if let status = row?.status.lowercased(), status.contains("interrupted") || status.contains("cancelled") || status.contains("reconnect") {
            return .stopped
        }
        return outcome == .failed ? .failed : .stopped
    }

    static func chip(_ item: TransferItem) -> Chip {
        item.chip ?? (item.outcome == .failed ? .failed : .stopped)
    }

    static func reason(row: FileTransferRow?, outcome: TransferHistoryEntry.Outcome, deviceName: String, isFolder: Bool = false) -> String {
        let device = deviceName.isEmpty ? L10n.text("transfers.window.reason.device", fallback: "The device") : deviceName
        func disconnected() -> String { String(format: L10n.text("transfers.window.reason.disconnected", fallback: "%@ disconnected"), device) }
        if let folder = row?.folder {
            if folder.state == .interrupted { return disconnected() }
            if let end = folder.endText, !end.isEmpty { return end }
        }
        if let status = row?.status.lowercased() {
            if status.contains("interrupted") || status.contains("reconnect") { return disconnected() }
            if status.contains("cancelled") { return L10n.text("transfers.window.reason.cancelled", fallback: "Cancelled") }
            if status.contains("stalled") { return L10n.text("transfers.window.reason.stalled", fallback: "No data for 2 minutes") }
            if status.contains("verification") { return L10n.text("transfers.window.reason.damaged", fallback: "The file arrived damaged") }
            if status.contains("turned off") {
                return String(format: L10n.text("transfers.window.reason.filesOff", fallback: "File transfer is off on %@"), device)
            }
            if status.contains("not enough") { return L10n.text("transfers.window.reason.space", fallback: "Not enough free space") }
            if status.contains("could not read") || status.contains("could not prepare") {
                return L10n.text("transfers.window.reason.unreadable", fallback: "The file could not be read")
            }
        }
        switch outcome {
        case .cancelled: return L10n.text("transfers.window.reason.cancelled", fallback: "Cancelled")
        case .incomplete:
            return isFolder ? L10n.text("transfers.window.reason.incomplete", fallback: "Not every file arrived")
                : L10n.text("transfers.window.reason.unfinished", fallback: "Stopped before the end")
        case .failed, .completed: return L10n.text("transfers.window.reason.unknown", fallback: "Could not finish")
        }
    }
}

/// The filter chips, the device menu and search. They combine.
struct TransfersFilter: Equatable {
    enum Category: CaseIterable, Equatable { case all, media, documents, folders, failed }

    var category: Category = .all
    var deviceID: String?
    var direction: TransferHistoryEntry.Direction?
    var query = ""

    var isEmpty: Bool { category == .all && deviceID == nil && direction == nil && query.trimmingCharacters(in: .whitespaces).isEmpty }

    func matches(_ item: TransferItem) -> Bool {
        switch category {
        case .all: break
        case .media: if !item.kind.isMedia { return false }
        case .documents: if item.kind != .document { return false }
        case .folders: if item.kind != .folder { return false }
        case .failed: if !item.failed { return false }
        }
        if let deviceID, item.deviceID != deviceID { return false }
        if let direction, item.direction != direction { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        return item.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// One day of history: photos and videos for the grid, then documents, folders and failures as rows.
struct TransferDay: Identifiable, Equatable {
    let id: String
    let title: String
    let media: [TransferItem]
    let rows: [TransferItem]
}

enum TransferDays {
    static func group(_ items: [TransferItem], now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [TransferDay] {
        var order: [Date] = []
        var byDay: [Date: [TransferItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(item)
        }
        return order.sorted(by: >).map { day in
            let list = (byDay[day] ?? []).sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
            return TransferDay(id: "day-\(Int(day.timeIntervalSince1970))", title: title(day, now: now, calendar: calendar, locale: locale),
                               media: list.filter(\.inGrid), rows: list.filter { !$0.inGrid })
        }
    }

    /// "Today", "Yesterday", "Sat 22 Nov", and "Sat 22 Nov 2025" for another year.
    static func title(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.text("phonefiles.day.today", fallback: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.text("phonefiles.day.yesterday", fallback: "Yesterday")
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return TransfersText.formatter(sameYear ? "EEE d MMM" : "EEE d MMM yyyy", locale: locale, calendar: calendar).string(from: date)
    }
}

/// One line of the history list, in order: a day's title, a row of the day's media grid, or a history row. The list is
/// lazy over these, so only the lines on screen are built, however long the history.
enum TransferHistoryLine: Identifiable, Equatable {
    case title(id: String, text: String)
    /// `last`: the grid's last row, which has the gap before the day's rows under it.
    case grid(id: String, items: [TransferItem], last: Bool)
    case row(TransferItem)

    var id: String {
        switch self {
        case let .title(id, _), let .grid(id, _, _): id
        case let .row(item): item.id
        }
    }

    static func lines(_ days: [TransferDay], columns: Int) -> [TransferHistoryLine] {
        let columns = max(1, columns)
        var lines: [TransferHistoryLine] = []
        for day in days {
            lines.append(.title(id: day.id, text: day.title))
            let rows = stride(from: 0, to: day.media.count, by: columns).map { Array(day.media[$0..<min($0 + columns, day.media.count)]) }
            for (index, row) in rows.enumerated() {
                lines.append(.grid(id: "\(day.id)-grid-\(row[0].id)", items: row, last: index == rows.count - 1))
            }
            lines.append(contentsOf: day.rows.map(TransferHistoryLine.row))
        }
        return lines
    }
}

/// "Today: 418 MB moved, fastest 38.2 MB/s", from the history. Nil when nothing moved today.
enum TransferTotals {
    static func today(_ entries: [TransferHistoryEntry], now: Date, calendar: Calendar = .current) -> (bytes: Int64, fastest: Double?)? {
        let today = entries.filter { calendar.isDate($0.date, inSameDayAs: now) && $0.bytes > 0 }
        guard !today.isEmpty else { return nil }
        let bytes = today.reduce(Int64(0)) { $0 + $1.bytes }
        let fastest = today.compactMap(\.bytesPerSecond).filter { $0 > 0 }.max()
        return (bytes, fastest)
    }

    static func text(_ entries: [TransferHistoryEntry], now: Date, calendar: Calendar = .current) -> String? {
        guard let totals = today(entries, now: now, calendar: calendar) else { return nil }
        let moved = TransfersText.bytes(totals.bytes)
        guard let fastest = totals.fastest else {
            return String(format: L10n.text("transfers.window.today", fallback: "Today: %@ moved"), moved)
        }
        return String(format: L10n.text("transfers.window.todayFastest", fallback: "Today: %1$@ moved, fastest %2$@"), moved,
                      TransfersText.speed(fastest))
    }
}

/// The average speed a finished transfer keeps in its history entry: bytes over the time they took.
enum TransferSpeed {
    /// Nil for transfers too small or too short to say anything (under 1 MB or half a second).
    static func average(bytes: Int64, since start: Date, now: Date) -> Double? {
        let elapsed = now.timeIntervalSince(start)
        guard bytes >= 1_000_000, elapsed >= 0.5 else { return nil }
        return Double(bytes) / elapsed
    }
}

/// The live card's speed: a rolling average over about 3 seconds of byte counts, per transfer.
final class TransferRollingSpeed {
    static let window: TimeInterval = 3

    private var samples: [String: [(at: Date, bytes: Int64)]] = [:]

    func record(_ id: String, bytes: Int64, at now: Date) {
        var list = samples[id] ?? []
        if let last = list.last, last.bytes == bytes { return }
        if let last = list.last, bytes < last.bytes { list.removeAll() }
        list.append((now, bytes))
        // Keep one sample older than the window, so the average always spans about 3 seconds.
        while list.count > 2, now.timeIntervalSince(list[1].at) >= Self.window { list.removeFirst() }
        samples[id] = list
    }

    /// Bytes per second over the last 3 seconds; nil until there are two samples half a second apart. A transfer
    /// that has not moved for the whole window reads 0.
    func speed(_ id: String, now: Date) -> Double? {
        guard let list = samples[id], let last = list.last, let first = list.first else { return nil }
        if now.timeIntervalSince(last.at) >= Self.window { return 0 }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 0.5 else { return nil }
        return Double(last.bytes - first.bytes) / span
    }

    func keep(_ ids: Set<String>) {
        samples = samples.filter { ids.contains($0.key) }
    }
}

/// One row of the live card.
struct TransferLive: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: TransferKind
    let incoming: Bool
    let deviceID: String?
    let deviceName: String
    let localURL: URL?
    let bytesDone: Int64?
    let bytesTotal: Int64?
    /// Folders: "12 of 48 photos".
    let fileProgress: String?
    /// While nothing is counted yet ("Waiting for Android…", "Optimising 3 of 12").
    let status: String
    let queued: Bool

    var fraction: Double? {
        guard let bytesDone, let bytesTotal, bytesTotal > 0 else { return nil }
        return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
    }

    static func make(_ row: FileTransferRow, deviceName: (String) -> String) -> TransferLive {
        if let folder = row.folder {
            let progress = folder.progress
            let counting = progress.bytesTotal > 0 && (folder.state == .running || progress.bytesDone > 0)
            return TransferLive(
                id: row.id, name: progress.rootName ?? folder.displayName, kind: .folder, incoming: folder.incoming,
                deviceID: row.deviceID, deviceName: row.deviceID.map(deviceName) ?? folder.phoneName, localURL: row.localURL,
                bytesDone: counting ? progress.bytesDone : nil, bytesTotal: counting ? progress.bytesTotal : nil,
                fileProgress: progress.filesTotal > 0 ? TransfersText.files(done: progress.filesDone, total: progress.filesTotal,
                                                                            photos: allPhotos(progress.recent)) : nil,
                status: row.status, queued: row.queued
            )
        }
        return TransferLive(
            id: row.id, name: row.name, kind: TransferKind.of(name: row.name, isFolder: false), incoming: row.incoming,
            deviceID: row.deviceID, deviceName: row.deviceID.map(deviceName) ?? "", localURL: row.localURL,
            bytesDone: row.bytesDone, bytesTotal: row.bytesTotal, fileProgress: nil, status: row.status, queued: row.queued
        )
    }

    /// "photos" when every file seen so far is a photo or video.
    private static func allPhotos(_ recent: [String]) -> Bool {
        !recent.isEmpty && recent.allSatisfy { TransferKind.of(name: $0, isFolder: false).isMedia }
    }
}

// MARK: - Coalescing

/// Runs its work at most once per `interval`. The first signal after a quiet spell runs on the next turn of the run
/// loop; signals inside the interval wait for its end and run once, together. The Transfers window redraws from it
/// at most five times a second, however often transfers report progress.
@MainActor
final class TransfersCoalescer {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    nonisolated static let interval: TimeInterval = 0.2

    private let interval: TimeInterval
    private let clock: () -> TimeInterval
    private let schedule: Schedule
    private let work: () -> Void
    private var pending = false
    private var lastRun = -TimeInterval.infinity

    init(interval: TimeInterval = TransfersCoalescer.interval, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = TransfersCoalescer.onMainQueue, work: @escaping () -> Void) {
        self.interval = interval
        self.clock = clock
        self.schedule = schedule
        self.work = work
    }

    /// Something changed: the work runs once, on the next turn or at the end of the interval.
    func signal() {
        guard !pending else { return }
        pending = true
        schedule(max(0, lastRun + interval - clock())) { [weak self] in self?.fire() }
    }

    private func fire() {
        guard pending else { return }
        pending = false
        lastRun = clock()
        work()
    }

    nonisolated static func onMainQueue(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { block() } }
    }
}

/// When a transfer brings the Transfers window forward by itself: the first of a run of transfers. A phone sends
/// files one after another with short gaps between them, so a run ends only after `idle` seconds with nothing moving
/// or waiting; within a run, more files leave the window (and the app in front) as they are, closed included.
struct TransfersAutoShow {
    static let idle: TimeInterval = 10

    private var active = false
    private var idleSince: TimeInterval?
    private var newRun = true

    /// Whether anything is moving or waiting (the coordinator's `fileTransferActive`).
    mutating func activeChanged(_ value: Bool, at now: TimeInterval) {
        guard value != active else { return }
        active = value
        if !value {
            idleSince = now
        } else if let idleSince, now - idleSince >= Self.idle {
            newRun = true
        }
    }

    /// A transfer starts: true when it is the first of a run, so the window comes forward.
    mutating func transferStarted(at now: TimeInterval) -> Bool {
        if !active, let idleSince, now - idleSince >= Self.idle { newRun = true }
        guard newRun else { return false }
        newRun = false
        return true
    }
}

enum TransferLiveList {
    /// Every active row, running before queued, oldest first.
    static func ordered(_ rows: [FileTransferRow]) -> [FileTransferRow] {
        rows.filter(\.active).sorted { lhs, rhs in
            if lhs.queued != rhs.queued { return !lhs.queued }
            return lhs.startedAt == rhs.startedAt ? lhs.id < rhs.id : lhs.startedAt < rhs.startedAt
        }
    }

    /// The live card: up to `limit` running rows (the first queued one when nothing runs yet), and how many more wait.
    static func split(_ live: [TransferLive], limit: Int = 2) -> (shown: [TransferLive], waiting: Int) {
        var shown = Array(live.filter { !$0.queued }.prefix(limit))
        if shown.isEmpty { shown = Array(live.prefix(1)) }
        return (shown, live.count - shown.count)
    }
}

// MARK: - Route chip

/// How a connected device is reached, for the live card's chip.
struct TransferRouteChip: Equatable {
    enum Style: Equatable { case lan, privateNetwork, direct, relay }
    let text: String
    let style: Style
}

/// The chip from what the session knows: Same Wi-Fi for a LAN socket, Tailscale or Private network for another
/// socket, and a tunnel's own route (Same Wi-Fi, Private network, Direct, or Relay with its place).
func makeTransferRouteChip(tier: SessionTier, socketRoute: ConnectionRoute, tunnelRoute: String?, relay: String?) -> TransferRouteChip? {
    switch tier {
    case .lan:
        return TransferRouteChip(text: L10n.text("connect.route.lan", fallback: "Same Wi-Fi"), style: .lan)
    case .socket:
        if socketRoute == .privateNetwork { return TransferRouteChip(text: L10n.text("connect.route.tailscale", fallback: "Tailscale"), style: .privateNetwork) }
        return TransferRouteChip(text: L10n.text("connect.route.vpn", fallback: "Private network"), style: .privateNetwork)
    case .tunnel:
        guard let text = connectRouteChipText(tunnelRoute: tunnelRoute, relay: relay, legacy: .unknown) else { return nil }
        let style: TransferRouteChip.Style
        switch tunnelRoute.flatMap(ConnectRouteKind.init(rawValue:)) {
        case .lan: style = .lan
        case .vpn: style = .privateNetwork
        case .direct: style = .direct
        case .relay, nil: style = .relay
        }
        return TransferRouteChip(text: text, style: style)
    }
}

// MARK: - Words

enum TransfersText {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file) }

    /// "21.4 MB/s".
    static func speed(_ bytesPerSecond: Double) -> String {
        String(format: L10n.text("transfers.window.speed", fallback: "%@/s"), bytes(Int64(bytesPerSecond.rounded())))
    }

    /// "3 s left", "2 min left", "1 h 5 min left". Nil when it cannot be said yet.
    static func timeLeft(remaining: Int64, bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond >= 1, remaining > 0 else { return nil }
        let seconds = max(1, Int((Double(remaining) / bytesPerSecond).rounded(.up)))
        if seconds < 60 { return String(format: L10n.text("transfers.window.left.seconds", fallback: "%d s left"), seconds) }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        if minutes < 60 { return String(format: L10n.text("transfers.window.left.minutes", fallback: "%d min left"), minutes) }
        return String(format: L10n.text("transfers.window.left.hours", fallback: "%1$d h %2$d min left"), minutes / 60, minutes % 60)
    }

    /// "12 of 48 photos" or "12 of 48 files".
    static func files(done: Int, total: Int, photos: Bool) -> String {
        let key = photos ? "transfers.window.folder.photos" : "transfers.window.folder.files"
        let fallback = photos ? "%1$@ of %2$@ photos" : "%1$@ of %2$@ files"
        return String(format: L10n.text(key, fallback: fallback), FolderText.number(done), FolderText.number(total))
    }

    static func device(_ name: String, incoming: Bool) -> String {
        incoming ? String(format: L10n.text("history.from", fallback: "From %@"), name)
            : String(format: L10n.text("history.to", fallback: "To %@"), name)
    }

    static func time(_ date: Date, locale: Locale = .current) -> String {
        formatter(nil, locale: locale, calendar: .current).string(from: date)
    }

    /// One formatter per format, locale and calendar (a window of history redraws while a transfer moves).
    /// Nil format: the locale's short time.
    static func formatter(_ format: String?, locale: Locale, calendar: Calendar) -> DateFormatter {
        let key = [format ?? "time", locale.identifier, String(describing: calendar.identifier), calendar.timeZone.identifier].joined(separator: "\u{1F}")
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if let format {
            formatter.dateFormat = format
        } else {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        }
        formatters[key] = formatter
        return formatter
    }

    private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    static func waiting(_ count: Int) -> String {
        String(format: L10n.text("transfers.window.waiting", fallback: "%d more waiting"), count)
    }

    static func category(_ category: TransfersFilter.Category) -> String {
        switch category {
        case .all: L10n.text("transfers.window.filter.all", fallback: "All")
        case .media: L10n.text("transfers.window.filter.media", fallback: "Photos and videos")
        case .documents: L10n.text("transfers.window.filter.documents", fallback: "Documents")
        case .folders: L10n.text("transfers.window.filter.folders", fallback: "Folders")
        case .failed: L10n.text("transfers.window.filter.failed", fallback: "Failed")
        }
    }
}
