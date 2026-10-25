import AppKit
import CoreText
import SwiftUI

/*
 * Direction B "Stream" tokens for the Mac app: Midnight Aurora colours, the bundled
 * Space Grotesk and Inter fonts, the motion springs from the design's motion table, and
 * the Aurora B app mark. Every control here is drawn in SwiftUI so it renders the same
 * in the app and in ImageRenderer screenshots.
 */

struct BrandPalette: Equatable {
    let bg, s1, s2, s3, s4: Color
    let on, on2: Color
    let ol, olv: Color
    let pri, onpri, good: Color
    let tp, tpi, tb, tbi, tg, tgi: Color
    let warn: Color
    let panel, panelBorder: Color
    let switchOn, switchThumb, switchOff: Color
    let ringGap: Color
    let isDark: Bool

    static let midnight = Color(hex: 0x050B18)
    static let frost = Color(hex: 0xF4F7FA)
    static let auroraBlue = Color(hex: 0x54C7F5)
    static let auroraGreen = Color(hex: 0x5EF2B2)
    static let auroraPurple = Color(hex: 0x9B7CFF)

    static let dark = BrandPalette(
        bg: Color(hex: 0x050B18), s1: Color(hex: 0x0D1321), s2: Color(hex: 0x151C29), s3: Color(hex: 0x19202D), s4: Color(hex: 0x232A38),
        on: Color(hex: 0xF4F7FA), on2: Color(hex: 0x9AA8B8),
        ol: Color(hex: 0x2A303F), olv: Color(hex: 0x19202D),
        pri: Color(hex: 0x54C7F5), onpri: Color(hex: 0x050B18), good: Color(hex: 0x5EF2B2),
        tp: Color(red: 155 / 255, green: 124 / 255, blue: 1, opacity: 0.16), tpi: Color(hex: 0xCDBDFF),
        tb: Color(red: 84 / 255, green: 199 / 255, blue: 245 / 255, opacity: 0.15), tbi: Color(hex: 0x6AD3FF),
        tg: Color(red: 94 / 255, green: 242 / 255, blue: 178 / 255, opacity: 0.13), tgi: Color(hex: 0x5EF2B2),
        warn: Color(hex: 0xFFB4A8),
        panel: Color(hex: 0x0D1321), panelBorder: Color.white.opacity(0.08),
        switchOn: Color(hex: 0x54C7F5), switchThumb: Color(hex: 0x050B18), switchOff: Color(hex: 0x232A38),
        ringGap: Color(hex: 0x050B18),
        isDark: true
    )

    static let light = BrandPalette(
        bg: Color(hex: 0xF4F7FA), s1: Color(hex: 0xFFFFFF), s2: Color(hex: 0xEEF2F7), s3: Color(hex: 0xE6EBF2), s4: Color(hex: 0xDCE3EC),
        on: Color(hex: 0x050B18), on2: Color(hex: 0x4C5262),
        ol: Color(hex: 0xDDE3EB), olv: Color(hex: 0xE6EBF2),
        pri: Color(hex: 0x006685), onpri: Color(hex: 0xFFFFFF), good: Color(hex: 0x006C49),
        tp: Color(hex: 0xEDE4FF), tpi: Color(hex: 0x5A38BA),
        tb: Color(hex: 0xDAF1FF), tbi: Color(hex: 0x005A74),
        tg: Color(hex: 0xCDFFE2), tgi: Color(hex: 0x005236),
        warn: Color(hex: 0xB3261E),
        panel: Color(hex: 0xFFFFFF), panelBorder: Color(red: 5 / 255, green: 11 / 255, blue: 24 / 255, opacity: 0.10),
        switchOn: Color(hex: 0x006685), switchThumb: Color(hex: 0xFFFFFF), switchOff: Color(hex: 0xDCE3EC),
        ringGap: Color(hex: 0xFFFFFF),
        isDark: false
    )

