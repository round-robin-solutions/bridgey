import Foundation

/// What the reconnect engine did, for logs and diagnostics.
enum ReconnectEvent: Equatable {
    case dial(deviceID: String, address: KnownAddress, attempt: Int, reason: String)
    /// Nothing to dial on this network. Reported for the first attempt and every tenth.
    case noAddress(deviceID: String, attempt: Int, reason: String)
    case foundByDiscovery(deviceID: String, addresses: Int)
}

/// Keeps dialling trusted devices that are not connected, at every address they are known at,
/// on `ReconnectPolicy`'s schedule. It does not care which side dialled before: both apps run
/// one, and the session registry keeps a single socket when both dial at once. Main queue only.
/// The coordinator owns the sockets; it reports connects, drops and dial results here.
final class ReconnectEngine {
    let addressBook: KnownAddressBook
    let schedule = ReconnectSchedule()
    private let clock: ReconnectClock
    private let delay: (Int, TimeInterval) -> TimeInterval
    /// The networks this device is on now (tests pass loopback).
    var networks: () -> [LocalIPv4Network] = localIPv4Networks
    var isTrusted: (String) -> Bool = { _ in false }
    var isConnected: (String) -> Bool = { _ in false }
    /// Opens a connection to the device at the address. The coordinator calls `dialEnded` when
    /// that connection authenticates or fails.
    var dial: (String, KnownAddress) -> Void = { _, _ in }
    var onEvent: ((ReconnectEvent) -> Void)?
    /// The schedule changed: the UI's reconnect state may have too.
    var onChange: (() -> Void)?
    private(set) var livePeers: [DiscoveredPeer] = []
    private var dialing: [String: Int] = [:]
    private var timer: ScheduledTask?

    init(
        addressBook: KnownAddressBook,
        clock: ReconnectClock,
        delay: @escaping (Int, TimeInterval) -> TimeInterval = ReconnectPolicy.delay(afterAttempts:elapsed:)
    ) {
        self.addressBook = addressBook
        self.clock = clock
        self.delay = delay
    }

    // MARK: Reports from the coordinator

    /// The device's link dropped. `seenNow` is false at launch, where the device was last seen
    /// whenever the book says, not now.
    func disconnected(_ id: String, seenNow: Bool = true) {
        guard isTrusted(id) else { return }
        let now = clock.now
        if seenNow { addressBook.markSeen(id, at: now) }
        schedule.disconnected(id, at: now, phaseStart: phaseStart(for: id, at: now), delay: delay)
        arm()
    }

    /// The link is alive (a heartbeat): "last seen" stays current even if the app quits.
    func stillConnected(_ id: String) {
        addressBook.markSeen(id, at: clock.now, persistAfter: 60)
    }

    /// The device authenticated over a connection with `host` at its other end.
    func connected(_ id: String, host: String?, port: Int, source: AddressSource) {
        let now = clock.now
        if let host { addressBook.learn(id, host: host, port: port, source: source, at: now) }
        addressBook.markSeen(id, at: now)
        schedule.connected(id)
        arm()
    }

    func dialEnded(_ id: String) {
        dialing[id] = max((dialing[id] ?? 1) - 1, 0)
        arm()
    }

    func isDialing(_ id: String) -> Bool { (dialing[id] ?? 0) > 0 }

    func forget(_ id: String) {
        addressBook.forget(id)
        schedule.connected(id)
        arm()
    }

    /// Discovery's current list. Trusted devices in it are remembered at their addresses; one
    /// that is not connected and just appeared (or moved) is tried now.
    func discoveryChanged(_ peers: [DiscoveredPeer]) {
        let previous = livePeers
        livePeers = peers
        let now = clock.now
        for peer in peers {
            guard let id = peer.deviceIDHint, isTrusted(id) else { continue }
            let port = peer.port ?? ReconnectPolicy.listeningPort
            // IP addresses work when mDNS lookups do not; the host name only when there is no IP.
            let hosts = peer.addresses.isEmpty ? peer.host.map { [$0] } ?? [] : peer.addresses
            for host in hosts { addressBook.learn(id, host: host, port: port, source: .discovery, at: now) }
            guard !isConnected(id) else { continue }
            let before = previous.first { $0.deviceIDHint == id }
            if before == nil || before?.addresses != peer.addresses || before?.port != peer.port {
                onEvent?(.foundByDiscovery(deviceID: id, addresses: hosts.count))
                schedule.reset(id, at: now)
            }
        }
        arm()
    }

    /// A launch, wake or network change: every listed device is tried now, with the fast delays
    /// again, except a device that is away (see `ReconnectPolicy.awayAfter`), which is tried now
    /// and then keeps to the slow delay.
    func resetAll(_ ids: [String]) {
        let now = clock.now
        for id in ids where isTrusted(id) && !isConnected(id) { schedule.reset(id, at: now, phaseStart: phaseStart(for: id, at: now)) }
        arm()
    }

