import AppKit
import Darwin
import Foundation

/// The official installation is external to Bridgey; detecting it never starts or changes it.
struct TailscaleInstallation: Equatable, Sendable {
    var application: URL?
    var executable: URL?

    @MainActor static func detect() -> Self {
        let workspace = NSWorkspace.shared
        let identifiers = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
        let registered = identifiers.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        let conventional = [URL(fileURLWithPath: "/Applications/Tailscale.app"),
                            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Tailscale.app")]
            .filter { url in
                guard let identifier = Bundle(url: url)?.bundleIdentifier else { return false }
                return identifiers.contains(identifier)
            }
        let applications = registered + conventional
        return locate(applications: applications, binaries: ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"],
                      executable: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    static func locate(applications: [URL], binaries: [String], executable: (URL) -> Bool) -> Self {
        for application in applications {
            let binary = application.appendingPathComponent("Contents/MacOS/Tailscale")
            if executable(binary) { return Self(application: application, executable: binary) }
        }
        return Self(application: applications.first, executable: binaries.map { URL(fileURLWithPath: $0) }.first(where: executable))
    }
}

enum TailscaleSetupState: String, CaseIterable, Sendable {
    case checking, notInstalled, needsLogin, stopped, needsApproval, starting, running, unavailable
}

struct TailscaleSetupDisplay: Equatable, Sendable {
    var state: TailscaleSetupState = .checking
    var hasApplication = false
    var hasCommandLine = false
    var refreshing = false
}

struct TailscaleSnapshot: Equatable, Sendable {
    var state: TailscaleSetupState
    var peers: [TailnetPeerInfo] = []
    var answering: Set<String> = []

    static func decode(_ data: Data) -> Self {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let backend = json["BackendState"] as? String else { return Self(state: .unavailable) }
        switch backend {
        case "NeedsLogin": return Self(state: .needsLogin)
        case "Stopped": return Self(state: .stopped)
        case "NeedsMachineAuth": return Self(state: .needsApproval)
        case "Starting": return Self(state: .starting)
        case "Running": return Self(state: .running, peers: TailnetStatus.parse(data))
        default: return Self(state: .unavailable)
        }
    }
}

/// A bounded, read-only child process. No daemon, login, preferences or account commands are run.
enum TailscaleStatusCommand {
    enum Result: Equatable {
        case output(Data)
        case unavailable, timedOut, outputTooLarge
    }

    static func run(executable: URL, timeout: TimeInterval = 5, outputLimit: Int = 1_048_576) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable }
        pipe.fileHandleForWriting.closeFile()
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            stop(process)
            pipe.fileHandleForReading.closeFile()
            return .unavailable
        }
        defer { pipe.fileHandleForReading.closeFile() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var observedExit = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                guard output.count + count <= outputLimit else { stop(process); return .outputTooLarge }
                output.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                stop(process)
                return .unavailable
            }
            if !process.isRunning {
                // A child may write between our EAGAIN read and the exit check. Observe exit,
                // then drain once more before treating EAGAIN as the end of its output.
                if count == 0 || observedExit {
                    process.waitUntilExit()
                    return process.terminationStatus == 0 ? .output(output) : .unavailable
                }
                observedExit = true
                continue
            }
            if count == 0 { usleep(20_000) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
        stop(process)
        return .timedOut
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

/// Coalesces concurrent lifecycle/manual requests, so a slow CLI never piles up status processes.
@MainActor
final class TailscaleRefreshGate {
    private var pending: Task<TailscaleSnapshot, Never>?

    func read(_ work: @escaping @Sendable () async -> TailscaleSnapshot) async -> TailscaleSnapshot {
        if let pending { return await pending.value }
        let task = Task { await work() }
        pending = task
        let value = await task.value
        pending = nil
        return value
    }
}
