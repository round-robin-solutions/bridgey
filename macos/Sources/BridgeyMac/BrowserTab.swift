import AppKit
import Foundation

/*
 * "Send the current browser tab to the phone": asks Safari or Chrome for the address of the front
 * window's tab with a fixed AppleScript. macOS asks for Automation access to that browser the
 * first time, only when the person uses it. A browser extension would avoid the prompt; it is
 * described as future work in docs/automation.md.
 */

enum SupportedBrowser: String, CaseIterable, Equatable {
    case safari = "com.apple.Safari"
    case safariPreview = "com.apple.SafariTechnologyPreview"
    case chrome = "com.google.Chrome"

    var name: String {
        switch self {
        case .safari: "Safari"
        case .safariPreview: "Safari Technology Preview"
        case .chrome: "Google Chrome"
        }
    }

    /// A fixed script: no part of it comes from the network or the phone.
    var script: String {
        switch self {
        case .safari, .safariPreview:
            "with timeout of 3 seconds\n tell application id \"\(rawValue)\" to return URL of current tab of front window\nend timeout"
        case .chrome:
            "with timeout of 3 seconds\n tell application id \"\(rawValue)\" to return URL of active tab of front window\nend timeout"
        }
    }
}

enum BrowserTabFailure: Error, Equatable {
    case noBrowser
    /// No window, or the tab has no web address (a start page).
    case noTab
    /// Automation was refused or the browser did not answer.
    case automation
}

/// Remembers the browser the person used last, since opening the menu bar panel does not change it.
@MainActor
final class BrowserTabReader: ObservableObject {
    @Published private(set) var lastBrowser: SupportedBrowser?
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "\(Edition.identifier).browser")

    init() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { lastBrowser = SupportedBrowser(rawValue: front) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, let browser = SupportedBrowser(rawValue: id) else { return }
            Task { @MainActor in self?.lastBrowser = browser }
        }
    }

    /// The browser to ask: the last one used that is still running, else any running one.
    var browser: SupportedBrowser? {
        let running = SupportedBrowser.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty }
        if let last = lastBrowser, running.contains(last) { return last }
        return running.first
    }

    func currentTab(completion: @escaping (Result<String, BrowserTabFailure>) -> Void) {
        guard let browser else { completion(.failure(.noBrowser)); return }
        let script = browser.script
        queue.async {
            let output = runFixedAppleScript(script)
            DispatchQueue.main.async {
                guard let output else { completion(.failure(.automation)); return }
                guard let link = validatedWebLink(output) else { completion(.failure(.noTab)); return }
                completion(.success(link))
            }
        }
    }
}

/// Runs a fixed script with osascript (no shell) and returns its output, nil on failure or after 5 s.
func runFixedAppleScript(_ source: String) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    do { try process.run() } catch { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
    var data = Data()
    while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
        guard data.count + chunk.count <= 8192 else { process.terminate(); break }
        data.append(chunk)
    }
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}
