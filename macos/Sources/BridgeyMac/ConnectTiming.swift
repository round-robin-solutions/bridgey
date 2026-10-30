import Foundation

/// The connection waterfall (docs/connect-anywhere-latency.md): every step of reaching a phone away from
/// home as one log line with the wall clock. The core's steps arrive as `timing` events; the app adds its own
/// (tunnel hand-off, authenticated session). Step names and short device IDs only, never an address.
/// A test instance (debug builds with BridgeyTestInstance) also appends each step to
/// `/tmp/<bundle id>-control/events.jsonl`, so a live test can time connects on one clock.
enum ConnectTiming {
    static func mark(_ step: String, peer: String? = nil, detail: String? = nil, at: Double = Date().timeIntervalSince1970 * 1000) {
        let atMillis = Int64(at)
        BridgeyLog.transport.notice("connect timing \(step, privacy: .public) at=\(atMillis, privacy: .public) peer=\(peer.map(shortDeviceID) ?? "-", privacy: .public) detail=\(detail ?? "-", privacy: .public)")
        guard TestInstance.enabled else { return }
        var line: [String: Any] = ["step": step, "at": atMillis]
        if let peer { line["peer"] = shortDeviceID(peer) }
        if let detail { line["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: line), let text = String(data: data, encoding: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/\(Edition.identifier)-control/events.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
    }
}
