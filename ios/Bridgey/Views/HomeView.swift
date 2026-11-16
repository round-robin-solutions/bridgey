import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The device home in the Stream style: paired devices on top, live cards (requests, links, files on the way),
/// the activity stream, and the send bar. On iPad and other wide windows the devices move into a sidebar.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.brand) private var c
    @State private var sheet: HomeSheet?
    @State private var preview: URL?
    @State private var picking = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    DeviceSidebar(sheet: $sheet)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
                } detail: {
                    NavigationStack { stream(showDevices: false) }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack { stream(showDevices: true) }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .pair: PairSheet()
            case .settings: SettingsView()
            case let .device(id): NavigationStack { DeviceSettingsView(deviceID: id, closes: true) }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result, let device = model.target { model.sendFiles(urls, to: device) }
        }
        .quickLookPreview($preview)
    }

    private func stream(showDevices: Bool) -> some View {
        VStack(spacing: 0) {
            HomeHeader(showPair: showDevices, sheet: $sheet)
            StreamPane(showDevices: showDevices, sheet: $sheet, preview: $preview)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.devices.isEmpty {
                SendBar(attach: { picking = true })
            }
        }
        .background(c.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The brand row, as on the Mac's panel: the mark, the name, Pair and Settings. It stays put while the stream
/// scrolls.
private struct HomeHeader: View {
    let showPair: Bool
    @Binding var sheet: HomeSheet?
    @Environment(\.brand) private var c

    var body: some View {
        HStack(spacing: 10) {
            AuroraMark(size: 30)
            Text("Bridgey")
                .font(BrandFont.heading(24, relativeTo: .title2))
                .foregroundStyle(c.on)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if showPair {
                button("plus", label: "Pair a device", id: "toolbar.pair") { sheet = .pair }
            }
            button("gearshape", label: "Settings", id: "toolbar.settings") { sheet = .settings }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(c.bg)
    }

    private func button(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(c.on2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(c.s2))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

enum HomeSheet: Identifiable, Equatable {
    case pair, settings
    case device(String)

    var id: String {
        switch self {
        case .pair: "pair"
        case .settings: "settings"
        case let .device(id): "device-\(id)"
        }
    }
}

/// Everything under the toolbar: devices (on iPhone), banners and cards, then the stream.
private struct StreamPane: View {
    let showDevices: Bool
    @Binding var sheet: HomeSheet?
    @Binding var preview: URL?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if showDevices, !model.devices.isEmpty {
                    DeviceStrip(sheet: $sheet)
                        .padding(.horizontal, -16)
                }
                if model.devices.isEmpty {
                    EmptyDevicesCard { sheet = .pair }
                }
                if model.localNetwork == .denied {
                    LocalNetworkBanner()
                }
                if let request = model.pairingRequest {
                    PairingRequestCard(request: request)
                        .transition(BrandMotion.arrival(reduce: reduce))
                }
                if model.pairing != .idle, sheet != .pair {
                    CardShell { PairingStatusView() }
                        .transition(BrandMotion.arrival(reduce: reduce))
                }
                ForEach(model.links) { card in
                    LinkCardView(card: card)
                        .transition(BrandMotion.arrival(reduce: reduce))
                }
                ForEach(model.transfers) { transfer in
                    TransferCard(transfer: transfer)
                        .transition(BrandMotion.arrival(reduce: reduce))
                }
                if model.activity.isEmpty, !model.devices.isEmpty {
                    Text(model.target?.connected == true
                         ? "Things you send and receive appear here."
                         : "Open Bridgey on your other devices to connect.")
                        .font(.subheadline)
                        .foregroundStyle(c.on2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 32)
                }
                ForEach(model.activity) { item in
                    ActivityRow(item: item, preview: $preview)
                        .transition(BrandMotion.arrival(reduce: reduce))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: model.activity.map(\.id))
            .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: model.links.map(\.id))
            .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: model.transfers.map(\.id))
            .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: model.pairingRequest)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .top) { NoticeBanner() }
    }
}

// MARK: - Devices

