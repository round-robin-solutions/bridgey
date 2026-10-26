import AppKit
import SwiftUI

@MainActor
final class CallOverlayWindowController: NSWindowController {
    init(pairing: PairingCoordinator) {
        let root = CallOverlayView(pairing: pairing)
        let panel = NSPanel(contentViewController: NSHostingController(rootView: root))
        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // macOS draws notification banners in a full-screen window at level 21 (measured on macOS
        // 26), above `.floating` (3): a banner arriving during a call used to cover the card in the
        // same top-right corner. `.statusBar` (25) keeps the card above banners and other windows.
        panel.level = callOverlayWindowLevel
        // On every Space and over full-screen apps; stationary so Mission Control does not hide it.
        panel.collectionBehavior = callOverlayCollectionBehavior
        panel.animationBehavior = .utilityWindow
        panel.setContentSize(NSSize(width: 390, height: 154))
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Placed once when it appears; updates while it is on screen never move it.
    func show() {
        if window?.isVisible != true { positionNearTopRight() }
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func positionNearTopRight() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - 18,
            y: visible.maxY - frame.height - 18
        ))
    }
}

let callOverlayWindowLevel = NSWindow.Level.statusBar
let callOverlayCollectionBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
]

/// A soft ring repeated while a call rings on the phone, until it is answered, declined, hidden or
/// ends. Stops by itself after `maximumDuration`, as a phone stops ringing.
@MainActor
final class CallRinger {
    static let interval: TimeInterval = 3
    static let maximumDuration: TimeInterval = 120
    private let sound: NSSound?
    private var startedAt: Date?
    private var next: DispatchWorkItem?

    init(sound: NSSound? = NSSound(named: NSSound.Name("Glass"))) {
        self.sound = sound
        sound?.volume = 0.6
    }

    var isRinging: Bool { next != nil }

    func update(ringing: Bool) {
        if ringing {
            guard startedAt == nil else { return }
            startedAt = Date()
            ring()
        } else {
            next?.cancel()
            next = nil
            startedAt = nil
            sound?.stop()
        }
    }

    private func ring() {
        guard let startedAt, Date().timeIntervalSince(startedAt) < Self.maximumDuration else {
            next = nil
            return
        }
        sound?.stop()
        sound?.play()
        let work = DispatchWorkItem { [weak self] in self?.ring() }
        next = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval, execute: work)
    }
}

private struct CallOverlayView: View {
    @ObservedObject var pairing: PairingCoordinator

    var body: some View {
        Group {
            if let call = pairing.remoteCall {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(remoteCallStatusTitle(call.type))
                                .font(.headline)
                            Text(call.caller.isEmpty ? call.applicationName : call.caller)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            pairing.hideCallOverlay()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Hide call controls; they remain available in Bridgey")
                    }

                    if call.actions.isEmpty {
                        Text("Use the phone to control this call.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ForEach(visibleCallActions(call.actions, limit: 2)) { action in
                                Button(action.title) {
                                    pairing.performRemoteCallAction(action)
                                }
                                .buttonStyle(CallActionButtonStyle(color: callActionColor(action.title)))
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 390, height: 154)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
    }

    private func callActionColor(_ title: String) -> Color {
        switch callActionRole(title) {
        case .answer: return .green
        case .end: return .red
        case .other: return .gray
        }
    }
}

private struct CallActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                color.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum CallActionRole {
    case answer
    case end
    case other
}

private let answerCallActionTitles = ["answer", "accept", "ответить", "принять"]
private let endCallActionTitles = [
    "decline", "reject", "hang up", "hangup", "end call",
    "отклонить", "сбросить", "завершить",
]

// Titles are only a hint: Android sends the semantic call actions first, in its own order.
func callActionRole(_ title: String) -> CallActionRole {
    let normalized = title.lowercased()
    if endCallActionTitles.contains(where: normalized.contains) { return .end }
    if answerCallActionTitles.contains(where: normalized.contains) { return .answer }
    return .other
}

func visibleCallActions(_ actions: [RemoteCallAction], limit: Int) -> [RemoteCallAction] {
    var visible = Array(actions.prefix(limit))
    guard !visible.isEmpty,
          !visible.contains(where: { callActionRole($0.title) == .end }),
          let end = actions.dropFirst(limit).first(where: { callActionRole($0.title) == .end }) else {
        return visible
    }
    visible[visible.count - 1] = end
    return visible
}
