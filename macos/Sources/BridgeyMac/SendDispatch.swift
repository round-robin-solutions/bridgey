import AppKit
import Foundation

// Every send from the send sheet, the Tray, the drop tiles and the menu-bar icon goes through here, so the
// optimisation step and Undo work the same everywhere.

/// One send in flight: the transfer rows it started, so Undo can cancel them.
@MainActor
final class SendHandle {
    let deviceID: String
    let payloads: [DropPayload]
    private(set) var transferIDs: Set<String> = []
    private(set) var cancelled = false
    /// Cancels work that has not reached the transfer queue yet (optimisation).
    var cancelPreparation: (() -> Void)?

    init(deviceID: String, payloads: [DropPayload]) {
        self.deviceID = deviceID
        self.payloads = payloads
    }

    func started(_ ids: Set<String>) {
        transferIDs.formUnion(ids)
        if cancelled { ids.forEach(cancelTransfer) }
    }

    private var cancelTransfer: (String) -> Void = { _ in }

    func bind(_ pairing: PairingCoordinator) {
        cancelTransfer = { [weak pairing] id in pairing?.cancelFileTransfer(id: id) }
    }

    /// True when something was still in flight to stop.
    @discardableResult
    func cancel(in pairing: PairingCoordinator) -> Bool {
        cancelled = true
        cancelPreparation?()
        cancelPreparation = nil
        let live = transferIDs.filter { pairing.fileTransfers[$0]?.active == true }
        live.forEach { pairing.cancelFileTransfer(id: $0) }
        return !live.isEmpty
    }

    var itemCount: Int { payloads.reduce(0) { $0 + $1.itemCount } }
}

@MainActor
enum SendDispatcher {
    /// Files and folders to one phone. Nil when nothing could be queued.
    @discardableResult
    static func send(urls: [URL], to deviceID: String, pairing: PairingCoordinator) -> SendHandle? {
        send([.files(urls)], to: deviceID, pairing: pairing)
    }

    /// Whatever a drop carried: files and folders queue as transfers; images without a file are written to
    /// an owner-only folder first; text and links go as clipboard text.
    @discardableResult
    static func send(_ payloads: [DropPayload], to deviceID: String, pairing: PairingCoordinator) -> SendHandle? {
        let handle = SendHandle(deviceID: deviceID, payloads: payloads)
        handle.bind(pairing)
        var urls: [URL] = []
        var texts: [String] = []
        for payload in payloads {
            switch payload {
            case let .files(list): urls += list
            case let .image(data, ext): if let url = DroppedData.write(data, ext: ext) { urls.append(url) }
            case let .text(text): texts.append(text)
            case let .link(url): texts.append(url.absoluteString)
            }
        }
        var sent = false
        if !urls.isEmpty {
            let before = Set(pairing.fileTransfers.keys)
            if pairing.sendDroppedFiles(urls, to: deviceID) {
                sent = true
                handle.started(Set(pairing.fileTransfers.keys).subtracting(before))
            }
        }
        for text in texts where pairing.sendText(text, to: deviceID) { sent = true }
        return sent ? handle : nil
    }
}

/// Images dragged in without a file (from a browser): written once, owner-only, cleared after a day.
enum DroppedData {
    static func directory() -> URL {
        TrayStore.defaultDirectory().deletingLastPathComponent().appendingPathComponent("Dropped", isDirectory: true)
    }

    static func write(_ data: Data, ext: String, now: Date = Date()) -> URL? {
        prune(now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = directory().appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let url = folder.appendingPathComponent("Image \(formatter.string(from: now)).\(ext)")
        return TrayStore.writeOwnerOnly(data, to: url) ? url : nil
    }

    static func prune(now: Date) {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: directory(), includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            if now.timeIntervalSince(created) > 24 * 60 * 60 { try? manager.removeItem(at: folder) }
        }
    }
}
