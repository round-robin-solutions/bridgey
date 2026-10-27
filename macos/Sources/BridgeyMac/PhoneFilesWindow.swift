import AppKit
import SwiftUI

// Files 2.0: the Phone files window (Photos and Videos, Files, Folders, Recent from phone) and its entries
// in the panel and on the Devices page.

@MainActor
enum PhoneFilesWindowController {
    private static var window: PhoneFilesNSWindow?
    private static var model: PhoneFilesModel?
    private static var promises: PhoneFilePromises?
    private static var closeObserver: NSObjectProtocol?

    /// Opens (or brings forward) the Phone files window on a phone; nil picks the last or selected phone.
    static func show(pairing: PairingCoordinator, phoneID: String?) {
        if let window, let model {
            if let phoneID { model.select(phone: phoneID) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = PhoneFilesModel(service: pairing.phoneFiles)
        let promises = PhoneFilePromises(model: model)
        let window = PhoneFilesNSWindow(contentRect: NSRect(origin: .zero, size: PhoneFilesWindowView.size),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                        backing: .buffered, defer: false)
        let root = PhoneFilesLiveView(model: model, promises: promises,
                                      quickLook: { [weak window] entries in quickLook(entries, model: model, window: window) },
                                      showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
        window.contentViewController = NSHostingController(rootView: root)
        window.title = L10n.text("phonefiles.window", fallback: "Phone files")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.setContentSize(PhoneFilesWindowView.size)
        window.setFrameAutosaveName("BridgeyPhoneFilesWindow")
        if window.frame.origin == .zero { window.center() }
        window.onSpace = { [weak window] in
            guard let window else { return }
            if window.toggleQuickLook() { return }
            let entries = model.preview.map { [$0.entry] } ?? model.selectedEntries
            quickLook(entries.filter(PhoneFilesText.quickLookable), model: model, window: window)
        }
        window.onEscape = {
            guard model.preview != nil else { return false }
            model.closePreview()
            return true
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                PhoneFilesWindowController.model?.stop()
                if let observer = PhoneFilesWindowController.closeObserver { NotificationCenter.default.removeObserver(observer) }
                PhoneFilesWindowController.window = nil
                PhoneFilesWindowController.model = nil
                PhoneFilesWindowController.promises = nil
            }
        }
        self.window = window
        self.model = model
        self.promises = promises
        model.start(preferred: phoneID)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Downloads the originals into the private preview folder (once per cache key), then opens Quick Look.
    private static func quickLook(_ entries: [PhoneFileEntry], model: PhoneFilesModel, window: PhoneFilesNSWindow?) {
        guard !entries.isEmpty else { return }
        var urls = [URL?](repeating: nil, count: entries.count)
        var remaining = entries.count
        for (index, entry) in entries.enumerated() {
            model.fetchOriginal(entry) { url in
                urls[index] = url
                remaining -= 1
                if remaining == 0 { window?.showQuickLook(urls.compactMap { $0 }) }
            }
        }
    }
}

private struct PhoneFilesLiveView: View {
    @ObservedObject var model: PhoneFilesModel
    let promises: PhoneFilePromises
    let quickLook: ([PhoneFileEntry]) -> Void
    let showInFinder: (URL) -> Void
    @AppStorage("settings.reduceMotion") private var reduceMotion = false

    var body: some View {
        BrandRoot(reduceMotion: reduceMotion) {
            PhoneFilesWindowView(model: model, promises: promises, quickLook: quickLook, showInFinder: showInFinder)
        }
        .ignoresSafeArea()
    }
}

/// The panel's entry to Phone files and History, under the quick actions.
struct PhoneFilesPanelEntry: View {
    let model: PanelModel
    let actions: PanelActions
    @Environment(\.brand) private var c

    var body: some View {
        if model.onboardingDone, model.isConnected || model.hasTransferHistory {
            HStack(spacing: 8) {
                if model.isConnected {
                    entry(symbol: "photo.on.rectangle.angled", title: L10n.text("phonefiles.entry", fallback: "Phone files"),
                          help: L10n.text("phonefiles.entry.help", fallback: "Browse photos, documents and folders on the phone")) {
                        actions.openPhoneFiles(model.targetDeviceID)
                    }
                    .disabled(!model.available.contains(.files))
                }
                entry(symbol: "clock.arrow.circlepath", title: L10n.text("history.entry", fallback: "History"),
                      help: L10n.text("history.entry.help", fallback: "Every file sent and received")) {
                    actions.openTransferHistory()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func entry(symbol: String, title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(BrandFont.body(12, .medium))
            }
            .foregroundStyle(c.on)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.s2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
    }
}

/// The Devices page's entry to Phone files, in each device card's header (connected phones only).
struct PhoneFilesDeviceEntry: View {
    let deviceID: String
    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        if model.rings.first(where: { $0.deviceID == deviceID })?.state == .connected {
            Button(L10n.text("phonefiles.entry", fallback: "Phone files")) { actions.openPhoneFiles(deviceID) }
                .buttonStyle(PillButtonStyle(kind: .tonal, height: 28))
                .help(L10n.text("phonefiles.entry.help", fallback: "Browse photos, documents and folders on the phone"))
        }
    }
}
