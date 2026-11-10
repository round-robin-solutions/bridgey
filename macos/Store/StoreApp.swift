import AppKit
import SwiftUI

@main
enum BridgeyStoreLauncher {
    @MainActor
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--self-check") { exit(StoreBoundaryChecks.run() ? 0 : 1) }
        #endif
        if CommandLine.arguments.contains("--snapshot-dark") || CommandLine.arguments.contains("--snapshot-light") {
            renderSnapshot(dark: CommandLine.arguments.contains("--snapshot-dark"))
            return
        }
        if CommandLine.arguments.contains("--sandbox-smoke") {
            let manager = FileManager.default
            let inside = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let outside = URL(fileURLWithPath: "/private/tmp/bridgey-store-deny-" + UUID().uuidString)
            var insideAllowed = false
            var outsideDenied = false
            do { try Data("sandbox proof".utf8).write(to: inside); insideAllowed = true; try manager.removeItem(at: inside) } catch {}
            do { try Data("sandbox proof".utf8).write(to: outside); try? manager.removeItem(at: outside) } catch { outsideDenied = true }
            let container = NSHomeDirectory().contains("/Containers/" + StorePolicy.identifier + "/Data")
            print("{\"container\":\(container),\"containerWrite\":\(insideAllowed),\"outsideWriteDenied\":\(outsideDenied)}")
            exit(container && insideAllowed && outsideDenied ? 0 : 1)
        }
        BridgeyStoreApp.main()
    }
    @MainActor
    private static func renderSnapshot(dark: Bool) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let connection = StoreConnection(startNetworking: false)
        let view = NSHostingView(rootView: StoreView(connection: connection).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApplication.shared.appearance
        view.appearance = window.appearance
        window.contentView = view
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            FileHandle.standardOutput.write(png)
            exit(0)
        }
        RunLoop.main.run()
    }
}

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
                                Button("Codes match") { connection.confirm() }.buttonStyle(StorePrimaryButtonStyle())
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
                                Button("Send a file...") { connection.files.chooseFile() }.buttonStyle(StorePrimaryButtonStyle()).disabled(!connection.filesReady)
                                Button("Send clipboard") { connection.sendClipboard() }.disabled(!connection.clipboardReady)
                            }
                            Text("Enable the same features on your phone. Clipboard text syncs while enabled; phone notifications appear in Notification Centre.")
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
                                    Button("Receive...") { connection.files.accept() }.buttonStyle(StorePrimaryButtonStyle())
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
                        Button("Allow pairing for 2 minutes") { connection.arm() }.buttonStyle(StorePrimaryButtonStyle())
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
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.connected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.verification)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: connection.pendingFile?.id)
    }
}

private struct StorePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .foregroundStyle(Color(red: 5.0 / 255, green: 11.0 / 255, blue: 24.0 / 255))
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(Color(red: 84.0 / 255, green: 199.0 / 255, blue: 245.0 / 255), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
