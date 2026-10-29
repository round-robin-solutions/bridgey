import CryptoKit
import Foundation
@testable import BridgeyMac

/// A scripted phone for the browse client: records requests and answers them as a phone would (the wire,
/// not Android). `respond` runs for every encrypted request; tests either answer by hand or install a
/// server function. `lan` simulates a link: each answer arrives after the latency plus bytes over bandwidth.
@MainActor
final class LoopbackPhone: FolderTransport, PhoneFilesHost {
    struct Sent {
        let kind: String
        let payload: Data?
        let transferID: String?
        let sequence: Int64?
    }

    let phoneID = "11111111-1111-1111-1111-111111111111"
    var name = "OnePlus 11"
    var browsable = true
    var connected = true
    var route: PhoneRoute = .lan
    private(set) var sent: [Sent] = []
    weak var controller: PhoneFilesController?
    /// Answers a request: return (kind, payload) messages to deliver, in order.
    var server: ((String, Data) -> [(String, Data)])?
    /// Simulated link (nil: answers are delivered synchronously).
    var link: (latency: TimeInterval, bytesPerSecond: Double)?
    /// Phone-side work before each answer message (thumbnail generation and so on).
    var workPerMessage: TimeInterval = 0
    private var busyUntil = Date.distantPast
    var expected: [ExpectedDownload] = []
    var cancelledDownloads: [ExpectedDownload] = []
    var uploads: [UploadRequest] = []

    // FolderTransport (Mac to phone).
    nonisolated func send(kind: String, payload: Data, transferID: String?, sequence: Int64?) -> Bool {
        MainActor.assumeIsolated { self.record(kind: kind, payload: payload, transferID: transferID, sequence: sequence) }
        return true
    }

    nonisolated func sendOuter(kind: String, transferID: String) {
        MainActor.assumeIsolated { self.sent.append(Sent(kind: kind, payload: nil, transferID: transferID, sequence: nil)) }
    }

    /// Requests the Mac cancelled with media.cancel: their answers still on the way are dropped, as on the phone.
    private var cancelledRequests = Set<String>()

    private func record(kind: String, payload: Data, transferID: String?, sequence: Int64?) {
        sent.append(Sent(kind: kind, payload: payload, transferID: transferID, sequence: sequence))
        if kind == BrowseKind.mediaCancel, let cancel = try? JSONDecoder().decode(MediaCancelPayload.self, from: payload) {
            cancelledRequests.insert(cancel.requestId)
        }
        guard let server else { return }
        let answers = server(kind, payload)
        let requestID = (try? JSONDecoder().decode(BrowseRequestProbe.self, from: payload))?.requestId
        guard let link else {
            for (answerKind, data) in answers { controller?.handle(kind: answerKind, payload: data, from: phoneID) }
            return
        }
        // Messages leave the phone one after another; each costs its work and its bytes on the wire.
        var at = max(Date(), busyUntil)
        for (answerKind, data) in answers {
            at = at.addingTimeInterval(workPerMessage + Double(data.count) * 4 / 3 / link.bytesPerSecond)
            let deliverAt = at.addingTimeInterval(link.latency)
            let delay = max(0, deliverAt.timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !(requestID.map(self.cancelledRequests.contains) ?? false) else { return }
                self.controller?.handle(kind: answerKind, payload: data, from: self.phoneID)
            }
        }
        busyUntil = at
    }

    func deliver(_ kind: String, _ payload: Encodable) {
        let data = try! FolderJSON.encoder.encode(AnyEncodable(payload))
        controller?.handle(kind: kind, payload: data, from: phoneID)
    }

    func requests(_ kind: String) -> [Sent] { sent.filter { $0.kind == kind } }

    func decode<T: Decodable>(_ type: T.Type, _ message: Sent) -> T { try! JSONDecoder().decode(type, from: message.payload!) }

    // PhoneFilesHost.
    func browseTransport(for phoneID: String) -> FolderTransport? { connected && phoneID == self.phoneID ? self : nil }
    func browsePhones() -> [BrowsablePhone] { connected ? [BrowsablePhone(id: phoneID, name: name, browsable: browsable, route: route)] : [] }
    func expectDownload(_ download: ExpectedDownload) { expected.append(download) }
    func cancelDownload(_ download: ExpectedDownload) { cancelledDownloads.append(download) }
    func startUpload(_ upload: UploadRequest) -> String? {
        uploads.append(upload)
        return "upload-\(uploads.count)"
    }
    func cancelUpload(_ id: String) {}
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// A phone-side thumbnail server: makes a thumbnail of `bytes` bytes for each media ID and packs as many as fit
/// into each batch (at most 44 KiB of plaintext), in the order asked. IDs in `missing` have none.
@MainActor
func thumbnailServer(bytes: Int = 9_000, missing: Set<String> = []) -> (String, Data) -> [(String, Data)] {
    { kind, payload in
        guard kind == BrowseKind.mediaThumbnails, let request = try? JSONDecoder().decode(MediaThumbnailsPayload.self, from: payload) else { return [] }
        var batches: [(String, Data)] = []
        var thumbs: [ThumbPayload] = []
        var gone: [String] = []
        var size = 200
        let data = Data(repeating: 0xAB, count: bytes).base64EncodedString()
        func flush(done: Bool) {
            let batch = MediaThumbnailsBatchPayload(requestId: request.requestId, thumbs: thumbs, missing: gone, done: done)
            batches.append((BrowseKind.mediaThumbnailsBatch, try! FolderJSON.encoder.encode(batch)))
            thumbs = []
            gone = []
            size = 200
        }
        for item in request.items {
            if let id = item.ref.mediaId, missing.contains(id) {
                gone.append(item.key)
                continue
            }
            let thumb = ThumbPayload(key: item.key, mimeType: "image/webp", width: 256, height: 192, tint: "#336699", data: data)
            let cost = data.count + 120
            if size + cost > BrowseKind.mediaPartPlaintext - 64, !thumbs.isEmpty { flush(done: false) }
            thumbs.append(thumb)
            size += cost
        }
        flush(done: true)
        return batches
    }
}

func mediaEntries(_ count: Int, thumbs: Bool = true) -> [PhoneFileEntry] {
    (0..<count).map { index in
        PhoneFileEntry(ref: .media(id: String(1_000 + index)), name: "IMG_\(index).jpg", isDirectory: false, size: 3_000_000,
                       modified: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)), mimeType: "image/jpeg", hasThumbnail: thumbs)
    }
}
