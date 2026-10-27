import AppKit
import Combine
import SwiftUI

// Share and Services (Files 2.0 quick win): three ways to send to the phone from other apps, all ending in
// the same small "Send to" chooser (device tiles, Tray, optimisation chip, free space), then the usual
// send path (SendDispatcher):
// - the Share extension (ShareExtension/, built and signed by build-app.sh) puts what was shared on the
//   private pasteboard `ShareHandoff.pasteboardName` and opens `ShareHandoff.scheme://share`;
// - the Services menu item "Send to Phone with Bridgey" (Info.plist NSServices, `sendToPhoneWithBridgey`);
// - an NSSharingService named Bridgey for share pickers this app shows (`BridgeySharing`).

enum ShareHandoff {
    /// Must match ShareExtension/ShareViewController.swift.
    static let pasteboardName = NSPasteboard.Name("in.roundrobin.bridgey.share")
    static let scheme = "in.roundrobin.bridgey.send"

    static func isHandoff(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme && url.host == "share" }

    /// Reads and clears what the extension left. Empty when nothing is waiting.
    static func take(from pasteboard: NSPasteboard = NSPasteboard(name: pasteboardName)) -> [DropPayload] {
        let payloads = DropPayload.from(pasteboard: pasteboard)
        pasteboard.clearContents()
        return payloads
    }
}

/// The app delegate: tel: links go to the call router as before, the Share extension's hand-off to the
/// chooser. Wraps PhoneURLHandler so that file stays as it is.
@MainActor
final class BridgeyAppDelegate: NSObject, NSApplicationDelegate {
    private let phone = PhoneURLHandler()
    private var pendingShares = 0
    private var onShare: (() -> Void)?

    func configure(onCall: @escaping (String) -> Void) { phone.configure(onCall: onCall) }

    /// Shares that arrived before the menu bar was ready are delivered once it is.
    func configure(onShare: @escaping () -> Void) {
        self.onShare = onShare
        for _ in 0..<pendingShares { onShare() }
        pendingShares = 0
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let shares = urls.filter(ShareHandoff.isHandoff)
        let others = urls.filter { !ShareHandoff.isHandoff($0) }
        if !others.isEmpty { phone.application(application, open: others) }
        guard !shares.isEmpty else { return }
        if let onShare { onShare() } else { pendingShares += 1 }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // New or changed Services entries show without logging out.
        NSUpdateDynamicServices()
    }
}

/// NSApp.servicesProvider: the existing "Call with Bridgey RR" and the new "Send to Phone with Bridgey".
/// AppKit calls services on the main thread.
@MainActor
final class BridgeyServiceProvider: NSObject {
    private let calls: CallServiceProvider
    private let onSend: ([DropPayload]) -> Void

    init(calls: CallServiceProvider, onSend: @escaping ([DropPayload]) -> Void) {
        self.calls = calls
        self.onSend = onSend
    }

    @objc func callWithBridgey(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        calls.callWithBridgey(pasteboard, userData: userData, error: error)
    }

    @objc func sendToPhoneWithBridgey(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let payloads = DropPayload.from(pasteboard: pasteboard)
        guard !payloads.isEmpty else {
            error.pointee = L10n.text("share.nothing", fallback: "There is nothing here Bridgey can send.") as NSString
            return
        }
        DispatchQueue.main.async { self.onSend(payloads) }
    }
}

/// A share picker entry for this app's own pickers (none yet; the Phone files and History windows can
/// add it through `BridgeySharing.pickerDelegate`).
@MainActor
enum BridgeySharing {
    /// Adds Bridgey first in a picker's list; `items` are the picker's items.
    final class PickerDelegate: NSObject, NSSharingServicePickerDelegate {
        private let items: [Any]
        private let present: ([DropPayload]) -> Void

        init(items: [Any], present: @escaping ([DropPayload]) -> Void) {
            self.items = items
            self.present = present
        }

        func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                                  proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
            let payloads = BridgeySharing.payloads(self.items)
            guard !payloads.isEmpty else { return proposed }
            let image = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil) ?? NSImage()
            let bridgey = NSSharingService(title: L10n.text("share.service", fallback: "Bridgey"), image: image, alternateImage: nil) { [present] in
                present(payloads)
            }
            return [bridgey] + proposed
        }
    }

    /// File URLs, web links, strings and images as drop payloads.
    nonisolated static func payloads(_ items: [Any]) -> [DropPayload] {
        var files: [URL] = []
        var rest: [DropPayload] = []
        for item in items {
            if let url = item as? URL {
                if url.isFileURL { files.append(url) } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { rest.append(.link(url)) }
            } else if let text = item as? String, !text.isEmpty {
                rest.append(.text(text))
            } else if let attributed = item as? NSAttributedString, !attributed.string.isEmpty {
                rest.append(.text(attributed.string))
            } else if let image = item as? NSImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                rest.append(.image(png, ext: "png"))
            }
        }
        return (files.isEmpty ? [] : [.files(files)]) + rest
    }
}

// MARK: - The chooser

struct QuickSendState {
    var payloads: [DropPayload] = []
    var devices: [DropTileDevice] = []
    var trayCount = 0
    var optimization: SendOptimization = .default
    var defaults: SendOptimization = .default
    var saving: Double?
    var bytes: Int64 = 0

    var itemCount: Int { payloads.reduce(0) { $0 + $1.itemCount } }
}

struct QuickSendActions {
    var pick: (DropTarget) -> Void = { _ in }
    var cancel: () -> Void = {}
    var changeOptimization: (SendOptimization) -> Void = { _ in }
}

