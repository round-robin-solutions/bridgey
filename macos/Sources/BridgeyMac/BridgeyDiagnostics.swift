import Foundation

struct BridgeyDiagnosticEvent: Codable, Equatable {
    let timestamp: String
    let category: String
    let event: String
    let outcome: String
    /// The first eight characters of the device id, for connection events.
    var device: String? = nil
    /// A short normalized detail such as an attempt number, an address source or a reason.
    var detail: String? = nil
}

/// A bounded log of what happened, for the exported diagnostics report. Only normalized tokens
/// are stored: never names, clipboard or notification text, file names or network addresses.
/// With a `fileURL` the events survive a restart of the app, so a report exported the next
/// morning still shows the night's drops and retries.
final class BridgeyDiagnostics {
    private let limit: Int
    private var events: [BridgeyDiagnosticEvent] = []
    private let formatter = ISO8601DateFormatter()
    private let fileURL: URL?
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "in.roundrobin.bridgey.diagnostics")

    init(limit: Int = 200, fileURL: URL? = nil) {
        self.limit = limit
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([BridgeyDiagnosticEvent].self, from: data) {
            events = Array(stored.suffix(limit))
        }
    }

    func record(category: String, event: String, outcome: String = "ok", device: String? = nil, detail: String? = nil) {
        events.append(BridgeyDiagnosticEvent(
            timestamp: formatter.string(from: Date()),
            category: token(category),
            event: token(event),
            outcome: token(outcome),
            device: device.map { token(String($0.prefix(8))) },
            detail: detail.map(token)
        ))
        if events.count > limit { events.removeFirst(events.count - limit) }
        scheduleSave()
    }

    func snapshot() -> [BridgeyDiagnosticEvent] { events }

    func report(
        connectionState: String,
        transfers: [FileTransferRow],
        localFeatures: [BridgeyFeature: Bool],
        remoteFeatures: [BridgeyFeature: Bool],
        devices: [[String: Any]] = []
    ) throws -> Data {
        let featureObject: ([BridgeyFeature: Bool]) -> [String: Bool] = { features in
            Dictionary(uniqueKeysWithValues: BridgeyFeature.allCases.map { ($0.rawValue, features[$0] != false) })
        }
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "generatedAt": formatter.string(from: Date()),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "platform": "macos",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "connectionState": token(connectionState),
            "activeTransferCount": transfers.filter { $0.active }.count,
            "historyCount": transfers.filter { !$0.active }.count,
            "localFeatures": featureObject(localFeatures),
            "remoteFeatures": featureObject(remoteFeatures),
            "devices": devices,
            "events": try events.map { event in
                let data = try JSONEncoder().encode(event)
                return try JSONSerialization.jsonObject(with: data)
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes at most every two seconds, off the main thread.
    private func scheduleSave() {
        guard let fileURL, saveWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWorkItem = nil
            guard let data = try? JSONEncoder().encode(self.events) else { return }
            self.saveQueue.async {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("\(Edition.supportFolderName)/diagnostics.json")
    }

    func token(_ value: String) -> String {
        String(value.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character)) ? character : "_"
        }.prefix(64))
    }
}
