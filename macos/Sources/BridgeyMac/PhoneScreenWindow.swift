import AppKit
import AVFoundation
import SwiftUI

/*
 * The "OnePlus 11 screen" window: a slim header (live state, the phone's latency, bit rate and
 * frame rate, Stop) over the video, black around it. Resizable; the video area keeps the stream's
 * aspect ratio. Frames go straight from the stream's queue to an AVSampleBufferDisplayLayer.
 */

/// What the header shows; updated from screen.stats.
@MainActor
final class PhoneScreenWindowModel: ObservableObject {
    @Published var phoneName: String
    @Published var stats: ScreenStats?
    @Published var hasFrame = false
    /// Set when the stream ended; shown over the last frame until the window closes.
    @Published var endedMessage: String?

    init(phoneName: String) { self.phoneName = phoneName }
}

/// "48 ms · 2.1 Mb/s · 30 fps".
func screenStatsLine(_ stats: ScreenStats?) -> String {
    guard let stats else { return L10n.text("screen.window.connecting", fallback: "Connecting\u{2026}") }
    let megabits = Double(stats.sentBitrate) / 1_000_000
    let rate = megabits >= 10 ? String(format: "%.0f", megabits) : String(format: "%.1f", megabits)
    return String(format: L10n.text("screen.window.stats", fallback: "%1$@ ms \u{00B7} %2$@ Mb/s \u{00B7} %3$@ fps"),
                  "\(stats.latencyMs)", rate, "\(stats.fps)")
}

struct PhoneScreenHeader: View {
    @ObservedObject var model: PhoneScreenWindowModel
    let stop: () -> Void
    @Environment(\.brand) private var c

    static let height: CGFloat = 44

    var body: some View {
        let ended = model.endedMessage != nil
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(ended ? c.on2 : c.good).frame(width: 7, height: 7)
                Text(ended ? L10n.text("screen.window.ended", fallback: "Ended") : L10n.text("screen.window.live", fallback: "Live"))
                    .font(BrandFont.body(11.5, .semibold))
                    .foregroundStyle(ended ? c.on2 : c.tgi)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(ended ? c.s3 : c.tg))
            Text(ended ? (model.endedMessage ?? "") : screenStatsLine(model.stats))
                .font(BrandFont.body(12).monospacedDigit())
                .foregroundStyle(c.on2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(L10n.text("action.stop", fallback: "Stop"), action: stop)
                .buttonStyle(PillButtonStyle(kind: .danger, height: 26))
                .disabled(ended)
                .help(L10n.text("screen.window.stop.help", fallback: "Stop showing the phone\u{2019}s screen"))
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(c.s1)
        .overlay(alignment: .bottom) { Rectangle().fill(c.ol).frame(height: 1) }
    }
}

/// The whole window content; `video` is the live layer view, or a still in screenshots.
struct PhoneScreenWindowContent<Video: View>: View {
    @ObservedObject var model: PhoneScreenWindowModel
    let stop: () -> Void
    @ViewBuilder let video: Video

