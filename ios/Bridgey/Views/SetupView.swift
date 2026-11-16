import SwiftUI

/// First run: the name other devices see, why Bridgey needs Local Network access (before iOS asks), then pairing.
struct SetupView: View {
    enum Step: Int { case welcome, network, pair }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce
    @State private var step = Step.welcome
    @State private var name = ""

    var body: some View {
        ZStack {
            c.bg.ignoresSafeArea()
            Group {
                switch step {
                case .welcome: welcome
                case .network: network
                case .pair: pair
                }
            }
            .id(step)
            .transition(BrandMotion.forward(reduce: reduce))
        }
        .animation(BrandMotion.animation(BrandMotion.page, reduce: reduce), value: step)
        .onAppear { name = settings.deviceName }
    }

    private var welcome: some View {
        page {
            AuroraMark(size: 88)
            Text("Bridgey").font(BrandFont.heading(40, relativeTo: .largeTitle)).foregroundStyle(c.on)
            Text("Text, links and files between this \(UIDevice.current.localizedModel) and your Mac, PC and Android phone.")
                .font(.title3).foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your other devices see this name").font(.footnote.weight(.semibold)).foregroundStyle(c.on2)
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.s2))
                    .foregroundStyle(c.on)
                    .accessibilityIdentifier("setup.name")
            }
            .padding(.top, 12)
        } actions: {
            Button("Continue") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { settings.deviceName = trimmed }
                step = .network
            }
            .buttonStyle(PillButtonStyle(kind: .gradient, fill: true))
            .accessibilityIdentifier("setup.continue")
        }
    }

    private var network: some View {
        page {
            IconTile(symbol: "wifi", tint: .blue, size: 72)
            Text("Find your devices").font(BrandFont.heading(32, relativeTo: .largeTitle)).foregroundStyle(c.on)
            Text("Bridgey looks for your devices on this Wi-Fi and talks to them directly. Nothing goes through the internet.")
                .font(.body).foregroundStyle(c.on2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Next, iOS asks whether Bridgey may find devices on your local network. Choose Allow.")
                .font(.body).foregroundStyle(c.on)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Continue") {
                // Starting the session is what makes iOS ask.
                model.start()
                step = .pair
            }
            .buttonStyle(PillButtonStyle(kind: .gradient, fill: true))
            .accessibilityIdentifier("setup.allow")
        }
    }

    private var pair: some View {
        VStack(spacing: 0) {
            Text("Pair a device")
                .font(BrandFont.heading(32, relativeTo: .largeTitle))
                .foregroundStyle(c.on)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 32)
            Text("Open Bridgey on the other device, on the same Wi-Fi.")
                .font(.body).foregroundStyle(c.on2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 4)
            PairContent()
            Button(isPaired ? "Done" : "Skip for now") { settings.setupDone = true }
                .buttonStyle(PillButtonStyle(kind: isPaired ? .gradient : .outline, fill: true))
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .accessibilityIdentifier("setup.finish")
        }
        .frame(maxWidth: 560)
        .onAppear { model.pairingScreen(open: true) }
        .onDisappear { model.pairingScreen(open: false) }
    }

    private var isPaired: Bool {
        if case .paired = model.pairing { return true }
        return !model.devices.isEmpty
    }

    private func page<Content: View, Actions: View>(@ViewBuilder _ content: () -> Content, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 72)
                    .frame(maxWidth: .infinity)
            }
            actions()
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }
}
