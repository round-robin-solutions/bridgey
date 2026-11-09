import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct StoreFileOffer: Codable, Identifiable {
    var id: String { transferId }
    let transferId: String
    let name: String
    let mimeType: String
    let size: Int64
    let sha256: String
}
private struct StoreFileComplete: Codable { let transferId: String; let sha256: String }

@MainActor
final class StoreFiles {
    private unowned let owner: StoreConnection
    private var incoming: StoreFileOffer?
    private var staging: URL?
    private var destination: URL?
    private var destinationScoped = false
    private var output: FileHandle?
    private var received: Int64 = 0
    private var sequence: Int64 = 0
    private var hasher = SHA256()
    private var outgoing: StoreFileOffer?
    private var input: FileHandle?
    private var source: URL?
    private var sourceScoped = false
    private var sent: Int64 = 0
    private var generation = UUID()
    init(owner: StoreConnection) { self.owner = owner }

    func chooseFile() {
        guard owner.filesReady, outgoing == nil, incoming == nil, owner.pendingFile == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Send to phone"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url else { return }
                self.prepare(url)
            }
        }
    }
    private func prepare(_ url: URL) {
        guard owner.connected, outgoing == nil, incoming == nil else { return }
        let token = UUID(); generation = token
        source = url; sourceScoped = url.startAccessingSecurityScopedResource()
        owner.transferStatus = "Preparing \(url.lastPathComponent)..."
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .utility) { () throws -> (Int64, String) in
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PairingError.invalidMessage }
                    var hash = SHA256(); var bytes: Int64 = 0
                    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                        bytes += Int64(chunk.count)
                        guard bytes <= 10 * 1024 * 1024 * 1024 else { throw PairingError.invalidMessage }
                        hash.update(data: chunk)
                    }
                    return (bytes, Data(hash.finalize()).base64EncodedString())
                }.value
                guard self.generation == token, self.owner.filesReady else { return }
                let offer = StoreFileOffer(transferId: UUID().uuidString.lowercased(), name: url.lastPathComponent,
                                           mimeType: "application/octet-stream", size: result.0, sha256: result.1)
                self.input = try FileHandle(forReadingFrom: url); self.outgoing = offer; self.sequence = 0; self.sent = 0
                self.owner.encrypted("files.offer", data: try JSONEncoder().encode(offer), transfer: offer.transferId)
                self.owner.transferStatus = "Waiting for your phone to accept \(offer.name)."
                self.expire(token)
            } catch {
                if self.generation == token { self.cancel(); self.owner.transferStatus = "This file could not be sent. Choose it again." }
            }
        }
    }
    func accept() {
        guard let offer = owner.pendingFile, owner.filesReady else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = offer.name; panel.prompt = "Receive file"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, self.owner.pendingFile?.id == offer.id else { return }
                guard response == .OK, let url = panel.url else { self.reject(); return }
                do {
                    // Never silently replace an existing file, including a symlink.
                    guard !FileManager.default.fileExists(atPath: url.path), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                        self.reject(); self.owner.transferStatus = "Choose a new filename to receive this file."; return
                    }
                    self.destination = url; self.destinationScoped = url.startAccessingSecurityScopedResource()
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
                    guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PairingError.invalidMessage }
                    self.staging = tmp; self.output = try FileHandle(forWritingTo: tmp)
                    self.incoming = offer; self.received = 0; self.sequence = 0; self.hasher = SHA256()
                    self.owner.pendingFile = nil; self.owner.control("files.accept", transfer: offer.id)
                    self.owner.transferStatus = "Receiving \(offer.name)..."
                    let token = UUID(); self.generation = token; self.expire(token)
                } catch { self.reject(); self.cancel(); self.owner.transferStatus = "This file could not be saved. Try another destination." }
            }
        }
    }
    func reject() {
        if let offer = owner.pendingFile { owner.control("files.rejected", transfer: offer.id) }
        owner.pendingFile = nil
    }
    func payload(_ message: PairingMessage, _ data: Data) throws {
        switch message.kind {
        case "files.offer":
            let offer = try JSONDecoder().decode(StoreFileOffer.self, from: data)
            guard owner.filesReady, incoming == nil, outgoing == nil, owner.pendingFile == nil,
                  UUID(uuidString: offer.id) != nil, message.transferId == offer.id, StorePolicy.fileName(offer.name) != nil,
                  (0...(10 * 1024 * 1024 * 1024)).contains(offer.size), Data(base64Encoded: offer.sha256)?.count == 32 else {
                owner.control("files.rejected", transfer: offer.id); return
            }
            owner.pendingFile = offer
            let token = UUID(); generation = token; expire(token)
        case "files.chunk":
            guard owner.filesReady, let offer = incoming, message.transferId == offer.id, message.sequence == sequence,
                  !data.isEmpty, data.count <= 24 * 1024, received + Int64(data.count) <= offer.size, let output else { throw PairingError.invalidMessage }
            try output.write(contentsOf: data); hasher.update(data: data); received += Int64(data.count)
            owner.control("files.chunk.ack", transfer: offer.id, sequence: sequence); sequence += 1
            owner.transferStatus = "Receiving \(offer.name): \(received) of \(offer.size) bytes"
            let token = UUID(); generation = token; expire(token)
        case "files.complete":
            let complete = try JSONDecoder().decode(StoreFileComplete.self, from: data)
            guard owner.filesReady, let offer = incoming, complete.transferId == offer.id, message.transferId == offer.id,
                  received == offer.size, complete.sha256 == offer.sha256, Data(hasher.finalize()).base64EncodedString() == offer.sha256,
                  let staging, let destination else { throw PairingError.invalidMessage }
            try output?.synchronize(); try output?.close(); output = nil
            // copyItem fails if a file appeared at the selected path during transfer.
            try FileManager.default.copyItem(at: staging, to: destination)
            owner.receivedFiles.insert(destination, at: 0)
            if owner.receivedFiles.count > 20 { owner.receivedFiles.removeLast() }
            owner.control("files.complete.ack", transfer: offer.id)
            cancel(); owner.transferStatus = "Saved \(offer.name)."
        default: break
        }
    }
    func control(_ message: PairingMessage) throws {
        if message.kind == "files.cancel" {
            guard message.transferId == incoming?.id || message.transferId == outgoing?.id || message.transferId == owner.pendingFile?.id else { return }
            owner.control("files.cancel.ack", transfer: message.transferId); cancel(); owner.transferStatus = "Transfer cancelled."; return
        }
        guard let outgoing, message.transferId == outgoing.id else { return }
        switch message.kind {
        case "files.accept":
            // A second accept cannot start another writer over the same stream.
            guard sent == 0, sequence == 0, !sending else { return }
            sending = true; sendChunk()
        case "files.rejected": cancel(); owner.transferStatus = "Your phone declined the file."
        case "files.complete.ack":
            guard sent == outgoing.size, input == nil else { throw PairingError.invalidMessage }
            cancel(); owner.transferStatus = "File sent to your phone."
        default: break
        }
    }
    private var sending = false
    private func sendChunk() {
        guard owner.filesReady, let outgoing, let input else { cancel(); return }
        do {
            let chunk = try input.read(upToCount: 24 * 1024) ?? Data()
            if chunk.isEmpty {
                guard sent == outgoing.size else { throw PairingError.invalidMessage }
                try input.close(); self.input = nil
                owner.encrypted("files.complete", data: try JSONEncoder().encode(StoreFileComplete(transferId: outgoing.id, sha256: outgoing.sha256)), transfer: outgoing.id)
                owner.transferStatus = "Waiting for your phone to confirm receipt."
                return
            }
            guard sent + Int64(chunk.count) <= outgoing.size else { throw PairingError.invalidMessage }
            let next = sequence; sequence += 1; sent += Int64(chunk.count)
            let token = UUID(); generation = token; expire(token)
            owner.encrypted("files.chunk", data: chunk, transfer: outgoing.id, sequence: next) { [weak self] in self?.sendChunk() }
            owner.transferStatus = "Sending \(outgoing.name): \(sent) of \(outgoing.size) bytes"
        } catch { owner.control("files.cancel", transfer: outgoing.id); cancel(); owner.transferStatus = "Transfer interrupted. Choose the file to retry." }
    }
    private func expire(_ token: UUID) {
        // One cancellable inactivity deadline, replaced as bytes move. No background polling.
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            let id = self.incoming?.id ?? self.outgoing?.id ?? self.owner.pendingFile?.id
            self.owner.control("files.cancel", transfer: id); self.cancel(); self.owner.transferStatus = "Transfer timed out. Try again."
        }
    }
    private var deadline: Task<Void, Never>?
    func cancel() {
        deadline?.cancel(); deadline = nil; generation = UUID()
        try? input?.close(); try? output?.close(); input = nil; output = nil
        if let staging { try? FileManager.default.removeItem(at: staging) }
        if destinationScoped { destination?.stopAccessingSecurityScopedResource() }
        if sourceScoped { source?.stopAccessingSecurityScopedResource() }
        destination = nil; source = nil; staging = nil; incoming = nil; outgoing = nil
        destinationScoped = false; sourceScoped = false; sending = false; owner.pendingFile = nil
    }
}
