import Foundation

// Section 4.5, sender side of places.*: requests by requestId, answered within 8 seconds or failed with
// `timeout` ("OnePlus 11 did not answer"). Used on the main thread; the clock is injected for tests.

enum PlacesFailure: Error, Equatable {
    /// No answer within 8 seconds.
    case timeout
    /// places.error with its code.
    case code(String)
    /// The phone is not connected (or does not serve places).
    case notConnected
}

final class PlacesClient {
    typealias Send = (_ kind: String, _ payload: Data) -> Bool

    private struct Pending {
        let phoneID: String
        let expects: String
        let timer: FolderTimer
        let complete: (Result<Data, PlacesFailure>) -> Void
    }

    private let clock: FolderClock
    private let makeID: () -> String
    private var pending: [String: Pending] = [:]

    init(clock: FolderClock, makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.clock = clock
        self.makeID = makeID
    }

    var inFlight: Int { pending.count }

    func list(phoneID: String, send: Send, completion: @escaping (Result<PlacesListedPayload, PlacesFailure>) -> Void) {
        let id = makeID()
        request(id: id, phoneID: phoneID, kind: FolderKind.placesList, expects: FolderKind.placesListed,
                payload: PlacesListPayload(requestId: id), send: send) { result in
            completion(result.flatMap { data in
                guard let listed = try? JSONDecoder().decode(PlacesListedPayload.self, from: data), listed.isValid else {
                    return .failure(.code(FolderCode.invalidMessage))
                }
                return .success(listed)
            })
        }
    }

    func browse(phoneID: String, placeId: String, path: String, cursor: String?, send: Send,
                completion: @escaping (Result<PlacesChildrenPayload, PlacesFailure>) -> Void) {
        let id = makeID()
        request(id: id, phoneID: phoneID, kind: FolderKind.placesBrowse, expects: FolderKind.placesChildren,
                payload: PlacesBrowsePayload(requestId: id, placeId: placeId, path: path, cursor: cursor), send: send) { result in
            completion(result.flatMap { data in
                guard let children = try? JSONDecoder().decode(PlacesChildrenPayload.self, from: data),
                      children.placeId == placeId, children.folders.count <= FolderLimits.maxBrowseNames else {
                    return .failure(.code(FolderCode.invalidMessage))
                }
                return .success(children)
            })
        }
    }

    /// `name` is converted to a portable name first. The same request ID is never reused, so a double click
    /// sends two requests only if the caller lets it; the sheet disables New Folder while one is in flight.
    func createFolder(phoneID: String, placeId: String, path: String, name: String, send: Send,
                      completion: @escaping (Result<PlacesFolderCreatedPayload, PlacesFailure>) -> Void) {
        let id = makeID()
        let portable = PortableName.convert(name)
        request(id: id, phoneID: phoneID, kind: FolderKind.placesCreateFolder, expects: FolderKind.placesFolderCreated,
                payload: PlacesCreateFolderPayload(requestId: id, placeId: placeId, path: path, name: portable), send: send) { result in
            completion(result.flatMap { data in
                guard let created = try? JSONDecoder().decode(PlacesFolderCreatedPayload.self, from: data) else {
                    return .failure(.code(FolderCode.invalidMessage))
                }
                return .success(created)
            })
        }
    }

    /// An answer from the phone. Returns false when it matches no request (late, or for someone else).
    @discardableResult
    func handle(kind: String, payload: Data, from phoneID: String) -> Bool {
        guard let probe = try? JSONDecoder().decode(RequestProbe.self, from: payload),
              let request = pending[probe.requestId], request.phoneID == phoneID else { return false }
        if kind == FolderKind.placesError {
            let code = (try? JSONDecoder().decode(PlacesErrorPayload.self, from: payload))?.code ?? FolderCode.invalidMessage
            finish(probe.requestId, .failure(.code(code)))
            return true
        }
        guard kind == request.expects else { return false }
        finish(probe.requestId, .success(payload))
        return true
    }

    /// The phone disconnected: its requests fail now instead of after 8 seconds.
    func cancelAll(phoneID: String) {
        for (id, request) in pending where request.phoneID == phoneID { finish(id, .failure(.notConnected)) }
    }

    private func request<P: Encodable>(id: String, phoneID: String, kind: String, expects: String, payload: P, send: Send,
                                       completion: @escaping (Result<Data, PlacesFailure>) -> Void) {
        guard let data = try? FolderJSON.encoder.encode(payload), send(kind, data) else {
            completion(.failure(.notConnected))
            return
        }
        let timer = clock.schedule(after: FolderTimeouts.placesAnswer) { [weak self] in
            self?.finish(id, .failure(.timeout))
        }
        pending[id] = Pending(phoneID: phoneID, expects: expects, timer: timer, complete: completion)
    }

    private func finish(_ id: String, _ result: Result<Data, PlacesFailure>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        request.complete(result)
    }

    private struct RequestProbe: Decodable { let requestId: String }
}

struct PlacesFolderCreatedPayload: Codable, Equatable {
    var version = 1
    let requestId: String
    let placeId: String
    let path: String
    let name: String
}
