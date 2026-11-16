import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share > Bridgey in any app: send text, a link or files to a paired device.
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        self.model = model
        let host = UIHostingController(rootView: ShareRoot(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model?.stop()
    }
}

/// What was shared, read from the extension's input items.
enum SharedItem: Equatable {
    case text(String)
    case link(URL)
    case file(URL, name: String)
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case connecting
        case sending(done: Int, of: Int)
        case sent
        /// Not reachable: offer to keep it until Bridgey next connects to the device.
        case unreachable
        case failed(String)
    }

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let platform: String?
    }

    @Published var items: [SharedItem] = []
    @Published var devices: [Device] = []
    @Published var selected: String?
    @Published var phase = Phase.loading

    private weak var context: NSExtensionContext?
    private var client: BridgeyCore?
    private var discovery: BonjourDiscovery?
    private var features: [String: [String: Bool]] = [:]
    private var connected: Set<String> = []
    private var pending: Set<UInt64> = []
    private var failures = 0
    private var timeout: Task<Void, Never>?
    private let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Shared-\(UUID().uuidString)", isDirectory: true)

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func start() {
        Task { await load() }
        let defaults = SharedStorage.defaults
        let name = defaults.string(forKey: "deviceName").flatMap { $0.isEmpty ? nil : $0 } ?? UIDevice.current.name
        var options = CoreOptions(deviceName: name)
        options.listen = false
        options.manualConnect = true
        let relay = ShareRelay(self)
        do {
            let client = try BridgeyCore.start(options, store: KeychainStore()) { event in relay.post(event) }
            self.client = client
            let snapshot = try client.snapshot()
            devices = snapshot.devices.map { Device(id: $0.deviceId, name: $0.name, platform: $0.platform) }
            let last = defaults.string(forKey: "lastDeviceID")
            selected = devices.first { $0.id == last }?.id ?? devices.first?.id
            let discovery = BonjourDiscovery(ownDeviceID: client.deviceID)
            discovery.onFound = { [weak self] d in
                try? self?.client?.addDiscovered(deviceID: d.deviceID, name: d.name, platform: d.platform, host: d.host, port: d.port)
            }
            discovery.start()
            self.discovery = discovery
            // Connecting starts at once, so Send is quick.
            if let selected { try? client.connect(selected) }
        } catch {
            phase = .failed(String(localized: "Open Bridgey once to set it up, then try again."))
        }
    }

    func stop() {
        timeout?.cancel()
        discovery?.stop()
        client?.stop()
        client = nil
        try? FileManager.default.removeItem(at: temporary)
    }

    func select(_ id: String) {
        selected = id
        try? client?.connect(id)
    }

    private func load() async {
        var found: [SharedItem] = []
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        for item in context?.inputItems.compactMap({ $0 as? NSExtensionItem }) ?? [] {
            for provider in item.attachments ?? [] {
                if let shared = await read(provider) { found.append(shared) }
            }
        }
        items = found
        if phase == .loading { phase = found.isEmpty ? .failed(String(localized: "There’s nothing here Bridgey can send.")) : .ready }
    }

    private func read(_ provider: NSItemProvider) async -> SharedItem? {
        // A web page or a link: the URL. A file URL is a file.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, url.scheme?.hasPrefix("http") == true {
                return .link(url)
            }
        }
        for type in [UTType.fileURL, .image, .movie, .pdf, .data] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let file = await copyFile(provider, type: type) { return file }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String, !text.isEmpty {
            return .text(text)
        }
        return nil
    }

    private func copyFile(_ provider: NSItemProvider, type: UTType) async -> SharedItem? {
        let folder = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let name = provider.suggestedName.map { name in
                    url.pathExtension.isEmpty || name.hasSuffix(".\(url.pathExtension)") ? name : "\(name).\(url.pathExtension)"
                } ?? url.lastPathComponent
                let destination = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: .file(destination, name: name))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    var summary: String {
        let files = items.filter { if case .file = $0 { return true } else { return false } }.count
        if files > 0 { return files == 1 ? String(localized: "1 file") : String(localized: "\(files) files") }
        switch items.first {
        case let .link(url)?: return url.host() ?? url.absoluteString
        case let .text(text)?: return String(text.prefix(140))
        default: return ""
        }
    }

    func send() {
        guard let id = selected, let client else { return }
        SharedStorage.defaults.set(id, forKey: "lastDeviceID")
        if ready(id) { return sendNow(to: id) }
        phase = .connecting
        try? client.connect(id)
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.phase == .connecting else { return }
            self.phase = .unreachable
        }
    }

    /// Connected and the device's switches known.
    private func ready(_ id: String) -> Bool { connected.contains(id) && features[id] != nil }

    private func on(_ id: String, _ key: String) -> Bool { features[id]?[key] == true }

    private func sendNow(to id: String) {
        guard let client else { return }
        timeout?.cancel()
        pending.removeAll()
        failures = 0
        for item in items {
            do {
                switch item {
                case let .text(text): pending.insert(try client.sendClipboard(id, text: text))
                case let .link(url):
                    pending.insert(on(id, "links") ? try client.sendLink(id, url: url.absoluteString) : try client.sendClipboard(id, text: url.absoluteString))
                case let .file(url, name): pending.insert(try client.sendFile(id, url: url, name: name, mime: nil))
                }
            } catch {
                phase = .failed((error as? CoreError)?.code == CoreError.featureOff
                    ? String(localized: "That’s turned off on \(name(id)). Turn it on in Bridgey there.")
                    : error.localizedDescription)
                return
            }
        }
        phase = .sending(done: 0, of: pending.count)
    }

    /// Keeps what was shared until Bridgey on this phone next reaches the device.
    func keepForLater() {
        guard let id = selected else { return }
        let deviceName = name(id)
        for item in items {
            switch item {
            case let .text(text): try? Outbox.add(OutboxItem(deviceID: id, deviceName: deviceName, kind: .text, value: text))
            case let .link(url): try? Outbox.add(OutboxItem(deviceID: id, deviceName: deviceName, kind: .link, value: url.absoluteString))
            case let .file(url, name): try? Outbox.add(OutboxItem(deviceID: id, deviceName: deviceName, kind: .file, value: name), file: url)
            }
        }
        finish()
    }

    func name(_ id: String) -> String { devices.first { $0.id == id }?.name ?? String(localized: "the device") }

    func finish() {
        stop()
        context?.completeRequest(returningItems: nil)
    }

    func cancel() {
        stop()
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    func handle(_ e: CoreEvent) {
        switch e.kind {
        case .connected:
            if let id = e.deviceID { connected.insert(id) }
        case .disconnected:
            if let id = e.deviceID { connected.remove(id) }
        case .features:
            guard let id = e.deviceID, let data = e.extra?.data(using: .utf8), let map = try? JSONDecoder().decode([String: Bool].self, from: data) else { break }
            features[id] = map
            if phase == .connecting, id == selected { sendNow(to: id) }
        case .clipboardSent, .linkSent:
            done(e.id, ok: e.status == SendStatus.delivered.rawValue)
        case .fileDone:
            if e.status == 0 { done(e.id, ok: true) }
        case .fileFailed:
            if e.status == 0 { done(e.id, ok: false) }
        default:
            break
        }
    }

    private func done(_ request: UInt64, ok: Bool) {
        guard pending.remove(request) != nil, case let .sending(sent, total) = phase else { return }
        if !ok { failures += 1 }
        phase = .sending(done: sent + 1, of: total)
        guard pending.isEmpty else { return }
        if failures > 0 {
            phase = .failed(String(localized: "\(failures) of \(total) didn’t arrive."))
        } else {
            phase = .sent
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                finish()
            }
        }
    }
}

