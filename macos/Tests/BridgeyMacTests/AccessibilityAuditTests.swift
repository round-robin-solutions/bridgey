import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Accessibility checks for the Mac app, in two halves.
///
/// The tree walk hosts the Settings window's six groups (More options open), the menu bar panel, Messages, Transfers,
/// Calls, the code float, the call card, the phone screen window and the screen-sharing prompt in an off-screen window
/// and reads the accessibility tree in this process (no Accessibility permission, no prompt), in English and Russian.
/// SwiftUI only builds its own nodes once an assistive app such as VoiceOver connects, so in a test the walk reaches the
/// AppKit-backed controls (text fields, text areas, scroll views, menus): each needs a name or a placeholder.
/// The source checks cover the SwiftUI controls the walk cannot see: icon-only buttons need an accessibility label, and
/// tap gestures stand in for buttons only where the keyboard has another way.
/// With BRIDGEY_A11Y_DUMP=<dir> each tree is also written out as text.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    override func tearDown() {
        L10n.bundle = .main
        L10n.language = nil
        super.tearDown()
    }

    // MARK: Surfaces

    private func surfaces() -> [(String, CGSize, AnyView)] {
        let settings = SettingsSearchScreenshots().model
        var list: [(String, CGSize, AnyView)] = SettingsGroup.allCases.map { group in
            ("settings-\(group.rawValue)", SettingsWindowView.size, AnyView(
                SettingsWindowView(model: settings, actions: SettingsActions(), group: .constant(group))
                    .environment(\.settingsExpandAll, true)))
        }
        list.append(("panel", CGSize(width: StreamPanelView.width, height: 720),
                     AnyView(StreamPanelView(model: DesignScreenshots().connectedModel, actions: PanelActions()))))
        list.append(("messages", MessagesView.size, AnyView(MessagesView(model: MessagesScreenshots().model, actions: MessagesActions(), copiedMessage: nil))))
        let transfers = TransfersWindowScreenshots()
        list.append(("transfers", TransfersWindowView.size, AnyView(
            TransfersWindowView(state: transfers.state(), live: transfers.feed(true), filter: .constant(TransfersFilter()),
                                selection: .constant("record"), pendingSend: .constant(nil)))))
        list.append(("calls", CGSize(width: 420, height: 620), AnyView(CallsView(model: CallsScreenshots().model, actions: CallsActions()))))
        let code = CodeFloatContent()
        code.card = LiveCodeCard(id: "a", code: "482913", sender: "HDFC Bank", deviceName: "OnePlus 11", receivedAt: Date())
        list.append(("code-float", CGSize(width: 360, height: 160), AnyView(CodeFloatView(content: code, copy: {}, close: {}))))
        let call = CallCardContent()
        call.call = RemoteCallStatus(notificationID: "n1", deviceID: "d1", applicationName: "Phone", caller: "Anna Kapoor", detail: "",
                                     type: "ongoing", actions: [RemoteCallAction(id: "hang", title: "Hang up")])
        list.append(("call-card", CGSize(width: 380, height: 200), AnyView(CallOverlayView(content: call, hide: {}, perform: { _ in }))))
        for (phase, control) in [("off", PhoneControlView(capable: true, allowed: true, width: 720, height: 1600)),
                                 ("active", PhoneControlView(capable: true, allowed: true, phase: .active,
                                                            input: ScreenControl.InputCapabilities(pointer: true, touch: true, keys: true, text: true, navigation: true),
                                                            width: 720, height: 1600))] {
            let screen = PhoneScreenWindowModel(phoneName: "OnePlus 11", controllable: true)
            screen.control = control
            list.append(("phone-screen-\(phase)", CGSize(width: 405, height: 700), AnyView(
                PhoneScreenWindowContent(model: screen, stop: {}) { Color.gray }
                    .frame(width: 405, height: 700))))
        }
        list.append(("screen-prompt", CGSize(width: 420, height: 260), AnyView(VStack {
            DisplayConsentPrompt(deviceName: "Pixel 9", blocked: false, allow: {}, deny: {})
            RemoteControlPill(title: "Pixel 9", symbol: "rectangle.on.rectangle", onStop: {})
        })))
        return list
    }

    func testEveryControlHasANameInEnglish() throws {
        try audit(language: "en")
    }

    func testEveryControlHasANameInRussian() throws {
        try audit(language: "ru")
    }

    private func audit(language: String) throws {
        L10n.bundle = try XCTUnwrap(Bundle(path: Self.resources.appendingPathComponent("\(language).lproj").path))
        L10n.language = language
        var report: [String] = []
        var controls = 0
        for (name, size, view) in surfaces() {
            let tree = AXTree(view: view, size: size, scheme: .light)
            let problems = tree.problems()
            report += problems.map { "\(name): \($0)" }
            if let dump = ProcessInfo.processInfo.environment["BRIDGEY_A11Y_DUMP"], !dump.isEmpty {
                let folder = URL(fileURLWithPath: dump, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try tree.dump().write(to: folder.appendingPathComponent("\(name)-\(language).txt"), atomically: true, encoding: .utf8)
            }
            controls += tree.controls
        }
        XCTAssertGreaterThan(controls, 5, "the walk found no controls; is the accessibility tree still reachable in tests?")
        XCTAssertTrue(report.isEmpty, "Controls without a name (\(language)):\n" + report.joined(separator: "\n"))
    }

    // MARK: Source checks

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/BridgeyMac")

    private func sourceFiles() throws -> [(String, String)] {
        try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }.sorted().map {
            ($0, try String(contentsOf: Self.sources.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// A button whose label is only a symbol is read by its symbol name ("xmark.circle.fill") unless it has a label;
    /// `.help` is only the tooltip.
    func testIconOnlyButtonsHaveAnAccessibilityLabel() throws {
        var missing: [String] = []
        for (file, source) in try sourceFiles() {
            let text = Array(source.utf16)
            let string = source as NSString
            let opener = try NSRegularExpression(pattern: #"\bButton\s*(\((?:[^()]|\([^()]*\))*\))?\s*\{"#)
            for match in opener.matches(in: source, range: NSRange(location: 0, length: string.length)) {
                let braceAt = match.range.location + match.range.length - 1
                let bodyEnd = Self.closingBrace(text, from: braceAt)
                var label: String
                var chainStart: Int
                let rest = string.substring(with: NSRange(location: bodyEnd, length: min(40, string.length - bodyEnd)))
                if let labelRange = rest.range(of: #"^\s*label:\s*\{"#, options: .regularExpression) {
                    let open = bodyEnd + rest.distance(from: rest.startIndex, to: labelRange.upperBound) - 1
                    let close = Self.closingBrace(text, from: open)
                    label = string.substring(with: NSRange(location: open, length: close - open))
                    chainStart = close
                } else if match.range(at: 1).location != NSNotFound, string.substring(with: match.range(at: 1)).contains("action") {
                    label = string.substring(with: NSRange(location: braceAt, length: bodyEnd - braceAt))
                    chainStart = bodyEnd
                } else {
                    continue
                }
                guard label.contains("Image("), label.range(of: #"\b(Text|Label)\(|L10n\.|configuration\.label"#, options: .regularExpression) == nil else { continue }
                // The modifier chain: the lines right after the button that start with a dot.
                var chain = ""
                for line in string.substring(from: chainStart).split(separator: "\n", omittingEmptySubsequences: false).dropFirst().prefix(12) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix(".") else { break }
                    chain += trimmed
                }
                if !chain.contains(".accessibilityLabel(") {
                    let line = string.substring(to: match.range.location).components(separatedBy: "\n").count
                    missing.append("\(file):\(line)")
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "Icon-only buttons without .accessibilityLabel:\n" + missing.joined(separator: "\n"))
    }

    /// `.onTapGesture` is not reachable with Tab and has no button role. Each use here has a keyboard way and was checked
    /// by hand; a new one needs a Button or an entry with its reason.
    func testTapGesturesHaveAKeyboardWay() throws {
        let reviewed: [String: Int] = [
            "MessagesWindow.swift": 2, // conversation rows and search hits: button role; Up and Down open conversations
            "CallsWindow.swift": 2, // recents rows: Up and Down move, Return calls (CallsWindow keyDown)
            "TransfersWindowView.swift": 3, // items: the arrow keys select, Return opens, Space previews; the backdrop tap is Escape's twin
            "SetupWindow.swift": 1, // the backdrop behind Leave setup?: its buttons and Escape do the same
            "SettingsWindow.swift": 1, // the hidden developer-settings counter on the version line
        ]
        var found: [String: Int] = [:]
        for (file, source) in try sourceFiles() {
            let count = source.components(separatedBy: ".onTapGesture").count - 1
            if count > 0 { found[file] = count }
        }
        XCTAssertEqual(found, reviewed, "A tap gesture changed: use a Button, or check the keyboard way and update this list")
    }

    private static func closingBrace(_ text: [UInt16], from start: Int) -> Int {
        var depth = 0
        var index = start
        var inString = false
        while index < text.count {
            let char = text[index]
            if inString {
                if char == 92 { index += 1 } else if char == 34 { inString = false }
            } else if char == 34 {
                inString = true
            } else if char == 123 {
                depth += 1
            } else if char == 125 {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return index
    }
}

/// The accessibility tree of a SwiftUI view hosted in an off-screen window.
@MainActor
struct AXTree {
    struct Node {
        let depth: Int
        let role: String
        let label: String
        let title: String
        let value: String
        let help: String
        let placeholder: String
        let enabled: Bool
    }

    static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .textArea, .slider, .comboBox,
        .disclosureTriangle, .incrementor, .link,
    ]

    private(set) var nodes: [Node] = []
    private let window: NSWindow

    /// SwiftUI builds accessibility nodes only once an assistive client has asked the app for them. In a test nothing
    /// has, so ask the way an assistive app does (in this process; no Accessibility permission involved).
    static let enableAccessibility: Void = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: attribute))
        }
        _ = app.accessibilityWindows()
    }()

    init<V: View>(view: V, size: CGSize, scheme: ColorScheme) {
        _ = Self.enableAccessibility
        let host = NSHostingView(rootView: BrandRoot(reduceMotion: true) { view }
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height))
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Off screen, never key: SwiftUI builds its accessibility nodes once something asks and the view draws again.
        window.orderFrontRegardless()
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            host.display()
            _ = host.accessibilityChildren()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        var visited = Set<ObjectIdentifier>()
        walk(host, depth: 0, visited: &visited)
        window.orderOut(nil)
        window.close()
    }

    var controls: Int { nodes.filter { Self.controlRoles.contains(NSAccessibility.Role(rawValue: $0.role)) }.count }

    private mutating func walk(_ element: Any, depth: Int, visited: inout Set<ObjectIdentifier>) {
        guard depth < 80, let object = element as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return }
        let ax = object as? NSAccessibilityProtocol
        let role = ax?.accessibilityRole()?.rawValue ?? ""
        func text(_ value: Any?) -> String {
            switch value {
            case let string as String: string
            case let attributed as NSAttributedString: attributed.string
            case let number as NSNumber: number.stringValue
            default: ""
            }
        }
        if !role.isEmpty {
            nodes.append(Node(depth: depth, role: role, label: ax?.accessibilityLabel() ?? "", title: ax?.accessibilityTitle() ?? "",
                              value: text(ax?.accessibilityValue()), help: ax?.accessibilityHelp() ?? "",
                              placeholder: ax?.accessibilityPlaceholderValue() ?? "", enabled: ax?.isAccessibilityEnabled() ?? true))
        }
        // A scroll bar's arrow and page parts are the system's own, read by VoiceOver from the bar.
        guard role != NSAccessibility.Role.scrollBar.rawValue else { return }
        for child in ax?.accessibilityChildren() ?? [] {
            walk(child, depth: depth + 1, visited: &visited)
        }
    }

    /// Controls VoiceOver would read without a name, or with an SF Symbol's name.
    func problems() -> [String] {
        nodes.compactMap { node in
            guard Self.controlRoles.contains(NSAccessibility.Role(rawValue: node.role)) else { return nil }
            let name = [node.label, node.title].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            let isField = node.role == NSAccessibility.Role.textField.rawValue || node.role == NSAccessibility.Role.textArea.rawValue
            if name.isEmpty, !(isField && !node.placeholder.isEmpty) {
                return "\(node.role) with no name (value \"\(node.value)\", help \"\(node.help)\")"
            }
            if name.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil {
                return "\(node.role) named by its symbol \"\(name)\""
            }
            return nil
        }
    }

    func dump() -> String {
        nodes.map { node in
            let fields = [("label", node.label), ("title", node.title), ("value", node.value), ("help", node.help), ("placeholder", node.placeholder)]
                .filter { !$0.1.isEmpty }.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
            return String(repeating: "  ", count: node.depth) + node.role + (node.enabled ? "" : " (dimmed)") + (fields.isEmpty ? "" : " " + fields)
        }.joined(separator: "\n")
    }
}
