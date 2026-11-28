import SwiftUI

/// The phone's call, ringing both ways, and the phone's notifications, as live cards above the stream. They last
/// while Bridgey is open: iOS ends the session soon after the app leaves the screen.
struct AlertCards: View {
    @EnvironmentObject private var alerts: AlertsModel
    @Environment(\.brandReduceMotion) private var reduce
    @State private var showAll = false

    /// Notifications shown before Show all.
    static let collapsed = 3

    var body: some View {
        Group {
            if let call = alerts.call {
                CallCardView(card: call)
                    .transition(BrandMotion.arrival(reduce: reduce))
            }
            ForEach(alerts.rings) { ring in
                RingCardView(ring: ring)
                    .transition(BrandMotion.arrival(reduce: reduce))
            }
            ForEach(visible) { alert in
                NotificationCard(alert: alert)
                    .transition(BrandMotion.arrival(reduce: reduce))
            }
            if alerts.notifications.count > Self.collapsed {
                Button(showAll ? "Show fewer" : "Show all \(alerts.notifications.count)") { showAll.toggle() }
                    .buttonStyle(PillButtonStyle(kind: .neutral))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("alert.showAll")
            }
        }
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: alerts.notifications.map(\.id))
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: alerts.call?.id)
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: alerts.rings.map(\.id))
    }

    private var visible: [PhoneAlert] {
        showAll ? alerts.notifications : Array(alerts.notifications.prefix(Self.collapsed))
    }
}

// MARK: - A notification

private struct NotificationCard: View {
    let alert: PhoneAlert
    @EnvironmentObject private var alerts: AlertsModel
    @Environment(\.brand) private var c
    @FocusState private var replying: Bool

    var body: some View {
        CardShell {
            HStack(alignment: .top, spacing: 12) {
                AppIcon(data: alert.icon, symbol: alert.code == nil ? "bell" : "key")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(alert.source)
                        Text("·")
                        Text(alert.date, style: .time)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(c.on2)
                    .lineLimit(1)
                    if !alert.title.isEmpty {
                        Text(alert.title).font(.subheadline.weight(.semibold)).foregroundStyle(c.on).lineLimit(2)
                    }
                    if !alert.text.isEmpty {
                        Text(alert.text).font(.subheadline).foregroundStyle(c.on).lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("alert.content")
                Spacer(minLength: 0)
                Button { alerts.dismiss(alert) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(c.on2).frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss")
                .accessibilityHint("Clears it on \(alert.deviceName) too.")
                .accessibilityIdentifier("alert.dismiss")
            }
            if let code = alert.code {
                HStack(spacing: 12) {
                    Text(code.code)
                        .font(BrandFont.heading(26, relativeTo: .title2))
                        .monospacedDigit()
                        .foregroundStyle(c.on)
                        .textSelection(.enabled)
                        .accessibilityLabel("Code \(code.code.map(String.init).joined(separator: " "))")
                        .accessibilityIdentifier("alert.code")
                    Spacer(minLength: 8)
                    Button("Copy code") { alerts.copyCode(alert) }
                        .buttonStyle(PillButtonStyle(kind: .gradient))
                        .accessibilityIdentifier("alert.copyCode")
                }
            }
            if !alert.buttons.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(alert.buttons) { action in
                            Button(action.title) { alerts.run(action, on: alert) }
                                .buttonStyle(PillButtonStyle(kind: .tonal))
                                .accessibilityIdentifier("alert.action")
                        }
                    }
                }
            }
            if alert.canReply {
                HStack(spacing: 8) {
                    TextField("Reply", text: Binding(get: { alerts.replies[alert.id] ?? "" }, set: { alerts.replies[alert.id] = $0 }), axis: .vertical)
                        .lineLimit(1...4)
                        .focused($replying)
                        .submitLabel(.send)
                        .onSubmit { alerts.reply(to: alert) }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(c.s3))
                        .foregroundStyle(c.on)
                        .accessibilityLabel("Reply to \(alert.title.isEmpty ? alert.source : alert.title)")
                        .accessibilityIdentifier("alert.reply")
                    Button { alerts.reply(to: alert) } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(BrandPalette.midnight)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(BrandPalette.aurora))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(draft.isEmpty)
                    .opacity(draft.isEmpty ? 0.5 : 1)
                    .accessibilityLabel("Send reply")
                    .accessibilityIdentifier("alert.send")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alert.card")
    }

    private var draft: String { (alerts.replies[alert.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The app's own icon from the phone, or a symbol in a tile.
private struct AppIcon: View {
    let data: Data?
    let symbol: String

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: symbol, tint: .purple)
        }
    }
}

// MARK: - The phone's call

private struct CallCardView: View {
    let card: CallCard
    @EnvironmentObject private var alerts: AlertsModel
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            HStack(spacing: 14) {
                Text(initials)
                    .font(BrandFont.heading(20, relativeTo: .title3))
                    .foregroundStyle(BrandPalette.midnight)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(BrandPalette.aurora))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.caller)
                        .font(BrandFont.heading(22, relativeTo: .title2))
                        .foregroundStyle(c.on)
                        .lineLimit(2)
                    status.font(.subheadline).foregroundStyle(c.on2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("call.caller")
            if card.buttons.isEmpty {
                Text("Answer on \(card.alert.deviceName).").font(.footnote).foregroundStyle(c.on2)
            } else {
                HStack(spacing: 8) {
                    ForEach(card.buttons) { action in
                        Button(action.title) { alerts.run(action, on: card.alert) }
                            .buttonStyle(PillButtonStyle(kind: kind(action), fill: true))
                            .accessibilityIdentifier("call.action")
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(c.pri.opacity(0.45), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.card")
    }

    @ViewBuilder private var status: some View {
        switch card.alert.callType {
        case "incoming": Text("Incoming call on \(card.alert.deviceName)")
        case "ongoing":
            if let since = card.since {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Call in progress · \(Self.elapsed(from: since, to: context.date))")
                        .monospacedDigit()
                }
            } else {
                Text("Call in progress")
            }
        case "screening": Text("Call screening on \(card.alert.deviceName)")
        default: Text("Phone call on \(card.alert.deviceName)")
        }
    }

    private func kind(_ action: AlertAction) -> PillKind {
        switch action.role {
        case .answer: .gradient
        case .end: .danger
        case .other: .tonal
        }
    }

    /// "AK" for Anna Kapoor, "#" for a number.
    private var initials: String {
        let words = card.caller.split(separator: " ").filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "#" }
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + last).uppercased()
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Ringing

private struct RingCardView: View {
    let ring: RingCard
    @EnvironmentObject private var alerts: AlertsModel
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            HStack(spacing: 12) {
                IconTile(symbol: "bell.and.waves.left.and.right", tint: ring.direction == .incoming ? .purple : .blue)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(c.on)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ring.title")
            Button("Stop") { alerts.stop(ring) }
                .buttonStyle(PillButtonStyle(kind: ring.direction == .incoming ? .gradient : .tonal, fill: ring.direction == .incoming))
                .accessibilityLabel(ring.direction == .incoming ? "Stop ringing" : "Stop ringing \(ring.deviceName)")
                .accessibilityIdentifier("ring.stop")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ring.card")
    }

    private var title: String {
        switch ring.direction {
        case .incoming: String(localized: "\(ring.deviceName) is ringing this \(UIDevice.current.localizedModel)")
        case .outgoing: ring.confirmed ? String(localized: "Ringing \(ring.deviceName)") : String(localized: "Asking \(ring.deviceName) to ring…")
        }
    }
}
