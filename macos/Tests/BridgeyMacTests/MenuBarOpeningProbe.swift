import AppKit
import SwiftUI
import XCTest
@testable import BridgeyMac

/// Native, synthetic-data measurements only. No live coordinator, clipboard, preferences or user files.
@MainActor
enum MenuBarOpeningProbe {
    final class Fixture {
        var roots = 0
        var appearances = 0
        var providerReads = 0
        let now = Date(timeIntervalSince1970: 1_793_984_000)

        func refreshClipboard() { providerReads += 1 }

        func model() -> PanelModel {
            let phone = "11111111-1111-1111-1111-111111111111"
            var model = PanelModel()
            model.state = .connected(deviceID: phone, peerName: "OnePlus 11")
            model.targetDeviceID = phone
            model.rings = [
                DeviceRing(id: phone, deviceID: phone, name: "OnePlus 11", state: .connected, trusted: true, platform: "android", peer: nil),
                DeviceRing(id: "mac-a", deviceID: "mac-a", name: "Personal Mac", state: .connected, trusted: true, platform: "macos", peer: nil),
                DeviceRing(id: "mac-b", deviceID: "mac-b", name: "Work MacBook Pro with a long display name", state: .connected, trusted: true, platform: "macos", peer: nil),
            ]
            model.battery = RemoteBatteryStatus(level: 76, isCharging: true)
            model.available = Set(BridgeyFeature.allCases)
            model.clipboardLine = "Synthetic clipboard preview for the fixture"
            model.messagesUnread = 3
            model.now = now
            let items = (0..<200).map { index in
                ActivityItem(id: Int64(index + 1), kind: index.isMultiple(of: 2) ? .clipboardSent : .fileReceived,
                             deviceID: phone, deviceName: "OnePlus 11", fileName: "Sample document \(index).pdf",
                             preview: "Synthetic history item", appName: nil, sensitive: false,
                             automatic: true, count: 1, at: now.addingTimeInterval(-Double(index) * 60))
            }
            model.rows = streamRows(items, now: now)
            return model
        }
    }

    private struct Content: View {
        let fixture: Fixture
        let model: PanelModel
        let retainingRoot: Bool
        let reduced: Bool
        let scheme: ColorScheme

        var body: some View {
            MenuBarPanelSurface {
                BrandRoot(reduceMotion: reduced) { StreamPanelView(model: model, actions: PanelActions()) }
            }
            .environment(\.colorScheme, scheme)
            .environment(\.snapshotRendering, true)
            .onAppear {
                fixture.appearances += 1
                // Mirrors Beta25's onAppear provider call without touching the real pasteboard.
                if !retainingRoot { fixture.refreshClipboard() }
            }
        }
    }