private final class ShareRelay: @unchecked Sendable {
    private weak var model: ShareModel?

    init(_ model: ShareModel) { self.model = model }

    func post(_ event: CoreEvent) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model?.handle(event) }
        }
    }
}

// MARK: - View

private struct ShareRoot: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        BrandRoot(reduceMotion: SharedStorage.defaults.bool(forKey: "reduceMotion")) {
            ShareView(model: model)
        }
    }
}

private struct ShareView: View {
    @ObservedObject var model: ShareModel
    @Environment(\.brand) private var c
    @Environment(\.brandReduceMotion) private var reduce

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if !model.summary.isEmpty {
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol, tint: .blue, size: 40)
                        Text(model.summary).font(.subheadline).foregroundStyle(c.on).lineLimit(3)
                    }
                }
                if model.devices.isEmpty, model.phase != .loading {
                    Text("Pair a device in Bridgey first.").font(.body).foregroundStyle(c.on2)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.devices) { device in
                                Button { model.select(device.id) } label: {
                                    HStack(spacing: 12) {
                                        DeviceRingView(state: .offline, platform: device.platform, size: 36)
                                        Text(device.name).font(.body.weight(.semibold)).foregroundStyle(c.on)
                                        Spacer()
                                        Image(systemName: model.selected == device.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.selected == device.id ? c.pri : c.on2)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(model.selected == device.id ? c.tb : c.s1))
                                }
                                .buttonStyle(PressScaleStyle())
                                .accessibilityAddTraits(model.selected == device.id ? .isSelected : [])
                            }
                        }
                    }
                }
                status
                Spacer(minLength: 0)
                actions
            }
            .padding(20)
            .background(c.bg.ignoresSafeArea())
            .animation(BrandMotion.animation(BrandMotion.effects, reduce: reduce), value: model.phase)
            .navigationTitle("Send with Bridgey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
            }
        }
    }

    private var symbol: String {
        switch model.items.first {
        case .link?: "link"
        case .file?: "doc"
        default: "text.alignleft"
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .connecting:
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(model.name(model.selected ?? ""))…").font(.subheadline).foregroundStyle(c.on2)
            }
        case let .sending(done, total):
            ProgressView(value: Double(done), total: Double(max(total, 1))).tint(c.pri)
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(c.good)
        case .unreachable:
            Text("Bridgey can’t reach \(model.name(model.selected ?? "")) right now. Send it later and it goes the next time Bridgey connects to it.")
                .font(.subheadline).foregroundStyle(c.on)
        case let .failed(message):
            Text(message).font(.subheadline).foregroundStyle(c.warn)
        case .loading, .ready:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .unreachable:
            VStack(spacing: 8) {
                Button("Send later") { model.keepForLater() }.buttonStyle(PillButtonStyle(kind: .gradient, fill: true))
                Button("Try again") { model.send() }.buttonStyle(PillButtonStyle(kind: .outline, fill: true))
            }
        case .ready, .failed:
            Button("Send") { model.send() }
                .buttonStyle(PillButtonStyle(kind: .gradient, fill: true))
                .disabled(model.selected == nil || model.items.isEmpty)
        default:
            EmptyView()
        }
    }
}