    /// The midnight band used in light mode (the panel header and the Settings sidebar).
    static let band = BrandPalette(
        bg: Color(hex: 0x050B18), s1: Color(hex: 0x0D1321), s2: Color(hex: 0x151C29), s3: Color(hex: 0x1B2333), s4: Color(hex: 0x232A38),
        on: Color(hex: 0xF4F7FA), on2: Color(hex: 0x9AA8B8),
        ol: Color(hex: 0x2A303F), olv: Color(hex: 0x19202D),
        pri: Color(hex: 0x54C7F5), onpri: Color(hex: 0x050B18), good: Color(hex: 0x5EF2B2),
        tp: Color(red: 155 / 255, green: 124 / 255, blue: 1, opacity: 0.2), tpi: Color(hex: 0xCDBDFF),
        tb: Color(red: 84 / 255, green: 199 / 255, blue: 245 / 255, opacity: 0.18), tbi: Color(hex: 0x6AD3FF),
        tg: Color(red: 94 / 255, green: 242 / 255, blue: 178 / 255, opacity: 0.15), tgi: Color(hex: 0x5EF2B2),
        warn: Color(hex: 0xFFB4A8),
        panel: Color(hex: 0x0D1321), panelBorder: Color.white.opacity(0.08),
        switchOn: Color(hex: 0x54C7F5), switchThumb: Color(hex: 0x050B18), switchOff: Color(hex: 0x232A38),
        ringGap: Color(hex: 0x050B18),
        isDark: true
    )

    static func forScheme(_ scheme: ColorScheme) -> BrandPalette { scheme == .dark ? .dark : .light }

    /// The aurora gradient: purple, blue, green.
    static let auroraStops: [Gradient.Stop] = [
        .init(color: auroraPurple, location: 0),
        .init(color: auroraBlue, location: 0.55),
        .init(color: auroraGreen, location: 1),
    ]
    static var aurora: LinearGradient {
        LinearGradient(stops: auroraStops, startPoint: UnitPoint(x: 0, y: 0.36), endPoint: UnitPoint(x: 1, y: 0.64))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

private struct BrandPaletteKey: EnvironmentKey {
    static let defaultValue = BrandPalette.dark
}

private struct BrandReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var brand: BrandPalette {
        get { self[BrandPaletteKey.self] }
        set { self[BrandPaletteKey.self] = newValue }
    }

    /// The system's Reduce motion or Bridgey's own Settings > General > Reduce motion.
    var brandReduceMotion: Bool {
        get { self[BrandReduceMotionKey.self] }
        set { self[BrandReduceMotionKey.self] = newValue }
    }

    /// True while ImageRenderer draws a screenshot: scroll views become plain clipped stacks.
    var snapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}

/// Sets the palette for the current appearance and combines the two reduce-motion sources.
struct BrandRoot<Content: View>: View {
    let reduceMotion: Bool
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        content
            .environment(\.brand, BrandPalette.forScheme(scheme))
            .environment(\.brandReduceMotion, reduceMotion || systemReduceMotion)
            .font(BrandFont.body(13))
    }
}

// MARK: - Fonts

/// Space Grotesk for headings and Inter for body, bundled in Resources/Fonts (SIL OFL, licences
/// alongside). The files are the Android build's static subsets (Latin and Cyrillic). They share
/// one PostScript name per family, so they are used straight from their data instead of
/// being registered by name; missing glyphs fall back to the system font.
enum BrandFont {
    enum Weight: String {
        case regular = "inter_regular"
        case medium = "inter_medium"
        case semibold = "inter_semibold"
    }

    static func heading(_ size: CGFloat) -> Font { font("space_grotesk_semibold", size: size) ?? .system(size: size, weight: .semibold) }

    static func body(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        font(weight.rawValue, size: size) ?? .system(size: size, weight: weight.systemWeight)
    }

    static func font(_ name: String, size: CGFloat) -> Font? {
        guard let graphicsFont = graphicsFonts[name] else { return nil }
        let cascade = CTFontDescriptorCreateWithNameAndSize("HelveticaNeue" as CFString, size)
        let system = NSFont.systemFont(ofSize: size).fontDescriptor as CTFontDescriptor
        let attributes = [kCTFontCascadeListAttribute: [system, cascade]] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        return Font(CTFontCreateWithGraphicsFont(graphicsFont, size, nil, descriptor))
    }

