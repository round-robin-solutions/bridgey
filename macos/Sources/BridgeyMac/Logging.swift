import Foundation
import os

/// Bridgey's unified-log categories, all under the subsystem `in.roundrobin.bridgey`.
///
/// Read them on the Mac with:
/// `/usr/bin/log show --last 12h --predicate 'subsystem == "in.roundrobin.bridgey"'`
///
/// Connection lifecycle events use `notice`, which macOS keeps on disk, so they are still there
/// the next morning; `info` stays in memory only. Privacy: states, reasons, counts, error codes
/// and 8-character device id prefixes are public. Device names, file names, app package names,
/// clipboard and notification text and full network addresses are never logged as public.
enum BridgeyLog {
    static let subsystem = "in.roundrobin.bridgey"
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let reconnect = Logger(subsystem: subsystem, category: "reconnect")
    static let pairing = Logger(subsystem: subsystem, category: "pairing")
    static let plugin = Logger(subsystem: subsystem, category: "plugin")
    /// Phone call cards: state changes, removals and reasons with 8-character ids, never callers.
    static let calls = Logger(subsystem: subsystem, category: "calls")
}

/// The first eight characters of a device id: enough to tell devices apart in logs.
func shortDeviceID(_ id: String) -> String { String(id.prefix(8)) }
