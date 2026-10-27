import Foundation

// The browse client (protocol.md "Draft: phone files, media and folders both ways"): every request the Phone
// files window, the send sheet and the Tray make of a phone, on the main thread. Two lanes per phone, as the
// phone budgets them: browse (lists, downloads) and media (thumbnails, previews, ranges; at most 4 active and
// 60 per 10 seconds, so the client queues the rest). Thumbnail jobs replace each other per lane: what the
// phone has not sent yet is cancelled with media.cancel. Downloads and uploads run as folder transfers; the
// coordinator wires them through `PhoneFilesHost`.

/// A download this Mac asked for, waiting for (or running as) the phone's `into` folder offer.
final class ExpectedDownload {
    let requestId: String
    let phoneID: String
    let directory: URL
    let purpose: PhoneDownloadPurpose
    var folderTransferId: String?
    var cancelled = false
    let progress: (PhoneTransferProgress) -> Void
    let completion: (Result<[URL], PhoneFilesError>) -> Void
    private var finished = false

    init(requestId: String, phoneID: String, directory: URL, purpose: PhoneDownloadPurpose,
         progress: @escaping (PhoneTransferProgress) -> Void, completion: @escaping (Result<[URL], PhoneFilesError>) -> Void) {
        self.requestId = requestId
        self.phoneID = phoneID
        self.directory = directory
        self.purpose = purpose
        self.progress = progress
        self.completion = completion
    }

    /// Runs the completion once.
    func finish(_ result: Result<[URL], PhoneFilesError>) {
        guard !finished else { return }
        finished = true
        completion(result)
    }

    var isFinished: Bool { finished }
}

/// An upload into a folder of a place (an `into` offer with destination).
struct UploadRequest {
    let phoneID: String
    let urls: [URL]
    let destination: FolderDestination
    let progress: (PhoneTransferProgress) -> Void
    let completion: (Result<Void, PhoneFilesError>) -> Void
}

@MainActor
protocol PhoneFilesHost: AnyObject {
    /// Encrypted messages to the phone's current session; nil when it is not connected.
    func browseTransport(for phoneID: String) -> FolderTransport?
    /// Connected phones with their browse key and route.
    func browsePhones() -> [BrowsablePhone]
    /// The receive side waits for the offer that answers this download.
    func expectDownload(_ download: ExpectedDownload)
    /// The caller cancelled: the expected offer is refused, or the running download stops.
    func cancelDownload(_ download: ExpectedDownload)
    /// Starts an upload; false when it could not start (the completion has run).
    func startUpload(_ upload: UploadRequest) -> String?
    func cancelUpload(_ id: String)
}

@MainActor
final class PhoneFilesController: PhoneFilesService {
    private weak var host: PhoneFilesHost?
    private let clock: FolderClock
    private let makeID: () -> String

    var onPhonesChanged: (() -> Void)?

    init(host: PhoneFilesHost?, clock: FolderClock = DispatchFolderClock(queue: .main), makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.host = host
        self.clock = clock
        self.makeID = makeID
    }

    func attach(_ host: PhoneFilesHost) { self.host = host }

    var phones: [BrowsablePhone] { host?.browsePhones() ?? [] }

    /// The coordinator calls this when connections or features change.
    func phonesChanged() { onPhonesChanged?() }

    // MARK: Requests

    private final class Request {
        let id: String
        let phoneID: String
        let media: Bool
        var timer: FolderTimer?
        /// Handles one answer; true when the request is finished.
        var answer: (String, Data) -> Bool
        var fail: (PhoneFilesError) -> Void
        var sent = false
        /// Queued media requests: the payload to send when a slot is free.
        var pending: (kind: String, payload: Data)?

        init(id: String, phoneID: String, media: Bool, answer: @escaping (String, Data) -> Bool, fail: @escaping (PhoneFilesError) -> Void) {
            self.id = id
            self.phoneID = phoneID
            self.media = media
            self.answer = answer
            self.fail = fail
        }
    }

