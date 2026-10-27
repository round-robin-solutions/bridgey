import SwiftUI

/*
 * Settings > Privacy > Reset Bridgey on this device: four choices, each with a confirm dialog
 * that lists exactly what goes and what stays (LocalDataReset.items and .kept).
 */

struct ResetPane: View {
    let model: SettingsModel
    let actions: SettingsActions
    @Environment(\.brand) private var c

    var body: some View {
        if let message = model.setup.resetMessage {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(c.tgi)
                Text(message)
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.tg))
            .accessibilityElement(children: .combine)
        }
        SettingsCard(footnote: L10n.setup("reset.note", fallback: "Only this Mac changes. Your phones keep their own data. Each choice asks before it deletes anything.")) {
            ForEach(Array(ResetChoice.allCases.enumerated()), id: \.element) { index, choice in
                HStack(spacing: 12) {
                    IconTile(symbol: choice.symbol, tint: choice == .everything ? .purple : .neutral, size: 30, corner: 9)
                    RowText(title: choice.title, subtitle: choice.summary)
                    Button(choice == .everything
                           ? L10n.setup("reset.action.everything.row", fallback: "Reset\u{2026}")
                           : L10n.setup("reset.action.delete.row", fallback: "Delete\u{2026}")) {
                        actions.setup.confirmReset(choice)
                    }
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 28))
                }
                .padding(.vertical, 10)
                .frame(minHeight: 56)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(c.olv).frame(height: 1) } }
            }
        }
    }
}

/// The confirm dialog: what is deleted, what is kept, Cancel and the destructive button.
struct ResetConfirmView: View {
    let choice: ResetChoice
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}
    @Environment(\.brand) private var c

    static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconTile(symbol: choice.symbol, tint: choice == .everything ? .purple : .neutral, size: 44, corner: 12)
            Text(choice.confirmTitle)
                .font(BrandFont.heading(20))
                .foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ResetList(title: L10n.setup("reset.deletes", fallback: "Deletes"),
                      lines: LocalDataReset.confirmLines(choice), symbol: "minus.circle.fill", tint: c.warn)
            let kept = LocalDataReset.kept(choice)
            if kept.isEmpty {
                Text(L10n.setup("reset.everything.kept", fallback: "Nothing is kept. Paired devices will need pairing again, and Bridgey returns to first-run setup."))
                    .font(BrandFont.body(13, .medium))
                    .foregroundStyle(c.on)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ResetList(title: L10n.setup("reset.keeps", fallback: "Keeps"),
                          lines: kept.map(\.title), symbol: "checkmark.circle.fill", tint: c.tgi)
            }
            if choice.restartsApp {
                Text(L10n.setup("reset.restarts", fallback: "Bridgey restarts to finish."))
                    .font(BrandFont.body(12))
                    .foregroundStyle(c.on2)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.setup("action.cancel", fallback: "Cancel"), action: onCancel)
                    .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(choice.confirmButton, role: .destructive, action: onConfirm)
                    .buttonStyle(PillButtonStyle(kind: .danger, height: 32))
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: Self.width, alignment: .leading)
        .background(c.s1)
    }
}

private struct ResetList: View {
    let title: String
    let lines: [String]
    let symbol: String
    let tint: Color
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(c.on2)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(line)
                        .font(BrandFont.body(13))
                        .foregroundStyle(c.on)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
