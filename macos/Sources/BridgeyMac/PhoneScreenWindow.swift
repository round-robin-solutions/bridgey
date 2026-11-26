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
    /// Controlling the phone (phone_control_draft1): the bar's state.
    @Published var control = PhoneControlView()
    /// The stream has the control bar.
    let controllable: Bool
    /// The phone sends screenshots, about 3 a second, because nobody approved video there.
    let stillFrames: Bool

    init(phoneName: String, controllable: Bool = false, stillFrames: Bool = false) {
        self.phoneName = phoneName
        self.controllable = controllable
        self.stillFrames = stillFrames
    }

    /// The header's line: control's note when it ended or was refused, else the stream's numbers, after "Slower mode"
    /// while the phone sends screenshots.
    var line: String {
        if control.phase == .waiting {
            return String(format: L10n.text("phonecontrol.waiting", fallback: "Allow control on %@"), phoneName)
        }
        if control.phase == .off, let note = control.note, let text = phoneControlNoteText(note, phone: phoneName) { return text }
        guard stillFrames else { return screenStatsLine(stats) }
        return PhoneScreenStillFrames.title + " \u{00B7} " + screenStatsLine(stats)
    }
}

/// What the window says while the phone sends screenshots instead of video.
enum PhoneScreenStillFrames {
    static var title: String { L10n.text("screen.window.stillFrames", fallback: "Slower mode") }
    static var help: String {
        L10n.text("screen.window.stillFrames.help", fallback: "Nobody approved video on the phone, so it sends screenshots, about 3 a second.")
    }
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
            Text(ended ? (model.endedMessage ?? "") : model.line)
                .font(BrandFont.body(12).monospacedDigit())
                .foregroundStyle(c.on2)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.stillFrames && !ended ? PhoneScreenStillFrames.help : "")
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
    var begin: () -> Void = {}
    var end: () -> Void = {}
    var navigate: (ScreenControl.Navigation) -> Void = { _ in }
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
            if model.controllable {
                PhoneControlBar(model: model, begin: begin, end: end, navigate: navigate)
            }
        }
    }
}

