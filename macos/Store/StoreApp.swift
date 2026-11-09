import AppKit
import SwiftUI

@main
struct BridgeyStoreApp: App {
    @StateObject private var connection = StoreConnection()
    var body: some Scene {
        WindowGroup("Bridgey by Round Robin") { StoreView(connection: connection).frame(minWidth: 480, minHeight: 520) }
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct StoreView: View {
    @ObservedObject var connection: StoreConnection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bridgey", systemImage: "link.circle.fill").font(.largeTitle.bold())
                    Text("Files, clipboard and phone notifications.").foregroundStyle(.secondary)
                    Text(connection.status).font(.callout).accessibilityLabel("Connection: " + connection.status)
                }
                if let code = connection.verification {
                    GroupBox("Compare the code on both devices") {
                        VStack(spacing: 16) {
                            Text(code).font(.system(size: 36, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Button("Codes match") { connection.confirm() }.buttonStyle(.borderedProminent)
                                Button("Don't match", role: .cancel) { connection.disconnect() }
                            }
                        }.frame(maxWidth: .infinity).padding(16)
                    }.transition(.opacity)
                } else if connection.connected {
                    GroupBox("This phone") {
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Files", isOn: $connection.filesEnabled)
                            Toggle("Clipboard sync", isOn: $connection.clipboardEnabled)
                            Toggle("Phone notifications", isOn: Binding(get: { connection.notificationsEnabled }, set: {
                                if $0 { connection.enableNotifications() } else { connection.notificationsEnabled = false }
                            }))
                            HStack {
                                Button("Send a file...") { connection.files.chooseFile() }.buttonStyle(.borderedProminent).disabled(!connection.filesEnabled)
                                Button("Send clipboard") { connection.sendClipboard() }.disabled(!connection.clipboardEnabled)
                            }
                            Text("Clipboard text syncs while enabled. Phone notifications appear in Notification Centre.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                    }.transition(.opacity)
                    if let text = connection.receivedClipboard {
                        GroupBox("Clipboard from your phone") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(text.prefix(512))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Button("Copy to Mac") { connection.copyReceived() }
                                    Button("Dismiss") { connection.receivedClipboard = nil }
                                }
                            }.padding(12)
                        }.transition(.opacity)
                    }
                    if let offer = connection.pendingFile {
                        GroupBox("Incoming file") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(offer.name).lineLimit(3)
                                Text(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file)).foregroundStyle(.secondary)
                                HStack {
                                    Button("Receive...") { connection.files.accept() }.buttonStyle(.borderedProminent)
                                    Button("Decline") { connection.files.reject() }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }.transition(.opacity)
                    }
                    HStack {
                        Button("Disconnect") { connection.disconnect() }
                        Button("Forget phone", role: .destructive) { connection.forget() }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Allow pairing for 2 minutes") { connection.arm() }.buttonStyle(.borderedProminent)
                        Text("Open Bridgey on your Android phone and allow pairing there, then choose it below. The store edition pairs separately from the direct download.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(connection.peers, id: \.name) { peer in
                            Button { connection.pair(peer) } label: {
                                HStack { Image(systemName: "iphone"); Text(peer.name); Spacer(); Text("Pair").foregroundStyle(.secondary) }
                                    .padding(8).contentShape(Rectangle())
                            }.buttonStyle(.bordered)
                        }
                    }.transition(.opacity)
                }
                if !connection.transferStatus.isEmpty { Text(connection.transferStatus).font(.callout).textSelection(.enabled) }
                Text("Round Robin Solutions").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 640, alignment: .leading)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.connected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.verification)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.pendingFile?.id)
    }
}
