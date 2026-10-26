import AppKit
import Foundation

/// The parts of a pasteboard the code copy needs. Nothing here reads what is on the clipboard.
protocol CodePasteboard: AnyObject {
    var changeCount: Int { get }
    /// Replaces the contents with [code], marked concealed and transient, kept off Universal
    /// Clipboard. Returns the change count after the write.
    @discardableResult func writeCode(_ code: String) -> Int
    func clearCode()
}

/// nspasteboard.org markers: clipboard managers (and Bridgey's own Automatic clipboard) skip these.
let codeConcealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let codeTransientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

extension NSPasteboard: CodePasteboard {

    @discardableResult func writeCode(_ code: String) -> Int {
        // currentHostOnly keeps the code off Universal Clipboard; the nspasteboard.org markers tell
        // clipboard managers (and Bridgey's own Automatic clipboard) to skip it.
        prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        item.setData(Data(), forType: codeConcealedPasteboardType)
        item.setData(Data(), forType: codeTransientPasteboardType)
        writeObjects([item])
        return changeCount
    }

    func clearCode() {
        clearContents()
    }
}

/// Copies a code and clears it again after `clearAfter` seconds if nothing was copied since. It
/// compares change counts only, so it never reads the clipboard.
@MainActor
final class CodeClipboard {
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    nonisolated static let clearAfter: TimeInterval = 60

    private let pasteboard: CodePasteboard
    private let schedule: Scheduler
    /// The change count right after our last write, while it may still be ours to clear.
    private(set) var pendingChangeCount: Int?

    init(pasteboard: CodePasteboard = NSPasteboard.general, schedule: @escaping Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }) {
        self.pasteboard = pasteboard
        self.schedule = schedule
    }

    func copy(_ code: String) {
        let written = pasteboard.writeCode(code)
        pendingChangeCount = written
        schedule(Self.clearAfter) { [weak self] in self?.clearIfUnchanged(written) }
    }

    /// Clears only if the clipboard still holds the code this write put there.
    func clearIfUnchanged(_ written: Int) {
        guard pendingChangeCount == written else { return }
        pendingChangeCount = nil
        if pasteboard.changeCount == written { pasteboard.clearCode() }
    }
}