    private var requests: [String: Request] = [:]
    /// Media lane per phone: active request IDs, the waiting queue (oldest first) and recent send times.
    private var mediaActive: [String: Set<String>] = [:]
    private var mediaQueue: [String: [String]] = [:]
    private var mediaSent: [String: [Date]] = [:]
    private var mediaRetry: [String: FolderTimer] = [:]

    var activeMediaRequests: Int { mediaActive.values.reduce(0) { $0 + $1.count } }
    var inFlight: Int { requests.count }

    private func encode<P: Encodable>(_ payload: P) -> Data? { try? FolderJSON.encoder.encode(payload) }

    private func transport(_ phoneID: String) -> FolderTransport? {
        guard phones.first(where: { $0.id == phoneID })?.browsable == true else { return nil }
        return host?.browseTransport(for: phoneID)
    }

    private func availability(_ phoneID: String) -> PhoneFilesError? {
        guard let phone = phones.first(where: { $0.id == phoneID }) else { return .notConnected }
        guard phone.browsable else { return .notBrowsable }
        return host?.browseTransport(for: phoneID) == nil ? .notConnected : nil
    }

    /// A browse-lane request: sent now, answered within 8 seconds.
    private func browse(_ phoneID: String, kind: String, id: String, payload: Data?, answer: @escaping (String, Data) -> Bool,
                        fail: @escaping (PhoneFilesError) -> Void) {
        if let problem = availability(phoneID) { return fail(problem) }
        guard let payload, let wire = transport(phoneID) else { return fail(.code(FolderCode.invalidMessage)) }
        let request = Request(id: id, phoneID: phoneID, media: false, answer: answer, fail: fail)
        requests[id] = request
        request.sent = true
        arm(request)
        guard wire.send(kind: kind, payload: payload, transferID: nil, sequence: nil) else { return finish(id, .notConnected) }
    }

    /// A media-lane request: queued until the phone's media budget has room.
    private func media(_ phoneID: String, kind: String, id: String, payload: Data?, answer: @escaping (String, Data) -> Bool,
                       fail: @escaping (PhoneFilesError) -> Void) {
        if let problem = availability(phoneID) { return fail(problem) }
        guard let payload else { return fail(.code(FolderCode.invalidMessage)) }
        let request = Request(id: id, phoneID: phoneID, media: true, answer: answer, fail: fail)
        request.pending = (kind, payload)
        requests[id] = request
        mediaQueue[phoneID, default: []].append(id)
        pumpMedia(phoneID)
    }

    private func pumpMedia(_ phoneID: String) {
        while var queue = mediaQueue[phoneID], !queue.isEmpty {
            guard mediaActive[phoneID, default: []].count < BrowseLimits.mediaActive else { return }
            let now = clock.now
            var sent = mediaSent[phoneID, default: []].filter { now.timeIntervalSince($0) < BrowseLimits.mediaWindow }
            mediaSent[phoneID] = sent
            if sent.count >= BrowseLimits.mediaPerWindow, let oldest = sent.first {
                // Over 60 in 10 seconds: wait until the oldest leaves the window instead of earning `busy`.
                if mediaRetry[phoneID] == nil {
                    let delay = max(0.05, BrowseLimits.mediaWindow - now.timeIntervalSince(oldest))
                    mediaRetry[phoneID] = clock.schedule(after: delay) { [weak self] in
                        self?.mediaRetry[phoneID] = nil
                        self?.pumpMedia(phoneID)
                    }
                }
                return
            }
            let id = queue.removeFirst()
            mediaQueue[phoneID] = queue
            guard let request = requests[id], let pending = request.pending else { continue }
            request.pending = nil
            request.sent = true
            sent.append(now)
            mediaSent[phoneID] = sent
            mediaActive[phoneID, default: []].insert(id)
            arm(request)
            // Marked active before sending: a transport that answers at once finds the request in place.
            guard let wire = host?.browseTransport(for: phoneID),
                  wire.send(kind: pending.kind, payload: pending.payload, transferID: nil, sequence: nil) else {
                finish(id, .notConnected)
                continue
            }
        }
    }

