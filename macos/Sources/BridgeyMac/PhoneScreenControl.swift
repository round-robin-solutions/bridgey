import AppKit
import SwiftUI

/*
 * Controlling the phone from its screen window (phone_control_draft1, docs/protocol.md "Mac controls the phone"): the
 * bar under the picture (Control, Back, Home, Recents) and the mapping from mouse, trackpad and keyboard to the phone's
 * input. Clicks and drags are one finger, a right click is a long press, scrolling is a drag, a pinch is two fingers,
 * typing is text on Android 13 and later. Positions are fractions of the full picture; the letterbox sends nothing.
 */

/// What the window asks of the phone screen coordinator (PhoneScreen).
@MainActor
protocol PhoneScreenControlling: AnyObject {
    func beginControl(_ deviceID: String)
    func endControl(_ deviceID: String)
    @discardableResult func controlInput(_ deviceID: String, _ action: PhoneControlAction) -> Bool
    @discardableResult func pressKey(_ deviceID: String, _ key: ScreenControl.Key, shift: Bool) -> Bool
}

extension PhoneScreen: PhoneScreenControlling {}

/// The line the window shows when control ended or was refused.
func phoneControlNoteText(_ reason: PhoneControlReason, phone: String) -> String? {
    switch reason {
    case .user: nil
    case .declined: String(format: L10n.text("phonecontrol.note.declined", fallback: "%@ did not allow control"), phone)
    case .disabled: String(format: L10n.text("phonecontrol.note.disabled", fallback: "Control from this Mac is off on %@"), phone)
    case .permission: String(format: L10n.text("phonecontrol.note.permission", fallback: "Turn on Bridgey control on %@"), phone)
    case .locked: String(format: L10n.text("phonecontrol.note.locked", fallback: "%@ is locked"), phone)
    case .focus: String(format: L10n.text("phonecontrol.note.focus", fallback: "Typing stopped: %@ has another display on"), phone)
    case .timeout: String(format: L10n.text("phonecontrol.note.timeout", fallback: "Control stopped: no answer from %@"), phone)
    case .localStop: String(format: L10n.text("phonecontrol.note.localStop", fallback: "Control stopped on %@"), phone)
    case .rate, .invalid, .sourceChanged, .failed: L10n.text("phonecontrol.note.failed", fallback: "Control stopped")
    }
}

/// Control, then Back, Home and Recents, under the picture of a control-capable stream.
struct PhoneControlBar: View {
    @ObservedObject var model: PhoneScreenWindowModel
    let begin: () -> Void
    let end: () -> Void
    let navigate: (ScreenControl.Navigation) -> Void
    @Environment(\.brand) private var c

    static let height: CGFloat = 44

    var body: some View {
        let control = model.control
        let active = control.phase == .active
        HStack(spacing: 4) {
            switch control.phase {
            case .off:
                Button(L10n.text("phonecontrol.control", fallback: "Control"), action: begin)
                    .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                    .disabled(!control.allowed || model.endedMessage != nil)
                    .help(control.allowed ? L10n.text("phonecontrol.control.help", fallback: "Tap, swipe and type on the phone")
                        : String(format: L10n.text("phonecontrol.note.permission", fallback: "Turn on Bridgey control on %@"), model.phoneName))
            case .starting, .waiting:
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: end)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
            case .active:
                Button(L10n.text("phonecontrol.stop", fallback: "Stop control"), action: end)
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                    .help(L10n.text("phonecontrol.stop.help", fallback: "Stop controlling the phone; the picture stays"))
            }
            Spacer(minLength: 8)
            navButton("chevron.backward", L10n.text("phonecontrol.back", fallback: "Back"), .back, enabled: active && control.input.navigation)
            navButton("circle", L10n.text("phonecontrol.home", fallback: "Home"), .home, enabled: active && control.input.navigation)
            navButton("square", L10n.text("phonecontrol.recents", fallback: "Recents"), .recents, enabled: active && control.input.navigation)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(c.s1)
        .overlay(alignment: .top) { Rectangle().fill(c.ol).frame(height: 1) }
    }

