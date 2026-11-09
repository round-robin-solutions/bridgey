import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import UserNotifications

@MainActor
final class StoreConnection: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published var peers: [NetService] = []
    @Published var status = "Pair your phone on the same Wi-Fi network."
    @Published var verification: String?
    @Published var connected = false
    @Published var clipboardEnabled = false
    @Published var notificationsEnabled = false
    @Published var filesEnabled = false
    @Published var receivedClipboard: String?
    @Published var pendingFile: StoreFileOffer?
    @Published var receivedFiles: [URL] = []
    @Published var transferStatus = ""
    @Published var armedUntil: Date?
    @Published private(set) var remoteFeatures: [String: Bool] = [:]
    var filesReady: Bool { connected && filesEnabled && remoteFeatures["files"] == true }
    var clipboardReady: Bool { connected && clipboardEnabled && remoteFeatures["clipboard"] == true }
    var files: StoreFiles!
    var identity: StoreIdentity?
    private var browser = NetServiceBrowser()
    private var published: NetService?
    private var listener: NWListener?
    private var session: StoreSession?
    private var subscription: AnyCancellable?
    private var resolved: [NetService] = []
    private var attempts: [Date] = []
    private var clipboardTask: Task<Void, Never>?
    private var clipboardChange = NSPasteboard.general.changeCount

    init(startNetworking: Bool = true) {
        super.init()
        files = StoreFiles(owner: self)
        guard startNetworking else { return }
        do { identity = try StoreIdentity.load() } catch { status = "Pairing storage could not be opened. Restart Bridgey or contact support."; return }
        browser.delegate = self
        browser.searchForServices(ofType: "_bridgey._tcp.", inDomain: "local.")
        do {
            // An allocated port lets the two editions coexist. Bonjour advertises this port.
            let listener = try NWListener(using: .tcp)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state, let port = listener?.port { self.publish(port: port) }
                    if case .failed = state { self.status = "Local network access is unavailable. Check System Settings." }
                }
            }
            listener.start(queue: .main)
        } catch { status = "Bridgey could not listen on the local network." }
        subscription = Publishers.CombineLatest3($clipboardEnabled, $filesEnabled, $notificationsEnabled).dropFirst().sink { [weak self] _ in
            // A UI toggle must update the advertised map after its new value is stored.
            DispatchQueue.main.async { self?.sendFeatures(); self?.refreshClipboardSync() }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name != published?.name else { return }
        service.delegate = self; resolved.append(service); service.resolve(withTimeout: 5)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        guard let platform = txt["platform"].flatMap({ String(data: $0, encoding: .utf8) }), platform == "android" else { return }
        if !peers.contains(where: { $0.name == sender.name }) { peers.append(sender) }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        peers.removeAll { $0.name == service.name }; resolved.removeAll { $0.name == service.name }
    }
    private func publish(port: NWEndpoint.Port) {
        guard let identity else { return }
        let service = NetService(domain: "local.", type: "_bridgey._tcp.", name: "Bridgey-\(identity.deviceID.prefix(8))-Store", port: Int32(port.rawValue))
        service.setTXTRecord(NetService.data(fromTXTRecord: ["id": Data(identity.deviceID.utf8), "name": Data("Bridgey Store on Mac".utf8), "platform": Data("macos".utf8), "version": Data("1".utf8)]))
        published = service; service.publish()
    }
    func arm() { armedUntil = Date().addingTimeInterval(120); status = "Allow pairing for 2 minutes. Compare the code on both devices." }
    func pair(_ peer: NetService) {
        guard let host = peer.hostName, let port = NWEndpoint.Port(rawValue: UInt16(peer.port)), identity != nil else { return }
        disconnect()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let next = StoreSession(connection: connection, initiated: true)
        next.id = UUID().uuidString.lowercased()
        session = next; status = "Connecting to your phone..."; start(next)
    }
    private func accept(_ connection: NWConnection) {
        guard identity != nil, session == nil else { connection.cancel(); return }
        attempts.removeAll { Date().timeIntervalSince($0) > 120 }
        guard attempts.count < 5 else { connection.cancel(); return }
        attempts.append(Date())
        let next = StoreSession(connection: connection, initiated: false); session = next; start(next)
    }
    private func start(_ next: StoreSession) {
        next.connection.stateUpdateHandler = { [weak self, weak next] state in
            Task { @MainActor in
                guard let self, let next, self.session === next else { return }
                switch state {
                case .ready:
                    if next.initiated, let identity = self.identity {
                        self.send(PairingMessage(kind: "pairing.offer", sessionId: next.id, deviceId: identity.deviceID,
                            deviceName: "Bridgey Store on Mac", commitment: SessionSecurity.commitment(sessionID: next.id, publicKey: next.publicKey), protocolVersion: 2))
                    }
                    self.read(next)
                case .failed, .cancelled: self.disconnect()
                default: break
                }
            }
        }
        next.connection.start(queue: .main)
        Task { @MainActor [weak self, weak next] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if let self, let next, self.session === next, !next.authenticated { self.disconnect(); self.status = "Pairing timed out. Try again." }
        }
    }
    private func read(_ current: StoreSession) {
        current.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak current] data, _, complete, error in
            Task { @MainActor in
                guard let self, let current, self.session === current else { return }
                do {
                    if let data {
                        current.reader.append(data)
                        while let message = try current.reader.next() { try self.receive(message, current) }
                    }
                    if complete || error != nil { self.disconnect() } else { self.read(current) }
                } catch { self.disconnect(); self.status = "The connection could not be verified. Pair again." }
            }
        }
    }
    func send(_ message: PairingMessage, completion: (() -> Void)? = nil) {
        guard let current = session, let identity else { return }
        var message = message
        if let key = current.key, !SessionSecurity.allowedBeforeAuthentication(message.kind) || message.kind == "pairing.cancel" { message.tag = SessionSecurity.tag(envelopeKey: SessionSecurity.envelopeKey(sessionKey: key), senderDeviceID: identity.deviceID, message: message) }
        guard var data = try? JSONEncoder().encode(message), data.count <= maximumProtocolFrameBytes else { return }
        data.append(10)
        current.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                if error != nil { self?.disconnect() } else { completion?() }
            }
        })
    }
    func encrypted(_ kind: String, data: Data, transfer: String? = nil, sequence: Int64? = nil, completion: (() -> Void)? = nil) {
        guard let current = session, current.authenticated, let key = current.key, let box = try? encrypt(data, key: key) else { return }
        send(PairingMessage(kind: kind, sessionId: current.id, messageId: UUID().uuidString.lowercased(), nonce: box.nonce, ciphertext: box.ciphertext, transferId: transfer, sequence: sequence), completion: completion)
    }
    func control(_ kind: String, transfer: String? = nil, sequence: Int64? = nil, messageID: String? = nil) {
        guard let current = session, current.authenticated else { return }
        send(PairingMessage(kind: kind, sessionId: current.id, messageId: messageID, transferId: transfer, sequence: sequence))
    }
    private func receive(_ message: PairingMessage, _ current: StoreSession) throws {
        guard let identity else { throw PairingError.invalidMessage }
        if message.kind == "pairing.offer" {
            guard !current.initiated, current.id.isEmpty, !current.authenticated,
                  let remoteID = message.deviceId, UUID(uuidString: remoteID) != nil, remoteID != identity.deviceID,
                  message.targetDeviceId == nil || message.targetDeviceId == identity.deviceID,
                  (message.protocolVersion ?? 1) >= 2 else { throw PairingError.invalidMessage }
            current.id = message.sessionId; current.remoteID = remoteID
            current.commitment = message.commitment
            if let commitment = current.commitment {
                guard Data(base64Encoded: commitment)?.count == 32, (armedUntil ?? .distantPast) > Date() else { throw PairingError.invalidMessage }
            } else {
                guard identity.trusted[remoteID] != nil, let remoteKey = message.publicKey else { throw PairingError.invalidMessage }
                current.remoteKey = remoteKey; try derive(current, committed: false)
            }
            send(PairingMessage(kind: "pairing.answer", sessionId: current.id, deviceId: identity.deviceID, deviceName: "Bridgey Store on Mac", publicKey: current.publicKey, protocolVersion: 2))
            if current.key != nil { confirm() }
            return
        }
        guard !current.id.isEmpty, message.sessionId == current.id else { throw PairingError.invalidMessage }
        if message.kind == "pairing.answer" {
            guard current.initiated, current.key == nil, (message.protocolVersion ?? 1) >= 2,
                  let remoteID = message.deviceId, UUID(uuidString: remoteID) != nil, remoteID != identity.deviceID,
                  let remoteKey = message.publicKey else { throw PairingError.invalidMessage }
            current.remoteID = remoteID; current.remoteKey = remoteKey
            try derive(current, committed: true)
            send(PairingMessage(kind: "pairing.reveal", sessionId: current.id, publicKey: current.publicKey))
            verification = current.code; status = "Compare this code with your phone."
            return
        }
        if message.kind == "pairing.reveal" {
            guard !current.initiated, current.key == nil, let commitment = current.commitment,
                  let remoteKey = message.publicKey, SessionSecurity.commitmentMatches(commitment, sessionID: current.id, publicKey: remoteKey) else { throw PairingError.invalidMessage }
            current.remoteKey = remoteKey; try derive(current, committed: true)
            verification = current.code; status = "Compare this code with your phone."
            return
        }
        if message.kind == "pairing.confirm" {
            guard !current.authenticated, !current.remoteConfirmed, let key = current.key,
                  message.deviceId == current.remoteID, let publicText = message.identityKey,
                  identity.trusted[current.remoteID].map({ $0 == publicText }) ?? true,
                  let proof = message.proof, verifyConfirmationProof(proof, key: key, sessionID: current.id, deviceID: current.remoteID, identityKey: publicText),
                  let publicData = Data(base64Encoded: publicText), let signatureData = message.signature.flatMap({ Data(base64Encoded: $0) }),
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: publicData),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
                  publicKey.isValidSignature(signature, for: transcript(current)) else { throw PairingError.invalidMessage }
            current.remoteIdentity = publicText; current.remoteConfirmed = true; try complete(current); return
        }
        guard let key = current.key else { throw PairingError.invalidMessage }
        guard current.authenticated, SessionSecurity.tagMatches(envelopeKey: SessionSecurity.envelopeKey(sessionKey: key), senderDeviceID: current.remoteID, message: message) else { throw PairingError.invalidMessage }
        if message.kind == "pairing.cancel" { disconnect(); return }
        // Unknown and excluded capabilities are never dispatched, even if a trusted phone sends them.
        guard StorePolicy.permits(message.kind) else { return }
        if message.kind == "heartbeat.ping" { control("heartbeat.pong", messageID: message.messageId); return }
        if ["features.update", "clipboard.update", "clipboard.rich", "notifications.post", "notifications.remove", "files.offer", "files.chunk", "files.complete"].contains(message.kind) {
            guard let id = message.messageId, !id.isEmpty, current.replay.accept(id), let nonce = message.nonce, let ciphertext = message.ciphertext else { throw PairingError.invalidMessage }
            let plaintext = try decrypt(nonce: nonce, ciphertext: ciphertext, key: key)
            try payload(message, plaintext)
        } else if message.kind.hasPrefix("files.") { try files.control(message) }
    }
    private func derive(_ current: StoreSession, committed: Bool) throws {
        let keys = current.initiated ? (current.publicKey, current.remoteKey) : (current.remoteKey, current.publicKey)
        let material = try pairingMaterial(privateKey: current.privateKey, remoteKey: current.remoteKey, sessionID: current.id, sasKeys: committed ? keys : nil)
        current.key = material.key; current.code = material.code
    }
    private func transcript(_ current: StoreSession) -> Data {
        let fields = current.initiated ? [identity!.deviceID, current.remoteID, current.publicKey, current.remoteKey] : [current.remoteID, identity!.deviceID, current.remoteKey, current.publicKey]
        return Data((["bridgey-auth-v1", current.id] + fields).joined(separator: "\0").utf8)
    }
    func confirm() {
        guard let current = session, !current.localConfirmed, let key = current.key, let identity,
              let signing = try? P256.Signing.PrivateKey(rawRepresentation: identity.key),
              let signature = try? signing.signature(for: transcript(current)) else { return }
        let publicKey = signing.publicKey.x963Representation.base64EncodedString()
        current.localConfirmed = true
        send(PairingMessage(kind: "pairing.confirm", sessionId: current.id, deviceId: identity.deviceID, identityKey: publicKey,
                           proof: confirmationProof(key: key, sessionID: current.id, deviceID: identity.deviceID, identityKey: publicKey), signature: signature.derRepresentation.base64EncodedString()))
        do { try complete(current) } catch { disconnect(); status = "Pairing could not be saved. Try again." }
    }
    private func complete(_ current: StoreSession) throws {
        guard current.localConfirmed, current.remoteConfirmed, let remoteIdentity = current.remoteIdentity else { return }
        guard var value = identity else { throw PairingError.invalidMessage }
        value.trusted[current.remoteID] = remoteIdentity
        try value.save(); identity = value
        current.authenticated = true; verification = nil; armedUntil = nil; connected = true; status = "Phone connected."
        sendFeatures(); refreshClipboardSync()
    }
    func disconnect() {
        clipboardTask?.cancel(); clipboardTask = nil
        let old = session; session = nil; old?.connection.cancel()
        files?.cancel(); remoteFeatures = [:]; pendingFile = nil; verification = nil; connected = false; status = "Phone disconnected."
    }
    func forget() {
        guard let remote = session?.remoteID, var value = identity else { return }
        value.trusted.removeValue(forKey: remote)
        do { try value.save(); identity = value; disconnect() } catch { status = "Could not forget this phone. Try again." }
    }
    private func sendFeatures() {
        guard connected else { return }
        var features = StorePolicy.features
        features["clipboard"] = clipboardEnabled; features["files"] = filesEnabled; features["notifications"] = notificationsEnabled
        if let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "features": features]) { encrypted("features.update", data: data) }
    }
    func sendClipboard() {
        guard clipboardReady, let text = NSPasteboard.general.string(forType: .string), clipboardTextFits(text) else { status = "Copy some text first (up to 32 KB)."; return }
        encrypted("clipboard.update", data: Data(text.utf8)); status = "Clipboard sent to your phone."
    }
    func copyReceived() {
        guard let text = receivedClipboard else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        clipboardChange = NSPasteboard.general.changeCount; receivedClipboard = nil
    }
    private func refreshClipboardSync() {
        guard connected, clipboardEnabled else { clipboardTask?.cancel(); clipboardTask = nil; return }
        guard clipboardTask == nil else { return }
        clipboardChange = NSPasteboard.general.changeCount
        clipboardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
                guard let self, self.connected, self.clipboardEnabled else { return }
                let board = NSPasteboard.general
                guard board.changeCount != self.clipboardChange else { continue }
                self.clipboardChange = board.changeCount
                guard self.clipboardReady, !clipboardTypesAreSecret((board.types ?? []).map(\.rawValue)),
                      let text = board.string(forType: .string), clipboardTextFits(text) else { continue }
                self.encrypted("clipboard.update", data: Data(text.utf8))
            }
        }
    }
    func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsEnabled = granted }
        }
    }
    private func payload(_ message: PairingMessage, _ data: Data) throws {
        switch message.kind {
        case "features.update":
            let state = try JSONDecoder().decode(StoreFeatureState.self, from: data)
            guard state.version == 1 else { return }
            guard ["clipboard", "files", "notifications", "battery", "find_device"].allSatisfy({ state.features[$0] != nil }) else { throw PairingError.invalidMessage }
            remoteFeatures = state.features
        case "clipboard.update", "clipboard.rich":
            guard clipboardReady else { control("clipboard.rejected", messageID: message.messageId); return }
            let text: String?
            if message.kind == "clipboard.rich" { text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String }
            else { text = String(data: data, encoding: .utf8) }
            guard let text, text.utf8.count <= 32_768 else { throw PairingError.invalidMessage }
            receivedClipboard = text; copyReceived(); control("clipboard.ack", messageID: message.messageId)
        case "notifications.post":
            guard notificationsEnabled, remoteFeatures["notifications"] == true else { return }
            let item = try JSONDecoder().decode(StoreNotification.self, from: data)
            let content = UNMutableNotificationContent()
            content.title = String(item.applicationName.prefix(128)); content.subtitle = String(item.title.prefix(256)); content.body = String(item.text.prefix(2048))
            // Display only: no notification actions, SMS replies or arbitrary URL launch.
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(session!.remoteID):\(item.notificationId)", content: content, trigger: nil))
        case "notifications.remove":
            guard let reference = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let id = reference["notificationId"] as? String else { throw PairingError.invalidMessage }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(session!.remoteID):\(id)"])
        case "files.offer", "files.chunk", "files.complete": try files.payload(message, data)
        default: break
        }
    }
}

private struct StoreFeatureState: Decodable { let version: Int; let features: [String: Bool] }

private struct StoreNotification: Decodable {
    let notificationId: String
    let applicationName: String
    let title: String
    let text: String
}

@MainActor
private final class StoreSession {
    let connection: NWConnection
    let initiated: Bool
    let privateKey = P256.KeyAgreement.PrivateKey()
    var publicKey: String { privateKey.publicKey.x963Representation.base64EncodedString() }
    var id = ""
    var remoteID = ""
    var remoteKey = ""
    var remoteIdentity: String?
    var commitment: String?
    var key: Data?
    var code = ""
    var localConfirmed = false
    var remoteConfirmed = false
    var authenticated = false
    var reader = ProtocolFrameReader()
    var replay = ReplayWindow()
    init(connection: NWConnection, initiated: Bool) { self.connection = connection; self.initiated = initiated }
}
