import AppKit
import SwiftUI

#if DEBUG
/// Live checks of the Settings window in a debug test instance (TestInstance, make-test-instance.sh). Control files in
/// `/tmp/<bundle id>-control/`, as for PairingCoordinator's TestControl:
///
/// - `settings-open`: shows Settings, at the pane named in the file (a SettingsPane raw value) when there is one.
/// - `settings-close`: closes the window, as its close button does.
/// - `settings-appearance`: `light`, `dark` or `system`, for this app only.
/// - `settings-keys`: keys separated by spaces (`cmd-f`, `down`, `up`, `return`, `esc`, `tab`, `shift-tab`,
///   `text:<characters>`, and `blur`, which takes the keyboard away from every field as a click elsewhere would), posted one at a time to this app's own event queue for the Settings window, so they pass
///   the window's key monitor and its first responder as typed keys do. Nothing reaches any other app, and no
///   Accessibility or input monitoring is involved.
/// - `settings-snapshot`: once the keys have gone, draws the window into the PNG named in the file (under /tmp) and
///   writes `settings-state.json` beside the control files: focus, the search state, and where the highlighted row
///   sits in the pane's visible area.
///
/// Release builds compile none of it.
@MainActor
final class SettingsTestHooks {
    static let shared = SettingsTestHooks()

    /// What the window shows, reported by SettingsWindowView and SearchPulse.
    struct Probe: Equatable {
        var query = ""
        var selected = 0
        var pane = ""
        var target: String?
        var fieldFocused = false
        var choosable: [String] = []
    }

    var probe = Probe()
    /// The highlighted row's frame in the window's content (top-left origin), while it pulses.
    var pulse: CGRect?

    private var open: (SettingsPane?) -> Void = { _ in }
    private var timer: Timer?
    private var keys: [String] = []
    private var pendingSnapshot: String?

    private var directory: URL { URL(fileURLWithPath: "/tmp/\(Edition.identifier)-control", isDirectory: true) }

    func start(open: @escaping (SettingsPane?) -> Void) {
        guard TestInstance.enabled, timer == nil else { return }
        self.open = open
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One key per 150 ms, so SwiftUI has settled before the next one, as with a person typing quickly.
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func take(_ name: String) -> String? {
        let url = directory.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var window: NSWindow? { NSApp.windows.first { $0.identifier == SettingsSearchKeys.windowID } }

    private func tick() {
        if let pane = take("settings-open") { open(SettingsPane(rawValue: pane)) }
        if take("settings-close") != nil { window?.performClose(nil) }
        if let appearance = take("settings-appearance") {
            NSApp.appearance = switch appearance {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }
        }
        if let text = take("settings-keys") {
            for token in text.split(separator: " ").map(String.init) {
                if token.hasPrefix("text:") {
                    keys += token.dropFirst(5).map { "char:\($0)" }
                } else {
                    keys.append(token)
                }
            }
        }
        if let path = take("settings-snapshot"), path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") { pendingSnapshot = path }
        if !keys.isEmpty {
            post(keys.removeFirst())
            return
        }
        if let path = pendingSnapshot {
            pendingSnapshot = nil
            snapshot(to: path)
        }
    }

    private func post(_ token: String) {
        guard let window else { return }
        if token == "blur" {
            window.makeFirstResponder(nil)
            return
        }
        let key: (code: UInt16, characters: String, flags: NSEvent.ModifierFlags)? = switch token {
        case "cmd-f": (3, "f", .command)
        case "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.numericPad, .function])
        case "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.numericPad, .function])
        case "return": (36, "\r", [])
        case "esc": (53, "\u{1B}", [])
        case "tab": (48, "\t", [])
        case "shift-tab": (48, "\u{19}", .shift)
        default: token.hasPrefix("char:") ? (0, String(token.dropFirst(5)), []) : nil
        }
        guard let key else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                                            isARepeat: false, keyCode: key.code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private func snapshot(to path: String) {
        var state: [String: Any] = ["at": Date().timeIntervalSince1970, "windowShown": window?.isVisible == true,
                                    "appActive": NSApp.isActive, "keyWindow": window?.isKeyWindow == true,
                                    "occluded": window.map { !$0.occlusionState.contains(.visible) } ?? NSNull()]
        if let window, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            let responder = window.firstResponder
            state["firstResponder"] = responder.map { String(describing: type(of: $0)) } ?? NSNull()
            if let editor = responder as? NSTextView, editor.isFieldEditor {
                state["fieldEditorText"] = editor.string
                state["fieldEditorFor"] = (editor.delegate as? NSView).map { String(describing: type(of: $0)) } ?? NSNull()
            }
            let height = view.bounds.height
            // The pane's scroll view: the widest one right of the sidebar.
            let scrolls = Self.scrollViews(in: view).map { scroll -> (CGRect, NSScrollView) in
                let frame = scroll.convert(scroll.bounds, to: view)
                return (view.isFlipped ? frame : CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height), scroll)
            }
            state["scrollViews"] = scrolls.map { frame, scroll in
                ["frame": Self.rect(frame), "scrollY": scroll.documentVisibleRect.minY, "documentHeight": scroll.documentView?.frame.height ?? 0]
            }
            if let (frame, scroll) = scrolls.filter({ $0.0.minX >= 200 }).max(by: { $0.0.width < $1.0.width }) {
                state["paneViewport"] = Self.rect(frame)
                state["paneScrollY"] = scroll.documentVisibleRect.minY
                state["paneDocumentHeight"] = scroll.documentView?.frame.height ?? 0
                if let pulse {
                    state["pulse"] = Self.rect(pulse)
                    state["pulseInView"] = frame.contains(CGPoint(x: frame.midX, y: pulse.minY)) && frame.contains(CGPoint(x: frame.midX, y: pulse.maxY))
                    state["pulseCentreOffset"] = pulse.midY - frame.midY
                }
            }
        }
        state["probe"] = ["query": probe.query, "selected": probe.selected, "pane": probe.pane, "target": probe.target ?? NSNull(),
                          "fieldFocused": probe.fieldFocused, "choosable": probe.choosable]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("settings-state.json"), options: .atomic)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func rect(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
#endif
