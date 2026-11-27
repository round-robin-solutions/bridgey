import Foundation
/// The status lines Pairing and QuickActions set ("Ping delivered", "Saved photo.jpg to Downloads") in the app's language,
/// at the point they are shown: the menu bar panel, the Send sheet, the Tray and the Transfers window. The English text
/// stays the value inside, because TransfersModel reads words such as "cancelled" from it to choose a chip and reason.
enum StatusText {
    static func localized(_ status: String) -> String {
        if let key = exact[status] { return L10n.text(key, fallback: status) }
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: status, range: NSRange(status.startIndex..., in: status)) else { continue }
            let values: [CVarArg] = (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: status).map { String(status[$0]) }
            }
            return String(format: L10n.text(pattern.key, fallback: pattern.fallback), arguments: values)
        }
        return status
    }

    private struct Pattern {
        let key: String
        let regex: NSRegularExpression
        let fallback: String
    }
    private static let exact: [String: String] = [
        "Transfer cancelled": "status.transferCancelled",
        "File transfer is turned off on one of your devices": "status.filesOffSomewhere",
        "File transfer failed": "status.fileFailed",
        "Transfer interrupted; reconnect to retry": "status.transferInterrupted",
        "Not connected, so the file was not sent": "status.fileNotConnected",
        "Folders aren\u{2019}t sent yet": "status.foldersNotYet",
        "File transfer is turned off on Android": "status.filesOffAndroid",
        "Waiting for Android\u{2026}": "status.waitingAndroid",
        "Transfer cancelled by Android": "status.cancelledByAndroid",
        "File verification failed": "status.verificationFailed",
        "File transfer interrupted": "status.fileInterrupted",
        "Encryption failed": "status.encryptionFailed",
        "Copy a valid http or https link first": "status.copyLink",
        "Clipboard is turned off on one of your devices": "status.clipboardOffSomewhere",
        "Clipboard exceeds 32 KiB. Send large text or diagnostics as a file.": "status.clipboardTooBig",
        "Android is not connected": "status.androidNotConnected",
        "Web links are unavailable on one of your devices": "status.linksOffSomewhere",
        "Waiting for Android connection\u{2026}": "status.waitingAndroidConnection",
        "Sending link\u{2026}": "status.sendingLink",
        "Sending call request\u{2026}": "status.sendingCall",
        "Reconnect before retrying": "status.reconnectFirst",
        "Pinging Android\u{2026}": "status.pinging",
        "Ping requires Bridgey 0.6 on both devices": "status.pingNeedsVersion",
        "Ping delivered": "status.pingDelivered",
        "Ping could not be encrypted": "status.pingEncryption",
        "Phone link does not contain a valid number": "status.linkNoNumber",
        "Not enough free space on this Mac": "status.macSpace",
        "Not connected, so the link was not sent": "status.linkNotConnected",
        "Link received": "status.linkReceived",
        "Link opened": "status.linkOpened",
        "Link delivered; it opens when tapped on the other device": "status.linkDelivered",
        "Link declined; check settings or dismiss the previous link": "status.linkDeclined",
        "Could not read the selected file": "status.fileUnreadable",
        "Could not prepare the selected file": "status.filePrepare",
        "Could not prepare the clipboard": "status.clipboardPrepare",
        "Could not open your browser": "status.browserFailed",
        "Copy a phone number first": "status.copyNumber",
        "Confirm the call from the Android notification": "status.confirmCall",
        "Clipboard is over 32 KiB, so it was not sent automatically": "status.clipboardNotAuto",
        "Clipboard is empty or unavailable": "status.clipboardEmpty",
        "Clipboard does not contain a valid phone number": "status.clipboardNoNumber",
        "Calls are turned off or require Bridgey alpha.5 on both devices": "status.callsUnavailable",
        "Call started on Android": "status.callStarted",
        "Android rejected the call request": "status.callRejected",
        "Android did not connect in time": "status.androidLate",
        "Android did not confirm the call request": "status.callNotConfirmed",
        "Android did not confirm delivery": "status.linkNotConfirmed",
        "Android did not acknowledge the ping": "status.pingNoAnswer",
    ]

    // Most specific first: "Sending x: detail" before "Sending x…".
    private static let patterns: [Pattern] = [
        ("status.receivingDetail", #"^Receiving (.+): ([^:]+)$"#, "Receiving %1$@: %2$@"),
        ("status.sendingDetail", #"^Sending (.+): ([^:]+)$"#, "Sending %1$@: %2$@"),
        ("status.sending", #"^Sending (.+)…$"#, "Sending %@\u{2026}"),
        ("status.preparing", #"^Preparing (.+)…$"#, "Preparing %@\u{2026}"),
        ("status.verifying", #"^Verifying (.+) on Android…$"#, "Verifying %@ on Android\u{2026}"),
        ("status.saved", #"^Saved (.+) to (.+)$"#, "Saved %1$@ to %2$@"),
        ("status.savedOnAndroid", #"^(.+) saved on Android$"#, "%@ saved on Android"),
        ("status.pingFrom", #"^Ping from (.+)$"#, "Ping from %@"),
        ("status.clipFrom", #"^This clip came from (.+)$"#, "This clip came from %@"),
        ("status.filesOffOn", #"^File transfer is turned off on (.+)$"#, "File transfer is turned off on %@"),
    ].map { Pattern(key: $0.0, regex: try! NSRegularExpression(pattern: $0.1), fallback: $0.2) }
}