/// The layer-backed view frames are drawn into. While the phone is controlled it takes the mouse, trackpad and keys.
final class ScreenVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    /// Phone control's input mapping; nil for a view-only stream.
    var input: PhoneScreenInput?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { input != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { input?.active() == true }

    /// The event's position with the origin at the top left.
    private func point(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let input, input.active() else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        input.mouseDown(at: point(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let input else { return super.mouseDragged(with: event) }
        input.mouseDragged(at: point(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let input else { return super.mouseUp(with: event) }
        input.mouseUp(at: point(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let input, input.active() else { return super.rightMouseDown(with: event) }
        input.rightMouseDown(at: point(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input, input.active() else { return super.scrollWheel(with: event) }
        input.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas, at: point(event))
    }

    override func magnify(with event: NSEvent) {
        guard let input, input.active() else { return super.magnify(with: event) }
        let phase: PhoneScreenInput.PinchPhase = event.phase.contains(.began) ? .began
            : (event.phase.contains(.ended) || event.phase.contains(.cancelled)) ? .ended : .changed
        input.magnify(Double(event.magnification), phase: phase, at: point(event))
    }

    override func keyDown(with event: NSEvent) {
        guard let input, input.key(keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags) else {
            return super.keyDown(with: event)
        }
    }

    /// Command-V types the Mac's clipboard text on the phone.
    @objc func paste(_ sender: Any?) {
        guard let input, let text = NSPasteboard.general.string(forType: .string) else { return }
        _ = input.paste(text)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let input, input.active(), window?.firstResponder === self, event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v", let text = NSPasteboard.general.string(forType: .string) {
            return input.paste(text)
        }
        return super.performKeyEquivalent(with: event)
    }
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
    private let input: PhoneScreenInput?
    private var videoSize: (width: Int, height: Int)
    var onClose: () -> Void = {}

    /// The header, plus the control bar for a control-capable stream.
    private var chrome: CGFloat { PhoneScreenHeader.height + (model.controllable ? PhoneControlBar.height : 0) }

    init(phoneName: String, width: Int, height: Int, reduceMotion: Bool, deviceID: String = "", controller: PhoneScreenControlling? = nil,
         controllable: Bool = false, stillFrames: Bool = false) {
        model = PhoneScreenWindowModel(phoneName: phoneName, controllable: controllable, stillFrames: stillFrames)
        aspect = CGFloat(max(width, 1)) / CGFloat(max(height, 1))
        videoSize = (width, height)
        input = controllable ? PhoneScreenInput() : nil
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(format: L10n.text("screen.window.title", fallback: "%@ screen"), phoneName)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.backgroundColor = .black
        super.init(window: window)
        let content = BrandRoot(reduceMotion: reduceMotion) { [model, videoView] in
            PhoneScreenWindowContent(model: model, stop: { [weak self] in self?.close() },
                                     begin: { [weak controller] in controller?.beginControl(deviceID) },
                                     end: { [weak controller] in controller?.endControl(deviceID) },
                                     navigate: { [weak controller] action in _ = controller?.controlInput(deviceID, .navigate(action)) }) {
                ScreenVideoRepresentable(view: videoView)
            }
        }
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        if let input {
            input.send = { [weak controller] action in controller?.controlInput(deviceID, action) ?? false }
            input.press = { [weak controller] key, shift in controller?.pressKey(deviceID, key, shift: shift) ?? false }
            input.active = { [weak model] in model?.control.phase == .active }
            input.layout = { [weak self] in
                guard let self else { return (.zero, 0, 0) }
                let control = self.model.control
                let width = control.width > 0 ? control.width : self.videoSize.width
                let height = control.height > 0 ? control.height : self.videoSize.height
                return (self.videoView.bounds.size, width, height)
            }
            videoView.input = input
        }
        window.setContentSize(Self.initialSize(aspect: aspect, chrome: chrome))
        window.contentMinSize = NSSize(width: 220, height: 220)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// About two thirds of the screen's height, the video's aspect ratio.
    static func initialSize(aspect: CGFloat, chrome: CGFloat = PhoneScreenHeader.height) -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        var videoHeight = (visible.height * 0.72).rounded()
        var videoWidth = (videoHeight * aspect).rounded()
        if videoWidth > visible.width * 0.8 {
            videoWidth = (visible.width * 0.8).rounded()
            videoHeight = (videoWidth / aspect).rounded()
        }
        return NSSize(width: videoWidth, height: videoHeight + chrome)
    }

    var sink: ScreenDisplaySink { ScreenDisplaySink(layer: videoView.displayLayer) }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window as drawn, with `frame` as the picture, written as a PNG (test instances: no Screen Recording needed).
    func snapshot(to url: URL, frame: CGImage?) {
        let size = window?.contentView?.bounds.size ?? NSSize(width: 360, height: 800)
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let content = BrandRoot(reduceMotion: true) { [model] in
            PhoneScreenWindowContent(model: model, stop: {}) {
                if let frame { Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit) }
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = window?.backingScaleFactor ?? 2
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    /// Phone control's state: the bar, and the view takes the keys while control is on.
    func updateControl(_ control: PhoneControlView) {
        let previous = model.control
        model.control = control
        if control.epoch != previous.epoch { input?.reset() }
        if control.phase == .active, previous.phase != .active { window?.makeFirstResponder(videoView) }
    }

    /// A new stream size (rotation): the window keeps its height and takes the new aspect ratio.
    func resize(width: Int, height: Int) {
        model.hasFrame = true
        videoSize = (width, height)
        let next = CGFloat(max(width, 1)) / CGFloat(max(height, 1))
        guard abs(next - aspect) > 0.001, let window else { return }
        aspect = next
        let content = window.contentRect(forFrameRect: window.frame)
        let videoHeight = content.height - chrome
        var size = NSSize(width: (videoHeight * aspect).rounded(), height: content.height)
        if let visible = window.screen?.visibleFrame, size.width > visible.width * 0.9 {
            size = Self.initialSize(aspect: aspect, chrome: chrome)
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
            size.height = (size.width / aspect).rounded() + chrome
        } else {
            let videoHeight = max(content.height - chrome, 120)
            size.height = videoHeight + chrome
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
    /// Where the windows' control actions go (PhoneScreen).
    weak var controlling: PhoneScreenControlling?

    func open(deviceID: String, phoneName: String, width: Int, height: Int, controllable: Bool, stillFrames: Bool,
              onClose: @escaping () -> Void) -> ScreenDisplaySink? {
        controllers.removeValue(forKey: deviceID)?.end(message: nil)
        let controller = PhoneScreenWindowController(phoneName: phoneName, width: width, height: height, reduceMotion: reduceMotion(),
                                                     deviceID: deviceID, controller: controlling, controllable: controllable,
                                                     stillFrames: stillFrames)
        controller.onClose = { [weak self] in
            self?.controllers.removeValue(forKey: deviceID)
            onClose()
        }
        controllers[deviceID] = controller
        controller.show()
        return controller.sink
    }

    func update(deviceID: String, stats: ScreenStats) { controllers[deviceID]?.model.stats = stats }

    func updateControl(deviceID: String, control: PhoneControlView) { controllers[deviceID]?.updateControl(control) }

    /// The open window of a phone (the test instance renders it).
    func controller(for deviceID: String) -> PhoneScreenWindowController? { controllers[deviceID] }

    func resize(deviceID: String, width: Int, height: Int) { controllers[deviceID]?.resize(width: width, height: height) }

    func bringToFront(deviceID: String) { controllers[deviceID]?.show() }

    func close(deviceID: String, message: String?) {
        controllers.removeValue(forKey: deviceID)?.end(message: message)
    }
}
