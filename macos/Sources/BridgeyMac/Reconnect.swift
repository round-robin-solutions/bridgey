import Foundation

/*
 * Reconnecting to trusted devices without relying on Bonjour alone. Pure logic, unit tested:
 * the policy (every knob in one place), the per-device address book, the retry schedule, the
 * event debouncer and the on-link check. Mirrors android/.../Reconnect.kt.
 * The trade-offs behind each value are in docs/reconnect-reliability.md.
 */

enum ReconnectPolicy {
    /// Delays between attempts after a drop, in seconds. The last one repeats for the rest of
    /// the fast phase: 2 s, 5 s, 15 s, 30 s, then every 60 s.
    static let fastDelays: [TimeInterval] = [2, 5, 15, 30, 60]
    /// How long the fast delays apply after a drop, a wake, a network change or a manual retry.
    static let fastPhase: TimeInterval = 3_600
    /// After the fast phase the device has been away for a while: one attempt every 10 minutes.
    static let slowDelay: TimeInterval = 600
    /// After this many failed attempts the device shows "Can't reach" rather than "Reconnecting".
    static let strugglingAfterAttempts = 4
    /// Discovery restarts (browse and re-announce) this often while a trusted device is away...
    static let discoveryRestartInterval: TimeInterval = 300
    /// ...for this long after it went away (or after the last wake or network change). After
    /// that only wake, network changes and "Look for devices again" restart discovery.
    static let discoveryRestartWindow: TimeInterval = 3_600
    /// Wake and network events this close together collapse into one recovery...
    static let eventQuietPeriod: TimeInterval = 2
    /// ...which still runs this long after the first event of a long burst.
    static let eventMaxWait: TimeInterval = 10
    /// A reconnect dial that has not connected by then is abandoned; the schedule tries again.
    static let connectTimeout: TimeInterval = 8
    /// Addresses remembered per device.
    static let addressesPerDevice = 4
    /// "Look for devices again" waits this long for devices to answer before reporting.
    static let rediscoverWindow: TimeInterval = 10
    /// Heartbeat: a ping every 10 s; a link silent for 30 s is dead.
    static let heartbeatInterval: TimeInterval = 10
    static let heartbeatTimeout: TimeInterval = 30
    /// The port Bridgey listens on. Inbound connections come from a random port, so an address
    /// learned from one is stored with this port.
    static let listeningPort = 42_458

    /// The wait after `attempts` attempts, `elapsed` seconds into the fast phase.
    static func delay(afterAttempts attempts: Int, elapsed: TimeInterval) -> TimeInterval {
        if elapsed >= fastPhase { return slowDelay }
        return fastDelays[min(max(attempts, 0), fastDelays.count - 1)]
    }
}

// MARK: - Address book

enum AddressSource: String, Codable, Equatable {
    /// Seen in Bonjour: an untrusted hint until a connection there authenticates.
    case discovery
    /// This Mac dialled the device there and the connection authenticated.
    case outbound
    /// The device connected from there and the connection authenticated.
    case inbound

    var authenticated: Bool { self != .discovery }
}

struct KnownAddress: Codable, Equatable {
    var host: String
    var port: Int
    var source: AddressSource
    var lastSeen: Date
}

struct DeviceAddressRecord: Codable, Equatable {
    /// Most recent first.
    var addresses: [KnownAddress] = []
    /// When the device was last connected: the moment its link dropped, or the latest connect.
    var lastConnectedAt: Date?
}

protocol AddressBookStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

final class UserDefaultsAddressBookStore: AddressBookStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "reconnect.addressBook.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Data? { defaults.data(forKey: key) }
    func save(_ data: Data) { defaults.set(data, forKey: key) }
}

/// Where each trusted device was last reachable, learned from discovery, from this Mac's own
/// dials and from the remote end of connections the device made to this Mac. Persisted, so a
/// restart of either app still knows where to look.
final class KnownAddressBook {
    private(set) var records: [String: DeviceAddressRecord] = [:]
    /// When "last seen" was last written, per device.
    private var persistedSeen: [String: Date] = [:]
    private let store: AddressBookStore
    private let limit: Int

    init(store: AddressBookStore, limit: Int = ReconnectPolicy.addressesPerDevice) {
        self.store = store
        self.limit = max(limit, 1)
        if let data = store.load(), let decoded = try? JSONDecoder().decode([String: DeviceAddressRecord].self, from: data) {
            records = decoded
        }
    }

    /// Remembers that `deviceID` was at `host`. Returns false for a host that is not an address.
    @discardableResult
    func learn(_ deviceID: String, host rawHost: String, port: Int, source: AddressSource, at date: Date) -> Bool {
        guard let host = normalizedHost(rawHost), (1...65_535).contains(port) else { return false }
        var record = records[deviceID] ?? DeviceAddressRecord()
        var entry = KnownAddress(host: host, port: port, source: source, lastSeen: date)
        if let index = record.addresses.firstIndex(where: { $0.host == host }) {
            let existing = record.addresses.remove(at: index)
            // A discovery sighting never downgrades an address that authenticated.
            if !source.authenticated && existing.source.authenticated { entry.source = existing.source }
            entry.lastSeen = max(existing.lastSeen, date)
        }
        record.addresses.insert(entry, at: 0)
        record.addresses = trimmed(record.addresses)
        records[deviceID] = record
        persist()
        return true
    }

