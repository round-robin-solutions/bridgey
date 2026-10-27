import Foundation

// Folders sent to this Mac (phone to Mac) and downloads this Mac asked for: one receive session per folder.

@MainActor
final class FolderReceiver {
    private var expected: [String: ExpectedDownload] = [:]

    func expect(_ download: ExpectedDownload) {
        expected[download.requestId] = download
    }

    func cancelExpected(_ download: ExpectedDownload) {
        expected.removeValue(forKey: download.requestId)
    }
}
