import SwiftUI

enum LocalAgentCodesText {
    static var title: String { L10n.text("localCodes.title", fallback: "Local agent codes") }
    static var footnote: String { L10n.text("localCodes.footnote", fallback: "Uses Codes from messages. Codes stay in memory on this Mac and clear when switched off.") }
    static var toggle: String { L10n.text("localCodes.toggle", fallback: "Let local agents read codes") }
    static var detail: String { L10n.text("localCodes.detail", fallback: "Off by default. Any process running as you can read them.") }
    static var lifetime: String { L10n.text("localCodes.lifetime", fallback: "Keep codes for") }
    static var lifetimeDetail: String { L10n.text("localCodes.lifetimeDetail", fallback: "1 to 30 minutes. Default: 10.") }
    static var minutes: String { L10n.text("localCodes.minutes", fallback: "Minutes") }
    static var minutesLabel: String { L10n.text("localCodes.minutesLabel", fallback: "Code lifetime in minutes") }
    static var unit: String { L10n.text("localCodes.unit", fallback: "min") }
    static var blocked: String { L10n.text("localCodes.blocked", fallback: "Blocked senders") }
    static var blockedDetail: String { L10n.text("localCodes.blockedDetail", fallback: "One name or app per line. Matches part of the name, ignoring punctuation and case.") }
    static var blockedLabel: String { L10n.text("localCodes.blockedLabel", fallback: "Blocked senders, one per line") }
    static var defaults: String { L10n.text("localCodes.defaults", fallback: "Use defaults") }
    static var defaultsHelp: String { L10n.text("localCodes.defaultsHelp", fallback: "Banks and payment apps") }
    static var save: String { L10n.text("localCodes.save", fallback: "Save") }
    static var invalid: String { L10n.text("localCodes.invalid", fallback: "Enter a whole number from 1 to 30.") }
    static var unavailable: String { L10n.text("localCodes.unavailable", fallback: "Local access couldn't start. Switch off, then on to retry.") }
    static var clear: String { L10n.text("localCodes.clear", fallback: "Changes clear saved codes.") }
}


/// Extends the existing settings system. The switch is the main action; fields stay in place
/// when it changes. Controls provide keyboard focus, press feedback and reduced motion.
struct LocalAgentCodesCard: View {
    let options: LocalAgentCodeOptions
    var unavailable = false
    let set: (LocalAgentCodeOptions) -> Void
    @State private var minutes = "10"
    @State private var blocked = ""
    @State private var invalid = false
    @FocusState private var lifetimeFocused: Bool
    @FocusState private var blockedFocused: Bool
    @Environment(\.brand) private var c

    init(options: LocalAgentCodeOptions, unavailable: Bool = false, set: @escaping (LocalAgentCodeOptions) -> Void) {
        self.options = options
        self.unavailable = unavailable
        self.set = set
        _minutes = State(initialValue: String(options.minutes))
        _blocked = State(initialValue: options.blockedSenders.joined(separator: "\n"))
    }

    var body: some View {
        SettingsCard(title: LocalAgentCodesText.title, footnote: LocalAgentCodesText.footnote) {
            LocalAgentCodeSwitch(isOn: options.enabled, set: { on in
                var next = options
                next.enabled = on
                set(next)
            })
            SettingsRow(title: LocalAgentCodesText.lifetime, subtitle: LocalAgentCodesText.lifetimeDetail) {
                HStack(spacing: 6) {
                    TextField(LocalAgentCodesText.minutes, text: $minutes)
                        .textFieldStyle(.plain)
                        .font(BrandFont.body(13))
                        .foregroundStyle(c.on)
                        .padding(8)
                        .frame(width: 54)
                        .background(RoundedRectangle(cornerRadius: 8).fill(c.s1))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(lifetimeFocused ? c.tbi : c.olv, lineWidth: lifetimeFocused ? 2 : 1))
                        .focused($lifetimeFocused)
                        .accessibilityLabel(LocalAgentCodesText.minutesLabel)
                        .onSubmit(save)
                    Text(LocalAgentCodesText.unit).font(BrandFont.body(12)).foregroundStyle(c.on2)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                RowText(title: LocalAgentCodesText.blocked, subtitle: LocalAgentCodesText.blockedDetail)
                TextEditor(text: $blocked)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 104)
                    .background(RoundedRectangle(cornerRadius: 8).fill(c.s1))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(blockedFocused ? c.tbi : c.olv, lineWidth: blockedFocused ? 2 : 1))
                    .focused($blockedFocused)
                    .accessibilityLabel(LocalAgentCodesText.blockedLabel)
                HStack(spacing: 8) {
                    Button(LocalAgentCodesText.defaults) { blocked = LocalAgentCodeOptions.defaultBlockedSenders.joined(separator: "\n") }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                        .help(LocalAgentCodesText.defaultsHelp)
                    Spacer()
                    Button(LocalAgentCodesText.save, action: save)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                        .disabled(!hasEdits)
                }
                Text(invalid ? LocalAgentCodesText.invalid : unavailable ? LocalAgentCodesText.unavailable : LocalAgentCodesText.clear)
                    .font(BrandFont.body(12))
                    .foregroundStyle(invalid || unavailable ? c.tpi : c.on2)
                    .frame(minHeight: 30, alignment: .topLeading)
                    .accessibilityAddTraits(invalid || unavailable ? .updatesFrequently : [])
            }
            .padding(.vertical, 8)
            .settingsSearchAnchor(LocalAgentCodesText.blocked)
        }
    }

    private var rules: [String] {
        blocked.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var hasEdits: Bool { minutes != String(options.minutes) || rules != options.blockedSenders }
    private func save() {
        guard let value = Int(minutes.trimmingCharacters(in: .whitespaces)), (1...30).contains(value) else { invalid = true; return }
        invalid = false
        var next = options
        next.minutes = value
        next.blockedSenders = rules
        set(next)
        minutes = String(value)
    }
}

/// A keyboard-focusable button with a fixed-size thumb. Only its position and press state animate.
private struct LocalAgentCodeSwitch: View {
    let isOn: Bool
    let set: (Bool) -> Void
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button { set(!isOn) } label: {
            HStack(spacing: 12) {
                RowText(title: LocalAgentCodesText.toggle, subtitle: LocalAgentCodesText.detail)
                ZStack(alignment: .leading) {
                    Capsule().fill(isOn ? c.switchOn : c.switchOff)
                    Circle().fill(c.switchThumb)
                        .frame(width: 20, height: 20)
                        .offset(x: isOn ? 20 : 2)
                        .animation(reduce ? nil : BrandMotion.small, value: isOn)
                }
                .frame(width: 42, height: 24)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(LocalCodePressStyle())
        .focused($focused)
        .onHover { hovered = $0 }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? c.tbi : hovered ? c.olv : .clear, lineWidth: focused ? 2 : 1))
        .accessibilityLabel(LocalAgentCodesText.toggle)
        .accessibilityHint(LocalAgentCodesText.detail)
        .accessibilityValue(isOn ? L10n.text("action.on", fallback: "On") : L10n.text("action.off", fallback: "Off"))
        .settingsSearchAnchor(LocalAgentCodesText.toggle)
    }
}

private struct LocalCodePressStyle: ButtonStyle {
    @Environment(\.brandReduceMotion) private var reduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduce ? 0.99 : 1)
            .animation(reduce ? nil : BrandMotion.small, value: configuration.isPressed)
    }
}
