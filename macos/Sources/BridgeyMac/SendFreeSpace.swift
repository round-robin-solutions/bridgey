import Foundation

// The phone's free space on the send surfaces (send sheet, Tray, drop tiles, quick send): what a send writes
// on the phone, and what happens when it does not fit. The numbers come from PairingCoordinator.phoneFreeSpace
// (FreeSpace.swift); without them every check is `.ok`.

enum SendSizing {
    /// Bytes of files and folders as they are now (folders counted up to 20,000 entries).
    nonisolated static func bytes(_ urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return total + (values?.isDirectory == true ? TrayStore.folderSize(url) : Int64(values?.fileSize ?? 0))
        }
    }

    /// Bytes of what a drop carried that land as files (text and links go to the clipboard).
    nonisolated static func bytes(_ payloads: [DropPayload]) -> Int64 {
        payloads.reduce(Int64(0)) { total, payload in
            switch payload {
            case let .files(urls): return total + bytes(urls)
            case let .image(data, _): return total + Int64(data.count)
            case .text, .link: return total
            }
        }
    }

    /// What lands on the phone: the optimised estimate when known, else the originals.
    static func needed(original: Int64, saving: Double?) -> Int64 {
        guard let saving else { return original }
        return Int64((Double(original) * (1 - min(max(saving, 0), 1))).rounded())
    }
}

/// What a send surface does with a free-space check.
enum FreeSpaceGate: Equatable {
    case send
    /// Send, and show the line as a warning.
    case sendWithWarning(String)
    /// Do not send; show the line.
    case refuse(String)

    init(_ check: FreeSpaceCheck, phoneName: String) {
        switch check {
        case .ok: self = .send
        case .warn: self = .sendWithWarning(check.message(phoneName: phoneName) ?? "")
        case .block: self = .refuse(check.message(phoneName: phoneName) ?? "")
        }
    }

    var message: String? {
        switch self {
        case .send: nil
        case let .sendWithWarning(text), let .refuse(text): text
        }
    }

    var refuses: Bool { if case .refuse = self { return true } else { return false } }
}

extension PairingCoordinator {
    /// The gate for `needed` bytes to `deviceID`, with the phone's name in the line.
    func freeSpaceGate(needed: Int64, deviceID: String, now: Date = Date()) -> FreeSpaceGate {
        let name = connectedPhones.first { $0.id == deviceID }?.name ?? deviceID
        return FreeSpaceGate(FreeSpaceCheck.evaluate(needed: needed, free: phoneFreeSpace[deviceID], now: now), phoneName: name)
    }
}
