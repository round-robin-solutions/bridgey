import SwiftUI

/// Settings → Updates (Round Robin edition).
struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Section("Updates") {
            Picker("Channel", selection: Binding(
                get: { updater.channel },
                set: { updater.setChannel($0) }
            )) {
                ForEach(UpdateChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            Text("\(updater.channel.detail) Switching to a more stable channel never downgrades; Bridgey waits for the next newer build there.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.setAutomaticallyChecks($0) }
            ))
            .disabled(!updater.isAvailable)
            LabeledContent("Version", value: updater.versionDescription)
            LabeledContent("Last checked", value: updater.lastCheck.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "Never")
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
            if !updater.isAvailable {
                Text("Updates work only in the packaged app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings → About, with the attribution required by the edition.
struct AboutSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Section("About") {
            LabeledContent(Edition.displayName, value: updater.versionDescription)
            Text("Built on Bridgey by Semyon Mikhailov. Open source under the MIT License.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Original Bridgey project", destination: Edition.upstreamProjectURL)
        }
    }
}
