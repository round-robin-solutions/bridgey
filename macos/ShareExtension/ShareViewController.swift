import AppKit
import UniformTypeIdentifiers

// Bridgey's Share extension: Share > Bridgey in Finder, Photos, Safari and every other app. It shows no UI
// of its own. It copies what was shared onto a private pasteboard and asks Bridgey to take it
// (`in.roundrobin.bridgey.send://share`); Bridgey then shows its Send to chooser (device, Tray,
// optimisation, free space). Nothing is sent from here and nothing is stored. The names below must match
// ShareHandoff in Sources/BridgeyMac/ShareAndServices.swift.

private let pasteboardName = NSPasteboard.Name("in.roundrobin.bridgey.share")
private let handoffURL = URL(string: "in.roundrobin.bridgey.send://share")!

final class ShareViewController: NSViewController {
    private var started = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard !started else { return }
        started = true
        collect { [weak self] files, links, images, texts in
            self?.handOff(files: files, links: links, images: images, texts: texts)
        }
    }

    private func providers() -> [NSItemProvider] {
        (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }

    private func sharedText() -> [String] {
        (extensionContext?.inputItems as? [NSExtensionItem] ?? []).compactMap { $0.attributedContentText?.string }
            .filter { !$0.isEmpty }
    }

    private func collect(_ done: @escaping ([URL], [URL], [(Data, String)], [String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [URL] = []
        var links: [URL] = []
        var images: [(Data, String)] = []
        var texts: [String] = sharedText()
        for provider in providers() {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { lock.withLock { files.append(url) } }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { lock.withLock { links.append(url) } }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.png.identifier
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    if let data { lock.withLock { images.append((data, type)) } }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    if let text, !text.isEmpty { lock.withLock { texts.append(text) } }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) { done(files, links, images, texts) }
    }

    /// One kind per hand-off, in Bridgey's order: files, else a link, else an image, else text.
    private func handOff(files: [URL], links: [URL], images: [(Data, String)], texts: [String]) {
        let board = NSPasteboard(name: pasteboardName)
        board.clearContents()
        if !files.isEmpty {
            board.writeObjects(files as [NSURL])
        } else if let link = links.first {
            board.writeObjects([link as NSURL])
        } else if let (data, type) = images.first {
            let pasteType: NSPasteboard.PasteboardType = UTType(type)?.conforms(to: .png) == true ? .png
                : (UTType(type)?.conforms(to: .jpeg) == true ? NSPasteboard.PasteboardType("public.jpeg") : .tiff)
            if pasteType == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                board.setData(png, forType: .png)
            } else {
                board.setData(data, forType: pasteType)
            }
        } else if let text = texts.first {
            board.setString(text, forType: .string)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }
        NSWorkspace.shared.open(handoffURL)
        extensionContext?.completeRequest(returningItems: nil)
    }
}