    /// Most recent first.
    func addresses(for deviceID: String) -> [KnownAddress] {
        (records[deviceID]?.addresses ?? []).sorted { $0.lastSeen > $1.lastSeen }
    }

    func lastConnected(_ deviceID: String) -> Date? { records[deviceID]?.lastConnectedAt }

    /// The link is up now, or just dropped: either way the device was last seen at `date`.
    /// With `persistAfter`, a heartbeat's update is written only when the stored time is older
    /// than that many seconds (the in-memory value is always current).
    func markSeen(_ deviceID: String, at date: Date, persistAfter: TimeInterval = 0) {
        var record = records[deviceID] ?? DeviceAddressRecord()
        record.lastConnectedAt = date
        records[deviceID] = record
        if persistAfter > 0, let written = persistedSeen[deviceID], date.timeIntervalSince(written) < persistAfter { return }
        persistedSeen[deviceID] = date
        persist()
    }

    func forget(_ deviceID: String) {
        guard records.removeValue(forKey: deviceID) != nil else { return }
        persist()
    }

    /// Drops records of devices that are no longer trusted.
    func retain(_ deviceIDs: Set<String>) {
        let before = records.count
        records = records.filter { deviceIDs.contains($0.key) }
        if records.count != before { persist() }
    }

    /// Keeps the newest `limit`, but never lets discovery hints push out the newest address that
    /// authenticated: someone advertising a trusted device's id cannot hide where it really is.
    private func trimmed(_ addresses: [KnownAddress]) -> [KnownAddress] {
        let sorted = addresses.sorted { $0.lastSeen > $1.lastSeen }
        guard sorted.count > limit else { return sorted }
        var kept = Array(sorted.prefix(limit))
        if !kept.contains(where: { $0.source.authenticated }),
           let newestAuthenticated = sorted.first(where: { $0.source.authenticated }) {
            kept[kept.count - 1] = newestAuthenticated
        }
        return kept
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        store.save(data)
    }
}

/// An IP literal (IPv4-mapped IPv6 unwrapped) or a `.local` host name; nil for anything else.
func normalizedHost(_ raw: String) -> String? {
    var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
    if host.lowercased().hasPrefix("::ffff:"), parseIPv4(String(host.dropFirst(7))) != nil {
        host = String(host.dropFirst(7))
    }
    guard !host.isEmpty, host.utf8.count <= 253 else { return nil }
    if parseIPv4(host) != nil { return host }
    if isIPv6Literal(host) { return host.lowercased().hasPrefix("fe80") ? nil : host.lowercased() }
    let name = host.hasSuffix(".") ? String(host.dropLast()) : host
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
    guard name.lowercased().hasSuffix(".local"), name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return name
}

/// A short, non-identifying tag for logs: the address family and the last IPv4 octet.
func addressTag(_ host: String) -> String {
    if let value = parseIPv4(host) { return "v4.\(value & 0xFF)" }
    if isIPv6Literal(host) { return "v6" }
    return "name"
}

func parseIPv4(_ text: String) -> UInt32? {
    var address = in_addr()
    guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
    return UInt32(bigEndian: address.s_addr)
}

private func isIPv6Literal(_ text: String) -> Bool {
    var address = in6_addr()
    return inet_pton(AF_INET6, text, &address) == 1
}

// MARK: - On-link check

/// One IPv4 network this Mac is on.
struct LocalIPv4Network: Equatable, Hashable {
    let address: UInt32
    let netmask: UInt32

    func contains(_ other: UInt32) -> Bool { other & netmask == address & netmask }
}

/// Only addresses on a network this device is on are dialled: on another Wi-Fi the old home
/// address is someone else's (or nobody's), and dialling it is noise. IPv6 and `.local` names
/// are dialled whenever any network is up.
func isDialable(_ host: String, on networks: [LocalIPv4Network]) -> Bool {
    guard !networks.isEmpty else { return false }
    guard let value = parseIPv4(host) else { return true }
    return networks.contains { $0.contains(value) }
}

/// Up, non-loopback IPv4 interfaces.
func localIPv4Networks() -> [LocalIPv4Network] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    var networks = Set<LocalIPv4Network>()
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        defer { cursor = current.pointee.ifa_next }
        let flags = Int32(current.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              let mask = current.pointee.ifa_netmask else { continue }
        let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        // Link-local (169.254/16) only: no DHCP lease yet, nothing worth dialling.
        if ip & 0xFFFF_0000 == 0xA9FE_0000 { continue }
        networks.insert(LocalIPv4Network(address: ip, netmask: netmask))
    }
    return networks.sorted { $0.address < $1.address }
}

// MARK: - Schedule

/// One trusted device's reconnect episode.
struct ReconnectEntry: Equatable {
    /// Attempts made since the episode (or the last reset) began.
    var attempts: Int
    /// The start of the current fast phase.
    var phaseStart: Date
    var nextAt: Date
}

