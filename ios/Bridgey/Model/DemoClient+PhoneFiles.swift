import Foundation
import UIKit

#if DEBUG
extension DemoClient {
    private static let day: Int64 = 86_400_000

    private static func daysAgo(_ days: Int64) -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) - days * day }

    /// Sample folders: name, folder or file size, MIME type.
    private static func demoEntries(_ path: String) -> [[String: Any]] {
        func folder(_ name: String, _ d: Int64) -> [String: Any] { ["name": name, "dir": true, "modified": daysAgo(d), "thumb": false] }
        func file(_ name: String, _ size: Int64, _ mime: String, _ d: Int64, thumb: Bool = false) -> [String: Any] {
            ["name": name, "dir": false, "size": size, "mimeType": mime, "modified": daysAgo(d), "thumb": thumb]
        }
        switch path {
        case "":
            return [folder("Boarding passes", 2), folder("Receipts", 9), folder("Trip to Goa", 14),
                    file("Lease renewal.pdf", 412_000, "application/pdf", 1), file("Notes.txt", 2_300, "text/plain", 3),
                    file("Site walkthrough.mov", 96_000_000, "video/quicktime", 6, thumb: true)]
        case "Trip to Goa":
            return [file("Beach at sunset.jpg", 3_400_000, "image/jpeg", 14, thumb: true), file("Fort Aguada.jpg", 2_900_000, "image/jpeg", 14, thumb: true),
                    file("Itinerary.pdf", 188_000, "application/pdf", 15), file("Market.heic", 2_100_000, "image/heic", 13, thumb: true)]
        default:
            return [file("Document.pdf", 120_000, "application/pdf", 5)]
        }
    }

    private static var demoPhotos: [[String: Any]] {
        var photos: [[String: Any]] = []
        for i in 0..<18 {
            let video = i % 7 == 3
            var photo: [String: Any] = ["ref": ["mediaId": String(500 + i)], "name": "IMG_\(4100 + i).jpg", "thumb": true, "location": "Camera"]
            photo["size"] = 2_400_000 + i * 10_000
            photo["mimeType"] = video ? "video/mp4" : "image/jpeg"
            photo["modified"] = daysAgo(Int64(i / 3))
            if video { photo["durationMs"] = 42_000 }
            photos.append(photo)
        }
        return photos
    }

    private func emitFiles(_ name: String, _ detail: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail), let text = String(data: data, encoding: .utf8) else { return }
        let event = CoreEvent(kind: .phoneFiles, deviceID: Self.pixel, name: name, text: text)
        let send = onEvent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(event) }
    }

    func demoPhoneFiles(deviceID: String, command: [String: Any]) -> [String: Any] {
        let id = UUID().uuidString.lowercased()
        switch command["op"] as? String {
        case "status":
            return ["ok": true, "available": true, "files": true]
        case "places":
            emitFiles("places", ["requestId": id, "writable": true, "media": "full", "documents": true, "places": [
                ["placeId": "default", "label": "Download/Bridgey", "available": true, "freeBytes": 41_000_000_000],
                ["placeId": "q3Jx0bVv1eG7tq8Wm2l5wA", "label": "Documents", "available": true, "freeBytes": NSNull()],
            ]])
        case "list":
            let path = command["path"] as? String ?? ""
            let entries = Self.demoEntries(path)
            emitFiles("list", ["requestId": id, "placeId": command["placeId"] ?? "default", "path": path, "entries": entries, "writable": true,
                               "folderCount": entries.filter { $0["dir"] as? Bool == true }.count, "fileCount": entries.filter { $0["dir"] as? Bool != true }.count])
        case "media":
            emitFiles("media", ["requestId": id, "kind": command["kind"] ?? "media", "items": Self.demoPhotos, "access": "full", "indexing": false])
        case "thumbnails":
            let items = command["items"] as? [[String: Any]] ?? []
            let thumbs: [[String: Any]] = items.enumerated().compactMap { n, item in
                guard let key = item["key"] as? String else { return nil }
                return ["key": key, "mimeType": "image/png", "width": 96, "height": 96, "data": Self.demoThumbnail(n)]
            }
            emitFiles("thumbnails", ["requestId": id, "thumbs": thumbs, "missing": [], "done": true])
        default:
            break
        }
        return ["ok": true, "requestId": id]
    }

    /// An abstract gradient, like a photo seen from far away: sky, sea, sand and dusk tones.
    private static func demoThumbnail(_ n: Int) -> String {
        let palettes: [(UIColor, UIColor)] = [
            (UIColor(red: 0.98, green: 0.62, blue: 0.38, alpha: 1), UIColor(red: 0.35, green: 0.25, blue: 0.55, alpha: 1)),
            (UIColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 1), UIColor(red: 0.10, green: 0.40, blue: 0.55, alpha: 1)),
            (UIColor(red: 0.95, green: 0.88, blue: 0.70, alpha: 1), UIColor(red: 0.30, green: 0.60, blue: 0.70, alpha: 1)),
            (UIColor(red: 0.55, green: 0.80, blue: 0.55, alpha: 1), UIColor(red: 0.15, green: 0.35, blue: 0.25, alpha: 1)),
            (UIColor(red: 0.85, green: 0.45, blue: 0.50, alpha: 1), UIColor(red: 0.20, green: 0.15, blue: 0.30, alpha: 1)),
        ]
        let (top, bottom) = palettes[n % palettes.count]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { ctx in
            let colours = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 30, y: 96), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            UIColor.white.withAlphaComponent(0.18).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 52 - CGFloat(n % 4) * 8, y: 18, width: 22, height: 22))
        }
        return image.pngData()?.base64EncodedString() ?? ""
    }

    /// Screenshots of the phone's files: `files` (the test opens a place, a folder and Photos).
    @MainActor
    static func seedPhoneFiles(_ model: AppModel, screen: String) {
        guard screen == "files" else { return }
        model.targetID = pixel
        model.path = [.phoneFiles(deviceID: pixel)]
    }
}
#endif