    static func run(directory: URL, retainingRoot: Bool,
                    configure: (MenuBarStatusController, Fixture) -> Void = { _, _ in }) throws {
        _ = NSApplication.shared
        var scenarios: [[String: Any]] = []
        for scheme in [ColorScheme.light, .dark] {
            for reduced in [false, true] {
                let label = "\(scheme == .dark ? "dark" : "light")-\(reduced ? "reduced" : "motion")"
                let fixture = Fixture()
                let start = ProcessInfo.processInfo.systemUptime
                let hosting = NSHostingController(rootView: AnyView(EmptyView()))
                let controller = MenuBarStatusController(content: hosting)
                controller.setSymbol("link.circle")
                controller.panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                controller.reduceMotion = { reduced }
                let makeContent = {
                    fixture.roots += 1
                    return AnyView(Content(fixture: fixture, model: fixture.model(), retainingRoot: retainingRoot,
                                           reduced: reduced, scheme: scheme).id(fixture.roots))
                }
                hosting.rootView = makeContent()
                controller.onWillOpen = { if !retainingRoot { hosting.rootView = makeContent() } }
                let initialized = ProcessInfo.processInfo.systemUptime
                configure(controller, fixture)
                let prepared = ProcessInfo.processInfo.systemUptime
                defer {
                    controller.close()
                    BridgeyWindows.orderOut(controller.panel)
                    NSStatusBar.system.removeStatusItem(controller.statusItem)
                }
                var samples: [[String: Any]] = []
                for index in 0..<6 {
                    let beforeReads = fixture.providerReads
                    let opened = ProcessInfo.processInfo.systemUptime
                    controller.open(byDrag: false)
                    let returned = ProcessInfo.processInfo.systemUptime
                    let acknowledged = BridgeyWindows.windowServerShows(controller.panel.windowNumber)
                    let serverTime = ProcessInfo.processInfo.systemUptime
                    let initialFrame = controller.panel.frame
                    pump(until: opened + 0.045)
                    let midpoint = ProcessInfo.processInfo.systemUptime
                    let midAlpha = controller.panel.alphaValue
                    let midServerAlpha = serverAlpha(controller.panel)
                    let readsAtMidpoint = fixture.providerReads - beforeReads
                    if index == 0 {
                        try capture(hosting.view, directory: directory, name: "menu-content-mid-open-\(label)", canvas: nil, scheme: scheme)
                    }
                    pump(until: max(opened + 0.20, ProcessInfo.processInfo.systemUptime))
                    let settled = controller.panel.frame
                    if index == 0 {
                        try capture(hosting.view, directory: directory, name: "menu-panel-390-\(label)",
                                    canvas: NSSize(width: 390, height: 844), scheme: scheme)
                        try capture(hosting.view, directory: directory, name: "menu-panel-1440-\(label)",
                                    canvas: NSSize(width: 1440, height: 900), scheme: scheme)
                    }
                    let closing = ProcessInfo.processInfo.systemUptime
                    controller.close()
                    pump(until: closing + 0.045)
                    let closeAlpha = controller.panel.alphaValue
                    let closeVisible = controller.panel.isVisible
                    let closeServerAlpha = serverAlpha(controller.panel)
                    pump(until: max(closing + 0.16, ProcessInfo.processInfo.systemUptime))
                    samples.append([
                        "index": index, "openCallMs": (returned - opened) * 1000,
                        "windowServerAckMs": (serverTime - opened) * 1000, "windowServerAcknowledged": acknowledged,
                        "midOpenMs": (midpoint - opened) * 1000, "midOpenAlpha": Double(midAlpha),
                        "midOpenServerAlpha": midServerAlpha.map { $0 as Any } ?? NSNull(),
                        "readsAtMidOpen": readsAtMidpoint, "providerReads": fixture.providerReads - beforeReads,
                        "initialFrame": rect(initialFrame), "settledFrame": rect(settled),
                        "contentBounds": rect(hosting.view.bounds), "midCloseAlpha": Double(closeAlpha),
                        "midCloseServerAlpha": closeServerAlpha.map { $0 as Any } ?? NSNull(), "midCloseVisible": closeVisible,
                        "closedAtEnd": !controller.panel.isVisible,
                    ])
                }
                controller.open(byDrag: false)
                pump(until: ProcessInfo.processInfo.systemUptime + 0.16)
                controller.dismissFromOutside()
                controller.togglePanel()
                let rapidReopen = controller.isOpen
                // Exercise the real animator through a reversal, then outlive the stale exit.
                pump(until: ProcessInfo.processInfo.systemUptime + 0.20)
                controller.close()
                pump(until: ProcessInfo.processInfo.systemUptime + 0.03)
                let reversalAlpha = serverAlpha(controller.panel)
                controller.open(byDrag: false)
                pump(until: ProcessInfo.processInfo.systemUptime + 0.25)
                let reversalSucceeded = controller.isOpen && controller.panel.isVisible
                    && controller.panel.alphaValue == 1 && !controller.panel.ignoresMouseEvents
                    && !controller.panel.isAccessibilityHidden()
                if retainingRoot {
                    XCTAssertTrue(rapidReopen, "a distinct new click must reopen immediately")
                    XCTAssertTrue(reversalSucceeded, "a stale exit must not hide a reopened panel")
                }
                controller.close()
                BridgeyWindows.orderOut(controller.panel)
                scenarios.append([
                    "name": label, "initializationMs": (initialized - start) * 1000,
                    "preparationMs": (prepared - initialized) * 1000, "rootConstructions": fixture.roots,
                    "appearances": fixture.appearances, "providerReads": fixture.providerReads,
                    "rapidReopenHonored": rapidReopen, "screenUnavailable": BridgeyWindows.screenUnavailable(),
                    "reversalStartServerAlpha": reversalAlpha.map { $0 as Any } ?? NSNull(),
                    "reversalSucceeded": reversalSucceeded,
                    "samples": samples,
                ])
            }
        }
        let report: [String: Any] = [
            "retainingRoot": retainingRoot, "scenarios": scenarios,
            "fixture": "Synthetic StreamPanelView: 3 peers, 200 history entries, no real provider access",
            "measurement": "Native open-call CPU and window-server acknowledgement, not physical click-to-photon latency",
            "capture": "Mounted NSHostingView bitmap; excludes window alpha/shadow/compositor. Native alpha telemetry recorded separately.",
            "configuration": "Owned native Swift XCTest debug build; compiler reservation is not browser CPU throttling",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("menu-panel-opening.json"))
    }

    private static func pump(until end: TimeInterval) {
        while ProcessInfo.processInfo.systemUptime < end {
            RunLoop.main.run(until: Date().addingTimeInterval(min(0.003, end - ProcessInfo.processInfo.systemUptime)))
        }
    }

    private static func rect(_ rect: NSRect) -> [Double] {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].map(Double.init)
    }

    private static func serverAlpha(_ window: NSWindow) -> Double? {
        let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return (windows.first { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }?[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
    }

    private static func capture(_ view: NSView, directory: URL, name: String, canvas: NSSize?, scheme: ColorScheme) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw XCTSkip("NSHostingView cannot draw a fixture bitmap here")
        }
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        var result = bitmap
        if let canvas {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            (scheme == .dark ? NSColor(calibratedRed: 5/255, green: 11/255, blue: 24/255, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
            NSRect(origin: .zero, size: canvas).fill()
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            image.draw(in: NSRect(x: (canvas.width - view.bounds.width) / 2, y: canvas.height - view.bounds.height - 16,
                                  width: view.bounds.width, height: view.bounds.height))
            NSGraphicsContext.restoreGraphicsState()
            result = rep
        }
        let bytes = try XCTUnwrap(result.representation(using: .png, properties: [:]))
        try bytes.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
