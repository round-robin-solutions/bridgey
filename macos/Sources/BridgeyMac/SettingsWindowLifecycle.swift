import AppKit

/// Settings is an ordinary retained window, independent of transient menu-bar panels.
/// The trace contains lifecycle flags only, never settings values or window contents.
@MainActor
final class SettingsWindow: NSWindow {
    struct Lifecycle: Equatable {
        let event: String
        let visible: Bool
        let miniaturized: Bool
        let key: Bool
        let appActive: Bool
        let appHidden: Bool
        let occluded: Bool
        let hidesOnDeactivate: Bool

        var line: String {
            "settings_window event=\(event) visible=\(visible) minimized=\(miniaturized) key=\(key) active=\(appActive) hidden=\(appHidden) occluded=\(occluded) hide_on_deactivate=\(hidesOnDeactivate)"
        }
    }

    var onLifecycle: (Lifecycle) -> Void = { BridgeyLog.line(BridgeyLog.windows, $0.line) }
    private var observers: [NSObjectProtocol] = []

    static func make(content: NSViewController, title: String,
                     frameAutosaveName: String? = "BridgeySettingsWindowB") -> SettingsWindow {
        let window = SettingsWindow(contentViewController: content)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: SettingsWindowView.size.width, height: SettingsWindowView.size.height))
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.managed]
        window.identifier = SettingsSearchKeys.windowID
        if let frameAutosaveName { window.setFrameAutosaveName(frameAutosaveName) }
        window.center()
        window.observeLifecycle()
        return window
    }

    override func close() {
        trace("close")
        super.close()
    }

    override func orderOut(_ sender: Any?) {
        trace("order_out")
        super.orderOut(sender)
    }

    func trace(_ event: String) {
        onLifecycle(Lifecycle(event: event, visible: isVisible, miniaturized: isMiniaturized,
                              key: isKeyWindow, appActive: NSApp.isActive, appHidden: NSApp.isHidden,
                              occluded: !occlusionState.contains(.visible), hidesOnDeactivate: hidesOnDeactivate))
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        for (name, event) in [(NSWindow.didResignKeyNotification, "resign_key"),
                              (NSWindow.didChangeOcclusionStateNotification, "occlusion"),
                              (NSWindow.didMiniaturizeNotification, "minimize"),
                              (NSWindow.didDeminiaturizeNotification, "restore")] {
            observers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trace(event) }
            })
        }
        for (name, event) in [(NSApplication.didResignActiveNotification, "app_inactive"),
                              (NSApplication.didHideNotification, "app_hidden"),
                              (NSApplication.didUnhideNotification, "app_unhidden")] {
            observers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.trace(event) }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
