import AppKit
import Combine
import SwiftUI

// The optimisation chip ("Original", "Optimised · −68%") with its per-send popover, the estimate behind
// it, and Settings > Files > Before sending with the live side-by-side preview of a sample photo.

// MARK: - Chip label and estimate

enum OptimizationLabel {
    /// The chip text for `options`, with the measured or estimated saving when known.
    static func chip(_ options: SendOptimization, saving: Double?) -> String {
        if options.isOriginal { return L10n.text("chip.original", fallback: "Original") }
        if options.imageMode == .original && options.videoMode == .original && options.folderMode == .asIs {
            return options.stripLocation && !options.stripCamera && !options.stripDates
                ? L10n.text("chip.noLocation", fallback: "Original, no location")
                : L10n.text("chip.noMetadata", fallback: "Original, metadata removed")
        }
        let base = L10n.text("chip.optimised", fallback: "Optimised")
        guard let saving, saving >= 0.01 else { return base }
        return "\(base) \u{00B7} \u{2212}\(Int((saving * 100).rounded()))%"
    }

    /// Fraction saved: 0.68 for 100 MB sent as 32 MB.
    static func saving(original: Int64, optimized: Int64) -> Double? {
        guard original > 0 else { return nil }
        return max(0, Double(original - optimized) / Double(original))
    }
}

/// Measures what the chosen settings would save on the items about to be sent: images are optimised for
/// real (the copies land in the cache, so the send itself is then instant), videos are estimated from their
/// bitrate, folders and other files count as unchanged. Bounded, cancelled when the selection changes.
@MainActor
final class SendEstimator: ObservableObject {
    @Published private(set) var saving: Double?

    nonisolated static let maximumImages = 40
    nonisolated static let maximumImageBytes: Int64 = 400 * 1024 * 1024

    private var task: Task<Void, Never>?
    private var cancel = OptimizerCancel()
    private var lastKey = ""

    func update(urls: [URL], options: SendOptimization) {
        let key = urls.map(\.path).joined(separator: "\n") + "|\(options.imageFingerprint)|\(options.videoFingerprint)|\(options.folderMode.rawValue)"
        guard key != lastKey else { return }
        lastKey = key
        task?.cancel()
        cancel.cancel()
        saving = nil
        guard !urls.isEmpty, !options.isOriginal else { return }
        let cancel = OptimizerCancel()
        self.cancel = cancel
        task = Task.detached(priority: .utility) { [weak self] in
            var original: Int64 = 0
            var optimized: Int64 = 0
            var images = 0
            var imageBytes: Int64 = 0
            for url in urls {
                if cancel.isCancelled { return }
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard SendOptimizer.mightChange(url, with: options) else {
                    original += size
                    optimized += size
                    continue
                }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                if type?.conforms(to: .image) == true {
                    images += 1
                    imageBytes += size
                    if images > Self.maximumImages || imageBytes > Self.maximumImageBytes { continue }
                    if let item = try? await SendOptimizer.optimize(url, with: options, cancel: cancel) {
                        original += item.originalBytes
                        optimized += item.outputBytes
                    }
                } else if let estimate = await SendOptimizer.estimatedVideoBytes(url, options: options) {
                    original += size
                    optimized += min(size, estimate)
                } else {
                    original += size
                    optimized += size
                }
            }
            let value = OptimizationLabel.saving(original: original, optimized: optimized)
            await MainActor.run { [weak self] in
                guard let self, !cancel.isCancelled else { return }
                self.saving = value
            }
        }
    }
}

// MARK: - Per-send popover

