import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var alerts: AlertsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brand) private var c
    @State private var confirmReset = false
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $settings.deviceName)
                        .textInputAutocapitalization(.words)
                        .onSubmit(model.renamed)
                        .accessibilityIdentifier("settings.name")
                } footer: {
                    Text("Your other devices see this name.")
                }
                .listRowBackground(c.s1)

                Section {
                    Toggle("Clipboard", isOn: $settings.clipboard)
                    Toggle("Copy received text", isOn: $settings.copyReceivedText)
                        .disabled(!settings.clipboard)
                    Toggle("Files", isOn: $settings.files)
                    Toggle("Links", isOn: $settings.links)
                    Toggle("Open links right away", isOn: $settings.openLinksRightAway)
                        .disabled(!settings.links)
                    Toggle("Text previews", isOn: $settings.showPreviews)
                } footer: {
                    Text("Received files are in the Files app, under On My \(UIDevice.current.localizedModel) › Bridgey.")
                }
                .listRowBackground(c.s1)

                Section {
                    Toggle("Phone notifications", isOn: $settings.notifications)
                        .accessibilityIdentifier("settings.notifications")
                    Toggle("Codes from messages", isOn: $settings.codesFromMessages)
                        .disabled(!settings.notifications)
                    Toggle("Also read codes in email", isOn: $settings.codesFromEmail)
                        .disabled(!settings.notifications || !settings.codesFromMessages)
                    if settings.notifications, settings.codesFromMessages {
                        // Android shows code messages only to a linked companion device.
                        ForEach(model.devices.filter { $0.connected && alerts.needsLink($0.id) }) { device in
                            Button("Link this \(UIDevice.current.localizedModel) on \(device.name)") { alerts.link(device.id) }
                                .accessibilityHint("Android hides code messages from Bridgey until you allow it there.")
                                .accessibilityIdentifier("settings.codesLink")
                        }
                    }
                    Toggle("Text messages", isOn: $settings.textMessages)
                        .accessibilityIdentifier("settings.textMessages")
                    Toggle("Keep conversations", isOn: $settings.keepConversations)
                        .disabled(!settings.textMessages)
                } footer: {
                    Text("From your Android phone, while Bridgey is open. Codes are found on this \(UIDevice.current.localizedModel) and never leave it.")
                }
                .listRowBackground(c.s1)

                Section {
                    Toggle("Screens", isOn: $settings.screens)
                        .accessibilityIdentifier("settings.screens")
                    Toggle("Battery", isOn: $settings.battery)
                    Toggle("Find device", isOn: $settings.findDevice)
                    Toggle(isOn: $settings.connectAway) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect away from home")
                            Text(settings.connectAway ? alerts.connectText : String(localized: "Off. Only devices on this Wi-Fi connect."))
                                .font(.footnote)
                                .foregroundStyle(c.on2)
                                .accessibilityIdentifier("settings.connectStatus")
                        }
                    }
                } footer: {
                    Text("Screens shows an Android phone or a Mac here, and controls it when that device allows.")
                }
                .listRowBackground(c.s1)

                Section("Devices") {
                    ForEach(model.devices) { device in
                        NavigationLink {
                            DeviceSettingsView(deviceID: device.id, closes: false)
                        } label: {
                            HStack(spacing: 12) {
                                DeviceRingView(state: device.ring, platform: device.platform, size: 32)
                                Text(device.name)
                                Spacer()
                                Text(device.connected ? "Connected" : "Not connected").font(.footnote).foregroundStyle(c.on2)
                            }
                        }
                    }
                    Button { pairing = true } label: { Label("Pair a device", systemImage: "plus") }
                }
                .listRowBackground(c.s1)

                Section {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Reduce motion", isOn: $settings.reduceMotion)
                } footer: {
                    Text("iOS’s own Reduce Motion always applies.")
                }
                .listRowBackground(c.s1)

                Section {
                    LabeledContent("Local Network") {
                        Text(localNetworkText).foregroundStyle(model.localNetwork == .denied ? c.warn : c.on2)
                    }
                    if model.localNetwork == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                .listRowBackground(c.s1)

                Section {
                    NavigationLink("About") { AboutView() }
                        .accessibilityIdentifier("settings.about")
                }
                .listRowBackground(c.s1)

                Section {
                    Button("Forget all devices", role: .destructive) { confirmReset = true }
                        .disabled(model.devices.isEmpty)
                }
                .listRowBackground(c.s1)
            }
            .scrollContentBackground(.hidden)
            .background(c.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.renamed()
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.done")
                }
            }
            .confirmationDialog("Forget all devices?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Forget all", role: .destructive) {
                    for device in model.devices { model.forget(device) }
                    model.forgetFeatureData()
                }
            } message: {
                Text("You’ll need to pair them again.")
            }
            .sheet(isPresented: $pairing) { PairSheet() }
        }
        .onChange(of: settings.clipboard) { model.applyDefaults() }
        .onChange(of: settings.files) { model.applyDefaults() }
        .onChange(of: settings.links) { model.applyDefaults() }
        .onChange(of: settings.openLinksRightAway) { model.applyDefaults() }
        .onChange(of: settings.notifications) { model.applyDefaults() }
        .onChange(of: settings.codesFromMessages) { model.applyDefaults() }
        .onChange(of: settings.codesFromEmail) { model.applyDefaults() }
        .onChange(of: settings.textMessages) { model.applyDefaults() }
        .onChange(of: settings.keepConversations) { model.applyDefaults() }
        .onChange(of: settings.screens) { model.applyDefaults() }
        .onChange(of: settings.battery) { model.applyDefaults() }
        .onChange(of: settings.findDevice) { model.applyDefaults() }
        .onChange(of: settings.connectAway) { model.applyDefaults() }
    }

    private var localNetworkText: String {
        switch model.localNetwork {
        case .browsing: String(localized: "Allowed")
        case .denied: String(localized: "Off")
        case .failed: String(localized: "Not working")
        case .idle: model.running ? String(localized: "Checking…") : String(localized: "Not asked yet")
        }
    }
}