/// Per device: when to try next. A drop starts an episode; each attempt pushes the next one out
/// along `ReconnectPolicy`; a wake, a network change, discovery seeing the device or "Retry now"
/// resets it to "now" with a fresh fast phase; connecting ends it.
final class ReconnectSchedule {
    private(set) var entries: [String: ReconnectEntry] = [:]

    func isTracking(_ id: String) -> Bool { entries[id] != nil }

    func entry(_ id: String) -> ReconnectEntry? { entries[id] }

    /// The device is not connected: start its episode unless one is running.
    func disconnected(
        _ id: String,
        at now: Date,
        delay: (Int, TimeInterval) -> TimeInterval = ReconnectPolicy.delay(afterAttempts:elapsed:)
    ) {
        guard entries[id] == nil else { return }
        entries[id] = ReconnectEntry(attempts: 0, phaseStart: now, nextAt: now + delay(0, 0))
    }

    func connected(_ id: String) { entries.removeValue(forKey: id) }

    /// Try `id` now, with the fast delays again.
    func reset(_ id: String, at now: Date) {
        entries[id] = ReconnectEntry(attempts: 0, phaseStart: now, nextAt: now)
    }

    func resetAll(at now: Date) {
        for id in entries.keys { reset(id, at: now) }
    }

    func due(at now: Date) -> [String] {
        entries.filter { $0.value.nextAt <= now }.map(\.key).sorted()
    }

    /// An attempt for `id` starts now. Returns its number in the episode, from 1.
    @discardableResult
    func attemptStarted(
        _ id: String,
        at now: Date,
        delay: (Int, TimeInterval) -> TimeInterval = ReconnectPolicy.delay(afterAttempts:elapsed:)
    ) -> Int {
        var entry = entries[id] ?? ReconnectEntry(attempts: 0, phaseStart: now, nextAt: now)
        entry.attempts += 1
        entry.nextAt = now + delay(entry.attempts, now.timeIntervalSince(entry.phaseStart))
        entries[id] = entry
        return entry.attempts
    }

    var nextDueDate: Date? { entries.values.map(\.nextAt).min() }
}

// MARK: - Timers and debounce

protocol ScheduledTask: AnyObject {
    func cancel()
}

/// The clock and timer the reconnect logic runs on; tests use a manual one.
protocol ReconnectClock: AnyObject {
    var now: Date { get }
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask
}

final class MainQueueClock: ReconnectClock {
    private final class Task: ScheduledTask {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    var now: Date { Date() }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: item)
        return Task(item)
    }
}

/// Collapses a burst of events (a wake brings a screen wake and several network path updates)
/// into one call with every reason: it fires once nothing new arrived for `quiet` seconds, and
/// at the latest `maxWait` after the burst's first event.
final class EventDebouncer {
    private let clock: ReconnectClock
    private let quiet: TimeInterval
    private let maxWait: TimeInterval
    private let fire: ([String]) -> Void
    private var reasons: [String] = []
    private var burstStart: Date?
    private var pending: ScheduledTask?

    init(
        clock: ReconnectClock,
        quiet: TimeInterval = ReconnectPolicy.eventQuietPeriod,
        maxWait: TimeInterval = ReconnectPolicy.eventMaxWait,
        fire: @escaping ([String]) -> Void
    ) {
        self.clock = clock
        self.quiet = quiet
        self.maxWait = maxWait
        self.fire = fire
    }

    func note(_ reason: String) {
        let now = clock.now
        if !reasons.contains(reason) { reasons.append(reason) }
        let start = burstStart ?? now
        burstStart = start
        pending?.cancel()
        let deadline = min(now.addingTimeInterval(quiet), start.addingTimeInterval(maxWait))
        pending = clock.schedule(after: deadline.timeIntervalSince(now)) { [weak self] in self?.flush() }
    }

    private func flush() {
        let fired = reasons
        reasons = []
        burstStart = nil
        pending = nil
        if !fired.isEmpty { fire(fired) }
    }
}

// MARK: - Look for devices again

/// The feedback line after "Look for devices again": who answered and who did not.
func rediscoverSummary(found: [String], stillMissing: [String]) -> String {
    let foundText: String? = found.isEmpty ? nil : String(
        format: L10n.text("rediscover.found", fallback: "Found %@"), joinedNames(found))
    let missingText: String? = stillMissing.isEmpty ? nil : String(
        format: L10n.text("rediscover.missing", fallback: "Still can\u{2019}t reach %@"), joinedNames(stillMissing))
    switch (foundText, missingText) {
    case let (found?, missing?): return "\(found). \(missing)"
    case let (found?, nil): return found
    case let (nil, missing?): return missing
    default: return L10n.text("rediscover.none", fallback: "No new devices found")
    }
}

private func joinedNames(_ names: [String]) -> String {
    if names.count > 2 {
        return String(format: L10n.text("rediscover.count", fallback: "%d devices"), names.count)
    }
    return ListFormatter.localizedString(byJoining: names)
}
