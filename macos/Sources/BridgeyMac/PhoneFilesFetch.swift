import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Optimized starts from the verified download, not media.preview: that is an unverified display image (1 MiB cap,
// poster frame for videos) that ignores the user's size, format and metadata choices.

/// What Copy and Download fetch.
enum PhoneFetchQuality: String, CaseIterable, Equatable {
    case optimized, original

    /// Settings > Files > Copy and download from the phone. This Mac only, never synced.
    static let defaultsKey = "phoneFiles.quality"

    static func preferred(_ defaults: UserDefaults) -> PhoneFetchQuality {
        defaults.string(forKey: defaultsKey).flatMap(PhoneFetchQuality.init(rawValue:)) ?? .optimized
    }

    var other: PhoneFetchQuality { self == .optimized ? .original : .optimized }

    var copyTitle: String {
        switch self {
        case .optimized: L10n.text("phonefiles.copy.optimized", fallback: "Copy Optimized")
        case .original: L10n.text("phonefiles.copy.original", fallback: "Copy Original")
        }
    }

    var downloadTitle: String {
        switch self {
        case .optimized: L10n.text("phonefiles.download.optimized", fallback: "Download Optimized")
        case .original: L10n.text("phonefiles.download.original", fallback: "Download Original")
        }
    }

    var settingTitle: String {
        switch self {
        case .optimized: L10n.text("settings.phoneFiles.quality.optimized", fallback: "Optimized")
        case .original: L10n.text("settings.phoneFiles.quality.original", fallback: "Original")
        }
    }

    var downloadHelp: String {
        switch self {
        case .optimized: L10n.text("phonefiles.download.help.optimized", fallback: "Save smaller copies to Received files")
        case .original: L10n.text("phonefiles.download.help.original", fallback: "Save the originals to Received files")
        }
    }
}

enum PhoneFilesOptimization {
    /// Before sending's settings; a kind left at original size gets the recommended size, since Optimized must shrink it.
    static func options(from send: SendOptimization) -> SendOptimization {
        var options = send
        let recommended = SendOptimization.recommended
        if options.imageMode == .original {
            options.imageMode = .optimize
            options.maxEdge = recommended.maxEdge
            options.format = recommended.format
            options.quality = recommended.quality
        }
        if options.videoMode == .original { options.videoMode = recommended.videoMode }
        options.folderMode = .asIs
        return options
    }

    /// A photo or a video, the only things Optimized makes smaller.
    static func applies(_ entry: PhoneFileEntry) -> Bool {
        guard !entry.isDirectory else { return false }
        if entry.isImage || entry.isVideo { return true }
        guard let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// The copy when it is smaller, else the source.
    static func smaller(_ item: OptimizedItem?, source: URL) -> URL {
        guard let item, item.changed, item.outputBytes > 0, item.outputBytes < item.originalBytes else { return source }
        return item.output
    }

    /// One URL per input, in order: the smaller copy, or the input itself.
    static func lighter(_ urls: [URL], options: SendOptimization, cache: URL, cancel: OptimizerCancel,
                        step: @escaping @Sendable (_ done: Int, _ total: Int) async -> Void) async -> [URL] {
        let total = urls.filter { SendOptimizer.mightChange($0, with: options) }.count
        var outputs: [URL] = []
        var done = 0
        for url in urls {
            guard !cancel.isCancelled, SendOptimizer.mightChange(url, with: options) else {
                outputs.append(url)
                continue
            }
            await step(done, total)
            let item = try? await SendOptimizer.optimize(url, with: options, cache: cache, cancel: cancel)
            outputs.append(smaller(item, source: url))
            done += 1
        }
        if total > 0 { SendOptimizer.trimCache(cache) }
        return outputs
    }

    /// Quarantined before taking its name, like any received file.
    static func place(_ urls: [URL], into folder: URL) -> [URL?] {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return urls.map { url in
            let target = uniqueReceivedFileURL(folder.appendingPathComponent(url.lastPathComponent))
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).bridgey-part")
            do {
                try manager.copyItem(at: url, to: temporary)
                if !url.hasDirectoryPath { try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path) }
                FinderMetadata.quarantine(temporary)
                try manager.moveItem(at: temporary, to: target)
                return target
            } catch {
                try? manager.removeItem(at: temporary)
                return nil
            }
        }
    }
}

