import Foundation
import UniformTypeIdentifiers

// Files 2.0: wording and formatting for the Phone files and History windows (English and Russian through
// Localizable.strings).

enum PhoneFilesText {
    static func sectionTitle(_ section: PhoneFilesSection) -> String {
        switch section {
        case .media: L10n.text("phonefiles.section.media", fallback: "Photos and Videos")
        case .files: L10n.text("phonefiles.section.files", fallback: "Files")
        case .folders: L10n.text("phonefiles.section.folders", fallback: "Folders")
        case .recent: L10n.text("phonefiles.section.recent", fallback: "Recent from phone")
        }
    }

    static func sectionSymbol(_ section: PhoneFilesSection) -> String {
        switch section {
        case .media: "photo.on.rectangle"
        case .files: "doc.text"
        case .folders: "folder"
        case .recent: "clock"
        }
    }

    static func sortTitle(_ sort: PhoneFileSort) -> String {
        switch sort {
        case .name: L10n.text("phonefiles.sort.name", fallback: "Name")
        case .modified: L10n.text("phonefiles.sort.modified", fallback: "Date Modified")
        case .size: L10n.text("phonefiles.sort.size", fallback: "Size")
        case .kind: L10n.text("phonefiles.sort.kind", fallback: "Kind")
        }
    }

    static func error(_ error: PhoneFilesError, phone: String) -> String {
        switch error {
        case .notConnected:
            return String(format: L10n.text("phonefiles.error.notConnected", fallback: "%@ is not connected."), phone)
        case .notBrowsable:
            return notBrowsable(phone)
        case .timeout:
            return String(format: L10n.text("phonefiles.error.timeout", fallback: "%@ did not answer. Try again."), phone)
        case .cancelled:
            return L10n.text("phonefiles.error.cancelled", fallback: "Cancelled")
        case let .code(code):
            switch code {
            case "read_only":
                return String(format: L10n.text("phonefiles.readOnly", fallback: "Turn on Allow other devices to change files here on %@ to add files."), phone)
            case "not_found":
                return L10n.text("phonefiles.error.notFound", fallback: "This item is no longer on the phone.")
            case "place_unavailable":
                return String(format: L10n.text("phonefiles.error.place", fallback: "Bridgey on %@ lost access to this folder. Grant it again on the phone."), phone)
            case "busy":
                return String(format: L10n.text("phonefiles.error.busy", fallback: "%@ is busy. Try again in a moment."), phone)
            case "policy":
                return notBrowsable(phone)
            case "insufficient_space":
                return L10n.text("phonefiles.error.space", fallback: "There is not enough free space.")
            case "unsupported":
                return L10n.text("phonefiles.error.unsupported", fallback: "This file can't be previewed. It may be damaged; Download still gets the original.")
            default:
                return String(format: L10n.text("phonefiles.error.other", fallback: "Something went wrong on %@."), phone)
            }
        }
    }

    /// Errors worth a Try again (the phone was busy or slow, or the connection dropped).
    static func isTransient(_ error: PhoneFilesError) -> Bool {
        switch error {
        case .timeout, .notConnected: return true
        case let .code(code): return [FolderCode.busy, FolderCode.ioError, FolderCode.timeout].contains(code)
        case .notBrowsable, .cancelled: return false
        }
    }

    static func notBrowsable(_ phone: String) -> String {
        String(format: L10n.text("phonefiles.notBrowsable", fallback: "Turn on Let other devices browse this phone in Bridgey on %@, or update it."), phone)
    }

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    static func duration(_ milliseconds: Int64?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func date(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: L10n.text("phonefiles.date.today", fallback: "Today, %@"), time)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: L10n.text("phonefiles.date.yesterday", fallback: "Yesterday, %@"), time)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    /// Grid section headers: "Today", "Yesterday", "Monday", "12 October", "12 October 2025".
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return L10n.text("phonefiles.day.today", fallback: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.text("phonefiles.day.yesterday", fallback: "Yesterday")
        }
        let template: String
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            template = "EEEE"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            template = "d MMMM"
        } else {
            template = "d MMMM yyyy"
        }
        return formatter(template).string(from: date)
    }

    /// One formatter per template and locale: making one per call cost a grid of 2,000 photos about 100 ms on
    /// every redraw (the main thread was 92% in DateFormatter during a download, 2026-10-28).
    private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    static func formatter(_ template: String) -> DateFormatter {
        let locale = Locale.current
        let key = template + "\u{1F}" + locale.identifier + "\u{1F}" + TimeZone.current.identifier
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter
    }

    static func kind(_ entry: PhoneFileEntry) -> String {
        if entry.isDirectory { return L10n.text("phonefiles.kind.folder", fallback: "Folder") }
        if let mime = entry.mimeType, let type = UTType(mimeType: mime), let description = type.localizedDescription { return description }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription { return description }
        return L10n.text("phonefiles.kind.document", fallback: "Document")
    }

    static func symbol(_ entry: PhoneFileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        let mime = entry.mimeType ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.plaintext" }
        if mime.contains("zip") || mime.contains("compressed") || mime.contains("archive") { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.on.rectangle" }
        return "doc"
    }

    /// Images, PDFs, text and videos open in Quick Look.
    static func quickLookable(_ entry: PhoneFileEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        let mime = entry.mimeType ?? ""
        if mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("text/") || mime == "application/pdf" { return true }
        let ext = (entry.name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .movie)
    }

    static func uniformType(_ entry: PhoneFileEntry) -> UTType {
        if entry.isDirectory { return .folder }
        if let mime = entry.mimeType, let type = UTType(mimeType: mime) { return type }
        let ext = (entry.name as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    static func progress(_ progress: PhoneTransferProgress) -> String {
        switch progress.phase {
        case .preparing: return L10n.text("phonefiles.progress.preparing", fallback: "Preparing on the phone")
        case .waiting: return L10n.text("phonefiles.progress.waiting", fallback: "Waiting for the phone")
        case .finishing: return L10n.text("phonefiles.progress.finishing", fallback: "Finishing")
        case .transferring:
            let done = size(progress.bytesDone), total = size(progress.bytesTotal)
            if progress.filesTotal > 1 {
                return String(format: L10n.text("phonefiles.progress.files", fallback: "%1$d of %2$d files, %3$@ of %4$@"),
                              progress.filesDone, progress.filesTotal, done, total)
            }
            return String(format: L10n.text("phonefiles.progress.bytes", fallback: "%1$@ of %2$@"), done, total)
        }
    }

    static func activityTitle(_ activity: PhoneFilesActivity) -> String {
        switch activity.kind {
        case .download: String(format: L10n.text("phonefiles.activity.download", fallback: "Downloading %@"), activity.title)
        case .upload: String(format: L10n.text("phonefiles.activity.upload", fallback: "Adding %@"), activity.title)
        case .quickLook: String(format: L10n.text("phonefiles.activity.open", fallback: "Opening %@"), activity.title)
        }
    }
}