/// The chip's popover: change the settings for this send only.
struct SendOptimizationPopover: View {
    let options: SendOptimization
    let defaults: SendOptimization
    let change: (SendOptimization) -> Void
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("chip.popover.title", fallback: "For this send"))
                .font(BrandFont.heading(14))
                .foregroundStyle(c.on)
            HStack(spacing: 6) {
                choice(L10n.text("chip.original", fallback: "Original"), selected: options.isOriginal) { change(.original) }
                choice(L10n.text("chip.optimised", fallback: "Optimised"), selected: !options.isOriginal) {
                    change(defaults.isOriginal || defaults.imageMode == .original ? .recommended : defaults)
                }
            }
            if !options.isOriginal {
                row(L10n.text("optimize.images", fallback: "Photos")) {
                    menu(imageTitle(options)) {
                        [PopUpMenuItem(title: L10n.text("optimize.images.original", fallback: "Original size"), checked: options.imageMode == .original) {
                            var next = options; next.imageMode = .original; change(next)
                        }] + SendOptimization.maxEdgeChoices.map { edge in
                            PopUpMenuItem(title: edgeTitle(edge), checked: options.imageMode == .optimize && options.maxEdge == edge) {
                                var next = options; next.imageMode = .optimize; next.maxEdge = edge; change(next)
                            }
                        }
                    }
                }
                if options.imageMode == .optimize {
                    row(L10n.text("optimize.format", fallback: "Format")) {
                        menu("\(formatTitle(options.format)), \(options.quality)") {
                            SendOptimization.ImageFormat.allCases.flatMap { format in
                                SendOptimization.qualityChoices.map { quality in
                                    PopUpMenuItem(title: "\(formatTitle(format)), \(String(format: L10n.text("optimize.quality.value", fallback: "quality %d"), quality))",
                                                  checked: options.format == format && options.quality == quality) {
                                        var next = options; next.format = format; next.quality = quality; change(next)
                                    }
                                }
                            }
                        }
                    }
                }
                row(L10n.text("optimize.videos", fallback: "Videos")) {
                    menu(videoTitle(options.videoMode)) {
                        SendOptimization.VideoMode.allCases.map { mode in
                            PopUpMenuItem(title: videoTitle(mode), checked: options.videoMode == mode) { var next = options; next.videoMode = mode; change(next) }
                        }
                    }
                }
                row(L10n.text("optimize.folders", fallback: "Folders")) {
                    menu(folderTitle(options.folderMode)) {
                        SendOptimization.FolderMode.allCases.map { mode in
                            PopUpMenuItem(title: folderTitle(mode), checked: options.folderMode == mode) { var next = options; next.folderMode = mode; change(next) }
                        }
                    }
                }
                Toggle(isOn: Binding(get: { options.stripLocation }, set: { var next = options; next.stripLocation = $0; change(next) })) {
                    Text(L10n.text("optimize.strip.location", fallback: "Remove location"))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on)
                }
                .toggleStyle(BrandSwitchStyle(scale: 0.6))
            }
            Text(L10n.text("chip.popover.note", fallback: "Originals stay as they are. Defaults are in Settings, Files."))
                .font(BrandFont.body(11))
                .foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .background(c.panel)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle(kind: selected ? .tonal : .neutral, height: 28))
            .overlay(Capsule().strokeBorder(selected ? c.pri : Color.clear, lineWidth: 1.5))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(BrandFont.body(12)).foregroundStyle(c.on2)
            Spacer()
            content()
        }
    }

    private func menu(_ value: String, items: @escaping () -> [PopUpMenuItem]) -> some View {
        ChoiceButton(value: value, items: items)
    }
}

func edgeTitle(_ edge: Int) -> String { String(format: L10n.text("optimize.edge", fallback: "Up to %d px"), edge) }

func formatTitle(_ format: SendOptimization.ImageFormat) -> String {
    switch format {
    case .jpeg: "JPEG"
    case .webp: "WebP"
    }
}

func imageTitle(_ options: SendOptimization) -> String {
    options.imageMode == .original ? L10n.text("optimize.images.original", fallback: "Original size") : edgeTitle(options.maxEdge)
}

func videoTitle(_ mode: SendOptimization.VideoMode) -> String {
    switch mode {
    case .original: L10n.text("optimize.video.original", fallback: "Original")
    case .hd1080Balanced: L10n.text("optimize.video.1080", fallback: "1080p, balanced")
    case .hd1080Small: L10n.text("optimize.video.1080small", fallback: "1080p, small")
    case .hd720Balanced: L10n.text("optimize.video.720", fallback: "720p, balanced")
    case .hd720Small: L10n.text("optimize.video.720small", fallback: "720p, small")
    }
}

func folderTitle(_ mode: SendOptimization.FolderMode) -> String {
    switch mode {
    case .asIs: L10n.text("optimize.folders.asIs", fallback: "As they are")
    case .zip: L10n.text("optimize.folders.zip", fallback: "As a zip file")
    }
}

/// The chip plus its popover, for the send sheet and the Tray.
struct OptimizationChipButton: View {
    let options: SendOptimization
    let defaults: SendOptimization
    let saving: Double?
    let change: (SendOptimization) -> Void
    @State private var open = false

    var body: some View {
        OptimizationChip(label: OptimizationLabel.chip(options, saving: saving)) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .top) {
                BrandRoot(reduceMotion: UserDefaults.standard.bool(forKey: "settings.reduceMotion")) {
                    SendOptimizationPopover(options: options, defaults: defaults, change: change)
                }
            }
    }
}

