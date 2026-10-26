import AppKit
import Carbon
import SwiftUI

/*
 * While a phone controls this Mac: a small pill at the top of the screen ("OnePlus 11 is
 * controlling this Mac", Stop), always on top, non-activating, above full-screen slideshows; the
 * Control-Option-Escape stop shortcut; and the laser dot. The remote cannot send Control or
 * Option, so it can never press the shortcut itself.
 */

@MainActor
final class RemoteControlIndicator: RemoteControlIndicating {
    private var pill: NSPanel?
    private var laser: NSPanel?
    private var laserDisplay: CGRect?
    private var stopHotKey: GlobalHotKey?

    func show(deviceName: String, mode: RemoteInputMode, onStop: @escaping () -> Void) {
        hide()
        let content = RemoteControlPillWindowContent(deviceName: deviceName, mode: mode, onStop: onStop)
        let host = FirstClickHostingView(rootView: content)
        let size = host.fittingSize
        let panel = Self.overlayPanel(size: size)
        panel.contentView = host
        panel.ignoresMouseEvents = false
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10))
        }
        panel.orderFrontRegardless()
        pill = panel
        stopHotKey = GlobalHotKey(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey | optionKey), identifier: 90, action: onStop)
    }

    func hide() {
        pill?.orderOut(nil)
        pill = nil
        stopHotKey = nil
        hideLaser()
    }

    func showLaser(x: Int, y: Int, anchor: Bool) {
        let displays = CGEventInjector.displayBounds()
        if anchor || laserDisplay == nil {
            let pointer = CGEvent(source: nil)?.location ?? .zero
            laserDisplay = display(containing: pointer, displays: displays) ?? displays.first
        }
        guard let target = laserDisplay else { return }
        let size = RemoteLaserDot.size
        let panel = laser ?? {
            let created = Self.overlayPanel(size: CGSize(width: size, height: size))
            created.contentView = NSHostingView(rootView: RemoteLaserDot())
            created.ignoresMouseEvents = true
            laser = created
            return created
        }()
        let quartz = laserPoint(x: x, y: y, on: target)
        let point = cocoaPoint(fromQuartz: quartz, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        // Moving the window is the only change per update: nothing is redrawn.
        panel.setFrameOrigin(NSPoint(x: point.x - size / 2, y: point.y - size / 2))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hideLaser() {
        laser?.orderOut(nil)
        laserDisplay = nil
    }

    private static func overlayPanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        // Above a captured full-screen slideshow, so the pill and the laser stay visible.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

/// Stop works on the first click, without activating Bridgey or taking focus from the slideshow.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pill in its window: the palette follows the system appearance.
private struct RemoteControlPillWindowContent: View {
    let deviceName: String
    let mode: RemoteInputMode
    let onStop: () -> Void

    var body: some View {
        BrandRoot(reduceMotion: UserDefaults.standard.bool(forKey: "settings.reduceMotion")) {
            RemoteControlPill(deviceName: deviceName, mode: mode, onStop: onStop)
                .padding(10)
        }
    }
}

/// "OnePlus 11 is controlling this Mac", the stop shortcut, and Stop.
struct RemoteControlPill: View {
    let deviceName: String
    let mode: RemoteInputMode
    let onStop: () -> Void
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.snapshotRendering) private var snapshot
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                // A soft ring that grows and fades: scale and opacity only, and none with Reduce motion.
                Circle()
                    .fill(c.good.opacity(0.35))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1 : 0.45)
                    .opacity(pulse ? 0 : 1)
                Circle()
                    .fill(c.good)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            Image(systemName: mode == .presentation ? "play.rectangle" : "cursorarrow.rays")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(c.on2)
                .accessibilityHidden(true)
            Text(String(format: L10n.text("remote.pill.title", fallback: "%@ is controlling this Mac"), deviceName))
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(c.on)
                .lineLimit(1)
            Text("\u{2303}\u{2325}\u{238B}")
                .font(BrandFont.body(12, .medium))
                .foregroundStyle(c.on2)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.s3))
                .help(L10n.text("remote.pill.shortcut", fallback: "Control-Option-Escape also stops remote control"))
                .accessibilityLabel(L10n.text("remote.pill.shortcut", fallback: "Control-Option-Escape also stops remote control"))
            Button(L10n.text("action.stop", fallback: "Stop"), action: onStop)
                .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(Capsule().fill(c.panel))
        .overlay(Capsule().strokeBorder(BrandPalette.aurora, lineWidth: 1.5))
        .compositingGroup()
        .shadow(color: .black.opacity(c.isDark ? 0.45 : 0.18), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .onAppear {
            guard !reduce, !snapshot else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// The laser: a red dot with a soft glow, drawn once; only its window moves.
struct RemoteLaserDot: View {
    static let size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0xFF3B30).opacity(0.55), .clear], center: .center, startRadius: 4, endRadius: Self.size / 2))
            Circle().fill(Color(hex: 0xFF453A)).frame(width: 12, height: 12)
            Circle().fill(Color.white.opacity(0.85)).frame(width: 4, height: 4)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}
