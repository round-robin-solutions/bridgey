import Darwin
import Network
import XCTest
@testable import BridgeyMac

/// The Personal Mac's app held 17 CLOSED TCP sockets after a day (lsof): a session whose peer closed or reset the
/// connection was dropped without cancelling its NWConnection, and Network.framework keeps the socket until cancel.
final class SessionSocketTests: XCTestCase {
    private func listener() -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        Darwin.listen(fd, 4)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    /// This process's TCP sockets whose remote port is `port`, in any state (lsof's CLOSED ones included).
    private func sockets(to port: UInt16) -> Int {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return 0 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        var count = 0
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport))
            if remote == port { count += 1 }
        }
        return count
    }

    /// The peer ends the connection (`reset`: RST, else FIN); the session reports the end and gives its socket back.
    private func peerEnds(reset: Bool, expectedReason: String) {
        let (server, port) = listener()
        defer { Darwin.close(server) }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let session = Session(connection: connection, peerName: "Test phone")
        let ended = expectation(description: "session ended")
        session.onFailure = { ended.fulfill() }
        connection.stateUpdateHandler = { state in
            if case .ready = state { session.receive() }
        }
        connection.start(queue: .main)
        let client = Darwin.accept(server, nil, nil)
        XCTAssertGreaterThanOrEqual(client, 0)
        // Let the session read once before the peer goes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(sockets(to: port), 1)
        if reset {
            var hard = linger(l_onoff: 1, l_linger: 0)
            setsockopt(client, SOL_SOCKET, SO_LINGER, &hard, socklen_t(MemoryLayout<linger>.size))
        }
        Darwin.close(client)
        wait(for: [ended], timeout: 5)
        XCTAssertEqual(session.dropReason, expectedReason)
        // cancel() hands the socket back asynchronously.
        let deadline = Date().addingTimeInterval(3)
        while sockets(to: port) > 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(sockets(to: port), 0, "the ended session still holds its socket")
    }

    func testAPeerThatClosesLeavesNoSocketBehind() {
        peerEnds(reset: false, expectedReason: "closed_by_peer")
    }

    func testAPeerThatResetsLeavesNoSocketBehind() {
        peerEnds(reset: true, expectedReason: "reset_by_peer")
    }
}
