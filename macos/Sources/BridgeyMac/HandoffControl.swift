import Darwin
import Foundation

/*
 * `BridgeyMac --handoff off|on|status [--json]`: Let Bridgey handle copy and paste from the command line
 * (HandoffTakeover.swift). `off` turns Apple's Handoff off on this Mac, so Universal Clipboard and Handoff's file
 * copy stop racing Bridgey; `on` puts Handoff back exactly the way it was; `status` shows both.
 *
 * The running app serves it on handoff-control.sock in its own Application Support folder, with the same server,
 * request and checks as `--update-all` (UpdateControl.swift): owner-only folder and socket, getpeereid. Going
 * through the app keeps one writer and lets the choice sync to the person's other Macs at once. When Bridgey is
 * not running, the command does the same step itself on the app's own preferences and never starts the app (so
 * there is never a second copy running); the other Macs follow the next time Bridgey opens.
 *
 * Answers, newline-delimited JSON:
 *   {"event":"handoff","takeover":bool,"handoff":"on|off|partly|unknown","advertising":"unset|yes|no",
 *    "receiving":..,"applied":bool,"overridden":bool,"running":bool}
 *   {"event":"result","result":"done|failed","reason":"unreadable|write_failed","key":..}
 * Exit codes: 0 done, 1 failed, 2 usage.
 */
enum HandoffControl {
    static let socketName = "handoff-control.sock"
    static let usage = """
    Usage: BridgeyMac --handoff off|on|status [--json]
      off     Let Bridgey handle copy and paste: turn Apple Handoff off on this Mac
      on      Turn Handoff back on, the way it was before
      status  Show whether Bridgey handles copy and paste and whether Handoff is on
    """

    /// "on", "off", "partly" (one direction only) or "unknown".
    static func word(_ state: HandoffState?) -> String {
        guard let state else { return "unknown" }
        if state.isOff { return "off" }
        return state.advertising.allows && state.receiving.allows ? "on" : "partly"
    }

    static func stateEvent(_ outcome: HandoffOutcome, running: Bool) -> [String: Any] {
        var object: [String: Any] = ["event": "handoff", "takeover": outcome.takeover, "handoff": word(outcome.state),
                                     "applied": outcome.applied, "overridden": outcome.overridden, "running": running]
        if let state = outcome.state {
            object["advertising"] = state.advertising.rawValue
            object["receiving"] = state.receiving.rawValue
        }
        return object
    }

    static func resultEvent(_ outcome: HandoffOutcome) -> [String: Any] {
        switch outcome.error {
        case nil: return ["event": "result", "result": "done"]
        case .unreadable?: return ["event": "result", "result": "failed", "reason": "unreadable"]
        case let .writeFailed(key)?: return ["event": "result", "result": "failed", "reason": "write_failed", "key": key]
        }
    }

    struct Environment {
        var socketPath = UpdateControlSocket.defaultURL(fileName: HandoffControl.socketName).path
        /// Used only when Bridgey is not running.
        var store = HandoffTakeoverStore(defaults: .standard)
        var output: (String) -> Void = { print($0); fflush(stdout) }
    }

    static func run(arguments: [String], environment: Environment = Environment()) -> Int32 {
        let out = environment.output
        guard let at = arguments.firstIndex(of: "--handoff"), at + 1 < arguments.count,
              let command = HandoffCommand(rawValue: arguments[at + 1].lowercased()) else {
            out(usage)
            return 2
        }
        let json = arguments.contains("--json")
        var events: [[String: Any]] = []
        switch UpdateControlSocket.connect(environment.socketPath) {
        case let .success(fd):
            defer { close(fd) }
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let request = UpdateControlRequest(command: .handoff, handoff: command).line
            _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            while let line = UpdateControlSocket.readLine(fd, limit: 64 * 1024) {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                events.append(object)
            }
        case let .failure(error):
            if case let .system(_, code) = error, code == EACCES || code == EPERM {
                out("Error: permission denied. Only the user running \(Edition.displayName) can change its Handoff setting.")
                return 1
            }
            // Not running: do it here, without starting the app.
            let outcome = environment.store.perform(command)
            events = [stateEvent(outcome, running: false), resultEvent(outcome)]
        }
        guard let result = events.last(where: { $0["event"] as? String == "result" }) else {
            out("Error: \(Edition.displayName) closed the connection without a result. Quit it and open it again, then try once more.")
            return 1
        }
        if json {
            for event in events {
                if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) { out(String(decoding: data, as: UTF8.self)) }
            }
        } else {
            for line in lines(events, command: command) { out(line) }
        }
        return result["result"] as? String == "done" ? 0 : 1
    }

    /// The command line's words. English only: scripts read them, and the JSON form (`--json`) is the stable interface.
    static func lines(_ events: [[String: Any]], command: HandoffCommand) -> [String] {
        var lines: [String] = []
        let state = events.first { $0["event"] as? String == "handoff" }
        let result = events.first { $0["event"] as? String == "result" }
        if result?["result"] as? String == "failed" {
            if result?["reason"] as? String == "write_failed" {
                lines.append("Error: could not change Handoff (\(result?["key"] as? String ?? "?")). Change it in System Settings > General > AirDrop & Handoff.")
            } else if result?["reason"] as? String == "unreadable" {
                lines.append("Error: could not read the Handoff setting on this Mac.")
            } else {
                lines.append("Error: \(Edition.displayName) refused the request. Update it and try again.")
            }
        }
        guard let state else { return lines }
        let takeover = state["takeover"] as? Bool == true
        let handoff = state["handoff"] as? String ?? "unknown"
        lines.append("Let Bridgey handle copy and paste: \(takeover ? "on" : "off")")
        switch handoff {
        case "partly": lines.append("Apple Handoff on this Mac: partly on (one direction only)")
        default: lines.append("Apple Handoff on this Mac: \(handoff)")
        }
        if state["overridden"] as? Bool == true {
            lines.append("Handoff was turned back on in System Settings. Run BridgeyMac --handoff off to turn it off again.")
        }
        if command == .on && !takeover && handoff == "off" {
            lines.append("Handoff is off in System Settings, so it stays off. Turn it on in System Settings > General > AirDrop & Handoff.")
        }
        if state["running"] as? Bool == false && command != .status {
            lines.append("\(Edition.displayName) is not running, so this was done here. Your other Macs follow the next time it opens.")
        }
        return lines
    }
}
