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
    static func send(urls: [URL], to deviceID: String, pairing: PairingCoordinator, optimization: SendOptimization? = nil) -> SendHandle? {
        send([.files(urls)], to: deviceID, pairing: pairing, optimization: optimization)
    }

    /// Whatever a drop carried: files and folders queue as transfers (after optimisation when the settings
    /// change any of them); images without a file are written to an owner-only folder first; text and links
    /// go as clipboard text. `optimization` nil uses Settings > Files > Before sending.
    @discardableResult
    static func send(_ payloads: [DropPayload], to deviceID: String, pairing: PairingCoordinator,
                     optimization: SendOptimization? = nil) -> SendHandle? {
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
            let options = optimization ?? SendPreferences.shared.optimization
            if urls.contains(where: { SendOptimizer.mightChange($0, with: options) }) {
                guard pairing.connectedPhones.contains(where: { $0.id == deviceID }), pairing.isFeatureAvailable(.files, for: deviceID) else {
                    return texts.isEmpty ? nil : sendTexts(texts, handle: handle, pairing: pairing)
                }
                SendPreparation.start(urls, options: options, handle: handle, pairing: pairing)
                sent = true
            } else {
                let before = Set(pairing.fileTransfers.keys)
                if pairing.sendDroppedFiles(urls, to: deviceID) {
                    sent = true
                    handle.started(Set(pairing.fileTransfers.keys).subtracting(before))
                }
            }
        }
        for text in texts where pairing.sendText(text, to: deviceID) { sent = true }
        return sent ? handle : nil
    }

    private static func sendTexts(_ texts: [String], handle: SendHandle, pairing: PairingCoordinator) -> SendHandle? {
        var sent = false
        for text in texts where pairing.sendText(text, to: handle.deviceID) { sent = true }
        return sent ? handle : nil
    }
}

/// The optimisation step before a send: one Stream row ("Optimising 3 of 12"), work off the main thread,
/// then the copies go to the transfer queue. Cancelling the row, or Undo, stops it.
@MainActor
enum SendPreparation {
    static func start(_ urls: [URL], options: SendOptimization, handle: SendHandle, pairing: PairingCoordinator) {
        let rowID = "prepare-\(UUID().uuidString.lowercased())"
        let work = urls.filter { SendOptimizer.mightChange($0, with: options) }
        let name = urls.count == 1 ? urls[0].lastPathComponent
            : String(format: L10n.text("optimize.row.items", fallback: "%d items"), urls.count)
        let cancel = OptimizerCancel()
        handle.cancelPreparation = { [weak pairing] in
            cancel.cancel()
            pairing?.removePreparationRow(id: rowID)
        }
        func status(_ done: Int) -> String {
            String(format: L10n.text("optimize.row.progress", fallback: "Optimising %d of %d"), min(done + 1, work.count), work.count)
        }
        pairing.showPreparationRow(id: rowID, name: name, status: status(0), active: true)
        let cache = SendOptimizer.cacheDirectory()
        Task.detached(priority: .userInitiated) {
            var outputs: [URL] = []
            var done = 0
            for url in urls {
                if cancel.isCancelled { break }
                guard SendOptimizer.mightChange(url, with: options) else {
                    outputs.append(url)
                    continue
                }
                let item = try? await SendOptimizer.optimize(url, with: options, cache: cache, cancel: cancel)
                outputs.append(item?.output ?? url)
                done += 1
                let step = done
                await MainActor.run {
                    // The row's Cancel in the Stream ends it; stop with it.
                    if pairing.fileTransfers[rowID]?.active == false { cancel.cancel() }
                    if !cancel.isCancelled, step < work.count { pairing.showPreparationRow(id: rowID, name: name, status: status(step), active: true) }
                }
            }
            SendOptimizer.trimCache(cache)
            let finished = outputs
            await MainActor.run {
                if pairing.fileTransfers[rowID]?.active == false { cancel.cancel() }
                pairing.removePreparationRow(id: rowID)
                guard !cancel.isCancelled, !handle.cancelled else { return }
                let before = Set(pairing.fileTransfers.keys)
                if pairing.sendDroppedFiles(finished, to: handle.deviceID) {
                    handle.started(Set(pairing.fileTransfers.keys).subtracting(before))
                }
            }
        }
    }
}

/// Images dragged in without a file (from a browser): written once, owner-only, cleared after a day.
enum DroppedData {
    static func directory() -> URL {
        TrayStore.defaultDirectory().deletingLastPathComponent().appendingPathComponent("Dropped", isDirectory: true)
    }

    static func write(_ data: Data, ext: String, name: String? = nil, now: Date = Date()) -> URL? {
        prune(now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = directory().appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let url = folder.appendingPathComponent(name ?? "Image \(formatter.string(from: now)).\(ext)")
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