/// A Copy or Download Optimized in flight: Cancel stops the transfer and the optimiser.
@MainActor
final class PhoneFetchJob {
    var transfer: PhoneFilesCancellable?
    let optimizer = OptimizerCancel()
    private(set) var cancelled = false

    func cancel() {
        cancelled = true
        optimizer.cancel()
        transfer?.cancel()
    }
}

enum PhoneFilesPasteboard {
    /// File URLs, as Finder's Copy writes them; returns the new change count.
    @MainActor
    @discardableResult
    static func write(_ urls: [URL], to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard.changeCount
    }
}

enum PhoneFilesKeys {
    /// true for the other quality; layouts without a Latin C match by key position.
    static func copy(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> Bool? {
        let modifiers = flags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command || modifiers == [.command, .option] else { return nil }
        let character = characters?.lowercased() ?? ""
        let latin = character.unicodeScalars.allSatisfy(\.isASCII)
        guard character == "c" || (keyCode == 8 && !latin) else { return nil }
        return modifiers.contains(.option)
    }
}

/// A tonal pill with an attached menu: the label runs the default, the chevron offers each choice.
struct SplitPillButton: View {
    let title: String
    let help: String
    let menuHelp: String
    let items: () -> [PopUpMenuItem]
    let action: () -> Void
    var height: CGFloat = 28
    @Environment(\.brand) private var c
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title)
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .help(help)
            Rectangle()
                .fill(c.tbi.opacity(0.28))
                .frame(width: 1, height: height - 12)
            Button { PopUpMenuPresenter.show(items()) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.leading, 8)
                    .padding(.trailing, 11)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .help(menuHelp)
            .accessibilityLabel(menuHelp)
        }
        .font(BrandFont.body(13, .semibold))
        .lineLimit(1)
        .foregroundStyle(c.tbi)
        .background(Capsule().fill(c.tb))
        .clipShape(Capsule())
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The Download button of the toolbar and the viewer: the preferred quality, the other one from its menu.
struct PhoneDownloadButton: View {
    @ObservedObject var model: PhoneFilesModel
    let download: (PhoneFetchQuality?) -> Void

    var body: some View {
        SplitPillButton(title: L10n.text("phonefiles.download", fallback: "Download"), help: model.preferredQuality.downloadHelp,
                        menuHelp: L10n.text("phonefiles.download.choose", fallback: "Choose how to download"),
                        items: { Self.items(preferred: model.preferredQuality, download: download) }, action: { download(nil) })
    }

    /// The preferred quality first.
    static func items(preferred: PhoneFetchQuality, download: @escaping (PhoneFetchQuality?) -> Void) -> [PopUpMenuItem] {
        [preferred, preferred.other].map { quality in PopUpMenuItem(title: quality.downloadTitle) { download(quality) } }
    }
}

/// Settings > Files: what Copy and Download in the Phone files window fetch unless another choice is picked.
struct PhoneFilesQualitySettingsCard: View {
    @AppStorage(PhoneFetchQuality.defaultsKey) private var stored = PhoneFetchQuality.optimized.rawValue

    var body: some View {
        let current = PhoneFetchQuality(rawValue: stored) ?? .optimized
        SettingsCard(footnote: L10n.text("settings.phoneFiles.quality.note", fallback: "Optimized uses the Before sending sizes. If those are set to original size, photos go to 2048 px and videos to 1080p. Files that would not get smaller stay as they are.")) {
            SettingsRow(title: L10n.text("settings.phoneFiles.quality", fallback: "Copy and download from the phone"), subtitle: nil, divider: false) {
                ChoiceButton(value: current.settingTitle) {
                    PhoneFetchQuality.allCases.map { quality in
                        PopUpMenuItem(title: quality.settingTitle, checked: quality == current) { stored = quality.rawValue }
                    }
                }
            }
        }
    }
}