    static var isAvailable: Bool { !graphicsFonts.isEmpty }

    private static let graphicsFonts: [String: CGFont] = {
        var fonts: [String: CGFont] = [:]
        for directory in candidateDirectories {
            for name in ["inter_regular", "inter_medium", "inter_semibold", "space_grotesk_semibold"] where fonts[name] == nil {
                let url = directory.appendingPathComponent("\(name).ttf")
                guard let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider) else { continue }
                fonts[name] = font
            }
        }
        return fonts
    }()

    private static var candidateDirectories: [URL] {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("Fonts", isDirectory: true))
        }
        // Tests and `swift run`: the package's own Resources folder.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts", isDirectory: true)
        directories.append(source)
        return directories
    }
}

private extension BrandFont.Weight {
    var systemWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}

// MARK: - Motion

/// Springs from the design's motion table (Expressive Snap; mass 1). A Compose spring
/// (damping ratio z, stiffness k) is SwiftUI's interpolating spring with damping 2z*sqrt(k).
enum BrandMotion {
    static func spring(_ dampingRatio: Double, _ stiffness: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: stiffness, damping: 2 * dampingRatio * stiffness.squareRoot(), initialVelocity: 0)
    }

    /// New stream item, selected ring, menus popping in.
    static let pop = spring(0.5, 600)
    /// Items sliding down, presses, small moves.
    static let small = spring(0.6, 800)
    /// Opacity and route cross-fades.
    static let effects = spring(1.0, 1600)
    /// Pages and the stream swap: shared axis.
    static let page = spring(0.8, 380)
    /// Reduced motion: a 150 ms cross-fade on the Sharp curve.
    static let fade = Animation.timingCurve(0.33, 0, 0.67, 1, duration: 0.15)

    static let arriveRise: CGFloat = 24
    static let arriveScale: CGFloat = 0.7
    static let pressScale: CGFloat = 0.92

    /// The animation for a change, or the reduced-motion cross-fade.
    static func animation(_ animation: Animation, reduce: Bool) -> Animation { reduce ? fade : animation }

    /// A new item drops from 24 pt above and grows from 0.7; reduced motion only fades.
    static func arrival(reduce: Bool) -> AnyTransition {
        guard !reduce else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: ArrivalModifier(progress: 0),
                identity: ArrivalModifier(progress: 1)
            ),
            removal: .opacity
        )
    }
}

private struct ArrivalModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        let scale = BrandMotion.arriveScale + (1 - BrandMotion.arriveScale) * progress
        content
            .scaleEffect(scale, anchor: .top)
            .offset(y: -(1 - progress) * BrandMotion.arriveRise)
            .opacity(progress)
    }
}

/// Presses to 0.92 on spring(0.6, 800); reduced motion keeps the size.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.brandReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduce ? BrandMotion.pressScale : 1)
            .opacity(configuration.isPressed && reduce ? 0.8 : 1)
            .animation(reduce ? nil : BrandMotion.small, value: configuration.isPressed)
    }
}

// MARK: - App mark

