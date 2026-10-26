import AppKit
import Network

/// Tells the coordinator when the network under Bridgey may have changed: the Mac woke, its
/// screens woke, or the network path changed (Wi-Fi joined or left, a new address). Each of
/// these is a moment when a dropped phone is likely reachable again, so the reconnect backoff
/// and discovery restart. Events arrive raw; the coordinator debounces them.
@MainActor
final class LinkEventMonitor {
    var onEvent: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?

    func start() {
        guard pathMonitor == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, "wake"),
            (NSWorkspace.screensDidWakeNotification, "screen_wake"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session_active"),
        ]
        for (name, reason) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onEvent?(reason) }
            })
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let signature = Self.signature(path)
            Task { @MainActor in self?.pathChanged(signature: signature, satisfied: satisfied) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
    }

    private func pathChanged(signature: String, satisfied: Bool) {
        // The first update describes the network at start; only changes after it count.
        defer { lastPathSignature = signature }
        guard let last = lastPathSignature, last != signature else { return }
        onEvent?(satisfied ? "network_change" : "network_lost")
    }

    /// What identifies "the same network": status, interfaces, gateways and this Mac's IPv4
    /// networks (a new DHCP address is a change too).
    nonisolated private static func signature(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted()
        let gateways = path.gateways.map { "\($0)" }.sorted()
        let networks = localIPv4Networks().map { "\($0.address)/\($0.netmask)" }
        return ([String(describing: path.status)] + interfaces + gateways + networks).joined(separator: "|")
    }
}
