import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/*
 * Mac screen to phone: input from the viewer at absolute points on the shared display (docs/protocol.md, "Control").
 * The host maps each validated packet position with DisplayGeometryRules.macPoint and calls these; the app posts
 * CGEvents (Accessibility-gated, like the touchpad), test instances and tests record them instead.
 */

@MainActor
protocol ScreenControlInjecting: AnyObject {
    /// Moves the pointer to a global Quartz point; with a button held it is a drag of that button.
    func moveTo(_ point: CGPoint, held: Set<PointerButton>)
    func button(_ button: PointerButton, down: Bool, at point: CGPoint)
    /// Pixel scroll at a point: how far the content moves, positive right and down, as `input.scroll`.
    func scroll(dx: Int, dy: Int, at point: CGPoint)
    /// One named key down or up; Shift held adds its flag.
    func key(_ key: ScreenControl.Key, down: Bool, shift: Bool)
    /// Typed as text (Unicode key events), never as shortcuts.
    func type(_ text: String)
}

extension ScreenControl.Button {
    var pointer: PointerButton {
        switch self {
        case .primary: .left
        case .secondary: .right
        case .middle: .middle
        }
    }
}

extension ScreenControl.Key {
    /// Control, Option and Command are never posted from a viewer on this Mac: no shortcuts.
    var allowedOnMac: Bool { self != .control && self != .alt && self != .meta }

    /// The Carbon virtual key code, nil for a key this Mac never posts.
    var macKeyCode: CGKeyCode? {
        switch self {
        case .enter: KeyStroke.Code.returnKey
        case .tab: KeyStroke.Code.tab
        case .backspace: KeyStroke.Code.backspace
        case .escape: KeyStroke.Code.escape
        case .left: KeyStroke.Code.left
        case .right: KeyStroke.Code.right
        case .up: KeyStroke.Code.up
        case .down: KeyStroke.Code.down
        case .home: KeyStroke.Code.home
        case .end: KeyStroke.Code.end
        case .pageUp: KeyStroke.Code.pageUp
        case .pageDown: KeyStroke.Code.pageDown
        case .delete: 117
        case .shift: KeyStroke.Code.shift
        case .control, .alt, .meta: nil
        }
    }
}

extension CGEventInjector: ScreenControlInjecting {
    func moveTo(_ point: CGPoint, held: Set<PointerButton>) {
        let (type, button): (CGEventType, CGMouseButton) = if held.contains(.left) {
            (.leftMouseDragged, .left)
        } else if held.contains(.right) {
            (.rightMouseDragged, .right)
        } else if held.contains(.middle) {
            (.otherMouseDragged, .center)
        } else {
            (.mouseMoved, .left)
        }
        CGEvent(mouseEventSource: Self.screenSource, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    func button(_ button: PointerButton, down: Bool, at point: CGPoint) {
        // The pointer goes there first, so the click lands where the viewer touched even without a move before it.
        if down { moveTo(point, held: []) }
        let (type, mouseButton): (CGEventType, CGMouseButton) = switch button {
        case .left: (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        guard let event = CGEvent(mouseEventSource: Self.screenSource, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        let state = Self.screenClicks.count(button, down: down, point: point)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(state))
        event.post(tap: .cghidEventTap)
    }

    func scroll(dx: Int, dy: Int, at point: CGPoint) {
        moveTo(point, held: [])
        scroll(dx: dx, dy: dy, unit: .pixel)
    }

    func key(_ key: ScreenControl.Key, down: Bool, shift: Bool) {
        guard key.allowedOnMac, let code = key.macKeyCode,
              let event = CGEvent(keyboardEventSource: Self.screenSource, virtualKey: code, keyDown: down) else { return }
        var flags: CGEventFlags = shift || key == .shift ? .maskShift : []
        switch key {
        case .left, .right, .up, .down: flags.formUnion([.maskNumericPad, .maskSecondaryFn])
        case .home, .end, .pageUp, .pageDown, .delete: flags.insert(.maskSecondaryFn)
        default: break
        }
        if key == .shift && !down { flags.remove(.maskShift) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static let screenSource = InjectedEvents.source()
    private static var screenClicks = ScreenClickTracker()
}

/// Double and triple clicks for absolute input: macOS reads the click count from each event.
struct ScreenClickTracker {
    private var counter = ClickCounter(interval: NSEvent.doubleClickInterval)
    private var states: [PointerButton: Int] = [:]

    mutating func count(_ button: PointerButton, down: Bool, point: CGPoint) -> Int {
        if down {
            let state = counter.down(button, at: ProcessInfo.processInfo.systemUptime, point: point)
            states[button] = state
            return state
        }
        return states.removeValue(forKey: button) ?? 1
    }
}

/// Records what would have been injected and never posts an event: tests, and the throwaway test instance, where
/// nothing may move the person's pointer.
@MainActor
final class RecordingScreenInjector: ScreenControlInjecting {
    enum Event: Equatable {
        case move(CGPoint, held: Set<PointerButton>)
        case button(PointerButton, down: Bool, CGPoint)
        case scroll(dx: Int, dy: Int, CGPoint)
        case key(ScreenControl.Key, down: Bool, shift: Bool)
        case text(String)
    }

    private(set) var events: [Event] = []
    private(set) var lastPoint: CGPoint?
    /// Called after each event (the test instance draws the point on the test pattern).
    var onEvent: ((Event) -> Void)?

    init() {}

    var count: Int { events.count }

    func moveTo(_ point: CGPoint, held: Set<PointerButton>) { record(.move(point, held: held), point) }
    func button(_ button: PointerButton, down: Bool, at point: CGPoint) { record(.button(button, down: down, point), point) }
    func scroll(dx: Int, dy: Int, at point: CGPoint) { record(.scroll(dx: dx, dy: dy, point), point) }
    func key(_ key: ScreenControl.Key, down: Bool, shift: Bool) { record(.key(key, down: down, shift: shift), nil) }
    func type(_ text: String) { record(.text(text), nil) }

    func clear() { events.removeAll() }

    private func record(_ event: Event, _ point: CGPoint?) {
        // Keep the newest 512 only: a long test session never grows without bound.
        if events.count >= 512 { events.removeFirst(events.count - 511) }
        events.append(event)
        if let point { lastPoint = point }
        onEvent?(event)
    }
}

/// The frontmost app's focused window, in global Quartz points, through Accessibility; nil without permission or
/// without a focused window. Read only for key and text input.
enum FocusedWindow {
    static func frame() -> CGRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let axWindow = window as! AXUIElement // swiftlint:disable:this force_cast
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position), // swiftlint:disable:this force_cast
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil } // swiftlint:disable:this force_cast
        return CGRect(origin: position, size: size)
    }
}
