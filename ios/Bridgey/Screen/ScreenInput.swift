import CoreGraphics
import Foundation

/// The picture inside the view: the stream fitted whole and centred (docs/protocol.md "Geometry", display::letterbox
/// in rust/client). A touch becomes fractions of the stream; one on the letterbox sends nothing.
enum Letterbox {
    static func picture(view: CGSize, video: CGSize) -> CGRect {
        guard view.width > 0, view.height > 0, video.width > 0, video.height > 0 else { return .zero }
        let k = min(view.width / video.width, view.height / video.height)
        let size = CGSize(width: video.width * k, height: video.height * k)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Fractions of the stream, or nil on the letterbox.
    static func fraction(view: CGSize, video: CGSize, point: CGPoint) -> CGPoint? {
        let p = picture(view: view, video: video)
        guard p.width > 0, p.height > 0 else { return nil }
        let x = (point.x - p.minX) / p.width, y = (point.y - p.minY) / p.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// For a finger already down: it may slide onto the letterbox, so the position stays on the picture's edge.
    static func clampedFraction(view: CGSize, video: CGSize, point: CGPoint) -> CGPoint? {
        let p = picture(view: view, video: video)
        guard p.width > 0, p.height > 0 else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - p.minX) / p.width)), y: min(1, max(0, (point.y - p.minY) / p.height)))
    }

    /// Stream pixels for a distance on screen (scrolling).
    static func streamPixels(view: CGSize, video: CGSize, distance: CGPoint) -> CGPoint {
        let p = picture(view: view, video: video)
        guard p.width > 0 else { return .zero }
        let k = video.width / p.width
        return CGPoint(x: distance.x * k, y: distance.y * k)
    }
}

/// The commands a gesture or key sends, as `bridgey_phone` JSON. Pure, so tests check the mapping without a view.
enum ScreenCommands {
    typealias Command = [String: Any]

    private static func at(_ p: CGPoint) -> Command { ["x": Double(p.x), "y": Double(p.y)] }

    // MARK: A phone: touches and navigation

    static func touch(contact: Int, phase: String, at p: CGPoint) -> Command {
        ["op": "touch", "contact": contact, "phase": phase].merging(at(p)) { $1 }
    }

    static func navigate(_ action: String) -> Command { ["op": "navigate", "action": action] }

    // MARK: A Mac: a pointer and buttons

    /// A tap: the pointer goes there, then a click.
    static func click(at p: CGPoint, button: String = "primary") -> [Command] {
        [["op": "pointer"].merging(at(p)) { $1 },
         ["op": "button", "button": button, "down": true].merging(at(p)) { $1 },
         ["op": "button", "button": button, "down": false].merging(at(p)) { $1 }]
    }

    static func pointer(at p: CGPoint) -> Command { ["op": "pointer"].merging(at(p)) { $1 } }

    static func button(down: Bool, at p: CGPoint, button: String = "primary") -> Command {
        ["op": "button", "button": button, "down": down].merging(at(p)) { $1 }
    }

    /// Stream pixels the content moves, positive right and down: it follows the fingers.
    static func scroll(dx: Int, dy: Int, at p: CGPoint) -> Command {
        ["op": "scroll", "dx": dx, "dy": dy].merging(at(p)) { $1 }
    }

    // MARK: Keys

    /// Typed text: Return and Tab become key presses, other control characters go nowhere, the rest is text.
    static func typed(_ text: String) -> [Command] {
        var out: [Command] = []
        var run = ""
        func flush() {
            if !run.isEmpty { out.append(["op": "text", "text": run]) }
            run = ""
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r":
                flush()
                out.append(press("enter"))
            case "\t":
                flush()
                out.append(press("tab"))
            default:
                if CharacterSet.controlCharacters.contains(scalar) { continue }
                run.unicodeScalars.append(scalar)
                // The contract's limit per packet: 256 characters.
                if run.unicodeScalars.count >= 200 { flush() }
            }
        }
        flush()
        return out
    }

    /// One press of a named key (enter, tab, backspace, escape, left, right, up, down, home, end, page_up,
    /// page_down, delete). Control, Alt and Meta are never sent.
    static func press(_ key: String, shift: Bool = false) -> Command {
        ["op": "press", "key": key, "shift": shift]
    }
}
