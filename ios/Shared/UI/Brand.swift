import CoreText
import SwiftUI

/*
 * Direction B "Stream" for iOS: the Midnight Aurora palette of the Mac and Android apps (BrandTheme.swift,
 * Theme.kt), Space Grotesk headings with the system font for everything else, the design's springs, and the
 * Aurora B mark. Motion moves only transform and opacity; Reduce Motion (the system's or Bridgey's own) turns
 * movement into a short cross-fade.
 */

struct BrandPalette: Equatable {
    let bg, s1, s2, s3, s4: Color
    let on, on2: Color
    let ol, olv: Color
    let pri, onpri, good: Color
    let tp, tpi, tb, tbi, tg, tgi: Color
    let warn: Color
    let ringGap: Color
    let isDark: Bool

    static let midnight = Color(hex: 0x050B18)
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
        ringGap: Color(hex: 0xF4F7FA),
        isDark: false
    )

    static func forScheme(_ scheme: ColorScheme) -> BrandPalette { scheme == .dark ? .dark : .light }

    static var aurora: LinearGradient {
        LinearGradient(
            stops: [.init(color: auroraPurple, location: 0), .init(color: auroraBlue, location: 0.55), .init(color: auroraGreen, location: 1)],
            startPoint: UnitPoint(x: 0, y: 0.36),
            endPoint: UnitPoint(x: 1, y: 0.64)
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

private struct BrandPaletteKey: EnvironmentKey {
    static let defaultValue = BrandPalette.dark
}

private struct BrandReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var brand: BrandPalette {
        get { self[BrandPaletteKey.self] }
        set { self[BrandPaletteKey.self] = newValue }
    }

    /// The system's Reduce Motion or Bridgey's own Settings > Reduce motion.
    var brandReduceMotion: Bool {
        get { self[BrandReduceMotionKey.self] }
        set { self[BrandReduceMotionKey.self] = newValue }
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
            .tint(BrandPalette.forScheme(scheme).pri)
    }
}

// MARK: - Fonts

/// Space Grotesk (SIL OFL, licence beside the file) for headings; it scales with Dynamic Type through its text
/// style. Body text is the system font.
enum BrandFont {
    private static let headingName: String? = {
        guard let url = Bundle.main.url(forResource: "space_grotesk_semibold", withExtension: "ttf"),
              let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider) else { return nil }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterGraphicsFont(font, &error)
        return font.postScriptName as String?
    }()

    static func heading(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        guard let name = headingName else { return .system(style, design: .default).weight(.semibold) }
        return .custom(name, size: size, relativeTo: style)
    }
}

// MARK: - Motion

/// Springs from the design's motion table. A Compose spring (damping ratio z, stiffness k) is SwiftUI's
/// interpolating spring with damping 2z*sqrt(k).
enum BrandMotion {
    static func spring(_ dampingRatio: Double, _ stiffness: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: stiffness, damping: 2 * dampingRatio * stiffness.squareRoot(), initialVelocity: 0)
    }

    /// New stream items, cards and chips arriving.
    static let pop = spring(0.5, 600)
    /// Presses and small moves.
    static let small = spring(0.6, 800)
    /// Opacity and colour changes.
    static let effects = spring(1.0, 1600)
    /// Screens and sheets' content: shared axis.
    static let page = spring(0.8, 380)
    /// Reduced motion: a 150 ms cross-fade.
    static let fade = Animation.timingCurve(0.33, 0, 0.67, 1, duration: 0.15)

    static func animation(_ animation: Animation, reduce: Bool) -> Animation { reduce ? fade : animation }

    /// A new item drops from 24 pt above and grows from 0.7; reduced motion only fades.
    static func arrival(reduce: Bool) -> AnyTransition {
        guard !reduce else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: ArrivalModifier(progress: 0), identity: ArrivalModifier(progress: 1)),
            removal: .opacity
        )
    }

    /// Moving forward between screens: in from the trailing edge a little, fading.
    static func forward(reduce: Bool) -> AnyTransition {
        guard !reduce else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: SlideFade(offset: 32, opacity: 0), identity: SlideFade(offset: 0, opacity: 1)),
            removal: .modifier(active: SlideFade(offset: -32, opacity: 0), identity: SlideFade(offset: 0, opacity: 1))
        )
    }
}