/// "Aurora B": the launcher mark on its midnight tile (branding/bridgey-rr-app-icon.svg).
struct AuroraMark: View {
    var size: CGFloat = 22

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 108
            let tile = Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 24 * scale, style: .continuous)
            context.fill(tile, with: .color(BrandPalette.midnight))
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: 14.7129, y: 9.2391)
                .scaledBy(x: 0.72788, y: 0.72788)
            let glyph = AuroraMark.glyph.applying(transform)
            let start = CGPoint(x: 28, y: 26).applying(transform)
            let end = CGPoint(x: 84, y: 97).applying(transform)
            context.fill(
                glyph,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: BrandPalette.auroraPurple, location: 0),
                        .init(color: BrandPalette.auroraPurple, location: 0.2),
                        .init(color: BrandPalette.auroraGreen, location: 0.55),
                        .init(color: BrandPalette.auroraBlue, location: 1),
                    ]),
                    startPoint: start,
                    endPoint: end
                ),
                style: FillStyle(eoFill: true)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// M28,26H57C72,26 81,34 81,45C81,52 77,57 71,60C79,63 84,69 84,77C84,90 74,97 57,97H28Z
    /// M41,38V54H56C64,54 68,51 68,46C68,41 64,38 56,38Z M41,66V85H58C66,85 71,81 71,75C71,69 66,66 58,66Z
    static let glyph: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 28, y: 26))
        path.addLine(to: CGPoint(x: 57, y: 26))
        path.addCurve(to: CGPoint(x: 81, y: 45), control1: CGPoint(x: 72, y: 26), control2: CGPoint(x: 81, y: 34))
        path.addCurve(to: CGPoint(x: 71, y: 60), control1: CGPoint(x: 81, y: 52), control2: CGPoint(x: 77, y: 57))
        path.addCurve(to: CGPoint(x: 84, y: 77), control1: CGPoint(x: 79, y: 63), control2: CGPoint(x: 84, y: 69))
        path.addCurve(to: CGPoint(x: 57, y: 97), control1: CGPoint(x: 84, y: 90), control2: CGPoint(x: 74, y: 97))
        path.addLine(to: CGPoint(x: 28, y: 97))
        path.closeSubpath()
        path.move(to: CGPoint(x: 41, y: 38))
        path.addLine(to: CGPoint(x: 41, y: 54))
        path.addLine(to: CGPoint(x: 56, y: 54))
        path.addCurve(to: CGPoint(x: 68, y: 46), control1: CGPoint(x: 64, y: 54), control2: CGPoint(x: 68, y: 51))
        path.addCurve(to: CGPoint(x: 56, y: 38), control1: CGPoint(x: 68, y: 41), control2: CGPoint(x: 64, y: 38))
        path.closeSubpath()
        path.move(to: CGPoint(x: 41, y: 66))
        path.addLine(to: CGPoint(x: 41, y: 85))
        path.addLine(to: CGPoint(x: 58, y: 85))
        path.addCurve(to: CGPoint(x: 71, y: 75), control1: CGPoint(x: 66, y: 85), control2: CGPoint(x: 71, y: 81))
        path.addCurve(to: CGPoint(x: 58, y: 66), control1: CGPoint(x: 71, y: 69), control2: CGPoint(x: 66, y: 66))
        path.closeSubpath()
        return path
    }()
}

// MARK: - Device ring

/// A device glyph inside a ring whose style shows how it is reached.
struct DeviceRingView: View {
    let state: RingState
    let platform: String?
    var size: CGFloat = 36
    @Environment(\.brand) private var c

    var body: some View {
        ZStack {
            ring
            Circle()
                .fill(c.ringGap)
                .padding(3)
            Circle()
                .fill(c.s3)
                .padding(6)
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(state == .offline ? c.on2 : c.on)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var ring: some View {
        switch state {
        case .connected:
            Circle().fill(AngularGradient(
                colors: [BrandPalette.auroraPurple, BrandPalette.auroraBlue, BrandPalette.auroraGreen, BrandPalette.auroraPurple],
                center: .center,
                startAngle: .degrees(110),
                endAngle: .degrees(470)
            ))
        case .connecting, .privateNetwork:
            Circle().fill(BrandPalette.auroraBlue)
        case .nearby:
            Circle()
                .strokeBorder(c.good, style: StrokeStyle(lineWidth: 2, dash: [3.2, 2.6]))
                .padding(0.5)
        case .relay:
            Circle()
                .strokeBorder(BrandPalette.auroraPurple, style: StrokeStyle(lineWidth: 3, dash: [3, 3]))
        case .offline:
            Circle().fill(c.ol)
        }
    }

    private var symbol: String {
        switch platform {
        case "macos": "laptopcomputer"
        default: "smartphone"
        }
    }
}

// MARK: - Controls

/// The design's switch: 52 by 32 track, thumb grows when on. Drawn in SwiftUI.
struct BrandSwitchStyle: ToggleStyle {
    var scale: CGFloat = 0.75
    @Environment(\.brand) private var c
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.brandReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        let toggle = {
            guard isEnabled else { return }
            withAnimation(BrandMotion.animation(BrandMotion.small, reduce: reduce)) { configuration.isOn.toggle() }
        }
        return HStack(spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            track(isOn: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
        .accessibilityAction(.default, toggle)
    }

    private func track(isOn: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? c.switchOn : c.switchOff)
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : c.ol, lineWidth: 2))
            Circle()
                .fill(isOn ? c.switchThumb : c.on2)
                .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                .offset(x: isOn ? 24 : 8)
        }
        .frame(width: 52, height: 32)
        .scaleEffect(scale)
        .frame(width: 52 * scale, height: 32 * scale)
    }
}