    /// 8 seconds to the first answer, and again between the parts of a streamed answer.
    private func arm(_ request: Request) {
        request.timer?.cancel()
        guard requests[request.id] === request else { return }
        let id = request.id
        request.timer = clock.schedule(after: FolderTimeouts.placesAnswer) { [weak self] in self?.finish(id, .timeout) }
    }

    /// Ends a request with a failure (nil: finished normally). Frees its media slot.
    private func finish(_ id: String, _ failure: PhoneFilesError?) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.timer?.cancel()
        if request.media {
            mediaActive[request.phoneID]?.remove(id)
            mediaQueue[request.phoneID]?.removeAll { $0 == id }
        }
        if let failure { request.fail(failure) }
        if request.media { pumpMedia(request.phoneID) }
    }

    /// Stops a request on the caller's behalf: dropped if still queued, media.cancel if the phone has it.
    private func cancelRequest(_ id: String) {
        guard let request = requests[id] else { return }
        if request.media, request.sent, let wire = host?.browseTransport(for: request.phoneID),
           let payload = encode(MediaCancelPayload(requestId: id)) {
            wire.send(kind: BrowseKind.mediaCancel, payload: payload, transferID: nil, sequence: nil)
        }
        finish(id, .cancelled)
    }

    /// An answer from the phone. False when it matches no request (late, cancelled, or another client's).
    @discardableResult
    func handle(kind: String, payload: Data, from phoneID: String) -> Bool {
        guard let probe = try? JSONDecoder().decode(BrowseRequestProbe.self, from: payload),
              let request = requests[probe.requestId], request.phoneID == phoneID else { return false }
        if kind == FolderKind.placesError {
            let code = (try? JSONDecoder().decode(PlacesErrorPayload.self, from: payload))?.code ?? FolderCode.invalidMessage
            finish(probe.requestId, .code(code))
            return true
        }
        if request.answer(kind, payload) {
            finish(probe.requestId, nil)
        } else if requests[probe.requestId] != nil {
            arm(request)
        }
        return true
    }

    /// The phone disconnected: its requests fail now instead of after 8 seconds.
    func phoneDisconnected(_ phoneID: String) {
        for (id, request) in requests where request.phoneID == phoneID { finish(id, .notConnected) }
        for (key, job) in thumbJobs where job.phoneID == phoneID {
            thumbJobs.removeValue(forKey: key)
            job.end(.failure(.notConnected))
        }
        mediaActive[phoneID] = nil
        mediaQueue[phoneID] = nil
        mediaRetry.removeValue(forKey: phoneID)?.cancel()
        onPhonesChanged?()
    }

    // MARK: Listing

    func places(phoneID: String, completion: @escaping (Result<PhoneBrowseInfo, PhoneFilesError>) -> Void) {
        let id = makeID()
        browse(phoneID, kind: FolderKind.placesList, id: id, payload: encode(BrowsePlacesListPayload(requestId: id)), answer: { kind, data in
            guard kind == FolderKind.placesListed else { return false }
            if let listed = try? JSONDecoder().decode(BrowsePlacesListedPayload.self, from: data), listed.isValid {
                completion(.success(listed.info))
            } else {
                completion(.failure(.code(FolderCode.invalidMessage)))
            }
            return true
        }, fail: { completion(.failure($0)) })
    }

    func listFiles(phoneID: String, placeId: String, path: String, sort: PhoneFileSort, descending: Bool, cursor: String?,
                   completion: @escaping (Result<PhoneFilesPage, PhoneFilesError>) -> Void) {
        guard FolderJSON.isPlaceID(placeId), FolderPaths.isValidExistingPath(path) else { return completion(.failure(.code(FolderCode.invalidMessage))) }
        let id = makeID()
        let payload = PlacesFilesPayload(requestId: id, placeId: placeId, path: path, cursor: cursor, sort: sort.rawValue, descending: descending)
        browse(phoneID, kind: BrowseKind.placesFiles, id: id, payload: encode(payload), answer: { kind, data in
            guard kind == BrowseKind.placesFilesPage else { return false }
            if let page = try? JSONDecoder().decode(PlacesFilesPagePayload.self, from: data), page.placeId == placeId, page.path == path,
               let result = page.page() {
                completion(.success(result))
            } else {
                completion(.failure(.code(FolderCode.invalidMessage)))
            }
            return true
        }, fail: { completion(.failure($0)) })
    }

    func listMedia(phoneID: String, kind mediaKind: PhoneMediaKind, cursor: String?, limit: Int,
                   completion: @escaping (Result<PhoneMediaPage, PhoneFilesError>) -> Void) {
        let id = makeID()
        let payload = MediaListPayload(requestId: id, kind: mediaKind.rawValue, cursor: cursor, limit: min(max(limit, 1), BrowseLimits.maxListLimit))
        browse(phoneID, kind: BrowseKind.mediaList, id: id, payload: encode(payload), answer: { kind, data in
            guard kind == BrowseKind.mediaPage else { return false }
            if let page = try? JSONDecoder().decode(MediaPagePayload.self, from: data), page.kind == mediaKind.rawValue, let result = page.page() {
                completion(.success(result))
            } else {
                completion(.failure(.code(FolderCode.invalidMessage)))
            }
            return true
        }, fail: { completion(.failure($0)) })
    }

    // MARK: Thumbnails

    private final class ThumbJob {
        let phoneID: String
        let deliver: (PhoneFileEntry, PhoneImage) -> Void
        let finished: (Result<[PhoneFileEntry], PhoneFilesError>) -> Void
        var requestIDs: [String] = []
        var remaining = 0
        var missing: [PhoneFileEntry] = []
        var ended = false

        init(phoneID: String, deliver: @escaping (PhoneFileEntry, PhoneImage) -> Void,
             finished: @escaping (Result<[PhoneFileEntry], PhoneFilesError>) -> Void) {
            self.phoneID = phoneID
            self.deliver = deliver
            self.finished = finished
        }

        func end(_ result: Result<[PhoneFileEntry], PhoneFilesError>) {
            guard !ended else { return }
            ended = true
            finished(result)
        }
    }

    private var thumbJobs: [String: ThumbJob] = [:]

    @discardableResult
    func thumbnails(phoneID: String, entries: [PhoneFileEntry], size: (PhoneFileEntry) -> Int, lane: String,
                    deliver: @escaping (PhoneFileEntry, PhoneImage) -> Void,
                    finished: @escaping (Result<[PhoneFileEntry], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        let laneKey = "\(phoneID)\u{1F}\(lane)"
        if let previous = thumbJobs.removeValue(forKey: laneKey) { stop(previous) }
        let wanted = entries.filter(\.hasThumbnail)
        let job = ThumbJob(phoneID: phoneID, deliver: deliver, finished: finished)
        job.missing = entries.filter { !$0.hasThumbnail }
        if let problem = availability(phoneID) {
            job.end(.failure(problem))
            return .none
        }
        guard !wanted.isEmpty else {
            job.end(.success(job.missing))
            return .none
        }
        thumbJobs[laneKey] = job
        // One request per size (in order of first appearance, so visible items lead), at most 64 items each.
        var groups: [(pixels: Int, entries: [PhoneFileEntry])] = []
        for entry in wanted {
            let pixels = min(max(size(entry), BrowseLimits.minThumbnailSize), BrowseLimits.maxThumbnailSize)
            if let index = groups.firstIndex(where: { $0.pixels == pixels }) {
                groups[index].entries.append(entry)
            } else {
                groups.append((pixels, [entry]))
            }
        }
        var chunks: [(pixels: Int, entries: [PhoneFileEntry])] = []
        for group in groups {
            var index = 0
            while index < group.entries.count {
                chunks.append((group.pixels, Array(group.entries[index..<min(index + BrowseLimits.maxThumbnailItems, group.entries.count)])))
                index += BrowseLimits.maxThumbnailItems
            }
        }
        job.remaining = chunks.count
        for (pixels, chunk) in chunks {
            let id = makeID()
            var byKey: [String: PhoneFileEntry] = [:]
            let items = chunk.enumerated().map { offset, entry -> ThumbnailItemPayload in
                let key = "k\(offset)"
                byKey[key] = entry
                return ThumbnailItemPayload(key: key, ref: WireRef(entry.ref))
            }
            job.requestIDs.append(id)
            media(phoneID, kind: BrowseKind.mediaThumbnails, id: id,
                  payload: encode(MediaThumbnailsPayload(requestId: id, items: items, size: pixels, replaces: nil)),
                  answer: { [weak self, weak job] kind, data in
                      guard kind == BrowseKind.mediaThumbnailsBatch else { return false }
                      guard let job, !job.ended else { return true }
                      guard let batch = try? JSONDecoder().decode(MediaThumbnailsBatchPayload.self, from: data) else {
                          byKey.values.forEach { job.missing.append($0) }
                          self?.chunkDone(job, laneKey: laneKey)
                          return true
                      }
                      for thumb in batch.thumbs {
                          guard let entry = byKey.removeValue(forKey: thumb.key) else { continue }
                          guard let bytes = Data(base64Encoded: thumb.data), bytes.count <= BrowseLimits.maxThumbnailBytes,
                                thumb.width > 0, thumb.height > 0, thumb.mimeType.hasPrefix("image/") else {
                              job.missing.append(entry)
                              continue
                          }
                          job.deliver(entry, PhoneImage(data: bytes, mimeType: thumb.mimeType, width: thumb.width, height: thumb.height,
                                                        tint: BrowseColor.tint(thumb.tint)))
                      }
                      for key in batch.missing ?? [] {
                          if let entry = byKey.removeValue(forKey: key) { job.missing.append(entry) }
                      }
                      guard batch.done else { return false }
                      // Keys the phone never mentioned count as missing.
                      job.missing.append(contentsOf: byKey.values)
                      byKey.removeAll()
                      self?.chunkDone(job, laneKey: laneKey)
                      return true
                  },
                  fail: { [weak self, weak job] error in
                      guard let self, let job, !job.ended else { return }
                      if error == .cancelled { return }
                      // One chunk failing ends the job: the window asks again when it scrolls.
                      if self.thumbJobs[laneKey] === job { self.thumbJobs.removeValue(forKey: laneKey) }
                      self.stop(job, ending: .failure(error))
                  })
        }
        return PhoneFilesCancellable { [weak self, weak job] in
            guard let self, let job else { return }
            if self.thumbJobs[laneKey] === job { self.thumbJobs.removeValue(forKey: laneKey) }
            self.stop(job)
        }
    }

    private func chunkDone(_ job: ThumbJob, laneKey: String) {
        job.remaining -= 1
        guard job.remaining <= 0 else { return }
        if thumbJobs[laneKey] === job { thumbJobs.removeValue(forKey: laneKey) }
        job.end(.success(job.missing))
    }

    /// Cancels what is still out on the phone or queued here, and ends the job as cancelled.
    private func stop(_ job: ThumbJob, ending result: Result<[PhoneFileEntry], PhoneFilesError> = .failure(.cancelled)) {
        guard !job.ended else { return }
        job.end(result)
        for id in job.requestIDs { cancelRequest(id) }
    }

    // MARK: Preview and range

    @discardableResult
    func preview(phoneID: String, entry: PhoneFileEntry, size: Int,
                 completion: @escaping (Result<PhoneImage, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        let id = makeID()
        let pixels = min(max(size, BrowseLimits.minPreviewSize), BrowseLimits.maxPreviewSize)
        var parts: [Data] = []
        var total = 0
        var head: MediaPreviewPartPayload?
        var done = false
        let complete: (Result<PhoneImage, PhoneFilesError>) -> Void = { result in
            guard !done else { return }
            done = true
            completion(result)
        }
        media(phoneID, kind: BrowseKind.mediaPreview, id: id,
              payload: encode(MediaPreviewPayload(requestId: id, ref: WireRef(entry.ref), size: pixels, replaces: nil)),
              answer: { kind, data in
                  guard kind == BrowseKind.mediaPreviewPart else { return false }
                  guard let part = try? JSONDecoder().decode(MediaPreviewPartPayload.self, from: data), let bytes = Data(base64Encoded: part.data),
                        part.index == parts.count, part.count >= 1, part.count <= BrowseLimits.maxPreviewBytes / BrowseLimits.maxPartData + 1,
                        bytes.count <= BrowseLimits.maxPartData, total + bytes.count <= BrowseLimits.maxPreviewBytes,
                        head == nil || head?.count == part.count else {
                      complete(.failure(.code(FolderCode.invalidMessage)))
                      return true
                  }
                  if head == nil { head = part }
                  parts.append(bytes)
                  total += bytes.count
                  guard parts.count == part.count, let first = head else { return false }
                  var image = Data(capacity: total)
                  parts.forEach { image.append($0) }
                  complete(.success(PhoneImage(data: image, mimeType: first.mimeType, width: first.width, height: first.height,
                                               tint: BrowseColor.tint(first.tint))))
                  return true
              },
              fail: { complete(.failure($0)) })
        return PhoneFilesCancellable { [weak self] in self?.cancelRequest(id) }
    }

    @discardableResult
    func range(phoneID: String, entry: PhoneFileEntry, offset: Int64, length: Int64,
               progress: @escaping (Int64) -> Void,
               completion: @escaping (Result<Data, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        guard offset >= 0, length > 0, !entry.isDirectory else {
            completion(.failure(.code(FolderCode.invalidMessage)))
            return .none
        }
        var received = Data()
        var done = false
        var currentID: String?
        let expectedSize = entry.size
        let expectedModified = entry.modified.map(BrowseTime.millis)
        let complete: (Result<Data, PhoneFilesError>) -> Void = { result in
            guard !done else { return }
            done = true
            completion(result)
        }
        // Ranges over 4 MiB go as several requests, one after another.
        func next() {
            let start = offset + Int64(received.count)
            let remaining = length - Int64(received.count)
            guard remaining > 0 else { return complete(.success(received)) }
            let id = makeID()
            currentID = id
            let piece = min(remaining, BrowseLimits.maxRangeLength)
            var expectedOffset = start
            media(phoneID, kind: BrowseKind.mediaRange, id: id,
                  payload: encode(MediaRangePayload(requestId: id, ref: WireRef(entry.ref), offset: start, length: piece, replaces: nil)),
                  answer: { kind, data in
                      guard kind == BrowseKind.mediaRangePart else { return false }
                      guard let part = try? JSONDecoder().decode(MediaRangePartPayload.self, from: data), let bytes = Data(base64Encoded: part.data),
                            part.offset == expectedOffset, bytes.count <= BrowseLimits.maxPartData,
                            Int64(bytes.count) <= start + piece - expectedOffset else {
                          complete(.failure(.code(FolderCode.invalidMessage)))
                          return true
                      }
                      if let expectedSize, part.fileSize != expectedSize {
                          complete(.failure(.code(FolderCode.sourceChanged)))
                          return true
                      }
                      if let expectedModified, let modified = part.modified, abs(modified - expectedModified) > 1_000 {
                          complete(.failure(.code(FolderCode.sourceChanged)))
                          return true
                      }
                      received.append(bytes)
                      expectedOffset += Int64(bytes.count)
                      progress(Int64(received.count))
                      let endOfFile = expectedOffset >= part.fileSize
                      guard part.last || expectedOffset >= start + piece else { return false }
                      if endOfFile || expectedOffset < start + piece {
                          // The file ended before the range did.
                          complete(.success(received))
                      } else {
                          DispatchQueue.main.async { next() }
                      }
                      return true
                  },
                  fail: { complete(.failure($0)) })
        }
        next()
        return PhoneFilesCancellable { [weak self] in
            if let id = currentID { self?.cancelRequest(id) }
            complete(.failure(.cancelled))
        }
    }

    // MARK: Downloads and uploads

    @discardableResult
    func download(phoneID: String, refs: [PhoneRef], into directory: URL, purpose: PhoneDownloadPurpose,
                  progress: @escaping (PhoneTransferProgress) -> Void,
                  completion: @escaping (Result<[URL], PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        guard !refs.isEmpty, refs.count <= BrowseLimits.maxDownloadItems else {
            completion(.failure(.code(FolderCode.limitExceeded)))
            return .none
        }
        if let problem = availability(phoneID) {
            completion(.failure(problem))
            return .none
        }
        let id = makeID()
        let expected = ExpectedDownload(requestId: id, phoneID: phoneID, directory: directory, purpose: purpose, progress: progress, completion: completion)
        // Registered first: the offer follows places.download_started on the same socket.
        host?.expectDownload(expected)
        progress(PhoneTransferProgress(phase: .preparing))
        browse(phoneID, kind: BrowseKind.placesDownload, id: id, payload: encode(PlacesDownloadPayload(requestId: id, items: refs.map(WireRef.init))),
               answer: { kind, data in
                   guard kind == BrowseKind.placesDownloadStarted else { return false }
                   guard let started = try? JSONDecoder().decode(PlacesDownloadStartedPayload.self, from: data), FolderJSON.isWireID(started.folderTransferId) else {
                       expected.finish(.failure(.code(FolderCode.invalidMessage)))
                       return true
                   }
                   expected.folderTransferId = started.folderTransferId
                   var update = PhoneTransferProgress(phase: .preparing)
                   update.filesTotal = started.fileCount
                   update.bytesTotal = started.totalSize
                   if !expected.isFinished { expected.progress(update) }
                   return true
               },
               fail: { [weak self] error in
                   self?.host?.cancelDownload(expected)
                   expected.finish(.failure(error))
               })
        return PhoneFilesCancellable { [weak self] in
            expected.cancelled = true
            self?.finish(id, nil)
            self?.host?.cancelDownload(expected)
            expected.finish(.failure(.cancelled))
        }
    }

    @discardableResult
    func upload(phoneID: String, urls: [URL], placeId: String, path: String,
                progress: @escaping (PhoneTransferProgress) -> Void,
                completion: @escaping (Result<Void, PhoneFilesError>) -> Void) -> PhoneFilesCancellable {
        guard !urls.isEmpty, FolderJSON.isPlaceID(placeId), FolderPaths.isValidExistingPath(path) else {
            completion(.failure(.code(FolderCode.invalidMessage)))
            return .none
        }
        if let problem = availability(phoneID) {
            completion(.failure(problem))
            return .none
        }
        let request = UploadRequest(phoneID: phoneID, urls: urls, destination: FolderDestination(placeId: placeId, path: path),
                                    progress: progress, completion: completion)
        guard let id = host?.startUpload(request) else { return .none }
        return PhoneFilesCancellable { [weak self] in self?.host?.cancelUpload(id) }
    }
}

/// LAN or not, from the phone's address. Hover prefetch runs on LAN only; relay and metered routes come later.
enum PhoneRouteClassifier {
    static func route(host: String?) -> PhoneRoute {
        guard var host = host?.lowercased(), !host.isEmpty else { return .unknown }
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".local") { return .lan }
        if host.hasPrefix("::ffff:") { host = String(host.dropFirst(7)) }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168), (169, 254): return .lan
            case (172, 16...31): return .lan
            // Tailscale and other carrier-grade NAT addresses: a VPN route, not the local network.
            case (100, 64...127): return .relay
            default: return .unknown
            }
        }
        if host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc") { return host.hasPrefix("fd7a:115c:a1e0") ? .relay : .lan }
        return .unknown
    }
}
