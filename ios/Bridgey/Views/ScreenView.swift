import SwiftUI

/// A phone's or a Mac's screen, full screen: the picture on a dark stage, a bar with the device, Control and Stop,
/// and, while controlling a phone, its Back, Home and Recents buttons. Leaving the app stops the stream.
struct ScreenView: View {
    let deviceID: String
    @EnvironmentObject private var screen: ScreenModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboard = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(keyboard: $keyboard)
            ZStack {
                Color.black
                if let stream = screen.stream {
                    ScreenSurface(
                        display: screen.display,
                        videoSize: CGSize(width: stream.width, height: stream.height),
                        mode: inputMode,
                        keyboard: keyboard && screen.control.active,
                        label: String(localized: "Screen of \(screen.deviceName)"),
                        live: screen.live,
                        send: { screen.send($0) }
                    )
                    if !screen.live {
                        ProgressView().tint(.white).accessibilityHidden(true)
                    }
                } else {
                    ScreenStatus()
                        .padding(24)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            if !screen.isMac, screen.control.active, screen.control.navigation {
                PhoneButtons(keyboard: $keyboard)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { ScreenNotice() }
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: screen.control.active)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { screen.close(reason: "left_screen") }
        }
        .onChange(of: screen.control.active) { _, active in
            if !active { keyboard = false }
        }
    }

    private var inputMode: ScreenInputMode {
        guard screen.control.active else { return .off }
        return screen.isMac ? .mac : .phone
    }
}

/// The device, what kind of stream it is, Control, Keyboard and Stop.
private struct ScreenTopBar: View {
    @Binding var keyboard: Bool
    @EnvironmentObject private var screen: ScreenModel
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            Button { screen.close(reason: "user") } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(c.on)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(c.s3))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Stop")
            .accessibilityHint("Stops showing this screen.")
            .accessibilityIdentifier("screen.stop")
            VStack(alignment: .leading, spacing: 3) {
                Text(screen.deviceName)
                    .font(.headline)
                    .foregroundStyle(c.on)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("screen.title")
                HStack(spacing: 6) {
                    if screen.stream?.screenshots == true {
                        Text("Slower mode")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(c.tpi)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(c.tp))
                            .accessibilityHint("About three pictures a second, because nobody approved video on the phone.")
                            .accessibilityIdentifier("screen.slower")
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(c.on2)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if screen.control.available {
                if screen.control.active, screen.control.keys || screen.control.text {
                    Button { keyboard.toggle() } label: {
                        Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(keyboard ? c.tb : c.s3))
                            .foregroundStyle(keyboard ? c.tbi : c.on)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(keyboard ? "Hide keyboard" : "Keyboard")
                    .accessibilityIdentifier("screen.keyboard")
                }
                Toggle(isOn: Binding(get: { screen.control.phase != "off" }, set: { screen.setControl($0) })) {
                    Text("Control").font(.subheadline.weight(.semibold)).foregroundStyle(c.on)
                }
                .fixedSize()
                .tint(c.pri)
                .accessibilityValue(controlValue)
                .accessibilityHint("Your touches go to \(screen.deviceName).")
                .accessibilityIdentifier("screen.control")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(c.s1.ignoresSafeArea(edges: .top))
    }

    /// The Mac's display, or how control is going.
    private var detail: String? {
        switch screen.control.phase {
        case "starting", "waiting": return String(localized: "Asking for control…")
        case "active": return String(localized: "Controlling")
        default: return screen.stream?.displayName
        }
    }

    private var controlValue: String {
        switch screen.control.phase {
        case "active": String(localized: "On")
        case "off": String(localized: "Off")
        default: String(localized: "Asking")
        }
    }
}

/// While there is no picture: asking, waiting for the phone or Mac, or why it ended, with Try again.
private struct ScreenStatus: View {
    @EnvironmentObject private var screen: ScreenModel
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 16) {
            switch screen.phase {
            case .idle, .asking, .showing:
                ProgressView().tint(.white)
                Text("Asking \(screen.deviceName)…").font(.body).foregroundStyle(.white)
            case let .waiting(needs):
                ProgressView().tint(.white)
                Text(screen.waitingText(needs))
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("screen.waiting")
            case let .ended(text):
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("screen.ended")
                Button("Try again") { screen.request() }
                    .buttonStyle(PillButtonStyle(kind: .gradient))
                    .accessibilityIdentifier("screen.retry")
            }
        }
        .frame(maxWidth: 420)
    }
}

/// A phone's own buttons while controlling it.
private struct PhoneButtons: View {
    @Binding var keyboard: Bool
    @EnvironmentObject private var screen: ScreenModel
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.backward", "Back", action: "back", id: "screen.back")
            button("circle", "Home", action: "home", id: "screen.home")
            button("square.on.square", "Recent apps", action: "recents", id: "screen.recents")
        }
        .padding(.vertical, 6)
        .background(c.s1.ignoresSafeArea(edges: .bottom))
    }

    private func button(_ symbol: String, _ label: LocalizedStringKey, action: String, id: String) -> some View {
        Button { screen.send(ScreenCommands.navigate(action)) } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(c.on)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A short note over the picture about control, gone after a few seconds.
private struct ScreenNotice: View {
    @EnvironmentObject private var screen: ScreenModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        ZStack {
            if let notice = screen.notice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(c.on)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(c.s3))
                    .padding(.horizontal, 24)
                    .padding(.top, 72)
                    .onTapGesture { screen.notice = nil }
                    .transition(reduce ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        if screen.notice == notice { screen.notice = nil }
                    }
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: notice) }
            }
        }
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: screen.notice)
    }
}
