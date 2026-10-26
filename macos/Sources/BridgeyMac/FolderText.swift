import Foundation

// Words for folder rows, cards, the send sheet and the conflict question (sections 3.1 to 3.5). Pure
// functions over plain values, so tests and screenshots use them without a running transfer.

enum FolderRowState: Equatable {
    /// Scanning or hashing on this Mac.
    case preparing
    /// The send sheet is open for it.
    case choosing
    case queued
    case running
    /// The connection dropped; resumes when the phone reconnects.
    case interrupted
    case done
    /// Ended before every file arrived (cancelled, rejected, failed files, no answer).
    case incomplete
}

/// Everything a folder row and card show. Lives in `FileTransferRow.folder`.
struct FolderRowSummary: Equatable {
    var phoneName: String
    var displayName: String
    /// The phone's display path of the parent folder ("Pictures/Trip"), once known.
    var destinationLabel: String?
    /// Mode (c): where the phone saves it ("Pictures/Inbox"), from places.listed.
    var fixedLabel: String?
    var state: FolderRowState = .preparing
    var progress = FolderProgress()
    /// Hashing progress, 0 to 1, while preparing.
    var hashing: Double?
    var skipped = SkippedCounts()
    /// The final line for a finished row ("Photos saved on OnePlus 11 in Pictures/Trip").
    var endText: String?
    var canResume = false
    var canSendAgain = false
}