// MARK: - Settings > Files > Before sending

struct SendOptimizationSettings: View {
    let options: SendOptimization
    let change: (SendOptimization) -> Void
    var preview: SendPreviewState
    @Environment(\.brand) private var c

    var body: some View {
        SettingsCard(title: L10n.text("optimize.title", fallback: "Before sending"),
                     footnote: L10n.text("optimize.note", fallback: "Copies are made on this Mac before sending; originals never change. The chip in the send sheet and the Tray changes this for one send.")) {
            SendPreviewView(state: preview)
                .padding(.vertical, 10)
            SettingsRow(title: L10n.text("optimize.images", fallback: "Photos"), subtitle: nil) {
                ChoiceButton(value: imageTitle(options)) {
                    [PopUpMenuItem(title: L10n.text("optimize.images.original", fallback: "Original size"), checked: options.imageMode == .original) {
                        var next = options; next.imageMode = .original; change(next)
                    }] + SendOptimization.maxEdgeChoices.map { edge in
                        PopUpMenuItem(title: edgeTitle(edge), checked: options.imageMode == .optimize && options.maxEdge == edge) {
                            var next = options; next.imageMode = .optimize; next.maxEdge = edge; change(next)
                        }
                    }
                }
            }
            if options.imageMode == .optimize {
                SettingsRow(title: L10n.text("optimize.format", fallback: "Format"), subtitle: nil) {
                    ChoiceButton(value: formatTitle(options.format)) {
                        SendOptimization.ImageFormat.allCases.map { format in
                            PopUpMenuItem(title: formatTitle(format), checked: options.format == format) { var next = options; next.format = format; change(next) }
                        }
                    }
                }
                SettingsRow(title: L10n.text("optimize.quality", fallback: "Quality"), subtitle: nil) {
                    HStack(spacing: 4) {
                        ForEach(SendOptimization.qualityChoices, id: \.self) { quality in
                            Button("\(quality)") { var next = options; next.quality = quality; change(next) }
                                .buttonStyle(PillButtonStyle(kind: options.quality == quality ? .tonal : .neutral, height: 26))
                        }
                    }
                }
            }
            SettingsToggle(title: L10n.text("optimize.strip.location", fallback: "Remove location"),
                           subtitle: L10n.text("optimize.strip.location.detail", fallback: "Where a photo was taken. On by default."),
                           isOn: options.stripLocation) { var next = options; next.stripLocation = $0; change(next) }
            SettingsToggle(title: L10n.text("optimize.strip.camera", fallback: "Remove camera details"),
                           subtitle: L10n.text("optimize.strip.camera.detail", fallback: "Make, model, lens and serial numbers."),
                           isOn: options.stripCamera) { var next = options; next.stripCamera = $0; change(next) }
            SettingsToggle(title: L10n.text("optimize.strip.dates", fallback: "Remove dates"),
                           subtitle: L10n.text("optimize.strip.dates.detail", fallback: "When it was taken. The phone's gallery sorts by this."),
                           isOn: options.stripDates) { var next = options; next.stripDates = $0; change(next) }
            SettingsRow(title: L10n.text("optimize.videos", fallback: "Videos"),
                        subtitle: L10n.text("optimize.videos.detail", fallback: "HEVC with this Mac's hardware encoder")) {
                ChoiceButton(value: videoTitle(options.videoMode)) {
                    SendOptimization.VideoMode.allCases.map { mode in
                        PopUpMenuItem(title: videoTitle(mode), checked: options.videoMode == mode) { var next = options; next.videoMode = mode; change(next) }
                    }
                }
            }
            SettingsRow(title: L10n.text("optimize.folders", fallback: "Folders"), subtitle: nil) {
                ChoiceButton(value: folderTitle(options.folderMode)) {
                    SendOptimization.FolderMode.allCases.map { mode in
                        PopUpMenuItem(title: folderTitle(mode), checked: options.folderMode == mode) { var next = options; next.folderMode = mode; change(next) }
                    }
                }
            }
        }
    }
}

/// The live preview's content: the same crop of the sample, as sent and as optimised.
struct SendPreviewState: Equatable {
    var original: NSImage?
    var optimized: NSImage?
    var originalBytes: Int64 = 0
    var optimizedBytes: Int64?
    var working = false
    var detail = ""

