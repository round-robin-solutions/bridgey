import Foundation
import Network
import XCTest
@testable import BridgeyMac

/// A phone stand-in listening on 127.0.0.1. It resets its first connection with a TCP RST, as
/// the phone did at 02:56, and keeps later ones open.
private final class ResettingPhone {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var accepted: [Int32] = []
    var onAccept: ((Int) -> Void)?

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    func start() {
        let listener = listener
        Thread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0, let self else { return }
                let count = self.lock.withLock { () -> Int in
                    self.accepted.append(client)
                    return self.accepted.count
                }
                if count == 1 {
                    // Let the Mac see the link come up, then reset it.
                    usleep(200_000)
                    var option = linger(l_onoff: 1, l_linger: 0)
                    setsockopt(client, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<linger>.size))
                    close(client)
                }
                self.onAccept?(count)
            }
        }.start()
    }

    func stop() {
        close(listener)
        lock.withLock { accepted.dropFirst().forEach { close($0) } }
    }
}

final class ReconnectIntegrationTests: XCTestCase {
    private final class Link {
        var connected = Set<String>()
        var connections: [NWConnection] = []
        var dropReasons: [String] = []
        var readyCount = 0
    }

    /// Connection reset by peer, the phone is absent from discovery, and the Mac must still
    /// redial the address the phone last connected from, over real TCP, and reconnect.
    func testRedialsTheKnownAddressAfterAResetWhileDiscoveryShowsNothing() throws {
        let phone = try ResettingPhone()
        let phoneID = "a1b2c3d4-0000-4000-8000-000000000001"
        let reset = expectation(description: "the Mac saw the reset")
        let redialled = expectation(description: "the phone accepted a second connection")
        let reconnected = expectation(description: "the link is up again")
        phone.onAccept = { count in if count == 2 { redialled.fulfill() } }
        phone.start()
        defer { phone.stop() }

        let link = Link()
        let engine = ReconnectEngine(
            addressBook: KnownAddressBook(store: MemoryAddressBookStore()),
            clock: MainQueueClock(),
            delay: { _, _ in 0.05 }
        )
        engine.isTrusted = { $0 == phoneID }
        engine.isConnected = { link.connected.contains($0) }
        engine.networks = { [LocalIPv4Network(address: 0x7F00_0001, netmask: 0xFF00_0000)] }
        engine.dial = { id, address in
            let connection = NWConnection(
                host: NWEndpoint.Host(address.host),
                port: NWEndpoint.Port(rawValue: UInt16(address.port))!,
                using: .tcp
            )
            link.connections.append(connection)
            var ended = false
            var wasReady = false
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { _, _, complete, error in
                    DispatchQueue.main.async {
                        guard complete || error != nil else { return receive() }
                        guard !ended else { return }
                        ended = true
                        link.dropReasons.append(error.map(connectionDropReason) ?? "closed_by_peer")
                        if link.dropReasons.count == 1 { reset.fulfill() }
                        link.connected.remove(id)
                        engine.disconnected(id)
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        wasReady = true
                        link.readyCount += 1
                        link.connected.insert(id)
                        engine.dialEnded(id)
                        engine.connected(id, host: address.host, port: address.port, source: .outbound)
                        if link.readyCount == 2 { reconnected.fulfill() }
                        receive()
                    case .failed, .cancelled:
                        if !ended && !wasReady {
                            ended = true
                            engine.dialEnded(id)
                        }
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }

        // The phone dialled this Mac earlier: that is the only place the Mac knows it from.
        engine.addressBook.learn(phoneID, host: "127.0.0.1", port: Int(phone.port), source: .inbound, at: Date())
        engine.discoveryChanged([])
        engine.disconnected(phoneID)

        wait(for: [reset, redialled, reconnected], timeout: 10)
        XCTAssertEqual(link.dropReasons.first, "reset_by_peer")
        XCTAssertTrue(link.connected.contains(phoneID))
        XCTAssertNil(engine.schedule.entry(phoneID))
        link.connections.forEach { $0.cancel() }
    }
}