struct QuickSendView: View {
    let state: QuickSendState
    let actions: QuickSendActions
    @Environment(\.brand) private var c

    var body: some View {
        VStack(spacing: 0) {
            DropTilesView(devices: state.devices, trayCount: state.trayCount,
                          title: title, onPick: actions.pick)
                .frame(height: tilesHeight)
            HStack(spacing: 8) {
                OptimizationChipButton(options: state.optimization, defaults: state.defaults, saving: state.saving,
                                       change: actions.changeOptimization)
                Spacer(minLength: 0)
                if state.devices.isEmpty {
                    Text(L10n.text("share.noDevice", fallback: "No device connected"))
                        .font(BrandFont.body(12))
                        .foregroundStyle(c.on2)
                }
                Button(L10n.text("action.cancel", fallback: "Cancel"), action: actions.cancel)
                    .buttonStyle(PillButtonStyle(kind: .neutral, height: 28))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 340)
        .background(c.panel)
    }

    private var title: String {
        let size = state.bytes > 0 ? ", " + ByteCountFormatter.string(fromByteCount: state.bytes, countStyle: .file) : ""
        return state.itemCount == 1
            ? String(format: L10n.text("share.title.one", fallback: "Send 1 item%@ to"), size)
            : String(format: L10n.text("share.title", fallback: "Send %d items%@ to"), state.itemCount, size)
    }

    private var tilesHeight: CGFloat {
        let rows = (state.devices.count + 2) / 2
        return CGFloat(64 + rows * 130)
    }
}

/// Shows the chooser for what came in through Share, Services or a share picker.
@MainActor
final class QuickSendController: NSObject, NSWindowDelegate {
    static let shared = QuickSendController()

    private var panel: NSPanel?
    private var pairing: PairingCoordinator?
    private var state = QuickSendState()
    private var host: NSHostingView<AnyView>?
    private var override: SendOptimization?
    private let estimator = SendEstimator()
    private var savingObservation: AnyCancellable?

    func attach(pairing: PairingCoordinator) { self.pairing = pairing }

    func present(_ payloads: [DropPayload]) {
        guard let pairing, !payloads.isEmpty else { return }
        let preferences = SendPreferences.shared
        override = nil
        state = QuickSendState()
        state.payloads = payloads
        state.trayCount = TrayStore.shared.items.count
        state.defaults = preferences.optimization
        state.optimization = preferences.optimization
        sendTargets(pairing).forEach { pairing.refreshPhoneFreeSpace($0.id) }
        let urls = payloads.flatMap { payload -> [URL] in if case let .files(list) = payload { return list } else { return [] } }
        estimator.update(urls: urls, options: state.optimization)
        savingObservation = estimator.$saving.sink { [weak self] value in
            self?.state.saving = value
            DispatchQueue.main.async { self?.render() }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let bytes = SendSizing.bytes(payloads)
            await MainActor.run { [weak self] in
                self?.state.bytes = bytes
                self?.render()
            }
        }
        render()
        show()
    }

    private func needed() -> Int64 {
        SendSizing.needed(original: state.bytes, saving: state.optimization.isOriginal ? nil : state.saving)
    }

    private func render() {
        guard let pairing else { return }
        state.devices = sendTargets(pairing).map { target in
            DropTileDevice(id: target.id, name: target.name, battery: target.battery,
                           freeSpace: pairing.freeSpaceGate(needed: needed(), deviceID: target.id))
        }
        var actions = QuickSendActions()
        actions.pick = { [weak self] target in self?.pick(target) }
        actions.cancel = { [weak self] in self?.close() }
        actions.changeOptimization = { [weak self] options in
            guard let self else { return }
            override = options
            state.optimization = options
            let urls = state.payloads.flatMap { payload -> [URL] in if case let .files(list) = payload { return list } else { return [] } }
            estimator.update(urls: urls, options: options)
            render()
        }
        let reduce = UserDefaults.standard.bool(forKey: "settings.reduceMotion")
        let view = AnyView(BrandRoot(reduceMotion: reduce) { QuickSendView(state: self.state, actions: actions) })
        if let host { host.rootView = view } else { host = NSHostingView(rootView: view) }
        if let panel, let host { panel.setContentSize(host.fittingSize) }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentView !== host, let host { panel.contentView = host }
        if let host { panel.setContentSize(host.fittingSize) }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 8))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300), styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = L10n.text("share.window", fallback: "Send to phone")
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.canJoinAllSpaces)
        panel.delegate = self
        return panel
    }

    private func pick(_ target: DropTarget) {
        guard let pairing else { return }
        let payloads = state.payloads
        switch target {
        case .tray, .icon:
            TrayStore.shared.add(payloads)
            close()
            TrayController.show(pairing: pairing)
        case let .device(id):
            guard !pairing.freeSpaceGate(needed: needed(), deviceID: id).refuses else { return }
            let options = override ?? SendPreferences.shared.optimization
            guard let handle = SendDispatcher.send(payloads, to: id, pairing: pairing, optimization: options) else { return }
            SendPreferences.shared.rememberDevice(id)
            close()
            MenuBarDropController.shared.showSentToast(handle, warning: pairing.freeSpaceGate(needed: needed(), deviceID: id).message)
        }
    }

    func close() {
        panel?.orderOut(nil)
        savingObservation = nil
    }

    func windowWillClose(_ notification: Notification) { savingObservation = nil }
}