    /// Not connected for longer than `ReconnectPolicy.awayAfter` (a device never connected is not away).
    func isAway(_ id: String) -> Bool {
        guard !isConnected(id), let last = addressBook.lastConnected(id) else { return false }
        return clock.now.timeIntervalSince(last) >= ReconnectPolicy.awayAfter
    }

    /// Where a new episode starts: now, or for a device that is away, when it was last connected,
    /// so the schedule is already past its fast phase.
    private func phaseStart(for id: String, at now: Date) -> Date {
        guard isAway(id), let last = addressBook.lastConnected(id) else { return now }
        return last
    }

    /// "Retry now" and "Look for devices again": dial every known address at once. If two reach
    /// the device, the session registry keeps one.
    func dialEverywhere(_ id: String, reason: String) {
        guard isTrusted(id), !isConnected(id) else { return }
        let now = clock.now
        schedule.reset(id, at: now)
        let attempt = schedule.attemptStarted(id, at: now, delay: delay)
        let candidates = candidates(for: id)
        if candidates.isEmpty { onEvent?(.noAddress(deviceID: id, attempt: attempt, reason: reason)) }
        for address in candidates { startDial(id, address, attempt: attempt, reason: reason) }
        arm()
    }

    // MARK: State for the UI

    func display(for id: String) -> ReconnectDisplay? {
        guard isTrusted(id), !isConnected(id) else { return nil }
        let attempts = schedule.entry(id)?.attempts ?? 0
        // Away and not in discovery: it is not on this network, whatever the attempt count says.
        let away = isAway(id) && !livePeers.contains { $0.deviceIDHint == id }
        return ReconnectDisplay(lastSeen: addressBook.lastConnected(id), struggling: away || attempts >= ReconnectPolicy.strugglingAfterAttempts,
                                away: away)
    }

    // MARK: Schedule

    /// Where to try `id`: what discovery shows now, then the address book, newest first, keeping
    /// only addresses on a network this device is on. A remembered address that discovery now
    /// shows for another device is skipped: the address moved on (DHCP gave it to another device,
    /// or the device was reset and has a new identity), and dialling it only reaches a device
    /// that closes the connection.
    func candidates(for id: String) -> [KnownAddress] {
        let now = clock.now
        var list: [KnownAddress] = []
        if let peer = livePeers.first(where: { $0.deviceIDHint == id }) {
            let port = peer.port ?? ReconnectPolicy.listeningPort
            list += peer.addresses.map { KnownAddress(host: $0, port: port, source: .discovery, lastSeen: now) }
        }
        // Bonjour just saw the live addresses on a local network, so they are always worth a try;
        // the remembered ones only on a network this Mac is on now.
        let networks = networks()
        var seen = Set<String>()
        let live = list.filter { seen.insert($0.host).inserted }
        let elsewhere = Set(livePeers.filter { $0.deviceIDHint != nil && $0.deviceIDHint != id }.flatMap { $0.addresses.compactMap(normalizedHost) })
        return live + addressBook.addresses(for: id).filter {
            seen.insert($0.host).inserted && !elsewhere.contains($0.host) && isDialable($0.host, on: networks)
        }
    }

    /// One timer for every device: it fires at the earliest due attempt of a device that has no
    /// dial in flight.
    func arm() {
        timer?.cancel()
        timer = nil
        onChange?()
        let waiting = schedule.entries.filter { !isDialing($0.key) }
        guard let next = waiting.values.map(\.nextAt).min() else { return }
        timer = clock.schedule(after: next.timeIntervalSince(clock.now)) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.runDue()
        }
    }

    private func runDue() {
        let now = clock.now
        for id in schedule.due(at: now) where !isDialing(id) {
            guard isTrusted(id), !isConnected(id) else {
                schedule.connected(id)
                continue
            }
            let attempt = schedule.attemptStarted(id, at: now, delay: delay)
            let candidates = candidates(for: id)
            guard !candidates.isEmpty else {
                // Nothing to dial here; discovery, a network change or the user brings it forward.
                if attempt == 1 || attempt % 10 == 0 {
                    onEvent?(.noAddress(deviceID: id, attempt: attempt, reason: "backoff"))
                }
                continue
            }
            // Successive attempts rotate through the addresses, newest first.
            startDial(id, candidates[(attempt - 1) % candidates.count], attempt: attempt, reason: "backoff")
        }
        arm()
    }

    private func startDial(_ id: String, _ address: KnownAddress, attempt: Int, reason: String) {
        dialing[id, default: 0] += 1
        onEvent?(.dial(deviceID: id, address: address, attempt: attempt, reason: reason))
        dial(id, address)
    }
}