    private func navButton(_ symbol: String, _ label: String, _ action: ScreenControl.Navigation, enabled: Bool) -> some View {
        Button { navigate(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? c.on : c.on2)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
    }
}

/*
 * Mouse, trackpad and keyboard to phone input. Points are in the picture view, origin at the top left. A gesture that
 * starts on the letterbox sends nothing; a drag that started on the picture stays on its edge. Main actor only.
 */
@MainActor
final class PhoneScreenInput {
    enum PinchPhase { case began, changed, ended }

    /// Sends one action; false when it was refused.
    var send: (PhoneControlAction) -> Bool = { _ in false }
    var press: (ScreenControl.Key, Bool) -> Bool = { _, _ in false }
    /// The picture view's size and the stream's size.
    var layout: () -> (view: CGSize, width: Int, height: Int) = { (.zero, 0, 0) }
    /// Control is on: nothing is sent otherwise.
    var active: () -> Bool = { false }
    /// A right click holds this long, a long press on the phone.
    var longPressSeconds: TimeInterval = 0.65
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }

    private var dragging = false
    private var holding = false
    private var holdToken = 0
    private var remainder = (x: 0.0, y: 0.0)
    private var pinch: (center: (x: Double, y: Double), radius: Double)?

    /// Control ended or the geometry changed: whatever was held is forgotten (the phone already lifted it).
    func reset() {
        dragging = false
        holding = false
        holdToken += 1
        remainder = (0, 0)
        pinch = nil
    }

    private func fraction(_ point: CGPoint, clamp: Bool = false) -> (x: Double, y: Double)? {
        let size = layout()
        return PhoneScreenGeometry.fraction(viewSize: size.view, videoWidth: size.width, videoHeight: size.height, point: point, clamp: clamp)
    }

    func mouseDown(at point: CGPoint) {
        guard active(), !holding, pinch == nil, let at = fraction(point) else { return }
        dragging = send(.touch(contact: 0, phase: .down, x: at.x, y: at.y))
    }

    func mouseDragged(at point: CGPoint) {
        guard dragging, let at = fraction(point, clamp: true) else { return }
        _ = send(.touch(contact: 0, phase: .move, x: at.x, y: at.y))
    }

    func mouseUp(at point: CGPoint) {
        guard dragging else { return }
        dragging = false
        let at = fraction(point, clamp: true) ?? (x: 0.5, y: 0.5)
        _ = send(.touch(contact: 0, phase: .up, x: at.x, y: at.y))
    }

    /// A right click: a long press where it is.
    func rightMouseDown(at point: CGPoint) {
        guard active(), !dragging, !holding, pinch == nil, let at = fraction(point) else { return }
        guard send(.touch(contact: 0, phase: .down, x: at.x, y: at.y)) else { return }
        holding = true
        holdToken += 1
        let token = holdToken
        schedule(longPressSeconds) { [weak self] in
            guard let self, self.holding, self.holdToken == token else { return }
            self.holding = false
            _ = self.send(.touch(contact: 0, phase: .up, x: at.x, y: at.y))
        }
    }

    /// Scrolling: the content moves by the deltas in view points (AppKit's scrollingDelta, already in the person's
    /// direction). Lines from a mouse wheel count as 24 points each.
    func scroll(dx: Double, dy: Double, precise: Bool, at point: CGPoint) {
        guard active(), !dragging, let at = fraction(point, clamp: true) else { return }
        let size = layout()
        let scale = precise ? 1.0 : 24.0
        remainder.x += PhoneScreenGeometry.streamPixels(viewDelta: dx * scale, viewSize: size.view, videoWidth: size.width, videoHeight: size.height)
        remainder.y += PhoneScreenGeometry.streamPixels(viewDelta: dy * scale, viewSize: size.view, videoWidth: size.width, videoHeight: size.height)
        let sx = Int(remainder.x)
        let sy = Int(remainder.y)
        remainder.x -= Double(sx)
        remainder.y -= Double(sy)
        guard sx != 0 || sy != 0 else { return }
        _ = send(.scroll(dx: sx, dy: sy, x: at.x, y: at.y))
    }