enum PillKind {
    case gradient, tonal, outline, neutral, danger, good
}

/// Buttons from the design: gradient (the one main action), tonal, outline.
struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .tonal
    var height: CGFloat = 32
    @Environment(\.brand) private var c
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.brandReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(13, .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(background)
            .overlay(Capsule().strokeBorder(kind == .outline ? c.ol : Color.clear, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduce ? BrandMotion.pressScale : 1)
            .opacity(isEnabled ? (configuration.isPressed && reduce ? 0.8 : 1) : 0.45)
            .animation(reduce ? nil : BrandMotion.small, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .gradient: BrandPalette.midnight
        case .tonal: c.tbi
        case .outline: c.on
        case .neutral: c.on
        case .danger: c.warn
        case .good: c.tgi
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .gradient: BrandPalette.aurora
        case .tonal: c.tb
        case .outline: Color.clear
        case .neutral: c.s3
        case .danger: c.warn.opacity(c.isDark ? 0.16 : 0.1)
        case .good: c.tg
        }
    }
}

/// An icon tile: 28 pt rounded square in a tint.
enum TileTint { case blue, green, purple, neutral }

struct IconTile: View {
    let symbol: String
    let tint: TileTint
    var size: CGFloat = 28
    var corner: CGFloat = 8
    @Environment(\.brand) private var c

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(foreground)
            )
            .accessibilityHidden(true)
    }

    private var background: Color {
        switch tint {
        case .blue: c.tb
        case .green: c.tg
        case .purple: c.tp
        case .neutral: c.s3
        }
    }

    private var foreground: Color {
        switch tint {
        case .blue: c.tbi
        case .green: c.tgi
        case .purple: c.tpi
        case .neutral: c.on2
        }
    }
}

/// A button that opens a native menu. The label is plain SwiftUI, so it renders in screenshots;
/// the menu is AppKit's own and appears under the pointer.
struct PopUpMenuButton<Label: View>: View {
    let items: () -> [PopUpMenuItem]
    @ViewBuilder let label: Label

    var body: some View {
        Button {
            PopUpMenuPresenter.show(items())
        } label: {
            label
        }
        .buttonStyle(.plain)
    }
}

struct PopUpMenuItem {
    let title: String
    var checked = false
    var enabled = true
    var isSeparator = false
    let action: () -> Void

    static var separator: PopUpMenuItem { PopUpMenuItem(title: "", isSeparator: true, action: {}) }
}

@MainActor
private enum PopUpMenuPresenter {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func show(_ items: [PopUpMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let target = Target(item.action)
            let menuItem = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            menuItem.target = target
            menuItem.state = item.checked ? .on : .off
            menuItem.isEnabled = item.enabled
            menuItem.representedObject = target
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A scroll view that becomes a clipped stack while ImageRenderer draws a screenshot
/// (ImageRenderer cannot draw AppKit-backed scroll views).
struct BoundedScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        if snapshot {
            VStack(spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 0) { content }
            }
            .scrollIndicators(.automatic)
        }
    }
}
