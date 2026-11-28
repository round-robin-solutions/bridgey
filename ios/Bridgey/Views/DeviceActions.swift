import SwiftUI

/// What the chosen device offers beyond sending: its screen, the phone's messages and files, and ringing it. Only
/// what works right now is shown; the phone or Mac decides the rest.
struct DeviceActions: View {
    let device: DeviceItem
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var screen: ScreenModel
    @EnvironmentObject private var alerts: AlertsModel

    var body: some View {
        if !actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(actions, id: \.id) { action in
                        Button(action: action.run) {
                            Label(action.title, systemImage: action.symbol)
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(PillButtonStyle(kind: .tonal))
                        .accessibilityIdentifier("action.\(action.id)")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private struct Action {
        let id: String
        let title: LocalizedStringKey
        let symbol: String
        let run: () -> Void
    }

    private var actions: [Action] {
        guard device.connected else { return [] }
        var list: [Action] = []
        if settings.screens, device.screenReady {
            list.append(Action(id: "screen", title: "Screen", symbol: device.isMac ? "macbook" : "iphone.gen3") { screen.open(device) })
        }
        if device.messagesOffered {
            list.append(Action(id: "messages", title: "Messages", symbol: "message") { model.path = [.messages(deviceID: device.id)] })
        }
        if device.phoneFilesReady {
            list.append(Action(id: "files", title: "Files", symbol: "folder") { model.path = [.phoneFiles(deviceID: device.id)] })
        }
        if device.findReady {
            list.append(Action(id: "ring", title: "Ring", symbol: "bell.and.waves.left.and.right") { alerts.ring(device) })
        }
        return list
    }
}
