import SwiftUI
import UIKit

/// How touches on the picture become input.
enum ScreenInputMode: Equatable {
    /// Control is off: touches do nothing.
    case off
    /// An Android phone: each finger is a touch contact, as on the phone.
    case phone
    /// A Mac: a tap clicks, a drag drags, a long press or two-finger tap is a secondary click, two fingers scroll.
    case mac
}

/// The stream's picture (the display layer) with touch, gesture and keyboard input. Typing goes through a hidden
/// keyboard: this view is the text input while Keyboard is on.
final class ScreenSurfaceView: UIView, UIKeyInput {
    typealias Command = ScreenCommands.Command

    var display: ScreenDisplay? {
        didSet {
            guard display !== oldValue else { return }
            oldValue?.layer.removeFromSuperlayer()
            if let display { layer.addSublayer(display.layer) }
            setNeedsLayout()
        }
    }

    var videoSize: CGSize = .zero
    var mode: ScreenInputMode = .off {
        didSet { if mode != oldValue { modeChanged() } }
    }
    var send: ([Command]) -> Void = { _ in }
    var wantsKeyboard = false {
        didSet {
            guard wantsKeyboard != oldValue else { return }
            if wantsKeyboard { becomeFirstResponder() } else { resignFirstResponder() }
        }
    }