enum FolderText {
    private static func format(_ key: String, _ fallback: String, _ values: CVarArg...) -> String {
        String(format: L10n.text(key, fallback: fallback), arguments: values)
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file) }

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "2:41".
    static func countdown(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "Photos → OnePlus 11 › Pictures/Trip", or "Photos → OnePlus 11" before the destination is known.
    static func title(_ summary: FolderRowSummary) -> String {
        // The phone's final name ("Photos (1)") once it accepted; the Finder name before.
        let name = summary.progress.destinationLabel != nil ? summary.progress.rootName ?? summary.displayName : summary.displayName
        if let place = summary.destinationLabel ?? summary.fixedLabel, !place.isEmpty {
            return format("folders.row.titleTo", "%1$@ \u{2192} %2$@ \u{203A} %3$@", name, summary.phoneName, place)
        }
        return format("folders.row.title", "%1$@ \u{2192} %2$@", name, summary.phoneName)
    }

    /// "37 of 124 files · 812 MB of 2.3 GB · 12 MB/s · 2 min left".
    static func progressLine(_ progress: FolderProgress) -> String {
        var parts = [
            format("folders.progress.files", "%1$@ of %2$@ files", number(progress.filesDone), number(progress.filesTotal)),
            format("folders.progress.bytes", "%1$@ of %2$@", bytes(progress.bytesDone), bytes(progress.bytesTotal)),
        ]
        if progress.phase == .sending, progress.bytesPerSecond >= 1 {
            parts.append(format("folders.progress.speed", "%@/s", bytes(Int64(progress.bytesPerSecond))))
            let remaining = Double(max(0, progress.bytesTotal - progress.bytesDone)) / progress.bytesPerSecond
            parts.append(timeLeft(remaining))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return L10n.text("folders.progress.lessThanMinute", fallback: "less than a minute left") }
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return format("folders.progress.minutes", "%@ min left", number(minutes)) }
        return format("folders.progress.hours", "%1$@ h %2$@ min left", number(minutes / 60), number(minutes % 60))
    }

    /// The line under the title, live (the countdown needs `now`).
    static func status(_ summary: FolderRowSummary, now: Date) -> String {
        let phone = summary.phoneName
        switch summary.state {
        case .preparing:
            if let hashing = summary.hashing {
                return format("folders.status.hashing", "Preparing: reading files (%@%%)", number(Int((hashing * 100).rounded(.down))))
            }
            return L10n.text("folders.status.scanning", fallback: "Preparing: counting files\u{2026}")
        case .choosing:
            return format("folders.status.choosing", "Choose where to save it on %@", phone)
        case .queued:
            if let fixed = summary.fixedLabel { return format("folders.status.fixed", "Queued, saving to %1$@ on %2$@", fixed, phone) }
            return L10n.text("files.queued", fallback: "Queued")
        case .running:
            switch summary.progress.phase {
            case .offered:
                if let fixed = summary.fixedLabel { return format("folders.status.savingTo", "Saving to %1$@ on %2$@", fixed, phone) }
                return format("folders.status.offered", "Waiting for %@\u{2026}", phone)
            case let .waiting(reason, deadline):
                let time = countdown(until: deadline, now: now)
                return reason == FolderWaitingPayload.destination
                    ? format("folders.status.waitingDestination", "Waiting for %1$@: choose where to save (%2$@)", phone, time)
                    : format("folders.status.waitingConflict", "Waiting for %1$@: the folder already exists (%2$@)", phone, time)
            case let .asking(deadline):
                return format("folders.status.asking", "The folder already exists on %1$@. Answer on this Mac (%2$@)", phone, countdown(until: deadline, now: now))
            case .sending:
                return progressLine(summary.progress)
            case .completing:
                return format("folders.status.completing", "Finishing on %@\u{2026}", phone)
            case .cancelling:
                return L10n.text("folders.status.cancelling", fallback: "Cancelling\u{2026}")
            case .finished:
                return summary.endText ?? progressLine(summary.progress)
            }
        case .interrupted:
            return summary.endText ?? format("folders.status.interrupted", "Interrupted, resumes when %@ reconnects", phone)
        case .done, .incomplete:
            return summary.endText ?? progressLine(summary.progress)
        }
    }

    /// "Photos saved on OnePlus 11 in Pictures/Trip".
    static func saved(name: String, phone: String, destination: String?) -> String {
        guard let destination, !destination.isEmpty else { return format("folders.done.noPlace", "%1$@ saved on %2$@", name, phone) }
        return format("folders.done", "%1$@ saved on %2$@ in %3$@", name, phone, destination)
    }

    /// The end of a transfer in words, for the row and the status line.
    static func outcome(_ outcome: FolderOutcome, name: String, phone: String, destination: String?, progress: FolderProgress) -> String {
        switch outcome {
        case let .done(result):
            if result.isComplete { return saved(name: name, phone: phone, destination: destination) }
            return incomplete(progress: progress)
        case .unconfirmed:
            return format("folders.end.unconfirmed", "Not confirmed by %@", phone)
        case let .rejected(code, needed, free):
            return rejection(code: code, phone: phone, needed: needed, free: free)
        case .filesOff:
            return format("folders.end.filesOff", "File transfer is turned off on %@", phone)
        case .cancelledHere:
            return L10n.text("folders.end.cancelled", fallback: "Cancelled")
        case let .cancelledByPhone(reason):
            return reason == FolderCancelPayload.timeout
                ? format("folders.end.phoneTimeout", "Cancelled: nobody chose a folder on %@", phone)
                : format("folders.end.phoneCancelled", "Cancelled on %@", phone)
        case .noAnswer:
            return format("folders.end.noAnswer", "%@ did not answer", phone)
        case .questionTimedOut:
            return L10n.text("folders.end.questionTimeout", fallback: "Cancelled: nobody answered on this Mac")
        case .interrupted:
            return format("folders.status.interrupted", "Interrupted, resumes when %@ reconnects", phone)
        }
    }

    static func incomplete(progress: FolderProgress) -> String {
        let base = format("folders.end.incomplete", "Incomplete: %1$@ of %2$@ files", number(progress.filesDone), number(progress.filesTotal))
        guard progress.failedCount > 0 else { return base }
        return base + " \u{00B7} " + failedFiles(progress.failedCount)
    }

    static func failedFiles(_ count: Int) -> String {
        count == 1 ? L10n.text("folders.failed.one", fallback: "1 file failed") : format("folders.failed.many", "%@ files failed", number(count))
    }

    static func rejection(code: String, phone: String, needed: Int64?, free: Int64?) -> String {
        switch code {
        case FolderCode.busy:
            return format("folders.rejected.busy", "%@ is busy with another folder. Try again in a moment.", phone)
        case FolderCode.insufficientSpace:
            if let needed, let free {
                return format("folders.rejected.spaceDetail", "Not enough space on %1$@: needs %2$@, %3$@ free", phone, bytes(needed), bytes(free))
            }
            return format("folders.rejected.space", "Not enough space on %@", phone)
        case FolderCode.placeUnavailable:
            return format("folders.rejected.place", "That folder is no longer available on %@", phone)
        case FolderCode.notFound:
            return format("folders.rejected.notFound", "That folder no longer exists on %@", phone)
        case FolderCode.resumeUnavailable:
            return format("folders.rejected.resume", "%@ can\u{2019}t resume this folder. Send it again.", phone)
        case FolderCode.policy:
            return format("folders.end.filesOff", "File transfer is turned off on %@", phone)
        case FolderCode.limitExceeded:
            return format("folders.rejected.limit", "The folder is too big for %@", phone)
        case FolderCode.declined:
            return format("folders.end.phoneCancelled", "Cancelled on %@", phone)
        case FolderCode.timeout:
            return format("folders.end.phoneTimeout", "Cancelled: nobody chose a folder on %@", phone)
        default:
            return format("folders.rejected.other", "%1$@ refused the folder (%2$@)", phone, code)
        }
    }

    /// A failure reason in words, for the expanded row.
    static func failureReason(_ code: String) -> String {
        switch code {
        case FolderCode.sourceChanged: return L10n.text("folders.reason.changed", fallback: "Changed while sending")
        case FolderCode.unreadable: return L10n.text("folders.reason.unreadable", fallback: "Can\u{2019}t be read")
        case FolderCode.ioError: return L10n.text("folders.reason.io", fallback: "Could not be saved")
        case FolderCode.verificationFailed: return L10n.text("folders.reason.verification", fallback: "Arrived damaged")
        case FolderCode.insufficientSpace: return L10n.text("folders.reason.space", fallback: "Not enough space")
        case FolderCode.cancelled: return L10n.text("folders.reason.cancelled", fallback: "Cancelled")
        case FolderCode.placeUnavailable: return L10n.text("folders.reason.place", fallback: "Folder no longer available")
        default: return code
        }
    }

    /// "124 files, 9 folders, 2.3 GB".
    static func counts(files: Int, folders: Int, bytes size: Int64) -> String {
        let fileText = files == 1 ? L10n.text("folders.count.file", fallback: "1 file") : format("folders.count.files", "%@ files", number(files))
        let folderText = folders == 1 ? L10n.text("folders.count.folder", fallback: "1 folder") : format("folders.count.folders", "%@ folders", number(folders))
        return "\(fileText), \(folderText), \(bytes(size))"
    }

    /// "Skipped 12 hidden files, 48 system files", or nil when neither group was skipped.
    static func skippedHiddenSystem(_ skipped: SkippedCounts) -> String? {
        var parts: [String] = []
        if skipped.hidden > 0 {
            parts.append(skipped.hidden == 1 ? L10n.text("folders.skip.hiddenOne", fallback: "1 hidden file") : format("folders.skip.hidden", "%@ hidden files", number(skipped.hidden)))
        }
        if skipped.system > 0 {
            parts.append(skipped.system == 1 ? L10n.text("folders.skip.systemOne", fallback: "1 system file") : format("folders.skip.system", "%@ system files", number(skipped.system)))
        }
        guard !parts.isEmpty else { return nil }
        return format("folders.skip.lead", "Skipped %@", parts.joined(separator: ", "))
    }

    /// The other skipped groups: "3 links · 2 not downloaded · 1 unreadable".
    static func skippedOther(_ skipped: SkippedCounts) -> String? {
        var parts: [String] = []
        func add(_ count: Int, _ one: String, _ oneFallback: String, _ many: String, _ manyFallback: String) {
            guard count > 0 else { return }
            parts.append(count == 1 ? L10n.text(one, fallback: oneFallback) : format(many, manyFallback, number(count)))
        }
        add(skipped.links, "folders.skip.linkOne", "1 link skipped", "folders.skip.links", "%@ links skipped")
        add(skipped.notDownloaded, "folders.skip.cloudOne", "1 not downloaded", "folders.skip.cloud", "%@ not downloaded")
        add(skipped.unreadable, "folders.skip.unreadableOne", "1 unreadable", "folders.skip.unreadable", "%@ unreadable")
        add(skipped.tooLarge, "folders.skip.largeOne", "1 over 10 GB", "folders.skip.large", "%@ over 10 GB")
        add(skipped.tooLong, "folders.skip.longOne", "1 path too long", "folders.skip.long", "%@ paths too long")
        add(skipped.other, "folders.skip.otherOne", "1 other item", "folders.skip.other", "%@ other items")
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// "Xcode.app is an app bundle. On the phone it is an ordinary folder."
    static func packageNotice(_ packages: [String]) -> String? {
        guard let first = packages.first else { return nil }
        if packages.count == 1 { return format("folders.package", "%@ is an app bundle. On the phone it is an ordinary folder.", first) }
        return format("folders.packages", "%1$@ and %2$@ more are bundles. On the phone they are ordinary folders.", first, number(packages.count - 1))
    }

    static func renamed(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? L10n.text("folders.renamedOne", fallback: "1 name changed to fit the phone") : format("folders.renamed", "%@ names changed to fit the phone", number(count))
    }

    /// "Saves to Pictures/Trip/Photos".
    static func savesTo(placeLabel: String, path: String, rootName: String) -> String {
        let parts = [placeLabel] + FolderPaths.components(path) + [rootName]
        return format("folders.sheet.savesTo", "Saves to %@", parts.joined(separator: "/"))
    }

    /// The conflict question's text.
    static func conflictMessage(_ conflict: FolderConflictPayload, name: String, destination: String, totalFiles: Int) -> String {
        if conflict.existingIsFile {
            return format("folders.conflict.file", "A file named \u{201C}%1$@\u{201D} already exists in %2$@.", name, destination)
        }
        let lead = format("folders.conflict.exists", "\u{201C}%1$@\u{201D} already exists in %2$@.", name, destination)
        guard let clashing = conflict.clashingFiles else {
            return lead + " " + L10n.text("folders.conflict.maybe", fallback: "Some files may have the same names.")
        }
        if clashing == 0 { return lead + " " + L10n.text("folders.conflict.none", fallback: "No files have the same names.") }
        return lead + " " + format("folders.conflict.count", "%1$@ of %2$@ files have the same names.", number(clashing), number(totalFiles))
    }

    static func saveAs(_ newName: String) -> String { format("folders.conflict.saveAs", "Save as \u{201C}%@\u{201D}", newName) }

    static func cannotReceive(_ phone: String) -> String {
        format("folders.unsupported", "%@ can\u{2019}t receive folders yet. Update Bridgey on the phone.", phone)
    }

    static func noAnswer(_ phone: String) -> String { format("folders.end.noAnswer", "%@ did not answer", phone) }
}