private struct ArrivalModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.7 + 0.3 * progress, anchor: .top)
            .offset(y: -(1 - progress) * 24)
            .opacity(progress)
    }
}

private struct SlideFade: ViewModifier {
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: offset).opacity(opacity)
    }
}

/// Presses to 0.92; reduced motion dims instead.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.brandReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduce ? 0.92 : 1)
            .opacity(configuration.isPressed && reduce ? 0.7 : 1)
            .animation(reduce ? nil : BrandMotion.small, value: configuration.isPressed)
    }
}

// MARK: - Mark

/// "Aurora B": the launcher mark on its midnight tile (branding/bridgey-rr-app-icon.svg).
struct AuroraMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 108
            let tile = Path(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 24 * scale, style: .continuous)
            context.fill(tile, with: .color(BrandPalette.midnight))
            let transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: 14.7129, y: 9.2391).scaledBy(x: 0.72788, y: 0.72788)
            context.fill(
                AuroraMark.glyph.applying(transform),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: BrandPalette.auroraPurple, location: 0), .init(color: BrandPalette.auroraPurple, location: 0.2),
                        .init(color: BrandPalette.auroraGreen, location: 0.55), .init(color: BrandPalette.auroraBlue, location: 1),
                    ]),
                    startPoint: CGPoint(x: 28, y: 26).applying(transform),
                    endPoint: CGPoint(x: 84, y: 97).applying(transform)
                ),
                style: FillStyle(eoFill: true)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

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

/// How a device is reached right now; each has its own ring.
enum RingState: Equatable {
    /// Connected: the aurora ring.
    case connected
    /// Pairing or reconnecting: solid blue.
    case connecting
    /// On this network, not paired: dashed green.
    case nearby
    /// Paired, not connected: plain grey.
    case offline
}

struct DeviceRingView: View {
    let state: RingState
    let platform: String?
    var size: CGFloat = 40
    @Environment(\.brand) private var c

    var body: some View {
        ZStack {
            ring
            Circle().fill(c.ringGap).padding(3)
            Circle().fill(c.s3).padding(6)
            Image(systemName: DeviceRingView.symbol(platform))
                .font(.system(size: size * 0.36, weight: .medium))
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
                center: .center, startAngle: .degrees(110), endAngle: .degrees(470)
            ))
        case .connecting:
            Circle().fill(BrandPalette.auroraBlue)
        case .nearby:
            Circle().strokeBorder(c.good, style: StrokeStyle(lineWidth: 2, dash: [3.2, 2.6])).padding(0.5)
        case .offline:
            Circle().fill(c.ol)
        }
    }

    static func symbol(_ platform: String?) -> String {
        switch platform {
        case "macos": "laptopcomputer"
        case "windows", "linux": "pc"
        case "ios": "iphone"
        default: "smartphone"
        }
    }
}

// MARK: - Controls

enum PillKind {
    case gradient, tonal, outline, neutral, danger
}

/// The design's buttons: gradient for the one main action, tonal, outline, neutral, danger.
struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .tonal
    var fill = false
    @Environment(\.brand) private var c
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.brandReduceMotion) private var reduce

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: 44)
            .background(background)
            .overlay(Capsule().strokeBorder(kind == .outline ? c.ol : .clear, lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduce ? 0.95 : 1)
            .opacity(isEnabled ? (configuration.isPressed && reduce ? 0.75 : 1) : 0.45)
            .animation(reduce ? nil : BrandMotion.small, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .gradient: BrandPalette.midnight
        case .tonal: c.tbi
        case .outline, .neutral: c.on
        case .danger: c.warn
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .gradient: BrandPalette.aurora
        case .tonal: c.tb
        case .outline: Color.clear
        case .neutral: c.s3
        case .danger: c.warn.opacity(c.isDark ? 0.16 : 0.1)
        }
    }
}

enum TileTint { case blue, green, purple, neutral }

/// A rounded square holding a symbol, in a tint.
struct IconTile: View {
    let symbol: String
    var tint: TileTint = .blue
    var size: CGFloat = 36
    @Environment(\.brand) private var c

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(foreground))
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

/// A card on the stream's surface.
struct CardShell<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(c.s2))
    }
}