    /// Phone: which finger is which contact (0 to 9).
    private var contacts: [ObjectIdentifier: Int] = [:]
    /// Mac: a drag in progress, at its last point.
    private var dragging: CGPoint?
    private var lastScroll: CGPoint = .zero
    private var macRecognizers: [UIGestureRecognizer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityIdentifier = "screen.surface"
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(secondaryTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        tap.require(toFail: twoFingerTap)
        macRecognizers = [tap, twoFingerTap, long, drag, scroll]
        for r in macRecognizers {
            r.isEnabled = false
            addGestureRecognizer(r)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display?.layer.frame = bounds
        CATransaction.commit()
    }

    private func modeChanged() {
        for r in macRecognizers { r.isEnabled = mode == .mac }
        liftAll()
        if mode == .off { wantsKeyboard = false }
        accessibilityTraits = mode == .off ? [.image] : [.allowsDirectInteraction]
    }

    private func fraction(_ point: CGPoint, clamped: Bool = false) -> CGPoint? {
        clamped ? Letterbox.clampedFraction(view: bounds.size, video: videoSize, point: point)
            : Letterbox.fraction(view: bounds.size, video: videoSize, point: point)
    }

    // MARK: A phone: every finger

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard mode == .phone else { return super.touchesBegan(touches, with: event) }
        var out: [Command] = []
        for touch in touches {
            guard let p = fraction(touch.location(in: self)), let contact = (0..<10).first(where: { !contacts.values.contains($0) }) else { continue }
            contacts[ObjectIdentifier(touch)] = contact
            out.append(ScreenCommands.touch(contact: contact, phase: "down", at: p))
        }
        send(out)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard mode == .phone else { return super.touchesMoved(touches, with: event) }
        send(touches.compactMap { touch in
            guard let contact = contacts[ObjectIdentifier(touch)], let p = fraction(touch.location(in: self), clamped: true) else { return nil }
            return ScreenCommands.touch(contact: contact, phase: "move", at: p)
        })
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard mode == .phone else { return super.touchesEnded(touches, with: event) }
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard mode == .phone else { return super.touchesCancelled(touches, with: event) }
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        send(touches.compactMap { touch in
            guard let contact = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { return nil }
            let p = fraction(touch.location(in: self), clamped: true) ?? CGPoint(x: 0.5, y: 0.5)
            return ScreenCommands.touch(contact: contact, phase: "up", at: p)
        })
    }

    /// Control ended or the mode changed: the library already releases what it held; this side forgets its fingers.
    private func liftAll() {
        contacts = [:]
        dragging = nil
    }

    // MARK: A Mac: pointer gestures

    @objc private func tapped(_ r: UITapGestureRecognizer) {
        guard let p = fraction(r.location(in: self)) else { return }
        send(ScreenCommands.click(at: p))
    }

    @objc private func secondaryTapped(_ r: UITapGestureRecognizer) {
        guard let p = fraction(r.location(in: self)) else { return }
        send(ScreenCommands.click(at: p, button: "secondary"))
    }

    @objc private func longPressed(_ r: UILongPressGestureRecognizer) {
        guard r.state == .began, let p = fraction(r.location(in: self)) else { return }
        send(ScreenCommands.click(at: p, button: "secondary"))
    }

    @objc private func dragged(_ r: UIPanGestureRecognizer) {
        let location = r.location(in: self)
        switch r.state {
        case .began:
            // From where the finger first touched, not where the pan was recognised.
            let start = CGPoint(x: location.x - r.translation(in: self).x, y: location.y - r.translation(in: self).y)
            guard let s = fraction(start), let p = fraction(location, clamped: true) else { return }
            dragging = p
            send([ScreenCommands.pointer(at: s), ScreenCommands.button(down: true, at: s), ScreenCommands.pointer(at: p)])
        case .changed:
            guard dragging != nil, let p = fraction(location, clamped: true) else { return }
            dragging = p
            send([ScreenCommands.pointer(at: p)])
        case .ended, .cancelled, .failed:
            guard let last = dragging else { return }
            dragging = nil
            send([ScreenCommands.button(down: false, at: fraction(location, clamped: true) ?? last)])
        default:
            break
        }
    }

    @objc private func scrolled(_ r: UIPanGestureRecognizer) {
        let t = r.translation(in: self)
        switch r.state {
        case .began:
            lastScroll = .zero
        case .changed:
            let moved = Letterbox.streamPixels(view: bounds.size, video: videoSize, distance: CGPoint(x: t.x - lastScroll.x, y: t.y - lastScroll.y))
            let (dx, dy) = (Int(moved.x.rounded()), Int(moved.y.rounded()))
            guard dx != 0 || dy != 0, let p = fraction(r.location(in: self), clamped: true) else { return }
            // Only the whole pixels sent count, so slow scrolling still adds up.
            let picture = Letterbox.picture(view: bounds.size, video: videoSize)
            let points = videoSize.width > 0 ? picture.width / videoSize.width : 1
            lastScroll = CGPoint(x: lastScroll.x + CGFloat(dx) * points, y: lastScroll.y + CGFloat(dy) * points)
            send([ScreenCommands.scroll(dx: dx, dy: dy, at: p)])
        default:
            lastScroll = .zero
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { wantsKeyboard && mode != .off }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        send(ScreenCommands.typed(text))
    }

    func deleteBackward() {
        send([ScreenCommands.press("backspace")])
    }

    // The keyboard types what is pressed, without corrections.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    /// A hardware keyboard's arrows, Escape, Delete and paging keys, as named keys. Characters come through insertText.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, mode != .off, let name = Self.namedKey(key.keyCode) else { continue }
            send([ScreenCommands.press(name, shift: key.modifierFlags.contains(.shift))])
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    static func namedKey(_ code: UIKeyboardHIDUsage) -> String? {
        switch code {
        case .keyboardLeftArrow: "left"
        case .keyboardRightArrow: "right"
        case .keyboardUpArrow: "up"
        case .keyboardDownArrow: "down"
        case .keyboardEscape: "escape"
        case .keyboardDeleteForward: "delete"
        case .keyboardHome: "home"
        case .keyboardEnd: "end"
        case .keyboardPageUp: "page_up"
        case .keyboardPageDown: "page_down"
        default: nil
        }
    }
}

/// The surface in SwiftUI.
struct ScreenSurface: UIViewRepresentable {
    let display: ScreenDisplay
    let videoSize: CGSize
    let mode: ScreenInputMode
    let keyboard: Bool
    let label: String
    let live: Bool
    let send: ([ScreenCommands.Command]) -> Void

    func makeUIView(context: Context) -> ScreenSurfaceView { ScreenSurfaceView() }

    func updateUIView(_ view: ScreenSurfaceView, context: Context) {
        view.display = display
        view.videoSize = videoSize
        view.mode = mode
        view.send = send
        view.wantsKeyboard = keyboard
        view.accessibilityLabel = label
        view.accessibilityValue = live ? String(localized: "Live") : String(localized: "Starting")
        view.accessibilityHint = mode == .off ? nil : String(localized: "Touches go to the other device.")
    }
}
