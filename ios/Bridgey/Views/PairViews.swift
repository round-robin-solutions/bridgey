import SwiftUI

/// Devices on this network to pair with, an address for those that don't show up, and the pairing itself. While
/// it is open, other devices may pair with this one too.
struct PairSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.brand) private var c

    var body: some View {
        NavigationStack {
            PairContent()
                .navigationTitle("Pair a device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("pair.done")
                    }
                }
                .background(c.bg.ignoresSafeArea())
        }
        .onAppear { model.pairingScreen(open: true) }
        .onDisappear { model.pairingScreen(open: false) }
        .presentationDetents([.large])
    }
}

/// The pairing list, shared by the sheet and the last setup step.
struct PairContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @State private var address = ""

    var body: some View {
        List {
            if model.pairing != .idle {
                Section {
                    PairingStatusView()
                        .listRowBackground(c.s2)
                        .transition(BrandMotion.arrival(reduce: reduce))
                }
            }
            Section {
                if model.nearby.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(model.localNetwork == .denied ? "Local Network is off for Bridgey." : "Looking for devices on this Wi-Fi…")
                            .font(.subheadline)
                            .foregroundStyle(c.on2)
                    }
                    .listRowBackground(c.s1)
                }
                ForEach(model.nearby) { device in
                    HStack(spacing: 12) {
                        DeviceRingView(state: .nearby, platform: device.platform, size: 40)
                        Text(device.name).font(.body.weight(.semibold)).foregroundStyle(c.on).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Pair") { model.pair(device) }
                            .buttonStyle(PillButtonStyle(kind: .tonal))
                            .disabled(model.pairing.isActive)
                    }
                    .listRowBackground(c.s1)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pair.nearby")
                }
            } footer: {
                Text("While this is open, your other devices can pair with this \(UIDevice.current.localizedModel) too.")
            }
            Section {
                HStack(spacing: 8) {
                    TextField("IP address", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(pairAddress)
                        .accessibilityIdentifier("pair.address")
                    Button("Pair", action: pairAddress)
                        .buttonStyle(PillButtonStyle(kind: .tonal))
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || model.pairing.isActive)
                        .accessibilityIdentifier("pair.addressButton")
                }
                .listRowBackground(c.s1)
            } footer: {
                Text("For a device that doesn’t appear above. It’s in Bridgey’s settings on that device.")
            }
        }
        .scrollContentBackground(.hidden)
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: model.pairing)
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: model.nearby)
    }

    private func pairAddress() {
        model.pair(address: address)
    }
}

/// Where a pairing is, and the code to compare.
struct PairingStatusView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.pairing {
            case .idle:
                EmptyView()
            case let .dialling(_, name):
                progress(String(localized: "Connecting to \(name)…"))
            case let .waiting(_, name):
                progress(String(localized: "On \(name), open Bridgey and choose Allow pairing."))
                cancelButton
            case let .code(_, name, code):
                codeView(code)
                Text("Check \(name) shows the same code.").font(.subheadline).foregroundStyle(c.on2)
                HStack(spacing: 8) {
                    Button("They match") { model.confirmCode(true) }
                        .buttonStyle(PillButtonStyle(kind: .gradient))
                        .accessibilityIdentifier("pairing.match")
                    Button("They don’t") { model.confirmCode(false) }
                        .buttonStyle(PillButtonStyle(kind: .outline))
                        .accessibilityIdentifier("pairing.mismatch")
                }
            case let .confirming(_, name, code):
                codeView(code)
                progress(String(localized: "Waiting for \(name)…"))
            case let .paired(name):
                Label {
                    Text("Paired with \(name)").font(.body.weight(.semibold)).foregroundStyle(c.on)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(c.good)
                }
                .accessibilityIdentifier("pairing.paired")
                Button("Done") { model.clearPairingResult() }.buttonStyle(PillButtonStyle(kind: .tonal))
            case let .failed(name, reason):
                Text(PairingState.failureText(reason, name: name)).font(.subheadline).foregroundStyle(c.on)
                Button("OK") { model.clearPairingResult() }.buttonStyle(PillButtonStyle(kind: .tonal))
            }
        }
        .padding(.vertical, 4)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(c.on).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { model.cancelPairing() }.buttonStyle(PillButtonStyle(kind: .outline))
    }

    private func codeView(_ code: String) -> some View {
        // "744 419": two groups of three, read out digit by digit.
        let spaced = code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
        return Text(spaced)
            .font(BrandFont.heading(40, relativeTo: .largeTitle))
            .monospacedDigit()
            .foregroundStyle(c.on)
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
            .accessibilityIdentifier("pairing.code")
    }
}