    /// A trackpad pinch: two fingers either side of the pointer, moving apart or together.
    func magnify(_ magnification: Double, phase: PinchPhase, at point: CGPoint) {
        guard active() else { return }
        switch phase {
        case .began:
            guard !dragging, !holding, pinch == nil, let at = fraction(point) else { return }
            let current = (center: at, radius: 0.12)
            let (a, b) = fingers(current)
            guard send(.touch(contact: 0, phase: .down, x: a.x, y: a.y)) else { return }
            _ = send(.touch(contact: 1, phase: .down, x: b.x, y: b.y))
            pinch = current
        case .changed:
            guard var current = pinch else { return }
            current.radius = min(max(current.radius * (1 + magnification), 0.02), 0.45)
            pinch = current
            let (a, b) = fingers(current)
            _ = send(.touch(contact: 0, phase: .move, x: a.x, y: a.y))
            _ = send(.touch(contact: 1, phase: .move, x: b.x, y: b.y))
        case .ended:
            guard let current = pinch else { return }
            pinch = nil
            let (a, b) = fingers(current)
            _ = send(.touch(contact: 0, phase: .up, x: a.x, y: a.y))
            _ = send(.touch(contact: 1, phase: .up, x: b.x, y: b.y))
        }
    }

    /// The two fingers of a pinch, horizontally either side of the centre; the radius is a fraction of the shorter side.
    private func fingers(_ pinch: (center: (x: Double, y: Double), radius: Double)) -> ((x: Double, y: Double), (x: Double, y: Double)) {
        let size = layout()
        let short = Double(min(size.width, size.height))
        let dx = size.width > 0 ? pinch.radius * short / Double(size.width) : pinch.radius
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        return ((clamp(pinch.center.x - dx), pinch.center.y), (clamp(pinch.center.x + dx), pinch.center.y))
    }

    /// A key on this Mac; true when it went to the phone. Command and Control shortcuts stay on the Mac.
    func key(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard active() else { return false }
        if modifiers.contains(.command) || modifiers.contains(.control) { return false }
        if let named = Self.namedKeys[keyCode] {
            _ = press(named, modifiers.contains(.shift))
            return true
        }
        guard let characters else { return false }
        let text = String(String.UnicodeScalarView(characters.unicodeScalars.filter { !ScreenControl.isControl($0) && !(0xF700...0xF8FF).contains($0.value) }))
        guard !text.isEmpty else { return false }
        _ = send(.text(text))
        return true
    }

    /// Command-V: the Mac's clipboard text is typed on the phone (the phone's clipboard is never written). Line breaks
    /// become Return; at most 2,000 characters.
    func paste(_ text: String) -> Bool {
        guard active() else { return false }
        let lines = String(text.prefix(2_000)).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { _ = press(.enter, false) }
            for chunk in Self.chunks(String(line)) { _ = send(.text(chunk)) }
        }
        return true
    }

    /// Text in pieces the phone accepts: at most 256 scalars and 1,024 UTF-8 bytes, no control characters.
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars where !ScreenControl.isControl(scalar) {
            let size = String(scalar).utf8.count
            if current.count + 1 > ScreenControl.maxTextScalars || bytes + size > ScreenControl.maxTextBytes {
                out.append(String(current))
                current = String.UnicodeScalarView()
                bytes = 0
            }
            current.append(scalar)
            bytes += size
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// Mac key codes (kVK_*) for the contract's named keys.
    static let namedKeys: [UInt16: ScreenControl.Key] = [
        36: .enter, 76: .enter, 48: .tab, 51: .backspace, 117: .delete, 53: .escape,
        123: .left, 124: .right, 125: .down, 126: .up, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
    ]
}