/// iPhone: the paired devices as chips that scroll sideways. Tapping a connected one sends to it.
private struct DeviceStrip: View {
    @Binding var sheet: HomeSheet?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.devices) { device in
                    DeviceChip(device: device, selected: device.id == model.target?.id, sheet: $sheet)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct DeviceChip: View {
    let device: DeviceItem
    let selected: Bool
    @Binding var sheet: HomeSheet?
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        Button {
            model.targetID = device.id
        } label: {
            HStack(spacing: 10) {
                DeviceRingView(state: device.ring, platform: device.platform, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.subheadline.weight(.semibold)).foregroundStyle(c.on).lineLimit(1)
                    Text(device.connected ? "Connected" : "Not connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(device.connected ? c.tgi : c.on2)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected && device.connected ? c.tb : c.s2))
            .overlay(Capsule().strokeBorder(selected && device.connected ? c.pri.opacity(0.5) : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: device.connected)
        .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: selected)
        .contextMenu { DeviceMenu(device: device, sheet: $sheet) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.name)
        .accessibilityValue(device.connected ? (selected ? "Connected, sending here" : "Connected") : "Not connected")
        .accessibilityHint("Sends go to this device. Touch and hold for more.")
        .accessibilityIdentifier("device.chip")
    }
}

/// The same actions from a chip's context menu and the iPad sidebar.
struct DeviceMenu: View {
    let device: DeviceItem
    @Binding var sheet: HomeSheet?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if device.connected {
            Button { model.targetID = device.id } label: { Label("Send here", systemImage: "arrow.up.circle") }
        }
        if device.pingReady {
            Button { model.ping(device) } label: { Label("Ping", systemImage: "bell") }
        }
        Button { sheet = .device(device.id) } label: { Label("Device settings", systemImage: "slider.horizontal.3") }
    }
}

/// iPad: devices in a sidebar.
private struct DeviceSidebar: View {
    @Binding var sheet: HomeSheet?
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c

    var body: some View {
        List(selection: Binding(get: { model.target?.id }, set: { model.targetID = $0 })) {
            ForEach(model.devices) { device in
                HStack(spacing: 12) {
                    DeviceRingView(state: device.ring, platform: device.platform, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.body.weight(.semibold)).foregroundStyle(c.on)
                        Text(device.connected ? "Connected" : "Not connected")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(device.connected ? c.tgi : c.on2)
                    }
                }
                .padding(.vertical, 4)
                .tag(device.id)
                .contextMenu { DeviceMenu(device: device, sheet: $sheet) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("device.chip")
            }
            Button { sheet = .pair } label: { Label("Pair a device", systemImage: "plus.circle") }
                .accessibilityIdentifier("toolbar.pair")
        }
        .scrollContentBackground(.hidden)
        .background(c.s1)
        .navigationTitle("Devices")
    }
}

private struct EmptyDevicesCard: View {
    let pair: () -> Void
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            HStack(spacing: 12) {
                IconTile(symbol: "dot.radiowaves.left.and.right", tint: .blue, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No devices yet").font(BrandFont.heading(19, relativeTo: .headline)).foregroundStyle(c.on)
                    Text("Open Bridgey on your Mac, PC or Android phone, on the same Wi-Fi.")
                        .font(.subheadline).foregroundStyle(c.on2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Pair a device", action: pair)
                .buttonStyle(PillButtonStyle(kind: .gradient, fill: true))
                .accessibilityIdentifier("home.pair")
        }
    }
}

// MARK: - Banners and cards

private struct LocalNetworkBanner: View {
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "wifi.exclamationmark", tint: .purple)
                Text("Local Network is off for Bridgey, so it can’t find or reach your devices.")
                    .font(.subheadline).foregroundStyle(c.on)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(PillButtonStyle(kind: .tonal))
        }
    }
}

private struct PairingRequestCard: View {
    let request: PairingRequest
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            HStack(spacing: 12) {
                IconTile(symbol: "link.badge.plus", tint: .purple)
                Text("\(request.name) wants to pair").font(.body.weight(.semibold)).foregroundStyle(c.on)
            }
            HStack(spacing: 8) {
                Button("Allow") { model.allowPairingRequest() }.buttonStyle(PillButtonStyle(kind: .gradient))
                Button("Not now") { model.dismissPairingRequest() }.buttonStyle(PillButtonStyle(kind: .outline))
            }
        }
    }
}

private struct LinkCardView: View {
    let card: LinkCard
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "link", tint: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link from \(card.deviceName)").font(.subheadline.weight(.semibold)).foregroundStyle(c.on)
                    Text(card.url.absoluteString).font(.footnote).foregroundStyle(c.on2).lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button { model.dismiss(card) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(c.on2).frame(width: 32, height: 32)
                }
                .accessibilityLabel("Dismiss")
            }
            HStack(spacing: 8) {
                Button("Open") { model.open(card) }.buttonStyle(PillButtonStyle(kind: .gradient))
                Button("Copy") { model.copy(card) }.buttonStyle(PillButtonStyle(kind: .tonal))
            }
        }
        .accessibilityIdentifier("card.link")
    }
}

private struct TransferCard: View {
    let transfer: TransferItem
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c

    var body: some View {
        CardShell {
            HStack(spacing: 12) {
                IconTile(symbol: transfer.incoming ? "arrow.down.doc" : "arrow.up.doc", tint: transfer.incoming ? .green : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.name).font(.subheadline.weight(.semibold)).foregroundStyle(c.on).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.caption).foregroundStyle(c.on2).monospacedDigit()
                }
                Spacer(minLength: 0)
                Button { model.cancel(transfer) } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(c.on2)
                }
                .accessibilityLabel("Cancel")
            }
            ProgressView(value: transfer.fraction)
                .tint(c.pri)
                .accessibilityLabel(transfer.incoming ? "Receiving \(transfer.name)" : "Sending \(transfer.name)")
        }
    }

    private var detail: String {
        let direction = transfer.incoming ? String(localized: "From \(transfer.deviceName)") : String(localized: "To \(transfer.deviceName)")
        guard transfer.total > 0 else { return direction }
        return "\(direction) · \(ByteCountFormatter.file(transfer.bytes)) of \(ByteCountFormatter.file(transfer.total))"
    }
}

