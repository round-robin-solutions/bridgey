import AppKit

// Files 2.0: the History entry points (the panel, Phone files). History now lives in the Transfers window
// (FileTransferWindow.swift), so they open that window at its history.

@MainActor
enum TransferHistoryWindowController {
    static func show(pairing: PairingCoordinator) {
        pairing.showFileTransferWindow(history: true)
    }
}