    var body: some View {
        VStack(spacing: 0) {
            PhoneScreenHeader(model: model, stop: stop)
            ZStack {
                Color.black
                video
                if !model.hasFrame && model.endedMessage == nil {
                    Text(L10n.text("screen.window.waiting", fallback: "Waiting for the first frame\u{2026}"))
                        .font(BrandFont.body(13))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                if let message = model.endedMessage {
                    Color.black.opacity(0.55)
                    Text(message)
                        .font(BrandFont.body(14, .medium))
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        }
    }
}

/// The layer-backed view frames are drawn into.
final class ScreenVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct ScreenVideoRepresentable: NSViewRepresentable {
    let view: ScreenVideoView
    func makeNSView(context: Context) -> ScreenVideoView { view }
    func updateNSView(_ nsView: ScreenVideoView, context: Context) {}
}

@MainActor
final class PhoneScreenWindowController: NSWindowController, NSWindowDelegate {
    let model: PhoneScreenWindowModel
    let videoView = ScreenVideoView(frame: .zero)
    private var aspect: CGFloat
    private var closingOnPurpose = false
    var onClose: () -> Void = {}

    init(phoneName: String, width: Int, height: Int, reduceMotion: Bool) {
        model = PhoneScreenWindowModel(phoneName: phoneName)
        aspect = CGFloat(max(width, 1)) / CGFloat(max(height, 1))
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(format: L10n.text("screen.window.title", fallback: "%@ screen"), phoneName)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.backgroundColor = .black
        super.init(window: window)
        let content = BrandRoot(reduceMotion: reduceMotion) { [model, videoView] in
            PhoneScreenWindowContent(model: model, stop: { [weak self] in self?.close() }) {
                ScreenVideoRepresentable(view: videoView)
            }
        }
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        window.setContentSize(Self.initialSize(aspect: aspect))
        window.contentMinSize = NSSize(width: 220, height: 220)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// About two thirds of the screen's height, the video's aspect ratio.
    static func initialSize(aspect: CGFloat) -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        var videoHeight = (visible.height * 0.72).rounded()
        var videoWidth = (videoHeight * aspect).rounded()
        if videoWidth > visible.width * 0.8 {
            videoWidth = (visible.width * 0.8).rounded()
            videoHeight = (videoWidth / aspect).rounded()
        }
        return NSSize(width: videoWidth, height: videoHeight + PhoneScreenHeader.height)
    }

    var sink: ScreenDisplaySink { ScreenDisplaySink(layer: videoView.displayLayer) }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A new stream size (rotation): the window keeps its height and takes the new aspect ratio.
    func resize(width: Int, height: Int) {
        model.hasFrame = true
        let next = CGFloat(max(width, 1)) / CGFloat(max(height, 1))
        guard abs(next - aspect) > 0.001, let window else { return }
        aspect = next
        let content = window.contentRect(forFrameRect: window.frame)
        let videoHeight = content.height - PhoneScreenHeader.height
        var size = NSSize(width: (videoHeight * aspect).rounded(), height: content.height)
        if let visible = window.screen?.visibleFrame, size.width > visible.width * 0.9 {
            size = Self.initialSize(aspect: aspect)
        }
        window.setContentSize(size)
    }

    /// Shows `message` over the video for a moment, then closes without telling the phone again.
    func end(message: String?) {
        closingOnPurpose = true
        guard let message else {
            close()
            return
        }
        model.endedMessage = message
        // Holds the controller until the window closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.close() }
    }

    /// Keeps the video area at the stream's aspect ratio, following whichever edge is dragged more.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        let current = sender.contentRect(forFrameRect: sender.frame)
        var size = content.size
        if abs(content.width - current.width) > abs(content.height - current.height) {
            size.width = max(content.width, 220)
            size.height = (size.width / aspect).rounded() + PhoneScreenHeader.height
        } else {
            let videoHeight = max(content.height - PhoneScreenHeader.height, 120)
            size.height = videoHeight + PhoneScreenHeader.height
            size.width = max((videoHeight * aspect).rounded(), 220)
        }
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
    }

    func windowWillClose(_ notification: Notification) {
        if !closingOnPurpose {
            closingOnPurpose = true
            onClose()
        }
    }
}

/// One window per phone.
@MainActor
final class PhoneScreenWindows: PhoneScreenPresenter {
    private var controllers: [String: PhoneScreenWindowController] = [:]
    var reduceMotion: () -> Bool = { false }

    func open(deviceID: String, phoneName: String, width: Int, height: Int, onClose: @escaping () -> Void) -> ScreenDisplaySink? {
        controllers.removeValue(forKey: deviceID)?.end(message: nil)
        let controller = PhoneScreenWindowController(phoneName: phoneName, width: width, height: height, reduceMotion: reduceMotion())
        controller.onClose = { [weak self] in
            self?.controllers.removeValue(forKey: deviceID)
            onClose()
        }
        controllers[deviceID] = controller
        controller.show()
        return controller.sink
    }

    func update(deviceID: String, stats: ScreenStats) { controllers[deviceID]?.model.stats = stats }

    func resize(deviceID: String, width: Int, height: Int) { controllers[deviceID]?.resize(width: width, height: height) }

    func bringToFront(deviceID: String) { controllers[deviceID]?.show() }

    func close(deviceID: String, message: String?) {
        controllers.removeValue(forKey: deviceID)?.end(message: message)
    }
}