/// A short message about what just went wrong, at the top, gone after a few seconds.
private struct NoticeBanner: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        ZStack {
            if let notice = model.notice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(c.on)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(c.s3).shadow(color: .black.opacity(c.isDark ? 0.4 : 0.12), radius: 12, y: 4))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .onTapGesture { model.notice = nil }
                    .transition(reduce ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        model.notice = nil
                    }
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear { UIAccessibility.post(notification: .announcement, argument: notice) }
            }
        }
        .animation(BrandMotion.animation(BrandMotion.pop, reduce: reduce), value: model.notice)
    }
}

// MARK: - Stream

private struct ActivityRow: View {
    let item: ActivityItem
    @Binding var preview: URL?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.brand) private var c

    var body: some View {
        Button(action: primary) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: item.direction == .received ? .green : .blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(c.on)
                        .lineLimit(item.kind == .text ? 3 : 2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(subtitle)
                        Text(item.date, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(c.on2)
                    if let status {
                        Text(status).font(.caption.weight(.medium)).foregroundStyle(item.outcome == .failed ? c.warn : c.on2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.s1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityValue(status ?? "")
        .accessibilityHint(hint)
        .accessibilityIdentifier("activity.row")
    }

    private var symbol: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .file: "doc"
        }
    }

    private var title: String {
        switch item.kind {
        case .text where !settings.showPreviews:
            return item.direction == .received ? String(localized: "Text") : String(localized: "Text sent")
        case .text:
            return item.value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .link, .file:
            return item.value
        }
    }

    private var subtitle: String {
        item.direction == .received ? String(localized: "From \(item.deviceName) ·") : String(localized: "To \(item.deviceName) ·")
    }

    private var status: String? {
        switch item.outcome {
        case .sending: String(localized: "Sending…")
        case .failed: item.detail ?? String(localized: "Not delivered")
        case .delivered: item.direction == .sent ? String(localized: "Delivered") : nil
        }
    }

    private var hint: String {
        switch item.kind {
        case .text: String(localized: "Copies the text.")
        case .link: String(localized: "Opens the link.")
        case .file: item.direction == .received ? String(localized: "Shows the file.") : ""
        }
    }

    private func primary() {
        switch item.kind {
        case .text:
            model.copy(item)
            model.notice = String(localized: "Copied")
        case .link:
            if let url = URL(string: item.value) { UIApplication.shared.open(url) }
        case .file:
            if let url = model.fileURL(item) { preview = url }
        }
    }

    @ViewBuilder private var menu: some View {
        if item.kind != .file {
            Button { model.copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        if item.kind == .link, let url = URL(string: item.value) {
            Button { UIApplication.shared.open(url) } label: { Label("Open", systemImage: "safari") }
        }
        if let url = model.fileURL(item) {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            Button {
                if let files = URL(string: "shareddocuments://\(SharedStorage.receivedFiles.path)") { UIApplication.shared.open(files) }
            } label: { Label("Show in Files", systemImage: "folder") }
        }
        if item.kind == .text {
            ShareLink(item: item.value) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

// MARK: - Send bar

/// Text or a link to the chosen device, the clipboard with one tap on Paste (iOS asks no question for a paste the
/// person taps), and files from the Files picker.
private struct SendBar: View {
    let attach: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.brand) private var c
    @FocusState private var focused: Bool

    var body: some View {
        let target = model.target
        VStack(alignment: .leading, spacing: 8) {
            if model.devices.count > 1, let target {
                Menu {
                    ForEach(model.devices.filter(\.connected)) { device in
                        Button(device.name) { model.targetID = device.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("To \(target.name)")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(c.on2)
                }
                .accessibilityLabel("Send to \(target.name)")
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: attach) {
                    Image(systemName: "paperclip").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .foregroundStyle(c.tbi)
                .background(Circle().fill(c.tb))
                .disabled(target?.filesReady != true)
                .accessibilityLabel("Send files")
                .accessibilityIdentifier("send.attach")
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    guard let device = model.target else { return }
                    Task { @MainActor in model.sendText(text, to: device) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .tint(c.tbi)
                .disabled(target?.clipboardReady != true)
                .accessibilityIdentifier("send.paste")
                TextField("Text or a link", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c.s2))
                    .foregroundStyle(c.on)
                    .submitLabel(.send)
                    .onSubmit(model.sendDraft)
                    .accessibilityIdentifier("send.field")
                Button(action: model.sendDraft) {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(BrandPalette.midnight).frame(width: 44, height: 44)
                        .background(Circle().fill(BrandPalette.aurora))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target?.clipboardReady != true)
                .opacity(model.draft.isEmpty ? 0.5 : 1)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send.button")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(c.bg.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(c.olv).frame(height: 1) }
    }
}
