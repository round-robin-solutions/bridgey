import AppKit
import SwiftUI

@MainActor
final class FileTransferWindowController: NSWindowController {
    init(pairing: PairingCoordinator) {
        let root = FileTransferView(pairing: pairing)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Bridgey File Transfer"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 360))
        window.minSize = NSSize(width: 520, height: 260)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct FileTransferView: View {
    @ObservedObject var pairing: PairingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("File Transfer").font(.title2).fontWeight(.semibold)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if pairing.fileTransfers.isEmpty {
                        Text("No recent file transfers").foregroundStyle(.secondary)
                    } else {
                        ForEach(pairing.fileTransfers.values.sorted(by: { $0.startedAt > $1.startedAt })) { transfer in
                            if let folder = transfer.folder {
                                FolderTransferRow(transfer: transfer, folder: folder, pairing: pairing)
                            } else {
                            HStack(alignment: .center, spacing: 12) {
                                if transfer.active && !transfer.queued { ProgressView().controlSize(.small) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(transfer.name).fontWeight(.medium)
                                    Text(transfer.status).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if transfer.active {
                                    Button("Cancel", role: .destructive) {
                                        pairing.cancelFileTransfer(id: transfer.id)
                                    }
                                } else {
                                    ShowInFinderButton(url: transfer.localURL)
                                    if transfer.retryable {
                                        Button("Retry") { pairing.retryFileTransfer(id: transfer.id) }
                                    }
                                }
                            }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if pairing.fileTransferActive {
                    Button("Cancel All", role: .destructive) { pairing.cancelFileTransfer() }
                }
                if pairing.fileTransfers.values.contains(where: { !$0.active }) {
                    Button("Clear History") { pairing.clearTransferHistory() }
                }
                Spacer()
                Button(L10n.text("history.entry", fallback: "History")) { TransferHistoryWindowController.show(pairing: pairing) }
                Button("Close") { BridgeyWindows.close(NSApp.keyWindow) }
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 240)
    }
}

/// One row per folder: "Photos → OnePlus 11 › Pictures/Trip", a bar by bytes, the live status line, and a
/// disclosure for the current file, failures and the last completed names.
private struct FolderTransferRow: View {
    let transfer: FileTransferRow
    let folder: FolderRowSummary
    @ObservedObject var pairing: PairingCoordinator
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("folders.details.toggle", fallback: "Show files"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(FolderText.title(folder)).fontWeight(.medium).lineLimit(1)
                    if folder.state == .running, folder.progress.phase == .sending || folder.progress.phase == .completing {
                        ProgressView(value: Double(folder.progress.bytesDone), total: Double(max(folder.progress.bytesTotal, 1)))
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(FolderText.status(folder, now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if transfer.active {
                    Button(L10n.text("action.cancel", fallback: "Cancel"), role: .destructive) { pairing.cancelFileTransfer(id: transfer.id) }
                } else {
                    ShowInFinderButton(url: transfer.localURL)
                    if folder.canResume {
                        Button(L10n.text("folders.action.resume", fallback: "Resume")) { pairing.resumeFolderTransfer(id: transfer.id) }
                    }
                    if folder.canSendAgain {
                        Button(L10n.text("folders.action.sendAgain", fallback: "Send Again")) { pairing.retryFileTransfer(id: transfer.id) }
                    }
                }
            }
            if expanded {
                BrandRoot(reduceMotion: false) {
                    FolderExpandedDetails(progress: folder.progress, maxHeight: 160)
                }
                .padding(.leading, 24)
            }
        }
    }
}

/// Show in Finder for a finished row; disabled when the item is gone (moved or deleted).
private struct ShowInFinderButton: View {
    let url: URL?

    var body: some View {
        if let url {
            Button(L10n.text("phonefiles.showInFinder", fallback: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}
