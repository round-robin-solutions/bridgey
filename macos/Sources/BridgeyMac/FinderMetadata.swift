import CoreServices
import Darwin
import Foundation

// Files 2.0: what Finder shows about a file from the phone. "Where from" (kMDItemWhereFroms) on every received
// file and folder, the Bridgey tag when Settings > Files asks for it, and the Downloads stack bounce in the
// Dock when something lands inside ~/Downloads. All best effort: a volume without extended attributes just
// goes without.

enum FinderMetadata {
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"
    static let quarantineAttribute = "com.apple.quarantine"
    static let tag = "Bridgey"

    /// "Bridgey: OnePlus 11".
    static func whereFrom(phoneName: String) -> String { "Bridgey: \(phoneName)" }

    /// Writes kMDItemWhereFroms as Safari does: a binary property list holding an array of strings.
    @discardableResult
    static func setWhereFrom(_ url: URL, _ value: String) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0) else { return false }
        return data.withUnsafeBytes { bytes in
            setxattr(url.path, whereFromsAttribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) == 0
        }
    }

    static func whereFroms(_ url: URL) -> [String]? {
        let size = getxattr(url.path, whereFromsAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, whereFromsAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
    }

    /// Marks a received file or folder as downloaded (com.apple.quarantine), as browsers do, so
    /// macOS checks it before it first opens. Set before the item is moved into place.
    @discardableResult
    static func quarantine(_ url: URL) -> Bool {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Bridgey",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var target = url
        return (try? target.setResourceValues(values)) != nil
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    /// Adds the Bridgey Finder tag, keeping the item's other tags.
    @discardableResult
    static func addTag(_ url: URL) -> Bool {
        let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        guard !existing.contains(tag) else { return true }
        do {
            try (url as NSURL).setResourceValue(existing + [tag], forKey: .tagNamesKey)
            return true
        } catch {
            return false
        }
    }

    static func tags(_ url: URL) -> [String] { (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [] }

    /// True when `url` is inside the user's Downloads folder (then the Dock's Downloads stack can bounce).
    static func isInDownloads(_ url: URL, downloads: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first) -> Bool {
        guard let downloads else { return false }
        let base = downloads.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    /// The Dock bounces the Downloads stack, as for a finished Safari download.
    static func bounceDownloads(_ url: URL) {
        guard isInDownloads(url) else { return }
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: url.resolvingSymlinksInPath().path)
    }

    /// Everything a finished receive gets: where from (again, on the top-level items), the tag, the bounce.
    static func finish(_ urls: [URL], phoneName: String, tag: Bool) {
        let value = whereFrom(phoneName: phoneName)
        for url in urls {
            setWhereFrom(url, value)
            if tag { addTag(url) }
        }
        if let first = urls.first { bounceDownloads(first) }
    }
}
