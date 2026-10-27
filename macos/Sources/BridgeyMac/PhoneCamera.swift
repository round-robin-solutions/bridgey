import AppIntents
import AppKit
import Foundation

/*
 * Phone camera to Mac, draft `camera_draft1` (docs/protocol.md). "Take Photo with OnePlus 11"
 * asks the phone for one photo; the phone opens its camera only when it is unlocked and the person
 * taps, and sends the JPEG back as an ordinary file marked with the request.
 */

let cameraFeatureKey = "camera_draft1"

enum CameraStatus: String, Equatable {
    case opened, locked, permissionRequired = "permission_required", cancelled, busy, disabled, sending, failed
}

@MainActor
final class PhoneCamera: ObservableObject {
    static let lifetime: TimeInterval = 120
    static let spacing: TimeInterval = 3

    struct Request: Equatable {
        let id: String
        let deviceID: String
        let at: Date
    }

    /// The open request per phone.
    @Published private(set) var pending: [String: Request] = [:]
    /// The panel's line about the latest request.
    @Published private(set) var status: String? {
        didSet { if status != oldValue { scheduleClear(status) } }
    }
    /// Files > Copy photos from the phone camera to the clipboard. Off by default.
    @Published private(set) var copyToClipboard: Bool
    /// Photos that arrived, by request ID (for the Shortcuts action that waits for one).
    private(set) var photos: [String: URL] = [:]
    /// Final statuses by request ID (for the Shortcuts action).
    private(set) var outcomes: [String: CameraStatus] = [:]

    var send: (_ deviceID: String, _ payload: [String: Any]) -> Bool = { _, _ in false }
    var copyImage: (URL) -> Void = { url in
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image, url as NSURL])
    }

    private let defaults: UserDefaults?
    private let clock: () -> Date
    private var lastRequest: [String: Date] = [:]

    init(defaults: UserDefaults? = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        copyToClipboard = defaults?.bool(forKey: "settings.camera.copyToClipboard") ?? false
    }

    func setCopyToClipboard(_ enabled: Bool) {
        defaults?.set(enabled, forKey: "settings.camera.copyToClipboard")
        copyToClipboard = enabled
    }

    /// Asks `deviceID` for a photo. Returns the request ID, or nil when one is still open or the
    /// last request was under 3 seconds ago.
    @discardableResult
    func request(from deviceID: String, phoneName: String) -> String? {
        expire()
        let now = clock()
        if pending[deviceID] != nil { status = String(format: L10n.text("camera.status.waiting", fallback: "Waiting for the photo from %@"), phoneName); return nil }
        if let last = lastRequest[deviceID], now.timeIntervalSince(last) < Self.spacing { return nil }
        let id = UUID().uuidString.lowercased()
        guard send(deviceID, ["version": 1, "requestId": id, "mode": "photo"]) else {
            status = String(format: L10n.text("camera.status.notConnected", fallback: "%@ is not connected"), phoneName)
            return nil
        }
        lastRequest[deviceID] = now
        pending[deviceID] = Request(id: id, deviceID: deviceID, at: now)
        status = String(format: L10n.text("camera.status.asked", fallback: "Take the photo on %@"), phoneName)
        return id
    }

    /// `camera.status` from a phone, for its open request only.
    func received(status wire: String, requestID: String, from deviceID: String, phoneName: String) {
        expire()
        guard let request = pending[deviceID], request.id == requestID, let value = CameraStatus(rawValue: wire) else { return }
        status = cameraStatusText(value, phone: phoneName)
        switch value {
        case .cancelled, .busy, .disabled, .failed, .permissionRequired:
            pending.removeValue(forKey: deviceID)
            outcomes[requestID] = value
        case .opened, .locked, .sending:
            break
        }
    }

    /// A files.offer from `deviceID` carries `cameraRequestId`: is it this Mac's open request?
    func matches(_ requestID: String?, from deviceID: String) -> Bool {
        expire()
        guard let requestID else { return false }
        return pending[deviceID]?.id == requestID
    }

    /// The photo was saved at `url`.
    func photoArrived(_ url: URL, requestID: String, from deviceID: String, phoneName: String) {
        guard pending[deviceID]?.id == requestID else { return }
        pending.removeValue(forKey: deviceID)
        photos[requestID] = url
        if photos.count > 8, let oldest = photos.keys.first(where: { $0 != requestID }) { photos.removeValue(forKey: oldest) }
        if copyToClipboard { copyImage(url) }
        status = copyToClipboard
            ? String(format: L10n.text("camera.status.copied", fallback: "Photo from %@ saved and copied"), phoneName)
            : String(format: L10n.text("camera.status.saved", fallback: "Photo from %@ saved"), phoneName)
    }

    func disconnected(_ deviceID: String) {
        if let request = pending.removeValue(forKey: deviceID) { outcomes[request.id] = .cancelled }
    }

    func clearStatus() { status = nil }

    /// The panel line fades after eight seconds unless something newer replaced it.
    private func scheduleClear(_ line: String?) {
        guard let line else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.status == line { self?.status = nil }
        }
    }

    private func expire() {
        let now = clock()
        for (deviceID, request) in pending where now.timeIntervalSince(request.at) >= Self.lifetime {
            pending.removeValue(forKey: deviceID)
            outcomes[request.id] = .cancelled
        }
    }
}

func cameraStatusText(_ status: CameraStatus, phone: String) -> String {
    switch status {
    case .opened: String(format: L10n.text("camera.status.opened", fallback: "The camera is open on %@"), phone)
    case .locked: String(format: L10n.text("camera.status.locked", fallback: "Unlock %@ to take the photo"), phone)
    case .permissionRequired: String(format: L10n.text("camera.status.permission", fallback: "Allow the camera in Bridgey on %@"), phone)
    case .cancelled: L10n.text("camera.status.cancelled", fallback: "Photo cancelled")
    case .busy: String(format: L10n.text("camera.status.busy", fallback: "%@ is already taking a photo"), phone)
    case .disabled: String(format: L10n.text("camera.status.disabled", fallback: "Take photos for the Mac is off on %@"), phone)
    case .sending: String(format: L10n.text("camera.status.sending", fallback: "Receiving the photo from %@"), phone)
    case .failed: L10n.text("camera.status.failed", fallback: "The photo could not be taken")
    }
}

/// Shortcuts: "Take Photo with Phone". Waits up to two minutes and returns the photo.
struct TakePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intent.camera.title", defaultValue: "Take Photo with Phone")
    static var description = IntentDescription(LocalizedStringResource("intent.camera.description", defaultValue: "Opens the camera on a paired phone and returns the photo when you take it."))
    @Parameter(title: LocalizedStringResource("intent.phone", defaultValue: "Phone"))
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let (pairing, id) = try await IntentHost.connected(phone)
        guard pairing.cameraAvailable(for: id), let requestID = pairing.takePhoto(with: id) else {
            throw IntentFailure.featureOff(L10n.text("camera.feature", fallback: "Take photos for the Mac"))
        }
        let deadline = Date().addingTimeInterval(PhoneCamera.lifetime + 5)
        while Date() < deadline {
            if let url = pairing.camera.photos[requestID] { return .result(value: IntentFile(fileURL: url)) }
            if pairing.camera.outcomes[requestID] != nil { throw IntentFailure.failed }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw IntentFailure.failed
    }
}
