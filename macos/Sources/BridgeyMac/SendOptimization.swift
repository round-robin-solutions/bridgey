import Foundation

// Settings > Files > Before sending: what the Mac does to a copy of each item before it goes to the phone.
// Originals are never modified. Phone-side sends get the same options later (deferred).

struct SendOptimization: Codable, Equatable {
    enum ImageMode: String, Codable, CaseIterable { case original, optimize }
    enum ImageFormat: String, Codable, CaseIterable { case jpeg, webp }
    /// Hardware HEVC (H.264 when HEVC is unavailable) at a target size and bitrate.
    enum VideoMode: String, Codable, CaseIterable {
        case original
        case hd1080Balanced = "1080_balanced"
        case hd1080Small = "1080_small"
        case hd720Balanced = "720_balanced"
        case hd720Small = "720_small"
    }
    enum FolderMode: String, Codable, CaseIterable { case asIs = "as_is", zip }

    static let maxEdgeChoices = [1280, 2048, 4096]
    static let qualityChoices = [60, 70, 80, 90]

    var imageMode: ImageMode = .original
    var maxEdge = 2048
    var format: ImageFormat = .jpeg
    var quality = 80
    /// GPS position. On by default: where a photo was taken is the detail people least mean to share.
    var stripLocation = true
    /// Camera make, model, lens and serial numbers.
    var stripCamera = false
    /// Capture and edit dates (kept by default: the phone's gallery sorts by them).
    var stripDates = false
    var videoMode: VideoMode = .original
    var folderMode: FolderMode = .asIs

    static let `default` = SendOptimization()

    /// Everything off: the item is sent as it is.
    static let original = SendOptimization(imageMode: .original, stripLocation: false, stripCamera: false, stripDates: false,
                                           videoMode: .original, folderMode: .asIs)

    /// What the chip's "Optimised" means when Settings leave everything original.
    static let recommended = SendOptimization(imageMode: .optimize, maxEdge: 2048, format: .jpeg, quality: 80, stripLocation: true,
                                              videoMode: .hd1080Balanced, folderMode: .asIs)

    var stripsMetadata: Bool { stripLocation || stripCamera || stripDates }

    /// True when nothing would change any item.
    var isOriginal: Bool { imageMode == .original && !stripsMetadata && videoMode == .original && folderMode == .asIs }

    /// The image settings that change the bytes of an image, for cache keys.
    var imageFingerprint: String {
        let resize = imageMode == .optimize ? "\(maxEdge)-\(format.rawValue)-\(quality)" : "orig"
        return "img1:\(resize):\(stripLocation ? 1 : 0)\(stripCamera ? 1 : 0)\(stripDates ? 1 : 0)"
    }

    var videoFingerprint: String { "vid1:\(videoMode.rawValue)" }
}