    static func == (a: SendPreviewState, b: SendPreviewState) -> Bool {
        a.original === b.original && a.optimized === b.optimized && a.originalBytes == b.originalBytes
            && a.optimizedBytes == b.optimizedBytes && a.working == b.working && a.detail == b.detail
    }
}

struct SendPreviewView: View {
    let state: SendPreviewState
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                pane(L10n.text("optimize.preview.original", fallback: "Original"), image: state.original,
                     bytes: ByteCountFormatter.string(fromByteCount: state.originalBytes, countStyle: .file))
                pane(L10n.text("optimize.preview.sent", fallback: "Sent"), image: state.optimized ?? state.original,
                     bytes: state.optimizedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "\u{2026}",
                     badge: badge)
                    .opacity(state.working ? 0.6 : 1)
                    .animation(BrandMotion.animation(BrandMotion.fade, reduce: reduce), value: state.working)
            }
            Text(state.detail)
                .font(BrandFont.body(11))
                .foregroundStyle(c.on2)
                .lineLimit(2)
        }
    }

    private var badge: String? {
        guard let bytes = state.optimizedBytes, let saving = OptimizationLabel.saving(original: state.originalBytes, optimized: bytes),
              saving >= 0.01 else { return nil }
        return "\u{2212}\(Int((saving * 100).rounded()))%"
    }

    private func pane(_ title: String, image: NSImage?, bytes: String, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(c.s2)
                    .overlay {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fill)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let badge {
                    Text(badge)
                        .font(BrandFont.body(11, .semibold))
                        .foregroundStyle(c.tgi)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(c.tg))
                        .padding(6)
                }
            }
            .frame(height: 150)
            HStack {
                Text(title).font(BrandFont.body(12, .semibold)).foregroundStyle(c.on)
                Spacer()
                Text(bytes).font(BrandFont.body(12)).foregroundStyle(c.on2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Runs the sample photo through the current settings (debounced) and crops the same detail of both, at
/// the original's pixel scale, so resizing and compression show.
@MainActor
final class SendPreviewModel: ObservableObject {
    @Published private(set) var state = SendPreviewState()
    private var task: Task<Void, Never>?
    private var last: SendOptimization?
    private let sample: URL?

    init(sample: URL? = SendPreviewModel.sampleURL()) {
        self.sample = sample
        if let sample {
            state.originalBytes = Int64((try? sample.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            state.original = Self.crop(sample, longEdge: nil)
        }
    }

    /// The bundled sample (Resources/send-preview-sample.jpg; source and licence in the docs).
    nonisolated static func sampleURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "send-preview-sample", withExtension: "jpg") { return bundled }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/send-preview-sample.jpg")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    func update(_ options: SendOptimization) {
        guard options != last, let sample else { return }
        last = options
        task?.cancel()
        state.working = true
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("bridgey-send-preview", isDirectory: true)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let started = Date()
            let item = try? await SendOptimizer.optimize(sample, with: options, cache: cache)
            let elapsed = Date().timeIntervalSince(started)
            let output = item?.output ?? sample
            let longEdge = options.imageMode == .optimize ? options.maxEdge : nil
            let image = Self.crop(output, longEdge: longEdge)
            let bytes = item?.outputBytes ?? Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let dimensions = Self.dimensions(output)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.state.optimized = image
                self.state.optimizedBytes = bytes
                self.state.working = false
                self.state.detail = String(format: L10n.text("optimize.preview.detail", fallback: "Sample photo, %@ sent as %@ (%d ms on this Mac)"),
                                           "2400 \u{00D7} 1600", dimensions, Int(elapsed * 1000))
            }
        }
    }

    nonisolated private static func dimensions(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return "" }
        return "\(width) \u{00D7} \(height) \(url.pathExtension.uppercased())"
    }

    /// The centre 360 x 240 of the original's pixel grid (a resized copy is scaled back up to match).
    nonisolated static func crop(_ url: URL, longEdge: Int?) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let sampleWidth = 2400.0
        let scale = Double(image.width) / sampleWidth
        let cropWidth = 360.0 * scale
        let cropHeight = 240.0 * scale
        let rect = CGRect(x: (Double(image.width) - cropWidth) / 2 + Double(image.width) * 0.12, y: (Double(image.height) - cropHeight) / 2,
                          width: cropWidth, height: cropHeight).integral
        guard let cropped = image.cropping(to: rect) else { return nil }
        _ = longEdge
        return NSImage(cgImage: cropped, size: NSSize(width: 360, height: 240))
    }
}
