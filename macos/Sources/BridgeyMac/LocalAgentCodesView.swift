import SwiftUI

/// Extends the existing settings system. The switch is the main action; fields stay in place
/// when it changes. BrandSwitchStyle and PillButtonStyle provide focus, press and reduced motion.
struct LocalAgentCodesCard: View {
    let options: LocalAgentCodeOptions
    var unavailable = false
    let set: (LocalAgentCodeOptions) -> Void
    @State private var minutes = "10"
    @State private var blocked = ""
    @State private var invalid = false
    @Environment(\.brand) private var c

    init(options: LocalAgentCodeOptions, unavailable: Bool = false, set: @escaping (LocalAgentCodeOptions) -> Void) {
        self.options = options
        self.unavailable = unavailable
        self.set = set
        _minutes = State(initialValue: String(options.minutes))
        _blocked = State(initialValue: options.blockedSenders.joined(separator: "\n"))
    }

    var body: some View {
        SettingsCard(title: "Local agent codes", footnote: "Uses Codes from messages. Codes stay in memory on this Mac and clear when switched off.") {
            SettingsToggle(title: "Let local agents read codes", subtitle: "Off by default. Any process running as you can read them.", divider: false,
                           isOn: options.enabled, set: { on in
                var next = options
                next.enabled = on
                set(next)
            })
            SettingsRow(title: "Keep codes for", subtitle: "1 to 30 minutes. Default: 10.") {
                HStack(spacing: 6) {
                    TextField("Minutes", text: $minutes)
                        .textFieldStyle(.plain)
                        .font(BrandFont.body(13))
                        .foregroundStyle(c.on)
                        .padding(8)
                        .frame(width: 54)
                        .background(RoundedRectangle(cornerRadius: 8).fill(c.s1))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c.olv, lineWidth: 1))
                        .accessibilityLabel("Code lifetime in minutes")
                        .onSubmit(save)
                    Text("min").font(BrandFont.body(12)).foregroundStyle(c.on2)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                RowText(title: "Blocked senders", subtitle: "One name or app per line. Matches part of the name, ignoring punctuation and case.")
                TextEditor(text: $blocked)
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 104)
                    .background(RoundedRectangle(cornerRadius: 8).fill(c.s1))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c.olv, lineWidth: 1))
                    .accessibilityLabel("Blocked senders, one per line")
                HStack(spacing: 8) {
                    Button("Use defaults") { blocked = LocalAgentCodeOptions.defaultBlockedSenders.joined(separator: "\n") }
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                        .help("Banks and payment apps")
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(PillButtonStyle(kind: .tonal, height: 30))
                        .disabled(!hasEdits)
                }
                Text(invalid ? "Enter a whole number from 1 to 30." : unavailable ? "Local access couldn't start. Switch off, then on to retry." : "Changes clear saved codes.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(invalid || unavailable ? c.tpi : c.on2)
                    .frame(minHeight: 30, alignment: .topLeading)
                    .accessibilityAddTraits(invalid || unavailable ? .updatesFrequently : [])
            }
            .padding(.vertical, 8)
            .settingsSearchAnchor("Blocked senders")
        }
        .onAppear {
            minutes = String(options.minutes)
            blocked = options.blockedSenders.joined(separator: "\n")
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