/// One paired device: its switches on this end, a ping, and Forget.
struct DeviceSettingsView: View {
    let deviceID: String
    let closes: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brand) private var c
    @State private var confirmForget = false

    var body: some View {
        Group {
            if let device = model.devices.first(where: { $0.id == deviceID }) {
                form(device)
            } else {
                ContentUnavailableView("Device forgotten", systemImage: "iphone.slash")
            }
        }
        .background(c.bg.ignoresSafeArea())
        .toolbar {
            if closes {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func form(_ device: DeviceItem) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    DeviceRingView(state: device.ring, platform: device.platform, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(BrandFont.heading(20, relativeTo: .title3)).foregroundStyle(c.on)
                        Text(device.connected ? "Connected" : "Not connected").font(.subheadline).foregroundStyle(device.connected ? c.tgi : c.on2)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(c.s1)
            Section {
                toggle("Clipboard", key: "clipboard", device)
                toggle("Files", key: "files", device)
                toggle("Links", key: "links", device)
                toggle("Battery", key: "battery", device)
                toggle("Find device", key: "find_device", device)
                if device.isPhone {
                    toggle("Phone notifications", key: "notifications", device)
                    toggle("Text messages", key: "sms_draft1", device)
                }
                if device.screenArea != nil {
                    Toggle("Screen", isOn: Binding(get: { settings.screens && !settings.screensOff.contains(device.id) },
                                                   set: { model.setScreen(device, on: $0) }))
                        .disabled(!settings.screens)
                }
            } footer: {
                Text("Turned off here, \(device.name) can’t send you that, and you can’t send it there.")
            }
            .listRowBackground(c.s1)
            if device.pingReady {
                Section {
                    Button("Ping \(device.name)") { model.ping(device) }
                }
                .listRowBackground(c.s1)
            }
            Section {
                Button("Forget \(device.name)", role: .destructive) { confirmForget = true }
            }
            .listRowBackground(c.s1)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Forget \(device.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                model.forget(device)
                dismiss()
            }
        } message: {
            Text("You’ll need to pair again to use it.")
        }
    }

    private func toggle(_ title: LocalizedStringKey, key: String, _ device: DeviceItem) -> some View {
        Toggle(title, isOn: Binding(get: { device.local[key] ?? false }, set: { model.setFeature(device, key: key, on: $0) }))
    }
}

struct AboutView: View {
    @Environment(\.brand) private var c

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AuroraMark(size: 72)
                    Text(Edition.displayName).font(BrandFont.heading(22, relativeTo: .title2)).foregroundStyle(c.on)
                    Text(Versions.shortLabel).font(.body.weight(.semibold)).foregroundStyle(c.on)
                        .accessibilityIdentifier("about.version")
                    Text(Versions.fullLabel).font(.footnote).foregroundStyle(c.on2).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)

            Section("On \(UIDevice.current.localizedModel)") {
                limit("bolt.horizontal", "Bridgey connects while it’s open. iOS pauses it soon after you leave, and it reconnects when you come back.")
                limit("doc.on.clipboard", "iOS lets apps read the clipboard only when you paste, so sending it takes a tap on Paste.")
                limit("folder", "Files you receive are in the Files app, under On My \(UIDevice.current.localizedModel) › Bridgey.")
                limit("hand.raised", "Other devices can’t see or control this \(UIDevice.current.localizedModel). iOS doesn’t allow it.")
                limit("bell.badge", "Your phone’s notifications, messages and calls show while Bridgey is open.")
                limit("play.slash", "iOS doesn’t let apps control what other apps play, so your phone can’t control media here.")
            }
            .listRowBackground(c.s1)

            Section {
                Link("roundrobin.in/bridgey", destination: Edition.websiteURL)
                Link("Privacy and security", destination: Edition.privacyURL)
                Link("Source code", destination: Edition.sourceURL)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Edition.credit)
                    Text("Session library \(CoreLibrary.version)")
                }
            }
            .listRowBackground(c.s1)
        }
        .scrollContentBackground(.hidden)
        .background(c.bg.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func limit(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(c.on).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(c.tbi)
        }
    }
}
